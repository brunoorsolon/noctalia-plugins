#!/usr/bin/env python3
"""Graphical source installer for the transcribe.cpp recognition engine.

This program is deliberately separate from the ``magus/dictation`` Noctalia
plugin.  The Noctalia community rules do not allow a plugin to fetch, build or
run remote code, so this route is distributed and executed on its own and the
plugin only ever consumes the executable it produces.

What this program is allowed to do is deliberately narrow: it fetches one
pinned upstream revision of transcribe.cpp, builds the ordinary CPU target,
stages the result apart from any existing engine, and publishes a verified
executable.  It never patches the engine source, never downloads a prebuilt
inference binary or a model, never installs a GPU stack, never updates an
unrelated package, and never runs an arbitrary command supplied by the user.

The headless half of this module imports without a display or Tk and is driven
by ``selftest.py``.  ``--gui`` (the default when no subcommand is given) lazily
imports Tk and presents the same operations.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path

SOURCE_URL = "https://github.com/handy-computer/transcribe.cpp.git"
# One identified upstream revision.  The installer refuses any other commit.
SOURCE_REVISION = "9eed7f0919ac97c71c71dcd5dcc765c969aa2b05"
ENGINE = "transcribe-cli"

# Every engine flag the Dictation plugin's own probe requires.  The built
# executable must advertise all of them or it is not published.  Keep this list
# identical to dictation/dictation-helper.py.
REQUIRED_FLAGS = (
    "--backend",
    "--threads",
    "--timestamps",
    "--model",
    "--batch",
    "--batch-size",
    "--batch-jsonl",
)

# The ordinary CPU build.  GPU backends are explicitly off, the default
# ``auto`` device selection is never reached, and no tool is built.
CMAKE_ARGS = (
    "-DCMAKE_BUILD_TYPE=Release",
    "-DTRANSCRIBE_VULKAN=OFF",
    "-DTRANSCRIBE_CUDA=OFF",
    "-DTRANSCRIBE_HIP=OFF",
    "-DTRANSCRIBE_METAL=OFF",
    "-DTRANSCRIBE_BUILD_TOOLS=OFF",
)

# Fedora development prerequisites for the CPU path only.  openblas-devel is
# recommended upstream but optional; it accelerates the host decoder and is not
# a GPU stack.
FEDORA_PACKAGES = ("git", "cmake", "gcc-c++", "make", "openblas-devel")
PACKAGE_COMMANDS = {
    "git": "git",
    "cmake": "cmake",
    "gcc-c++": "g++",
    "make": "make",
    "openblas-devel": None,
}

_SENSITIVE_ENV = re.compile(
    r"(TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH|_KEY$|^AWS_|^GPG_|^SSH_"
    r"|^GIT_(?:CONFIG_|ASKPASS|SSH|CREDENTIAL|PROXY_COMMAND))",
    re.I,
)

RESOURCE_NOTE = (
    "The checkout and build tree use a few hundred MB on disk. A CPU build "
    "takes a few minutes and several hundred MB to about 2 GB of RAM. No GPU "
    "is used and no model is downloaded."
)


@dataclass
class Paths:
    state: Path
    install: Path
    staging: Path
    bin_dir: Path

    @property
    def manifest(self) -> Path:
        return self.state / "install.json"

    @property
    def logs(self) -> Path:
        return self.state / "logs"


def default_paths(home: Path | None = None) -> Paths:
    home = Path(home).expanduser() if home else Path.home()
    state = Path(os.environ.get("XDG_STATE_HOME", home / ".local" / "state"))
    data = Path(os.environ.get("XDG_DATA_HOME", home / ".local" / "share"))
    base = state / "dictation-source-installer"
    root = data / "dictation-source-installer"
    return Paths(
        state=base,
        install=root / "engine" / SOURCE_REVISION,
        staging=root / "staging" / SOURCE_REVISION,
        bin_dir=home / ".local" / "bin",
    )


def child_env(extra: dict | None = None) -> dict:
    """A child environment without credential-looking variables.

    Build tools need almost nothing; passing the user's tokens and keys through
    to a compiler or a package manager would only widen what a log can leak.
    """
    env = {k: v for k, v in os.environ.items() if not _SENSITIVE_ENV.search(k)}
    if extra:
        env.update(extra)
    return env


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


class Cancelled(Exception):
    """Raised inside a running step when the user cancels it."""


class Runner:
    """Runs one owned child process at a time in its own process group."""

    def __init__(self) -> None:
        self.cancelled = False
        self._proc: subprocess.Popen | None = None
        self._lock = threading.Lock()

    def run(self, argv: list[str], logpath: Path | None = None, cwd: Path | None = None) -> int:
        if self.cancelled:
            raise Cancelled()
        if logpath is not None:
            logpath.parent.mkdir(parents=True, exist_ok=True)
            out = open(logpath, "ab")
        else:
            out = subprocess.DEVNULL
        try:
            proc = subprocess.Popen(
                [str(a) for a in argv],
                cwd=str(cwd) if cwd else None,
                env=child_env(),
                stdout=out,
                stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
                start_new_session=True,
            )
        finally:
            if logpath is not None:
                out.close()
        with self._lock:
            self._proc = proc
            cancelled_late = self.cancelled
        if cancelled_late:
            # cancel() landed before the process was tracked; signal it now so
            # the step cannot run to completion and reach publish.
            _signal_group(proc, signal.SIGTERM)
        try:
            rc = proc.wait()
        finally:
            with self._lock:
                self._proc = None
        if self.cancelled:
            raise Cancelled()
        return rc

    def cancel(self) -> None:
        self.cancelled = True
        with self._lock:
            proc = self._proc
        if proc is None or proc.poll() is not None:
            return
        _signal_group(proc, signal.SIGTERM)
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            _signal_group(proc, signal.SIGKILL)

    def reset(self) -> None:
        self.cancelled = False


def _signal_group(proc: subprocess.Popen, sig: int) -> None:
    try:
        os.killpg(proc.pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


# --------------------------------------------------------------------------
# Host inspection
# --------------------------------------------------------------------------


def approval_surface() -> dict | None:
    """The graphical package-approval surface actually present on this host.

    Fedora offers two routes: PackageKit (used by the graphical software
    centres) and a polkit authentication agent reached through ``pkexec``.  The
    installer uses whichever exists and asks polkit, which is the graphical
    privilege prompt.  Neither present means no graphical approval is possible
    and the installer must show a blocked state instead of a terminal recipe.
    """
    if shutil.which("pkcon"):
        return {"kind": "packagekit", "command": "pkcon"}
    if shutil.which("pkexec"):
        return {"kind": "polkit", "command": "pkexec"}
    return None


def missing_packages() -> list[str]:
    rpm = shutil.which("rpm")
    missing: list[str] = []
    if rpm:
        for pkg in FEDORA_PACKAGES:
            rc = subprocess.run(
                [rpm, "-q", pkg], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            ).returncode
            if rc != 0:
                missing.append(pkg)
        return missing
    for pkg, command in PACKAGE_COMMANDS.items():
        if command and shutil.which(command) is None:
            missing.append(pkg)
    return missing


def verify_engine(path: Path) -> tuple[bool, list[str], str]:
    """True when the engine's help text advertises every required flag.

    Matching is on whole tokens: a plain substring test would let ``--batch``
    be satisfied by ``--batch-size`` and report a flag as present that the
    engine does not actually accept.
    """
    try:
        proc = subprocess.run(
            [str(path), "--help"],
            capture_output=True,
            text=True,
            timeout=60,
            env=child_env(),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        return False, list(REQUIRED_FLAGS), str(exc)
    output = (proc.stdout or "") + (proc.stderr or "")
    missing = [
        flag
        for flag in REQUIRED_FLAGS
        if not re.search(rf"(?<![\w-]){re.escape(flag)}(?![\w-])", output)
    ]
    return not missing, missing, output[-4000:]


def find_installed_engines(paths: Paths) -> list[dict]:
    seen: dict[str, dict] = {}
    candidates = []
    which = shutil.which(ENGINE)
    if which:
        candidates.append(Path(which))
    manifest = load_manifest(paths)
    if manifest and manifest.get("engine_path"):
        candidates.append(Path(manifest["engine_path"]))
    link = paths.bin_dir / ENGINE
    if link.is_symlink() or link.exists():
        candidates.append(link)
    for candidate in candidates:
        real = Path(os.path.realpath(candidate))
        key = str(real)
        if key in seen:
            continue
        if not real.is_file() or not os.access(real, os.X_OK):
            continue
        ok, missing, _ = verify_engine(real)
        seen[key] = {
            "path": str(real),
            "usable": ok,
            "missing_flags": missing,
            "installer_owned": paths.install in real.parents,
        }
    return list(seen.values())


# --------------------------------------------------------------------------
# Manifest
# --------------------------------------------------------------------------


def load_manifest(paths: Paths) -> dict | None:
    try:
        return json.loads(paths.manifest.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None


def _write_manifest(paths: Paths, record: dict) -> None:
    paths.state.mkdir(parents=True, exist_ok=True)
    tmp = paths.manifest.with_suffix(".json.new")
    tmp.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, paths.manifest)


# --------------------------------------------------------------------------
# Installer
# --------------------------------------------------------------------------


class Installer:
    def __init__(self, paths: Paths, runner: Runner | None = None, log=None) -> None:
        self.paths = paths
        self.runner = runner or Runner()
        self._log = log or (lambda message: None)
        self.log_lines: list[str] = []

    def log(self, message: str) -> None:
        line = message.rstrip()
        self.log_lines.append(line)
        self._log(line)

    # -- inspection --------------------------------------------------------

    def detect(self) -> dict:
        surface = approval_surface()
        missing = missing_packages()
        engines = find_installed_engines(self.paths)
        return {
            "state": "detected",
            "existing_engines": engines,
            "usable_existing": [e for e in engines if e["usable"]],
            "approval_surface": surface,
            "missing_packages": missing,
            "source": SOURCE_URL,
            "revision": SOURCE_REVISION,
            "install_path": str(self.paths.install / ENGINE),
            "bin_link": str(self.paths.bin_dir / ENGINE),
            "staging": str(self.paths.staging),
        }

    def plan_text(self, detection: dict | None = None) -> str:
        detection = detection or self.detect()
        surface = detection["approval_surface"]
        if surface:
            approval = (
                f"yes, through {surface['command']} and the desktop's polkit prompt"
            )
        else:
            approval = "no graphical package-approval surface was found"
        usable = detection["usable_existing"]
        existing = (
            f"a working engine already exists at {usable[0]['path']} and is left as it is"
            if usable
            else "no working recognition engine was detected"
        )
        missing = detection["missing_packages"]
        packages = ", ".join(missing) if missing else "none missing"
        return "\n".join(
            [
                f"Source: {SOURCE_URL}",
                f"Revision: {SOURCE_REVISION} (the only revision this installer will build)",
                "",
                "This source is fetched over the network with git and built on this machine;",
                "the installer does not download a prebuilt executable or a model.",
                "",
                f"Existing engine: {existing}.",
                f"Graphical package approval: {approval}.",
                f"Fedora development packages to install: {packages}.",
                "",
                f"Build staging: {self.paths.staging}",
                f"Published executable: {self.paths.install / ENGINE}",
                f"PATH link (created only when free): {self.paths.bin_dir / ENGINE}",
                "",
                RESOURCE_NOTE,
            ]
        )

    # -- install -----------------------------------------------------------

    def install(self, approve_packages: bool = False) -> dict:
        self.runner.reset()
        paths = self.paths
        existing = load_manifest(paths)
        if (
            existing
            and existing.get("revision") == SOURCE_REVISION
            and existing.get("engine_path")
        ):
            target = Path(existing["engine_path"])
            if (
                target.is_file()
                and sha256_file(target) == existing.get("engine_sha256")
                and verify_engine(target)[0]
            ):
                self.log(f"revision {SOURCE_REVISION} is already installed and verified")
                return {
                    "state": "already-installed",
                    "engine": str(target),
                    "revision": SOURCE_REVISION,
                }

        missing = missing_packages()
        surface = approval_surface()
        if missing:
            if not approve_packages:
                return {
                    "state": "blocked",
                    "reason": "missing packages require explicit approval: "
                    + ", ".join(missing),
                    "missing_packages": missing,
                    "approval_surface": surface,
                }
            if surface is None:
                return {
                    "state": "blocked",
                    "reason": "no graphical package-approval surface (PackageKit or "
                    "polkit) is available; install the prerequisites through the "
                    "desktop and retry",
                    "missing_packages": missing,
                    "approval_surface": None,
                }
            self.log(f"requesting approval for: {', '.join(missing)}")
            argv = (
                ["pkcon", "-y", "install", *missing]
                if surface["kind"] == "packagekit"
                else [
                    "pkexec",
                    "dnf",
                    "install",
                    "-y",
                    "--setopt=install_weak_deps=False",
                    *missing,
                ]
            )
            try:
                rc = self.runner.run(argv, logpath=self._log_path("packages"))
            except Cancelled:
                return {"state": "cancelled", "reason": "package approval was cancelled"}
            if rc != 0:
                return {
                    "state": "blocked",
                    "reason": "package approval was refused or failed (exit "
                    f"{rc}); see {self._log_path('packages')}",
                    "missing_packages": missing,
                    "approval_surface": surface,
                }
            still_missing = missing_packages()
            if still_missing:
                return {
                    "state": "blocked",
                    "reason": "after approval these packages are still missing: "
                    + ", ".join(still_missing),
                    "missing_packages": still_missing,
                }

        staging = paths.staging
        if staging.exists():
            shutil.rmtree(staging)
        staging.mkdir(parents=True, exist_ok=True)

        try:
            self.log("fetching the pinned source revision")
            fetched, detail = self.fetch_source(staging, self._log_path("git"))
            if not fetched:
                return {
                    "state": "error",
                    "reason": f"{detail}; see {self._log_path('git')}",
                }
            self.log(f"source verified at revision {detail}")

            build_dir = staging / "build"
            self.log("configuring the CPU build")
            if not self.compile_source(staging, build_dir, self._log_path("build")):
                return {"state": "error", "reason": f"build failed; see {self._log_path('build')}"}
            self.log("build finished; publishing")
            result = self.publish(build_dir, staging)
        except Cancelled:
            return {"state": "cancelled", "reason": "the build was cancelled"}
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        return result

    def fetch_source(self, dest: Path, logpath: Path) -> tuple[bool, str]:
        steps = [
            ["git", "init", "-q", str(dest)],
            ["git", "-C", str(dest), "remote", "add", "origin", SOURCE_URL],
            ["git", "-C", str(dest), "fetch", "-q", "--depth", "1", "origin", SOURCE_REVISION],
            ["git", "-C", str(dest), "checkout", "-q", "--detach", "FETCH_HEAD"],
        ]
        for argv in steps:
            rc = self.runner.run(argv, logpath=logpath)
            if rc != 0:
                return False, f"git failed ({' '.join(argv[1:4])}) with exit {rc}"
        head = self._capture(["git", "-C", str(dest), "rev-parse", "HEAD"]).strip()
        url = self._capture(["git", "-C", str(dest), "remote", "get-url", "origin"]).strip()
        if head != SOURCE_REVISION:
            return False, f"fetched revision {head or 'unknown'} does not match pinned {SOURCE_REVISION}"
        if url != SOURCE_URL:
            return False, f"unexpected source remote {url!r}"
        if not (dest / "CMakeLists.txt").is_file():
            return False, "the fetched revision has no CMakeLists.txt"
        return True, head

    def compile_source(self, source: Path, build_dir: Path, logpath: Path) -> bool:
        configure = ["cmake", "-S", str(source), "-B", str(build_dir), *CMAKE_ARGS]
        if self.runner.run(configure, logpath=logpath) != 0:
            return False
        build = ["cmake", "--build", str(build_dir), "--parallel"]
        return self.runner.run(build, logpath=logpath) == 0

    def publish(self, build_dir: Path, source: Path | None = None) -> dict:
        if self.runner.cancelled:
            raise Cancelled()
        exe = build_dir / "bin" / ENGINE
        if not exe.is_file():
            return {"state": "error", "reason": "the build produced no build/bin/transcribe-cli"}
        ok, missing, _ = verify_engine(exe)
        if not ok:
            return {
                "state": "error",
                "reason": "the built engine does not accept the required flags: "
                + ", ".join(missing),
            }
        digest = sha256_file(exe)
        target = self.paths.install / ENGINE
        target.parent.mkdir(parents=True, exist_ok=True)
        staged = target.with_suffix(".new")
        shutil.copy2(exe, staged)
        os.chmod(staged, 0o755)
        os.replace(staged, target)
        linked = self._link_into_path(target)
        # Keep the upstream license text beside the executable: it is what the
        # manifest refers to, and staging (which holds the checkout) is removed
        # as soon as this run ends.
        license_files = self._copy_license_files(source, target.parent)
        record = {
            "schema": 1,
            "engine": ENGINE,
            "source": SOURCE_URL,
            "revision": SOURCE_REVISION,
            "build_args": list(CMAKE_ARGS),
            "engine_path": str(target),
            "engine_sha256": digest,
            "license": "MIT (transcribe.cpp); vendored components are covered in the copied license files",
            "license_files": license_files,
            "installed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "path_link": str(self.paths.bin_dir / ENGINE) if linked else None,
        }
        _write_manifest(self.paths, record)
        self.log(f"published {target} ({digest[:12]}…)")
        return {
            "state": "installed",
            "engine": str(target),
            "sha256": digest,
            "revision": SOURCE_REVISION,
            "linked_into_path": linked,
        }

    def _copy_license_files(self, source: Path | None, dest: Path) -> list[str]:
        if source is None:
            return []
        copied: list[str] = []
        for name in ("LICENSE", "LICENSE.md", "LICENSE.txt", "THIRD-PARTY-LICENSES.md"):
            candidate = source / name
            if candidate.is_file() and candidate.stat().st_size < (1 << 20):
                shutil.copy2(candidate, dest / name)
                copied.append(name)
        return copied

    def _link_into_path(self, target: Path) -> bool:
        link = self.paths.bin_dir / ENGINE
        if link.is_symlink() and os.path.realpath(link) == str(target):
            return True
        if link.exists() or link.is_symlink():
            self.log(f"left {link} untouched; select {target} in Dictation instead")
            return False
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(target)
        return True

    def remove(self) -> dict:
        record = load_manifest(self.paths)
        removed: list[str] = []
        link = self.paths.bin_dir / ENGINE
        if record and link.is_symlink():
            if os.path.realpath(link) == record.get("engine_path"):
                link.unlink()
                removed.append(str(link))
        if record and record.get("engine_path"):
            owned = Path(record["engine_path"]).parent
            try:
                inside = owned.resolve().is_relative_to(self.paths.install.resolve())
            except (OSError, ValueError):
                inside = False
            if not inside:
                owned = self.paths.install
            if owned.is_dir():
                shutil.rmtree(owned)
                removed.append(str(owned))
        elif self.paths.install.is_dir():
            # A manifest-write failure must not strand installer-owned files.
            shutil.rmtree(self.paths.install)
            removed.append(str(self.paths.install))
        for path in (self.paths.manifest,):
            if path.exists():
                path.unlink()
                removed.append(str(path))
        for tree in (self.paths.staging, self.paths.logs):
            shutil.rmtree(tree, ignore_errors=True)
        return {"state": "removed", "removed": removed}

    # -- helpers -----------------------------------------------------------

    def _log_path(self, name: str) -> Path:
        self.paths.logs.mkdir(parents=True, exist_ok=True)
        return self.paths.logs / f"{name}.log"

    def _capture(self, argv: list[str]) -> str:
        proc = subprocess.run(
            argv, capture_output=True, text=True, timeout=60, env=child_env()
        )
        return proc.stdout or ""


# --------------------------------------------------------------------------
# Graphical interface
# --------------------------------------------------------------------------


def run_gui(paths: Paths) -> int:
    import tkinter as tk
    from tkinter import messagebox, scrolledtext, ttk

    class App:
        def __init__(self) -> None:
            self.lines: list[str] = []
            self.result: tuple[str, dict] | None = None
            self.detection: dict | None = None
            self.busy = False

        def push(self, line: str) -> None:
            self.lines.append(line)

        def show(self, text: str) -> None:
            info.configure(state="normal")
            info.delete("1.0", "end")
            info.insert("1.0", text)
            info.configure(state="disabled")

        def drain(self) -> None:
            while self.lines:
                line = self.lines.pop(0)
                status.configure(text=line)

    app = App()
    installer = Installer(paths, log=app.push)
    root = tk.Tk()
    root.title("Dictation source installer")
    root.geometry("760x560")
    root.minsize(620, 460)

    frame = ttk.Frame(root, padding=12)
    frame.pack(fill="both", expand=True)
    ttk.Label(
        frame,
        text="Build the transcribe.cpp recognition engine from source (CPU only)",
        font=("", 12, "bold"),
    ).pack(anchor="w")
    ttk.Label(
        frame,
        text="Separate from the Dictation plugin. Nothing is downloaded prebuilt and no model is fetched.",
        wraplength=720,
    ).pack(anchor="w", pady=(2, 8))

    info = scrolledtext.ScrolledText(frame, height=14, wrap="word", state="disabled")
    info.pack(fill="both", expand=True)

    status = ttk.Label(frame, text="Checking this host…", wraplength=720)
    status.pack(anchor="w", pady=(8, 4))
    progress = ttk.Progressbar(frame, mode="indeterminate")

    buttons = ttk.Frame(frame)
    buttons.pack(fill="x", pady=(6, 0))
    install_button = ttk.Button(buttons, text="Install from source")
    remove_button = ttk.Button(buttons, text="Remove installer files")
    cancel_button = ttk.Button(buttons, text="Cancel", state="disabled")
    install_button.pack(side="left")
    remove_button.pack(side="left", padx=6)
    cancel_button.pack(side="right")

    def set_busy(busy: bool) -> None:
        app.busy = busy
        cancel_button.configure(state="normal" if busy else "disabled")
        install_button.configure(state="disabled" if busy else "normal")
        remove_button.configure(state="disabled" if busy else "normal")
        if busy:
            progress.pack(fill="x", pady=(0, 4))
            progress.start(12)
        else:
            progress.stop()
            progress.pack_forget()

    def finish(action: str, result: dict) -> None:
        set_busy(False)
        lines = [f"{k}: {v}" for k, v in result.items()]
        app.show("\n".join(lines))
        state = result.get("state")
        if action == "detect":
            app.detection = result
            app.show(installer.plan_text(result))
            usable = result.get("usable_existing") or []
            if usable:
                status.configure(
                    text=f"An engine already works at {usable[0]['path']}. Building is optional."
                )
            elif result.get("approval_surface"):
                status.configure(text="Ready to build from source after you approve the packages.")
            else:
                status.configure(
                    text="Blocked: no graphical package-approval surface (PackageKit or polkit) was found."
                )
        elif state in {"installed", "already-installed"}:
            messagebox.showinfo("Dictation source installer", result.get("reason", "Engine ready."))
            status.configure(text=f"Engine ready at {result.get('engine')}")
        elif state == "blocked":
            messagebox.showwarning("Approval blocked", result.get("reason", "Blocked"))
        elif state == "cancelled":
            status.configure(text="Cancelled. Nothing was published.")
        elif state == "error":
            messagebox.showerror("Install failed", result.get("reason", "Failed"))

    def worker(action: str) -> None:
        try:
            if action == "install":
                result = installer.install(approve_packages=True)
            elif action == "remove":
                result = installer.remove()
            else:
                result = installer.detect()
        except Exception as exc:  # keep the window alive and report it
            result = {"state": "error", "reason": f"{type(exc).__name__}: {exc}"}
        # Hand the result to the main loop; tkinter is not thread safe.
        app.result = (action, result)

    def start(action: str) -> None:
        if app.busy:
            return
        set_busy(True)
        status.configure(text="Working…")
        threading.Thread(target=worker, args=(action,), daemon=True).start()

    def request_cancel() -> None:
        # cancel() waits for the process group to stop, so keep it off the
        # event loop or the window would freeze for up to eight seconds.
        status.configure(text="Cancelling…")
        threading.Thread(target=installer.runner.cancel, daemon=True).start()

    install_button.configure(command=lambda: start("install"))
    remove_button.configure(command=lambda: start("remove"))
    cancel_button.configure(command=request_cancel)

    def tick() -> None:
        app.drain()
        if app.result is not None:
            action, result = app.result
            app.result = None
            finish(action, result)
        root.after(150, tick)

    tick()
    start("detect")
    root.mainloop()
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--detect", action="store_true", help="print host inspection as JSON")
    group.add_argument("--install", action="store_true", help="build and publish the engine")
    group.add_argument("--remove", action="store_true", help="remove installer-owned files only")
    parser.add_argument(
        "--approve-packages",
        action="store_true",
        help="allow the graphical approval surface to install the prerequisites",
    )
    args = parser.parse_args(argv)
    paths = default_paths()
    installer = Installer(paths, log=lambda line: print(line, file=sys.stderr))

    if args.detect:
        print(json.dumps(installer.detect(), indent=2, sort_keys=True))
        return 0
    if args.install:
        result = installer.install(approve_packages=args.approve_packages)
        print(json.dumps(result, indent=2, sort_keys=True))
        return 0 if result["state"] in {"installed", "already-installed"} else 1
    if args.remove:
        print(json.dumps(installer.remove(), indent=2, sort_keys=True))
        return 0
    return run_gui(paths)


if __name__ == "__main__":
    raise SystemExit(main())
