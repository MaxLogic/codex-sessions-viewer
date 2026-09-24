import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import '../usage/session_activity.dart';
import 'database_connection.dart';

/// Activity for stored sessions, keyed by `sessions.id`, read on a worker
/// isolate from the rows the collector wrote. Missing sessions are left out.
Future<Map<String, SessionActivityStats>> loadSessionActivity(
  File databaseFile,
  List<String> sessionIds,
) {
  final path = databaseFile.path;
  final ids = [...sessionIds];
  return Isolate.run(() {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      db.execute('pragma busy_timeout = $defaultSqliteBusyTimeoutMs');
      db.execute('begin');
      return {for (final id in ids) id: ?readSessionActivity(db, id)};
    } finally {
      db.close();
    }
  });
}

/// One stored session's activity, or null when it does not exist.
SessionActivityStats? readSessionActivity(Database db, String sessionId) {
  final session = db.select('select agent_role from sessions where id = ?', [
    sessionId,
  ]);
  if (session.isEmpty) return null;
  final messages = [
    for (final row in db.select(
      '''
      select author_type, created_at_utc, model,
        -- User text decides whether a prompt is injected context.
        case when author_type = 'user'
          then coalesce(content_plain, content_preview, '') else '' end as head
      from messages where session_id = ? order by message_index
      ''',
      [sessionId],
    ))
      ActivityMessage(
        author: row['author_type'] as String? ?? '',
        createdAtUtc: _time(row['created_at_utc']),
        model: row['model'] as String?,
        content: row['head'] as String? ?? '',
      ),
  ];
  final toolCalls = [
    for (final row in db.select(
      '''
      select tool_name, status, started_at_utc, finished_at_utc, error_message,
        input_preview, substr(coalesce(output_preview, ''), 1, 20000) as output
      from tool_calls where session_id = ? order by tool_index
      ''',
      [sessionId],
    ))
      ActivityToolCall(
        name: row['tool_name'] as String? ?? 'tool',
        status: row['status'] as String? ?? '',
        startedAtUtc: _time(row['started_at_utc']),
        finishedAtUtc: _time(row['finished_at_utc']),
        errorMessage: row['error_message'] as String?,
        inputPreview: row['input_preview'] as String? ?? '',
        outputPreview: row['output'] as String? ?? '',
      ),
  ];
  final reasoning =
      db
              .select(
                '''
      select sum(reasoning_output_tokens) as tokens from usage_events
      where session_row_id = ? and branch_scope = 'local'
      ''',
                [sessionId],
              )
              .single['tokens']
          as int?;
  final role = (session.single['agent_role'] as String?)?.trim();
  return computeSessionActivity(
    messages: messages,
    toolCalls: toolCalls,
    reasoningOutputTokens: reasoning,
    agentRole: role == null || role.isEmpty ? null : role,
  );
}

DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;
