#!/usr/bin/env python3
"""Emit a self-contained icon review page from the shipped Luau artwork."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

source = Path(__file__).with_name("icon.luau").read_text()
runner = "local icon = (function()\n" + source + "\nend)()\n" + '''
for _, state in ipairs({ "idle", "working", "waiting", "unknown" }) do
  for frame = 0, 11 do
    print(state .. "|" .. table.concat(icon.frame(state, frame * icon.interval), "/"))
  end
end
print("interval|" .. icon.interval)
'''
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / "frames.luau"
    path.write_text(runner)
    result = subprocess.run(
        [os.environ.get("LUAU", "luau"), str(path)],
        check=True, text=True, capture_output=True,
    )
frames = {}
interval = None
for line in result.stdout.splitlines():
    state, value = line.split("|", 1)
    if state == "interval":
        interval = int(value)
        continue
    rows = value.split("/")
    assert len(rows) == 20 and all(len(row) == 20 for row in rows)
    assert all(set(row) <= {" ", "#"} for row in rows)
    frames.setdefault(state, []).append(rows)
assert interval and len(frames) == 4
assert all(len(value) == 12 for value in frames.values())
assert len({tuple(frame) for frame in frames["working"]}) > 1
assert len({tuple(frame) for frame in frames["waiting"]}) > 1

print('''<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Pi Scratchpad · icon review</title>
<style>
:root { color-scheme: dark; font: 16px system-ui; background: #17151d; color: #efebf6; }
body { max-width: 1000px; margin: 40px auto; padding: 0 24px; }
h1 { font-size: 28px; margin-bottom: 8px; } p { line-height: 1.6; color: #c8c1d5; }
.controls { display: flex; flex-wrap: wrap; gap: 20px; align-items: center; margin: 24px 0; }
button, select { font: inherit; padding: 8px 14px; border-radius: 8px; border: 1px solid #796c90; background: #30273e; color: #fff; }
label { display: flex; align-items: center; gap: 8px; } input { cursor: pointer; }
.cards { display: grid; grid-template-columns: repeat(auto-fit,minmax(220px,1fr)); gap: 16px; }
.card { border: 1px solid #494052; border-radius: 14px; overflow: hidden; }
.card h2 { font-size: 18px; margin: 20px 20px 4px; } .card p { font-size: 14px; margin: 0 20px 20px; }
.sample { background: var(--bar,#201c29); color: var(--ink,#b08bf5); display: flex; align-items: center; justify-content: center; gap: 24px; padding: 24px 12px; }
.large { width: 100px; height: 100px; } .native { width: 20px; height: 20px; } .scaled { width: 25px; height: 25px; }
.bar { justify-content: flex-start; border-radius: 10px; min-height: 32px; gap: 20px; margin: 18px 0; padding: 8px 18px; }
.note { border-left: 3px solid #b08bf5; padding-left: 16px; }
footer { margin-top: 24px; font-size: 14px; } svg { display: block; flex-shrink: 0; }
</style>
<h1>Pi Scratchpad · final artwork</h1>
<p>One pixel-display robot. Bold π at rest, a scrolling heartbeat while working, and a swaying bell when Pi needs you. Stopped uses exactly the idle artwork.</p>
<div class="controls">
<label>Icon color <input id="color" type="color" value="#b08bf5"></label>
<label>Bar <select id="theme"><option value="#201c29">Dark</option><option value="#f5f0fa">Light</option><option value="#000000">Black</option></select></label>
<button id="pause" type="button">Pause animation</button>
<button id="step" type="button">Next frame</button>
<span id="frame" aria-live="off"></span>
</div>
<div class="cards">
''')
for state, title, description in (
    ("idle", "Idle / stopped", "Also shown after viewing and hiding a waiting Pi."),
    ("working", "Processing", "Heartbeat scrolls left; it never becomes idle just because you hide Pi."),
    ("waiting", "Needs you", "Bell sways twice, then rests briefly. A new wait rearms attention."),
    ("unknown", "Unreadable status", "A visible warning, never a reason to launch a duplicate Pi."),
):
    print(f'<section class="card"><h2>{title}</h2><p>{description}</p>'
          f'<div class="sample"><svg class="large" data-state="{state}" viewBox="0 0 20 20" role="img" aria-label="{title}"></svg></div>'
          f'<div class="sample"><svg class="native" data-state="{state}" viewBox="0 0 20 20" aria-hidden="true"></svg>'
          f'<svg class="scaled" data-state="{state}" viewBox="0 0 20 20" aria-hidden="true"></svg></div></section>')
print('''</div>
<p>Each card: enlarged 5×, then actual 20 px and your 1.25× scale (25 px).</p>
<p class="note">Frames and timing come directly from the shipped <code>icon.luau</code>, not a separately drawn mockup. The browser draws the pixel grid as SVG; Noctalia draws it with native filled-square glyphs so your Icon Color and widget Color settings apply. Font antialiasing, fractional scale, and final bar layout still need a live Noctalia check. This page does not control Pi.</p>
<footer>Local, self-contained preview. No network requests or dependencies. Reduced-motion preference pauses playback initially; Play and Next frame remain available.</footer>
<script>
''')
print("const frames = " + json.dumps(frames) + ";")
print("const interval = " + str(interval) + ";")
print('''let frame = 0;
let paused = matchMedia('(prefers-reduced-motion: reduce)').matches;
const pause = document.getElementById('pause');
function draw() {
  for (const svg of document.querySelectorAll('[data-state]')) {
    const rows = frames[svg.dataset.state][frame];
    let pixels = '';
    rows.forEach((row,y) => [...row].forEach((pixel,x) => {
      if (pixel === '#') pixels += `<rect x="${x}" y="${y}" width="1" height="1" fill="currentColor"/>`;
    }));
    svg.innerHTML = pixels;
  }
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
