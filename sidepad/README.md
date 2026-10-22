# Sidepad

Shows one selected external application on a dedicated Hyprland special workspace. Noctalia provides the bar widget and selector panel; the applications remain ordinary windows, not content embedded in the panel.

| Field | Value |
| --- | --- |
| ID | `magus/sidepad` |
| Version / license | `0.1.0` / MIT |
| Noctalia | v5, plugin API 24 supported |
| Entries | Service `controller`, widget `sidepad`, panel `selector` |
| Compositor | Hyprland with the 0.55-era Lua dispatcher API |

## Requirements

- Noctalia v5 supporting plugin API 24 and Hyprland configured in Lua (`hyprland.lua`). Sidepad uses `hl.get_windows`, `hl.dsp.window.*` and `hl.dsp.workspace.toggle_special` through `hyprctl dispatch`; legacy `hyprland.conf` dispatch syntax and other compositors are not supported. The agreed target is the Hyprland 0.55-era API, not a claim that every newer version or application build has been smoke-tested.
- `hyprctl` and `socat` on the Noctalia process's `PATH`. `socat` monitors Hyprland's event socket; `hyprctl` supplies authoritative snapshots and window operations. Noctalia must run in the same Hyprland session.
- The applications you include in `pads.json`, each able to expose its own dedicated, exact class. The initial examples are Kitty, Firefox and VS Code (`kitty`, `firefox`, `code` on `PATH`). Remove an example if that application is not installed: one invalid definition or missing executable rejects the configuration rather than partly loading it.

Sidepad has no runtime dependency on Bash, jq, Rofi, Walker or the ML4W dispatcher. Application commands are argv arrays, never evaluated shell fragments. The fixed event-stream command uses the system shell to connect `socat`; it contains no user pad values. Shell commands below are manual setup, not plugin runtime requirements.

## Installation

1. Open **Settings → Plugins → Sources** and add a Git source named `magus` at `https://github.com/brunoorsolon/noctalia-plugins.git`. Enable **Sidepad**. The equivalent commands are:

   ```sh
   noctalia msg plugins source add magus git https://github.com/brunoorsolon/noctalia-plugins.git
   noctalia msg plugins enable magus/sidepad
   ```

   An initial missing-`pads.json` error is expected until configuration is supplied. Enabling does not install applications, write pad definitions or change Hyprland configuration.

2. Create the user-owned data directory and copy [pads.example.json](pads.example.json) into it as `pads.json`. Download the example or copy it from your source checkout; do not edit the installed plugin files. With default state-directory settings:

   ```sh
   data="${NOCTALIA_STATE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}}/noctalia/plugins/data/magus/sidepad"
   mkdir -p "$data/firefox" "$data/code"
   # Run from this repository's root; do not overwrite an existing pads.json.
   test -e "$data/pads.json" || cp sidepad/pads.example.json "$data/pads.json"
   printf '%s\n' "$data"
   ```

   `noctalia.pluginDataDir()` is authoritative. It resolves to `<state-home>/noctalia/plugins/data/magus/sidepad`, where state-home is `NOCTALIA_STATE_HOME`, then `XDG_STATE_HOME`, then `~/.local/state`. Use the environment of the running Noctalia process, which can differ from your terminal. Both `pads.json` and controller-written `preferences.json` belong here, not in the Git source cache or installed plugin directory.

3. Edit your copy of `pads.json`. Replace both `/ABSOLUTE/PATH/TO/sidepad-data` placeholders with the absolute directory printed above. Keep only installed applications. JSON argv does **not** expand `~`, `$HOME`, `$data`, shell quoting or command substitutions. Keep arguments as separate strings.

   | Pad ID | Dedicated class | Launch setup |
   | --- | --- | --- |
   | `terminal` | `noctalia-sidepad-terminal` | Kitty's `--class` sets the dedicated identity. |
   | `browser` | `noctalia-sidepad-browser` | Firefox uses `--name` for the native Wayland identity and `--class` for X11, `--no-remote` to avoid an ordinary browser instance, and its own profile directory. |
   | `code` | `noctalia-sidepad-code` | VS Code requests Wayland and a dedicated class, with a separate `--user-data-dir` to avoid forwarding into an ordinary editor instance. |

   The Firefox profile and VS Code data directory start separately from your normal settings and logins. Do not point them at a profile already in use. Keep one window per dedicated class; opening extra windows in these instances creates an ambiguity. Application identity switches vary with packaging and Electron/Firefox versions: verify the actual `class` in `hyprctl -j clients` when each example is first launched. If it stays a generic `firefox` or `Code` class, do not change the pad to that generic class; fix the launch identity for your build before using it. The controller cannot safely distinguish ordinary windows sharing a class.

