#!/usr/bin/env bash
# Behavior check for dictation-helper.py with a fake recognition engine, so it
# runs anywhere: checks argv/env/nice transmission, WAV validation, every
# outcome, the watchdog, cancellation and durable per-attempt persistence.
set -euo pipefail
cd -- "$(dirname -- "$0")"

helper="$PWD/dictation-helper.py"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

engine="$work/fake-engine"
data="$work/data"

cat >"$engine" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time

HELP = """usage: fake-engine [options] audio.wav
  -m, --model PATH
  --threads N
  --backend TYPE
  --timestamps TYPE
  --batch FILE
  --batch-size N
  --batch-jsonl
"""

if "--help" in sys.argv:
    if os.environ.get("FAKE_HELP_FAIL"):
        sys.exit(2)
    # A barrier for the check that presses Stop while the helper is still in
    # preflight: the helper only leaves --help once the gate exists.
    gate = os.environ.get("FAKE_HELP_GATE")
    if gate:
        while not os.path.exists(gate):
            time.sleep(0.02)
    drop = os.environ.get("FAKE_DROP", "")
    print("\n".join(line for line in HELP.splitlines() if not (drop and drop in line)))
    sys.exit(0)

if os.environ.get("FAKE_RECORD"):
    with open(os.environ["FAKE_RECORD"], "w") as handle:
        json.dump({
            "argv": sys.argv,
            "OMP_NUM_THREADS": os.environ.get("OMP_NUM_THREADS"),
            "OPENBLAS_NUM_THREADS": os.environ.get("OPENBLAS_NUM_THREADS"),
            "nice": os.nice(0),
        }, handle)

batch = sys.argv[sys.argv.index("--batch") + 1]
with open(batch) as handle:
    wav = handle.read().strip()

def emit(*lines):
    for line in lines:
        print(line, flush=True)

def row(text, error=None):
    entry = {"file": wav, "text": text, "mel_ms": 1.0, "encode_ms": 2.0, "decode_ms": 3.0}
    if error is not None:
        entry["error"] = error
    return json.dumps(entry)

HEADER = json.dumps({"type": "batch_header", "load_ms": 1.0})

mode = os.environ.get("FAKE_MODE", "ok")
if mode == "ok":
    emit(HEADER, row("hello world"))
elif mode == "empty":
    emit(HEADER, row(""))
elif mode == "malformed":
    emit(HEADER, "{not json", row("hello"))
elif mode == "nonzero":
    emit(HEADER)
    sys.exit(3)
elif mode == "per_file_error":
    emit(HEADER, row("", "backend failure"))
    sys.exit(1)
elif mode == "truncated":
    emit(HEADER, row("partial text", "output truncated"))
elif mode == "unknown_token":
    emit(HEADER, row("hi <|endoftext|> there"))
elif mode == "missing_result":
    emit(HEADER)
elif mode == "bad_type":
    entry = json.loads(row("hello"))
    entry["text"] = {"not": "recognized speech"}
    emit(HEADER, json.dumps(entry))
elif mode == "fail_log":
    print("error: failed to load model: unknown tensor type", file=sys.stderr, flush=True)
    sys.exit(1)
elif mode == "slow":
    time.sleep(60)
else:
    emit(HEADER, row("hello world"))
PY
chmod +x "$engine"

python3 - "$work" <<'PY'
import os, sys, wave
work = sys.argv[1]
def make(name, rate=16000, channels=1, width=2, frames=16000):
    with wave.open(os.path.join(work, name), "wb") as handle:
        handle.setnchannels(channels)
        handle.setsampwidth(width)
        handle.setframerate(rate)
        handle.writeframes(b"\x00" * (width * channels * frames))
make("good.wav")
make("model-b.gguf")
make("stereo.wav", channels=2)
make("rate.wav", rate=44100)
make("empty.wav", frames=0)
PY

MODEL="$work/good.wav"
THREADS=4
WAV="$work/good.wav"
MODE=ok
TIMEOUT=1800
RECORD=

helper_run() {
  FAKE_MODE="$MODE" FAKE_RECORD="$RECORD" python3 "$helper" run \
    --engine "$engine" --model "$MODEL" --threads "$THREADS" --wav "$WAV" \
    --job-id "$1" --data-dir "${DATA_ROOT:-$data}" --timeout "$TIMEOUT"
}

field() { python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1],""))' "$1"; }
check() { # check <description> <expected> <actual>
  if [[ "$2" != "$3" ]]; then echo "FAIL: $1: expected [$2] got [$3]" >&2; exit 1; fi
}

probe() { python3 "$helper" probe --engine "$engine" --model "$MODEL" --data-dir "$data"; }

# Explicit setup verifies the engine and records both hashes.
out=$(probe)
check "setup probe" ok "$(printf '%s' "$out" | field outcome)"
check "probe summary persisted" ok "$(field outcome <"$data/setup-summary.json")"
python3 - "$data/setup.json" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
assert len(record["engine"]["sha256"]) == 64, record
assert len(record["model"]["sha256"]) == 64, record
PY

# An engine missing a required flag is incompatible, not guessed around.
out=$(FAKE_DROP=--batch-jsonl probe)
check "incompatible engine" engine_incompatible "$(printf '%s' "$out" | field outcome)"

# A successful run transmits the exact argv, thread-matched limits and niceness 10.
RECORD="$work/ok.json"
out=$(helper_run job-ok)
check "ok outcome" ok "$(printf '%s' "$out" | field outcome)"
check "ok copyable" True "$(printf '%s' "$out" | field copyable)"
check "ok transcript" "hello world" "$(cat "$data/jobs/job-ok/attempt-1/transcript.txt")"
check "ok summary persisted" ok "$(field outcome <"$data/jobs/job-ok/summary.json")"
check "raw jsonl persisted" True "$([[ -s "$data/jobs/job-ok/attempt-1/engine.jsonl" ]] && echo True || echo False)"
check "engine log persisted" True "$([[ -f "$data/jobs/job-ok/attempt-1/engine.log" ]] && echo True || echo False)"
python3 - "$work/ok.json" "$engine" "$data/jobs/job-ok/attempt-1/input-list.txt" "$work/good.wav" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
engine, input_list, model = sys.argv[2], sys.argv[3], sys.argv[4]
expected = [engine, "--backend", "cpu", "--threads", "4", "--timestamps", "none",
            "-m", model, "--batch", input_list, "--batch-size", "1", "--batch-jsonl"]
assert record["argv"] == expected, record["argv"]
assert record["OMP_NUM_THREADS"] == "4", record
assert record["OPENBLAS_NUM_THREADS"] == "4", record
assert record["nice"] == 10, record["nice"]
PY

# Changing the model or thread count reaches the engine without code edits.
RECORD="$work/model-b.json"
MODEL="$work/model-b.gguf" MODE=ok helper_run job-model-b >/dev/null
python3 - "$work/model-b.json" "$work/model-b.gguf" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
assert record["argv"][record["argv"].index("-m") + 1] == sys.argv[2], record["argv"]
PY
MODEL="$work/good.wav"
RECORD="$work/two-threads.json"
THREADS=2 MODE=ok helper_run job-two-threads >/dev/null
python3 - "$work/two-threads.json" <<'PY'
import json, sys
record = json.load(open(sys.argv[1]))
assert record["OMP_NUM_THREADS"] == "2" and record["OPENBLAS_NUM_THREADS"] == "2", record
PY
THREADS=4

# Every failure mode gets its own truthful outcome; partial text is preserved, not success.
expect_outcome() { # expect_outcome <mode> <outcome> <copyable> <job>
  local out
  RECORD=; MODE="$1" helper_run "$4" >"$work/$4.json" || true
  out=$(field outcome <"$work/$4.json")
  check "mode $1" "$2" "$out"
  check "mode $1 copyable" "$3" "$(field copyable <"$work/$4.json")"
}
expect_outcome empty empty False job-empty
expect_outcome malformed malformed_row False job-malformed
# A result field of the wrong type is a malformed row, never text to copy.
expect_outcome bad_type malformed_row False job-bad-type
check "bad type transcript empty" "" "$(cat "$data/jobs/job-bad-type/attempt-1/transcript.txt")"
expect_outcome nonzero nonzero_exit False job-nonzero
expect_outcome per_file_error per_file_error False job-per-file
expect_outcome truncated truncated True job-truncated
check "truncated keeps partial text" "partial text" "$(cat "$data/jobs/job-truncated/attempt-1/transcript.txt")"
expect_outcome unknown_token unknown_token True job-token
check "unknown token keeps partial text" "hi <|endoftext|> there" "$(cat "$data/jobs/job-token/attempt-1/transcript.txt")"
expect_outcome missing_result missing_result False job-missing

# A non-conforming WAV is rejected before any engine work.
for name in stereo rate empty; do
  RECORD=; MODE=ok WAV="$work/$name.wav" helper_run "job-wav-$name" >"$work/$name.json"
  check "wav $name" invalid_wav "$(field outcome <"$work/$name.json")"
  check "wav $name ran no engine" False "$([[ -d "$data/jobs/job-wav-$name/attempt-1" ]] && echo True || echo False)"
  check "wav $name summary persisted" invalid_wav "$(field outcome <"$data/jobs/job-wav-$name/summary.json")"
