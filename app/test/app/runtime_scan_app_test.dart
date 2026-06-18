import 'dart:io';

import 'package:codex_sessions_viewer/src/app/runtime_session_controller.dart';
import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/scanner/scan_batching.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/utils/profiling.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'runtime scan loads settings, persists parsed sessions, and returns rows',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_runtime_scan_');
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
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
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
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

      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      expect(
        db.select('select count(*) as count from sessions').single['count'],
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
        progressEvents.last.statusMessage,
        contains('estimated progress 100%'),
      );
      final spanNames = {
        for (final event in profilingEvents)
          if (event.kind == ProfilingEventKind.start) event.name,
      };
      expect(spanNames, contains('scan.runtime.refresh'));
      expect(spanNames, contains('scan.runtime.load_rows'));
      expect(spanNames, contains('scan.runtime.persist_flush'));
      expect(spanNames, contains('scan.runtime.persist_scan'));
      expect(spanNames, contains('scan.runtime.resolve_wsl_project'));
    },
  );

  test('background runtime scan emits progress and returns rows', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_background_scan_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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
          await temp.delete(recursive: true);
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
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
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
  );

  test(
    'runtime refresh status reports cached visible sessions separately',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_cached_status_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
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
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      );
      final firstResult = await controller.refresh();
      final secondResult = await controller.refresh();

      expect(firstResult.rows, hasLength(1));
      expect(secondResult.rows, hasLength(1));
      expect(secondResult.statusMessage, contains('1 session visible'));
      expect(
        secondResult.statusMessage,
        contains('0 new or changed sessions parsed'),
      );
    },
  );

  test(
    'runtime refresh coalesces persistence flushes and row snapshots',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_scan_batching_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
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
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
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
      expect(result.persistenceFlushCount, 3);
      expect(result.fullRowSnapshotCount, 2);
      expect(
        progressEvents
            .where((event) => event.rows != null)
            .map((event) => event.rows!.length),
        [4, 5],
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
          await temp.delete(recursive: true);
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
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
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
    'background runtime refresh preserves injected batching policy',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_background_batching_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
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
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final progressEvents = <SessionsRefreshProgress>[];
      final result = await RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
        scanBatchingPolicy: const ScanBatchingPolicy(
          parsedSessionFlushBatchSize: 2,
          fullRowSnapshotBatchSize: 4,
        ),
      ).refreshInBackground(onProgress: progressEvents.add);

      expect(result.rows, hasLength(5));
      expect(result.persistenceFlushCount, 3);
      expect(result.fullRowSnapshotCount, 2);
      expect(
        progressEvents
            .where((event) => event.rows != null)
            .map((event) => event.rows!.length),
        [4, 5],
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
          await temp.delete(recursive: true);
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
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
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
        'select scan_status from sessions where source_file_path = ?',
        [fixture.path],
      ).single;
      expect(row['scan_status'], 'missing');
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
          await temp.delete(recursive: true);
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
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
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
    expect(find.text('Test WSL path'), findsOneWidget);
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
    expect(find.textContaining('Refresh failed'), findsOneWidget);
    expect(find.textContaining('Invalid settings.toml'), findsOneWidget);
  });

  test('runtime refresh does not show root errors as session rows', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_scan_empty_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final emptyRoot = Directory(p.join(temp.path, 'empty'));
    await emptyRoot.create();
    final missingRoot = p.join(temp.path, 'missing');
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: emptyRoot.path,
          wslCodexUncPath: missingRoot,
        ),
        logging: _testLogging(temp),
      ),
    );
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final result = await RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refresh();

    expect(result.rows, isEmpty);
    expect(result.statusMessage, contains('No supported files found'));
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
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(refreshCalls, 1);
    expect(find.text('Loaded from runtime scan'), findsOneWidget);
  });

  test('runtime loads cached sessions before refresh is clicked', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_cached_startup_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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

    expect(detail?.estimatedCostDisplay, '\$0.0575');
    expect(detail?.userMessageTokens, 12);
    expect(detail?.assistantResponseTokens, 31);
    expect(detail?.modelsUsedForDetail, ['gpt-5.5-thinking']);
  });

  test('cached loading backfills auto projects for older sessions', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_cached_auto_project_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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

    final cached = await controller.loadCachedRows();
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
  });

  test('auto project assignment keeps manual overrides on rescan', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_auto_project_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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
  });

  test(
    'runtime falls back to aggregate token counts for JSONL message rows',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_aggregate_tokens_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
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
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final result = await RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      ).refresh();

      final row = result.rows.single;
      expect(row.userMessageTokens, 42);
      expect(row.assistantResponseTokens, 21);
      expect(row.toolCallTokens, 0);
      expect(row.totalTokens, 70);
      expect(row.estimatedCostDisplay, '\$0.0875');
    },
  );

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

      await tester.tap(find.text('Test WSL path'));
      await _pumpFrames(tester);
      expect(refreshCalls, 2);

      await tester.tap(find.text('Open Settings'));
      await _pumpFrames(tester);
      expect(openSettingsCalls, 1);
    },
  );
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
