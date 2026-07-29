import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'src/benchmark/scan_memory_benchmark.dart';
import 'src/database/database_migrator.dart';
import 'src/app/codex_sessions_viewer_app.dart';
import 'src/config/app_settings.dart';
import 'src/platform/application_working_directory.dart';
import 'src/platform/app_instance_lock.dart';
import 'src/window/window_state.dart';
import 'src/platform/windows_startup_registration.dart';

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
  final windowStateController = AppWindowStateController(
    store: WindowStateStore(SettingsRepository(defaultSettingsFile())),
  );
  await restoreWindowStateBestEffort(windowStateController.restoreAndTrack);
  final sqlRoot = defaultSqlRoot();
  final startupRegistration = WindowsStartupRegistration();
  runApp(
    CodexSessionsViewerApp(
      settingsStartup: _afterFirstFrame(
        () => SettingsRepository(defaultSettingsFile()).loadOrCreate(),
      ),
      databaseStartup: _afterFirstFrame(
        () => DatabaseMigrator(sqlRoot: sqlRoot).openAndMigrate(databaseFile),
      ),
      startupPreferenceApplier: (enabled) =>
          applyWindowsStartupPreferenceBestEffort(startupRegistration, enabled),
    ),
  );
}

Future<void> applyWindowsStartupPreferenceBestEffort(
  WindowsStartupRegistration startupRegistration,
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
        context: ErrorDescription(
          'while applying the Windows startup preference',
        ),
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
