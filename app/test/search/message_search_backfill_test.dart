import 'dart:io';

import 'package:codex_sessions_viewer/src/search/message_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late MessageSearchIndex index;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute(File('../sql/init/001_initial_schema.sql').readAsStringSync());
    db.execute(
      File('../sql/migration/007_session_thread_name.sql').readAsStringSync(),
    );
    db.execute(
      File('../sql/migration/009_message_search.sql').readAsStringSync(),
    );
    index = MessageSearchIndex(db);
    _insertSession(db, 'backfill-session');
  });

  tearDown(() {
    db.close();
  });

  test('indexes old rows in batches and resumes without duplicates', () {
    _insertMessage(db, 0, 'first historical needle');
    _insertMessage(db, 1, 'second historical needle');
    _insertMessage(db, 2, 'third historical needle');

    final first = index.backfillBatch(limit: 2);

    expect(first.indexedInBatch, 2);
    expect(first.remaining, 1);
    expect(
      index.search(const MessageSearchQuery(text: 'historical')),
      hasLength(2),
    );

    final second = index.backfillBatch(limit: 2);
    final third = index.backfillBatch(limit: 2);

    expect(second.indexedInBatch, 1);
    expect(second.remaining, 0);
    expect(third.indexedInBatch, 0);
    expect(third.complete, isTrue);
    expect(
      index.search(const MessageSearchQuery(text: 'historical')),
      hasLength(3),
    );

    index.backfillBatch(limit: 10);

    expect(
      index.search(const MessageSearchQuery(text: 'historical')),
      hasLength(3),
    );
    expect(index.backfillStatus().remaining, 0);
  });
}

void _insertSession(Database db, String id) {
  db.execute(
    '''
    insert into sessions (
      id,
      source_type,
      source_file_path,
      display_path,
      platform_path,
      title,
      scan_status,
      parse_status,
      created_at_utc,
      updated_at_utc
    ) values (?, 'windows', ?, ?, ?, 'Backfill session', 'available',
      'available', '2026-07-08T10:00:00.000Z', '2026-07-08T10:00:00.000Z')
    ''',
    [id, '$id.jsonl', '$id.jsonl', '$id.jsonl'],
  );
}

void _insertMessage(Database db, int index, String content) {
  db.execute(
    '''
    insert into messages (
      session_id,
      message_index,
      author_type,
      created_at_utc,
      first_line,
      content_plain,
      content_preview,
      created_at_db_utc,
      updated_at_db_utc
    ) values (
      'backfill-session',
      ?,
      'user',
      '2026-07-08T10:00:00.000Z',
      ?,
      ?,
      ?,
      '2026-07-08T10:00:00.000Z',
      '2026-07-08T10:00:00.000Z'
    )
    ''',
    [index, content, content, content],
  );
}
