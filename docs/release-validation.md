# Release Validation

Use the checked-in PowerShell scripts from the repository root.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package_release.ps1
```

## Build Script

`scripts/build_windows.ps1` performs the normal release build path:

1. Checks Flutter and Rust, using `C:\tools\flutter\bin` as a Flutter fallback.
2. Checks Rust formatting and Clippy, runs the Rust tests, and builds the collector and hub executables.
3. Runs `flutter pub get`, `dart format --set-exit-if-changed .`, and `flutter analyze`.
4. Runs `flutter test` and `flutter test integration_test` with the just-built collector and hub.
5. Runs `flutter build windows` and prepares `release\windows`.

The release folder contains:

- `codex_session_viewer.exe`
- `codex-sessions-collector.exe`
- `codex-sessions-hub.exe`
- `codex-sessions-scan-launcher.exe` (windowless runner for the scheduled background scan)
- Flutter runtime files, including `flutter_windows.dll`, `sqlite3.dll`,
  `native_assets.json`, and `data`
- `README.md`
- `settings.sample.toml`
- `sql`
- `assets`

If root `README.md` is not present, the script writes a short packaged fallback.
The build preserves an existing local `release\windows\settings.toml` and copies
`settings.sample.toml` separately. It does not create a runtime settings file.

## Package Script

`scripts/package_release.ps1` invokes `build_windows.ps1`, refreshes
`release\package`, copies the prepared release payload, and creates:

```text
release\codex_session_viewer_windows.zip
```

The package includes the built executable and Flutter runtime files. It excludes
the local `settings.toml` and contains `settings.sample.toml`. Before sharing
the ZIP, verify that neither the package nor archive contains `settings.toml`,
that both sample copies match the repository sample, and that
`release\windows\settings.toml` retains its local contents. A package that
contains only the executable is incomplete.

Run the native UI Automation filter smoke check against the packaged executable
and complete the separate NVDA keyboard and speech pass in
[accessibility release checks](accessibility-release-check.md). Flutter widget
semantics, Windows UI Automation, and NVDA speech are distinct evidence.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_release_filter_uia.ps1
```

## Additional Checks

