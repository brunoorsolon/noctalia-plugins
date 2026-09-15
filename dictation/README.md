# Dictation

A Noctalia plugin that records your microphone and transcribes the recording with an engine you already installed.

The plugin owns the native interface and the settings; `dictation-helper.py` owns the recording and the recognition job. You pick an installed `transcribe-cli` executable and a GGUF model, choose a PipeWire capture source, press **Record**, press **Stop**, and read or copy the finished transcript. The engine is used exactly as installed: the plugin never rebuilds it, downloads anything, or patches its source. A WAV you recorded elsewhere can still be imported and transcribed.

## Plugin

| Field | Value |
| --- | --- |
| ID | `magus/dictation` |
| Entries | Service: `controller`, Panel: `panel`, Widget: `widget` |
| Minimum plugin API | 24 |
| Version | 0.3.0 |

The service is the only owner of a job, so closing the panel or the bar widget never interrupts recording or recognition. The panel and the bar widget are thin views of the state the service publishes.

## Supported host and tested applications

| Component | Supported |
| --- | --- |
| Noctalia | v5 beta with plugin API 24 or newer, including the argument-vector form of `runAsync` |
| Compositor | Hyprland with `hyprctl` and the `sendshortcut` dispatcher; automatic paste and the recording shortcut are Hyprland-only |
| Audio | PipeWire, with `pw-dump`, `pw-record` and `pw-play` |
| Engine | an installed `transcribe-cli` from transcribe.cpp that accepts `--batch` and `--batch-jsonl` |
| Model | a GGUF the engine can load |
| Distribution | Fedora with PipeWire and Hyprland is the target this release is built for; another distribution works when the tools above are present, but nothing else is developed against |

Automatic paste is aimed at the editor and the browser you work in, reached as ordinary clipboard-paste targets and identified by the compositor window class the plugin reads. The plugin ships no per-application list: the first recording into a window class you have not confirmed is held for **Paste now**, and terminals, password managers, an unreadable class and any window other than the one the recording was started from are always held. Nothing is typed as keystrokes, so the application receives its own normal paste of the clipboard the plugin set.

The release-candidate host measurements — the versions of Noctalia, Hyprland, PipeWire and the engine on the machine this is meant for, the two timings (stop-to-ready, stop-to-paste), idle cost and busy RSS — belong to the target-host run recorded on the release pull request, and this document does not assert them. The one historical reference, a single warm-cache run, was 5.42 s of recognition for 117.86 s of audio; treat it as an anecdote, not a promise.

## Requirements

- `python3` (standard library only — the bundled helper has no third-party imports).
- PipeWire tools: `pw-dump` to list capture sources, `pw-record` to capture, `pw-play` to play a recording back. They ship together in `pipewire-bin` (or `pipewire` on some distributions).
- `hyprctl` for automatic paste, for the destination check and for the recording shortcut: the chord is dispatched by the compositor itself (`hyprctl dispatch sendshortcut CTRL,V,`), so no daemon and no input-device access is needed, and `hyprctl` is the same tool this plugin already uses to read the focused window. It is required only for automatic paste and the shortcut setup, and it is listed in the catalog's dependency metadata for that reason — without it, and in manual copy mode, the transcript is still copied when you ask for it, and the shortcut row stays actionable instead of pretending.
- `ps` to read the compositor's command line when the recording shortcut has to find which configuration file Hyprland loaded. The shortcut row stays actionable without it; recording and paste do not use it.
- A capture source (microphone) PipeWire reports as an `Audio/Source`.
- An installed recognition engine from [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp), such as `transcribe-cli`.
- A GGUF model the engine can load.

On Fedora the packages for everything above are:

```sh
sudo dnf install python3 pipewire-utils hyprland
```

`pipewire-utils` provides `pw-dump`, `pw-record` and `pw-play`, and `hyprctl` ships with `hyprland`; on Debian and Ubuntu the PipeWire tools come from `pipewire-bin`. The dependency list is metadata: it names the tools the plugin runs, Noctalia does not install packages from it, and the engine and the model are yours to install. A user who has no engine yet cannot finish setup from this plugin alone.

## Installation

Open **Settings → Plugins**, select **Add source**, and add this Git source:

| Field | Value |
| --- | --- |
| Name | `magus` |
| Kind | Git |
| Location | `https://github.com/brunoorsolon/noctalia-plugins.git` |

Enable **Dictation** after it appears, then add the `magus/dictation:widget` bar widget if you want the status and the controls in the bar. The equivalent commands are:

```sh
noctalia msg plugins source add magus git https://github.com/brunoorsolon/noctalia-plugins.git
noctalia msg plugins enable magus/dictation
```

## Setup

