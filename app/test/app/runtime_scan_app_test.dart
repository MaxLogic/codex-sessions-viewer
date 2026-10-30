import 'package:codex_sessions_viewer/src/ui/widgets/collector_status.dart';
import '../support/collector_fixture.dart';
import '../support/scripted_collector_bridge.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/app/runtime_session_controller.dart';
import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/commands/resume_command_generator.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/application_maintenance.dart';
import 'package:codex_sessions_viewer/src/pricing/pricing_repository.dart';
import 'package:codex_sessions_viewer/src/database/database_generation.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:codex_sessions_viewer/src/database/collector_versions.dart';
import 'package:codex_sessions_viewer/src/database/usage_path_context_migration.dart';
import 'package:codex_sessions_viewer/src/scanner/collector_process.dart';
import 'package:codex_sessions_viewer/src/scanner/resident_collector_client.dart';
import 'package:codex_sessions_viewer/src/scanner/scan_batching.dart';
import 'package:codex_sessions_viewer/src/search/message_search.dart';
import 'package:codex_sessions_viewer/src/search/session_search.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/ui/screens/settings_screen.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:codex_sessions_viewer/src/usage/usage_cost_projection.dart';
import 'package:codex_sessions_viewer/src/utils/profiling.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

late Directory _collectorTemplateFolder;
late File _collectorTemplate;

/// The source type the collector records for this host's own session folders.
final _nativeSourceType = Platform.isWindows
    ? 'windows'
    : Platform.isMacOS
    ? 'macos'
    : 'linux';

final Object _skipWithoutWsl = Platform.isWindows
    ? false
    : 'Only Windows hosts read WSL session roots.';

