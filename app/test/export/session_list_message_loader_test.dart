import 'dart:io';

import 'package:codex_sessions_viewer/src/export/session_list_message_loader.dart';
import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('loads only meaningful first user and last message bodies', () async {
    final directory = await Directory.systemTemp.createTemp('list-export-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/sessions.sqlite');
    final db = sqlite3.open(file.path);
    try {
      db.execute('''
        create table messages (
          session_id text not null,
          message_index integer not null,
          author_type text not null,
          created_at_utc text,
          content_preview text,
          content_plain text,
          unique (session_id, message_index)
        )
      ''');
      void add(String session, int index, String author, String body) {
        db.execute('insert into messages values (?, ?, ?, ?, ?, ?)', [
          session,
          index,
          author,
          '2026-09-23T10:00:00Z',
          'preview',
          body,
        ]);
      }

      add(
        'one',
        0,
        'user',
        '<environment_context><current_date>today</current_date>'
            '</environment_context>',
      );
      add('one', 1, 'user', 'First prompt in full.');
      add('one', 2, 'assistant', 'Earlier response.');
      add(
        'one',
        3,
        'tool',
        '{"type":"task_complete","last_agent_message":"Final answer."}',
      );
      for (var index = 4; index < 45; index++) {
        add('one', index, 'tool', '{"type":"token_count"}');
      }
      add('two', 1, 'assistant', 'No user prompt.');
    } finally {
      db.close();
    }

    final result = await loadSessionListExportMessages(
      file,
      ['one', 'two', 'missing'],
      includeFirstMessage: true,
      includeLastMessage: true,
    );

    expect(result['one']!.map((message) => message.number), [1, 3]);
    expect(result['one']!.first.body, 'First prompt in full.');
    expect(result['one']!.last.author, ConversationAuthor.tool);
    expect(result['two']!.map((message) => message.number), [1]);
    expect(result['missing'], isEmpty);

    final lastOnly = await loadSessionListExportMessages(
      file,
      ['one'],
      includeFirstMessage: false,
      includeLastMessage: true,
    );
    expect(lastOnly['one']!.map((message) => message.number), [3]);
  });
}