1. Open **Settings → Plugins → Dictation** (the gear on the plugin's row).
2. Set **Recognition executable** to the installed engine, for example `/usr/local/bin/transcribe-cli`. It is run as it is.
3. Set **Model GGUF** to the model file the engine should load.
4. Set **Inference threads**. The default of 4 is passed to the engine, and `OMP_NUM_THREADS` and `OPENBLAS_NUM_THREADS` follow it.
5. Set **Kept dictations**. The default of 10 is how many finished dictations stay on disk; the panel shows what they currently occupy, and the count is clamped to 1–1000. Only finished dictations are ever removed, and only after a newer one has been saved. See **Where the files go**.
6. Press **Verify and record** in the panel (or open the panel from the bar widget's panel button). Verification runs the executable's `--help`, checks that the flags this plugin needs are accepted, hashes the executable and the model, and writes the result to `setup.json`. Verification also tests the paste mechanism itself: `sendshortcut` is dispatched with no chord at all, which a compositor that has the dispatcher answers with its own argument error and which sends nothing. The panel names the mechanism, whether `hyprctl` is installed, and whether the compositor answered that probe. Nothing is rebuilt or downloaded; the recorded hashes only describe the files you selected.
7. Choose the **Microphone** in the panel. The list is read from the PipeWire graph, and the choice is saved next to the plugin's data, so it survives a restart. The choice is a stable node name, so a reconnect keeps the same microphone selected.

Optionally set **Recording to transcribe** if you also want to import a WAV you recorded elsewhere.

A relative settings path resolves against Noctalia's working directory, so use an absolute path or a `~` path. Settings changes take effect on the next job; a running job keeps the arguments it started with.

Verification is a record, not a lock: **Record** and **Transcribe file** stay available while setup is unverified or stale, and the helper re-checks the engine's flags on every job. The recorded paths, hashes and sizes describe the files you verified: if either file moves or changes size, the banner asks you to verify again instead of claiming the old record. Nothing is repaired silently — an engine that cannot load the model fails with the engine's own reason in the outcome, and no executable, model or source file is ever replaced, rebuilt, or downloaded.

## Recording shortcut

The panel's **Recording shortcut** row configures a compositor-global chord for **Toggle**, so a recording starts and stops while another window is focused and no panel opens and takes focus. Setup proposes **Super+Alt+D**, and the row shows what the compositor reports for that chord — free, already held by something else, installed, or unverifiable — before anything is written.

- **Install shortcut** is the only action that writes a binding, and it happens only when you press it. It reads the compositor's live bind table first and refuses when the chord is already bound to something else, naming what holds it: an existing binding is never overwritten. That includes a binding of the same command written by hand — the compositor runs every binding on a chord, so a second copy would toggle twice. The row keeps reporting that as a conflict, even when this setup's own block is also there, rather than calling the chord installed. Pressing it again converges on the same block instead of adding a second one.
- The binding runs the same entry the panel and the bar use, `noctalia msg plugin magus/dictation:controller all toggle`, so a chord press and the Record button drive one controller. No second recorder, shortcut daemon, key grab or device access exists.
- The edit is one delimited block and nothing else, placed at the top of the file — a configuration can end inside a submap, where a bind is not in effect outside it, and a Lua configuration can end in a top-level `return`. In `hyprland.conf` it is a `# magus/dictation:recording-shortcut:begin` / `# magus/dictation:recording-shortcut:end` pair around one `bindd = SUPER ALT, D, …, exec, …` line. In `hyprland.lua` it is the same pair as `--` comments around one `hl.bind("SUPER + ALT + D", hl.dsp.exec_cmd(…), { description = … })` call. Nothing else in the file is touched.
- The file is copied to `<file>.magus-dictation.bak` before every write, and the compositor is reloaded afterwards — under a Lua configuration `hyprctl keyword` cannot add a binding at all, so a reload is the only activation route.
- A reload that answered `ok` is not evidence, so the setup re-reads the bind table and reports **installed** only when the chord is really registered. A block that is on disk but did not register is reported as an error with **Undo shortcut** still offered, and a compositor that never answers bounds the wait instead of leaving the row busy: the setup says nothing was confirmed and offers the recheck.
- **Undo shortcut** removes exactly the delimited block, reloads and re-checks. It never restores the backup over later edits, so bindings and settings you changed after installing are preserved. This is the way to reverse the change; disabling or removing the plugin leaves the block in your configuration, because the file is yours. Once the plugin is gone that leftover chord is a dead key — it runs `noctalia msg plugin magus/dictation:controller all toggle`, and there is no controller left to receive it. To take it out, delete the whole block by hand — the two marked lines *and* the `bindd = …` / `hl.bind(…)` line between them — and reload; or re-enable the plugin and press **Undo shortcut**.
- Which file is used follows Hyprland's own precedence: a `--config` path on the compositor's command line first, then `HYPRLAND_CONFIG` when it is set, otherwise `hyprland.lua` in `$XDG_CONFIG_HOME/hypr` (or `~/.config/hypr`) and then in `$XDG_CONFIG_DIRS`, and `hyprland.conf` in the same order. The command line is read with `ps`, and one it cannot delimit unambiguously — a `--config` with no path, a `--config=path` or `-c=path` form, several Hyprland processes, or tokens left after the path — is refused with its own reason, and the setup writes nothing rather than guessing which file to edit. An explicit path that names a file which does not exist is reported as such, and the row offers no chord, rather than claiming a free chord in a file it cannot write.
- A block you deleted half by hand is neither overwritten nor claimed as removed: writing beside it would add a second binding and stripping it would report a removal that never happened, so the setup names the missing marker and leaves the file alone.

## Usage

Open the panel from the bar widget's panel button (or a right click) or with:

```sh
noctalia msg panel-toggle magus/dictation:panel
```

- **Record** captures the selected microphone with `pw-record` into a private 16 kHz mono signed-16 WAV inside the job's directory. **Stop** finalizes that WAV, validates it, and only then runs recognition on it. **Cancel** stops the microphone without transcribing; the audio captured so far is kept. A **Cancel** that arrives after **Stop**, while the WAV is already being finalized, is honoured as well: the job reports `cancelled` and recognition is not started. A **Stop** or **Cancel** that arrives before the microphone is opened is honoured too, even when it arrives before the helper process itself has started: the request belongs to the job id the controller has just allocated, so the microphone is never opened and the job reports that no audio was captured instead of recording on.
- **Play** plays the saved recording with `pw-play`, and **Retry** transcribes the saved recording again as a new job. Neither one pastes anything: delivery belongs to a recording that this session finished, so an import, a retry, and a job recovered from disk are only copied on request.
- The bar widget and the panel expose the same actions and share the one job: pressing Record in the bar while the panel is open starts exactly one recording, and pressing Stop twice converges on one finalized recording. A second Stop that arrives while the WAV is already being finalized is refused with the reason instead of being sent again. A second Record while a job runs is refused with the reason instead of starting a second recorder.
- The bar names the microphone the recording came from and says whether audio is still being captured: while the WAV is being finalized the microphone glyph becomes a working glyph, **Stop** disappears, and the status the bar shows names the microphone and the phase. That working glyph, the elapsed time and the missing **Stop** continue through recognition, because the microphone is released once the WAV is finalized; pressing the bar's toggle then reports the running job instead of asking the helper to stop a capture that already ended. The microphone choice itself is closed while audio is being captured — the picker is disabled and a change is refused with the reason — because the recorder keeps the microphone it was started with, and the status would otherwise name one the recording does not come from.
- The Record, Stop and Cancel buttons in the bar never open a panel or move focus, so recording from the bar leaves the window you were typing in focused. The panel button, and a right click, open the panel.
- The plugin writes the id of the running job to disk and reads it back when it starts, so reloading or updating the plugin adopts the job that is already running instead of forgetting it: **Cancel** keeps addressing that job, and another job is refused until it ends. A reload does not restart recognition, does not resume a recording, and never delivers text on its own.
- While a recording runs, the controller refreshes a lease file once a second. If Noctalia or the plugin dies, the helper notices the lease going stale and releases the microphone within ten seconds, keeping whatever audio it captured. The job is then reported as `interrupted` and stays on disk, so **Retry** can transcribe it once you are back.
- The last recording stays reachable for **Play** and **Retry** after a restart: the plugin writes its path, and reads the newest recording the job directories still hold when that file is missing or points at nothing. Nothing is resumed, replayed or delivered on its own.
- **Recent dictations** lists the newest jobs the helper finds on disk, each with its time, length, outcome and the first words of the raw transcript, so what happened survives closing the panel, reloading the plugin and restarting the shell. Reading that list is read-only: it never starts a recording, an engine or a paste. A job that was cut off during recording, finalization or inference is listed as **Interrupted** rather than hidden, and a job a helper process still owns is listed as **In progress**.
- Selecting a dictation exposes its whole transcript in its own field, beside **Copy**, **Play** and **Retry**. **Copy** copies the text you see, so the saved file stays as the engine wrote it. **Play** plays that dictation's own recording. **Retry** starts a new job that reads that same saved recording: the original audio, its earlier attempts and their result files are never replaced, and the new job records the engine, model and settings it actually used, plus the dictation it retried, so a later attempt names the recording it came from instead of looking like an unrelated import. Play, Copy and Retry move no focus and start no recording, and a refusal — unusable or missing audio, or another job already running — is reported in the panel as well as in a notification.
- **Delete recording** removes only that dictation's audio. The transcript, its attempts and its result files stay, the row stays in **Recent dictations**, and **Play** and **Retry** stop being offered with the reason shown. **Delete dictation** removes that one job's whole directory — audio, transcript and every attempt — and nothing else. **Export text** writes the selected transcript to a `.txt` file in `~/Downloads` (or your home directory when there is no `Downloads`), `0600` and never overwritten: a name that already exists gets a `-2`, `-3`, … suffix, and the panel names the file it wrote. Nothing is pasted by that export.
- **Clear history** removes every saved dictation except work that is still running. Both it and the two delete actions name what they will remove and wait for a confirmation in the panel; a cancel sends nothing. The helper then decides what is really removable: the id has to be a dictation this plugin owns, its directory has to be inside the plugin's own data directory and not a link, and a recording has to be this job's own `recording.wav`, so a path, a link, a replacement or a whole other file cannot reach an engine, a model, a benchmark file, a home file or a job that is still running. A deletion that could not remove every file reports which paths survived, keeps the dictation listed, and leaves its `job.json` in place so it can be retried instead of vanishing from the history while its files are still on disk.
- The **Diagnostics** row is opt-in. **Open diagnostics** prepares the report and shows it in the panel; **Export diagnostics** stays disabled until that preview exists, then asks for a confirmation. The export copies the previewed bytes unchanged — the preview is rendered as read-only text, so what you read is what the file contains. It carries this plugin's own metadata: the format and version, the storage accounting, the retention setting and the last pruning, and per job its id, mode, start time, state, outcome, severity, this plugin's own message, attempt count, transcript length and recording size. It never carries audio, transcript text, raw recognition output, engine logs, the paths of the files you chose, or environment variables: the engine's own output is where recognised speech and file paths appear, so the part of a failure message that came from the engine is left out of the export even though the panel shows it. The file is written `0600` into `~/Downloads` (or your home directory when there is no `Downloads`) and the panel names the path it used. Nothing is uploaded, and no background request is made.
- The helper rewrites a heartbeat while it runs. If it stops reporting for a minute — a crash, a killed process, a full disk — the panel says contact was lost and keeps the job owned, so **Cancel** still reaches it and another job is refused. The job is released once the helper reports, or once no process for that job is left running; its files stay in the plugin data directory.
- **Cancel** stops only processes this job started: the recorder, with its whole process group, and the engine process the helper launched itself, by its own pid. Nothing is matched by name, and no stale pid is ever signalled. The recorder gets a bounded grace to finish before it is killed, so its WAV usually stays usable; when the recorder has to be killed outright, the audio is still kept and the outcome says whether it is usable.
- Recording has no length limit of its own: it ends when you press **Stop** or **Cancel**, when the recorder exits, or when the controller stops refreshing the lease. A recording that ends any way other than **Stop** is not transcribed on its own.
- Recording is refused before anything is started when less than 20 MB is free, so a full disk cannot destroy an older job's files or leave a truncated recording. A failed write is reported as an error, and earlier jobs are left untouched.
- The transcript appears in a selectable multiline field once the engine has returned text. Text is shown even when the outcome is an error or a review, so a partial result is readable; only a usable transcript enables **Copy transcript**.
- **Copy transcript** copies the text that is shown. **Paste now** copies it and sends the ordinary paste shortcut into the window that is focused when you press it; it is the route for a held transcript and for any other transcript the plugin did not deliver.
- When a recording finishes with a usable transcript, the plugin copies that transcript to the clipboard and sends the ordinary paste shortcut (`Ctrl+V`, dispatched by the compositor) into the window the recording was started from. Nothing is typed as keystrokes, no Return is sent, and no part of the speech is interpolated into a command. The first paste into a window class you have not confirmed is held for **Paste now**, and that confirmation makes later recordings into the same class automatic for the rest of the session. Terminals, password managers, a window whose class cannot be read, and a window that is not the one the recording was started from are always held. Nothing is pasted while the panel itself holds the keyboard or while the destination has changed or closed, and focus is never moved to a window to make a paste work.
- Delivery is reported as **Paste attempted**, **Delivery held**, or **Delivery failed** — never as a verified insertion, because the tool's exit status only says the shortcut was sent, not that the application inserted the text. A hold and a failure also raise a notification; a successful attempt does not, so the paste cannot steal focus with a popup.
- The **Delivery** setting chooses **Automatic** (the above) or **Manual**, which never pastes on its own and leaves **Copy transcript** and **Paste now** as your own route.
- **Verify and record** repeats setup verification and re-hashes the files, for example after replacing the model.

The controller also exposes `toggle`, `stop`, `cancel`, `show` and `paste` over IPC:

```sh
noctalia msg plugin magus/dictation:controller all toggle
noctalia msg plugin magus/dictation:controller all stop
noctalia msg plugin magus/dictation:controller all cancel
noctalia msg plugin magus/dictation:controller all show
noctalia msg plugin magus/dictation:controller all paste
```

Any of those actions can be bound, and a press bind is enough — the chord is dispatched by the compositor rather than typed by a client, so there is no shortcut release to observe — for example:

```sh
bind = SUPER, D, exec, noctalia msg plugin magus/dictation:controller all toggle
```

The panel's **Recording shortcut** row writes that binding for **Toggle** in the active configuration format, with the conflict check and the undo described above, so hand-editing is not the only route.

## Where the files go

Everything is under the plugin's own data directory, normally `~/.local/state/noctalia/plugins/data/magus/dictation/`. That is the directory Noctalia resolves for a plugin's data (`NOCTALIA_STATE_HOME`, then `XDG_STATE_HOME`, then `~/.local/state`), and it is deliberately not the materialized runtime copy an update replaces, so everything below survives an update:

```
setup.json                                  recorded setup: paths, sizes, hashes, engine flags
setup-summary.json                          outcome of the last verification
current-job                                 the job this plugin currently owns
last-recording                              the recording Play and Retry fall back to after a restart
sources.json                                the last capture-source list read from pw-dump
microphone.json                             the node name of the selected microphone
jobs/<jobId>.cancel                         cancellation request, while a job is running
jobs/<jobId>.stop                           stop-and-finalize request, while a recording runs
jobs/<jobId>.lease                          the controller's claim on the job, refreshed once a second
jobs/<jobId>/job.json                       the config the job started with
jobs/<jobId>/status.json                    the phase the panel reports
jobs/<jobId>/heartbeat.json                 rewritten while the helper runs, so lost contact is noticed
jobs/<jobId>/summary.json                   outcome the panel reads
jobs/<jobId>/delivery.json                  the paste attempt: state, target, exit status
jobs/<jobId>/recording.wav                  the captured audio, kept whether or not recognition ran
jobs/<jobId>/recorder.log                   pw-record's own output
jobs/<jobId>/attempt-1/argv.json            the exact argument vector, as a list
jobs/<jobId>/attempt-1/input-list.txt       the engine's --batch input list
jobs/<jobId>/attempt-1/engine.jsonl         raw engine output, exactly as written
jobs/<jobId>/attempt-1/engine.log           engine standard error
jobs/<jobId>/attempt-1/transcript.txt       the transcript
jobs/<jobId>/attempt-1/result.json          the full outcome record
retention.json                              the last automatic pruning: what was removed, and what could not be
diagnostics-preview.json                    the exact text the diagnostics export copies, written when you open it
```

Job directories and their files are private to your user (directory `0700`, files `0600`). Re-running an existing job id writes `attempt-2`, and so on; earlier attempts are kept. **Recent dictations** reads these directories and nothing else, so it lists a job the same way after a restart. Files shipped by this plugin are only ever read, never written.

Pruning happens only after a transcription finishes and its own result is saved, whether that job was a recording, a **Retry** or a **Transcribe file**: the newest **Kept dictations** finished jobs are kept and older ones are pruned. A job that failed, was cancelled, was interrupted, or that a helper process still owns is never pruned, a job whose recording a kept dictation still plays is kept, and a write that failed leaves every older job alone. The panel's storage line shows the count and the bytes, and names any file the last pruning could not remove. No pruning happens while nothing finishes.

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
| `cancelled` | You asked for the job to stop. The audio captured so far is kept, or nothing was captured when the request arrived before the microphone was opened. |
| `interrupted` | The controller stopped claiming the recording, so the microphone was released. The audio is kept for **Retry**. |
| `source_missing` | The selected microphone is not in the PipeWire graph. No other source is used. |
| `sources_unavailable` | `pw-dump` could not be run or did not report the graph. |
| `invalid_recording` | The capture ended without usable 16 kHz mono signed-16 WAV audio, or it was stopped before the microphone was opened. |
| `recorder_failed` | `pw-record` stopped on its own before a stop was requested. |
| `recorder_unavailable` | `pw-record` could not be started. |
| `invalid_wav` | An imported recording is missing or is not 16 kHz mono signed-16-bit WAV. |
| `engine_incompatible` | The selected executable does not accept the flags this plugin needs. |
| `engine_unavailable` | The engine could not be started, or running it to check its flags failed. |
| `setup_required` | The executable or the model is missing or not executable. |
| `invalid_threads` | The thread count is outside 1–64. |
| `internal` | The helper failed, the plugin could not start it, or it stopped reporting. |

Nothing is repaired automatically: an incompatible engine or a malformed recording is reported as it is, with the class of problem named. A failed run also carries the last lines the engine wrote to standard error, so a model the engine cannot load is reported with the engine's own reason rather than a bare exit status.

## How the engine is called

Capture, playback and inference all run from an argument vector — never a shell string, so no path or source name is ever split or expanded by a shell:

```
<python3> dictation-helper.py record --engine … --model … --threads 4 --source … --job-id … --data-dir …
pw-record --target SOURCE --rate 16000 --channels 1 --format s16 <jobDir>/recording.wav

<python3> dictation-helper.py run --engine … --model … --threads 4 --wav … --job-id … --data-dir …
transcribe-cli --backend cpu --threads 4 --timestamps none -m MODEL --batch input-list.txt --batch-size 1 --batch-jsonl

pw-play <jobDir>/recording.wav
```

Playback runs from the helper too, bounded by a ten-minute limit, so a stuck `pw-play` cannot outlive it:

```
<python3> dictation-helper.py play --wav <jobDir>/recording.wav
```

`Stop` sends `SIGINT` to the recorder process the helper started, and only to that process, then waits for it to finish the WAV before validating the audio. `Cancel` and a controller loss send `SIGTERM` to that recorder's own process group and escalate to `SIGKILL` after a three-second grace; the recorder finalizes the WAV on `SIGTERM`, so the captured audio survives.

The engine runs with `OMP_NUM_THREADS` and `OPENBLAS_NUM_THREADS` set to the thread count and with niceness 10, so it yields to interactive work. The recorder is never niced, because capture is the real-time path. On the first run against a new executable, the helper checks the `--help` output for every flag above and refuses to guess when one is missing.

The helper keeps the 30-minute watchdog, not Noctalia: a captured-process callback is capped far below a long inference, so the helper is launched detached and reports its outcome through `summary.json` instead. Every child — the recorder and the engine — is tied to the helper's lifetime, so a helper killed outright takes its children with it instead of leaving a recorder or an engine running behind a lost job.

## How the delivery works

One mechanism, chosen and tested, with no fallback matrix: the transcript is copied to the clipboard with Noctalia's clipboard API, and the ordinary paste shortcut is dispatched by the compositor itself — `hyprctl dispatch sendshortcut CTRL,V,` — through Hyprland's own seat. `sendshortcut` declares the chord's modifier state (ctrl) to the focused client, sends the key straight to that client instead of through the bind matcher, and clears the modifiers again afterwards, so the client receives exactly `Ctrl+V` and is left with no modifier of its own. It needs no daemon, no `/dev/uinput` and no device access, and `hyprctl` is already what this plugin reads the focused window with. Nothing is installed, replaced or escalated by the plugin, and no second injector is kept as a fallback: `ydotool` is deliberately not used, because it wants `/dev/uinput` and a running daemon, and `wtype` is not used either, because it synthesizes the chord as keystrokes at the seat, where a modifier you still hold can change what the application receives. **Verify and record** tests the mechanism without sending a key: `sendshortcut` is dispatched with no chord, which the dispatcher answers with its own argument error and which sends nothing, and the panel names the mechanism and whether the compositor answered. When `hyprctl` is missing, or the compositor does not have the dispatcher, the transcript is held and **Copy transcript** stays the route.

What is sent is exactly one chord, `hyprctl dispatch sendshortcut CTRL,V,`: no speech is typed as keystrokes, no extra key rides along, and no Return is ever sent, so dictation cannot submit a form or run a command on its own. The window selector in that chord is left empty on purpose, because `sendshortcut` re-points focus to a window when it is given one; the focus check above stays the one thing that decides where the text goes. The transcript itself travels as clipboard data (`text/plain`), and the plugin never clears or restores the clipboard afterwards — the transcript stays there for you, and a clipboard manager keeps it in its history.

The destination is the window the recording was started from, and it is identified by the compositor's own answer to `hyprctl -j activewindow` at record start: its address is the identity, and its class is what decides a hold. A recording started from the panel arms no destination at all, because the panel is a layer surface and not the application you were typing in; the job is held until you press **Paste now** with the target window focused. Before the paste, the window is asked again: a destination that changed address, closed, or became a terminal, a password manager, or an unreadable class is held instead of receiving the text, and the plugin never moves focus to make a paste fit.

The chord is sent no sooner than 500 ms after the job finished, so a panel that is closing or a focus change that is landing has a moment to settle. Nothing has to be waited out for the shortcut itself: the modifier state of the chord comes from the compositor, not from the keyboard, so a modifier you still hold cannot join it. What the compositor does not tell anyone is whether the application acted on the chord — it reports that the dispatch was accepted, not that the text was inserted — so delivery is reported as an attempt, never as a verified insertion.

Delivery happens at most once per finished recording, and only for a result the plugin trusts: `ok` **and** copyable, with the transcript and result files really on disk. `empty`, `malformed_row`, `truncated`, `unknown_token`, `nonzero_exit` and every other outcome is never pasted on its own, even when partial text is shown and copyable by hand. The attempt is written to the job's `delivery.json` **before** the clipboard is touched, and an attempt that cannot be recorded is not made: if that write fails, nothing is copied and no key is sent. With the marker in place, if the plugin crashes between it and the shortcut, the next run holds the job and says so instead of pasting it a second time, and a job adopted after a restart never delivers at all. Duplicate controller events, a second update tick, and a compositor answer that never arrives cannot repeat the side effects: an attempt in flight is never restarted, and one that never answers is held after 30 seconds.

## When something looks wrong

Every item here is reachable from the panel, so recovery never needs a terminal.

- **"Setup required"** names the missing piece: the executable, the model, `python3`, or the data directory.
- **"Choose a microphone before recording"** means no microphone has been selected yet. Open the panel and pick one from the list.
- **`source_missing`** means the microphone you chose is not in the PipeWire graph. The plugin selects nothing else, not even the default source and not a monitor: reconnect it, press **Refresh**, and pick it again.
- **`engine_incompatible`** means the executable rejected one of the flags. Check that the version you selected supports `--batch-jsonl`.
- **`invalid_wav`** means an imported recording is not 16 kHz mono signed-16 WAV. Convert it first, for example with `ffmpeg -i in.wav -ar 16000 -ac 1 -c:a pcm_s16le out.wav`. This plugin does not transcode its own captures either; it asks `pw-record` for exactly that format.
- A stuck job can be stopped with **Cancel**; only the processes the helper started see a signal.
- A deletion that reports files it could not remove has left the dictation listed on purpose: its record is still there, so it can be retried or deleted again instead of disappearing while its files are on disk.

## Known limits

- CPU only: the engine is always called with `--backend cpu`.
- One job at a time, and no queue.
- Automatic paste needs `hyprctl` and a compositor with the `sendshortcut` dispatcher; the plugin never installs it, never requests device access, and never runs a daemon, so without it a transcript is held and copied by hand. There is no fallback tool: `ydotool` and `wtype` are not used and not required, and nothing is granted or escalated to make a paste work.
- What automatic paste cannot know is whether the application inserted the text. The compositor reports that the chord was accepted, and delivery is reported as **Paste attempted** for that reason; a window that ignores or discards `Ctrl+V` looks exactly like one that pasted.
- Holds are decided from the window's class, which is all the compositor reports. The plugin does not detect a password field, and a terminal or password manager without a recognisable class is pasted into; use **Manual** mode for those windows you always want to paste into by hand.
- Monitors are excluded from the microphone list by name: a source whose node name ends in `.monitor`, or whose description starts with `Monitor of `, is treated as an output loopback and hidden. PipeWire does not mark monitors with a single portable field, so a monitor that is named differently could appear in the list; selecting it captures playback rather than a microphone, and nothing else about the plugin changes.
- Only `media.class = "Audio/Source"` nodes are listed, so a virtual source that PipeWire reports as a different class is not offered.
- Adopting a running job after a reload continues its elapsed timer: the helper writes the capture's start time as wall-clock milliseconds, and `noctalia.nowMs()` is on the same clock, so the elapsed time keeps counting from the real start. Elapsed time is clamped at zero, so two clocks that disagree can never show a negative duration. The job id, its files and **Cancel** are unaffected.
- Only 16 kHz mono signed-16-bit WAV is accepted, and no resampling is attempted.
- Stale setup detection compares each recorded file's path and size, so a replacement that keeps the same size is only reported by the job that fails on it.
- The newest **Kept dictations** finished jobs stay on disk. After any finished job's own result is saved — a recording, a **Retry** or a **Transcribe file** — older finished jobs beyond that count are removed. A job that failed, was cancelled, was interrupted, or that a helper process still owns is never pruned, a job whose recording a kept dictation still plays is kept, and a write that failed leaves every older job alone. No pruning happens while nothing finishes.
- **Clear history** and the delete actions remove only directories and files the helper has validated as this plugin's own. Listing the history is still read-only, and a refusal is reported rather than worked around.
- Recording is refused before anything is started when less than 20 MB is free, and earlier jobs are left untouched. That pre-check needs `noctalia.diskStats`; when the runtime cannot answer it, the job directory, pointer and lease writes still happen before anything is launched, so a full disk fails there or fails the recorder itself, and both are reported as errors.
- **Play** and **Retry** address the newest recording by default, which is the one a preserved failure leaves behind. **Recent dictations** reaches older ones without importing their files. The history lists the newest 20 jobs; older ones stay on disk until retention or a deletion removes them.
- **Cancel** does not stop a playback that already started, because playback is not a job: it runs on its own under the helper and ends when the recording ends or the ten-minute playback limit is reached.
- The shortcut setup manages one chord in one file: the active Hyprland configuration the compositor loads. A binding for the same chord added in a sourced fragment, a submap, or another configuration file is outside it — the live bind table still reports the collision, so setup refuses rather than overwriting, but the block cannot be found in a file the setup does not write. Only Hyprland is supported, only the primary configuration file, and only the one proposed chord; the row says so instead of guessing when `hyprctl` or the file is missing.

## Checks

Run the behavior check from this directory:

```sh
./selftest.sh
```

It uses fake `pw-dump`, `pw-record`, `pw-play` and engine executables with generated WAV fixtures to check the argument vector, thread limits and niceness, the helper's outcomes (including `engine_unavailable` and `internal`), the log excerpt a failing run carries, the watchdog, cancellation before and during a job, a cancel that arrives while the WAV is already being finalized, a stop and a cancel that arrive before the capture starts, including before the helper process itself is running (the microphone is never opened), file permissions, the heartbeat it rewrites while the engine runs, source enumeration and monitor exclusion, recording stop and finalization, cancel escalation to `SIGKILL`, controller-loss release, playback, the history read that lists the newest jobs from the durable directories alone (a job a helper process still owns is `running`, one without a summary is `interrupted`, the length comes from the finalized WAV, the preview from the raw transcript, and missing audio is reported instead of offered, a retry whose durable record names the dictation it retried, and the wording a job's own audio is explained with), result rows whose fields have the wrong type, and that an imported recording is left untouched and becomes the recording **Play** and **Retry** address. It also covers retention and deletion: it runs jobs until the count is over the limit and checks that only the newest finished ones are removed, that a job below the limit, a failed job, a job with no summary and a live job are all kept, that `retention.json` records the removal, and that no pruning happens at all when the summary it would follow could not be written. It checks that deleting a recording keeps the transcript and the attempts, that an import and a retry refuse to delete audio they do not own, and that a traversal, a nested path and a symlinked job directory are refused while a symlink inside a job is unlinked rather than followed. It checks **Clear history** against the job pointer, a live helper and a kept job, and that a permission-denied deletion reports the survivor and keeps the dictation listed. It checks that the diagnostics preview and export omit transcript text, raw recognition output and the user's paths — including the engine's half of a failure message and a summary written before it was kept apart — that the exported bytes are the previewed bytes with mode `0600`, that a destination directory's own permissions are never changed, and that a text export is a faithful copy. An unrelated recorder and an unrelated recognizer are kept alive across cancellation and controller loss, so a name-based or library-wide cancellation fails this check instead of passing. If `luau-compile` is on `PATH` it also compiles every entry script.

```sh
./controller-selftest.sh
```

It checks the controller's logic — duplicate-toggle convergence, one job at a time, cancel and stop routing, the lease it refreshes, microphone selection and refusal (including a change refused while recording), the phase it keeps once a stop is accepted, the transcribing state that follows a finalized recording, the elapsed time it restores for an adopted job, the low-disk refusal, adopting a recording after a reload, recovery after a restart, the recording it falls back to when its pointer is gone, the durable history it reads back and publishes, the retry that starts a new job under an older dictation's recording without rewriting it and records which dictation it retried, the concurrent retry and the unusable audio it refuses with the reason, the playback that plays the selected dictation, the IPC actions, and what the bar widget and the panel render, including the finalizing and transcribing states, the history list with an interrupted entry, its selection, and the actions its audio allows, the destructive history actions that arm before they send and the confirmation that actually sends them, the storage and retention lines, a retention failure that stays visible, the diagnostics preview that is read-only and the export that waits for its confirmation, and that the retention setting reaches the helper with a value outside 1–1000 clamped instead of passed through — by loading `controller.luau`, `panel.luau` and `widget.luau` into a stubbed `noctalia` API, without PipeWire or Noctalia. It drives delivery against a stubbed compositor as well: the setup probe that sends no chord and the answers that accept or refuse it, the settle wait, one chord per attempt, the chord's empty window selector, the destination check that holds a changed window, the terminal and password-manager holds, the first-time confirmation of a window class, the explicit paste that closes the panel and skips a hold, the empty, malformed, truncated, unknown-token and nonzero-exit results that never paste, the attempt marker that survives a crash, a job recovered from disk that never delivers, an import that starts while a paste is waiting, a marker write that fails, a missing tool, a failed clipboard write, a refused chord that is reported instead of claimed, manual mode, and that every injection over the whole run is the one ordinary chord. The recording-shortcut setup is driven the same way, against a stubbed bind table and configuration files: the free chord that is offered, the exact block written in the hyprlang and the Lua form, the user's own lines and a top-level `return` that survive, the backup taken before the write, the reload that is verified against the bind table instead of its exit status, the second install that converges with no duplicate block, the chord already held by something else that is refused and named, undo that removes only the block and keeps later edits, a write and a backup that fail and say so, a block that is written but never registers, a reload that fails and one that never answers, a block half-deleted by hand that is left alone, a missing `hyprctl` and a missing configuration file that stay actionable, and the panel showing the state with its install, undo and recheck controls. The run fails its process when any check fails, so a caller reading the exit status sees a failed run. If `luau` is not on `PATH`, set `LUAU=/path/to/luau`.

## Processes, files and network

Processes the plugin starts: `python3 dictation-helper.py` from the plugin package, once per job; `pw-record` for capture; `pw-play` for playback; `pw-dump` to list capture sources; `hyprctl` to read the focused window, to probe and re-check the paste mechanism, to install or undo the shortcut block, and to send the one paste chord; `ps` to read the compositor's command line when choosing which configuration file to edit; and the engine you selected, once per transcription, with the argument vector documented under **How the engine is called**. The engine's `--help` is run during setup verification. Everything else is Noctalia's own IPC between the panel, the bar widget and the controller.

Files the plugin writes: everything listed under **Where the files go**, all inside the per-plugin data directory with `0700` directories and `0600` files, plus one Hyprland configuration file when you press **Install shortcut** or **Undo shortcut** (with a `<file>.magus-dictation.bak` copy taken first), plus the `.txt` export and the diagnostics export in `~/Downloads` (or your home directory) when you explicitly ask for them. Files shipped by the plugin are only ever read. The plugin never writes into its own package, never replaces the executable, the model or the source tree you selected, and never touches the benchmark recordings you use to check the engine.

Network: none. Nothing is downloaded, installed, uploaded or fetched, and no key, transcript or metadata leaves the machine, in the background or on demand. There is no telemetry, no update check and no cloud fallback. You install and update the engine and the model yourself, outside the plugin.

## Updating, disabling and removing

Noctalia updates enabled Git sources automatically by default. To update immediately:

```sh
noctalia msg plugins update magus
```

An update replaces Noctalia's materialized runtime copy of the plugin. Your data is not there: it lives in the per-plugin data directory described under **Where the files go**, which Noctalia does not rewrite, so setup, the microphone choice, the shortcut record and every saved dictation survive an update. The engine path, the model path and the recorded hashes point at your own files; the plugin never replaces, rebuilds or downloads them, so an update leaves them exactly as they are, and a file that changed underneath is reported as stale instead of being repaired silently. Nothing about an update re-enables the plugin, changes a setting, or performs a setup step for you.

A job that is running when the plugin reloads or is updated is adopted, not replaced: the controller reads the job id back from disk and keeps addressing the same helper and the same recording, so the history survives and nothing is delivered twice. A recording whose controller disappears is released by the helper's lease within ten seconds and stays on disk as `interrupted`, which **Retry** can pick up. An update never pastes a transcript again: delivery happens once, for a recording that this session finished, and is refused for an adopted, retried or imported job; a `delivery.json` marker left behind by a crash makes the next run hold the job and say so.

Disabling or removing the plugin is handled by Noctalia, which stops the service and deletes its materialized copy. The controller cancels the running job on `disable` and `uninstall`, so the recorder or the engine the helper owns is stopped instead of being left running, and a helper that cannot be reached stops its own children because they are tied to its lifetime. Capture therefore does not outlive the plugin: either the cancellation reaches the helper, or the lease expires and the helper releases the microphone on its own, and the last recording stays on disk either way.

Removal touches only Noctalia's own copy of the plugin. It does not delete the per-plugin data directory, and it cannot reach anything else: the delete and retention code refuses any path outside the plugin's own data directory and any file that is not a job's own file, so your engine, your model, the benchmark recordings and sources and the rest of your home directory are never candidates. Retaining private history is the default, and deleting it is a separate, explicit action rather than a step of removal: the plugin never asks to delete your dictations for you, and history that was kept when the plugin went away is still there when it comes back. To remove it, delete the directory explicitly, before or after removing the plugin:

```sh
rm -rf "${NOCTALIA_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}}/noctalia/plugins/data/magus/dictation"
```

What removal cannot undo is the one block the shortcut setup wrote into your Hyprland configuration. That file is yours, so it is left alone, and **Undo shortcut** is the supported way to reverse the change (see **Recording shortcut**). Once the plugin is gone the leftover chord runs `noctalia msg plugin magus/dictation:controller all toggle` with no controller to receive it: delete the two marked lines together with the `bindd = …` or `hl.bind(…)` line between them and reload, or re-enable the plugin and press **Undo shortcut**.

## Release scope

- **Requires an installed engine.** Dictation is an existing-engine plugin: a `transcribe-cli` build and a GGUF model must already be installed. The plugin never downloads, bundles, rebuilds, patches or installs an engine, a model or a package, and the catalog's dependency list is metadata rather than an installation step. A user who has no engine yet cannot complete setup from this plugin alone; that graphical source-install route is a separate ticket and is not shipped here.
- **What this release covers.** Installing from the Git source, setup verification, microphone selection, shortcut-driven recording, automatic paste into the editor and browser you dictate into, history with Retry, cancellation and error recovery, retention and deletion, diagnostics export, and update, reload and removal safety.
- **What publishing does not authorize.** Publishing this code does not authorize an automatic merge, an installation on anyone's host, or a submission to a community store. Those remain separate human decisions.
- **No privileged behaviour.** The plugin does not install a package, a permission, a udev rule or a background daemon, does not use `ydotool` or `/dev/uinput`, does not request input-device access, and does not change boost or any global policy. Inference is CPU-only by design.
