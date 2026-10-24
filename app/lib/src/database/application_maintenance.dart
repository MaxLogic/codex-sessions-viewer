import 'package:codex_sessions_viewer/src/platform/app_environment.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../config/app_settings.dart';
import '../logging/structured_logger.dart';
import '../scanner/resident_collector_client.dart';
import '../pricing/pricing_repository.dart';
import '../pricing/hub_price_history.dart';
import '../usage/usage_cost_projection.dart';
import 'backup_retention.dart';
import 'collector_versions.dart';
import 'database_connection.dart';
import 'database_maintenance.dart';
import 'disk_space_probe.dart';
import 'maintenance_job.dart';

/// `app_metadata` key: the Codex parser version whose reparse has had its
/// freed space reclaimed (or found too little to be worth a VACUUM).
const spaceReclaimMarkerKey = 'space_reclaim.codex_parser_version';

/// `app_metadata` key the collector writes after a scan that listed every
/// configured Codex root (`COMPLETE_CODEX_SCAN_KEY` in
/// `collector/src/store/writer.rs`).
const completeCodexScanKey = 'codex_scan.completed_parser_version';

/// Application-owned schedules; the coordinator is also shared by UI writers.
class ApplicationMaintenance extends ChangeNotifier {
  ApplicationMaintenance({
    required this.databaseFile,
    required this.coordinator,
    this.client = const OpenRouterHttpClient(),
    DateTime Function()? clock,
    String? Function()? hubMachineToken,
    DiskSpaceProbe? diskSpace,
    this.reclaimMinimumDatabaseBytes = 256 * 1024 * 1024,
  }) : clock = clock ?? DateTime.now,
       hubMachineToken = hubMachineToken ?? _environmentHubMachineToken,
       diskSpace = diskSpace ?? DiskSpaceProbe.forCurrentPlatform();

  final File databaseFile;
  final DatabaseMaintenanceCoordinator coordinator;
  final OpenRouterModelsClient client;
  final DateTime Function() clock;
  final DiskSpaceProbe diskSpace;

  /// Smaller databases are not compacted after a reparse: whatever the
  /// reparse left unused is not worth the rewrite.
  final int reclaimMinimumDatabaseBytes;

  /// Set when freed space could not be reclaimed (for example, too little
  /// free disk space); retried on the next start.
  String? spaceReclaimWarning;
  var _reclaimAttempted = false;

  /// The hub machine credential. It is read from the environment for each
  /// refresh and never stored in settings or the database.
  final String? Function() hubMachineToken;

  static String? _environmentHubMachineToken() =>
      AppEnvironment.current['CODEX_SESSIONS_HUB_MACHINE_TOKEN'];

  /// The last hub price sync problem in this session; also persisted as the
  /// price schedule's fixed-text warning for Settings.
  String? hubPriceSyncError;

  /// Set when an old backup could not be deleted (for example, a file still
  /// open elsewhere); the details are in the logs. Retried the next day.
  String? backupRetentionWarning;
  DateTime? _lastBackupRetention;

  AppSettings? _settings;
  List<MaintenanceScheduleRecord> schedules = const [];
  DatabaseMaintenanceProgress? progress;
  String? errorMessage;
  var _dataRevision = 0;
  int get dataRevision => _dataRevision;
  Future<void>? _drain;
  DatabaseMaintenanceOperation? _operation;
  Timer? _timer;
  var _started = false;
  var _stopped = false;
  var _disposed = false;
  var _manualPricing = false;
  var _pricingRunning = false;
  var _lastPricingSucceeded = false;
  final _stopSignal = Completer<void>();

  T _withDatabase<T>(T Function(Database db) work) {
    final db = openFileBackedDatabase(databaseFile);
    try {
      return work(db);
    } finally {
      db.close();
    }
  }

