# Focused development tests and the full gate

Use focused tests during development. Run the complete release gate before
closing a larger slice (normally after 3-4 related tasks), after shared
database/runtime/build changes, before release, and in CI. A focused pass does
not close the slice by itself.

## Windows fast lane

Requires PowerShell 7, Python 3, Rust and Flutter. Put `C:\tools\flutter\bin`
and the Rust toolchain on PATH. From the repository root:

```powershell
# Compare the working tree with a branch/commit, including staged, unstaged
# and non-ignored untracked files. Renames check both old and new paths.
pwsh -NoProfile -File scripts/test_fast.ps1 -Base origin/main -DryRun
pwsh -NoProfile -File scripts/test_fast.ps1 -Base origin/main -OutputRoot F:\dev-artifacts\runs\codex-sessions-viewer-main\my-unique-fast-run

# Inspect or exercise one hypothetical change without editing that source.
pwsh -NoProfile -File scripts/test_fast.ps1 -ChangedPath collector/src/resident/bridge.rs -DryRun
pwsh -NoProfile -File scripts/test_fast.ps1 -ChangedPath app/lib/src/database/application_maintenance.dart -OutputRoot F:\dev-artifacts\runs\codex-sessions-viewer-main\my-unique-maintenance-run

python scripts/test_fast_tests.py
Invoke-Pester scripts/test_support/FastTestLaunch.Tests.ps1
```

`-OutputRoot` must be a new directory. It retains `selection.json`, a log and
monotonic duration for every command/setup step in `timings.json`, plus the
total duration and sandbox path in `run.json`. Unfiltered Flutter files run
together; `flutter-target-timings.json` records each suite's measured span
including load time and its pass/fail/skip counts. These concurrent spans
overlap and must not be summed. A failed native step records its
exit code and stops the run. Sandboxes are retained for inspection; remove
only that run's sandbox after collecting proof and confirming its writers
have stopped. Reuse the checkout's incremental `collector/target` and Flutter
caches. Do not set `CARGO_TARGET_DIR`.

The checked-in policy is `scripts/fast_tests.py` and the source graph and
semantic rules are in `scripts/test_dependencies.py`. Each selected path has
a reason in the dry-run JSON:

- Rust selects tests that directly reference the changed module, or reference
  a library module that directly imports it (one hop). `use` trees, qualified
  module names and external `mod` declarations supply edges. Inline library
  tests are included. Explicit semantic mappings retain resident protocol/
  launcher/transport targets, price-history write-budget coverage, and
  contract outbox/hub-sync coverage.
- One-hop expansion stops at these explicit hubs: `collector/src/lib.rs`,
  `main.rs`, `cli.rs`, `hub_server.rs`, `resident/mod.rs`, `store/mod.rs`,
  `bin/codex-sessions-hub.rs`, and `bin/codex-sessions-scan-launcher.rs`.
  Changing a hub itself widens as a shared path. Resident identity also widens
  because it controls write-lease identity.
- Rust source changes also select native contract sentinels:
  `collector_ingestion_compat_test.dart`, `hub_price_history_test.dart`, and
  `resident_collector_client_test.dart`, plus their reverse Dart consumers.
  These exercise ingestion, hub/Dart price parity and the resident bridge
  with the candidate sidecars; they do not select every process-spawning test.
- Every changed Dart file follows full reverse local import/export/part
  closure, including conditional branches, test-to-test imports, test helpers
  and integration tests. Application maintenance currently selects 18 files.
  In the large runtime fixture it
  runs only `pricing commits between background scan batches before scan
  completion`, the case that uses `ApplicationMaintenance`. The dry run prints
  this `flutter_filters` entry; any other changed path selecting that file
  removes the filter.
- Existing Rust integration test files select themselves. A changed Dart test
  selects itself and all importing test files.
- Cargo manifests/locks, pubspec, SQL, test harness/support, build scripts,
  CI, unmapped paths, deleted targets and stale map entries widen to all Rust,
  Flutter and integration tests. Documentation under `docs/`, README and
  CHANGELOG need no runtime tests.

This is risk-based development selection: tests reached only through a binary
entry point or beyond the Rust one-hop boundary are caught by the full gate.
The selector self-test checks this exact Rust rule and full Dart closure over
every source module/Dart file in the real tree, alongside the review witnesses.

