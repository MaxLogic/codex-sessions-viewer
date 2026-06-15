# Codex Session Viewer

Codex Session Viewer is a local-only Flutter Windows app for browsing,
searching, reviewing, exporting, and resuming Codex session history. It indexes
session metadata and searchable text into SQLite with FTS5 while leaving the
original Codex JSONL files as the source of truth.

The app does not send prompts, paths, messages, token data, or private session
content to external services. OpenRouter pricing is optional and used only for
model pricing metadata when enabled.

## Run

Development requires Flutter with Windows desktop support. This repository is
validated with Flutter 3.44.1 from the local SDK at `C:\tools\flutter`.

```powershell
$env:PATH = 'C:\tools\flutter\bin;' + $env:PATH
cd app
flutter pub get
flutter run -d windows
```

## Build

Use the repository scripts for normal release validation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package_release.ps1
```

`build_windows.ps1` checks Flutter, runs formatting, analysis, tests, and the
Windows release build. It prepares `release\windows` with
`codex_session_viewer.exe`, Flutter runtime files, `README.md`, `settings.toml`,
`sql`, and `assets`.

`package_release.ps1` rebuilds through the build script, creates
`release\package`, and writes `release\codex_session_viewer_windows.zip`.

Refresh local benchmark results with:

```powershell
cd app
dart run bin/benchmark_local.dart --fixtures ../samples/sessions --out ../docs/benchmark-results.md
```

## Configuration

Configuration lives in `settings.toml`. The packaged copy is a starting point;
adjust paths for each machine.

Windows Codex sessions:

```toml
[paths]
windows_codex_path = 'C:\Users\<user>\.codex'
```

WSL Codex sessions:

```toml
[paths]
wsl_codex_unc_path = '\\wsl.localhost\Ubuntu\home\<user>\.codex'

[wsl]
distro = 'Ubuntu'
linux_home = '/home/<user>'
linux_root_unc = '\\wsl.localhost\Ubuntu\'
```

Terminal profiles:

```toml
[terminal]
default_terminal = 'alacritty'

[terminal.alacritty]
enabled = true
exe = 'C:\Program Files\Alacritty\alacritty.exe'

[terminal.windows_terminal]
enabled = true
exe = 'wt.exe'
```

Scanner and pricing durations use explicit units:

```toml
[scanner]
background_rescan_interval_seconds = 300

[pricing]
cache_pricing_hours = 24
```

OpenRouter pricing:

```toml
[pricing]
provider = 'openrouter'
use_external_pricing = true
cache_pricing_hours = 24
fallback_to_overrides = true
```

Keep the OpenRouter API key in local private configuration. Do not commit real
keys.

## Accessibility

The UI is designed for keyboard and screen-reader use. It avoids exposing a
whole conversation as one large accessible node, collapses large tool output by
default, provides a focus reader, and exposes table equivalents for usage
charts.

Run the accessibility verification suite with:

```powershell
cd app
flutter test test/accessibility
```

See `docs/accessibility-verification.md` for the current checklist.

## Troubleshooting

WSL path unavailable:
Verify the distro name with `wsl.exe -l -v`, then check that the configured UNC
path opens in File Explorer.

FTS5 unavailable:
Verify the SQLite build supports FTS5. The app migration/startup flow reports
database and migration failures instead of silently disabling search.

DB migration failure:
Check the logs screen and local log file configured in `settings.toml`. Keep the
database file for inspection before deleting or recreating it.

Terminal launch failure:
Use the Settings diagnostics for Alacritty, Windows Terminal, WSL command, and
Codex command checks. Confirm the configured executable paths exist.

Codex command not found:
Verify `codex` is on PATH for the selected platform. For WSL sessions, validate
the command inside the configured distro.
