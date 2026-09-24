import 'dart:io';

import 'package:codex_sessions_viewer/src/ui/models/session_row_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/session_stats_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory temp;
  late File databaseFile;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('csv_stats_cache_');
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
      db.execute('''
        insert into sessions (id, harness, source_type, source_file_path,
          display_path, platform_path, created_at_utc, updated_at_utc)
        values ('s', 'codex', 'windows', 'C:/s.jsonl', 'C:/s.jsonl',
          'C:/s.jsonl', 'now', 'now');
        insert into messages (session_id, message_index, author_type,
          created_at_utc, content_plain, content_preview, created_at_db_utc,
          updated_at_db_utc)
        values ('s', 0, 'user', '2026-09-24T10:00:00Z', 'Go.', 'Go.', 'now',
          'now');
        insert into tool_calls (session_id, tool_index, tool_name, status,
          started_at_utc, finished_at_utc)
        values ('s', 0, 'shell', 'finished', '2026-09-24T10:00:01Z',
          '2026-09-24T10:00:02Z');
      ''');
    } finally {
      db.close();
    }
  });

  tearDown(() => temp.deleteSync(recursive: true));

  SessionRowViewModel row({required int toolCallCount}) => SessionRowViewModel(
    id: 's',
    startedAtUtc: DateTime.utc(2026, 9, 24, 10),
    lastMessageAtUtc: DateTime.utc(2026, 9, 24, 10),
    platform: SessionRowPlatform.windows,
    project: 'p',
    path: 'C:/s.jsonl',
    title: 't',
    summary: '',
    messageCount: 1,
    totalTokens: 0,
    model: '',
    tags: const [],
    status: 'Available',
    toolCallCount: toolCallCount,
  );

  test('a reparse that keeps the last message time reloads activity', () async {
    final load = storedSessionActivityLoader(databaseFile);
    final before = await load(row(toolCallCount: 1), const []);
    expect(before.main?.toolCallCount, 1);

    // The collector reparsed the file: one more tool call, same last message.
    final db = sqlite3.open(databaseFile.path);
    try {
      db.execute('''
        insert into tool_calls (session_id, tool_index, tool_name, status,
          started_at_utc, finished_at_utc)
        values ('s', 1, 'shell', 'finished', '2026-09-24T10:00:03Z',
          '2026-09-24T10:00:04Z')
      ''');
    } finally {
      db.close();
    }
    final after = await load(row(toolCallCount: 2), const []);
    expect(after.main?.toolCallCount, 2);
  });
}