  Future<void> configure(AppSettings settings) async {
    if (_stopped) return;
    await coordinator.runWriter(() async {
      if (_stopped) return;
      _withDatabase((db) {
        PricingRepository(
          db,
        ).synchronizeSettings(settings.pricing, nowUtc: clock());
        final jobs = MaintenanceJobRepository(db, clock: clock);
        jobs.configureSchedule(
          jobType: 'openrouter_price_refresh',
          enabled:
              settings.pricing.useExternalPricing &&
              settings.pricing.automaticRefreshEnabled,
          intervalSeconds: settings.pricing.refreshIntervalHours * 3600,
          utcSlots: settings.pricing.refreshUtcSlots,
        );
        jobs.configureSchedule(
          jobType: 'database_optimize',
          enabled: settings.maintenance.databaseOptimizeEnabled,
          intervalSeconds:
              settings.maintenance.databaseOptimizeIntervalDays * 86400,
        );
      });
      _settings = settings;
    });
    if (_stopped) return;
    _readStatus();
    _armTimer();
  }

  void start() {
    if (_started || _stopped) return;
    _started = true;
    unawaited(runDueJobs());
  }

  void _readStatus() {
    schedules = _withDatabase((db) => MaintenanceJobRepository(db).schedules());
    if (!_disposed) notifyListeners();
  }

  bool _due(String type) => schedules.any(
    (row) =>
        row.jobType == type &&
        row.enabled &&
        (row.nextDueAtUtc == null ||
            !row.nextDueAtUtc!.isAfter(clock().toUtc())),
  );

  Future<void> runDueJobs() {
    if (_stopped || _settings == null) return Future.value();
    return _drain ??= Future<void>.microtask(_runDueJobs).whenComplete(() {
      _drain = null;
      _armTimer();
    });
  }

  Future<bool> refreshPrices() async {
    if (_stopped || _settings?.pricing.useExternalPricing != true) return false;
    if (!_pricingRunning) _manualPricing = true;
    await runDueJobs();
    // A request made during optimization gets one subsequent refresh, not one
    // refresh for each caller waiting on that same operation.
    if (_manualPricing && !_stopped) await runDueJobs();
    return !_stopped && _lastPricingSucceeded;
  }

  Future<void> _runDueJobs() async {
    _timer?.cancel();
    try {
      errorMessage = null;
      _readStatus();
      await _pruneBackups();
      await _reprice();
      if (_manualPricing || _due('openrouter_price_refresh')) {
        final manual = _manualPricing;
        _manualPricing = false;
        _pricingRunning = true;
        try {
          await _refreshPrices(manual: manual);
        } finally {
          _pricingRunning = false;
        }
      }
      if (!_stopped) await _reprice();
      if (!_stopped && _due('database_optimize')) await _optimize();
      if (!_stopped) await _reclaimSpace();
    } on Object {
      errorMessage =
          'Database maintenance failed. Retry after checking the database.';
      _report(
        'maintenance_failed',
        errorMessage!,
        state: DatabaseMaintenanceState.failed,
      );
    }
  }

  /// Deletes the viewer's own old backups once a day. It runs only here,
  /// after the startup gate released normal database access, so it never
  /// races a startup migration; unfinished migrations keep their backups.
  Future<void> _pruneBackups() async {
    final settings = _settings;
    final now = clock().toUtc();
    final last = _lastBackupRetention;
    if (_stopped ||
        settings == null ||
        (last != null && now.difference(last) < const Duration(days: 1))) {
      return;
    }
    _lastBackupRetention = now;
    try {
      await coordinator.runWriter(() async {
        if (_stopped) return;
        final db = openFileBackedDatabase(databaseFile);
        try {
          final result = ViewerBackupRetention(
            databaseFile: databaseFile,
            retention: Duration(days: settings.database.backupRetentionDays),
            clock: clock,
          ).prune(db);
          backupRetentionWarning = result.failed.isEmpty
              ? null
              : 'An old database backup could not be deleted; it will be retried tomorrow.';
          final logger = StructuredLogger(db: db, settings: settings.logging);
          for (final entry in result.deleted) {
            await logger.writeBestEffort(
              LogEntryDraft(
                level: LogLevel.info,
                category: LogCategory.database,
                message: 'Deleted an old database backup.',
                details: {'path': entry.path, 'bytes': entry.bytes},
              ),
            );
          }
          for (final path in result.failed) {
            await logger.writeBestEffort(
              LogEntryDraft(
                level: LogLevel.warning,
                category: LogCategory.database,
                message:
                    'An old database backup could not be deleted; it may be open in another program.',
                details: {'path': path},
              ),
            );
          }
        } finally {
          db.close();
        }
      }, priority: DatabaseWriterPriority.optimize);
    } on Object {
      backupRetentionWarning =
          'Old database backups could not be checked; retried tomorrow.';
    }
    if (!_disposed) notifyListeners();
  }

