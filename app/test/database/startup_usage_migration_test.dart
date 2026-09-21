import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_backup.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_generation.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance_cancelled.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/database_migration_preflight.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:codex_sessions_viewer/src/database/startup_usage_migration.dart';
import 'package:codex_sessions_viewer/src/database/usage_migration_bootstrap.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final prices in [false, true]) {
    final phase = prices ? 'initialize_prices' : 'project_usage';
    final unit = prices ? 'models' : 'sessions';
    test(
      '$phase migration reports known totals and resumes from its phase baseline',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'csv_projection_progress_',
        );
        addTearDown(() => temporary.delete(recursive: true));
        final file = File('${temporary.path}/viewer.sqlite');
        await DatabaseMigrator(
          sqlRoot: Directory('../sql'),
        ).openAndMigrate(file, deferUsageMigration: true);
        final seed = openFileBackedDatabase(file, maintenanceWriter: true);
        if (prices) {
          seed.execute('''
          with recursive n(value) as (select 0 union all select value+1 from n where value<520)
          insert into model_pricing_cache(model_id,provider,prompt_price_per_token,completion_price_per_token,fetched_at_utc,source)
          select printf('model%04d',value),'openrouter','0.000001','0.000002','2026-09-01T00:00:00Z','openrouter' from n
        ''');
        } else {
          seed.execute('''
      with recursive n(value) as (select 0 union all select value+1 from n where value<520)
      insert into sessions(id,source_type,source_file_path,display_path,platform_path,created_at_utc,updated_at_utc)
      select printf('s%04d',value),'windows',printf('fixture%04d',value),'fixture','fixture','2026-09-01','2026-09-01' from n
    ''');
        }
        seed.close();
        final operation = await DatabaseMaintenanceCoordinator(file).start(
          jobType: 'usage_projection_migration',
          initialPhase: 'bootstrap',
          bootstrapWorker: prices
              ? _bootstrapStopDuringPrices
              : _bootstrapStopDuringProjection,
          worker: _completeUsageMigration,
        );
        final reports = operation.progress.toList();
        final stopped = await operation.result;
        expect(
          stopped.state,
          DatabaseMaintenanceState.interrupted,
          reason: stopped.errorMessage,
        );
        final projection = (await reports)
            .where((item) => item.phase == phase && item.unitLabel == unit)
            .toList();
        expect(projection.first.totalUnits, 521);
        expect(projection.last.completedUnits, 512);
        final writer = openFileBackedDatabase(file, maintenanceWriter: true);
        writer.execute(
          'drop trigger ${prices ? 'stop_during_prices' : 'stop_during_projection'}',
        );
        writer.close();
        final resumed = await DatabaseMaintenanceCoordinator(file).start(
          jobType: 'usage_projection_migration',
          initialPhase: 'bootstrap',
          bootstrapWorker: _verifiedBootstrap,
          worker: _completeUsageMigration,
        );
        final resumedReports = resumed.progress.toList();
        final completed = await resumed.result;
        expect(completed.succeeded, isTrue, reason: completed.errorMessage);
        final continued = (await resumedReports)
            .where((item) => item.phase == phase && item.unitLabel == unit)
            .toList();
        expect(continued.first.completedUnits, 512);
        expect(continued.first.ratePerSecond, isNull);
        expect(continued.first.estimatedRemaining, isNull);
        expect(continued.last.completedUnits, 521);
        expect(continued.last.totalUnits, 521);
      },
    );
  }

  test(
    'startup resumes committed cutover and keeps cleanup gated on reopen failure',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'csv_cutover_resume_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final file = File('${temporary.path}/viewer.sqlite');
      await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(file, deferUsageMigration: true);
      final operation = await DatabaseMaintenanceCoordinator(file).start(
        jobType: 'usage_projection_migration',
        initialPhase: 'bootstrap',
        bootstrapWorker: _bootstrapStopAtReady,
        worker: _commitCutoverWithoutCheckpoint,
      );
      expect(
        (await operation.result).state,
        DatabaseMaintenanceState.interrupted,
      );
      final writer = openFileBackedDatabase(file, maintenanceWriter: true);
      try {
        final job = MaintenanceJobRepository(
          writer,
        ).latestForType('usage_projection_migration')!;
        expect(job.phase, 'cutover');
        expect(
          DatabaseGenerationRepository(writer).activeGeneration().state,
          DatabaseGenerationState.active,
        );
        writer.execute(
          "update database_generations set validation_report_json=json_set(validation_report_json, '\$.context_parity.event_count', 1) where id=?",
          [job.databaseGenerationId],
        );
        final failed = await startPendingDatabaseMigration(
          file,
          sqlRoot: Directory('../sql'),
        );
        final failedResult = await failed!.result;
        expect(failedResult.state, DatabaseMaintenanceState.failed);
        expect(failedResult.errorMessage, contains('Reopened event count'));
        expect(DatabaseGenerationRepository(writer).activeGeneration().id, 1);
        expect(
          writer.select('select state from database_generations where id=?', [
            job.databaseGenerationId,
          ]).single['state'],
          'ready',
        );
        expect(
          writer
              .select("pragma table_info('usage_events')")
              .map((row) => row['name']),
          contains('working_directory_display'),
        );
        expect(
          writer.select(
            "select name from sqlite_schema where name='usage_events_next'",
          ),
          hasLength(1),
        );
        final normal = openFileBackedDatabase(file);
        try {
          expect(normal.select('pragma query_only').single.values.single, 1);
        } finally {
          normal.close();
        }
        writer.execute(
          "update database_generations set validation_report_json=json_set(validation_report_json, '\$.context_parity.event_count', 0) where id=?",
          [job.databaseGenerationId],
        );
        final resumed = await startPendingDatabaseMigration(
          file,
          sqlRoot: Directory('../sql'),
        );
        final resumedResult = await resumed!.result;
        expect(
          resumedResult.succeeded,
          isTrue,
          reason: resumedResult.errorMessage,
        );
        expect(
          DatabaseGenerationRepository(writer).activeGeneration().state,
          DatabaseGenerationState.complete,
        );
        expect(
          writer.select(
            "select name from sqlite_schema where name='usage_events_legacy'",
          ),
          isEmpty,
        );
      } finally {
        writer.close();
      }
    },
  );

  test('stale startup worker cannot roll back the replacement owner', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'csv_stale_cutover_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final file = File('${temporary.path}/viewer.sqlite');
    await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(file, deferUsageMigration: true);
    final operation = await DatabaseMaintenanceCoordinator(file).start(
      jobType: 'usage_projection_migration',
      initialPhase: 'bootstrap',
      bootstrapWorker: _bootstrapStopAtReady,
      worker: _commitCutoverWithoutCheckpoint,
    );
    expect(
      (await operation.result).state,
      DatabaseMaintenanceState.interrupted,
    );
    final stale = await DatabaseMaintenanceCoordinator(file).start(
      jobType: 'usage_projection_migration',
      initialPhase: 'cutover',
      bootstrapWorker: _verifiedBootstrap,
      worker: _reclaimedBeforeValidation,
    );
    expect((await stale.result).state, DatabaseMaintenanceState.failed);
    final db = openFileBackedDatabase(file, maintenanceWriter: true);
    try {
      expect(
        DatabaseGenerationRepository(db).activeGeneration().targetSchemaVersion,
        16,
      );
      final replacement = MaintenanceJobRepository(
        db,
      ).latestForType('usage_projection_migration')!;
      expect(replacement.runToken, 'replacement-owner');
      expect(replacement.state, MaintenanceJobState.running);
      expect(
        db.select(
          "select name from sqlite_schema where name='usage_events_legacy'",
        ),
        hasLength(1),
      );
    } finally {
      db.close();
    }
  });

  test('startup resumes committed cleanup after loss before job success', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'csv_cleanup_resume_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final file = File('${temporary.path}/viewer.sqlite');
    await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(file, deferUsageMigration: true);
    final operation = await DatabaseMaintenanceCoordinator(file).start(
      jobType: 'usage_projection_migration',
      initialPhase: 'bootstrap',
      bootstrapWorker: _verifiedBootstrap,
      worker: _abandonAfterCleanup,
    );
    expect((await operation.result).state, DatabaseMaintenanceState.failed);
    final writer = openFileBackedDatabase(file, maintenanceWriter: true);
    try {
      final job = MaintenanceJobRepository(
        writer,
      ).latestForType('usage_projection_migration')!;
      expect(job.phase, 'cleanup_complete');
      expect(job.state, MaintenanceJobState.running);
      expect(
        writer.select(
          "select value from app_metadata where key='usage_migration_bootstrap'",
        ),
        isEmpty,
      );
      writer.execute(
        "update maintenance_jobs set lease_expires_at_utc='2000-01-01T00:00:00.000Z' where id=?",
        [job.id],
      );
      final resumed = await startPendingDatabaseMigration(
        file,
        sqlRoot: Directory('../sql'),
      );
      final result = await resumed!.result;
      expect(result.succeeded, isTrue, reason: result.errorMessage);
      expect(
        MaintenanceJobRepository(
          writer,
        ).latestForType('usage_projection_migration')!.id,
        job.id,
      );
      expect(DatabaseGenerationRepository(writer).rollbackTo(1), isFalse);
    } finally {
      writer.close();
    }
  });

  test(
    'production factory upgrades schema 15 and needs no work after completion',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'csv_factory_complete_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final file = File('${temporary.path}/viewer.sqlite');
      await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(file, deferUsageMigration: true);
      final operation = await startPendingDatabaseMigration(
        file,
        sqlRoot: Directory('../sql'),
        pricingSettings: AppSettings.defaults().pricing,
      );
      expect(operation, isNotNull);
      final result = await operation!.result;
      expect(result.succeeded, isTrue, reason: result.errorMessage);
      expect(
        await startPendingDatabaseMigration(
          file,
          sqlRoot: Directory('../sql'),
          pricingSettings: AppSettings.defaults().pricing,
        ),
        isNull,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'bootstrap refuses a backup with a mismatched embedded identity before schema 16',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'csv_backup_identity_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final file = File('${temporary.path}/viewer.sqlite');
      await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(file, deferUsageMigration: true);
      final operation = await DatabaseMaintenanceCoordinator(file).start(
        jobType: 'usage_projection_migration',
        initialPhase: 'bootstrap',
        bootstrapWorker: _mismatchedBackupBootstrap,
        worker: _stopBeforeMigration,
      );
      final result = await operation.result;
      expect(result.state, DatabaseMaintenanceState.failed);
      expect(result.errorMessage, contains('Backup identity'));
      final db = openFileBackedDatabase(file);
      try {
        expect(
          db
              .select(
                'select max(version) v from schema_version where success=1',
              )
              .single['v'],
          15,
        );
        expect(
          db.select(
            "select name from sqlite_schema where name='maintenance_jobs'",
          ),
          isEmpty,
        );
        expect(db.select('pragma query_only').single.values.single, 1);
      } finally {
        db.close();
      }
    },
  );

  test('complete startup worker activates and seals a fresh generation', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'csv_startup_complete_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final file = File('${temporary.path}/viewer.sqlite');
    await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(file, deferUsageMigration: true);
    final operation = await DatabaseMaintenanceCoordinator(file).start(
      jobType: 'usage_projection_migration',
      initialPhase: 'bootstrap',
      bootstrapWorker: _verifiedBootstrap,
      worker: _completeUsageMigration,
    );
    final reports = operation.progress.toList();
    final result = await operation.result;
    expect(result.succeeded, isTrue, reason: result.errorMessage);
    final phases = (await reports).map((item) => item.phase).toSet();
    expect(
      phases,
      containsAll([
        'project_usage',
        'initialize_prices',
        'final_statistics',
        'validate_usage',
        'cutover',
        'reopen_validate',
        'cleanup',
      ]),
    );
    final db = openFileBackedDatabase(file);
    try {
      expect(
        DatabaseGenerationRepository(db).activeGeneration().state,
        DatabaseGenerationState.complete,
      );
      expect(
        DatabaseGenerationRepository(db).activeGeneration().targetSchemaVersion,
        16,
      );
      expect(db.select('pragma query_only').single.values.single, 0);
      expect(
        db.select(
          "select name from sqlite_schema where name in ('usage_events_next','usage_events_legacy')",
        ),
        isEmpty,
      );
      expect(
        db.select(
          "select value from app_metadata where key='usage_migration_bootstrap'",
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
      expect(db.select('pragma foreign_key_check'), isEmpty);
      expect(
        MaintenanceJobRepository(
          db,
        ).latestForType('usage_projection_migration')!.state,
        MaintenanceJobState.succeeded,
      );
    } finally {
      db.close();
    }
  });

  test(
    'schema 16 reuses its verified receipt and rejects changed recovery evidence',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'csv_receipt_resume_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final file = File('${temporary.path}/viewer.sqlite');
      await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(file, deferUsageMigration: true);
      Future<DatabaseMaintenanceResult> attempt() async {
        final operation = await DatabaseMaintenanceCoordinator(file).start(
          jobType: 'usage_projection_migration',
          initialPhase: 'bootstrap',
          bootstrapWorker: _verifiedBootstrap,
          worker: _stopBeforeMigration,
        );
        return operation.result;
      }

      expect((await attempt()).state, DatabaseMaintenanceState.interrupted);
      final writer = openFileBackedDatabase(file, maintenanceWriter: true);
      final jobs = MaintenanceJobRepository(writer);
      final initialJob = jobs.latestForType('usage_projection_migration')!;
      final initialReceipt =
          writer
                  .select(
                    "select value from app_metadata where key='usage_migration_bootstrap'",
                  )
                  .single['value']
              as String;
      try {
        expect((await attempt()).state, DatabaseMaintenanceState.interrupted);
        expect(
          jobs.latestForType('usage_projection_migration')!.id,
          initialJob.id,
        );
        expect(
          jobs
              .latestForType('usage_projection_migration')!
              .databaseGenerationId,
          initialJob.databaseGenerationId,
        );
        expect(
          Directory(
            '${temporary.path}/backups',
          ).listSync().whereType<File>().length,
          1,
        );
        for (final field in [
          'observed_at_utc',
          'source_schema_version',
          'backup_path',
        ]) {
          final changedJob =
              jsonDecode(initialJob.payloadJson!) as Map<String, dynamic>;
          changedJob[field] = field == 'source_schema_version' ? 14 : 'changed';
          writer.execute(
            'update maintenance_jobs set payload_json=? where id=?',
            [jsonEncode(changedJob), initialJob.id],
          );
          final mismatch = await attempt();
          expect(
            mismatch.state,
            DatabaseMaintenanceState.failed,
            reason: field,
          );
          expect(mismatch.errorMessage, contains('receipt do not match'));
          writer.execute(
            'update maintenance_jobs set payload_json=? where id=?',
            [initialJob.payloadJson, initialJob.id],
          );
        }
        final changed = jsonDecode(initialReceipt) as Map<String, dynamic>;
        (changed['backup'] as Map)['sha256'] = '0' * 64;
        writer.execute(
          "update app_metadata set value=? where key='usage_migration_bootstrap'",
          [jsonEncode(changed)],
        );
        final rejected = await attempt();
        expect(rejected.state, DatabaseMaintenanceState.failed);
        expect(rejected.errorMessage, contains('no longer matches'));
        expect(
          jobs.latestForType('usage_projection_migration')!.id,
          initialJob.id,
        );
        writer.execute(
          "delete from app_metadata where key='usage_migration_bootstrap'",
        );
        final missing = await attempt();
        expect(missing.state, DatabaseMaintenanceState.failed);
        expect(missing.errorMessage, contains('no verified pre-upgrade'));
        final normal = openFileBackedDatabase(file);
        try {
          expect(normal.select('pragma query_only').single.values.single, 1);
        } finally {
          normal.close();
        }
      } finally {
        writer.close();
      }
    },
  );

  test('pre-16 retry takes a fresh backup after an old-build write', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'csv_bootstrap_retry_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final file = File('${temporary.path}/viewer.sqlite');
    await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(file, deferUsageMigration: true);
    final interrupted = await DatabaseMaintenanceCoordinator(file).start(
      jobType: 'usage_projection_migration',
      initialPhase: 'bootstrap',
      bootstrapWorker: _bootstrapFailBefore16,
      worker: _stopBeforeMigration,
    );
    expect((await interrupted.result).state, DatabaseMaintenanceState.failed);
    final oldDb = openFileBackedDatabase(file, maintenanceWriter: true);
    late Map<String, dynamic> firstReceipt;
    try {
      firstReceipt =
          jsonDecode(
                oldDb
                        .select(
                          "select value from app_metadata where key='usage_migration_bootstrap'",
                        )
                        .single['value']
                    as String,
              )
              as Map<String, dynamic>;
      expect(
        oldDb
            .select('select max(version) v from schema_version where success=1')
            .single['v'],
        15,
      );
      oldDb.execute(
        "insert into app_metadata values ('old_build_write', 'new', '2026-09-07')",
      );
    } finally {
      oldDb.close();
    }
    final retry = await DatabaseMaintenanceCoordinator(file).start(
      jobType: 'usage_projection_migration',
      initialPhase: 'bootstrap',
      bootstrapWorker: _verifiedBootstrap,
      worker: _stopBeforeMigration,
    );
    expect((await retry.result).state, DatabaseMaintenanceState.interrupted);
    final db = openFileBackedDatabase(file);
    late Map<String, dynamic> secondReceipt;
    try {
      secondReceipt =
          jsonDecode(
                MaintenanceJobRepository(
                  db,
                ).latestForType('usage_projection_migration')!.payloadJson!,
              )
              as Map<String, dynamic>;
    } finally {
      db.close();
    }
    final firstBackup = firstReceipt['backup'] as Map;
    final secondBackup = secondReceipt['backup'] as Map;
    expect(secondBackup['path'], isNot(firstBackup['path']));
    expect(
      (await SqliteBackupService().inspect(
        File(firstBackup['path'] as String),
      )).sha256,
      firstBackup['sha256'],
    );
    final restored = File('${temporary.path}/restored.sqlite');
    await SqliteBackupService().restore(
      backup: File(secondBackup['path'] as String),
      destinationFile: restored,
    );
    final restoredDb = openFileBackedDatabase(
      restored,
      maintenanceWriter: true,
    );
    try {
      expect(
        restoredDb
            .select(
              "select value from app_metadata where key='old_build_write'",
            )
            .single['value'],
        'new',
      );
    } finally {
      restoredDb.close();
    }
  });

  test(
    'verified bootstrap preserves schema 15 WAL data and freezes private-free policy',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'csv_verified_bootstrap_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final file = File('${temporary.path}/viewer.sqlite');
      await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(file, deferUsageMigration: true);
      final writer = openFileBackedDatabase(file, maintenanceWriter: true);
      writer.execute(
        "insert into app_metadata values ('committed_wal_probe', 'retained', '2026-09-07')",
      );
      final operation = await DatabaseMaintenanceCoordinator(file).start(
        jobType: 'usage_projection_migration',
        initialPhase: 'bootstrap',
        bootstrapWorker: _verifiedBootstrap,
        worker: _stopBeforeMigration,
      );
      final result = await operation.result;
      writer.close();
      expect(
        result.state,
        DatabaseMaintenanceState.interrupted,
        reason: result.errorMessage,
      );
      final db = openFileBackedDatabase(file);
      late Map<String, dynamic> payload;
      try {
        final job = MaintenanceJobRepository(
          db,
        ).latestForType('usage_projection_migration')!;
        expect(job.phase, 'backup_complete');
        payload = jsonDecode(job.payloadJson!) as Map<String, dynamic>;
        expect(job.payloadJson, isNot(contains('DO_NOT_PERSIST')));
        expect(
          (payload['pricing_policy'] as Map).containsKey('openrouter'),
          isFalse,
        );
        expect((payload['pricing_policy'] as Map)['overrides'], isEmpty);
        expect(
          (payload['pricing_policy'] as Map)['cost_projection_version'],
          usageCostProjectionVersion,
        );
        final frozen = UsageMigrationBootstrap.readPricingSettings(payload);
        expect(frozen.overrides, isEmpty);
        expect(frozen.fallbackToOverrides, isFalse);
        final unsupported =
            jsonDecode(job.payloadJson!) as Map<String, dynamic>;
        (unsupported['pricing_policy'] as Map)['cost_projection_version'] =
            usageCostProjectionVersion + 1;
        expect(
          () => UsageMigrationBootstrap.readPricingSettings(unsupported),
          throwsStateError,
        );
        expect(db.select('pragma query_only').single.values.single, 1);
      } finally {
        db.close();
      }
      final evidence = payload['backup'] as Map;
      final backup = File(evidence['path'] as String);
      final verified = await SqliteBackupService().inspect(backup);
      expect(verified.sha256, evidence['sha256']);
      expect(verified.lengthBytes, evidence['length_bytes']);
      final restored = File('${temporary.path}/old-build.sqlite');
      await SqliteBackupService().restore(
        backup: backup,
        destinationFile: restored,
      );
      final oldStartup = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
        supportedSchemaVersion: 15,
      ).openAndMigrate(restored);
      expect(
        oldStartup.canStartNormalUi,
        isTrue,
        reason: oldStartup.fatalError?.details,
      );
      expect(oldStartup.lastAppliedSchemaVersion, 15);
      final oldDb = openFileBackedDatabase(restored, maintenanceWriter: true);
      try {
        expect(
          oldDb
              .select(
                "select value from app_metadata where key='committed_wal_probe'",
              )
              .single['value'],
          'retained',
        );
        expect(
          oldDb.select(
            "select name from sqlite_schema where name='maintenance_jobs'",
          ),
          isEmpty,
        );
      } finally {
        oldDb.close();
      }
    },
  );

  for (final fail in [false, true]) {
    test(
      'bootstrap ${fail ? 'failure' : 'stop'} leaves schema 15 resumable',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'csv_bootstrap_stop_',
        );
        addTearDown(() => temporary.delete(recursive: true));
        final file = File('${temporary.path}/viewer.sqlite');
        await DatabaseMigrator(
          sqlRoot: Directory('../sql'),
        ).openAndMigrate(file, deferUsageMigration: true);
        final operation = await DatabaseMaintenanceCoordinator(file).start(
          jobType: 'usage_projection_migration',
          initialPhase: 'bootstrap',
          bootstrapWorker: fail ? _failBootstrap : _stopBeforeMigration,
          worker: _assertBootstrapConnection,
        );
        expect(
          (await operation.result).state,
          fail
              ? DatabaseMaintenanceState.failed
              : DatabaseMaintenanceState.interrupted,
        );
        final reopened = openFileBackedDatabase(file);
        try {
          expect(
            reopened
                .select(
                  'select max(version) v from schema_version where success=1',
                )
                .single['v'],
            15,
          );
          expect(
            reopened.select(
              "select name from sqlite_schema where name='maintenance_jobs'",
            ),
            isEmpty,
          );
          expect(reopened.autocommit, isTrue);
        } finally {
          reopened.close();
        }
        final retry = await DatabaseMaintenanceCoordinator(file).start(
          jobType: 'usage_projection_migration',
          initialPhase: 'bootstrap',
          bootstrapWorker: _bootstrapSchemaAndJob,
          worker: _assertBootstrapConnection,
        );
        expect((await retry.result).succeeded, isTrue);
      },
    );
  }

  test('bootstrap precedes leases and retains the worker connection', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'csv_startup_bootstrap_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final file = File('${temporary.path}/viewer.sqlite');
    await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(file, deferUsageMigration: true);
    final operation = await DatabaseMaintenanceCoordinator(file).start(
      jobType: 'usage_projection_migration',
      initialPhase: 'bootstrap',
      bootstrapWorker: _bootstrapSchemaAndJob,
      worker: _assertBootstrapConnection,
    );
    final progress = operation.progress.toList();
    expect((await operation.result).succeeded, isTrue);
    expect(
      (await progress).any((item) => item.phase == 'bootstrap_schema'),
      isTrue,
    );
    final reopened = openFileBackedDatabase(file);
    try {
      expect(
        reopened
            .select('select max(version) v from schema_version where success=1')
            .single['v'],
        17,
      );
      expect(
        MaintenanceJobRepository(
          reopened,
        ).latestForType('usage_projection_migration')!.state,
        MaintenanceJobState.succeeded,
      );
    } finally {
      reopened.close();
    }
  });

  test('startup factory creates and resumes an inactive generation', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'csv_startup_usage_',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final file = File('${temporary.path}/viewer.sqlite');
    final startup = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(file);
    expect(startup.canStartNormalUi, isTrue);

    final operation = await startPendingDatabaseMigration(
      file,
      migrationWorker: _stopBeforeMigration,
    );
    expect(operation, isNotNull);
    expect(
      (await operation!.result).state,
      DatabaseMaintenanceState.interrupted,
    );
    final first = openFileBackedDatabase(file);
    late int generationId;
    late int jobId;
    try {
      final job = MaintenanceJobRepository(
        first,
      ).latestForType('usage_projection_migration')!;
      generationId = job.databaseGenerationId!;
      jobId = job.id;
      expect(first.select('pragma query_only').single.values.single, 1);
      expect(
        DatabaseGenerationRepository(
          first,
        ).activeGeneration().targetSchemaVersion,
        15,
      );
      expect(
        first.select('select state from database_generations where id = ?', [
          generationId,
        ]).single['state'],
        'building',
      );
    } finally {
      first.close();
    }

    final resumed = await startPendingDatabaseMigration(
      file,
      migrationWorker: _stopBeforeMigration,
    );
    expect((await resumed!.result).state, DatabaseMaintenanceState.interrupted);
    final reopened = openFileBackedDatabase(file);
    try {
      final job = MaintenanceJobRepository(
        reopened,
      ).latestForType('usage_projection_migration')!;
      expect(job.id, jobId);
      expect(job.databaseGenerationId, generationId);
      expect(
        reopened
            .select(
              "select count(*) n from database_generations where state = 'building'",
            )
            .single['n'],
        1,
      );
    } finally {
      reopened.close();
    }
  });

  test(
    'progress starts a fresh rate baseline for each phase and unit',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'csv_startup_rate_',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final file = File('${temporary.path}/viewer.sqlite');
      await DatabaseMigrator(sqlRoot: Directory('../sql')).openAndMigrate(file);
      final operation = await DatabaseMaintenanceCoordinator(file).start(
        jobType: 'usage_projection_migration',
        initialPhase: 'copy_events',
        worker: _publishPhaseRates,
      );
      final progress = operation.progress.toList();
      expect((await operation.result).succeeded, isTrue);
      final reports = (await progress)
          .where((item) => item.currentWork.startsWith('rate-test:'))
          .toList();
      expect(reports, hasLength(4));
      expect(
        reports[0].ratePerSecond,
        isNull,
        reason: 'Previously completed work is not new work in this run.',
      );
      expect(reports[0].estimatedRemaining, isNull);
      expect(reports[1].ratePerSecond, greaterThan(0));
      expect(
        reports[2].ratePerSecond,
        isNull,
        reason: 'A new phase has no measured rate yet.',
      );
      expect(reports[2].estimatedRemaining, isNull);
      expect(
        reports[3].ratePerSecond,
        isNull,
        reason: 'Different work units cannot share a throughput estimate.',
      );
    },
  );
}

