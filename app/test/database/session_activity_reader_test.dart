import 'dart:io';

import 'package:codex_sessions_viewer/src/database/session_activity_reader.dart';
import 'package:codex_sessions_viewer/src/usage/session_activity.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory temp;
  late Database db;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('csv_activity_reader_');
    db = sqlite3.open('${temp.path}/viewer.sqlite');
    final scripts =
        [
          ...Directory('../sql/init').listSync().whereType<File>(),
          ...Directory('../sql/migration').listSync().whereType<File>(),
        ].where((file) => file.path.endsWith('.sql')).toList()..sort(
          (a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
        );
    for (final script in scripts) {
      db.execute(script.readAsStringSync());
    }
  });

  tearDown(() {
    db.close();
    temp.deleteSync(recursive: true);
  });

  test('the reader flags stored text in SQL with the Dart predicates', () {
    final padding = 'x' * 50000;
    final messages = <(String, String?, String?)>[
      ('user', 'Fix the build.', null),
      // Injected context whose deciding tag sits far from either end.
      (
        'user',
        '<environment_context>$padding<cwd>C:\\p</cwd>$padding'
            '</environment_context>',
        null,
      ),
      (
        'user',
        '  # AGENTS.md instructions\n<instructions>$padding</instructions>',
        null,
      ),
      // Looks injected but is not: the closing tag is missing.
      ('user', '<environment_context><cwd>C:\\p</cwd>', null),
      // Only the preview was stored.
      ('user', null, '<environment_context><cwd>x</cwd></environment_context>'),
      (
        'assistant',
        '<environment_context><cwd>x</cwd></environment_context>',
        null,
      ),
      ('user', 'Next task.', null),
    ];
    final outputs = <String>[
      'ok',
      'Exit code: 1',
      '${'y' * 15000}Exit code: 2',
      // Beyond the scanned prefix: not a failure.
      '${'y' * 25000}Exit code: 3',
      '{"exit_code": 0}',
      r'{\"exit_code\": 4}',
      'Script failed',
    ];
    db.execute('''
      insert into sessions (id, harness, source_type, source_file_path,
        display_path, platform_path, created_at_utc, updated_at_utc)
      values ('s', 'codex', 'windows', 'C:/s.jsonl', 'C:/s.jsonl',
        'C:/s.jsonl', 'now', 'now')
    ''');
    final start = DateTime.utc(2026, 9, 24, 10);
    DateTime at(int minute) => start.add(Duration(minutes: minute));
    for (var index = 0; index < messages.length; index++) {
      final (author, plain, preview) = messages[index];
      db.execute(
        '''
        insert into messages (session_id, message_index, author_type,
          created_at_utc, content_plain, content_preview, created_at_db_utc,
          updated_at_db_utc)
        values ('s', ?, ?, ?, ?, ?, 'now', 'now')
        ''',
        [index, author, at(index * 10).toIso8601String(), plain, preview ?? ''],
      );
    }
    for (var index = 0; index < outputs.length; index++) {
      db.execute(
        '''
        insert into tool_calls (session_id, tool_index, tool_name, status,
          started_at_utc, finished_at_utc, output_preview)
        values ('s', ?, 'shell', 'finished', ?, ?, ?)
        ''',
        [
          index,
          at(index * 10 + 1).toIso8601String(),
          at(index * 10 + 2).toIso8601String(),
          outputs[index],
        ],
      );
    }

    final stored = readSessionActivity(db, 's')!;
    // The reference: the same computation over the full text in Dart.
    final expected = computeSessionActivity(
      messages: [
        for (var index = 0; index < messages.length; index++)
          ActivityMessage(
            author: messages[index].$1,
            createdAtUtc: at(index * 10),
            content: messages[index].$2 ?? messages[index].$3 ?? '',
          ),
      ],
      toolCalls: [
        for (var index = 0; index < outputs.length; index++)
          ActivityToolCall(
            name: 'shell',
            status: 'finished',
            startedAtUtc: at(index * 10 + 1),
            finishedAtUtc: at(index * 10 + 2),
            outputPreview: outputs[index],
          ),
      ],
    );
    expect(expected.turnCount, 3);
    expect(expected.failedToolCallCount, 4);
    expect(stored.turnCount, expected.turnCount);
    expect(stored.failedToolCallCount, expected.failedToolCallCount);
    expect(stored.toolCallCount, expected.toolCallCount);
    expect(stored.activeTime, expected.activeTime);
    expect(stored.toolTime, expected.toolTime);
    expect(stored.span, expected.span);
  });
}
