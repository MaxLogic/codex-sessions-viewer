The JSON beside this file records actual e81ecf9b132e8aa5bc3aa7cd45903adba61ec51f
behavior for `write_side_effects.rs::capture`, with hub queueing enabled.
It is a base-semantics oracle, not output blessed from the chunked candidate.

Only wall-clock columns ending in `_at_utc` are normalized. Queue IDs and
sequences, complete envelope JSON (including duplicate references and input
order), record hashes, hub state, and exact session journal revisions remain.
Every `collector_*` table and both journal tables are enumerated, including
empty delivery/dead-letter tables. The tests compare both one-unit transactions
and the default soft budget to this same oracle; no network service is used.

Fixtures cover repeated statuses with different local priority/delivery order,
changed and unchanged local projects, absent peers, empty references/hints,
duplicate original references, intermediate thread-name changes, raw/trimmed
names, backfill, metadata cleanup, cache-repair deletion and repeated completion,
and changed/unchanged/removed T3 lineage (including its orphan relationship).

Generation proof, the exact base test source and source hashes are retained in
`F:\dev-artifacts\runs\codex-sessions-viewer-main\cxv180-s1b-r1-irjempfy`.
The base was extracted with `git archive e81ecf9 collector sql samples`, its
Rust sources touched to force a fresh library build in the shared target, and
the fixture run against that library. The base project-hint outbox counts
1/2/3/3 were independently checked; the pre-fix candidate produced 1/1/1/1.
Do not regenerate this golden from the current candidate.

`write_sessions_base.json` extends this same contract to session batches: initial
snapshots, unchanged reingest and a changed title. It was captured from an actual
`git archive e81ecf9 collector sql samples` extraction, not the candidate. Exact
generator source, command, exit, source/golden hashes and provenance are retained
under `F:\dev-artifacts\runs\codex-sessions-viewer-main\cxv180-s1b-r3-zlskk7hi`
(`session-base-oracle.rs`, `session-base.json`, `session-base.log`). The candidate
is tested with both zero and default soft budgets against that same base golden.

`write_order_base.json` adds the r5 ordering fixtures: six rows whose insertion
and ID orders oppose one another, multiple status updates/missing placeholders,
multiple T3 orphan cleanups, and reversed project-hint references. Journal rows
are also captured in revision order and packets in outbox ID order. Both the
default budget and soft=0 compare to these actual e81ecf9 outputs. The generator
uses the extracted base status/hint/T3 algorithms (linkage-only adapters described
in the receipt), not candidate output. Exact source, commands, native exits and
hashes: F:/dev-artifacts/runs/codex-sessions-viewer-main/run-7wfa9msb/
`order-base-provenance.json`, `order-base-generator.rs`, `base_writer.rs`,
`base_t3.rs`, `order-base-compile.log`, `order-base-run.log`.