Future<DatabaseMaintenanceWorkerOutcome> _stopBeforeMigration(
  DatabaseMaintenanceWorkerContext context,
) async => DatabaseMaintenanceWorkerOutcome.interrupted;

Future<DatabaseMaintenanceWorkerOutcome> _failBootstrap(
  DatabaseMaintenanceWorkerContext context,
) async => throw StateError('Injected bootstrap failure.');

Future<DiskVolumeSpace> _ampleSpace(Directory _) async =>
    const DiskVolumeSpace(volumeKey: 'fixture', availableBytes: 1 << 50);

Future<DatabaseMaintenanceWorkerOutcome> _verifiedBootstrap(
  DatabaseMaintenanceWorkerContext context,
) => UsageMigrationBootstrap(
  migrator: DatabaseMigrator(sqlRoot: Directory('../sql')),
  settings: const PricingSettings(
    provider: 'openrouter',
    useExternalPricing: true,
    fallbackToOverrides: false,
    openRouter: OpenRouterSettings(
      modelsEndpoint: 'https://DO_NOT_PERSIST.invalid',
      apiKey: 'DO_NOT_PERSIST',
    ),
    overrides: {},
  ),
  backupDirectory: Directory('${context.databaseFile.parent.path}/backups'),
  preflight: DatabaseMigrationPreflight(diskSpaceProbe: _ampleSpace),
).run(context);

