#!/usr/bin/env bash
# Runs the plugin's entries against a stubbed Noctalia runtime, so entry loading,
# the shared request/status contract and both UI consumers are checked here
# rather than only on a host with Noctalia and Hyprland. Not a plugin entry:
# plugin.toml never loads sidepad-harness.luau.
#
# Needs a Luau interpreter. Without one the harness is skipped, not failed.
set -euo pipefail
cd "$(dirname "$0")"

python3 ../scripts/check-catalog.py

# The manifest is the contract the host reads, so the entries and settings this
# slice declares are checked here rather than trusted to review.
python3 - <<'PY'
import json
import pathlib
import sys
import tomllib

fail = lambda message: sys.exit("FAIL: %s" % message)

manifest = tomllib.loads(pathlib.Path("plugin.toml").read_text())

for key, expected in (
    ("id", "magus/sidepad"),
    ("author", "magus"),
    ("name", "Sidepad"),
    ("license", "MIT"),
    ("plugin_api", 24),
):
    if manifest.get(key) != expected:
        fail("plugin.toml %s: expected %r got %r" % (key, expected, manifest.get(key)))

entries = []
for kind in ("service", "widget", "panel"):
    for entry in manifest.get(kind, []):
        entries.append((kind, entry["id"], entry["entry"]))
expected = [
    ("service", "controller", "service.luau"),
    ("widget", "sidepad", "widget.luau"),
    ("panel", "selector", "panel.luau"),
]
if entries != expected:
    fail("entries: expected %r got %r" % (expected, entries))

declared_kinds = {kind for kind in ("service", "widget", "panel", "shortcut", "launcher_provider",
                                    "desktop_widget", "layer") if kind in manifest}
if declared_kinds != {"service", "widget", "panel"}:
    fail("entry kinds: expected only service, widget and panel, got %r" % sorted(declared_kinds))

for _, _, path in expected:
    if not pathlib.Path(path).is_file():
        fail("entry '%s' points at a missing file" % path)

settings = {setting["key"]: setting["default"] for setting in manifest.get("setting", [])}
expected_settings = {
    "narrow_width": 900,
    "wide_width": 1200,
    "edge_gap": 10,
    "top_gap": 100,
    "bottom_gap": 100,
    "launch_timeout_ms": 5000,
}
if settings != expected_settings:
    fail("settings: expected %r got %r" % (expected_settings, settings))

translations = json.loads(pathlib.Path("translations/en.json").read_text())
for setting in manifest.get("setting", []):
    for field in ("label_key", "description_key"):
        if setting[field] not in translations:
            fail("setting '%s' %s is not translated" % (setting["key"], field))

print("manifest ok (3 entries, 6 settings)")
PY

LUAU="${LUAU:-$(command -v luau || true)}"
if [[ -z "$LUAU" ]]; then
  echo "selftest: skipped, no luau on PATH (set LUAU=/path/to/luau)"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The entries and their shared module are embedded as long strings so the harness
# loads each one as its own runtime, the way a plugin runtime loads its entries.
{
  printf 'SOURCES = {\n'
  for entry in shared service widget panel; do
    printf '%s = [==[\n' "$entry"
    cat "$entry.luau"
    printf '\n]==],\n'
  done
  printf '}\n'
  # The shipped example is loaded by the harness as a real startup fixture, so a
  # corrupt example fails here instead of only in review.
  printf 'EXAMPLE_PADS = [==[\n'
  cat pads.example.json
  printf '\n]==]\n'
  cat sidepad-harness.luau
} >"$work/run.luau"

"$LUAU" "$work/run.luau"
