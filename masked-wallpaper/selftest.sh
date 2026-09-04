#!/usr/bin/env bash
# Smoke test for generate-masked-wallpaper.sh with a fake ImageMagick, so it runs
# anywhere: checks argument handling, cache reuse, atomic publish and the snippet.
set -euo pipefail
cd -- "$(dirname -- "$0")"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/magick" <<'FAKE'
#!/usr/bin/env bash
last=${*: -1}
[[ "$last" == null: ]] && exit 0
: > "${last#*:}"
FAKE
chmod +x "$work/magick"
: > "$work/wall.png"
: > "$work/shape.png"
: > "$work/deco.png"

run() {
  PATH="$work:$PATH" ./generate-masked-wallpaper.sh \
    --wallpaper "$work/wall.png" --shape "$work/shape.png" \
    --decoration-1 "$work/deco.png" --decoration-color-1 '#f5f1ed' \
    --width 2560 --height 1440 --connector DP-3 \
    --cache-dir "$work/cache" --dest "$work/out/backdrop.jpg" "$@"
}

first=$(run)
[[ "$first" == generated:* ]] || { echo "expected a fresh generation, got: $first"; exit 1; }
[[ -f "$work/out/backdrop.jpg" ]] || { echo "publish did not reach the dest"; exit 1; }
grep -qF "image_path = \"$work/out/backdrop.jpg\"" "$work"/cache/*.toml || { echo "snippet points at the cache file, not the dest"; exit 1; }
grep -qF 'opacity = 1.0' "$work"/cache/*.toml || { echo "snippet lost opacity 1.0"; exit 1; }

second=$(run)
[[ "$second" == cache\ hit:* ]] || { echo "expected a cache hit, got: $second"; exit 1; }

rm -f "$work/out/backdrop.jpg"
run >/dev/null
[[ -f "$work/out/backdrop.jpg" ]] || { echo "a cache hit must still republish a missing dest"; exit 1; }

[[ -z "$(find "$work/out" -name '.publish.*')" ]] || { echo "left a temporary publish file behind"; exit 1; }
[[ "$(run --blur 0.9)" == generated:* ]] || { echo "changing blur must miss the cache"; exit 1; }

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
