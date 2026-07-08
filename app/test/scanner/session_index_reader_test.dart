import 'dart:io';

import 'package:codex_sessions_viewer/src/scanner/session_index_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('reads session_index names and keeps the latest duplicate', () async {
    final temp = await Directory.systemTemp.createTemp('csv_session_index_');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });
    final file = File(p.join(temp.path, 'session_index.jsonl'));
    await file.writeAsString(
      [
        '{"id":"a","thread_name":"old","updated_at":"2026-07-07T10:00:00Z"}',
        '{"id":"a","thread_name":"dmk2","updated_at":"2026-07-08T10:00:00Z"}',
        '{"id":"b","thread_name":"Unicode <plain> zażółć","updated_at":"2026-07-08T11:00:00Z"}',
        'not json',
        '',
      ].join('\n'),
    );

    final result = await const CodexSessionIndexReader().read(file);

    expect(result.readFailed, isFalse);
    expect(result.rowsRead, 4);
    expect(result.parseFailures, 1);
    expect(result.entriesById['a']?.threadName, 'dmk2');
    expect(result.entriesById['b']?.threadName, 'Unicode <plain> zażółć');
  });

  test('missing session_index is an empty result', () async {
    final temp = await Directory.systemTemp.createTemp('csv_session_index_');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final result = await const CodexSessionIndexReader().read(
      File(p.join(temp.path, 'session_index.jsonl')),
    );

    expect(result.readFailed, isFalse);
    expect(result.rowsRead, 0);
    expect(result.entriesById, isEmpty);
  });
}
