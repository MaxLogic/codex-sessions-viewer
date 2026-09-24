import 'package:sqlite3/sqlite3.dart';

class MessageSearchIndex {
  const MessageSearchIndex(this.db);

  final Database db;

  /// Whether `sessions.harness` exists, cached per connection.
  static final _sessionsHaveHarness = Expando<bool>('sessions.harness');
  static const _lastMessageRowIdKey =
      'message_search.backfill.last_message_rowid';
  static const _targetMessageRowIdKey =
      'message_search.backfill.target_message_rowid';
  static const _targetMessageCountKey =
      'message_search.backfill.target_message_count';
  static const _indexedMessageCountKey =
      'message_search.backfill.indexed_message_count';
  static const _updatedAtKey = 'message_search.backfill.updated_at_utc';
  static const _completedAtKey = 'message_search.backfill.completed_at_utc';

  MessageSearchBackfillResult backfillBatch({int limit = 500}) {
    if (limit <= 0) {
      return backfillStatus().toResult(indexedInBatch: 0, complete: false);
    }
    final lastRowId = _metadataInt(_lastMessageRowIdKey);
    final targetRowId = _metadataInt(_targetMessageRowIdKey);
    final targetCount = _backfillTargetCount(targetRowId);
    final insert = db.prepare(
      'insert into message_search (rowid, content_plain) values (?, ?)',
    );
    var maxRowId = lastRowId;
    var indexed = 0;
    var complete = false;
    try {
      db.execute('begin immediate');
      final rows = db.select(
        '''
        select
          id as message_rowid,
          content_plain
        from messages
        where id > ?
          and id <= ?
        order by id
        limit ?
        ''',
        [lastRowId, targetRowId, limit],
      );
      for (final row in rows) {
        final content = row['content_plain'] as String? ?? '';
        final messageRowId = row['message_rowid'] as int;
        insert.execute([messageRowId, content]);
        indexed++;
        maxRowId = messageRowId;
      }
      complete = rows.length < limit;
      final committedRowId = complete ? targetRowId : maxRowId;
      _setMetadata(_lastMessageRowIdKey, committedRowId.toString());
      final previousIndexed = _metadataInt(_indexedMessageCountKey);
      final indexedCount = complete
          ? targetCount
          : (previousIndexed + indexed).clamp(0, targetCount).toInt();
      _setMetadata(_indexedMessageCountKey, indexedCount.toString());
      if (indexed > 0) {
        _setMetadata(_updatedAtKey, DateTime.now().toUtc().toIso8601String());
      }
      if (complete) {
        _setMetadata(_completedAtKey, DateTime.now().toUtc().toIso8601String());
      }
      db.execute('commit');
    } on Object {
      db.execute('rollback');
      rethrow;
    } finally {
      insert.close();
    }
    final status = backfillStatus();
    return status.toResult(
      indexedInBatch: indexed,
      complete: complete || status.remaining == 0,
    );
  }

  MessageSearchBackfillStatus backfillStatus() {
    final lastRowId = _metadataInt(_lastMessageRowIdKey);
    final targetRowId = _metadataInt(_targetMessageRowIdKey);
    final targetCount = _backfillTargetCount(targetRowId);
    final indexed = _metadataInt(
      _indexedMessageCountKey,
    ).clamp(0, targetCount).toInt();
    return MessageSearchBackfillStatus(
      indexed: indexed,
      remaining: targetCount - indexed,
      lastMessageRowId: lastRowId,
      updatedAtUtc: _dateTime(_metadataString(_updatedAtKey)),
      completedAtUtc: _dateTime(_metadataString(_completedAtKey)),
    );
  }

