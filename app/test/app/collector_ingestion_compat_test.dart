@TestOn('windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/app/runtime_session_controller.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/search/session_search.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The Rust collector (T-119) writes the viewer's database with SQL that must
/// match the Dart scan writer. This test scans one fixture tree twice, once
/// with the production Dart writer and once with the built collector
/// executable, and compares every written table. It then reads the collector's
/// database through the production repositories.
/// A database prepared the way production startup prepares it: schema files,
/// then the persisted-usage startup migration. Migrated once (the startup
/// migration takes about a minute) and copied for each test database.
late File _template;

Future<File> _migrateTemplate() async {
  final folder = await Directory.systemTemp.createTemp(
    'csv_collector_template_',
  );
  final file = File(p.join(folder.path, 'template.sqlite'));
  final sqlRoot = Directory('../sql');
  final startup = await DatabaseMigrator(
    sqlRoot: sqlRoot,
  ).openAndMigrate(file, deferUsageMigration: true);
  expect(startup.canStartNormalUi, isTrue, reason: startup.fatalError?.details);
  final migration = await startPendingDatabaseMigration(file, sqlRoot: sqlRoot);
  if (migration != null) {
    final result = await migration.result;
    expect(result.succeeded, isTrue, reason: result.state.name);
  }
  final db = openFileBackedDatabase(file);
  try {
    db.execute('pragma wal_checkpoint(TRUNCATE)');
  } finally {
    db.close();
  }
  return file;
}

void main() {
  late File collector;

  setUpAll(() async {
    _template = await _migrateTemplate();
    final override = Platform.environment['CODEX_SESSIONS_COLLECTOR_EXE'];
    if (override != null && override.isNotEmpty) {
      collector = File(override);
    } else {
      // Always rebuild so the test never runs a stale executable.
      final build = await Process.run('cargo', [
        'build',
        '--quiet',
        '--manifest-path',
        p.join('..', 'collector', 'Cargo.toml'),
        '--bin',
        'codex-sessions-collector',
      ]);
      expect(
        build.exitCode,
        0,
        reason: 'cargo build failed:\n${build.stdout}\n${build.stderr}',
      );
      collector = File(
        p.join(
          '..',
          'collector',
          'target',
          'debug',
          'codex-sessions-collector.exe',
        ),
      );
    }
    expect(collector.existsSync(), isTrue, reason: collector.path);
  });

  tearDownAll(() => _template.parent.delete(recursive: true));

  test(
    'collector writes the same rows as the Dart scan across scan, rescan, append, and delete',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);

      final dartDb = await fixture.migratedDatabase('dart.sqlite');
      final rustDb = await fixture.migratedDatabase('rust.sqlite');

      Future<void> scanBoth(String label) async {
        await fixture.dartScan(dartDb);
        await fixture.collectorScan(collector, rustDb);
        _expectSameContent(_content(dartDb), _content(rustDb), reason: label);
      }

      await scanBoth('first scan');
      final firstScan = _content(rustDb);
      expect(
        (firstScan['sessions'] as List)
            .where((row) => (row as Map)['parse_status'] == 'available')
            .length,
        greaterThanOrEqualTo(8),
      );
      expect(firstScan['usage_events'], isNotEmpty);
      expect(firstScan['usage_event_inputs'], isNotEmpty);

      await scanBoth('unchanged rescan');

      await fixture.appendToForkedSession();
      await fixture.deleteHistoryBaseSession();
      await scanBoth('rescan after append and delete');

      await _expectProductionReadsMatch(fixture, dartDb, rustDb);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'the viewer and the collector take turns on one database without reparsing',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final shared = await fixture.migratedDatabase('shared.sqlite');
      final reference = await fixture.migratedDatabase('reference.sqlite');
      await fixture.dartScan(reference);

      Map<String, Object?> parsedAt(File file) {
        final db = openFileBackedDatabase(file);
        try {
          return {
            for (final row in db.select(
              "select id, last_parsed_utc from sessions where parse_status = 'available'",
            ))
              row['id'] as String: row['last_parsed_utc'],
          };
        } finally {
          db.close();
        }
      }

      await fixture.dartScan(shared);
      final afterViewer = parsedAt(shared);
      await fixture.collectorScan(collector, shared);
      expect(
        parsedAt(shared),
        afterViewer,
        reason: 'the collector must not reparse what the viewer parsed',
      );
      await fixture.dartScan(shared);
      expect(
        parsedAt(shared),
        afterViewer,
        reason: 'the viewer must not reparse what is unchanged',
      );
      _expectSameContent(
        _content(reference),
        _content(shared),
        reason: 'interleaved writers converge on a single-writer result',
      );

      await fixture.appendToForkedSession();
      await fixture.collectorScan(collector, shared);
      await fixture.dartScan(shared);
      await fixture.dartScan(reference);
      _expectSameContent(
        _content(reference),
        _content(shared),
        reason:
            'a change collected by the collector is not redone by the viewer',
      );
    },
  );

  test('the viewer refuses a database a standalone collector owns', () async {
    final fixture = await _Fixture.create();
    addTearDown(fixture.dispose);
    final standalone = File(p.join(fixture.temp.path, 'standalone.sqlite'));
    final created = await Process.run(collector.path, [
      'codex',
      'scan',
      '--no-wsl-projects',
      '--settings',
      fixture.settingsFile.path,
      '--standalone',
      standalone.path,
    ]);
    expect(created.exitCode, 0, reason: '${created.stdout}\n${created.stderr}');
    final before = await standalone.readAsBytes();
    final startup = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(standalone);
    expect(startup.canStartNormalUi, isFalse);
    expect(startup.fatalError?.summary, contains('standalone collector'));
    expect(await _schemaVersion(standalone), 19);
    expect(await standalone.readAsBytes(), hasLength(before.length));
  });

  test(
    'a database the viewer migrated accepts the collector as a writer',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final db = await fixture.migratedDatabase('viewer.sqlite');
      final connection = openFileBackedDatabase(db);
      try {
        expect(
          connection
              .select(
                "select value from app_metadata where key = 'database_owner'",
              )
              .single['value'],
          'viewer',
        );
        expect(
          connection
              .select("select value from app_metadata where key = 'machine_id'")
              .single['value'],
          hasLength(32),
        );
      } finally {
        connection.close();
      }
      final result = await Process.run(collector.path, [
        'codex',
        'scan',
        '--json',
        '--no-wsl-projects',
        '--settings',
        fixture.settingsFile.path,
        '--db',
        db.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final report =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(report['owner'], 'viewer');
      expect(report['files_parsed'], greaterThanOrEqualTo(8));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

class _Fixture {
  _Fixture(this.temp);

  final Directory temp;

  Directory get windowsHome => Directory(p.join(temp.path, 'codex-home'));
  Directory get wslHome => Directory(p.join(temp.path, 'wsl-home'));
  Directory get day =>
      Directory(p.join(windowsHome.path, 'sessions', '2026', '09', '01'));
  File get settingsFile => File(p.join(temp.path, 'settings.toml'));

  static const _parityDir = '../samples/collector-parity/sessions';

  static Future<_Fixture> create() async {
    final fixture = _Fixture(
      await Directory.systemTemp.createTemp('csv_collector_compat_'),
    );
    await fixture._populate();
    return fixture;
  }

  Future<void> _populate() async {
    await day.create(recursive: true);
    final archived = Directory(p.join(windowsHome.path, 'archived_sessions'));
    await archived.create(recursive: true);
    for (final name in [
      'rich_session.jsonl',
      'subagent_session.jsonl',
      'forked_legacy_session.jsonl',
      'history_base_session.jsonl',
      'no_session_id.jsonl',
      'jsonl_in_json_file.json',
      'legacy_session.json',
      'malformed_line.jsonl',
      'invalid_utf8.jsonl',
      'scalar_root.json',
    ]) {
      await File('$_parityDir/$name').copy(p.join(day.path, name));
    }
    // The same session also archived: the active copy must win in both.
    await File(
      '$_parityDir/rich_session.jsonl',
    ).copy(p.join(archived.path, 'rich_session.jsonl'));
    await File(p.join(day.path, 'notes.txt')).writeAsString('not a session');

    // A working directory inside a git repository resolves to the repo name.
    final repo = Directory(p.join(temp.path, 'repo-root'));
    await Directory(p.join(repo.path, '.git')).create(recursive: true);
    await Directory(
      p.join(repo.path, 'nested', 'deeper'),
    ).create(recursive: true);
    final cwd = p.join(repo.path, 'nested', 'deeper');
    await File(p.join(day.path, 'git_repo_session.jsonl')).writeAsString(
      [
        jsonEncode({
          'timestamp': '2026-09-09T09:00:00Z',
          'type': 'session_meta',
          'payload': {
            'id': 'parity-git-011',
            'cwd': cwd,
            'model_provider': 'openai',
          },
        }),
        jsonEncode({
          'timestamp': '2026-09-09T09:00:01Z',
          'type': 'turn_context',
          'payload': {'cwd': cwd, 'model': 'gpt-5.5'},
        }),
        jsonEncode({
          'timestamp': '2026-09-09T09:00:02Z',
          'type': 'event_msg',
          'payload': {
            'type': 'token_count',
            'info': {
              'total_token_usage': {'input_tokens': 10, 'output_tokens': 2},
              'last_token_usage': {'input_tokens': 10, 'output_tokens': 2},
            },
          },
        }),
      ].join('\n'),
    );

    await File(p.join(windowsHome.path, 'session_index.jsonl')).writeAsString(
      [
        jsonEncode({
          'id': 'parity-rich-001',
          'thread_name': 'Indexed rich name',
          'updated_at': '2026-09-10T00:00:00Z',
        }),
        jsonEncode({
          'id': 'parity-fork-003',
          'thread_name': 'Indexed fork',
          'updated_at': '2026-09-10T00:00:00Z',
        }),
        jsonEncode({'id': 'not-collected', 'thread_name': 'Nobody'}),
      ].join('\n'),
    );

    // A second, WSL-typed Codex home.
    final wslDay = Directory(
      p.join(wslHome.path, 'sessions', '2026', '09', '02'),
    );
    await wslDay.create(recursive: true);
    await File(
      '$_parityDir/subagent_session.jsonl',
    ).copy(p.join(wslDay.path, 'wsl_subagent_copy.jsonl'));

    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsHome.path,
          wslCodexUncPath: wslHome.path,
        ),
        logging: LoggingSettings(
          level: 'info',
          logFile: p.join(temp.path, 'logs', 'viewer.log'),
          maxLogFiles: 2,
          maxLogSizeMb: 1,
        ),
      ),
    );
  }

  /// A copy of the production-migrated template database.
  Future<File> migratedDatabase(String name) =>
      _template.copy(p.join(temp.path, name));

  Future<void> dartScan(File db) async {
    await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: db,
      wslProjectResolver: const _NoWslProjects(),
    ).refresh();
  }

  Future<void> collectorScan(File exe, File db) async {
    final result = await Process.run(exe.path, [
      'codex',
      'scan',
      '--no-wsl-projects',
      '--settings',
      settingsFile.path,
      '--db',
      db.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }

  Future<void> appendToForkedSession() async {
    await File(p.join(day.path, 'forked_legacy_session.jsonl')).writeAsString(
      '${jsonEncode({
        'timestamp': '2026-09-03T10:05:00Z',
        'type': 'event_msg',
        'payload': {'type': 'agent_message', 'message': 'appended answer'},
      })}\n',
      mode: FileMode.append,
    );
  }

  Future<void> deleteHistoryBaseSession() =>
      File(p.join(day.path, 'history_base_session.jsonl')).delete();

  Future<void> dispose() => temp.delete(recursive: true);
}

