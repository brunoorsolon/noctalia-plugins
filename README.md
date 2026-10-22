# Noctalia Plugins

A small collection of plugins for [Noctalia](https://github.com/noctalia-dev/noctalia).

## Add this source

Open **Settings → Plugins → Sources**, add a Git source named `magus` with this location, then enable the plugin you want:

```text
https://github.com/brunoorsolon/noctalia-plugins.git
```

Or run:

```sh
noctalia msg plugins source add magus git https://github.com/brunoorsolon/noctalia-plugins.git
noctalia msg plugins enable magus/masked-wallpaper
noctalia msg plugins enable magus/dictation
noctalia msg plugins enable magus/pi-companion
noctalia msg plugins enable magus/sidepad
```

## Plugins

| Plugin | Description |
| --- | --- |
| [Masked Wallpaper Backdrop](masked-wallpaper/) | Keeps a blurred, tinted, decorated lockscreen backdrop in sync with the wallpaper. |
| [Dictation](dictation/) | Records the microphone you choose and transcribes it with an installed recognition engine and GGUF model. |
| [Pi Companion](pi-companion/) | Your desktop agent companion, powered by [Pi](https://pi.dev). Keeps Pi one shortcut away and shows when it is working or needs you. |
| [Sidepad](sidepad/) | Shows a selected external application on a dedicated Hyprland special workspace, with native bar and panel controls. |

Each plugin documents its own requirements, setup, and usage in its directory. [Sidepad requires a user-owned `pads.json`](sidepad/#installation); enabling it does not install applications or create pad definitions.

The [Dictation](dictation/) plugin consumes an already-installed recognition engine. [source-installer/](source-installer/) is a separate graphical tool that builds that engine from one pinned source revision for users who have none; it is not part of the plugin and Noctalia does not load or run it.
