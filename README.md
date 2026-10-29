# Codex Session Viewer

A desktop app for finding your way back through Codex and Claude Code session
history. It indexes the session files the two tools leave on disk into a local
SQLite database with full-text search, so you can find a conversation by what
was said in it, see what it cost, export it, or resume it in a terminal.

The original session files stay the source of truth. The viewer never edits
them, and nothing leaves your computer unless you configure a personal hub.

Release builds are available for Windows and Linux. The macOS build is
scripted but has not been released.

## What it does

- **Sessions** lists every Codex and Claude Code session from the folders you
  configure, including WSL. Filter by project, model, tag or text, sort by any
  column, and read a conversation with find-in-conversation and collapsed tool
  output. The Stats tab splits a session's time between model work, tools and
  subagents and shows tokens and cost per agent, tool and model.
- **Resume and fork.** Copy the command that resumes a session, or on Windows
  open it directly in Windows Terminal or Alacritty.
- **Context Search** searches message text and returns snippets with author,
  session and timestamp. Copy what you need or jump to that message.
- **Projects** groups sessions by folder. Folder rules and manual moves fix the
  cases where detection guesses wrong, such as worktrees, and every change can
  be undone.
- **Usage** totals tokens and cost by model and by origin, separating main
  sessions from subagents, with a table beside each chart. Costs come from the public OpenRouter price catalog.
- **Evals** turns chosen sessions into datasets for DeepEval, OpenAI evals,
  Promptfoo, Markdown or plain text. Paths are anonymized by default.
- **Hub** browses sessions from your other machines when you run a
  [personal hub](docs/hub-setup.md).

## Install

