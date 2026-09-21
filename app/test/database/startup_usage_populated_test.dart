import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_backup.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_generation.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migration_preflight.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:codex_sessions_viewer/src/database/startup_usage_migration.dart';
import 'package:codex_sessions_viewer/src/database/usage_migration_bootstrap.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'populated startup resumes 512 events and preserves facts, branches and historical costs',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_populated_startup_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/viewer.sqlite');
      final prepared = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(file, deferUsageMigration: true);
      expect(prepared.lastAppliedSchemaVersion, 15);
      final source = openFileBackedDatabase(file, maintenanceWriter: true);
      late List<Map<String, Object?>> rawFacts;
      try {
        _seed(source);
        rawFacts = _facts(source);
        expect(
          source
              .select(
                'select count(*) n, sum(total_tokens) t from usage_events',
              )
              .single,
          {'n': 520, 't': 51480},
        );
      } finally {
        source.close();
      }

      final first = await DatabaseMaintenanceCoordinator(file).start(
        jobType: 'usage_projection_migration',
        initialPhase: 'bootstrap',
        bootstrapWorker: _bootstrapWithStop,
        worker: _migrate,
      );
      final firstResult = await first.result;
      expect(
        firstResult.state,
        DatabaseMaintenanceState.interrupted,
        reason: firstResult.errorMessage,
      );
      final interrupted = openFileBackedDatabase(file, maintenanceWriter: true);
      late int jobId;
      late Map<String, dynamic> backup;
      try {
        final job = MaintenanceJobRepository(
          interrupted,
        ).latestForType('usage_projection_migration')!;
        jobId = job.id;
        backup = Map<String, dynamic>.from(
          (jsonDecode(job.payloadJson!) as Map)['backup'] as Map,
        );
        expect(job.phase, 'copy_events');
        expect(job.completedUnits, 512);
        expect(job.lastProcessedRowId, 512);
        expect(
          interrupted
              .select('select count(*) n from usage_events_next')
              .single['n'],
          512,
        );
        expect(
          DatabaseGenerationRepository(
            interrupted,
          ).activeGeneration().targetSchemaVersion,
          15,
        );
        expect(_facts(interrupted), rawFacts);
        interrupted.execute('drop trigger stop_populated_copy');
      } finally {
        interrupted.close();
      }

      final second = await DatabaseMaintenanceCoordinator(file).start(
        jobType: 'usage_projection_migration',
        initialPhase: 'bootstrap',
        bootstrapWorker: _bootstrap,
        worker: _migrate,
      );
      final result = await second.result;
      expect(result.succeeded, isTrue, reason: result.errorMessage);
      final db = openFileBackedDatabase(file);
      try {
        final job = MaintenanceJobRepository(
          db,
        ).latestForType('usage_projection_migration')!;
        expect(job.id, jobId);
        expect(job.state, MaintenanceJobState.succeeded);
        expect((jsonDecode(job.payloadJson!) as Map)['backup'], backup);
        expect(
          DatabaseGenerationRepository(db).activeGeneration().state,
          DatabaseGenerationState.complete,
        );
        expect(
          DatabaseGenerationRepository(
            db,
          ).activeGeneration().targetSchemaVersion,
          16,
        );
        expect(db.select('pragma query_only').single.values.single, 0);
        expect(
          db.select(
            "select name from sqlite_schema where name in ('usage_events_next', 'usage_events_legacy')",
          ),
          isEmpty,
        );
        expect(
          db.select(
            "select value from app_metadata where key = 'usage_migration_bootstrap'",
          ),
          isEmpty,
        );
        expect(
          db
              .select('select normal_writes_resumed_at_utc from database_state')
              .single
              .values
              .single,
          isNotNull,
        );
        expect(
          _facts(db),
          rawFacts,
          reason: 'Raw totals and every immutable event fact survive cutover.',
        );
        expect(
          db
              .select(
                'select count(distinct path_context_id) n from usage_events',
              )
              .single['n'],
          1,
        );
        final contextId = db
            .select('select path_context_id from usage_events limit 1')
            .single['path_context_id'];
        expect(
          db
              .select(
                '''select detected_project_id, mask_project_id, effective_project_id
        from usage_path_contexts where id = ?''',
                [contextId],
              )
              .single,
          {
            'detected_project_id': 1,
            'mask_project_id': 2,
            'effective_project_id': 2,
          },
        );
        expect(
          db
              .select(
                '''select display_path_raw, platform_path_raw, unc_path_raw
        from usage_path_context_aliases where path_context_id = ?''',
                [contextId],
              )
              .map((row) => Map<String, Object?>.from(row)),
          unorderedEquals([
            {
              'display_path_raw': r'C:\Work\Fixture',
              'platform_path_raw': r'C:\Work\Fixture',
              'unc_path_raw': '',
            },
            {
              'display_path_raw': 'c:/work/fixture',
              'platform_path_raw': r'C:\Work\Fixture',
              'unc_path_raw': '',
            },
          ]),
        );
        expect(
          db
              .select('select project_id, detected_project_id from sessions')
              .map((row) => Map<String, Object?>.from(row)),
          everyElement({'project_id': 2, 'detected_project_id': 1}),
        );

        final period = db.select('select * from model_price_periods').single;
        expect(period['model_id'], 'provider/fixture');
        expect(period['valid_from_utc'], '2026-09-01T00:00:00.000000Z');
        expect(period['valid_to_utc'], isNull);
        final daily = db.select(
          'select * from usage_session_daily order by branch_scope',
        );
        expect(daily, hasLength(3));
        // Per event: (10-4-1)*.001 + 4*.0005 + (5-2)*.002 + 2*.003
        //          + .0000000833333333333333 = .0190000833333333333333.
        // Reasoning is an output subset; cache-write precision must survive.
        const expected = {
          'local': (count: 500, cost: '9.50004166666666666665'),
          'inherited': (count: 10, cost: '0.190000833333333333333'),
          'ambiguous': (count: 10, cost: '0.190000833333333333333'),
        };
        for (final row in daily) {
          final branch = expected[row['branch_scope']]!;
          expect(row['input_tokens'], branch.count * 10);
          expect(row['cached_input_tokens'], branch.count * 4);
          expect(row['cache_write_input_tokens'], branch.count);
          expect(row['output_tokens'], branch.count * 5);
          expect(row['reasoning_output_tokens'], branch.count * 2);
          expect(
            row['total_tokens'],
            branch.count * 15,
            reason: 'Daily totals are canonical, not raw 99-token totals.',
          );
          expect(row['estimated_cost_text'], branch.cost);
          expect(row['cost_status'], 'complete');
          expect(row['provider_price_period_id'], period['id']);
          expect(
            row['pricing_catalog_snapshot_id'],
            period['first_snapshot_id'],
          );
          expect(row['provider_rule_ids_json'], '[]');
          expect(row['local_override_period_id'], isNull);
          expect(row['cost_projection_version'], usageCostProjectionVersion);
          expect(row['path_context_id'], contextId);
        }
        final summary = UsageSummaryRepository(db).summarize(
          UsageSummaryRequest(
            period: UsagePeriod.today,
            nowUtc: DateTime.utc(2026, 9, 2, 23),
          ),
        );
        expect(summary.totalTokens, 7500);
        expect(summary.inputTokens, 5000);
        expect(summary.outputTokens, 2500);
        expect(summary.cachedInputTokens, 2000);
        expect(summary.estimatedCostText, '9.50004166666666666665');
        expect(summary.costUnknown, isFalse);
        // Breakdown rows also include metadata-only session groups with no usage.
        final billedProject = summary.byProject
            .where((row) => row.totalTokens > 0)
            .single;
        expect(billedProject.key, 'Matched fixture');
        expect(billedProject.totalTokens, 7500);
        expect(
          summary.byModel.where((row) => row.totalTokens > 0).single.key,
          'Fixture',
        );
        expect(db.select('select * from usage_cost_dirty_partitions'), isEmpty);
        expect(db.select('pragma foreign_key_check'), isEmpty);
        expect(db.select('pragma integrity_check').single.values.single, 'ok');
        expect(
          db.select('''
        select tbl, idx, stat from sqlite_stat1
        where tbl in ('usage_events_next', 'usage_events_legacy')
      '''),
          isEmpty,
          reason:
              'Final statistics must describe active storage, not retired table names.',
        );
        expect(
          db.select('''
        select stat from sqlite_stat1
        where tbl = 'usage_events' and idx in (
          select name from sqlite_schema where type = 'index' and tbl_name = 'usage_events'
        )
      '''),
          isNotEmpty,
        );
      } finally {
        db.close();
      }
      expect(
        Directory('${temp.path}/backups').listSync().whereType<File>(),
        hasLength(1),
      );
      final verified = await SqliteBackupService().inspect(
        File(backup['path'] as String),
      );
      expect(verified.sha256, backup['sha256']);
      expect(verified.lengthBytes, backup['length_bytes']);
    },
  );
}