  void _report(
    String phase,
    String message, {
    DateTime? started,
    DatabaseMaintenanceState state = DatabaseMaintenanceState.running,
  }) {
    progress = DatabaseMaintenanceProgress(
      state: state,
      phase: phase,
      currentWork: state == DatabaseMaintenanceState.failed
          ? 'Database maintenance is not running.'
          : message,
      unitLabel: 'items',
      completedUnits: 0,
      totalUnits: null,
      ratePerSecond: null,
      elapsed: started == null
          ? Duration.zero
          : clock().toUtc().difference(started),
      estimatedRemaining: null,
      walBytes: 0,
      errorMessage: state == DatabaseMaintenanceState.failed ? message : null,
    );
    if (!_disposed) notifyListeners();
  }

  Future<void> _reprice() async {
    if (_stopped) return;
    final generationId = _withDatabase((db) {
      final rows = db.select('''
        select generation.id from database_state state
        join database_generations generation on generation.id=state.active_usage_generation_id
        where state.id=1 and generation.target_schema_version>=16
          and exists(select 1 from usage_cost_dirty_partitions)
      ''');
      return rows.isEmpty ? null : rows.single['id'] as int;
    });
    if (generationId == null) return;
    final result = await _watchOperation(
      await coordinator.start(
        jobType: 'usage_cost_repricing',
        initialPhase: 'reprice_costs',
        databaseGenerationId: generationId,
        worker: _repriceCosts(_settings!.pricing),
        yieldToQueuedWriters: true,
      ),
      phase: 'reprice_costs',
    );
    _dataRevision++;
    if (!_disposed) notifyListeners();
    if (result.state == DatabaseMaintenanceState.interrupted && !_stopped) {
      await coordinator.idle;
    }
    if (result.state == DatabaseMaintenanceState.failed) {
      throw StateError('Daily cost maintenance failed.');
    }
  }

  Future<DatabaseMaintenanceResult> _watchOperation(
    DatabaseMaintenanceOperation operation, {
    required String phase,
  }) async {
    _operation = operation;
    final subscription = operation.progress.listen((value) {
      progress = value.state == DatabaseMaintenanceState.failed
          ? DatabaseMaintenanceProgress(
              state: value.state,
              phase: value.phase,
              currentWork: 'Database maintenance is not running.',
              unitLabel: value.unitLabel,
              completedUnits: value.completedUnits,
              totalUnits: value.totalUnits,
              ratePerSecond: value.ratePerSecond,
              elapsed: value.elapsed,
              estimatedRemaining: value.estimatedRemaining,
              walBytes: value.walBytes,
              errorMessage: _maintenanceFailureText(value.errorMessage, phase),
            )
          : value;
      if (!_disposed) notifyListeners();
    });
    try {
      if (_stopped) await operation.requestStop();
      final result = await operation.result;
      if (result.state == DatabaseMaintenanceState.failed) {
        _report(
          phase,
          _maintenanceFailureText(result.errorMessage, phase),
          state: DatabaseMaintenanceState.failed,
        );
      }
      return result;
    } finally {
      await subscription.cancel();
      _operation = null;
    }
  }

  // Coordinator.start holds the resident pause through the worker result;
  // VACUUM below uses the same boundary, including interrupted/failed work.
  Future<void> _optimize() async {
    const type = 'database_optimize';
    await coordinator.runWriter(() async {
      _withDatabase(
        (db) => MaintenanceJobRepository(
          db,
          clock: clock,
        ).recordScheduleAttempt(type),
      );
    }, priority: DatabaseWriterPriority.optimize);
    final result = await _watchOperation(
      await coordinator.start(
        jobType: type,
        initialPhase: 'optimize',
        worker: _optimizeDatabase,
        totalUnits: 1,
        atomicPhases: const {'optimize'},
      ),
      phase: 'optimize',
    );
    await coordinator.runWriter(() async {
      _withDatabase(
        (db) => MaintenanceJobRepository(
          db,
          clock: clock,
        ).completeScheduleAttempt(type, succeeded: result.succeeded),
      );
    }, priority: DatabaseWriterPriority.optimize);
    _readStatus();
    if (result.state == DatabaseMaintenanceState.failed) {
      errorMessage = _maintenanceFailureText(result.errorMessage, 'optimize');
    }
  }