4. Disable and enable Sidepad after saving `pads.json`, then add its **Sidepad** bar widget in Noctalia's bar settings. Left click toggles the selected pad; right click opens the selector. Configuration is read on controller startup, so `refresh` alone does not reload an edited pad file.

   ```sh
   noctalia msg plugins disable magus/sidepad
   noctalia msg plugins enable magus/sidepad
   ```

No application launches until a show, toggle or selection request. Missing or invalid preferences select the first valid configured pad and default to the left edge. `preferences.json` contains only `selectedPadId` and `side`; selection and edge changes write the complete document. Width mode, addresses, visibility, output and busy state are not saved. The controller's mutable files stay in its plugin data directory; applications still manage their own normal caches and documents.

## Controls and behavior

- **Show / Hide:** show adopts an existing unique window or launches a stopped pad once, floats it, applies geometry and focuses it on the currently focused output. Hide only hides its special workspace; the application keeps running. Showing a pad hides other visible workspaces reserved for Sidepad, leaving at most one managed pad visible. Names are derived as `special:noctalia-sidepad-<id>`; do not reuse this namespace for unrelated workspaces.
- **Select:** click a pad in the selector to select and show it, launching only if stopped. The previous application stays alive. Selection is durable; if showing fails after the preference is saved, the new pad remains selected for a retry. The panel dismisses only after success and stays open with errors after failure.
- **Narrow / Wide and Left / Right:** width toggles only a running pad, preserving its edge without revealing a hidden workspace. Edge switching persists the side and immediately repositions a visible pad; hidden or stopped pads remain hidden. Showing reapplies geometry on the focused output, including negative desktop coordinates, with sizes capped to output bounds. Manual window geometry is replaced on the next show. Application minimum sizes can still constrain the real result.
- **Close:** sends a normal close request to the selected unique window address, never a PID signal or force-kill. A window still open after the bounded confirmation wait is reported as refusing close or awaiting confirmation; respond to any application save dialog yourself. Close cannot act on another pad's ID.
- **Reload / disable / recovery:** disabling or reloading the plugin does not close applications. Startup adopts surviving exact-class matches and reconstructs state from Hyprland. The UI remains responsive while busy, and competing operations do not run concurrently. An action finishes by reconciling actual compositor state, including after failure.

## Public IPC and user-owned keybindings

Sidepad exposes functions; it registers **no global shortcuts** and never edits your Hyprland configuration. The controller is a singleton service, so address it with `all`, **not** the `focused` target used by an output-bound widget such as Pi Companion:

```sh
noctalia msg plugin magus/sidepad:controller all toggle
```

This is the same toggle as the widget's left click: launch/show if stopped, show if hidden, hide if visible. It does not require a bar placement. Other actions use the same endpoint:

| Action | Payload | Result |
| --- | --- | --- |
| `toggle` | None | Toggle the selected pad. |
| `select` | Configured pad ID | Select and show that pad, e.g. `select browser`. |
| `show`, `hide` | Selected pad ID | Explicit show/hide, e.g. `show terminal`; these require the selected ID. |
| `toggle_width`, `switch_side`, `close` | None, or selected pad ID | Act on the selected pad. |
| `refresh` | None | Reconcile compositor state; does not reload configuration. |

For example:

```sh
noctalia msg plugin magus/sidepad:controller all select browser
noctalia msg plugin magus/sidepad:controller all toggle_width
noctalia msg plugin magus/sidepad:controller all refresh
```

If you want a shortcut, add a binding yourself in `hyprland.lua`. **Choose a free chord**; `SUPER + A` below is an illustration, not a required Sidepad key:

```lua
hl.bind(
    "SUPER + A",
    hl.dsp.exec_cmd("noctalia msg plugin magus/sidepad:controller all toggle")
)
```

In a configuration that already defines `mainMod`, `ipc` and a `flags` helper, the same pattern can use `mainMod .. " + <your key>"`, `ipc .. " plugin magus/sidepad:controller all toggle"` and your usual binding description. Those helpers belong to your configuration, not to Sidepad. Bind other public actions in the same way if desired.

## Settings

Set these in Noctalia's Sidepad plugin settings. Dimensions are logical compositor pixels.

| Key | Default | Meaning |
| --- | --- | --- |
| `narrow_width` | 900 | Narrow-mode width; positive. |
| `wide_width` | 1200 | Wide-mode width; positive. |
| `edge_gap` | 10 | Gap from the left or right edge; nonnegative. |
| `top_gap` | 100 | Gap from the output's top edge; nonnegative. |
| `bottom_gap` | 100 | Gap from the output's bottom edge; nonnegative. |
| `launch_timeout_ms` | 5000 | Maximum mapping wait after launching; increase for slow applications. |

