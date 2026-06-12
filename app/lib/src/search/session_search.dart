import 'package:sqlite3/sqlite3.dart';

enum SessionSearchSourceType { windows, wsl }

enum ArchivedFilter { activeOnly, archivedOnly, all }

enum SearchTextScope {
  title,
  summary,
  userMessages,
  assistantMessages,
  toolNames,
  path,
  project,
  tags,
  toolOutput,
}

class SessionSearchIndex {
  const SessionSearchIndex(this.db);

  final Database db;

  void upsert(SessionSearchDocument document) {
    final now = DateTime.now().toUtc().toIso8601String();
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
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
        has_code_blocks = excluded.has_code_blocks,
        has_tool_calls = excluded.has_tool_calls,
        has_errors = excluded.has_errors,
        total_tokens = excluded.total_tokens,
        model_primary = excluded.model_primary,
        models_used = excluded.models_used,
        project_name_snapshot = excluded.project_name_snapshot,
        is_pinned = excluded.is_pinned,
        is_archived = excluded.is_archived,
        updated_at_utc = excluded.updated_at_utc
      ''',
      [
        document.id,
        document.sourceType.wireName,
        document.sourceFilePath,
        document.displayPath,
        document.platformPath,
        document.scanStatus,
        document.parseStatus,
        document.startedAtUtc?.toIso8601String(),
        document.lastMessageAtUtc?.toIso8601String(),
        document.title,
        document.summary,
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
    db.execute('delete from session_search where rowid = ?', [rowid]);
    db.execute(
      '''
      insert into session_search (
        rowid,
        title,
        summary,
        user_messages,
        assistant_messages,
        tool_names,
        display_path,
        normalized_path_keys,
        project_name,
        tags,
        tool_output
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        rowid,
        document.title,
        document.summary,
        document.userMessages,
        document.assistantMessages,
        document.toolNames,
        document.displayPath,
        document.normalizedPathKeys,
        document.projectName,
        document.tags.join(' '),
        document.toolOutput,
      ],
    );
    for (final tag in document.tags) {
      db.execute(
        'insert or ignore into tags (name, created_at_utc, updated_at_utc) '
        'values (?, ?, ?)',
        [tag, now, now],
      );
    }
    db.execute('delete from session_tags where session_id = ?', [document.id]);
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

  List<String> search(SessionSearchQuery query) {
    final where = <String>[];
    final args = <Object?>[];
    if (query.text.trim().isNotEmpty) {
      final textWhere = _textWhere(query);
      where.add(textWhere.sql);
      args.addAll(textWhere.args);
    }
    if (query.sourceTypes.isNotEmpty) {
      where.add(
        's.source_type in (${_placeholders(query.sourceTypes.length)})',
      );
      args.addAll(query.sourceTypes.map((source) => source.wireName));
    }
    if (query.fromUtc != null) {
      where.add('s.started_at_utc >= ?');
      args.add(query.fromUtc!.toIso8601String());
    }
    if (query.toUtc != null) {
      where.add('s.started_at_utc <= ?');
      args.add(query.toUtc!.toIso8601String());
    }
    if (query.pathPatterns.isNotEmpty) {
      where.add(
        'exists (select 1 from session_path_keys pk where pk.session_id = s.id '
        'and (${List.filled(query.pathPatterns.length, 'pk.path_key like ? escape \'~\'').join(' or ')}))',
      );
      args.addAll(query.pathPatterns.map(_pathPatternToLike));
    }
    if (query.projectNames.isNotEmpty) {
      where.add(
        's.project_name_snapshot in (${_placeholders(query.projectNames.length)})',
      );
      args.addAll(query.projectNames);
    }
    if (query.tags.isNotEmpty) {
      for (final tag in query.tags) {
        where.add(
          'exists (select 1 from session_tags st '
          'join tags t on t.id = st.tag_id '
          'where st.session_id = s.id and t.name = ?)',
        );
        args.add(tag);
      }
    }
    if (query.models.isNotEmpty) {
      for (final model in query.models) {
        where.add('s.models_used like ? escape \'~\'');
        args.add('%|${_escapeLike(model)}|%');
      }
    }
    if (query.statuses.isNotEmpty) {
      where.add(
        '(s.scan_status in (${_placeholders(query.statuses.length)}) '
        'or s.parse_status in (${_placeholders(query.statuses.length)}))',
      );
      args
        ..addAll(query.statuses)
        ..addAll(query.statuses);
    }
    if (query.pinned != null) {
      where.add('s.is_pinned = ?');
      args.add(query.pinned! ? 1 : 0);
    }
    switch (query.archived) {
      case ArchivedFilter.activeOnly:
        where.add('s.is_archived = 0');
      case ArchivedFilter.archivedOnly:
        where.add('s.is_archived = 1');
      case ArchivedFilter.all:
        break;
    }
    if (query.hasCodeBlocks != null) {
      where.add('s.has_code_blocks = ?');
      args.add(query.hasCodeBlocks! ? 1 : 0);
    }
    if (query.hasToolCalls != null) {
      where.add('s.has_tool_calls = ?');
      args.add(query.hasToolCalls! ? 1 : 0);
    }
    if (query.hasErrors != null) {
      where.add('s.has_errors = ?');
      args.add(query.hasErrors! ? 1 : 0);
    }
    if (query.minTotalTokens != null) {
      where.add('s.total_tokens >= ?');
      args.add(query.minTotalTokens);
    }
    if (query.maxTotalTokens != null) {
      where.add('s.total_tokens <= ?');
      args.add(query.maxTotalTokens);
    }

    final whereSql = where.isEmpty ? '' : 'where ${where.join(' and ')}';
    final rows = db.select('''
      select s.id
      from sessions s
      join session_search f on f.rowid = s.rowid
      $whereSql
      order by coalesce(s.last_message_at_utc, s.started_at_utc, s.updated_at_utc) desc,
               s.id asc
      ''', args);
    return [for (final row in rows) row['id'] as String];
  }

  _SqlClause _textWhere(SessionSearchQuery query) {
    final scopes = query.effectiveTextScopes;
    final columns = [for (final scope in scopes) ...scope.ftsColumns];
    final likeColumns = [for (final scope in scopes) ...scope.likeColumns];
    if (columns.isEmpty || likeColumns.isEmpty) {
      return const _SqlClause('0 = 1', []);
    }
    final tokens = _searchTokens(query.text);
    if (tokens.isEmpty) {
      return const _SqlClause('0 = 1', []);
    }
    final args = <Object?>[];
    final tokenClauses = <String>[];
    for (final token in tokens) {
      tokenClauses.add(
        '(${likeColumns.map((column) => '$column like ? escape \'~\'').join(' or ')})',
      );
      args.addAll(
        List<Object?>.filled(likeColumns.length, '%${_escapeLike(token)}%'),
      );
    }
    final matchQuery = _ftsColumnQuery(columns, tokens);
    return _SqlClause(
      '(s.rowid in (select rowid from session_search where session_search match ?) '
      'or (${tokenClauses.join(' and ')}))',
      [matchQuery, ...args],
    );
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
    this.userMessages = '',
    this.assistantMessages = '',
    this.toolNames = '',
    this.toolOutput = '',
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
  final String userMessages;
  final String assistantMessages;
  final String toolNames;
  final String toolOutput;
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

