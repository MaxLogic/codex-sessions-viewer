import 'package:codex_sessions_viewer/src/platform/app_environment.dart';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../usage/session_activity.dart';
import '../utils/injected_context_filter.dart';
import 'database_connection.dart';

/// Activity for stored sessions, keyed by `sessions.id`, read on a worker
/// isolate from the rows the collector wrote. Missing sessions are left out.
Future<Map<String, SessionActivityStats>> loadSessionActivity(
  File databaseFile,
  List<String> sessionIds,
) {
  final path = databaseFile.path;
  final ids = [...sessionIds];
  return AppEnvironment.runIsolate(() {
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
  _registerActivityFunctions(db);
  // Message text and tool output stay in SQLite: the query returns only the
  // injected-context and failure flags. The `instr` guards skip the Dart
  // callback for text that cannot match, so a long session's content never
  // accumulates in the isolate.
  final messages = [
    for (final row in db.select(
      '''
      select author_type, created_at_utc, model,
        case when author_type = 'user'
          and (instr(coalesce(content_plain, content_preview, ''), '<environment_context>') > 0
            or instr(lower(coalesce(content_plain, content_preview, '')), '# agents.md instructions') > 0)
          then csv_activity_injected_context(coalesce(content_plain, content_preview, ''))
          else 0 end as injected
      from messages where session_id = ? order by message_index
      ''',
      [sessionId],
    ))
      ActivityMessage(
        author: row['author_type'] as String? ?? '',
        createdAtUtc: _time(row['created_at_utc']),
        model: row['model'] as String?,
        injectedContext: row['injected'] == 1,
      ),
  ];
  final toolCalls = [
    for (final row in db.select(
      '''
      select tool_name, status, started_at_utc, finished_at_utc, error_message,
        input_preview,
        case when instr(output, 'exit_code') > 0 or instr(output, 'Exit code: ') > 0
            or instr(output, 'Script failed') > 0
          then csv_activity_output_failed(output) else 0 end as output_failed
      from (
        select *, substr(coalesce(output_preview, ''), 1, 20000) as output
        from tool_calls where session_id = ?
      ) order by tool_index
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
        outputSignalsFailure: row['output_failed'] == 1,
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

final _registered = Expando<bool>('activity functions');

/// The Dart predicates the activity queries call on stored text.
void _registerActivityFunctions(Database db) {
  if (_registered[db] ?? false) return;
  db.createFunction(
    functionName: 'csv_activity_injected_context',
    argumentCount: const AllowedArgumentCount(1),
    deterministic: true,
    function: (args) =>
        isInjectedEnvironmentContextMessage(args.single as String? ?? '')
        ? 1
        : 0,
  );
  db.createFunction(
    functionName: 'csv_activity_output_failed',
    argumentCount: const AllowedArgumentCount(1),
    deterministic: true,
    function: (args) =>
        toolOutputSignalsFailure(args.single as String? ?? '') ? 1 : 0,
  );
  _registered[db] = true;
}

DateTime? _time(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;
