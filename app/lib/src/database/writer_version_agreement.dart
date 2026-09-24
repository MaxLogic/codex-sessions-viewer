import 'package:sqlite3/sqlite3.dart';

import '../usage/usage_summary.dart';
import 'collector_versions.dart';

/// The algorithm versions the owning viewer publishes for collectors, keyed
/// like `collector/src/store/schema.rs`. A collector refuses every write
/// unless the cost projection version agrees, and a session write unless the
/// parser version for that session's harness agrees.
const viewerWriterVersions = {
  'writer_codex_parser_version': collectorCodexParserVersion,
  'writer_claude_parser_version': collectorClaudeParserVersion,
  'writer_usage_cost_projection_version': usageCostProjectionVersion,
};

/// Publish the owning viewer's versions under the same SQLite write lock the
/// collector takes before every batch. No key is visible in isolation.
void recordViewerWriterVersions(Database db) {
  final now = DateTime.now().toUtc().toIso8601String();
  db.execute('begin immediate');
  try {
    for (final entry in viewerWriterVersions.entries) {
      db.execute(
        '''
        insert into app_metadata(key, value, updated_at_utc) values (?, ?, ?)
        on conflict(key) do update set value = excluded.value,
          updated_at_utc = excluded.updated_at_utc
      ''',
        [entry.key, entry.value.toString(), now],
      );
    }
    db.execute('commit');
  } catch (_) {
    db.execute('rollback');
    rethrow;
  }
}
