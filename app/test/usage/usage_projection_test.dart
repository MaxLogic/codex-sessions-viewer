import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_generation.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:codex_sessions_viewer/src/database/usage_projection_migration.dart';
import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late UsageSummaryRepository repository;
  late int contextId;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute('pragma foreign_keys = on');
    final scripts =
        [
          ...Directory('../sql/init').listSync().whereType<File>(),
          ...Directory('../sql/migration').listSync().whereType<File>(),
        ].where((file) => file.path.endsWith('.sql')).toList()..sort(
          (a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
        );
    for (final script in scripts) {
      db.execute(script.readAsStringSync());
    }
    final generations = DatabaseGenerationRepository(db);
    final generation = generations.createBuilding(
      sourceSchemaVersion: 15,
      targetSchemaVersion: 16,
      sourceFingerprint: 'projection-fixture',
    );
    // Exercise the realized active16 layout, not production migration readiness.
    generations.markReady(generation.id, validationReportJson: '{}');
    generations.activate(generation.id);
    for (final id in ['selected', 'unrelated']) {
      db.execute(
        '''
        insert into sessions (id, source_type, source_file_path, display_path,
          platform_path, created_at_utc, updated_at_utc)
        values (?, 'windows', ?, ?, ?, '2026-09-05', '2026-09-05')
      ''',
        [id, '$id.jsonl', '$id.jsonl', '$id.jsonl'],
      );
    }
    contextId = ProjectTagStateStore(
      db,
    ).resolveUsagePathContext(displayPath: 'c:/selected');
    repository = UsageSummaryRepository(db);
  });

  tearDown(() => db.close());

  test(
    'daily replacement queues exact cost partitions without downgrading pending work',
    () {
      _event(db, contextId, 1, input: 1, output: 1);
      _event(
        db,
        contextId,
        2,
        input: 1,
        output: 1,
        time: '2026-09-06T00:00:00Z',
      );
      _replace(db, repository, ['selected']);
      final dirty = db.select(
        'select * from usage_cost_dirty_partitions order by day_utc',
      );
      expect(dirty.map((row) => row['day_utc']), ['2026-09-05', '2026-09-06']);
      expect(
        dirty.every((row) => row['target_cost_projection_version'] == 1),
        isTrue,
      );
      db.execute('''
      update usage_cost_dirty_partitions set target_cost_projection_version = 2;
      insert into usage_cost_dirty_partitions (session_id, day_utc, model_key, reason,
        target_cost_projection_version, created_at_utc, updated_at_utc)
      values ('unrelated', '2026-09-05', 'other', 'fixture', 1, '2026-09-05', '2026-09-05');
      delete from usage_events where session_row_id = 'selected' and source_record_ordinal = 2;
    ''');
      _replace(db, repository, ['selected']);
      final retained = db
          .select(
            "select * from usage_cost_dirty_partitions where session_id = 'selected'",
          )
          .single;
      expect(retained['day_utc'], '2026-09-05');
      expect(retained['target_cost_projection_version'], 2);
      expect(
        db.select(
          "select * from usage_cost_dirty_partitions where session_id = 'unrelated'",
        ),
        hasLength(1),
      );
    },
  );

  test('active daily replacement requires the caller transaction', () {
    expect(
      () =>
          repository.replaceDailyProjectionsInCurrentTransaction(['selected']),
      throwsStateError,
    );
    expect(_allRows(db), isEmpty);
  });

  test('shadow projection batches commit data and cursor together', () {
    _event(db, contextId, 1, input: 10, output: 5);
    _event(db, contextId, 2, input: 7, output: 2, time: 'undated');
    final generations = DatabaseGenerationRepository(db);
    expect(generations.rollbackTo(1), isTrue);
    final building = generations.createBuilding(
      sourceSchemaVersion: 15,
      targetSchemaVersion: 16,
      sourceFingerprint: 'batch-fixture',
    );
    db.execute('''
      with recursive n(i) as (select 1 union all select i + 1 from n where i < 518)
      insert into sessions (id, source_type, source_file_path, display_path,
        platform_path, created_at_utc, updated_at_utc)
      select printf('extra%04d', i), 'windows', printf('extra%04d', i),
        'fixture', 'fixture', '2026-09-05', '2026-09-05' from n;
    ''');
    final jobs = MaintenanceJobRepository(db);
    final job = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'contexts_validated',
      databaseGenerationId: building.id,
      payloadJson: '{"preserved_field":true}',
    );
    final lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 5),
    )!;
    jobs.commitBatch(
      lease: lease,
      phase: 'contexts_validated',
      completedUnits: 1000,
      totalUnits: 1000,
      lastProcessedRowId: 1000,
      apply: (_) {},
      statusMessage: 'Context phase complete.',
    );
    final migration = UsageProjectionMigration(db);
    expect(migration.rebuildNextBatch(jobs: jobs, lease: lease), 512);
    final checkpoint = jobs.read(job.id)!;
    expect(checkpoint.completedUnits, 1512);
    expect(checkpoint.totalUnits, 1520);
    expect(
      jsonDecode(checkpoint.payloadJson!)['projection_session_cursor'],
      'extra0512',
    );
    expect(jsonDecode(checkpoint.payloadJson!)['preserved_field'], isTrue);
    expect(
      db
          .select(
            'select count(*) n from sessions where usage_local_event_count is not null',
          )
          .single['n'],
      512,
    );
    db.execute('''
      create trigger fail_last_projection before insert on usage_session_daily
      begin select raise(abort, 'injected batch failure'); end;
    ''');
    expect(
      () => migration.rebuildNextBatch(jobs: jobs, lease: lease),
      throwsA(isA<SqliteException>()),
    );
    expect(jobs.read(job.id)!.payloadJson, checkpoint.payloadJson);
    expect(jobs.read(job.id)!.completedUnits, 1512);
    expect(
      db
          .select(
            'select count(*) n from sessions where usage_local_event_count is not null',
          )
          .single['n'],
      512,
    );
    expect(_allRows(db), isEmpty);
    db.execute('drop trigger fail_last_projection');
    // A fresh repository reads only the committed checkpoint, as after restart.
    expect(
      UsageProjectionMigration(db).rebuildNextBatch(jobs: jobs, lease: lease),
      8,
    );
    expect(migration.rebuildNextBatch(jobs: jobs, lease: lease), 0);
    expect(jobs.read(job.id)!.completedUnits, 1520);
    expect(migration.validateShadowParity()['session_count'], 520);
    expect(generations.activeGeneration().targetSchemaVersion, 15);
    // Simulate damaged persisted evidence bypassing writer constraints. JSON
    // references are invisible to SQLite's ordinary foreign-key audit.
    db.execute('''
      drop trigger trg_usage_session_daily_rule_period_update;
      pragma ignore_check_constraints = on;
      update usage_session_daily set provider_rule_ids_json = '[999999]';
    ''');
    expect(db.select('pragma foreign_key_check'), isEmpty);
    expect(migration.validateShadowParity, throwsStateError);
    db.execute('''
      update usage_session_daily set provider_rule_ids_json = '[]';
      pragma ignore_check_constraints = off;
    ''');
    db.execute(
      'update usage_session_daily set input_tokens = input_tokens + 1',
    );
    expect(migration.validateShadowParity, throwsStateError);
    db.execute(
      'update usage_session_daily set input_tokens = input_tokens - 1',
    );
    db.execute(
      "update sessions set usage_local_event_count = 1 where id = 'selected'",
    );
    expect(migration.validateShadowParity, throwsStateError);
  });

  test('shadow writes reject active and unowned generations', () {
    _event(db, contextId, 1, input: 10, output: 5);
    final generations = DatabaseGenerationRepository(db);
    final building = generations.createBuilding(
      sourceSchemaVersion: 15,
      targetSchemaVersion: 16,
      sourceFingerprint: 'invalid-owner-fixture',
    );
    db.execute('begin immediate');
    expect(
      () => repository.replaceDailyProjectionsInCurrentTransaction([
        'selected',
      ], shadowGenerationId: building.id),
      throwsStateError,
    );
    db.execute('rollback');
    expect(generations.rollbackTo(1), isTrue);
    db.execute('begin immediate');
    for (final id in [1, 2, 999]) {
      expect(
        () => repository.replaceDailyProjectionsInCurrentTransaction([
          'selected',
        ], shadowGenerationId: id),
        throwsStateError,
      );
    }
    db.execute('rollback');
    expect(_allRows(db), isEmpty);
  });

  test('migration projects shadow facts without activating the generation', () {
    _event(db, contextId, 1, input: 10, output: 5);
    _event(db, contextId, 2, input: 3, output: 2, time: 'undated');
    final generations = DatabaseGenerationRepository(db);
    expect(generations.rollbackTo(1), isTrue);
    final building = generations.createBuilding(
      sourceSchemaVersion: 15,
      targetSchemaVersion: 16,
      sourceFingerprint: 'shadow-fixture',
    );
    expect(db.select('select * from usage_events'), isEmpty);
    db.execute('begin immediate');
    repository.replaceDailyProjectionsInCurrentTransaction([
      'selected',
    ], shadowGenerationId: building.id);
    db.execute('commit');
    expect(_facts(db, 'selected'), [
      ['2026-09-05', 'model-a', contextId, 'local', 10, 0, 0, 5, 0, 15],
    ]);
    expect(
      db
          .select(
            "select usage_local_event_count n from sessions where id = 'selected'",
          )
          .single['n'],
      2,
    );
    expect(generations.activeGeneration().targetSchemaVersion, 15);
    expect(
      db.select('select state from database_generations where id = ?', [
        building.id,
      ]).single['state'],
      'building',
    );
    expect(db.select('pragma foreign_key_check'), isEmpty);
  });

  test('daily replacement groups UTC facts and preserves unrelated rows', () {
    final otherContext = ProjectTagStateStore(
      db,
    ).resolveUsagePathContext(displayPath: 'c:/other');
    _event(
      db,
      contextId,
      1,
      time: '2026-09-06T00:30:00+02:00',
      input: 10,
      output: 5,
      cached: 2,
      cacheWrite: 1,
      reasoning: 1,
    );
    _event(
      db,
      contextId,
      2,
      time: '2026-09-05T22:40:00Z',
      input: 20,
      output: 10,
      cached: 3,
      cacheWrite: 2,
      reasoning: 2,
    );
    _event(db, contextId, 3, time: '2026-09-06T00:30:00Z', input: 7, output: 3);
    _event(db, contextId, 4, model: 'model-b', input: 11, output: 4);
    _event(db, contextId, 5, model: null, input: 2, output: 1);
    _event(db, contextId, 6, model: '', input: 3, output: 1);
    _event(db, otherContext, 7, input: 13, output: 6);
    _event(db, contextId, 8, scope: 'inherited', input: 17, output: 8);
    _event(db, contextId, 9, scope: 'ambiguous', input: 19, output: 9);
    _event(db, otherContext, 1, session: 'unrelated', input: 31, output: 12);
    _replace(db, repository, ['selected', 'unrelated']);

    final expected = [
      ['2026-09-05', '', contextId, 'local', 5, 0, 0, 2, 0, 7],
      ['2026-09-05', 'model-a', contextId, 'ambiguous', 19, 0, 0, 9, 0, 28],
      ['2026-09-05', 'model-a', contextId, 'inherited', 17, 0, 0, 8, 0, 25],
      ['2026-09-05', 'model-a', contextId, 'local', 30, 5, 3, 15, 3, 45],
      ['2026-09-05', 'model-a', otherContext, 'local', 13, 0, 0, 6, 0, 19],
      ['2026-09-05', 'model-b', contextId, 'local', 11, 0, 0, 4, 0, 15],
      ['2026-09-06', 'model-a', contextId, 'local', 7, 0, 0, 3, 0, 10],
    ];
    expect(_facts(db, 'selected'), expected);
    final unrelated = _allRows(db, session: 'unrelated');
    _replace(db, repository, ['selected', 'selected']);
    expect(_facts(db, 'selected'), expected);
    expect(_allRows(db, session: 'unrelated'), unrelated);
    for (final row in _allRows(db)) {
      expect(row['estimated_cost_text'], isNull);
      expect(row['cost_status'], 'unknown');
      expect(row['pricing_resolution_method'], 'pending_history');
      expect(row['provider_price_period_id'], isNull);
      expect(row['provider_rule_ids_json'], '[]');
      expect(row['local_override_period_id'], isNull);
      expect(row['pricing_catalog_snapshot_id'], isNull);
      expect(row['cost_projection_version'], 1);
    }

    db.execute('begin immediate');
    db.execute("delete from usage_events where session_row_id = 'selected'");
    repository.replaceDailyProjectionsInCurrentTransaction(['selected']);
    db.execute('commit');
    expect(_facts(db, 'selected'), isEmpty);
    expect(_allRows(db, session: 'unrelated'), unrelated);
    expect(db.select('pragma foreign_key_check'), isEmpty);
  });

  test('projection failure rolls back with surrounding event mutations', () {
    _event(db, contextId, 1, input: 10, output: 5);
    _event(db, contextId, 1, session: 'unrelated', input: 20, output: 10);
    _replace(db, repository, ['selected', 'unrelated']);
    final before = _allRows(db);
    final beforeEvents = db.select(
      'select * from usage_events order by session_row_id',
    );
    db.execute('''
      create trigger fail_projection before insert on usage_session_daily
      when new.session_id = 'selected'
      begin select raise(abort, 'injected projection failure'); end
    ''');

    db.execute('begin immediate');
    db.execute('update usage_events set input_tokens = 555');
    try {
      expect(
        () => repository.replaceDailyProjectionsInCurrentTransaction([
          'unrelated',
          'selected',
        ]),
        throwsA(
          isA<SqliteException>().having(
            (error) => error.message,
            'message',
            contains('injected projection failure'),
          ),
        ),
      );
      expect(db.autocommit, isFalse);
    } finally {
      db.execute('rollback');
    }

    expect(_allRows(db), before);
    expect(
      db.select('select * from usage_events order by session_row_id'),
      beforeEvents,
    );
    expect(db.select('pragma foreign_key_check'), isEmpty);
  });
}

