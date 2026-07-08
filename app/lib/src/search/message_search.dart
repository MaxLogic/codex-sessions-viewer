import 'package:sqlite3/sqlite3.dart';

class MessageSearchIndex {
  const MessageSearchIndex(this.db);

  final Database db;
  static const _lastMessageRowIdKey =
      'message_search.backfill.last_message_rowid';
  static const _updatedAtKey = 'message_search.backfill.updated_at_utc';
  static const _completedAtKey = 'message_search.backfill.completed_at_utc';

  void replaceSessionMessages(
    String sessionId,
    Iterable<MessageSearchDocument> documents,
  ) {
    deleteSession(sessionId);
    final insert = db.prepare('''
      insert into message_search (
        session_id,
        message_index,
        author_type,
        created_at_utc,
        content
      ) values (?, ?, ?, ?, ?)
      ''');
    try {
      for (final document in documents) {
        final content = document.content.trim();
        if (content.isEmpty) {
          continue;
        }
        insert.execute([
          document.sessionId,
          document.messageIndex,
          document.author,
          document.createdAtUtc?.toIso8601String(),
          content,
        ]);
      }
    } finally {
      insert.close();
    }
  }

  void deleteSession(String sessionId) {
    db.execute('delete from message_search where session_id = ?', [sessionId]);
  }

  MessageSearchBackfillResult backfillBatch({int limit = 500}) {
    if (limit <= 0) {
      return backfillStatus().toResult(indexedInBatch: 0, complete: false);
    }
    final lastRowId = _metadataInt(_lastMessageRowIdKey);
    final insert = db.prepare('''
      insert into message_search (
        session_id,
        message_index,
        author_type,
        created_at_utc,
        content
      ) values (?, ?, ?, ?, ?)
      ''');
    var maxRowId = lastRowId;
    var indexed = 0;
    var complete = false;
    try {
      db.execute('begin immediate');
      final rows = db.select(
        '''
        select
          rowid as message_rowid,
          session_id,
          message_index,
          author_type,
          created_at_utc,
          content_plain
        from messages
        where rowid > ?
          and trim(coalesce(content_plain, '')) <> ''
        order by rowid
        limit ?
        ''',
        [lastRowId, limit],
      );
      if (rows.isEmpty) {
        _setMetadata(_completedAtKey, DateTime.now().toUtc().toIso8601String());
        complete = true;
      }
      for (final row in rows) {
        final content = (row['content_plain'] as String? ?? '').trim();
        if (content.isEmpty) {
          continue;
        }
        final sessionId = row['session_id'] as String;
        final messageIndex = row['message_index'] as int;
        db.execute(
          'delete from message_search where session_id = ? and message_index = ?',
          [sessionId, messageIndex],
        );
        insert.execute([
          sessionId,
          messageIndex,
          row['author_type'] as String? ?? '',
          row['created_at_utc'] as String?,
          content,
        ]);
        indexed++;
        maxRowId = row['message_rowid'] as int;
      }
      if (rows.isNotEmpty) {
        _setMetadata(_lastMessageRowIdKey, maxRowId.toString());
        _setMetadata(_updatedAtKey, DateTime.now().toUtc().toIso8601String());
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
    final indexed =
        db
                .select('select count(*) as count from message_search')
                .single['count']
            as int;
    final remaining =
        db
                .select(
                  '''
          select count(*) as count
          from messages
          where rowid > ?
            and trim(coalesce(content_plain, '')) <> ''
          ''',
                  [lastRowId],
                )
                .single['count']
            as int;
    return MessageSearchBackfillStatus(
      indexed: indexed,
      remaining: remaining,
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
    final rows = db.select(
      '''
      select
        message_search.session_id as session_id,
        cast(message_search.message_index as integer) as message_index,
        message_search.author_type as author_type,
        snippet(message_search, 4, '<mark>', '</mark>', '...', 12) as snippet,
        coalesce(
          nullif(trim(s.thread_name), ''),
          nullif(trim(s.title), ''),
          s.id
        ) as session_identity,
        coalesce(s.title, '') as session_title,
        coalesce(s.project_name_snapshot, '') as project_name,
        s.source_type as source_type,
        coalesce(
          message_search.created_at_utc,
          s.last_message_at_utc,
          s.started_at_utc,
          s.updated_at_utc
        ) as timestamp_utc
      from message_search
      join sessions s on s.id = message_search.session_id
      where message_search match ?
        and s.scan_status = 'available'
        and s.parse_status = 'available'
      order by coalesce(
                 message_search.created_at_utc,
                 s.last_message_at_utc,
                 s.started_at_utc,
                 s.updated_at_utc
               ) desc,
               message_search.session_id asc,
               cast(message_search.message_index as integer) asc
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
          timestampUtc: _dateTime(row['timestamp_utc'] as String?),
        ),
    ];
  }

  int _metadataInt(String key) {
    final value = _metadataString(key);
    return int.tryParse(value ?? '') ?? 0;
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

class MessageSearchDocument {
  const MessageSearchDocument({
    required this.sessionId,
    required this.messageIndex,
    required this.author,
    required this.createdAtUtc,
    required this.content,
  });

  final String sessionId;
  final int messageIndex;
  final String author;
  final DateTime? createdAtUtc;
  final String content;
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
  });

  final String sessionId;
  final int messageIndex;
  final String author;
  final String snippet;
  final String sessionIdentity;
  final String sessionTitle;
  final String projectName;
  final String sourceType;
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
