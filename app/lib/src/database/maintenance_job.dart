import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'database_connection.dart';

enum MaintenanceJobState {
  pending,
  running,
  interrupted,
  succeeded,
  failed;

  static MaintenanceJobState parse(String value) => values.singleWhere(
    (state) => state.name == value,
    orElse: () => throw StateError('Unknown maintenance job state: $value'),
  );
}

final class MaintenanceJobRecord {
  const MaintenanceJobRecord({
    required this.id,
    required this.jobType,
    required this.databaseGenerationId,
    required this.state,
    required this.phase,
    required this.completedUnits,
    required this.totalUnits,
    required this.lastProcessedRowId,
    required this.statusMessage,
    required this.runToken,
    required this.ownerProcessId,
    required this.heartbeatAtUtc,
    required this.leaseExpiresAtUtc,
    required this.attemptCount,
    required this.startedAtUtc,
    required this.updatedAtUtc,
    required this.finishedAtUtc,
    required this.errorMessage,
    required this.payloadJson,
    required this.createdAtUtc,
  });

  final int id;
  final String jobType;
  final int? databaseGenerationId;
  final MaintenanceJobState state;
  final String phase;
  final int completedUnits;
  final int? totalUnits;
  final int lastProcessedRowId;
  final String? statusMessage;
  final String? runToken;
  final int? ownerProcessId;
  final DateTime? heartbeatAtUtc;
  final DateTime? leaseExpiresAtUtc;
  final int attemptCount;
  final DateTime? startedAtUtc;
  final DateTime updatedAtUtc;
  final DateTime? finishedAtUtc;
  final String? errorMessage;
  final String? payloadJson;
  final DateTime createdAtUtc;
}

final class MaintenanceJobLease {
  const MaintenanceJobLease({
    required this.jobId,
    required this.runToken,
    required this.leaseDuration,
  });

  final int jobId;
  final String runToken;
  final Duration leaseDuration;
}

final class MaintenanceScheduleRecord {
  const MaintenanceScheduleRecord({
    required this.jobType,
    required this.enabled,
    required this.intervalSeconds,
    this.lastAttemptAtUtc,
    this.lastSuccessAtUtc,
    this.nextDueAtUtc,
    this.retryCount = 0,
    this.lastError,
    this.lastWarning,
  });

  MaintenanceScheduleRecord._(Row row, {String? warning})
    : jobType = row['job_type'] as String,
      enabled = row['enabled'] == 1,
      intervalSeconds = row['interval_seconds'] as int,
      lastAttemptAtUtc = _date(row['last_attempt_at_utc']),
      lastSuccessAtUtc = _date(row['last_success_at_utc']),
      nextDueAtUtc = _date(row['next_due_at_utc']),
      retryCount = row['retry_count'] as int,
      lastError = row['last_error'] as String?,
      lastWarning = warning;

  final String jobType;
  final bool enabled;
  final int intervalSeconds;
  final DateTime? lastAttemptAtUtc;
  final DateTime? lastSuccessAtUtc;
  final DateTime? nextDueAtUtc;
  final int retryCount;
  final String? lastError;

  /// A problem that did not fail the job, such as an unreachable optional
  /// hub while the local OpenRouter fallback succeeded. Fixed text only.
  final String? lastWarning;
}

final class StaleMaintenanceLeaseException implements Exception {
  const StaleMaintenanceLeaseException(this.jobId);

  final int jobId;

  @override
  String toString() =>
      'Maintenance job $jobId is no longer owned by this worker.';
}

typedef MaintenanceTokenFactory = String Function();
typedef MaintenanceBatchApply = void Function(Database transaction);

final class MaintenanceJobRepository {
  MaintenanceJobRepository(
    this.db, {
    DateTime Function()? clock,
    MaintenanceTokenFactory? tokenFactory,
    double Function()? retryJitter,
    int? ownerProcessId,
  }) : _clock = clock ?? DateTime.now,
       _tokenFactory = tokenFactory ?? _newRunToken,
       _retryJitter = retryJitter ?? Random().nextDouble,
       _ownerProcessId = ownerProcessId ?? pid;