done
WAV="$work/good.wav"

# An engine that lost a required flag after setup is caught at job time.
out=$(FAKE_DROP=--threads MODE=ok helper_run job-flag)
check "engine flag check at run" engine_incompatible "$(printf '%s' "$out" | field outcome)"

# An executable that cannot run at all is not "incompatible": its flags were
# never read, so it is reported as unavailable instead.
printf 'not a real binary\n' >"$work/broken-engine"
chmod +x "$work/broken-engine"
out=$(python3 "$helper" probe --engine "$work/broken-engine" --model "$MODEL" --data-dir "$data" || true)
check "unrunnable engine probe" engine_unavailable "$(printf '%s' "$out" | field outcome)"
RECORD=; out=$(MODE=ok python3 "$helper" run --engine "$work/broken-engine" --model "$MODEL" \
  --threads 4 --wav "$work/good.wav" --job-id job-broken --data-dir "$data" || true)
check "unrunnable engine run" engine_unavailable "$(printf '%s' "$out" | field outcome)"

# An engine whose --help exits nonzero without answering is unavailable, not
# incompatible: its flags were never reported.
out=$(FAKE_HELP_FAIL=1 python3 "$helper" probe --engine "$engine" --model "$MODEL" --data-dir "$data" || true)
check "silent failing help" engine_unavailable "$(printf '%s' "$out" | field outcome)"

# A thread count outside the supported range is reported, not passed to the engine.
for bad in 0 100; do
  RECORD=; out=$(MODE=ok python3 "$helper" run --engine "$engine" --model "$MODEL" --threads "$bad" \
    --wav "$work/good.wav" --job-id "job-threads-$bad" --data-dir "$data")
  check "threads $bad" invalid_threads "$(printf '%s' "$out" | field outcome)"
done

# A failing engine's own reason reaches the outcome, not only its exit status.
RECORD=; MODE=fail_log helper_run job-log >"$work/log.json"
check "engine reason in outcome" True \
  "$(grep -q 'failed to load model' <<<"$(field message <"$work/log.json")" && echo True || echo False)"

# A crash still reports an outcome, because the plugin would otherwise wait for it.
: >"$work/not-a-dir"
MODE=ok python3 "$helper" run --engine "$engine" --model "$MODEL" --threads 4 \
  --wav "$work/good.wav" --job-id job-internal --data-dir "$work/not-a-dir" \
  >"$work/internal.json" 2>"$work/internal.err" && internal_exit=0 || internal_exit=$?
check "crash reports internal" internal "$(field outcome <"$work/internal.json")"
check "crash exits nonzero" 3 "$internal_exit"

# The helper owns the watchdog; a slow engine is stopped.
start=$(date +%s)
RECORD=; MODE=slow TIMEOUT=1 helper_run job-timeout >"$work/timeout.json"
check "watchdog" timeout "$(field outcome <"$work/timeout.json")"
check "heartbeat written" True "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ts"] > 0)' "$data/jobs/job-timeout/heartbeat.json")"
check "heartbeat private" 600 "$(stat -c '%a' "$data/jobs/job-timeout/heartbeat.json")"
(( $(date +%s) - start < 30 )) || { echo "FAIL: watchdog did not stop the engine promptly" >&2; exit 1; }

# A cancel that arrives before any engine work is honoured instead of discarded.
mkdir -p "$data/jobs"
printf 1 >"$data/jobs/job-early-cancel.cancel"
RECORD=; MODE=ok helper_run job-early-cancel >"$work/early-cancel.json"
check "early cancel cleared" False "$([[ -f "$data/jobs/job-early-cancel.cancel" ]] && echo True || echo False)"
check "early cancel outcome" cancelled "$(field outcome <"$work/early-cancel.json")"
check "early cancel ran no engine" False "$([[ -d "$data/jobs/job-early-cancel/attempt-1" ]] && echo True || echo False)"

# Cancel stops the owned engine and only that work.
UNRELATED_ENGINE="$work/unrelated-engine.pid"
printf '%s\n' "$work/good.wav" >"$work/unrelated-list.txt"
python3 - "$engine" "$work/unrelated-list.txt" "$UNRELATED_ENGINE" <<'PY'
import os, subprocess, sys
engine, batch, pid_file = sys.argv[1], sys.argv[2], sys.argv[3]
proc = subprocess.Popen(
    [engine, "--model", "/dev/null", "--threads", "1", "--batch", batch],
    env=dict(os.environ, FAKE_MODE="slow"),
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
with open(pid_file, "w") as handle:
    handle.write(str(proc.pid))
PY
unrelated_engine_state() {
    python3 - "$UNRELATED_ENGINE" 2>/dev/null <<'PY' || echo dead
import os, sys
os.kill(int(open(sys.argv[1]).read()), 0)
print("alive")
PY
}

MODE=slow TIMEOUT=60 helper_run job-cancel >"$work/cancel.json" &
pid=$!
for _ in $(seq 1 100); do [[ -f "$data/jobs/job-cancel/attempt-1/engine.jsonl" ]] && break; sleep 0.1; done
sleep 0.5
printf 1 >"$data/jobs/job-cancel.cancel"
wait "$pid"
check "cancel outcome" cancelled "$(field outcome <"$work/cancel.json")"
check "cancel copyable" False "$(field copyable <"$work/cancel.json")"
check "cancel summary persisted" cancelled "$(field outcome <"$data/jobs/job-cancel/summary.json")"
# Ownership is the engine this helper launched, never a process name, so an
# unrelated recognizer the user is already running has to survive the cancel.
check "unrelated recognizer survives cancel" alive "$(unrelated_engine_state)"
python3 - "$UNRELATED_ENGINE" <<'PY'
import os, signal, sys
os.kill(int(open(sys.argv[1]).read()), signal.SIGKILL)
PY

# A retry opens a new attempt instead of overwriting the previous one.
RECORD=; MODE=ok helper_run job-retry >/dev/null
RECORD=; MODE=ok helper_run job-retry >"$work/retry.json"
check "retry attempt number" 2 "$(field attempt <"$work/retry.json")"
check "attempt 1 kept" True "$([[ -f "$data/jobs/job-retry/attempt-1/result.json" ]] && echo True || echo False)"

# Persistence is private, and the imported original is never touched.
before=$(sha256sum "$work/good.wav" | cut -d' ' -f1)
RECORD=; MODE=ok helper_run job-persist >/dev/null
after=$(sha256sum "$work/good.wav" | cut -d' ' -f1)
check "original untouched" "$before" "$after"
check "result persisted" True "$([[ -f "$data/jobs/job-persist/attempt-1/result.json" ]] && echo True || echo False)"
check "import becomes the play target" "$WAV" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["paths"]["recording"])' "$data/jobs/job-persist/summary.json")"
check "transcript private" 600 "$(stat -c '%a' "$data/jobs/job-persist/attempt-1/transcript.txt")"
check "raw jsonl private" 600 "$(stat -c '%a' "$data/jobs/job-persist/attempt-1/engine.jsonl")"
check "engine log private" 600 "$(stat -c '%a' "$data/jobs/job-persist/attempt-1/engine.log")"
check "attempt dir private" 700 "$(stat -c '%a' "$data/jobs/job-persist/attempt-1")"

# ── Live recording ───────────────────────────────────────────────────────────

# PipeWire is not available in every check environment, so the capture side runs
# against fakes that behave like the real tools: pw-dump emits the structured
# graph, pw-record writes a WAV and finalizes it on SIGINT/SIGTERM, and pw-play
# records how it was called.
bin="$work/bin"
mkdir -p "$bin"
cat >"$bin/pw-dump" <<'PY'
#!/usr/bin/env python3
import json, os, sys

mode = os.environ.get("FAKE_PWDUMP_MODE", "ok")
if mode == "fail":
    print("pw-dump: connect: Connection refused", file=sys.stderr)
    sys.exit(1)
if mode == "badjson":
    print("pw-dump is not speaking JSON today")
    sys.exit(0)
if mode == "empty":
    print(json.dumps([]))
    sys.exit(0)


def node(node_id, name, description, media_class="Audio/Source"):
    return {
        "id": node_id,
        "type": "PipeWire:Interface:Node",
        "info": {"props": {"media.class": media_class, "node.name": name, "node.description": description}},
    }


print(json.dumps([
    node(41, "alsa_input.usb-mic", "USB Microphone"),
    node(42, "alsa_output.hdmi", "HDMI Output", media_class="Audio/Sink"),
    node(43, "alsa_input.loopback", "Monitor of HDMI Output"),
    node(44, "alsa_output.hdmi.monitor", "HDMI Loopback"),
    node(45, "alsa_input.internal-mic", "Built-in Microphone"),
    {"id": 46, "type": "PipeWire:Interface:Client", "info": {"props": {}}},
]))
PY

cat >"$bin/pw-record" <<'PY'
#!/usr/bin/env python3
"""Writes the WAV the way pw-record does, and records how it was called."""
import json, os, signal, struct, sys, time

argv = sys.argv
mode = os.environ.get("FAKE_PWRECORD_MODE", "ok")


def flag(name):
    return argv[argv.index(name) + 1] if name in argv else None


