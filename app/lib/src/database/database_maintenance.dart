import 'package:codex_sessions_viewer/src/platform/app_environment.dart';
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import 'package:sqlite3/sqlite3.dart' show sqlite3, SqliteException;

import '../third_party/sqlite_interrupt.g.dart' as native;
import '../config/app_settings.dart';
import '../scanner/resident_collector_client.dart';
import 'database_connection.dart';
import 'database_generation.dart';
import 'database_maintenance_cancelled.dart';
import 'maintenance_job.dart';
import 'startup_usage_migration.dart';

enum DatabaseMaintenanceState { running, interrupted, succeeded, failed }

final class DatabaseMaintenanceProgress {
  const DatabaseMaintenanceProgress({
    required this.state,
    required this.phase,
    required this.currentWork,
    required this.unitLabel,
    required this.completedUnits,
    required this.totalUnits,
    required this.ratePerSecond,
    required this.elapsed,
    required this.estimatedRemaining,
    required this.walBytes,
    this.errorMessage,
  });

  final DatabaseMaintenanceState state;
  final String phase;
  final String currentWork;
  final String unitLabel;
  final int completedUnits;
  final int? totalUnits;
  final double? ratePerSecond;
  final Duration elapsed;
  final Duration? estimatedRemaining;
  final int walBytes;
  final String? errorMessage;

  double? get fraction {
    final total = totalUnits;
    if (total == null || total <= 0) {
      return null;
    }
    return (completedUnits / total).clamp(0, 1).toDouble();
  }

  int? get percentage => fraction == null ? null : (fraction! * 100).floor();

  String get boundedAnnouncement {
    final stateLabel = switch (state) {
      DatabaseMaintenanceState.running => 'running',
      DatabaseMaintenanceState.interrupted => 'interrupted',
      DatabaseMaintenanceState.succeeded => 'complete',
      DatabaseMaintenanceState.failed => 'failed',
    };
    final percent = percentage;
    final milestone = percent == null
        ? ''
        : ', ${(percent ~/ 10) * 10} percent';
    return 'Database maintenance $stateLabel. $phase$milestone.';
  }
}

final class DatabaseMaintenanceResult {
  const DatabaseMaintenanceResult({required this.state, this.errorMessage});

  final DatabaseMaintenanceState state;
  final String? errorMessage;

  bool get succeeded => state == DatabaseMaintenanceState.succeeded;
}

final class DatabaseMaintenanceOperation {
  const DatabaseMaintenanceOperation({
    required this.result,
    required this.progress,
    required this.requestStop,
  });

  final Future<DatabaseMaintenanceResult> result;
  final Stream<DatabaseMaintenanceProgress> progress;
  final Future<void> Function() requestStop;
}

enum DatabaseMaintenanceWorkerOutcome { succeeded, interrupted }

/// Called by production startup before normal database writers are constructed.
Future<DatabaseMaintenanceOperation?> startPendingDatabaseMigration(
  File databaseFile, {
  DatabaseMaintenanceWorker? migrationWorker,
  PricingSettings? pricingSettings,
  Directory? sqlRoot,
  DatabaseMaintenanceCoordinator? coordinator,
}) async {
  if (migrationWorker == null) {
    return startUsageMigration(
      databaseFile,
      sqlRoot: sqlRoot,
      pricingSettings: pricingSettings,
      coordinator: coordinator,
    );
  }
  const jobType = 'usage_projection_migration';
  final db = openFileBackedDatabase(databaseFile, maintenanceWriter: true);
  MaintenanceJobRecord? job;
  try {
    final jobs = MaintenanceJobRepository(db);
    job = jobs.latestForType(jobType);
    if (job == null &&
        DatabaseGenerationRepository(
              db,
            ).activeGeneration().targetSchemaVersion <
            16) {
      // A crash may occur between creating the generation and enqueueing its
      // job. Reuse that inactive generation instead of creating another shadow.
      final building = db.select('''
        select id from database_generations
        where state = 'building' and target_schema_version = 16
        order by id limit 2
      ''');
      if (building.length > 1) {
        throw StateError(
          'Multiple inactive usage generations require recovery.',
        );
      }
      final generationId = building.isEmpty
          ? DatabaseGenerationRepository(db)
                .createBuilding(
                  sourceSchemaVersion: 15,
                  targetSchemaVersion: 16,
                  sourceFingerprint: 'pending-backup',
                )
                .id
          : building.single['id'] as int;
      job = jobs.enqueue(
        jobType: jobType,
        phase: 'preflight',
        databaseGenerationId: generationId,
        statusMessage: 'Preparing persisted usage migration.',
      );
    }
  } finally {
    db.close();
  }
  if (job == null || job.state == MaintenanceJobState.succeeded) return null;
  return (coordinator ?? DatabaseMaintenanceCoordinator(databaseFile)).start(
    jobType: jobType,
    initialPhase: job.phase,
    databaseGenerationId: job.databaseGenerationId,
    totalUnits: job.totalUnits,
    payloadJson: job.payloadJson,
    worker: migrationWorker,
    atomicPhases: const {'build_indexes', 'cutover'},
  );
}

