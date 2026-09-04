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
```

## Plugins

| Plugin | Description |
| --- | --- |
| [Masked Wallpaper Backdrop](masked-wallpaper/) | Keeps a blurred, tinted, decorated lockscreen backdrop in sync with the wallpaper. |

Each plugin documents its own requirements, setup, and usage in its directory.