Future<DatabaseMaintenanceWorkerOutcome> _completeUsageMigration(
  DatabaseMaintenanceWorkerContext context,
) => StartupUsageMigration(
  UsageMigrationBootstrap(
    migrator: DatabaseMigrator(sqlRoot: Directory('../sql')),
    settings: AppSettings.defaults().pricing,
    backupDirectory: Directory('${context.databaseFile.parent.path}/backups'),
    preflight: DatabaseMigrationPreflight(diskSpaceProbe: _ampleSpace),
  ),
).run(context);

Future<DatabaseMaintenanceWorkerOutcome> _bootstrapStopAtReady(
  DatabaseMaintenanceWorkerContext context,
) async {
  final outcome = await _verifiedBootstrap(context);
  context.database.execute(r'''
    create trigger stop_at_ready after update of state on database_generations
    when new.state='ready' begin
      update maintenance_jobs set payload_json=json_set(payload_json, '$.stop_requested', json('true'))
      where job_type='usage_projection_migration';
    end;
  ''');
  return outcome;
}

Future<DatabaseMaintenanceWorkerOutcome> _bootstrapStopDuringProjection(
  DatabaseMaintenanceWorkerContext context,
) async {
  final outcome = await _verifiedBootstrap(context);
  context.database.execute(r'''
    create trigger stop_during_projection after update of phase on maintenance_jobs
    when new.phase='project_usage' and json_extract(new.payload_json, '$.projected_session_count')=512 begin
      update maintenance_jobs set payload_json=json_set(payload_json, '$.stop_requested', json('true'))
      where job_type='usage_projection_migration';
    end;
  ''');
  return outcome;
}

