# Changelog

## [Unreleased]

### Added
- Added resumable background backfill for historical message search rows plus a Settings diagnostic for indexed and remaining message-search counts.
- Added a persisted `app.start_with_windows` setting, defaulted on, exposed in Settings under Application, and wired to the current-user Windows Run key.
- Added subagent-aware session grouping, main/subagent usage rollups, and origin breakdowns in Usage statistics.
- Added a persisted `ui.motion` setting with `system`, `reduced`, and `normal` choices exposed in Settings.
- Added an ignored private-corpus benchmark mode for realistic aggregate session scan timing.
- Added persisted Sessions table column widths, multi-column sorting, right-click sort options, per-cell screen-reader semantics, and minute-by-minute relative last-message dates.
- Wired production session refresh to load settings, scan configured Codex roots, persist parsed sessions to SQLite, and show real Sessions rows.
- Added Sessions empty states for no supported files, filter-empty results, unreachable paths, and refresh failures.
- Added explicit Settings units and helper text for scanner, font, pricing, path, terminal, and voice-over fields.
- Added a local benchmark harness and baseline report for scanner, parser, cache skip, SQLite search, and release packaging timings.
- Added an explicit app composition boundary so production screen wiring lives in the app layer and the shell renders injected screens.
- Wired session row actions plus message, command, and detail copy buttons to callbacks or clipboard behavior.
- Removed remaining production no-op UI handlers and added unavailable reasons for disabled session filters.

### Changed
- Improved window placement restore so maximized state is saved separately from restored bounds and invalid saved bounds are clamped to the current display.
- Stabilized parsed session row identity so growing JSONL files update the same row and existing duplicate snapshots collapse while retaining local metadata.
- Improved Sessions table filtering, row identity, count formatting, row actions, scan-status wording, and empty-detail guidance for clearer desktop and screen-reader use.
- Hid injected AGENTS.md instruction blocks from conversation messages, collapsed duplicated echoed user prompts, and show missing per-message token counts as unknown instead of `0 tokens`.
- Made startup cached session loading lighter and non-blocking by streaming newest-first cached rows from a background isolate, skipping list-level pricing work, batching tag reads, and keeping richer cost/token detail loading lazy per selected session.
- Moved the Sessions visible count into the header, added a cached-load progress line with a compact spinner and total count, and auto-detected project names from each session working directory while preserving manual project overrides.
- Backfilled auto-detected project names for older cached sessions, removed placeholder values from Sessions table cells, animated active load/scan status, and started a scan automatically after cached startup rows finish loading.
- Removed the Sessions title column, stopped deriving JSONL titles from first user messages, hid empty title headers in session details, and cleaned placeholder `auto` summaries plus AGENTS-instruction titles from cached metadata.
- Added a Sessions table filter that shows only the newest session per project while leaving sessions with no project ungrouped.
