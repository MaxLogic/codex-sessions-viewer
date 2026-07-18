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
    db.execute(
      File(
        '../sql/migration/012_external_content_search.sql',
      ).readAsStringSync(),
    );
    index = MessageSearchIndex(db);
  });

  tearDown(() {
    db.close();
  });

  test('returns snippets and target metadata with deterministic limits', () {
    _insertSession(
      db,
      id: 'recent',
      title: 'Recent session',
      threadName: 'Named recent thread',
      projectName: 'Codex Sessions Viewer',
      sourceType: 'wsl',
      startedAtUtc: '2026-07-07T09:00:00.000Z',
      lastMessageAtUtc: '2026-07-07T10:00:00.000Z',
    );
    _insertSession(
      db,
      id: 'older',
      title: 'Older session',
      projectName: 'Other Project',
      sourceType: 'windows',
      startedAtUtc: '2026-07-06T09:00:00.000Z',
      lastMessageAtUtc: '2026-07-06T10:00:00.000Z',
    );

    _insertMessage(
      db,
      sessionId: 'older',
      messageIndex: 0,
      author: 'user',
      createdAtUtc: '2026-07-06T10:00:00.000Z',
      content: 'cache needle in an older conversation',
    );
    _insertMessage(
      db,
      sessionId: 'recent',
      messageIndex: 2,
      author: 'assistant',
      createdAtUtc: '2026-07-07T10:00:00.000Z',
      content: 'The cache needle appears in the newer assistant reply.',
    );

    final results = index.search(
      const MessageSearchQuery(text: 'cache needle', limit: 1),
    );

    expect(results, hasLength(1));
    final result = results.single;
    expect(result.sessionId, 'recent');
    expect(result.messageIndex, 2);
    expect(result.author, 'assistant');
    expect(result.snippet, contains('<mark>'));
    expect(result.snippet, contains('cache'));
    expect(result.sessionIdentity, 'Named recent thread');
    expect(result.sessionTitle, 'Recent session');
    expect(result.projectName, 'Codex Sessions Viewer');
    expect(result.sourceType, 'wsl');
    expect(result.timestampUtc, DateTime.utc(2026, 7, 7, 10));
  });

  test('replaces and deletes stale rows for a session', () {
    _insertSession(db, id: 'alpha', title: 'Alpha session');

    _insertMessage(
      db,
      sessionId: 'alpha',
      messageIndex: 0,
      author: 'user',
      createdAtUtc: '2026-07-07T09:00:00.000Z',
      content: 'stale context token',
    );
    expect(index.search(const MessageSearchQuery(text: 'stale')), hasLength(1));

    db.execute('delete from messages where session_id = ?', ['alpha']);
    _insertMessage(
      db,
      sessionId: 'alpha',
      messageIndex: 1,
      author: 'assistant',
      createdAtUtc: '2026-07-07T10:00:00.000Z',
      content: 'fresh context token',
    );

    expect(index.search(const MessageSearchQuery(text: 'stale')), isEmpty);
    expect(index.search(const MessageSearchQuery(text: 'fresh')), hasLength(1));

    db.execute('delete from sessions where id = ?', ['alpha']);
    expect(index.search(const MessageSearchQuery(text: 'fresh')), isEmpty);
  });

  test('removes message search rows when a session is deleted', () {
    _insertSession(db, id: 'deleted', title: 'Deleted session');
    _insertMessage(
      db,
      sessionId: 'deleted',
      messageIndex: 0,
      author: 'user',
      createdAtUtc: '2026-07-07T09:00:00.000Z',
      content: 'delete trigger context token',
    );

    db.execute('delete from sessions where id = ?', ['deleted']);

    expect(
      index.search(const MessageSearchQuery(text: 'delete trigger')),
      isEmpty,
    );
  });

  test('searches external message content with message metadata', () {
    _insertSession(
      db,
      id: 'external',
      title: 'External content session',
      threadName: 'External thread',
      projectName: 'Search Storage',
      sourceType: 'windows',
      startedAtUtc: '2026-07-17T09:00:00.000Z',
      lastMessageAtUtc: '2026-07-17T10:00:00.000Z',
    );
    _insertMessage(
      db,
      sessionId: 'external',
      messageIndex: 3,
      author: 'assistant',
      createdAtUtc: '2026-07-17T10:00:00.000Z',
      content: 'external content needle',
    );

    final result = index
        .search(const MessageSearchQuery(text: 'external needle'))
        .single;

    expect(result.sessionId, 'external');
    expect(result.messageIndex, 3);
    expect(result.author, 'assistant');
    expect(result.snippet, contains('<mark>external</mark>'));
    expect(result.sessionIdentity, 'External thread');
    expect(result.timestampUtc, DateTime.utc(2026, 7, 17, 10));
  });
}

void _insertSession(
  Database db, {
  required String id,
  String title = '',
  String threadName = '',
  String projectName = '',
  String sourceType = 'windows',
  String startedAtUtc = '2026-07-07T09:00:00.000Z',
  String lastMessageAtUtc = '2026-07-07T09:00:00.000Z',
}) {
  db.execute(
    '''
    insert into sessions (
      id,
      source_type,
      source_file_path,
      display_path,
      platform_path,
      started_at_utc,
      last_message_at_utc,
      title,
      thread_name,
      project_name_snapshot,
      created_at_utc,
      updated_at_utc
    ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    [
      id,
      sourceType,
      '$id.jsonl',
      '$id.jsonl',
      '$id.jsonl',
      startedAtUtc,
      lastMessageAtUtc,
      title,
      threadName,
      projectName,
      startedAtUtc,
      startedAtUtc,
    ],
  );
}

void _insertMessage(
  Database db, {
  required String sessionId,
  required int messageIndex,
  required String author,
  required String createdAtUtc,
  required String content,
}) {
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
    ) values (?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    [
      sessionId,
      messageIndex,
      author,
      createdAtUtc,
      content,
      content,
      content,
      createdAtUtc,
      createdAtUtc,
    ],
  );
}
