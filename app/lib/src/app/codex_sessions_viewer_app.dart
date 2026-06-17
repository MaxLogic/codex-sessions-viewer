import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sqlite3/sqlite3.dart';

import '../config/app_settings.dart';
import '../database/database_migrator.dart';
import '../app/runtime_session_controller.dart';
import '../ui/app_shell.dart';
import '../ui/screens/logs_screen.dart';
import '../ui/screens/sessions_screen.dart';
import '../ui/screens/settings_screen.dart';
import '../ui/screens/usage_screen.dart';
import '../ui/themes.dart';

class CodexSessionsViewerApp extends StatelessWidget {
  CodexSessionsViewerApp({
    super.key,
    Future<DatabaseStartupResult>? databaseStartup,
    File? settingsFile,
    File? databaseFile,
    Future<AppSettings>? settingsStartup,
    this.sessionRefresh,
  }) : databaseStartup =
           databaseStartup ??
           Future.value(
             DatabaseStartupResult.ready(lastAppliedSchemaVersion: 0),
           ),
       settingsFile = settingsFile ?? defaultSettingsFile(),
       databaseFile = databaseFile ?? defaultDatabaseFile(),
       settingsStartup =
           settingsStartup ??
           SettingsRepository(
             settingsFile ?? defaultSettingsFile(),
           ).loadOrCreate();

  static const appTitle = 'Codex Session Viewer';
  static const nativeTitleBarEnabled = true;

  final Future<DatabaseStartupResult> databaseStartup;
  final Future<AppSettings> settingsStartup;
  final File settingsFile;
  final File databaseFile;
  final Future<SessionsRefreshResult> Function()? sessionRefresh;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appTitle,
      debugShowCheckedModeBanner: false,
      theme: CodexAppTheme.themeData(CodexThemeMode.light),
      darkTheme: CodexAppTheme.themeData(CodexThemeMode.dark),
      highContrastTheme: CodexAppTheme.themeData(
        CodexThemeMode.highContrastLight,
      ),
      highContrastDarkTheme: CodexAppTheme.themeData(
        CodexThemeMode.highContrastDark,
      ),
      themeMode: CodexAppTheme.themeMode(CodexThemeMode.system),
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
          return FutureBuilder<AppSettings>(
            future: settingsStartup,
            initialData: AppSettings.defaults(),
            builder: (context, settingsSnapshot) {
              if (settingsSnapshot.hasError) {
                return FatalDatabaseScreen(
                  error: DatabaseFatalError(
                    summary: 'Settings startup failed.',
                    databasePath: settingsFile.path,
                    lastAppliedSchemaVersion: result.lastAppliedSchemaVersion,
                    details: settingsSnapshot.error.toString(),
                  ),
                );
              }
              final settings = settingsSnapshot.requireData;
              return CodexAppShell(
                sessionsScreenBuilder: (context, onOpenSettings) =>
                    _SessionsScreenLoader(
                      settings: settings,
                      settingsFile: settingsFile,
                      databaseFile: databaseFile,
                      onRefreshWithProgress: _sessionRefresh,
                      onOpenSettings: onOpenSettings,
                      onSessionAction: (request) =>
                          _handleSessionAction(request),
                      onTableStateChanged: (state) {
                        unawaited(_saveSessionTableState(state));
                      },
                    ),
                usageScreen: UsageScreen(),
                settingsScreen: SettingsScreen(initialSettings: settings),
                logsScreen: LogsScreen(),
              );
            },
          );
        },
      ),
    );
  }

  Future<SessionsRefreshResult> _sessionRefresh([
    SessionsRefreshProgressCallback? onProgress,
  ]) {
    final refresh = sessionRefresh;
    if (refresh != null) {
      return refresh();
    }
    return RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
    ).refreshInBackground(onProgress: onProgress);
  }

  Future<void> _handleSessionAction(SessionActionRequest request) async {
    final payload = request.payload;
    switch (request.action) {
      case SessionRowAction.copyPath:
      case SessionRowAction.copyPlainResumeCommand:
      case SessionRowAction.copyPlatformResumeCommand:
      case SessionRowAction.copyTerminalCommand:
        if (payload != null) {
          await Clipboard.setData(ClipboardData(text: payload));
        }
        return;
      case SessionRowAction.openPath:
        await _openPath(payload ?? request.row.sourcePathForDisplay);
        return;
      case SessionRowAction.openTerminalResume:
        if (payload != null) {
          await _runDetachedCommand(payload);
        }
        return;
      case SessionRowAction.togglePin:
        _updateSessionFlag(
          request.row.id,
          column: 'is_pinned',
          value: !request.row.isPinned,
        );
        return;
      case SessionRowAction.toggleArchive:
        _updateSessionFlag(
          request.row.id,
          column: 'is_archived',
          value: !request.row.isArchived,
        );
        return;
      case SessionRowAction.reparse:
        await RuntimeSessionController(
          settingsFile: settingsFile,
          databaseFile: databaseFile,
        ).refresh();
        return;
    }
  }

  Future<void> _openPath(String path) async {
    if (path.trim().isEmpty) {
      return;
    }
    await Process.start('explorer.exe', ['/select,', path]);
  }

  Future<void> _runDetachedCommand(String command) async {
    if (command.trim().isEmpty) {
      return;
    }
    await Process.start('cmd.exe', [
      '/c',
      command,
    ], mode: ProcessStartMode.detached);
  }

  void _updateSessionFlag(
    String sessionId, {
    required String column,
    required bool value,
  }) {
    assert(column == 'is_pinned' || column == 'is_archived');
    final db = sqlite3.open(databaseFile.path);
    try {
      db.execute(
        'update sessions set $column = ?, updated_at_utc = ? where id = ?',
        [value ? 1 : 0, DateTime.now().toUtc().toIso8601String(), sessionId],
      );
    } finally {
      db.close();
    }
  }

  Future<void> _saveSessionTableState(SessionTableSettings tableState) async {
    final repository = SettingsRepository(settingsFile);
    final settings = await repository.loadOrCreate();
    await repository.save(
      settings.copyWith(ui: settings.ui.copyWith(sessionTable: tableState)),
    );
  }
}

