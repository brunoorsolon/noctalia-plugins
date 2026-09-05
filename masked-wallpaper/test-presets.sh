#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "$0")"

usage() {
  cat <<'EOF'
Usage: ./test-presets.sh [WALLPAPER] [OUTPUT_DIR] [--width PX] [--height PX]
       ./test-presets.sh [--wallpaper FILE] [--output-dir DIR] [--width PX] [--height PX]

Renders all 20 bundled presets through generate-masked-wallpaper.sh.
Defaults: synthetic wallpaper, /tmp/masked-wallpaper-presets, 1280x720.
EOF
}

wallpaper=
output_dir=${TMPDIR:-/tmp}/masked-wallpaper-presets
wallpaper_set=false
output_dir_set=false
width=1280
height=720
while (($#)); do
  case "$1" in
    --wallpaper) wallpaper=${2:?missing wallpaper path}; wallpaper_set=true; shift 2 ;;
    --output-dir) output_dir=${2:?missing output directory}; output_dir_set=true; shift 2 ;;
    --width) width=${2:?missing width}; shift 2 ;;
    --height) height=${2:?missing height}; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) printf 'error: unknown option: %s\n' "$1" >&2; exit 1 ;;
    *)
      if [[ "$wallpaper_set" == false ]]; then wallpaper=$1; wallpaper_set=true
      elif [[ "$output_dir_set" == false ]]; then output_dir=$1; output_dir_set=true
      else printf 'error: unexpected argument: %s\n' "$1" >&2; exit 1
      fi
      shift
      ;;
  esac
done
[[ "$width" =~ ^[1-9][0-9]*$ && "$height" =~ ^[1-9][0-9]*$ ]] || { echo 'error: width and height must be positive integers' >&2; exit 1; }

if command -v magick >/dev/null 2>&1; then
  im=(magick); identify_image=(magick identify); compare_image=(magick compare); montage_image=(magick montage)
elif command -v convert >/dev/null 2>&1; then
  for command in identify compare montage; do
    command -v "$command" >/dev/null 2>&1 || { echo "error: ImageMagick $command is required" >&2; exit 1; }
  done
  im=(convert); identify_image=(identify); compare_image=(compare); montage_image=(montage)
else
  echo 'error: ImageMagick is required (magick or convert)' >&2; exit 1
fi

