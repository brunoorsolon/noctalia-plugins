#!/usr/bin/env bash
# Runs the plugin's Luau widget entry against a stubbed Noctalia runtime and a
# stubbed hyprctl, so the status file to widget state mapping, the click routing
# and the waiting notification are checked here rather than only on a host with
# Noctalia, Hyprland and Pi. Not a plugin entry: plugin.toml never loads
# scratchpad-harness.luau.
#
# Needs a Luau interpreter. Without one the check is skipped, not failed.
set -euo pipefail
cd "$(dirname "$0")"

LUAU="${LUAU:-$(command -v luau || true)}"
if [[ -z "$LUAU" ]]; then
  echo "selftest: skipped, no luau on PATH (set LUAU=/path/to/luau)"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The entry is embedded as a long string so the harness can load it into a global
# table, the way a plugin runtime loads its entries.
{
  printf 'SOURCES = {\n'
  printf 'scratchpad = [==[\n'
  cat scratchpad.luau
  printf '\n]==],\n'
  printf '}\n'
  cat scratchpad-harness.luau
} >"$work/run.luau"

"$LUAU" "$work/run.luau"
