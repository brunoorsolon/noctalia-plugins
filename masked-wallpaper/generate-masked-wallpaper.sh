#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Generate a cached, flattened JPEG lockscreen image for a full-screen Noctalia sticker.
Opaque pixels in --shape are blurred/tinted; transparent pixels retain the original wallpaper.

Usage:
  generate-masked-wallpaper.sh --wallpaper FILE --shape PNG [options]

Options:
  --preset-decoration PNG Bundled decoration below every custom layer
  --decoration-1 PNG      Optional topmost transparent decoration layer
  --decoration-2 PNG      Optional middle transparent decoration layer
  --decoration-3 PNG      Optional bottom transparent decoration layer
  --decoration-color-1 C  Replace decoration 1 RGB with C; preserve alpha
  --decoration-color-2 C  Replace decoration 2 RGB with C; preserve alpha
  --decoration-color-3 C  Replace decoration 3 RGB with C; preserve alpha
  --decorations PNG       Alias for --decoration-1
  --width PX              Output width (default: 2560)
  --height PX             Output height (default: 1440)
  --connector NAME        Noctalia output name (default: DP-3)
  --blur 0..1             Blur intensity; 1 maps to radius 40 (default: 0.45)
  --tint COLOR            ImageMagick color, usually #RRGGBB (default: #18151c)
  --tint-intensity 0..1   Tint strength (default: 0.28)
  --palette FILE          Palette written by the Noctalia template; resolves role names
  --cache-dir DIR         Cache destination (default: $XDG_CACHE_HOME/noctalia/masked-wallpaper)
  --dest FILE             Also publish the result to this stable path, atomically
  --force                 Regenerate an existing cache entry
  -h, --help              Show this help
EOF
}

note() { [[ -n "${log:-}" ]] && printf '%s %s\n' "$(date -Is)" "$*" >>"$log"; return 0; }
die() { note "FAILED: $*"; printf 'error: %s\n' "$*" >&2; exit 1; }
unit_float() { awk -v n="$1" 'BEGIN { exit !(n ~ /^([0-9]+([.][0-9]*)?|[.][0-9]+)$/ && n >= 0 && n <= 1) }'; }

wallpaper=
shape=
preset_decoration=
decorations=("" "" "")
decoration_colors=("" "" "")
width=2560
height=1440
connector=DP-3
blur=0.45
tint='#18151c'
tint_intensity=0.28
palette="${XDG_STATE_HOME:-$HOME/.local/state}/noctalia/masked-wallpaper-colors.env"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/noctalia/masked-wallpaper"
dest=
force=false

invocation=("$@")
while (($#)); do
  case "$1" in
    --wallpaper) wallpaper=${2:?missing wallpaper path}; shift 2 ;;
    --shape) shape=${2:?missing shape path}; shift 2 ;;
    --preset-decoration) preset_decoration=${2:?missing preset decoration path}; shift 2 ;;
    --decorations|--decoration-1) decorations[0]=${2:?missing decoration path}; shift 2 ;;
    --decoration-2) decorations[1]=${2:?missing decoration path}; shift 2 ;;
    --decoration-3) decorations[2]=${2:?missing decoration path}; shift 2 ;;
    --decoration-color-1) decoration_colors[0]=${2:?missing decoration color}; shift 2 ;;
    --decoration-color-2) decoration_colors[1]=${2:?missing decoration color}; shift 2 ;;
    --decoration-color-3) decoration_colors[2]=${2:?missing decoration color}; shift 2 ;;
    --width) width=${2:?missing width}; shift 2 ;;
    --height) height=${2:?missing height}; shift 2 ;;
    --connector) connector=${2:?missing connector}; shift 2 ;;
    --blur) blur=${2:?missing blur intensity}; shift 2 ;;
    --tint) tint=${2:?missing tint color}; shift 2 ;;
    --tint-intensity) tint_intensity=${2:?missing tint intensity}; shift 2 ;;
    --palette) palette=${2:?missing palette path}; shift 2 ;;
    --cache-dir) cache_dir=${2:?missing cache directory}; shift 2 ;;
    --dest) dest=${2:?missing dest path}; shift 2 ;;
    --force) force=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

mkdir -p "$cache_dir"
log="$cache_dir/generate.log"
# ponytail: trimmed by size, never rotated. It is one line per wallpaper change.
if [[ -f "$log" && $(stat -c%s "$log") -gt 100000 ]]; then
  tail -c 50000 "$log" >"$log.trim" && mv -f "$log.trim" "$log"
