# Howto: Dictation and Pi Scratchpad

A short path through the two newest plugins, from a clean machine to a working one. Each plugin's own README is the reference; this page is the order to do things in.

## Add the source once

Open **Settings → Plugins → Sources → Add source**, name it `magus`, kind Git, location the repository URL. Or run:

```sh
noctalia msg plugins source add magus git https://github.com/brunoorsolon/noctalia-plugins.git
noctalia msg plugins enable magus/dictation
noctalia msg plugins enable magus/pi-scratchpad
```

Both plugins need Noctalia v5 beta with plugin API 24 or newer, and Hyprland.

## Dictation

Records a microphone, transcribes it locally with an engine you already installed, and pastes the result into the window you were typing in. Nothing is downloaded at runtime and nothing leaves the machine. Full reference: [dictation/README.md](../dictation/README.md).

### 1. Host tools

```sh
sudo dnf install python3 pipewire-utils hyprland
```

That covers `python3`, `pw-dump`, `pw-record`, `pw-play` and `hyprctl`. On Debian and Ubuntu the PipeWire tools come from `pipewire-bin` instead. `ps` is needed only so the shortcut setup can find which Hyprland configuration the compositor loaded.

### 2. The engine

Dictation consumes a `transcribe-cli` from [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) that accepts `--batch` and `--batch-jsonl`. The plugin never builds or fetches one. If you have no engine yet, the separate graphical installer builds one:

```sh
python3 source-installer/dictation_source_installer.py
```

It installs `git cmake gcc-c++ make openblas-devel` through your desktop's own package prompt, builds one pinned revision CPU-only in staging, checks the built executable advertises every flag the plugin needs, and publishes it to `~/.local/share/dictation-source-installer/engine/<revision>/` with a link in `~/.local/bin` when that name is free. See [source-installer/README.md](../source-installer/README.md).

### 3. The model

A GGUF the engine can load. You supply it: neither the plugin nor the installer downloads models. Put it somewhere stable, because moving it later makes the recorded setup go stale.

### 4. Setup in the panel

