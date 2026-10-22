#!/usr/bin/env python3
"""Export the shipped animation using Noctalia's actual Tabler font and Cairo.

This models Glyph/Flex centering and CairoGlyphRenderer's padded, pixel-snapped
alpha tiles. It is a native-font raster probe, not a running Noctalia screenshot.
"""
import argparse
import base64
import ctypes as C
import ctypes.util
import hashlib
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--font", type=Path, required=True, help="Noctalia's noctalia-tabler.ttf")
args = parser.parse_args()
source = Path(__file__).with_name("icon.luau").read_text()
runner = "local icon = (function()\n" + source + "\nend)()\n" + '''
for _, state in ipairs({ "idle", "working", "waiting", "unknown" }) do
  for frame = 0, 11 do
    print(state .. "|" .. table.concat(icon.frame(state, frame * icon.interval), "/"))
  end
end
print("interval|" .. icon.interval)
print("pixelSize|" .. icon.pixelSize)
'''
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "frames.luau"
    path.write_text(runner)
    result = subprocess.run([os.environ.get("LUAU", "luau"), str(path)], check=True, text=True, capture_output=True)
frames = {}
settings = {}
for line in result.stdout.splitlines():
    state, value = line.split("|", 1)
    if state in ("interval", "pixelSize"):
        settings[state] = float(value)
        continue
    rows = value.split("/")
    assert len(rows) == 20 and all(len(row) == 20 and set(row) <= {" ", "#"} for row in rows)
    frames.setdefault(state, []).append(rows)
assert all(len(value) == 12 for value in frames.values()) and len(frames) == 4
assert all(len({tuple(f) for f in frames[state]}) > 1 for state in ("working", "waiting"))

# Match the host's unhinted grayscale icon-font path, rather than substituting
# solid SVG rectangles for glyphs whose alpha coverage may be quite different.
ft = C.CDLL(ctypes.util.find_library("freetype"))
ca = C.CDLL(ctypes.util.find_library("cairo"))
P, I, D = C.c_void_p, C.c_int, C.c_double

def bind(lib, name, result, *arguments):
    function = getattr(lib, name)
    function.restype, function.argtypes = result, arguments
    return function

class Glyph(C.Structure):
    _fields_ = [("index", C.c_ulong), ("x", D), ("y", D)]

class Extents(C.Structure):
    _fields_ = [(name, D) for name in ("x", "y", "width", "height", "advance_x", "advance_y")]

bind(ft, "FT_Init_FreeType", I, C.POINTER(P))
bind(ft, "FT_New_Face", I, P, C.c_char_p, C.c_long, C.POINTER(P))
bind(ft, "FT_Get_Char_Index", C.c_uint, P, C.c_ulong)
bind(ft, "FT_Set_Pixel_Sizes", I, P, C.c_uint, C.c_uint)
bind(ca, "cairo_ft_font_face_create_for_ft_face", P, P, I)
bind(ca, "cairo_image_surface_create", P, I, I, I)
bind(ca, "cairo_create", P, P)
bind(ca, "cairo_destroy", None, P)
bind(ca, "cairo_surface_destroy", None, P)
bind(ca, "cairo_set_font_face", None, P, P)
bind(ca, "cairo_set_font_size", None, P, D)
bind(ca, "cairo_font_options_create", P)
bind(ca, "cairo_font_options_set_antialias", None, P, I)
bind(ca, "cairo_font_options_set_hint_style", None, P, I)
bind(ca, "cairo_font_options_set_hint_metrics", None, P, I)
bind(ca, "cairo_set_font_options", None, P, P)
bind(ca, "cairo_glyph_extents", None, P, C.POINTER(Glyph), I, C.POINTER(Extents))
bind(ca, "cairo_show_glyphs", None, P, C.POINTER(Glyph), I)
bind(ca, "cairo_set_source_rgba", None, P, D, D, D, D)
bind(ca, "cairo_set_source_surface", None, P, P, D, D)
bind(ca, "cairo_paint", None, P)
bind(ca, "cairo_surface_write_to_png", I, P, C.c_char_p)
bind(ca, "cairo_image_surface_create_from_png", P, C.c_char_p)
bind(ca, "cairo_image_surface_get_data", P, P)
bind(ca, "cairo_image_surface_get_stride", I, P)

