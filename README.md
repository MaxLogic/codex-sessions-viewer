# Codex Session Viewer

Codex Session Viewer is a local-first Flutter Windows app for browsing,
searching, reviewing, exporting, and resuming Codex session history. It indexes
session metadata and searchable text into SQLite with FTS5 while leaving the
original Codex JSONL files as the source of truth.

The app runs locally without a hub. If you explicitly configure a personal hub,
the collector sends normalized session records to it for browsing across machines.
OpenRouter pricing is optional and sends no session content to the pricing provider.

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

`build_windows.ps1` checks Flutter and Rust, runs formatting, analysis, unit and integration tests, and the
Windows release build. It prepares `release\windows` with
`codex_session_viewer.exe`, `codex-sessions-collector.exe`, `codex-sessions-hub.exe`, Flutter runtime files, `README.md`, `settings.toml`,
`sql`, and `assets`.

Independent harness collectors can emit the [version 1 ingestion contract](docs/collectors/contract-v1.md).
The runnable [Python example](samples/collector-contract/example_collector.py)
and `python scripts/verify_collector_examples.py` show local integration.
An explicitly configured [personal hub](docs/hub-setup.md) can receive
normalized records while local collection and browsing remain available.

`package_release.ps1` rebuilds through the build script, creates
`release\package`, and writes `release\codex_session_viewer_windows.zip`.
The local `release\windows\settings.toml` is preserved across builds. The
package and ZIP always contain `settings.sample.toml` as `settings.toml`, so
local paths and credentials are not distributed.

The Rust collector parses every session file; the viewer reads only what it
stored. To time a refresh through the collector on a local corpus, run the
scan memory benchmark (`--benchmark-scan-memory` on the built viewer, see
`app/lib/src/benchmark/scan_memory_benchmark.dart`). Keep private corpora and
their reports in ignored storage such as `.agents/private-session-corpus/` and
`.agents/benchmark-results/`; reports contain aggregate timings and counts
only.

## Configuration

Configuration lives in `settings.toml`. The package starts with safe sample
settings; configure paths for each machine after installation. Keep the local
runtime file out of any package you share.

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
refresh_interval_hours = 6
refresh_utc_slots = true
```

OpenRouter pricing:

```toml
[pricing]
provider = 'openrouter'
use_external_pricing = true
refresh_interval_hours = 6
refresh_utc_slots = true
fallback_to_overrides = true
```

New installations observe public prices at 00:00, 06:00, 12:00 and 18:00 UTC;
the packaged `settings.sample.toml` enables this refresh of the public OpenRouter
catalog, which needs no API key. With a [personal hub](docs/hub-price-history.md)
configured in `[hub] url`, the viewer shares price history with it, reading the
machine credential only from `CODEX_SESSIONS_HUB_MACHINE_TOKEN`; Settings shows
why a hub price sync failed.
Missed slots coalesce into one catch-up attempt when the app next runs. Existing
explicit intervals (including the legacy `cache_pricing_hours` key) retain their
interval cadence. Set `refresh_utc_slots = false` for an interval measured from
the last successful observation; intervals other than six hours also select this
mode. Failed downloads keep existing observations and retry with bounded backoff.
Observation time is the actual download time, so history is never backdated.

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
