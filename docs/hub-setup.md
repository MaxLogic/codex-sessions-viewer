# Optional personal hub

The viewer and collector work locally without a hub. A hub is an explicit,
owner-operated destination for normalized session records. Each machine gets
an isolated SQLite database on the hub. Do not place a SQLite database on a
network share or let a second process open it from another host.

## Browse from the viewer

Sessions starts on **This machine**, with all local operations available offline.
Choose **Hub**, enter the HTTPS URL and an owner token, and select **Connect to
hub**. The owner token may instead come from `CODEX_SESSIONS_HUB_OWNER_TOKEN`.
Only the URL and selected machine are saved in `[hub]` in `settings.toml`; the
dialog token stays in memory. The same `[hub] url` is the only hub setting: price
history sharing uses it too (see [shared price history](hub-price-history.md)).
No hub credential is ever stored in `settings.toml`. Switching back to This
machine retains the hub connection for this window and pauses its polling. The
screen runs one hub request at a time; a click that arrives while a refresh is
running is ignored.

Hub sessions, message search, conversation pages, and the last 30 days of token
usage are requested on demand. While Hub is visible, the current page refreshes
every ten seconds and catches up after a temporary outage. A hub error leaves
the last successful rows visible with an explicit error; it never substitutes
local rows. **Search / refresh hub** returns to the newest page.

**Hub title annotation** and **Hub notes** belong to the hub, independently of
the uploaded source title and local annotations. Saving checks the last-read
revision; a conflicting edit requires reloading the session. Collector uploads
do not replace these annotations. Unsaved edits pause automatic refresh.

**Resume locally** checks the persistent machine identity and an existing local
session file, working folder, and installed harness in the recorded environment.
Foreign sessions cannot resume locally. Opening a foreign directory requires
**Map local folder**, even if the remote path happens to exist here. Mappings
apply only to the selected session in this window and never enable resume.

## Start one hub

Build the Rust binaries from this checkout with `cargo build --release
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
secret. The machine ID must use letters, digits, hyphens, or underscores. Keep
the file readable only by the hub account. Back up this file and the hub data
directory together. The hub does not manage accounts, public sharing, or TLS.

```powershell
codex-sessions-hub.exe 127.0.0.1:8765 C:\HubData C:\HubData\hub.json
```

The HTTP listener accepts loopback only. For another machine, place an HTTPS
reverse proxy in front of it and configure the collector with the proxy's
`https://` URL. The collector refuses plain HTTP except on a literal loopback
address (`http://127.0.0.1:PORT` or `http://[::1]:PORT`; `localhost` is refused
because the name can resolve elsewhere). A URL path prefix of the proxy, such
as `https://example.test/hub`, is kept. Allow proxy request bodies of at least
64 MiB and protect the owner token.

The collector checks HTTPS certificates against its bundled Mozilla root
certificates, not the Windows certificate store. A hub behind a certificate
from a private or corporate CA is therefore refused by the collector even when
Windows trusts it; use a publicly trusted certificate for the proxy.

The server accepts up to 128 records and 64 MiB per upload and refuses a
larger declared body before reading it. Credentials are checked before a body
is read. Each connection is served on its own thread, up to 32 at once; further
clients receive HTTP 503 at once. Every socket read and write must progress
within `request_timeout_seconds` (default 30), the request head must arrive
within that time, and a whole request within ten times it, so a stalled client
cannot hold the hub. A request that ends early or times out is answered with
HTTP 408, which the collector treats as transient. Raise the timeout when a
slow uplink sends single records of many megabytes:

```json
{
  "owner_token": "...",
  "machines": { "laptop-1": "..." },
  "request_timeout_seconds": 30
}
```

An upload's records and its sequence number are stored in one transaction: a
refused record leaves neither data nor a consumed sequence on the hub.

## Pair a collector

Use a collector from the same release as the hub and viewer. Open the viewer
once to migrate its database, then inspect the local machine ID:

```powershell
codex-sessions-collector.exe hub status --db C:\Path\codex_sessions_viewer.sqlite
```

Put that exact ID and its distinct machine secret in the hub configuration.
Then pair the local database and collect previously indexed sessions again so
they enter the outbox. Pairing does not upload existing history by itself.

```powershell
codex-sessions-collector.exe hub enable --hub-url https://hub.example.test --db C:\Path\codex_sessions_viewer.sqlite
codex-sessions-collector.exe codex scan --force --db C:\Path\codex_sessions_viewer.sqlite
codex-sessions-collector.exe claude scan --force --db C:\Path\codex_sessions_viewer.sqlite
$env:CODEX_SESSIONS_HUB_MACHINE_TOKEN = 'the-machine-secret'
codex-sessions-collector.exe hub sync --db C:\Path\codex_sessions_viewer.sqlite
```

For a collector-owned database, use `--standalone FILE` in place of `--db
FILE`. Keep the machine secret outside command arguments, logs, and the viewer
settings file. Run `hub sync` periodically in Task Scheduler with the secret
provided to the task process through its environment. Local scan and queries
continue while the hub is unavailable; committed records stay in
`collector_upload_outbox` and the next sync retries them.

