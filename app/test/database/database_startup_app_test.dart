import 'dart:async';

import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders normal shell after database startup succeeds', (
    tester,
  ) async {
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 1),
        ),
      ),
    );

    await tester.pump();

    expect(find.text(CodexSessionsViewerApp.appTitle), findsOneWidget);
    expect(find.text('Database error'), findsNothing);
  });

  testWidgets('blocks normal shell with fatal database details', (
    tester,
  ) async {
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.blocked(
            DatabaseFatalError(
              summary: 'SQLite FTS5 is unavailable.',
              databasePath: r'C:\data\viewer.sqlite',
              lastAppliedSchemaVersion: 2,
              failingMigrationFile: '002_bad.sql',
              details: 'no such module: fts5',
            ),
          ),
        ),
      ),
    );

    await tester.pump();

    expect(find.text(CodexSessionsViewerApp.appTitle), findsNothing);
    expect(find.text('Database error'), findsOneWidget);
    expect(find.text('SQLite FTS5 is unavailable.'), findsOneWidget);
    expect(find.text(r'C:\data\viewer.sqlite'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('002_bad.sql'), findsOneWidget);
    expect(find.text('no such module: fts5'), findsOneWidget);

    final semantics = tester.getSemantics(
      find.byKey(const Key('fatal-database-semantics')),
    );
    expect(semantics.label, contains('Database error'));
  });

  testWidgets('turns startup future errors into fatal database details', (
    tester,
  ) async {
    final startup = Completer<DatabaseStartupResult>();
    await tester.pumpWidget(
      CodexSessionsViewerApp(databaseStartup: startup.future),
    );

    startup.completeError(
      const DatabaseStartupException(
        databasePath: r'C:\blocked\viewer.sqlite',
        message: 'Access is denied',
      ),
    );
    await tester.pump();

    expect(find.text('Database error'), findsOneWidget);
    expect(find.text('SQLite database startup failed.'), findsOneWidget);
    expect(find.text(r'C:\blocked\viewer.sqlite'), findsOneWidget);
    expect(find.text('Access is denied'), findsOneWidget);
  });
}
