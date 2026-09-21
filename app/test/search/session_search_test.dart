import 'dart:io';

import 'package:codex_sessions_viewer/src/database/session_eval_state.dart';
import 'package:codex_sessions_viewer/src/search/session_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late SessionSearchIndex index;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute(File('../sql/init/001_initial_schema.sql').readAsStringSync());
    db.execute(
      File('../sql/migration/002_search_filter_schema.sql').readAsStringSync(),
    );
    db.execute(
      File('../sql/migration/007_session_thread_name.sql').readAsStringSync(),
    );
    db.execute(
      File(
        '../sql/migration/012_external_content_search.sql',
      ).readAsStringSync(),
    );
    index = SessionSearchIndex(db);
    db.execute(
      File(
        '../sql/migration/016_persisted_usage_pricing_maintenance.sql',
      ).readAsStringSync(),
    );
  });

  tearDown(() {
    db.close();
  });

  test('search order uses source activity rather than metadata edits', () {
    index.upsert(_document(id: 'older', title: 'Activity target'));
    index.upsert(_document(id: 'newer', title: 'Activity target'));
    db.execute(
      "update sessions set last_message_at_utc=null,started_at_utc=null,updated_at_utc='2026-08-01T00:00:00Z' where id='older'",
    );
    db.execute(
      "update sessions set last_message_at_utc=null,started_at_utc=null,updated_at_utc='2026-09-01T00:00:00Z' where id='newer'",
    );
    const query = SessionSearchQuery(text: 'Activity target');
    expect(index.search(query), ['newer', 'older']);
    db.execute(
      "update sessions set is_pinned=1,updated_at_utc='2099-01-01T00:00:00Z' where id='older'",
    );
    expect(index.search(query), ['newer', 'older']);
  });

  test('indexes default searchable fields with FTS5', () {
    index.upsert(
      _document(
        id: 'alpha',
        title: 'Parser cache notes',
        summary: 'SQLite FTS integration',
        toolNames: 'apply_patch shell_command',
        displayPath: r'F:\projects\MaxLogic\codex-sessions-viewer',
        normalizedPathKeys: 'f:/projects/maxlogic/codex-sessions-viewer',
        projectName: 'Codex Sessions Viewer',
        tags: ['parser', 'scanner'],
      ),
    );
    _insertMessage(
      db,
      sessionId: 'alpha',
      messageIndex: 0,
      author: 'user',
      content: 'Find my scanner implementation',
    );
    _insertMessage(
      db,
      sessionId: 'alpha',
      messageIndex: 1,
      author: 'assistant',
      content: 'The cache invalidation is complete',
    );

    expect(index.search(const SessionSearchQuery(text: 'scanner')), ['alpha']);
    expect(index.search(const SessionSearchQuery(text: 'apply_patch')), [
      'alpha',
    ]);
    expect(
      index.search(
        const SessionSearchQuery(text: 'maxlogic/codex-sessions-viewer'),
      ),
      ['alpha'],
    );
    expect(index.search(const SessionSearchQuery(text: 'parser')), ['alpha']);
  });

  test('searches and filters thread names without FTS schema changes', () {
    index.upsert(
      _document(id: 'named', title: 'Visible title', threadName: 'dmk2'),
    );
    index.upsert(_document(id: 'unnamed', title: 'Visible title'));

    expect(index.search(const SessionSearchQuery(text: 'dmk2')), ['named']);
    expect(index.search(const SessionSearchQuery(threadName: 'mk2')), [
      'named',
    ]);
    expect(index.search(const SessionSearchQuery(namedOnly: true)), ['named']);
    expect(
      index.search(
        const SessionSearchQuery(
          text: 'dmk2',
          textScopes: {SearchTextScope.threadName},
        ),
      ),
      ['named'],
    );
  });

  test('excludes tool output by default and includes it when configured', () {
    index.upsert(_document(id: 'tool-output', title: 'Visible title'));
    db.execute('''
      update app_metadata
      set value = '1'
      where key = 'tool_output_search.enabled'
      ''');
    _insertToolCall(
      db,
      sessionId: 'tool-output',
      toolIndex: 0,
      output: 'secret-build-output-token',
    );

    expect(
      index.search(const SessionSearchQuery(text: 'secret-build-output-token')),
      isEmpty,
    );
    expect(
      index.search(
        const SessionSearchQuery(
          text: 'secret-build-output-token',
          includeToolOutput: true,
        ),
      ),
      ['tool-output'],
    );
  });

  test('tool output index follows the persisted enable setting', () {
    index.upsert(_document(id: 'optional-output', title: 'Visible title'));
    _insertToolCall(
      db,
      sessionId: 'optional-output',
      toolIndex: 0,
      output: 'optional-output-needle',
    );
    const query = SessionSearchQuery(
      text: 'optional-output-needle',
      includeToolOutput: true,
    );
    expect(index.search(query), isEmpty);

    ToolOutputSearchIndex(db).configure(enabled: true);
    expect(index.search(query), ['optional-output']);

    ToolOutputSearchIndex(db).configure(enabled: false);
    expect(index.search(query), isEmpty);
  });

  test('limits full-text search to selected scopes', () {
    index.upsert(
      _document(
        id: 'scoped',
        title: 'Title needle',
        summary: 'Summary needle',
        displayPath: r'C:\needle\session.jsonl',
        normalizedPathKeys: 'c:/needle/session.jsonl',
        projectName: 'Project needle',
        tags: ['tag-needle'],
      ),
    );

    expect(
      index.search(
        const SessionSearchQuery(
          text: 'summary',
          textScopes: {SearchTextScope.title},
        ),
      ),
      isEmpty,
    );
    expect(
      index.search(
        const SessionSearchQuery(
          text: 'summary',
          textScopes: {SearchTextScope.summary},
        ),
      ),
      ['scoped'],
    );
    expect(
      index.search(
        const SessionSearchQuery(
          text: 'tag-needle',
          textScopes: {SearchTextScope.tags},
        ),
      ),
      ['scoped'],
    );
  });

  test('empty full-text scope matches nothing without throwing', () {
    index.upsert(_document(id: 'empty-scope', title: 'Hidden needle'));

    expect(
      index.search(const SessionSearchQuery(text: 'needle', textScopes: {})),
      isEmpty,
    );
  });

  test('non-token full-text queries match nothing', () {
    index.upsert(_document(id: 'punctuation', title: 'Visible title'));

    expect(index.search(const SessionSearchQuery(text: '!!!')), isEmpty);
    expect(index.search(const SessionSearchQuery(text: 'żółć')), isEmpty);
  });

  test('treats full-text LIKE fallback underscores as literals', () {
    index.upsert(_document(id: 'literal-tool', toolNames: 'apply_patch'));
    index.upsert(_document(id: 'wildcard-tool', toolNames: 'applyXpatch'));

    expect(index.search(const SessionSearchQuery(text: 'apply_patch')), [
      'literal-tool',
    ]);
  });

  test('applies session filters', () {
    index.upsert(
      _document(
        id: 'match',
        title: 'Filter target',
        toolNames: 'shell_command',
        sourceType: SessionSearchSourceType.wsl,
        startedAtUtc: DateTime.utc(2026, 6, 12, 10),
        displayPath: '/home/pawel/projects/app',
        normalizedPathKeys: '/home/pawel/projects/app',
        projectName: 'Viewer',
        tags: ['important'],
        modelsUsed: ['gpt-5.4'],
        scanStatus: 'available',
        parseStatus: 'available',
        isPinned: true,
        isArchived: false,
        hasCodeBlocks: true,
        hasToolCalls: true,
        hasErrors: false,
        totalTokens: 120,
      ),
    );
    index.upsert(
      _document(
        id: 'miss',
        title: 'Filter target',
        sourceType: SessionSearchSourceType.windows,
        startedAtUtc: DateTime.utc(2026, 5, 1),
        displayPath: r'C:\temp\other',
        normalizedPathKeys: 'c:/temp/other',
        projectName: 'Other',
        tags: ['later'],
        modelsUsed: ['gpt-4.1'],
        scanStatus: 'parse_error',
        parseStatus: 'parse_error',
        isPinned: false,
        isArchived: true,
        hasCodeBlocks: false,
        hasToolCalls: false,
        hasErrors: true,
        totalTokens: 25,
      ),
    );

    final result = index.search(
      SessionSearchQuery(
        text: 'target',
        sourceTypes: const {SessionSearchSourceType.wsl},
        fromUtc: DateTime.utc(2026, 6, 1),
        toUtc: DateTime.utc(2026, 6, 30),
        pathPatterns: const ['/home/*/projects/*'],
        projectNames: const {'Viewer'},
        tags: const {'important'},
        models: const {'gpt-5.4'},
        statuses: const {'available'},
        pinned: true,
        archived: ArchivedFilter.activeOnly,
        hasCodeBlocks: true,
        hasToolCalls: true,
        hasErrors: false,
        minTotalTokens: 100,
        maxTotalTokens: 150,
      ),
    );

    expect(result, ['match']);
  });

  test('filters sessions by eval metadata', () {
    db.execute(
      File('../sql/migration/008_local_eval_metadata.sql').readAsStringSync(),
    );
    index.upsert(_document(id: 'ready', title: 'Eval target'));
    index.upsert(_document(id: 'draft', title: 'Eval target'));
    index.upsert(_document(id: 'not-ready', title: 'Eval target'));

    final store = SessionEvalStateStore(db);
    store.setEvalMetadata(
      'ready',
      evalReady: true,
      status: 'correct',
      notes: 'Reviewed answer',
      expectedOutput: 'Expected answer',
      reviewedAtUtc: DateTime.utc(2026, 7, 7, 10),
    );
    store.setEvalMetadata(
      'draft',
      evalReady: true,
      status: 'needs_review',
      notes: 'Needs another pass',
      expectedOutput: 'Expected draft',
      reviewedAtUtc: DateTime.utc(2026, 7, 7, 11),
    );

    expect(
      index.search(const SessionSearchQuery(evalReady: true)),
      unorderedEquals(['ready', 'draft']),
    );
    expect(
      index.search(
        const SessionSearchQuery(evalReady: true, evalStatuses: {'correct'}),
      ),
      ['ready'],
    );

    final row = db
        .select(
          '''
      select eval_ready,
             eval_status,
             eval_notes,
             eval_expected_output,
             eval_reviewed_at_utc,
             eval_updated_at_utc
      from sessions
      where id = ?
      ''',
          ['ready'],
        )
        .single;
    expect(row['eval_ready'], 1);
    expect(row['eval_status'], 'correct');
    expect(row['eval_notes'], 'Reviewed answer');
    expect(row['eval_expected_output'], 'Expected answer');
    expect(row['eval_reviewed_at_utc'], '2026-07-07T10:00:00.000Z');
    expect(row['eval_updated_at_utc'], isNotNull);

    store.setEvalMetadata('ready', evalReady: false);
    expect(index.search(const SessionSearchQuery(evalReady: true)), ['draft']);
  });

  test('uses exact tag and model membership filters', () {
    index.upsert(
      _document(
        id: 'important-session',
        title: 'Membership target',
        tags: ['important'],
        modelsUsed: ['gpt-5.4'],
      ),
    );
    index.upsert(
      _document(
        id: 'exact-session',
        title: 'Membership target',
        tags: ['port'],
        modelsUsed: ['gpt-5'],
      ),
    );

    expect(
      index.search(
        const SessionSearchQuery(
          text: 'membership',
          tags: {'port'},
          models: {'gpt-5'},
        ),
      ),
      ['exact-session'],
    );
  });

  test('treats path underscores and percent signs as literals', () {
    index.upsert(
      _document(
        id: 'literal',
        title: 'Path target',
        displayPath: r'C:\work\my_project\100%real',
        normalizedPathKeys: 'c:/work/my_project/100%real',
      ),
    );
    index.upsert(
      _document(
        id: 'wildcard-leak',
        title: 'Path target',
        displayPath: r'C:\work\myXproject\100Zreal',
        normalizedPathKeys: 'c:/work/myXproject/100Zreal',
      ),
    );

    expect(
      index.search(
        const SessionSearchQuery(
          text: 'path',
          pathPatterns: ['c:/work/my_project/100%real'],
        ),
      ),
      ['literal'],
    );
  });

  test('matches any of multiple path patterns', () {
    index.upsert(
      _document(
        id: 'second-pattern',
        title: 'Path alternatives',
        displayPath: r'D:\work\client\session.jsonl',
        normalizedPathKeys: 'd:/work/client/session.jsonl',
      ),
    );

    expect(
      index.search(
        const SessionSearchQuery(
          text: 'alternatives',
          pathPatterns: ['c:/not-here/*', 'd:/work/*'],
        ),
      ),
      ['second-pattern'],
    );
  });
}

