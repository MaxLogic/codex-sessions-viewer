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

## Sessions started by other sessions

In Settings, set **T3 Code state database (optional)** to T3's `statev2.sqlite`
and select the session source platform. Leave the path blank to disable the lookup.
Refresh sessions to import T3's explicit fork and subagent links. The collector opens
T3 state read only; an unavailable or incompatible database does not stop collection.
The older `state.sqlite` schema has no parent lineage and is unsupported for this lookup.

Session details show the T3 relationship and parent, including unresolved parents.
**Hide child sessions** in the Sessions filters hides these sessions and provider-native
forks and subagents. The option is saved, composes with the other filters, and applies
to visible-list Markdown and CSV exports.

## Build

Use the repository scripts for normal release validation:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build_windows.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package_release.ps1
```

`build_windows.ps1` checks Flutter and Rust, runs formatting, analysis, unit and integration tests, and the
Windows release build. It prepares `release\windows` with
`codex_session_viewer.exe`, `codex-sessions-collector.exe`, `codex-sessions-hub.exe`, `codex-sessions-scan-launcher.exe`, Flutter runtime files, `README.md`, `settings.sample.toml`,
`sql`, and `assets`.

Independent harness collectors can emit the [version 1 ingestion contract](docs/collectors/contract-v1.md).
The runnable [Python example](samples/collector-contract/example_collector.py)
and `python scripts/verify_collector_examples.py` show local integration.
An explicitly configured [personal hub](docs/hub-setup.md) can receive
normalized records while local collection and browsing remain available.

`package_release.ps1` rebuilds through the build script, creates
`release\package`, and writes `release\codex_session_viewer_windows.zip`.
The local `release\windows\settings.toml` is preserved across builds. The
package and ZIP contain `settings.sample.toml` and omit the local runtime
`settings.toml`, so local paths and credentials are not distributed.

The Rust collector parses every session file; the viewer reads only what it
stored. To time a refresh through the collector on a local corpus, run the
scan memory benchmark (`--benchmark-scan-memory` on the built viewer, see
`app/lib/src/benchmark/scan_memory_benchmark.dart`). Keep private corpora and
their reports in ignored storage such as `.agents/private-session-corpus/` and
`.agents/benchmark-results/`; reports contain aggregate timings and counts
only.

## Background collection

The viewer connects to one resident collector per database. Refresh, startup
refresh and detail reload use that connection; the viewer reads committed changes
without restarting a collector for each scan. The resident schedules periodic scans
from `scanner.background_rescan_enabled` and
`scanner.background_rescan_interval_seconds`; the viewer has no periodic scan timer.
Pending migrations, VACUUM and exclusive viewer maintenance request a collection pause for at most four seconds. Current-schema startup does not pause collection. Startup migrations proceed under SQLite transaction locking if collection is unavailable; other exclusive work asks you to retry. Pauses are released on completion, failure or cancellation, and re-acquired when the connection recovers. Saved sessions remain available if collection cannot start.

A collector started by the viewer exits 30 seconds after the last viewer disconnects
when its pending work is complete. A hook or login launcher keeps the resident alive
for collection while the viewer is closed. Hook installation and Windows task
registration remain managed by the Background collection panel; the login-task
upgrade is a separate step.

## Configuration

Configuration lives in a writable per-user `settings.toml`. On first launch the
viewer creates it from the packaged `settings.sample.toml` and fills blank session
roots from the current user. An existing Windows
`settings.toml` beside the executable remains supported. Configure paths for
each machine after installation; keep the local runtime file out of packages.

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

Database backups:

```toml
[database]
backup_retention_days = 7
```

Before a schema migration or the legacy session cache repair, the viewer and
the collector copy the database to `backups\` beside it
(`%APPDATA%\CodexSessionViewer\backups`). These copies are deleted once they
are older than `backup_retention_days` (1 to 3650, default 7), together with
their `-wal`, `-shm` and `-journal` files. A backup that an unfinished
migration or repair still needs is kept whatever its age, and files that do
not match a backup name are never touched. The viewer checks once a day after
startup finishes and deletes its own `usage-pre16-*` and legacy v1/v2 repair
copies; the collector deletes its v3 repair copies after a scan and its old
setup `*.collector-backup` files after `setup --apply`. Each deletion is
logged with its path and size; a copy that is still open is retried later.
There is no "keep forever" value; use 3650, or copy a backup elsewhere.

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