  /// Once per Codex parser version, after every available local Codex
  /// session was reparsed: the reparse replaced every session's rows, which
  /// leaves free pages in the file (auto_vacuum is off) and deleted entries
  /// in the full-text segments. The job merges the search indexes and runs
  /// one VACUUM. VACUUM rewrites the used pages into a temporary copy and
  /// then through the WAL, so it needs about the used size free both in the
  /// temporary folder and next to the database. It runs as an atomic
  /// maintenance job with progress; stopping the app interrupts it and
  /// SQLite rolls the current step back. Skipped while database maintenance
  /// is disabled in settings.
  Future<void> _reclaimSpace() async {
    final settings = _settings;
    if (_reclaimAttempted ||
        _stopped ||
        settings == null ||
        !settings.maintenance.databaseOptimizeEnabled) {
      return;
    }
    final plan = _withDatabase(
      (db) => spaceReclaimPlan(
        db,
        codexParserVersion: collectorCodexParserVersion,
        minimumDatabaseBytes: reclaimMinimumDatabaseBytes,
      ),
    );
    if (plan == null) return;
    _reclaimAttempted = true;
    if (!plan.worthwhile) {
      await coordinator.runWriter(() async {
        if (_stopped) return;
        _withDatabase(_recordSpaceReclaimed);
      }, priority: DatabaseWriterPriority.optimize);
      return;
    }
    final shortage = _diskShortage(plan);
    if (shortage != null) {
      spaceReclaimWarning = shortage;
      _report(
        'reclaim_space_skipped',
        shortage,
        state: DatabaseMaintenanceState.succeeded,
      );
      return;
    }
    spaceReclaimWarning = null;
    final result = await _watchOperation(
      await coordinator.start(
        jobType: 'database_reclaim_space',
        initialPhase: 'reclaim_space',
        initialStatusMessage: plan.statusMessage,
        worker: _reclaimDatabaseSpace,
        totalUnits: 1,
        atomicPhases: const {'reclaim_space'},
      ),
      phase: 'reclaim_space',
    );
    if (result.state == DatabaseMaintenanceState.failed) {
      spaceReclaimWarning =
          result.errorMessage == CollectorPauseUnavailableException.message
          ? _maintenanceFailureText(result.errorMessage, 'reclaim_space')
          : 'Unused database space could not be reclaimed; retried on the next start.';
    }
    _dataRevision++;
    if (!_disposed) notifyListeners();
  }

  /// Null when both the database folder and the temporary folder can hold
  /// the rewrite; otherwise a message naming the space needed.
  String? _diskShortage(SpaceReclaimPlan plan) {
    final needed = plan.requiredBytesPerCopy;
    try {
      final required = <String, int>{};
      final available = <String, int>{};
      for (final directory in [databaseFile.parent, Directory.systemTemp]) {
        final volume = diskSpace.probe(directory);
        required[volume.volumeKey] = (required[volume.volumeKey] ?? 0) + needed;
        available[volume.volumeKey] = volume.availableBytes;
      }
      final short = required.entries.any(
        (entry) => available[entry.key]! < entry.value,
      );
      if (!short) return null;
    } on Object {
      // Without a reliable probe, do not start a rewrite that may not fit.
    }
    return 'Not enough free disk space to compact the database after the '
        'parser update: it needs about ${_mib(needed)} free in the database '
        'folder and in the temporary folder. Retried on the next start.';
  }