Future<DatabaseMaintenanceWorkerOutcome> _bootstrapStopDuringPrices(
  DatabaseMaintenanceWorkerContext context,
) async {
  final outcome = await _verifiedBootstrap(context);
  context.database.execute(r'''
    create trigger stop_during_prices after update of phase on maintenance_jobs
    when new.phase='initialize_prices' and json_extract(new.payload_json, '$.migrated_price_count')=512 begin
      update maintenance_jobs set payload_json=json_set(payload_json, '$.stop_requested', json('true'))
      where job_type='usage_projection_migration';
    end;
  ''');
  return outcome;
}

Future<DatabaseMaintenanceWorkerOutcome> _commitCutoverWithoutCheckpoint(
  DatabaseMaintenanceWorkerContext context,
) async {
  try {
    return await _completeUsageMigration(context);
  } on DatabaseMaintenanceCancelled {
    final job = context.jobs.read(context.lease.jobId)!;
    if (job.phase != 'cutover') rethrow;
    DatabaseGenerationRepository(
      context.database,
    ).activate(job.databaseGenerationId!);
    return DatabaseMaintenanceWorkerOutcome.interrupted;
  }
}

Future<DatabaseMaintenanceWorkerOutcome> _reclaimedBeforeValidation(
  DatabaseMaintenanceWorkerContext context,
) async {
  // Reproduce the durable token change made by a replacement claimant. The old
  // worker still holds its original lease and must not mutate generation state.
  context.database.execute(
    "update maintenance_jobs set run_token='replacement-owner' where id=?",
    [context.lease.jobId],
  );
  return _completeUsageMigration(context);
}