  final Database db;
  final DateTime Function() _clock;
  final MaintenanceTokenFactory _tokenFactory;
  final double Function() _retryJitter;
  final int _ownerProcessId;

  MaintenanceScheduleRecord? readSchedule(String jobType) {
    _validateScheduleType(jobType);
    final rows = db.select(
      'select * from maintenance_schedules where job_type = ?',
      [jobType],
    );
    return rows.isEmpty
        ? null
        : MaintenanceScheduleRecord._(rows.single, warning: _warning(jobType));
  }

  List<MaintenanceScheduleRecord> schedules() => [
    for (final row in db.select(
      "select * from maintenance_schedules where job_type in ('openrouter_price_refresh', 'database_optimize') order by job_type",
    ))
      MaintenanceScheduleRecord._(
        row,
        warning: _warning(row['job_type'] as String),
      ),
  ];

  MaintenanceScheduleRecord configureSchedule({
    required String jobType,
    required bool enabled,
    required int intervalSeconds,
    bool utcSlots = false,
  }) {
    _validateScheduleType(jobType);
    if (intervalSeconds <= 0) {
      throw ArgumentError.value(intervalSeconds, 'intervalSeconds');
    }
    return _scheduleTransaction(() {
      final previous = readSchedule(jobType);
      final stamp = _timestamp(_clock());
      final due =
          previous != null &&
              previous.retryCount == 0 &&
              previous.lastSuccessAtUtc != null
          ? _timestamp(
              utcSlots
                  ? nextPricingUtcSlot(previous.lastSuccessAtUtc!)
                  : previous.lastSuccessAtUtc!.add(
                      Duration(seconds: intervalSeconds),
                    ),
            )
          : previous?.nextDueAtUtc == null
          ? stamp
          : _timestamp(previous!.nextDueAtUtc!);
      db.execute(
        '''
      insert into maintenance_schedules (job_type, enabled, interval_seconds, next_due_at_utc, updated_at_utc)
      values (?, ?, ?, ?, ?)
      on conflict(job_type) do update set enabled = excluded.enabled,
        interval_seconds = excluded.interval_seconds, next_due_at_utc = excluded.next_due_at_utc,
        updated_at_utc = excluded.updated_at_utc
    ''',
        [jobType, enabled ? 1 : 0, intervalSeconds, due, stamp],
      );
      return readSchedule(jobType)!;
    });
  }

  T _scheduleTransaction<T>(T Function() action) {
    db.execute('begin immediate');
    try {
      final result = action();
      db.execute('commit');
      return result;
    } on Object {
      if (!db.autocommit) db.execute('rollback');
      rethrow;
    }
  }

  /// The application writer queue owns in-flight/coalescing decisions. These
  /// methods persist an attempt, not a second lease or scheduler.
  MaintenanceScheduleRecord recordScheduleAttempt(
    String jobType, {
    bool manual = false,
  }) => _scheduleTransaction(() {
    final schedule = readSchedule(jobType);
    if (schedule == null) throw StateError('Schedule has not been configured.');
    if (!manual && !schedule.enabled) {
      throw StateError('Automatic schedule is disabled.');
    }
    final stamp = _timestamp(_clock());
    db.execute(
      '''
        update maintenance_schedules set last_attempt_at_utc = ?, updated_at_utc = ?,
          retry_count = case when ? then 0 else retry_count end,
          next_due_at_utc = case when ? then ? else next_due_at_utc end
        where job_type = ?
      ''',
      [stamp, stamp, manual ? 1 : 0, manual ? 1 : 0, stamp, jobType],
    );
    return readSchedule(jobType)!;
  });

