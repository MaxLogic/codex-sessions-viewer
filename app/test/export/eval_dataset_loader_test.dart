import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/export/eval_dataset_exporter.dart';
import 'package:codex_sessions_viewer/src/export/eval_dataset_loader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory temp;
  late File databaseFile;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('csv_eval_loader_');
    databaseFile = File('${temp.path}/viewer.sqlite');
    final db = sqlite3.open(databaseFile.path);
    try {
      final scripts =
          [
            ...Directory('../sql/init').listSync().whereType<File>(),
            ...Directory('../sql/migration').listSync().whereType<File>(),
          ].where((file) => file.path.endsWith('.sql')).toList()..sort(
            (a, b) =>
                a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
          );
      for (final script in scripts) {
        db.execute(script.readAsStringSync());
      }
      // A Claude session whose transcript no longer exists on disk: the
      // export reads only what the collector stored.
      db.execute('''
        insert into sessions (id, session_id, harness, source_type,
          source_file_path, display_path, platform_path, title, models_used,
          total_tokens, eval_expected_output, eval_status, eval_notes,
          created_at_utc, updated_at_utc)
        values ('claude:session:c1', 'c1', 'claude', 'windows',
          'C:\\gone\\c1.jsonl', 'C:\\gone\\c1.jsonl', 'C:\\gone\\c1.jsonl',
          'Claude task', '|claude-sonnet-4|', 40, 'Use a cache.',
          'needs_review', 'From the database', 'now', 'now');
        insert into messages (session_id, message_index, author_type,
          created_at_utc, content_plain, content_preview,
          created_at_db_utc, updated_at_db_utc)
        values
          ('claude:session:c1', 0, 'user', '2026-09-24T10:00:00Z',
            'How do I cache this?', 'How do I', 'now', 'now'),
          ('claude:session:c1', 1, 'assistant', '2026-09-24T10:00:05Z',
            'Add a cache.', 'Add a cache.', 'now', 'now'),
          ('claude:session:c1', 2, 'assistant', '2026-09-24T10:01:00Z',
            null, 'Done caching.', 'now', 'now');
        insert into tool_calls (session_id, tool_index, tool_name, status,
          started_at_utc, input_preview, output_preview)
        values ('claude:session:c1', 0, 'Bash', 'success',
          '2026-09-24T10:00:30Z', 'ls', 'cache.dart');
      ''');
    } finally {
      db.close();
    }
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('eval sessions come from stored messages and tool calls', () async {
    final sessions = await loadEvalDatasetSessions(databaseFile, [
      'claude:session:c1',
      'missing',
    ]);
    expect(sessions, hasLength(1));
    final session = sessions.single;
    expect(session.sessionId, 'c1');
    expect(session.modelIds, {'claude-sonnet-4'});
    expect(session.messages.map((message) => message.author), [
      EvalMessageAuthor.user,
      EvalMessageAuthor.assistant,
      EvalMessageAuthor.assistant,
    ]);
    // A message without stored plain text falls back to its preview.
    expect(session.messages.last.contentPlain, 'Done caching.');
    // An unlinked (older) row places the call by time: it started after
    // message 1, so it belongs before message 2.
    expect(session.toolCalls.single.messageIndex, 2);

    final files = const EvalDatasetExporter().export(
      EvalDatasetExportRequest(
        sessions: sessions,
        format: EvalDatasetFormat.deepEvalJson,
        turnMode: EvalTurnMode.finalAssistantAnswer,
        options: const EvalDatasetExportOptions(includeToolCalls: true),
      ),
    );
    final entry =
        ((jsonDecode(files['deepeval.json']!)
                        as Map<String, Object?>)['test_cases']
                    as List<Object?>)
                .single
            as Map<String, Object?>;
    expect(entry['input'], 'How do I cache this?');
    expect(entry['actual_output'], 'Done caching.');
    expect(entry['expected_output'], 'Use a cache.');
    final metadata = entry['metadata'] as Map<String, Object?>;
    expect(metadata['eval_status'], 'needs_review');
    expect(metadata['total_tokens'], 40);
    expect((entry['tool_calls'] as List<Object?>).single, {
      'message_index': 2,
      'tool_name': 'Bash',
      'status': 'success',
      'input': 'ls',
      'output_preview': 'cache.dart',
    });
  });

  group('tool call message_index', () {
    /// A session with messages at [times] (null: no timestamp) and one tool
    /// call; returns the exported message_index.
    Future<int?> messageIndexFor({
      required List<String?> times,
      String? startedAt,
      int? linkedMessageIndex,
    }) async {
      final db = sqlite3.open(databaseFile.path);
      try {
        db.execute(r'''
          insert into sessions (id, harness, source_type, source_file_path,
            display_path, platform_path, created_at_utc, updated_at_utc)
          values ('s', 'codex', 'windows', 'C:\s.jsonl', 'C:\s.jsonl',
            'C:\s.jsonl', 'now', 'now')
        ''');
        for (var index = 0; index < times.length; index++) {
          db.execute(
            '''
            insert into messages (session_id, message_index, author_type,
              created_at_utc, content_plain, content_preview,
              created_at_db_utc, updated_at_db_utc)
            values ('s', ?, 'assistant', ?, 'm', 'm', 'now', 'now')
            ''',
            [index, times[index]],
          );
        }
        final linked = linkedMessageIndex == null
            ? null
            : db.select(
                    "select id from messages where session_id = 's' and message_index = ?",
                    [linkedMessageIndex],
                  ).single['id']
                  as int;
        db.execute(
          '''
          insert into tool_calls (session_id, message_id, tool_index,
            tool_name, status, started_at_utc)
          values ('s', ?, 0, 'shell', 'finished', ?)
          ''',
          [linked, startedAt],
        );
      } finally {
        db.close();
      }
      final sessions = await loadEvalDatasetSessions(databaseFile, ['s']);
      return sessions.single.toolCalls.single.messageIndex;
    }

    test('a linked call belongs before the message after its origin', () async {
      // Timestamps do not matter once the collector linked the call.
      expect(
        await messageIndexFor(
          times: ['2026-09-24T10:00:00Z', '2026-09-24T09:00:00Z', null],
          linkedMessageIndex: 0,
        ),
        1,
      );
    });

    test('a linked call after the last message points one past it', () async {
      expect(
        await messageIndexFor(
          times: ['2026-09-24T10:00:00Z'],
          linkedMessageIndex: 0,
        ),
        1,
      );
    });

    test('a message with the same timestamp issued the call', () async {
      expect(
        await messageIndexFor(
          times: [
            '2026-09-24T10:00:00Z',
            '2026-09-24T10:00:05Z',
            '2026-09-24T10:01:00Z',
          ],
          startedAt: '2026-09-24T10:00:05Z',
        ),
        2,
      );
    });

    test('an unlinked call without a start time has no index', () async {
      expect(await messageIndexFor(times: ['2026-09-24T10:00:00Z']), isNull);
    });

    test('out-of-order timestamps pick the last earlier message', () async {
      expect(
        await messageIndexFor(
          times: [
            '2026-09-24T10:00:00Z',
            '2026-09-24T09:00:00Z',
            null,
            '2026-09-24T11:00:00Z',
          ],
          startedAt: '2026-09-24T10:30:00Z',
        ),
        2,
      );
    });

    test('a call before every message belongs to the first one', () async {
      expect(
        await messageIndexFor(
          times: ['2026-09-24T10:00:00Z', '2026-09-24T10:01:00Z'],
          startedAt: '2026-09-24T09:00:00Z',
        ),
        0,
      );
    });
  });
}
