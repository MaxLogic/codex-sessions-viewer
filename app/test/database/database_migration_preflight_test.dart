import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_backup.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_migration_preflight.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show sqlite3;

void main() {
  late Directory temp;
  late File source;
  late Directory backupDirectory;
  late Directory temporaryDirectory;
  late Database database;
  late MaintenanceJobRepository jobs;
  late MaintenanceJobLease lease;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('csv_preflight_space_');
    source = File(p.join(temp.path, 'viewer.sqlite'));
    backupDirectory = Directory(p.join(temp.path, 'backup'));
    temporaryDirectory = Directory(p.join(temp.path, 'sqlite-temp'));
    await DatabaseMigrator(sqlRoot: Directory('../sql')).openAndMigrate(source);
    database = openFileBackedDatabase(source);
    // Unrelated content must be backed up but is not copied into usage tables.
    database.execute('create table unrelated_content (content blob)');
    database.execute(
      'insert into unrelated_content values (zeroblob(2097152))',
    );
    jobs = MaintenanceJobRepository(database);
    jobs.enqueue(jobType: 'space_probe', phase: 'preflight');
    lease = jobs.claim(
      jobType: 'space_probe',
      leaseDuration: const Duration(minutes: 1),
    )!;
    database.execute('pragma wal_checkpoint(truncate)');
  });

  tearDown(() async {
    database.close();
    await temp.delete(recursive: true);
  });

  Future<DatabaseMigrationPreflightResult> run(MigrationDiskSpaceProbe probe) =>
      DatabaseMigrationPreflight(diskSpaceProbe: probe).run(
        database: database,
        jobs: jobs,
        lease: lease,
        databaseFile: source,
        backupDirectory: backupDirectory,
        temporaryDirectory: temporaryDirectory,
      );

  test('split volumes reserve each allocation plus twenty percent', () async {
    final result = await run(
      (directory) async =>
          DiskVolumeSpace(volumeKey: directory.path, availableBytes: 1 << 40),
    );
    final requirements = {
      for (final requirement in result.spaceRequirements)
        requirement.volumeKey: requirement,
    };
    final backup = requirements[backupDirectory.path]!;
    // This volume only holds one verified backup; its margin is exactly 20%.
    final backupBytes = result.backup.lengthBytes;
    expect(backup.requiredBytes, (backupBytes * 6 + 4) ~/ 5);
    final db = requirements[source.parent.path]!;
    expect(db.requiredBytes, greaterThan(64 * 1024 * 1024));
    expect(
      requirements[temporaryDirectory.path]!.requiredBytes,
      lessThan(backup.requiredBytes),
      reason: 'SQLite table/index measurements exclude unrelated content.',
    );
  });

  test(
    'shared volume sums allocations before applying safety margin',
    () async {
      final result = await run(
        (_) async =>
            const DiskVolumeSpace(volumeKey: 'shared', availableBytes: 1 << 40),
      );
      final requirement = result.spaceRequirements.single;
      expect(
        requirement.allocations.keys,
        unorderedEquals([
          'verified_backup',
          'shadow_tables',
          'final_indexes',
          'temporary_index_build',
          'wal',
        ]),
      );
      final allocated = requirement.allocations.values.fold<int>(
        0,
        (a, b) => a + b,
      );
      expect(requirement.requiredBytes, (allocated * 6 + 4) ~/ 5);
    },
  );

  test('one byte below a volume requirement refuses before backup', () async {
    // Obtain a real estimate without producing a backup, then test its boundary.
    late MigrationSpaceRequirement requirement;
    try {
      await run(
        (_) async =>
            const DiskVolumeSpace(volumeKey: 'shared', availableBytes: 0),
      );
      fail('Space preflight must refuse an empty volume.');
    } on InsufficientMigrationSpaceException catch (error) {
      requirement = error.requirement;
    }
    expect(await backupDirectory.exists(), isFalse);
    await expectLater(
      run(
        (_) async => DiskVolumeSpace(
          volumeKey: 'shared',
          availableBytes: requirement.requiredBytes - 1,
        ),
      ),
      throwsA(isA<InsufficientMigrationSpaceException>()),
    );
    expect(await backupDirectory.exists(), isFalse);
    final result = await run(
      (_) async => DiskVolumeSpace(
        volumeKey: 'shared',
        availableBytes: requirement.requiredBytes,
      ),
    );
    expect(await result.backup.file.exists(), isTrue);
  });

  test(
    'resumed verified backup needs no additional backup volume space',
    () async {
      final first = await run(
        (directory) async =>
            DiskVolumeSpace(volumeKey: directory.path, availableBytes: 1 << 40),
      );
      final resumed = await run(
        (directory) async => DiskVolumeSpace(
          volumeKey: directory.path,
          availableBytes: directory.path == backupDirectory.path ? 0 : 1 << 40,
        ),
      );
      expect(resumed.backup.sha256, first.backup.sha256);
      expect(
        resumed.spaceRequirements
            .singleWhere((space) => space.volumeKey == backupDirectory.path)
            .requiredBytes,
        0,
      );
    },
  );

  test(
    'remaining space excludes allocated targets but not retired or free pages',
    () async {
      final probe = sqlite3.openInMemory();
      addTearDown(probe.close);
      probe.execute('create table usage_events (payload blob)');
      probe.execute('insert into usage_events values (zeroblob(1048576))');
      probe.execute('create index source_payload on usage_events(payload)');
      final preflight = DatabaseMigrationPreflight(
        diskSpaceProbe: (_) async =>
            const DiskVolumeSpace(volumeKey: 'shared', availableBytes: 1 << 40),
      );
      Future<MigrationSpaceRequirement> check() async =>
          (await preflight.checkSpace(
            database: probe,
            databaseFile: source,
            backupDirectory: backupDirectory,
            temporaryDirectory: temporaryDirectory,
            backupAlreadyPresent: true,
          )).single;
      // Realized schema 15 has no additive migration tables.
      final before = await check();
      for (final table in [
        'usage_events_next',
        'usage_path_contexts',
        'usage_path_context_aliases',
        'usage_context_project_candidates',
        'usage_session_daily',
      ]) {
        probe.execute('create table $table (payload blob)');
        probe.execute('insert into $table values (zeroblob(65536))');
        probe.execute('create index idx_${table}_probe on $table(payload)');
      }
      final allocated =
          probe.select('''
      select coalesce(sum(pgsize), 0) as bytes from dbstat
      where name in ('usage_events_next', 'usage_path_contexts',
        'usage_path_context_aliases', 'usage_context_project_candidates',
        'usage_session_daily')
    ''').single['bytes']
              as int;
      final allocatedIndexes =
          probe.select('''
      select coalesce(sum(pgsize), 0) as bytes from dbstat
      where name glob 'idx_*_probe'
    ''').single['bytes']
              as int;
      final resumed = await check();
      expect(
        resumed.allocations['shadow_tables'],
        before.allocations['shadow_tables']! - allocated,
      );
      expect(
        resumed.allocations['final_indexes'],
        before.allocations['final_indexes']! - allocatedIndexes,
      );
      expect(resumed.allocations['wal'], before.allocations['wal']);
      expect(
        resumed.allocations['temporary_index_build'],
        before.allocations['temporary_index_build'],
      );
      // Cutover retains the old table; its pages are not additional free space.
      probe.execute('alter table usage_events rename to usage_events_legacy');
      probe.execute('alter table usage_events_next rename to usage_events');
      expect((await check()).allocations, resumed.allocations);
      probe.execute('create table discarded_probe (payload blob)');
      probe.execute('insert into discarded_probe values (zeroblob(2097152))');
      probe.execute('drop table discarded_probe');
      expect(
        probe.select('pragma freelist_count').single.values.single,
        greaterThan(0),
      );
      expect((await check()).allocations, resumed.allocations);
    },
  );

  for (final backupState in ['intact', 'missing', 'modified', 'wal-modified']) {
    test(
      'failed-attempt retry checks its $backupState recorded backup',
      () async {
        Future<DiskVolumeSpace> ampleSpace(Directory _) async =>
            const DiskVolumeSpace(volumeKey: 'shared', availableBytes: 1 << 40);
        final first = await run(ampleSpace);
        final oldJobId = lease.jobId;
        jobs.markFailed(
          lease,
          phase: 'backup_complete',
          errorMessage: 'Injected failure after backup.',
        );
        jobs.enqueue(jobType: 'space_probe', phase: 'preflight');
        lease = jobs.claim(
          jobType: 'space_probe',
          leaseDuration: const Duration(minutes: 1),
        )!;
        expect(lease.jobId, isNot(oldJobId));
        if (backupState == 'missing') {
          await first.backup.file.delete();
        } else if (backupState == 'modified' || backupState == 'wal-modified') {
          final changed = openFileBackedDatabase(first.backup.file);
          changed.execute('update unrelated_content set content = zeroblob(1)');
          if (backupState == 'wal-modified') {
            addTearDown(changed.close);
          } else {
            changed.close();
          }
        }
        if (backupState == 'intact') {
          final resumed = await run(ampleSpace);
          expect(resumed.backup.file.path, first.backup.file.path);
          expect(resumed.backup.sha256, first.backup.sha256);
        } else {
          await expectLater(run(ampleSpace), throwsStateError);
        }
        expect(
          await File(
            p.join(
              backupDirectory.path,
              'usage-projection-job-${lease.jobId}.sqlite',
            ),
          ).exists(),
          isFalse,
          reason: 'A retry must never replace the recorded recovery source.',
        );
      },
    );
  }

  test('preflight refuses an unrelated valid published backup', () async {
    await SqliteBackupService().create(
      source: database,
      databaseFile: source,
      backupDirectory: backupDirectory,
      backupName: 'usage-projection-job-${lease.jobId}.sqlite',
    );
    await expectLater(
      run(
        (_) async =>
            const DiskVolumeSpace(volumeKey: 'shared', availableBytes: 1 << 40),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'recovery guidance',
          contains('Move'),
        ),
      ),
    );
  });

  test(
    'published backup embeds identity for recovery before evidence commit',
    () async {
      Future<DiskVolumeSpace> ampleSpace(Directory _) async =>
          const DiskVolumeSpace(volumeKey: 'shared', availableBytes: 1 << 40);
      final first = await run(ampleSpace);
      final payload =
          jsonDecode(jobs.read(lease.jobId)!.payloadJson!)
              as Map<String, dynamic>;
      expect(payload['backup_intent'], isNotNull);
      // Model a crash after publication but before the backup evidence checkpoint.
      payload.remove('backup');
      database.execute(
        'update maintenance_jobs set payload_json = ? where id = ?',
        [jsonEncode(payload), lease.jobId],
      );
      jobs.markFailed(
        lease,
        phase: 'preflight',
        errorMessage: 'Injected publication crash.',
      );
      jobs.enqueue(jobType: 'space_probe', phase: 'preflight');
      lease = jobs.claim(
        jobType: 'space_probe',
        leaseDuration: const Duration(minutes: 1),
      )!;
      final recovered = await run(ampleSpace);
      expect(recovered.backup.file.path, first.backup.file.path);
      expect(recovered.backup.sha256, first.backup.sha256);
    },
  );

  test(
    'retry before publication keeps the original backup volume and path',
    () async {
      final first = await run(
        (_) async =>
            const DiskVolumeSpace(volumeKey: 'shared', availableBytes: 1 << 40),
      );
      final payload =
          jsonDecode(jobs.read(lease.jobId)!.payloadJson!)
              as Map<String, dynamic>;
      payload.remove('backup');
      database.execute(
        'update maintenance_jobs set payload_json = ? where id = ?',
        [jsonEncode(payload), lease.jobId],
      );
      await first.backup.file.delete();
      final originalDirectory = backupDirectory.path;
      backupDirectory = Directory(p.join(temp.path, 'changed-backup-setting'));
      final probedDirectories = <String>[];
      final resumed = await run((directory) async {
        probedDirectories.add(directory.path);
        return const DiskVolumeSpace(
          volumeKey: 'shared',
          availableBytes: 1 << 40,
        );
      });
      expect(resumed.backup.file.path, first.backup.file.path);
      expect(probedDirectories, contains(originalDirectory));
      expect(await backupDirectory.exists(), isFalse);
    },
  );
}