rate = int(flag("--rate") or 16000)
channels = int(flag("--channels") or 1)
if mode == "bad_rate":
    rate = 44100
elif mode == "bad_channels":
    channels = 2
path = argv[-1]

record_path = os.environ.get("FAKE_PWRECORD_RECORD")
if record_path:
    with open(record_path, "w") as handle:
        json.dump({
            "argv": argv,
            "pid": os.getpid(),
            "own_group": os.getpgid(0) == os.getpid(),
        }, handle)

if mode == "exit_early":
    sys.exit(1)


def header(data_bytes):
    block = channels * 2
    return b"".join([
        b"RIFF", struct.pack("<I", 36 + data_bytes), b"WAVE",
        b"fmt ", struct.pack("<IHHIIHH", 16, 1, channels, rate, rate * block, block, 16),
        b"data", struct.pack("<I", data_bytes),
    ])


handle = open(path, "wb")
handle.write(header(0))
handle.flush()

stopping = []


def on_signal(_number, _frame):
    stopping.append(True)


signal.signal(signal.SIGINT, on_signal)
if mode == "ignore_int":
    # Will not stop on the graceful signal, so the helper's grace runs out, the
    # recorder is killed, and its WAV is left unfinalized.
    signal.signal(signal.SIGINT, signal.SIG_IGN)
if mode == "ignore_signals":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
else:
    signal.signal(signal.SIGTERM, on_signal)

block = b"\x00" * ((rate // 20) * channels * 2)
frames = 0
while not stopping:
    if mode != "no_data":
        handle.write(block)
        handle.flush()
        frames += rate // 20
    time.sleep(0.05)

handle.seek(0)
handle.write(header(frames * channels * 2))
handle.flush()
handle.close()
sys.exit(0)
PY

cat >"$bin/pw-play" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time

record_path = os.environ.get("FAKE_PWPLAY_RECORD")
if record_path:
    with open(record_path, "w") as handle:
        json.dump({"argv": sys.argv}, handle)
mode = os.environ.get("FAKE_PWPLAY_MODE", "ok")
if mode == "fail":
    print("pw-play: no such device", file=sys.stderr)
    sys.exit(1)
if mode == "hang":
    time.sleep(60)
sys.exit(0)
PY
chmod +x "$bin/pw-dump" "$bin/pw-record" "$bin/pw-play"
PATH="$bin:$PATH"

# A PATH with python3 but none of the PipeWire tools, for the missing-tool cases.
bare="$work/bare"
mkdir -p "$bare"
ln -sf "$(command -v python3)" "$bare/python3"
# A PATH with pw-dump but no pw-record or pw-play, to tell "no microphone graph"
# apart from "the capture tool is not installed".
norec="$work/norec"
mkdir -p "$norec"
ln -sf "$(command -v python3)" "$norec/python3"
ln -sf "$bin/pw-dump" "$norec/pw-dump"

SRC=alsa_input.usb-mic
DUMP=ok
REC_MODE=ok
REC_JSON=
LEASE=60
TIMEOUT=60

# The controller, not the helper, keeps the lease fresh. These checks play that
# part unless the case is about the lease itself.
helper_record() { # helper_record <job-id>
  [[ -d "$data/jobs" ]] || mkdir -p "$data/jobs"
  python3 -c 'import json,sys,time; open(sys.argv[1],"w").write(json.dumps({"ts": time.time()}))' "$data/jobs/$1.lease"
  FAKE_PWDUMP_MODE="$DUMP" FAKE_PWRECORD_MODE="$REC_MODE" FAKE_PWRECORD_RECORD="$REC_JSON" \
    FAKE_MODE="$MODE" python3 "$helper" record \
    --engine "$engine" --model "$MODEL" --threads "$THREADS" \
    --source "${REC_SOURCE:-$SRC}" --job-id "$1" --data-dir "$data" \
    --timeout "$TIMEOUT" --lease-seconds "$LEASE"
}

wait_for_recording() { # wait_for_recording <job-id>
  for _ in $(seq 1 200); do
    if [[ -f "$data/jobs/$1/status.json" ]] && grep -q '"phase": "recording"' "$data/jobs/$1/status.json"; then
      return 0
    fi
    sleep 0.05
  done
  echo "FAIL: job $1 never reported that it was recording" >&2
  exit 1
}

# Capture sources come from the structured graph: sinks and both kinds of monitor
# are excluded, so no output loopback is ever offered as a microphone.
out=$(python3 "$helper" sources --data-dir "$data")
check "sources outcome" ok "$(printf '%s' "$out" | field outcome)"
check "sources persist" ok "$(field outcome <"$data/sources.json")"
python3 - "$data/sources.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert [source["id"] for source in doc["sources"]] == ["alsa_input.internal-mic", "alsa_input.usb-mic"], doc
assert doc["sources"][0]["description"] == "Built-in Microphone", doc
assert doc["capturedAt"] > 0, doc
PY

out=$(FAKE_PWDUMP_MODE=empty python3 "$helper" sources --data-dir "$data" || true)
check "no capture sources" no_sources "$(printf '%s' "$out" | field outcome)"
out=$(FAKE_PWDUMP_MODE=fail python3 "$helper" sources --data-dir "$data" || true)
check "unreadable graph" sources_unavailable "$(printf '%s' "$out" | field outcome)"
out=$(FAKE_PWDUMP_MODE=badjson python3 "$helper" sources --data-dir "$data" || true)
check "graph without JSON" sources_unavailable "$(printf '%s' "$out" | field outcome)"
out=$(PATH="$bare" python3 "$helper" sources --data-dir "$data" || true)
check "pw-dump missing" sources_unavailable "$(printf '%s' "$out" | field outcome)"

# Stop: the helper finalizes the WAV itself and only then runs the engine.
REC_JSON="$work/recorder.json" helper_record job-rec >"$work/rec-ok.json" &
pid=$!
wait_for_recording job-rec
printf 'stop\n' >"$data/jobs/job-rec.stop"
printf 'stop\n' >"$data/jobs/job-rec.stop"
wait "$pid"
check "record outcome" ok "$(field outcome <"$work/rec-ok.json")"
check "record summary persisted" ok "$(field outcome <"$data/jobs/job-rec/summary.json")"
check "record transcript" "hello world" "$(cat "$data/jobs/job-rec/attempt-1/transcript.txt")"
check "record heartbeat" True "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ts"] > 0)' "$data/jobs/job-rec/heartbeat.json")"
check "record job record" record "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mode"])' "$data/jobs/job-rec/job.json")"
check "recording private" 600 "$(stat -c '%a' "$data/jobs/job-rec/recording.wav")"
check "job dir private" 700 "$(stat -c '%a' "$data/jobs/job-rec")"
check "duplicate stop cleared" False "$([[ -f "$data/jobs/job-rec.stop" ]] && echo True || echo False)"
check "one attempt for one stop" False "$([[ -d "$data/jobs/job-rec/attempt-2" ]] && echo True || echo False)"
python3 - "$work/recorder.json" "$data/jobs/job-rec/recording.wav" <<'PY'
import json, os, sys, wave
record = json.load(open(sys.argv[1]))
argv, wav = record["argv"], sys.argv[2]
assert os.path.basename(argv[0]) == "pw-record", argv
assert argv[argv.index("--target") + 1] == "alsa_input.usb-mic", argv
assert argv[argv.index("--rate") + 1] == "16000", argv
assert argv[argv.index("--channels") + 1] == "1", argv
assert argv[argv.index("--format") + 1] == "s16", argv
assert argv[-1] == wav, argv
assert record["own_group"], record
with wave.open(wav, "rb") as handle:
    assert handle.getframerate() == 16000, handle.getframerate()
    assert handle.getnchannels() == 1, handle.getnchannels()
    assert handle.getsampwidth() == 2, handle.getsampwidth()
    assert handle.getnframes() > 0, handle.getnframes()
try:
    os.kill(record["pid"], 0)
except ProcessLookupError:
    pass
else:
    raise AssertionError("the recorder outlived the job: %r" % record)
PY

# History is read back from the durable job directories alone, so it is what a
# restart can still list. It is read-only: no recorder, no engine and no paste
# follow from listing, and a job without a summary is interrupted unless a helper
# for it is still alive. The tree is its own so the count is the tree's, not every
# job these other checks left behind.
HDATA="$work/history-data"
mkdir -p "$HDATA/jobs"
python3 - "$HDATA/jobs" <<'PY'
import json, os, struct, sys, wave
jobs = sys.argv[1]

def wav(path, seconds):
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(16000)
        handle.writeframes(struct.pack("<%dh" % (16000 * seconds), *([0] * 16000 * seconds)))

finished = os.path.join(jobs, "job-done")
os.makedirs(os.path.join(finished, "attempt-1"))
wav(os.path.join(finished, "recording.wav"), 2)
json.dump({"jobId": "job-done", "mode": "record", "startedAt": 4000, "recording": os.path.join(finished, "recording.wav")}, open(os.path.join(finished, "job.json"), "w"))
open(os.path.join(finished, "attempt-1", "transcript.txt"), "w").write("hello history\n")
json.dump({"outcome": "ok", "severity": "ok", "message": "Transcribed 2 words.", "copyable": True, "paths": {"recording": os.path.join(finished, "recording.wav")}}, open(os.path.join(finished, "summary.json"), "w"))