class SessionSearchQuery {
  const SessionSearchQuery({
    this.text = '',
    this.includeToolOutput = false,
    this.textScopes,
    this.sourceTypes = const {},
    this.fromUtc,
    this.toUtc,
    this.pathPatterns = const [],
    this.projectNames = const {},
    this.tags = const {},
    this.models = const {},
    this.statuses = const {},
    this.pinned,
    this.archived = ArchivedFilter.activeOnly,
    this.hasCodeBlocks,
    this.hasToolCalls,
    this.hasErrors,
    this.minTotalTokens,
    this.maxTotalTokens,
  });

  final String text;
  final bool includeToolOutput;
  final Set<SearchTextScope>? textScopes;
  final Set<SessionSearchSourceType> sourceTypes;
  final DateTime? fromUtc;
  final DateTime? toUtc;
  final List<String> pathPatterns;
  final Set<String> projectNames;
  final Set<String> tags;
  final Set<String> models;
  final Set<String> statuses;
  final bool? pinned;
  final ArchivedFilter archived;
  final bool? hasCodeBlocks;
  final bool? hasToolCalls;
  final bool? hasErrors;
  final int? minTotalTokens;
  final int? maxTotalTokens;

  Set<SearchTextScope> get effectiveTextScopes {
    final scopes =
        textScopes ??
        const {
          SearchTextScope.title,
          SearchTextScope.summary,
          SearchTextScope.userMessages,
          SearchTextScope.assistantMessages,
          SearchTextScope.toolNames,
          SearchTextScope.path,
          SearchTextScope.project,
          SearchTextScope.tags,
        };
    if (includeToolOutput) {
      return {...scopes, SearchTextScope.toolOutput};
    }
    return scopes.difference(const {SearchTextScope.toolOutput});
  }
}

class _SqlClause {
  const _SqlClause(this.sql, this.args);

  final String sql;
  final List<Object?> args;
}

extension on SessionSearchSourceType {
  String get wireName => switch (this) {
    SessionSearchSourceType.windows => 'windows',
    SessionSearchSourceType.wsl => 'wsl',
  };
}

extension on SearchTextScope {
  List<String> get ftsColumns => switch (this) {
    SearchTextScope.title => const ['title'],
    SearchTextScope.summary => const ['summary'],
    SearchTextScope.userMessages => const ['user_messages'],
    SearchTextScope.assistantMessages => const ['assistant_messages'],
    SearchTextScope.toolNames => const ['tool_names'],
    SearchTextScope.path => const ['display_path', 'normalized_path_keys'],
    SearchTextScope.project => const ['project_name'],
    SearchTextScope.tags => const ['tags'],
    SearchTextScope.toolOutput => const ['tool_output'],
  };

  List<String> get likeColumns => [
    for (final column in ftsColumns) 'f.$column',
  ];
}

String _placeholders(int count) => List.filled(count, '?').join(', ');

List<String> _searchTokens(String text) => text
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9_]+'))
    .where((token) => token.isNotEmpty)
    .toList(growable: false);

String _ftsColumnQuery(List<String> columns, List<String> tokens) {
  final columnSet = '{${columns.join(' ')}}';
  return tokens.map((token) => '$columnSet: ${_ftsToken(token)}').join(' AND ');
}

String _ftsToken(String token) => '"${token.replaceAll('"', '""')}"';

String _pathPatternToLike(String pattern) {
  final normalized = pattern.replaceAll(r'\', '/').toLowerCase();
  final buffer = StringBuffer();
  for (final codePoint in normalized.runes) {
    final char = String.fromCharCode(codePoint);
    if (char == '*') {
      buffer.write('%');
    } else {
      buffer.write(_escapeLike(char));
    }
  }
  return buffer.toString();
}

String _encodeMembership(List<String> values) {
  if (values.isEmpty) {
    return '';
  }
  return '|${values.join('|')}|';
}

String _escapeLike(String value) =>
    value.replaceAll('~', '~~').replaceAll('%', '~%').replaceAll('_', '~_');