  /// Arbitrary [errorMessage] text is deliberately discarded: transport errors
  /// may contain credentials or local paths. Only fixed job-specific text is stored.
  /// [warning] must likewise be fixed text chosen by the caller.
  /// The caller serializes completion with configuration and the next attempt.
  MaintenanceScheduleRecord completeScheduleAttempt(
    String jobType, {
    required bool succeeded,
    String? errorMessage,
    String? warning,
    Duration? retryAfter,
    bool utcSlots = false,
    DateTime? successfulObservationAtUtc,
  }) => _scheduleTransaction(() {
    final schedule = readSchedule(jobType);
    if (schedule?.lastAttemptAtUtc == null) {
      throw StateError('Schedule attempt has not started.');
    }
    final now = _clock().toUtc();
    final successAt = successfulObservationAtUtc?.toUtc() ?? now;
    final retryCount = succeeded ? 0 : schedule!.retryCount + 1;
    Duration delay;
    if (succeeded) {
      final next = utcSlots
          ? nextPricingUtcSlot(successAt)
          : successAt.add(Duration(seconds: schedule!.intervalSeconds));
      delay = next.isAfter(now) ? next.difference(now) : Duration.zero;
    } else {
      const minutes = [15, 60, 240, 720, 1440];
      final base = Duration(
        minutes: minutes[min(retryCount - 1, minutes.length - 1)],
      ).inMilliseconds;
      final sample = _retryJitter();
      if (!sample.isFinite || sample < 0 || sample > 1) {
        throw StateError('Retry jitter must be between zero and one.');
      }
      const cap = Duration(hours: 24);
      final jittered = base + 1 + (base * 0.1 * sample).floor();
      final requested = max(0, retryAfter?.inMilliseconds ?? 0);
      delay = Duration(
        milliseconds: min(cap.inMilliseconds, max(jittered, requested)),
      );
    }
    db.execute(
      '''
      update maintenance_schedules set last_success_at_utc = ?, next_due_at_utc = ?,
        retry_count = ?, last_error = ?, updated_at_utc = ? where job_type = ?
    ''',
      [
        succeeded
            ? _timestamp(successAt)
            : schedule!.lastSuccessAtUtc == null
            ? null
            : _timestamp(schedule.lastSuccessAtUtc!),
        _timestamp(now.add(delay)),
        retryCount,
        succeeded
            ? null
            : jobType == 'openrouter_price_refresh'
            ? 'OpenRouter price refresh failed.'
            : 'Database optimization failed.',
        _timestamp(now),
        jobType,
      ],
    );
    final key = _warningKey(jobType);
    if (warning == null) {
      db.execute('delete from app_metadata where key = ?', [key]);
    } else {
      db.execute(
        '''insert into app_metadata(key, value, updated_at_utc) values (?, ?, ?)
        on conflict(key) do update set value = excluded.value,
          updated_at_utc = excluded.updated_at_utc''',
        [key, warning, _timestamp(now)],
      );
    }
    return readSchedule(jobType)!;
  });

  static String _warningKey(String jobType) => 'schedule_warning.$jobType';

