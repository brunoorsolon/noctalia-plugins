#!/usr/bin/env python3
"""Recognition and recording helper for the magus/dictation Noctalia plugin.

The plugin owns the interface and the settings; this helper owns every job. It
enumerates the PipeWire capture sources, records the selected microphone to a
private 16 kHz mono signed-16 WAV, finalizes that recording on a stop request,
validates the audio before recognition, runs the installed transcribe-cli with
CPU-only inference, thread-matched OpenMP/OpenBLAS limits and niceness 10,
enforces the 30-minute watchdog, ties every child's lifetime to its own so a
killed helper cannot leave a recorder or an engine behind, honours stop, cancel
and controller-loss requests, and persists the raw engine output, logs,
transcript and per-attempt result under the plugin data directory.

Only the Python standard library is used. The plugin never builds a shell
string: it passes a program name and an argument array here, and this helper
does the same to every child it starts.
"""

import argparse
import ctypes
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import wave

# Flags the plugin depends on. An installed engine that lacks any of them is
# incompatible and must be reported instead of guessed around.
REQUIRED_FLAGS = (
    "--backend",
    "--threads",
    "--timestamps",
    "--model",
    "--batch",
    "--batch-size",
    "--batch-jsonl",
)

DEFAULT_TIMEOUT_SECONDS = 1800  # the 30-minute inference watchdog lives here
HEARTBEAT_SECONDS = 5  # how often the helper tells the plugin it is still alive
NICE = 10
PR_SET_PDEATHSIG = 1  # Linux prctl option: signal the child when its parent dies
CONTROL_TOKEN = re.compile(r"<\|[^|>]*\|>")
TRUNCATION_MARK = "truncat"
# Everything after this mark is the engine's own output: the panel shows it, the
# diagnostics export never does. Recognised speech and user paths live in there.
ENGINE_NOTE_MARK = " Engine output: "
SAFE_ID = re.compile(r"[^A-Za-z0-9._-]")

# Recording is fixed to the format the engine and the plugin validate: a real
# 16 kHz mono signed-16 WAV captured by pw-record from the selected source.
RECORD_RATE = 16000
RECORD_CHANNELS = 1
RECORD_FORMAT = "s16"
# A stop waits this long for pw-record to finish the WAV before it is killed.
STOP_GRACE_SECONDS = 5
# Playback is bounded so a stuck pw-play cannot outlive its helper forever.
DEFAULT_PLAY_TIMEOUT_SECONDS = 600
# Cancel and controller loss wait this long before escalating to SIGKILL.
CANCEL_GRACE_SECONDS = 3
# The controller refreshes its lease every second; six seconds of silence means
# it is gone and the microphone must be released even if nobody asked.
DEFAULT_LEASE_SECONDS = 6
MONITOR_SUFFIX = ".monitor"
MONITOR_PREFIX = "monitor of "
HISTORY_LIMIT = 20  # the newest jobs the history interface offers
HISTORY_PREVIEW_CHARS = 120
# Every job directory is named by this plugin and sits directly under jobs/, so a
# deletion target that does not match is not this plugin's to remove.
JOB_NAME = re.compile(r"^job-[A-Za-z0-9._-]+$")
# Retention counts finished dictations. A job that produced a result the plugin
# can show is finished; a failed, interrupted or recoverable cancelled job is not,
# and is only ever removed when the user asks for it.
COMPLETED_SEVERITIES = ("ok", "review")
DEFAULT_RETENTION = 10
# Diagnostics are metadata about this plugin's own job directories, never the
# recognised speech, the raw engine output or anything outside the data directory.
DIAGNOSTIC_FORMAT = "magus/dictation-diagnostics"
DIAGNOSTIC_VERSION = 1
DIAGNOSTIC_PREVIEW_NAME = "diagnostics-preview.json"
DIAGNOSTIC_MESSAGE_CHARS = 200
EXPORT_PREFIX = "dictation"

# Set per command; every verdict is mirrored here so the plugin, which launches
# this helper detached, can read the outcome instead of a short-lived callback.
SUMMARY_PATH = None


def verdict(outcome, severity, message, **extra):
    payload = {
        "ok": severity in ("ok", "review"),
        "outcome": outcome,
        "severity": severity,
        "message": message,
        "copyable": False,
    }
    payload.update(extra)
    emit(payload)
    return payload


def emit(payload):
    """Report an outcome, and say whether its durable summary was committed.

    Retention runs on that answer alone: pruning older audio for a successor
    whose own result never reached the disk would hide the newer dictation and
    delete the older one for nothing.
    """
    line = json.dumps(payload)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()
    if not SUMMARY_PATH:
        return True
    try:
        private_dir(os.path.dirname(SUMMARY_PATH))
        temporary = SUMMARY_PATH + ".tmp"
        private_write(temporary, line + "\n")
        os.replace(temporary, SUMMARY_PATH)
    except OSError:
        # The plugin keeps its own stall guard; the verdict on stdout is what matters.
        return False
    return True


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def file_facts(path):
    stat = os.stat(path)
    return {"path": path, "size": stat.st_size, "mtime": int(stat.st_mtime)}


def private_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def private_write(path, text):
    handle = os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb")
    with handle:
        handle.write(text.encode("utf-8"))
    os.chmod(path, 0o600)


def private_open(path):
    """Binary handle for a file the engine writes into, with private permissions."""
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb")


def atomic_write(path, text):
    """Write through a rename so a reader never sees half a file."""
    temporary = path + ".tmp"
    private_write(temporary, text)
    os.replace(temporary, path)


def log_tail(path, limit=240):
    """The last engine output, so a failing run explains itself in the outcome."""
    try:
        with open(path, "rb") as handle:
            text = handle.read().decode("utf-8", "replace")
    except OSError:
        return ""
    lines = [" ".join(line.split()) for line in text.splitlines()]
    lines = [line for line in lines if line]
    return " ".join(lines[-2:])[-limit:]


def safe_id(value):
    return SAFE_ID.sub("_", str(value))[:120] or "job"


def write_heartbeat(path):
    """Tell the plugin this helper is still alive, for as long as it is."""
    try:
        private_write(path, json.dumps({"ts": int(time.time()), "pid": os.getpid()}) + "\n")
    except OSError:
        # Losing the heartbeat only shortens how long a stuck plugin waits.
        pass


def write_status(job_dir, job, phase, message):
    """The phase the panel reports: starting, recording, finalizing, transcribing."""
    try:
        atomic_write(
            os.path.join(job_dir, "status.json"),
            json.dumps(
                {
                    "ts": int(time.time()),
                    "jobId": job["jobId"],
                    "startedAt": job["startedAt"],
                    "phase": phase,
                    "message": message,
                }
            )
            + "\n",
        )
    except OSError:
        # Status is a view, not a contract; the summary carries the outcome.
        pass


def write_job_record(job_dir, job):
    """The config this job started with, so a reload adopts it instead of guessing."""
    try:
        atomic_write(os.path.join(job_dir, "job.json"), json.dumps(job, indent=2) + "\n")
    except OSError:
        pass


