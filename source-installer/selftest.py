#!/usr/bin/env python3
"""Self-test for the separate Dictation source installer.

Drives the real headless engine (fetch -> configure -> build -> publish) with
fake git/cmake/approval/engine tools placed on PATH, so the whole flow runs
without network access, a Fedora host or a GUI.  It covers the positive path,
the refusal and failure paths, cancellation, revision tampering, repeat
convergence and removal that must not touch a user's own engine.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import dictation_source_installer as inst  # noqa: E402

FAKE_TOOLS: dict[str, str] = {}

FAKE_TOOLS["git"] = """#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
if args and args[0] == "init":
    d = Path(args[-1]); d.mkdir(parents=True, exist_ok=True)
    (d / "LICENSE").write_text("MIT License")
    (d / "CMakeLists.txt").write_text("cmake_minimum_required(VERSION 3.16)\\n")
elif "-C" in args:
    d = Path(args[args.index("-C") + 1])
    if "rev-parse" in args:
        print(os.environ.get("FAKE_GIT_REV", "%(rev)s"))
    elif "get-url" in args:
        print(os.environ.get("FAKE_GIT_URL", "%(url)s"))
raise SystemExit(0)
""" % {"rev": inst.SOURCE_REVISION, "url": inst.SOURCE_URL}

FAKE_TOOLS["cmake"] = """#!/usr/bin/env python3
import os, stat, sys, time
from pathlib import Path
args = sys.argv[1:]
if os.environ.get("FAKE_CMAKE_SLEEP"):
    time.sleep(float(os.environ["FAKE_CMAKE_SLEEP"]))
if os.environ.get("FAKE_CMAKE_FAIL"):
    print("fake cmake: simulated configure error")
    raise SystemExit(3)
build = None
if "-B" in args:
    build = Path(args[args.index("-B") + 1])
elif "--build" in args:
    build = Path(args[args.index("--build") + 1])
if build is not None:
    build.mkdir(parents=True, exist_ok=True)
    if "--build" in args:
        bin_dir = build / "bin"; bin_dir.mkdir(parents=True, exist_ok=True)
        exe = bin_dir / "transcribe-cli"
        flags = " ".join("echo usage: transcribe-cli " + f for f in __FLAGS__)
        exe.write_text("#!/bin/sh\\n" + flags + "\\n")
        exe.chmod(exe.stat().st_mode | stat.S_IEXEC)