  String? _warning(String jobType) {
    final rows = db.select('select value from app_metadata where key = ?', [
      _warningKey(jobType),
    ]);
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  MaintenanceJobRecord enqueue({
    required String jobType,
    required String phase,
    int? databaseGenerationId,
    int? totalUnits,
    String? statusMessage,
    String? payloadJson,
  }) {
    final normalizedType = jobType.trim();
    final normalizedPhase = phase.trim();
    if (normalizedType.isEmpty || normalizedPhase.isEmpty) {
      throw ArgumentError('Maintenance job type and phase must not be empty.');
    }
    db.execute('begin immediate');
    try {
      final existing = _activeForType(normalizedType);
      if (existing != null) {
        db.execute('commit');
        return existing;
      }
      final latest = latestForType(normalizedType);
      if (latest != null &&
          latest.state == MaintenanceJobState.interrupted &&
          latest.databaseGenerationId == databaseGenerationId) {
        db.execute('commit');
        return latest;
      }
      final failed =
          latest?.state == MaintenanceJobState.failed &&
              latest?.databaseGenerationId == databaseGenerationId
          ? latest
          : null;
      final now = _timestamp(_clock());
      db.execute(
        '''
      insert into maintenance_jobs (
        job_type, database_generation_id, state, phase, total_units,
        status_message, updated_at_utc, payload_json, created_at_utc,
        completed_units, last_processed_rowid
      ) values (?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
        [
          normalizedType,
          databaseGenerationId,
          failed?.phase ?? normalizedPhase,
          failed?.totalUnits ?? totalUnits,
          statusMessage,
          now,
          failed?.payloadJson ?? payloadJson,
          now,
          failed?.completedUnits ?? 0,
          failed?.lastProcessedRowId ?? 0,
        ],
      );
      final queued = read(db.lastInsertRowId)!;
      db.execute('commit');
      return queued;
    } on Object {
      db.execute('rollback');
      rethrow;
    }
  }

  MaintenanceJobLease? claim({
    required String jobType,
    required Duration leaseDuration,
    Set<String> atomicPhases = const {},
  }) {
    if (leaseDuration <= Duration.zero) {
      throw ArgumentError.value(
        leaseDuration,
        'leaseDuration',
        'must be greater than zero',
      );
    }
    final normalizedType = jobType.trim();
    var transactionOpen = false;
    try {
      db.execute('begin immediate');
      transactionOpen = true;
      final candidates = db.select(
        '''
        select *
        from maintenance_jobs
        where job_type = ?
          and state in ('pending', 'running', 'interrupted')
        order by id desc
        limit 1
        ''',
        [normalizedType],
      );
      if (candidates.isEmpty) {
        db.execute('commit');
        transactionOpen = false;
        return null;
      }
      var current = _record(candidates.single);
      final now = _clock().toUtc();
      final otherRunning = db.select(
        '''
        select * from maintenance_jobs
        where state = 'running' and id <> ?
        order by id
        ''',
        [current.id],
      );
      for (final row in otherRunning) {
        final other = _record(row);
        if (other.leaseExpiresAtUtc!.isAfter(now)) {
          db.execute('commit');
          transactionOpen = false;
          return null;
        }
        db.execute(
          '''
          update maintenance_jobs
          set state = 'interrupted',
              status_message = 'Worker lease expired before another job started.',
              run_token = null, owner_process_id = null,
              heartbeat_at_utc = null, lease_expires_at_utc = null,
              updated_at_utc = ?, finished_at_utc = ?
          where id = ? and state = 'running'
          ''',
          [_timestamp(now), _timestamp(now), other.id],
        );
      }
      if (current.state == MaintenanceJobState.running &&
          current.leaseExpiresAtUtc != null &&
          current.leaseExpiresAtUtc!.isAfter(now)) {
        db.execute('commit');
        transactionOpen = false;
        return null;
      }
      if ((current.state == MaintenanceJobState.running ||
              current.state == MaintenanceJobState.interrupted) &&
          atomicPhases.contains(current.phase)) {
        final timestamp = _timestamp(now);
        db.execute(
          '''
          update maintenance_jobs
          set state = 'failed',
              status_message = 'Atomic maintenance phase was interrupted.',
              run_token = null, owner_process_id = null,
              heartbeat_at_utc = null, lease_expires_at_utc = null,
              updated_at_utc = ?, finished_at_utc = ?,
              error_message = 'Worker lease expired during an atomic phase.'
          where id = ? and state in ('running', 'interrupted')
          ''',
          [timestamp, timestamp, current.id],
        );
        db.execute(
          '''
          insert into maintenance_jobs (
            job_type, database_generation_id, state, phase,
            completed_units, total_units, last_processed_rowid,
            status_message, payload_json, updated_at_utc, created_at_utc
          ) values (?, ?, 'pending', ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            current.jobType,
            current.databaseGenerationId,
            current.phase,
            current.completedUnits,
            current.totalUnits,
            current.lastProcessedRowId,
            'Retrying the interrupted atomic maintenance phase.',
            current.payloadJson,
            timestamp,
            timestamp,
          ],
        );
        current = read(db.lastInsertRowId)!;
      }
      final token = _tokenFactory();
      final leaseExpiry = now.add(leaseDuration);
      final payloadWithoutStop = _payloadWithStop(
        current.payloadJson,
        stopRequested: false,
      );
      db.execute(
        '''
        update maintenance_jobs
        set state = 'running',
            run_token = ?,
            owner_process_id = ?,
            heartbeat_at_utc = ?,
            lease_expires_at_utc = ?,
            attempt_count = attempt_count + 1,
            started_at_utc = coalesce(started_at_utc, ?),
            updated_at_utc = ?,
            finished_at_utc = null,
            error_message = null,
            payload_json = ?
        where id = ?
        ''',
        [
          token,
          _ownerProcessId,
          _timestamp(now),
          _timestamp(leaseExpiry),
          _timestamp(now),
          _timestamp(now),
          payloadWithoutStop,
          current.id,
        ],
      );
      db.execute('commit');
      transactionOpen = false;
      return MaintenanceJobLease(
        jobId: current.id,
        runToken: token,
        leaseDuration: leaseDuration,
      );
    } on Object {
      if (transactionOpen) {
        db.execute('rollback');
      }
      rethrow;
    }
  }