library, face = P(), P()
assert ft.FT_Init_FreeType(C.byref(library)) == 0
assert ft.FT_New_Face(library, os.fsencode(args.font.resolve()), 0, C.byref(face)) == 0
font_face = ca.cairo_ft_font_face_create_for_ft_face(face, 0)
options = ca.cairo_font_options_create()
ca.cairo_font_options_set_antialias(options, 2)  # GRAY
ca.cairo_font_options_set_hint_style(options, 1)  # NONE
ca.cairo_font_options_set_hint_metrics(options, 1)  # OFF
index = ft.FT_Get_Char_Index(face, 0xFC40)  # Noctalia Tabler square-filled
assert index, "The font must include Noctalia's square-filled glyph (U+FC40)"

def rounded(value):
    return math.floor(value + 0.5) if value >= 0 else math.ceil(value - 0.5)

def raster(rows, scale, pixel_size, destination):
    size = pixel_size * scale
    ft.FT_Set_Pixel_Sizes(face, 0, rounded(size))
    surface = ca.cairo_image_surface_create(0, 1, 1)
    cr = ca.cairo_create(surface)
    ca.cairo_set_font_face(cr, font_face)
    ca.cairo_set_font_options(cr, options)
    ca.cairo_set_font_size(cr, size)
    glyph, extents = Glyph(index, 0, 0), Extents()
    ca.cairo_glyph_extents(cr, C.byref(glyph), 1, C.byref(extents))
    ca.cairo_destroy(cr)
    ca.cairo_surface_destroy(surface)
    tile = ca.cairo_image_surface_create(0, math.ceil(extents.width) + 2, math.ceil(extents.height) + 2)
    cr = ca.cairo_create(tile)
    ca.cairo_set_font_face(cr, font_face)
    ca.cairo_set_font_options(cr, options)
    ca.cairo_set_font_size(cr, size)
    ca.cairo_set_source_rgba(cr, 1, 1, 1, 1)
    glyph.x, glyph.y = 1 - extents.x, 1 - extents.y
    ca.cairo_show_glyphs(cr, C.byref(glyph), 1)
    ca.cairo_destroy(cr)
    surface = ca.cairo_image_surface_create(0, rounded(20 * scale), rounded(20 * scale))
    cr = ca.cairo_create(surface)
    box = rounded(size)
    inset = rounded((scale - box) / 2)
    for y, row in enumerate(rows):
        for x, pixel in enumerate(row):
            if pixel == "#":
                left = rounded(rounded(x * scale) + inset + box / 2 - extents.width / 2 - 1)
                top = rounded(rounded(y * scale) + inset + box / 2 - extents.height / 2 - 1)
                ca.cairo_set_source_surface(cr, tile, left, top)
                ca.cairo_paint(cr)
    assert ca.cairo_surface_write_to_png(surface, os.fsencode(destination)) == 0
    ca.cairo_destroy(cr)
    ca.cairo_surface_destroy(surface)
    ca.cairo_surface_destroy(tile)
    return "data:image/png;base64," + base64.b64encode(Path(destination).read_bytes()).decode()

images = {}
with tempfile.TemporaryDirectory() as tmp:
    # A filled grid must remain filled when alpha is thresholded at 50%, not
    # break into separated dots at the user's fractional widget scale.
    for scale in (1, 1.25):
        path = Path(tmp) / "coverage.png"
        raster(["#" * 20] * 20, scale, settings["pixelSize"], path)
        surface = ca.cairo_image_surface_create_from_png(os.fsencode(path))
        stride = ca.cairo_image_surface_get_stride(surface) // 4
        pixels = C.cast(ca.cairo_image_surface_get_data(surface), C.POINTER(C.c_uint32))
        n = rounded(20 * scale)
        minimum = min(pixels[y * stride + x] >> 24 for y in range(4, n - 4) for x in range(4, n - 4))
        ca.cairo_surface_destroy(surface)
        assert minimum >= 128, f"Glyph grid has low-coverage seams at scale {scale}: alpha {minimum}/255"
    for state, animation in frames.items():
        images[state] = {str(scale): [raster(rows, scale, settings["pixelSize"], Path(tmp) / "frame.png")
                                    for rows in animation] for scale in (1, 1.25)}
    # Keep the old renderer visible as a comparison, using the exact same font.
    old = raster(frames["idle"][0], 1.25, 4 / 3, Path(tmp) / "before.png")