  List<MessageSearchResult> search(MessageSearchQuery query) {
    final tokens = _searchTokens(query.text);
    if (tokens.isEmpty || query.limit <= 0) {
      return const [];
    }
    // Older read-only indexes predate the multi-harness schema. The schema
    // of an open connection does not change under a search, so the column
    // check runs once per connection.
    final hasHarness = _sessionsHaveHarness[db] ??= db
        .select('pragma table_info(sessions)')
        .any((row) => row['name'] == 'harness');
    final harnessExpression = hasHarness ? 's.harness' : "'codex'";
    final rows = db.select(
      '''
      select
        m.session_id as session_id,
        m.message_index as message_index,
        m.author_type as author_type,
        snippet(message_search, 0, '<mark>', '</mark>', '...', 12) as snippet,
        coalesce(
          nullif(trim(s.thread_name), ''),
          nullif(trim(s.title), ''),
          s.id
        ) as session_identity,
        coalesce(s.title, '') as session_title,
        coalesce(s.project_name_snapshot, '') as project_name,
        s.source_type as source_type,
        $harnessExpression as harness,
        coalesce(
          m.created_at_utc,
          s.last_message_at_utc,
          s.started_at_utc,
          s.updated_at_utc
        ) as timestamp_utc
      from message_search
      join messages m on m.id = message_search.rowid
      join sessions s on s.id = m.session_id
      where message_search match ?
        and s.scan_status = 'available'
        and s.parse_status = 'available'
      order by coalesce(
                 m.created_at_utc,
                 s.last_message_at_utc,
                 s.started_at_utc,
                 s.updated_at_utc
               ) desc,
               m.session_id asc,
               m.message_index asc
      limit ?
      ''',
      [_ftsQuery(tokens), query.limit],
    );
    return [
      for (final row in rows)
        MessageSearchResult(
          sessionId: row['session_id'] as String,
          messageIndex: row['message_index'] as int,
          author: row['author_type'] as String? ?? '',
          snippet: row['snippet'] as String? ?? '',
          sessionIdentity: row['session_identity'] as String? ?? '',
          sessionTitle: row['session_title'] as String? ?? '',
          projectName: row['project_name'] as String? ?? '',
          sourceType: row['source_type'] as String? ?? '',
          harness: row['harness'] as String? ?? 'codex',
          timestampUtc: _dateTime(row['timestamp_utc'] as String?),
        ),
    ];
  }

  int _metadataInt(String key) {
    final value = _metadataString(key);
    return int.tryParse(value ?? '') ?? 0;
  }

  int _backfillTargetCount(int targetRowId) {
    final stored = int.tryParse(_metadataString(_targetMessageCountKey) ?? '');
    if (stored != null && stored >= 0) {
      return stored;
    }
    final count =
        db
                .select(
                  '''
                  select count(*) as count
                  from messages
                  where id <= ?
                  ''',
                  [targetRowId],
                )
                .single['count']
            as int;
    _setMetadata(_targetMessageCountKey, count.toString());
    return count;
  }

  String? _metadataString(String key) {
    final rows = db.select('select value from app_metadata where key = ?', [
      key,
    ]);
    if (rows.isEmpty) {
      return null;
    }
    return rows.single['value'] as String?;
  }

  void _setMetadata(String key, String value) {
    db.execute(
      '''
      insert into app_metadata (key, value, updated_at_utc)
      values (?, ?, ?)
      on conflict(key) do update set
        value = excluded.value,
        updated_at_utc = excluded.updated_at_utc
      ''',
      [key, value, DateTime.now().toUtc().toIso8601String()],
    );
  }
}

class MessageSearchQuery {
  const MessageSearchQuery({required this.text, this.limit = 20});

  final String text;
  final int limit;
}

class MessageSearchResult {
  const MessageSearchResult({
    required this.sessionId,
    required this.messageIndex,
    required this.author,
    required this.snippet,
    required this.sessionIdentity,
    required this.sessionTitle,
    required this.projectName,
    required this.sourceType,
    required this.timestampUtc,
    this.harness = 'codex',
  });

  final String sessionId;
  final int messageIndex;
  final String author;
  final String snippet;
  final String sessionIdentity;
  final String sessionTitle;
  final String projectName;
  final String sourceType;
  final String harness;
  final DateTime? timestampUtc;
}

class MessageSearchBackfillStatus {
  const MessageSearchBackfillStatus({
    required this.indexed,
    required this.remaining,
    required this.lastMessageRowId,
    required this.updatedAtUtc,
    required this.completedAtUtc,
  });

  final int indexed;
  final int remaining;
  final int lastMessageRowId;
  final DateTime? updatedAtUtc;
  final DateTime? completedAtUtc;

  MessageSearchBackfillResult toResult({
    required int indexedInBatch,
    required bool complete,
    bool cancelled = false,
  }) => MessageSearchBackfillResult(
    indexed: indexed,
    remaining: remaining,
    lastMessageRowId: lastMessageRowId,
    indexedInBatch: indexedInBatch,
    complete: complete,
    cancelled: cancelled,
  );
}

class MessageSearchBackfillResult {
  const MessageSearchBackfillResult({
    required this.indexed,
    required this.remaining,
    required this.lastMessageRowId,
    required this.indexedInBatch,
    required this.complete,
    this.cancelled = false,
  });

  final int indexed;
  final int remaining;
  final int lastMessageRowId;
  final int indexedInBatch;
  final bool complete;
  final bool cancelled;
}

List<String> _searchTokens(String text) => text
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9_]+'))
    .where((token) => token.isNotEmpty)
    .toList(growable: false);

String _ftsQuery(List<String> tokens) =>
    tokens.map((token) => '"${token.replaceAll('"', '""')}"').join(' AND ');

DateTime? _dateTime(String? value) {
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  return DateTime.tryParse(value)?.toUtc();
}