typedef DatabaseMaintenanceWorker =
    Future<DatabaseMaintenanceWorkerOutcome> Function(
      DatabaseMaintenanceWorkerContext context,
    );

final class DatabaseMaintenanceWorkerContext {
  DatabaseMaintenanceWorkerContext._({
    required this.databaseFile,
    required this.database,
    required this.jobs,
    required this._lease,
    required this._publish,
    required this._controlStopRequested,
    required this._setAtomicSection,
  });

  final File databaseFile;
  final Database database;
  final MaintenanceJobRepository jobs;
  MaintenanceJobLease? _lease;
  MaintenanceJobLease get lease =>
      _lease ??
      (throw StateError('Bootstrap has not acquired a maintenance lease.'));
  final void Function(DatabaseMaintenanceProgress progress) _publish;
  final bool Function() _controlStopRequested;
  final Future<bool> Function(bool active) _setAtomicSection;
  var _atomicSectionActive = false;
  final _elapsed = Stopwatch()..start();
  String? _ratePhase;
  String? _rateUnit;
  var _rateBaselineUnits = 0;
  var _rateBaselineMicroseconds = 0;
  var _lastPublishedUnits = 0;

  /// Read only at a safe boundary, outside a batch transaction.
  bool get stopRequested {
    if (_lease == null) return _controlStopRequested();
    if (_controlStopRequested()) {
      jobs.requestStop(lease.jobId, lease: lease);
    }
    return jobs.stopRequested(lease);
  }

  /// Runs interruptible SQLite work, disarming interruption before returning or
  /// throwing so the caller can safely roll back and persist its checkpoint.
  /// Keep transaction recovery outside [action]. Nested/concurrent sections are
  /// not supported. Once used, explicit sections replace phase-label heuristics
  /// for this worker; wrap every later interruptible statement explicitly too.
  Future<T> runAtomic<T>(FutureOr<T> Function() action) async {
    if (_atomicSectionActive) {
      throw StateError('An atomic maintenance section is already active.');
    }
    _atomicSectionActive = true;
    late T value;
    Object? failure;
    StackTrace? failureStack;
    var stopped = false;
    try {
      if (await _setAtomicSection(true)) {
        throw const DatabaseMaintenanceCancelled();
      }
      value = await action();
    } on Object catch (error, stack) {
      failure = error;
      failureStack = stack;
    } finally {
      try {
        // The acknowledgement guarantees no repeating parent interrupt can
        // strike subsequent recovery SQL, even when the action itself failed.
        stopped = await _setAtomicSection(false);
      } finally {
        _atomicSectionActive = false;
      }
    }
    if (failure != null &&
        !(stopped && failure is SqliteException && failure.resultCode == 9)) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
    if (stopped) throw const DatabaseMaintenanceCancelled();
    return value;
  }

  void commitBatch({
    required String phase,
    required String currentWork,
    required String unitLabel,
    required int completedUnits,
    required int? totalUnits,
    required int lastProcessedRowId,
    required MaintenanceBatchApply apply,
  }) {
    jobs.commitBatch(
      lease: lease,
      phase: phase,
      completedUnits: completedUnits,
      totalUnits: totalUnits,
      lastProcessedRowId: lastProcessedRowId,
      statusMessage: currentWork,
      apply: apply,
    );
    publish(
      state: DatabaseMaintenanceState.running,
      phase: phase,
      currentWork: currentWork,
      unitLabel: unitLabel,
      completedUnits: completedUnits,
      totalUnits: totalUnits,
    );
  }

