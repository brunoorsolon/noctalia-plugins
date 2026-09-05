#!/usr/bin/env bash
# Smoke test for generate-masked-wallpaper.sh with a fake ImageMagick, so it runs
# anywhere: checks argument handling, layer order, cache reuse, atomic publish and the snippet.
set -euo pipefail
cd -- "$(dirname -- "$0")"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/magick" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
last=${*: -1}
[[ "$last" == null: ]] && exit 0
: > "${last#*:}"
FAKE
chmod +x "$work/magick"
: > "$work/wall.png"
: > "$work/shape.png"
: > "$work/deco-1.png"
: > "$work/deco-2.png"
: > "$work/deco-3.png"
: > "$work/transform.png"

run() {
  FAKE_LOG="$work/magick.log" PATH="$work:$PATH" ./generate-masked-wallpaper.sh \
    --wallpaper "$work/wall.png" --shape "$work/shape.png" \
    --decoration-1 "$work/deco-1.png" --decoration-color-1 '#f5f1ed' \
    --decoration-2 "$work/deco-2.png" \
    --decoration-3 "$work/deco-3.png" \
    --width 2560 --height 1440 --connector DP-3 \
    --cache-dir "$work/cache" --dest "$work/out/backdrop.jpg" "$@"
}

first=$(run)
[[ "$first" == generated:* ]] || { echo "expected a fresh generation, got: $first"; exit 1; }
[[ -f "$work/out/backdrop.jpg" ]] || { echo "publish did not reach the dest"; exit 1; }
grep -qF "image_path = \"$work/out/backdrop.jpg\"" "$work"/cache/*.toml || { echo "snippet points at the cache file, not the dest"; exit 1; }
grep -qF 'opacity = 1.0' "$work"/cache/*.toml || { echo "snippet lost opacity 1.0"; exit 1; }
bottom_line=$(grep -n 'merged-2.miff' "$work/magick.log" | head -n 1 | cut -d: -f1)
middle_line=$(grep -n 'merged-1.miff' "$work/magick.log" | head -n 1 | cut -d: -f1)
top_line=$(grep -n 'merged-0.miff' "$work/magick.log" | head -n 1 | cut -d: -f1)
((bottom_line < middle_line && middle_line < top_line)) || { echo "decorations must be applied 3, 2, 1 so 1 stays on top"; exit 1; }

second=$(run)
[[ "$second" == cache\ hit:* ]] || { echo "expected a cache hit, got: $second"; exit 1; }

rm -f "$work/out/backdrop.jpg"
run >/dev/null
[[ -f "$work/out/backdrop.jpg" ]] || { echo "a cache hit must still republish a missing dest"; exit 1; }

[[ -z "$(find "$work/out" -name '.publish.*')" ]] || { echo "left a temporary publish file behind"; exit 1; }
[[ "$(run --blur 0.9)" == generated:* ]] || { echo "changing blur must miss the cache"; exit 1; }
[[ "$(run --preset facet)" == generated:* ]] || { echo "selecting a preset must miss the custom cache"; exit 1; }
[[ "$(run --preset facet)" == cache\ hit:* ]] || { echo "an unchanged preset should hit the cache"; exit 1; }
[[ "$(run --preset facet-aperture)" == generated:* ]] || { echo "changing the preset identity must miss the cache"; exit 1; }

transform_run() {
  run --asset-root "$work" --transforms 'transform.png,1.1,0.04,0,false,1.2,1.3' "$@"
}
[[ "$(transform_run)" == generated:* ]] || { echo "adding a transform must miss the cache"; exit 1; }
[[ "$(transform_run)" == cache\ hit:* ]] || { echo "an unchanged transform should hit the cache"; exit 1; }
printf x >>"$work/transform.png"
[[ "$(transform_run)" == generated:* ]] || { echo "changing a transform mask must miss the cache"; exit 1; }
[[ "$(run --asset-root "$work" --transforms 'window,1.2,0,0,false,1,1')" == generated:* ]] || { echo "changing transform metadata must miss the cache"; exit 1; }

before=$(sha256sum "$work/out/backdrop.jpg")
if run --width nope >/dev/null 2>&1; then echo "invalid arguments must fail"; exit 1; fi
[[ "$(sha256sum "$work/out/backdrop.jpg")" == "$before" ]] || { echo "a failed run must preserve the published image"; exit 1; }

# Palette role names resolve through the file Noctalia renders, and a repainted
# palette must invalidate the cache even though the arguments never changed.
printf 'primary=#aabbcc\n' >"$work/palette.env"
palette_run() { run --palette "$work/palette.env" --tint primary "$@"; }
[[ "$(palette_run)" == generated:* ]] || { echo "a palette role should resolve"; exit 1; }
[[ "$(palette_run)" == cache\ hit:* ]] || { echo "an unchanged palette should hit the cache"; exit 1; }
printf 'primary=#ddeeff\n' >"$work/palette.env"
[[ "$(palette_run)" == generated:* ]] || { echo "a repainted palette must miss the cache"; exit 1; }

if run --palette "$work/palette.env" --tint no_such_role 2>"$work/err"; then
  echo "an undefined palette role must fail"; exit 1
fi
grep -q 'does not define' "$work/err" || { echo "expected a clear undefined-role error"; exit 1; }
grep -q 'FAILED' "$work/cache/generate.log" || { echo "failures must reach the log"; exit 1; }

echo "selftest ok"
