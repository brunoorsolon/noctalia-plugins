# Masked Wallpaper Backdrop

A Noctalia plugin that keeps a blurred, tinted, decorated lockscreen backdrop in sync with your wallpaper.

The plugin owns the settings and the trigger; `generate-masked-wallpaper.sh` does the pixels. The result is one flattened, fully opaque JPEG per output, layered top to bottom as decoration 1, decoration 2, decoration 3, masked blur/tint, original wallpaper. Because it is flattened, nothing has to line up with Noctalia's own wallpaper, and the same shape works on outputs of different resolutions.

## Plugin

| Field | Value |
| --- | --- |
| ID | `magus/masked-wallpaper` |
| Entries | Service: `sync` |

## Requirements

Install `imagemagick`. The plugin accepts either its `magick` or `convert` command.

## Installation

Open **Settings → Plugins**, select **Add source**, and add this Git source:

| Field | Value |
| --- | --- |
| Name | `magus` |
| Kind | Git |
| Location | `https://github.com/brunoorsolon/noctalia-plugins.git` |

Enable **Masked Wallpaper Backdrop** after it appears. The equivalent commands are:

```sh
noctalia msg plugins source add magus git https://github.com/brunoorsolon/noctalia-plugins.git
noctalia msg plugins enable magus/masked-wallpaper
```

## Usage

1. Open **Settings → Plugins → Masked Wallpaper Backdrop**.
2. Choose **Center glow**, **Left panel**, or **Right panel** under **Mask preset**. Choose **Custom** to reveal a PNG file picker instead.
3. Set **Output folder** to an absolute path such as `/home/you/.cache/noctalia/masked-wallpaper`. Generated files use the stable name `masked-wallpaper-<connector>.jpg`. Leaving the setting empty uses the plugin data directory.
4. Optionally choose up to three transparent decoration PNGs. Decoration 1 is the top layer. Enabling **Recolour** reveals that decoration's colour setting.
5. Complete the palette hooks and lockscreen sticker setup below.

A custom mask uses its alpha channel: opaque pixels get blurred and tinted, while transparent pixels keep the sharp wallpaper. The generator stretches masks and decorations to the output size; align custom assets before selecting them.

## Wire up the hooks and the palette

Colours may be a literal `#rrggbb` or a palette role name — `primary`, `on_surface`, `surface_variant`, and the other thirteen. A role name tracks your theme, so the backdrop repaints itself when the wallpaper changes the palette. Noctalia has no API that hands a plugin a resolved colour, so it renders the palette to a file for us instead.

In your own config at `~/.config/noctalia/config.toml` — the hand-edited layer, not the GUI-managed `~/.local/state/noctalia/settings.toml`:

    [hooks]
    wallpaper_changed = "noctalia msg plugin magus/masked-wallpaper:sync all regenerate"
    colors_changed = "noctalia msg plugin magus/masked-wallpaper:sync all regenerate"

    [theme.templates.user.masked_wallpaper]
    input_path = "/home/you/.local/state/noctalia/plugins/materialized/magus/masked-wallpaper/masked-wallpaper-colors.env"
    output_path = "/home/you/.cache/noctalia/masked-wallpaper/palette.env"

Replace `/home/you` with your home directory. If you chose a source name other than `magus`, replace that path segment too. If the template never renders, check whether `[theme.templates]` in your state `settings.toml` is shadowing it, and move the block there instead.

`output_path` must be your **Output folder** with `/palette.env` on the end; that is where the plugin and the script both look. Both hooks are wanted: `colors_changed` fires after the palette is resolved, and `wallpaper_changed` covers a wallpaper swap that leaves the palette alone. Firing both is harmless — the second one finds nothing changed and does nothing.

Without any hook the plugin still works, but only picks up changes on its hourly safety pass, on a settings change, or when your outputs change.

## Add the sticker, once

The plugin cannot write Noctalia's config, so point a lockscreen sticker at the output path yourself. Do it in the lockscreen widget editor, or add this to `~/.local/state/noctalia/settings.toml` with Noctalia's editor closed:

    [lockscreen_widgets.widget.masked-wallpaper-DP-3]
    type = "sticker"
    output = "DP-3"
    cx = 1280.0
    cy = 720.0
    placement_width = 2560.0
    placement_height = 1440.0
    box_width = 2560.0
    box_height = 1440.0
    rotation = 0.0

    [lockscreen_widgets.widget.masked-wallpaper-DP-3.settings]
    image_path = "/home/you/.cache/noctalia/masked-wallpaper/masked-wallpaper-DP-3.jpg"
    opacity = 1.0

Add its id first in `lockscreen_widgets.widget_order` so it sits behind the rest, keep `opacity = 1.0` and `rotation = 0.0` — the shape is tilted inside the image, not by the widget — and repeat per monitor. The path never changes again: the plugin replaces the file in place and the sticker reloads it.

Every generated file also gets a `.toml` sibling in the cache folder holding this snippet, filled in with real values.

## When something looks wrong

Every run appends to `<output folder>/cache/generate.log`, including the full argument list and any failure. The plugin launches the script detached, so this is the only place a failure shows up:

    tail -f ~/.cache/noctalia/masked-wallpaper/cache/generate.log

It is also how you find out what a colour setting actually stores: change a colour in the GUI and read the `--tint` or `--decoration-color-N` value in the next logged run. A `#rrggbb` means the picker stores literals; a bare word means it stores role names. Either works.

## Known limits

No desktop-snapshot backdrop and no animated wallpapers, since the wallpaper is baked into the image. A wallpaper change takes a second or so to appear; until then the lockscreen shows the previous backdrop.

## Updating the plugin

Noctalia updates enabled Git sources automatically by default. To update immediately:

```sh
noctalia msg plugins update magus
```

## Checks

    ./selftest.sh

Runs the generator against a fake ImageMagick to check argument handling, cache reuse, palette resolution and the atomic publish. Works without ImageMagick installed.
