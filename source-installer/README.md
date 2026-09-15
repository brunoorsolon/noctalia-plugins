# Dictation engine source installer

A standalone graphical installer that builds the [transcribe.cpp](https://github.com/handy-computer/transcribe.cpp) recognition engine on a Fedora desktop for users who have no compatible recognition executable yet. It is for the `magus/dictation` Noctalia plugin, but it is **not part of that plugin** and is not loaded or executed by it.

```sh
python3 source-installer/dictation_source_installer.py
```

A `dictation-source-installer.desktop` launcher is included; it resolves the script next to itself, so it works while it stays in this directory. To add a menu entry, copy the launcher to `~/.local/share/applications/` and edit its `Exec` line to the absolute path of `dictation_source_installer.py`.

## Why it is separate

The Noctalia plugin rules do not allow a plugin to fetch, build or run remote code. The plugin therefore only ever consumes an executable that already exists, and this route is distributed and executed on its own.

The installer's own boundary is narrow. It will never:

- download a prebuilt inference binary or a model;
- patch, vendor or modify the engine source;
- run a build command supplied by a user, a file or a shell string;
- install a GPU stack (Vulkan, CUDA, HIP or Metal) or update unrelated packages;
- replace an existing working engine, or delete anything it did not install;
- run as, or ask for, a general root shell.

## What it does

1. **Inspects the host before offering a build.** It reports any recognition engine already on `PATH` or in its own install location, whether that engine accepts the flags the plugin passes, the graphical package-approval surface that actually exists, and which Fedora development packages are missing.
2. **Explains the plan.** The window shows the source repository and the single pinned revision, the build and install locations, the packages to install, that the source is fetched over the network, and the expected disk and memory use. It states plainly that no prebuilt executable and no model is downloaded.
3. **Asks for package approval.** It installs only `git cmake gcc-c++ make openblas-devel` through PackageKit (`pkcon`) or the polkit agent (`pkexec dnf`), whichever this desktop provides, so approval happens in the normal graphical prompt. If neither surface exists it shows a blocked state and does not fall back to terminal instructions.
4. **Fetches one pinned revision.** `git init` / `remote add` / `fetch --depth 1` / `checkout --detach` of revision `9eed7f0919ac97c71c71dcd5dcc765c969aa2b05`, then it verifies that `HEAD` and the `origin` URL match the pin. Any other commit is rejected.
5. **Builds the ordinary CPU target in staging.** `cmake -B <staging>/build` with `CMAKE_BUILD_TYPE=Release` and `TRANSCRIBE_VULKAN/CUDA/HIP/METAL=OFF`, then `cmake --build --parallel`. The plugin's explicit `--backend cpu --threads 4` invocation is what the built engine is checked against; nothing here advertises portability.
6. **Publishes only on success.** The built `transcribe-cli` must advertise every flag the plugin's own probe requires — `--backend --threads --timestamps --model --batch --batch-size --batch-jsonl`, matched as whole tokens — before it is copied into place atomically. The manifest records the source revision, build configuration, executable SHA-256, license/attribution and install time, and the upstream license files are copied next to the executable so the attribution survives the staging cleanup.
7. **Selects into Dictation.** The engine is published under the installer's own data directory and linked into `~/.local/bin` when that name is free, so the setup introduced in #9 can find it. If an engine of the user's own is already there, it is left untouched and the window names the path to select instead.

`Progress`, `Cancel`, errors and re-running the install after a failure are all in the window; `Cancel` stays responsive because the process-group teardown happens off the event loop. Cancel signals only the process group the installer started; a cancelled or failed build publishes nothing and keeps its log.

## Locations

| Purpose | Path |
| --- | --- |
| Published engine and its license files | `~/.local/share/dictation-source-installer/engine/<revision>/` |
| PATH link (only when free) | `~/.local/bin/transcribe-cli` |
| Build staging (removed when the run ends) | `~/.local/share/dictation-source-installer/staging/<revision>` |
| Manifest | `~/.local/state/dictation-source-installer/install.json` |
| Diagnostics | `~/.local/state/dictation-source-installer/logs/` |

`XDG_DATA_HOME` and `XDG_STATE_HOME` are honoured.

## Removing it

`Remove installer files` deletes only what the manifest records: its own engine directory, the `~/.local/bin` link when that link points at its own engine, the manifest and the staging tree. A user's own engine, the user's models and the plugin's transcription history are never touched.

## Repeated use

Installing again verifies the recorded SHA-256 and the engine's flags; a matching install is reported as already installed and is not rebuilt. A build that failed or was cancelled leaves no partial executable and can simply be retried. Only the pinned revision is ever built, so a rerun converges on the same result rather than accumulating installs.

## Requirements and known limits

- A Fedora desktop session with PackageKit or a polkit authentication agent, and a working graphical approval prompt.
- Roughly a few hundred MB of disk for the build tree, and several hundred MB to about 2 GB of peak RAM. A CPU build takes a few minutes. No GPU is used.
- Only the CPU path is built. It does not install or advertise Vulkan, CUDA, HIP or Metal.
- Publishing proves the executable's identity and that it advertises the flags the plugin passes. The engine is not run with `--backend cpu --threads 4` and no GGUF transcription is performed during installation, because both need a model the user supplies; that remains a host-side step.
- Recognising audio still requires a compatible GGUF model that the user supplies or downloads themselves; this installer does not fetch models.

## Checks

```sh
source-installer/selftest.sh
```

Drives the real headless engine with fake `git`, `cmake`, `rpm`, `pkcon` and engine tools on `PATH`, and covers publishing and convergence, a tampered revision, a missing approval surface, denied approval, a failed build with preserved diagnostics, cancellation during a build, and removal that leaves a user's own engine and unrelated files intact. It needs no network, no Fedora host and no display.

Host-dependent behavior — a real Fedora graphical approval prompt, a real CMake build of transcribe.cpp, the engine appearing in the plugin's setup and completing a transcription — cannot be exercised by that self-test and has not been verified in this repository.

## License

The installer is covered by this repository's license. The engine it builds is MIT-licensed upstream; the upstream license files found in the checkout are copied next to the published executable and listed in the manifest.