  void commitBatch({
    required MaintenanceJobLease lease,
    required String phase,
    required int completedUnits,
    required int? totalUnits,
    required int lastProcessedRowId,
    required String statusMessage,
    required MaintenanceBatchApply apply,
    String? payloadJson,
  }) {
    var transactionOpen = false;
    try {
      db.execute('begin immediate');
      transactionOpen = true;
      final current = _requireLease(lease);
      if (completedUnits < current.completedUnits ||
          lastProcessedRowId < current.lastProcessedRowId) {
        throw StateError('Maintenance checkpoints must be monotonic.');
      }
      if (totalUnits != null && completedUnits > totalUnits) {
        throw StateError('Completed work exceeds total work.');
      }
      apply(db);
      final now = _clock().toUtc();
      db.execute(
        '''
        update maintenance_jobs
        set phase = ?, completed_units = ?, total_units = ?,
            last_processed_rowid = ?, status_message = ?,
            heartbeat_at_utc = ?, lease_expires_at_utc = ?, updated_at_utc = ?,
            payload_json = coalesce(?, payload_json)
        where id = ? and state = 'running' and run_token = ?
        ''',
        [
          phase,
          completedUnits,
          totalUnits,
          lastProcessedRowId,
          statusMessage,
          _timestamp(now),
          _timestamp(now.add(lease.leaseDuration)),
          _timestamp(now),
          payloadJson == null
              ? null
              : _payloadWithStop(
                  payloadJson,
                  stopRequested:
                      _payloadStopRequested(current.payloadJson) ||
                      _payloadStopRequested(payloadJson),
                ),
          lease.jobId,
          lease.runToken,
        ],
      );
      if (_changes() != 1) {
        throw StaleMaintenanceLeaseException(lease.jobId);
      }
      db.execute('commit');
      transactionOpen = false;
    } on Object {
      // SQLITE_INTERRUPT can roll back the whole transaction itself.
      if (transactionOpen && !db.autocommit) {
        db.execute('rollback');
      }
      rethrow;
    }
  }

  void renew(MaintenanceJobLease lease) {
    final now = _clock().toUtc();
    db.execute(
      '''
      update maintenance_jobs
      set heartbeat_at_utc = ?, lease_expires_at_utc = ?, updated_at_utc = ?
      where id = ? and state = 'running' and run_token = ?
      ''',
      [
        _timestamp(now),
        _timestamp(now.add(lease.leaseDuration)),
        _timestamp(now),
        lease.jobId,
        lease.runToken,
      ],
    );
    if (_changes() != 1) {
      throw StaleMaintenanceLeaseException(lease.jobId);
    }
  }

