import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

void main() {
  late Directory temp;
  late File databaseFile;
  late Database db;
  late DateTime now;

  setUp(() async {
    now = DateTime.utc(2026, 9, 7, 12);
    temp = await Directory.systemTemp.createTemp('csv_schedule_');
    databaseFile = File('${temp.path}/viewer.sqlite');
    final startup = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);
    db = openFileBackedDatabase(databaseFile);
    db.execute('delete from maintenance_schedules');
  });
  tearDown(() async {
    db.close();
    await temp.delete(recursive: true);
  });

  MaintenanceJobRepository repository() =>
      MaintenanceJobRepository(db, clock: () => now);

  test('each UTC slot advances only after its exact boundary', () {
    for (final monthDay in [(3, 29), (10, 25), (12, 31)]) {
      for (final hour in [0, 6, 12, 18]) {
        final slot = DateTime.utc(2026, monthDay.$1, monthDay.$2, hour);
        expect(
          nextPricingUtcSlot(slot.subtract(const Duration(microseconds: 1))),
          slot,
        );
        expect(nextPricingUtcSlot(slot), slot.add(const Duration(hours: 6)));
        expect(
          nextPricingUtcSlot(slot.add(const Duration(microseconds: 1))),
          slot.add(const Duration(hours: 6)),
        );
      }
    }
  });

  test('a download observed before a slot catches up after delayed apply', () {
    const type = 'openrouter_price_refresh';
    final jobs = repository();
    now = DateTime.utc(2026, 9, 7, 5, 58);
    jobs.configureSchedule(
      jobType: type,
      enabled: true,
      intervalSeconds: 21600,
      utcSlots: true,
    );
    jobs.recordScheduleAttempt(type);

    final observed = DateTime.utc(2026, 9, 7, 5, 59);
    now = DateTime.utc(2026, 9, 7, 6, 1);
    final completed = jobs.completeScheduleAttempt(
      type,
      succeeded: true,
      utcSlots: true,
      successfulObservationAtUtc: observed,
    );

    expect(completed.lastSuccessAtUtc, observed);
    expect(completed.nextDueAtUtc, now);
  });

  test(
    'UTC slots ignore local offsets and coalesce missed slots after restart',
    () {
      const type = 'openrouter_price_refresh';
      final jobs = repository();
      for (final hour in [0, 6, 12, 18, 23]) {
        now = DateTime.utc(2026, 3, 29, hour, 17);
        jobs.configureSchedule(
          jobType: type,
          enabled: true,
          intervalSeconds: 21600,
          utcSlots: true,
        );
        jobs.recordScheduleAttempt(type);
        final done = jobs.completeScheduleAttempt(
          type,
          succeeded: true,
          utcSlots: true,
        );
        expect(done.lastSuccessAtUtc, now);
        expect(
          done.nextDueAtUtc,
          DateTime.utc(2026, 3, 29, (hour ~/ 6 + 1) * 6),
        );
      }
      now = DateTime.parse('2026-10-25T08:00:00+02:00');
      jobs.recordScheduleAttempt(type);
      expect(
        jobs
            .completeScheduleAttempt(type, succeeded: true, utcSlots: true)
            .nextDueAtUtc,
        DateTime.utc(2026, 10, 25, 12),
      );
      now = DateTime.utc(2026, 11, 1, 14, 13);
      db.close();
      db = openFileBackedDatabase(databaseFile);
      final restarted = repository().configureSchedule(
        jobType: type,
        enabled: true,
        intervalSeconds: 21600,
        utcSlots: true,
      );
      expect(restarted.nextDueAtUtc!.isBefore(now), isTrue);
      repository().recordScheduleAttempt(type);
      final caughtUp = repository().completeScheduleAttempt(
        type,
        succeeded: true,
        utcSlots: true,
      );
      expect(caughtUp.nextDueAtUtc, DateTime.utc(2026, 11, 1, 18));
      expect(caughtUp.lastSuccessAtUtc, now);
      repository().recordScheduleAttempt(type);
      final failed = repository().completeScheduleAttempt(
        type,
        succeeded: false,
        utcSlots: true,
        retryAfter: const Duration(hours: 2),
      );
      expect(failed.nextDueAtUtc, now.add(const Duration(hours: 2)));
      expect(
        repository()
            .configureSchedule(
              jobType: type,
              enabled: true,
              intervalSeconds: 21600,
              utcSlots: true,
            )
            .nextDueAtUtc,
        failed.nextDueAtUtc,
      );
    },
  );

  test(
    'configures only app schedules and retains unchanged due times on reopen',
    () {
      final jobs = repository();
      expect(jobs.readSchedule('openrouter_price_refresh'), isNull);
      final first = jobs.configureSchedule(
        jobType: 'openrouter_price_refresh',
        enabled: true,
        intervalSeconds: 86400,
      );
      expect(first.enabled, isTrue);
      expect(first.intervalSeconds, 86400);
      expect(first.nextDueAtUtc, now);
      expect(first.lastAttemptAtUtc, isNull);
      expect(first.lastSuccessAtUtc, isNull);
      expect(first.retryCount, 0);
      expect(first.lastError, isNull);
      now = now.add(const Duration(days: 8));
      db.close();
      db = openFileBackedDatabase(databaseFile);
      final reopened = repository().configureSchedule(
        jobType: first.jobType,
        enabled: false,
        intervalSeconds: 86400,
      );
      expect(reopened.enabled, isFalse);
      expect(reopened.nextDueAtUtc, first.nextDueAtUtc);
      expect(repository().schedules().map((row) => row.jobType), [
        'openrouter_price_refresh',
      ]);
      for (final type in ['', 'scan', ' openrouter_price_refresh ']) {
        expect(
          () => jobs.configureSchedule(
            jobType: type,
            enabled: true,
            intervalSeconds: 1,
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => repository().configureSchedule(
          jobType: first.jobType,
          enabled: true,
          intervalSeconds: 0,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'interval changes rebase success cadence without postponing an active retry',
    () {
      final jobs = repository();
      jobs.configureSchedule(
        jobType: 'openrouter_price_refresh',
        enabled: true,
        intervalSeconds: 86400,
      );
      db.execute('''
      update maintenance_schedules set last_success_at_utc = '2026-09-06T12:00:00Z',
        next_due_at_utc = '2026-09-07T12:00:00Z'
    ''');
      final changed = jobs.configureSchedule(
        jobType: 'openrouter_price_refresh',
        enabled: true,
        intervalSeconds: 172800,
      );
      expect(changed.nextDueAtUtc, DateTime.utc(2026, 9, 8, 12));
      db.execute('''
      update maintenance_schedules set retry_count = 2, last_error = 'Safe error',
        next_due_at_utc = '2026-09-07T13:00:00Z'
    ''');
      final retrying = jobs.configureSchedule(
        jobType: changed.jobType,
        enabled: false,
        intervalSeconds: 3600,
      );
      expect(retrying.nextDueAtUtc, DateTime.utc(2026, 9, 7, 13));
      expect(retrying.retryCount, 2);
      expect(retrying.lastError, 'Safe error');
      expect(retrying.lastSuccessAtUtc, DateTime.utc(2026, 9, 6, 12));
    },
  );

  test(
    'persisted retries honor Retry-After and manual reset without moving last success',
    () {
      MaintenanceJobRepository jobs() => MaintenanceJobRepository(
        db,
        clock: () => now,
        retryJitter: () => 0.5,
      );
      const type = 'openrouter_price_refresh';
      jobs().configureSchedule(
        jobType: type,
        enabled: true,
        intervalSeconds: 86400,
      );
      jobs().recordScheduleAttempt(type);
      final success = jobs().completeScheduleAttempt(type, succeeded: true);
      expect(success.lastSuccessAtUtc, now);
      expect(success.nextDueAtUtc, now.add(const Duration(days: 1)));
      final lastSuccess = now;
      now = now.add(const Duration(days: 8));
      for (final (index, minutes) in [15, 60, 240, 720, 1440, 1440].indexed) {
        jobs().recordScheduleAttempt(type);
        final failed = jobs().completeScheduleAttempt(
          type,
          succeeded: false,
          errorMessage: 'Bearer private-test-secret',
          retryAfter: index == 0 ? const Duration(hours: 2) : null,
        );
        expect(failed.retryCount, index + 1);
        expect(failed.lastSuccessAtUtc, lastSuccess);
        expect(failed.lastAttemptAtUtc, now);
        expect(failed.lastError, 'OpenRouter price refresh failed.');
        final delay = failed.nextDueAtUtc!.difference(now);
        if (index == 0) {
          expect(delay, const Duration(hours: 2));
        } else if (minutes == 1440) {
          expect(delay, const Duration(hours: 24));
        } else {
          expect(delay, greaterThan(Duration(minutes: minutes)));
          expect(
            delay,
            lessThanOrEqualTo(
              Duration(minutes: minutes * 11 ~/ 10, seconds: 1),
            ),
          );
        }
        now = failed.nextDueAtUtc!;
        db.close();
        db = openFileBackedDatabase(databaseFile);
        expect(jobs().readSchedule(type)!.retryCount, index + 1);
      }
      final manual = jobs().recordScheduleAttempt(type, manual: true);
      expect(manual.retryCount, 0);
      expect(manual.lastSuccessAtUtc, lastSuccess);
      final capped = jobs().completeScheduleAttempt(
        type,
        succeeded: false,
        retryAfter: const Duration(days: 10),
      );
      expect(capped.nextDueAtUtc, now.add(const Duration(hours: 24)));
      expect(capped.retryCount, 1);
      jobs().recordScheduleAttempt(type, manual: true);
      final recovered = jobs().completeScheduleAttempt(type, succeeded: true);
      expect(recovered.lastSuccessAtUtc, now);
      expect(recovered.nextDueAtUtc, now.add(const Duration(days: 1)));
      expect(recovered.retryCount, 0);
      expect(recovered.lastError, isNull);
    },
  );

  test(
    'disabled schedules preserve history and failed state updates roll back',
    () {
      final jobs = repository();
      const type = 'database_optimize';
      jobs.configureSchedule(
        jobType: type,
        enabled: false,
        intervalSeconds: 604800,
      );
      expect(() => jobs.recordScheduleAttempt(type), throwsStateError);
      jobs.recordScheduleAttempt(type, manual: true);
      final before = db
          .select('select * from maintenance_schedules')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
      db.execute('''
      create trigger fail_schedule_update after update on maintenance_schedules
      begin select raise(abort, 'injected schedule failure'); end;
    ''');
      expect(
        () => jobs.completeScheduleAttempt(type, succeeded: true),
        throwsA(isA<SqliteException>()),
      );
      expect(
        db
            .select('select * from maintenance_schedules')
            .map((row) => Map<String, Object?>.from(row))
            .toList(),
        before,
      );
      expect(db.autocommit, isTrue);
      db.execute('drop trigger fail_schedule_update');
      final result = jobs.completeScheduleAttempt(
        type,
        succeeded: false,
        errorMessage: 'private-path-secret',
      );
      expect(result.enabled, isFalse);
      expect(result.lastError, 'Database optimization failed.');
      expect(
        result.nextDueAtUtc!.difference(now),
        greaterThan(const Duration(minutes: 15)),
      );
      expect(
        () => jobs.recordScheduleAttempt('openrouter_price_refresh'),
        throwsStateError,
      );
    },
  );
}
