import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/app/runtime_session_controller.dart';
import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/session_cache_repair.dart';
import 'package:codex_sessions_viewer/src/scanner/scan_batching.dart';
import 'package:codex_sessions_viewer/src/search/message_search.dart';
import 'package:codex_sessions_viewer/src/search/session_search.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/ui/screens/settings_screen.dart';
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
      expect(result.persistenceFlushCount, 1);

      final db = openFileBackedDatabase(databaseFile);
      addTearDown(db.close);
      expect(
        db.select('select count(*) as count from sessions').single['count'],
        2,
      );
      expect(
        db
            .select(
              'select count(*) as count from sessions where content_hash is not null',
            )
            .single['count'],
        0,
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
      expect(
        progressEvents.map((event) => event.statusMessage),
        contains(startsWith('Maintaining session cache:')),
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
    'runtime refresh status reports cached available sessions separately',
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
          parsedSessionFlushBatchSize: 99,
          parsedSessionFlushSourceBytes: 1,
          fullRowSnapshotBatchSize: 4,
        ),
      ).refreshInBackground(onProgress: progressEvents.add);

      expect(result.rows, hasLength(5));
      expect(result.persistenceFlushCount, 5);
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

  test('runtime persists active and archived source lifecycle separately', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_source_lifecycle_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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
          await temp.delete(recursive: true);
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
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
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
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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
    final statusFallbackId =
        'source-status:${p.normalize(sourceFile.path).toLowerCase()}';
    db.execute(
      '''
      insert into sessions (
        id, source_type, source_file_path, display_path, platform_path,
        project_id, project_name_snapshot, project_override,
        is_pinned, is_archived, archived_at_utc, archive_reason,
        eval_ready, eval_status, eval_notes, eval_expected_output,
        eval_reviewed_at_utc, eval_updated_at_utc,
        created_at_utc, updated_at_utc
      ) values (?, 'windows', ?, ?, ?, 2, 'Fallback Project', 1,
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
      ) values (?, 'windows', ?, ?, ?, 'parse_error', 'parse_error',
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
    expect(migrated.select('pragma foreign_key_check'), isEmpty);
  });

  test('rolls back identity reconciliation failure', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_fallback_rollback_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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
        ) values (?, ?, 'windows', ?, ?, ?,
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
    expect(rolledBack.select('pragma foreign_key_check'), isEmpty);
  });

  test('keeps case-distinct WSL fallback identities unresolved', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_wsl_identity_case_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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
  });

  test('release lifecycle certification preflight invariants', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_cache_repair_gate_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
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
    final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);
    final db = openFileBackedDatabase(databaseFile);
    db.execute(
      '''
      insert into sessions (
        id, source_type, source_file_path, display_path, platform_path,
        parser_version, created_at_utc, updated_at_utc
      ) values ('source:legacy-artifact', 'windows', ?, ?, ?, 1,
        '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z')
      ''',
      [legacyArtifact.path, legacyArtifact.path, legacyArtifact.path],
    );
    db.close();

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    );
    await controller.refresh();
    final afterFailedScan = openFileBackedDatabase(databaseFile);
    expect(
      afterFailedScan
          .select(
            "select count(*) as count from sessions where id = 'source:legacy-artifact'",
          )
          .single['count'],
      1,
    );
    expect(
      afterFailedScan
          .select(
            "select count(*) as count from app_metadata where key = '$sessionCacheRepairCompletionKey'",
          )
          .single['count'],
      0,
    );
    afterFailedScan.close();

    await malformed.writeAsString('''
      {
        "session_id": "repair-gate",
        "source_type": "windows",
        "messages": [{"type": "user", "content": "repaired"}]
      }
      ''');
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
    final backups = Directory(p.join(temp.path, 'backups'));
    expect(await backups.list().where((entity) => entity is File).length, 1);
  });

  test('runtime cache repair failure does not fail the scan', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_cache_repair_failure_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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

  test(
    'refresh applies session_index thread names to unchanged cached rows',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_session_index_',
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
        await temp.delete(recursive: true);
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
          await temp.delete(recursive: true);
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
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(dbFile);
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

  test('runtime refresh continues when the text log cannot open', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_scan_unavailable_log_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
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

  testWidgets(
    'settings save and reload update periodic rescans without restart',
    (tester) async {
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
          await temp.delete(recursive: true);
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

      await tester.tap(find.bySemanticsLabel('Settings navigation'));
      await _pumpFrames(tester);
      await tester.tap(
        find.bySemanticsLabel('Background scan enabled setting'),
      );
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

      await tester.tap(find.bySemanticsLabel('Sessions navigation'));
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
      expect(refreshCalls, 1);

      storedSettings = disabledSettings;
      await tester.tap(find.bySemanticsLabel('Settings navigation'));
      await _pumpFrames(tester);
      await tester.tap(find.text('Reload from file'));
      await _pumpFrames(tester);

      await tester.tap(find.bySemanticsLabel('Sessions navigation'));
      await tester.pump();
      final callsAfterReload = refreshCalls;
      await tester.pump(const Duration(milliseconds: 1001));
      expect(refreshCalls, callsAfterReload);
    },
  );

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

  test(
    'warm unchanged refresh does not rewrite skipped cached session rows',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_warm_skip_no_rewrite_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
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

  test(
    'runtime batches WSL project resolution for refresh and cached backfill',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_wsl_project_batch_',
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
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final resolver = _RecordingWslProjectResolver({
        sharedPath: 'shared-root',
      });
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
      final refreshed = await controller.refresh(
        onProgress: progressEvents.add,
      );
      expect(refreshed.persistenceFlushCount, greaterThan(1));
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
      final cached = await controller.loadCachedRows();

      expect(cached.rows.map((row) => row.project).toSet(), {
        'cached-root',
        'unresolved',
      });
      expect(resolver.calls, [
        {sharedPath, unresolvedPath},
        {sharedPath, unresolvedPath},
      ]);
    },
  );

  test('resolved WSL paths expose containing-folder actions', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_wsl_openable_path_',
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    );
    final result = await controller.refresh();
    final wslRow = result.rows.singleWhere(
      (row) => row.platform == SessionRowPlatform.wsl,
    );

    expect(wslRow.path, '/home/pawel/project');
    expect(wslRow.openablePath, r'\\wsl.localhost\Ubuntu\home\pawel\project');
  });

  test(
    'runtime Windows containing-folder target prefers working directory',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_windows_openable_path_',
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
  );

  test(
    'unresolved WSL working directories do not fall back to session file UNC',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_runtime_wsl_unresolved_openable_path_',
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
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
      );
      final result = await controller.refresh();
      final wslRow = result.rows.singleWhere(
        (row) => row.platform == SessionRowPlatform.wsl,
      );

      expect(wslRow.path, '/mnt/f/projects/oec/te5/maxtdb');
      expect(wslRow.openablePath, isEmpty);
      expect(wslRow.canOpenContainingFolder, isFalse);
    },
  );

  test('runtime cancellable refresh preserves partial cached rows', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_cancel_scan_',
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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
    expect(result.rows.length, lessThan(5));

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
          await temp.delete(recursive: true);
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
      final startup = await DatabaseMigrator(
        sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
      ).openAndMigrate(databaseFile);
      expect(startup.canStartNormalUi, isTrue);

      final controller = RuntimeSessionController(
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
  );

  test('runtime cancellation is honored during cache maintenance', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_cancel_maintenance_',
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
    await _writeJsonFixture(windowsRoot, 'maintenance-cancel');
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
    late CancellableSessionScanOperation operation;
    var maintenanceReported = false;
    operation = controller.startRefreshOperation(
      onProgress: (progress) {
        if (progress.statusMessage ==
            'Maintaining session cache: auditing cached rows...') {
          maintenanceReported = true;
          unawaited(operation.cancel());
        }
      },
    );

    final result = await operation.result;

    expect(maintenanceReported, isTrue);
    expect(result.cancelled, isTrue);
    expect(result.statusMessage, contains('cancelled'));
    final db = openFileBackedDatabase(databaseFile);
    addTearDown(db.close);
    expect(
      db
          .select(
            "select count(*) as count from app_metadata where key = '$sessionCacheRepairCompletionKey'",
          )
          .single['count'],
      0,
    );
  });

  test('background cancellable refresh acknowledges cancellation', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_runtime_background_cancel_scan_',
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);

    final operation = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
      scanBatchingPolicy: const ScanBatchingPolicy(
        parsedSessionFlushBatchSize: 1,
        fullRowSnapshotBatchSize: 1,
      ),
    ).startRefreshInBackgroundOperation();
    final cancelAck = operation.cancel();
    final result = await operation.result;
    await cancelAck;

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
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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
        await temp.delete(recursive: true);
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
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
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
      await directory.delete(recursive: true);
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
