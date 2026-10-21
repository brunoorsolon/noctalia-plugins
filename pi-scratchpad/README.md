# Pi Scratchpad

A Noctalia plugin that gives the Pi coding agent a home on the desktop: one long-lived Pi TUI parked in a Hyprland special workspace, a bar widget showing whether it is working, waiting on you or idle, a click that toggles the workspace, and a notification when Pi starts waiting out of sight.

The plugin never renders the conversation. Pi's own TUI is the UI, so nothing is rebuilt, no RPC subprocess runs, and no tool call escapes an approval gate. The widget reads one small status file and drives the compositor; that is the whole plugin.

## Plugin

| Field | Value |
| --- | --- |
| ID | `magus/pi-scratchpad` |
| Entry | Widget: `scratchpad` |
| Plugin API | 24 |
| Compositor | Hyprland 0.55+, configured in Lua |

## Requirements

- **Hyprland 0.55 or newer, configured in Lua (`hyprland.lua`).** Niri has no native special workspace, so this plugin is Hyprland only. Hyprland added its Lua configuration and dispatcher API in 0.55 and deprecated hyprlang there; the widget drives the compositor through `hl.dsp.exec_cmd` and `hl.dsp.workspace.toggle_special`. A legacy `hyprland.conf` configuration does not accept those calls, and the click reports Hyprland's refusal instead of opening Pi.
- **The companion Pi extension, [pi-hypr-agent-monitor](https://github.com/brunoorsolon/pi-hypr-agent-monitor).** It is what publishes the status file the widget reads. Without it the widget sits on "Pi is not running". Install it with `git clone https://github.com/brunoorsolon/pi-hypr-agent-monitor ~/.pi/agent/extensions/pi-hypr-agent-monitor`, then leave `PI_HYPR_MONITOR` alone; the plugin sets `PI_HYPR_MONITOR=1` for the Pi it spawns, so a Pi you start by hand in another terminal can never overwrite the scratchpad's status.
- **`hyprctl`** on `PATH`.
- **A terminal emulator** such as `foot` or `kitty`. The setting is a shell fragment, so a terminal that needs a flag works too: `alacritty -e`, `wezterm start --`.
- **`pi`** on `PATH`.

## Installation

Open **Settings → Plugins**, select **Add source**, and add this Git source:

| Field | Value |
| --- | --- |
| Name | `magus` |
| Kind | Git |
| Location | `https://github.com/brunoorsolon/noctalia-plugins.git` |

Enable **Pi Scratchpad**, then place its bar widget where you want it, the same as any other bar widget. The equivalent commands are:

```sh
noctalia msg plugins source add magus git https://github.com/brunoorsolon/noctalia-plugins.git
noctalia msg plugins enable magus/pi-scratchpad
```

## Usage

Click the widget. When Pi is running it toggles the special workspace; when it is not, it opens a terminal on the spawn command inside that workspace, floating at the configured size, and shows it. Pi takes a few seconds to publish a status file, so a click landing in that window is ignored: a second Pi would share the one session directory and the status file could not tell the two apart. The latch lifts as soon as Pi publishes anything, and lapses on its own after twenty seconds so a spawn that never started cannot wedge the widget.

Hiding a special workspace does not touch the process. Pi keeps running and keeps working; only closing the terminal or the compositor exiting ends it. The default spawn command resumes the same conversation with `pi -c` and a `--session-dir` of its own, so only scrollback is lost across a restart. Nothing here needs tmux or herdr, but if you run one, point the spawn command at it.

The workspace is one Pi, not one per project. It starts in the configured directory and Pi's own tools take paths from there. Anyone who needs a session rooted somewhere specific launches Pi as an ordinary window.

A click never fails silently. If Hyprland refuses the dispatch — a legacy `hyprland.conf` configuration, an unknown special workspace, a compositor that is not reachable — the widget sends a notification carrying Hyprland's own error; if Noctalia cannot start `hyprctl` at all, it says so. Either way the click stays retryable instead of latching the spawn.

### Settings

| Setting | Default | Purpose |
| --- | --- | --- |
| Special workspace | `pi` | The Hyprland special workspace the scratchpad lives in. `pi` and `special:pi` both work. |
| Terminal | `foot` | The terminal emulator the spawned Pi runs in. This is a shell fragment, so flags go here too. |
| Spawn command | `pi -c --session-dir ~/.local/state/pi-scratchpad/sessions` | What the terminal runs. The plugin adds `PI_HYPR_MONITOR=1`. |
| Working directory | `~` | Where the spawned Pi starts. |
| Window size | `900x600` | Floating size of the scratchpad window, as `WIDTHxHEIGHT`. |
| Notify when Pi starts waiting | on | Send a notification when Pi changes to waiting while the workspace is hidden. One per turn, even if the widget sits on two bars. |

No Pi configuration ships inside the plugin: the spawn command is the whole of it, so your model, provider and approval settings come from your own Pi setup.

## What the bar shows

| State | When | Glyph |
| --- | --- | --- |
| Working | Pi is running a turn | `loader` |
| Waiting | Pi wants an answer or an approval | `bell` |
| Idle | Pi is up with nothing to do | `robot` |
| Not running | There is no status file, or the recorded pid has no live process | `power` |
| Unknown | The file exists and Pi is alive, but the document cannot be read or its state is not one of the three above | `alert-triangle` |

Unknown is deliberately not "not running". A file that cannot be read still says a session was there, so the widget never reports a live Pi as gone and a click toggles the workspace instead of starting a second Pi.

The status file is `$XDG_RUNTIME_DIR/pi-hypr-agent-monitor/status.json`, or `$XDG_STATE_HOME/pi-hypr-agent-monitor/status.json` when the runtime directory is unset, with `XDG_STATE_HOME` itself defaulting to `~/.local/state` exactly as the extension resolves it. The extension writes it atomically, removes it on session shutdown, and records `state`, `pid`, `session_id`, `cwd`, `model` and `updated_at`. Liveness is the recorded pid, never the file age: a session legitimately sits in `waiting` for hours. A Pi that was SIGKILLed leaves no removal behind, and its dead pid is what the widget catches.

## Checking it

The widget's Luau entry can be exercised without a compositor:

```sh
./pi-scratchpad/selftest.sh
```

It runs the entry against a stubbed Noctalia runtime and a stubbed `hyprctl`, over fixture status files for each of the three states plus a missing file, malformed JSON, an unrecognised `state` and a dead pid, and checks the click routing, the spawn latch, the waiting notification and the two-placement cases. The `hyprctl` stub answers a dispatch the way a Lua-configured Hyprland does, by evaluating `return hl.dispatch(<argument>)` against a stubbed `hl.dsp`, so a dispatch expression that Hyprland or Lua would reject fails the check instead of passing as a string comparison. It also runs the repository-wide `scripts/check-catalog.py`, which compares every plugin manifest against its catalog row. It needs `luau` on `PATH`; without one the Luau half is skipped instead of failing. Set `LUAU=/path/to/luau` to point it at a specific interpreter.

What it cannot check is the host: whether a real Pi turn moves the indicator, whether the first click spawns and later clicks toggle, whether the window arrives at the configured size, and whether Hyprland accepts the dispatcher expressions on the live version. Those need Hyprland, Noctalia, a terminal and the extension.

The widget speaks Hyprland's Lua dispatcher interface. A `hyprland.lua` configuration evaluates every `hyprctl dispatch` argument as the expression in `hl.dispatch(<argument>)`, so the plugin emits `hl.dsp.exec_cmd(command, rules)` for the launch and `hl.dsp.workspace.toggle_special(name)` for the workspace. On a `hyprland.conf` configuration the same argument reads as a legacy dispatcher pair, and Hyprland answers `Invalid dispatcher`; the widget shows that reply as a notification rather than looking like it did nothing.