Future<DatabaseMaintenanceWorkerOutcome> _abandonAfterCleanup(
  DatabaseMaintenanceWorkerContext context,
) async {
  await _completeUsageMigration(context);
  context.database.close();
  Isolate.exit();
}

Future<DatabaseMaintenanceWorkerOutcome> _mismatchedBackupBootstrap(
  DatabaseMaintenanceWorkerContext context,
) => UsageMigrationBootstrap(
  migrator: DatabaseMigrator(sqlRoot: Directory('../sql')),
  settings: AppSettings.defaults().pricing,
  backupDirectory: Directory('${context.databaseFile.parent.path}/backups'),
  preflight: DatabaseMigrationPreflight(diskSpaceProbe: _ampleSpace),
  backupService: SqliteBackupService(backupStreamFactory: _wrongBackupIdentity),
).run(context);

Stream<double> _wrongBackupIdentity({
  required Database source,
  required Database destination,
  required int pagesPerStep,
}) async* {
  await for (final progress in source.backup(
    destination,
    nPage: pagesPerStep,
  )) {
    if (progress == 1) {
      destination.execute(
        "update app_metadata set value=json_set(value, '\$.identity', 'mismatched') where key='usage_migration_bootstrap'",
      );
    }
    yield progress;
  }
}

Future<DatabaseMaintenanceWorkerOutcome> _bootstrapFailBefore16(
  DatabaseMaintenanceWorkerContext context,
) => UsageMigrationBootstrap(
  migrator: _FailBefore16Migrator(),
  settings: AppSettings.defaults().pricing,
  backupDirectory: Directory('${context.databaseFile.parent.path}/backups'),
  preflight: DatabaseMigrationPreflight(diskSpaceProbe: _ampleSpace),
).run(context);