def probe_flags(engine):
    """Return (required flags the engine's --help omits, failure to run --help)."""
    try:
        completed = subprocess.run(
            [engine, "--help"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return [], "%s --help failed: %s" % (engine, exc)
    text = completed.stdout.decode("utf-8", "replace").lower()
    missing = [flag for flag in REQUIRED_FLAGS if flag not in text]
    if completed.returncode != 0 and len(missing) == len(REQUIRED_FLAGS):
        return [], "%s --help exited with status %d and printed no usage" % (engine, completed.returncode)
    return missing, None


def engine_problem(engine, model):
    """The shared engine/model preflight; None when the pair can be used."""
    if not os.path.isfile(engine) or not os.access(engine, os.X_OK):
        return {"outcome": "setup_required", "message": "Setup required: the recognition engine is missing or not executable."}
    if not os.path.isfile(model):
        return {"outcome": "setup_required", "message": "Setup required: the Model GGUF is missing."}
    missing, failure = probe_flags(engine)
    if failure:
        return {"outcome": "engine_unavailable", "message": "The recognition engine could not be run: %s." % failure}
    if missing:
        return {
            "outcome": "engine_incompatible",
            "message": "Setup required: the engine does not support %s." % ", ".join(missing),
            "extra": {"missingFlags": missing},
        }
    return None


def validate_wav(path):
    if path == "":
        return "Select the recording to transcribe in settings."
    if not os.path.isfile(path):
        return "The imported recording does not exist: %s" % path
    try:
        with wave.open(path, "rb") as handle:
            channels = handle.getnchannels()
            width = handle.getsampwidth()
            rate = handle.getframerate()
            frames = handle.getnframes()
            compression = handle.getcomptype()
    except (wave.Error, EOFError, OSError, ValueError) as exc:
        return "The imported file is not a readable WAV: %s" % exc
    if compression != "NONE":
        return "The imported WAV uses compressed audio; export signed-16 PCM."
    if channels != 1:
        return "The imported WAV has %d channels; the plugin needs 16 kHz mono signed-16." % channels
    if width != 2:
        return "The imported WAV is %d-byte samples; the plugin needs 16 kHz mono signed-16." % width
    if rate != 16000:
        return "The imported WAV is %d Hz; the plugin needs 16 kHz mono signed-16." % rate
    if frames <= 0:
        return "The imported WAV contains no audio frames."
    return None


# ── Capture sources ──────────────────────────────────────────────────────────

def is_monitor(props, name):
    """A monitor is an output loopback, never a microphone.

    pw-dump does not mark monitors with one portable field, so the two names
    PipeWire and the session managers give them are used, and the plugin never
    falls back to one when the chosen source is missing.
    """
    if name.lower().endswith(MONITOR_SUFFIX):
        return True
    text = str(props.get("node.description") or props.get("device.description") or "")
    return text.strip().lower().startswith(MONITOR_PREFIX)


def enumerate_sources(raw):
    sources = []
    for obj in raw:
        if not isinstance(obj, dict):
            continue
        info = obj.get("info")
        props = info.get("props") if isinstance(info, dict) else None
        if not isinstance(props, dict) or props.get("media.class") != "Audio/Source":
            continue
        name = props.get("node.name")
        if not isinstance(name, str) or name.strip() == "":
            continue
        if is_monitor(props, name):
            continue
        description = props.get("node.description") or props.get("device.description") or name
        sources.append(
            {
                "id": name,
                "name": name,
                "description": str(description),
            }
        )
    sources.sort(key=lambda source: (source["description"].lower(), source["id"]))
    return sources


def pw_dump_sources():
    """(sources, problem) from the structured PipeWire graph, never from names alone."""
    try:
        completed = subprocess.run(
            ["pw-dump"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        return None, "Could not read the PipeWire graph with pw-dump: %s" % exc
    if completed.returncode != 0:
        lines = [line for line in completed.stderr.decode("utf-8", "replace").splitlines() if line.strip()]
        detail = ": " + " ".join(lines[-1].split()) if lines else ""
        return None, "pw-dump exited with status %d%s" % (completed.returncode, detail)
    try:
        raw = json.loads(completed.stdout.decode("utf-8", "replace"))
    except ValueError as exc:
        return None, "pw-dump did not produce JSON: %s" % exc
    if not isinstance(raw, list):
        return None, "pw-dump produced an unexpected document."
    return enumerate_sources(raw), None


def read_json_file(path):
    """A job file as a dict, or None when it is missing or unreadable."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def wav_duration(path):
    """Seconds of audio in a finalized WAV, or None when it is not readable."""
    try:
        with wave.open(path, "rb") as handle:
            rate = handle.getframerate()
            frames = handle.getnframes()
    except (wave.Error, EOFError, OSError, ValueError):
        return None
    if rate <= 0 or frames <= 0:
        return None
    return round(frames / float(rate), 1)


def duration_label(seconds):
    if not isinstance(seconds, (int, float)):
        return ""
    total = int(round(seconds))
    return "%d:%02d" % (total // 60, total % 60)


def transcript_preview(path):
    """The first words of a raw engine transcript, on one line."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return ""
    return " ".join(text.split())[:HISTORY_PREVIEW_CHARS]


def latest_attempt(job_dir):
    """The highest-numbered attempt directory and how many attempts exist."""
    best, count = None, 0
    try:
        names = os.listdir(job_dir)
    except OSError:
        return None, 0
    for name in names:
        match = re.fullmatch(r"attempt-(\d+)", name)
        if not match:
            continue
        number = int(match.group(1))
        count += 1
        if number > (best[0] if best else 0):
            best = (number, os.path.join(job_dir, name))
    return (best[1] if best else None), count


def job_process_running(job_id):
    """Whether a helper process for this job id is still alive.

    The id is in the owning helper's own command line (the recorder and the
    engine are its children), so a match is a live job rather than a leftover
    file. /proc is the only signal available on the hosts this plugin supports;
    when it cannot be read the job stays unconfirmed and counts as interrupted,
    which is what the controller-loss path already does.
    """
    try:
        entries = os.listdir("/proc")
    except OSError:
        return False
    for entry in entries:
        if not entry.isdigit():
            continue
        # A maintenance command carries the id it was asked to act on, so this
        # process would otherwise match itself and refuse to touch anything.
        if int(entry) == os.getpid():
            continue
        try:
            with open(os.path.join("/proc", entry, "cmdline"), "rb") as handle:
                argv = handle.read().decode("utf-8", "replace").split("\0")
        except OSError:
            continue
        for index, token in enumerate(argv):
            if token == "--job-id" and index + 1 < len(argv) and argv[index + 1] == job_id:
                return True
    return False


def tree_size(path):
    """Bytes this plugin's own tree occupies, never following a link out of it."""
    total = 0
    for root, _dirs, files in os.walk(path, followlinks=False):
        for name in files:
            try:
                total += os.stat(os.path.join(root, name), follow_symlinks=False).st_size
            except OSError:
                pass
    return total


def job_entry(name, job_dir):
    """One history entry from the durable files this job already wrote."""
    job = read_json_file(os.path.join(job_dir, "job.json")) or {}
    summary = read_json_file(os.path.join(job_dir, "summary.json"))
    attempt_dir, attempts = latest_attempt(job_dir)
    result = read_json_file(os.path.join(attempt_dir, "result.json")) if attempt_dir else None
    transcript_path = ""
    if attempt_dir:
        candidate = os.path.join(attempt_dir, "transcript.txt")
        if os.path.isfile(candidate):
            transcript_path = candidate
    paths = summary.get("paths") if isinstance(summary, dict) and isinstance(summary.get("paths"), dict) else {}
    if not paths and isinstance(result, dict) and isinstance(result.get("paths"), dict):
        paths = result["paths"]

    recording = ""
    subject = "saved audio"
    if isinstance(job.get("recording"), str) and job["recording"] != "":
        recording = job["recording"]
    elif isinstance(paths.get("recording"), str) and paths["recording"] != "":
        recording = paths["recording"]
    elif isinstance(job.get("wav"), str) and job["wav"] != "":
        recording = job["wav"]
        # A retry reads an earlier dictation's own recording, so only a file the
        # user picked in settings is an import.
        if not job.get("retriesOf"):
            subject = "imported recording"
    if recording == "":
        problem = "There is no saved audio for this dictation, so it cannot be retried."
    else:
        problem = validate_wav(recording)
        if problem and not os.path.isfile(recording):
            problem = "The %s is missing, so this dictation cannot be retried: %s" % (subject, recording)
        elif problem and subject == "saved audio":
            # validate_wav speaks about the file the user picked in settings; this
            # audio is the job's own, so the explanation names that instead.
            problem = problem.replace("The imported ", "The saved ", 1)

    if isinstance(summary, dict) and isinstance(summary.get("outcome"), str):
        state = "complete"
        outcome = summary["outcome"]
        severity = summary.get("severity") if isinstance(summary.get("severity"), str) else "error"
        message = summary.get("message") if isinstance(summary.get("message"), str) else ""
        copyable = summary.get("copyable") is True and transcript_path != ""
    elif job_process_running(name):
        state, outcome, severity, message, copyable = (
            "running",
            "running",
            "ok",
            "This dictation is still running.",
            False,
        )
    else:
        state, outcome, severity, copyable = (
            "interrupted",
            "interrupted",
            "cancelled",
            False,
        )
        message = "Noctalia stopped holding this job before it reported a result, so it was interrupted. The captured audio was preserved."

    started = job.get("startedAt")
    if not isinstance(started, (int, float)) and isinstance(result, dict):
        started = result.get("startedAt")
        started = started * 1000 if isinstance(started, (int, float)) else None
    started = int(started) if isinstance(started, (int, float)) else 0
    duration = wav_duration(recording) if recording != "" else None
    return {
        "id": name,
        "mode": job.get("mode") if isinstance(job.get("mode"), str) else "",
        "retriesOf": job.get("retriesOf") if isinstance(job.get("retriesOf"), str) else "",
        "startedAtMs": started,
        "timestamp": time.strftime("%Y-%m-%d %H:%M", time.localtime(started / 1000)) if started else "",
        "durationSeconds": duration,
        "duration": duration_label(duration),
        "state": state,
        "outcome": outcome,
        "severity": severity,
        "message": message,
        "attempts": attempts,
        "preview": transcript_preview(transcript_path),
        "transcriptPath": transcript_path,
        "recordingPath": recording,
        "recordingUsable": problem is None,
        "recordingMessage": "" if problem is None else problem,
        "copyable": copyable,
    }


def command_history(args):
    """List the durable jobs on disk, newest first, for the history interface.

    Read-only: this never starts a recording, an engine or a paste. A job with
    no summary is interrupted unless a helper for it is still alive, so a
    restart reports the job that was cut off instead of hiding it.
    """
    global SUMMARY_PATH
    args.data_dir = os.path.abspath(args.data_dir)
    SUMMARY_PATH = None
    jobs_dir = os.path.join(args.data_dir, "jobs")
    try:
        names = os.listdir(jobs_dir)
    except OSError:
        names = []
    jobs = []
    for name in sorted(names):
        if not name.startswith("job-"):
            continue
        job_dir = os.path.join(jobs_dir, name)
        if not os.path.isdir(job_dir):
            continue
        jobs.append(job_entry(name, job_dir))
    jobs = [entry for entry in jobs if entry["startedAtMs"] > 0]
    jobs.sort(key=lambda entry: entry["startedAtMs"], reverse=True)
    jobs = jobs[:HISTORY_LIMIT]
    interrupted = sum(1 for entry in jobs if entry["state"] == "interrupted")
    message = "Found %d dictation%s." % (len(jobs), "" if len(jobs) == 1 else "s")
    if interrupted == 1:
        message += " One was interrupted."
    elif interrupted > 1:
        message += " %d were interrupted." % interrupted
    verdict("ok", "ok", message, jobs=jobs, storage=storage_summary(args.data_dir), retention=last_prune(args.data_dir))


# ── Retention, deletion and export ───────────────────────────────────────────
#
# The plugin's own data directory is the only thing these commands may touch.
# Every path is rebuilt from the data directory and a job name this plugin
# writes, checked to be a direct child of jobs/, and then removed without ever
# following a symlink, so a link or a crafted name cannot reach an engine, a
# model, a benchmark recording or a home file.


def jobs_dir_for(data_dir):
    return os.path.join(os.path.abspath(data_dir), "jobs")


def owned_job_dir(data_dir, job_id):
    """A job directory this plugin owns, or (None, reason) for anything else."""
    name = job_id if isinstance(job_id, str) else ""
    if not JOB_NAME.match(name) or ".." in name:
        return None, "That is not a dictation this plugin owns, so nothing was deleted."
    jobs_dir = jobs_dir_for(data_dir)
    candidate = os.path.join(jobs_dir, name)
    if os.path.islink(candidate):
        return None, "That dictation's directory is a link, so it was left alone."
    if os.path.dirname(os.path.realpath(candidate)) != os.path.realpath(jobs_dir):
        return None, "That dictation is outside the plugin's own data directory, so it was left alone."
    if not os.path.isdir(candidate):
        return None, "That dictation is no longer on disk."
    return candidate, None


def remove_tree(root):
    """Remove a directory tree without ever entering a symlink.

    A link inside the tree is unlinked as a link, so it can never reach the file
    or directory it names. Returns the paths that survived.
    """
    failures = []

    def remove(path):
        try:
            entries = list(os.scandir(path))
        except OSError as exc:
            failures.append("%s (%s)" % (path, exc.strerror or exc))
            return
        for entry in entries:
            target = entry.path
            try:
                if entry.is_symlink():
                    os.unlink(target)
                elif entry.is_dir(follow_symlinks=False):
                    remove(target)
                    os.rmdir(target)
                else:
                    os.unlink(target)
            except OSError as exc:
                failures.append("%s (%s)" % (target, exc.strerror or exc))

    remove(root)
    try:
        os.rmdir(root)
    except OSError as exc:
        failures.append("%s (%s)" % (root, exc.strerror or exc))
    return failures


def forget_sidecars(jobs_dir, name):
    for suffix in (".stop", ".cancel", ".lease"):
        path = os.path.join(jobs_dir, name + suffix)
        if os.path.lexists(path):
            try:
                os.unlink(path)
            except OSError:
                pass


def current_job_id(data_dir):
    """The job the controller last claimed, as the plain string it writes."""
    try:
        with open(os.path.join(os.path.abspath(data_dir), "current-job"), "r", encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return ""


def job_is_live(name, data_dir, keep):
    """Work this plugin must not delete: a live helper, the claimed job, a kept one."""
    return name in keep or name == current_job_id(data_dir) or job_process_running(name)


def forget_last_recording(data_dir, removed_prefix):
    """Drop the playback pointer once the recording it named is gone."""
    path = os.path.join(os.path.abspath(data_dir), "last-recording")
    try:
        with open(path, "r", encoding="utf-8") as handle:
            named = handle.read().strip()
    except OSError:
        return
    if named == "" or named.startswith(removed_prefix) or not os.path.isfile(named):
        try:
            os.unlink(path)
        except OSError:
            pass


def completed_names(data_dir):
    """Owned job directories that finished with a result, newest first."""
    jobs_dir = jobs_dir_for(data_dir)
    try:
        names = os.listdir(jobs_dir)
    except OSError:
        return []
    finished = []
    for name in names:
        if not JOB_NAME.match(name):
            continue
        job_dir = os.path.join(jobs_dir, name)
        if os.path.islink(job_dir) or not os.path.isdir(job_dir):
            continue
        summary = read_json_file(os.path.join(job_dir, "summary.json"))
        if not isinstance(summary, dict) or summary.get("severity") not in COMPLETED_SEVERITIES:
            continue
        job = read_json_file(os.path.join(job_dir, "job.json")) or {}
        started = job.get("startedAt")
        finished.append((int(started) if isinstance(started, (int, float)) else 0, name))
    finished.sort(reverse=True)
    return [name for _started, name in finished]


def retention_path(data_dir):
    return os.path.join(os.path.abspath(data_dir), "retention.json")


def last_prune(data_dir):
    """The last automatic pruning, so a partial failure stays visible."""
    record = read_json_file(retention_path(data_dir))
    if not isinstance(record, dict):
        return {"removed": [], "failures": [], "at": 0}
    return {
        "removed": record.get("removed") if isinstance(record.get("removed"), list) else [],
        "failures": record.get("failures") if isinstance(record.get("failures"), list) else [],
        "at": record.get("at") if isinstance(record.get("at"), (int, float)) else 0,
    }


def referenced_recordings(data_dir, skip):
    """Real paths of recordings that jobs outside `skip` still name.

    A retry stores the dictation it retried as its own audio, so a job can point
    into another job's directory; the manual delete path already refuses to delete
    another dictation's recording for the same reason.
    """
    jobs_dir = jobs_dir_for(data_dir)
    used = set()
    try:
        names = os.listdir(jobs_dir)
    except OSError:
        return used
    for name in names:
        if name in skip or not JOB_NAME.match(name):
            continue
        job = read_json_file(os.path.join(jobs_dir, name, "job.json")) or {}
        recording = job.get("recording")
        if isinstance(recording, str) and recording != "":
            used.add(os.path.realpath(recording))
    return used


def holds_referenced_recording(job_dir, used):
    """Whether a job directory contains a recording a surviving job still needs."""
    prefix = os.path.realpath(job_dir) + os.sep
    return any(path.startswith(prefix) for path in used)


def prune_jobs(data_dir, retention, keep=None):
    """Delete finished dictations beyond the retention count.

    Called only after a successor's own result was committed. Only a finished job
    with a durable summary is a candidate, so a running, failed, interrupted or
    recoverable cancelled job is never silently removed, and a live job is
    skipped even when it is old. A candidate whose audio a surviving dictation
    still names is kept: removing it would take Play and Retry away from a
    dictation that is inside the retention window.
    """
    keep = set(keep or [])
    result = {"removed": [], "failures": []}
    retention = int(retention)
    if retention < 1:
        return result
    jobs_dir = jobs_dir_for(data_dir)
    candidates = []
    for index, name in enumerate(completed_names(data_dir)):
        if index < retention or job_is_live(name, data_dir, keep):
            continue
        candidates.append(name)
    used = referenced_recordings(data_dir, set(candidates))
    for name in candidates:
        job_dir, problem = owned_job_dir(data_dir, name)
        if problem:
            result["failures"].append("%s (%s)" % (name, problem))
            continue
        if holds_referenced_recording(job_dir, used):
            continue
        failures = remove_owned_job(job_dir)
        forget_sidecars(jobs_dir, name)
        if failures:
            result["failures"].extend(failures)
            continue
        forget_last_recording(data_dir, job_dir + os.sep)
        result["removed"].append(name)
    if result["removed"] or result["failures"]:
        atomic_write(
            retention_path(data_dir),
            json.dumps({"at": int(time.time()), "removed": result["removed"], "failures": result["failures"][:20]}) + "\n",
        )
    return result


def storage_summary(data_dir):
    """How much the plugin's own data occupies, and how much disk is left."""
    jobs_dir = jobs_dir_for(data_dir)
    try:
        names = os.listdir(jobs_dir)
    except OSError:
        names = []
    total, count = 0, 0
    for name in names:
        if not JOB_NAME.match(name):
            continue
        job_dir = os.path.join(jobs_dir, name)
        if os.path.islink(job_dir) or not os.path.isdir(job_dir):
            continue
        total += tree_size(job_dir)
        count += 1
    try:
        free = shutil.disk_usage(os.path.abspath(data_dir)).free
    except OSError:
        free = None
    return {"jobsBytes": total, "jobsCount": count, "freeBytes": free}


def owned_recording(data_dir, job_id):
    """The one recording file this job owns, or (None, reason)."""
    job_dir, problem = owned_job_dir(data_dir, job_id)
    if problem:
        return None, problem
    job = read_json_file(os.path.join(job_dir, "job.json")) or {}
    candidate = job.get("recording")
    if not isinstance(candidate, str) or candidate == "":
        return None, "This dictation has no recording the plugin owns: the audio is the file you imported, so it was left alone."
    if os.path.basename(candidate) != "recording.wav":
        return None, "This dictation's recording is not a file the plugin owns, so it was left alone."
    # A retry reads an earlier dictation's recording, so the file has to be in
    # this job's own directory before this job may delete it.
    if os.path.islink(candidate) or os.path.realpath(os.path.dirname(candidate)) != os.path.realpath(job_dir):
        return None, "This dictation's recording belongs to another dictation, so it was left alone."
    if not os.path.isfile(candidate):
        return None, "That dictation has no saved recording to delete."
    return candidate, None


def remove_owned_job(job_dir):
    """Remove one owned job directory, keeping its record if anything survived.

    A partial removal that also deleted job.json would drop the dictation from the
    history while its files were still on disk, and the user could neither see nor
    retry it. The record is rewritten on failure so the row stays where it was.
    """
    job_file = os.path.join(job_dir, "job.json")
    try:
        with open(job_file, "rb") as handle:
            job_bytes = handle.read()
    except OSError:
        job_bytes = None
    failures = remove_tree(job_dir)
    if failures and job_bytes is not None:
        try:
            os.makedirs(job_dir, mode=0o700, exist_ok=True)
            with private_open(job_file) as handle:
                handle.write(job_bytes)
        except OSError:
            pass
    return failures


def command_delete(args):
    """Delete one plugin-owned recording, or one whole plugin-owned dictation."""
    global SUMMARY_PATH
    args.data_dir = os.path.abspath(args.data_dir)
    SUMMARY_PATH = None
    job_id = args.job_id
    job_dir, problem = owned_job_dir(args.data_dir, job_id)
    if problem:
        verdict("not_owned", "error", problem, jobId=job_id)
        return
    if job_is_live(job_id, args.data_dir, set()):
        verdict(
            "job_active",
            "error",
            "That dictation is still running, so nothing was deleted. Cancel it first.",
            jobId=job_id,
        )
        return
    if args.what == "recording":
        recording, recording_problem = owned_recording(args.data_dir, job_id)
        if recording_problem:
            verdict("not_owned", "error", recording_problem, jobId=job_id)
            return
        try:
            os.unlink(recording)
        except OSError as exc:
            verdict(
                "delete_failed",
                "error",
                "Could not delete the recording: %s. It is still on disk." % (exc.strerror or exc),
                jobId=job_id,
                failures=[recording],
            )
            return
        forget_last_recording(args.data_dir, job_dir + os.sep)
        verdict(
            "ok",
            "ok",
            "Deleted the recording. The transcript and its attempts were kept; playback and Retry are no longer offered.",
            jobId=job_id,
        )
        return
    failures = remove_owned_job(job_dir)
    forget_sidecars(jobs_dir_for(args.data_dir), job_id)
    if failures:
        verdict(
            "delete_partial",
            "error",
            "Deleted part of the dictation, but these files could not be removed: " + "; ".join(failures[:5]),
            jobId=job_id,
            failures=failures[:20],
        )
        return
    forget_last_recording(args.data_dir, job_dir + os.sep)
    verdict("ok", "ok", "Deleted the dictation, including its recording, transcript and attempts.", jobId=job_id)


def command_clear(args):
    """Delete every plugin-owned dictation except work that is still live."""
    global SUMMARY_PATH
    args.data_dir = os.path.abspath(args.data_dir)
    SUMMARY_PATH = None
    jobs_dir = jobs_dir_for(args.data_dir)
    keep = set(name for name in (args.keep or []) if isinstance(name, str) and name != "")
    try:
        names = sorted(os.listdir(jobs_dir))
    except OSError:
        names = []
    removed, kept, held, failures = [], [], [], []
    doomed = []
    for name in names:
        if not JOB_NAME.match(name):
            continue
        job_dir = os.path.join(jobs_dir, name)
        if os.path.islink(job_dir) or not os.path.isdir(job_dir):
            continue
        if job_is_live(name, args.data_dir, keep):
            kept.append(name)
            continue
        owned, problem = owned_job_dir(args.data_dir, name)
        if problem:
            failures.append("%s (%s)" % (name, problem))
            continue
        doomed.append((name, owned))
    # A dictation that survives this clear — the job that is still running, for
    # instance — keeps needing the recording it names, even when that recording
    # lives in a job this clear would otherwise remove.
    used = referenced_recordings(args.data_dir, set(name for name, _owned in doomed))
    for name, owned in doomed:
        if holds_referenced_recording(owned, used):
            held.append(name)
            continue
        job_failures = remove_owned_job(owned)
        forget_sidecars(jobs_dir, name)
        if job_failures:
            failures.extend(job_failures)
            continue
        forget_last_recording(args.data_dir, owned + os.sep)
        removed.append(name)
    message = "Deleted %d dictation%s." % (len(removed), "" if len(removed) == 1 else "s")
    if kept:
        message += " %d still running %s kept: %s." % (
            len(kept),
            "job was" if len(kept) == 1 else "jobs were",
            ", ".join(kept),
        )
    if held:
        message += " Kept for dictations that still use it: %s." % ", ".join(held)
    if failures:
        message += " Some files could not be removed: " + "; ".join(failures[:5])
    if removed:
        # The previous pruning report was about jobs this clear just removed, so a
        # stale failure line must not outlive them in the panel.
        try:
            os.unlink(retention_path(args.data_dir))
        except OSError:
            pass
    verdict(
        "clear_partial" if failures else "cleared",
        "error" if failures else "ok",
        message,
        removed=removed,
        kept=kept,
        held=held,
        failures=failures[:20],
    )


def diagnostic_message(summary):
    """This plugin's own words about a job, never the engine's output.

    The engine's output is where recognised speech and the user's file paths
    appear, and a diagnostics file is exported rather than read on screen, so it
    is dropped. A job written before the separate field existed carries the
    engine's half inside its message, so an error-severity job is reported
    without one rather than guessing where its text ends.
    """
    if not isinstance(summary, dict):
        return ""
    brief = summary.get("diagnosticMessage")
    if not isinstance(brief, str):
        if summary.get("severity") == "error":
            return ""
        brief = summary.get("message") if isinstance(summary.get("message"), str) else ""
    return brief.split(ENGINE_NOTE_MARK, 1)[0].strip()[:DIAGNOSTIC_MESSAGE_CHARS]


def diagnostics_document(data_dir, retention):
    """Bounded metadata about this plugin's jobs. No audio, no transcript text.

    The raw recognition log is where recognised speech and user paths would leak,
    so it is summarised as counts and sizes, never copied. Only the plugin's own
    outcome messages are included verbatim.
    """
    jobs_dir = jobs_dir_for(data_dir)
    try:
        names = sorted(os.listdir(jobs_dir))
    except OSError:
        names = []
    jobs = []
    for name in names:
        if not JOB_NAME.match(name):
            continue
        job_dir = os.path.join(jobs_dir, name)
        if os.path.islink(job_dir) or not os.path.isdir(job_dir):
            continue
        job = read_json_file(os.path.join(job_dir, "job.json")) or {}
        summary = read_json_file(os.path.join(job_dir, "summary.json"))
        attempt_dir, attempts = latest_attempt(job_dir)
        chars = 0
        if attempt_dir:
            candidate = os.path.join(attempt_dir, "transcript.txt")
            try:
                if os.path.isfile(candidate) and not os.path.islink(candidate):
                    with open(candidate, "r", encoding="utf-8", errors="replace") as handle:
                        chars = len(handle.read())
            except OSError:
                chars = 0
        recording = job.get("recording")
        recording_bytes = None
        if isinstance(recording, str) and os.path.isfile(recording) and not os.path.islink(recording):
            try:
                recording_bytes = os.stat(recording, follow_symlinks=False).st_size
            except OSError:
                recording_bytes = None
        jobs.append(
            {
                "id": name,
                "mode": job.get("mode") if isinstance(job.get("mode"), str) else "",
                "startedAtMs": job.get("startedAt") if isinstance(job.get("startedAt"), (int, float)) else 0,
                "state": "complete" if isinstance(summary, dict) else "interrupted",
                "outcome": summary.get("outcome") if isinstance(summary, dict) and isinstance(summary.get("outcome"), str) else "",
                "severity": summary.get("severity") if isinstance(summary, dict) and isinstance(summary.get("severity"), str) else "",
                "message": diagnostic_message(summary),
                "attempts": attempts,
                "transcriptChars": chars,
                "recordingBytes": recording_bytes,
            }
        )
    jobs.sort(key=lambda entry: entry["startedAtMs"], reverse=True)
    return {
        "format": DIAGNOSTIC_FORMAT,
        "version": DIAGNOSTIC_VERSION,
        "generatedAt": int(time.time()),
        "plugin": {"id": "magus/dictation", "historyLimit": HISTORY_LIMIT},
        "storage": storage_summary(data_dir),
        "retention": {"count": int(retention), "last": last_prune(data_dir)},
        "jobs": jobs,
        "excluded": [
            "audio recordings",
            "transcripts and transcript previews",
            "raw recognition logs",
            "engine logs",
            "setup file paths",
            "environment variables",
        ],
    }


def command_diagnostics(args):
    """Write the exact bytes the preview shows, so exporting them is faithful."""
    global SUMMARY_PATH
    args.data_dir = os.path.abspath(args.data_dir)
    SUMMARY_PATH = None
    document = diagnostics_document(args.data_dir, args.retention)
    text = json.dumps(document, indent=2) + "\n"
    path = os.path.join(private_dir(args.data_dir), DIAGNOSTIC_PREVIEW_NAME)
    try:
        atomic_write(path, text)
    except OSError as exc:
        verdict("diagnostics_failed", "error", "Could not write the diagnostics preview: %s" % (exc.strerror or exc))
        return
    verdict(
        "ok",
        "ok",
        "Prepared diagnostics for review. Nothing was exported and nothing left this machine.",
        previewPath=path,
        previewBytes=len(text.encode("utf-8")),
        sha256=hashlib.sha256(text.encode("utf-8")).hexdigest(),
        jobs=len(document["jobs"]),
    )


def export_destination(name):
    home = os.environ.get("HOME", "")
    if home == "":
        return None, "HOME is not set, so there is no place to export to."
    downloads = os.path.join(home, "Downloads")
    directory = downloads if os.path.isdir(downloads) else home
    candidate = os.path.join(directory, name)
    stem, extension = os.path.splitext(name)
    for index in range(2, 100):
        if not os.path.exists(candidate):
            return candidate, None
        candidate = os.path.join(directory, "%s-%d%s" % (stem, index, extension))
    return None, "Could not find an unused export name."


def write_export(destination, content):
    """Write an export atomically with user-only permissions.

    The destination directory is created when missing but never chmod'ed, so an
    export into a directory the user already had cannot change its permissions.
    """
    os.makedirs(os.path.dirname(os.path.abspath(destination)), mode=0o700, exist_ok=True)
    temporary = destination + ".tmp"
    handle = os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "wb")
    with handle:
        handle.write(content)
    os.replace(temporary, destination)
    return destination


def command_export_diagnostics(args):
    """Copy the preview the user reviewed, byte for byte, to a file they own."""
    global SUMMARY_PATH
    args.data_dir = os.path.abspath(args.data_dir)
    SUMMARY_PATH = None
    preview_path = os.path.join(args.data_dir, DIAGNOSTIC_PREVIEW_NAME)
    try:
        with open(preview_path, "rb") as handle:
            content = handle.read()
    except OSError:
        verdict("no_preview", "error", "Preview the diagnostics first, then export that exact content.")
        return
    digest = hashlib.sha256(content).hexdigest()
    if args.expect_hash != "" and args.expect_hash != digest:
        verdict(
            "preview_changed",
            "error",
            "The diagnostics changed after you reviewed them. Open them again and export that text.",
        )
        return
    destination = args.out
    if destination == "":
        destination, problem = export_destination("%s-diagnostics-%s.json" % (EXPORT_PREFIX, time.strftime("%Y%m%d-%H%M%S")))
        if problem:
            verdict("export_failed", "error", problem)
            return
    try:
        write_export(destination, content)
    except OSError as exc:
        verdict("export_failed", "error", "Could not write the diagnostics export: %s" % (exc.strerror or exc))
        return
    verdict(
        "ok",
        "ok",
        "Exported the exact diagnostics you previewed. It contains no audio and no transcripts.",
        exportPath=destination,
        bytes=len(content),
        sha256=digest,
    )


def owned_transcript(data_dir, path):
    """A transcript this plugin wrote, or (None, reason)."""
    if not isinstance(path, str) or path == "":
        return None, "There is no transcript to export."
    if os.path.islink(path):
        return None, "That transcript path is a link, so it was not read."
    real = os.path.realpath(path)
    attempt_dir = os.path.dirname(real)
    job_dir = os.path.dirname(attempt_dir)
    if os.path.dirname(job_dir) != os.path.realpath(jobs_dir_for(data_dir)):
        return None, "That transcript is not one this plugin owns, so it was not exported."
    if not JOB_NAME.match(os.path.basename(job_dir)) or not re.fullmatch(r"attempt-\d+", os.path.basename(attempt_dir)):
        return None, "That transcript is not one this plugin owns, so it was not exported."
    if os.path.basename(real) != "transcript.txt" or not os.path.isfile(real):
        return None, "That file is not a saved transcript, so it was not exported."
    return real, None


def command_export_text(args):
    """Export one saved transcript as a text file. Nothing is pasted."""
    global SUMMARY_PATH
    args.data_dir = os.path.abspath(args.data_dir)
    SUMMARY_PATH = None
    transcript, problem = owned_transcript(args.data_dir, args.transcript)
    if problem:
        verdict("not_owned", "error", problem)
        return
    try:
        with open(transcript, "rb") as handle:
            content = handle.read()
    except OSError as exc:
        verdict("export_failed", "error", "Could not read the transcript: %s" % (exc.strerror or exc))
        return
    destination = args.out
    if destination == "":
        job_name = os.path.basename(os.path.dirname(os.path.dirname(transcript)))
        attempt_name = os.path.basename(os.path.dirname(transcript))
        destination, problem = export_destination("%s-%s-%s.txt" % (EXPORT_PREFIX, job_name, attempt_name))
        if problem:
            verdict("export_failed", "error", problem)
            return
    try:
        write_export(destination, content)
    except OSError as exc:
        verdict("export_failed", "error", "Could not write the transcript export: %s" % (exc.strerror or exc))
        return
    verdict(
        "ok",
        "ok",
        "Exported the transcript to %s. Nothing was pasted." % destination,
        exportPath=destination,
        bytes=len(content),
        sha256=hashlib.sha256(content).hexdigest(),
    )


def command_sources(args):
    """List the capture sources the user can choose from."""
    global SUMMARY_PATH
    args.data_dir = os.path.abspath(args.data_dir)
    data_dir = private_dir(args.data_dir)
    SUMMARY_PATH = os.path.join(data_dir, "sources.json")
    sources, problem = pw_dump_sources()
    if problem:
        verdict("sources_unavailable", "error", problem)
        return
    if not sources:
        verdict("no_sources", "error", "PipeWire reports no capture sources. Connect a microphone and refresh.")
        return
    verdict(
        "ok",
        "ok",
        "Found %d capture source%s." % (len(sources), "" if len(sources) == 1 else "s"),
        sources=sources,
        capturedAt=int(time.time()),
    )


# ── Process ownership ────────────────────────────────────────────────────────

def child_preexec(nice_value):
    """Runs in a forked child, before it execs.

    A helper that is killed outright cannot stop its children, and the plugin
    keeps a job owned while any process for it is alive, so no child may outlive
    the helper. PR_SET_PDEATHSIG covers exactly that case, including SIGKILL,
    which no in-helper cleanup can.
    """
    if nice_value is not None:
        try:
            os.nice(nice_value)
        except OSError:
            pass
    try:
        # The recorder writes its own WAV, so give it a private umask too.
        os.umask(0o077)
    except OSError:
        pass
    try:
        libc = ctypes.CDLL("libc.so.6", use_errno=True)
        parent = os.getppid()
        libc.prctl(PR_SET_PDEATHSIG, signal.SIGKILL)
        # The parent can die between the fork and that call; re-check the race.
        if os.getppid() != parent:
            os.kill(os.getpid(), signal.SIGKILL)
    except Exception:
        # Not Linux, or no libc to call: the watchdog still stops the engine.
        pass


def engine_preexec():
    child_preexec(NICE)


def recorder_preexec():
    child_preexec(None)


def group_signal(proc, number):
    """Signal the process group of a child this helper started itself."""
    try:
        os.killpg(os.getpgid(proc.pid), number)
        return True
    except (ProcessLookupError, OSError):
        return False


def stop_recorder(proc, grace=STOP_GRACE_SECONDS):
    """Ask one recorder to finish with SIGINT, then kill that same process."""
    try:
        proc.send_signal(signal.SIGINT)
    except (ProcessLookupError, OSError):
        pass
    try:
        proc.wait(timeout=grace)
        return
    except subprocess.TimeoutExpired:
        pass
    group_signal(proc, signal.SIGKILL)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def cancel_recorder(proc, grace=CANCEL_GRACE_SECONDS):
    """Cancel and controller loss: group SIGTERM, then group SIGKILL after a grace."""
    group_signal(proc, signal.SIGTERM)
    try:
        proc.wait(timeout=grace)
        return
    except subprocess.TimeoutExpired:
        pass
    group_signal(proc, signal.SIGKILL)
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def terminate(proc):
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def lease_stale(path, limit):
    """True when the controller has stopped refreshing its claim on this job.

    A missing or unreadable lease counts as stale: the plugin writes the lease
    before it launches the helper, so no lease means no live controller.
    """
    try:
        with open(path, "rb") as handle:
            record = json.loads(handle.read().decode("utf-8", "replace"))
    except (OSError, ValueError):
        return True
    stamp = record.get("ts") if isinstance(record, dict) else None
    if not isinstance(stamp, (int, float)):
        return True
    return (time.time() - stamp) > limit


# ── Commands ─────────────────────────────────────────────────────────────────

def command_probe(args):
    """Explicit setup: verify the engine, hash the engine and model, record them."""
    global SUMMARY_PATH
    engine, model = os.path.abspath(args.engine), os.path.abspath(args.model)
    args.engine, args.model = engine, model
    args.data_dir = os.path.abspath(args.data_dir)
    SUMMARY_PATH = os.path.join(private_dir(args.data_dir), "setup-summary.json")
    problems = []
    if not os.path.isfile(engine):
        problems.append("the recognition engine is not an existing file")
    elif not os.access(engine, os.X_OK):
        problems.append("the recognition engine is not executable")
    if not os.path.isfile(model):
        problems.append("the Model GGUF is not an existing file")
    if problems:
        verdict("setup_required", "error", "Setup required: " + "; ".join(problems) + ".")
        return
    missing, failure = probe_flags(engine)
    if failure:
        verdict("engine_unavailable", "error", "Setup required: the recognition engine could not be run: %s." % failure)
        return
    if missing:
        verdict(
            "engine_incompatible",
            "error",
            "Setup required: the engine does not support %s." % ", ".join(missing),
            missingFlags=missing,
        )
        return
    record = {
        "recordedAt": int(time.time()),
        "engine": dict(file_facts(engine), sha256=sha256_file(engine)),
        "model": dict(file_facts(model), sha256=sha256_file(model)),
        "requiredFlags": list(REQUIRED_FLAGS),
    }
    setup_path = os.path.join(private_dir(args.data_dir), "setup.json")
    private_write(setup_path, json.dumps(record, indent=2) + "\n")
    verdict(
        "ok",
        "ok",
        "Setup verified and recorded.",
        setupPath=setup_path,
        engineSha256=record["engine"]["sha256"],
        modelSha256=record["model"]["sha256"],
    )


def command_run(args):
    global SUMMARY_PATH
    # The engine runs with the attempt directory as its working directory, so a
    # relative engine, model or recording path would resolve against the wrong base.
    args.engine = os.path.abspath(args.engine)
    args.model = os.path.abspath(args.model)
    if args.wav != "":
        args.wav = os.path.abspath(args.wav)
    args.data_dir = os.path.abspath(args.data_dir)
    jobs_dir = private_dir(os.path.join(args.data_dir, "jobs"))
    job_dir = private_dir(os.path.join(jobs_dir, safe_id(args.job_id)))
    SUMMARY_PATH = os.path.join(job_dir, "summary.json")
    # The plugin watches this file, so a helper that dies is noticed in seconds
    # instead of waiting out the inference stall guard.
    heartbeat_path = os.path.join(job_dir, "heartbeat.json")
    write_heartbeat(heartbeat_path)
    write_job_record(
        job_dir,
        {
            "jobId": args.job_id,
            "mode": "import",
            "engine": args.engine,
            "model": args.model,
            "threads": args.threads,
            "startedAt": int(time.time() * 1000),
            "wav": args.wav,
            "retriesOf": args.retries_of,
        },
    )
    if args.threads < 1 or args.threads > 64:
        verdict("invalid_threads", "error", "Setup required: the inference thread count must be between 1 and 64.")
        return
    problem = engine_problem(args.engine, args.model)
    if problem:
        verdict(problem["outcome"], "error", problem["message"], **problem.get("extra", {}))
        return
    wav_problem = validate_wav(args.wav)
    if wav_problem:
        verdict("invalid_wav", "error", wav_problem, wav=args.wav)
        return
    # The imported file is this job's recording too, so the panel can play it back
    # and retry it without the user choosing it again.
    transcribe(args, heartbeat_path, recording=args.wav)


def command_play(args):
    """Play a saved recording on the local output.

    Playback runs here, not in Noctalia, so the process belongs to this helper:
    it is bounded by a timeout and it carries the same parent-death signal as the
    recorder. Nothing is pasted and no clipboard is touched.
    """
    wav = os.path.abspath(args.wav)
    if not os.path.isfile(wav):
        verdict("missing_recording", "error", "There is no saved recording to play.")
        return
    try:
        proc = subprocess.Popen(
            ["pw-play", wav],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            preexec_fn=recorder_preexec,
        )
    except OSError as exc:
        verdict("playback_unavailable", "error", "Could not start pw-play: %s." % exc)
        return
    try:
        _, stderr = proc.communicate(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        terminate(proc)
        verdict("playback_timeout", "error", "Playback exceeded the limit and was stopped.")
        return
    if proc.returncode != 0:
        detail = " ".join(stderr.decode("utf-8", "replace").split())[:200]
        verdict(
            "playback_failed",
            "error",
            "pw-play exited with status %d.%s" % (proc.returncode, (" " + detail) if detail else ""),
        )
        return
    verdict("ok", "ok", "Played the saved recording. Nothing was pasted.")


def command_record(args):
    """Record one job: capture, finalize, validate, then transcribe.

    Every step is owned by this process. Stop signals only the recorder this
    helper started, cancel and controller loss stop only that recorder's own
    process group, and the captured audio is preserved before any inference.
    """
    global SUMMARY_PATH
    args.engine = os.path.abspath(args.engine)
    args.model = os.path.abspath(args.model)
    args.data_dir = os.path.abspath(args.data_dir)
    job_name = safe_id(args.job_id)
    jobs_dir = private_dir(os.path.join(args.data_dir, "jobs"))
    job_dir = private_dir(os.path.join(jobs_dir, job_name))
    SUMMARY_PATH = os.path.join(job_dir, "summary.json")
    heartbeat_path = os.path.join(job_dir, "heartbeat.json")
    recording = os.path.join(job_dir, "recording.wav")
    stop_file = os.path.join(jobs_dir, job_name + ".stop")
    cancel_file = os.path.join(jobs_dir, job_name + ".cancel")
    lease_file = os.path.join(jobs_dir, job_name + ".lease")
    job = {
        "jobId": args.job_id,
        "mode": "record",
        "source": args.source,
        "engine": args.engine,
        "model": args.model,
        "threads": args.threads,
        "startedAt": int(time.time() * 1000),
        "recording": recording,
    }
    write_job_record(job_dir, job)
    write_heartbeat(heartbeat_path)
    write_status(job_dir, job, "starting", "Preparing the microphone.")
    recording_paths = {"jobDir": job_dir, "recording": recording}

    if args.threads < 1 or args.threads > 64:
        verdict("invalid_threads", "error", "Setup required: the inference thread count must be between 1 and 64.", jobId=args.job_id)
        return
    problem = engine_problem(args.engine, args.model)
    if problem:
        verdict(problem["outcome"], "error", problem["message"], jobId=args.job_id, **problem.get("extra", {}))
        return
    sources, source_problem = pw_dump_sources()
    if source_problem:
        verdict("sources_unavailable", "error", "Could not check the selected microphone: " + source_problem, jobId=args.job_id)
        return
    if not any(source["id"] == args.source for source in sources):
        verdict(
            "source_missing",
            "error",
            "The selected microphone is not available: %s. Connect it and choose it in the panel; no other source is used."
            % args.source,
            jobId=args.job_id,
            availableSources=[source["id"] for source in sources],
        )
        return

    # The controller allocates the job id fresh and never reuses one, so a request
    # written for this job id is this job's own request however early it arrives:
    # it is never discarded as a leftover from an earlier job. The controller
    # accepts Stop and Cancel as soon as it has launched this helper, so a request
    # can exist before this function, or this process, has started; the microphone
    # is not opened for a recording its owner has already ended.
    if os.path.exists(cancel_file):
        try:
            os.remove(cancel_file)
        except OSError:
            pass
        verdict(
            "cancelled",
            "cancelled",
            "Cancelled before the microphone was opened, so no audio was captured.",
            jobId=args.job_id,
            attempt=0,
            paths=recording_paths,
            source=args.source,
        )
        return
    if os.path.exists(stop_file):
        try:
            os.remove(stop_file)
        except OSError:
            pass
        verdict(
            "invalid_recording",
            "error",
            "The recording was stopped before the microphone was opened, so no audio was captured.",
            jobId=args.job_id,
            attempt=0,
            paths=recording_paths,
            source=args.source,
        )
        return
    argv = [
        "pw-record",
        "--target", args.source,
        "--rate", str(RECORD_RATE),
        "--channels", str(RECORD_CHANNELS),
        "--format", RECORD_FORMAT,
        recording,
    ]
    recorder_log = os.path.join(job_dir, "recorder.log")
    try:
        with private_open(recorder_log) as log:
            recorder = subprocess.Popen(
                argv,
                stdout=log,
                stderr=log,
                cwd=job_dir,
                env=dict(os.environ),
                preexec_fn=recorder_preexec,
                start_new_session=True,
            )
    except OSError as exc:
        verdict("recorder_unavailable", "error", "Could not start pw-record: %s." % exc, jobId=args.job_id)
        return
    write_status(job_dir, job, "recording", "Recording from the selected microphone.")
    write_heartbeat(heartbeat_path)

    override = None  # (outcome, severity, message)
    stop_requested = False
    recorder_code = None
    last_beat = time.monotonic()
    while True:
        code = recorder.poll()
        if code is not None:
            recorder_code = code
            break
        if os.path.exists(cancel_file):
            override = ("cancelled", "cancelled", "Cancelled while recording. The captured audio was preserved.")
            break
        if os.path.exists(stop_file):
            stop_requested = True
            break
        if lease_stale(lease_file, args.lease_seconds):
            override = (
                "interrupted",
                "error",
                "Noctalia stopped claiming the recording, so the microphone was released. The captured audio was preserved.",
            )
            break
        now = time.monotonic()
        if now - last_beat >= HEARTBEAT_SECONDS:
            last_beat = now
            write_heartbeat(heartbeat_path)
        time.sleep(0.25)

    # The request files never outlive the job that owns them.
    for path in (stop_file, cancel_file):
        if os.path.exists(path):
            try:
                os.remove(path)
            except OSError:
                pass
    if os.path.exists(recording):
        try:
            os.chmod(recording, 0o600)
        except OSError:
            pass

    if override:
        write_status(job_dir, job, "finalizing", "Stopping the recorder.")
        cancel_recorder(recorder)
        problem = validate_wav(recording)
        verdict(
            override[0],
            override[1],
            override[2],
            jobId=args.job_id,
            attempt=0,
            usableAudio=problem is None,
            paths=recording_paths,
            source=args.source,
        )
        return

    if stop_requested:
        write_status(job_dir, job, "finalizing", "Stopping the recorder and finalizing the WAV.")
        stop_recorder(recorder)
        # The stop is not the last word: a cancel that arrives while the WAV is
        # being finalized wins, so an accepted cancel is never silently dropped.
        if os.path.exists(cancel_file):
            try:
                os.remove(cancel_file)
            except OSError:
                pass
            problem = validate_wav(recording)
            verdict(
                "cancelled",
                "cancelled",
                "Cancelled while the recording was being finalized. The captured audio was preserved.",
                jobId=args.job_id,
                attempt=0,
                usableAudio=problem is None,
                paths=recording_paths,
                source=args.source,
            )
            return
        problem = validate_wav(recording)
        if problem:
            verdict(
                "invalid_recording",
                "error",
                "The microphone did not produce usable audio: %s" % problem,
                jobId=args.job_id,
                attempt=0,
                paths=recording_paths,
                source=args.source,
            )
            return
        args.wav = recording
        transcribe(args, heartbeat_path, status_dir=job_dir, status_job=job, recording=recording)
        return

    write_status(job_dir, job, "finalizing", "The recorder stopped on its own.")
    try:
        recorder.wait(timeout=5)
    except subprocess.TimeoutExpired:
        cancel_recorder(recorder)
    detail = log_tail(recorder_log)
    verdict(
        "recorder_failed",
        "error",
        "pw-record stopped before the recording was finished (status %s).%s The captured audio was preserved."
        % (recorder_code, (" " + detail) if detail else ""),
        jobId=args.job_id,
        attempt=0,
        paths=recording_paths,
        source=args.source,
    )


def transcribe(args, heartbeat_path, status_dir=None, status_job=None, recording=None):
    private_dir(args.data_dir)
    jobs_dir = private_dir(os.path.join(args.data_dir, "jobs"))
    job_name = safe_id(args.job_id)
    job_dir = private_dir(os.path.join(jobs_dir, job_name))
    cancel_file = os.path.join(jobs_dir, job_name + ".cancel")
    record_path = recording if recording is not None else (args.wav if os.path.isabs(args.wav) else "")
    if os.path.exists(cancel_file):
        # A cancel that arrived before any work started is honoured, not discarded.
        os.remove(cancel_file)
        verdict("cancelled", "cancelled", "Cancelled before the engine started.", jobId=args.job_id, attempt=0, paths={"jobDir": job_dir, "recording": record_path})
        return
    attempt = 1
    while os.path.isdir(os.path.join(job_dir, "attempt-%d" % attempt)):
        attempt += 1
    attempt_dir = private_dir(os.path.join(job_dir, "attempt-%d" % attempt))

    if status_dir and status_job:
        write_status(status_dir, status_job, "transcribing", "Transcribing the recording.")

    wav = os.path.abspath(args.wav)
    input_list = os.path.join(attempt_dir, "input-list.txt")
    private_write(input_list, wav + "\n")

    argv = [
        args.engine,
        "--backend", "cpu",
        "--threads", str(args.threads),
        "--timestamps", "none",
        "-m", args.model,
        "--batch", input_list,
        "--batch-size", "1",
        "--batch-jsonl",
    ]
    env_threads = str(args.threads)
    env = dict(os.environ, OMP_NUM_THREADS=env_threads, OPENBLAS_NUM_THREADS=env_threads)
    raw_path = os.path.join(attempt_dir, "engine.jsonl")
    log_path = os.path.join(attempt_dir, "engine.log")
    transcript_path = os.path.join(attempt_dir, "transcript.txt")
    result_path = os.path.join(attempt_dir, "result.json")
    private_write(
        os.path.join(attempt_dir, "argv.json"),
        json.dumps(
            {
                "argv": argv,
                "env": {"OMP_NUM_THREADS": env_threads, "OPENBLAS_NUM_THREADS": env_threads},
                "nice": NICE,
            },
            indent=2,
        ) + "\n",
    )

    started = time.time()
    killed = None
    with private_open(raw_path) as out, private_open(log_path) as err:
        try:
            proc = subprocess.Popen(
                argv,
                stdout=out,
                stderr=err,
                cwd=attempt_dir,
                env=env,
                preexec_fn=engine_preexec,
            )
        except OSError as exc:
            killed = "failed"
            exit_code = None
            failure = str(exc)
        else:
            failure = None
            deadline = time.monotonic() + args.timeout
            last_beat = time.monotonic()
            while True:
                code = proc.poll()
                if code is not None:
                    break
                if os.path.exists(cancel_file):
                    killed = "cancelled"
                    terminate(proc)
                    break
                if time.monotonic() >= deadline:
                    killed = "timeout"
                    terminate(proc)
                    break
                if time.monotonic() - last_beat >= HEARTBEAT_SECONDS:
                    write_heartbeat(heartbeat_path)
                    last_beat = time.monotonic()
                time.sleep(0.25)
            exit_code = proc.wait()
    # A cancel that raced the engine's own exit is still this job's request, so the
    # file never outlives the job.
    if os.path.exists(cancel_file):
        try:
            os.remove(cancel_file)
        except OSError:
            pass

    if killed == "failed":
        verdict("engine_unavailable", "error", "Could not start the engine: %s." % failure)
        return

    with open(raw_path, "rb") as handle:
        raw = handle.read().decode("utf-8", "replace")
    parsed = parse_jsonl(raw, wav)
    text = parsed["text"]
    private_write(transcript_path, text)

    outcome, severity, message = classify(killed, exit_code, parsed)
    # The panel shows the engine's own output on a failure, because that is what
    # explains it. The diagnostics export must not: it carries this plugin's
    # words only, so the engine's half is captured apart from it.
    diagnostic_message = message.split(ENGINE_NOTE_MARK, 1)[0].strip()
    if severity == "error":
        detail = log_tail(log_path)
        if detail:
            message = message + ENGINE_NOTE_MARK + detail
    result = {
        "jobId": args.job_id,
        "attempt": attempt,
        "outcome": outcome,
        "severity": severity,
        "message": message,
        "textChars": len(text),
        "exitCode": exit_code,
        "error": parsed["error"],
        "truncated": outcome == "truncated",
        "controlTokens": parsed["control_tokens"],
        "malformedLines": parsed["malformed_lines"],
        "melMs": parsed["mel_ms"],
        "encodeMs": parsed["encode_ms"],
        "decodeMs": parsed["decode_ms"],
        "wav": wav,
        "wavSha256": sha256_file(wav),
        "engine": args.engine,
        "model": args.model,
        "threads": args.threads,
        "startedAt": started,
        "finishedAt": time.time(),
        "paths": {
            "attemptDir": attempt_dir,
            "inputList": input_list,
            "rawJsonl": raw_path,
            "log": log_path,
            "transcript": transcript_path,
            "result": result_path,
            "recording": recording,
        },
    }
    write_result(result)
    committed = emit(
        {
            "ok": severity in ("ok", "review"),
            "outcome": outcome,
            "severity": severity,
            "message": message,
            "diagnosticMessage": diagnostic_message,
            "copyable": severity in ("ok", "review") and bool(text.strip()),
            "jobId": args.job_id,
            "attempt": attempt,
            "textChars": len(text),
            "controlTokens": parsed["control_tokens"],
            "paths": result["paths"],
        }
    )
    # Retention runs only after this job's own result is durable, so a write that
    # failed cannot delete older audio for a successor the user cannot see. A job
    # that produced no transcript is not a successor and never prunes.
    if committed and severity in COMPLETED_SEVERITIES:
        prune_jobs(args.data_dir, getattr(args, "retention", DEFAULT_RETENTION))


def write_result(result):
    private_write(result["paths"]["result"], json.dumps(result, indent=2) + "\n")


def row_problem(row):
    """The engine's result schema: a string file, and string text and error fields.

    A field of the wrong type is the engine misbehaving, not text to copy: a table
    or a number here would otherwise reach the user as a stringified structure.
    """
    if "file" not in row:
        return "the row has no file field"
    if not isinstance(row["file"], str):
        return "the file field is not a string"
    for field in ("text", "error"):
        if field in row and row[field] is not None and not isinstance(row[field], str):
            return "the %s field is not a string" % field
    return None


def parse_jsonl(raw, wav):
    malformed = []
    rows = []
    for number, line in enumerate(raw.splitlines(), 1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except ValueError:
            malformed.append((number, "the line is not valid JSON"))
            continue
        if not isinstance(row, dict):
            malformed.append((number, "the line is not a JSON object"))
            continue
        if row.get("type") == "batch_header":
            continue
        problem = row_problem(row)
        if problem:
            malformed.append((number, problem))
            continue
        rows.append(row)
    result = next(
        (row for row in rows if os.path.abspath(str(row.get("file", ""))) == wav),
        None,
    )
    text = str(result.get("text") or "") if result else ""
    error = str(result.get("error") or "") if result else ""
    return {
        "row": result,
        "text": text,
        "error": error,
        "control_tokens": CONTROL_TOKEN.findall(text),
        "malformed_lines": malformed,
        "mel_ms": result.get("mel_ms") if result else None,
        "encode_ms": result.get("encode_ms") if result else None,
        "decode_ms": result.get("decode_ms") if result else None,
    }


def classify(killed, exit_code, parsed):
    if killed == "cancelled":
        return "cancelled", "cancelled", "Cancelled before the engine finished."
    if killed == "timeout":
        return "timeout", "error", "Inference exceeded the 30-minute limit and was stopped."
    if parsed["malformed_lines"]:
        line, reason = parsed["malformed_lines"][0]
        return (
            "malformed_row",
            "error",
            "The engine emitted a result row the plugin cannot trust: %s (line %d)."
            % (reason, line),
        )
    row = parsed["row"]
    if row is None:
        if exit_code != 0:
            return "nonzero_exit", "error", "The engine exited with status %d before producing a result." % exit_code
        return "missing_result", "error", "The engine produced no result row for the imported recording."
    if parsed["error"] and TRUNCATION_MARK in parsed["error"].lower():
        return "truncated", "review", "The engine hit its output budget; the transcript is incomplete."
    if parsed["error"]:
        # The engine's own row text is not this plugin's words, and transcribe appends
        # the engine's log tail to whatever this returns, so the detail stays in the
        # result file instead of being named here twice.
        return "per_file_error", "error", "The engine reported an error for this recording."
    if not parsed["text"].strip():
        return "empty", "error", "The engine returned no text for this recording."
    if exit_code != 0:
        return "nonzero_exit", "error", "The engine exited with status %d." % exit_code
    if parsed["control_tokens"]:
        return (
            "unknown_token",
            "review",
            "The transcript contains control tokens the plugin does not understand: %s."
            % ", ".join(parsed["control_tokens"]),
        )
    return "ok", "ok", "Transcription complete."


def main(argv):
    parser = argparse.ArgumentParser(prog="dictation-helper.py")
    sub = parser.add_subparsers(dest="command", required=True)

    probe = sub.add_parser("probe")
    probe.add_argument("--engine", required=True)
    probe.add_argument("--model", required=True)
    probe.add_argument("--data-dir", required=True)

    sources = sub.add_parser("sources")
    sources.add_argument("--data-dir", required=True)

    run = sub.add_parser("run")
    run.add_argument("--engine", required=True)
    run.add_argument("--model", required=True)
    run.add_argument("--threads", type=int, required=True)
    run.add_argument("--wav", required=True)
    run.add_argument("--job-id", required=True)
    run.add_argument("--data-dir", required=True)
    run.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    # How many finished dictations stay on disk after this one is committed.
    run.add_argument("--retention", type=int, default=DEFAULT_RETENTION)
    # The job a retry reads from, so the new attempt names the dictation it
    # retried instead of looking like an unrelated file the user picked.
    run.add_argument("--retries-of", default="")

    record = sub.add_parser("record")
    record.add_argument("--engine", required=True)
    record.add_argument("--model", required=True)
    record.add_argument("--threads", type=int, required=True)
    record.add_argument("--source", required=True)
    record.add_argument("--job-id", required=True)
    record.add_argument("--data-dir", required=True)
    record.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS)
    record.add_argument("--retention", type=int, default=DEFAULT_RETENTION)
    record.add_argument("--lease-seconds", type=float, default=DEFAULT_LEASE_SECONDS)

    play = sub.add_parser("play")
    play.add_argument("--wav", required=True)
    play.add_argument("--timeout", type=float, default=DEFAULT_PLAY_TIMEOUT_SECONDS)

    history = sub.add_parser("history")
    history.add_argument("--data-dir", required=True)

    delete = sub.add_parser("delete")
    delete.add_argument("--job-id", required=True)
    delete.add_argument("--what", choices=("recording", "dictation"), required=True)
    delete.add_argument("--data-dir", required=True)

    clear = sub.add_parser("clear")
    clear.add_argument("--data-dir", required=True)
    # Repeatable: the controller names whatever job it is still working on, so a
    # clear never races a live recording.
    clear.add_argument("--keep", action="append", default=[])

    diagnostics = sub.add_parser("diagnostics")
    diagnostics.add_argument("--data-dir", required=True)
    diagnostics.add_argument("--retention", type=int, default=DEFAULT_RETENTION)

    export_diagnostics = sub.add_parser("export-diagnostics")
    export_diagnostics.add_argument("--data-dir", required=True)
    export_diagnostics.add_argument("--out", default="")
    # The reviewed preview is addressed by its own bytes: a second preview written
    # between the review and the export must not be exported instead.
    export_diagnostics.add_argument("--expect-hash", default="")

    export_text = sub.add_parser("export-text")
    export_text.add_argument("--data-dir", required=True)
    export_text.add_argument("--transcript", required=True)
    export_text.add_argument("--out", default="")

    args = parser.parse_args(argv)
    if args.command == "probe":
        command_probe(args)
    elif args.command == "sources":
        command_sources(args)
    elif args.command == "history":
        command_history(args)
    elif args.command == "delete":
        command_delete(args)
    elif args.command == "clear":
        command_clear(args)
    elif args.command == "diagnostics":
        command_diagnostics(args)
    elif args.command == "export-diagnostics":
        command_export_diagnostics(args)
    elif args.command == "export-text":
        command_export_text(args)
    elif args.command == "record":
        command_record(args)
    elif args.command == "play":
        command_play(args)
    else:
        command_run(args)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as exc:  # a crash must still leave a readable outcome
        import traceback

        traceback.print_exc()
        emit(
            {
                "ok": False,
                "outcome": "internal",
                "severity": "error",
                "message": "The recognition helper failed: %s" % exc,
                "copyable": False,
            }
        )
        sys.exit(3)
