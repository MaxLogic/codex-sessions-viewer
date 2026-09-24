import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import '../database/database_connection.dart';
import 'eval_dataset_exporter.dart';

/// Reads eval sessions, their messages, and tool calls from the database the
/// collector wrote, on a worker isolate. Sessions of every harness export the
/// same way; IDs that no longer exist are left out of the result.
Future<List<EvalDatasetSession>> loadEvalDatasetSessions(
  File databaseFile,
  List<String> sessionIds,
) {
  final path = databaseFile.path;
  final ids = [...sessionIds];
  return Isolate.run(() {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      db.execute('pragma busy_timeout = $defaultSqliteBusyTimeoutMs');
      // One snapshot, so a concurrent collector commit cannot mix versions.
      db.execute('begin');
      return [for (final id in ids) ?readEvalDatasetSession(db, id)];
    } finally {
      db.close();
    }
  });
}

/// One stored session as an eval source, or null when it does not exist.
EvalDatasetSession? readEvalDatasetSession(Database db, String id) {
  final rows = db.select(
    '''
    select id, session_id, title, source_type, display_path, models_used,
      model_primary, total_tokens, eval_expected_output, eval_status, eval_notes
    from sessions where id = ?
    ''',
    [id],
  );
  if (rows.isEmpty) return null;
  final row = rows.single;
  final messageRows = db.select(
    '''
    select message_index, author_type, created_at_utc, content_plain,
      content_preview
    from messages where session_id = ? order by message_index
    ''',
    [id],
  );
  final messages = [
    for (final message in messageRows)
      EvalDatasetMessage(
        index: message['message_index'] as int,
        author: evalMessageAuthor(message['author_type'] as String?),
        contentPlain:
            _nonEmpty(message['content_plain'] as String?) ??
            message['content_preview'] as String? ??
            '',
      ),
  ];
  final messageTimes = [
    for (final message in messageRows)
      (
        index: message['message_index'] as int,
        at: _time(message['created_at_utc'] as String?),
      ),
  ];
  final toolCalls = [
    for (final tool in db.select(
      '''
      select tool_name, status, started_at_utc, input_preview, output_preview
      from tool_calls where session_id = ? order by tool_index
      ''',
      [id],
    ))
      EvalDatasetToolCall(
        messageIndex: _messageAt(
          messageTimes,
          _time(tool['started_at_utc'] as String?),
        ),
        toolName: tool['tool_name'] as String? ?? '',
        status: tool['status'] as String? ?? '',
        inputPreview: tool['input_preview'] as String? ?? '',
        outputPreview: tool['output_preview'] as String? ?? '',
      ),
  ];
  final models = {
    for (final model in (row['models_used'] as String? ?? '').split('|'))
      if (model.trim().isNotEmpty) model.trim(),
    ?_nonEmpty(row['model_primary'] as String?),
  };
  return EvalDatasetSession(
    id: row['id'] as String,
    sessionId: _nonEmpty(row['session_id'] as String?),
    title: _nonEmpty(row['title'] as String?),
    sourceType: row['source_type'] as String? ?? 'windows',
    displayPath: row['display_path'] as String? ?? '',
    modelIds: models,
    totalTokens: row['total_tokens'] as int?,
    messages: messages,
    toolCalls: toolCalls,
    expectedOutput: _nonEmpty(row['eval_expected_output'] as String?),
    status: _nonEmpty(row['eval_status'] as String?),
    notes: _nonEmpty(row['eval_notes'] as String?),
  );
}

/// The last message at or before [at]; tool calls are stored without the
/// message that issued them.
int? _messageAt(List<({int index, DateTime? at})> messages, DateTime? at) {
  if (at == null) return null;
  int? found;
  for (final message in messages) {
    final time = message.at;
    if (time == null) continue;
    if (time.isAfter(at)) break;
    found = message.index;
  }
  return found;
}

DateTime? _time(String? value) =>
    value == null ? null : DateTime.tryParse(value)?.toUtc();

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : value;
}