stopped = os.path.join(jobs, "job-stopped")
os.makedirs(stopped)
wav(os.path.join(stopped, "recording.wav"), 1)
json.dump({"jobId": "job-stopped", "mode": "record", "startedAt": 3000, "recording": os.path.join(stopped, "recording.wav")}, open(os.path.join(stopped, "job.json"), "w"))

gone = os.path.join(jobs, "job-gone")
os.makedirs(gone)
json.dump({"jobId": "job-gone", "mode": "record", "startedAt": 2000, "recording": os.path.join(gone, "gone.wav")}, open(os.path.join(gone, "job.json"), "w"))

live = os.path.join(jobs, "job-live")
os.makedirs(live)
json.dump({"jobId": "job-live", "mode": "record", "startedAt": 0, "recording": os.path.join(live, "recording.wav")}, open(os.path.join(live, "job.json"), "w"))
PY
out=$(python3 "$helper" history --data-dir "$HDATA")
check "history outcome" ok "$(printf '%s' "$out" | field outcome)"
check "history counts its own tree" "Found 3 dictations. 2 were interrupted." "$(printf '%s' "$out" | field message)"
python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
jobs = {entry["id"]: entry for entry in doc["jobs"]}
assert [entry["id"] for entry in doc["jobs"]] == ["job-done", "job-stopped", "job-gone"], doc["jobs"]
finished = jobs["job-done"]
assert finished["state"] == "complete", finished
assert finished["outcome"] == "ok", finished
assert finished["preview"] == "hello history", finished
assert finished["durationSeconds"] == 2.0 and finished["duration"] == "0:02", finished
assert finished["attempts"] == 1, finished
assert finished["recordingUsable"] is True, finished
assert finished["copyable"] is True, finished
stopped = jobs["job-stopped"]
assert stopped["state"] == "interrupted", stopped
assert stopped["outcome"] == "interrupted", stopped
assert stopped["durationSeconds"] == 1.0, stopped
assert stopped["transcriptPath"] == "", stopped
assert stopped["recordingUsable"] is True, stopped
missing = jobs["job-gone"]
assert missing["state"] == "interrupted", missing
assert missing["recordingUsable"] is False, missing
assert "gone.wav" in missing["recordingMessage"], missing
PY

# The panel acts on the fields this read reports, so they are checked against the
# artifacts a real run left behind rather than against the fixture above: the
# recording and transcript paths must be the ones the job actually wrote, and the
# preview must be the raw transcript's own first words.
DATA_ROOT="$HDATA" WAV="$work/good.wav" RECORD= MODE=ok helper_run job-history-real >/dev/null
out=$(python3 "$helper" history --data-dir "$HDATA")
python3 - "$out" "$HDATA" "$work/good.wav" <<'PY'
import json, os, sys
doc = json.loads(sys.argv[1])
data, wav = sys.argv[2], sys.argv[3]
entry = next(item for item in doc["jobs"] if item["id"] == "job-history-real")
assert entry["state"] == "complete" and entry["outcome"] == "ok", entry
assert entry["recordingPath"] == wav and os.path.isfile(wav), entry
assert entry["recordingUsable"] is True and entry["recordingMessage"] == "", entry
assert entry["transcriptPath"] == os.path.join(data, "jobs", "job-history-real", "attempt-1", "transcript.txt"), entry
assert open(entry["transcriptPath"]).read().strip() == entry["preview"] == "hello world", entry
assert entry["attempts"] == 1 and entry["copyable"] is True, entry
assert entry["startedAtMs"] > 0 and entry["timestamp"] != "", entry
assert entry["durationSeconds"] > 0 and entry["duration"] != "", entry
assert entry["retriesOf"] == "", entry
PY

# A retry transcribes the saved recording as a new job, and the durable record has
# to name the dictation it retried or nothing on disk links the two attempts.
python3 "$helper" run --engine "$engine" --model "$MODEL" --threads "$THREADS" \
    --wav "$work/good.wav" --job-id job-history-retried --data-dir "$HDATA" \
    --timeout "$TIMEOUT" --retries-of job-history-real >/dev/null
out=$(python3 "$helper" history --data-dir "$HDATA")
python3 - "$out" "$HDATA" "$work/good.wav" <<'PY'
import json, os, sys
doc = json.loads(sys.argv[1])
data, wav = sys.argv[2], sys.argv[3]
entry = next(item for item in doc["jobs"] if item["id"] == "job-history-retried")
assert entry["retriesOf"] == "job-history-real", entry
assert entry["recordingPath"] == wav, entry
assert entry["recordingUsable"] is True, entry
record = json.load(open(os.path.join(data, "jobs", "job-history-retried", "job.json")))
assert record["retriesOf"] == "job-history-real", record
assert record["engine"] and record["model"] and record["threads"], record
original = json.load(open(os.path.join(data, "jobs", "job-history-real", "job.json")))
assert original.get("retriesOf", "") == "", original
PY

# A helper process that still owns the job is what separates running from
# interrupted, so the id in its command line is the signal, not the files alone.
python3 - "$HDATA/jobs/job-live" <<'PY'
import json, os, struct, sys, wave
live = sys.argv[1]
with wave.open(os.path.join(live, "recording.wav"), "wb") as handle:
    handle.setnchannels(1)
    handle.setsampwidth(2)
    handle.setframerate(16000)
    handle.writeframes(struct.pack("<16000h", *([0] * 16000)))
record = json.load(open(os.path.join(live, "job.json")))
record["startedAt"] = 1000
json.dump(record, open(os.path.join(live, "job.json"), "w"))
PY
python3 -c 'import time; time.sleep(30)' --job-id job-live &
live_pid=$!
sleep 0.5
out=$(python3 "$helper" history --data-dir "$HDATA")
python3 - "$out" <<'PY'
import json, sys
jobs = {entry["id"]: entry for entry in json.loads(sys.argv[1])["jobs"]}
assert jobs["job-live"]["state"] == "running", jobs["job-live"]
assert jobs["job-live"]["outcome"] == "running", jobs["job-live"]
PY
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true

