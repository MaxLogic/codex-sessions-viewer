import 'package:flutter/material.dart';

import 'src/database/database_migrator.dart';
import 'src/app/codex_sessions_viewer_app.dart';
import 'src/config/app_settings.dart';
import 'src/window/window_state.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppWindowStateController(
    store: WindowStateStore(SettingsRepository(defaultSettingsFile())),
  ).restoreAndTrack();
  final databaseFile = defaultDatabaseFile();
  final sqlRoot = defaultSqlRoot();
  runApp(
    CodexSessionsViewerApp(
      databaseStartup: DatabaseMigrator(
        sqlRoot: sqlRoot,
      ).openAndMigrate(databaseFile),
    ),
  );
}
