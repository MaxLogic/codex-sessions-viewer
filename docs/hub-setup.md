# Optional personal hub

The viewer and collector work locally without a hub. A hub is a server that you
run yourself and explicitly configure as the destination for normalized session
records from your machines. The hub keeps a separate SQLite database for each
machine. Do not place a SQLite database on a network share or let a second
process open it from another host.

## Browse from the viewer

The Sessions screen starts on **This machine**, where all local operations work
offline. Choose **Hub**, enter the HTTPS URL and an owner token, and select
**Connect to hub**. The owner token can instead come from
`CODEX_SESSIONS_HUB_OWNER_TOKEN`. Only the URL and the selected machine are
saved, in `[hub]` in `settings.toml`; a token typed into the dialog stays in
memory. `[hub] url` is the only hub setting, and price history sharing uses it
too (see [shared price history](hub-price-history.md)). No hub credential is
ever stored in `settings.toml`.

Switching back to This machine keeps the hub connection for this window and
pauses its polling. The screen runs one hub request at a time; a click that
arrives while a refresh is running is ignored.

Hub sessions, message search, conversation pages, and the last 30 days of token
usage are requested on demand. While Hub is visible, the current page refreshes
every ten seconds and catches up after a temporary outage. After a hub error,
the last successful rows stay visible with an error message; the viewer never
shows local rows in their place. **Search / refresh hub** returns to the newest
page.

**Hub title annotation** and **Hub notes** are stored on the hub, separately
from the uploaded source title and from local annotations. When you save, the
viewer checks the revision it last read; if the annotations were edited
elsewhere in the meantime, reload the session before saving.
Collector uploads do not replace these annotations. Unsaved edits pause
automatic refresh.

**Resume locally** works only for a session recorded on this machine, as
identified by its persistent machine identity, and only when the local session
file, the working folder, and the harness (Codex or Claude Code) exist in the
recorded environment. Sessions from other machines cannot be resumed locally.
To open the folder of a session from another machine, use **Map local folder**,
even if the remote path happens to exist here. A mapping applies only to the
selected session in this window and never enables resume.

## Start one hub

The release archive includes the `codex-sessions-hub` executable. To build the
Rust binaries from a source checkout instead, run `cargo build --release
--manifest-path collector/Cargo.toml --bins`. Put the hub executable on the
server and create a private JSON configuration file:

```json
{
  "owner_token": "replace-with-a-long-random-owner-secret",
  "machines": {
    "laptop-1": "replace-with-a-different-long-random-machine-secret"
  }
}
```

Each secret must contain at least 24 characters and differ from every other
secret. The machine ID may contain only letters, digits, hyphens, and
underscores. Keep the file readable only by the account that runs the hub.
Back up this file and the hub data directory together. The hub does not manage
accounts, public sharing, or TLS.

```powershell
codex-sessions-hub.exe 127.0.0.1:8765 C:\HubData C:\HubData\hub.json
```

The HTTP listener accepts only loopback connections. To reach the hub from
another machine, put an HTTPS reverse proxy in front of it and configure the
collector with the proxy's `https://` URL. The collector refuses plain HTTP
except on a literal loopback address (`http://127.0.0.1:PORT` or
`http://[::1]:PORT`). `localhost` is refused because the name can resolve
elsewhere. A URL path prefix on the proxy, such as `https://example.test/hub`,
is kept. Allow proxy request bodies of at least 64 MiB and protect the owner
token.

The collector checks HTTPS certificates against its bundled Mozilla root
certificates, not the Windows certificate store. It therefore refuses a hub
whose certificate comes from a private or corporate CA, even when Windows
trusts that CA. Use a publicly trusted certificate for the proxy.

### Upload limits and timeouts

The server accepts up to 128 records and 64 MiB of wire bytes per upload. It
refuses a larger declared body before reading it. In `/v1/verify` it
advertises zstd support and a 96 MiB decoded limit, and it enforces that limit
while decoding. Uncompressed uploads are still supported.

The hub reads, decodes and applies one upload at a time across all machines.
Other uploads wait, for a bounded time, to be admitted before their bodies are
read. If that wait runs out, the hub answers with HTTP 503, which is a
transient error. Queries and health requests do not wait for this admission.
Credentials are checked before a body is read.

