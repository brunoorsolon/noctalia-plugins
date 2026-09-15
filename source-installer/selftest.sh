#!/bin/sh
# Self-test for the separate Dictation source installer.
#
# Runs the whole fetch -> configure -> build -> publish flow against fake
# git/cmake/approval/engine tools on PATH. No network, Fedora host, packages
# or GUI are required.
set -eu
exec python3 "$(dirname "$0")/selftest.py" "$@"
