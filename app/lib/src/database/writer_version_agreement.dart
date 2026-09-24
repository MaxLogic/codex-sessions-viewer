import 'package:sqlite3/sqlite3.dart';

import '../parser/codex_session_parser.dart';
import '../usage/usage_summary.dart';

/// Publish the owning viewer's algorithm pair under the same SQLite write lock
/// the collector takes before every batch. Neither key is visible in isolation.
void recordViewerWriterVersions(Database db) {
  final now = DateTime.now().toUtc().toIso8601String();
  db.execute('begin immediate');
  try {
    for (final entry in {
      'writer_codex_parser_version': CodexSessionParser.currentVersion,
      'writer_usage_cost_projection_version': usageCostProjectionVersion,
    }.entries) {
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
