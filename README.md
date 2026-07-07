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

For realistic scan timing, copy local Codex session files into ignored private
benchmark storage and write the aggregate report to ignored benchmark storage:

```powershell
cd app
dart run bin/benchmark_local.dart --copy-from-settings --private-corpus ../.agents/private-session-corpus --out ../.agents/benchmark-results/session-scan-baseline.md --skip-release
```

Do not commit `.agents/private-session-corpus/` or
`.agents/benchmark-results/`. The private benchmark report is designed to
contain aggregate timings and counts only.

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

## Local Evals And Context Search

Use Sessions to mark a local session as eval-ready. Select a session, use the
eval controls in the detail pane to add or remove it from Evals, and edit the
review status, notes, or expected output when the session needs a durable eval
target.

Use Evals for review and export. The screen lists eval-ready sessions with
status, project, source, model/provider, tags, notes, and expected-output
markers. Filters narrow the queue by status, tag, source, project, model, or
text. Export can include selected rows or the current filtered set.

Dataset export formats are DeepEval JSON, OpenAI eval JSONL, Promptfoo JSONL,
Markdown files, and plain text files. Turn modes are full conversation, each
user/assistant turn, or final assistant answer only. The path anonymization
option is on by default for exports; turn it off in export options only when
full local paths are needed in the dataset.

Use Context Search to find reusable context without leaving the app. Session
mode searches session metadata; message mode searches the local message FTS
index and returns snippets with author, session identity, project/source, and
timestamp. Selected context can be copied, and a result can open the matching
session at the target message.

The eval and Context Search workflow is local-only. There is no cloud sync, no
external embeddings, no remote export, and no background network calls for
session content or context search.

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
