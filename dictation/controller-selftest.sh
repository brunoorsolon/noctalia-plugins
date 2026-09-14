#!/usr/bin/env bash
# Runs the plugin's Luau entries against a stubbed Noctalia runtime and a
# stubbed helper, so the controller's state machine is checked here rather than
# only on a host with Noctalia and PipeWire. Not a plugin entry: plugin.toml
# never loads controller-harness.luau.
#
# Needs a Luau interpreter. Without one the check is skipped, not failed.
set -euo pipefail
cd "$(dirname "$0")"

LUAU="${LUAU:-$(command -v luau || true)}"
if [[ -z "$LUAU" ]]; then
  echo "controller-selftest: skipped, no luau on PATH (set LUAU=/path/to/luau)"
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The entries are embedded as long strings so the harness can load them into one
# shared global table, the way a plugin runtime loads its entries.
{
  printf 'SOURCES = {\n'
  for entry in controller panel widget; do
    printf '%s = [==[\n' "$entry"
    cat "$entry.luau"
    printf '\n]==],\n'
  done
  printf '}\n'
  cat controller-harness.luau
} >"$work/run.luau"

"$LUAU" "$work/run.luau"