  void publish({
    required DatabaseMaintenanceState state,
    required String phase,
    required String currentWork,
    required String unitLabel,
    required int completedUnits,
    required int? totalUnits,
    String? errorMessage,
  }) {
    final elapsed = _elapsed.elapsed;
    if (_ratePhase != phase ||
        _rateUnit != unitLabel ||
        completedUnits < _lastPublishedUnits) {
      _ratePhase = phase;
      _rateUnit = unitLabel;
      _rateBaselineUnits = completedUnits;
      _rateBaselineMicroseconds = elapsed.inMicroseconds;
    }
    _lastPublishedUnits = completedUnits;
    final seconds =
        (elapsed.inMicroseconds - _rateBaselineMicroseconds) / 1000000;
    final newUnits = completedUnits - _rateBaselineUnits;
    final rate = newUnits > 0 && seconds > 0 ? newUnits / seconds : null;
    final remaining = rate == null || totalUnits == null || rate <= 0
        ? null
        : Duration(
            milliseconds:
                (((totalUnits - completedUnits).clamp(0, totalUnits) / rate) *
                        1000)
                    .round(),
          );
    _publish(
      DatabaseMaintenanceProgress(
        state: state,
        phase: phase,
        currentWork: currentWork,
        unitLabel: unitLabel,
        completedUnits: completedUnits,
        totalUnits: totalUnits,
        ratePerSecond: rate,
        elapsed: elapsed,
        estimatedRemaining: remaining,
        walBytes: _walLength(databaseFile),
        errorMessage: errorMessage,
      ),
    );
  }
}

enum DatabaseWriterPriority {
  migration,
  repair,
  interactive,
  pricing,
  scan,
  optimize,
}

