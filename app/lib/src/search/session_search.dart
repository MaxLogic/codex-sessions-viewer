import 'package:sqlite3/sqlite3.dart';

enum SessionSearchSourceType { windows, wsl, macos, linux }

enum ArchivedFilter { activeOnly, archivedOnly, all }

class ToolOutputSearchIndex {
  const ToolOutputSearchIndex(this.db);

  final Database db;

  void configure({required bool enabled}) {
    final rows = db.select(
      "select value from app_metadata where key = 'tool_output_search.enabled'",
    );
    final currentlyEnabled =
        rows.isNotEmpty && (rows.single['value'] as String? ?? '') == '1';
    if (currentlyEnabled == enabled) {
      return;
    }
    db.execute('begin immediate');
    try {
      db.execute(
        '''
        insert into app_metadata (key, value, updated_at_utc)
        values ('tool_output_search.enabled', ?, ?)
        on conflict(key) do update set
          value = excluded.value,
          updated_at_utc = excluded.updated_at_utc
        ''',
        [enabled ? '1' : '0', DateTime.now().toUtc().toIso8601String()],
      );
      db.execute(
        enabled
            ? "insert into tool_output_search(tool_output_search) values('rebuild')"
            : "insert into tool_output_search(tool_output_search) values('delete-all')",
      );
      db.execute('commit');
    } on Object {
      db.execute('rollback');
      rethrow;
    }
  }
}

enum SearchTextScope {
  title,
  summary,
  userMessages,
  assistantMessages,
  toolNames,
  path,
  project,
  threadName,
  tags,
  toolOutput,
}

class SessionSearchIndex {
  const SessionSearchIndex(this.db);

  final Database db;

  List<String> search(SessionSearchQuery query) {
    _ensureThreadNameSchema();
    final where = <String>[];
    final args = <Object?>[];
    if (query.text.trim().isNotEmpty) {
      final textWhere = _textWhere(query);
      where.add(textWhere.sql);
      args.addAll(textWhere.args);
    }
    if (query.sourceTypes.isNotEmpty) {
      where.add(
        's.source_type in (${_sqlParameters(query.sourceTypes.length)})',
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
        's.project_name_snapshot in (${_sqlParameters(query.projectNames.length)})',
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
    if (query.threadName.trim().isNotEmpty) {
      where.add('s.thread_name like ? escape \'~\'');
      args.add('%${_escapeLike(query.threadName.trim())}%');
    }
    if (query.namedOnly) {
      where.add("coalesce(trim(s.thread_name), '') <> ''");
    }
    if (query.evalReady != null) {
      where.add('s.eval_ready = ?');
      args.add(query.evalReady! ? 1 : 0);
    }
    if (query.evalStatuses.isNotEmpty) {
      where.add(
        's.eval_status in (${_sqlParameters(query.evalStatuses.length)})',
      );
      args.addAll(query.evalStatuses);
    }
    if (query.statuses.isNotEmpty) {
      where.add(
        '(s.scan_status in (${_sqlParameters(query.statuses.length)}) '
        'or s.parse_status in (${_sqlParameters(query.statuses.length)}))',
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
      order by s.activity_at_utc desc,
               s.id asc
      ''', args);
    return [for (final row in rows) row['id'] as String];
  }

  _SqlClause _textWhere(SessionSearchQuery query) {
    final scopes = query.effectiveTextScopes;
    final columns = [for (final scope in scopes) ...scope.sessionFtsColumns];
    final likeColumns = [for (final scope in scopes) ...scope.likeColumns];
    final messageAuthors = {
      for (final scope in scopes) ...scope.messageAuthors,
    };
    final includeToolOutput = scopes.contains(SearchTextScope.toolOutput);
    final tokens = _searchTokens(query.text);
    if (tokens.isEmpty ||
        (columns.isEmpty &&
            likeColumns.isEmpty &&
            messageAuthors.isEmpty &&
            !includeToolOutput)) {
      return const _SqlClause('0 = 1', []);
    }
    final args = <Object?>[];
    final tokenClauses = <String>[];
    for (final token in tokens) {
      final sources = <String>[];
      if (columns.isNotEmpty) {
        sources.add(
          's.rowid in (select rowid from session_search '
          'where session_search match ?)',
        );
        args.add(_ftsColumnQuery(columns, [token]));
      }
      for (final column in likeColumns) {
        sources.add('$column like ? escape \'~\'');
        args.add('%${_escapeLike(token)}%');
      }
      if (messageAuthors.isNotEmpty) {
        sources.add(
          'exists ('
          'select 1 '
          'from message_search '
          'join messages m on m.id = message_search.rowid '
          'where m.session_id = s.id '
          'and m.author_type in (${_sqlParameters(messageAuthors.length)}) '
          'and message_search match ?'
          ')',
        );
        args
          ..addAll(messageAuthors)
          ..add(_ftsToken(token));
      }
      if (includeToolOutput) {
        sources.add(
          'exists ('
          'select 1 '
          'from tool_output_search '
          'join tool_calls tc on tc.id = tool_output_search.rowid '
          'where tc.session_id = s.id '
          'and tool_output_search match ?'
          ')',
        );
        args.add(_ftsToken(token));
      }
      tokenClauses.add('(${sources.join(' or ')})');
    }
    return _SqlClause(tokenClauses.join(' and '), args);
  }

  void _ensureThreadNameSchema() {
    final rows = db.select('pragma table_info(sessions)');
    final hasThreadName = rows.any((row) => row['name'] == 'thread_name');
    if (hasThreadName) {
      return;
    }
    db.execute('alter table sessions add column thread_name text');
    db.execute(
      'create index if not exists idx_sessions_thread_name on sessions(thread_name)',
    );
  }
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
    this.threadName = '',
    this.namedOnly = false,
    this.evalReady,
    this.evalStatuses = const {},
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
  final String threadName;
  final bool namedOnly;
  final bool? evalReady;
  final Set<String> evalStatuses;
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
          SearchTextScope.threadName,
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
    SessionSearchSourceType.macos => 'macos',
    SessionSearchSourceType.linux => 'linux',
  };
}

extension on SearchTextScope {
  List<String> get sessionFtsColumns => switch (this) {
    SearchTextScope.title => const ['title'],
    SearchTextScope.summary => const ['summary'],
    SearchTextScope.userMessages => const [],
    SearchTextScope.assistantMessages => const [],
    SearchTextScope.toolNames => const ['tool_names'],
    SearchTextScope.path => const ['display_path', 'normalized_path_keys'],
    SearchTextScope.project => const ['project_name'],
    SearchTextScope.threadName => const [],
    SearchTextScope.tags => const ['tags'],
    SearchTextScope.toolOutput => const [],
  };

  List<String> get likeColumns => switch (this) {
    SearchTextScope.threadName => const ['s.thread_name'],
    _ => [for (final column in sessionFtsColumns) 'f.$column'],
  };

  List<String> get messageAuthors => switch (this) {
    SearchTextScope.userMessages => const ['user'],
    SearchTextScope.assistantMessages => const ['assistant'],
    _ => const [],
  };
}

String _sqlParameters(int count) => List.filled(count, '?').join(', ');

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

String _escapeLike(String value) =>
    value.replaceAll('~', '~~').replaceAll('%', '~%').replaceAll('_', '~_');