  Future<void> _refreshPrices({bool manual = false}) async {
    const type = 'openrouter_price_refresh';
    PricingSettings? requestSettings;
    var hubUrl = '';
    var origin = 'local';
    var localObservations = <PriceObservation>[];
    var knownHub = const HubPriceSyncResult([], 0, '');
    String? hubWarning;
    final token = hubMachineToken()?.trim() ?? '';
    final started = clock().toUtc();
    _lastPricingSucceeded = false;
    await coordinator.runWriter(() async {
      final settings = _settings!.pricing;
      if (_stopped ||
          !settings.useExternalPricing ||
          (!manual && !settings.automaticRefreshEnabled)) {
        return;
      }
      _withDatabase(
        (db) => MaintenanceJobRepository(
          db,
          clock: clock,
        ).recordScheduleAttempt(type, manual: manual),
      );
      requestSettings = settings;
      hubUrl = _settings!.hub.url.trim();
      if (hubUrl.isEmpty) return;
      // Price sync identifies this machine like the collector does: by the
      // database's machine identity, authenticated by the machine token.
      final prepared = await _prepareHubHistory(databaseFile.path, hubUrl);
      if (prepared == null) {
        hubWarning =
            'Not synchronized: this database has no machine identity yet.';
        return;
      }
      origin = prepared.$3;
      if (token.isEmpty) {
        hubWarning =
            'Not synchronized: set CODEX_SESSIONS_HUB_MACHINE_TOKEN for this machine.';
        return;
      }
      localObservations = prepared.$1;
      knownHub = prepared.$2;
    }, priority: DatabaseWriterPriority.pricing);
    final settings = requestSettings;
    if (_stopped || settings == null) return;
    bool requestIsCurrent() =>
        !_stopped &&
        _settings!.pricing.useExternalPricing &&
        _settings!.pricing.openRouter == settings.openRouter &&
        _settings!.hub.url.trim() == hubUrl;
    _readStatus();
    _report(
      'catalog_download',
      'Downloading public OpenRouter model prices.',
      started: started,
    );
    var succeeded = false;
    var superseded = false;
    Duration? retryAfter;
    DateTime? successfulObservationAtUtc;
    final cancelled = Completer<OpenRouterModelsResponse?>();
    final cancellation = _stopSignal.future.asStream().listen(
      (_) => cancelled.complete(null),
    );
    try {
      List<PriceObservation>? hubObservations;
      HubPriceSyncResult? hubResult;
      if (hubUrl.isNotEmpty && hubWarning == null) {
        try {
          hubResult = await HubPriceHistoryClient().synchronizeIncremental(
            endpoint: Uri.parse(hubUrl),
            token: token,
            cancellation: _stopSignal.future,
            observations: localObservations,
            known: knownHub.observations,
            after: knownHub.through,
            confirmationsAfter: knownHub.confirmationSeq,
          );
          hubObservations = hubResult.observations;
        } on Object catch (error) {
          // A disconnected optional hub must not disable local observations,
          // but the reason is reported instead of silently ignored.
          hubWarning = hubPriceSyncWarning(error);
        }
      }
      if (hubObservations != null && hubObservations.isNotEmpty) {
        await coordinator.runWriter(() async {
          if (!requestIsCurrent()) {
            superseded = true;
            return;
          }
          try {
            await _mergeHubHistory(databaseFile.path, hubResult!, hubUrl);
          } on Object catch (error) {
            hubWarning = hubPriceSyncWarning(error);
            return;
          }
          // An unchanged hub price is confirmed rather than observed again;
          // a confirmation in the current slot is fresh hub evidence.
          final hubTimes = [
            for (final item in hubObservations!)
              if (item.authority == 'hub') item.observedAtUtc,
            ...hubResult.confirmations.values,
          ];
          final allTimes = [
            for (final item in hubObservations) item.observedAtUtc,
            ...hubResult.confirmations.values,
          ];
          successfulObservationAtUtc = allTimes.reduce(
            (a, b) => a.isAfter(b) ? a : b,
          );
          final currentSlot = started.millisecondsSinceEpoch ~/ 21600000;
          succeeded = hubTimes.any(
            (at) => at.millisecondsSinceEpoch ~/ 21600000 >= currentSlot,
          );
          _dataRevision++;
          if (!_disposed) notifyListeners();
        }, priority: DatabaseWriterPriority.pricing);
      }
      if (!succeeded && !superseded && !_stopped) {
        final response = await Future.any<OpenRouterModelsResponse?>([
          client.fetchModels(
            OpenRouterModelsRequest(
              endpoint: Uri.parse(settings.openRouter.modelsEndpoint),
              apiKey: settings.openRouter.apiKey,
              cancellation: _stopSignal.future,
            ),
          ),
          cancelled.future,
        ]);
        if (response == null || _stopped) return;
        final observed = clock().toUtc();
        _report(
          'catalog_waiting_writer',
          'Prices downloaded; waiting for the database writer.',
          started: started,
        );
        await coordinator.runWriter(() async {
          if (!requestIsCurrent()) {
            superseded = true;
            return;
          }
          _report(
            'catalog_apply',
            'Storing observed model prices.',
            started: started,
          );
          // Only bounded public catalog data crosses into this isolate.
          await _applyCatalog(
            databaseFile.path,
            response,
            started,
            observed,
            origin,
            settings.refreshIntervalHours,
          );
          succeeded = true;
          successfulObservationAtUtc = observed;
          _dataRevision++;
          if (!_disposed) notifyListeners();
        }, priority: DatabaseWriterPriority.pricing);
      }
    } on Object catch (error) {
      retryAfter = error is PricingFetchException ? error.retryAfter : null;
    } finally {
      await cancellation.cancel();
    }
    if (_stopped) return;
    await coordinator.runWriter(() async {
      if (superseded || !requestIsCurrent()) {
        superseded = true;
        return;
      }
      _withDatabase((db) {
        if (!succeeded) {
          PricingRepository(
            db,
          ).recordCatalogFailure(startedAtUtc: started, nowUtc: clock());
        }
        MaintenanceJobRepository(db, clock: clock).completeScheduleAttempt(
          type,
          succeeded: succeeded,
          warning: hubWarning,
          retryAfter: retryAfter,
          utcSlots: _settings!.pricing.refreshUtcSlots,
          successfulObservationAtUtc: successfulObservationAtUtc,
        );
      });
    }, priority: DatabaseWriterPriority.pricing);
    if (superseded) {
      _readStatus();
      _report(
        'catalog_superseded',
        'Discarded an outdated download after provider settings changed.',
        state: DatabaseMaintenanceState.succeeded,
      );
      return;
    }
    _lastPricingSucceeded = succeeded;
    hubPriceSyncError = hubWarning;
    _readStatus();
    _report(
      succeeded ? 'complete' : 'catalog_failed',
      succeeded
          ? 'Observed model price history refreshed.'
          : 'Model price refresh failed; retained observations remain available.',
      started: started,
      state: succeeded
          ? DatabaseMaintenanceState.succeeded
          : DatabaseMaintenanceState.failed,
    );
  }