1. Open **Settings → Plugins → Dictation** (the gear on the plugin's row). Set **Recognition executable** and **Model GGUF** to absolute or `~` paths — a relative path resolves against Noctalia's working directory. Set **Inference threads** (default 4) and **Kept dictations** (default 10).
2. Open the panel and press **Verify and record**. It runs the engine's `--help`, checks the flags the plugin passes, hashes both files, and probes whether the compositor answers `sendshortcut`.
3. Choose the **Microphone**. The list is read from the PipeWire graph with monitors filtered out, and the choice is stored as a node name, so it survives a reconnect and a restart.

Verification is a record, not a gate: **Record** stays available while setup is unverified or stale, and the helper re-checks the engine's flags on every job.

### 5. Recording

Open the panel from the bar widget's panel button, a right click, or `noctalia msg panel-toggle magus/dictation:panel`.

| Action | What it does |
| --- | --- |
| Record | Captures the selected microphone into a private 16 kHz mono signed-16 WAV. |
| Stop | Finalizes that WAV, validates it, and only then runs recognition. |
| Cancel | Stops the microphone without transcribing. The audio captured so far is kept. |
| Play / Retry | Replays, or re-transcribes as a new job, the saved recording. Neither one pastes. |
| Copy transcript / Paste now | The manual route for a held transcript. |

The bar widget's Record, Stop and Cancel never open a panel or move focus, so you can drive a recording from the bar while the window you are typing in keeps focus.

### 6. Where the text goes

When a recording finishes with a usable transcript, the plugin copies it and dispatches `Ctrl+V` through the compositor into the window the recording started from. Nothing is typed as keystrokes and no Return is sent. The first paste into a window class you have not confirmed is held for **Paste now**, and confirming makes later recordings into that class automatic for the rest of the session. Terminals, password managers, a window whose class cannot be read, and any window that is not the one the recording started from are always held. Set **Delivery** to **Manual** to never paste automatically.

Delivery is reported as **Paste attempted**, never as a verified insertion: the compositor confirms the chord was accepted, not that the application inserted the text.

### 7. Global shortcut, optional

The panel's **Recording shortcut** row proposes **Super+Alt+D** for **Toggle** and writes one delimited block at the top of the active Hyprland configuration, taking a `<file>.magus-dictation.bak` copy first. It reads the live bind table and refuses when the chord is already held, naming what holds it. **Undo shortcut** removes exactly that block.

Disabling or removing the plugin leaves the binding in your configuration, where it becomes a dead key. Press **Undo shortcut** before removing the plugin, or delete the marked block by hand afterwards.

Any controller action can be bound by hand instead, and a press bind is enough:

```sh
bind = SUPER, D, exec, noctalia msg plugin magus/dictation:controller all toggle
```

The controller also answers `stop`, `cancel`, `show` and `paste` over the same route.

### When something looks wrong

| Symptom | Cause and fix |
| --- | --- |
| Setup required | Names the missing piece: the executable, the model, `python3`, or the data directory. |
| Choose a microphone before recording | None selected yet. Pick one in the panel. |
| `source_missing` | The microphone you chose is not in the PipeWire graph. Reconnect it, press **Refresh**, and pick it again — nothing else is selected for you, not even the default source. |
| `engine_incompatible` | The executable rejected one of the flags. Check the version supports `--batch-jsonl`. |
| `invalid_wav` | An imported recording is not 16 kHz mono signed-16 WAV. Convert it: `ffmpeg -i in.wav -ar 16000 -ac 1 -c:a pcm_s16le out.wav`. |
| Nothing pastes | Held by design for terminals, password managers, unknown classes, or a changed destination. Use **Paste now**. |
| A stuck job | **Cancel**. Only processes the helper started are signalled. |

Everything the plugin writes lives under `~/.local/state/noctalia/plugins/data/magus/dictation/`, private to your user, and survives a plugin update. The engine is called CPU-only, one job at a time, with no queue.

## Pi Scratchpad

Parks one long-lived Pi TUI in a Hyprland special workspace and puts a bar widget on it that says whether Pi is working, waiting on you, or idle. The plugin never renders the conversation: Pi's own TUI is the interface. Full reference: [pi-scratchpad/README.md](../pi-scratchpad/README.md).

### 1. Prerequisites

- **Hyprland.** Niri has no native special workspace, so this plugin is Hyprland only.
- **`pi` and `hyprctl` on `PATH`.**
- **A terminal emulator** such as `foot` or `kitty`. The setting is a shell fragment, so one that needs a flag works too: `alacritty -e`, `wezterm start --`.
- **The companion Pi extension [pi-hypr-agent-monitor](https://github.com/brunoorsolon/pi-hypr-agent-monitor).** It publishes the status file the widget reads. Without it the widget sits permanently on "Pi is not running".

Leave `PI_HYPR_MONITOR` unset in your own shell. The plugin sets `PI_HYPR_MONITOR=1` for the Pi it spawns, so a Pi you start by hand in another terminal can never overwrite the scratchpad's status.

### 2. Enable it and place the widget

```sh
noctalia msg plugins enable magus/pi-scratchpad
```

Then place its bar widget where you want it, the same as any other bar widget.

### 3. Settings

| Setting | Default | Note |
| --- | --- | --- |
| Special workspace | `pi` | `pi` and `special:pi` both work. |
| Terminal | `foot` | A shell fragment, so flags go here too. |
| Spawn command | `pi -c --session-dir ~/.local/state/pi-scratchpad/sessions` | The plugin adds `PI_HYPR_MONITOR=1`. Point it at tmux or herdr if you run one. |
| Working directory | `~` | Where the spawned Pi starts. |
| Window size | `900x600` | Floating size, as `WIDTHxHEIGHT`. |
| Notify when Pi starts waiting | on | Fires only while the workspace is hidden. One per turn, even with two bars. |

No Pi configuration ships inside the plugin, so your model, provider and approval settings come from your own Pi setup.

### 4. Daily use

Click the widget. When Pi is not running it opens a terminal on the spawn command inside the special workspace, floating at the configured size. When Pi is running it toggles the workspace.

Pi takes a few seconds to publish a status file, so a second click landing in that window is ignored: two Pis would share one session directory and the status file could not tell them apart. The latch lifts as soon as Pi publishes anything, and lapses after twenty seconds so a spawn that never started cannot wedge the widget.

Hiding the workspace does not touch the process. Pi keeps working, and only closing the terminal or the compositor exiting ends it. The default spawn command resumes the same conversation with `pi -c`, so a restart costs you scrollback and nothing else.

The workspace is one Pi, not one per project. It starts in the configured directory; anything that needs a session rooted somewhere specific is launched as an ordinary Pi window.

### 5. Reading the bar

| State | Glyph | Means |
| --- | --- | --- |
| Working | `loader` | Pi is running a turn. |
| Waiting | `bell` | Pi wants an answer or an approval. |
| Idle | `robot` | Up with nothing to do. |
| Not running | `power` | No status file, or the recorded pid has no live process. |
| Unknown | `alert-triangle` | The file exists and Pi is alive, but it cannot be read. A click toggles the workspace rather than starting a second Pi. |

The status file is `$XDG_RUNTIME_DIR/pi-hypr-agent-monitor/status.json`, falling back to `$XDG_STATE_HOME` (default `~/.local/state`). Liveness is the recorded pid, never the file's age, because a session legitimately sits in `waiting` for hours.

## Checking either plugin without a desktop

```sh
./dictation/selftest.sh
./pi-scratchpad/selftest.sh
```

Each runs its Luau entries against a stubbed Noctalia runtime and stubbed tools, and both run `scripts/check-catalog.py` to compare every plugin manifest against its catalog row. They need `luau` on `PATH`; without one the Luau half is skipped rather than failed. What they cannot check is the host: a real Pi turn moving the indicator, a real microphone, a real paste.

## Known gaps

- **No model source is documented.** Dictation needs a GGUF, and both the plugin and the source installer refuse to fetch one by design. Where to get a compatible model is currently left to the user.
- **Pi Scratchpad needs a second repository.** Installing the plugin without `pi-hypr-agent-monitor` gets a permanent "not running".
- **Hyprland 0.56 window-rule syntax.** Pi Scratchpad emits `[float;center;size 900 600;workspace special:pi]`. The exec rule syntax changed in 0.42 and again in 0.53, so an older Hyprland will not place the window.
