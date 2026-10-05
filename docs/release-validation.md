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