final class DatabaseMaintenanceCoordinator {
  DatabaseMaintenanceCoordinator(
    this.databaseFile, {
    this.pauseCollector,
    this.leaseDuration = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final File databaseFile;
  final CollectorPauser? pauseCollector;
  final Duration leaseDuration;
  final DateTime Function() _clock;
  final _writers =
      <
        ({
          DatabaseWriterPriority priority,
          DateTime queuedAt,
          Future<void> Function() execute,
        })
      >[];
  Completer<void>? _idle;
  bool _draining = false;
  void Function()? _requestActiveYield;
  Future<void> _scanTail = Future<void>.value();

  /// Serialize discovery lifetimes without reserving the database writer.
  /// Missing-file decisions from overlapping scans must not race each other.
  Future<T> runScan<T>(Future<T> Function() work) {
    final result = _scanTail.then((_) => work());
    _scanTail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Exclusive viewer operations hold a resident pause until every worker and
  /// database connection has completed, including failure and cancellation.
  Future<T> withCollectorPaused<T>(
    Future<T> Function() work, {
    bool startupMigration = false,
    void Function()? onPauseLost,
  }) async {
    CollectorPauseHandle? pause;
    var completed = false;
    try {
      if (pauseCollector != null) {
        pause = await acquireCollectorPause(pauseCollector!);
      }
    } on Object {
      if (!startupMigration) throw const CollectorPauseUnavailableException();
      debugPrint(
        'Session collection pause unavailable; startup migration is using SQLite transaction locking and the persisted migration guard.',
      );
    }
    unawaited(
      pause?.lost?.then((_) {
        if (!completed) onPauseLost?.call();
      }),
    );
    try {
      return await work();
    } finally {
      completed = true;
      await pause?.dispose();
    }
  }

  Future<void> get idle => _idle?.future ?? Future<void>.value();

  /// One application-owned instance also admits scans, edits and reparses.
  /// Worker isolates release this slot only outside their write transactions.
  Future<T> runWriter<T>(
    Future<T> Function() work, {
    DatabaseWriterPriority priority = DatabaseWriterPriority.interactive,
  }) {
    final result = Completer<T>();
    _writers.add((
      priority: priority,
      queuedAt: _clock(),
      execute: () async {
        try {
          result.complete(await work());
        } on Object catch (error, stack) {
          result.completeError(error, stack);
        }
      },
    ));
    _requestActiveYield?.call();
    if (!_draining) {
      _draining = true;
      _idle = Completer<void>();
      scheduleMicrotask(_drainWriters);
    }
    return result.future;
  }

  Future<void> _drainWriters() async {
    while (_writers.isNotEmpty) {
      final now = _clock();
      int score(int index) {
        final queued = _writers[index];
        if (queued.priority == DatabaseWriterPriority.migration) return 0;
        // Promote waiting work once per minute, but never ahead of migration.
        final age = now.difference(queued.queuedAt).inMinutes.clamp(0, 4);
        return (queued.priority.index - age).clamp(
          1,
          DatabaseWriterPriority.optimize.index,
        );
      }

      var next = 0;
      for (var index = 1; index < _writers.length; index++) {
        if (score(index) < score(next)) next = index;
      }
      await _writers.removeAt(next).execute();
    }
    _draining = false;
    _idle!.complete();
  }

  /// Opt-in repricing publishes increasing completed units only after durable
  /// commits. Its caller resumes an interrupted result after ordinary writers drain.
  Future<DatabaseMaintenanceOperation> start({
    required String jobType,
    required String initialPhase,
    required DatabaseMaintenanceWorker worker,
    DatabaseMaintenanceWorker? bootstrapWorker,
    int? databaseGenerationId,
    int? totalUnits,
    String? initialStatusMessage,
    String? payloadJson,
    Set<String> atomicPhases = const {},
    bool yieldToQueuedWriters = false,
  }) async {
    if (bootstrapWorker != null && jobType != 'usage_projection_migration') {
      throw ArgumentError(
        'Only startup usage migration may bootstrap its schema.',
      );
    }
    if (yieldToQueuedWriters &&
        (jobType != 'usage_cost_repricing' || atomicPhases.isNotEmpty)) {
      throw ArgumentError(
        'Only non-atomic cost repricing may yield to queued writers.',
      );
    }
    final progress = StreamController<DatabaseMaintenanceProgress>();
    DatabaseMaintenanceOperation? active;
    var stopped = false;
    Future<DatabaseMaintenanceResult> work() async {
      if (stopped) {
        return const DatabaseMaintenanceResult(
          state: DatabaseMaintenanceState.interrupted,
        );
      }
      final operation = await _startWorker(
        jobType: jobType,
        initialPhase: initialPhase,
        worker: worker,
        bootstrapWorker: bootstrapWorker,
        databaseGenerationId: databaseGenerationId,
        totalUnits: totalUnits,
        initialStatusMessage: initialStatusMessage,
        payloadJson: payloadJson,
        atomicPhases: atomicPhases,
      );
      active = operation;
      int? initialCompleted;
      var committedProgress = false;
      var yielding = false;
      void tryYield() {
        if (!yieldToQueuedWriters || !committedProgress || yielding) return;
        if (!_writers.any(
          (writer) =>
              writer.priority == DatabaseWriterPriority.interactive ||
              writer.priority == DatabaseWriterPriority.pricing ||
              writer.priority == DatabaseWriterPriority.scan ||
              writer.priority == DatabaseWriterPriority.optimize,
        )) {
          return;
        }
        yielding = true;
        unawaited(operation.requestStop());
      }

      if (yieldToQueuedWriters) _requestActiveYield = tryYield;
      final subscription = operation.progress.listen((value) {
        initialCompleted ??= value.completedUnits;
        if (value.state == DatabaseMaintenanceState.running &&
            value.completedUnits > initialCompleted!) {
          committedProgress = true;
        }
        progress.add(value);
        tryYield();
      });
      try {
        if (stopped) await operation.requestStop();
        return await operation.result;
      } finally {
        if (identical(_requestActiveYield, tryYield)) {
          _requestActiveYield = null;
        }
        await subscription.cancel();
      }
    }

    final exclusive =
        jobType == 'usage_projection_migration' || atomicPhases.isNotEmpty;
    final result = runWriter(
      exclusive
          ? () async {
              try {
                return await withCollectorPaused(
                  work,
                  startupMigration: jobType == 'usage_projection_migration',
                  onPauseLost: () {
                    // A shadow migration spans transactions. Stop at the existing
                    // durable boundaries rather than continuing across lost exclusion.
                    stopped = true;
                    unawaited(active?.requestStop());
                  },
                );
              } on CollectorPauseUnavailableException {
                return const DatabaseMaintenanceResult(
                  state: DatabaseMaintenanceState.failed,
                  errorMessage: CollectorPauseUnavailableException.message,
                );
              }
            }
          : work,
      priority: switch (jobType) {
        'usage_projection_migration' => DatabaseWriterPriority.migration,
        'usage_cost_repricing' => DatabaseWriterPriority.repair,
        'openrouter_price_refresh' => DatabaseWriterPriority.pricing,
        'database_optimize' ||
        'database_reclaim_space' => DatabaseWriterPriority.optimize,
        _ => DatabaseWriterPriority.interactive,
      },
    );
    return DatabaseMaintenanceOperation(
      result: result.whenComplete(() {
        unawaited(progress.close());
      }),
      progress: progress.stream,
      requestStop: () async {
        stopped = true;
        await active?.requestStop();
      },
    );
  }

  Future<DatabaseMaintenanceOperation> _startWorker({
    required String jobType,
    required String initialPhase,
    required DatabaseMaintenanceWorker worker,
    DatabaseMaintenanceWorker? bootstrapWorker,
    int? databaseGenerationId,
    int? totalUnits,
    String? initialStatusMessage,
    String? payloadJson,
    Set<String> atomicPhases = const {},
  }) async {
    final setup = openFileBackedDatabase(databaseFile, maintenanceWriter: true);
    try {
      if (bootstrapWorker == null) {
        MaintenanceJobRepository(setup).enqueue(
          jobType: jobType,
          phase: initialPhase,
          databaseGenerationId: databaseGenerationId,
          totalUnits: totalUnits,
          statusMessage: initialStatusMessage,
          payloadJson: payloadJson,
        );
      }
    } on Object {
      setup.close();
      rethrow;
    }

    final messages = ReceivePort();
    final progress = StreamController<DatabaseMaintenanceProgress>();
    final result = Completer<DatabaseMaintenanceResult>();
    late StreamSubscription<Object?> messageSubscription;
    SendPort? controlPort;
    var stopRequested = false;
    var atomicStatementPhase = atomicPhases.contains(initialPhase);
    var explicitAtomicSections = false;
    var atomicSectionActive = false;
    Timer? atomicInterruptTimer;
    DatabaseMaintenanceResult? workerFailure;

    void disarmAtomicInterrupts() {
      atomicSectionActive = false;
      atomicInterruptTimer?.cancel();
      atomicInterruptTimer = null;
    }

    void interruptAtomicSection() {
      if (stopRequested && atomicSectionActive && !result.isCompleted) {
        native.sqlite3_interrupt(setup.handle.cast());
      }
    }

    void armAtomicInterrupts() {
      if (!stopRequested || !atomicSectionActive || result.isCompleted) return;
      interruptAtomicSection();
      // An interrupt while SQLite is idle does not affect its next statement.
      // Repeat only inside the explicitly bounded section to close that gap.
      atomicInterruptTimer ??= Timer.periodic(
        const Duration(milliseconds: 50),
        (_) => interruptAtomicSection(),
      );
    }

    void complete(DatabaseMaintenanceResult value) {
      disarmAtomicInterrupts();
      if (!result.isCompleted) {
        result.complete(value);
      }
    }

    messageSubscription = messages.listen((message) {
      if (message is DatabaseMaintenanceProgress) {
        atomicStatementPhase = atomicPhases.contains(message.phase);
        progress.add(message);
      } else if (message is _DatabaseAtomicSection) {
        explicitAtomicSections = true;
        if (message.active) {
          atomicSectionActive = true;
          armAtomicInterrupts();
        } else {
          disarmAtomicInterrupts();
        }
        message.acknowledgement.send(stopRequested);
      } else if (message is _DatabaseMaintenanceDone) {
        complete(message.result);
      } else if (message is SendPort) {
        controlPort = message;
        if (stopRequested) message.send(true);
      } else if (message == null) {
        complete(
          workerFailure ??
              const DatabaseMaintenanceResult(
                state: DatabaseMaintenanceState.failed,
                errorMessage:
                    'The database maintenance worker stopped unexpectedly.',
              ),
        );
      } else {
        disarmAtomicInterrupts();
        workerFailure = const DatabaseMaintenanceResult(
          state: DatabaseMaintenanceState.failed,
          errorMessage: 'The database maintenance worker stopped unexpectedly.',
        );
      }
    });

    try {
      await AppEnvironment.spawnIsolate(
        _databaseMaintenanceWorkerEntry,
        _DatabaseMaintenanceWorkerRequest(
          databaseFilePath: databaseFile.path,
          databaseHandle: setup.handle.address,
          jobType: jobType,
          leaseDurationMilliseconds: leaseDuration.inMilliseconds,
          sendPort: messages.sendPort,
          worker: worker,
          bootstrapWorker: bootstrapWorker,
          atomicPhases: List.unmodifiable(atomicPhases),
        ),
        onError: messages.sendPort,
        onExit: messages.sendPort,
      );
    } on Object {
      disarmAtomicInterrupts();
      await messageSubscription.cancel();
      messages.close();
      unawaited(progress.close());
      setup.close();
      rethrow;
    }

    final completed = result.future.whenComplete(() async {
      // The worker borrows the native connection. Its owner survives worker
      // exit, so stop cannot race sqlite3_close_v2 or a worker finalizer.
      disarmAtomicInterrupts();
      setup.close();
      await messageSubscription.cancel();
      messages.close();
      unawaited(progress.close());
    });
    return DatabaseMaintenanceOperation(
      result: completed,
      progress: progress.stream,
      requestStop: () async {
        if (stopRequested || result.isCompleted) return;
        stopRequested = true;
        controlPort?.send(true);
        armAtomicInterrupts();
        if (!explicitAtomicSections && atomicStatementPhase) {
          native.sqlite3_interrupt(setup.handle.cast());
        }
      },
    );
  }
}

final class _DatabaseMaintenanceWorkerRequest {
  const _DatabaseMaintenanceWorkerRequest({
    required this.databaseFilePath,
    required this.databaseHandle,
    required this.jobType,
    required this.leaseDurationMilliseconds,
    required this.sendPort,
    required this.worker,
    required this.bootstrapWorker,
    required this.atomicPhases,
  });

  final String databaseFilePath;
  final int databaseHandle;
  final String jobType;
  final int leaseDurationMilliseconds;
  final SendPort sendPort;
  final DatabaseMaintenanceWorker worker;
  final DatabaseMaintenanceWorker? bootstrapWorker;
  final List<String> atomicPhases;
}

final class _DatabaseMaintenanceDone {
  const _DatabaseMaintenanceDone(this.result);

  final DatabaseMaintenanceResult result;
}

final class _DatabaseAtomicSection {
  const _DatabaseAtomicSection(this.active, this.acknowledgement);

  final bool active;
  final SendPort acknowledgement;
}

Future<void> _databaseMaintenanceWorkerEntry(
  _DatabaseMaintenanceWorkerRequest request,
) async {
  final databaseFile = File(request.databaseFilePath);
  final database = sqlite3.fromPointer(
    Pointer<Void>.fromAddress(request.databaseHandle),
    borrowed: true,
  );
  final jobs = MaintenanceJobRepository(database);
  MaintenanceJobLease? lease;
  final controls = ReceivePort();
  var stopRequested = false;
  final controlSubscription = controls.listen((_) => stopRequested = true);
  request.sendPort.send(controls.sendPort);
  Future<bool> setAtomicSection(bool active) async {
    final acknowledgement = ReceivePort();
    try {
      request.sendPort.send(
        _DatabaseAtomicSection(active, acknowledgement.sendPort),
      );
      final stopped = await acknowledgement.first as bool;
      if (stopped) stopRequested = true;
      return stopped;
    } finally {
      acknowledgement.close();
    }
  }

  late DatabaseMaintenanceResult result;
  final context = DatabaseMaintenanceWorkerContext._(
    databaseFile: databaseFile,
    database: database,
    jobs: jobs,
    lease: null,
    publish: request.sendPort.send,
    controlStopRequested: () => stopRequested,
    setAtomicSection: setAtomicSection,
  );
  try {
    if (request.bootstrapWorker != null) {
      final bootstrapOutcome = await request.bootstrapWorker!(context);
      await Future<void>.delayed(Duration.zero);
      if (bootstrapOutcome == DatabaseMaintenanceWorkerOutcome.interrupted ||
          context.stopRequested) {
        throw const DatabaseMaintenanceCancelled();
      }
    }
    lease = jobs.claim(
      jobType: request.jobType,
      leaseDuration: Duration(milliseconds: request.leaseDurationMilliseconds),
      atomicPhases: request.atomicPhases.toSet(),
    );
    if (lease == null) {
      throw StateError('Another worker owns this maintenance job.');
    }
    final record = jobs.read(lease.jobId)!;
    context._lease = lease;
    context.publish(
      state: DatabaseMaintenanceState.running,
      phase: record.phase,
      currentWork: record.statusMessage ?? 'Preparing database maintenance.',
      unitLabel: 'items',
      completedUnits: record.completedUnits,
      totalUnits: record.totalUnits,
    );
    DatabaseMaintenanceWorkerOutcome outcome;
    try {
      outcome = await request.worker(context);
    } on DatabaseMaintenanceCancelled {
      outcome = DatabaseMaintenanceWorkerOutcome.interrupted;
    } on SqliteException catch (error) {
      // Deliver the stop message queued while synchronous SQLite was running.
      await Future<void>.delayed(Duration.zero);
      if (error.resultCode != 9 || !context.stopRequested) rethrow;
      outcome = DatabaseMaintenanceWorkerOutcome.interrupted;
    }
    // Deliver stop signals queued while an atomic SQLite call held this isolate.
    await Future<void>.delayed(Duration.zero);
    if (context.stopRequested) {
      outcome = DatabaseMaintenanceWorkerOutcome.interrupted;
    }
    final latest = jobs.read(lease.jobId)!;
    switch (outcome) {
      case DatabaseMaintenanceWorkerOutcome.succeeded:
        jobs.markSucceeded(
          lease,
          phase: 'complete',
          statusMessage: 'Database maintenance complete.',
        );
        context.publish(
          state: DatabaseMaintenanceState.succeeded,
          phase: 'Complete',
          currentWork: 'Database maintenance complete.',
          unitLabel: 'items',
          completedUnits: latest.completedUnits,
          totalUnits: latest.totalUnits,
        );
        result = const DatabaseMaintenanceResult(
          state: DatabaseMaintenanceState.succeeded,
        );
      case DatabaseMaintenanceWorkerOutcome.interrupted:
        jobs.markInterrupted(
          lease,
          statusMessage: 'Stopped safely after the current batch.',
        );
        context.publish(
          state: DatabaseMaintenanceState.interrupted,
          phase: latest.phase,
          currentWork: 'Stopped safely after the current batch.',
          unitLabel: 'items',
          completedUnits: latest.completedUnits,
          totalUnits: latest.totalUnits,
        );
        result = const DatabaseMaintenanceResult(
          state: DatabaseMaintenanceState.interrupted,
        );
    }
  } on DatabaseMaintenanceCancelled {
    context.publish(
      state: DatabaseMaintenanceState.interrupted,
      phase: 'bootstrap',
      currentWork: 'Stopped safely before starting the migration job.',
      unitLabel: 'steps',
      completedUnits: 0,
      totalUnits: null,
    );
    result = const DatabaseMaintenanceResult(
      state: DatabaseMaintenanceState.interrupted,
    );
  } on Object catch (error) {
    var failureMessage = 'Database maintenance failed: $error';
    if (lease != null) {
      try {
        jobs.markFailed(
          lease,
          phase: jobs.read(lease.jobId)!.phase,
          errorMessage: error.toString(),
        );
      } on StaleMaintenanceLeaseException {
        // A replacement worker owns the durable record and decides its state.
      } on Object catch (recordError) {
        failureMessage +=
            '; recording the failed job also failed: $recordError';
      }
    }
    request.sendPort.send(
      DatabaseMaintenanceProgress(
        state: DatabaseMaintenanceState.failed,
        phase: 'Failed',
        currentWork: failureMessage,
        unitLabel: 'items',
        completedUnits: 0,
        totalUnits: null,
        ratePerSecond: null,
        elapsed: Duration.zero,
        estimatedRemaining: null,
        walBytes: _walLength(databaseFile),
        errorMessage: failureMessage,
      ),
    );
    result = DatabaseMaintenanceResult(
      state: DatabaseMaintenanceState.failed,
      errorMessage: failureMessage,
    );
  } finally {
    database.close();
    await controlSubscription.cancel();
    controls.close();
  }
  Isolate.exit(request.sendPort, _DatabaseMaintenanceDone(result));
}

int _walLength(File databaseFile) {
  final wal = File('${databaseFile.path}-wal');
  try {
    return wal.existsSync() ? wal.lengthSync() : 0;
  } on FileSystemException {
    return 0;
  }
}
