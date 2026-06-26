import 'dart:async';

import 'package:flutter/material.dart';

import 'src/database/database_migrator.dart';
import 'src/app/codex_sessions_viewer_app.dart';
import 'src/config/app_settings.dart';
import 'src/window/window_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final windowStateController = AppWindowStateController(
    store: WindowStateStore(SettingsRepository(defaultSettingsFile())),
  );
  await restoreWindowStateBestEffort(windowStateController.restoreAndTrack);
  final databaseFile = defaultDatabaseFile();
  final sqlRoot = defaultSqlRoot();
  runApp(
    CodexSessionsViewerApp(
      settingsStartup: _afterFirstFrame(
        () => SettingsRepository(defaultSettingsFile()).loadOrCreate(),
      ),
      databaseStartup: _afterFirstFrame(
        () => DatabaseMigrator(sqlRoot: sqlRoot).openAndMigrate(databaseFile),
      ),
    ),
  );
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