void main() {
  setUpAll(() async {
    _collectorTemplateFolder = await Directory.systemTemp.createTemp(
      'csv_runtime_template_',
    );
    _collectorTemplate = File(
      p.join(_collectorTemplateFolder.path, 'template.sqlite'),
    );
    final sqlRoot = Directory('../sql');
    final startup = await DatabaseMigrator(
      sqlRoot: sqlRoot,
    ).openAndMigrate(_collectorTemplate, deferUsageMigration: true);
    expect(startup.canStartNormalUi, isTrue);
    final migration = await startPendingDatabaseMigration(
      _collectorTemplate,
      sqlRoot: sqlRoot,
    );
    if (migration != null) {
      expect((await migration.result).succeeded, isTrue);
    }
    final db = openFileBackedDatabase(_collectorTemplate);
    db.execute('pragma wal_checkpoint(TRUNCATE)');
    db.close();
  });
  tearDownAll(() async => deleteCollectorFixture(_collectorTemplateFolder));

  test('background refresh and detail reload share the app bridge', () async {
    final root = await Directory.systemTemp.createTemp('cxv184-shared-bridge-');
    final database = File(p.join(root.path, 'viewer.sqlite'));
    final settings = File(p.join(root.path, 'settings.toml'));
    final source = await Directory(p.join(root.path, 'sessions')).create();
    await _writeJsonFixture(source, 'shared-bridge');
    await SettingsRepository(settings).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(windowsCodexPath: source.path, wslCodexUncPath: ''),
        logging: _testLogging(root),
      ),
    );
    expect((await _migrateCollectorFixture(database)).canStartNormalUi, isTrue);
    var starts = 0;
    final client = ResidentCollectorClient(
      databaseFile: database,
      settingsFile: settings,
      start: (exe, args) {
        starts++;
        return startCollectorProcess(exe, args);
      },
    );
    try {
      final controller = RuntimeSessionController(
        databaseFile: database,
        settingsFile: settings,
        collectorClient: client,
      );
      final result = await controller.refreshInBackground();
      expect(result.rows, hasLength(1));
      final detail = await controller.reloadSessionDetailFromSource(
        result.rows.single.id,
      );
      expect(detail, isNotNull);
      expect(starts, 1);
    } finally {
      await client.dispose();
      await deleteCollectorFixture(root);
    }
  });

  group('collector transport', () {
    test('a missing collector executable fails with a clear message', () async {
      final temp = await Directory.systemTemp.createTemp('csv_no_collector_');
      addTearDown(() => deleteCollectorFixture(temp));
      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(windowsCodexPath: temp.path, wslCodexUncPath: ''),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      expect(
        (await _migrateCollectorFixture(databaseFile)).canStartNormalUi,
        isTrue,
      );
      final missing = p.join(temp.path, 'codex-sessions-collector.exe');
      final unavailableClient = ResidentCollectorClient(
        databaseFile: databaseFile,
        settingsFile: settingsFile,
        executable: missing,
        start: (executable, arguments) async => throw ProcessException(
          executable,
          arguments,
          'Fixture executable is absent',
          2,
        ),
      );
      addTearDown(unavailableClient.dispose);
      Object? failure;
      try {
        await RuntimeSessionController(
          settingsFile: settingsFile,
          databaseFile: databaseFile,
          collectorExecutable: missing,
          collectorClient: unavailableClient,
        ).refresh();
      } on Object catch (error) {
        failure = error;
      }
      expect(failure, isA<CollectorUnavailableException>());
      expect(
        failure.toString(),
        allOf(
          contains(missing),
          contains('CODEX_SESSIONS_COLLECTOR_EXE'),
          contains('Reinstall'),
        ),
      );
      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      expect(
        db.select('select status from scan_runs').single['status'],
        'failed',
      );
    });

    test(
      'refresh collects Claude Code transcripts through the resident',
      () async {
        final temp = await Directory.systemTemp.createTemp('csv_claude_scan_');
        addTearDown(() => deleteCollectorFixture(temp));
        final codexRoot = Directory(p.join(temp.path, '.codex', 'sessions'));
        await codexRoot.create(recursive: true);
        await _writeJsonFixture(codexRoot, 'codex-beside-claude');
        final claudeRoot = Directory(p.join(temp.path, 'claude-projects'));
        await _copyTree(Directory('../samples/claude/projects'), claudeRoot);
        final settingsFile = File(p.join(temp.path, 'settings.toml'));
        await SettingsRepository(settingsFile).save(
          AppSettings.defaults().copyWith(
            paths: PathSettings(
              windowsCodexPath: p.join(temp.path, '.codex'),
              wslCodexUncPath: '',
            ),
            logging: _testLogging(temp),
          ),
        );
        final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
        expect(
          (await _migrateCollectorFixture(databaseFile)).canStartNormalUi,
          isTrue,
        );
        final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
        final controller = RuntimeSessionController(
          settingsFile: settingsFile,
          databaseFile: databaseFile,
          writerCoordinator: coordinator,
          claudeProjectRoots: [claudeRoot.path],
        );
        final progress = <SessionsRefreshProgress>[];
        final result = await controller.refresh(onProgress: progress.add);
        expect(result.cancelled, isFalse);
        expect(result.rows.map((row) => row.harness).toSet(), {
          'codex',
          'claude',
        });
        expect(result.rows.where((row) => row.harness == 'claude'), isNotEmpty);
        expect(progress.last.statusMessage, isNotEmpty);

        // A cancelled refresh does not start the Claude scan.
        final db = openFileBackedDatabase(databaseFile);
        addTearDown(db.close);
        db.execute("delete from sessions where harness = 'claude'");
        final operation = controller.startRefreshOperation();
        await operation.cancel();
        final cancelled = await operation.result;
        expect(cancelled.cancelled, isTrue);
        expect(
          db
              .select(
                "select count(*) as n from sessions where harness = 'claude'",
              )
              .single['n'],
          0,
        );
      },
    );

    test('loading cached rows never writes the database', () async {
      final temp = await Directory.systemTemp.createTemp('csv_cached_read_');
      addTearDown(() => deleteCollectorFixture(temp));
      final sessionsRoot = Directory(p.join(temp.path, '.codex', 'sessions'));
      await sessionsRoot.create(recursive: true);
      await _copyFixture('sample_windows_session.json', sessionsRoot);
      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: p.join(temp.path, '.codex'),
            wslCodexUncPath: '',
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      expect(
        (await _migrateCollectorFixture(databaseFile)).canStartNormalUi,
        isTrue,
      );
      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      );
      await controller.refresh();
      final observer = openFileBackedDatabase(databaseFile);
      addTearDown(observer.close);
      // Rows the collector will repair on its next scan.
      observer.execute('''
        update sessions set detected_project_id = null, project_id = null,
          project_name_snapshot = null, title = '# AGENTS.md instructions',
          summary = 'auto'
      ''');
      int dataVersion() =>
          observer.select('pragma data_version').single.values.single as int;
      final before = dataVersion();
      final cached = await controller.loadCachedRows();
      final background = await controller.loadCachedRowsInBackground();
      expect(dataVersion(), before, reason: 'Loads must not commit writes.');
      expect(cached.rows.single.title, isEmpty);
      expect(background.rows.single.project, isEmpty);
      await controller.refresh();
      final row = observer
          .select('select title, summary, project_name_snapshot from sessions')
          .single;
      expect(row['title'], isNull);
      expect(row['summary'], isNull);
      expect(row['project_name_snapshot'], isNotEmpty);
    });
  });
  test(
    'concurrent refresh requests keep one scan owner without blocking other writers',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_scan_owner_');
      final windowsRoot = await Directory('${temp.path}/windows').create();
      final wslRoot = await Directory('${temp.path}/wsl').create();
      for (var i = 0; i < 20; i++) {
        await _writeJsonFixture(windowsRoot, 'owner-$i');
      }
      final file = File('${temp.path}/viewer.sqlite');
      final settingsFile = File('${temp.path}/settings.toml');
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          logging: _testLogging(temp),
        ),
      );
      expect((await _migrateCollectorFixture(file)).canStartNormalUi, isTrue);
      final coordinator = DatabaseMaintenanceCoordinator(file);
      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: file,
        writerCoordinator: coordinator,
        scanBatchingPolicy: const ScanBatchingPolicy(
          parsedSessionFlushBatchSize: 1,
          fullRowSnapshotBatchSize: 1,
        ),
      );
      var overlap = false;
      void check(SessionsRefreshProgress _) {
        final db = openFileBackedDatabase(file);
        try {
          overlap |=
              (db
                      .select(
                        "select count(*) n from scan_runs where status='running'",
                      )
                      .single['n']
                  as int) >
              1;
        } finally {
          db.close();
        }
      }

      final first = controller.startRefreshInBackgroundOperation(
        onProgress: check,
      );
      final second = controller.startRefreshInBackgroundOperation(
        onProgress: check,
      );
      try {
        final results = await Future.wait([first.result, second.result]);
        expect(
          overlap,
          isFalse,
          reason:
              'A second discovery must not apply stale missing-file decisions over the active scan.',
        );
        expect(results.map((r) => r.rows.length), [20, 20]);
      } finally {
        await first.cancel();
        await second.cancel();
        await coordinator.idle;
        await deleteCollectorFixture(temp);
      }
    },
  );
  test(
    'pricing commits between background scan batches before scan completion',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_scan_prices_');
      final windowsRoot = await Directory('${temp.path}/windows').create();
      final wslRoot = await Directory('${temp.path}/wsl').create();
      for (var i = 0; i < 100; i++) {
        await _writeJsonFixture(windowsRoot, 'price-scan-$i');
      }
      final file = File('${temp.path}/viewer.sqlite');
      final settingsFile = File('${temp.path}/settings.toml');
      final settings = AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        logging: _testLogging(temp),
      );
      await SettingsRepository(settingsFile).save(settings);
      expect((await _migrateCollectorFixture(file)).canStartNormalUi, isTrue);
      final coordinator = DatabaseMaintenanceCoordinator(file);
      final maintenance = ApplicationMaintenance(
        databaseFile: file,
        coordinator: coordinator,
        client: _ScanPricingCatalog(),
      );
      await maintenance.configure(settings);
      Future<bool>? refresh;
      String? scanStateAtPriceCommit;
      void captureCommit() {
        if (maintenance.schedules.any(
          (s) =>
              s.jobType == 'openrouter_price_refresh' &&
              s.lastSuccessAtUtc != null,
        )) {
          final db = openFileBackedDatabase(file);
          try {
            scanStateAtPriceCommit ??=
                db
                        .select(
                          'select status from scan_runs order by id desc limit 1',
                        )
                        .single['status']
                    as String;
          } finally {
            db.close();
          }
        }
      }

      maintenance.addListener(captureCommit);
      final collector = ResidentCollectorClient(
        databaseFile: file,
        settingsFile: settingsFile,
      );
      final operation =
          RuntimeSessionController(
            settingsFile: settingsFile,
            databaseFile: file,
            writerCoordinator: coordinator,
            collectorClient: collector,
            scanBatchingPolicy: const ScanBatchingPolicy(
              parsedSessionFlushBatchSize: 1,
              fullRowSnapshotBatchSize: 1,
            ),
          ).startRefreshInBackgroundOperation(
            onProgress: (progress) {
              if ((progress.rows?.isNotEmpty ?? false) && refresh == null) {
                refresh = maintenance.refreshPrices();
              }
            },
          );
      try {
        final result = await operation.result.timeout(
          const Duration(seconds: 30),
        );
        expect(refresh, isNotNull);
        expect(await refresh!, isTrue);
        expect(
          scanStateAtPriceCommit,
          'running',
          reason: 'A downloaded catalog must not wait for the entire scan.',
        );
        expect(result.rows, hasLength(100));
        final db = openFileBackedDatabase(file);
        try {
          expect(db.select('pragma foreign_key_check'), isEmpty);
        } finally {
          db.close();
        }
      } finally {
        await operation.cancel();
        await collector.dispose();
        await maintenance.stop();
        maintenance.dispose();
        await coordinator.idle;
        await deleteCollectorFixture(temp);
      }
    },
    // The runner includes migration and isolated native-process teardown;
    // the scan itself retains its independent 30-second bound above.
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test('runtime project edits wait for the application writer queue', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_writer_queue_',
    );
    addTearDown(() => deleteCollectorFixture(temp));
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(
      settingsFile,
    ).save(AppSettings.defaults().copyWith(pricing: _testPricing()));
    expect(
      (await _migrateCollectorFixture(databaseFile)).canStartNormalUi,
      isTrue,
    );
    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    db.execute(
      "insert into projects (id, name, is_active, created_at_utc, updated_at_utc) values (1, 'fixture', 1, '2026-09-07', '2026-09-07')",
    );
    final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
    final release = Completer<void>();
    final held = coordinator.runWriter(() => release.future);
    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
      writerCoordinator: coordinator,
    );
    final edit = controller.upsertProjectMaskAndRecalculate(
      projectId: 1,
      pathMask: 'c:/fixture/*',
    );
    try {
      final earlyResult = await edit.timeout(
        const Duration(milliseconds: 300),
        onTimeout: () => -1,
      );
      expect(
        earlyResult,
        -1,
        reason: 'no project mutation may bypass the active application writer',
      );
      expect(db.select('select * from project_path_masks'), isEmpty);
      // Read-only detail loading remains usable while a writer is queued.
      expect(await controller.loadSessionDetail('missing'), isNull);
    } finally {
      release.complete();
      await held;
      await edit;
    }
    expect(
      db.select('select path_mask from project_path_masks').single['path_mask'],
      'c:/fixture/*',
    );
  });

  test('database migration resumes from its durable checkpoint', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_migration_resume_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);
    final seed = openFileBackedDatabase(databaseFile);
    seed.execute('create table migration_source (value text not null)');
    seed.execute('''
      create table migration_destination (
        source_rowid integer primary key,
        value text not null
      )
      ''');
    for (var index = 1; index <= 5; index++) {
      seed.execute('insert into migration_source (value) values (?)', [
        'row-$index',
      ]);
    }
    seed.close();

    final coordinator = DatabaseMaintenanceCoordinator(
      databaseFile,
      leaseDuration: const Duration(seconds: 2),
    );
    final first = await coordinator.start(
      jobType: 'usage_projection_migration',
      initialPhase: 'copy_probe',
      worker: _copyMigrationProbeRows,
      totalUnits: 5,
      initialStatusMessage: 'Preparing migration test rows.',
    );
    var stopRequested = false;
    final subscription = first.progress.listen((progress) {
      if (!stopRequested && progress.completedUnits == 2) {
        stopRequested = true;
        unawaited(first.requestStop());
      }
    });
    final firstResult = await first.result;
    await subscription.cancel();
    expect(firstResult.state, DatabaseMaintenanceState.interrupted);

    final interrupted = openFileBackedDatabase(
      databaseFile,
      maintenanceWriter: true,
    );
    final durable = MaintenanceJobRepository(
      interrupted,
    ).latestForType('usage_projection_migration')!;
    expect(durable.lastProcessedRowId, 2);
    expect(durable.completedUnits, 2);
    interrupted.execute('''
      create trigger reject_repeated_migration_rows
      before insert on migration_destination
      when new.source_rowid <= 2
      begin
        select raise(abort, 'committed migration batch repeated');
      end
      ''');
    interrupted.close();

    final resumed = await coordinator.start(
      jobType: 'usage_projection_migration',
      initialPhase: 'copy_probe',
      worker: _copyMigrationProbeRows,
      totalUnits: 5,
      initialStatusMessage: 'Resuming migration test rows.',
    );
    final resumedResult = await resumed.result;
    expect(resumedResult.state, DatabaseMaintenanceState.succeeded);

    final verified = openFileBackedDatabase(databaseFile);
    addTearDown(verified.close);
    expect(
      verified
          .select(
            'select source_rowid, value from migration_destination order by source_rowid',
          )
          .map((row) => (row['source_rowid'], row['value']))
          .toList(),
      [(1, 'row-1'), (2, 'row-2'), (3, 'row-3'), (4, 'row-4'), (5, 'row-5')],
    );
    expect(
      MaintenanceJobRepository(
        verified,
      ).latestForType('usage_projection_migration')!.attemptCount,
      2,
    );
  });

  test(
    'runtime scan loads settings, persists parsed sessions, and returns rows',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_runtime_scan_');
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      await _copyFixture('sample_windows_session.json', windowsRoot);
      await _copyFixture('sample_wsl_session.json', wslRoot);

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          wsl: WslSettings(
            distro: 'Ubuntu',
            linuxHome: '/home/pawel',
            linuxRootUnc: '${wslRoot.path}${Platform.pathSeparator}',
          ),
          logging: _testLogging(temp),
        ),
      );

      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
        // A fake resolver keeps the scan off the real wsl.exe (T-173).
        wslProjectResolver: _RecordingWslProjectResolver({}),
      );
      final progressEvents = <SessionsRefreshProgress>[];
      final profilingEvents = <ProfilingEvent>[];
      final result = await Profiling.captureAsync(profilingEvents.add, () {
        return controller.refresh(onProgress: progressEvents.add);
      });

      expect(result.rows, hasLength(2));
      expect(
        result.rows.map((row) => row.platformLabel),
        containsAll(['Windows', 'WSL']),
      );
      expect(result.statusMessage, contains('Scan finished'));
      expect(result.persistenceFlushCount, 1);

      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      expect(
        db.select('select count(*) as count from sessions').single['count'],
        2,
      );
      // The collector records a digest of the rows it wrote for each session.
      expect(
        db
            .select(
              'select count(*) as count from sessions where length(content_hash) = 64',
            )
            .single['count'],
        2,
      );
      expect(
        db
            .select('select count(*) as count from session_search')
            .single['count'],
        2,
      );
      expect(
        progressEvents.map((event) => event.statusMessage),
        contains(contains('scanned')),
      );
      expect(
        progressEvents.any((event) => event.rows?.isNotEmpty ?? false),
        isTrue,
      );
      expect(
        progressEvents.map((event) => event.statusMessage),
        contains(contains('estimated progress 100%')),
      );
      final spanNames = {
        for (final event in profilingEvents)
          if (event.kind == ProfilingEventKind.start) event.name,
      };
      expect(spanNames, contains('scan.runtime.refresh'));
      expect(spanNames, contains('scan.runtime.load_rows'));
      expect(spanNames, contains('scan.runtime.collector'));
      expect(spanNames, isNot(contains('scan.runtime.collector_write')));
    },
    skip: _skipWithoutWsl,
  );

  test('persists and reconciles branch-aware usage atomically', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_branch_usage_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    await _writeAggregateJsonlFixture(windowsRoot);
    final aggregateOnlyParentFile = await _writeAggregateOnlyJsonFixture(
      windowsRoot,
    );
    await _writeJsonFixture(windowsRoot, 'zero-usage');
    await _writeLegacyForkUsageFixture(windowsRoot, child: true);
    await _writeLegacyForkUsageFixture(
      windowsRoot,
      child: true,
      zeroPostFork: true,
    );
    await _writeSelfCycleUsageFixture(windowsRoot);
    await _writeSelfCycleUsageFixture(windowsRoot, withUsage: false);

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        pricing: _testPricing(),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    );
    final contextSetup = openFileBackedDatabase(databaseFile);
    final contextGenerations = DatabaseGenerationRepository(contextSetup);
    final contextGeneration = contextGenerations.createBuilding(
      sourceSchemaVersion: 15,
      targetSchemaVersion: 16,
      sourceFingerprint: 'empty fixture',
    );
    contextGenerations.markReady(
      contextGeneration.id,
      validationReportJson: jsonEncode(
        UsagePathContextMigration(contextSetup).validateShadowParity(),
      ),
    );
    contextGenerations.activate(contextGeneration.id);
    contextSetup.close();
    final refresh = await controller.refresh();
    expect(refresh.rows, hasLength(7));

    final db = openFileBackedDatabase(databaseFile);
    addTearDown(() {
      try {
        db.close();
      } on StateError {
        // The success path closes this handle before the parent-late refresh.
      }
    });
    final contexts = db.select('''
      select c.*, p.name as detected_name
      from usage_path_contexts c
      left join projects p on p.id = c.detected_project_id
      where c.display_path_key = 'f:/projects/maxlogic/codex-sessions-viewer'
    ''');
    expect(
      contexts,
      hasLength(1),
      reason: 'Usage ingestion must deduplicate path contexts.',
    );
    expect(contexts.single['detected_name'], 'codex-sessions-viewer');
    expect(contexts.single['resolution_source'], 'detected');
    expect(contexts.single['normalization_version'], 1);
    final projectionRows = db.select('''
      select session_id, usage_projection_status
      from sessions
      order by session_id
      ''');
    expect(
      projectionRows
          .map((row) => (row['session_id'], row['usage_projection_status']))
          .toList(),
      [
        ('aggregate-jsonl-001', 'complete'),
        ('aggregate-only-parent', 'ambiguous'),
        ('legacy-child', 'missing_parent'),
        ('legacy-zero-child', 'missing_parent'),
        ('self-cycle', 'ambiguous'),
        ('self-cycle-zero', 'ambiguous'),
        ('zero-usage', 'complete'),
      ],
    );
    final event = db.select('''
      select
        source_record_ordinal,
        occurred_at_utc,
        model,
        input_tokens,
        cached_input_tokens,
        cache_write_input_tokens,
        output_tokens,
        reasoning_output_tokens,
        total_tokens,
        branch_scope,
        derivation,
        length(event_fingerprint) as fingerprint_length
      from usage_events
      where session_row_id = (
        select id from sessions where session_id = 'aggregate-jsonl-001'
      )
      ''').single;
    expect(event['source_record_ordinal'], 4);
    expect(event['occurred_at_utc'], '2026-06-10T10:00:04.000Z');
    expect(event['model'], 'gpt-5.5-thinking');
    expect(event['input_tokens'], 42);
    expect(
      db.select('''
        select coalesce(sum(d.input_tokens), 0) n from usage_session_daily d
        join sessions s on s.id = d.session_id
        where s.session_id = 'aggregate-jsonl-001' and d.branch_scope = 'local'
      ''').single['n'],
      42,
      reason:
          'Ingestion must persist its daily projection in the same transaction.',
    );
    expect(event['cached_input_tokens'], 7);
    expect(event['cache_write_input_tokens'], 0);
    expect(event['output_tokens'], 21);
    expect(event['reasoning_output_tokens'], 0);
    expect(event['total_tokens'], 63);
    expect(event['branch_scope'], 'local');
    expect(event['derivation'], 'cumulative_delta');
    expect(event['fingerprint_length'], 64);
    expect(
      db
          .select('select count(*) as count from billable_usage_events')
          .single['count'],
      1,
    );
    db.execute('''
      insert into sessions (
        id, session_id, forked_from_id, usage_projection_status,
        source_type, source_file_path, display_path, platform_path,
        parser_version, created_at_utc, updated_at_utc
      ) values (
        'old-child-row', 'old-child', 'legacy-parent', 'legacy_pending',
        'windows', 'old-child.jsonl', 'old-child.jsonl', 'old-child.jsonl',
        2, '2026-07-28T10:00:00Z', '2026-07-28T10:00:00Z'
      )
      ''');
    db.execute(
      '''
      insert into sessions (
        id, session_id, forked_from_id, usage_projection_status,
        source_type, source_file_path, display_path, platform_path,
        parser_version, created_at_utc, updated_at_utc
      ) values (
        'aggregate-child-row', 'aggregate-child', 'aggregate-only-parent',
        'ambiguous', 'windows', 'aggregate-child.jsonl',
        'aggregate-child.jsonl', 'aggregate-child.jsonl', ?,
        '2026-07-28T10:00:00Z', '2026-07-28T10:00:00Z'
      )
      ''',
      [collectorCodexParserVersion],
    );
    db.execute(
      '''
      insert into usage_events (
        session_row_id, source_record_ordinal, epoch, input_tokens,
        cached_input_tokens, cache_write_input_tokens, output_tokens,
        reasoning_output_tokens, total_tokens, branch_scope, derivation,
        event_fingerprint, path_context_id
      ) values ('aggregate-child-row', 1, 0, 3, 0, 0, 2, 0, 5,
        'ambiguous', 'cumulative_delta', ?, 1)
      ''',
      ['e' * 64],
    );

    db.close();
    await aggregateOnlyParentFile.writeAsString(
      '${await aggregateOnlyParentFile.readAsString()}\n',
      flush: true,
    );
    final parentFile = await _writeLegacyForkUsageFixture(
      windowsRoot,
      child: false,
    );
    final parentRefresh = await controller.refresh();
    expect(parentRefresh.rows, hasLength(10));

    final reconciledDb = openFileBackedDatabase(databaseFile);
    addTearDown(reconciledDb.close);
    expect(
      reconciledDb
          .select(
            "select usage_projection_status from sessions "
            "where session_id = 'legacy-child'",
          )
          .single['usage_projection_status'],
      'complete',
    );
    expect(
      reconciledDb
          .select(
            "select usage_projection_status from sessions "
            "where session_id = 'old-child'",
          )
          .single['usage_projection_status'],
      'legacy_pending',
    );
    expect(
      reconciledDb
          .select(
            "select usage_projection_status from sessions "
            "where session_id = 'aggregate-child'",
          )
          .single['usage_projection_status'],
      'ambiguous',
    );
    expect(
      reconciledDb
          .select(
            "select branch_scope from usage_events "
            "where session_row_id = 'aggregate-child-row'",
          )
          .single['branch_scope'],
      'ambiguous',
    );
    expect(
      reconciledDb
          .select('''
            select branch_scope
            from usage_events
            where session_row_id = (
              select id from sessions where session_id = 'legacy-child'
            )
            order by source_record_ordinal
            ''')
          .map((row) => row['branch_scope'])
          .toList(),
      ['inherited', 'inherited', 'local'],
    );
    final childBillable = reconciledDb.select('''
      select count(*) as event_count, sum(total_tokens) as total_tokens
      from billable_usage_events
      where session_row_id = (
        select id from sessions where session_id = 'legacy-child'
      )
      ''').single;
    expect(childBillable['event_count'], 1);
    expect(childBillable['total_tokens'], 10);
    expect(
      reconciledDb
          .select('''
            select branch_scope
            from usage_events
            where session_row_id = (
              select id from sessions where session_id = 'legacy-zero-child'
            )
            order by source_record_ordinal
            ''')
          .map((row) => row['branch_scope'])
          .toList(),
      ['inherited', 'inherited'],
    );
    expect(
      reconciledDb.select('''
            select count(*) as count
            from billable_usage_events
            where session_row_id = (
              select id from sessions where session_id = 'legacy-zero-child'
            )
            ''').single['count'],
      0,
    );
    expect(
      reconciledDb
          .select('select count(*) as count from usage_events')
          .single['count'],
      11,
    );

    await _writeLegacyGrandchildUsageFixture(windowsRoot);
    final grandchildRefresh = await controller.refresh();
    expect(grandchildRefresh.rows, hasLength(11));
    expect(
      reconciledDb
          .select('''
            select branch_scope
            from usage_events
            where session_row_id = (
              select id from sessions where session_id = 'legacy-grandchild'
            )
            order by source_record_ordinal
            ''')
          .map((row) => row['branch_scope'])
          .toList(),
      ['inherited', 'inherited', 'inherited', 'local'],
    );
    expect(
      reconciledDb.select('''
            select sum(total_tokens) as total_tokens
            from billable_usage_events
            where session_row_id = (
              select id from sessions where session_id = 'legacy-grandchild'
            )
            ''').single['total_tokens'],
      6,
    );

    await parentFile.writeAsString(
      '${await parentFile.readAsString()}\n',
      flush: true,
    );
    await controller.refresh();
    expect(
      reconciledDb
          .select('select count(*) as count from usage_events')
          .single['count'],
      15,
    );
    expect(
      reconciledDb
          .select('''
            select branch_scope
            from usage_events
            where session_row_id = (
              select id from sessions where session_id = 'legacy-child'
            )
            order by source_record_ordinal
            ''')
          .map((row) => row['branch_scope'])
          .toList(),
      ['inherited', 'inherited', 'local'],
    );

    final cancelledOperation = controller.startRefreshOperation();
    await cancelledOperation.cancel();
    final cancelledRefresh = await cancelledOperation.result;
    expect(cancelledRefresh.cancelled, isTrue);
    expect(
      reconciledDb
          .select('select count(*) as count from usage_events')
          .single['count'],
      15,
    );

    final parentLines = (await parentFile.readAsLines())
        .where((line) => line.trim().isNotEmpty)
        .toList();
    final parentMetadata =
        jsonDecode(parentLines.first) as Map<String, dynamic>;
    final parentPayload = parentMetadata['payload'] as Map<String, dynamic>;
    parentPayload['forked_from_id'] = 'legacy-grandchild';
    parentLines[0] = jsonEncode(parentMetadata);
    await parentFile.writeAsString(parentLines.join('\n'), flush: true);
    await controller.refresh();
    expect(
      reconciledDb
          .select(
            "select usage_projection_status from sessions where session_id = 'legacy-grandchild'",
          )
          .single['usage_projection_status'],
      'ambiguous',
      reason:
          'Changing an ancestor must reconcile every descendant in the cycle.',
    );
    expect(
      reconciledDb.select('''
      select coalesce(sum(d.total_tokens), 0) n from usage_session_daily d
      join sessions s on s.id = d.session_id
      where s.session_id = 'legacy-grandchild' and d.branch_scope = 'local'
    ''').single['n'],
      0,
    );
    final cycleModifiedAt = (await parentFile.stat()).modified;
    parentPayload.remove('forked_from_id');
    parentLines[0] = jsonEncode(parentMetadata);
    await parentFile.writeAsString(parentLines.join('\n'), flush: true);
    // Windows stat exposes second-grained timestamps here. Make the smaller
    // replacement explicitly newer, rather than testing the size tie-breaker.
    await parentFile.setLastModified(
      cycleModifiedAt.add(const Duration(seconds: 2)),
    );
    await controller.refresh();
    expect(
      reconciledDb
          .select('''
        select session_id, forked_from_id, usage_projection_status from sessions
        where session_id in ('legacy-parent', 'legacy-child', 'legacy-grandchild')
        order by session_id
      ''')
          .map(
            (r) => (
              r['session_id'],
              r['forked_from_id'],
              r['usage_projection_status'],
            ),
          )
          .toList(),
      [
        ('legacy-child', 'legacy-parent', 'complete'),
        ('legacy-grandchild', 'legacy-child', 'complete'),
        ('legacy-parent', null, 'complete'),
      ],
    );
    expect(
      reconciledDb.select('''
      select coalesce(sum(d.total_tokens), 0) n from usage_session_daily d
      join sessions s on s.id = d.session_id
      where s.session_id = 'legacy-grandchild' and d.branch_scope = 'local'
    ''').single['n'],
      6,
    );
    final emptyChild = File(p.join(windowsRoot.path, 'empty-child.jsonl'));
    await emptyChild.writeAsString(
      jsonEncode({
        'type': 'session_meta',
        'timestamp': '2026-06-11T10:00:00Z',
        'payload': {
          'id': 'empty-child',
          'forked_from_id': 'legacy-parent',
          'timestamp': '2026-06-11T10:00:00Z',
        },
      }),
    );
    await controller.refresh();
    expect(
      reconciledDb
          .select(
            "select usage_projection_status from sessions where session_id = 'empty-child'",
          )
          .single['usage_projection_status'],
      'complete',
    );
    parentPayload['forked_from_id'] = 'empty-child';
    parentLines[0] = jsonEncode(parentMetadata);
    await parentFile.writeAsString(parentLines.join('\n'), flush: true);
    await parentFile.setLastModified(
      cycleModifiedAt.add(const Duration(seconds: 4)),
    );
    await controller.refresh();
    expect(
      reconciledDb
          .select(
            "select usage_projection_status from sessions where session_id = 'empty-child'",
          )
          .single['usage_projection_status'],
      'ambiguous',
    );
    parentPayload.remove('forked_from_id');
    parentLines[0] = jsonEncode(parentMetadata);
    await parentFile.writeAsString(parentLines.join('\n'), flush: true);
    await parentFile.setLastModified(
      cycleModifiedAt.add(const Duration(seconds: 6)),
    );
    await controller.refresh();
    expect(
      reconciledDb
          .select(
            "select usage_projection_status from sessions where session_id = 'empty-child'",
          )
          .single['usage_projection_status'],
      'complete',
      reason:
          'A successfully parsed empty descendant must recover without being reparsed.',
    );
  });

  test('background runtime scan emits progress and returns rows', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_background_scan_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    await _copyFixture('sample_windows_session.json', windowsRoot);

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        pricing: _testPricing(),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final progressEvents = <SessionsRefreshProgress>[];
    var callerStillPumping = false;
    final resultFuture = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refreshInBackground(onProgress: progressEvents.add);

    await Future<void>.delayed(Duration.zero);
    callerStillPumping = true;

    final result = await resultFuture;

    expect(callerStillPumping, isTrue);
    expect(result.rows, hasLength(1));
    expect(progressEvents, isNotEmpty);
    expect(
      progressEvents.map((event) => event.statusMessage),
      contains(contains('scanned')),
    );
  });

  test(
    'background cached startup load streams newest sessions first',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_cached_background_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      await _copyFixture('sample_windows_session.json', windowsRoot);
      await _copyFixture('sample_wsl_session.json', wslRoot);

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          wsl: WslSettings(
            distro: 'Ubuntu',
            linuxHome: '/home/pawel',
            linuxRootUnc: '${wslRoot.path}${Platform.pathSeparator}',
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
        // A fake resolver keeps the scan off the real wsl.exe (T-173).
        wslProjectResolver: _RecordingWslProjectResolver({}),
      );
      await controller.refresh();

      final progressEvents = <SessionsRefreshProgress>[];
      final profilingEvents = <ProfilingEvent>[];
      final result = await Profiling.captureAsync(profilingEvents.add, () {
        return controller.loadCachedRowsInBackground(
          onProgress: progressEvents.add,
          batchSize: 1,
        );
      });

      expect(progressEvents, hasLength(2));
      expect(progressEvents.first.rows, hasLength(1));
      expect(
        progressEvents.first.statusMessage,
        'Loaded 1 of 2 sessions from the previous scan.',
      );
      expect(progressEvents.first.rows!.single.title, 'WSL parser fixture');
      expect(result.rows.map((row) => row.title), [
        'WSL parser fixture',
        'Windows parser fixture',
      ]);
      expect(
        profilingEvents
            .where((event) => event.kind == ProfilingEventKind.start)
            .map((event) => event.name),
        contains('scan.runtime.load_cached_rows'),
      );
    },
    skip: _skipWithoutWsl,
  );

  test(
    'runtime refresh status reports cached available sessions separately',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_cached_status_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      await _copyFixture('sample_windows_session.json', windowsRoot);

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      );
      final firstResult = await controller.refresh();
      final secondResult = await controller.refresh();

      expect(firstResult.rows, hasLength(1));
      expect(firstResult.persistenceFlushCount, 1);
      expect(secondResult.rows, hasLength(1));
      expect(secondResult.statusMessage, contains('1 session available'));
      expect(
        secondResult.statusMessage,
        contains('0 new or changed sessions parsed'),
      );
    },
  );

  test(
    'runtime refresh uses resident batches and coalesces row snapshots',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_scan_batching_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      for (var i = 0; i < 5; i++) {
        await _writeJsonFixture(windowsRoot, 'batched-$i');
      }

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final progressEvents = <SessionsRefreshProgress>[];
      final result = await RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
        scanBatchingPolicy: const ScanBatchingPolicy(
          parsedSessionFlushBatchSize: 2,
          fullRowSnapshotBatchSize: 4,
        ),
      ).refresh(onProgress: progressEvents.add);

      expect(result.rows, hasLength(5));
      expect(result.persistenceFlushCount, 1);
      expect(result.fullRowSnapshotCount, 1);
      expect(
        progressEvents
            .where((event) => event.rows != null)
            .map((event) => event.rows!.length),
        [5],
      );
      expect(progressEvents.any((event) => event.rows == null), isTrue);
    },
  );

  test(
    'runtime refresh emits final snapshot after an exact flush boundary',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_scan_final_snapshot_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      for (var i = 0; i < 2; i++) {
        await _writeJsonFixture(windowsRoot, 'final-batch-$i');
      }

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final progressEvents = <SessionsRefreshProgress>[];
      final result = await RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
        scanBatchingPolicy: const ScanBatchingPolicy(
          parsedSessionFlushBatchSize: 2,
          fullRowSnapshotBatchSize: 4,
        ),
      ).refresh(onProgress: progressEvents.add);

      expect(result.persistenceFlushCount, 1);
      expect(result.fullRowSnapshotCount, 1);
      expect(
        progressEvents
            .where((event) => event.rows != null)
            .map((event) => event.rows!.length),
        [2],
      );
    },
  );

  test(
    'background runtime refresh uses resident batching and viewer snapshot policy',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_background_batching_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      for (var i = 0; i < 5; i++) {
        await _writeJsonFixture(windowsRoot, 'background-batched-$i');
      }

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final progressEvents = <SessionsRefreshProgress>[];
      final result = await RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
        scanBatchingPolicy: const ScanBatchingPolicy(
          parsedSessionFlushBatchSize: 99,
          parsedSessionFlushSourceBytes: 1,
          fullRowSnapshotBatchSize: 4,
        ),
      ).refreshInBackground(onProgress: progressEvents.add);

      expect(result.rows, hasLength(5));
      expect(result.persistenceFlushCount, 1);
      expect(result.fullRowSnapshotCount, 1);
      expect(
        progressEvents
            .where((event) => event.rows != null)
            .map((event) => event.rows!.length),
        [5],
      );
    },
  );

  test(
    'runtime refresh hides a previously parsed session after source deletion',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_scan_missing_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      final fixture = await _copyFixture(
        'sample_windows_session.json',
        windowsRoot,
      );

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      );
      expect((await controller.refresh()).rows, hasLength(1));

      await fixture.delete();
      final secondResult = await controller.refresh();

      expect(secondResult.rows, isEmpty);
      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      final row = db.select(
        'select scan_status, source_state '
        'from sessions where source_file_path = ?',
        [fixture.path],
      ).single;
      expect(row['scan_status'], 'missing');
      expect(row['source_state'], 'missing');
    },
  );

  test(
    'runtime refresh narrows a configured codex root to session files',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_codex_root_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final codexRoot = Directory(p.join(temp.path, '.codex'));
      final sessionsRoot = Directory(p.join(codexRoot.path, 'sessions'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await sessionsRoot.create(recursive: true);
      await wslRoot.create();
      await _copyFixture('sample_windows_session.json', sessionsRoot);
      await File(
        p.join(codexRoot.path, 'config.json'),
      ).writeAsString('{ bad json');

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: codexRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final result = await RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      ).refresh();

      expect(result.rows, hasLength(1));
      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      expect(
        db.select('select count(*) as count from scan_errors').single['count'],
        0,
      );
    },
  );

  test('runtime persists active and archived source lifecycle separately', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_source_lifecycle_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final codexRoot = Directory(p.join(temp.path, '.codex'));
    final activeRoot = Directory(p.join(codexRoot.path, 'sessions'));
    final archivedRoot = Directory(p.join(codexRoot.path, 'archived_sessions'));
    final unrelatedRoot = Directory(p.join(codexRoot.path, 'plugins'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await activeRoot.create(recursive: true);
    await archivedRoot.create();
    await unrelatedRoot.create();
    await wslRoot.create();
    await _writeJsonFixture(activeRoot, 'active-lifecycle');
    await _writeJsonFixture(archivedRoot, 'archived-lifecycle');
    await _writeJsonFixture(unrelatedRoot, 'unrelated-lifecycle');

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: codexRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    );
    final first = await controller.refresh();

    expect(first.rows, hasLength(2));
    expect(
      {for (final row in first.rows) row.sessionId: row.sourceState},
      {
        'active-lifecycle': SessionRowSourceState.active,
        'archived-lifecycle': SessionRowSourceState.codexArchived,
      },
    );
    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    expect(
      {
        for (final row in db.select(
          'select session_id, source_state from sessions order by session_id',
        ))
          row['session_id']: row['source_state'],
      },
      {'active-lifecycle': 'active', 'archived-lifecycle': 'codex_archived'},
    );
    await controller.reloadSessionDetailFromSource(
      'session:archived-lifecycle',
    );
    expect(
      db
          .select(
            "select source_state from sessions where session_id = 'archived-lifecycle'",
          )
          .single['source_state'],
      'codex_archived',
    );
    db.execute(
      "update sessions set is_archived = 1 where session_id = 'active-lifecycle'",
    );

    await controller.refresh();

    final active = db
        .select(
          "select source_state, is_archived from sessions where session_id = 'active-lifecycle'",
        )
        .single;
    expect(active['source_state'], 'active');
    expect(active['is_archived'], 1);
    expect(
      db
          .select(
            "select count(*) as count from sessions where session_id = 'unrelated-lifecycle'",
          )
          .single['count'],
      0,
    );
  });

  test(
    'reconciles active and archived copies by complete stable identity',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_identity_winner_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final codexRoot = Directory(p.join(temp.path, '.codex'));
      final activeRoot = Directory(p.join(codexRoot.path, 'sessions'));
      final archivedRoot = Directory(
        p.join(codexRoot.path, 'archived_sessions'),
      );
      await activeRoot.create(recursive: true);
      await archivedRoot.create();
      final activeFile = await _writeIdentityFixture(
        activeRoot,
        fileName: 'shared-active.json',
        sessionId: 'shared-identity',
        messages: const [
          ('user', '2026-07-27T10:01:00Z', 'active older message'),
        ],
      );
      final archivedFile = await _writeIdentityFixture(
        archivedRoot,
        fileName: 'shared-archived.json',
        sessionId: 'shared-identity',
        messages: const [
          ('user', '2026-07-27T10:01:00Z', 'archived first message'),
          ('assistant', '2026-07-27T10:02:00Z', 'archived complete reply'),
        ],
      );
      await activeFile.setLastModified(DateTime.utc(2026, 7, 27, 11));
      await archivedFile.setLastModified(DateTime.utc(2026, 7, 27, 10));

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: codexRoot.path,
            wslCodexUncPath: '',
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final result = await RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
        scanBatchingPolicy: const ScanBatchingPolicy(
          parsedSessionFlushBatchSize: 1,
          fullRowSnapshotBatchSize: 1,
        ),
      ).refresh(onProgress: (_) {});

      expect(result.rows, hasLength(1));
      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      final session = db.select('''
            select id, source_file_path, source_state, message_count
            from sessions where session_id = 'shared-identity'
            ''').single;
      expect(
        db.select('select count(*) as count from sessions').single['count'],
        1,
      );
      expect(session['id'], 'session:shared-identity');
      expect(session['source_file_path'], archivedFile.path);
      expect(session['source_state'], 'codex_archived');
      expect(session['message_count'], 2);
      expect(
        db
            .select(
              'select content_plain from messages where session_id = ? '
              'order by message_index',
              ['session:shared-identity'],
            )
            .map((row) => row['content_plain']),
        ['archived first message', 'archived complete reply'],
      );
    },
  );

  test('merges fallback identity and protected metadata atomically', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_fallback_merge_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final codexRoot = Directory(p.join(temp.path, '.codex'));
    final activeRoot = Directory(p.join(codexRoot.path, 'sessions'));
    await activeRoot.create(recursive: true);
    final sourceFile = await _writeIdentityFixture(
      activeRoot,
      fileName: 'fallback-merge.json',
      sessionId: 'fallback-merge',
      messages: const [
        ('user', '2026-07-27T14:00:00Z', 'current parsed message'),
      ],
    );

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: codexRoot.path,
          wslCodexUncPath: '',
        ),
        logging: _testLogging(temp),
        toolOutput: const ToolOutputSettings(
          indexToolOutput: true,
          maxToolOutputPreviewChars: 2000,
          maxToolOutputStoreChars: 20000,
          collapseToolOutputByDefault: true,
        ),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final db = openFileBackedDatabase(databaseFile);
    db.execute('''
      insert into projects (id, name, created_at_utc, updated_at_utc)
      values
        (1, 'Canonical Project', '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z'),
        (2, 'Fallback Project', '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z')
      ''');
    db.execute('''
      insert into sessions (
        id, session_id, source_type, source_file_path, display_path,
        platform_path, project_id, project_name_snapshot, project_override,
        is_pinned, is_archived, archived_at_utc, archive_reason,
        eval_ready, eval_status, eval_notes, eval_expected_output,
        eval_reviewed_at_utc, eval_updated_at_utc,
        created_at_utc, updated_at_utc
      ) values (
        'session:fallback-merge', 'fallback-merge', 'windows',
        'C:\\old\\canonical.jsonl', 'C:\\old\\canonical.jsonl',
        'C:\\old\\canonical.jsonl', 1, 'Canonical Project', 1,
        0, 1, '2026-07-27T12:00:00Z', 'canonical archive reason',
        1, 'canonical-eval', 'canonical notes', 'canonical expected',
        '2026-07-27T10:30:00Z', '2026-07-27T11:00:00Z',
        '2026-07-27T09:00:00Z', '2026-07-27T10:00:00Z'
      )
      ''');
    final fallbackId = 'source:${sourceFile.path}';
    // Linux keeps the case of status IDs; its paths are case-sensitive.
    final normalizedSource = p.normalize(sourceFile.path);
    final statusFallbackId =
        'source-status:${Platform.isLinux ? normalizedSource : normalizedSource.toLowerCase()}';
    db.execute(
      '''
      insert into sessions (
        id, source_type, source_file_path, display_path, platform_path,
        project_id, project_name_snapshot, project_override,
        is_pinned, is_archived, archived_at_utc, archive_reason,
        eval_ready, eval_status, eval_notes, eval_expected_output,
        eval_reviewed_at_utc, eval_updated_at_utc,
        created_at_utc, updated_at_utc
      ) values (?, '$_nativeSourceType', ?, ?, ?, 2, 'Fallback Project', 1,
        1, 1, '2026-07-27T11:00:00Z', 'fallback archive reason',
        1, 'fallback-eval', 'fallback notes', 'fallback expected',
        '2026-07-27T12:30:00Z', '2026-07-27T13:00:00Z',
        '2026-07-27T09:00:00Z', '2026-07-27T12:00:00Z')
      ''',
      [fallbackId, sourceFile.path, sourceFile.path, sourceFile.path],
    );
    db.execute(
      '''
      insert into sessions (
        id, source_type, source_file_path, display_path, platform_path,
        scan_status, parse_status, created_at_utc, updated_at_utc
      ) values (?, '$_nativeSourceType', ?, ?, ?, 'parse_error', 'parse_error',
        '2026-07-27T08:00:00Z', '2026-07-27T08:00:00Z')
      ''',
      [statusFallbackId, sourceFile.path, sourceFile.path, sourceFile.path],
    );
    db.execute('''
      insert into tags (id, name, created_at_utc, updated_at_utc)
      values
        (1, 'canonical-tag', '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z'),
        (2, 'fallback-tag', '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z')
      ''');
    db.execute(
      '''
      insert into session_tags (session_id, tag_id, created_at_utc)
      values
        ('session:fallback-merge', 1, '2026-07-27T09:00:00Z'),
        (?, 2, '2026-07-27T09:00:00Z')
      ''',
      [fallbackId],
    );
    db.execute(
      '''
      insert into session_path_keys (session_id, path_key)
      values
        ('session:fallback-merge', 'c:/old/canonical.jsonl'),
        (?, 'c:/old/fallback.jsonl')
      ''',
      [fallbackId],
    );
    db.execute(
      '''
      insert into messages (
        session_id, message_index, author_type, content_plain,
        content_preview, created_at_db_utc, updated_at_db_utc
      ) values (?, 0, 'user', 'legacy fallback message',
        'legacy fallback message', '2026-07-27T09:00:00Z',
        '2026-07-27T09:00:00Z')
      ''',
      [fallbackId],
    );
    ToolOutputSearchIndex(db).configure(enabled: true);
    db.execute(
      '''
      insert into tool_calls (
        session_id, tool_index, tool_name, status, output_preview
      ) values (?, 0, 'legacy_tool', 'completed', 'legacy output')
      ''',
      [fallbackId],
    );
    _seedIdentityUsageContext(db);
    db.execute(
      '''
      insert into usage_events (
        session_row_id, source_record_ordinal, epoch, path_context_id, input_tokens,
        cached_input_tokens, cache_write_input_tokens, output_tokens,
        reasoning_output_tokens, total_tokens, branch_scope, derivation,
        event_fingerprint
      ) values (?, 1, 0, 1, 1, 0, 0, 1, 0, 2, 'local',
        'cumulative_delta', ?)
      ''',
      [fallbackId, 'c' * 64],
    );
    final fallbackRowId = db.select('select rowid from sessions where id = ?', [
      fallbackId,
    ]).single['rowid'];
    db.execute(
      '''
      insert into session_search (
        rowid, title, summary, tool_names, display_path,
        normalized_path_keys, project_name, tags
      ) values (?, 'staleidentityterm', '', '', '', '', '', '')
      ''',
      [fallbackRowId],
    );
    db.close();

    final result = await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refresh();

    expect(result.rows, hasLength(1));
    final migrated = openFileBackedDatabase(databaseFile);
    addTearDown(migrated.close);
    final session = migrated.select('''
          select is_pinned, project_id, project_name_snapshot,
                 project_override, is_archived, archived_at_utc,
                 archive_reason, eval_ready, eval_status, eval_notes,
                 eval_expected_output, eval_reviewed_at_utc,
                 eval_updated_at_utc
          from sessions where id = 'session:fallback-merge'
          ''').single;
    expect(session['is_pinned'], 1);
    expect(session['project_id'], 2);
    expect(session['project_name_snapshot'], 'Fallback Project');
    expect(session['project_override'], 1);
    expect(session['is_archived'], 1);
    expect(session['archived_at_utc'], '2026-07-27T12:00:00Z');
    expect(session['archive_reason'], 'canonical archive reason');
    expect(session['eval_ready'], 1);
    expect(session['eval_status'], 'fallback-eval');
    expect(session['eval_notes'], 'fallback notes');
    expect(session['eval_expected_output'], 'fallback expected');
    expect(session['eval_reviewed_at_utc'], '2026-07-27T12:30:00Z');
    expect(session['eval_updated_at_utc'], '2026-07-27T13:00:00Z');
    expect(
      migrated
          .select('''
            select t.name
            from session_tags st join tags t on t.id = st.tag_id
            where st.session_id = 'session:fallback-merge'
            order by t.name
            ''')
          .map((row) => row['name']),
      ['canonical-tag', 'fallback-tag'],
    );
    expect(
      migrated
          .select('''
            select path_key from session_path_keys
            where session_id = 'session:fallback-merge'
            order by path_key
            ''')
          .map((row) => row['path_key']),
      containsAll(['c:/old/canonical.jsonl', 'c:/old/fallback.jsonl']),
    );
    expect(
      migrated
          .select(
            "select content_plain from messages where session_id = 'session:fallback-merge'",
          )
          .single['content_plain'],
      'current parsed message',
    );
    final canonicalRowId = migrated
        .select(
          "select rowid from sessions where id = 'session:fallback-merge'",
        )
        .single['rowid'];
    expect(
      migrated
          .select(
            "select rowid from session_search where session_search match 'fallback'",
          )
          .map((row) => row['rowid']),
      contains(canonicalRowId),
    );
    expect(
      migrated
          .select(
            "select count(*) as count from message_search where message_search match 'current'",
          )
          .single['count'],
      1,
    );
    expect(
      migrated
          .select(
            "select count(*) as count from session_search where session_search match 'staleidentityterm'",
          )
          .single['count'],
      0,
    );
    expect(
      migrated
          .select(
            "select count(*) as count from message_search where message_search match 'legacy'",
          )
          .single['count'],
      0,
    );
    expect(
      migrated
          .select(
            "select count(*) as count from tool_output_search where tool_output_search match 'legacy'",
          )
          .single['count'],
      0,
    );
    expect(
      migrated.select(
        'select count(*) as count from sessions where id in (?, ?)',
        [fallbackId, statusFallbackId],
      ).single['count'],
      0,
    );
    for (final table in [
      'messages',
      'tool_calls',
      'session_tags',
      'session_path_keys',
    ]) {
      expect(
        migrated.select(
          'select count(*) as count from $table where session_id = ?',
          [fallbackId],
        ).single['count'],
        0,
        reason: '$table must not retain fallback ownership',
      );
    }
    expect(
      migrated.select(
        'select count(*) as count from usage_events '
        'where session_row_id = ?',
        [fallbackId],
      ).single['count'],
      0,
    );
    expect(migrated.select('pragma foreign_key_check'), isEmpty);
  });

  test('rolls back identity reconciliation failure', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_fallback_rollback_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final codexRoot = Directory(p.join(temp.path, '.codex'));
    final activeRoot = Directory(p.join(codexRoot.path, 'sessions'));
    await activeRoot.create(recursive: true);
    final sourceFile = await _writeIdentityFixture(
      activeRoot,
      fileName: 'fallback-rollback.json',
      sessionId: 'fallback-rollback',
      messages: const [('user', '2026-07-27T14:00:00Z', 'replacement message')],
    );
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: codexRoot.path,
          wslCodexUncPath: '',
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final fallbackId = 'source:${sourceFile.path}';
    final db = openFileBackedDatabase(databaseFile);
    for (final row in [
      (
        id: 'session:fallback-rollback',
        sessionId: 'fallback-rollback',
        sourcePath: 'C:\\old\\canonical-rollback.jsonl',
      ),
      (id: fallbackId, sessionId: null, sourcePath: sourceFile.path),
    ]) {
      db.execute(
        '''
        insert into sessions (
          id, session_id, source_type, source_file_path, display_path,
          platform_path, created_at_utc, updated_at_utc
        ) values (?, ?, '$_nativeSourceType', ?, ?, ?,
          '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z')
        ''',
        [row.id, row.sessionId, row.sourcePath, row.sourcePath, row.sourcePath],
      );
    }
    db.execute('''
      update sessions
      set is_pinned = 1,
          project_name_snapshot = 'Canonical rollback metadata'
      where id = 'session:fallback-rollback'
      ''');
    db.execute('''
      insert into messages (
        session_id, message_index, author_type, content_plain,
        content_preview, created_at_db_utc, updated_at_db_utc
      ) values ('session:fallback-rollback', 0, 'user',
        'canonical original', 'canonical original',
        '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z')
      ''');
    db.execute(
      '''
      insert into messages (
        session_id, message_index, author_type, content_plain,
        content_preview, created_at_db_utc, updated_at_db_utc
      ) values (?, 0, 'user', 'fallback original', 'fallback original',
        '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z')
      ''',
      [fallbackId],
    );
    db.execute('''
      insert into tags (id, name, created_at_utc, updated_at_utc)
      values (1, 'rollback-tag', '2026-07-27T09:00:00Z',
        '2026-07-27T09:00:00Z')
      ''');
    db.execute(
      '''
      insert into session_tags (session_id, tag_id, created_at_utc)
      values (?, 1, '2026-07-27T09:00:00Z')
      ''',
      [fallbackId],
    );
    db.execute(
      'insert into session_path_keys (session_id, path_key) values (?, ?)',
      [fallbackId, 'c:/old/fallback-rollback.jsonl'],
    );
    _seedIdentityUsageContext(db);
    db.execute(
      '''
      insert into usage_events (
        session_row_id, source_record_ordinal, epoch, path_context_id, input_tokens,
        cached_input_tokens, cache_write_input_tokens, output_tokens,
        reasoning_output_tokens, total_tokens, branch_scope, derivation,
        event_fingerprint
      ) values ('session:fallback-rollback', 9, 0, 1, 4, 0, 0, 2, 0, 6,
        'local', 'cumulative_delta', ?)
      ''',
      ['d' * 64],
    );
    db.execute('''
      create trigger fail_identity_reconciliation
      before delete on sessions
      when old.id like 'source:%'
      begin
        select raise(abort, 'injected identity reconciliation failure');
      end
      ''');
    db.close();

    await expectLater(
      RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      ).refresh(),
      throwsA(anything),
    );

    final rolledBack = openFileBackedDatabase(databaseFile);
    addTearDown(rolledBack.close);
    expect(
      rolledBack.select(
        'select count(*) as count from sessions '
        "where id in ('session:fallback-rollback', ?)",
        [fallbackId],
      ).single['count'],
      2,
    );
    final canonical = rolledBack.select('''
      select source_file_path, is_pinned, project_name_snapshot
      from sessions where id = 'session:fallback-rollback'
      ''').single;
    expect(canonical['source_file_path'], r'C:\old\canonical-rollback.jsonl');
    expect(canonical['is_pinned'], 1);
    expect(canonical['project_name_snapshot'], 'Canonical rollback metadata');
    expect(
      rolledBack
          .select(
            "select content_plain from messages where session_id = 'session:fallback-rollback'",
          )
          .single['content_plain'],
      'canonical original',
    );
    for (final table in ['messages', 'session_tags', 'session_path_keys']) {
      expect(
        rolledBack.select(
          'select count(*) as count from $table where session_id = ?',
          [fallbackId],
        ).single['count'],
        1,
        reason: '$table must roll back with the identity transaction',
      );
    }
    expect(
      rolledBack.select('''
            select source_record_ordinal, total_tokens
            from usage_events
            where session_row_id = 'session:fallback-rollback'
            ''').single,
      containsPair('total_tokens', 6),
    );
    expect(rolledBack.select('pragma foreign_key_check'), isEmpty);
  });

  test('non-winning identity cleanup retries dependent usage', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_nonwinning_usage_merge_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    final candidateFile = await _writeIdentityFixture(
      windowsRoot,
      fileName: 'merge-parent.json',
      sessionId: 'merge-parent',
      messages: const [
        ('user', '2026-07-27T14:00:00Z', 'older duplicate candidate'),
      ],
    );
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final alternateId = 'source:${candidateFile.path}';
    final db = openFileBackedDatabase(databaseFile);
    addTearDown(() {
      try {
        db.close();
      } on StateError {
        // The success path closes this setup handle before scanning.
      }
    });
    final generations = DatabaseGenerationRepository(db);
    final generation = generations.createBuilding(
      sourceSchemaVersion: 15,
      targetSchemaVersion: 16,
      sourceFingerprint: 'empty identity fixture',
    );
    generations.markReady(generation.id, validationReportJson: '{}');
    generations.activate(generation.id);
    db.execute('drop index idx_sessions_harness_session_id_unique');
    for (final row in [
      (
        id: 'session:merge-parent',
        sessionId: 'merge-parent',
        sourcePath: 'canonical-parent.jsonl',
        projectionStatus: 'complete',
      ),
      (
        id: alternateId,
        sessionId: 'merge-parent',
        sourcePath: candidateFile.path,
        projectionStatus: 'legacy_pending',
      ),
      (
        id: 'session:merge-child',
        sessionId: 'merge-child',
        sourcePath: 'merge-child.jsonl',
        projectionStatus: 'ambiguous',
      ),
    ]) {
      db.execute(
        '''
        insert into sessions (
          id, session_id, forked_from_id, usage_projection_status,
          source_type, source_file_path, display_path, platform_path,
          parser_version, parse_status, scan_status, last_message_at_utc,
          modified_utc, file_size, created_at_utc, updated_at_utc
        ) values (?, ?, ?, ?, 'windows', ?, ?, ?, ?, 'available',
          'available', ?, '2026-07-27T14:00:00Z', 100,
          '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z')
        ''',
        [
          row.id,
          row.sessionId,
          row.id == 'session:merge-child' ? 'merge-parent' : null,
          row.projectionStatus,
          row.sourcePath,
          row.sourcePath,
          row.sourcePath,
          collectorCodexParserVersion,
          row.id == 'session:merge-parent'
              ? '2027-07-27T14:00:00Z'
              : '2026-07-27T14:00:00Z',
        ],
      );
    }
    for (final event in [
      (
        session: 'session:merge-parent',
        ordinal: 1,
        scope: 'local',
        fingerprint: 'a' * 64,
      ),
      (
        session: 'session:merge-child',
        ordinal: 1,
        scope: 'ambiguous',
        fingerprint: 'a' * 64,
      ),
      (
        session: 'session:merge-child',
        ordinal: 2,
        scope: 'ambiguous',
        fingerprint: 'b' * 64,
      ),
    ]) {
      db.execute(
        '''
        insert into usage_events (
          session_row_id, source_record_ordinal, epoch, input_tokens,
          cached_input_tokens, cache_write_input_tokens, output_tokens,
          reasoning_output_tokens, total_tokens, branch_scope, derivation,
          event_fingerprint, path_context_id, occurred_at_utc
        ) values (?, ?, 0, 1, 0, 0, 1, 0, 2, ?,
          'cumulative_delta', ?, 1, '2026-07-27T14:00:00Z')
        ''',
        [event.session, event.ordinal, event.scope, event.fingerprint],
      );
    }
    db.close();

    await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refresh();

    final reconciled = openFileBackedDatabase(databaseFile);
    addTearDown(reconciled.close);
    expect(
      reconciled.select('select id from sessions where id = ?', [alternateId]),
      isEmpty,
    );
    expect(
      reconciled
          .select(
            "select usage_projection_status from sessions "
            "where id = 'session:merge-child'",
          )
          .single['usage_projection_status'],
      'complete',
    );
    expect(
      reconciled
          .select('''
            select branch_scope from usage_events
            where session_row_id = 'session:merge-child'
            order by source_record_ordinal
            ''')
          .map((row) => row['branch_scope'])
          .toList(),
      ['inherited', 'local'],
    );
    expect(
      reconciled.select('''
      select coalesce(sum(total_tokens), 0) n from usage_session_daily
      where session_id = 'session:merge-child' and branch_scope = 'local'
    ''').single['n'],
      2,
    );
  });

  test('keeps case-distinct WSL fallback identities unresolved', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_wsl_identity_case_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final codexRoot = Directory(p.join(temp.path, '.codex'));
    final activeRoot = Directory(p.join(codexRoot.path, 'sessions'));
    await activeRoot.create(recursive: true);
    final sourceFile = await _writeIdentityFixture(
      activeRoot,
      fileName: 'Case-Sensitive.json',
      sessionId: 'wsl-case-sensitive',
      messages: const [
        ('user', '2026-07-27T14:00:00Z', 'case-sensitive source'),
      ],
    );
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: '',
          wslCodexUncPath: codexRoot.path,
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final caseDistinctPath =
        '/${sourceFile.path.replaceAll(r'\', '/').toLowerCase()}';
    final fallbackId = 'source-status:$caseDistinctPath';
    final db = openFileBackedDatabase(databaseFile);
    db.execute(
      '''
      insert into sessions (
        id, source_type, source_file_path, display_path, platform_path,
        is_pinned, created_at_utc, updated_at_utc
      ) values (?, 'wsl', ?, ?, ?, 1,
        '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z')
      ''',
      [fallbackId, caseDistinctPath, caseDistinctPath, caseDistinctPath],
    );
    db.close();

    await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refresh();

    final refreshed = openFileBackedDatabase(databaseFile);
    addTearDown(refreshed.close);
    expect(
      refreshed.select('select count(*) as count from sessions where id = ?', [
        fallbackId,
      ]).single['count'],
      1,
    );
    expect(
      refreshed
          .select(
            "select is_pinned from sessions where id = 'session:wsl-case-sensitive'",
          )
          .single['is_pinned'],
      0,
    );
  }, skip: _skipWithoutWsl);

  test('release lifecycle certification preflight invariants', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_cache_repair_gate_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final codexRoot = Directory(p.join(temp.path, '.codex'));
    final sessionsRoot = Directory(p.join(codexRoot.path, 'sessions'));
    final pluginsRoot = Directory(p.join(codexRoot.path, 'plugins'));
    await sessionsRoot.create(recursive: true);
    await pluginsRoot.create();
    final malformed = File(p.join(sessionsRoot.path, 'repair-gate.json'));
    await malformed.writeAsString('{ malformed');
    final legacyArtifact = File(p.join(pluginsRoot.path, 'legacy.json'));
    await legacyArtifact.writeAsString('{}');

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: codexRoot.path,
          wslCodexUncPath: '',
        ),
        logging: _testLogging(temp),
      ),
    );
    // The adjacent recovery copy has a longer name than the viewer database.
    // Exercise Windows backup creation and verification beyond MAX_PATH even
    // when the test runner allocates a short temporary root.
    var databaseDirectory = temp;
    if (Platform.isWindows) {
      while (databaseDirectory.path.length < 200) {
        databaseDirectory = Directory(
          p.join(databaseDirectory.path, 'long-path'),
        );
      }
    }
    final databaseFile = File(p.join(databaseDirectory.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);
    final db = openFileBackedDatabase(databaseFile);
    db.execute(
      '''
      insert into sessions (
        id, source_type, source_file_path, display_path, platform_path,
        parser_version, created_at_utc, updated_at_utc
      ) values ('source:legacy-artifact', '$_nativeSourceType', ?, ?, ?, 1,
        '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z')
      ''',
      [legacyArtifact.path, legacyArtifact.path, legacyArtifact.path],
    );
    db.close();

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    );
    // A file that fails to parse under a reachable Codex home does not
    // postpone the repair: only unreachable roots make discovery incomplete.
    await controller.refresh();

    final repaired = openFileBackedDatabase(databaseFile);
    addTearDown(repaired.close);
    expect(
      repaired
          .select(
            "select count(*) as count from sessions where id = 'source:legacy-artifact'",
          )
          .single['count'],
      0,
    );
    expect(
      repaired
          .select(
            "select count(*) as count from app_metadata where key = '$sessionCacheRepairCompletionKey'",
          )
          .single['count'],
      1,
    );
    expect(await legacyArtifact.exists(), isTrue);
    final backups = Directory(p.join(databaseFile.parent.path, 'backups'));
    final backupFiles = await backups
        .list()
        .where((entity) => entity is File)
        .toList();
    expect(backupFiles, hasLength(1));
    if (Platform.isWindows) {
      expect(backupFiles.single.path.length, greaterThan(260));
    }
  });

  test('runtime cache repair failure does not fail the scan', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_cache_repair_failure_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });
    final codexRoot = Directory(p.join(temp.path, '.codex'));
    final sessionsRoot = Directory(p.join(codexRoot.path, 'sessions'));
    await sessionsRoot.create(recursive: true);
    await _writeJsonFixture(sessionsRoot, 'repair-failure-session');
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: codexRoot.path,
          wslCodexUncPath: '',
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);
    final db = openFileBackedDatabase(databaseFile);
    db.execute('''
      create trigger fail_cache_repair_audit
      before insert on session_cache_repair_manifest
      begin
        select raise(abort, 'injected audit failure');
      end
      ''');
    db.close();

    final result = await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refresh();

    expect(result.rows, hasLength(1));
    final refreshed = openFileBackedDatabase(databaseFile);
    addTearDown(refreshed.close);
    expect(
      refreshed
          .select(
            "select count(*) as count from app_metadata where key = '$sessionCacheRepairCompletionKey'",
          )
          .single['count'],
      0,
    );
    expect(
      refreshed
          .select(
            "select details from logs where message = 'Session cache repair postponed.' order by id desc limit 1",
          )
          .single['details']
          .toString(),
      contains('unexpected_repair_error'),
    );
  });

  test('a scan logs the old repair backups the collector deleted', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_repair_backup_retention_',
    );
    addTearDown(() async {
      if (await temp.exists()) await deleteCollectorFixture(temp);
    });
    final codexRoot = Directory(p.join(temp.path, '.codex'));
    await Directory(p.join(codexRoot.path, 'sessions')).create(recursive: true);
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: codexRoot.path,
          wslCodexUncPath: '',
        ),
        logging: _testLogging(temp),
        database: const DatabaseSettings(backupRetentionDays: 3),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    expect(
      (await _migrateCollectorFixture(databaseFile)).canStartNormalUi,
      isTrue,
    );
    final db = openFileBackedDatabase(databaseFile);
    db.execute(
      "insert into app_metadata(key, value, updated_at_utc) values (?, 'repair-3-1-1', '2026-07-01T00:00:00Z')",
      [sessionCacheRepairCompletionKey],
    );
    db.close();
    final created = DateTime.now().subtract(const Duration(days: 4));
    final backup = File(
      p.join(
        temp.path,
        'backups',
        'viewer.pre-session-cache-repair-v3.repair-3-${created.microsecondsSinceEpoch}-1.sqlite',
      ),
    );
    await backup.parent.create();
    await backup.writeAsBytes(List.filled(9, 0));

    await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refresh();

    expect(await backup.exists(), isFalse);
    final logged = openFileBackedDatabase(databaseFile);
    addTearDown(logged.close);
    final details = logged
        .select(
          "select details from logs where message = 'Deleted an old database backup.'",
        )
        .single['details']
        .toString();
    final entry = jsonDecode(details) as Map<String, dynamic>;
    expect(p.equals(entry['path'] as String, backup.path), isTrue);
    expect(entry['bytes'], 9);
  });

  test(
    'refresh applies session_index thread names to unchanged cached rows',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_session_index_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      await _copyFixture('sample_windows_session.json', windowsRoot);

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      );
      final first = await controller.refresh();
      expect(first.rows.single.threadName, isEmpty);

      await File(p.join(windowsRoot.path, 'session_index.jsonl')).writeAsString(
        '{"id":"win-session-001","thread_name":"dmk2","updated_at":"2026-07-08T12:00:00Z"}\n',
      );

      final second = await controller.refresh();
      expect(second.rows.single.threadName, 'dmk2');

      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      expect(
        SessionSearchIndex(db).search(const SessionSearchQuery(text: 'dmk2')),
        [second.rows.single.id],
      );
    },
  );

  test('updates message search when session messages change', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_message_search_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    await _writeMessageSearchFixture(
      windowsRoot,
      userContent: 'first context needle',
      assistantContent: 'first answer body',
    );

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    );
    await controller.refresh();

    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    final index = MessageSearchIndex(db);
    expect(
      index.search(const MessageSearchQuery(text: 'first context needle')),
      hasLength(1),
    );

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await _writeMessageSearchFixture(
      windowsRoot,
      userContent: 'second context needle',
      assistantContent: 'second answer body',
    );
    await controller.refresh();

    final second = index.search(
      const MessageSearchQuery(text: 'second context needle'),
    );
    expect(second, hasLength(1));
    expect(second.single.author, 'user');
    expect(second.single.sessionTitle, 'Message search fixture');
    expect(
      index.search(const MessageSearchQuery(text: 'first context needle')),
      isEmpty,
    );
  });

  test(
    'runtime tool output setting controls the separate search index',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_tool_output_search_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      await _copyFixture('sample_windows_session.json', windowsRoot);
      final defaults = AppSettings.defaults();
      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      final disabledSettings = defaults.copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        logging: _testLogging(temp),
      );
      await SettingsRepository(settingsFile).save(disabledSettings);
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);
      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      );
      await controller.refresh();

      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      const query = SessionSearchQuery(
        text: '2026',
        includeToolOutput: true,
        textScopes: {SearchTextScope.toolOutput},
      );
      expect(SessionSearchIndex(db).search(query), isEmpty);

      await SettingsRepository(settingsFile).save(
        disabledSettings.copyWith(
          toolOutput: ToolOutputSettings(
            indexToolOutput: true,
            maxToolOutputPreviewChars:
                disabledSettings.toolOutput.maxToolOutputPreviewChars,
            maxToolOutputStoreChars:
                disabledSettings.toolOutput.maxToolOutputStoreChars,
            collapseToolOutputByDefault:
                disabledSettings.toolOutput.collapseToolOutputByDefault,
          ),
        ),
      );
      await controller.refresh();

      expect(SessionSearchIndex(db).search(query), isNotEmpty);
    },
  );

  test('updates growing jsonl sessions without duplicate rows', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_growing_jsonl_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    await _writeGrowingJsonlFixture(windowsRoot, messageCount: 1);

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    );
    final first = await controller.refresh();
    expect(first.rows, hasLength(1));
    expect(first.rows.single.messageCount, 1);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await _writeGrowingJsonlFixture(windowsRoot, messageCount: 3);
    final second = await controller.refresh();

    expect(second.rows, hasLength(1));
    expect(second.rows.single.sessionId, 'growing-jsonl-session');
    expect(second.rows.single.messageCount, 3);

    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    expect(
      db
          .select(
            "select count(*) as count from sessions where session_id = 'growing-jsonl-session'",
          )
          .single['count'],
      1,
    );
  });

  test(
    'message backfill yields its writer slot and cancellation wakes its pause',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_backfill_writer_',
      );
      addTearDown(() => deleteCollectorFixture(temp));
      final dbFile = await _prepareBackfillDatabase(temp, count: 4);
      final coordinator = DatabaseMaintenanceCoordinator(dbFile);
      final controller = RuntimeSessionController(
        settingsFile: File(p.join(temp.path, 'unused.toml')),
        databaseFile: dbFile,
        writerCoordinator: coordinator,
      );
      final operation = controller
          .startMessageSearchBackfillInBackgroundOperation(
            batchSize: 1,
            pauseBetweenBatches: const Duration(seconds: 5),
          );
      var finished = false;
      operation.result.then((_) => finished = true);
      Future<void>? writer;
      try {
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (true) {
          final db = openFileBackedDatabase(dbFile);
          final MessageSearchBackfillStatus status;
          try {
            status = MessageSearchIndex(db).backfillStatus();
          } finally {
            db.close();
          }
          if (status.indexed >= 1) break;
          if (DateTime.now().isAfter(deadline)) {
            fail('No committed backfill batch.');
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        writer = coordinator.runWriter(() async {
          final renamed = dbFile.renameSync('${dbFile.path}.writer');
          renamed.renameSync(dbFile.path);
          final db = openFileBackedDatabase(dbFile);
          try {
            expect(MessageSearchIndex(db).backfillStatus().remaining, 3);
            db.execute(
              "insert into app_metadata(key,value,updated_at_utc) values('fixture.writer','ran','2026-09-07T00:00:00Z')",
            );
          } finally {
            db.close();
          }
        });
        await writer.timeout(const Duration(seconds: 1));
        expect(finished, isFalse);
        await operation.cancel().timeout(const Duration(seconds: 1));
        expect((await operation.result).cancelled, isTrue);
      } finally {
        await operation.cancel();
        await writer;
      }
      final resumed = controller
          .startMessageSearchBackfillInBackgroundOperation(
            batchSize: 2,
            pauseBetweenBatches: Duration.zero,
          );
      expect((await resumed.result).complete, isTrue);
      final db = openFileBackedDatabase(dbFile);
      try {
        expect(MessageSearchIndex(db).backfillStatus().indexed, 4);
        expect(
          db
              .select(
                "select value from app_metadata where key='fixture.writer'",
              )
              .single['value'],
          'ran',
        );
      } finally {
        db.close();
      }
    },
  );

  test('queued message backfill cancellation does not index a batch', () async {
    final temp = await Directory.systemTemp.createTemp('csv_backfill_queued_');
    addTearDown(() => deleteCollectorFixture(temp));
    final dbFile = await _prepareBackfillDatabase(temp, count: 4);
    final coordinator = DatabaseMaintenanceCoordinator(dbFile);
    final release = Completer<void>();
    final writer = coordinator.runWriter(() => release.future);
    await Future<void>.delayed(Duration.zero);
    final operation = RuntimeSessionController(
      settingsFile: File(p.join(temp.path, 'unused.toml')),
      databaseFile: dbFile,
      writerCoordinator: coordinator,
    ).startMessageSearchBackfillInBackgroundOperation(batchSize: 1);
    final cancelled = operation.cancel();
    release.complete();
    await writer;
    await cancelled;
    final result = await operation.result;
    expect(result.cancelled, isTrue);
    final db = openFileBackedDatabase(dbFile);
    try {
      expect(MessageSearchIndex(db).backfillStatus().indexed, 0);
    } finally {
      db.close();
    }
  });

  test('message search backfill does not block startup', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'csv_runtime_backfill_',
    );
    addTearDown(() async {
      if (await tempDir.exists()) {
        await _deleteTempDirWithRetry(tempDir);
      }
    });
    final dbFile = File(p.join(tempDir.path, 'viewer.sqlite'));
    final settingsFile = File(p.join(tempDir.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(AppSettings.defaults());
    final startup = await _migrateCollectorFixture(dbFile);
    expect(startup.canStartNormalUi, isTrue);
    final db = openFileBackedDatabase(dbFile);
    _insertBackfillSession(db);
    for (var i = 0; i < 50; i++) {
      _insertBackfillMessage(db, i);
    }
    db.execute(
      "insert into message_search(message_search) values('delete-all')",
    );
    db.execute('''
      update app_metadata
      set value = '0'
      where key = 'message_search.backfill.last_message_rowid'
      ''');
    db.execute('''
      update app_metadata
      set value = (select cast(max(id) as text) from messages)
      where key = 'message_search.backfill.target_message_rowid'
      ''');
    db.close();

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: dbFile,
    );
    final stopwatch = Stopwatch()..start();
    final operation = controller
        .startMessageSearchBackfillInBackgroundOperation(
          batchSize: 1,
          pauseBetweenBatches: const Duration(milliseconds: 20),
        );
    stopwatch.stop();

    expect(stopwatch.elapsedMilliseconds, lessThan(200));
    var completedImmediately = false;
    operation.result.then((_) => completedImmediately = true);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(completedImmediately, isFalse);

    await operation.cancel();
  });

  testWidgets('production refresh distinguishes path errors from empty roots', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          onRefreshResult: () async {
            calls++;
            return const SessionsRefreshResult(
              rows: [],
              statusMessage:
                  r'Scan finished. Session root is unreachable. Unreachable paths: \\wsl.localhost\Ubuntu\home\pawel\.codex',
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.textContaining('Session root is unreachable'), findsOneWidget);
    expect(
      find.text('Codex session path is currently unreachable.'),
      findsOneWidget,
    );
    expect(find.text('Retry scan'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
    expect(
      find.textContaining(
        r'Configured path: \\wsl.localhost\Ubuntu\home\pawel\.codex',
      ),
      findsOneWidget,
    );
    expect(find.text('No sessions found.'), findsNothing);
  });

  testWidgets('refresh failure clears scanning state and shows error', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          onRefreshResult: () async {
            calls++;
            throw const FormatException('Invalid settings.toml');
          },
        ),
      ),
    );

    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(find.text('Refresh'), findsOneWidget);
    expect(
      find.text('Refresh could not finish. Select Refresh to try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('Invalid settings.toml'), findsNothing);
  });

  for (final (error, message) in <(Object, String)>[
    (
      const CollectorUnavailableException('missing', 'raw install path'),
      'Session collection could not start. Saved sessions are still shown. Reinstall Codex Sessions Viewer to restore session collection.',
    ),
    (
      const CollectorDisconnectedException('raw pipe error'),
      'Refresh stopped because the session collection connection was interrupted. Select Refresh to try again.',
    ),
    (
      const CollectorRequestException(
        'protocol_error',
        'raw protocol frame exceeds limit',
      ),
      'Refresh stopped because session collection sent an invalid response. Select Refresh to try again. If this keeps happening, restart Codex Sessions Viewer.',
    ),
    (
      const CollectorRequestException('busy'),
      'Session collection is busy. Try Refresh again in a moment.',
    ),
    (
      const CollectorRequestException('refused'),
      'Session collection is busy. Try Refresh again in a moment.',
    ),
  ]) {
    testWidgets(
      'refresh maps ${error.runtimeType} to retryable plain text: $message',
      (tester) async {
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            MaterialApp(
              home: SessionsScreen(onRefreshResult: () async => throw error),
            ),
          );
          await tester.tap(find.text('Refresh'));
          await tester.pumpAndSettle();
          expect(find.text(message), findsOneWidget);
          expect(find.textContaining('Bad state:'), findsNothing);
          expect(find.textContaining('raw pipe error'), findsNothing);
          // ignore: avoid_print
          print(
            'refresh_label="$message" semantics=${tester.getSemantics(find.text(message)).label}',
          );
        } finally {
          semantics.dispose();
        }
      },
    );
  }

  for (final (hung, reconnect) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    testWidgets(
      'saved startup and bounded app exit (hung bridge=$hung reconnect=$reconnect)',
      (tester) async {
        late Directory root;
        late File file;
        late File settings;
        late ResidentCollectorClient client;
        ScriptedBridge? hungBridge;
        late Future<DatabaseStartupResult> startup;
        late AppSettings configured;
        await tester.binding.setSurfaceSize(const Size(1800, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('cxv184-saved-missing-');
          file = File(p.join(root.path, 'viewer.sqlite'));
          settings = File(p.join(root.path, 'settings.toml'));
          await _migrateCollectorFixture(file);
          final db = openFileBackedDatabase(file);
          _insertBackfillSession(db);
          db.execute(
            "update sessions set session_id='saved-startup-session', started_at_utc='2026-07-08T10:00:00Z', last_message_at_utc='2026-07-08T10:00:00Z'",
          );
          db.close();
          configured = AppSettings.defaults().copyWith(
            paths: const PathSettings(
              windowsCodexPath: '',
              wslCodexUncPath: '',
            ),
            logging: _testLogging(root),
          );
          await SettingsRepository(settings).save(configured);
          if (hung) hungBridge = ScriptedBridge();
          client = ResidentCollectorClient(
            databaseFile: file,
            settingsFile: settings,
            start: (exe, args) async {
              if (!hung) {
                throw ProcessException(exe, args, 'missing executable');
              }
              final bridge = hungBridge!;
              bridge.emit({'event': 'bridge', 'state': 'connected'});
              return bridge;
            },
          );
          startup = Future.value(
            await DatabaseMigrator(
              sqlRoot: Directory('../sql'),
              pauseCollector: client.pause,
            ).openAndMigrate(file),
          );
        });
        final semantics = tester.ensureSemantics();
        try {
          await tester.pumpWidget(
            CodexSessionsViewerApp(
              databaseFile: file,
              settingsFile: settings,
              collectorClient: client,
              databaseStartup: startup,
              settingsStartup: Future.value(configured),
              now: () => DateTime.utc(2026, 7, 9),
            ),
          );
          for (var i = 0; i < 200; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 30)),
            );
            await tester.pump(const Duration(milliseconds: 50));
            if (hung
                ? (hungBridge?.received.any((r) => r['op'] == 'scan') ??
                          false) &&
                      find.text('Backfill session').evaluate().isNotEmpty
                : find
                          .textContaining('Reinstall Codex Sessions Viewer')
                          .evaluate()
                          .isNotEmpty &&
                      find.text('Refresh').evaluate().isNotEmpty) {
              break;
            }
          }
          await tester.pump(const Duration(milliseconds: 200));
          expect(find.text('Backfill session'), findsOneWidget);
          expect(
            find.textContaining('SQLite database startup failed'),
            findsNothing,
          );
          if (hung) {
            expect(hungBridge!.received.any((r) => r['op'] == 'scan'), isTrue);
            if (reconnect) {
              await tester.runAsync(() async {
                hungBridge!.emit({'event': 'bridge', 'state': 'reconnecting'});
                await Future<void>.delayed(Duration.zero);
              });
              await tester.pump();
              expect(client.statusText, 'Reconnecting to session collection…');
            }
          } else {
            const label =
                'Session collection could not start. Saved sessions are still shown. Reinstall Codex Sessions Viewer to restore session collection.';
            expect(
              find.descendant(
                of: find.byType(CollectorStatus),
                matching: find.text(label),
              ),
              findsOneWidget,
            );
            expect(
              tester
                  .getSemantics(
                    find.descendant(
                      of: find.byType(CollectorStatus),
                      matching: find.bySemanticsLabel(label),
                    ),
                  )
                  .getSemanticsData()
                  .flagsCollection
                  .isLiveRegion,
              isTrue,
            );
            // ignore: avoid_print
            print(
              'startup_missing saved_session_visible=true fatal_screen=false unavailable_live_region=true reinstall_guidance=true',
            );
          }
        } finally {
          var exited = false;
          final exitWatch = Stopwatch()..start();
          final exit = tester.binding.handleRequestAppExit().then((value) {
            exited = true;
            return value;
          });
          final deadline = DateTime.now().add(const Duration(seconds: 5));
          while (!exited && DateTime.now().isBefore(deadline)) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          final withinBound = exited;
          if (!exited) await tester.runAsync(client.dispose);
          while (!exited) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump();
          }
          await exit;
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await client.dispose();
            await deleteCollectorFixture(root);
          });
          semantics.dispose();
          expect(
            withinBound,
            isTrue,
            reason: 'App exit must not await a hung scan indefinitely.',
          );
          if (hung) expect(hungBridge!.killed, isTrue);
          // ignore: avoid_print
          print(
            'app_exit_hung=$hung reconnect=$reconnect elapsed_ms=${exitWatch.elapsedMilliseconds} completed_within_5s=$withinBound',
          );
        }
      },
    );
  }

  test('omitted summary diagnostics retain totals in logs and status', () async {
    final root = await Directory.systemTemp.createTemp('cxv194-omissions-');
    final database = File(p.join(root.path, 'viewer.sqlite'));
    final settings = File(p.join(root.path, 'settings.toml'));
    await SettingsRepository(settings).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(windowsCodexPath: root.path, wslCodexUncPath: ''),
        logging: _testLogging(root),
      ),
    );
    expect((await _migrateCollectorFixture(database)).canStartNormalUi, isTrue);
    final bridge = ScriptedBridge();
    bridge.onRequest = (request) {
      if (request['op'] != 'scan') return;
      bridge.emit({
        'id': request['id'],
        'event': 'finished',
        'command': 'codex scan',
        'files_failed': 200,
        'all_configured_roots_reachable': false,
        'errors_omitted': 100,
        'unreachable_paths_omitted': 100,
        'errors': List.generate(
          100,
          (i) => {
            'path': 'missing-$i',
            'status': 'missing',
            'message': 'Missing file.',
          },
        ),
        'cache_repair': {
          'status': 'completed',
          'reason_code': '',
          'deleted_rows': 0,
          'prune_failures': List.generate(100, (i) => 'locked-$i.sqlite'),
          'prune_failures_omitted': 100,
          'pruned_backups': List.generate(
            100,
            (i) => {'path': 'old-$i.sqlite', 'bytes': 1},
          ),
          'pruned_backups_omitted': 100,
        },
      });
      bridge.emit({'id': request['id'], 'event': 'done', 'cancelled': false});
    };
    final client = ResidentCollectorClient(
      databaseFile: database,
      settingsFile: settings,
      start: (_, _) async {
        bridge.emit({'event': 'bridge', 'state': 'connected'});
        return bridge;
      },
    );
    try {
      final result = await RuntimeSessionController(
        databaseFile: database,
        settingsFile: settings,
        collectorClient: client,
      ).refresh();
      final db = openFileBackedDatabase(database);
      try {
        final entries = db.select('select message, details, level from logs');
        for (final key in [
          'prune_failures_omitted',
          'pruned_backups_omitted',
          'errors_omitted',
          'unreachable_paths_omitted',
        ]) {
          expect(
            entries.any(
              (row) =>
                  (jsonDecode(row['details'] as String)
                      as Map<String, dynamic>)[key] ==
                  100,
            ),
            isTrue,
            reason: key,
          );
        }
        final warning = entries.singleWhere(
          (row) =>
              row['message'] ==
              '100 additional old database backups could not be deleted; their details were omitted.',
        );
        expect(warning['level'], 'warning');
        expect(
          (jsonDecode(warning['details'] as String) as Map)['total_count'],
          200,
        );
        expect(
          entries.where(
            (row) =>
                row['message'] ==
                'An old database backup could not be deleted; it may be open in another program.',
          ),
          hasLength(100),
        );
      } finally {
        db.close();
      }
      expect(
        result.statusMessage,
        contains('100 additional session collection errors omitted.'),
      );
      expect(
        result.statusMessage,
        contains('100 additional unreachable paths omitted.'),
      );
      expect(
        result.statusMessage,
        contains(
          'Session root is unreachable. Check your Windows and WSL Codex paths in Settings, then run Refresh.',
        ),
      );
      expect(
        result.statusMessage,
        allOf(
          contains('100 more repair problems were not listed; see the log.'),
          contains('100 more deleted backups were not listed; see the log.'),
        ),
      );
    } finally {
      await client.dispose();
      await deleteCollectorFixture(root);
    }
  });

  test('runtime refresh does not show root errors as session rows', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_scan_empty_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final emptyRoot = Directory(p.join(temp.path, 'empty'));
    await emptyRoot.create();
    final missingRoot = p.join(temp.path, 'missing');
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        // Off Windows only the native root is scanned, so it is the missing one.
        paths: PathSettings(
          windowsCodexPath: Platform.isWindows ? emptyRoot.path : missingRoot,
          wslCodexUncPath: Platform.isWindows ? missingRoot : '',
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final result = await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refresh();

    expect(result.rows, isEmpty);
    expect(result.statusMessage, contains('Session root is unreachable'));
    expect(result.statusMessage, contains(missingRoot));
  });

  test('runtime refresh distinguishes empty reachable roots', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_scan_empty_reachable_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        pricing: _testPricing(),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final result = await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refresh();

    expect(result.rows, isEmpty);
    expect(result.statusMessage, contains('No supported files found'));
  });

  test('runtime refresh continues when the text log cannot open', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_scan_unavailable_log_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    final unavailableLogFile = Directory(p.join(temp.path, 'unavailable.log'));
    await windowsRoot.create();
    await wslRoot.create();
    await unavailableLogFile.create();
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        pricing: _testPricing(),
        logging: LoggingSettings(
          level: 'info',
          logFile: unavailableLogFile.path,
          maxLogFiles: 2,
          maxLogSizeMb: 1,
        ),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final result = await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refresh();

    expect(result.rows, isEmpty);
    expect(result.statusMessage, contains('No supported files found'));
    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    expect(
      db
          .select(
            "select count(*) as count from logs where message like 'Text log write failed%'",
          )
          .single['count'],
      1,
    );
  });

  testWidgets('empty reachable scans show a no-sessions empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialStatusMessage: 'Scan finished. No supported files found.',
        ),
      ),
    );

    expect(find.text('No sessions found.'), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(find.text('Open Settings'), findsOneWidget);
  });

  testWidgets('filters hiding rows show a clear-filters empty state', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [_row('visible-row', SessionRowPlatform.windows)],
        ),
      ),
    );

    await tester.enterText(find.bySemanticsLabel('Session search'), 'nomatch');
    await tester.pump(const Duration(milliseconds: 221));
    await tester.pumpAndSettle();

    expect(find.text('No sessions match the current filters.'), findsOneWidget);
    expect(find.text('Clear filters'), findsWidgets);
  });

  testWidgets('app shell wires runtime refresh into the Sessions screen', (
    tester,
  ) async {
    var refreshCalls = 0;
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 3),
        ),
        sessionRefresh: () async {
          refreshCalls++;
          return SessionsRefreshResult.scanFinished([
            _row('runtime-row', SessionRowPlatform.windows),
          ]);
        },
        deferInitialSessionLoad: (_) {},
        now: () => DateTime.utc(2026, 6, 15, 12),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(refreshCalls, 1);
    expect(find.text('Loaded from runtime scan'), findsOneWidget);
  });

  testWidgets('app shell launches terminal from structured arguments', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    TerminalLaunchSpec? launched;
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 3),
        ),
        settingsStartup: Future.value(AppSettings.defaults()),
        sessionRefresh: () async =>
            SessionsRefreshResult.scanFinished([_resumableRow('resume-row')]),
        deferInitialSessionLoad: (_) {},
        terminalLaunch: (spec) async {
          launched = spec;
          return 1234;
        },
        now: () => DateTime.utc(2026, 6, 15, 12),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.bySemanticsLabel('Open terminal and resume for resume-row'),
    );
    await tester.pumpAndSettle();

    expect(launched?.executable, r'C:\Program Files\Alacritty\alacritty.exe');
    expect(launched?.arguments, contains('codex resume resume-row'));
    expect(find.text('Opening terminal for resume-row.'), findsOneWidget);
  });

  testWidgets('terminal launch failure remains visible in a dialog', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 3),
        ),
        settingsStartup: Future.value(AppSettings.defaults()),
        sessionRefresh: () async =>
            SessionsRefreshResult.scanFinished([_resumableRow('failed-row')]),
        deferInitialSessionLoad: (_) {},
        terminalLaunch: (_) async {
          throw const ProcessException(
            'alacritty.exe',
            <String>[],
            'Access denied',
          );
        },
        now: () => DateTime.utc(2026, 6, 15, 12),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.bySemanticsLabel('Open terminal and resume for failed-row'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not open terminal'), findsOneWidget);
    expect(find.textContaining('Access denied'), findsOneWidget);
    expect(find.text('Copy resume command'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('app shell cancels active refresh operation on dispose', (
    tester,
  ) async {
    final refresh = Completer<SessionsRefreshResult>();
    var cancelCalls = 0;
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 5),
        ),
        settingsStartup: Future.value(AppSettings.defaults()),
        sessionRefreshOperation: (_) => SessionsRefreshOperation(
          result: refresh.future,
          cancel: () {
            cancelCalls++;
            return refresh.future.then<void>((_) {});
          },
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Refresh'));
    await tester.pump();
    expect(find.text('Cancel scan'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(cancelCalls, 1);
    refresh.complete(
      const SessionsRefreshResult(
        rows: [],
        statusMessage: 'Scan cancelled.',
        cancelled: true,
      ),
    );
  });

  testWidgets('settings save and reload never start a viewer rescan timer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final temp = Directory.systemTemp.createTempSync(
      'csv_runtime_settings_rescan_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.runAsync(() async {
        if (!await temp.exists()) {
          return;
        }
        await deleteCollectorFixture(temp);
      });
    });

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final disabledSettings = AppSettings.defaults().copyWith(
      scanner: const ScannerSettings(
        backgroundRescanEnabled: false,
        backgroundRescanIntervalSeconds: 1,
      ),
    );
    var storedSettings = disabledSettings;
    var refreshCalls = 0;

    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 5),
        ),
        settingsFile: settingsFile,
        databaseFile: databaseFile,
        settingsStartup: Future.value(disabledSettings),
        settingsSave: (settings) async {
          storedSettings = settings;
        },
        settingsReload: () async => storedSettings,
        sessionRefreshOperation: (_) {
          refreshCalls++;
          return SessionsRefreshOperation.fromFuture(
            Future.value(
              const SessionsRefreshResult(
                rows: [],
                statusMessage: 'Scan finished.',
              ),
            ),
          );
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(refreshCalls, 0);

    await tester.tap(
      find.bySemanticsLabel(RegExp('^Settings navigation\\nTab ')),
    );
    await _pumpFrames(tester);
    await tester.ensureVisible(
      find.bySemanticsLabel('Background scan enabled setting'),
    );
    await tester.tap(find.bySemanticsLabel('Background scan enabled setting'));
    await tester.pump();
    await tester.tap(find.text('Save settings'));
    await _pumpFrames(tester);
    expect(storedSettings.scanner.backgroundRescanEnabled, isTrue);
    expect(
      tester
          .widget<SettingsScreen>(find.byType(SettingsScreen))
          .initialSettings!
          .scanner
          .backgroundRescanEnabled,
      isTrue,
    );

    await tester.tap(
      find.bySemanticsLabel(RegExp('^Sessions navigation\\nTab ')),
    );
    await tester.pump();
    expect(
      tester
          .widget<SessionsScreen>(find.byType(SessionsScreen))
          .settings!
          .scanner
          .backgroundRescanEnabled,
      isTrue,
    );
    await tester.pump(const Duration(milliseconds: 1001));
    expect(refreshCalls, 0);

    storedSettings = disabledSettings;
    await tester.tap(
      find.bySemanticsLabel(RegExp('^Settings navigation\\nTab ')),
    );
    await _pumpFrames(tester);
    await tester.tap(find.text('Reload from file'));
    await _pumpFrames(tester);

    await tester.tap(
      find.bySemanticsLabel(RegExp('^Sessions navigation\\nTab ')),
    );
    await tester.pump();
    final callsAfterReload = refreshCalls;
    await tester.pump(const Duration(milliseconds: 1001));
    expect(refreshCalls, callsAfterReload);
  });

  test('runtime loads cached sessions before refresh is clicked', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_cached_startup_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    await _copyFixture('sample_windows_session.json', windowsRoot);

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        pricing: _testPricing(),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refresh();

    final cached = await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).loadCachedRows();

    expect(cached.rows, hasLength(1));
    expect(cached.rows.single.title, 'Windows parser fixture');
    expect(cached.rows.single.project, 'codex-sessions-viewer');
    expect(cached.rows.single.estimatedCostDisplay, 'Cost unknown');
    expect(
      cached.statusMessage,
      'Loaded 1 of 1 sessions from the previous scan.',
    );

    final detail = await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).loadSessionDetail(cached.rows.single.id);

    // No usage events were recorded in this JSON fixture. Persisted pricing
    // deliberately leaves the estimate unknown instead of inventing costs.
    expect(detail?.estimatedCostDisplay, 'Cost unknown');
    expect(detail?.userMessageTokens, 12);
    expect(detail?.assistantResponseTokens, 28);
    expect(detail?.modelsUsedForDetail, ['gpt-5.5-thinking']);
  });

  test('persisted cost lookup cannot create a database', () async {
    final temp = await Directory.systemTemp.createTemp('csv_cost_readonly_');
    addTearDown(() => deleteCollectorFixture(temp));
    final file = File(p.join(temp.path, 'missing.sqlite'));
    final controller = RuntimeSessionController(
      settingsFile: File(p.join(temp.path, 'unused.toml')),
      databaseFile: file,
    );
    try {
      await controller.loadPersistedSessionCosts(['missing']);
    } on Object {
      // A missing database may fail, but must never be created by a cost read.
    }
    expect(await file.exists(), isFalse);
  });

  test('cached and detailed sessions use historical local projected costs', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_historical_cost_',
    );
    addTearDown(() => deleteCollectorFixture(temp));
    final windowsRoot = await Directory(p.join(temp.path, 'windows')).create();
    await _writeAggregateJsonlFixture(windowsRoot);
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: p.join(temp.path, 'missing-wsl'),
        ),
        pricing: _testPricing(),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);
    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    final generations = DatabaseGenerationRepository(db);
    final generation = generations.createBuilding(
      sourceSchemaVersion: 15,
      targetSchemaVersion: 16,
      sourceFingerprint: 'empty fixture',
    );
    generations.markReady(
      generation.id,
      validationReportJson: jsonEncode(
        UsagePathContextMigration(db).validateShadowParity(),
      ),
    );
    generations.activate(generation.id);
    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    );
    final scanned = await controller.refresh();
    final id = scanned.rows.single.id;
    expect(
      db.select(
        'select parse_status, usage_projection_status, parser_version from sessions where id = ?',
        [id],
      ).single,
      {
        'parse_status': 'available',
        'usage_projection_status': 'complete',
        'parser_version': collectorCodexParserVersion,
      },
    );
    db.execute('''
      insert into local_price_override_periods (model_id, prompt_price_per_token,
        settings_fingerprint, valid_from_utc, first_settings_revision, last_seen_settings_revision)
      values ('gpt-5.5-thinking', '0.01', 'historical fixture', '2026-01-01T00:00:00Z', 1, 1);
      delete from usage_session_daily;
      delete from usage_cost_dirty_partitions;
    ''');
    final basis = db.lastInsertRowId;
    for (final (day, scope, cost) in [
      ('2026-06-01', 'local', '0.10'),
      ('2026-06-02', 'local', '0.20'),
      ('2026-06-03', 'inherited', '99'),
    ]) {
      db.execute(
        '''
        insert into usage_session_daily (session_id, day_utc, model_key, path_context_id,
          branch_scope, input_tokens, cached_input_tokens, cache_write_input_tokens,
          output_tokens, reasoning_output_tokens, total_tokens, estimated_cost_text,
          cost_status, local_override_period_id, pricing_resolution_method,
          cost_projection_version, updated_at_utc)
        values (?, ?, 'gpt-5.5-thinking', 1, ?, 10, 0, 0, 0, 0, 10, ?, 'complete', ?, 'local_exact', 1, '2026-06-04')
      ''',
        [id, day, scope, cost, basis],
      );
    }
    Future<void> expectCost(String display) async {
      final cached = await controller.loadCachedRows();
      expect(cached.rows.single.estimatedCostDisplay, display);
      final detail = await controller.loadSessionDetail(id);
      expect(detail?.estimatedCostDisplay, display);
    }

    await expectCost(r'$0.3');
    final isolatedCosts = await controller.loadPersistedSessionCosts([
      id,
      'missing',
    ]);
    expect(isolatedCosts?[id]?.estimatedCostText, '0.3');
    expect(isolatedCosts?['missing']?.costUnknown, isTrue);
    final batch = UsageSummaryRepository(db).loadPersistedSessionCosts([
      for (var i = 0; i < 520; i++) 'missing-$i',
      id,
    ], projectionVersion: collectorCodexParserVersion)!;
    expect(batch, hasLength(521));
    expect(batch[id]!.estimatedCostText, '0.3');
    expect(batch['missing-0']!.costUnknown, isTrue);
    expect(batch['missing-519']!.costUnknown, isTrue);
    db.execute(
      '''
      insert into usage_cost_dirty_partitions (session_id, day_utc, model_key, reason,
        target_cost_projection_version, created_at_utc, updated_at_utc)
      values (?, '2026-06-03', 'gpt-5.5-thinking', 'fixture', 1, '2026-06-04', '2026-06-04')
    ''',
      [id],
    );
    await expectCost(r'$0.3');
    db.execute("update usage_cost_dirty_partitions set day_utc = '2026-06-01'");
    await expectCost('Pricing update in progress');
    db.execute('delete from usage_cost_dirty_partitions');
    db.execute(
      "update usage_session_daily set cost_status = 'partial_unsupported_units' where day_utc = '2026-06-02'",
    );
    await expectCost(r'$0.3 (partial)');
    db.execute(
      "update usage_session_daily set cost_status = 'unknown', estimated_cost_text = null where day_utc = '2026-06-01'",
    );
    await expectCost('Cost unknown');
    db.execute(
      "update usage_session_daily set estimated_cost_text = '0', cost_status = 'complete'",
    );
    await expectCost(r'$0');
    db.execute(
      "update sessions set usage_projection_status = 'ambiguous' where id = ?",
      [id],
    );
    await expectCost('Cost unknown');
    db.execute(
      "update sessions set usage_projection_status = 'complete', parser_version = 0 where id = ?",
      [id],
    );
    await expectCost('Cost unknown');
  });

  test(
    'warm unchanged refresh does not rewrite skipped cached session rows',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_warm_skip_no_rewrite_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      await windowsRoot.create();
      await _copyFixture('sample_windows_session.json', windowsRoot);

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: p.join(temp.path, 'missing-wsl'),
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      );
      await controller.refresh();

      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      Map<String, Object?> sessionTimestamps() => db.select('''
      select updated_at_utc, last_scanned_utc
      from sessions
      where id not like 'source-status:%'
      ''').single;
      final before = sessionTimestamps();

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await controller.refresh();
      final after = sessionTimestamps();
      final scanRun = db.select('''
      select files_parsed, files_skipped
      from scan_runs
      order by id desc
      limit 1
      ''').single;

      expect(scanRun['files_parsed'], 0);
      expect(scanRun['files_skipped'], 1);
      expect(after, before);
    },
  );

  test(
    'rescans backfill auto projects and clean placeholders the viewer no longer writes',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_cached_auto_project_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      await _copyFixture('sample_windows_session.json', windowsRoot);

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      );
      await controller.refresh();

      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      db.execute('''
      update sessions
      set project_id = null,
          project_name_snapshot = null,
          project_override = 0,
          title = '# AGENTS.md instructions for this repo',
          summary = 'auto'
      ''');
      db.execute('update session_search set project_name = ?', ['']);
      db.execute('update session_search set title = ?, summary = ?', [
        '# AGENTS.md instructions for this repo',
        'auto',
      ]);

      // The collector repairs stored rows on its next scan; loading only reads.
      final cached = await controller.refresh();
      expect(cached.rows.single.project, 'codex-sessions-viewer');
      expect(cached.rows.single.title, isEmpty);
      expect(cached.rows.single.summary, isEmpty);
      final row = db
          .select(
            'select title, summary, project_name_snapshot, project_override from sessions',
          )
          .single;
      expect(row['title'], isNull);
      expect(row['summary'], isNull);
      expect(row['project_name_snapshot'], 'codex-sessions-viewer');
      expect(row['project_override'], 0);
    },
  );

  test('runtime batches WSL project resolution for each refresh', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_wsl_project_batch_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    const sharedPath = '/home/pawel/projects/shared';
    const unresolvedPath = '/home/pawel/projects/unresolved';
    await _writeWslJsonFixture(wslRoot, 'wsl-shared-a', sharedPath);
    await _writeWslJsonFixture(wslRoot, 'wsl-shared-b', sharedPath);
    await _writeWslJsonFixture(wslRoot, 'wsl-unresolved', unresolvedPath);

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final resolver = _RecordingWslProjectResolver({sharedPath: 'shared-root'});
    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
      scanBatchingPolicy: const ScanBatchingPolicy(
        parsedSessionFlushBatchSize: 1,
        fullRowSnapshotBatchSize: 1,
      ),
      wslProjectResolver: resolver,
    );

    final progressEvents = <SessionsRefreshProgress>[];
    final refreshed = await controller.refresh(onProgress: progressEvents.add);
    expect(refreshed.persistenceFlushCount, greaterThanOrEqualTo(1));
    expect(refreshed.rows.map((row) => row.project).toSet(), {
      'shared-root',
      'unresolved',
    });
    expect(refreshed.rows, hasLength(3));
    expect(resolver.calls, [
      {sharedPath, unresolvedPath},
    ]);

    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    db.execute('''
      update sessions
      set project_id = null,
          project_name_snapshot = null,
          project_override = 0
      ''');
    db.execute('update session_search set project_name = ?', ['']);

    resolver.results[sharedPath] = 'cached-root';
    final cached = await controller.refresh();

    expect(cached.rows.map((row) => row.project).toSet(), {
      'cached-root',
      'unresolved',
    });
    expect(resolver.calls, [
      {sharedPath, unresolvedPath},
      {sharedPath, unresolvedPath},
    ]);
  }, skip: _skipWithoutWsl);

  test('resolved WSL paths expose containing-folder actions', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_wsl_openable_path_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    await _writeWslJsonFixture(
      wslRoot,
      'wsl-resolved-openable',
      '/home/pawel/project',
      workingDirectoryUnc: r'\\wsl.localhost\Ubuntu\home\pawel\project',
    );

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    // A fake resolver keeps the scan off the real wsl.exe (T-169).
    final resolver = _RecordingWslProjectResolver({});
    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
      wslProjectResolver: resolver,
    );
    final result = await controller.refresh();
    final wslRow = result.rows.singleWhere(
      (row) => row.platform == SessionRowPlatform.wsl,
    );

    expect(resolver.calls, [
      {'/home/pawel/project'},
    ]);
    expect(wslRow.path, '/home/pawel/project');
    expect(wslRow.openablePath, r'\\wsl.localhost\Ubuntu\home\pawel\project');
  }, skip: _skipWithoutWsl);

  test(
    'runtime Windows containing-folder target prefers working directory',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_windows_openable_path_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      await _copyFixture('sample_windows_session.json', windowsRoot);

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      );
      final result = await controller.refresh();
      final windowsRow = result.rows.singleWhere(
        (row) => row.platform == SessionRowPlatform.windows,
      );

      expect(
        windowsRow.sourcePathForDisplay,
        isNot(windowsRow.containingFolderTarget),
      );
      expect(
        windowsRow.containingFolderTarget,
        r'F:\projects\MaxLogic\codex-sessions-viewer',
      );
    },
    skip: Platform.isWindows
        ? false
        : 'The fixture records a Windows working directory.',
  );

  test(
    'unresolved WSL working directories do not fall back to session file UNC',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_wsl_unresolved_openable_path_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      await _writeWslJsonFixture(
        wslRoot,
        'wsl-unresolved-openable',
        '/mnt/f/projects/oec/te5/maxtdb',
      );

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      // A fake resolver keeps the scan off the real wsl.exe (T-169).
      final resolver = _RecordingWslProjectResolver({});
      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
        wslProjectResolver: resolver,
      );
      final result = await controller.refresh();
      final wslRow = result.rows.singleWhere(
        (row) => row.platform == SessionRowPlatform.wsl,
      );

      expect(resolver.calls, [
        {'/mnt/f/projects/oec/te5/maxtdb'},
      ]);
      expect(wslRow.path, '/mnt/f/projects/oec/te5/maxtdb');
      expect(wslRow.openablePath, isEmpty);
      expect(wslRow.canOpenContainingFolder, isFalse);
    },
    skip: _skipWithoutWsl,
  );

  test('runtime cancellable refresh preserves partial cached rows', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_cancel_scan_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    for (var i = 0; i < 80; i++) {
      await _writeJsonFixture(windowsRoot, 'cancel-$i');
    }

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
      scanBatchingPolicy: const ScanBatchingPolicy(
        parsedSessionFlushBatchSize: 1,
        fullRowSnapshotBatchSize: 1,
      ),
    );
    late CancellableSessionScanOperation operation;
    Future<void>? cancelAck;
    operation = controller.startRefreshOperation(
      onProgress: (progress) {
        if ((progress.rows?.isNotEmpty ?? false) && cancelAck == null) {
          cancelAck = operation.cancel();
        }
      },
    );

    final result = await operation.result;
    await cancelAck;

    expect(result.cancelled, isTrue);
    expect(result.statusMessage, contains('cancelled'));
    expect(result.rows, isNotEmpty);
    expect(result.rows.length, lessThan(80));

    final cached = await controller.loadCachedRows();
    expect(cached.rows, hasLength(result.rows.length));
  });

  test(
    'runtime cancellable rescan keeps prior cached rows available',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_cancel_cached_scan_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      const sessionCount = 120;
      for (var i = 0; i < sessionCount; i++) {
        await _writeJsonFixture(windowsRoot, 'cached-cancel-$i');
      }

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final collector = ResidentCollectorClient(
        databaseFile: databaseFile,
        settingsFile: settingsFile,
      );
      addTearDown(collector.dispose);
      final controller = RuntimeSessionController(
        collectorClient: collector,
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      );
      final first = await controller.refresh();
      expect(first.cancelled, isFalse);
      expect(first.rows, hasLength(sessionCount));

      late CancellableSessionScanOperation operation;
      Future<void>? cancelAck;
      operation = controller.startRefreshOperation(
        onProgress: (progress) {
          if (cancelAck != null) {
            return;
          }
          if (progress.statusMessage.startsWith('Scanning...') &&
              !progress.statusMessage.contains('found 0 JSON files')) {
            cancelAck = operation.cancel();
          }
        },
      );

      final result = await operation.result;
      await cancelAck;

      expect(result.cancelled, isTrue);
      expect(result.rows, hasLength(sessionCount));

      final cached = await controller.loadCachedRows();
      expect(cached.rows, hasLength(sessionCount));

      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      expect(
        db.select('''
            select count(*) as count
            from sessions
            where scan_status != 'available'
            ''').single['count'],
        0,
      );
      final scanRunStatuses = db
          .select('select status from scan_runs order by id')
          .map((row) => row['status'])
          .toList(growable: false);
      expect(scanRunStatuses.first, 'succeeded');
      expect(scanRunStatuses.last, 'cancelled');
    },
    // This native fixture creates 120 files and completes two scans. Full-suite
    // runs can exceed the runner's 30-second default before all state checks.
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('background cancellable refresh acknowledges cancellation', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_background_cancel_scan_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    for (var i = 0; i < 200; i++) {
      await _writeJsonFixture(windowsRoot, 'background-cancel-$i');
    }

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
    final operation = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
      writerCoordinator: coordinator,
      scanBatchingPolicy: const ScanBatchingPolicy(
        parsedSessionFlushBatchSize: 1,
        fullRowSnapshotBatchSize: 1,
      ),
    ).startRefreshInBackgroundOperation();
    final cancelAck = operation.cancel();
    final result = await operation.result;
    await cancelAck;
    await coordinator.idle.timeout(const Duration(seconds: 3));

    expect(result.cancelled, isTrue);
    expect(result.statusMessage, contains('cancelled'));
    final cached = await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).loadCachedRows();
    expect(cached.rows.length, result.rows.length);
  });

  test('auto project assignment keeps manual overrides on rescan', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_auto_project_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    await _copyFixture('sample_windows_session.json', windowsRoot);

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    );
    final first = await controller.refresh();
    expect(first.rows.single.project, 'codex-sessions-viewer');

    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    db.execute(
      '''
      insert into projects (name, created_at_utc, updated_at_utc)
      values (?, ?, ?)
      ''',
      [
        'Manual Project',
        DateTime.now().toUtc().toIso8601String(),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    final manualId = db.lastInsertRowId;
    db.execute(
      '''
      update sessions
      set project_id = ?,
          project_name_snapshot = ?,
          project_override = 1
      where id = ?
      ''',
      [manualId, 'Manual Project', first.rows.single.id],
    );

    final second = await controller.refresh();
    expect(second.rows.single.project, 'Manual Project');
    expect(
      db
          .select(
            '''
        select detected.name
        from sessions s join projects detected on detected.id = s.detected_project_id
        where s.id = ?
      ''',
            [first.rows.single.id],
          )
          .map((row) => row['name']),
      ['codex-sessions-viewer'],
      reason: 'A manual override must not erase persisted project discovery.',
    );
  });

  for (final operation in ['rescan', 'unchanged rescan']) {
    test(
      'runtime discovery preserves masked and manual projects during $operation',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'csv_runtime_project_precedence_',
        );
        addTearDown(() => deleteCollectorFixture(temp));
        final windowsRoot = await Directory(
          p.join(temp.path, 'windows'),
        ).create();
        final wslRoot = await Directory(p.join(temp.path, 'wsl')).create();
        final fixture = await _copyFixture(
          'sample_windows_session.json',
          windowsRoot,
        );
        final settingsFile = File(p.join(temp.path, 'settings.toml'));
        await SettingsRepository(settingsFile).save(
          AppSettings.defaults().copyWith(
            paths: PathSettings(
              windowsCodexPath: windowsRoot.path,
              wslCodexUncPath: wslRoot.path,
            ),
            logging: _testLogging(temp),
          ),
        );
        final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
        final startup = await _migrateCollectorFixture(databaseFile);
        expect(startup.canStartNormalUi, isTrue);
        final controller = RuntimeSessionController(
          settingsFile: settingsFile,
          databaseFile: databaseFile,
        );
        final initial = await controller.refresh();
        final sessionId = initial.rows.single.id;
        final db = openFileBackedDatabase(databaseFile);
        addTearDown(db.close);
        final store = ProjectTagStateStore(db);
        final maskedId = store.upsertProject(name: 'Masked Project');
        final maskId = store.upsertProjectMask(
          projectId: maskedId,
          pathMask: '*codex-sessions-viewer*',
        );
        store.recalculateSessionProjects();
        final rulesVersion = db
            .select('select project_rules_version from database_state')
            .single
            .values
            .single;
        db.execute(
          'update sessions set detected_project_id = null where id = ?',
          [sessionId],
        );
        if (operation == 'rescan') {
          // Changing file size forces the real parse/write path on the next scan.
          await fixture.writeAsString('${await fixture.readAsString()}\n ');
        }
        final refreshed = await controller.refresh();
        expect(refreshed.rows.single.project, 'Masked Project');
        expect(
          db.select(
            'select detected.name from sessions s join projects detected on detected.id = s.detected_project_id where s.id = ?',
            [sessionId],
          ).single['name'],
          'codex-sessions-viewer',
        );
        expect(
          db
              .select('select project_name from session_search')
              .single['project_name'],
          'Masked Project',
        );
        expect(
          db
              .select('select project_rules_version from database_state')
              .single
              .values
              .single,
          rulesVersion,
        );

        db.execute('delete from project_path_masks where id = ?', [maskId]);
        store.recalculateSessionProjects();
        expect(
          (await controller.loadCachedRows()).rows.single.project,
          'codex-sessions-viewer',
        );
        final manualId = store.upsertProject(name: 'Manual Project');
        store.setSessionProject(sessionId, manualId);
        db.execute(
          'update sessions set detected_project_id = null where id = ?',
          [sessionId],
        );
        final cached = await controller.refresh();
        expect(cached.rows.single.project, 'Manual Project');
        expect(
          db.select('select detected_project_id from sessions where id = ?', [
            sessionId,
          ]).single['detected_project_id'],
          isNotNull,
        );
        expect(
          db
              .select('select project_name from session_search')
              .single['project_name'],
          'Manual Project',
        );
      },
    );
  }

  test('project mask changes remap usage contexts', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_usage_project_remap_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        pricing: _testPricing(),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final db = openFileBackedDatabase(databaseFile);
    addTearDown(() {
      try {
        db.close();
      } on StateError {
        // The setup handle is closed before the controller opens the database.
      }
    });
    final now = DateTime.utc(2026, 6, 12, 12).toIso8601String();
    for (final name in ['Old Auto', 'Masked', 'Manual']) {
      db.execute(
        '''
        insert into projects (name, is_active, created_at_utc, updated_at_utc)
        values (?, 1, ?, ?)
        ''',
        [name, now, now],
      );
    }
    int projectId(String name) =>
        db.select('select id from projects where name = ?', [name]).single['id']
            as int;
    final oldAutoId = projectId('Old Auto');
    final maskedId = projectId('Masked');
    final manualId = projectId('Manual');
    for (final session in [
      (id: 'automatic', projectId: oldAutoId, name: 'Old Auto', manual: 0),
      (id: 'manual', projectId: manualId, name: 'Manual', manual: 1),
    ]) {
      db.execute(
        '''
        insert into sessions (
          id, source_type, source_file_path, display_path, platform_path,
          parse_status, scan_status, started_at_utc, last_message_at_utc,
          title, message_count, model_primary, project_id,
          project_name_snapshot, project_override, working_directory_display,
          parser_version, usage_projection_status, created_at_utc,
          updated_at_utc
        ) values (?, 'windows', ?, ?, ?, 'available', 'available', ?, ?, ?,
          1, 'gpt-5.5-thinking', ?, ?, ?, ?, ?, 'complete', ?, ?)
        ''',
        [
          session.id,
          '${session.id}.jsonl',
          '${session.id}.jsonl',
          '${session.id}.jsonl',
          now,
          now,
          session.id,
          session.projectId,
          session.name,
          session.manual,
          r'C:\work\client\repo',
          collectorCodexParserVersion,
          now,
          now,
        ],
      );
      final rowid = db.select('select rowid from sessions where id = ?', [
        session.id,
      ]).single['rowid'];
      db.execute(
        '''
        insert into session_search (
          rowid, project_name
        ) values (?, ?)
        ''',
        [rowid, session.name],
      );
      db.execute(
        '''
        insert into usage_events (
          session_row_id, source_record_ordinal, epoch, occurred_at_utc,
          model, working_directory_display, project_id, input_tokens,
          cached_input_tokens, cache_write_input_tokens, output_tokens,
          reasoning_output_tokens, total_tokens, branch_scope, derivation,
          event_fingerprint
        ) values (?, 1, 0, ?, 'gpt-5.5-thinking', ?, ?, 10, 0, 0, 5, 0,
          15, 'local', 'last_token_usage', ?)
        ''',
        [
          session.id,
          now,
          r'C:\work\client\repo',
          oldAutoId,
          session.id.substring(0, 1) * 64,
        ],
      );
    }
    for (var ordinal = 2; ordinal <= 520; ordinal++) {
      db.execute(
        '''
        insert into usage_events (
          session_row_id, source_record_ordinal, epoch, occurred_at_utc,
          model, working_directory_display, project_id, input_tokens,
          cached_input_tokens, cache_write_input_tokens, output_tokens,
          reasoning_output_tokens, total_tokens, branch_scope, derivation,
          event_fingerprint
        ) values ('automatic', ?, 0, ?, 'gpt-5.5-thinking', ?, ?, 1, 0, 0,
          0, 0, 1, 'local', 'last_token_usage', ?)
        ''',
        [
          ordinal,
          now,
          r'C:\work\client\repo',
          oldAutoId,
          ordinal.toRadixString(16).padLeft(64, '0'),
        ],
      );
    }
    db.execute(
      '''
      insert into usage_daily (
        day_utc, model, project_id, source_type, is_archived, total_tokens
      ) values ('2026-06-12', 'gpt-5.5-thinking', ?, 'windows', 0, 999)
      ''',
      [oldAutoId],
    );
    final generations = DatabaseGenerationRepository(db);
    final generation = generations.createBuilding(
      sourceSchemaVersion: 15,
      targetSchemaVersion: 16,
      sourceFingerprint: 'fixture',
    );
    final jobs = MaintenanceJobRepository(db);
    final job = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'copy_events',
      databaseGenerationId: generation.id,
    );
    final lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 1),
    )!;
    final migration = UsagePathContextMigration(db);
    while (migration.copyNextBatch(jobs: jobs, lease: lease) != 0) {}
    while (migration.resolveNextContextBatch(jobs: jobs, lease: lease) != 0) {}
    generations.markReady(
      generation.id,
      validationReportJson: jsonEncode(migration.validateShadowParity()),
    );
    generations.activate(generation.id);
    jobs.markSucceeded(
      lease,
      phase: 'complete',
      statusMessage: 'Fixture migrated.',
    );
    final eventsBefore = db
        .select(
          'select * from usage_events order by session_row_id, source_record_ordinal',
        )
        .map((row) => Map<String, Object?>.from(row))
        .toList();
    for (final table in [
      'usage_events',
      'usage_daily',
      'usage_session_daily',
    ]) {
      for (final operation in ['insert', 'update', 'delete']) {
        db.execute('''
          create trigger reject_${table}_$operation before $operation on $table
          begin select raise(abort, 'project remap must not rewrite usage'); end
        ''');
      }
    }
    db.close();

    await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).upsertProjectMaskAndRecalculate(
      projectId: maskedId,
      pathMask: 'c:/work/client/*',
      priority: 1,
    );

    final remapped = openFileBackedDatabase(databaseFile);
    addTearDown(remapped.close);
    expect(
      remapped
          .select(
            'select distinct effective_project_id as project_id from usage_path_contexts where id <> 1 order by project_id',
          )
          .map((row) => row['project_id'])
          .toList(),
      [maskedId],
    );
    expect(
      remapped
          .select(
            'select * from usage_events order by session_row_id, source_record_ordinal',
          )
          .map((row) => Map<String, Object?>.from(row))
          .toList(),
      eventsBefore,
    );
    expect(
      remapped
          .select('select id, project_id from sessions order by id')
          .map((row) => (row['id'], row['project_id']))
          .toList(),
      [('automatic', maskedId), ('manual', manualId)],
    );
    expect(
      remapped
          .select('''
            select s.id, ss.project_name
            from sessions s join session_search ss on ss.rowid = s.rowid
            order by s.id
            ''')
          .map((row) => (row['id'], row['project_name']))
          .toList(),
      [('automatic', 'Masked'), ('manual', 'Manual')],
    );
    expect(
      remapped
          .select('''
            select project_id, total_tokens, estimated_cost_text
            from usage_daily
            order by project_id
            ''')
          .map(
            (row) => (
              row['project_id'],
              row['total_tokens'],
              row['estimated_cost_text'],
            ),
          )
          .toList(),
      [(oldAutoId, 999, null)],
    );

    final dailyBeforeFailure = remapped
        .select('select * from usage_daily order by project_id')
        .map((row) => Map<String, Object?>.from(row))
        .toList(growable: false);
    remapped.execute('''
      create trigger reject_context_remap
      before update on usage_path_contexts
      begin
        select raise(abort, 'rejected context remap');
      end
      ''');
    await expectLater(
      RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      ).upsertProjectMaskAndRecalculate(
        projectId: oldAutoId,
        pathMask: 'c:/work/client/*',
        priority: 0,
      ),
      throwsA(isA<Object>()),
    );
    expect(
      remapped
          .select(
            'select project_id from project_path_masks order by project_id',
          )
          .map((row) => row['project_id'])
          .toList(),
      [maskedId],
    );
    expect(
      remapped
          .select(
            'select distinct effective_project_id as project_id from usage_path_contexts where id <> 1',
          )
          .single['project_id'],
      maskedId,
    );
    expect(
      remapped
          .select('select * from usage_daily order by project_id')
          .map((row) => Map<String, Object?>.from(row))
          .toList(growable: false),
      dailyBeforeFailure,
    );
    remapped.execute('drop trigger reject_context_remap');
  });

  test(
    'runtime falls back to aggregate token counts for JSONL message rows',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_aggregate_tokens_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await deleteCollectorFixture(temp);
        }
      });

      final windowsRoot = Directory(p.join(temp.path, 'windows'));
      final wslRoot = Directory(p.join(temp.path, 'wsl'));
      await windowsRoot.create();
      await wslRoot.create();
      await _writeAggregateJsonlFixture(windowsRoot);

      final settingsFile = File(p.join(temp.path, 'settings.toml'));
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: windowsRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          pricing: _testPricing(),
          logging: _testLogging(temp),
        ),
      );
      final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
      final startup = await _migrateCollectorFixture(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final result = await RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      ).refresh();

      final row = result.rows.single;
      expect(row.userMessageTokens, 42);
      expect(row.assistantResponseTokens, 21);
      expect(row.toolCallTokens, 0);
      expect(row.totalTokens, 63);
      expect(row.estimatedCostDisplay, 'Pricing update in progress');
      _repriceFixture(databaseFile, _testPricing());
      final repriced = await RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      ).loadSessionDetail(row.id);
      expect(repriced?.estimatedCostDisplay, '\$0.0805');

      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      final stored = db
          .select(
            '''
            select user_message_tokens,
                   assistant_response_tokens,
                   tool_call_tokens
            from sessions
            where id = ?
            ''',
            [row.id],
          )
          .single;
      expect(stored['user_message_tokens'], 42);
      expect(stored['assistant_response_tokens'], 21);
      expect(stored['tool_call_tokens'], 0);
    },
  );

  test('loads newest conversation page before older message bodies', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_tail_page_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    await _writePagedJsonFixture(windowsRoot, messageCount: 60);

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        pricing: _testPricing(),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    );
    final result = await controller.refresh();
    final detail = await controller.loadSessionDetail(result.rows.single.id);

    final messages = detail!.conversationMessages;
    expect(messages, hasLength(60));
    expect(messages.first.number, 0);
    expect(messages.first.isBodyLoaded, isFalse);
    expect(messages.first.body, isEmpty);
    expect(messages[10].number, 10);
    expect(messages[10].isBodyLoaded, isTrue);
    expect(messages[10].body, 'Message 11 body');
    expect(messages.last.number, 59);
    expect(messages.last.isBodyLoaded, isTrue);
    expect(messages.last.body, 'Message 60 body');
  });

  test('loads message index metadata without content_plain', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_message_index_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    await _writePagedJsonFixture(windowsRoot, messageCount: 60);

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        pricing: _testPricing(),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    );
    final result = await controller.refresh();
    final detail = await controller.loadSessionDetail(result.rows.single.id);

    final first = detail!.conversationMessages.first;
    expect(first.number, 0);
    expect(first.preview, 'Message 1 body');
    expect(first.tokenCount, 1);
    expect(first.isBodyLoaded, isFalse);
    expect(first.body, isEmpty);
  });

  test('loads message page around requested anchor', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_message_page_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    await _writePagedJsonFixture(windowsRoot, messageCount: 60);

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        pricing: _testPricing(),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    );
    final result = await controller.refresh();
    final page = await controller.loadMessagePage(result.rows.single.id, 0);

    expect(page.first.number, 0);
    expect(page.first.body, 'Message 1 body');
    expect(page.first.isBodyLoaded, isTrue);
  });

  test('paged detail load avoids full body materialization', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_paged_materialization_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await deleteCollectorFixture(temp);
      }
    });

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    await _writePagedJsonFixture(windowsRoot, messageCount: 60);

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: windowsRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
        pricing: _testPricing(),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await _migrateCollectorFixture(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    );
    final result = await controller.refresh();
    final detail = await controller.loadSessionDetail(result.rows.single.id);

    final messages = detail!.conversationMessages;
    expect(messages, hasLength(60));
    expect(messages.where((message) => message.isBodyLoaded), hasLength(50));
    expect(messages.take(10).every((message) => message.body.isEmpty), isTrue);
    expect(
      messages.skip(10).every((message) => message.body.isNotEmpty),
      isTrue,
    );
  });

  testWidgets(
    'production empty-state actions open settings and retry path test',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var refreshCalls = 0;
      var openSettingsCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SessionsScreen(
            onRefreshWithProgress: (_) async {
              refreshCalls++;
              return const SessionsRefreshResult(
                rows: [],
                statusMessage:
                    r'Scan finished. Session root is unreachable. Unreachable paths: \\wsl.localhost\Ubuntu\home\pawel\.codex',
              );
            },
            onOpenSettings: () {
              openSettingsCalls++;
            },
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('Refresh'));
      await _pumpFrames(tester);
      expect(refreshCalls, 1);

      await tester.tap(find.text('Retry scan'));
      await _pumpFrames(tester);
      expect(refreshCalls, 2);

      await tester.tap(find.text('Open Settings'));
      await _pumpFrames(tester);
      expect(openSettingsCalls, 1);
    },
  );
}