Widening is intentionally visible and has no few-minute promise. A widened
real run requires `-AllowWide`; otherwise the runner stops before starting
tests and points to the full gate. Review the reasons rather than bypassing
them with a guessed narrow path. `-ChangedPath` replaces the Git-derived list
and is intended for diagnostics/representative proof, not slice closure.

Tests use the same `New-TestEnvironment` / `Invoke-TestProcess` boundary as
`build_windows.ps1`, plus Flutter's `TestEnvironment.testMain` configuration.
The launch guard accepts only existing targets, the machine reporter, and the
one named maintenance case; it rejects arbitrary extra flags. Unit/widget
files are batched, while integration targets run separately. Flutter setup
builds debug collector/hub binaries and passes
their absolute paths via `CODEX_SESSIONS_COLLECTOR_EXE` and
`CODEX_SESSIONS_HUB_EXE`. The representative runs below verify these debug
sidecars through actual process-using tests. The release gate still builds and
tests release sidecars.

Budget: aim for **under 5 minutes** for a typical mapped change on PAWEL3
with available dependencies and incremental caches. Cold compilation, SDK
downloads, wide selections and heavy competing CPU load can exceed this.
The runner records time instead of terminating a valid test at the budget.
Representative results and individual target durations are recorded in
[test-target-timings.md](test-target-timings.md).

The selector itself is portable:

```sh
python3 scripts/fast_tests.py --base HEAD --dry-run
python3 scripts/test_fast_tests.py
```

Only selection is offered on Linux/macOS in this slice; the execution wrapper
is Windows-only. Use the existing native release scripts for a complete
platform gate. No new dependencies are required.

## Parser resume differential modes

`cargo test --manifest-path collector/Cargo.toml --test incremental_parse` defaults
to a fast parser lane, targeting 15 seconds on PAWEL3 with a warm build cache.
It includes every session fixture (Codex, Claude, WSL projections, subagents and
malformed inputs), generated seed 1, four chains per input/source projection with
at most five cuts, selected complete-line/mid-line/UTF-8 boundaries, and all
targeted fallback, corruption, BOM/CRLF and deterministic growth tests.

Run the exhaustive parser gate at slice review/batch boundaries:

```powershell
$env:CXV_INCREMENTAL_EXHAUSTIVE = '1'
try {
    cargo test --manifest-path collector/Cargo.toml --test incremental_parse -- --nocapture
} finally {
    Remove-Item Env:CXV_INCREMENTAL_EXHAUSTIVE
}
```

Exhaustive mode keeps every fixture and seeds 1..16, every line end, end minus
one, midpoint and UTF-8 interior cut, plus 50 random chains per input/source
projection of length 2..10. `CXV_INCREMENTAL_SEEDS=N` can override the number of
generated seeds (1..256) in either mode; leave it unset for these default bounds.
The suite prints mode, bounds and coverage counts. Its checkpoint-corruption
property uses seed `0xc2150001`, 24 mutation classes and 24 mutations on each of
two checkpoints per harness in fast mode; exhaustive mode uses 64 mutations on
each of eight checkpoints per harness. Corpus generation and test execution are
deterministic. A second generic property walks every leaf and array in one rich
generated checkpoint per harness (seed 1), using numeric extrema, changed strings,
flipped booleans, null replacements, and truncated/duplicated/swapped arrays.
Each mutation runs with its original digest (must reject) and a recomputed digest.
A correctly digested writer bug may change rows: it must return success without
panic, read at most source bytes plus the appended bytes read by the resume attempt
before abandoning plus 288 KiB, and emit at most 256 KiB compressed / 64 MiB decoded.
This is the coordinator's CXV-215-CR-05 decision (2026-11-08, review-r4 disposition):
a rare late abandon may read the appended suffix once before one full fallback.
The test-only per-reader counters measure the attempt separately, including an
early mismatch that reads zero bytes. The generic helper also asserts at most one
fallback reader and at most one source worth of fallback bytes, including the
reused second-step path. Both harnesses have deterministic large-source early-
abandon cases that inject a duplicate full fallback and independently require the
read bound and fallback-count assertions to reject it. Large-append regressions
account for exact fingerprint and suffix reads and one full-source fallback.
A fallback must equal Disabled exactly. A resumed case must emit a
decodable checkpoint and survive a second appended step under the same criteria.
The suite prints per-harness/mode counts and elapsed time. Default inputs include
extreme token values for both harnesses; token arithmetic always wraps, while
positions use checked operations. Every differential cut also compares Fresh with
Disabled and accepts only finality abandons from healthy saved state. A seeded
fold-grouping property and named default-policy overflow regressions cover the
checkpoint observer and wrapping totals. ResumeOutcome reports the abandon reason;
steps_since_full is zero after a full parse and positive after incremental ingest,
which phase-2 wiring can use for the accepted full reparse when growth stops.
WSL projections use local fixture files and do not certify live
UNC I/O. BOM behavior is compared with the existing full parser, including its
errors; the tests do not change the accepted input format.

