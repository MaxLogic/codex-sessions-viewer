import 'package:flutter/material.dart';

import '../database/database_migrator.dart';

class CodexSessionsViewerApp extends StatelessWidget {
  CodexSessionsViewerApp({
    super.key,
    Future<DatabaseStartupResult>? databaseStartup,
  }) : databaseStartup =
           databaseStartup ??
           Future.value(
             DatabaseStartupResult.ready(lastAppliedSchemaVersion: 0),
           );

  static const appTitle = 'Codex Session Viewer';
  static const nativeTitleBarEnabled = true;

  final Future<DatabaseStartupResult> databaseStartup;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appTitle,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: FutureBuilder<DatabaseStartupResult>(
        future: databaseStartup,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return FatalDatabaseScreen(
              error: _fatalErrorFromSnapshot(snapshot),
            );
          }
          if (!snapshot.hasData) {
            return const Scaffold(
              body: Center(child: Text('Loading database...')),
            );
          }
          final result = snapshot.requireData;
          if (!result.canStartNormalUi) {
            return FatalDatabaseScreen(error: result.fatalError!);
          }
          return const Scaffold(body: Center(child: Text(appTitle)));
        },
      ),
    );
  }
}

DatabaseFatalError _fatalErrorFromSnapshot(
  AsyncSnapshot<DatabaseStartupResult> snapshot,
) {
  final error = snapshot.error;
  if (error is DatabaseStartupException) {
    return DatabaseFatalError(
      summary: 'SQLite database startup failed.',
      databasePath: error.databasePath,
      lastAppliedSchemaVersion: 0,
      details: error.message,
    );
  }
  return DatabaseFatalError(
    summary: 'SQLite database startup failed.',
    databasePath: 'Unknown',
    lastAppliedSchemaVersion: 0,
    details: error.toString(),
  );
}

class FatalDatabaseScreen extends StatelessWidget {
  const FatalDatabaseScreen({super.key, required this.error});

  final DatabaseFatalError error;

  @override
  Widget build(BuildContext context) {
    final failingFile = error.failingMigrationFile ?? 'None';
    return Scaffold(
      body: Semantics(
        key: const Key('fatal-database-semantics'),
        container: true,
        label: 'Database error. ${error.summary}',
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Database error',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  _FatalDetail(label: 'Summary', value: error.summary),
                  _FatalDetail(
                    label: 'Database path',
                    value: error.databasePath,
                  ),
                  _FatalDetail(
                    label: 'Last applied schema version',
                    value: error.lastAppliedSchemaVersion.toString(),
                  ),
                  _FatalDetail(
                    label: 'Failing migration file',
                    value: failingFile,
                  ),
                  _FatalDetail(label: 'Details', value: error.details),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FatalDetail extends StatelessWidget {
  const _FatalDetail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelLarge),
          SelectableText(value),
        ],
      ),
    );
  }
}
