# Codex sessions collector

`codex-sessions-collector.exe` collects Codex session history into the Codex
Sessions Viewer database without the viewer running. It ships next to
`codex_session_viewer.exe` and reads the same `settings.toml`.

## Commands

```text
codex-sessions-collector codex scan   [--db FILE | --standalone FILE] [--settings FILE] [--json]
codex-sessions-collector codex ingest [--db FILE | --standalone FILE] <SESSION.jsonl>
codex-sessions-collector codex parse  <SESSION.jsonl>            # print contract records, no database
codex-sessions-collector apply  [--db FILE | --standalone FILE] [--input FILE]   # stdin by default
codex-sessions-collector version
```

`codex scan` reads the Windows and WSL Codex homes from `settings.toml`
(`[paths]`), skips files whose size and modification time are unchanged,
parses changed files in parallel, and records missing, unreadable, and
unsupported files the way the viewer's own scan does. `--windows-root` and
`--wsl-root` override the configured homes; `--no-wsl-projects` skips asking
`wsl.exe` for git project names; `--force` reparses everything.

Without `--db`, the collector writes the viewer's database at
`%APPDATA%\CodexSessionViewer\codex_sessions_viewer.sqlite`.

Exit codes: `0` success, `1` failure, `2` usage error, `3` database refused.

## Who owns the database

- **Viewer database (`--db`)**: the viewer creates and migrates it. The
  collector writes only when the schema is exactly the version it was built
  for and no viewer migration is pending. Otherwise it refuses with exit code
  3 and says what to do, usually "open the viewer once". It never creates or
  migrates a viewer database.
- **Standalone database (`--standalone`)**: for a machine without the viewer.
  The collector creates the database from the same schema files, records
  itself as the owner (`app_metadata.database_owner = 'collector'`), and
  migrates only databases it created.

Writers coordinate through SQLite: WAL journaling, short `BEGIN IMMEDIATE`
transactions, and a 30 second busy timeout. The viewer, several collectors,
and viewer edits can run at the same time; a writer waits for the other
instead of failing.

The collector never calculates cost. It stores token usage and marks the
affected days dirty; the viewer's pricing maintenance prices them.

## Records

Collectors exchange JSON Lines records of the versioned contract
`codex-sessions-viewer.ingest` version 1 (see `src/contract.rs`):

```json
{"contract":"codex-sessions-viewer.ingest","version":1,"kind":"session_snapshot","record":{...}}
```

Kinds: `session_snapshot`, `source_status`, `thread_name`, `project_hints`.
Unknown fields are ignored; an unknown contract, version, or kind is rejected
before anything is written. Token buckets that a source did not report are
`null`, never `0`.

## Querying history

`codex-sessions-collector query <command>` reads collected history without
the viewer: `status`, `projects`, `sessions`, `search`, `session`,
`messages`, `message`, and `export`. It opens the database read-only with
`query_only`, bounds every limit, pages with opaque `next_cursor` values that
never repeat or skip results, and returns the JSON contract
`codex-sessions-viewer.query` version 1 (`--format text` for people).

Results carry stable references such as
`history://<machine>/<harness>/<session>#<message_index>`; pass one back with
`--ref` or `--session`. Filters (`--project`, `--path`, `--since`, `--until`,
`--harness`, `--machine`) keep their meaning across pages. For direct SQL,
schema 19 publishes the read-only views `history_sessions`,
`history_messages`, and `history_tool_calls`
(`docs/skills/session-history/references/database.md`). The session-history
agent skill uses these commands through `scripts/session_history.py`.

## Parity with the viewer

The Codex parser and the database writer are ports of the viewer's Dart code
and must produce identical rows:

- `cargo test --test local_ingestion` compares the Rust parser with the Dart
  parser's retained output in `samples/collector-parity/expected`.
- `app/test/app/collector_ingestion_compat_test.dart` scans one fixture tree
  with the Dart writer and with this executable and compares every table.

After an intended parser change, update both parsers and regenerate the
goldens with `CODEX_PARITY_UPDATE=1 flutter test test/parser/collector_parity_golden_test.dart`.
