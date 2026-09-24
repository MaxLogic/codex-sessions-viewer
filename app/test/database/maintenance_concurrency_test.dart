import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show AppExitResponse;

import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/app/runtime_session_controller.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_backup.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_generation.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance_cancelled.dart';
import 'package:codex_sessions_viewer/src/database/database_migration_preflight.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late File databaseFile;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp(
      'csv_maintenance_concurrency_',
    );
    databaseFile = File('${temp.path}${Platform.pathSeparator}viewer.sqlite');
    final startup = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('only one connection claims an active maintenance job', () {
    final firstDb = openFileBackedDatabase(databaseFile);
    final secondDb = openFileBackedDatabase(databaseFile);
    addTearDown(firstDb.close);
    addTearDown(secondDb.close);
    var token = 0;
    final firstJobs = MaintenanceJobRepository(
      firstDb,
      tokenFactory: () => 'token-${++token}',
      ownerProcessId: 1,
    );
    final secondJobs = MaintenanceJobRepository(
      secondDb,
      tokenFactory: () => 'token-${++token}',
      ownerProcessId: 2,
    );
    firstJobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'preflight',
    );

    final first = firstJobs.claim(
      jobType: 'usage_projection_migration',
      leaseDuration: const Duration(minutes: 1),
    );
    final second = secondJobs.claim(
      jobType: 'usage_projection_migration',
      leaseDuration: const Duration(minutes: 1),
    );

    expect(first, isNotNull);
    expect(second, isNull);
    expect(
      firstJobs.latestForType('usage_projection_migration')!.attemptCount,
      1,
    );
  });

  test('different maintenance job types still share one writer slot', () {
    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    final jobs = MaintenanceJobRepository(db);
    jobs.enqueue(jobType: 'usage_projection_migration', phase: 'copy_events');
    jobs.enqueue(jobType: 'database_optimize', phase: 'optimize');
    final migration = jobs.claim(
      jobType: 'usage_projection_migration',
      leaseDuration: const Duration(minutes: 1),
    )!;

    expect(
      jobs.claim(
        jobType: 'database_optimize',
        leaseDuration: const Duration(minutes: 1),
      ),
      isNull,
    );
    jobs.markSucceeded(
      migration,
      phase: 'complete',
      statusMessage: 'Migration complete.',
    );
    expect(
      jobs.claim(
        jobType: 'database_optimize',
        leaseDuration: const Duration(minutes: 1),
      ),
      isNotNull,
    );
  });

  test(
    'injected startup worker detects and resumes unfinished migration work',
    () async {
      final db = openFileBackedDatabase(databaseFile);
      // No work is needed only when persisted storage is already active.
      // Fresh/inactive generation admission has its own startup factory test.
      final generations = DatabaseGenerationRepository(db);
      final generation = generations.createBuilding(
        sourceSchemaVersion: 15,
        targetSchemaVersion: 16,
        sourceFingerprint: 'empty test fixture',
      );
      generations.markReady(generation.id, validationReportJson: '{}');
      generations.activate(generation.id);
      expect(
        await startPendingDatabaseMigration(
          databaseFile,
          migrationWorker: _succeedImmediately,
        ),
        isNull,
      );
      final jobs = MaintenanceJobRepository(db);
      jobs.enqueue(jobType: 'usage_projection_migration', phase: 'copy_events');
      db.close();
      final resumedStartup = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(databaseFile);
      expect(resumedStartup.canStartNormalUi, isTrue);
      final rejected = await startPendingDatabaseMigration(databaseFile);
      expect((await rejected!.result).state, DatabaseMaintenanceState.failed);
      final operation = await startPendingDatabaseMigration(
        databaseFile,
        migrationWorker: _succeedImmediately,
      );
      expect(operation, isNotNull);
      expect((await operation!.result).succeeded, isTrue);
      expect(
        await startPendingDatabaseMigration(
          databaseFile,
          migrationWorker: _succeedImmediately,
        ),
        isNull,
      );
    },
  );

  testWidgets('startup maintenance blocks normal application writers', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final progress = StreamController<DatabaseMaintenanceProgress>();
    final result = Completer<DatabaseMaintenanceResult>();
    addTearDown(progress.close);
    var maintenanceStarts = 0;
    var deferredSessionLoads = 0;
    var usageLoads = 0;
    final coordinator = DatabaseMaintenanceCoordinator(databaseFile);

    try {
      await tester.pumpWidget(
        CodexSessionsViewerApp(
          databaseFile: databaseFile,
          writerCoordinator: coordinator,
          databaseStartup: Future.value(
            DatabaseStartupResult.ready(lastAppliedSchemaVersion: 16),
          ),
          settingsStartup: Future.value(AppSettings.defaults()),
          databaseMaintenanceStartup: () async {
            maintenanceStarts++;
            return DatabaseMaintenanceOperation(
              result: result.future,
              progress: progress.stream,
              requestStop: () async {},
            );
          },
          deferInitialSessionLoad: (_) {
            deferredSessionLoads++;
          },
          sessionCachedRowsLoader: (_) async =>
              const SessionsRefreshResult(rows: [], statusMessage: 'Loaded.'),
          usageSummaryLoader: (_, _) async {
            usageLoads++;
            return null;
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      progress.add(
        const DatabaseMaintenanceProgress(
          state: DatabaseMaintenanceState.running,
          phase: 'Copying usage events',
          currentWork: 'Copied 2 of 5 events.',
          unitLabel: 'events',
          completedUnits: 2,
          totalUnits: 5,
          ratePerSecond: 10,
          elapsed: Duration(seconds: 1),
          estimatedRemaining: Duration(milliseconds: 300),
          walBytes: 4096,
        ),
      );
      await tester.pump();

      expect(maintenanceStarts, 1);
      expect(deferredSessionLoads, 0);
      expect(usageLoads, 0);
      expect(find.text('Copied 2 of 5 events.'), findsOneWidget);

      result.complete(
        const DatabaseMaintenanceResult(
          state: DatabaseMaintenanceState.succeeded,
        ),
      );
      await tester.pumpAndSettle();

      expect(deferredSessionLoads, greaterThan(0));
      expect(usageLoads, 0);
      await tester.tap(
        find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')),
      );
      await tester.pumpAndSettle();
      expect(usageLoads, 1);
    } finally {
      if (!result.isCompleted) {
        result.complete(
          const DatabaseMaintenanceResult(
            state: DatabaseMaintenanceState.interrupted,
          ),
        );
      }
      // Reaching normal UI starts a real message-search worker. Widget dispose
      // signals cancellation but cannot join it; use the awaitable exit path
      // before the enclosing fixture deletes this Windows-owned database.
      var exitCompleted = false;
      final exit = tester.binding.handleRequestAppExit().then((response) {
        exitCompleted = true;
        return response;
      });
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!exitCompleted) {
        expect(
          DateTime.now().isBefore(deadline),
          isTrue,
          reason: 'Timed out joining startup-test background writers.',
        );
        // Native worker events and fake-zone callbacks both need to drain.
        // This polls completion, not an assumed worker duration.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(await exit, AppExitResponse.exit);
      var writerIdle = false;
      unawaited(coordinator.idle.then((_) => writerIdle = true));
      await tester.pump();
      expect(writerIdle, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        final renamed = await databaseFile.rename(
          '${databaseFile.path}.closed',
        );
        await renamed.rename(databaseFile.path);
      });
    }
  });

  test(
    'completed message backfill workers release SQLite before reporting done',
    () async {
      final controller = RuntimeSessionController(
        databaseFile: databaseFile,
        settingsFile: File('${temp.path}/settings.toml'),
      );
      for (var attempt = 0; attempt < 50; attempt++) {
        final result = await controller
            .startMessageSearchBackfillInBackgroundOperation()
            .result;
        expect(result.complete, isTrue);
        final renamed = await databaseFile.rename(
          '${databaseFile.path}.closed',
        );
        await renamed.rename(databaseFile.path);
      }
    },
  );

  testWidgets('disposing startup gate does not outlive its progress notifier', (
    tester,
  ) async {
    final progress = StreamController<DatabaseMaintenanceProgress>();
    final result = Completer<DatabaseMaintenanceResult>();
    addTearDown(progress.close);
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseFile: databaseFile,
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 16),
        ),
        settingsStartup: Future.value(AppSettings.defaults()),
        databaseMaintenanceStartup: () async => DatabaseMaintenanceOperation(
          result: result.future,
          progress: progress.stream,
          requestStop: () async {},
        ),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox());

    result.complete(
      const DatabaseMaintenanceResult(
        state: DatabaseMaintenanceState.failed,
        errorMessage: 'Expected test failure.',
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('graceful exit waits for the maintenance safe boundary', (
    tester,
  ) async {
    final result = Completer<DatabaseMaintenanceResult>();
    var stopCalls = 0;
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseFile: databaseFile,
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 16),
        ),
        databaseMaintenanceStartup: () async => DatabaseMaintenanceOperation(
          result: result.future,
          progress: const Stream.empty(),
          requestStop: () async {
            stopCalls++;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    var exitCompleted = false;
    final exit = tester.binding.handleRequestAppExit().then((value) {
      exitCompleted = true;
      return value;
    });
    await tester.pump();
    expect(stopCalls, 1);
    expect(exitCompleted, isFalse);
    result.complete(
      const DatabaseMaintenanceResult(
        state: DatabaseMaintenanceState.interrupted,
      ),
    );
    await tester.pump();
    expect(await exit, AppExitResponse.exit);
  });

  test(
    'online backup includes committed WAL data and restores cleanly',
    () async {
      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      db.execute('create table backup_probe (value text not null)');
      db.execute(
        "insert into backup_probe (value) values ('committed-in-wal')",
      );
      final progress = <double>[];
      final service = SqliteBackupService();

      final backup = await service.create(
        source: db,
        databaseFile: databaseFile,
        backupDirectory: Directory(
          '${temp.path}${Platform.pathSeparator}backup',
        ),
        backupName: 'before-migration.sqlite',
        onProgress: progress.add,
      );

      expect(await backup.file.exists(), isTrue);
      expect(backup.lengthBytes, greaterThan(0));
      expect(backup.sha256, hasLength(64));
      expect(backup.sqliteVersion, isNotEmpty);
      expect(progress, isNotEmpty);
      expect(progress.last, 1);
      expect(_isMonotonic(progress), isTrue);
      expect(await File('${backup.file.path}.partial').exists(), isFalse);

      final restoredFile = File(
        '${temp.path}${Platform.pathSeparator}restored.sqlite',
      );
      await service.restore(backup: backup.file, destinationFile: restoredFile);
      final restored = openFileBackedDatabase(restoredFile);
      addTearDown(restored.close);
      expect(
        restored.select('select value from backup_probe').single.values.single,
        'committed-in-wal',
      );
      expect(
        restored.select('pragma integrity_check').single.values.single,
        'ok',
      );
      expect(restored.select('pragma foreign_key_check'), isEmpty);
    },
  );

  test('migration preflight refuses insufficient volume headroom', () async {
    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    final jobs = MaintenanceJobRepository(db);
    final job = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'preflight',
    );
    final lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 1),
    )!;
    final backupDirectory = Directory(
      '${temp.path}${Platform.pathSeparator}preflight-backup',
    );
    final preflight = DatabaseMigrationPreflight(
      diskSpaceProbe: (directory) async =>
          const DiskVolumeSpace(volumeKey: 'test-volume', availableBytes: 0),
    );

    await expectLater(
      preflight.run(
        database: db,
        jobs: jobs,
        lease: lease,
        databaseFile: databaseFile,
        backupDirectory: backupDirectory,
        temporaryDirectory: temp,
      ),
      throwsA(isA<InsufficientMigrationSpaceException>()),
    );
    expect(await backupDirectory.exists(), isFalse);
  });

  test('migration preflight persists verified backup evidence', () async {
    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    final jobs = MaintenanceJobRepository(db);
    final job = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'preflight',
    );
    final lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 1),
    )!;
    final backupDirectory = Directory(
      '${temp.path}${Platform.pathSeparator}preflight-backup',
    );
    final preflight = DatabaseMigrationPreflight(
      diskSpaceProbe: (directory) async => const DiskVolumeSpace(
        volumeKey: 'test-volume',
        availableBytes: 1 << 50,
      ),
    );

    final result = await preflight.run(
      database: db,
      jobs: jobs,
      lease: lease,
      databaseFile: databaseFile,
      backupDirectory: backupDirectory,
      temporaryDirectory: temp,
    );

    expect(await result.backup.file.exists(), isTrue);
    expect(result.backup.sha256, hasLength(64));
    final persisted = jobs.read(job.id)!;
    expect(persisted.phase, 'backup_complete');
    final payload = jsonDecode(persisted.payloadJson!) as Map<String, dynamic>;
    final backupEvidence = payload['backup'] as Map<String, dynamic>;
    expect(backupEvidence['path'], result.backup.file.path);
    expect(backupEvidence['sha256'], result.backup.sha256);
    expect(backupEvidence['restore'], isNotEmpty);
  });

  test('migration preflight replaces an abandoned partial backup', () async {
    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    final jobs = MaintenanceJobRepository(db);
    final job = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'preflight',
    );
    final lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 1),
    )!;
    final backupDirectory = Directory(
      '${temp.path}${Platform.pathSeparator}preflight-backup',
    );
    await backupDirectory.create();
    final partial = File(
      '${backupDirectory.path}${Platform.pathSeparator}'
      'usage-projection-job-${job.id}.sqlite.partial',
    );
    await partial.writeAsString('abandoned partial copy');
    final preflight = DatabaseMigrationPreflight(
      diskSpaceProbe: (directory) async => const DiskVolumeSpace(
        volumeKey: 'test-volume',
        availableBytes: 1 << 50,
      ),
    );

    final result = await preflight.run(
      database: db,
      jobs: jobs,
      lease: lease,
      databaseFile: databaseFile,
      backupDirectory: backupDirectory,
      temporaryDirectory: temp,
    );

    expect(await result.backup.file.exists(), isTrue);
    expect(await partial.exists(), isFalse);
  });

  test(
    'failed backup removes partial output and leaves source unchanged',
    () async {
      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      db.execute('create table backup_probe (value text not null)');
      db.execute("insert into backup_probe (value) values ('source-value')");
      final backupDirectory = Directory(
        '${temp.path}${Platform.pathSeparator}backup-failure',
      );
      final service = SqliteBackupService(
        backupStreamFactory:
            ({
              required source,
              required destination,
              required pagesPerStep,
            }) async* {
              yield 0.25;
              throw StateError('injected backup failure');
            },
      );

      await expectLater(
        service.create(
          source: db,
          databaseFile: databaseFile,
          backupDirectory: backupDirectory,
          backupName: 'failed.sqlite',
        ),
        throwsStateError,
      );

      expect(
        await File('${backupDirectory.path}/failed.sqlite').exists(),
        isFalse,
      );
      expect(
        await File('${backupDirectory.path}/failed.sqlite.partial').exists(),
        isFalse,
      );
      expect(
        db.select('select value from backup_probe').single.values.single,
        'source-value',
      );
    },
  );

  test('backup publish refuses a final file created during the copy', () async {
    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    final backupDirectory = Directory(
      '${temp.path}${Platform.pathSeparator}backup-publish-race',
    );
    final backupFile = File(
      '${backupDirectory.path}${Platform.pathSeparator}race.sqlite',
    );
    const sentinel = 'created by another process';
    final service = SqliteBackupService(
      beforePublish: (_) async {
        await backupFile.writeAsString(sentinel);
      },
    );

    await expectLater(
      service.create(
        source: db,
        databaseFile: databaseFile,
        backupDirectory: backupDirectory,
        backupName: 'race.sqlite',
      ),
      throwsStateError,
    );

    expect(await backupFile.readAsString(), sentinel);
    expect(await File('${backupFile.path}.partial').exists(), isFalse);
  });

  test(
    'restore publish refuses a final file created during the copy',
    () async {
      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      final backupDirectory = Directory(
        '${temp.path}${Platform.pathSeparator}restore-publish-race',
      );
      final backup = await SqliteBackupService().create(
        source: db,
        databaseFile: databaseFile,
        backupDirectory: backupDirectory,
        backupName: 'source.sqlite',
      );
      final restoredFile = File(
        '${temp.path}${Platform.pathSeparator}restore-race.sqlite',
      );
      const sentinel = 'created by another process';
      final service = SqliteBackupService(
        beforePublish: (_) async {
          await restoredFile.writeAsString(sentinel);
        },
      );

      await expectLater(
        service.restore(backup: backup.file, destinationFile: restoredFile),
        throwsStateError,
      );

      expect(await restoredFile.readAsString(), sentinel);
      expect(await File('${restoredFile.path}.partial').exists(), isFalse);
    },
  );

  test('generation cutover is atomic and stale rollback is refused', () {
    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    final generations = DatabaseGenerationRepository(db);
    final legacyId = generations.activeGeneration().id;
    expect(generations.activeGeneration().targetSchemaVersion, 15);
    final building = generations.createBuilding(
      sourceSchemaVersion: 15,
      targetSchemaVersion: 16,
      sourceFingerprint: 'source-hash',
    );
    generations.markReady(building.id, validationReportJson: '{}');

    expect(
      () => generations.activate(
        building.id,
        beforeCommit: () => throw StateError('injected cutover failure'),
      ),
      throwsStateError,
    );
    expect(generations.activeGeneration().id, legacyId);
    expect(
      db.select("pragma table_info('usage_events')").map((row) => row['name']),
      contains('project_id'),
    );
    expect(
      db.select(
        "select name from sqlite_master where name = 'usage_events_legacy'",
      ),
      isEmpty,
    );
    expect(
      () => generations.activate(
        building.id,
        beforeCommit: () {
          // SQLite interruption can already have rolled back an atomic transaction.
          db.execute('rollback');
          throw StateError('original interrupted cutover');
        },
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'original interrupted cutover',
        ),
      ),
    );

    generations.activate(building.id);
    expect(generations.activeGeneration().id, building.id);
    expect(
      db.select("pragma table_info('usage_events')").map((row) => row['name']),
      contains('path_context_id'),
    );
    expect(
      db.select("pragma table_info('usage_events')").map((row) => row['name']),
      isNot(contains('project_id')),
    );
    expect(
      db.select(
        "select name from sqlite_master where name = 'usage_events_next'",
      ),
      isEmpty,
    );
    expect(generations.rollbackTo(legacyId), isTrue);
    expect(generations.activeGeneration().id, legacyId);
    expect(
      db.select("pragma table_info('usage_events')").map((row) => row['name']),
      contains('project_id'),
    );
    expect(
      db.select(
        "select name from sqlite_master where name = 'usage_events_next'",
      ),
      hasLength(1),
    );

    generations.activate(building.id);
    generations.markNormalWritesResumed();
    expect(generations.rollbackTo(legacyId), isFalse);
    expect(generations.activeGeneration().id, building.id);
    expect(() => generations.activate(legacyId), throwsStateError);
    expect(generations.activeGeneration().id, building.id);
  });

  test(
    'shared writer queue orders edits and maintenance and ages waiting work',
    () async {
      var now = DateTime.utc(2026, 9, 7);
      final coordinator = DatabaseMaintenanceCoordinator(
        databaseFile,
        clock: () => now,
      );
      final release = Completer<void>();
      final first = coordinator.runWriter(() => release.future);
      await Future<void>.delayed(Duration.zero);
      final seen = <String>[];
      Future<void> queue(String label, DatabaseWriterPriority priority) =>
          coordinator.runWriter(() async {
            seen.add(label);
          }, priority: priority);
      final optimize = queue('optimize', DatabaseWriterPriority.optimize);
      now = now.add(const Duration(minutes: 4));
      final pricing = queue('pricing', DatabaseWriterPriority.pricing);
      final edit = queue('edit', DatabaseWriterPriority.interactive);
      final repair = queue('repair', DatabaseWriterPriority.repair);
      final migration = queue('migration', DatabaseWriterPriority.migration);
      final failing = coordinator.runWriter(
        () async => throw StateError('fixture failure'),
      );
      final failed = expectLater(failing, throwsStateError);
      expect(seen, isEmpty);
      release.complete();
      await Future.wait([
        first,
        optimize,
        pricing,
        edit,
        repair,
        migration,
        failed,
      ]);
      await coordinator.idle;
      expect(seen, ['migration', 'optimize', 'repair', 'edit', 'pricing']);
      // A failed task does not poison the next drain.
      await queue('later', DatabaseWriterPriority.interactive);
      expect(seen.last, 'later');
    },
  );

  test(
    'repricing yields after committed progress and resumes behind ordinary writers',
    () async {
      final seed = openFileBackedDatabase(databaseFile);
      seed.execute('create table yield_probe (value integer not null)');
      seed.close();
      final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
      final operation = await coordinator.start(
        jobType: 'usage_cost_repricing',
        initialPhase: 'reprice_costs',
        worker: _yieldAtCheckpointProbe,
        totalUnits: 2,
        yieldToQueuedWriters: true,
      );
      final firstProgress = operation.progress.firstWhere(
        (value) =>
            value.currentWork == 'Waiting before first committed partition.',
      );
      var wrote = false;
      Future<void>? writer;
      try {
        await firstProgress;
        writer = coordinator.runWriter(() async {
          // Windows refuses this rename while the worker still owns SQLite.
          final renamed = databaseFile.renameSync(
            '${databaseFile.path}.yielded',
          );
          renamed.renameSync(databaseFile.path);
          final db = openFileBackedDatabase(databaseFile);
          try {
            final job = MaintenanceJobRepository(
              db,
            ).latestForType('usage_cost_repricing')!;
            expect(job.state, MaintenanceJobState.interrupted);
            expect(job.completedUnits, 1);
            expect(job.lastProcessedRowId, 1);
            expect(
              db.select('select value from yield_probe').single['value'],
              1,
            );
            db.execute('insert into yield_probe values (99)');
            wrote = true;
          } finally {
            db.close();
          }
        });
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          wrote,
          isFalse,
          reason: 'An initial progress event is not a committed partition.',
        );
        await File('${temp.path}/allow-first-partition').writeAsString('ready');
        await writer.timeout(const Duration(seconds: 2));
        expect(wrote, isTrue);
        expect(
          (await operation.result).state,
          DatabaseMaintenanceState.interrupted,
        );
      } finally {
        await operation.requestStop();
        await operation.result;
        await writer;
      }
      final resumed = await coordinator.start(
        jobType: 'usage_cost_repricing',
        initialPhase: 'reprice_costs',
        worker: _yieldAtCheckpointProbe,
        totalUnits: 2,
        yieldToQueuedWriters: true,
      );
      expect((await resumed.result).state, DatabaseMaintenanceState.succeeded);
      final db = openFileBackedDatabase(databaseFile);
      try {
        expect(
          db
              .select('select value from yield_probe order by rowid')
              .map((row) => row['value']),
          [1, 99, 2],
        );
        final job = MaintenanceJobRepository(
          db,
        ).latestForType('usage_cost_repricing')!;
        expect(job.completedUnits, 2);
        expect(job.attemptCount, 2);
      } finally {
        db.close();
      }
    },
  );

  for (final priority in [
    DatabaseWriterPriority.interactive,
    DatabaseWriterPriority.scan,
  ]) {
    test(
      'repricing yields when a ${priority.name} writer arrives after the checkpoint',
      () async {
        final seed = openFileBackedDatabase(databaseFile);
        seed.execute('create table yield_probe (value integer not null)');
        seed.close();
        await File('${temp.path}/allow-first-partition').writeAsString('ready');
        final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
        final operation = await coordinator.start(
          jobType: 'usage_cost_repricing',
          initialPhase: 'reprice_costs',
          worker: _yieldAtCheckpointProbe,
          yieldToQueuedWriters: true,
        );
        Future<int>? writer;
        try {
          await operation.progress.firstWhere(
            (value) => value.completedUnits == 1,
          );
          writer = coordinator.runWriter(() async => 42, priority: priority);
          expect(await writer.timeout(const Duration(seconds: 2)), 42);
          expect(
            (await operation.result).state,
            DatabaseMaintenanceState.interrupted,
          );
        } finally {
          await operation.requestStop();
          await operation.result;
          await writer;
        }
      },
    );
  }

  test('migration cannot opt into ordinary writer preemption', () async {
    final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
    await expectLater(
      coordinator.start(
        jobType: 'usage_projection_migration',
        initialPhase: 'copy_events',
        worker: _succeedImmediately,
        yieldToQueuedWriters: true,
      ),
      throwsArgumentError,
    );
    await expectLater(
      coordinator.start(
        jobType: 'usage_cost_repricing',
        initialPhase: 'build_indexes',
        worker: _succeedImmediately,
        atomicPhases: const {'build_indexes'},
        yieldToQueuedWriters: true,
      ),
      throwsArgumentError,
    );
  });

  test('queued maintenance can be stopped before it opens a worker', () async {
    final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
    final release = Completer<void>();
    final first = coordinator.runWriter(() => release.future);
    await Future<void>.delayed(Duration.zero);
    final pending = await coordinator.start(
      jobType: 'database_optimize',
      initialPhase: 'optimize',
      worker: _succeedImmediately,
    );
    await pending.requestStop();
    release.complete();
    await first;
    expect((await pending.result).state, DatabaseMaintenanceState.interrupted);
    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    expect(
      MaintenanceJobRepository(db).latestForType('database_optimize'),
      isNull,
    );
  });

  test('one coordinator queues maintenance behind its active writer', () async {
    final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
    final first = await coordinator.start(
      jobType: 'queue_hold',
      initialPhase: 'hold',
      worker: _waitForQueueStop,
    );
    addTearDown(() async {
      await first.requestStop();
      await first.result;
    });
    await first.progress.firstWhere(
      (progress) => progress.currentWork == 'Queue holder ready.',
    );
    final second = await coordinator.start(
      jobType: 'database_optimize',
      initialPhase: 'optimize',
      worker: _succeedImmediately,
    );
    // Let the second worker reach the already-held lease in the old behavior.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    await first.requestStop();
    expect((await first.result).state, DatabaseMaintenanceState.interrupted);
    expect((await second.result).state, DatabaseMaintenanceState.succeeded);
  });

  test('stop request returns while an atomic writer owns SQLite', () async {
    final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
    final operation = await coordinator.start(
      jobType: 'atomic_stop_probe',
      initialPhase: 'atomic_probe',
      worker: _holdAtomicWriter,
    );
    final atomicStarted = operation.progress.firstWhere(
      (progress) => progress.currentWork == 'Atomic writer owns SQLite.',
    );
    await atomicStarted;

    final stopwatch = Stopwatch()..start();
    await operation.requestStop();
    stopwatch.stop();

    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(
      (await operation.result).state,
      DatabaseMaintenanceState.interrupted,
    );
  });

  test('instant workers cannot lose completion to isolate exit', () async {
    final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
    for (var attempt = 0; attempt < 20; attempt++) {
      final operation = await coordinator.start(
        jobType: 'instant_worker_$attempt',
        initialPhase: 'instant',
        worker: _succeedImmediately,
      );
      expect(
        (await operation.result).state,
        DatabaseMaintenanceState.succeeded,
      );
    }
  });

  test(
    'stop interrupts a running index without advancing its checkpoint',
    () async {
      final seed = openFileBackedDatabase(databaseFile);
      seed.execute(
        'create table interrupt_index_probe (value integer not null)',
      );
      seed.execute('''
      with recursive values_to_index(value) as (
        select 1 union all select value + 1 from values_to_index where value < 200
      )
      insert into interrupt_index_probe select value from values_to_index
    ''');
      seed.close();
      final operation = await DatabaseMaintenanceCoordinator(databaseFile)
          .start(
            jobType: 'interrupt_index_probe',
            initialPhase: 'build_indexes',
            atomicPhases: const {'build_indexes'},
            worker: _buildSlowIndex,
          );
      await operation.progress.firstWhere(
        (progress) => progress.currentWork == 'SQLite index statement running.',
      );
      final stopwatch = Stopwatch()..start();
      await operation.requestStop();
      final result = await operation.result;
      stopwatch.stop();

      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      final job = MaintenanceJobRepository(
        db,
      ).latestForType('interrupt_index_probe')!;
      expect(
        job.completedUnits,
        7,
        reason: 'An interrupted index must not commit.',
      );
      expect(job.lastProcessedRowId, 7);
      expect(
        db.select(
          "select name from sqlite_master where name = 'idx_interrupt_probe'",
        ),
        isEmpty,
      );
      expect(
        result.state,
        DatabaseMaintenanceState.interrupted,
        reason: result.errorMessage,
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(
        db
            .select('select count(*) from interrupt_index_probe')
            .single
            .values
            .single,
        200,
      );
      expect(db.select('pragma integrity_check').single.values.single, 'ok');
      expect(db.select('pragma foreign_key_check'), isEmpty);
      final retry = await DatabaseMaintenanceCoordinator(databaseFile).start(
        jobType: 'interrupt_index_probe',
        initialPhase: 'build_indexes',
        atomicPhases: const {'build_indexes'},
        worker: _resumeInterruptedIndex,
      );
      expect((await retry.result).state, DatabaseMaintenanceState.succeeded);
      final jobs = MaintenanceJobRepository(db);
      expect(jobs.read(job.id)!.state, MaintenanceJobState.failed);
      final retried = jobs.latestForType('interrupt_index_probe')!;
      expect(retried.id, isNot(job.id));
      expect(retried.completedUnits, 8);
      expect(
        db.select(
          "select name from sqlite_master where name = 'idx_interrupt_probe'",
        ),
        hasLength(1),
      );
      // A delayed UI stop callback must not touch an already closed native handle.
      await operation.requestStop();
      await retry.requestStop();
    },
  );

  test(
    'worker failure exposes its recovery reason and durable phase',
    () async {
      final operation = await DatabaseMaintenanceCoordinator(databaseFile)
          .start(
            jobType: 'failure_probe',
            initialPhase: 'verify_backup',
            worker: _failBackupVerification,
          );
      final result = await operation.result;
      expect(result.state, DatabaseMaintenanceState.failed);
      expect(result.errorMessage, contains('Backup verification mismatch'));
      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      expect(
        MaintenanceJobRepository(db).latestForType('failure_probe')!.phase,
        'verify_backup',
      );
    },
  );

  for (final phasePublished in [false, true]) {
    test(
      'explicit atomic stop ${phasePublished ? 'after' : 'before'} phase publication interrupts idle-to-SQL entry',
      () async {
        final seed = openFileBackedDatabase(databaseFile);
        seed.execute(
          'create table interrupt_index_probe (value integer not null)',
        );
        seed.execute('''
          with recursive probe(value) as (
            select 1 union all select value + 1 from probe where value < 200
          ) insert into interrupt_index_probe select value from probe
        ''');
        seed.execute('create table atomic_recovery_probe (value integer)');
        seed.close();
        final operation = await DatabaseMaintenanceCoordinator(databaseFile)
            .start(
              jobType: 'explicit_atomic_probe',
              initialPhase: 'prepare',
              worker: phasePublished
                  ? _stopAfterAtomicPhase
                  : _stopBeforeAtomicPhase,
              atomicPhases: const {'build_indexes'},
            );
        await operation.progress.firstWhere(
          (progress) =>
              progress.currentWork == 'Atomic section idle at test gate.',
        );
        await operation.requestStop();
        // The worker is synchronously idle, unable to consume its Stop message.
        // The initial native interrupt therefore cannot cancel the next SQL.
        File('${temp.path}/atomic-test-release').writeAsStringSync('release');
        final result = await operation.result;
        // Neither the old Stop callback nor a timer may retain the closed handle.
        await operation.requestStop();
        final renamed = File('${temp.path}/released.sqlite');
        await databaseFile.rename(renamed.path);
        await renamed.rename(databaseFile.path);
        final db = openFileBackedDatabase(databaseFile);
        addTearDown(db.close);
        final job = MaintenanceJobRepository(
          db,
        ).latestForType('explicit_atomic_probe')!;
        expect(
          job.completedUnits,
          7,
          reason: 'Stop must not commit the pending index.',
        );
        expect(job.lastProcessedRowId, 7);
        expect(
          db.select(
            "select name from sqlite_schema where name = 'idx_interrupt_probe'",
          ),
          isEmpty,
        );
        expect(
          result.state,
          DatabaseMaintenanceState.interrupted,
          reason: result.errorMessage,
        );
        expect(
          db.select('select value from atomic_recovery_probe').single['value'],
          200,
          reason:
              'Recovery SQL must execute after repeating interrupts are disarmed.',
        );
        expect(db.select('pragma integrity_check').single.values.single, 'ok');
        expect(db.select('pragma foreign_key_check'), isEmpty);
      },
    );
  }

  test(
    'lost worker rolls back index creation and retries the atomic phase',
    () async {
      final seed = openFileBackedDatabase(databaseFile);
      seed.execute('create table atomic_index_probe (value text)');
      seed.close();
      final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
      final interrupted = await coordinator.start(
        jobType: 'atomic_index_probe',
        initialPhase: 'build_indexes',
        atomicPhases: const {'build_indexes'},
        worker: _abandonIndexTransaction,
      );
      expect((await interrupted.result).state, DatabaseMaintenanceState.failed);
      final recovered = openFileBackedDatabase(databaseFile);
      final abandoned = MaintenanceJobRepository(
        recovered,
      ).latestForType('atomic_index_probe')!;
      expect(abandoned.state, MaintenanceJobState.running);
      expect(
        recovered.select(
          "select name from sqlite_master where name = 'idx_atomic_probe'",
        ),
        isEmpty,
      );
      recovered.execute(
        "update maintenance_jobs set lease_expires_at_utc = '2000-01-01T00:00:00.000Z' where id = ?",
        [abandoned.id],
      );
      recovered.close();

      final retry = await coordinator.start(
        jobType: 'atomic_index_probe',
        initialPhase: 'build_indexes',
        atomicPhases: const {'build_indexes'},
        worker: _createProbeIndex,
      );
      expect((await retry.result).state, DatabaseMaintenanceState.succeeded);
      final verified = openFileBackedDatabase(databaseFile);
      addTearDown(verified.close);
      final jobs = MaintenanceJobRepository(verified);
      expect(jobs.read(abandoned.id)!.state, MaintenanceJobState.failed);
      expect(jobs.latestForType('atomic_index_probe')!.id, isNot(abandoned.id));
      expect(
        verified.select(
          "select name from sqlite_master where name = 'idx_atomic_probe'",
        ),
        hasLength(1),
      );
      expect(
        verified.select('pragma integrity_check').single.values.single,
        'ok',
      );
    },
  );
}

