import '../support/test_environment.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:codex_sessions_viewer/src/pricing/pricing_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('csv_db_connection_test_');
    dbFile = File('${tempDir.path}${Platform.pathSeparator}viewer.sqlite');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'file-backed connections enable WAL, busy timeout, and foreign keys',
    () {
      final db = openFileBackedDatabase(dbFile);
      addTearDown(db.close);

      final journalMode = db.select('pragma journal_mode').single.values.single;
      final busyTimeout = db.select('pragma busy_timeout').single.values.single;
      final foreignKeys = db.select('pragma foreign_keys').single.values.single;

      expect(journalMode, 'wal');
      expect(busyTimeout, greaterThan(0));
      expect(foreignKeys, 1);
    },
  );

  test('configuration fails when SQLite does not enable WAL', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);

    expect(
      () => configureFileBackedDatabase(db),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('WAL journal mode'),
        ),
      ),
    );
  });

  test(
    'unfinished migration denies fresh writers until durable success',
    () async {
      final startup = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(dbFile);
      expect(startup.canStartNormalUi, isTrue);
      final maintenance = openFileBackedDatabase(
        dbFile,
        maintenanceWriter: true,
      );
      addTearDown(maintenance.close);
      maintenance.execute('create table write_probe (value text not null)');
      maintenance.execute("insert into write_probe values ('preserved')");
      final jobs = MaintenanceJobRepository(maintenance);
      const jobType = 'usage_projection_migration';

      void expectFreshWriterDenied(MaintenanceJobState state) {
        expect(jobs.latestForType(jobType)!.state, state);
        final contender = openFileBackedDatabase(dbFile);
        try {
          expect(
            contender.select('select value from write_probe').single['value'],
            'preserved',
          );
          for (final sql in [
            "insert into write_probe values ('unexpected')",
            'update sessions set project_id = project_id',
            'update usage_events set total_tokens = total_tokens',
            'update projects set name = name',
            'update model_pricing_cache set model_name = model_name',
            'update logs set message = message',
          ]) {
            expect(
              () => contender.execute(sql),
              throwsA(
                isA<SqliteException>().having(
                  (error) => error.resultCode,
                  'SQLITE_READONLY',
                  8,
                ),
              ),
              reason: '${state.name}: $sql',
            );
          }
        } finally {
          contender.close();
        }
      }

      jobs.enqueue(jobType: jobType, phase: 'copy_events');
      expectFreshWriterDenied(MaintenanceJobState.pending);
      final maintenanceReopened = openFileBackedDatabase(
        dbFile,
        maintenanceWriter: true,
      );
      try {
        maintenanceReopened.execute('update write_probe set value = value');
      } finally {
        maintenanceReopened.close();
      }
      var lease = jobs.claim(
        jobType: jobType,
        leaseDuration: const Duration(minutes: 1),
      )!;
      expectFreshWriterDenied(MaintenanceJobState.running);
      jobs.markInterrupted(lease, statusMessage: 'Stopped at a safe boundary.');
      expectFreshWriterDenied(MaintenanceJobState.interrupted);
      lease = jobs.claim(
        jobType: jobType,
        leaseDuration: const Duration(minutes: 1),
      )!;
      jobs.markFailed(
        lease,
        phase: 'copy_events',
        errorMessage: 'Injected failure',
      );
      expectFreshWriterDenied(MaintenanceJobState.failed);
      final failedId = lease.jobId;
      jobs.enqueue(jobType: jobType, phase: 'copy_events');
      lease = jobs.claim(
        jobType: jobType,
        leaseDuration: const Duration(minutes: 1),
      )!;
      jobs.markSucceeded(lease, phase: 'complete', statusMessage: 'Validated.');
      expect(jobs.read(failedId)!.state, MaintenanceJobState.failed);
      final reopened = openFileBackedDatabase(dbFile);
      try {
        reopened.execute("insert into write_probe values ('allowed')");
        expect(reopened.select('select value from write_probe'), hasLength(2));
      } finally {
        reopened.close();
      }
    },
  );

  test(
    'bootstrap marker denies schema 15 writers until committed cleanup',
    () async {
      final startup = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(dbFile, deferUsageMigration: true);
      expect(startup.canStartNormalUi, isTrue);
      final owner = openFileBackedDatabase(dbFile, maintenanceWriter: true);
      addTearDown(owner.close);
      expect(
        owner.select(
          "select name from sqlite_schema where name = 'maintenance_jobs'",
        ),
        isEmpty,
      );
      owner.execute('create table bootstrap_write_probe (value text not null)');
      owner.execute("insert into bootstrap_write_probe values ('preserved')");
      owner.execute('''
      insert into app_metadata (key, value, updated_at_utc)
      values ('unrelated_marker', '{}', '2026-09-07T00:00:00Z')
    ''');
      final before = openFileBackedDatabase(dbFile);
      before.execute('update bootstrap_write_probe set value = value');
      before.close();

      void expectDenied() {
        final contender = openFileBackedDatabase(dbFile);
        try {
          expect(
            contender
                .select('select value from bootstrap_write_probe')
                .single['value'],
            'preserved',
          );
          expect(
            () => contender.execute(
              "insert into bootstrap_write_probe values ('unexpected')",
            ),
            throwsA(
              isA<SqliteException>().having(
                (error) => error.resultCode,
                'SQLITE_READONLY',
                8,
              ),
            ),
          );
        } finally {
          contender.close();
        }
      }

      // Presence is the barrier, even if a receipt is damaged or incomplete.
      for (final receipt in [
        '{"state":"backup_pending"}',
        'damaged JSON',
        '',
      ]) {
        owner.execute(
          '''
        insert or replace into app_metadata (key, value, updated_at_utc)
        values ('usage_migration_bootstrap', ?, '2026-09-07T00:00:00Z')
      ''',
          [receipt],
        );
        expectDenied();
        final maintenance = openFileBackedDatabase(
          dbFile,
          maintenanceWriter: true,
        );
        maintenance.execute('update bootstrap_write_probe set value = value');
        maintenance.close();
      }
      owner.execute('begin immediate');
      owner.execute(
        "delete from app_metadata where key = 'usage_migration_bootstrap'",
      );
      owner.execute('rollback');
      expectDenied();
      owner.execute('begin immediate');
      owner.execute(
        "delete from app_metadata where key = 'usage_migration_bootstrap'",
      );
      owner.execute('commit');
      final reopened = openFileBackedDatabase(dbFile);
      try {
        reopened.execute(
          "insert into bootstrap_write_probe values ('allowed')",
        );
        expect(
          reopened.select('select value from bootstrap_write_probe'),
          hasLength(2),
        );
      } finally {
        reopened.close();
      }
    },
  );

  test('separate process writers serialize through the busy timeout', () async {
    final setup = openFileBackedDatabase(dbFile);
    setup.execute('create table actor_writes (value text not null)');
    setup.close();
    final signalBase = '${dbFile.path}.writer_test';
    final contender = await _startActor(dbFile, 'write', signalBase);
    _registerActorCleanup(contender, signalBase);
    expect(await contender.nextOutputLine(), 'ready');
    final holder = await _startActor(dbFile, 'hold', signalBase);
    _registerActorCleanup(holder, signalBase);
    expect(await holder.nextOutputLine(), 'locked');
    await File('$signalBase.start').create();
    expect(await contender.nextOutputLine(), 'attempting');

    await File('$signalBase.release').create();

    expect(await holder.process.exitCode, 0);
    expect(await contender.process.exitCode, 0);
    final verification = openFileBackedDatabase(dbFile);
    addTearDown(verification.close);
    expect(
      verification
          .select('select value from actor_writes order by rowid')
          .map((row) => row['value']),
      ['holder', 'contender'],
    );
  });

  test(
    'cached pricing remains readable while another process writes',
    () async {
      final setup = openFileBackedDatabase(dbFile);
      setup.execute(
        File('../sql/init/001_initial_schema.sql').readAsStringSync(),
      );
      setup.execute('create table actor_writes (value text not null)');
      setup.close();
      final signalBase = '${dbFile.path}.reader_test';
      final holder = await _startActor(dbFile, 'hold', signalBase);
      _registerActorCleanup(holder, signalBase);
      expect(await holder.nextOutputLine(), 'locked');
      final reader = openFileBackedDatabase(dbFile, busyTimeoutMs: 100);
      addTearDown(reader.close);

      final catalog = PricingRepository(
        reader,
      ).loadCached(_pricingSettings, nowUtc: DateTime.utc(2026, 6, 13, 10));

      expect(catalog.models['local/model']?.promptPricePerToken, '0.10');
      await File('$signalBase.release').create();
      expect(await holder.process.exitCode, 0);
    },
  );
}