class _ScanPricingCatalog implements OpenRouterModelsClient {
  @override
  Future<OpenRouterModelsResponse> fetchModels(
    OpenRouterModelsRequest request,
  ) async => OpenRouterModelsResponse.fromJsonText(
    '{"data":[{"id":"openai/gpt-5","pricing":{"prompt":"0.000001","completion":"0.000002"}}]}',
  );
}

Future<DatabaseMaintenanceWorkerOutcome> _copyMigrationProbeRows(
  DatabaseMaintenanceWorkerContext context,
) async {
  while (true) {
    if (context.stopRequested) {
      return DatabaseMaintenanceWorkerOutcome.interrupted;
    }
    final job = context.jobs.read(context.lease.jobId)!;
    final rows = context.database.select(
      '''
      select rowid, value
      from migration_source
      where rowid > ?
      order by rowid
      limit 2
      ''',
      [job.lastProcessedRowId],
    );
    if (rows.isEmpty) {
      return DatabaseMaintenanceWorkerOutcome.succeeded;
    }
    final lastRowId = rows.last['rowid'] as int;
    final completed = job.completedUnits + rows.length;
    context.commitBatch(
      phase: 'copy_probe',
      currentWork: 'Copied $completed of ${job.totalUnits} migration rows.',
      unitLabel: 'rows',
      completedUnits: completed,
      totalUnits: job.totalUnits,
      lastProcessedRowId: lastRowId,
      apply: (transaction) {
        final insert = transaction.prepare('''
          insert into migration_destination (source_rowid, value)
          values (?, ?)
          ''');
        try {
          for (final row in rows) {
            insert.execute([row['rowid'], row['value']]);
          }
        } finally {
          insert.close();
        }
      },
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 5}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<File> _copyFixture(String name, Directory destination) async {
  final source = File(p.normalize(p.join('..', 'samples', 'sessions', name)));
  return source.copy(p.join(destination.path, name));
}

Future<File> _writeJsonFixture(Directory destination, String id) async {
  final file = File(p.join(destination.path, '$id.json'));
  await file.writeAsString('''
{
  "session_id": "$id",
  "source_type": "windows",
  "messages": [
    { "type": "user", "content": "hello $id" }
  ]
}
''');
  return file;
}

Future<File> _writeIdentityFixture(
  Directory destination, {
  required String fileName,
  required String sessionId,
  required List<(String, String, String)> messages,
}) async {
  final file = File(p.join(destination.path, fileName));
  final encodedMessages = messages
      .map(
        (message) =>
            '{"type":${jsonEncode(message.$1)},'
            '"created_at":${jsonEncode(message.$2)},'
            '"content":${jsonEncode(message.$3)}}',
      )
      .join(',');
  await file.writeAsString(
    '{"session_id":${jsonEncode(sessionId)},'
    '"source_type":"windows","messages":[$encodedMessages]}',
  );
  return file;
}

Future<File> _writeMessageSearchFixture(
  Directory destination, {
  required String userContent,
  required String assistantContent,
}) async {
  final file = File(p.join(destination.path, 'message-search.json'));
  await file.writeAsString('''
{
  "session_id": "message-search",
  "source_type": "windows",
  "working_directory": "F:\\\\projects\\\\MaxLogic\\\\codex-sessions-viewer",
  "title": "Message search fixture",
  "created_at": "2026-07-07T09:00:00Z",
  "messages": [
    {
      "type": "user",
      "created_at": "2026-07-07T09:01:00Z",
      "content": "$userContent"
    },
    {
      "type": "assistant",
      "created_at": "2026-07-07T09:02:00Z",
      "content": "$assistantContent"
    }
  ]
}
''');
  return file;
}

Future<File> _writeAggregateJsonlFixture(Directory destination) async {
  final file = File(p.join(destination.path, 'aggregate_usage.jsonl'));
  await file.writeAsString(
    [
      '{"timestamp":"2026-06-10T10:00:00.000Z","type":"session_meta","payload":{"id":"aggregate-jsonl-001","timestamp":"2026-06-10T10:00:00.000Z","cwd":"F:\\\\projects\\\\MaxLogic\\\\codex-sessions-viewer"}}',
      '{"timestamp":"2026-06-10T10:00:01.000Z","type":"turn_context","payload":{"cwd":"F:\\\\projects\\\\MaxLogic\\\\codex-sessions-viewer","model":"gpt-5.5-thinking"}}',
      '{"timestamp":"2026-06-10T10:00:02.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Aggregate-only request"}]}}',
      '{"timestamp":"2026-06-10T10:00:03.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Aggregate-only response"}]}}',
      '{"timestamp":"2026-06-10T10:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":42,"output_tokens":21,"cached_input_tokens":7}}}}',
    ].join('\n'),
  );
  return file;
}

Future<File> _writeAggregateOnlyJsonFixture(Directory destination) async {
  final file = File(p.join(destination.path, 'aggregate-only-parent.json'));
  await file.writeAsString('''
{
  "session_id": "aggregate-only-parent",
  "source_type": "windows",
  "working_directory": "F:\\\\projects\\\\MaxLogic\\\\codex-sessions-viewer",
  "usage": {
    "input_tokens": 10,
    "output_tokens": 5
  },
  "messages": []
}
''');
  return file;
}

Future<File> _writeLegacyForkUsageFixture(
  Directory destination, {
  required bool child,
  bool zeroPostFork = false,
}) async {
  final id = child
      ? zeroPostFork
            ? 'legacy-zero-child'
            : 'legacy-child'
      : 'legacy-parent';
  final file = File(p.join(destination.path, '$id.jsonl'));
  final metadata = <String, Object?>{
    'id': id,
    'timestamp': '2026-06-11T10:00:00.000Z',
    'cwd': r'F:\projects\MaxLogic\codex-sessions-viewer',
    if (child) 'forked_from_id': 'legacy-parent',
  };
  final lines = <Map<String, Object?>>[
    {
      'timestamp': '2026-06-11T10:00:00.000Z',
      'type': 'session_meta',
      'payload': metadata,
    },
    {
      'timestamp': '2026-06-11T10:00:00.500Z',
      'type': 'turn_context',
      'payload': {
        'cwd': r'F:\projects\MaxLogic\codex-sessions-viewer',
        'model': 'gpt-5.6-sol',
      },
    },
    _usageFixtureRecord(
      timestamp: '2026-06-11T10:00:01.000Z',
      input: 10,
      output: 5,
      lastInput: 10,
      lastOutput: 5,
    ),
    _usageFixtureRecord(
      timestamp: '2026-06-11T10:00:02.000Z',
      input: 20,
      output: 10,
      lastInput: 10,
      lastOutput: 5,
    ),
    if (!zeroPostFork)
      _usageFixtureRecord(
        timestamp: child
            ? '2026-06-11T10:00:03.000Z'
            : '2026-06-11T10:00:04.000Z',
        input: child ? 27 : 30,
        output: child ? 13 : 15,
        lastInput: child ? 7 : 10,
        lastOutput: child ? 3 : 5,
      ),
  ];
  await file.writeAsString(lines.map(jsonEncode).join('\n'));
  return file;
}

Future<File> _writeLegacyGrandchildUsageFixture(Directory destination) async {
  final file = File(p.join(destination.path, 'legacy-grandchild.jsonl'));
  final lines = <Map<String, Object?>>[
    {
      'timestamp': '2026-06-11T10:00:00.000Z',
      'type': 'session_meta',
      'payload': {
        'id': 'legacy-grandchild',
        'forked_from_id': 'legacy-child',
        'cwd': r'F:\projects\MaxLogic\codex-sessions-viewer',
      },
    },
    {
      'timestamp': '2026-06-11T10:00:00.500Z',
      'type': 'turn_context',
      'payload': {
        'cwd': r'F:\projects\MaxLogic\codex-sessions-viewer',
        'model': 'gpt-5.6-sol',
      },
    },
    _usageFixtureRecord(
      timestamp: '2026-06-11T10:00:01.000Z',
      input: 10,
      output: 5,
      lastInput: 10,
      lastOutput: 5,
    ),
    _usageFixtureRecord(
      timestamp: '2026-06-11T10:00:02.000Z',
      input: 20,
      output: 10,
      lastInput: 10,
      lastOutput: 5,
    ),
    _usageFixtureRecord(
      timestamp: '2026-06-11T10:00:03.000Z',
      input: 27,
      output: 13,
      lastInput: 7,
      lastOutput: 3,
    ),
    _usageFixtureRecord(
      timestamp: '2026-06-11T10:00:05.000Z',
      input: 31,
      output: 15,
      lastInput: 4,
      lastOutput: 2,
    ),
  ];
  await file.writeAsString(lines.map(jsonEncode).join('\n'));
  return file;
}

Future<File> _writeSelfCycleUsageFixture(
  Directory destination, {
  bool withUsage = true,
}) async {
  final id = withUsage ? 'self-cycle' : 'self-cycle-zero';
  final file = File(p.join(destination.path, '$id.jsonl'));
  final lines = <Map<String, Object?>>[
    {
      'timestamp': '2026-06-12T10:00:00.000Z',
      'type': 'session_meta',
      'payload': {
        'id': id,
        'forked_from_id': id,
        'cwd': r'F:\projects\MaxLogic\codex-sessions-viewer',
      },
    },
    if (withUsage)
      _usageFixtureRecord(
        timestamp: '2026-06-12T10:00:01.000Z',
        input: 2,
        output: 1,
        lastInput: 2,
        lastOutput: 1,
      ),
  ];
  await file.writeAsString(lines.map(jsonEncode).join('\n'));
  return file;
}

Map<String, Object?> _usageFixtureRecord({
  required String timestamp,
  required int input,
  required int output,
  required int lastInput,
  required int lastOutput,
}) => {
  'timestamp': timestamp,
  'type': 'event_msg',
  'payload': {
    'type': 'token_count',
    'info': {
      'total_token_usage': {'input_tokens': input, 'output_tokens': output},
      'last_token_usage': {
        'input_tokens': lastInput,
        'output_tokens': lastOutput,
      },
    },
  },
};

Future<File> _writeGrowingJsonlFixture(
  Directory destination, {
  required int messageCount,
}) async {
  final file = File(p.join(destination.path, 'growing.jsonl'));
  final lines = <String>[
    '{"timestamp":"2026-06-10T10:00:00.000Z","type":"session_meta","payload":{"id":"growing-jsonl-session","timestamp":"2026-06-10T10:00:00.000Z","cwd":"F:\\\\repo","title":"Growing JSONL"}}',
    for (var i = 0; i < messageCount; i++)
      '{"timestamp":"2026-06-10T10:00:0${i + 1}.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"message $i"}]}}',
  ];
  await file.writeAsString('${lines.join('\n')}\n');
  return file;
}

Future<File> _writePagedJsonFixture(
  Directory destination, {
  required int messageCount,
}) async {
  final file = File(p.join(destination.path, 'paged-detail.json'));
  final messages = [
    for (var i = 1; i <= messageCount; i++)
      '''
    {
      "type": "assistant",
      "id": "m$i",
      "created_at": "2026-06-10T10:${(i % 60).toString().padLeft(2, '0')}:00Z",
      "content": "Message $i body",
      "usage": {
        "input_tokens": 0,
        "output_tokens": $i,
        "cached_input_tokens": 0
      }
    }''',
  ].join(',\n');
  await file.writeAsString('''
{
  "session_id": "paged-detail-001",
  "source_type": "windows",
  "source_file_path": "C:\\\\Users\\\\pawel\\\\.codex\\\\sessions\\\\paged-detail.json",
  "display_path": "C:\\\\Users\\\\pawel\\\\.codex\\\\sessions\\\\paged-detail.json",
  "platform_path": "C:\\\\Users\\\\pawel\\\\.codex\\\\sessions\\\\paged-detail.json",
  "working_directory": "F:\\\\projects\\\\MaxLogic\\\\codex-sessions-viewer",
  "title": "Paged detail fixture",
  "model": "gpt-5.5-thinking",
  "created_at": "2026-06-10T10:00:00Z",
  "messages": [
$messages
  ]
}
''');
  return file;
}

Future<File> _writeWslJsonFixture(
  Directory destination,
  String id,
  String workingDirectory, {
  String? workingDirectoryUnc,
}) async {
  final file = File(p.join(destination.path, '$id.json'));
  await file.writeAsString('''
{
  "session_id": "$id",
  "source_type": "wsl",
  "source_file_path": "\\\\\\\\wsl.localhost\\\\Ubuntu\\\\home\\\\pawel\\\\.codex\\\\sessions\\\\$id.json",
  "source_file_unc_path": "\\\\\\\\wsl.localhost\\\\Ubuntu\\\\home\\\\pawel\\\\.codex\\\\sessions\\\\$id.json",
  "display_path": "/home/pawel/.codex/sessions/$id.json",
  "platform_path": "/home/pawel/.codex/sessions/$id.json",
  "working_directory": "$workingDirectory",
  ${workingDirectoryUnc == null ? '' : '"working_directory_unc": "${_escapedJsonString(workingDirectoryUnc)}",'}
  "created_at": "2026-06-10T09:00:00Z",
  "messages": [
    { "type": "user", "content": "hello $id" }
  ]
}
''');
  return file;
}

String _escapedJsonString(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

Future<File> _prepareBackfillDatabase(
  Directory temp, {
  required int count,
}) async {
  final file = File(p.join(temp.path, 'viewer.sqlite'));
  final startup = await _migrateCollectorFixture(file);
  expect(startup.canStartNormalUi, isTrue);
  final db = openFileBackedDatabase(file);
  try {
    _insertBackfillSession(db);
    for (var index = 0; index < count; index++) {
      _insertBackfillMessage(db, index);
    }
    db.execute(
      "insert into message_search(message_search) values('delete-all')",
    );
    db.execute(
      "update app_metadata set value='0' where key='message_search.backfill.last_message_rowid'",
    );
    db.execute(
      "update app_metadata set value=(select cast(max(id) as text) from messages) where key='message_search.backfill.target_message_rowid'",
    );
  } finally {
    db.close();
  }
  return file;
}

void _insertBackfillSession(Database db) {
  db.execute('''
    insert into sessions (
      id,
      source_type,
      source_file_path,
      display_path,
      platform_path,
      title,
      scan_status,
      parse_status,
      created_at_utc,
      updated_at_utc
    ) values (
      'backfill-session',
      'windows',
      'backfill.jsonl',
      'backfill.jsonl',
      'backfill.jsonl',
      'Backfill session',
      'available',
      'available',
      '2026-07-08T10:00:00.000Z',
      '2026-07-08T10:00:00.000Z'
    )
    ''');
}

void _insertBackfillMessage(Database db, int index) {
  final content = 'background backfill needle $index';
  db.execute(
    '''
    insert into messages (
      session_id,
      message_index,
      author_type,
      created_at_utc,
      first_line,
      content_plain,
      content_preview,
      created_at_db_utc,
      updated_at_db_utc
    ) values (
      'backfill-session',
      ?,
      'user',
      '2026-07-08T10:00:00.000Z',
      ?,
      ?,
      ?,
      '2026-07-08T10:00:00.000Z',
      '2026-07-08T10:00:00.000Z'
    )
    ''',
    [index, content, content, content],
  );
}

Future<void> _deleteTempDirWithRetry(Directory directory) async {
  for (var attempt = 0; attempt < 5; attempt++) {
    try {
      await deleteCollectorFixture(directory);
      return;
    } on FileSystemException {
      if (attempt == 4) {
        rethrow;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

class _RecordingWslProjectResolver implements WslProjectResolver {
  _RecordingWslProjectResolver(this.results);

  final Map<String, String> results;
  final calls = <Set<String>>[];

  @override
  Future<Map<String, String>> resolveProjectNames(
    Iterable<String> workingDirectories,
  ) async {
    final paths = workingDirectories.toSet();
    calls.add(paths);
    return {
      for (final path in paths)
        if ((results[path] ?? '').trim().isNotEmpty) path: results[path]!,
    };
  }
}

LoggingSettings _testLogging(Directory temp) => LoggingSettings(
  level: 'info',
  logFile: p.join(temp.path, 'logs', 'codex-session-viewer.log'),
  maxLogFiles: 2,
  maxLogSizeMb: 1,
);

PricingSettings _testPricing() => const PricingSettings(
  provider: 'openrouter',
  useExternalPricing: false,
  cachePricingHours: 24,
  fallbackToOverrides: true,
  openRouter: OpenRouterSettings(
    modelsEndpoint: 'https://openrouter.ai/api/v1/models',
    apiKey: '',
  ),
  overrides: {
    'gpt-5.5-thinking': PricingOverrideSettings(
      prompt: '0.001',
      completion: '0.002',
      inputCacheRead: '0.0005',
      inputCacheWrite: '0',
      internalReasoning: '0',
    ),
  },
);

SessionRowViewModel _row(String title, SessionRowPlatform platform) {
  return SessionRowViewModel(
    id: title,
    startedAtUtc: DateTime.utc(2026, 6, 14, 10),
    lastMessageAtUtc: DateTime.utc(2026, 6, 14, 11),
    platform: platform,
    project: 'Codex Viewer',
    path: r'C:\Users\pawel\.codex\sessions\runtime.jsonl',
    title: title,
    summary: 'Loaded from runtime scan',
    messageCount: 1,
    totalTokens: 42,
    model: 'gpt-5.4',
    tags: const [],
    status: 'available',
  );
}

SessionRowViewModel _resumableRow(String title) {
  return SessionRowViewModel(
    id: title,
    sessionId: title,
    startedAtUtc: DateTime.utc(2026, 6, 14, 10),
    lastMessageAtUtc: DateTime.utc(2026, 6, 14, 11),
    platform: SessionRowPlatform.windows,
    project: 'Codex Viewer',
    path: r'F:\projects\MaxLogic\codex-sessions-viewer',
    workingDirectory: r'F:\projects\MaxLogic\codex-sessions-viewer',
    title: title,
    summary: 'Resumable session',
    messageCount: 1,
    totalTokens: 42,
    model: 'gpt-5.4',
    tags: const [],
    status: 'available',
  );
}

// Use the production startup migration once, then isolate every scan fixture.
Future<DatabaseStartupResult> _migrateCollectorFixture(File target) async {
  await target.parent.create(recursive: true);
  await _collectorTemplate.copy(target.path);
  return DatabaseMigrator(sqlRoot: Directory('../sql')).openAndMigrate(target);
}

void _seedIdentityUsageContext(Database db) {
  db.execute(
    "insert or ignore into usage_path_contexts (id, display_path_raw, platform_path_raw, unc_path_raw, display_path_key, platform_path_key, unc_path_key, normalization_version, resolution_source, project_rules_version, created_at_utc, updated_at_utc) values (1, '', '', '', '', '', '', 1, 'unassigned', 0, '2026-09-24', '2026-09-24')",
  );
}

void _repriceFixture(File file, PricingSettings settings) {
  final db = openFileBackedDatabase(file, maintenanceWriter: true);
  try {
    // Fixture price evidence predates the June usage events.
    db.execute('delete from local_price_override_periods');
    PricingRepository(
      db,
    ).synchronizeSettings(settings, nowUtc: DateTime.utc(2026, 1, 1));
    final jobs = MaintenanceJobRepository(db);
    final job = jobs.enqueue(
      jobType: 'usage_cost_repricing',
      phase: 'reprice_costs',
    );
    final lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 5),
    )!;
    final costs = UsageCostProjectionRepository(db);
    while (costs.repriceNextBatch(
          jobs: jobs,
          lease: lease,
          settings: settings,
        ) !=
        0) {}
    jobs.markSucceeded(
      lease,
      phase: 'complete',
      statusMessage: 'Fixture repriced.',
    );
  } finally {
    db.close();
  }
}

Future<void> _copyTree(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final entity in from.list()) {
    final target = p.join(to.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyTree(entity, Directory(target));
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}
