# Changelog

## [Unreleased]

### Added
- Added a keyboard shortcuts dialog (F1 or the Shortcuts button in the navigation rail) and the documented Ctrl+L (go to filters) and Ctrl+E (export the selected session) shortcuts.
- Wired the Logs screen to the stored log entries, with copy, open log file, open logs folder, and clear entries older than 7 days.
- Added a session Stats tab: active time split into model work, tool execution, and subagent waits; token split by agent, token type, and message kind; per-tool calls, failures, and time; models with reasoning effort; and a subagent table with kind (preconfigured role or generic), model, tokens and share, tool calls, active time, and cost. Timing is read on demand from the local session files.
- Added find-in-conversation with match highlighting, a match counter, Enter/Shift+Enter and F3 navigation, per-message match counts in the message index, and full-session search for paged sessions.
- Added working Project, Model, and Tag session filters, removable chips for every active filter, and a "N of M shown" summary.
- Added Ctrl+F (session search, or find in the conversation when it has focus) and F5 (refresh) shortcuts, and a draggable split between the session list and the detail pane.
- Added a visible startup usage migration with a verified pre-upgrade backup, resumable batches, historical pricing, parity checks, and rollback before normal writes resume.
- Added configurable daily OpenRouter price refresh and weekly database optimization, with saved job status, bounded retries, manual refresh, and accessible progress in Settings. Database writers share a queue; catalog downloads do not hold it.
- Added explicit active/archived Codex source lifecycle tracking and a one-time, audited legacy-cache repair with verified SQLite backup and fail-closed recovery checks.
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
- Apply the theme, UI density, and font size settings; they were saved but ignored.
- Show pin and archive changes immediately, and say when an archived session is hidden by the current filter.
- Re-parse this session now re-reads only that session file and refreshes its row, instead of running an incremental scan of everything.
- Run and Edit and run in the session details now launch the (edited) command without a shell; they previously always failed.
- Export Markdown in the session details is enabled; the export callback was not passed to the Sessions screen.
- The unreachable-path recovery button is labeled Retry scan, which is what it does.
- Redesigned session detail: a compact header, one primary Resume in terminal action with the rest in More, and Conversation, Stats, Details, and Focus reader tabs that fill the pane instead of a fixed-height conversation below collapsible panels.
- The conversation shows only user prompts and assistant replies by default; tool calls and reasoning are one toggle away. Long messages expand in place instead of scrolling inside a 150-pixel box, and prompts are tinted so turns are easy to scan.
- Reorganized session filters into search, time, and refresh, then compact facet menus; viewer archive, named-only, newest-per-project, path, and thread-name filters moved under More filters, which opens automatically when one of them is active.
- Let pricing and interactive writes run between session-scan batches while preserving a single scan owner. Distinguish downloaded prices waiting for the database writer from prices being stored.
- Reduce the parsed-source batch threshold from 512 MiB to 32 MiB to yield the writer more frequently; individual large sessions remain atomic.
- Index the nullable tool-call message foreign key in schema 17 so replacing messages does not repeatedly scan every unrelated tool call. Preserve cascade behavior and optimize after the migration.
- Make keyboard-focused navigation announce destination names with tab positions and selection state in screen readers.
- Keep cached session lists on the existing activity index when status statistics are skewed, avoiding a full-list temporary sort while preserving primary-key detail reads.
- Preserve provider price precision beyond 18 decimal places in cached-history migration and exact cost arithmetic, including observed 22-place cache-write rates.
- Persist session activity ordering so metadata edits do not reorder Sessions or search results. Use the measured visible-session index, shrink the billable-day and running-job indexes, and remove unused or redundant indexes.
- Run SQLite optimization after each committed schema migration and retry failed statistics updates without undoing the migration. Repricing refreshes displayed costs from persisted projections without rescanning sessions.
- Persisted observed provider and local price history with exact per-event cost bases. Reasoning replaces completion pricing for its subset, and all matching provider rules apply in order. Price, policy, and calculation-version changes invalidate affected costs until atomic repricing completes; Usage and session rows disclose updating, unknown, and partial estimates.
- Moved post-cutover Usage reads to persisted daily projections, with atomic branch-dependent updates, dirty-cost exclusion, and bounded shadow initialization. Period filters now reload statistics and preserve their selection across navigation; custom dates use whole UTC days.
- Preserved detected project assignments beneath masks and manual overrides during rescans and migration; post-cutover mask edits remap deduplicated path contexts without rewriting usage events or daily projections.
- Added durable maintenance checkpoints, verified migration backups and disk-space checks, and a startup progress dialog with safe stop and resume. Atomic SQLite work can be interrupted without advancing its checkpoint.
- Kept newly opened normal database connections read-only while a usage migration is unfinished, including interrupted or failed attempts; only explicit maintenance connections can write until a successful retry completes.
- Supervised parser-worker failures and made cache maintenance cancellable, skipping no-op backups and removing backups from failed or cancelled repair attempts.
- Made packaged startup resolve logs, SQL, settings, and other executable-owned resources from the executable directory even when launched with another working directory.
- Streamed fixed-snapshot JSONL parsing and serialized persistence in count- and byte-bounded batches, removing redundant full-file hash reads and sharply reducing forced-scan memory use.
- Prevented duplicate viewer processes from racing database startup and migrations by holding a process-lifetime app-instance lock.
- Indexed migration 11's temporary identity tables so large existing databases avoid unindexed correlated lookups during the stable-session rewrite.
- Added bounded, cancellation-aware retries for temporarily unavailable WSL session roots while keeping Windows roots fail-fast.
- Avoided writer contention during cached pricing reads and batched changed pricing overrides into atomic transactions.
- Reworked full-text search to index canonical message and optional tool-output rows without copying conversation text into session search.
- Made conversation messages individually focusable for screen readers and labeled the virtualized message list as a conversation region.
- Exposed Open terminal and resume in each session row's More menu alongside Open terminal and fork.
- Improved window placement restore so maximized state is saved separately from restored bounds and invalid saved bounds are clamped to the current display.
- Stabilized parsed session row identity so growing JSONL files update the same row and existing duplicate snapshots collapse while retaining local metadata.
- Improved Sessions table filtering, row identity, count formatting, row actions, scan-status wording, and empty-detail guidance for clearer desktop and screen-reader use.
- Hid injected AGENTS.md instruction blocks from conversation messages, collapsed duplicated echoed user prompts, and show missing per-message token counts as unknown instead of `0 tokens`.
- Made startup cached session loading lighter and non-blocking by streaming newest-first cached rows from a background isolate, skipping list-level pricing work, batching tag reads, and keeping richer cost/token detail loading lazy per selected session.
- Moved the Sessions visible count into the header, added a cached-load progress line with a compact spinner and total count, and auto-detected project names from each session working directory while preserving manual project overrides.
- Backfilled auto-detected project names for older cached sessions, removed placeholder values from Sessions table cells, animated active load/scan status, and started a scan automatically after cached startup rows finish loading.
- Removed the Sessions title column, stopped deriving JSONL titles from first user messages, hid empty title headers in session details, and cleaned placeholder `auto` summaries plus AGENTS-instruction titles from cached metadata.
- Added a Sessions table filter that shows only the newest session per project while leaving sessions with no project ungrouped.