Future<DatabaseMaintenanceWorkerOutcome> _abandonIndexTransaction(
  DatabaseMaintenanceWorkerContext context,
) async {
  context.database.execute('begin immediate');
  context.database.execute(
    'create index idx_atomic_probe on atomic_index_probe(value)',
  );
  // Closing a lost connection rolls back its uncommitted index, as process exit does.
  context.database.close();
  Isolate.exit();
}

Future<DatabaseMaintenanceWorkerOutcome> _buildSlowIndex(
  DatabaseMaintenanceWorkerContext context,
) async {
  context.commitBatch(
    phase: 'build_indexes',
    currentWork: 'Prior checkpoint committed.',
    unitLabel: 'indexes',
    completedUnits: 7,
    totalUnits: 8,
    lastProcessedRowId: 7,
    apply: (_) {},
  );
  var announced = false;
  context.database.createFunction(
    functionName: 'slow_index_value',
    deterministic: true,
    directOnly: false,
    function: (arguments) {
      if (!announced) {
        announced = true;
        context.publish(
          state: DatabaseMaintenanceState.running,
          phase: 'build_indexes',
          currentWork: 'SQLite index statement running.',
          unitLabel: 'indexes',
          completedUnits: 7,
          totalUnits: 8,
        );
      }
      // Keep SQLite executing long enough to request stop, without a large fixture.
      sleep(const Duration(milliseconds: 15));
      return arguments.single;
    },
  );
  context.commitBatch(
    phase: 'build_indexes',
    currentWork: 'Index committed.',
    unitLabel: 'indexes',
    completedUnits: 8,
    totalUnits: 8,
    lastProcessedRowId: 8,
    apply: (db) => db.execute(
      'create index idx_interrupt_probe on interrupt_index_probe(slow_index_value(value))',
    ),
  );
  return DatabaseMaintenanceWorkerOutcome.succeeded;
}

