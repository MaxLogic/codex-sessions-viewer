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
collector/target/debug/codex-sessions-collector.exe query search --db example.sqlite --query searchable
```

The example reads a small fictional transcript. Its `--harness` option shows
how another harness can keep the same native session ID without colliding.
Use `apply --db PATH` for a viewer-owned database that the viewer has already
migrated. `apply --standalone PATH` creates a collector-owned local database.
`query` reads either kind through `--db PATH`. Neither mode requires a hub or
network access.

## Envelope and compatibility

Each nonempty line has this form:

```json
{"contract":"codex-sessions-viewer.ingest","version":1,"kind":"session_snapshot","record":{}}
```

`contract`, `version` and `kind` are required. The four kinds are
`session_snapshot`, `source_status`, `thread_name`, and `project_hints`; the
[record reference](#record-reference) lists the fields of each. The empty
snapshot above illustrates the envelope only; it is not a valid record.
Version 1 accepts unknown object fields so an adapter can retain new
source evidence. It rejects another contract name, version, kind, malformed
JSON, invalid harness names, invalid states and status values, and invalid
usage-event derivations. A new required field or changed meaning requires a
new contract version. `apply` validates the whole input stream before writing;
individual batches are committed by kind. Do not rely on an entire mixed-kind
stream being one transaction if an I/O or database error occurs after
validation.

Run `python scripts/verify_collector_examples.py` from the repository root.
It always rebuilds the Rust executable, runs the commands above against an
isolated temporary database, and checks duplicate delivery, search, a changed
revision, unknown optional fields, malformed and unsupported envelopes, a
native session ID shared by two harnesses, a refused foreign machine ID, and an
empty message. It exits non-zero on the first failed check. `cargo test
--manifest-path collector/Cargo.toml --test collector_contract` runs the same
example from the Rust test suite.

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
database before installing hooks.

## Versions

Three version numbers are independent:

- The envelope `version` is the contract version, `1` for this document.
- `session.parser_version` is the adapter's own parser version. The example
  uses `1`. Increase it when the adapter would emit different records for an
  unchanged source file, so stored sessions are parsed again. Do not copy
  another harness's value: `4` is the built-in Codex parser version and `1` is
  the built-in Claude Code parser version, each meaningful only for its own
  harness.
- The viewer's cost projection version (currently `1`) belongs to the
  viewer's pricing maintenance. Adapters never write or depend on it.

## Record reference

Types are JSON types. *Required* fields must be present. Optional fields may
be omitted or `null`, unless a default is given; arrays default to empty and
booleans to `false`. Timestamps are UTC ISO-8601 strings such as
`2026-01-01T00:00:00Z`. Integers are signed 64-bit unless noted. Unknown fields
are accepted and ignored at every level.

### `session_snapshot`

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `harness` | string | yes | Lowercase ASCII letters, digits or `-`. Namespaces `session.session_id`. |
| `machine_id` | string | no | Omit or `null` for the local machine; any other value is refused locally. |
| `source` | object | yes | See `source` below. |
| `session` | object | yes | See `session` below. |
| `messages` | array of message | no | The complete message list of this revision. |
| `tool_calls` | array of tool call | no | The complete tool-call list of this revision. |
| `usage_events` | array of usage event | no | Source records that reported token counters. |
| `project_hints` | array of project hint | no | Project names resolved on the source machine. |
| `extra` | any JSON | no | Unmodelled source evidence, stored as-is. |

`source`:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `path` | string | yes | Source identity for rescans; keep it stable. |
| `environment` | string | yes | `windows` or `wsl`. |
| `state` | string | yes | `active`, `codex_archived` or `missing`. |
| `status` | string | yes | `available`, or `changed_pending_parse` if the file changed while read. |
| `size` | unsigned integer | yes | Byte size of the parsed revision. |
| `modified_utc` | timestamp | yes | Modification time of the parsed revision. |
| `display_path` | string | yes | Path shown to the user. |
| `mapped_source_file_path` | string | yes | Path in the viewer's address form. |
| `platform_path` | string | yes | Path in the harness's own address form. |
| `unc_path` | string | no | UNC form of a WSL path. |
| `normalized_path_keys` | array of string | no | Alternate keys that identify the same file. |

`session`:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `usage_projection_status` | string | yes | `complete` or `ambiguous`; see below. |
| `parser_version` | integer | yes | The adapter's own parser version. |
| `session_id` | string | no | The harness's native ID, unchanged. Omit when the source has none. |
| `thread_name`, `thread_source` | string | no | Display name and its origin. |
| `parent_thread_id`, `forked_from_id`, `history_base_thread_id` | string | no | Lineage of subagents and forks. |
| `history_base_end_ordinal_exclusive`, `history_base_end_byte_offset`, `subagent_history_start_ordinal` | integer | no | Where inherited history ends. |
| `agent_nickname`, `agent_role` | string | no | Subagent labels. |
| `subagent_depth` | integer | no | Nesting depth of a subagent. |
| `working_directory_display`, `working_directory_platform`, `working_directory_unc` | string | no | Working-directory address forms. |
| `title`, `summary` | string | no | Short descriptions. |
| `started_at_utc`, `last_message_at_utc` | timestamp | no | Activity range. |
| `models` | array of string | no | Models in first-use order. |
| `usage` | usage | no | Session totals; omitted buckets are unknown. |

Send `usage_projection_status` `complete` when the reported usage is fully
described by `usage_events`, including a session that reports no usage at
all; its token counts stay `null`. Send `ambiguous` when the source reports
usage totals that cannot be attributed to usage events. The store may later
set `ambiguous`, `missing_parent` or `legacy_pending` itself while resolving
fork and subagent lineage; adapters do not send those two last values.

A usage object has the optional integer fields `input_tokens`,
`cached_input_tokens`, `cache_write_input_tokens`, `output_tokens`,
`reasoning_output_tokens` and `total_tokens`.

Message:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `index` | integer | yes | Stable, unique position within the session. |
| `author_type` | string | yes | `user`, `assistant`, `system`, `tool`, `reasoning` or `unknown`. |
| `first_line` | string | yes | First line of the text; `""` for an empty message. |
| `content_plain` | string | yes | Searchable plain text; may be `""`. |
| `content_preview` | string | yes | Short preview; may be `""`. |
| `raw_type` | string | no | Source-specific type. |
| `created_at_utc` | timestamp | no | Message time. |
| `content_truncated` | boolean | no | The adapter shortened `content_plain`. |
| `usage` | usage | no | Usage reported on this message. |
| `model` | string | no | Model that produced the message. |
| `has_tool_calls`, `has_error` | boolean | no | Message flags. |

Tool call:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `tool_index` | integer | yes | Stable, unique position within the session. |
| `tool_name` | string | yes | Tool name. |
| `message_index` | integer | no | `message_index` of the first message after the one that issued the call (the number of messages before the call). Links the call to its issuing message; when absent, the viewer falls back to timestamps. |
| `status` | string | yes | Source-reported outcome, such as `completed` or `failed`. |
| `started_at_utc`, `finished_at_utc` | timestamp | no | Call duration. |
| `input_preview`, `output_preview` | string | no | Default `""`. |
| `output_truncated` | boolean | no | The adapter shortened the output preview. |
| `error_message` | string | no | Error reported by the tool. |

Usage event:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `source_record_ordinal` | integer, at least 0 | yes | Position of the reporting record; unique per session. |
| `usage` | usage | yes | Counters attributed to this event. |
| `derivation` | string | yes | `last_token_usage`, `cumulative_delta` or `counter_reset`. |
| `branch_scope` | string | yes | `local`, `inherited` or `ambiguous`. |
| `event_fingerprint` | string | yes | 64 hexadecimal characters, stable for the same event. |
| `rollout_ordinal`, `turn_ordinal` | integer | no | Source ordering hints. |
| `counter_epoch` | integer | no | Default `0`; increases after a counter reset. |
| `occurred_at_utc` | timestamp | no | Event time. |
| `model`, `provider` | string | no | Pricing inputs. |
| `working_directory`, `working_directory_unc` | string | no | Where the request ran. |
| `request_input_tokens`, `model_context_window` | integer | no | Conditional-pricing inputs. |
| `billable_units` | object of integers | no | Non-token units such as `{"web_search_calls": 2}`. |

Project hint: `working_directory` and `project_name`, both required strings.

### `source_status`

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `harness` | string | yes | As for snapshots. |
| `path` | string | yes | The source path. |
| `status` | string | yes | `available`, `missing`, `path_unreachable`, `parse_error`, `permission_denied`, `unsupported_format` or `changed_pending_parse`. |
| `state` | string | yes | `active`, `codex_archived` or `missing`. |
| `message` | string | no | Short diagnostic; never include transcript content. |

### `thread_name`

`harness`, `session_id` and `thread_name`, all required strings.

### `project_hints`

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `harness` | string | yes | As for snapshots. |
| `sessions` | array | yes | Each item has `source_path` (string, required) and `session_id` (string, optional). |
| `hints` | array of project hint | yes | Resolved project names by working directory. |
