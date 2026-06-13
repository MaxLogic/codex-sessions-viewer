# Release Validation

Use the checked-in PowerShell scripts from the repository root.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package_release.ps1
```

## Build Script

`scripts/build_windows.ps1` performs the normal release build path:

1. Checks Flutter, using `C:\tools\flutter\bin` as a fallback location.
2. Runs `flutter pub get`.
3. Runs `dart format --set-exit-if-changed .`.
4. Runs `flutter analyze`.
5. Runs `flutter test`.
6. Runs `flutter build windows`.
7. Prepares `release\windows`.

The release folder contains:

- `codex_session_viewer.exe`
- Flutter runtime files, including `flutter_windows.dll`, `sqlite3.dll`,
  `native_assets.json`, and `data`
- `README.md`
- `settings.toml`
- `sql`
- `assets`

If root `README.md` is not present, the script writes a short packaged fallback.
The default settings file is copied only when missing from the output folder.

## Package Script

`scripts/package_release.ps1` invokes `build_windows.ps1`, refreshes
`release\package`, copies the prepared release payload, and creates:

```text
release\codex_session_viewer_windows.zip
```

The package must include the same release payload as `release\windows`,
including the Flutter runtime files. A package that contains only the executable
is incomplete.

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