Future<_ActorProcess> _startActor(
  File databaseFile,
  String mode,
  String signalBase,
) async {
  final helper = [
    Directory.current.path,
    'test',
    'database',
    'helpers',
    'database_process_actor.dart',
  ].join(Platform.pathSeparator);
  final process = await startTestProcess(_dartExecutable(), [
    '--packages=.dart_tool/package_config.json',
    helper,
    databaseFile.path,
    mode,
    signalBase,
  ], workingDirectory: Directory.current.path);
  return _ActorProcess(process);
}

void _registerActorCleanup(_ActorProcess actor, String signalBase) {
  addTearDown(() async {
    await File('$signalBase.start').create();
    await File('$signalBase.release').create();
    actor.process.kill();
    await actor.process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
  });
}

String _dartExecutable() {
  final separator = Platform.isWindows ? ';' : ':';
  final executableName = Platform.isWindows ? 'dart.exe' : 'dart';
  for (final entry in (Platform.environment['PATH'] ?? '').split(separator)) {
    final direct = File([entry, executableName].join(Platform.pathSeparator));
    if (direct.existsSync()) {
      return direct.path;
    }
    final flutterSdk = File(
      [
        entry,
        'cache',
        'dart-sdk',
        'bin',
        executableName,
      ].join(Platform.pathSeparator),
    );
    if (flutterSdk.existsSync()) {
      return flutterSdk.path;
    }
  }
  throw StateError('Unable to locate the Dart SDK executable.');
}

class _ActorProcess {
  _ActorProcess(this.process)
    : _lines = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );

  final Process process;
  final StreamIterator<String> _lines;

  Future<String> nextOutputLine() async {
    final hasLine = await _lines.moveNext().timeout(
      const Duration(seconds: 30),
    );
    if (!hasLine) {
      final error = await process.stderr.transform(utf8.decoder).join();
      throw StateError('Database actor exited without output. $error');
    }
    return _lines.current;
  }
}

const _pricingSettings = PricingSettings(
  provider: 'openrouter',
  useExternalPricing: false,
  cachePricingHours: 24,
  fallbackToOverrides: true,
  openRouter: OpenRouterSettings(
    modelsEndpoint: 'https://openrouter.ai/api/v1/models',
    apiKey: '',
  ),
  overrides: {
    'local/model': PricingOverrideSettings(
      prompt: '0.10',
      completion: '0.20',
      inputCacheRead: '0.03',
      inputCacheWrite: '0.04',
      internalReasoning: '0.05',
    ),
  },
);
