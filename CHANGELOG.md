# Changelog

## [Unreleased]

### Added
- Wired production session refresh to load settings, scan configured Codex roots, persist parsed sessions to SQLite, and show real Sessions rows.
- Added Sessions empty states for no supported files, filter-empty results, unreachable paths, and refresh failures.
- Added explicit Settings units and helper text for scanner, font, pricing, path, terminal, and voice-over fields.
- Added a local benchmark harness and baseline report for scanner, parser, cache skip, SQLite search, and release packaging timings.
- Added an explicit app composition boundary so production screen wiring lives in the app layer and the shell renders injected screens.
- Wired session row actions plus message, command, and detail copy buttons to callbacks or clipboard behavior.
