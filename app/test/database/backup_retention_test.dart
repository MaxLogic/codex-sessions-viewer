import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/application_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/backup_retention.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _hash = '4e98c339d45e13339601941b7b6c5c69';

void main() {
  late Directory temp;
  late File databaseFile;
  late Directory backups;
  late DateTime now;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('csv_backup_retention_');
    databaseFile = File(p.join(temp.path, 'codex_sessions_viewer.sqlite'));
    final migrated = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(databaseFile);
    expect(migrated.canStartNormalUi, isTrue);
    backups = Directory(p.join(temp.path, 'backups'))..createSync();
    now = DateTime.now().toUtc();
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  File write(
    String name, {
    int bytes = 10,
    DateTime? modified,
    Directory? folder,
  }) {
    final file = File(p.join((folder ?? backups).path, name))
      ..writeAsBytesSync(List.filled(bytes, 1));
    if (modified != null) file.setLastModifiedSync(modified);
    return file;
  }

  String legacyRepair(int version, DateTime created, [int sequence = 1]) =>
      'codex_sessions_viewer.pre-session-cache-repair-v$version.repair-$version-'
      '${created.microsecondsSinceEpoch}-$sequence.sqlite';

  BackupRetentionResult prune({int days = 7}) {
    final db = openFileBackedDatabase(databaseFile);
    try {
      return ViewerBackupRetention(
        databaseFile: databaseFile,
        retention: Duration(days: days),
        clock: () => now,
      ).prune(db);
    } finally {
      db.close();
    }
  }

  void execute(String sql, [List<Object?> args = const []]) {
    final db = openFileBackedDatabase(databaseFile, maintenanceWriter: true);
    try {
      db.execute(sql, args);
    } finally {
      db.close();
    }
  }

  void insertUsageJob(String state, {required DateTime created, String? path}) {
    execute(
      '''
      insert into maintenance_jobs(job_type, state, phase, run_token,
        lease_expires_at_utc, updated_at_utc, created_at_utc, payload_json)
      values ('usage_projection_migration', ?, 'backup_complete', ?, ?, ?, ?, ?)
      ''',
      [
        state,
        state == 'running' ? 'token' : null,
        state == 'running' ? now.toIso8601String() : null,
        now.toIso8601String(),
        created.toIso8601String(),
        path == null ? null : '{"backup":{"path":${_json(path)}}}',
      ],
    );
  }

  test('old completed backups are removed with their side files; recent '
      'backups, collector backups and unrelated files are untouched', () {
    final old = now.subtract(const Duration(days: 30));
    final usage = write('usage-pre16-$_hash.sqlite', bytes: 18, modified: old);
    final v1 = write(legacyRepair(1, old), bytes: 11);
    final v1Wal = write('${p.basename(v1.path)}-wal', bytes: 3);
    final v1Shm = write('${p.basename(v1.path)}-shm', bytes: 4);
    final v2 = write(legacyRepair(2, old), bytes: 12);
    // A side file whose backup is already gone.
    final orphanJournal = write('${legacyRepair(1, old, 7)}-journal', bytes: 5);
    final recentUsage = write(
      'usage-pre16-${'a' * 32}.sqlite',
      modified: now.subtract(const Duration(days: 1)),
    );
    final recentV1 = write(
      legacyRepair(1, now.subtract(const Duration(days: 1))),
    );
    final untouched = [
      // Collector-owned: the collector prunes its own v3 copies.
      write(legacyRepair(3, old)),
      write('usage-pre16-$_hash.sqlite.partial', modified: old),
      write('usage-pre16-notahash.sqlite', modified: old),
      write('usage-pre16-$_hash.sqlite.bak', modified: old),
      write(
        legacyRepair(1, old).replaceFirst('codex_sessions_viewer', 'other'),
        modified: old,
      ),
      write('notes.txt', modified: old),
      // The backup name outside the backup folder.
      write('usage-pre16-${'b' * 32}.sqlite', modified: old, folder: temp),
    ];

    final result = prune();

    for (final file in [usage, v1, v1Wal, v1Shm, v2, orphanJournal]) {
      expect(file.existsSync(), isFalse, reason: '${file.path} is deleted');
    }
    for (final file in [recentUsage, recentV1, ...untouched]) {
      expect(file.existsSync(), isTrue, reason: '${file.path} is untouched');
    }
    expect(databaseFile.existsSync(), isTrue);
    expect(
      {for (final entry in result.deleted) entry.path: entry.bytes},
      {
        usage.path: 18,
        v1.path: 11,
        v1Wal.path: 3,
        v1Shm.path: 4,
        v2.path: 12,
        orphanJournal.path: 5,
      },
    );
    expect(result.failed, isEmpty);
  });

  test('a usage backup of an unfinished migration is kept whatever its age', () {
    final old = now.subtract(const Duration(days: 300));
    final usage = write('usage-pre16-$_hash.sqlite', modified: old);
    final v1 = write(legacyRepair(1, old));

    execute(
      "insert into app_metadata(key, value, updated_at_utc) values ('usage_migration_bootstrap', ?, ?)",
      [
        '{"identity":"$_hash","backup_path":${_json(usage.path)}}',
        now.toIso8601String(),
      ],
    );
    prune(days: 1);
    expect(usage.existsSync(), isTrue, reason: 'the receipt references it');
    expect(v1.existsSync(), isFalse, reason: 'legacy repairs never resume');

    execute("delete from app_metadata where key='usage_migration_bootstrap'");
    for (final state in ['running', 'interrupted', 'failed']) {
      execute('delete from maintenance_jobs');
      insertUsageJob(state, created: old, path: usage.path);
      prune(days: 1);
      expect(usage.existsSync(), isTrue, reason: 'the job is $state');
    }

    execute('delete from maintenance_jobs');
    insertUsageJob('succeeded', created: old, path: usage.path);
    prune(days: 1);
    expect(usage.existsSync(), isFalse, reason: 'the migration succeeded');
  });

  test('the recorded backup time wins over the file time', () {
    final usage = write(
      'usage-pre16-$_hash.sqlite',
      modified: now.subtract(const Duration(days: 30)),
    );
    insertUsageJob(
      'succeeded',
      created: now.subtract(const Duration(days: 2)),
      path: usage.path,
    );
    prune();
    expect(usage.existsSync(), isTrue);
    prune(days: 1);
    expect(usage.existsSync(), isFalse);
  });

  test('the retention period is configurable', () {
    final threeDays = now.subtract(const Duration(days: 3));
    final usage = write('usage-pre16-$_hash.sqlite', modified: threeDays);
    final v2 = write(legacyRepair(2, threeDays));
    prune();
    expect(usage.existsSync() && v2.existsSync(), isTrue);
    prune(days: 2);
    expect(usage.existsSync() || v2.existsSync(), isFalse);

    expect(AppSettings.defaults().database.backupRetentionDays, 7);
    expect(defaultBackupRetentionDays, 7);
    expect(
      AppSettings.fromTomlMap({
        'database': {'backup_retention_days': 3},
      }).database.backupRetentionDays,
      3,
    );
    for (final invalid in [0, -1, 3651]) {
      expect(
        () => AppSettings.fromTomlMap({
          'database': {'backup_retention_days': invalid},
        }),
        throwsA(isA<SettingsValidationException>()),
      );
    }
    final settings = AppSettings.defaults().copyWith(
      database: const DatabaseSettings(backupRetentionDays: 14),
    );
    expect(
      AppSettings.fromTomlMap(
        settings.toTomlMap().cast<String, dynamic>(),
      ).database.backupRetentionDays,
      14,
    );
  });

  test('a backup that cannot be deleted is reported and keeps its side '
      'files', () async {
    final old = now.subtract(const Duration(days: 30));
    final v1 = write(legacyRepair(1, old));
    final wal = write('${p.basename(v1.path)}-wal');
    final handle = await v1.open();
    try {
      final result = prune();
      expect(result.failed, [v1.path]);
      expect(v1.existsSync() && wal.existsSync(), isTrue);
    } finally {
      await handle.close();
    }
    expect(prune().failed, isEmpty);
    expect(v1.existsSync() || wal.existsSync(), isFalse);
  }, skip: Platform.isWindows ? false : 'Open files block deletion on Windows');

  test('application maintenance prunes after startup and logs each deletion '
      'with its path and size', () async {
    final usage = write(
      'usage-pre16-$_hash.sqlite',
      bytes: 21,
      modified: now.subtract(const Duration(days: 10)),
    );
    final maintenance = ApplicationMaintenance(
      databaseFile: databaseFile,
      coordinator: DatabaseMaintenanceCoordinator(databaseFile),
    );
    try {
      await maintenance.configure(
        AppSettings.fromTomlMap({
          'pricing': {'use_external_pricing': false},
          'maintenance': {'database_optimize_enabled': false},
          'database': {'backup_retention_days': 7},
          'logging': {'log_file': p.join(temp.path, 'logs', 'viewer.log')},
        }),
      );
      expect(usage.existsSync(), isTrue, reason: 'nothing runs before start');
      await maintenance.runDueJobs();
      expect(usage.existsSync(), isFalse);
      expect(maintenance.backupRetentionWarning, isNull);
    } finally {
      await maintenance.stop();
      maintenance.dispose();
    }
    final db = openFileBackedDatabase(databaseFile);
    try {
      final logs = db.select(
        "select message, details from logs where message like '%backup%'",
      );
      expect(logs, hasLength(1));
      expect(logs.single['details'], contains(_json(usage.path)));
      expect(logs.single['details'], contains('"bytes":21'));
    } finally {
      db.close();
    }
  });
}

String _json(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