The admission wait is limited to twice `request_timeout_seconds`, but never
more than 30 seconds, and it must also fit within the whole-request deadline
while leaving one socket timeout for reading the body. Health and query
requests use their own connection slots. Collectors send
`Expect: 100-continue` and wait up to 35 seconds for admission. If the hub
explicitly answers that it is busy, the collector retries up to three times,
after 100, 200 and 400 ms, within the original upload timeout. These retries
resend the same batch with the same sequence and do not increase the
transport-failure counters.

Each connection is served on its own thread, up to 32 at once; further clients
receive HTTP 503 immediately. Every socket read and write must make progress
within `request_timeout_seconds` (default 30). The request head must arrive
within that time, and the whole request within ten times that time, so a
stalled client cannot block the hub. A request that ends early or times out is
answered with HTTP 408, which the collector treats as transient. Raise the
timeout when a slow uplink sends single records of many megabytes:

```json
{
  "owner_token": "...",
  "machines": { "laptop-1": "..." },
  "request_timeout_seconds": 30
}
```

The hub stores an upload's records and its sequence number in one transaction.
If a record is refused, the hub keeps neither the data nor the sequence number.

## Pair a collector

Use a collector from the same release as the hub and viewer. Open the viewer
once to migrate its database, then look up the local machine ID:

```powershell
codex-sessions-collector.exe hub status --db C:\Path\codex_sessions_viewer.sqlite
```

Put that exact ID and its own machine secret in the hub configuration. Then
pair the local database and collect the already indexed sessions again so they
enter the outbox, the local queue of records waiting for upload. Pairing alone
does not upload existing history.

```powershell
codex-sessions-collector.exe hub enable --hub-url https://hub.example.test --db C:\Path\codex_sessions_viewer.sqlite
codex-sessions-collector.exe codex scan --force --db C:\Path\codex_sessions_viewer.sqlite
codex-sessions-collector.exe claude scan --force --db C:\Path\codex_sessions_viewer.sqlite
$env:CODEX_SESSIONS_HUB_MACHINE_TOKEN = 'the-machine-secret'
codex-sessions-collector.exe hub sync --db C:\Path\codex_sessions_viewer.sqlite
```

For a collector-owned database, use `--standalone FILE` in place of `--db
FILE`. Keep the machine secret out of command arguments, logs, and the viewer
settings file. Run `hub sync` periodically in Task Scheduler, with the secret
provided to the task process through its environment. Local scans and queries
continue while the hub is unavailable; committed records stay in
`collector_upload_outbox` and the next sync retries them.

Only changes are queued. A scan that finds a source or thread name unchanged
queues nothing, and a newer state of a source replaces its older unsent state.
Repeated scans therefore do not grow the outbox while the hub is unreachable.

The sync command sends batches of up to 128 records and 8 MiB of UTF-8 until
the outbox is empty; a single larger record is sent alone. When the
authenticated hub advertises zstd ingestion, uploads are compressed at level 3,
and the record limit is the advertised decoded limit minus 64 KiB reserved for
the envelope. Hubs without zstd receive plain JSON with the existing 48 MiB
record limit. The collector allows each upload one minute plus one second per
64 KiB.

Before sending, the collector records the batch, its sequence number, and a
batch ID that includes a random part. If an acknowledgment is lost, the batch
is retried with the same sequence and batch ID, and the hub answers with a
duplicate acknowledgment. After two consecutive network failures (for example
timeouts on a slow uplink), the collector halves the in-flight batch and keeps
the same batch ID. If the hub had in fact stored the full batch, it
acknowledges the smaller one as a duplicate, and the rest is sent again, which
the hub applies idempotently.

### Dead letters

A dead letter is a record that the collector has moved out of the outbox
because it cannot be delivered. This happens when the hub refuses an upload
with a JSON `code` of `record_rejected` (a record the hub cannot store, a batch
above its size limit, or a record for another machine) or `invalid_batch` (an
upload the hub cannot parse). The hub applies a batch atomically, so the
collector resends a refused batch of several records one record at a time to
find the refused record.

