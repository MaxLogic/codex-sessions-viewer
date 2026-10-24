import 'package:codex_sessions_viewer/src/platform/app_environment.dart';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../database/database_connection.dart';
import '../ui/models/conversation_message_view_model.dart';
import '../utils/injected_context_filter.dart';
import 'session_list_exporter.dart';

/// Reads only the message endpoints needed by a session list export. The whole
/// request uses one read-only SQLite connection on a worker isolate; the
/// result map moves back to the caller without another copy.
Future<Map<String, List<ConversationMessageViewModel>>>
loadSessionListExportMessages(
  File databaseFile,
  List<String> sessionIds, {
  required bool includeFirstMessage,
  required bool includeLastMessage,
}) async {
  if ((!includeFirstMessage && !includeLastMessage) || sessionIds.isEmpty) {
    return const {};
  }
  final path = databaseFile.path;
  return AppEnvironment.runIsolate(() {
    final db = openSessionListExportDatabase(File(path));
    try {
      final result = <String, List<ConversationMessageViewModel>>{};
      for (final sessionId in sessionIds) {
        final messages = <ConversationMessageViewModel>[];
        if (includeFirstMessage) {
          final first = findSessionListEndpoint(db, sessionId, firstUser: true);
          if (first != null) messages.add(first);
        }
        if (includeLastMessage) {
          final last = findSessionListEndpoint(db, sessionId, firstUser: false);
          if (last != null &&
              !messages.any((message) => message.number == last.number)) {
            messages.add(last);
          }
        }
        result[sessionId] = messages;
      }
      return result;
    } finally {
      db.close();
    }
  });
}

/// Opens the export connection with writes disabled; the export only reads.
@visibleForTesting
Database openSessionListExportDatabase(File file) {
  final db = openFileBackedDatabase(file);
  try {
    db.execute('pragma query_only = on');
    return db;
  } on Object {
    db.close();
    rethrow;
  }
}

/// The text the exporter shows: the plain body, or the preview when the body
/// is blank. Evaluated in SQL so skipped rows never reach Dart.
const _exportText =
    "trim(coalesce(nullif(trim(content_plain), ''), content_preview, ''))";

/// Finds the first user prompt or latest assistant response, including
/// completion-event text. Mirrors [SessionListExporter.messageContent]. Probes
/// select only indexes and authors; a body is loaded for one candidate at a
/// time, so large skipped bodies are never copied out of SQLite.
@visibleForTesting
ConversationMessageViewModel? findSessionListEndpoint(
  Database db,
  String sessionId, {
  required bool firstUser,
  void Function(int messageIndex)? onBodyLoaded,
}) {
  const probeSize = 32;
  int? cursor;
  while (true) {
    final candidates = db.select(
      '''
      select message_index, author_type
      from messages
      where session_id = ?
        ${firstUser ? "and author_type = 'user'" : """
        and (
          author_type = 'assistant'
          or (
            author_type in ('tool', 'system')
            and case when json_valid($_exportText) then
              json_extract($_exportText, '\$.type') = 'task_complete'
              and json_type($_exportText, '\$.last_agent_message') = 'text'
              and length(trim(json_extract(
                $_exportText, '\$.last_agent_message'
              ))) > 0
            else 0 end
          )
        )
        """}
        ${cursor == null ? '' : 'and message_index ${firstUser ? '>' : '<'} ?'}
        and length($_exportText) > 0
      order by message_index ${firstUser ? 'asc' : 'desc'}
      limit $probeSize
      ''',
      [sessionId, ?cursor],
    );
    for (final candidate in candidates) {
      final index = candidate['message_index'] as int;
      onBodyLoaded?.call(index);
      final message = _loadEndpointMessage(
        db,
        sessionId,
        index,
        candidate['author_type'] as String?,
      );
      if (message != null) return message;
    }
    if (candidates.length < probeSize) return null;
    cursor = candidates.last['message_index'] as int;
  }
}

ConversationMessageViewModel? _loadEndpointMessage(
  Database db,
  String sessionId,
  int index,
  String? authorType,
) {
  final row = db
      .select(
        '''
    select created_at_utc, $_exportText as text
    from messages
    where session_id = ? and message_index = ?
    ''',
        [sessionId, index],
      )
      .firstOrNull;
  if (row == null) return null;
  final text = row['text'] as String? ?? '';
  if (authorType == 'user' && isInjectedEnvironmentContextMessage(text)) {
    return null;
  }
  final message = ConversationMessageViewModel(
    id: '$sessionId:$index',
    number: index,
    author: switch (authorType) {
      'user' => ConversationAuthor.user,
      'assistant' => ConversationAuthor.assistant,
      'reasoning' => ConversationAuthor.reasoning,
      'system' => ConversationAuthor.system,
      _ => ConversationAuthor.tool,
    },
    createdAtUtc:
        DateTime.tryParse(row['created_at_utc'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    // The exporter reads the body first; one copy of the text is enough.
    preview: '',
    body: text,
    tokenCount: null,
  );
  return SessionListExporter.messageContent(message) == null ? null : message;
}
