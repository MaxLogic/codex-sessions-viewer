import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../config/app_settings.dart';
import '../pricing/pricing_repository.dart';
import '../pricing/hub_price_history.dart';
import '../usage/usage_cost_projection.dart';
import 'database_connection.dart';
import 'database_maintenance.dart';
import 'maintenance_job.dart';

/// Application-owned schedules; the coordinator is also shared by UI writers.
class ApplicationMaintenance extends ChangeNotifier {
  ApplicationMaintenance({
    required this.databaseFile,
    required this.coordinator,
    this.client = const OpenRouterHttpClient(),
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final File databaseFile;
  final DatabaseMaintenanceCoordinator coordinator;
  final OpenRouterModelsClient client;
  final DateTime Function() clock;

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

  void _report(
    String phase,
    String message, {
    DateTime? started,
    DatabaseMaintenanceState state = DatabaseMaintenanceState.running,
  }) {
    progress = DatabaseMaintenanceProgress(
      state: state,
      phase: phase,
      currentWork: message,
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
    DatabaseMaintenanceOperation operation,
  ) async {
    _operation = operation;
    final subscription = operation.progress.listen((value) {
      progress = value;
      if (!_disposed) notifyListeners();
    });
    try {
      if (_stopped) await operation.requestStop();
      return await operation.result;
    } finally {
      await subscription.cancel();
      _operation = null;
    }
  }

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
  }

  Future<void> _refreshPrices({bool manual = false}) async {
    const type = 'openrouter_price_refresh';
    PricingSettings? requestSettings;
    var localObservations = <PriceObservation>[];
    var knownHub = const HubPriceSyncResult([], 0, '');
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
      if (settings.hubUrl.isNotEmpty && settings.hubMachineId.isNotEmpty) {
        final prepared = await _prepareHubHistory(
          databaseFile.path,
          settings.hubMachineId,
          settings.hubUrl,
        );
        localObservations = prepared.$1;
        knownHub = prepared.$2;
      }
    }, priority: DatabaseWriterPriority.pricing);
    final settings = requestSettings;
    if (_stopped || settings == null) return;
    bool requestIsCurrent() =>
        !_stopped &&
        _settings!.pricing.useExternalPricing &&
        _settings!.pricing.openRouter == settings.openRouter &&
        _settings!.pricing.hubUrl == settings.hubUrl &&
        _settings!.pricing.hubToken == settings.hubToken &&
        _settings!.pricing.hubMachineId == settings.hubMachineId;
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
      if (settings.hubUrl.isNotEmpty &&
          settings.hubToken.isNotEmpty &&
          settings.hubMachineId.isNotEmpty) {
        try {
          hubResult = await HubPriceHistoryClient().synchronizeIncremental(
            endpoint: Uri.parse(settings.hubUrl),
            token: settings.hubToken,
            cancellation: _stopSignal.future,
            observations: localObservations,
            known: knownHub.observations,
            after: knownHub.through,
          );
          hubObservations = hubResult.observations;
        } on Object {
          // A disconnected optional hub must not disable local observations.
        }
      }
      if (hubObservations != null && hubObservations.isNotEmpty) {
        await coordinator.runWriter(() async {
          if (!requestIsCurrent()) {
            superseded = true;
            return;
          }
          await _mergeHubHistory(
            databaseFile.path,
            hubResult!,
            settings.hubUrl,
          );
          successfulObservationAtUtc = hubObservations!
              .map((item) => item.observedAtUtc)
              .reduce((a, b) => a.isAfter(b) ? a : b);
          final currentSlot = started.millisecondsSinceEpoch ~/ 21600000;
          succeeded = hubObservations.any(
            (item) => item.authority == 'hub' && item.slot >= currentSlot,
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
            settings.hubMachineId.isEmpty ? 'local' : settings.hubMachineId,
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

Future<void> _applyCatalog(
  String path,
  OpenRouterModelsResponse response,
  DateTime started,
  DateTime observed,
  String origin,
) => Isolate.run(() {
  final db = openFileBackedDatabase(File(path));
  try {
    PricingRepository(db).applyCatalog(
      response,
      startedAtUtc: started,
      observedAtUtc: observed,
      origin: origin,
    );
  } finally {
    db.close();
  }
});

Future<void> _mergeHubHistory(
  String path,
  HubPriceSyncResult snapshot,
  String url,
) => Isolate.run(() {
  final db = openFileBackedDatabase(File(path));
  try {
    PricingRepository(db).mergePriceObservations(
      snapshot.observations,
      hubUrl: url,
      through: snapshot.through,
      hubRevision: snapshot.revision,
    );
  } finally {
    db.close();
  }
});

Future<(List<PriceObservation>, HubPriceSyncResult)> _prepareHubHistory(
  String path,
  String origin,
  String url,
) => Isolate.run(() {
  final db = openFileBackedDatabase(File(path));
  try {
    final repository = PricingRepository(db);
    return (
      repository.localPriceObservationsForHub(origin),
      repository.hubSyncSnapshot(url),
    );
  } finally {
    db.close();
  }
});