# One recorder this job never started stays alive through Cancel and controller
# loss: ownership is the process group the helper created, never a process name,
# so a broad pkill or a name match would be caught here.
UNRELATED_JSON="$work/unrelated.json"
python3 - "$UNRELATED_JSON" "$work/unrelated.wav" <<'PY'
import os, subprocess, sys, time
record, wav = sys.argv[1], sys.argv[2]
subprocess.Popen(
    ["pw-record", "--target", "alsa_input.usb-mic", "--rate", "16000",
     "--channels", "1", "--format", "s16", wav],
    env=dict(os.environ, FAKE_PWRECORD_RECORD=record),
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
deadline = time.time() + 5
while not os.path.exists(record) and time.time() < deadline:
    time.sleep(0.05)
PY
unrelated_state() {
    python3 - "$UNRELATED_JSON" 2>/dev/null <<'PY' || echo dead
import json, os, sys
os.kill(json.load(open(sys.argv[1]))["pid"], 0)
print("alive")
PY
}

# Cancel during capture keeps the audio and starts no recognition.
REC_JSON= helper_record job-cancel-rec >"$work/rec-cancel.json" &
pid=$!
wait_for_recording job-cancel-rec
printf 'cancel\n' >"$data/jobs/job-cancel-rec.cancel"
wait "$pid"
check "cancel while recording" cancelled "$(field outcome <"$work/rec-cancel.json")"
check "cancel keeps usable audio" True "$(field usableAudio <"$work/rec-cancel.json")"
check "cancel runs no engine" False "$([[ -d "$data/jobs/job-cancel-rec/attempt-1" ]] && echo True || echo False)"
check "cancel request cleared" False "$([[ -f "$data/jobs/job-cancel-rec.cancel" ]] && echo True || echo False)"
check "cancelled audio preserved" True "$(python3 -c 'import sys,wave; print(wave.open(sys.argv[1]).getnframes() > 0)' "$data/jobs/job-cancel-rec/recording.wav")"

# A recorder that ignores the graceful signal is killed, and the audio it left
# behind is reported as unusable instead of being transcribed.
REC_MODE=ignore_signals REC_JSON="$work/killed.json" helper_record job-kill >"$work/rec-kill.json" &
pid=$!
wait_for_recording job-kill
start=$(date +%s)
printf 'cancel\n' >"$data/jobs/job-kill.cancel"
wait "$pid"
(( $(date +%s) - start < 30 )) || { echo "FAIL: cancel escalation was not bounded" >&2; exit 1; }
check "cancel escalates" cancelled "$(field outcome <"$work/rec-kill.json")"
check "unfinalized audio not usable" False "$(field usableAudio <"$work/rec-kill.json")"
check "escalation ran no engine" False "$([[ -d "$data/jobs/job-kill/attempt-1" ]] && echo True || echo False)"
python3 - "$work/killed.json" <<'PY'
import json, os, sys
record = json.load(open(sys.argv[1]))
try:
    os.kill(record["pid"], 0)
except ProcessLookupError:
    pass
else:
    raise AssertionError("SIGKILL never reached the recorder: %r" % record)
PY
check "unrelated recorder survives cancel" alive "$(unrelated_state)"

# A Cancel that arrives while the WAV is being finalized wins over the Stop: the
# recording is cancelled and no recognition is started.
REC_MODE=ignore_int REC_JSON= helper_record job-stop-cancel >"$work/rec-stop-cancel.json" &
pid=$!
wait_for_recording job-stop-cancel
printf 'stop\n' >"$data/jobs/job-stop-cancel.stop"
sleep 0.5
printf 'cancel\n' >"$data/jobs/job-stop-cancel.cancel"
wait "$pid"
check "cancel while finalizing" cancelled "$(field outcome <"$work/rec-stop-cancel.json")"
check "cancel while finalizing reports the audio honestly" False "$(field usableAudio <"$work/rec-stop-cancel.json")"
check "cancel while finalizing runs no engine" False "$([[ -d "$data/jobs/job-stop-cancel/attempt-1" ]] && echo True || echo False)"
check "cancel while finalizing cleared" False "$([[ -f "$data/jobs/job-stop-cancel.cancel" ]] && echo True || echo False)"
check "unrelated recorder survives finalizing cancel" alive "$(unrelated_state)"
REC_MODE=ok

# A Stop that arrives while the helper is still preparing the engine and the
# source belongs to this job, not to an earlier one: the capture ends and the job
# reports a verdict. Deleting that request instead left the microphone recording
# while the controller reported that the recording was being finalized.
gate="$work/help-gate"
FAKE_HELP_GATE="$gate" LEASE=6 REC_JSON= helper_record job-early-stop >"$work/rec-early-stop.json" &
pid=$!
unset FAKE_HELP_GATE
for _ in $(seq 1 200); do
  [[ -f "$data/jobs/job-early-stop/status.json" ]] && break
  sleep 0.05
done
printf 'stop\n' >"$data/jobs/job-early-stop.stop"
touch "$gate"
wait "$pid"
check "stop during startup is honoured" invalid_recording "$(field outcome <"$work/rec-early-stop.json")"
check "stop during startup opens no microphone" False "$([[ -f "$data/jobs/job-early-stop/recorder.log" ]] && echo True || echo False)"
check "stop during startup cleared the request" False "$([[ -f "$data/jobs/job-early-stop.stop" ]] && echo True || echo False)"

# The controller accepts Stop as soon as it has launched the helper, so a request
# for this job can exist before this helper process has started at all. The job id
# is allocated fresh and never reused, so such a request is this job's own and the
# microphone is not opened for a recording its owner already ended. A lease short
# enough to end the recording keeps the unfixed path from waiting forever.
printf 'stop\n' >"$data/jobs/job-pre-stop.stop"
LEASE=6 REC_JSON= helper_record job-pre-stop >"$work/rec-pre-stop.json"
check "stop queued before the helper starts is honoured" invalid_recording "$(field outcome <"$work/rec-pre-stop.json")"
check "stop queued before the helper starts opens no microphone" False "$([[ -f "$data/jobs/job-pre-stop/recorder.log" ]] && echo True || echo False)"
check "stop queued before the helper starts cleared the request" False "$([[ -f "$data/jobs/job-pre-stop.stop" ]] && echo True || echo False)"

# The same window for Cancel: the request wins over the capture and no recognition
# is started, because the job never captured anything to recognize.
printf 'cancel\n' >"$data/jobs/job-pre-cancel.cancel"
LEASE=6 REC_JSON= helper_record job-pre-cancel >"$work/rec-pre-cancel.json"
check "cancel queued before the helper starts is honoured" cancelled "$(field outcome <"$work/rec-pre-cancel.json")"
check "cancel queued before the helper starts opens no microphone" False "$([[ -f "$data/jobs/job-pre-cancel/recorder.log" ]] && echo True || echo False)"
check "cancel queued before the helper starts cleared the request" False "$([[ -f "$data/jobs/job-pre-cancel.cancel" ]] && echo True || echo False)"

# A controller that stops refreshing the lease releases the microphone by itself.
LEASE=6 REC_JSON= helper_record job-lease >"$work/rec-lease.json" &
pid=$!
wait_for_recording job-lease
sleep 0.3
# The lease was fresh when the recorder started and goes stale here, which is
# what a plugin that died or lost the job looks like from the helper side.
python3 -c 'import json,sys,time; open(sys.argv[1],"w").write(json.dumps({"ts": time.time() - 600}))' "$data/jobs/job-lease.lease"
wait "$pid"
check "controller loss releases the microphone" interrupted "$(field outcome <"$work/rec-lease.json")"
check "controller loss keeps usable audio" True "$(field usableAudio <"$work/rec-lease.json")"
check "controller loss runs no engine" False "$([[ -d "$data/jobs/job-lease/attempt-1" ]] && echo True || echo False)"
check "unrelated recorder survives controller loss" alive "$(unrelated_state)"
python3 - "$UNRELATED_JSON" <<'PY'
import json, os, signal, sys
os.kill(json.load(open(sys.argv[1]))["pid"], signal.SIGTERM)
PY

# A microphone that is gone is a named failure; nothing is substituted for it.
out=$(REC_SOURCE=alsa_input.gone helper_record job-gone)
check "missing microphone" source_missing "$(printf '%s' "$out" | field outcome)"
check "missing microphone starts no recorder" False "$([[ -f "$data/jobs/job-gone/recorder.log" ]] && echo True || echo False)"
out=$(DUMP=fail helper_record job-nograph || true)
check "unreadable graph blocks recording" sources_unavailable "$(printf '%s' "$out" | field outcome)"
out=$(PATH="$norec" helper_record job-nopw || true)
check "pw-record missing" recorder_unavailable "$(printf '%s' "$out" | field outcome)"

# A recorder that exits on its own is reported with its own status, not success.
REC_MODE=exit_early
out=$(REC_JSON= helper_record job-died)
check "recorder stopped on its own" recorder_failed "$(printf '%s' "$out" | field outcome)"
REC_MODE=ok

# Audio the microphone never produced is rejected before any recognition.
for mode in bad_rate bad_channels no_data; do
  REC_MODE="$mode" helper_record "job-wav-$mode" >"$work/rec-$mode.json" &
  pid=$!
  wait_for_recording "job-wav-$mode"
  printf 'stop\n' >"$data/jobs/job-wav-$mode.stop"
  wait "$pid"
  check "recording $mode" invalid_recording "$(field outcome <"$work/rec-$mode.json")"
  check "recording $mode runs no engine" False "$([[ -d "$data/jobs/job-wav-$mode/attempt-1" ]] && echo True || echo False)"
  check "recording $mode kept" True "$([[ -f "$data/jobs/job-wav-$mode/recording.wav" ]] && echo True || echo False)"
done
REC_MODE=ok

# Playback goes through the helper, plays the saved file and touches no clipboard.
out=$(FAKE_PWPLAY_RECORD="$work/play.json" python3 "$helper" play --wav "$data/jobs/job-rec/recording.wav")
check "playback outcome" ok "$(printf '%s' "$out" | field outcome)"
python3 - "$work/play.json" "$data/jobs/job-rec/recording.wav" <<'PY'
import json, os, sys
argv = json.load(open(sys.argv[1]))["argv"]
assert os.path.basename(argv[0]) == "pw-play", argv
assert argv[1] == sys.argv[2], argv
PY
out=$(FAKE_PWPLAY_MODE=fail python3 "$helper" play --wav "$data/jobs/job-rec/recording.wav" || true)
check "playback failure" playback_failed "$(printf '%s' "$out" | field outcome)"
out=$(python3 "$helper" play --wav "$work/absent.wav" || true)
check "playback without a recording" missing_recording "$(printf '%s' "$out" | field outcome)"
out=$(PATH="$bare" python3 "$helper" play --wav "$data/jobs/job-rec/recording.wav" || true)
check "pw-play missing" playback_unavailable "$(printf '%s' "$out" | field outcome)"

# ── Retention, deletion, storage and diagnostics ─────────────────────────────

# Only a finished dictation with a durable summary is a retention candidate, and
# only behind a newer dictation that committed its own result. These fixtures are
# written by hand, so "older" is a fact of the data rather than a race between
# processes that all start inside the same second.
retention_fixtures() { # retention_fixtures <data-dir> <finished-count>
  python3 - "$1" "$2" <<'PY'
import json, os, sys
data, count = sys.argv[1], int(sys.argv[2])
jobs = os.path.join(data, "jobs")
def finished(name, started):
    job = os.path.join(jobs, name)
    os.makedirs(os.path.join(job, "attempt-1"))
    recording = os.path.join(job, "recording.wav")
    open(recording, "wb").write(b"RIFF0000WAVE")
    json.dump({"jobId": name, "mode": "record", "startedAt": started, "recording": recording},
              open(os.path.join(job, "job.json"), "w"))
    open(os.path.join(job, "attempt-1", "transcript.txt"), "w").write("kept text %s\n" % name)
    json.dump({"outcome": "ok", "severity": "ok", "message": "done", "copyable": True},
              open(os.path.join(job, "summary.json"), "w"))
def unfinished(name, started, severity):
    job = os.path.join(jobs, name)
    os.makedirs(job)
    json.dump({"jobId": name, "mode": "record", "startedAt": started},
              open(os.path.join(job, "job.json"), "w"))
    if severity:
        json.dump({"outcome": "failed", "severity": severity, "message": "failed", "copyable": False},
                  open(os.path.join(job, "summary.json"), "w"))
for index in range(1, count + 1):
    finished("job-fin-%d" % index, index * 1000)
unfinished("job-broken", 60000, None)
unfinished("job-failed", 70000, "error")
PY
}

run_into() { # run_into <data-dir> <job-id> [retention]
  local extra=()
  if [[ -n "${3:-}" ]]; then extra=(--retention "$3"); fi
  RECORD= python3 "$helper" run --engine "$engine" --model "$MODEL" --threads "$THREADS" \
    --wav "$work/good.wav" --job-id "$2" --data-dir "$1" --timeout "$TIMEOUT" "${extra[@]}"
}

RDATA="$work/retention"
retention_fixtures "$RDATA" 5
run_into "$RDATA" job-new 3 >/dev/null
python3 - "$RDATA" <<'PY'
import json, os, sys
data = sys.argv[1]
jobs = os.path.join(data, "jobs")
kept = {name for name in os.listdir(jobs)}
assert "job-new" in kept, kept
assert "job-fin-4" in kept and "job-fin-5" in kept, kept
for old in ("job-fin-1", "job-fin-2", "job-fin-3"):
    assert old not in kept, kept
# Unfinished work is not a successor and never a candidate: a failed or
# interrupted dictation is kept until the user deletes it.
assert "job-broken" in kept and "job-failed" in kept, kept
record = json.load(open(os.path.join(data, "retention.json")))
assert sorted(record["removed"]) == ["job-fin-1", "job-fin-2", "job-fin-3"], record
assert record["failures"] == [], record
PY
out=$(python3 "$helper" history --data-dir "$RDATA")
python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["storage"]["jobsCount"] == 5, doc["storage"]
assert doc["storage"]["jobsBytes"] > 0, doc["storage"]
assert sorted(doc["retention"]["removed"]) == ["job-fin-1", "job-fin-2", "job-fin-3"], doc["retention"]
PY
check "jobs directory is private" 700 "$(stat -c %a "$RDATA/jobs")"
check "a job record is private" 600 "$(stat -c %a "$RDATA/jobs/job-new/job.json")"
check "a summary is private" 600 "$(stat -c %a "$RDATA/jobs/job-new/summary.json")"
check "a transcript is private" 600 "$(stat -c %a "$RDATA/jobs/job-new/attempt-1/transcript.txt")"

# A retry names the earlier dictation's recording as its own audio, so retention
# must not remove a job whose audio a kept dictation still plays: doing so would
# take Play and Retry away from a dictation inside the retention window, with no
# failure reported anywhere. The retry is built by the command the panel actually
# runs, so this exercises the record the plugin writes.
SDATA="$work/shared-recording"
python3 - "$SDATA" <<'PY'
import json, os, struct, sys, wave
data = sys.argv[1]
job = os.path.join(data, "jobs", "job-src")
os.makedirs(os.path.join(job, "attempt-1"))
json.dump({"jobId": "job-src", "mode": "record", "startedAt": 1000,
           "recording": os.path.join(job, "recording.wav")},
          open(os.path.join(job, "job.json"), "w"))
json.dump({"outcome": "ok", "severity": "ok", "message": "done", "copyable": True},
          open(os.path.join(job, "summary.json"), "w"))
open(os.path.join(job, "attempt-1", "transcript.txt"), "w").write("kept text\n")
with wave.open(os.path.join(job, "recording.wav"), "wb") as handle:
    handle.setnchannels(1)
    handle.setsampwidth(2)
    handle.setframerate(16000)
    handle.writeframes(struct.pack("<16000h", *([0] * 16000)))
PY
python3 "$helper" run --engine "$engine" --model "$MODEL" --threads "$THREADS" \
    --wav "$SDATA/jobs/job-src/recording.wav" --job-id job-retry --data-dir "$SDATA" \
    --timeout "$TIMEOUT" --retries-of job-src >/dev/null
out=$(python3 "$helper" history --data-dir "$SDATA")
python3 - "$out" "$SDATA/jobs/job-src/recording.wav" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
entry = next(item for item in doc["jobs"] if item["id"] == "job-retry")
# Precondition: the retry plays the source dictation's own file. If that stops
# holding, the guard below is no longer testing what it claims to.
assert entry["recordingPath"] == sys.argv[2], entry
PY
run_into "$SDATA" job-third 2 >/dev/null
check "retention keeps the audio a kept dictation still plays" True \
  "$([[ -f "$SDATA/jobs/job-src/recording.wav" ]] && echo True || echo False)"
out=$(python3 "$helper" history --data-dir "$SDATA")
python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
entry = next(item for item in doc["jobs"] if item["id"] == "job-retry")
assert entry["recordingUsable"] is True and entry["recordingMessage"] == "", entry
assert doc["retention"]["removed"] == [], doc["retention"]
PY

# The same guard on the manual path: a clear that keeps a dictation keeps the
# recording that dictation names, even though it lives in another job's directory.
python3 "$helper" clear --data-dir "$SDATA" --keep job-retry >/dev/null
check "clearing keeps the recording of the job it kept" True \
  "$([[ -f "$SDATA/jobs/job-src/recording.wav" ]] && echo True || echo False)"
check "clearing removes the dictation nothing needs" False \
  "$([[ -d "$SDATA/jobs/job-third" ]] && echo True || echo False)"

# The pruning report describes the jobs the last pruning acted on, so clearing
# those jobs has to drop it: a failure line must not name paths that are gone.
PDATA="$work/clear-report"
retention_fixtures "$PDATA" 2
run_into "$PDATA" job-prune 1 >/dev/null
check "the fixture left a pruning report" True "$([[ -f "$PDATA/retention.json" ]] && echo True || echo False)"
python3 "$helper" clear --data-dir "$PDATA" >/dev/null
check "clearing drops the pruning report" False "$([[ -f "$PDATA/retention.json" ]] && echo True || echo False)"

# A successor whose own result never reached the disk has replaced nothing, so it
# must not delete the older audio it was going to make room for.
CDATA="$work/commit-failure"
retention_fixtures "$CDATA" 2
mkdir -p "$CDATA/jobs/job-commit/summary.json"
run_into "$CDATA" job-commit 1 >/dev/null || true
check "a failed commit removes nothing" True \
  "$([[ -d "$CDATA/jobs/job-fin-1" && -d "$CDATA/jobs/job-fin-2" ]] && echo True || echo False)"
check "a failed commit records no pruning" False "$([[ -f "$CDATA/retention.json" ]] && echo True || echo False)"

# Deleting a recording keeps the transcript and the attempts, and never reaches an
# imported file or the dictation a retry read from.
DDATA="$work/deleting"
python3 - "$DDATA" <<'PY'
import json, os, sys
jobs = os.path.join(sys.argv[1], "jobs")
def base(name, started, extra):
    job = os.path.join(jobs, name)
    os.makedirs(os.path.join(job, "attempt-1"))
    open(os.path.join(job, "attempt-1", "transcript.txt"), "w").write("text %s\n" % name)
    record = {"jobId": name, "mode": "record", "startedAt": started}
    record.update(extra(job))
    json.dump(record, open(os.path.join(job, "job.json"), "w"))
    json.dump({"outcome": "ok", "severity": "ok", "message": "done", "copyable": True},
              open(os.path.join(job, "summary.json"), "w"))
def recorded(job):
    path = os.path.join(job, "recording.wav")
    open(path, "wb").write(b"RIFF0000WAVE")
    return {"recording": path}
base("job-recorded", 3000, recorded)
base("job-imported", 2000, lambda job: {})
base("job-retried", 1000, lambda job: {"recording": os.path.join(jobs, "job-recorded", "recording.wav")})
PY
out=$(python3 "$helper" delete --what recording --job-id job-imported --data-dir "$DDATA" || true)
check "an imported dictation owns no recording" not_owned "$(printf '%s' "$out" | field outcome)"
check "the imported dictation is untouched" True "$([[ -f "$DDATA/jobs/job-imported/job.json" ]] && echo True || echo False)"
out=$(python3 "$helper" delete --what recording --job-id job-retried --data-dir "$DDATA" || true)
check "a retry does not delete the recording it read" not_owned "$(printf '%s' "$out" | field outcome)"
check "the retried recording survives" True "$([[ -f "$DDATA/jobs/job-recorded/recording.wav" ]] && echo True || echo False)"
out=$(python3 "$helper" delete --what recording --job-id job-recorded --data-dir "$DDATA")
check "delete recording outcome" ok "$(printf '%s' "$out" | field outcome)"
check "the recording is gone" False "$([[ -e "$DDATA/jobs/job-recorded/recording.wav" ]] && echo True || echo False)"
check "the transcript is kept" True "$([[ -f "$DDATA/jobs/job-recorded/attempt-1/transcript.txt" ]] && echo True || echo False)"
check "the summary is kept" True "$([[ -f "$DDATA/jobs/job-recorded/summary.json" ]] && echo True || echo False)"
out=$(python3 "$helper" history --data-dir "$DDATA")
python3 - "$out" <<'PY'
import json, sys
entry = next(item for item in json.loads(sys.argv[1])["jobs"] if item["id"] == "job-recorded")
# The row survives with its text, and playback and Retry are refused by the same
# missing-audio check the panel reads; nothing has to remember the deletion.
assert entry["state"] == "complete" and entry["outcome"] == "ok", entry
assert entry["recordingUsable"] is False, entry
assert entry["transcriptPath"].endswith("transcript.txt"), entry
assert "no longer" in entry["recordingMessage"] or "not" in entry["recordingMessage"], entry
PY
out=$(python3 "$helper" delete --what dictation --job-id job-recorded --data-dir "$DDATA")
check "delete dictation outcome" ok "$(printf '%s' "$out" | field outcome)"
check "the dictation is gone" False "$([[ -e "$DDATA/jobs/job-recorded" ]] && echo True || echo False)"

# A crafted name, an out-of-tree link and a link inside a job are all refused: no
# path this plugin did not write is ever removed.
SDATA="$work/owned-data"
outside="$work/outside"
mkdir -p "$SDATA/jobs" "$outside/jobs"
printf 'precious\n' >"$outside/jobs/precious.txt"
ln -s "$outside/jobs" "$SDATA/jobs/job-escape"
python3 - "$SDATA" "$outside" <<'PY'
import json, os, sys
data, outside = sys.argv[1], sys.argv[2]
job = os.path.join(data, "jobs", "job-linked")
os.makedirs(job)
json.dump({"jobId": "job-linked", "mode": "record", "startedAt": 1000},
          open(os.path.join(job, "job.json"), "w"))
os.symlink(os.path.join(outside, "jobs", "precious.txt"), os.path.join(job, "sneak"))
PY
for name in "../escape" "sub/job" ""; do
  out=$(python3 "$helper" delete --what dictation --job-id "$name" --data-dir "$SDATA" || true)
  check "a name this plugin did not write is refused ($name)" not_owned "$(printf '%s' "$out" | field outcome)"
done
out=$(python3 "$helper" delete --what dictation --job-id job-escape --data-dir "$SDATA" || true)
check "a linked job directory is refused" not_owned "$(printf '%s' "$out" | field outcome)"
check "files outside the data directory survive" True "$([[ -f "$outside/jobs/precious.txt" ]] && echo True || echo False)"
out=$(python3 "$helper" delete --what dictation --job-id job-linked --data-dir "$SDATA")
check "deleting a linked job succeeds" ok "$(printf '%s' "$out" | field outcome)"
check "a link inside a job does not reach through" True "$([[ -f "$outside/jobs/precious.txt" ]] && echo True || echo False)"
check "the link itself is gone" False "$([[ -e "$SDATA/jobs/job-linked/sneak" ]] && echo True || echo False)"

# Clear removes what this plugin owns and explicitly keeps live work: the running
# helper and the job the controller names are both left alone.
KDATA="$work/clearing"
mkdir -p "$KDATA/jobs" "$KDATA/jobs/job-a" "$KDATA/jobs/job-b" "$KDATA/jobs/job-c"
printf 'job-b\n' >"$KDATA/current-job"
python3 - "$KDATA" <<'PY'
import json, os, sys
for index, name in enumerate(("job-a", "job-b", "job-c"), start=1):
    json.dump({"jobId": name, "mode": "record", "startedAt": index * 1000},
              open(os.path.join(sys.argv[1], "jobs", name, "job.json"), "w"))
PY
out=$(python3 "$helper" clear --data-dir "$KDATA" --keep job-c)
check "clear outcome" cleared "$(printf '%s' "$out" | field outcome)"
check "clear removed the idle dictation" False "$([[ -d "$KDATA/jobs/job-a" ]] && echo True || echo False)"
check "clear kept the claimed dictation" True "$([[ -d "$KDATA/jobs/job-b" ]] && echo True || echo False)"
check "clear kept the named dictation" True "$([[ -d "$KDATA/jobs/job-c" ]] && echo True || echo False)"
python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert doc["removed"] == ["job-a"], doc
assert sorted(doc["kept"]) == ["job-b", "job-c"], doc
PY
python3 -c 'import time; time.sleep(30)' --job-id job-live-clear &
live_pid=$!
mkdir -p "$KDATA/jobs/job-live-clear"
sleep 0.5
out=$(python3 "$helper" clear --data-dir "$KDATA")
check "clear keeps a running helper's own job" True "$([[ -d "$KDATA/jobs/job-live-clear" ]] && echo True || echo False)"
python3 - "$out" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
assert "job-live-clear" in doc["kept"], doc
assert doc["removed"] == ["job-c"], doc
PY
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true

# A removal that could not finish leaves the dictation listed, so a partial
# deletion stays visible and can be retried instead of silently vanishing.
if [[ "$(id -u)" != "0" ]]; then
  PDATA="$work/partial"
  mkdir -p "$PDATA/jobs/job-partial/attempt-1"
  printf 'text\n' >"$PDATA/jobs/job-partial/attempt-1/transcript.txt"
  printf '{"jobId":"job-partial","startedAt":1000}\n' >"$PDATA/jobs/job-partial/job.json"
  chmod 000 "$PDATA/jobs/job-partial/attempt-1"
  out=$(python3 "$helper" delete --what dictation --job-id job-partial --data-dir "$PDATA" || true)
  chmod 700 "$PDATA/jobs/job-partial/attempt-1"
  check "a partial delete is reported" delete_partial "$(printf '%s' "$out" | field outcome)"
  check "a partial delete names what survived" True \
    "$(grep -q 'attempt-1' <<<"$(printf '%s' "$out" | field message)" && echo True || echo False)"
  check "the surviving file is still there" True "$([[ -f "$PDATA/jobs/job-partial/attempt-1/transcript.txt" ]] && echo True || echo False)"
  check "the partial dictation stays listed" True \
    "$(python3 "$helper" history --data-dir "$PDATA" | grep -q job-partial && echo True || echo False)"
else
  echo "note: running as root; the permission-denied deletion check was skipped"
fi

# Diagnostics are opt-in, bounded and redacted: the export contains this plugin's
# own metadata, never speech, transcript text, raw recognition output or the
# paths of the files the user chose.
XDATA="$work/diagnostics"
python3 - "$XDATA" <<'PY'
import json, os, sys
root = sys.argv[1]
secret = "SENTINEL-SPEECH-9f3a"
job = os.path.join(root, "jobs", "job-secret")
os.makedirs(os.path.join(job, "attempt-1"))
open(os.path.join(job, "recording.wav"), "wb").write(b"RIFFsecret")
json.dump({"jobId": "job-secret", "mode": "record", "startedAt": 1234,
           "recording": os.path.join(job, "recording.wav"),
           "engine": "/home/someone/PRIVATE-PATH-4b7c/engine",
           "model": "/home/someone/PRIVATE-PATH-4b7c/model.gguf"},
          open(os.path.join(job, "job.json"), "w"))
open(os.path.join(job, "attempt-1", "transcript.txt"), "w").write(secret + "\n")
open(os.path.join(job, "attempt-1", "engine.jsonl"), "w").write(json.dumps({"text": secret}) + "\n")
open(os.path.join(job, "attempt-1", "engine.log"), "w").write("log " + secret + "\n")
# The panel keeps the engine's own output on a failure; the export must not.
json.dump({"outcome": "nonzero_exit", "severity": "error",
           "diagnosticMessage": "The engine exited with status 1 before producing a result.",
           "message": "The engine exited with status 1 before producing a result. Engine output: " + secret,
           "copyable": False},
          open(os.path.join(job, "summary.json"), "w"))
# A job written before the engine's half was kept apart still has it inside its
# message, so an old error is reported without any message at all.
old = os.path.join(root, "jobs", "job-old-error")
os.makedirs(old)
json.dump({"jobId": "job-old-error", "mode": "import", "startedAt": 1234},
          open(os.path.join(old, "job.json"), "w"))
json.dump({"outcome": "per_file_error", "severity": "error",
           "message": "The engine reported: " + secret, "copyable": False},
          open(os.path.join(old, "summary.json"), "w"))
PY
out=$(python3 "$helper" export-diagnostics --data-dir "$XDATA" --out "$work/none.json" || true)
check "an export before the preview is refused" no_preview "$(printf '%s' "$out" | field outcome)"
check "a refused export writes nothing" False "$([[ -e "$work/none.json" ]] && echo True || echo False)"
out=$(python3 "$helper" diagnostics --data-dir "$XDATA" --retention 5)
check "diagnostics outcome" ok "$(printf '%s' "$out" | field outcome)"
preview=$(printf '%s' "$out" | field previewPath)
digest=$(printf '%s' "$out" | field sha256)
check "the preview is written" True "$([[ -f "$preview" ]] && echo True || echo False)"
check "the preview is private" 600 "$(stat -c %a "$preview")"
for sentinel in "SENTINEL-SPEECH-9f3a" "PRIVATE-PATH-4b7c"; do
  check "diagnostics omit $sentinel" False "$(grep -q "$sentinel" "$preview" && echo True || echo False)"
done
python3 - "$preview" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
assert doc["format"] == "magus/dictation-diagnostics" and doc["version"] == 1, doc
entries = {entry["id"]: entry for entry in doc["jobs"]}
entry = entries["job-secret"]
# The plugin's own sentence survives; the engine's half of the same message is cut.
assert entry["message"] == "The engine exited with status 1 before producing a result.", entry
assert entry["transcriptChars"] == len("SENTINEL-SPEECH-9f3a") + 1, entry
assert entry["recordingBytes"] == len(b"RIFFsecret"), entry
assert entries["job-old-error"]["message"] == "", entries["job-old-error"]
assert doc["storage"]["jobsCount"] == 2, doc["storage"]
for phrase in ("audio recordings", "transcripts and transcript previews", "raw recognition logs", "environment variables"):
    assert phrase in doc["excluded"], doc["excluded"]
PY

# The export addresses the bytes that were reviewed: a preview that changed
# after the review is refused rather than exported in its place.
check "a changed preview is not exported" preview_changed \
  "$(python3 "$helper" export-diagnostics --data-dir "$XDATA" --out "$work/changed.json" --expect-hash 0000 | field outcome)"
check "a refused changed export writes nothing" False "$([[ -e "$work/changed.json" ]] && echo True || echo False)"

# The export is the preview: same bytes, a private file, and a destination
# directory whose own permissions are never changed.
mkdir -p "$work/exports"
chmod 755 "$work/exports"
out=$(python3 "$helper" export-diagnostics --data-dir "$XDATA" --out "$work/exports/diagnostics.json" --expect-hash "$digest")
check "export outcome" ok "$(printf '%s' "$out" | field outcome)"
check "the export is the reviewed preview" "" "$(cmp "$preview" "$work/exports/diagnostics.json" 2>&1 || true)"
check "the export file is private" 600 "$(stat -c %a "$work/exports/diagnostics.json")"
check "the export leaves its directory alone" 755 "$(stat -c %a "$work/exports")"
check "the export reports the bytes it wrote" "$(stat -c %s "$work/exports/diagnostics.json")" "$(printf '%s' "$out" | field bytes)"
check "the export reports the hash of those bytes" \
  "$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$work/exports/diagnostics.json")" \
  "$(printf '%s' "$out" | field sha256)"

