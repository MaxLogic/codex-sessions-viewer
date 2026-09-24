/// Versions and keys the viewer shares with the Rust collector, which owns
/// every session parser. `test/database/writer_version_agreement_test.dart`
/// proves each value equals the collector's constant.
library;

/// `PARSER_VERSION` in `collector/src/codex/parser.rs`.
const collectorCodexParserVersion = 5;

/// `CLAUDE_PARSER_VERSION` in `collector/src/claude/parser.rs`.
const collectorClaudeParserVersion = 1;

/// `COMPLETION_KEY` in `collector/src/store/cache_repair.rs`: the collector
/// records it once the legacy session cache repair has run.
const sessionCacheRepairCompletionKey = 'session_cache_repair.v3.completed';

/// SQL for the parser version this viewer agrees on for the harness of the
/// session row [alias]. The Codex version is bound as its single `?`
/// parameter; harnesses the viewer does not version always match.
String agreedParserVersionSql(String alias) =>
    "(case $alias.harness when 'codex' then ? "
    "when 'claude' then $collectorClaudeParserVersion "
    'else $alias.parser_version end)';
