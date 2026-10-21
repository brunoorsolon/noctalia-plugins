#!/usr/bin/env python3
"""Checks every plugin manifest against its row in catalog.toml.

Noctalia reads the manifest and renders the catalog row, so a field that drifts
between the two shows the user the wrong package, and a version that drifts
leaves an update offered forever. The catalog is a repository-wide artifact, so
the check walks every plugin rather than living inside one plugin's selftest.
A plugin whose catalog row has not been added yet is listed here as pending and
reported instead of failing the check: registration is its own step, and an
unregistered plugin is not offered to users. Every other manifest still needs
exactly one row, so a lost or typo'd row keeps failing its own plugin.

Run from a plugin directory (`python3 ../scripts/check-catalog.py`) or from the
repository root; it resolves paths against its own location.
"""

import glob
import os
import sys
import tomllib

# The fields Noctalia reads from the manifest or renders from the row.
FIELDS = (
    "name",
    "icon",
    "description",
    "license",
    "tags",
    "author",
    "version",
    "plugin_api",
    "dependencies",
)


# Manifests that landed before their catalog row. Registration is the last step
# of the plugin's own breakdown; remove the entry with that registration.
PENDING_REGISTRATION = {"sidepad"}


def fail(message):
    sys.exit("FAIL: %s" % message)


root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

with open(os.path.join(root, "catalog.toml"), "rb") as handle:
    rows = tomllib.load(handle)["plugin"]

checked = 0
unregistered = []
manifests = 0
for path in sorted(glob.glob(os.path.join(root, "*", "plugin.toml"))):
    with open(path, "rb") as handle:
        manifest = tomllib.load(handle)

    manifests += 1
    relative = os.path.relpath(path, root)
    matching = [row for row in rows if row.get("id") == manifest.get("id")]
    if not matching and os.path.dirname(relative) in PENDING_REGISTRATION:
        unregistered.append(relative)
        continue
    if len(matching) != 1:
        fail("%s: catalog rows for %r: expected 1, got %d" % (relative, manifest.get("id"), len(matching)))
    row = matching[0]

    for field in FIELDS:
        if manifest.get(field) != row.get(field):
            fail("%s: catalog %s: expected %r got %r" % (relative, field, manifest.get(field), row.get(field)))
    if row.get("updated_at", 0) < row.get("added_at", 0):
        fail("%s: updated_at is older than added_at" % relative)

    checked += 1

if manifests == 0:
    fail("no plugin manifest found under %s" % root)

if unregistered:
    print("catalog ok (%d plugins, not yet registered: %s)" % (checked, ", ".join(unregistered)))
else:
    print("catalog ok (%d plugins)" % checked)
