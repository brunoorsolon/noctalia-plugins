# Masked Wallpaper Backdrop

A Noctalia plugin that keeps a blurred, tinted, decorated lockscreen backdrop in sync with your wallpaper.

The plugin owns the settings and the trigger; `generate-masked-wallpaper.sh` does the pixels. The result is one flattened, fully opaque JPEG per output, layered top to bottom as decoration 1, decoration 2, decoration 3, masked blur/tint, original wallpaper. Because it is flattened, nothing has to line up with Noctalia's own wallpaper, and the same shape works on outputs of different resolutions.

## Plugin

| Field | Value |
| --- | --- |
| ID | `magus/masked-wallpaper` |
| Entries | Service: `sync` |

## Requirements

Install `imagemagick`.

## Usage

The folder must be named `masked-wallpaper`, matching the part of the plugin id after the slash. Noctalia will not find it under any other name.

    mkdir -p ~/.local/share/noctalia/plugins
    cp -r masked-wallpaper ~/.local/share/noctalia/plugins/
    noctalia msg plugins enable magus/masked-wallpaper

Or add the containing directory as a local source under Settings → Plugins and toggle it on.

## Configure

Settings → Plugins → Masked Wallpaper Backdrop. Set **Output folder** to an absolute path you will retype a few times below, for example `/home/you/.cache/noctalia/masked-wallpaper`. Generated files land there as `masked-wallpaper-<connector>.jpg`. Leaving it empty uses the plugin's own data folder, which works but is harder to point anything at.

Then pick a **Shape mask**: a transparent PNG where opaque pixels get blurred and tinted and transparent pixels keep the sharp wallpaper. Decoration slots 1–3 are optional transparent PNGs composited above the blur, 1 on top. **Recolour** replaces a layer's colours with the colour below while keeping its transparency — leave it off for artwork that is already coloured.

Aligning the shape and the decorations is your job. The generator composites them as given and does not check.

## Wire up the hooks and the palette

Colours may be a literal `#rrggbb` or a palette role name — `primary`, `on_surface`, `surface_variant`, and the other thirteen. A role name tracks your theme, so the backdrop repaints itself when the wallpaper changes the palette. Noctalia has no API that hands a plugin a resolved colour, so it renders the palette to a file for us instead.

In your own config at `~/.config/noctalia/config.toml` — the hand-edited layer, not the GUI-managed `~/.local/state/noctalia/settings.toml`:

    [hooks]
    wallpaper_changed = "noctalia msg plugin magus/masked-wallpaper:sync all regenerate"
    colors_changed = "noctalia msg plugin magus/masked-wallpaper:sync all regenerate"

    [theme.templates.user.masked_wallpaper]
    input_path = "$XDG_DATA_HOME/noctalia/plugins/masked-wallpaper/masked-wallpaper-colors.env"
    output_path = "/home/you/.cache/noctalia/masked-wallpaper/palette.env"

If the template never renders, check whether `[theme.templates]` in your state `settings.toml` is shadowing it, and move the block there instead.

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

Enabling exports the plugin into `~/.local/state/noctalia/plugins/materialized/`, and the service runs from that copy — `noctalia.pluginDir()` is the runtime copy, not your source folder. The manifest is re-read from the source folder, so `plugin.toml` edits appear at once, but an edited `.luau` or shell script keeps running the exported version. After changing either, force a re-export:

    noctalia msg plugins disable magus/masked-wallpaper
    noctalia msg plugins enable magus/masked-wallpaper

## Checks

    ./selftest.sh

Runs the generator against a fake ImageMagick to check argument handling, cache reuse, palette resolution and the atomic publish. Works without ImageMagick installed.
