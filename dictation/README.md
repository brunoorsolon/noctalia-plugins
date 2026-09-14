# Dictation

A Noctalia plugin that transcribes a saved recording with an engine you already installed.

The plugin owns the native interface and the settings; `dictation-helper.py` owns the recognition job. You pick an installed `transcribe-cli` executable and a GGUF model, import a 16 kHz mono WAV, and read or copy the finished transcript. The engine is used exactly as installed: the plugin never rebuilds it, downloads anything, or patches its source.

## Plugin

| Field | Value |
| --- | --- |
| ID | `magus/dictation` |
| Entries | Service: `controller`, Panel: `panel`, Widget: `widget` |
| Minimum plugin API | 24 |

The service is the only owner of a job, so closing the panel or the bar widget never interrupts recognition. The panel and the bar widget are thin views of the state the service publishes.

## Requirements

- `python3` (standard library only — the bundled helper has no third-party imports).
- An installed recognition engine from [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), such as `transcribe-cli`.
- A GGUF model the engine can load.
- A recording already saved as 16 kHz mono signed-16-bit WAV.

## Installation

Open **Settings → Plugins**, select **Add source**, and add this Git source:

| Field | Value |
| --- | --- |
| Name | `magus` |
| Kind | Git |
| Location | `https://github.com/brunoorsolon/noctalia-plugins.git` |

Enable **Dictation** after it appears, then add the `magus/dictation:widget` bar widget if you want a status glyph. The equivalent commands are:

```sh
noctalia msg plugins source add magus git https://github.com/brunoorsolon/noctalia-plugins.git
noctalia msg plugins enable magus/dictation
```

## Setup