## Full slice/release/CI gate

The full path is unchanged:

```powershell
pwsh -NoProfile -File scripts/build_windows.ps1 -OutputDirectory F:\dev-artifacts\builds\codex-sessions-viewer-main\release
# Packaging also invokes the build gate:
pwsh -NoProfile -File scripts/package_release.ps1
```

On native Linux/macOS use `scripts/build_linux.sh` / `scripts/build_macos.sh`
(Linux CI uses Xvfb). These existing scripts and the Native release CI workflow
run all Rust test targets, all Flutter unit/widget tests, integration tests,
formatting/static checks and a release build. Retain one complete result on
the final candidate; reuse it only while source and consumed inputs match.
Keep the platform-specific release and accessibility checks documented in
[release-validation.md](release-validation.md).

## Where the time goes; proposed follow-up only

The old all-tests-on-every-change policy pays for `write_lease` (601.33 s),
`resident` (133.73 s), `hub_sync` (126.01 s), `write_interleavings` (99.47 s),
and `write_budget` (41.29 s) on Windows CI. Flutter's
`runtime_scan_app_test.dart` spans about 224 s in that log. These costs are
avoided when unrelated; none of those tests is rewritten here.

A preliminary PAWEL3 probe that selected the whole runtime file for maintenance took
358.74 s overall, including 296.92 s in that file. Source inspection found
that only the pricing-contention case directly uses `ApplicationMaintenance`,
so the final rule selects that case for maintenance-only changes. Runtime
source/test changes still run the entire affected file. Serialize runs in a
checkout: concurrent Flutter invocations contend for generated native assets
such as `app/build/native_assets/windows/sqlite3.dll`.

The 601 s lease result is consistent with the source, rather than a 600 s
sleep in the fixture. In `collector/tests/write_lease.rs`,
`l6_public_writers_busy_without_changes` holds a competing connection's
`WriteLease` and enters `LeaseWait::enter(Duration::ZERO)`, then calls
`codex::collect_file`. In `collector/src/codex/mod.rs`, that public function
enters its own 600-second `LeaseWait`, overriding the outer test scope.
`WriteLease::acquire` polls the held file lock with sleeps of up to 25 ms until
the timeout. Its guard cannot be released until the blocking call returns.
This explains approximately 600 s of the target's 601 s baseline. The Claude
scan entry also has a 600-second scope. The child-helper test's 15-second
sleep is killed by its parent after readiness, so it does not explain 601 s.

Proposed follow-up: factor acquisition timeout policy behind a scoped,
test-only injectable override respected by public scan entry points. Keep the
production ten-minute default; run the busy/no-mutation inventory with a tiny
deadline and assert that exact refusal and unchanged data/journals. Keep a
separate production-default policy assertion and a synchronized process-death
case using the real OS lock. This retains contention, ordering and recovery
coverage without waiting ten minutes for a deliberate refusal. Measure the
result before claiming a speedup.

For resident idle/timeout tests, propose injecting scheduler/idle deadlines
while retaining a small real-process protocol smoke set. For hub and writer
interleavings, first record per-case time, replace readiness sleeps with
barriers/events where possible, and keep bounded real lock/HTTP timeout cases.
For Flutter runtime scanning, measure setup versus waits, reuse immutable
fixtures and inject controllable debounce/retry clocks while preserving real
collector bridge cases. These are proposals, not changes or measured gains.