void _event(
  Database db,
  int context,
  int ordinal, {
  String session = 'selected',
  String time = '2026-09-05T12:00:00Z',
  String? model = 'model-a',
  String scope = 'local',
  required int input,
  required int output,
  int cached = 0,
  int cacheWrite = 0,
  int reasoning = 0,
}) {
  db.execute(
    '''
    insert into usage_events (session_row_id, source_record_ordinal, epoch,
      occurred_at_utc, model, path_context_id, input_tokens, cached_input_tokens,
      cache_write_input_tokens, output_tokens, reasoning_output_tokens,
      total_tokens, branch_scope, derivation, event_fingerprint)
    values (?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, 999, ?, 'last_token_usage', ?)
  ''',
    [
      session,
      ordinal,
      time,
      model,
      context,
      input,
      cached,
      cacheWrite,
      output,
      reasoning,
      scope,
      ordinal.toString().padLeft(64, '0'),
    ],
  );
}

void _replace(
  Database db,
  UsageSummaryRepository repository,
  List<String> ids,
) {
  db.execute('begin immediate');
  try {
    repository.replaceDailyProjectionsInCurrentTransaction(ids);
    db.execute('commit');
  } on Object {
    db.execute('rollback');
    rethrow;
  }
}

List<List<Object?>> _facts(Database db, String session) => [
  for (final row in db.select(
    '''
    select day_utc, model_key, path_context_id, branch_scope, input_tokens,
      cached_input_tokens, cache_write_input_tokens, output_tokens,
      reasoning_output_tokens, total_tokens
    from usage_session_daily where session_id = ?
    order by day_utc, model_key, path_context_id, branch_scope
  ''',
    [session],
  ))
    row.values.toList(),
];

List<Map<String, Object?>> _allRows(Database db, {String? session}) => [
  for (final row in db.select(
    '''
    select * from usage_session_daily
    ${session == null ? '' : 'where session_id = ?'} order by id
  ''',
    [?session],
  ))
    Map<String, Object?>.from(row),
];