# With no destination named the export picks one in the user's home and still
# leaves that directory's permissions untouched.
mkdir -p "$work/home/Downloads"
chmod 755 "$work/home/Downloads"
out=$(HOME="$work/home" python3 "$helper" export-diagnostics --data-dir "$XDATA")
check "the default export uses Downloads" "$work/home/Downloads" "$(dirname "$(printf '%s' "$out" | field exportPath)")"
check "the default destination keeps its permissions" 755 "$(stat -c %a "$work/home/Downloads")"

# A text export is a faithful copy of the saved transcript and pastes nothing.
out=$(python3 "$helper" export-text --data-dir "$XDATA" \
  --transcript "$XDATA/jobs/job-secret/attempt-1/transcript.txt" --out "$work/exports/text.txt")
check "text export outcome" ok "$(printf '%s' "$out" | field outcome)"
check "text export is faithful" "" \
  "$(cmp "$XDATA/jobs/job-secret/attempt-1/transcript.txt" "$work/exports/text.txt" 2>&1 || true)"
check "text export is private" 600 "$(stat -c %a "$work/exports/text.txt")"
check "text export pastes nothing" True "$(grep -q 'Nothing was pasted' <<<"$(printf '%s' "$out" | field message)" && echo True || echo False)"
out=$(python3 "$helper" export-text --data-dir "$XDATA" --transcript "$work/good.wav" --out "$work/exports/escape.txt" || true)
check "a transcript outside the data directory is refused" not_owned "$(printf '%s' "$out" | field outcome)"
ln -s "$outside/jobs/precious.txt" "$XDATA/jobs/job-secret/attempt-1/link.txt"
out=$(python3 "$helper" export-text --data-dir "$XDATA" \
  --transcript "$XDATA/jobs/job-secret/attempt-1/link.txt" --out "$work/exports/link.txt" || true)