class _FailBefore16Migrator extends DatabaseMigrator {
  _FailBefore16Migrator() : super(sqlRoot: Directory('../sql'));

  @override
  Future<DatabaseStartupResult> migrateOpenDatabase(
    Database db,
    File databaseFile, {
    bool deferUsageMigration = false,
    Future<void> Function(void Function())? runAtomic,
  }) async => throw StateError('Injected loss before schema 16.');
}

Future<DatabaseMaintenanceWorkerOutcome> _bootstrapSchemaAndJob(
  DatabaseMaintenanceWorkerContext context,
) async {
  if (context.stopRequested) {
    return DatabaseMaintenanceWorkerOutcome.interrupted;
  }
  context.publish(
    state: DatabaseMaintenanceState.running,
    phase: 'bootstrap_schema',
    currentWork: 'Preparing schema before the lease exists.',
    unitLabel: 'steps',
    completedUnits: 0,
    totalUnits: null,
  );
  context.database.execute('create temp table bootstrap_owner (value integer)');
  context.database.execute('insert into bootstrap_owner values (73)');
  final result = await DatabaseMigrator(sqlRoot: Directory('../sql'))
      .migrateOpenDatabase(
        context.database,
        context.databaseFile,
        runAtomic: context.runAtomic,
      );
  if (!result.canStartNormalUi) throw StateError(result.fatalError!.details);
  context.jobs.enqueue(
    jobType: 'usage_projection_migration',
    phase: 'prepared',
  );
  return DatabaseMaintenanceWorkerOutcome.succeeded;
}

