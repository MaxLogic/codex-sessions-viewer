# Collector ingestion contract, version 2

Collectors write one UTF-8 JSON object per line. The `apply` command validates
the entire input stream before opening the database for writes; the optional
hub accepts the same records. New built-in producers emit version 2:

```json
{"contract":"codex-sessions-viewer.ingest","version":2,"kind":"source_status","record":{"harness":"codex","path":"/home/ada/.codex/sessions/bad.jsonl","environment":"linux","status":"parse_error","state":"active"}}
```

The four record kinds and all fields other than environment follow the
[version 1 record reference](contract-v1.md#record-reference). Unknown optional
object fields are accepted and ignored. An unsupported contract name, version,
kind, environment, state, or status is refused before writing. No path spelling
or receiving machine determines the source environment.

`session_snapshot.source.environment` is required and is one of `windows`,
`wsl`, `macos`, or `linux`. `source_status.environment` is also required in v2
with the same values, including for errors that produced no snapshot. Native
macOS and Linux paths remain native paths; WSL denotes sessions collected
through the Windows WSL bridge. The schema stores these values as distinct
`sessions.source_type` values.

Version 1 input remains accepted for snapshots whose environment is `windows`
or `wsl`, and for source statuses without environment. A native macOS/Linux
snapshot cannot be sent as v1. A field named `environment` on a v1 status was
previously an unknown optional field: it is ignored, not promoted to trusted
provenance. Existing session rows keep their stored source type when such a
legacy status updates them. A new legacy error placeholder alone uses the
version 1 Windows/WSL path fallback. Queued and in-flight v1 upload JSON is
never rewritten during upgrade or retry; newly queued legacy statuses also
remain v1 rather than acquiring guessed provenance. Newly queued external v1
snapshots and other record kinds also retain their accepted envelope version;
typed parsing continues to ignore unknown optional fields.

The ingestion version is separate from schema version 29, read-only query
contract version 2, and hub HTTP `/v1` protocol. Collector and hub peers still
require exact schema and ingestion-version agreement at verification. A hub
upgraded to this contract can receive existing v1 outbox records.

Query responses use `codex-sessions-viewer.query` version 2, including for older
supported databases. The Rust remote reader and Dart hub reader require exactly
version 2; HTTP `/v1/query` and its request `protocol: 1` stay unchanged. There
is no legacy query-output mode. Direct SQL readers must accept the four source
values themselves.

Schema 29 rebuilds `sessions` with the expanded environment constraint. The
viewer and standalone collector disable foreign keys before beginning the
replacement transaction, retain child rows and upload state, validate foreign
keys and the restored objects before commit, then restore the original foreign
key setting. Failure or cancellation rolls back the replacement. A fresh Rust
standalone bootstrap remains one atomic transaction across all migrations.

Migration receipts use SHA256 of UTF8 SQL with CRLF normalized to LF. Both
runtimes accept existing receipts matching either the current SQL's exact LF
bytes or its uniform CRLF spelling, across all migration versions. Successful
receipt rows remain unchanged; new and retried receipts use the LF digest.
Other SQL changes and unknown hashes are refused. Mixed endings, bare CR and
BOM variants are not additional accepted historical forms. Backup and session
hashes retain their existing byte policies. Upgraded releases accept either
newline receipt; older raw-hashing binaries may reject new LF receipts.

On native hosts the existing `windows_codex_path` settings key names the local
Codex folder for compatibility; WSL folders/settings/filter choices are skipped.
Copied WSL session rows remain readable. Native paths receive no WSL aliases.
Search and session identity stay case-insensitive on every host; source-status
IDs follow the centralized host policy (Linux sensitive, Windows/macOS
insensitive). This does not make case-distinct physical WSL/Linux files aliases:
copy ranking and NULL-ID fallback association distinguish those paths. A pin
stays with its physical fallback until a stable ID is established for that source.
Windows/macOS physical path comparison retains its insensitive policy.
Native resume actions currently report unsupported; CXV-151 owns
the native launcher work.