Future<DatabaseMaintenanceWorkerOutcome> _stopBeforeAtomicPhase(
  DatabaseMaintenanceWorkerContext context,
) => _stopAtAtomicEntry(context, phasePublished: false);

Future<DatabaseMaintenanceWorkerOutcome> _stopAfterAtomicPhase(
  DatabaseMaintenanceWorkerContext context,
) => _stopAtAtomicEntry(context, phasePublished: true);

Future<DatabaseMaintenanceWorkerOutcome> _stopAtAtomicEntry(
  DatabaseMaintenanceWorkerContext context, {
  required bool phasePublished,
}) async {
  context.commitBatch(
    phase: 'prepare',
    currentWork: 'Prior checkpoint committed.',
    unitLabel: 'indexes',
    completedUnits: 7,
    totalUnits: 8,
    lastProcessedRowId: 7,
    apply: (_) {},
  );
  context.database.createFunction(
    functionName: 'slow_index_value',
    deterministic: true,
    directOnly: false,
    function: (arguments) {
      sleep(const Duration(milliseconds: 15));
      return arguments.single;
    },
  );
  context.database.createFunction(
    functionName: 'slow_recovery_value',
    function: (arguments) {
      sleep(const Duration(milliseconds: 1));
      return arguments.single;
    },
  );
  context.database.execute('begin immediate');
  try {
    await context.runAtomic(() {
      context.publish(
        state: DatabaseMaintenanceState.running,
        phase: phasePublished ? 'build_indexes' : 'prepare',
        currentWork: 'Atomic section idle at test gate.',
        unitLabel: 'indexes',
        completedUnits: 7,
        totalUnits: 8,
      );
      final gate = File(
        '${context.databaseFile.parent.path}/atomic-test-release',
      );
      final deadline = Stopwatch()..start();
      while (!gate.existsSync()) {
        if (deadline.elapsed > const Duration(seconds: 10)) {
          throw StateError('Atomic test gate was not released.');
        }
        sleep(const Duration(milliseconds: 5));
      }
      if (!phasePublished) {
        context.publish(
          state: DatabaseMaintenanceState.running,
          phase: 'build_indexes',
          currentWork: 'Entering SQLite after Stop.',
          unitLabel: 'indexes',
          completedUnits: 7,
          totalUnits: 8,
        );
      }
      context.database.execute(
        'create index idx_interrupt_probe on interrupt_index_probe(slow_index_value(value))',
      );
    });
    context.database.execute('commit');
  } on Object catch (error) {
    if (!context.database.autocommit) context.database.execute('rollback');
    if (error is! DatabaseMaintenanceCancelled) {
      throw StateError(
        'Atomic Stop must expose typed cancellation, got ${error.runtimeType}.',
      );
    }
    // Deliberately longer than the interrupt interval, not a timing assertion.
    context.database.execute('''
      insert into atomic_recovery_probe
      select count(slow_recovery_value(value)) from interrupt_index_probe
    ''');
    rethrow;
  }
  context.commitBatch(
    phase: 'build_indexes',
    currentWork: 'Index committed.',
    unitLabel: 'indexes',
    completedUnits: 8,
    totalUnits: 8,
    lastProcessedRowId: 8,
    apply: (_) {},
  );
  return DatabaseMaintenanceWorkerOutcome.succeeded;
}