SessionSearchDocument _document({
  required String id,
  String title = '',
  String summary = '',
  String threadName = '',
  String toolNames = '',
  String displayPath = '',
  String normalizedPathKeys = '',
  String projectName = '',
  List<String> tags = const [],
  SessionSearchSourceType sourceType = SessionSearchSourceType.windows,
  DateTime? startedAtUtc,
  List<String> modelsUsed = const [],
  String scanStatus = 'available',
  String parseStatus = 'available',
  bool isPinned = false,
  bool isArchived = false,
  bool hasCodeBlocks = false,
  bool hasToolCalls = false,
  bool hasErrors = false,
  int? totalTokens,
}) => SessionSearchDocument(
  id: id,
  sourceType: sourceType,
  sourceFilePath: displayPath.isEmpty ? '$id.jsonl' : displayPath,
  displayPath: displayPath.isEmpty ? '$id.jsonl' : displayPath,
  platformPath: displayPath.isEmpty ? '$id.jsonl' : displayPath,
  title: title,
  summary: summary,
  threadName: threadName,
  toolNames: toolNames,
  normalizedPathKeys: normalizedPathKeys,
  projectName: projectName,
  tags: tags,
  startedAtUtc: startedAtUtc,
  modelsUsed: modelsUsed,
  scanStatus: scanStatus,
  parseStatus: parseStatus,
  isPinned: isPinned,
  isArchived: isArchived,
  hasCodeBlocks: hasCodeBlocks,
  hasToolCalls: hasToolCalls,
  hasErrors: hasErrors,
  totalTokens: totalTokens,
);

void _insertMessage(
  Database db, {
  required String sessionId,
  required int messageIndex,
  required String author,
  required String content,
}) {
  db.execute(
    '''
    insert into messages (
      session_id,
      message_index,
      author_type,
      first_line,
      content_plain,
      content_preview,
      created_at_db_utc,
      updated_at_db_utc
    ) values (?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    [
      sessionId,
      messageIndex,
      author,
      content,
      content,
      content,
      '2026-07-17T10:00:00.000Z',
      '2026-07-17T10:00:00.000Z',
    ],
  );
}

void _insertToolCall(
  Database db, {
  required String sessionId,
  required int toolIndex,
  required String output,
}) {
  db.execute(
    '''
    insert into tool_calls (
      session_id,
      tool_index,
      tool_name,
      status,
      output_preview
    ) values (?, ?, 'shell_command', 'completed', ?)
    ''',
    [sessionId, toolIndex, output],
  );
}
