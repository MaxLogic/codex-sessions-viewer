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
      select origin.message_index as origin_index, tc.tool_name, tc.status,
        tc.started_at_utc, tc.input_preview, tc.output_preview
      from tool_calls tc
      left join messages origin on origin.id = tc.message_id
      where tc.session_id = ? order by tc.tool_index
      ''',
      [id],
    ))
      EvalDatasetToolCall(
        messageIndex: toolCallMessageIndex(
          messageTimes,
          originIndex: tool['origin_index'] as int?,
          startedAtUtc: _time(tool['started_at_utc'] as String?),
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

/// A tool call's exported `message_index`, with the meaning the viewer's
/// original parser gave it: the index of the next message after the message
/// that issued the call (the first message when none came before it, one
/// past the last message when none follows). [messages] are the session's
/// stored messages in `message_index` order.
///
/// The collector links each call to the message that preceded it
/// ([originIndex], from `tool_calls.message_id`). Rows stored before it did,
/// and calls that came before every message, have no link and are placed by
/// time instead: the preceding message is the highest-indexed message
/// created at or before [startedAtUtc] (a message with the same timestamp
/// issued the call), whatever the order of the other timestamps. Without a
/// start time an unlinked call has no index.
int? toolCallMessageIndex(
  List<({int index, DateTime? at})> messages, {
  int? originIndex,
  DateTime? startedAtUtc,
}) {
  var origin = originIndex;
  if (origin == null) {
    if (startedAtUtc == null) return null;
    for (final message in messages) {
      final time = message.at;
      if (time != null && !time.isAfter(startedAtUtc)) origin = message.index;
    }
    if (origin == null) return messages.isEmpty ? 0 : messages.first.index;
  }
  for (final message in messages) {
    if (message.index > origin) return message.index;
  }
  return origin + 1;
}

DateTime? _time(String? value) =>
    value == null ? null : DateTime.tryParse(value)?.toUtc();

String? _nonEmpty(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : value;
}