Future<DatabaseMaintenanceWorkerOutcome> _resumeInterruptedIndex(
  DatabaseMaintenanceWorkerContext context,
) async {
  final previous = context.jobs.read(context.lease.jobId)!;
  if (previous.completedUnits != 7 || previous.lastProcessedRowId != 7) {
    throw StateError('Atomic retry lost its prior checkpoint.');
  }
  context.commitBatch(
    phase: 'build_indexes',
    currentWork: 'Index committed.',
    unitLabel: 'indexes',
    completedUnits: 8,
    totalUnits: 8,
    lastProcessedRowId: 8,
    apply: (db) => db.execute(
      'create index idx_interrupt_probe on interrupt_index_probe(value)',
    ),
  );
  return DatabaseMaintenanceWorkerOutcome.succeeded;
}

Future<DatabaseMaintenanceWorkerOutcome> _createProbeIndex(
  DatabaseMaintenanceWorkerContext context,
) async {
  context.database.execute(
    'create index idx_atomic_probe on atomic_index_probe(value)',
  );
  return DatabaseMaintenanceWorkerOutcome.succeeded;
}

Future<DatabaseMaintenanceWorkerOutcome> _yieldAtCheckpointProbe(
  DatabaseMaintenanceWorkerContext context,
) async {
  final completed = context.jobs.read(context.lease.jobId)!.completedUnits;
  if (completed == 0) {
    context.publish(
      state: DatabaseMaintenanceState.running,
      phase: 'reprice_costs',
      currentWork: 'Waiting before first committed partition.',
      unitLabel: 'partitions',
      completedUnits: 0,
      totalUnits: 2,
    );
    final allowed = File(
      '${context.databaseFile.parent.path}/allow-first-partition',
    );
    while (!allowed.existsSync() && !context.stopRequested) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (context.stopRequested) {
      return DatabaseMaintenanceWorkerOutcome.interrupted;
    }
  }
  final next = completed + 1;
  context.commitBatch(
    phase: 'reprice_costs',
    currentWork: 'Committed partition $next.',
    unitLabel: 'partitions',
    completedUnits: next,
    totalUnits: 2,
    lastProcessedRowId: next,
    apply: (db) => db.execute('insert into yield_probe values (?)', [next]),
  );
  if (next == 2) return DatabaseMaintenanceWorkerOutcome.succeeded;
  while (!context.stopRequested) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return DatabaseMaintenanceWorkerOutcome.interrupted;
}