fi
note "run: ${invocation[*]}"

[[ -f "$wallpaper" ]] || die "wallpaper not found: $wallpaper"
[[ -f "$shape" ]] || die "shape not found: $shape"
[[ -z "$preset_decoration" || -f "$preset_decoration" ]] || die "preset decoration not found: $preset_decoration"
for i in 0 1 2; do
  [[ -z "${decorations[$i]}" || -f "${decorations[$i]}" ]] || die "decoration $((i + 1)) not found: ${decorations[$i]}"
  [[ -z "${decoration_colors[$i]}" || -n "${decorations[$i]}" ]] || die "decoration color $((i + 1)) requires decoration $((i + 1))"
done
[[ "$width" =~ ^[1-9][0-9]*$ ]] || die 'width must be a positive integer'
[[ "$height" =~ ^[1-9][0-9]*$ ]] || die 'height must be a positive integer'
unit_float "$blur" || die 'blur must be between 0 and 1'
unit_float "$tint_intensity" || die 'tint intensity must be between 0 and 1'

if command -v magick >/dev/null 2>&1; then
  im=(magick)
elif command -v convert >/dev/null 2>&1; then
  im=(convert)
else
  die 'ImageMagick is required (magick or convert)'
fi

# A colour is either a literal #rrggbb or a palette role name that Noctalia
# regenerates on every theme change. Resolve roles before anything hashes them,
# so a new palette means a new cache key.
resolve_color() {
  local value=$1 label=$2 hex
  [[ "$value" == \#* ]] && { printf '%s' "$value"; return 0; }
  [[ "$value" =~ ^[A-Za-z0-9_]+$ ]] || die "$label is neither a #rrggbb colour nor a palette role name: $value"
  [[ -f "$palette" ]] || die "$label uses palette role \"$value\" but no palette file exists at $palette; add the masked_wallpaper template to [theme.templates.user] (see README)"
  hex=$(sed -n "s/^$value=//p" "$palette" | head -n 1)
  [[ -n "$hex" ]] || die "$label uses palette role \"$value\", which $palette does not define"
  printf '%s' "$hex"
}

tint=$(resolve_color "$tint" 'tint')
for i in 0 1 2; do
  [[ -z "${decoration_colors[$i]}" ]] || decoration_colors[$i]=$(resolve_color "${decoration_colors[$i]}" "decoration colour $((i + 1))")
done

"${im[@]}" -size 1x1 "xc:$tint" null: 2>/dev/null || die "ImageMagick does not recognize tint color: $tint"
for i in 0 1 2; do
  color=${decoration_colors[$i]}
  [[ -z "$color" ]] || "${im[@]}" -size 1x1 "xc:$color" null: 2>/dev/null || die "ImageMagick does not recognize decoration color $((i + 1)): $color"
done
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required'

wall_hash=$(sha256sum -- "$wallpaper" | awk '{print $1}')
shape_hash=$(sha256sum -- "$shape" | awk '{print $1}')
preset_decoration_hash=none
[[ -z "$preset_decoration" ]] || preset_decoration_hash=$(sha256sum -- "$preset_decoration" | awk '{print $1}')
decorations_fingerprint="preset:$preset_decoration_hash|"
for i in 0 1 2; do
  decoration_hash=none
  [[ -z "${decorations[$i]}" ]] || decoration_hash=$(sha256sum -- "${decorations[$i]}" | awk '{print $1}')
  decorations_fingerprint+="$decoration_hash:${decoration_colors[$i]}|"
done
key=$(printf '%s\n' "$wall_hash" "$shape_hash" "$decorations_fingerprint" "$width" "$height" "$connector" "$blur" "$tint" "$tint_intensity" 'flattened-jpeg-v5' | sha256sum | cut -c1-16)
safe_connector=${connector//[^A-Za-z0-9_.-]/_}
stem="masked-wallpaper-${safe_connector}-${width}x${height}-${key}"
output="$cache_dir/$stem.jpg"
snippet="$cache_dir/$stem.toml"
widget_id="masked-wallpaper-${safe_connector}"
cx=$(awk -v n="$width" 'BEGIN { printf "%.1f", n / 2 }')
cy=$(awk -v n="$height" 'BEGIN { printf "%.1f", n / 2 }')

# The sticker widget reloads a same-path replacement, so the stable dest is what the
# widget points at for good; the versioned cache file behind it is what we reuse.
publish() {
  [[ -n "$dest" ]] || return 0
  local dest_dir tmp
  dest_dir=$(dirname -- "$dest")
  mkdir -p "$dest_dir"
  tmp=$(mktemp "$dest_dir/.publish.XXXXXX")
  cp -- "$output" "$tmp"
  mv -f -- "$tmp" "$dest"
}

write_snippet() {
  cat >"$snippet" <<EOF
# Add "$widget_id" before the visible widgets in lockscreen_widgets.widget_order.
[lockscreen_widgets.widget.$widget_id]
type = "sticker"
output = "$connector"
cx = $cx
cy = $cy
placement_width = ${width}.0
placement_height = ${height}.0
box_width = ${width}.0
box_height = ${height}.0
rotation = 0.0
flip_x = false
flip_y = false

[lockscreen_widgets.widget.$widget_id.settings]
image_path = "${dest:-$output}"
opacity = 1.0
EOF
}

if [[ -f "$output" && "$force" == false ]]; then
  publish
  write_snippet
  note "cache hit: $output"
  printf 'cache hit: %s\nwidget TOML: %s\n' "$output" "$snippet"
  exit 0
fi

tmpdir=$(mktemp -d "$cache_dir/.generate.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT
base="$tmpdir/base.miff"
processed="$tmpdir/processed.miff"
mask="$tmpdir/mask.miff"
masked="$tmpdir/masked.miff"
flattened="$tmpdir/flattened.miff"
tmp_output="$tmpdir/output.jpg"

# Match Noctalia's default crop behavior: center, cover, then crop to output dimensions.
"${im[@]}" "$wallpaper" -auto-orient -resize "${width}x${height}^" -gravity center -extent "${width}x${height}" "$base"
radius=$(awk -v n="$blur" 'BEGIN { printf "%.3f", n * 40 }')
tint_percent=$(awk -v n="$tint_intensity" 'BEGIN { printf "%.3f%%", n * 100 }')

if awk -v n="$blur" 'BEGIN { exit !(n > 0) }'; then
  "${im[@]}" "$base" -blur "0x$radius" -fill "$tint" -colorize "$tint_percent" "$processed"
else
  "${im[@]}" "$base" -fill "$tint" -colorize "$tint_percent" "$processed"
fi

# The shape's alpha is the affected area: opaque = blurred/tinted, transparent = original wallpaper.
"${im[@]}" "$shape" -resize "${width}x${height}!" -alpha extract "$mask"
"${im[@]}" "$processed" "$mask" -alpha off -compose CopyOpacity -composite "MIFF:$masked"
"${im[@]}" "$base" "$masked" -compose over -composite "MIFF:$flattened"

current=$flattened
# The preset decoration sits above the mask but below every custom decoration.
if [[ -n "$preset_decoration" ]]; then
  preset_layer="$tmpdir/preset-decoration.miff"
  preset_merged="$tmpdir/merged-preset.miff"
  "${im[@]}" "$preset_decoration" -resize "${width}x${height}!" "MIFF:$preset_layer"
  "${im[@]}" "$current" "$preset_layer" -compose over -composite "MIFF:$preset_merged"
  current=$preset_merged
fi
# Composite custom layers bottom-to-top so decoration 1 remains topmost.
for i in 2 1 0; do
  decoration=${decorations[$i]}
  [[ -n "$decoration" ]] || continue
  layer="$tmpdir/decoration-$i.miff"
  merged="$tmpdir/merged-$i.miff"
  color=${decoration_colors[$i]}
  if [[ -n "$color" ]]; then
    decoration_alpha="$tmpdir/decoration-alpha-$i.miff"
    "${im[@]}" "$decoration" -resize "${width}x${height}!" -alpha extract "$decoration_alpha"
    "${im[@]}" -size "${width}x${height}" "xc:$color" "$decoration_alpha" -alpha off -compose CopyOpacity -composite "MIFF:$layer"
  else
    "${im[@]}" "$decoration" -resize "${width}x${height}!" "MIFF:$layer"
  fi
  "${im[@]}" "$current" "$layer" -compose over -composite "MIFF:$merged"
  current=$merged
done
"${im[@]}" "$current" -alpha off -colorspace sRGB -strip -sampling-factor 4:4:4 -quality 92 -interlace none "JPEG:$tmp_output"
mv -- "$tmp_output" "$output"

publish
write_snippet
note "generated: $output"
printf 'generated: %s\nwidget TOML: %s\n' "$output" "$snippet"
