# Collector ingestion contract, version 1

An independent collector writes UTF-8 JSON Lines to standard output. The
viewer does not need to be running. Pipe or save those lines and pass them to
`codex-sessions-collector apply`; the shared collector validates the records
and owns all SQLite writes, search indexes, project assignment, and usage
projection. An adapter may be written in any language. It must not write the
viewer database directly.

```powershell
python samples/collector-contract/example_collector.py samples/collector-contract/session.json > example.jsonl
collector/target/debug/codex-sessions-collector.exe apply --standalone example.sqlite --input example.jsonl
collector/target/debug/codex-sessions-collector.exe query search --standalone example.sqlite --query searchable
```

The example reads a small fictional transcript. Its `--harness` option shows
how another harness can keep the same native session ID without colliding.
Use `--db PATH` for a viewer-owned database that the viewer has already
migrated. `--standalone PATH` creates a collector-owned local database. Neither
mode requires a hub or network access.

## Envelope and compatibility

Each nonempty line has this form:

```json
{"contract":"codex-sessions-viewer.ingest","version":1,"kind":"session_snapshot","record":{}}
```

The concrete shape is defined in `collector/src/contract.rs`. The four kinds
are `session_snapshot`, `source_status`, `thread_name`, and `project_hints`.
The empty snapshot above illustrates the envelope only; it is not a valid
record. Version 1 accepts unknown object fields so an adapter can retain new
source evidence. It rejects another contract name, version, kind, malformed
JSON, invalid harness names, invalid states and status values, and invalid
usage-event derivations. A new required field or changed meaning requires a
new contract version. `apply` validates the whole input stream before writing;
individual batches are committed by kind. Do not rely on an entire mixed-kind
stream being one transaction if an I/O or database error occurs after
validation.

Run `python scripts/verify_collector_examples.py` from the repository root.
It builds the Rust executable if needed and uses an isolated temporary
database. `cargo test --manifest-path collector/Cargo.toml --test
collector_contract` additionally checks the separately run Python process,
duplicate delivery, changed revisions, search, rejected records, and identity
isolation.

## Session snapshots

`session_snapshot` describes the complete current parse of one source. Supply:

- `harness`: a stable lowercase ASCII name containing letters, digits, or
  hyphens. It namespaces the harness's own `session.session_id`.
- `machine_id`: omit or use `null` for the local database's machine. A foreign
  machine ID is refused by the local store; records cannot silently relabel
  another computer's session. A future hub uses a separate storage boundary.
- `source`: original `path`, `environment` (`windows` or `wsl`), lifecycle
  `state`, parse `status`, byte `size`, UTC `modified_utc`, `display_path`,
  `mapped_source_file_path`, and `platform_path`. Optional `unc_path` and
  `normalized_path_keys` preserve alternate address forms. `path` is the
  source identity for rescans; keep it stable and distinguish files whose
  harness session IDs are absent.
- `session`: native `session_id` if known, thread and parent IDs, optional
  working-directory forms, title, summary, times, models, `usage`,
  `usage_projection_status`, and `parser_version`. Do not invent a native ID
  when the source provides none. The store uses the source path for that case.
- Complete `messages`, `tool_calls`, and `usage_events` arrays for this
  revision. Reapplying a snapshot replaces the stored children. Indices and
  source-record ordinals must be stable and unique within the session. Message
  `author_type` distinguishes user, assistant, tool, reasoning, system, and
  unknown material; `raw_type` can retain a source-specific type.
- Optional `project_hints` and `extra`. Put unmodelled source fields in
  `extra` as JSON evidence rather than converting them to guessed known
  values.

The writer keys a Codex row as `session:<native-id>` and another harness as
`<harness>:session:<native-id>`; sessions without an ID use a source-path
key. It chooses a canonical source when multiple files claim one session ID,
using valid parse, activity time, file revision, lifecycle state, and path as
tie breakers. Repeated delivery converges on one row; a changed revision
replaces its messages and tools. A `changed_pending_parse` source was modified
while read and needs another pass. Source size and modification time are
revision evidence, not proof that arbitrary equal-size edits were detected.

## Usage and unknown values

Token fields are nullable: `null` or omission means the harness did not
report a number; `0` means it explicitly reported zero. Never turn missing
usage into a zero estimate. `session.usage`, each message's `usage`, and each
usage event can carry `input_tokens`, `cached_input_tokens`,
`cache_write_input_tokens`, `output_tokens`, `reasoning_output_tokens`, and
`total_tokens`. `total_tokens` is the source's reported total, if present.

Use `usage_events` for the source records that actually reported counters.
Each event has a nonnegative `source_record_ordinal`, an `event_fingerprint`,
`derivation` (`last_token_usage`, `cumulative_delta`, or `counter_reset`), and
`branch_scope` (`local`, `inherited`, or `ambiguous`). Keep parent/fork lineage
fields when a harness exposes them; inherited usage must not be counted again
as local. Optional `request_input_tokens`, `model_context_window`, provider,
and `billable_units` such as `web_search_calls` preserve inputs needed for
conditional pricing. The collector does not calculate authoritative cost.
The viewer's pricing maintenance applies the active catalog later.

## Hook and reconciliation duties

Hooks enqueue a small durable work item promptly. They should not parse a
large transcript or wait for a hub. The separate drain applies the latest
complete source revision, and a periodic full scan repairs missed hooks,
append races, moved or deleted sources, and restarts. A partial last JSONL
line is not a complete revision. Report a `source_status` for missing,
unreachable, permission-denied, malformed, or unsupported files so the viewer
can distinguish those states. Preserve other configured harness hooks or
notify commands when installing yours. See `collector/README.md` for the
current Codex and Claude entry points and exit codes.

Adapters should be packaged with their own parser and fixtures, plus this
compatibility runner. The shared `apply` executable and its schema-version
check remain the only database writer. A native harness plugin may emit the
same JSON Lines; no Rust FFI or plugin ABI is required.

For a local package, ship the adapter, its required language runtime or
compiled executable, and the shared `codex-sessions-collector.exe` from the
same viewer release. Have the adapter write a temporary JSONL file, then run
`apply --db <viewer-database> --input <file>` only after the adapter exits
successfully. Keep the JSONL until `apply` succeeds so a failed delivery can
be retried. Test the package with the verifier above on a clean temporary
database before installing hooks. The example's `parser_version` is pinned to
the current viewer projection version 4; update and retest an adapter when
that version changes.