Future<DatabaseMaintenanceWorkerOutcome> _assertBootstrapConnection(
  DatabaseMaintenanceWorkerContext context,
) async {
  if (context.database
              .select('select value from temp.bootstrap_owner')
              .single['value'] !=
          73 ||
      context.jobs.read(context.lease.jobId)!.phase != 'prepared') {
    throw StateError('Bootstrap did not hand off its connection and lease.');
  }
  return DatabaseMaintenanceWorkerOutcome.succeeded;
}

Future<DatabaseMaintenanceWorkerOutcome> _publishPhaseRates(
  DatabaseMaintenanceWorkerContext context,
) async {
  void report(String phase, String unit, int completed, String label) {
    context.publish(
      state: DatabaseMaintenanceState.running,
      phase: phase,
      currentWork: 'rate-test:$label',
      unitLabel: unit,
      completedUnits: completed,
      totalUnits: 1000,
    );
  }

  await Future<void>.delayed(const Duration(milliseconds: 20));
  report('copy_events', 'events', 100, 'resumed');
  await Future<void>.delayed(const Duration(milliseconds: 20));
  report('copy_events', 'events', 110, 'new work');
  report('initialize_prices', 'models', 110, 'new phase');
  report('initialize_prices', 'rules', 110, 'new unit');
  return DatabaseMaintenanceWorkerOutcome.succeeded;
}