raise SystemExit(0)
""".replace("__FLAGS__", repr(list(inst.REQUIRED_FLAGS)))

FAKE_TOOLS["rpm"] = """#!/usr/bin/env python3
import os, sys
pkg = sys.argv[-1]
missing = os.environ.get("FAKE_RPM_MISSING", "").split()
raise SystemExit(1 if pkg in missing else 0)
"""

FAKE_TOOLS["pkcon"] = """#!/usr/bin/env python3
import os, sys
print("simulated package approval:", " ".join(sys.argv[1:]))
raise SystemExit(126 if os.environ.get("FAKE_APPROVAL_DENY") else 0)
"""


class Checks:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.count = 0

    def check(self, name: str, condition: bool, detail: str = "") -> None:
        self.count += 1
        if condition:
            print(f"  ok   {name}")
        else:
            print(f"  FAIL {name} {detail}")
            self.failures.append(name)


def build_fakes(root: Path, tools: list[str]) -> Path:
    bin_dir = root / "fakebin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    for name in tools:
        path = bin_dir / name
        path.write_text(FAKE_TOOLS[name], encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IEXEC)
    # g++/make only exist so the non-rpm package probe sees them as present.
    for name in ("g++", "make"):
        marker = bin_dir / name
        marker.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        marker.chmod(marker.stat().st_mode | stat.S_IEXEC)
    return bin_dir


class Sandbox:
    """A throwaway HOME and PATH built from the given fake tool set."""

    def __init__(self, name: str, tools: list[str], env: dict | None = None) -> None:
        self.root = Path(tempfile.mkdtemp(prefix=f"installer-{name}-"))
        self.home = self.root / "home"
        self.bin_dir = build_fakes(self.root, tools)
        # Only the fake tools plus a python3 link are reachable.  A real
        # /usr/bin on PATH would let the test find the host's own pkcon, rpm
        # or cmake and act on the real system.
        sysbin = self.root / "sysbin"
        sysbin.mkdir()
        os.symlink(sys.executable, sysbin / "python3")
        self._saved = dict(os.environ)
        os.environ["HOME"] = str(self.home)
        os.environ["XDG_STATE_HOME"] = str(self.home / ".local" / "state")
        os.environ["XDG_DATA_HOME"] = str(self.home / ".local" / "share")
        os.environ["PATH"] = f"{self.bin_dir}:{sysbin}"
        for key in ("FAKE_GIT_REV", "FAKE_GIT_URL", "FAKE_CMAKE_FAIL",
                    "FAKE_CMAKE_SLEEP", "FAKE_RPM_MISSING", "FAKE_APPROVAL_DENY"):
            os.environ.pop(key, None)
        os.environ.update(env or {})
        self.home.mkdir(parents=True, exist_ok=True)

    def paths(self) -> inst.Paths:
        return inst.default_paths(self.home)

    def installer(self) -> inst.Installer:
        return inst.Installer(self.paths())

    def __enter__(self) -> "Sandbox":
        return self

    def __exit__(self, *exc) -> None:
        os.environ.clear()
        os.environ.update(self._saved)


def test_sandbox_isolation(checks: Checks) -> None:
    with Sandbox("isolation", ["git", "cmake"]) as box:
        entries = os.environ["PATH"].split(os.pathsep)
        checks.check(
            "selftest never exposes host tool directories",
            all(str(box.root) in entry for entry in entries),
            str(entries),
        )
        checks.check(
            "selftest sees no host pkcon, pkexec or rpm",
            all(shutil.which(tool) is None for tool in ("pkcon", "pkexec", "rpm")),
        )


def test_flag_contract(checks: Checks) -> None:
    helper = (HERE.parent / "dictation" / "dictation-helper.py").read_text(encoding="utf-8")
    block = helper.split("REQUIRED_FLAGS = (", 1)[1].split(")", 1)[0]
    plugin_flags = re.findall(r'"([^"]+)"', block)
    checks.check(
        "installer requires exactly the flags the plugin probes for",
        list(inst.REQUIRED_FLAGS) == plugin_flags,
        f"installer={list(inst.REQUIRED_FLAGS)} plugin={plugin_flags}",
    )


def test_engine_verification(checks: Checks) -> None:
    with Sandbox("verify", []) as box:
        def engine(name: str, flags: list[str]) -> Path:
            path = box.root / name
            body = "\n".join(f"echo {flag}" for flag in flags)
            path.write_text(f"#!/bin/sh\n{body}\n", encoding="utf-8")
            path.chmod(0o755)
            return path

        good = engine("good", list(inst.REQUIRED_FLAGS))
        checks.check("engine advertising every flag passes", inst.verify_engine(good)[0])

        no_model = engine("no-model", [f for f in inst.REQUIRED_FLAGS if f != "--model"])
        ok, missing, _ = inst.verify_engine(no_model)
        checks.check("engine without --model is rejected", not ok and missing == ["--model"], str(missing))

        no_batch_size = engine("no-batch-size", [f for f in inst.REQUIRED_FLAGS if f != "--batch-size"])
        ok, missing, _ = inst.verify_engine(no_batch_size)
        checks.check(
            "--batch does not stand in for --batch-size",
            not ok and missing == ["--batch-size"],
            str(missing),
        )


def test_detection(checks: Checks) -> None:
    with Sandbox("detect", ["git", "cmake", "pkcon"]) as box:
        result = box.installer().detect()
        checks.check("detect finds no engine", result["usable_existing"] == [])
        checks.check(
            "detect reports the packagekit approval surface",
            result["approval_surface"] == {"kind": "packagekit", "command": "pkcon"},
            str(result["approval_surface"]),
        )
        checks.check("detect needs no package", result["missing_packages"] == [])
        checks.check(
            "plan explains revision and locations",
            inst.SOURCE_REVISION in (text := box.installer().plan_text(result))
            and str(box.paths().install) in text
            and "no model" in text,
        )


def test_install_and_converge(checks: Checks) -> None:
    with Sandbox("install", ["git", "cmake", "pkcon"]) as box:
        installer = box.installer()
        result = installer.install(approve_packages=True)
        checks.check("install publishes the engine", result["state"] == "installed", str(result))
        paths = box.paths()
        engine = paths.install / inst.ENGINE
        checks.check("published engine exists and runs", engine.is_file() and inst.verify_engine(engine)[0])
        record = inst.load_manifest(paths)
        checks.check("manifest records revision and hash",
                     record["revision"] == inst.SOURCE_REVISION
                     and record["engine_sha256"] == inst.sha256_file(engine))
        checks.check("manifest records build config and license",
                     record["build_args"] == list(inst.CMAKE_ARGS) and "MIT" in record["license"])
        checks.check("upstream license is copied beside the engine",
                     record["license_files"] == ["LICENSE"]
                     and (paths.install / "LICENSE").is_file())
        checks.check("engine is linked onto PATH",
                     (paths.bin_dir / inst.ENGINE).is_symlink()
                     and os.path.realpath(paths.bin_dir / inst.ENGINE) == str(engine))
        checks.check("build staging is cleaned up", not paths.staging.exists())

        again = box.installer().install(approve_packages=True)
        checks.check("repeat install converges without rebuilding",
                     again["state"] == "already-installed", str(again))


def test_revision_tamper(checks: Checks) -> None:
    with Sandbox("tamper", ["git", "cmake", "pkcon"], {"FAKE_GIT_REV": "0" * 40}) as box:
        result = box.installer().install(approve_packages=True)
        checks.check("tampered revision is rejected", result["state"] == "error", str(result))
        checks.check("tampered source publishes nothing",
                     not (box.paths().install / inst.ENGINE).exists())


def test_blocked_without_surface(checks: Checks) -> None:
    with Sandbox("blocked", ["git", "rpm"], {"FAKE_RPM_MISSING": "cmake"}) as box:
        result = box.installer().install(approve_packages=True)
        checks.check("missing packages without a surface block the install",
                     result["state"] == "blocked" and "graphical package-approval" in result["reason"],
                     str(result))
        checks.check("blocked install publishes nothing",
                     not (box.paths().install / inst.ENGINE).exists())
        result = box.installer().install(approve_packages=False)
        checks.check("unapproved packages block the install",
                     result["state"] == "blocked" and "explicit approval" in result["reason"], str(result))


def test_approval_denied(checks: Checks) -> None:
    with Sandbox("denied", ["git", "rpm", "pkcon"],
                 {"FAKE_RPM_MISSING": "cmake", "FAKE_APPROVAL_DENY": "1"}) as box:
        result = box.installer().install(approve_packages=True)
        checks.check("denied approval blocks the install",
                     result["state"] == "blocked" and "refused or failed" in result["reason"], str(result))
        checks.check("denied approval publishes nothing",
                     not (box.paths().install / inst.ENGINE).exists())


def test_build_failure(checks: Checks) -> None:
    with Sandbox("fail", ["git", "cmake", "pkcon"], {"FAKE_CMAKE_FAIL": "1"}) as box:
        result = box.installer().install(approve_packages=True)
        checks.check("failed build reports an error", result["state"] == "error", str(result))
        paths = box.paths()
        checks.check("failed build publishes nothing",
                     not (paths.install / inst.ENGINE).exists() and inst.load_manifest(paths) is None)
        checks.check("failed build keeps diagnostics",
                     "simulated configure error" in (paths.logs / "build.log").read_text())


def test_cancel(checks: Checks) -> None:
    with Sandbox("cancel", ["git", "cmake", "pkcon"], {"FAKE_CMAKE_SLEEP": "30"}) as box:
        installer = box.installer()
        holder: dict = {}

        def run() -> None:
            holder["result"] = installer.install(approve_packages=True)

        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        deadline = time.time() + 20
        started = False
        while time.time() < deadline:
            if any("build" in line for line in installer.log_lines):
                started = True
                break
            time.sleep(0.05)
        checks.check("build reached the compile step before cancelling", started)
        time.sleep(0.3)
        installer.runner.cancel()
        thread.join(timeout=20)
        checks.check("cancel stops the install", holder.get("result", {}).get("state") == "cancelled",
                     str(holder.get("result")))
        checks.check("cancel publishes nothing",
                     not (box.paths().install / inst.ENGINE).exists())
        checks.check("cancel removes own staging", not box.paths().staging.exists())


def test_remove_preserves_user_engine(checks: Checks) -> None:
    with Sandbox("remove", ["git", "cmake", "pkcon"]) as box:
        paths = box.paths()
        paths.bin_dir.mkdir(parents=True, exist_ok=True)
        user_engine = paths.bin_dir / inst.ENGINE
        user_engine.write_text("#!/bin/sh\necho user engine\n", encoding="utf-8")
        user_engine.chmod(0o755)
        unrelated = paths.bin_dir / "other-tool"
        unrelated.write_text("x", encoding="utf-8")

        result = box.installer().install(approve_packages=True)
        checks.check("install never replaces a user engine",
                     result["state"] == "installed" and result["linked_into_path"] is False, str(result))
        checks.check("user engine is untouched by install",
                     user_engine.read_text() == "#!/bin/sh\necho user engine\n")

        box.installer().remove()
        checks.check("removal deletes installer-owned engine",
                     not (paths.install / inst.ENGINE).exists() and not paths.manifest.exists())
        checks.check("removal keeps the user engine", user_engine.is_file())
        checks.check("removal keeps unrelated files", unrelated.is_file())


def main() -> int:
    checks = Checks()
    for test in (
        test_sandbox_isolation,
        test_flag_contract,
        test_engine_verification,
        test_detection,
        test_install_and_converge,
        test_revision_tamper,
        test_blocked_without_surface,
        test_approval_denied,
        test_build_failure,
        test_cancel,
        test_remove_preserves_user_engine,
    ):
        print(f"{test.__name__}:")
        test(checks)
    print(f"\n{checks.count - len(checks.failures)}/{checks.count} checks passed")
    if checks.failures:
        print("failed: " + ", ".join(checks.failures))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
