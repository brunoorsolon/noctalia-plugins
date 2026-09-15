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
```

## Plugins

| Plugin | Description |
| --- | --- |
| [Masked Wallpaper Backdrop](masked-wallpaper/) | Keeps a blurred, tinted, decorated lockscreen backdrop in sync with the wallpaper. |
| [Dictation](dictation/) | Records the microphone you choose and transcribes it with an installed recognition engine and GGUF model. |

Each plugin documents its own requirements, setup, and usage in its directory.

The [Dictation](dictation/) plugin consumes an already-installed recognition engine. [source-installer/](source-installer/) is a separate graphical tool that builds that engine from one pinned source revision for users who have none; it is not part of the plugin and Noctalia does not load or run it.