The refused record moves to the `collector_upload_dead_letters` table with the
HTTP status, the time and the hub's reason (the credential is never echoed),
and no longer blocks the records behind it. A record above the negotiated
record limit is never sent and moves there too. Hub refusals are never retried
automatically.

Records refused locally for size have a NULL HTTP status. When they fit the
negotiated limit, `hub sync` removes them and rebuilds the current session
snapshot and path status from local database rows while holding the
collector's database lease. It never resends a dead letter's stored payload or
relies on wall-clock ordering. Sessions and paths that were deleted queue
nothing, and records already in the queue take priority. Non-session metadata
without an authoritative snapshot stays in dead letters.

Discovery, reconstruction and JSON serialization of these records run outside
SQLite's write lock. Each current snapshot and its lifecycle status are
committed together. The old dead letter is then deleted in a separate chunk
that uses the existing write budget of 250 ms soft / 1,000 ms hard with a
150 ms gap. A single large SQLite write or COMMIT can exceed these targets,
because it cannot be interrupted safely halfway through.

An acknowledged delivery clears dead letters for the delivered keys. The sync
result includes `requeued_dead_letters` and `pruned_dead_letters`.
`hub disable` discards all dead letters.

Every other failure is transient and leaves the queue untouched for the next
run: network errors and timeouts, HTTP 408 and 5xx, a rejected credential, a
protocol mismatch, and any error without a hub code, such as the HTML error
page of a reverse proxy (for example nginx's 413 when its body limit is below
the hub's). A sequence conflict stops the sync with a message that names
`hub resync`. `hub status` reports the pending count, the last acknowledged
sequence, and the number of dead-lettered records with their most recent
reasons:

```powershell
codex-sessions-collector.exe hub status --db C:\Path\codex_sessions_viewer.sqlite
```

`hub disable` stops queuing and discards queued, in-flight and rejected
records. The pairing and last acknowledged sequence remain, so `hub enable`
with the same URL continues the same hub history; collect again with `--force`
to queue existing sessions.

### Sessions whose files are gone

A forced collection queues only sessions whose source files still exist. A
session that was collected before pairing and whose file has since been
deleted exists only in the local database. `hub backfill` rebuilds each such
session (source recorded as missing, parsed data available) from its stored
rows, queues it with an explicit missing status, and leaves the upload to the
next `hub sync`. A session whose file, or a `.zst` copy of it, is on disk again
is skipped (`still_present`), and the next scan sends it parsed.

```powershell
codex-sessions-collector.exe hub backfill --db C:\Path\codex_sessions_viewer.sqlite
codex-sessions-collector.exe hub sync --db C:\Path\codex_sessions_viewer.sqlite
```

The rebuilt snapshot reflects the stored state, not the source file, so
per-message reasoning and cache-write tokens are absent. A hub that already
holds a parsed copy of the session keeps it, because a missing source ranks
below an available one. Each run queues every qualifying session again, so run
it once after pairing, or after restoring an older hub backup.

### Reconcile after restoring a backup

Back up the local database together with its hub state and outbox. Replacing
it with an older copy rewinds its sequence; the next sync then fails with a
sequence conflict and names `hub resync`. The same happens after restoring an
older hub backup. `hub resync` asks the hub for the last sequence it accepted
from this machine and continues from there, keeping the queued records. It
also forgets which statuses and thread names were already queued. Collect again
with `--force` so that records the hub lost are queued again:

```powershell
$env:CODEX_SESSIONS_HUB_MACHINE_TOKEN = 'the-machine-secret'
codex-sessions-collector.exe hub resync --db C:\Path\codex_sessions_viewer.sqlite
codex-sessions-collector.exe codex scan --force --db C:\Path\codex_sessions_viewer.sqlite
codex-sessions-collector.exe hub sync --db C:\Path\codex_sessions_viewer.sqlite
```

The hub applies source revisions idempotently, so sending records it already
has does no harm.

A hub restored from an older backup has lost every record it accepted after
that backup, and the collector has already removed those records from its
outbox. `hub resync` alone cannot bring them back. After it, always collect
again with `--force` on every paired machine (`codex scan --force` and
`claude scan --force`) and then run `hub sync`, as above.

A restored local database cannot make the hub skip new records. Each batch ID
contains a random part, so when the restored database builds a batch for a
sequence that was already used, the hub refuses it as a sequence conflict
instead of acknowledging it as a duplicate.

Before sending records, the sync command checks the authenticated hub's
protocol, schema, contract, and machine identity. On a mismatch, it stops
without sending. The hub never treats an absent machine as a deletion. A
missing source is sent only when the collector records an explicit
missing-source status.

## Query the hub

Set the owner secret in `CODEX_SESSIONS_HUB_OWNER_TOKEN` and use the existing
query commands with a hub destination and machine ID:

```powershell
$env:CODEX_SESSIONS_HUB_OWNER_TOKEN = 'the-owner-secret'
codex-sessions-collector.exe query sessions --hub https://hub.example.test --hub-machine laptop-1 --limit 20
codex-sessions-collector.exe query search --hub https://hub.example.test --hub-machine laptop-1 --query 'example' --limit 20
```

The hub forwards only the listed query options. It sets the destination and
output options (`--db`, `--format`, `--hub`, `--hub-machine`) itself and
refuses them in a request. The owner API also exposes `/v1/machines` and
`/v1/usage`. Machine credentials can upload and verify compatibility but
cannot query another machine. The hub stores normalized content, paths, and
usage inputs, so treat its database and backups as private session data.
Pricing history reconciliation is a separate feature and is not implied by the
usage totals returned here.

### Local Caddy regression

This section is for contributors working from a source checkout. This opt-in
test uses only loopback endpoints, synthetic credentials and a new scratch
database. It never uses the installed app's database or a real hub.
Prerequisites: Python 3.9+, native Caddy (tested with 2.11.7), and both Rust
binaries built in this checkout's `collector/target/debug`:

```powershell
cargo build --manifest-path collector/Cargo.toml --bins
python scripts/test_hub_caddy.py --caddy <absolute-path-to-caddy> --output-root <existing-scratch-parent>
```

Use `--profile release` for binaries built with `--release`. Each run creates a
unique `caddy-busy-*` directory with logs, `result.json`, isolated Caddy
settings and synthetic databases. Keep the result and logs, and remove the
disposable fixtures after both child processes have stopped. The script stops
its own child processes even on failure. It needs no Docker or installed Caddy
service.

The test uploads 56 MiB of decoded data that is deliberately compressible. A
direct request that keeps making progress holds the local hub's ingest gate
while `hub sync` uses up four busy attempts through Caddy. The test checks
that HTTP 503 is reported, that the queue and batch identity are kept, that
the sync finishes within its bound, and that the transport-failure counters do
not change. Once the gate is released, the same stored batch must be delivered
successfully.

To also test large, poorly compressible bodies, add `--noise-mib 9`. This
places seeded high-entropy bytes inside the same record. Known limitation: on
Windows with Caddy 2.11.7's default HTTP transport, Caddy sends an early 100
and later records the hub's 503, but closes the connection while the collector
is still uploading. The collector sees a connection reset and counts a
transport failure. In that case the script fails its response and counter
checks on purpose and keeps the observation. Until the proxy or transport
behavior is fixed, busy-response handling is not confirmed for large, poorly
compressible bodies sent through Caddy. A 103 response with headers that
arrives before the 100 is also subject to ureq-proto 0.6.4's Await100
limitation. The collector's response filter tests confirm that the bytes pass
through unchanged, not that ureq itself supports that sequence.

A separate measurement covers large dead letters. It uses three synthetic
56 MiB records and a scratch copy of a database, and never reads a live
database:

```powershell
$env:CODEX_SESSIONS_COLLECTOR_TIMINGS = '1'
cargo test --manifest-path collector/Cargo.toml --test hub_sync three_56_mib_dead_letters_rebuild_within_the_write_hold_budget -- --ignored --exact --nocapture
```

This test checks the 1,000 ms hard limit on holding the write lock and fails on
purpose if a single SQLite blob insert or COMMIT exceeds it. The chunking code
limits the size of each unit of work and inserts gaps, but it cannot guarantee
a deadline for a single SQLite operation that cannot be split. The ordinary
test suite skips this expensive measurement, so a passing ordinary suite does
not prove the hold limit for large records.
