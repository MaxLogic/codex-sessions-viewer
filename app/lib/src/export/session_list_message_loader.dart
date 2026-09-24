import 'dart:io';
import 'dart:isolate';

import '../database/database_connection.dart';
import '../ui/models/conversation_message_view_model.dart';
import '../utils/injected_context_filter.dart';
import 'session_list_exporter.dart';

/// Reads only the message endpoints needed by a session list export. The whole
/// request uses one SQLite connection on a worker isolate.
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
  return Isolate.run(() {
    final db = openFileBackedDatabase(File(path));
    try {
      final result = <String, List<ConversationMessageViewModel>>{};
      for (final sessionId in sessionIds) {
        final messages = <ConversationMessageViewModel>[];
        if (includeFirstMessage) {
          final first = _findEndpoint(db, sessionId, firstUser: true);
          if (first != null) messages.add(first);
        }
        if (includeLastMessage) {
          final last = _findEndpoint(db, sessionId, firstUser: false);
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

ConversationMessageViewModel? _findEndpoint(
  Database db,
  String sessionId, {
  required bool firstUser,
}) {
  int? cursor;
  while (true) {
    final rows = db.select(
      '''
      select message_index, author_type, created_at_utc,
             content_preview, content_plain
      from messages
      where session_id = ?
        ${firstUser ? "and author_type = 'user'" : ''}
        ${cursor == null ? '' : 'and message_index ${firstUser ? '>' : '<'} ?'}
      order by message_index ${firstUser ? 'asc' : 'desc'}
      limit 32
      ''',
      [sessionId, ?cursor],
    );
    if (rows.isEmpty) return null;
    for (final row in rows) {
      final body = row['content_plain'] as String? ?? '';
      final preview = row['content_preview'] as String? ?? '';
      if (row['author_type'] == 'user' &&
          isInjectedEnvironmentContextMessage(
            body.isNotEmpty ? body : preview,
          )) {
        continue;
      }
      final message = ConversationMessageViewModel(
        id: '$sessionId:${row['message_index']}',
        number: row['message_index'] as int,
        author: switch (row['author_type'] as String?) {
          'user' => ConversationAuthor.user,
          'assistant' => ConversationAuthor.assistant,
          'reasoning' => ConversationAuthor.reasoning,
          'system' => ConversationAuthor.system,
          _ => ConversationAuthor.tool,
        },
        createdAtUtc:
            DateTime.tryParse(row['created_at_utc'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        preview: preview,
        body: body,
        tokenCount: null,
      );
      if (SessionListExporter.messageContent(message) != null) return message;
    }
    if (rows.length < 32) return null;
    cursor = rows.last['message_index'] as int;
  }
}