  void _armTimer() {
    _timer?.cancel();
    if (!_started || _stopped || _drain != null) return;
    // ponytail: one application timer also discovers newly dirtied partitions.
    // Replace this short idle poll only if measured idle I/O warrants a signal.
    var delay = const Duration(seconds: 30);
    for (final row in schedules.where((row) => row.enabled)) {
      final due = row.nextDueAtUtc;
      final remaining = due == null
          ? Duration.zero
          : due.difference(clock().toUtc());
      if (remaining < delay) delay = remaining;
    }
    if (errorMessage != null) delay = const Duration(seconds: 30);
    _timer = Timer(
      delay < const Duration(seconds: 1) ? const Duration(seconds: 1) : delay,
      () => unawaited(runDueJobs()),
    );
  }

  Future<void> stop() async {
    _stopped = true;
    if (!_stopSignal.isCompleted) _stopSignal.complete();
    _timer?.cancel();
    await _operation?.requestStop();
    await _drain;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    super.dispose();
  }
}

String _maintenanceFailureText(String? message, String phase) =>
    message == CollectorPauseUnavailableException.message
    ? phase == 'reclaim_space'
          ? 'Unused database space was not reclaimed because session collection could not pause. It will be retried the next time the viewer starts.'
          : 'Database optimization was postponed because session collection could not pause. It will be retried automatically.'
    : 'Database maintenance could not finish. Try again in a moment.';

