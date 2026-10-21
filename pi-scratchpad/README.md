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

Click the widget. When Pi is running it toggles the special workspace; when it is not, it opens a terminal on the spawn command inside that workspace, floating at the configured size, and shows it. Pi takes a few seconds to publish a status file, so a click landing in that window is ignored: a second Pi would share the one session directory and the status file could not tell the two apart. The launch waits for a mapped window in the configured workspace, then uses `hl.dsp.focus({ workspace = "special:pi" })` to reveal it. Unlike a toggle, focus cannot accidentally hide a window that Hyprland has just revealed itself. Mapping is checked every 250 ms (or on animation ticks), bounded by twenty seconds. Repeated requests during that wait cannot launch another Pi or toggle the new window out of sight. The startup latch also protects the gap before Pi publishes status; it lapses after twenty seconds, and an unmapped-window timeout is reported.

If the terminal has disappeared but its monitored Pi is still shutting down, the click is remembered for up to twenty seconds. Once Pi exits, that same request launches and reveals the replacement. A process that remains alive is never duplicated just because its window is missing; the request times out with a notification instead.

Hiding a special workspace does not touch the process. Pi keeps running and keeps working; only closing the terminal or the compositor exiting ends it. The default spawn command resumes the same conversation with `pi -c` and a `--session-dir` of its own, so only scrollback is lost across a restart. Nothing here needs tmux or herdr, but if you run one, point the spawn command at it.

The workspace is one Pi, not one per project. It starts in the configured directory and Pi's own tools take paths from there. Anyone who needs a session rooted somewhere specific launches Pi as an ordinary window.

A click never fails silently. If Hyprland refuses the dispatch — a legacy `hyprland.conf` configuration, an unknown special workspace, a compositor that is not reachable — the widget sends a notification carrying Hyprland's own error; if Noctalia cannot start `hyprctl` at all, it says so. Either way the click stays retryable instead of latching the spawn.

### Hyprland shortcut

Use the same toggle as the bar click from a terminal:

```sh
noctalia msg plugin magus/pi-scratchpad:scratchpad focused toggle
```

For example, in `hyprland.lua`:

```lua
hl.bind("SUPER + grave", hl.dsp.exec_cmd("noctalia msg plugin magus/pi-scratchpad:scratchpad focused toggle"))
```

Choose your own key combination in Hyprland. The command hides a visible scratchpad, reveals a hidden one, or launches and reveals Pi if it is stopped. It shares the click's launch latch and persistent-session settings.

The widget must be placed on the targeted output. If more than one bar on that output contains it, use `focused:<bar-name>` (for example `focused:main`) instead of `focused`. A connector name such as `DP-1:main` can target a fixed placement when the focused output has no widget. Do not use `all`: that broadcasts a toggle to every placement and could toggle the workspace twice. Noctalia reports a missing or ambiguous target instead of guessing.

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

The widget is a 20 × 20 pixel-display robot/TV head. Its outline stays the same; the display inside carries the state. It occupies the same square on horizontal and vertical bars.

| State | When | Display inside the head |
| --- | --- | --- |
| Working | Pi is running a turn | Heartbeat scrolling horizontally to the left |
| Waiting | Pi wants an answer or an approval | Bell swaying twice, then resting briefly |
| Idle / stopped | Pi is idle, or there is no live monitored session | Thin π; no plus badge or separate stopped appearance |
| Waiting, acknowledged | You viewed the waiting scratchpad and hid it | Thin π; tooltip says “Pi is idle” |
| Unknown | The file exists and Pi is alive, but the document cannot be read or its state is unrecognised | Exclamation mark |

The artwork inherits **Icon Color → widget Color → theme default** through Noctalia's native glyph rendering. It no longer forces `on_surface` (which bypassed the presentation overrides and left the icon white). Pick a color with enough contrast against your bar. Shapes and tooltips, rather than color alone, carry meaning.

Working and unacknowledged waiting animate at eight frames per second; idle, acknowledged waiting, and unknown update once per second outside startup. The artwork is built from native filled-square glyphs, with no external font or image dependency. Each glyph slightly overlaps its grid cell to cover the font's rounded, antialiased edges and the gaps introduced by pixel snapping at fractional scales. This preserves the host's per-placement color inheritance, which plugin images do not expose. The artwork bitmaps and timing are unchanged; their raster edges are denser. Fractional scaling and font antialiasing should still be checked on the host.

Tooltips name the displayed state without click instructions. All π presentations—including stopped and acknowledged waiting—say “Pi is idle”. This is the indicator's display state, not a change to Pi's actual pending question or approval.

Viewing then hiding a waiting Pi acknowledges only its indicator. It does not answer a question, approve a tool, cancel work, or change the status file. The click and IPC command acknowledge a successful hide immediately. Hiding through another compositor action is detected by a one-second visibility poll; a show/hide entirely between polls cannot be observed. A fresh waiting status publication rearms the bell, including one after a short working turn missed between polls. The companion extension also republishes on model selection, so changing models while waiting can rearm attention. Acknowledgments are shared by all placements and are scoped to the process, session, and status timestamp.