Future<DatabaseMaintenanceWorkerOutcome> _waitForQueueStop(
  DatabaseMaintenanceWorkerContext context,
) async {
  context.publish(
    state: DatabaseMaintenanceState.running,
    phase: 'hold',
    currentWork: 'Queue holder ready.',
    unitLabel: 'items',
    completedUnits: 0,
    totalUnits: null,
  );
  while (!context.stopRequested) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return DatabaseMaintenanceWorkerOutcome.interrupted;
}

Future<DatabaseMaintenanceWorkerOutcome> _holdAtomicWriter(
  DatabaseMaintenanceWorkerContext context,
) async {
  context.database.execute('begin immediate');
  context.publish(
    state: DatabaseMaintenanceState.running,
    phase: 'Atomic probe',
    currentWork: 'Atomic writer owns SQLite.',
    unitLabel: 'items',
    completedUnits: 0,
    totalUnits: null,
  );
  await Future<void>.delayed(const Duration(seconds: 2));
  context.database.execute('commit');
  return DatabaseMaintenanceWorkerOutcome.succeeded;
}

Future<DatabaseMaintenanceWorkerOutcome> _succeedImmediately(
  DatabaseMaintenanceWorkerContext context,
) async => DatabaseMaintenanceWorkerOutcome.succeeded;

Future<DatabaseMaintenanceWorkerOutcome> _failBackupVerification(
  DatabaseMaintenanceWorkerContext context,
) async => throw StateError('Backup verification mismatch');

bool _isMonotonic(List<double> values) {
  for (var index = 1; index < values.length; index++) {
    if (values[index] < values[index - 1]) {
      return false;
    }
  }
  return true;
}
