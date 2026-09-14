#!/usr/bin/env python3
"""Recognition helper for the magus/dictation Noctalia plugin.

The plugin owns the interface and the settings; this helper owns every
recognition job. It validates the imported WAV, builds the engine argv, runs
the installed transcribe-cli with CPU-only inference, thread-matched
OpenMP/OpenBLAS limits and niceness 10, enforces the 30-minute watchdog, ties
the engine's lifetime to its own so a killed helper cannot leave it running,
honours a cancel request, and persists the raw engine output, logs, transcript
and per-attempt result under the plugin data directory.

Only the Python standard library is used. The plugin never builds a shell
string: it passes a program name and an argument array here, and this helper
does the same to the engine.
"""

import argparse
import ctypes
import hashlib
import json
import os
import re
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
SAFE_ID = re.compile(r"[^A-Za-z0-9._-]")

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
    line = json.dumps(payload)
    sys.stdout.write(line + "\n")
    sys.stdout.flush()
    if not SUMMARY_PATH:
        return
    try:
        private_dir(os.path.dirname(SUMMARY_PATH))
        temporary = SUMMARY_PATH + ".tmp"
        private_write(temporary, line + "\n")
        os.replace(temporary, SUMMARY_PATH)
    except OSError:
        # The plugin keeps its own stall guard; the verdict on stdout is what matters.
        pass


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


def engine_preexec():
    """Runs in the forked engine process, before it execs.

    A helper that is killed outright cannot stop its engine, and the plugin keeps
    the job owned while any process for it is alive, so the engine must not
    outlive the helper. PR_SET_PDEATHSIG covers exactly that case, including
    SIGKILL, which no in-helper cleanup can.
    """
    os.nice(NICE)
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


def command_run(args):
    global SUMMARY_PATH
    # The engine runs with the attempt directory as its working directory, so a
    # relative engine, model or recording path would resolve against the wrong base.
    args.engine = os.path.abspath(args.engine)
    args.model = os.path.abspath(args.model)
    if args.wav != "":
        args.wav = os.path.abspath(args.wav)
    args.data_dir = os.path.abspath(args.data_dir)
    job_dir = private_dir(os.path.join(args.data_dir, "jobs", safe_id(args.job_id)))
    SUMMARY_PATH = os.path.join(job_dir, "summary.json")
    # The plugin watches this file, so a helper that dies is noticed in seconds
    # instead of waiting out the inference stall guard.
    heartbeat_path = os.path.join(job_dir, "heartbeat.json")
    write_heartbeat(heartbeat_path)
    if args.threads < 1 or args.threads > 64:
        verdict("invalid_threads", "error", "Setup required: the inference thread count must be between 1 and 64.")
        return
    if not os.path.isfile(args.engine) or not os.access(args.engine, os.X_OK):
        verdict("setup_required", "error", "Setup required: the recognition engine is missing or not executable.")
        return
    if not os.path.isfile(args.model):
        verdict("setup_required", "error", "Setup required: the Model GGUF is missing.")
        return
    missing, failure = probe_flags(args.engine)
    if failure:
        verdict("engine_unavailable", "error", "The recognition engine could not be run: %s." % failure)
        return
    if missing:
        verdict(
            "engine_incompatible",
            "error",
            "Setup required: the engine does not support %s." % ", ".join(missing),
            missingFlags=missing,
        )
        return
    wav_problem = validate_wav(args.wav)
    if wav_problem:
        verdict("invalid_wav", "error", wav_problem, wav=args.wav)
        return
    transcribe(args, heartbeat_path)


def terminate(proc):
    proc.terminate()
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()


def transcribe(args, heartbeat_path):
    private_dir(args.data_dir)
    jobs_dir = private_dir(os.path.join(args.data_dir, "jobs"))
    job_name = safe_id(args.job_id)
    job_dir = private_dir(os.path.join(jobs_dir, job_name))
    cancel_file = os.path.join(jobs_dir, job_name + ".cancel")
    if os.path.exists(cancel_file):
        # A cancel that arrived before any work started is honoured, not discarded.
        os.remove(cancel_file)
        verdict("cancelled", "cancelled", "Cancelled before the engine started.")
        return
    attempt = 1
    while os.path.isdir(os.path.join(job_dir, "attempt-%d" % attempt)):
        attempt += 1
    attempt_dir = private_dir(os.path.join(job_dir, "attempt-%d" % attempt))

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
    if severity == "error":
        detail = log_tail(log_path)
        if detail:
            message = message + " Engine output: " + detail
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
        },
    }
    write_result(result)
    emit(
        {
            "ok": severity in ("ok", "review"),
            "outcome": outcome,
            "severity": severity,
            "message": message,
            "copyable": severity in ("ok", "review") and bool(text.strip()),
            "jobId": args.job_id,
            "attempt": attempt,
            "textChars": len(text),
            "controlTokens": parsed["control_tokens"],
            "paths": result["paths"],
        }
    )


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
        return "per_file_error", "error", "The engine reported: %s." % parsed["error"].rstrip(".")
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

    run = sub.add_parser("run")
    run.add_argument("--engine", required=True)
    run.add_argument("--model", required=True)
    run.add_argument("--threads", type=int, required=True)
    run.add_argument("--wav", required=True)
    run.add_argument("--job-id", required=True)
    run.add_argument("--data-dir", required=True)
    run.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS)

    args = parser.parse_args(argv)
    if args.command == "probe":
        command_probe(args)
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