print('''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Pi Companion · native-font review</title>
<style>
:root { color-scheme: dark; font: 16px system-ui; background: #17151d; color: #efebf6; }
body { max-width: 1000px; margin: 40px auto; padding: 0 24px; }
h1 { font-size: 28px; margin-bottom: 8px; } p { line-height: 1.6; color: #c8c1d5; }
.controls { display: flex; flex-wrap: wrap; gap: 20px; align-items: center; margin: 24px 0; }
button, select { font: inherit; padding: 8px 14px; border-radius: 8px; border: 1px solid #796c90; background: #30273e; color: #fff; }
label { display: flex; align-items: center; gap: 8px; }
.cards { display: grid; grid-template-columns: repeat(auto-fit,minmax(220px,1fr)); gap: 16px; }
.card { border: 1px solid #494052; border-radius: 14px; overflow: hidden; }
.card h2 { font-size: 18px; margin: 20px 20px 4px; } .card p { font-size: 14px; margin: 0 20px 20px; }
.sample { background: var(--bar,#201c29); color: var(--ink,#b08bf5); display: flex; align-items: center; justify-content: center; gap: 24px; padding: 24px 12px; }
.icon { display: block; width: 20px; height: 20px; background: currentColor; mask-size: 100% 100%; }
.zoom { display: flex; align-items: center; justify-content: center; width: 125px; height: 125px; }
.zoom .icon { transform: scale(5); image-rendering: pixelated; }
.scaled { width: 25px; height: 25px; } .note { border-left: 3px solid #b08bf5; padding-left: 16px; }
footer { margin-top: 24px; font-size: 14px; overflow-wrap: anywhere; }
</style>
<h1>Pi Companion · native-font raster preview</h1>
<p>Thick robot, thin π / heartbeat / bell, unchanged warning. These are Cairo-rendered Tabler glyphs, not idealized SVG squares.</p>
<div class="controls">
<label>Icon color <input id="color" type="color" value="#b08bf5"></label>
<label>Bar <select id="theme"><option value="#201c29">Dark</option><option value="#f5f0fa">Light</option><option value="#000000">Black</option></select></label>
<button id="pause" type="button">Pause animation</button><button id="step" type="button">Next frame</button>
<span id="frame" aria-live="off"></span></div><div class="cards">
''')
for state, title in (("idle", "Idle / stopped / seen"), ("working", "Processing"), ("waiting", "Needs you"), ("unknown", "Unreadable status")):
    print(f'<section class="card"><h2>{title}</h2><div class="sample"><div class="zoom"><span class="icon scaled" data-state="{state}" data-scale="1.25" role="img" aria-label="{title}"></span></div></div>'
          f'<div class="sample"><span class="icon" data-state="{state}" data-scale="1" aria-hidden="true"></span>'
          f'<span class="icon scaled" data-state="{state}" data-scale="1.25" aria-hidden="true"></span></div></section>')
print(f'''</div><p>Top: 25 px raster enlarged 5×. Bottom: actual 20 px and 25 px (1.25× widget scale).</p>
<h2>Before: the old spaced-dot renderer</h2><div class="sample"><div class="zoom"><span class="icon scaled" style="mask-image:url('{old}')"></span></div></div>
<p class="note">The font, unhinted grayscale rasterization, one-pixel texture padding, cell centering and pixel snapping follow Noctalia’s Glyph/Flex/CairoGlyphRenderer code. The revised cells overlap the font’s alpha edges to remove dotted seams. This is a renderer model at output scale 1, not a live Noctalia capture: different output DPI, host versions, clipping and GPU rendering still need a desktop check. Artwork and timing come directly from icon.luau.</p>
<footer>Font SHA-256: {hashlib.sha256(args.font.read_bytes()).hexdigest()}<br>Self-contained, no network requests. Reduced-motion preference pauses playback initially.</footer>
<script>''')
print("const images = " + json.dumps(images) + ";")
print("const interval = " + str(settings["interval"]) + ";")
print('''let frame = 0;
let paused = matchMedia('(prefers-reduced-motion: reduce)').matches;
const pause = document.getElementById('pause');
function draw() {
  for (const icon of document.querySelectorAll('[data-state]'))
    icon.style.maskImage = `url('${images[icon.dataset.state][icon.dataset.scale][frame]}')`;
  document.getElementById('frame').textContent = `Frame ${frame + 1}/12 · ${interval} ms/frame`;
  pause.textContent = paused ? 'Play animation' : 'Pause animation';
}
pause.onclick = () => { paused = !paused; draw(); };
document.getElementById('step').onclick = () => { paused = true; frame = (frame + 1) % 12; draw(); };
document.getElementById('color').oninput = e => document.body.style.setProperty('--ink', e.target.value);
document.getElementById('theme').onchange = e => document.body.style.setProperty('--bar', e.target.value);
setInterval(() => { if (!paused) { frame = (frame + 1) % 12; draw(); } }, interval);
draw();
</script></html>''')