const _factColumns = '''session_row_id, source_record_ordinal, rollout_ordinal,
  turn_ordinal, epoch, occurred_at_utc, model, input_tokens, cached_input_tokens,
  cache_write_input_tokens, output_tokens, reasoning_output_tokens, total_tokens,
  branch_scope, derivation, event_fingerprint''';

List<Map<String, Object?>> _facts(Database db) => db
    .select(
      'select $_factColumns from usage_events order by source_record_ordinal',
    )
    .map((row) => Map<String, Object?>.from(row))
    .toList();

void _seed(Database db) {
  db.execute('begin immediate');
  for (final (id, name) in [(1, 'Legacy fixture'), (2, 'Matched fixture')]) {
    db.execute(
      '''insert into projects (id, name, created_at_utc, updated_at_utc)
      values (?, ?, '2026-09-01', '2026-09-01')''',
      [id, name],
    );
  }
  db.execute(
    '''insert into project_path_masks
    (project_id, path_mask, created_at_utc, updated_at_utc)
    values (2, ?, '2026-09-01', '2026-09-01')''',
    [r'C:\Work\Fixture*'],
  );
  for (final scope in ['local', 'inherited', 'ambiguous']) {
    db.execute(
      '''insert into sessions (id, source_type, source_file_path, display_path,
      platform_path, working_directory_display, working_directory_platform,
      project_id, usage_projection_status, started_at_utc, last_message_at_utc,
      created_at_utc, updated_at_utc)
      values (?, 'windows', ?, ?, ?, ?, ?, 1, ?, '2026-09-02T12:00:00Z',
        '2026-09-02T13:00:00Z', '2026-09-02', '2026-09-02')''',
      [
        scope,
        '$scope.jsonl',
        '$scope.jsonl',
        '$scope.jsonl',
        r'C:\Work\Fixture',
        r'C:\Work\Fixture',
        scope == 'ambiguous' ? 'ambiguous' : 'complete',
      ],
    );
  }
  final insert = db.prepare('''insert into usage_events ($_factColumns,
    working_directory_display, working_directory_platform, project_id)
    values (?, ?, ?, ?, ?, ?, 'provider/fixture', 10, 4, 1, 5, 2, 99,
      ?, ?, ?, ?, ?, 1)''');
  try {
    for (var ordinal = 1; ordinal <= 520; ordinal++) {
      final scope = ordinal <= 500
          ? 'local'
          : ordinal <= 510
          ? 'inherited'
          : 'ambiguous';
      insert.execute([
        scope,
        ordinal,
        ordinal ~/ 5,
        ordinal ~/ 2,
        ordinal ~/ 200,
        DateTime.utc(
          2026,
          9,
          2,
          12,
        ).add(Duration(seconds: ordinal)).toIso8601String(),
        scope,
        ordinal.isEven ? 'last_token_usage' : 'cumulative_delta',
        ordinal.toRadixString(16).padLeft(64, '0'),
        ordinal.isEven ? r'C:\Work\Fixture' : 'c:/work/fixture',
        r'C:\Work\Fixture',
      ]);
    }
  } finally {
    insert.close();
  }
  db.execute('''insert into model_pricing_cache (model_id, provider,
    prompt_price_per_token, completion_price_per_token,
    input_cache_read_price_per_token, input_cache_write_price_per_token,
    internal_reasoning_price_per_token, fetched_at_utc, source)
    values ('provider/fixture', 'provider', '0.001', '0.002', '0.0005', '0.0000000833333333333333', '0.003',
      '2026-09-01T00:00:00Z', 'openrouter')''');
  db.execute('commit');
}