class _NoWslProjects extends WslProjectResolver {
  const _NoWslProjects();

  @override
  Future<Map<String, String>> resolveProjectNames(
    Iterable<String> workingDirectories,
  ) async => const {};
}

List<Map<String, Object?>> _rows(Database db, String sql) => [
  for (final row in db.select(sql))
    {for (final column in row.keys) column: row[column]},
];

Map<String, Object?> _without(Map<String, Object?> row, List<String> keys) =>
    Map.of(row)..removeWhere((key, _) => keys.contains(key));

/// Stored content that must not depend on the writer: timestamps, the
/// per-database machine ID, and autoincrement IDs are left out or replaced by
/// their natural keys.
Map<String, Object?> _content(File file) {
  final db = openFileBackedDatabase(file);
  try {
    return {
      'sessions': [
        for (final row in _rows(db, '''
          select s.*, p.name as project_name, d.name as detected_project_name
          from sessions s
          left join projects p on p.id = s.project_id
          left join projects d on d.id = s.detected_project_id
          order by s.id
          '''))
          _without(row, [
            'created_at_utc',
            'updated_at_utc',
            'last_scanned_utc',
            'last_parsed_utc',
            'activity_at_utc',
            'machine_id',
            'project_id',
            'detected_project_id',
          ]),
      ],
      'messages': [
        for (final row in _rows(
          db,
          'select * from messages order by session_id, message_index',
        ))
          _without(row, ['id', 'created_at_db_utc', 'updated_at_db_utc']),
      ],
      'tool_calls': [
        for (final row in _rows(
          db,
          'select * from tool_calls order by session_id, tool_index',
        ))
          _without(row, ['id']),
      ],
      'usage_events': [
        for (final row in _rows(db, '''
          select e.*, c.display_path_key, c.platform_path_key, c.unc_path_key
          from usage_events e
          join usage_path_contexts c on c.id = e.path_context_id
          order by e.session_row_id, e.source_record_ordinal
          '''))
          _without(row, ['path_context_id']),
      ],
      'usage_event_inputs': _rows(
        db,
        'select * from usage_event_inputs order by session_row_id, source_record_ordinal',
      ),
      'usage_session_daily': _rows(db, '''
        select d.session_id, d.day_utc, d.model_key, c.display_path_key,
          d.branch_scope, d.input_tokens, d.cached_input_tokens,
          d.cache_write_input_tokens, d.output_tokens,
          d.reasoning_output_tokens, d.total_tokens, d.estimated_cost_text,
          d.cost_status, d.pricing_resolution_method
        from usage_session_daily d
        join usage_path_contexts c on c.id = d.path_context_id
        order by d.session_id, d.day_utc, d.model_key, c.display_path_key,
          d.branch_scope
        '''),
      'usage_cost_dirty_partitions': _rows(db, '''
        select session_id, day_utc, model_key, reason,
          target_cost_projection_version
        from usage_cost_dirty_partitions
        order by session_id, day_utc, model_key
        '''),
      'usage_path_contexts': _rows(db, '''
        select c.display_path_raw, c.platform_path_raw, c.unc_path_raw,
          c.display_path_key, c.resolution_source, c.detected_project_source,
          d.name as detected, m.name as mask, e.name as effective
        from usage_path_contexts c
        left join projects d on d.id = c.detected_project_id
        left join projects m on m.id = c.mask_project_id
        left join projects e on e.id = c.effective_project_id
        order by c.display_path_raw, c.platform_path_raw, c.unc_path_raw
        '''),
      'projects': _rows(
        db,
        'select name, description, is_active from projects order by name',
      ),
      'session_path_keys': _rows(
        db,
        'select * from session_path_keys order by session_id, path_key',
      ),
      'session_search': _rows(db, '''
        select s.id, f.title, f.summary, f.tool_names, f.display_path,
          f.normalized_path_keys, f.project_name, f.tags
        from session_search f join sessions s on s.rowid = f.rowid
        order by s.id
        '''),
      'message_search': _rows(db, '''
        select m.session_id, m.message_index
        from message_search f join messages m on m.id = f.rowid
        where message_search match 'parser OR subagent OR forked OR legacy'
        order by m.session_id, m.message_index
        '''),
    };
  } finally {
    db.close();
  }
}