DatabaseMaintenanceWorker _repriceCosts(
  PricingSettings settings,
) => (context) async {
  final costs = UsageCostProjectionRepository(context.database);
  while (!context.stopRequested) {
    if (costs.repriceNextBatch(
          jobs: context.jobs,
          lease: context.lease,
          settings: settings,
        ) ==
        0) {
      return DatabaseMaintenanceWorkerOutcome.succeeded;
    }
    final job = context.jobs.read(context.lease.jobId)!;
    context.publish(
      state: DatabaseMaintenanceState.running,
      phase: 'reprice_costs',
      currentWork:
          'Updating daily cost partition ${job.completedUnits} of ${job.totalUnits}.',
      unitLabel: 'partitions',
      completedUnits: job.completedUnits,
      totalUnits: job.totalUnits,
    );
    // Deliver cancellation between durable partition transactions.
    await Future<void>.delayed(Duration.zero);
  }
  return DatabaseMaintenanceWorkerOutcome.interrupted;
};

Future<DatabaseMaintenanceWorkerOutcome> _optimizeDatabase(
  DatabaseMaintenanceWorkerContext context,
) async {
  if (context.stopRequested) {
    return DatabaseMaintenanceWorkerOutcome.interrupted;
  }
  context.commitBatch(
    phase: 'optimize',
    currentWork: 'Optimizing database statistics.',
    unitLabel: 'jobs',
    completedUnits: 1,
    totalUnits: 1,
    lastProcessedRowId: 0,
    apply: (db) {
      // The worker owns a fresh connection: ask SQLite to consider all tables.
      db.execute('pragma optimize=0x10002');
      db.execute('''
        update database_state set last_optimized_schema_version =
          (select max(version) from schema_version where success=1) where id=1
      ''');
    },
  );
  return DatabaseMaintenanceWorkerOutcome.succeeded;
}

/// The database after a finished reparse, and whether compacting it is worth
/// the rewrite. The free page count understates the gain: deleted full-text
/// entries still occupy index pages until the job merges them.
@visibleForTesting
final class SpaceReclaimPlan {
  const SpaceReclaimPlan({
    required this.freeBytes,
    required this.usedBytes,
    required this.worthwhile,
  });

  final int freeBytes;
  final int usedBytes;
  final bool worthwhile;

  /// One rewritten copy of the used pages, plus a tenth for the journal and
  /// growth while it runs.
  int get requiredBytesPerCopy => usedBytes + usedBytes ~/ 10;

  String get statusMessage =>
      'Compacting the ${_mib(freeBytes + usedBytes)} database after the '
      'parser update; this can take several minutes.';
}

/// Null until reclaiming is due: [codexParserVersion] has not been reclaimed
/// yet, and either a complete collector scan ran with that parser or no
/// available Codex session still awaits it.
@visibleForTesting
SpaceReclaimPlan? spaceReclaimPlan(
  Database db, {
  required int codexParserVersion,
  required int minimumDatabaseBytes,
}) {
  final marker = db.select('select value from app_metadata where key = ?', [
    spaceReclaimMarkerKey,
  ]);
  if (marker.isNotEmpty && marker.single['value'] == '$codexParserVersion') {
    return null;
  }
  // The collector records a scan that listed every configured root with
  // this parser: a row still on an older one lies outside those roots and is
  // never reparsed, so it must not keep the compaction waiting.
  final completeScan = db.select(
    'select value from app_metadata where key = ?',
    [completeCodexScanKey],
  );
  final scanned =
      completeScan.isNotEmpty &&
      completeScan.single['value'] == '$codexParserVersion';
  // Sessions collected on other machines are never reparsed here.
  final pending = db.select(
    '''
    select exists(
      select 1 from sessions
      where harness = 'codex' and scan_status = 'available'
        and parse_status = 'available' and parser_version <> ?
        and (machine_id is null or machine_id =
          (select value from app_metadata where key = 'machine_id'))
    ) as pending
    ''',
    [codexParserVersion],
  );
  if (!scanned && pending.single['pending'] == 1) return null;
  final pages = db.select('''
    select page_count, freelist_count, page_size
    from pragma_page_count, pragma_freelist_count, pragma_page_size
  ''').single;
  final pageSize = pages['page_size'] as int;
  final total = (pages['page_count'] as int) * pageSize;
  final free = (pages['freelist_count'] as int) * pageSize;
  return SpaceReclaimPlan(
    freeBytes: free,
    usedBytes: total - free,
    worthwhile: total >= minimumDatabaseBytes,
  );
}

