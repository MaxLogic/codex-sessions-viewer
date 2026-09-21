import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late File databaseFile;
  late Database db;
  var now = DateTime.utc(2026, 9, 4, 10);
  var tokenSequence = 0;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('csv_maintenance_job_');
    databaseFile = File('${temp.path}${Platform.pathSeparator}viewer.sqlite');
    final startup = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);
    db = openFileBackedDatabase(databaseFile);
    db.execute(
      'create table migration_probe (source_rowid integer primary key)',
    );
  });

  tearDown(() async {
    db.close();
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  MaintenanceJobRepository repository() => MaintenanceJobRepository(
    db,
    clock: () => now,
    tokenFactory: () => 'run-${++tokenSequence}',
    ownerProcessId: 4242,
  );

  test('commits batch data and its durable checkpoint atomically', () {
    final jobs = repository();
    final queued = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'copy_events',
      totalUnits: 2,
    );
    final lease = jobs.claim(
      jobType: queued.jobType,
      leaseDuration: const Duration(minutes: 1),
    );
    expect(lease, isNotNull);

    jobs.commitBatch(
      lease: lease!,
      phase: 'copy_events',
      completedUnits: 1,
      totalUnits: 2,
      lastProcessedRowId: 10,
      statusMessage: 'Copied event batch 1 of 2.',
      apply: (transaction) {
        transaction.execute(
          'insert into migration_probe (source_rowid) values (10)',
        );
      },
    );

    final afterFirst = jobs.read(queued.id)!;
    expect(afterFirst.completedUnits, 1);
    expect(afterFirst.lastProcessedRowId, 10);
    expect(
      db
          .select('select source_rowid from migration_probe')
          .single
          .values
          .single,
      10,
    );

    expect(
      () => jobs.commitBatch(
        lease: lease,
        phase: 'copy_events',
        completedUnits: 2,
        totalUnits: 2,
        lastProcessedRowId: 20,
        statusMessage: 'This batch must roll back.',
        apply: (transaction) {
          transaction.execute(
            'insert into migration_probe (source_rowid) values (20)',
          );
          throw StateError('injected batch failure');
        },
      ),
      throwsStateError,
    );

    final afterFailure = jobs.read(queued.id)!;
    expect(afterFailure.completedUnits, 1);
    expect(afterFailure.lastProcessedRowId, 10);
    expect(
      db.select(
        'select source_rowid from migration_probe order by source_rowid',
      ),
      hasLength(1),
    );
  });

  test('expired lease is reclaimed and stale workers cannot commit', () {
    final jobs = repository();
    final queued = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'copy_events',
      totalUnits: 3,
    );
    final first = jobs.claim(
      jobType: queued.jobType,
      leaseDuration: const Duration(seconds: 30),
    )!;
    jobs.commitBatch(
      lease: first,
      phase: 'copy_events',
      completedUnits: 1,
      totalUnits: 3,
      lastProcessedRowId: 10,
      statusMessage: 'First batch complete.',
      apply: (transaction) => transaction.execute(
        'insert into migration_probe (source_rowid) values (10)',
      ),
    );

    expect(
      jobs.claim(
        jobType: queued.jobType,
        leaseDuration: const Duration(seconds: 30),
      ),
      isNull,
    );
    now = now.add(const Duration(minutes: 1));
    final replacement = jobs.claim(
      jobType: queued.jobType,
      leaseDuration: const Duration(seconds: 30),
    )!;

    expect(replacement.jobId, first.jobId);
    expect(replacement.runToken, isNot(first.runToken));
    expect(jobs.read(queued.id)!.attemptCount, 2);
    expect(jobs.read(queued.id)!.lastProcessedRowId, 10);
    expect(
      () => jobs.requestStop(first.jobId, lease: first),
      throwsA(isA<StaleMaintenanceLeaseException>()),
    );
    expect(jobs.stopRequested(replacement), isFalse);
    expect(
      () => jobs.commitBatch(
        lease: first,
        phase: 'copy_events',
        completedUnits: 2,
        totalUnits: 3,
        lastProcessedRowId: 20,
        statusMessage: 'Stale worker.',
        apply: (_) {},
      ),
      throwsA(isA<StaleMaintenanceLeaseException>()),
    );
  });

  test('heartbeat keeps ownership during a long atomic operation', () {
    final jobs = repository();
    final queued = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'backup',
    );
    final lease = jobs.claim(
      jobType: queued.jobType,
      leaseDuration: const Duration(seconds: 30),
    )!;

    now = now.add(const Duration(seconds: 20));
    jobs.renew(lease);
    now = now.add(const Duration(seconds: 20));

    expect(
      jobs.claim(
        jobType: queued.jobType,
        leaseDuration: const Duration(seconds: 30),
      ),
      isNull,
    );
    expect(
      jobs.read(queued.id)!.heartbeatAtUtc,
      now.subtract(const Duration(seconds: 20)),
    );
  });

  test('expired atomic phase is failed before a fresh retry attempt', () {
    final jobs = repository();
    final queued = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'build_indexes',
      totalUnits: 4,
    );
    jobs.claim(
      jobType: queued.jobType,
      leaseDuration: const Duration(seconds: 30),
      atomicPhases: const {'build_indexes'},
    );
    now = now.add(const Duration(minutes: 1));

    final retry = jobs.claim(
      jobType: queued.jobType,
      leaseDuration: const Duration(seconds: 30),
      atomicPhases: const {'build_indexes'},
    )!;

    expect(retry.jobId, isNot(queued.id));
    expect(jobs.read(queued.id)!.state, MaintenanceJobState.failed);
    expect(jobs.read(queued.id)!.errorMessage, contains('lease expired'));
    expect(jobs.read(retry.jobId)!.attemptCount, 1);
    expect(jobs.read(retry.jobId)!.phase, 'build_indexes');
  });

  test('stop is persisted and takes effect at the next safe boundary', () {
    final jobs = repository();
    final queued = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'copy_events',
      totalUnits: 3,
    );
    final lease = jobs.claim(
      jobType: queued.jobType,
      leaseDuration: const Duration(minutes: 1),
    )!;

    expect(jobs.requestStop(queued.id), isTrue);
    expect(jobs.stopRequested(lease), isTrue);
    jobs.markInterrupted(
      lease,
      statusMessage: 'Stopped safely after the current batch.',
    );

    final interrupted = jobs.read(queued.id)!;
    expect(interrupted.state, MaintenanceJobState.interrupted);
    expect(interrupted.runToken, isNull);
    final resumed = jobs.claim(
      jobType: queued.jobType,
      leaseDuration: const Duration(minutes: 1),
    );
    expect(resumed, isNotNull);
    expect(resumed!.jobId, queued.id);
  });

  test('checkpoint payload cannot erase a concurrent stop request', () {
    final jobs = repository();
    final job = jobs.enqueue(jobType: 'migration', phase: 'backup');
    final lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 1),
    )!;
    const stalePayload = '{"backup":{"sha256":"verified"}}';
    jobs.requestStop(job.id);
    jobs.commitBatch(
      lease: lease,
      phase: 'backup_complete',
      completedUnits: 0,
      totalUnits: null,
      lastProcessedRowId: 0,
      statusMessage: 'Backup verified.',
      payloadJson: stalePayload,
      apply: (_) {},
    );
    expect(jobs.stopRequested(lease), isTrue);
    expect(jobs.read(job.id)!.payloadJson, contains('verified'));
  });

  test('atomic attempt displaced by another job is failed on retry', () {
    final jobs = repository();
    final atomic = jobs.enqueue(jobType: 'migration', phase: 'build_indexes');
    jobs.claim(
      jobType: atomic.jobType,
      leaseDuration: const Duration(seconds: 30),
    );
    now = now.add(const Duration(minutes: 1));
    final other = jobs.enqueue(jobType: 'optimize', phase: 'optimize');
    final otherLease = jobs.claim(
      jobType: other.jobType,
      leaseDuration: const Duration(minutes: 1),
    )!;
    expect(jobs.read(atomic.id)!.state, MaintenanceJobState.interrupted);
    jobs.markSucceeded(
      otherLease,
      phase: 'complete',
      statusMessage: 'Complete.',
    );
    final retry = jobs.claim(
      jobType: atomic.jobType,
      leaseDuration: const Duration(minutes: 1),
      atomicPhases: const {'build_indexes'},
    )!;
    expect(retry.jobId, isNot(atomic.id));
    expect(jobs.read(atomic.id)!.state, MaintenanceJobState.failed);
  });

  test('retrying failed migration preserves its committed checkpoint', () {
    final jobs = repository();
    final job = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'preflight',
    );
    final lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 1),
    )!;
    jobs.commitBatch(
      lease: lease,
      phase: 'copy_events',
      completedUnits: 512,
      totalUnits: 1024,
      lastProcessedRowId: 900,
      statusMessage: 'Copied batch.',
      payloadJson: '{"backup":{"path":"verified.sqlite"}}',
      apply: (_) {},
    );
    jobs.markFailed(
      lease,
      phase: 'copy_events',
      errorMessage: 'Temporary write failure.',
    );
    final retry = jobs.enqueue(jobType: job.jobType, phase: 'preflight');
    expect(retry.id, isNot(job.id));
    expect(retry.state, MaintenanceJobState.pending);
    expect(retry.phase, 'copy_events');
    expect(retry.completedUnits, 512);
    expect(retry.lastProcessedRowId, 900);
    expect(retry.totalUnits, 1024);
    expect(retry.payloadJson, contains('verified.sqlite'));
  });
}