Only changes are queued. A scan that finds a source or thread name unchanged
queues nothing, and a newer state of a source replaces its older unsent state,
so an unreachable hub does not grow the outbox with repeated scans. The sync
command sends batches of up to 128 records and 8 MiB of UTF-8 until the
outbox is empty; a single larger record (up to 48 MiB) is sent alone. Each
upload may take a minute plus one second per 64 KiB. A batch, its sequence and
a batch ID with a random part are recorded before sending, so a lost
acknowledgment is retried with the same sequence and batch ID and the hub
answers with a duplicate acknowledgment. After two consecutive network
failures (for example timeouts on a slow uplink) the in-flight batch is halved
under the same batch ID; if the hub did store the full batch, it acknowledges
the smaller one as a duplicate and the rest is sent again, which the hub
applies idempotently.

### Dead letters

Only the hub's own refusal moves records aside: a response whose JSON `code`
is `record_rejected` (a record the hub cannot store, a batch above its size
limit, or a record for another machine) or `invalid_batch` (an upload the hub
cannot parse). The hub applies a batch atomically, so a refused batch of
several records is resent one record at a time to find the refused record.
That record, or one above 48 MiB that is never sent, moves to the
`collector_upload_dead_letters` table with the HTTP status, the time and the
hub's reason (the credential is never echoed), and no longer blocks the
records behind it. Dead letters are not retried; `hub disable` discards them.

Every other failure is transient and leaves the queue untouched for the next
run: network errors and timeouts, HTTP 408 and 5xx, a rejected credential, a
protocol mismatch, and any error without a hub code, such as the HTML error
page of a reverse proxy (for example nginx's 413 when its body limit is below
the hub's). A sequence conflict stops the sync and names `hub resync`.
`hub status` reports the pending count, the last acknowledged sequence, and
the number and most recent reasons of dead-lettered records:

```powershell
codex-sessions-collector.exe hub status --db C:\Path\codex_sessions_viewer.sqlite
```

`hub disable` stops queuing and discards queued, in-flight and rejected
records. The pairing and last acknowledged sequence remain, so `hub enable`
with the same URL continues the same hub history; collect again with `--force`
to queue existing sessions.

### Sessions whose files are gone

A forced collection queues only sessions whose source files still exist. A
session collected before pairing whose file was deleted since exists only in
the local database. `hub backfill` rebuilds each such session (source recorded
missing, parse available) from its stored rows, queues it with an explicit
missing status, and leaves the upload to the next `hub sync`:

```powershell
codex-sessions-collector.exe hub backfill --db C:\Path\codex_sessions_viewer.sqlite
codex-sessions-collector.exe hub sync --db C:\Path\codex_sessions_viewer.sqlite
```

The rebuilt snapshot is the stored state, not the source: per-message
reasoning and cache-write tokens are absent. A hub that already holds a parsed
copy of the session keeps it, because a missing source ranks below an
available one. Each run queues every qualifying session again; run it once
after pairing, or after restoring an older hub backup.

### Reconcile after restoring a backup

Back up the local database while preserving its hub state and outbox.
Replacing it with an older copy rewinds its sequence; the next sync then fails
with a sequence conflict and names `hub resync`. The same happens after
restoring an older hub backup. `hub resync` asks the hub for the last sequence
it accepted from this machine and continues from there, keeping the queued
records; it also forgets which statuses and thread names were already queued.
Collect again with `--force` so that records the hub lost are queued again:

```powershell
$env:CODEX_SESSIONS_HUB_MACHINE_TOKEN = 'the-machine-secret'
codex-sessions-collector.exe hub resync --db C:\Path\codex_sessions_viewer.sqlite
codex-sessions-collector.exe codex scan --force --db C:\Path\codex_sessions_viewer.sqlite
codex-sessions-collector.exe hub sync --db C:\Path\codex_sessions_viewer.sqlite
```

The hub applies source revisions idempotently, so records it already has are
harmless to send again.

A hub restored from an older backup has lost every record accepted after that
backup, and the collector has already removed those records from its outbox.
`hub resync` alone cannot bring them back: after it, always collect again with
`--force` on every paired machine (`codex scan --force` and `claude scan
--force`) and then run `hub sync`, as above.

A restored local database cannot make the hub skip new records: each batch ID
contains a random part, so a batch the restored database builds for an already
used sequence is refused as a sequence conflict instead of being acknowledged
as a duplicate.

The sync command checks the authenticated hub protocol, schema, contract, and
machine identity before sending records. A mismatch fails closed. The hub
never treats an absent machine as a deletion. A missing source is sent only
when the collector records an explicit missing-source status.

## Query the hub

Set the owner secret in `CODEX_SESSIONS_HUB_OWNER_TOKEN` and use the existing
query commands with a hub destination and machine ID:

```powershell
$env:CODEX_SESSIONS_HUB_OWNER_TOKEN = 'the-owner-secret'
codex-sessions-collector.exe query sessions --hub https://hub.example.test --hub-machine laptop-1 --limit 20
codex-sessions-collector.exe query search --hub https://hub.example.test --hub-machine laptop-1 --query 'example' --limit 20
```

The hub forwards only listed query options; destination and output options
(`--db`, `--format`, `--hub`, `--hub-machine`) are chosen by the hub and refused
in a request. The owner API also exposes `/v1/machines` and `/v1/usage`.
Machine credentials can upload and verify compatibility but cannot query
another machine. The
hub stores normalized content, paths, and usage inputs; treat its database and
backups as private session data. Pricing history reconciliation is a separate
feature and is not implied by the usage totals returned here.