UsageMigrationBootstrap _configuration(
  DatabaseMaintenanceWorkerContext context,
) => UsageMigrationBootstrap(
  migrator: DatabaseMigrator(sqlRoot: Directory('../sql')),
  settings: const PricingSettings(
    provider: 'openrouter',
    useExternalPricing: true,
    fallbackToOverrides: false,
    overrides: {},
    openRouter: OpenRouterSettings(
      modelsEndpoint: 'https://unused.invalid',
      apiKey: '',
    ),
  ),
  backupDirectory: Directory('${context.databaseFile.parent.path}/backups'),
  preflight: DatabaseMigrationPreflight(
    diskSpaceProbe: (_) async =>
        const DiskVolumeSpace(volumeKey: 'fixture', availableBytes: 1 << 50),
  ),
);

Future<DatabaseMaintenanceWorkerOutcome> _bootstrap(
  DatabaseMaintenanceWorkerContext context,
) => _configuration(context).run(context);

Future<DatabaseMaintenanceWorkerOutcome> _bootstrapWithStop(
  DatabaseMaintenanceWorkerContext context,
) async {
  final result = await _bootstrap(context);
  if (result == DatabaseMaintenanceWorkerOutcome.succeeded) {
    context.database.execute(r'''
      create trigger stop_populated_copy after insert on usage_events_next
      when new.source_record_ordinal = 512 begin
        update maintenance_jobs set payload_json = json_set(payload_json, '$.stop_requested', json('true'))
        where job_type = 'usage_projection_migration';
      end
    ''');
  }
  return result;
}

Future<DatabaseMaintenanceWorkerOutcome> _migrate(
  DatabaseMaintenanceWorkerContext context,
) => StartupUsageMigration(_configuration(context)).run(context);
