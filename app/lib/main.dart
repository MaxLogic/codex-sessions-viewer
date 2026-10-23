import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'src/background_collection/background_collection.dart';
import 'src/benchmark/scan_memory_benchmark.dart';
import 'src/database/database_migrator.dart';
import 'src/database/database_maintenance.dart';
import 'src/database/application_maintenance.dart';
import 'src/app/codex_sessions_viewer_app.dart';
import 'src/config/app_settings.dart';
import 'src/platform/application_working_directory.dart';
import 'src/platform/app_instance_lock.dart';
import 'src/window/window_state.dart';
import 'src/platform/startup_registration.dart';
import 'src/platform/wsl_default_distro_detector.dart';
import 'src/scanner/collector_process.dart';
import 'src/scanner/resident_collector_client.dart';
import 'src/app/runtime_session_controller.dart';

final _processLifetimeInstanceLocks = <AppInstanceLock>[];

Future<void> main(List<String> arguments) async {
  useExecutableDirectoryAsWorkingDirectory();
  if (arguments.contains(scanMemoryBenchmarkFlag)) {
    final request = ScanMemoryBenchmarkRequest.tryParse(arguments);
    exit(
      await (request == null
          ? Future<int>.value(64)
          : runScanMemoryBenchmark(request)),
    );
  }
  WidgetsFlutterBinding.ensureInitialized();
  final databaseFile = defaultDatabaseFile();
  final instanceLock = AppInstanceLock(
    File('${databaseFile.path}.instance.lock'),
  );
  if (!instanceLock.tryAcquire()) {
    exit(0);
  }
  _processLifetimeInstanceLocks.add(instanceLock);
  // The window store never creates settings.toml; the settings startup after
  // the first frame does, and fills the WSL defaults then.
  final windowStateController = AppWindowStateController(
    store: WindowStateStore(SettingsRepository(defaultSettingsFile())),
  );
  await restoreWindowStateBestEffort(windowStateController.restoreAndTrack);
  final sqlRoot = defaultSqlRoot();
  final startupRegistration = StartupRegistration.forCurrentPlatform();
  final resident = ResidentCollectorClient(
    databaseFile: databaseFile,
    settingsFile: defaultSettingsFile(),
    claudeRoots: RuntimeSessionController.defaultClaudeProjectRoots(),
  );
  final maintenance = ApplicationMaintenance(
    databaseFile: databaseFile,
    coordinator: DatabaseMaintenanceCoordinator(
      databaseFile,
      pauseCollector: resident.pause,
    ),
  );
  final settingsStartup = _afterFirstFrame(
    () => SettingsRepository(
      defaultSettingsFile(),
      wslDetector: WslDefaultDistroDetector.forCurrentPlatform(),
    ).loadOrCreate(),
  );
  runApp(
    CodexSessionsViewerApp(
      databaseFile: databaseFile,
      applicationMaintenance: maintenance,
      collectorClient: resident,
      backgroundCollection: CollectorBackgroundCollection(
        collectorExecutable: CollectorProcess.defaultExecutable(),
        databaseFile: databaseFile.absolute.path,
        settingsFile: defaultSettingsFile().absolute.path,
      ),
      settingsStartup: settingsStartup,
      databaseStartup: _afterFirstFrame(() async {
        await settingsStartup;
        return DatabaseMigrator(
          sqlRoot: sqlRoot,
          pauseCollector: resident.pause,
        ).openAndMigrate(databaseFile, deferUsageMigration: true);
      }),
      databaseMaintenanceStartup: () async => startPendingDatabaseMigration(
        databaseFile,
        sqlRoot: sqlRoot,
        pricingSettings: (await settingsStartup).pricing,
        coordinator: maintenance.coordinator,
      ),
      startupPreferenceApplier: (enabled) =>
          applyStartupPreferenceBestEffort(startupRegistration, enabled),
    ),
  );
}

Future<void> applyStartupPreferenceBestEffort(
  StartupRegistration startupRegistration,
  bool enabled,
) async {
  try {
    await startupRegistration.apply(enabled: enabled);
  } on Object catch (error, stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'codex_sessions_viewer',
        context: ErrorDescription('while applying the startup preference'),
      ),
    );
  }
}

Future<void> restoreWindowStateBestEffort(
  Future<void> Function() restore,
) async {
  try {
    await restore();
  } on Object {
    // Settings startup still owns user-visible configuration failures.
  }
}

Future<T> _afterFirstFrame<T>(Future<T> Function() work) {
  final completer = Completer<T>();
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Future<void>.microtask(() {
      Future<T>.sync(
        work,
      ).then(completer.complete, onError: completer.completeError);
    });
  });
  return completer.future;
}
