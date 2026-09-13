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
    --job-id "$1" --data-dir "$data" --timeout "$TIMEOUT"
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
(( $(date +%s) - start < 30 )) || { echo "FAIL: watchdog did not stop the engine promptly" >&2; exit 1; }

# A cancel that arrives before any engine work is honoured instead of discarded.
mkdir -p "$data/jobs"
printf 1 >"$data/jobs/job-early-cancel.cancel"
RECORD=; MODE=ok helper_run job-early-cancel >"$work/early-cancel.json"
check "early cancel cleared" False "$([[ -f "$data/jobs/job-early-cancel.cancel" ]] && echo True || echo False)"
check "early cancel outcome" cancelled "$(field outcome <"$work/early-cancel.json")"
check "early cancel ran no engine" False "$([[ -d "$data/jobs/job-early-cancel/attempt-1" ]] && echo True || echo False)"

# Cancel stops the owned engine and only that work.
MODE=slow TIMEOUT=60 helper_run job-cancel >"$work/cancel.json" &
pid=$!
for _ in $(seq 1 100); do [[ -f "$data/jobs/job-cancel/attempt-1/engine.jsonl" ]] && break; sleep 0.1; done
sleep 0.5
printf 1 >"$data/jobs/job-cancel.cancel"
wait "$pid"
check "cancel outcome" cancelled "$(field outcome <"$work/cancel.json")"
check "cancel copyable" False "$(field copyable <"$work/cancel.json")"
check "cancel summary persisted" cancelled "$(field outcome <"$data/jobs/job-cancel/summary.json")"

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
check "transcript private" 600 "$(stat -c '%a' "$data/jobs/job-persist/attempt-1/transcript.txt")"
check "raw jsonl private" 600 "$(stat -c '%a' "$data/jobs/job-persist/attempt-1/engine.jsonl")"
check "engine log private" 600 "$(stat -c '%a' "$data/jobs/job-persist/attempt-1/engine.log")"
check "attempt dir private" 700 "$(stat -c '%a' "$data/jobs/job-persist/attempt-1")"

# Luau syntax is checked when a compiler is available; the entry scripts are the
# plugin's only untested surface otherwise.
if command -v luau-compile >/dev/null 2>&1; then
  for script in ./*.luau; do
    luau-compile --binary "$script" >/dev/null || { echo "FAIL: $script does not compile" >&2; exit 1; }
  done
else
  echo "note: luau-compile not on PATH; Luau entry scripts were not compiled"
fi

echo "selftest ok"