class _SessionsScreenLoader extends StatefulWidget {
  const _SessionsScreenLoader({
    required this.settings,
    required this.settingsFile,
    required this.databaseFile,
    required this.onRefreshWithProgress,
    required this.onOpenSettings,
    required this.onSessionAction,
    required this.onTableStateChanged,
  });

  final AppSettings settings;
  final File settingsFile;
  final File databaseFile;
  final SessionsRefreshWithProgress onRefreshWithProgress;
  final VoidCallback onOpenSettings;
  final SessionActionCallback onSessionAction;
  final SessionTableStateChanged onTableStateChanged;

  @override
  State<_SessionsScreenLoader> createState() => _SessionsScreenLoaderState();
}

class _SessionsScreenLoaderState extends State<_SessionsScreenLoader> {
  var _cachedRows = <SessionRowViewModel>[];
  var _cachedStatusMessage = '';
  var _cachedLoadGeneration = 0;
  var _autoRefreshToken = 0;

  @override
  void initState() {
    super.initState();
    _startCachedLoad();
  }

  @override
  void didUpdateWidget(covariant _SessionsScreenLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settingsFile.path != widget.settingsFile.path ||
        oldWidget.databaseFile.path != widget.databaseFile.path) {
      _startCachedLoad();
    }
  }

  RuntimeSessionController get _controller => RuntimeSessionController(
    settingsFile: widget.settingsFile,
    databaseFile: widget.databaseFile,
  );

  void _startCachedLoad() {
    final generation = ++_cachedLoadGeneration;
    setState(() {
      _cachedRows = const [];
      _cachedStatusMessage = 'Loading previous sessions...';
    });
    unawaited(_loadCachedRows(generation));
  }

  Future<void> _loadCachedRows(int generation) async {
    try {
      final result = await _controller.loadCachedRowsInBackground(
        onProgress: (progress) {
          if (!mounted || generation != _cachedLoadGeneration) {
            return;
          }
          setState(() {
            _cachedRows = progress.rows ?? _cachedRows;
            _cachedStatusMessage = progress.statusMessage;
          });
        },
      );
      if (!mounted || generation != _cachedLoadGeneration) {
        return;
      }
      setState(() {
        _cachedRows = result.rows;
        _cachedStatusMessage = '';
        _autoRefreshToken++;
      });
    } on Object catch (error) {
      if (!mounted || generation != _cachedLoadGeneration) {
        return;
      }
      setState(() {
        _cachedStatusMessage = 'Failed to load cached sessions. $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SessionsScreen(
      settings: widget.settings,
      initialRows: _cachedRows,
      initialStatusMessage: _cachedStatusMessage,
      autoRefreshToken: _autoRefreshToken,
      onRefreshWithProgress: widget.onRefreshWithProgress,
      onOpenSettings: widget.onOpenSettings,
      onSessionAction: widget.onSessionAction,
      onLoadSessionDetail: _controller.loadSessionDetail,
      initialTableState: widget.settings.ui.sessionTable,
      onTableStateChanged: widget.onTableStateChanged,
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