expected=(facet facet-aperture left-panel right-panel refracted-ribbon shard-gate right-zoom-cut left-zoom-cut panorama-stack vertical-slice horizontal-slice mirror-slash signal-tear halo-lens soft-arch tidal-veil liquid-lens arc-sweep soft-cascade canopy-curve)
mapfile -t metadata_presets < <(awk -F '\t' '!/^#/ {print $1}' presets.tsv)
[[ "${metadata_presets[*]}" == "${expected[*]}" ]] || { echo 'error: presets.tsv does not contain the approved ordered inventory' >&2; exit 1; }
mapfile -t setting_presets < <(sed -n '/^options = \[/,/^]/p' plugin.toml | sed -n 's/.*value = "\([^"]*\)".*/\1/p')
[[ "${setting_presets[*]}" == "${expected[*]} custom" ]] || { echo 'error: plugin preset options do not match presets.tsv plus Custom' >&2; exit 1; }
for preset in "${expected[@]}"; do
  key=${preset//-/_}
  grep -qF "settings.mask_preset.$key" translations/en.json || { echo "error: missing translation for $preset" >&2; exit 1; }
done
removed='center[- _]'; removed+='glow'
if grep -R -I -i -E "$removed" -- README.md backdrop.luau generate-masked-wallpaper.sh plugin.toml presets.tsv selftest.sh test-presets.sh translations masks decorations transforms thumbnail.webp 2>/dev/null; then
  echo 'error: removed preset is still present' >&2; exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$output_dir"
if [[ -z "$wallpaper" ]]; then
  wallpaper=$work/wallpaper.png
  "${im[@]}" -size 1600x1000 gradient:'#17233f-#d25263' \
    -fill '#f5d547' -draw 'rectangle 50,60 470,330' \
    -fill '#39d6bd' -draw 'circle 1320,190 1470,190' \
    -fill '#8139d6' -draw 'polygon 120,900 620,520 880,940' \
    -stroke '#ffffff80' -strokewidth 10 -fill none -draw 'line 0,0 1600,1000 line 0,1000 1600,0' "$wallpaper"
fi
[[ -f "$wallpaper" ]] || { echo "error: wallpaper not found: $wallpaper" >&2; exit 1; }

presets=()
while IFS=$'\t' read -r preset mask decorations mode transforms; do
  [[ -n "$preset" && "$preset" != \#* ]] || continue
  presets+=("$preset")
  [[ -f "$mask" ]] || { echo "error: missing mask: $mask" >&2; exit 1; }
  [[ "$("${identify_image[@]}" -format '%[opaque]' "$mask" | tr '[:upper:]' '[:lower:]')" == false ]] || { echo "error: mask has no transparent sharp region: $mask" >&2; exit 1; }
  for slot in 1 2 3; do
    [[ -f "$decorations/$slot.png" ]] || { echo "error: missing decoration: $decorations/$slot.png" >&2; exit 1; }
    "${identify_image[@]}" "$decorations/$slot.png" >/dev/null
  done
  rm -f -- "$output_dir/$preset.jpg"
  ./generate-masked-wallpaper.sh \
    --wallpaper "$wallpaper" --shape "$mask" --asset-mode "$mode" --transforms "$transforms" --asset-root "$PWD" --preset "$preset" \
    --decoration-1 "$decorations/1.png" --decoration-color-1 '#f0cb75' \
    --decoration-2 "$decorations/2.png" --decoration-color-2 '#f5f1ed' \
    --decoration-3 "$decorations/3.png" --decoration-color-3 '#8bc6d8' \
    --width "$width" --height "$height" --connector "$preset" \
    --cache-dir "$work/cache" --dest "$output_dir/$preset.jpg" >/dev/null
  [[ -s "$output_dir/$preset.jpg" ]] || { echo "error: missing output: $preset.jpg" >&2; exit 1; }
  actual=$("${identify_image[@]}" -format '%wx%h' "$output_dir/$preset.jpg")
  [[ "$actual" == "${width}x${height}" ]] || { echo "error: $preset.jpg is $actual, expected ${width}x${height}" >&2; exit 1; }
done < presets.tsv

((${#presets[@]} == 20)) || { echo "error: presets.tsv contains ${#presets[@]} presets, expected 20" >&2; exit 1; }
for pair in 'masks/left-panel.png masks/right-panel.png' 'masks/right-zoom-cut.png masks/left-zoom-cut.png' 'transforms/left-panel-refraction.png transforms/right-panel-refraction.png' 'transforms/right-zoom-cut-glint.png transforms/left-zoom-cut-glint.png'; do
  read -r source target <<<"$pair"
  "${im[@]}" "$source" -flop "$work/mirror.png"
  "${compare_image[@]}" -metric AE "$work/mirror.png" "$target" null: >/dev/null 2>&1 || { echo "error: $source and $target are not exact mirrors" >&2; exit 1; }
done
for slot in 1 2 3; do
  for pair in 'left-panel right-panel' 'right-zoom-cut left-zoom-cut'; do
    read -r source target <<<"$pair"
    "${im[@]}" "decorations/$source/$slot.png" -flop "$work/mirror.png"
    "${compare_image[@]}" -metric AE "$work/mirror.png" "decorations/$target/$slot.png" null: >/dev/null 2>&1 || { echo "error: decoration $slot for $source and $target is not mirrored" >&2; exit 1; }
  done
done
rm -f -- "$output_dir/contact-sheet.jpg"
images=(); for preset in "${presets[@]}"; do images+=("$output_dir/$preset.jpg"); done
"${montage_image[@]}" "${images[@]}" -thumbnail 320x180 -tile 4x5 -geometry +6+24 -background '#10131a' -fill white -set label '%t' "$output_dir/contact-sheet.jpg"
[[ -s "$output_dir/contact-sheet.jpg" ]] || { echo 'error: contact sheet was not created' >&2; exit 1; }
printf 'Rendered 20 presets to %s\n' "$output_dir"
