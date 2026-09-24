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

Configure a viewer in its existing `settings.toml`:

```toml
[pricing]
hub_url = "https://your-personal-hub.example"
hub_machine_id = "your-registered-machine"
hub_token = "your-machine-credential"
```

The machine ID and credential must match the hub's registered machine. The
viewer prefers fresh authoritative hub observations. An unavailable or stale
hub allows the existing local OpenRouter fetch to run. Leaving these fields
empty preserves standalone operation. Disabling external pricing preserves
the existing explicit local-override policy. Settings edits in the GUI retain
these optional fields; credentials are not sent to OpenRouter.

## Reconciliation and provenance

Each immutable observation contains its origin, authority, actual UTC time,
provider and model identity, decimal rate strings, and conditional rules.
Unknown rates and unsupported units remain unknown or partial; token counts
and event timestamps are never changed by price reconciliation.

Different observation times remain separate historical evidence, including
local observations made during a missed hub fetch. At the same provider,
model and exact observation time, hub evidence wins over local evidence.
Otherwise equal-authority conflicts use a deterministic fingerprint tie break.
The fetch schedule does not collapse distinct observations within a slot.
An authoritative complete catalog can record model withdrawal as an explicit
observation, preserving the resulting no-price interval.

Fingerprints use SHA-256 over JSON with recursively sorted object keys.
Observation times use UTC with six fractional digits. A revision hashes the
sorted observation fingerprints, so retries and arrival order do not change
the final revision. All original observations remain available, including
evidence that did not win a conflict.

Schema 23 stores the observation log and canonical revisions. Existing local
periods are imported before the first hub synchronization, including their
rules and withdrawals. Export assigns previously unlabelled local evidence to
the explicitly configured machine; the original local records remain in the
viewer database.

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

Uploads and downloads use batches of at most 512 observations, with byte caps.
Downloads retain one server rowid watermark across all pages. Each viewer
persists the acknowledged hub membership and cursor with the applied revision;
subsequent synchronization sends and receives new evidence only. A replaced or
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