PowerShell script checks:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_release_scripts.ps1
Invoke-ScriptAnalyzer -Path scripts -Recurse
```

Documentation privacy check:

```powershell
rg -n "api_key\s*=\s*\"[^\"]+\"" README.md docs scripts
```

Expected result: no matches for literal private API key examples.

## Native macOS and Linux releases

Run each script on its native host, from a checkout with Python 3.11 or newer,
Flutter/Dart, Cargo, rustfmt and Clippy on PATH. Linux also needs clang, CMake,
Ninja, pkg-config and GTK 3 development files; macOS needs Xcode and its command
line tools. These wrappers use Bash 3.2-compatible syntax:

```bash
bash scripts/build_linux.sh
bash scripts/build_macos.sh
```

The wrappers use `python3` by default. If that name points to an older Python,
select an installed supported interpreter explicitly, for example
`CXV_PYTHON=python3.11 bash scripts/build_linux.sh`. Python older than 3.11 fails
with a clear prerequisite message before any release gate; global PATH and
Python installations are left unchanged.

Each native pipeline runs the Windows gate sequence: Cargo format check,
locked Clippy, locked tests with `--no-fail-fast`, locked release binaries,
Flutter dependency resolution, Dart format check, Flutter analysis, unit/widget
tests, integration tests and the native release build. Flutter tests receive
absolute paths to the just-built collector and hub. Environment overrides are
passed only to children. Cargo and native compilation use at most two jobs;
temporary PATH shims enforce Ninja `-j2` and Xcode project `-jobs 2` without
modifying the Flutter SDK.
Independent gates continue after failures, while missing/failed native sidecars
block dependent Flutter tests. Any gate failure blocks packaging.

Native steps retain logs and JSON status (exit code, duration, deadline and
input fingerprint) in `release/logs/<platform>-<run>/`. Each step has a
60-minute deadline for its entire owned POSIX process group, including children
whose parent exits early. On expiry the runner sends TERM, waits five seconds,
then sends KILL; timeout is exit 124. Other failures retain the first native
error code. Signing/notary arguments and tool output are suppressed to protect
configured identity and profile names. Full logs stay local; archives contain
public release payload only.

Outputs:

| Platform | Bundle | Archive |
| --- | --- | --- |
| macOS | `release/macos/codex_sessions_viewer.app` | `release/codex_sessions_viewer_macos.zip` |
| Linux | `release/linux` | `release/codex_sessions_viewer_linux.tar.gz` |

The complete Flutter-generated bundle is preserved, including native SQLite,
plugin libraries, Flutter assets, executable modes and internal framework
symlinks. The collector and hub sit beside the viewer: macOS `Contents/MacOS`,
Linux bundle root. Public SQL, app assets, README and byte-identical sample
settings sit in macOS `Contents/Resources` and Linux `data/`. Runtime
`settings.toml`, profile directories and database/WAL/SHM files are excluded.
External, absolute, dangling and cyclic bundle symlinks are rejected. Build and
source folders cannot overlap the package output. Staging precedes publication,
so failed gates, version checks or signing keep the previous release available.

The public manifest distinguishes pubspec's app version/build number from
Cargo's collector version. Linux's manifest is in its bundle; macOS metadata
lives beside the signed `.app` to avoid modifying its signature. Packaging
executes only the bundled collector's `version` command and checks the hub
artifact's presence. The hub has no version command and is never started by
the packager.

Linux portable launch is `./codex_sessions_viewer` from `release/linux`, or its
absolute path after extracting the archive. The app-ID desktop entry and icon
are included for an optional XDG installation. Its bare `Exec` assumes the
viewer is on PATH; it does not install itself when unpacked in Downloads. For
a per-user installation, copy the bundle to a chosen permanent directory,
copy `eu.maxlogic.codexsessionsviewer.desktop` to
`~/.local/share/applications/`, and change its `Exec` to the quoted absolute
viewer path and its `Icon` to the absolute
`data/eu.maxlogic.codexsessionsviewer.png` path. Quote desktop-entry values
according to the desktop-entry specification (shell quoting is different).
The build never modifies desktop/profile locations. No AppImage or deb is
produced by this pipeline.

macOS ordinary local/CI bundles reapply ad-hoc signing after adding resources
and sidecars, then verify the app seal. They require no
distribution secrets. To use existing Developer ID credentials, configure
`CXV_MACOS_SIGN_IDENTITY`. Set `CXV_MACOS_NOTARY_PROFILE` only for an already
configured notarytool keychain profile; a profile without an identity fails
before building. The distribution path signs embedded code inside-out, signs
both sidecars and the app with hardened runtime/timestamps, verifies the
signature, uploads a temporary ZIP for notarization, staples and validates the
ticket, then recreates the final ZIP with macOS `ditto` to retain extended
metadata. It does not import credentials, create
profiles or add sandbox entitlements. Signing and notarization require a Mac
with the corresponding configured credentials; fixture ordering is separate
from actual distribution proof.

Cheap fixture checks (no compilers, app startup or real signing):

```bash
python3 -B scripts/test_native_release.py
bash -n scripts/build_linux.sh
bash -n scripts/build_macos.sh
```

`.github/workflows/native-release.yml` runs the native Windows and Linux
pipelines on separate hosted runners, with a 150-minute job deadline and at
most two concurrent matrix jobs. macOS is not in the workflow: it failed there
and has no Mac to diagnose it on, so `scripts/build_macos.sh` has to be run on a
Mac. Windows retains the existing PowerShell pipeline. CI pins Flutter 3.47.9, Rust 1.99.1 and immutable action commits
verified from their upstream release tags: [checkout v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1),
[setup-python v7.1.0](https://github.com/actions/setup-python/releases/tag/v7.1.0),
[upload-artifact v7.0.2](https://github.com/actions/upload-artifact/releases/tag/v7.0.2)
and [flutter-action v2.23.0](https://github.com/subosito/flutter-action/releases/tag/v2.23.0).
Workflow source does not constitute a CI run or authorize a push.

Before accepting a native release, run its complete script on that host,
inspect the archive, start the packaged viewer, verify native SQLite with a
disposable database and run the bundled collector's `version` command.
Actual macOS build/start/signing/notarization and native GUI/screen-reader
behavior remain separate required evidence; focused fixtures cannot prove
them. Full native gates belong to the coherent batch checkpoint after portable
commands/fixtures and the outstanding analysis decision are resolved.
