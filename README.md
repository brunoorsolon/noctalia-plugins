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
| [Dictation](dictation/) | Transcribes a saved 16 kHz WAV with an installed recognition engine and GGUF model. |

Each plugin documents its own requirements, setup, and usage in its directory.