void _differences(
  String path,
  Object? expected,
  Object? actual,
  List<String> found,
) {
  if (found.length >= 15) return;
  if (expected is Map && actual is Map) {
    for (final key in {...expected.keys, ...actual.keys}) {
      _differences('$path.$key', expected[key], actual[key], found);
    }
    return;
  }
  if (expected is List && actual is List) {
    for (var i = 0; i < expected.length && i < actual.length; i++) {
      _differences('$path[$i]', expected[i], actual[i], found);
    }
    if (expected.length != actual.length) {
      found.add(
        '$path: ${expected.length} Dart rows, ${actual.length} collector rows',
      );
    }
    return;
  }
  if (expected != actual) {
    String show(Object? value) {
      final text = '$value';
      return text.length > 160 ? '${text.substring(0, 160)}...' : text;
    }

    found.add('$path: Dart ${show(expected)} != collector ${show(actual)}');
  }
}

void _expectSameContent(
  Map<String, Object?> dart,
  Map<String, Object?> rust, {
  required String reason,
}) {
  final found = <String>[];
  _differences(r'$', dart, rust, found);
  expect(found, isEmpty, reason: '$reason:\n${found.join('\n')}');
}

Future<void> _expectProductionReadsMatch(
  _Fixture fixture,
  File dartDb,
  File rustDb,
) async {
  Future<List<Map<String, Object?>>> rows(File db) async {
    final result = await RuntimeSessionController(
      settingsFile: fixture.settingsFile,
      databaseFile: db,
      wslProjectResolver: const _NoWslProjects(),
    ).loadCachedRows();
    return [
      for (final row in result.rows)
        {
          'id': row.id,
          'title': row.title,
          'thread': row.threadName,
          'project': row.project,
          'messages': row.messageCount,
          'tools': row.toolCallCount,
          'tokens': row.totalTokens,
          'status': row.status,
          'source': row.sourceState.name,
          'models': row.modelsUsed,
          'cost_unknown': row.costUnknown,
        },
    ];
  }

  final dartRows = await rows(dartDb);
  final rustRows = await rows(rustDb);
  expect(rustRows, isNotEmpty);
  _expectSameContent(
    {'rows': dartRows},
    {'rows': rustRows},
    reason: 'session list rows',
  );

  List<String> search(File file, String text) {
    final db = openFileBackedDatabase(file);
    try {
      return SessionSearchIndex(db).search(SessionSearchQuery(text: text));
    } finally {
      db.close();
    }
  }

  for (final text in ['parser', 'subagent', 'shell', 'Parity']) {
    expect(search(rustDb, text), search(dartDb, text), reason: text);
  }
  expect(search(rustDb, 'parser'), isNotEmpty);

  Map<String, Object?> usage(File file) {
    final db = openFileBackedDatabase(file);
    try {
      final summary = UsageSummaryRepository(db).summarize(
        UsageSummaryRequest(
          period: UsagePeriod.custom,
          nowUtc: DateTime.utc(2026, 9, 30),
          customStartUtc: DateTime.utc(2026, 8, 1),
          customEndExclusiveUtc: DateTime.utc(2026, 10, 1),
        ),
      );
      return {
        'sessions': summary.totalSessions,
        'messages': summary.totalMessages,
        'input': summary.inputTokens,
        'output': summary.outputTokens,
        'cached': summary.cachedInputTokens,
        'total': summary.totalTokens,
        'model': summary.mostUsedModel,
        'project': summary.mostActiveProject,
      };
    } finally {
      db.close();
    }
  }

  final rustUsage = usage(rustDb);
  expect(rustUsage['total'], greaterThan(0));
  _expectSameContent(usage(dartDb), rustUsage, reason: 'usage summary');
}

Future<int> _schemaVersion(File file) async {
  final db = openFileBackedDatabase(file);
  try {
    return db
            .select(
              'select max(version) v from schema_version where success = 1',
            )
            .single['v']
        as int;
  } finally {
    db.close();
  }
}
