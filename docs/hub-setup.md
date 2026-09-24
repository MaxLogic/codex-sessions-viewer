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
dialog token stays in memory. Switching back to This machine retains the hub
connection for this window and pauses its polling.

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
`https://` URL. The collector refuses plain HTTP except for loopback. Limit
proxy request bodies to at least 64 MiB and protect the owner token. The
server accepts up to 128 records per upload; current collectors send one.

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
`collector_upload_outbox` and the next sync retries them. `hub status` reports
the pending count and last acknowledged sequence. Back up the local database
while preserving its hub state and outbox; replacing it with an older copy can
reuse a sequence and requires an explicit reconciliation before upload.

The sync command checks the authenticated hub protocol, schema, contract, and
machine identity before sending records. A mismatch fails closed. It delivers
at most 256 queued records per invocation, so schedule it often enough for
your collection volume. The hub applies source revisions idempotently and
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

The owner API also exposes `/v1/machines` and `/v1/usage`. Machine credentials
can upload and verify compatibility but cannot query another machine. The
hub stores normalized content, paths, and usage inputs; treat its database and
backups as private session data. Pricing history reconciliation is a separate
feature and is not implied by the usage totals returned here.