Download the archive for your platform from the
[latest release](https://github.com/MaxLogic/codex-sessions-viewer/releases/latest).

**Windows:** extract `codex_session_viewer_windows.zip` to a permanent folder,
for example `C:\Tools\CodexSessionViewer`, and run `codex_session_viewer.exe`.
Keep the folder in place: collection hooks and the sign-in task point to the
collector at that path. The executables are not code-signed, so SmartScreen may
ask for confirmation on first start.

**Linux (x64):** extract `codex_sessions_viewer_linux.tar.gz` to a permanent
folder and run `./codex_sessions_viewer` from it. The app needs GTK 3, which
desktop distributions normally include. The release is built and tested on
Ubuntu 24.04. To add it to your application menu, see
[native releases](docs/release-validation.md#native-macos-and-linux-releases).

Each archive contains the viewer, the `codex-sessions-collector` that parses
session files, the `codex-sessions-hub` server, and on Windows the windowless
`codex-sessions-scan-launcher` for scheduled scans.

## First start

On first start the viewer creates its settings file from the packaged
`settings.sample.toml` and fills in the default session folders for the current
user: `~/.codex` (or `CODEX_HOME`) and `~/.claude/projects`. Change them under
Settings. The settings file and the database live in a per-user folder:

| Platform | Settings | Database and logs |
| --- | --- | --- |
| Windows | `%APPDATA%\CodexSessionViewer\settings.toml` | `%APPDATA%\CodexSessionViewer` |
| Linux | `~/.config/CodexSessionViewer/settings.toml` | `~/.local/share/CodexSessionViewer` and `~/.local/state/CodexSessionViewer` |

On Linux the XDG variables override these locations. An existing
`settings.toml` beside the Windows executable is still read.

To include sessions from WSL on Windows, set the WSL paths:

```toml
[paths]
wsl_codex_unc_path = '\\wsl.localhost\Ubuntu\home\<user>\.codex'

[wsl]
distro = 'Ubuntu'
linux_home = '/home/<user>'
linux_root_unc = '\\wsl.localhost\Ubuntu\'
```

Press F1 for the keyboard shortcuts. F5 refreshes, Ctrl+F searches sessions or
the open conversation, and Ctrl+L moves to the filters.

## How collection works

The viewer does not parse session files itself. A resident
`codex-sessions-collector` process owns the database: it scans the session
folders, writes what it parsed, and the viewer reads the result. Writes are
split into short transactions with pauses between them, so the viewer stays
responsive during a full rescan.

When the viewer starts, it connects to the collector for its database or starts
one. That collector rescans on the interval set under Settings and exits 30
seconds after the last viewer closes.

To keep collecting while the viewer is closed, use the Background collection
panel in Settings. On Windows it can:

- install Codex and Claude Code hooks, so a finished turn is collected right
  away. Codex runs a new hook only after you review it with `/hooks` and
  restart the session.
- register a per-user scheduled task that starts the collector at sign-in and
  restarts it within five minutes if it stops.

Setup previews every change, backs up the files it edits and leaves your other
hooks in place. The command-line equivalent is in
[collector setup](docs/collector-setup.md). Autostart on Linux and macOS is not
implemented yet; there, collection runs while the viewer is open.

Other tools can feed sessions into the same database through the
[ingestion contract](docs/collectors/contract-v1.md); a
[Python example](samples/collector-contract/example_collector.py) shows a
complete collector.

## Network use and privacy

Session content stays on your computer unless you configure a hub. The viewer
makes these network requests:

- It downloads the public OpenRouter model catalog at 00:00, 06:00, 12:00 and
  18:00 UTC to price token usage. This needs no API key and sends no session
  data. Set `use_external_pricing = false` under `[pricing]` to turn it off.
- With `[hub] url` set, the collector uploads normalized session records to
  that hub, and the viewer shares price history with it. The machine token is
  read only from the `CODEX_SESSIONS_HUB_MACHINE_TOKEN` environment variable,
  never from `settings.toml`. See [hub setup](docs/hub-setup.md).

Evals export and Context Search run locally. There are no external embeddings
and no cloud sync.

## Accessibility

The viewer is built for keyboard and screen-reader use and is tested with NVDA
on Windows. A conversation is exposed message by message rather than as one
large block, and long tool output starts collapsed. The Focus reader tab moves
through a conversation with single keys: N and P for the next and previous
message, U, A and T for user, assistant and tool messages, E for tool calls
and errors. Every usage chart has an equivalent table. Optional
voice-over sounds mark events such as a finished scan, a copy or a parse
error, with a spoken announcement when a sound cannot play.

## Database backups

Before a schema migration or repair, the viewer and the collector copy the
database to a `backups` folder beside it. Copies older than
`backup_retention_days` (1 to 3650, default 7) are deleted, except a backup
that an unfinished migration still needs. Only files with a backup name are
ever deleted.

```toml
[database]
backup_retention_days = 7
```

## Build from source

The release scripts run every check before they build: Rust formatting,
Clippy and tests, Dart formatting and analysis, and the Flutter unit, widget
and integration tests. Any failure stops the build.

Windows needs Flutter 3.44.1 with Windows desktop support and Rust 1.98:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/package_release.ps1
```

This writes the app to `release\windows` and the archive to
`release\codex_session_viewer_windows.zip`. A local `settings.toml` in the
output folder is kept and never packaged.

Linux additionally needs Python 3.11, clang, CMake, Ninja, pkg-config and the
GTK 3 development files. If the checkout is inside your home folder, point the
test sandboxes elsewhere:

```bash
CXV_TEST_SANDBOX_PARENT=/tmp/cxv-test-sandboxes bash scripts/build_linux.sh
```

The output is `release/linux` and `release/codex_sessions_viewer_linux.tar.gz`.
[Release validation](docs/release-validation.md) describes both pipelines, the
macOS build and the checks to run before publishing.

For development, run the app from `app/`:

```powershell
cd app
flutter pub get
flutter run -d windows
```

## Troubleshooting

**WSL sessions are missing.** Check the distribution name with `wsl.exe -l -v`
and open the configured UNC path in File Explorer.

**The database fails to open or migrate.** The Logs screen and the log file
show the error. Keep the database file for inspection before deleting it; a
backup made before the migration is in the `backups` folder.

**Resume does not start a terminal.** Settings has diagnostics for Alacritty,
Windows Terminal, the WSL command and the Codex command. Check that the
configured executables exist and that `codex` or `claude` is on PATH for the
platform the session came from.

**Hook collection stopped.** The Codex Windows app can reinstall its own
notify wrapper when computer use starts. Check the Background collection panel
after that happens.

## License

[MIT](LICENSE)
