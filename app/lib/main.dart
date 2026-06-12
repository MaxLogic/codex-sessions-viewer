import 'package:flutter/material.dart';

import 'src/database/database_migrator.dart';
import 'src/app/codex_sessions_viewer_app.dart';

void main() {
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