  bool requestStop(int jobId, {MaintenanceJobLease? lease}) {
    if (lease != null && lease.jobId != jobId) {
      throw ArgumentError('Stop lease belongs to a different job.');
    }
    var transactionOpen = false;
    try {
      db.execute('begin immediate');
      transactionOpen = true;
      final rows = db.select(
        '''
        select payload_json from maintenance_jobs
        where id = ? and state = 'running'
          and (? is null or run_token = ?)
        ''',
        [jobId, lease?.runToken, lease?.runToken],
      );
      if (rows.isEmpty && lease != null) {
        throw StaleMaintenanceLeaseException(jobId);
      }
      if (rows.isEmpty || _payloadStopRequested(rows.single['payload_json'])) {
        db.execute('commit');
        transactionOpen = false;
        return false;
      }
      db.execute(
        '''
        update maintenance_jobs
        set payload_json = ?,
            status_message = 'Stopping after the current atomic operation.',
            updated_at_utc = ?
        where id = ? and state = 'running'
        ''',
        [
          _payloadWithStop(
            rows.single['payload_json'] as String?,
            stopRequested: true,
          ),
          _timestamp(_clock()),
          jobId,
        ],
      );
      db.execute('commit');
      transactionOpen = false;
      return true;
    } on Object {
      if (transactionOpen) {
        db.execute('rollback');
      }
      rethrow;
    }
  }

  bool stopRequested(MaintenanceJobLease lease) {
    final rows = db.select(
      '''
      select payload_json
      from maintenance_jobs
      where id = ? and state = 'running' and run_token = ?
      ''',
      [lease.jobId, lease.runToken],
    );
    if (rows.isEmpty) {
      throw StaleMaintenanceLeaseException(lease.jobId);
    }
    return _payloadStopRequested(rows.single['payload_json']);
  }

  void markInterrupted(
    MaintenanceJobLease lease, {
    required String statusMessage,
  }) => _finish(
    lease,
    state: MaintenanceJobState.interrupted,
    statusMessage: statusMessage,
  );

  void markSucceeded(
    MaintenanceJobLease lease, {
    required String phase,
    required String statusMessage,
  }) => _finish(
    lease,
    state: MaintenanceJobState.succeeded,
    phase: phase,
    statusMessage: statusMessage,
  );

  void markFailed(
    MaintenanceJobLease lease, {
    required String phase,
    required String errorMessage,
  }) => _finish(
    lease,
    state: MaintenanceJobState.failed,
    phase: phase,
    statusMessage: 'Database maintenance failed.',
    errorMessage: errorMessage,
  );

  MaintenanceJobRecord? read(int jobId) {
    final rows = db.select('select * from maintenance_jobs where id = ?', [
      jobId,
    ]);
    return rows.isEmpty ? null : _record(rows.single);
  }

  MaintenanceJobRecord? latestForType(String jobType) {
    final rows = db.select(
      '''
      select * from maintenance_jobs
      where job_type = ?
      order by id desc
      limit 1
      ''',
      [jobType],
    );
    return rows.isEmpty ? null : _record(rows.single);
  }

  MaintenanceJobRecord? _activeForType(String jobType) {
    final rows = db.select(
      '''
      select * from maintenance_jobs
      where job_type = ? and state in ('pending', 'running')
      order by id desc
      limit 1
      ''',
      [jobType],
    );
    return rows.isEmpty ? null : _record(rows.single);
  }

  MaintenanceJobRecord _requireLease(MaintenanceJobLease lease) {
    final rows = db.select(
      '''
      select * from maintenance_jobs
      where id = ? and state = 'running' and run_token = ?
      ''',
      [lease.jobId, lease.runToken],
    );
    if (rows.isEmpty) {
      throw StaleMaintenanceLeaseException(lease.jobId);
    }
    return _record(rows.single);
  }