With output `(x, y, width, height)`, placement starts at `x + edge_gap` on the left or `x + output.width - pad.width - edge_gap` on the right; vertical placement starts at `y + top_gap` with height `output.height - top_gap - bottom_gap`. Gaps and dimensions are clamped to leave a positive size within the output. Width mode starts narrow on controller restart and is shared across pads, not a per-pad preference.

## Errors and recovery

The widget and panel display configuration, dependency, launch, duplicate-window and compositor errors. Explicit user-action failures also produce a Noctalia error notification; background failures do not repeatedly notify.

| Error | What to fix |
| --- | --- |
| Missing/malformed `pads.json`, invalid/duplicate IDs or classes | Edit the user-owned file, then disable/enable Sidepad. The root must be `{"version":1,"pads":[...]}`. Every pad needs `id`, `name`, `class` and a nonempty string argv `command`; `icon` is optional. IDs allow lowercase ASCII letters, digits, `-` and `_`; classes allow ASCII letters, digits, `.`, `_`, `@`, `+` and `-`, not selectors or regexes. IDs and classes must be unique. |
| Missing executable, `hyprctl` or `socat` | Install it or fix the Noctalia process's `PATH`; remove unwanted pad definitions. Reload after configuration or environment changes. |
| Duplicate matching windows / changed target | Close or reclassify the extra window yourself, then `refresh` and retry. Sidepad refuses to guess or move, focus or close an arbitrary match. |
| Launch timeout | Check command, absolute profile paths and exact observed class. Resolve first-run dialogs and increase `launch_timeout_ms` if needed. A late window is adopted on refresh/retry rather than intentionally duplicated. |
| Failed/rejected compositor command, invalid output geometry, stream failure | Check the Hyprland session and Lua API, focused output and settings. Repair the cause, then `refresh` or retry; reload for changed configuration. The event stream reconnects automatically. |

A partial operation can leave changed compositor state; read the resulting status instead of assuming rollback. A saved selection or edge remains saved if later placement fails. Correct the cause and retry. No force-kill recovery is provided.

## Optional anti-flash rule — not an installation step

A directly launched application may briefly appear before its mapped window is moved. Sidepad does not install dynamic rules or require anti-flash rules. If that flash bothers you, you may separately add user-owned rules to your Lua Hyprland configuration, using the exact dedicated classes you verified:

```lua
hl.window_rule({
    match = { class = "^noctalia-sidepad-terminal$" },
    workspace = "special:noctalia-sidepad-terminal silent",
})
hl.window_rule({
    match = { class = "^noctalia-sidepad-browser$" },
    workspace = "special:noctalia-sidepad-browser silent",
})
hl.window_rule({
    match = { class = "^noctalia-sidepad-code$" },
    workspace = "special:noctalia-sidepad-code silent",
})
```

Keep only rules for pads you use, and update both class and derived workspace if you rename a pad. `silent` routes the initial window without revealing the workspace; the controller still applies floating, geometry, visibility and focus. Consult the [Hyprland window-rule reference](https://wiki.hypr.land/configuring/core/rules/window-rules/) for your installed version. This snippet describes Hyprland's public API; it does not copy or adapt ML4W's GPL source.

## Verification

From this repository, run `python3 scripts/check-catalog.py` and `LUAU=/path/to/luau ./sidepad/selftest.sh`. The existing harness loads the shipped three-pad example through the real controller against a stubbed Noctalia/compositor model. It checks parsing, action routing and lifecycle behavior, not real application flags, source installation or desktop outcomes.

On the target Noctalia/Hyprland session, record the tested revision and versions, install/enable through the plugin source, configure the examples above and test each with `noctalia msg plugin magus/sidepad:controller all select <id>`. Verify a single window with the exact dedicated class in `hyprctl -j clients`, then run public `toggle` twice and observe hide/show without a second process. Check widget/panel agreement and that ordinary application windows stay untouched. Disable/enable and confirm the surviving pad is adopted. Compare your Hyprland configuration files before and after setup to confirm no automatic edits; add neither optional bindings nor anti-flash rules during that comparison. Capture actual results, not just successful IPC delivery, which does not prove the asynchronous action succeeded.

Target install/enable and application-class smoke evidence is still needed for the initial release; the repository harness is not a substitute for that evidence.

## Deferred

No graphical pad-definition editor, per-pad geometry/monitor policy, multiple windows per pad, launcher provider, native-content pads, non-Hyprland adapter, force-kill or exact ML4W off-screen animation is enabled. Runtime behavior is a rewrite using Noctalia and Hyprland interfaces, not the ML4W Bash dispatcher.
