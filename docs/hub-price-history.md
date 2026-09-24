# Shared observed price history

The optional hub shares public model price observations. These are observed
catalog prices, not an exact record of provider billing changes or invoices.
Session content is never included in price-provider requests.

## Configuration

Enable fetching in the hub JSON configuration:

```json
"pricing": {
  "enabled": true,
  "endpoint": "https://openrouter.ai/api/v1/models",
  "interval_hours": 6
}
```

The default six-hour schedule uses 00:00, 06:00, 12:00 and 18:00 UTC.
Successful fetch completion is the observation time. Failed fetches retain the
last history and use bounded retries. A disabled or absent pricing section does
not fetch provider data.

A fetch that finds a model's price unchanged does not store another copy of
the same evidence. It records a last-confirmed time on the model's latest hub
observation instead, so the log grows only when a price, rule or catalog entry
changes. Confirmation is contiguous: it applies only when the previous
confirmation (or the observation) is in the current or the previous fetch
slot. After a missed slot, for example while the hub or the provider was
unreachable, the unchanged price is stored as a new observation, so the
earlier coverage ends at its last contiguous confirmation. A new revision is computed only when the log changes; unchanged
synchronizations read the stored revision.

Configure a viewer with the one hub setting in its `settings.toml`, the same
URL used to browse hub sessions:

```toml
[hub]
url = "https://your-personal-hub.example"
```

Provide the machine credential only through the environment of the viewer
process; it is never stored in `settings.toml`:

```powershell
$env:CODEX_SESSIONS_HUB_MACHINE_TOKEN = 'the-machine-secret'
```

The viewer uploads its evidence as this database's machine identity, the same
identity the collector uses (`hub status` shows it), so that ID must be
registered on the hub with this credential. The former `pricing.hub_url` is
adopted as `[hub] url` when `[hub] url` is empty; the former `pricing.hub_token`
and `pricing.hub_machine_id` are no longer read. Saving `settings.toml` keeps
them unchanged, since secrets are never rewritten or dropped without an
explicit request, and Settings shows a warning that a legacy hub token was
found and that price sync reads `CODEX_SESSIONS_HUB_MACHINE_TOKEN`. The token
value is never shown. Remove the legacy keys from the file by hand.

The viewer prefers fresh authoritative hub observations. An unavailable or
stale hub allows the existing local OpenRouter fetch to run. The reason of the
last failed hub price sync (for example a rejected credential, a missing
`CODEX_SESSIONS_HUB_MACHINE_TOKEN`, or an unreachable hub) is shown in Settings
under the OpenRouter price refresh status; it is fixed text and never contains
the credential. Plain `http://` is accepted only for a literal loopback
address (`127.0.0.1` or `[::1]`), as in the collector. Leaving `[hub] url` empty
preserves standalone operation.
Disabling external pricing preserves the existing explicit local-override
policy. Credentials are not sent to OpenRouter.

## Reconciliation and provenance

Each immutable observation contains its origin, authority, actual UTC time,
provider and model identity, decimal rate strings, and conditional rules.
Unknown rates and unsupported units remain unknown or partial; token counts
and event timestamps are never changed by price reconciliation.

Hub evidence wins wherever it covers the same provider and model: from a hub
observation's time through the last complete hub catalog that confirmed it
unchanged in contiguous fetches. Local observations inside that coverage are
superseded, even at different instants. Local observations outside it, such as
those made during a missed hub fetch, remain separate historical evidence:
coverage never spans a missed fetch slot (see above). At the same provider,
model and exact observation time, hub evidence wins over local evidence.
Otherwise equal-authority conflicts use a deterministic fingerprint tie break.
Rust and Dart apply the same rule. The hub refuses uploaded observations more
than five minutes later than its own clock, so a wrong client clock cannot
place evidence in the future.
The fetch schedule does not collapse distinct observations within a slot.
An authoritative complete catalog can record model withdrawal as an explicit
observation, preserving the resulting no-price interval.

Fingerprints use SHA-256 over JSON with recursively sorted object keys.
Observation times use UTC with six fractional digits. A revision hashes the
sorted observation fingerprints, so retries and arrival order do not change
the final revision. Confirmations do not change the revision; they change
only which evidence wins. All original observations remain available,
including evidence that did not win a conflict.

Schema 23 stores the observation log and canonical revisions; schema 24 adds
the last-confirmed times. Existing local periods are imported before the first
hub synchronization, including their rules and withdrawals. Export assigns
previously unlabelled local evidence to this database's machine identity; the
original local records remain in the viewer database.

The viewer materializes non-overlapping periods under immutable source
identities. Existing cost rows retain their price-period and snapshot links;
snapshots identify the canonical revision that produced them. Only usage
partitions containing events in changed price intervals are queued for
repricing. Existing stale/unknown indicators continue to apply until this work
finishes. Explicit local price overrides have separate history and are not
rewritten by hub data.

## Protocol and verification

`POST /v1/prices/sync` uses a registered machine's bearer credential. Protocol
version 1 accepts only that machine's local observations. Clients cannot upload
authoritative hub observations or impersonate another origin. The response
contains the canonical revision and retained observations; the viewer verifies
the revision before applying the response atomically.

The request goes to `/v1/prices/sync` under the configured hub URL, keeping a
proxy path prefix. Uploads and downloads use batches of at most 512
observations, with byte caps. Downloads retain one server rowid watermark
across all pages. Confirmations follow the observations in pages of at most
1024, with their own watermark captured at the same time. Each viewer persists
the acknowledged hub membership, both cursors and the applied revision;
subsequent synchronization sends and receives new evidence and confirmations
only. A replaced or
restored hub triggers a verified full snapshot and re-upload of this machine's
local evidence. A failed import does not advance its cursor. Back up the hub
database to preserve authoritative evidence after hub data loss.

Revision records retain a watermark into the immutable observation log, rather
than another full catalog copy. Unchanged repeated prices reuse materialized
periods while retaining each distinct observation's provenance.

```powershell
cargo test --manifest-path collector/Cargo.toml --test price_history_sync
cd app
flutter test test/pricing/hub_price_history_test.dart test/pricing/pricing_repository_test.dart test/usage/usage_projection_test.dart
```

`samples/pricing/hub-parity.json` is shared by Rust transport and Dart pricing
tests. It retains a 22-digit fractional cache-write rate, conditional pricing,
separate token buckets, and the exact expected decimal result.
