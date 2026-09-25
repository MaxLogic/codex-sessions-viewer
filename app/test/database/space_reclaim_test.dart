import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/application_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/collector_versions.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/disk_space_probe.dart';
import 'package:flutter_test/flutter_test.dart';

/// T-146: a Codex parser change reparses every session and frees the pages of
/// the rows it no longer stores; the viewer reclaims them once, afterwards.
void main() {
  late Directory temp;
  late File file;
  late Database db;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('csv_space_reclaim_');
    file = File('${temp.path}/viewer.sqlite');
    expect(
      (await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(file)).canStartNormalUi,
      isTrue,
    );
    db = openFileBackedDatabase(file);
  });

  tearDown(() async {
    db.close();
    await temp.delete(recursive: true);
  });

  int freePages() =>
      db.select('pragma freelist_count').single.values.single as int;

  String? marker() =>
      db
              .select(
                "select value from app_metadata where key = '$spaceReclaimMarkerKey'",
              )
              .firstOrNull?['value']
          as String?;

  List<String> reclaimJobs() => [
    for (final row in db.select(
      "select state from maintenance_jobs where job_type = 'database_reclaim_space' order by id",
    ))
      row['state'] as String,
  ];

  void freeSomePages() {
    db.execute('''
      create table reclaim_filler(id integer primary key, body text not null);
      with recursive n(x) as (values(1) union all select x+1 from n where x<2000)
        insert into reclaim_filler select x, printf('%.2000c', 'x') from n;
      drop table reclaim_filler;
    ''');
    expect(freePages(), greaterThan(500));
  }

  void addCodexSession(
    int parserVersion, {
    String id = 'reparse',
    String? machine,
  }) {
    db.execute(
      '''
      insert into sessions(id, harness, machine_id, source_type, source_file_path,
        display_path, platform_path, parser_version, created_at_utc, updated_at_utc)
      values(?, 'codex', ?, 'windows', ?, 'fixture', 'fixture', ?,
        '2026-09-24', '2026-09-24')
      ''',
      [id, machine, id, parserVersion],
    );
  }

  Future<ApplicationMaintenance> scheduler({
    DiskSpaceProbe diskSpace = const _AmpleDisk(),
    int minimumDatabaseBytes = 0,
  }) async {
    final maintenance = ApplicationMaintenance(
      databaseFile: file,
      coordinator: DatabaseMaintenanceCoordinator(file),
      diskSpace: diskSpace,
      reclaimMinimumDatabaseBytes: minimumDatabaseBytes,
    );
    addTearDown(() async {
      await maintenance.stop();
      maintenance.dispose();
    });
    await maintenance.configure(
      AppSettings.fromTomlMap({
        'pricing': {'use_external_pricing': false},
      }),
    );
    return maintenance;
  }

  test(
    'reclaims freed space once, after the Codex reparse completes',
    () async {
      freeSomePages();
      addCodexSession(collectorCodexParserVersion - 1);
      // Another machine's sessions arrive through the hub and are never
      // reparsed here.
      addCodexSession(1, id: 'hub-row', machine: 'another-machine');
      final maintenance = await scheduler();
      await maintenance.runDueJobs();
      expect(
        reclaimJobs(),
        isEmpty,
        reason: 'sessions still awaiting the new parser keep their old rows',
      );
      expect(marker(), isNull);
      expect(freePages(), greaterThan(500));

      db.execute(
        "update sessions set parser_version = ? where id = 'reparse'",
        [collectorCodexParserVersion],
      );
      // A fresh viewer run: the reparse finished during the previous one.
      final next = await scheduler();
      await next.runDueJobs();
      expect(reclaimJobs(), ['succeeded']);
      expect(freePages(), 0);
      expect(marker(), '$collectorCodexParserVersion');
      expect(next.spaceReclaimWarning, isNull);
      for (final index in [
        'message_search',
        'tool_output_search',
        'session_search',
      ]) {
        db.execute("insert into $index($index) values('integrity-check')");
      }

      freeSomePages();
      await (await scheduler()).runDueJobs();
      expect(reclaimJobs(), ['succeeded'], reason: 'once per parser version');
    },
  );

  test(
    'a complete scan with the new parser lets stale rows outside the roots stop blocking',
    () async {
      freeSomePages();
      // A row the collector never revisits, for example under a Codex home
      // that is no longer configured.
      addCodexSession(collectorCodexParserVersion - 1, id: 'outside-roots');
      final maintenance = await scheduler();
      await maintenance.runDueJobs();
      expect(reclaimJobs(), isEmpty);

      db.execute(
        'insert into app_metadata(key, value, updated_at_utc) values (?, ?, ?)',
        [
          completeCodexScanKey,
          '${collectorCodexParserVersion - 1}',
          '2026-09-25',
        ],
      );
      await (await scheduler()).runDueJobs();
      expect(
        reclaimJobs(),
        isEmpty,
        reason: 'a complete scan with an older parser proves nothing',
      );

      db.execute('update app_metadata set value = ? where key = ?', [
        '$collectorCodexParserVersion',
        completeCodexScanKey,
      ]);
      await (await scheduler()).runDueJobs();
      expect(reclaimJobs(), ['succeeded']);
      expect(marker(), '$collectorCodexParserVersion');
    },
  );

  test('a small database is recorded without compacting', () async {
    freeSomePages();
    final maintenance = await scheduler(minimumDatabaseBytes: 1 << 40);
    await maintenance.runDueJobs();
    expect(reclaimJobs(), isEmpty);
    expect(freePages(), greaterThan(500));
    expect(marker(), '$collectorCodexParserVersion');
  });

  test('without enough free disk space it warns and retries later', () async {
    freeSomePages();
    final maintenance = await scheduler(diskSpace: const _FullDisk());
    await maintenance.runDueJobs();
    expect(reclaimJobs(), isEmpty);
    expect(freePages(), greaterThan(500));
    expect(marker(), isNull);
    expect(maintenance.spaceReclaimWarning, contains('free disk space'));
  });

  test('disabled database maintenance leaves the space alone', () async {
    freeSomePages();
    final maintenance = ApplicationMaintenance(
      databaseFile: file,
      coordinator: DatabaseMaintenanceCoordinator(file),
      diskSpace: const _AmpleDisk(),
      reclaimMinimumDatabaseBytes: 0,
    );
    addTearDown(() async {
      await maintenance.stop();
      maintenance.dispose();
    });
    await maintenance.configure(
      AppSettings.fromTomlMap({
        'pricing': {'use_external_pricing': false},
        'maintenance': {'database_optimize_enabled': false},
      }),
    );
    await maintenance.runDueJobs();
    expect(reclaimJobs(), isEmpty);
    expect(marker(), isNull);
  });
}

final class _AmpleDisk implements DiskSpaceProbe {
  const _AmpleDisk();

  @override
  DiskVolumeSpace probe(Directory directory) =>
      const DiskVolumeSpace(volumeKey: 'ample', availableBytes: 1 << 50);
}

final class _FullDisk implements DiskSpaceProbe {
  const _FullDisk();

  @override
  DiskVolumeSpace probe(Directory directory) =>
      const DiskVolumeSpace(volumeKey: 'full', availableBytes: 0);
}