check "a linked transcript is refused" not_owned "$(printf '%s' "$out" | field outcome)"
check "nothing was written for a refused transcript" False "$([[ -e "$work/exports/escape.txt" || -e "$work/exports/link.txt" ]] && echo True || echo False)"

# The controller drives this helper, so the options and subcommands it passes
# must be the ones the helper actually defines. Without this, the two sides can
# drift apart and their separate checks still pass.
python3 - "$helper" controller.luau <<'PY'
import re, subprocess, sys

helper, controller = sys.argv[1], sys.argv[2]
top = subprocess.run(["python3", helper, "--help"], stdout=subprocess.PIPE).stdout.decode()
listed = re.search(r"\{([a-z0-9,\-]+)\}", top)
commands = set(listed.group(1).split(",")) if listed else set()
assert commands, "helper defines no subcommands: %r" % top
defined = set()
for command in sorted(commands):
    usage = subprocess.run(["python3", helper, command, "--help"], stdout=subprocess.PIPE).stdout.decode()
    defined.update(re.findall(r"--[a-z][a-z-]*", usage))
source = open(controller).read()
passed = set(re.findall(r'"(--[a-z][a-z-]*)"', source))
ran = set(re.findall(r'HELPER,\s*"([a-z-]+)"', source)) | set(re.findall(r'runHelperMaintenance\("([a-z-]+)"', source))
assert ran, "no helper command found in controller.luau"
unknown = sorted(ran - commands)
assert not unknown, "controller runs unknown helper commands: %r" % unknown
assert {"record", "sources", "run", "play", "history", "delete", "clear", "diagnostics"} <= ran, sorted(ran)
missing = sorted(passed - defined)
assert not missing, "controller passes options the helper does not define: %r" % missing
assert passed, "no helper option found in controller.luau"
PY