void _recordSpaceReclaimed(Database db) {
  db.execute(
    '''
    insert into app_metadata(key, value, updated_at_utc) values (?, ?, ?)
    on conflict(key) do update set
      value = excluded.value, updated_at_utc = excluded.updated_at_utc
    ''',
    [
      spaceReclaimMarkerKey,
      '$collectorCodexParserVersion',
      DateTime.now().toUtc().toIso8601String(),
    ],
  );
}

Future<DatabaseMaintenanceWorkerOutcome> _reclaimDatabaseSpace(
  DatabaseMaintenanceWorkerContext context,
) async {
  if (context.stopRequested) {
    return DatabaseMaintenanceWorkerOutcome.interrupted;
  }
  final db = context.database;
  // A reparse deletes and reinserts every indexed row. FTS5 keeps deleted
  // entries in its segments until they merge, so merge them first; VACUUM
  // then returns the index's freed pages too. Each step is one statement an
  // interrupt rolls back.
  for (final (index, table) in _searchIndexes.indexed) {
    context.publish(
      state: DatabaseMaintenanceState.running,
      phase: 'reclaim_space',
      currentWork:
          'Compacting search index ${index + 1} of ${_searchIndexes.length}.',
      unitLabel: 'steps',
      completedUnits: 0,
      totalUnits: 1,
    );
    await context.runAtomic(
      () => db.execute("insert into $table($table) values('optimize')"),
    );
    db.select('pragma wal_checkpoint(truncate)');
  }
  context.publish(
    state: DatabaseMaintenanceState.running,
    phase: 'reclaim_space',
    currentWork: 'Rewriting the database file without its unused space.',
    unitLabel: 'steps',
    completedUnits: 0,
    totalUnits: 1,
  );
  // VACUUM cannot run inside a transaction; an interrupt rolls it back.
  await context.runAtomic(() => db.execute('vacuum'));
  db.select('pragma wal_checkpoint(truncate)');
  context.commitBatch(
    phase: 'reclaim_space',
    currentWork: 'Unused database space reclaimed.',
    unitLabel: 'steps',
    completedUnits: 1,
    totalUnits: 1,
    lastProcessedRowId: 0,
    apply: _recordSpaceReclaimed,
  );
  return DatabaseMaintenanceWorkerOutcome.succeeded;
}

const _searchIndexes = [
  'message_search',
  'tool_output_search',
  'session_search',
];

String _mib(int bytes) => '${(bytes / (1024 * 1024)).ceil()} MiB';

Future<void> _applyCatalog(
  String path,
  OpenRouterModelsResponse response,
  DateTime started,
  DateTime observed,
  String origin,
  int refreshIntervalHours,
) => AppEnvironment.runIsolate(() {
  final db = openFileBackedDatabase(File(path));
  try {
    PricingRepository(db).applyCatalog(
      response,
      startedAtUtc: started,
      observedAtUtc: observed,
      origin: origin,
      refreshIntervalHours: refreshIntervalHours,
    );
  } finally {
    db.close();
  }
});

Future<void> _mergeHubHistory(
  String path,
  HubPriceSyncResult snapshot,
  String url,
) => AppEnvironment.runIsolate(() {
  final db = openFileBackedDatabase(File(path));
  try {
    PricingRepository(db).mergePriceObservations(
      snapshot.observations,
      hubUrl: url,
      through: snapshot.through,
      hubRevision: snapshot.revision,
      confirmations: snapshot.confirmations,
      confirmationSeq: snapshot.confirmationSeq,
    );
  } finally {
    db.close();
  }
});

/// Null when the database has no machine identity to sync as.
Future<(List<PriceObservation>, HubPriceSyncResult, String)?>
_prepareHubHistory(String path, String url) => AppEnvironment.runIsolate(() {
  final db = openFileBackedDatabase(File(path));
  try {
    final rows = db.select(
      "select value from app_metadata where key = 'machine_id'",
    );
    final machine = rows.isEmpty ? '' : (rows.single['value'] as String? ?? '');
    if (machine.isEmpty) return null;
    final repository = PricingRepository(db);
    return (
      repository.localPriceObservationsForHub(machine),
      repository.hubSyncSnapshot(url),
      machine,
    );
  } finally {
    db.close();
  }
});