Unknown is deliberately not "not running". A file that cannot be read still says a session was there, so the widget never reports a live Pi as gone and a click toggles the workspace instead of starting a second Pi.

The status file is `$XDG_RUNTIME_DIR/pi-hypr-agent-monitor/status.json`, or `$XDG_STATE_HOME/pi-hypr-agent-monitor/status.json` when the runtime directory is unset, with `XDG_STATE_HOME` itself defaulting to `~/.local/state` exactly as the extension resolves it. The extension writes it atomically, removes it on session shutdown, and records `state`, `pid`, `session_id`, `cwd`, `model` and `updated_at`. Liveness is the recorded pid, never the file age: a session legitimately sits in `waiting` for hours. A Pi that was SIGKILLed leaves no removal behind, and its dead pid is what the widget catches.

## Checking it

The widget's Luau entry can be exercised without a compositor:

```sh
./pi-scratchpad/selftest.sh
```

It runs the entry against a stubbed Noctalia runtime and a stubbed `hyprctl`, over fixture status files for each of the three states plus a missing file, malformed JSON, an unrecognised `state` and a dead pid, and checks the state presentation and inherited colors, animation frames, the tooltips, click and IPC routing, the spawn latch, waiting notifications, visibility acknowledgment (including failed and stale observations), two-placement cases, and delayed close/reopen mapping. The launch regression models a window becoming visible between a compositor snapshot and its callback, as well as hidden mapping, delayed process shutdown after unmapping, repeated requests, failed/malformed client queries, timeouts, and stale callbacks. The `hyprctl` stub answers a dispatch the way a Lua-configured Hyprland does, by evaluating `return hl.dispatch(<argument>)` against a stubbed `hl.dsp`, so a dispatch expression that Hyprland or Lua would reject fails the check instead of passing as a string comparison. It also runs the repository-wide `scripts/check-catalog.py`, which compares every plugin manifest against its catalog row. It needs `luau` on `PATH`; without one the Luau half is skipped instead of failing. Set `LUAU=/path/to/luau` to point it at a specific interpreter.

### Preview all icons before approving a change

Generate a self-contained HTML page from the actual `icon.luau` frames and timing, using Noctalia's installed `noctalia-tabler.ttf` font. The exporter needs Python, Luau, and the Cairo/FreeType shared libraries on Linux; it does not install packages.

```sh
LUAU=/path/to/luau python3 pi-scratchpad/preview.py --font /path/to/noctalia-tabler.ttf > /tmp/pi-scratchpad-preview.html
```

Open the resulting file in a separate browser profile. It has live heartbeat and bell animations, pause and frame-step buttons, a color picker, dark/light backgrounds, and actual-size (20 px), 1.25× (25 px), and enlarged samples. It makes no network requests. Unlike the earlier idealized SVG preview, this page embeds PNG alpha masks rasterized from the real Tabler glyph with Cairo/FreeType. The model follows Noctalia's unhinted grayscale rasterization, padded glyph textures, fixed-cell centering, and pixel snapping. A before sample shows the old spaced-dot renderer using the same font. The exporter also checks that a filled grid has no sub-50%-alpha interior seams at 1× and 1.25× widget scale.

This is a native-font renderer model at output scale 1, not a screenshot from a running Noctalia session. Other output DPI, host versions, GPU sampling and clipping can differ. The supplied font's SHA-256 is displayed so the preview's provenance is explicit.

On the PR branch, check in Noctalia that changing **Icon Color** affects every state, that the icon stays square at 1.25× and on a vertical bar, and that the shortcut starts/shows/hides a single Pi. Run a turn, view and hide its waiting result, then run another turn to check the bell rearms. Close and reopen the terminal to check the conversation resumes. Check animation smoothness and shell CPU usage on the actual host as well.

What the harness cannot check is the host: whether a real Pi turn moves the indicator, whether the first click spawns and later clicks toggle, whether the window arrives at the configured size, and whether Hyprland accepts the dispatcher expressions on the live version. Those need Hyprland, Noctalia, a terminal and the extension.

The widget speaks Hyprland's Lua dispatcher interface. A `hyprland.lua` configuration evaluates every `hyprctl dispatch` argument as the expression in `hl.dispatch(<argument>)`, so the plugin emits `hl.dsp.exec_cmd(command, rules)` for the launch, `hl.dsp.focus({ workspace = "special:<name>" })` to reveal the mapped launch, and `hl.dsp.workspace.toggle_special(name)` for ordinary show/hide clicks. On a `hyprland.conf` configuration the same argument reads as a legacy dispatcher pair, and Hyprland answers `Invalid dispatcher`; the widget shows that reply as a notification rather than looking like it did nothing.