# Recording must never paste on its own and delivery is one mechanism in one place:
# the controller copies the finished transcript and sends the ordinary paste chord
# from there, nothing anywhere types the speech as keystrokes or presses Return,
# and only the panel's explicit Copy button touches the clipboard besides delivery.
check "helper pastes nothing" False \
  "$(grep -qE 'wl-copy|xclip|xsel|wl-paste|wtype|ydotool|dotool' "$helper" && echo True || echo False)"
check "controller copies for delivery once" 1 "$(grep -c 'copyToClipboard' controller.luau)"
check "controller injects keys in one place" 1 "$(grep -c 'runAsync(PASTE_CHORD' controller.luau)"
check "delivery's one mechanism is the compositor" 1 \
  "$(grep -c 'local PASTE_TOOL = "hyprctl"' controller.luau)"
check "delivery sends the ordinary paste chord" 1 \
  "$(grep -c 'PASTE_CHORD = { PASTE_TOOL, "dispatch", "sendshortcut", "CTRL,V," }' controller.luau)"
for entry in controller widget panel; do
  check "$entry sends no Return" False "$(grep -qE '\bReturn\b|KP_Enter|"Enter"' "$entry.luau" && echo True || echo False)"
done
check "widget touches no clipboard" False "$(grep -q 'copyToClipboard' widget.luau && echo True || echo False)"
check "panel copy is explicit" True "$(grep -q 'copyToClipboard' panel.luau && echo True || echo False)"

# The catalog row and the package manifest are read together: Noctalia offers an
# update while the catalog version differs from the materialized manifest's, so a
# version that drifts between them leaves the update offered forever. The package
# shape the catalog convention asks for is checked here because nothing else reads
# the manifest or the thumbnail.
python3 - <<'PY'
import os, sys, tomllib


def eq(name, expected, actual):
    if expected != actual:
        sys.exit("FAIL: %s: expected %r got %r" % (name, expected, actual))


def true(name, value):
    eq(name, True, bool(value))


def read(name):
    if not os.path.isfile(name):
        sys.exit("FAIL: %s is missing" % name)
    with open(name, "rb") as handle:
        return handle.read()


manifest = tomllib.loads(read("plugin.toml").decode("utf-8"))
rows = tomllib.loads(read("../catalog.toml").decode("utf-8"))["plugin"]
row = [entry for entry in rows if entry["id"] == manifest["id"]]
if len(row) != 1:
    sys.exit("FAIL: catalog rows for %s: expected [1] got [%d]" % (manifest["id"], len(row)))
row = row[0]

for field in ("name", "version", "plugin_api", "dependencies"):
    eq("catalog %s" % field, manifest[field], row[field])
eq("version is MAJOR.MINOR.PATCH", 3, len(manifest["version"].split(".")))
true("license is declared", manifest["license"])
true("updated_at is not older than added_at", row["updated_at"] >= row["added_at"])
for kind in ("service", "panel", "widget"):
    for entry in manifest[kind]:
        true("%s entry %s exists" % (kind, entry["entry"]), os.path.isfile(entry["entry"]))
true("translations are shipped", os.path.isfile("translations/en.json"))
thumb = read("thumbnail.webp")
eq("thumbnail container", b"RIFF", thumb[:4])
eq("thumbnail type", b"WEBP", thumb[8:12])
true("thumbnail is not a stub", len(thumb) > 4096)
PY

if command -v luau-compile >/dev/null 2>&1; then
  for script in ./*.luau; do
    luau-compile --binary "$script" >/dev/null || { echo "FAIL: $script does not compile" >&2; exit 1; }
  done
else
  echo "note: luau-compile not on PATH; Luau entry scripts were not compiled"
fi

echo "selftest ok"