  void _finish(
    MaintenanceJobLease lease, {
    required MaintenanceJobState state,
    required String statusMessage,
    String? phase,
    String? errorMessage,
  }) {
    if (state == MaintenanceJobState.pending ||
        state == MaintenanceJobState.running) {
      throw ArgumentError.value(state, 'state', 'must be a terminal boundary');
    }
    final now = _timestamp(_clock());
    db.execute(
      '''
      update maintenance_jobs
      set state = ?, phase = coalesce(?, phase), status_message = ?,
          run_token = null, owner_process_id = null,
          heartbeat_at_utc = null, lease_expires_at_utc = null,
          updated_at_utc = ?, finished_at_utc = ?, error_message = ?
      where id = ? and state = 'running' and run_token = ?
      ''',
      [
        state.name,
        phase,
        statusMessage,
        now,
        now,
        errorMessage,
        lease.jobId,
        lease.runToken,
      ],
    );
    if (_changes() != 1) {
      throw StaleMaintenanceLeaseException(lease.jobId);
    }
  }

  int _changes() => db.select('select changes()').single.values.single as int;
}

MaintenanceJobRecord _record(Row row) => MaintenanceJobRecord(
  id: row['id'] as int,
  jobType: row['job_type'] as String,
  databaseGenerationId: row['database_generation_id'] as int?,
  state: MaintenanceJobState.parse(row['state'] as String),
  phase: row['phase'] as String,
  completedUnits: row['completed_units'] as int,
  totalUnits: row['total_units'] as int?,
  lastProcessedRowId: row['last_processed_rowid'] as int,
  statusMessage: row['status_message'] as String?,
  runToken: row['run_token'] as String?,
  ownerProcessId: row['owner_process_id'] as int?,
  heartbeatAtUtc: _date(row['heartbeat_at_utc']),
  leaseExpiresAtUtc: _date(row['lease_expires_at_utc']),
  attemptCount: row['attempt_count'] as int,
  startedAtUtc: _date(row['started_at_utc']),
  updatedAtUtc: DateTime.parse(row['updated_at_utc'] as String).toUtc(),
  finishedAtUtc: _date(row['finished_at_utc']),
  errorMessage: row['error_message'] as String?,
  payloadJson: row['payload_json'] as String?,
  createdAtUtc: DateTime.parse(row['created_at_utc'] as String).toUtc(),
);

DateTime? _date(Object? value) =>
    value == null ? null : DateTime.parse(value as String).toUtc();

void _validateScheduleType(String jobType) {
  if (jobType != 'openrouter_price_refresh' && jobType != 'database_optimize') {
    throw ArgumentError.value(jobType, 'jobType', 'Unknown scheduled job.');
  }
}

String _timestamp(DateTime value) => value.toUtc().toIso8601String();

String _newRunToken() {
  final bytes = List<int>.generate(24, (_) => Random.secure().nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

bool _payloadStopRequested(Object? payloadJson) {
  if (payloadJson is! String || payloadJson.trim().isEmpty) {
    return false;
  }
  final decoded = jsonDecode(payloadJson);
  return decoded is Map<String, Object?> && decoded['stop_requested'] == true;
}

String? _payloadWithStop(String? payloadJson, {required bool stopRequested}) {
  final payload = <String, Object?>{};
  if (payloadJson != null && payloadJson.trim().isNotEmpty) {
    final decoded = jsonDecode(payloadJson);
    if (decoded is! Map<String, Object?>) {
      throw StateError('Maintenance job payload must be a JSON object.');
    }
    payload.addAll(decoded);
  }
  if (stopRequested) {
    payload['stop_requested'] = true;
  } else {
    payload.remove('stop_requested');
  }
  return payload.isEmpty ? null : jsonEncode(payload);
}

/// Next strictly future UTC slot, independent of local timezone and DST.
DateTime nextPricingUtcSlot(DateTime observation) {
  final utc = observation.toUtc();
  return DateTime.utc(utc.year, utc.month, utc.day, (utc.hour ~/ 6 + 1) * 6);
}
