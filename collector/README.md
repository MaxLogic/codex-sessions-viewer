# Codex sessions collector

`codex-sessions-collector.exe` collects Codex and Claude Code session history
into the Codex Sessions Viewer database without the viewer running. It ships next to
`codex_session_viewer.exe` and reads the same `settings.toml`.

## Commands

```text
codex-sessions-collector codex scan   [--db FILE | --standalone FILE] [--settings FILE] [--json]
codex-sessions-collector codex ingest [--db FILE | --standalone FILE] <SESSION.jsonl>
codex-sessions-collector codex parse  <SESSION.jsonl>            # print contract records, no database
codex-sessions-collector codex notify [--previous-notify JSON] <PAYLOAD>
codex-sessions-collector claude scan   [--claude-root DIR] [--db FILE | --standalone FILE] [--json]
codex-sessions-collector claude ingest [--db FILE | --standalone FILE] <TRANSCRIPT.jsonl>
codex-sessions-collector claude parse  <TRANSCRIPT.jsonl>
codex-sessions-collector claude hook                              # hook input as JSON on stdin
codex-sessions-collector drain  [--db FILE | --standalone FILE]
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

## GUI scan transport

Refresh launches the bundled executable with `codex scan --coordinate-writes`
and then, unless the refresh was cancelled, `claude scan --coordinate-writes`
with the Claude Code projects folder (`%USERPROFILE%\.claude\projects` when it
exists). Both use the same protocol. The collector emits JSON lines on stdout.
`write_requested` waits for `grant` on stdin; `write_released` returns that
lease to the viewer's maintenance scheduler. This lets pricing and other queued
writes run between scan batches. `progress` carries `counts` and
`sessions_written`, at most once per 100 ms plus once per committed batch; the
final `finished` record contains the scan summary, `cancelled`,
`persistence_flushes`, and for `codex scan` the `cache_repair` report.

The viewer sends `cancel` on stdin to stop discovery and new parser work.
Closing stdin also requests cancellation. A cancel that arrives while the
collector waits for a `grant` withdraws the request with `write_released`; after
a cancel the collector asks for no further lease, so parsed sessions that were
not yet committed, source statuses, and project refinements wait for the next
scan. Cancelled scans never mark unseen files missing. `--progress-json`
streams progress without writer leases; ordinary `--json` still emits only the
final summary.

The viewer writes every stdin line through one serialized writer, treats a
closed pipe after the collector exits as the end of the conversation, and stops
a collector that holds a lease for more than five minutes, returning the lease
to its writer queue. A missing executable is reported with the path the viewer
expected and how to fix it.

Tests can set `CODEX_SESSIONS_COLLECTOR_EXE` to an explicitly built executable.
Installed applications use the collector next to the viewer executable.

## Who owns the database

- **Viewer database (`--db`)**: the viewer creates and migrates it. The
  collector writes only when the schema is exactly the version it was built
  for, its versions agree with the viewer's recorded versions (below), and no
  viewer migration is pending. Otherwise it refuses with exit code
  3 and says what to do, usually "open the viewer once". It never creates or
  migrates a viewer database.
- **Standalone database (`--standalone`)**: for a machine without the viewer.
  The collector creates the database from the same schema files, records
  itself as the owner (`app_metadata.database_owner = 'collector'`), and
  migrates only databases it created.

The viewer records `writer_codex_parser_version`,
`writer_claude_parser_version`, and `writer_usage_cost_projection_version` in
`app_metadata` during successful startup. Every write needs the cost projection
version to agree, because every harness's usage becomes daily cost rows. A
session write also needs the parser version of that session's harness: Codex
rows are gated only by the Codex parser version and Claude rows only by the
Claude parser version. Third-party harnesses carry their own parser versions,
which the viewer does not filter on. The collector checks under each batch's
write lock. Missing metadata also refuses writes: install matching
viewer/collector binaries and open the viewer once. The viewer mirrors the
constants in `app/lib/src/database/collector_versions.dart`, and
`app/test/database/writer_version_agreement_test.dart` fails when they differ
from the Rust sources; SQL migration checksums alone do not detect an
algorithm-only version change.

Only the collector writes parsed session state. Besides snapshots it cleans
legacy `# AGENTS.md`/`auto` title placeholders, assigns automatic projects to
stored sessions that have none, and, after a scan that reached every configured
Codex home without errors, runs the one-time legacy cache repair
(`session_cache_repair.v3`): a content-free audit in
`session_cache_repair_manifest`, a verified backup in `backups\` next to the
database, then deletion of allowlisted legacy placeholder rows only. Once the
repair is completed, each scan deletes its backups older than
`[database] backup_retention_days` (7 days by default) and reports them in
`cache_repair.pruned_backups`. The viewer only reads sessions and logs the
repair report.

Writers coordinate through SQLite: WAL journaling, short `BEGIN IMMEDIATE`
transactions, and a 30 second busy timeout. The viewer, several collectors,
and viewer edits can run at the same time; a writer waits for the other
instead of failing.

The collector never calculates cost. It stores token usage and marks the
affected days dirty; the viewer's pricing maintenance prices them.

## What a Codex session stores

The database is an index of the session files, which stay on disk. Messages
hold what people read and search: prompts, answers, reasoning summaries, and
system content (Codex's injected developer context, messages between agents,
and a turn that ended with an error such as a usage limit). Tool calls keep
their input and output previews.

Protocol events that repeat those rows or only mark progress are not stored:
the app-server `item_completed`/`item_started` agent and user messages,
reasoning, command executions, file changes, and compactions; the legacy
`exec_command_end`, `patch_apply_end`, `agent_reasoning`, `task_started`,
`task_complete`, `context_compacted`, and `turn_aborted` events. Two of them
become source extras instead (`session_source_extras.extra_json`):
`files_changed`, the sorted paths of applied patches and file changes
(rename targets included, failed changes excluded, at most 500 with
`files_changed_total` when there are more), and `goal`, the latest
`{objective, status}`. `thread_name_updated` names the session when the
session index does not. Other small events (collaboration, web search, MCP,
image, review mode, errors) are still stored as raw evidence.

Parser version 5 introduced this. Every Codex session is parsed again on the
next scan, which replaces its rows; the full-text index follows through its
triggers. SQLite keeps the freed pages in the file, and FTS5 keeps deleted
entries in its index segments, so once no available local Codex session
awaits the new parser the viewer runs one database maintenance job (skipped
while database maintenance is disabled): it merges the three search indexes
(`'optimize'`) and then runs `VACUUM`. VACUUM needs about the database's used
size free in the temporary folder and the same again next to the database
for the WAL; without it the viewer skips the job and retries on the next
start. Measured on a copy of an 18.6 GB database with the removed rows
deleted: the index merge took 2 minutes and freed 7.3 GB, and the VACUUM took
1.5 minutes and left a 5.7 GB file (VACUUM alone, without the merge, took 6
minutes and left 13 GB).

## Claude Code

`claude scan` reads every transcript under `%USERPROFILE%\.claude\projects`
(or each `--claude-root` / `--claude-wsl-root`). A transcript's subagents
(`<session>/subagents/agent-<id>.jsonl`) become their own sessions,
`<session>:agent-<id>`, linked to the parent. Records that share one
`message.id` are one response and count its usage once. Input tokens include
cache reads and cache writes, as the viewer expects; the cache-write split and
server tool requests are kept as billable units. Record types and usage fields
the parser does not model are listed in the session's source extras rather
than dropped. A response without usage stays unknown.

Session IDs are unique per harness: a Claude session and a Codex session may
share an ID and remain separate sessions (row IDs `claude:session:<id>` and
`session:<id>`).

## Hooks

Hooks keep the database current between scans without slowing the agent. A
hook only writes a small work item to the queue folder and starts a detached
`drain`; it never opens the database and always exits 0. `drain` claims queue
items by renaming them, ingests the named session, and deletes each item
after its commit. Failed items return with a growing delay; the drain waits
for them (at most 5 minutes; `drain --no-wait` handles only what is due) and
drops an item after 6 attempts. A claim left by a crashed drain is reclaimed
10 minutes after it was claimed. Problems go to `errors.log` in the queue folder
(`CODEX_SESSIONS_COLLECTOR_QUEUE`, default
`%LOCALAPPDATA%\CodexSessionViewer\collector\queue`). A transcript caught
mid-write is stored up to its last complete line and retried.

- **Codex**: set `notify` in `~/.codex/config.toml` to
  `['<path>\codex-sessions-collector.exe', 'codex', 'notify']` (single quotes
  keep the backslashes literal). To keep an
  existing notify program, pass it as JSON with `--previous-notify`; it runs
  with the same payload.
- **Claude Code**: add a `Stop` and a `SessionEnd` command hook running
  `"<path>\codex-sessions-collector.exe" claude hook`.
  Claude Code running in WSL reports Linux transcript paths; the drain opens
  them through the configured WSL root (`--wsl-unc-root` or settings).

Hooks are an accelerator: run `codex scan` and `claude scan` periodically to
repair anything a hook missed.

## Records

Collectors exchange JSON Lines records of the versioned contract
`codex-sessions-viewer.ingest` version 1 (field reference in
[`docs/collectors/contract-v1.md`](../docs/collectors/contract-v1.md)):

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

## Parser goldens and the viewer

The collector is the only session parser; the viewer has none and reads what
the collector stored. Two suites hold that contract:

- `cargo test --test local_ingestion` compares the Codex parser's normalized
  output for every fixture in `samples/collector-parity/sessions` with the
  goldens in `samples/collector-parity/expected`. The goldens began as the
  retired Dart parser's output and are now owned here. After an intended
  parser change, regenerate them with
  `CODEX_PARITY_UPDATE=1 cargo test --test local_ingestion parser_output`,
  review the diff, and bump `PARSER_VERSION` (and the viewer's mirror in
  `app/lib/src/database/collector_versions.dart`) when stored rows change.
- `app/test/app/collector_ingestion_compat_test.dart` collects one fixture
  tree through GUI Refresh and through this executable, compares every
  table, and checks that the viewer's production reads (session rows,
  conversations, usage, and costs) return the same results from both.
  `app/test/app/multi_harness_ingestion_test.dart` does the same for Claude
  Code sessions, including the Stats tab and eval exports.
