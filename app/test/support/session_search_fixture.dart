import 'package:codex_sessions_viewer/src/search/session_search.dart';
import 'package:sqlite3/sqlite3.dart';

/// Test fixtures for session rows. The collector is the only production
/// writer of sessions; tests use this to seed search and project scenarios.
extension SessionSearchFixtures on SessionSearchIndex {
  void upsert(SessionSearchDocument document) {
    // Fixtures built from early schema files lack the thread name column.
    if (!db
        .select('pragma table_info(sessions)')
        .any((row) => row['name'] == 'thread_name')) {
      db.execute('alter table sessions add column thread_name text');
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final existingState = _existingUserState(db, document.id);
    db.execute(
      '''
      insert into sessions (
        id,
        source_type,
        source_file_path,
        display_path,
        platform_path,
        scan_status,
        parse_status,
        started_at_utc,
        last_message_at_utc,
        title,
        summary,
        thread_name,
        has_code_blocks,
        has_tool_calls,
        has_errors,
        total_tokens,
        model_primary,
        models_used,
        project_name_snapshot,
        is_pinned,
        is_archived,
        created_at_utc,
        updated_at_utc
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict(id) do update set
        source_type = excluded.source_type,
        source_file_path = excluded.source_file_path,
        display_path = excluded.display_path,
        platform_path = excluded.platform_path,
        scan_status = excluded.scan_status,
        parse_status = excluded.parse_status,
        started_at_utc = excluded.started_at_utc,
        last_message_at_utc = excluded.last_message_at_utc,
        title = excluded.title,
        summary = excluded.summary,
        thread_name = excluded.thread_name,
        has_code_blocks = excluded.has_code_blocks,
        has_tool_calls = excluded.has_tool_calls,
        has_errors = excluded.has_errors,
        total_tokens = excluded.total_tokens,
        model_primary = excluded.model_primary,
        models_used = excluded.models_used,
        updated_at_utc = excluded.updated_at_utc
      ''',
      [
        document.id,
        document.sourceType.name,
        document.sourceFilePath,
        document.displayPath,
        document.platformPath,
        document.scanStatus,
        document.parseStatus,
        document.startedAtUtc?.toIso8601String(),
        document.lastMessageAtUtc?.toIso8601String(),
        document.title,
        document.summary,
        document.threadName.isEmpty ? null : document.threadName,
        document.hasCodeBlocks ? 1 : 0,
        document.hasToolCalls ? 1 : 0,
        document.hasErrors ? 1 : 0,
        document.totalTokens,
        document.modelsUsed.isEmpty ? null : document.modelsUsed.first,
        _encodeMembership(document.modelsUsed),
        document.projectName.isEmpty ? null : document.projectName,
        document.isPinned ? 1 : 0,
        document.isArchived ? 1 : 0,
        now,
        now,
      ],
    );

    db.execute('delete from session_path_keys where session_id = ?', [
      document.id,
    ]);
    for (final pathKey in document.normalizedPathKeys.split(' ')) {
      if (pathKey.trim().isEmpty) {
        continue;
      }
      db.execute(
        'insert or ignore into session_path_keys (session_id, path_key) '
        'values (?, ?)',
        [document.id, pathKey.trim()],
      );
    }

    final rowid =
        db.select('select rowid from sessions where id = ?', [
              document.id,
            ]).single['rowid']
            as int;
    final ftsProjectName = existingState?.projectName ?? document.projectName;
    final ftsTags = existingState?.tags ?? document.tags;
    db.execute('delete from session_search where rowid = ?', [rowid]);
    db.execute(
      '''
      insert into session_search (
        rowid,
        title,
        summary,
        tool_names,
        display_path,
        normalized_path_keys,
        project_name,
        tags
      ) values (?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        rowid,
        document.title,
        document.summary,
        document.toolNames,
        document.displayPath,
        document.normalizedPathKeys,
        ftsProjectName,
        ftsTags.join(' '),
      ],
    );
    if (existingState == null) {
      for (final tag in document.tags) {
        db.execute(
          'insert or ignore into tags (name, created_at_utc, updated_at_utc) '
          'values (?, ?, ?)',
          [tag, now, now],
        );
      }
      db.execute('delete from session_tags where session_id = ?', [
        document.id,
      ]);
      for (final tag in document.tags) {
        final tagId =
            db.select('select id from tags where name = ?', [tag]).single['id']
                as int;
        db.execute(
          'insert or ignore into session_tags (session_id, tag_id, created_at_utc) '
          'values (?, ?, ?)',
          [document.id, tagId, now],
        );
      }
    }
  }
}

class SessionSearchDocument {
  const SessionSearchDocument({
    required this.id,
    required this.sourceType,
    required this.sourceFilePath,
    required this.displayPath,
    required this.platformPath,
    this.title = '',
    this.summary = '',
    this.threadName = '',
    this.toolNames = '',
    this.normalizedPathKeys = '',
    this.projectName = '',
    this.tags = const [],
    this.startedAtUtc,
    this.lastMessageAtUtc,
    this.modelsUsed = const [],
    this.scanStatus = 'available',
    this.parseStatus = 'available',
    this.isPinned = false,
    this.isArchived = false,
    this.hasCodeBlocks = false,
    this.hasToolCalls = false,
    this.hasErrors = false,
    this.totalTokens,
  });

  final String id;
  final SessionSearchSourceType sourceType;
  final String sourceFilePath;
  final String displayPath;
  final String platformPath;
  final String title;
  final String summary;
  final String threadName;
  final String toolNames;
  final String normalizedPathKeys;
  final String projectName;
  final List<String> tags;
  final DateTime? startedAtUtc;
  final DateTime? lastMessageAtUtc;
  final List<String> modelsUsed;
  final String scanStatus;
  final String parseStatus;
  final bool isPinned;
  final bool isArchived;
  final bool hasCodeBlocks;
  final bool hasToolCalls;
  final bool hasErrors;
  final int? totalTokens;
}

_ExistingUserState? _existingUserState(Database db, String sessionId) {
  final rows = db.select(
    'select project_name_snapshot from sessions where id = ?',
    [sessionId],
  );
  if (rows.isEmpty) {
    return null;
  }
  final tagRows = db.select(
    '''
    select t.name
    from session_tags st
    join tags t on t.id = st.tag_id
    where st.session_id = ?
    order by t.name
    ''',
    [sessionId],
  );
  return _ExistingUserState(
    projectName: rows.single['project_name_snapshot'] as String? ?? '',
    tags: [for (final row in tagRows) row['name'] as String],
  );
}

class _ExistingUserState {
  const _ExistingUserState({required this.projectName, required this.tags});

  final String projectName;
  final List<String> tags;
}

String _encodeMembership(List<String> values) {
  if (values.isEmpty) {
    return '';
  }
  return '|${values.join('|')}|';
}