1. Open **Settings → Plugins → Dictation** (the gear on the plugin's row).
2. Set **Recognition executable** to the installed engine, for example `/usr/local/bin/transcribe-cli`. It is run as it is.
3. Set **Model GGUF** to the model file the engine should load.
4. Set **Recording to transcribe** to the WAV you want transcribed.
5. Set **Inference threads**. The default of 4 is passed to the engine, and `OMP_NUM_THREADS` and `OPENBLAS_NUM_THREADS` follow it.
6. Press **Verify and record** in the panel (or open the panel from the bar widget). Verification runs the executable's `--help`, checks that the flags this plugin needs are accepted, hashes the executable and the model, and writes the result to `setup.json`. Nothing is rebuilt or downloaded; the recorded hashes only describe the files you selected.

A relative path resolves against Noctalia's working directory, so use an absolute path or a `~` path. Settings changes take effect on the next job; a running job keeps the arguments it started with.

Verification is a record, not a lock: **Transcribe** stays available while setup is unverified or stale, and the helper re-checks the engine's flags on every run. The recorded paths, hashes and sizes describe the files you verified: if either file moves or changes size, the banner asks you to verify again instead of claiming the old record. Nothing is repaired silently — an engine that cannot load the model fails with the engine's own reason in the outcome, and no executable, model or source file is ever replaced, rebuilt, or downloaded.

## Usage

Open the panel from the bar widget glyph or with:

```sh
noctalia msg panel-toggle magus/dictation:panel
```

- **Transcribe** imports the selected recording as one job. Only one job runs at a time, and the buttons stay responsive while it runs — the elapsed time keeps counting.
- The plugin writes the id of the running job to disk and reads it back when it starts, so reloading or updating the plugin adopts the job that is already running instead of forgetting it: **Cancel** keeps addressing that job, and another import is refused until it ends.
- The helper rewrites a heartbeat while it runs. If it stops reporting for a minute — a crash, a killed process, a full disk — the panel says contact was lost and keeps the job owned, so **Cancel** still reaches it and another import is refused. The job is released once the helper reports, or once no process for that job is left running; its files stay in the plugin data directory.
- **Cancel** asks the helper to stop the engine this job started. If no engine has started yet, the cancel is honoured anyway instead of being discarded. Only this plugin's own process is stopped.
- The transcript appears in a selectable multiline field once the engine has returned text. Text is shown even when the outcome is an error or a review, so a partial result is readable; only a usable transcript enables **Copy transcript**.
- **Copy transcript** copies the text that is shown. Nothing is pasted automatically: put the text where you want it yourself.
- **Verify and record** repeats setup verification and re-hashes the files, for example after replacing the model.

## Where the files go

Everything is under the plugin data directory, normally `~/.local/state/noctalia/plugins/materialized/magus/dictation/`:

```
setup.json                                  recorded setup: paths, sizes, hashes, engine flags
setup-summary.json                          outcome of the last verification
current-job                                 the job this plugin currently owns
jobs/<jobId>.cancel                         cancellation request, while a job is running
jobs/<jobId>/heartbeat.json                 rewritten while the helper runs, so lost contact is noticed
jobs/<jobId>/summary.json                   outcome the panel reads
jobs/<jobId>/attempt-1/argv.json            the exact argument vector, as a list
jobs/<jobId>/attempt-1/input-list.txt       the engine's --batch input list
jobs/<jobId>/attempt-1/engine.jsonl         raw engine output, exactly as written
jobs/<jobId>/attempt-1/engine.log           engine standard error
jobs/<jobId>/attempt-1/transcript.txt       the transcript
jobs/<jobId>/attempt-1/result.json          the full outcome record
```

Job directories and their files are private to your user (directory `0700`, files `0600`). Re-running an existing job id writes `attempt-2`, and so on; earlier attempts are kept. The imported recording and every file shipped by this plugin are only ever read, never written.

## Outcomes

Each job ends in exactly one outcome. The plugin never reports success for text it did not receive, and partial text is kept whenever the engine produced any.

| Outcome | Meaning |
| --- | --- |
| `ok` | A usable transcript was produced. |
| `truncated` | The engine's result said the audio was truncated. The partial text is kept. |
| `unknown_token` | The transcript contains a control token such as `<\|endoftext\|>`. The text is kept for review. |
| `empty` | The engine completed but produced no text. |
| `malformed_row` | The engine's JSONL output could not be parsed, or a result field was not a string. |
| `missing_result` | The engine wrote no result row. |
| `per_file_error` | The engine reported a per-file error. |
| `nonzero_exit` | The engine exited with a nonzero status and no result. |
| `timeout` | The 30-minute inference watchdog stopped the engine. |
| `cancelled` | You asked for the job to stop. |
| `invalid_wav` | The recording is missing or is not 16 kHz mono signed-16-bit WAV. |
| `engine_incompatible` | The selected executable does not accept the flags this plugin needs. |
| `engine_unavailable` | The engine could not be started, or running it to check its flags failed. |
| `setup_required` | The executable or the model is missing or not executable. |
| `invalid_threads` | The thread count is outside 1–64. |
| `internal` | The helper failed, the plugin could not start it, or it stopped reporting. |

Nothing is repaired automatically: an incompatible engine or a malformed recording is reported as it is, with the class of problem named. A failed run also carries the last lines the engine wrote to standard error, so a model the engine cannot load is reported with the engine's own reason rather than a bare exit status.

## How the engine is called

Inference runs with explicit CPU arguments and an argument vector — never a shell string, so no path is ever split or expanded by a shell:

```
<python3> dictation-helper.py run --engine … --model … --threads 4 --wav … --job-id … --data-dir …

transcribe-cli --backend cpu --threads 4 --timestamps none -m MODEL --batch input-list.txt --batch-size 1 --batch-jsonl
```

The engine runs with `OMP_NUM_THREADS` and `OPENBLAS_NUM_THREADS` set to the thread count and with niceness 10, so it yields to interactive work. On the first run against a new executable, the helper checks the `--help` output for every flag above and refuses to guess when one is missing.

The helper keeps the 30-minute watchdog, not Noctalia: a captured-process callback is capped far below a long inference, so the helper is launched detached and reports its outcome through `summary.json` instead. The engine is tied to the helper's lifetime, so a helper killed outright takes the engine with it instead of leaving inference running behind a lost job.

## When something looks wrong

- **"Setup required"** names the missing piece: the executable, the model, `python3`, or the data directory.
- **`engine_incompatible`** means the executable rejected one of the flags. Check that the version you selected supports `--batch-jsonl`.
- **`invalid_wav`** means the recording is not 16 kHz mono signed-16 WAV. Convert it first, for example with `ffmpeg -i in.wav -ar 16000 -ac 1 -c:a pcm_s16le out.wav`. This plugin does not transcode.
- A stuck job can be stopped with **Cancel**; the engine only sees a signal from the process the helper started.

## Known limits

- Recognition only. Recording audio and pasting the result into the focused window are later work; nothing is pasted for you.
- CPU only: the engine is always called with `--backend cpu`.
- One job at a time, and no queue.
- Adopting the running job after a reload restarts its elapsed timer, because the plugin's clock does not survive a reload. The job id, its files and **Cancel** are unaffected.
- Only 16 kHz mono signed-16-bit WAV is accepted, and no resampling is attempted.
- Stale setup detection compares each recorded file's path and size, so a replacement that keeps the same size is only reported by the run that fails on it.

## Checks

Run the behavior check from this directory:

```sh
./selftest.sh
```

It uses a fake engine and generated WAV fixtures to check the argument vector, thread limits and niceness, the helper's outcomes (including `engine_unavailable` and `internal`), the log excerpt a failing run carries, the watchdog, cancellation before and during a job, file permissions, the heartbeat it rewrites while the engine runs, result rows whose fields have the wrong type, and that the imported recording is left untouched. If `luau-compile` is on `PATH` it also compiles every entry script.

The controller, panel and widget are exercised through a disposable Luau harness with a stubbed `noctalia`/`ui` API during development: one-job-at-a-time, cancel routing, copy gating, adopting the running job after a reload, keeping the job owned when a helper stops reporting, refusing storage it cannot write, and the widget glyph per state. That harness is scratch tooling and is not part of this repository, so `./selftest.sh` alone only compiles those three files.

## Updating the plugin

Noctalia updates enabled Git sources automatically by default. To update immediately:

```sh
noctalia msg plugins update magus
```
