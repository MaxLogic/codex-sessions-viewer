import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_settings.dart';
import '../database/database_connection.dart';
import '../database/database_migrator.dart';
import '../database/project_tag_state.dart';
import '../app/runtime_session_controller.dart';
import '../pricing/pricing_repository.dart';
import '../ui/app_shell.dart';
import '../ui/screens/logs_screen.dart';
import '../ui/screens/sessions_screen.dart';
import '../ui/screens/settings_screen.dart';
import '../ui/screens/usage_screen.dart';
import '../ui/themes.dart';
import '../usage/usage_summary.dart';

typedef SessionCachedRowsLoader =
    Future<SessionsRefreshResult> Function(
      SessionsRefreshProgressCallback onProgress,
    );
typedef FrameDeferredCallback = void Function(VoidCallback callback);
typedef UsageSummaryLoader =
    Future<UsageSummary?> Function(AppSettings settings);

class CodexSessionsViewerApp extends StatefulWidget {
  CodexSessionsViewerApp({
    super.key,
    Future<DatabaseStartupResult>? databaseStartup,
    File? settingsFile,
    File? databaseFile,
    Future<AppSettings>? settingsStartup,
    this.sessionRefresh,
    this.sessionRefreshOperation,
    this.sessionCachedRowsLoader,
    this.deferInitialSessionLoad = _deferUntilAfterFirstFrame,
    this.settingsSave,
    this.settingsReload,
    this.usageSummaryLoader,
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
  final SessionsRefreshOperationFactory? sessionRefreshOperation;
  final SessionCachedRowsLoader? sessionCachedRowsLoader;
  final FrameDeferredCallback deferInitialSessionLoad;
  final SettingsSaveCallback? settingsSave;
  final SettingsReloadCallback? settingsReload;
  final UsageSummaryLoader? usageSummaryLoader;

  @override
  State<CodexSessionsViewerApp> createState() => _CodexSessionsViewerAppState();
}

class _CodexSessionsViewerAppState extends State<CodexSessionsViewerApp> {
  AppSettings? _settings;
  UsageSummary? _usageSummary;
  var _usageLoadGeneration = 0;
  var _usageLoadScheduled = false;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: CodexSessionsViewerApp.appTitle,
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
        future: widget.databaseStartup,
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
            future: widget.settingsStartup,
            initialData: AppSettings.defaults(),
            builder: (context, settingsSnapshot) {
              if (settingsSnapshot.hasError) {
                return FatalDatabaseScreen(
                  error: DatabaseFatalError(
                    summary: 'Settings startup failed.',
                    databasePath: widget.settingsFile.path,
                    lastAppliedSchemaVersion: result.lastAppliedSchemaVersion,
                    details: settingsSnapshot.error.toString(),
                  ),
                );
              }
              final settings =
                  _settings ?? settingsSnapshot.data ?? AppSettings.defaults();
              if (_settings == null &&
                  settingsSnapshot.connectionState == ConnectionState.done) {
                _settings = settings;
              }
              _startUsageSummaryLoad(settings);
              return CodexAppShell(
                motionMode: settings.ui.motion,
                sessionsScreenBuilder: (context, onOpenSettings) =>
                    _SessionsScreenLoader(
                      settings: settings,
                      settingsFile: widget.settingsFile,
                      databaseFile: widget.databaseFile,
                      onRefreshOperation: _sessionRefreshOperation,
                      onLoadCachedRows: widget.sessionCachedRowsLoader,
                      deferInitialLoad: widget.deferInitialSessionLoad,
                      onOpenSettings: onOpenSettings,
                      onSessionAction: (request) =>
                          _handleSessionAction(request),
                      onExportMarkdown: _exportConversationMarkdown,
                      onTableStateChanged: (state) {
                        unawaited(_saveSessionTableState(state));
                      },
                    ),
                usageScreen: UsageScreen(summary: _usageSummary),
                settingsScreen: SettingsScreen(
                  initialSettings: settings,
                  onSave: _saveSettings,
                  onReload: _reloadSettings,
                ),
                logsScreen: LogsScreen(),
              );
            },
          );
        },
      ),
    );
  }

  SessionsRefreshOperation _sessionRefreshOperation(
    SessionsRefreshProgressCallback onProgress,
  ) {
    final refreshOperation = widget.sessionRefreshOperation;
    SessionsRefreshOperation operation;
    if (refreshOperation != null) {
      operation = refreshOperation(onProgress);
    } else {
      final refresh = widget.sessionRefresh;
      if (refresh != null) {
        operation = SessionsRefreshOperation.fromFuture(refresh());
      } else {
        final runtimeOperation = RuntimeSessionController(
          settingsFile: widget.settingsFile,
          databaseFile: widget.databaseFile,
        ).startRefreshInBackgroundOperation(onProgress: onProgress);
        operation = SessionsRefreshOperation(
          result: runtimeOperation.result,
          cancel: runtimeOperation.cancel,
        );
      }
    }
    return SessionsRefreshOperation(
      result: operation.result.then((result) async {
        await _loadUsageSummary(_settings ?? AppSettings.defaults());
        return result;
      }),
      cancel: operation.cancel,
    );
  }

  Future<void> _saveSettings(AppSettings settings) async {
    final save = widget.settingsSave;
    if (save == null) {
      await SettingsRepository(widget.settingsFile).save(settings);
    } else {
      await save(settings);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _settings = settings;
    });
    unawaited(_loadUsageSummary(settings));
  }

  Future<AppSettings> _reloadSettings() async {
    final reload = widget.settingsReload;
    final settings = reload == null
        ? await SettingsRepository(widget.settingsFile).loadOrCreate()
        : await reload();
    if (mounted) {
      setState(() {
        _settings = settings;
      });
      unawaited(_loadUsageSummary(settings));
    }
    return settings;
  }

  void _startUsageSummaryLoad(AppSettings settings) {
    if (_usageSummary != null || _usageLoadScheduled) {
      return;
    }
    _usageLoadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_loadUsageSummary(settings));
      }
    });
  }

  Future<void> _loadUsageSummary(AppSettings settings) async {
    final generation = ++_usageLoadGeneration;
    final loader = widget.usageSummaryLoader;
    if (loader != null) {
      final summary = await loader(settings);
      if (!mounted || generation != _usageLoadGeneration) {
        return;
      }
      setState(() {
        _usageSummary = summary;
      });
      return;
    }
    await _loadUsageSummaryFromDatabase(settings, generation);
  }

  Future<void> _loadUsageSummaryFromDatabase(
    AppSettings settings,
    int generation,
  ) async {
    final db = openFileBackedDatabase(widget.databaseFile);
    try {
      final pricing = PricingRepository(db).loadCached(settings.pricing);
      final summary = UsageSummaryRepository(db).summarize(
        UsageSummaryRequest(
          period: UsagePeriod.last30Days,
          nowUtc: DateTime.now().toUtc(),
        ),
        pricing: pricing,
      );
      if (!mounted || generation != _usageLoadGeneration) {
        return;
      }
      setState(() {
        _usageSummary = summary;
      });
    } on Object {
      if (!mounted || generation != _usageLoadGeneration) {
        return;
      }
      setState(() {
        _usageSummary = null;
      });
    } finally {
      db.close();
    }
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
      case SessionRowAction.editTags:
        await _editSessionTags(request.row);
        return;
      case SessionRowAction.openPath:
        await _openPath(payload ?? request.row.sourcePathForDisplay);
        return;
      case SessionRowAction.openTerminalResume:
      case SessionRowAction.openTerminalFork:
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
          settingsFile: widget.settingsFile,
          databaseFile: widget.databaseFile,
        ).refresh();
        return;
    }
  }

  Future<void> _editSessionTags(SessionRowViewModel row) async {
    final controller = TextEditingController(text: row.tags.join(', '));
    final tags = await showDialog<List<String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit tags'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Tags',
            helperText: 'Separate tags with commas.',
          ),
          onSubmitted: (_) =>
              Navigator.of(context).pop(_parseTagInput(controller.text)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(_parseTagInput(controller.text)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (tags == null) {
      return;
    }
    final db = openFileBackedDatabase(widget.databaseFile);
    try {
      ProjectTagStateStore(db).setSessionTags(row.id, tags);
    } finally {
      db.close();
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Session tags updated.')));
  }

  Future<void> _openPath(String path) async {
    final trimmed = path.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final targetType = await FileSystemEntity.type(trimmed);
    if (targetType == FileSystemEntityType.directory) {
      await Process.start('explorer.exe', [trimmed]);
      return;
    }
    await Process.start('explorer.exe', ['/select,', trimmed]);
  }

  Future<void> _exportConversationMarkdown(
    SessionRowViewModel row,
    String markdown,
  ) async {
    final destination = await getSaveLocation(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'Markdown', extensions: ['md', 'markdown']),
      ],
      suggestedName: _exportFileName(row),
      confirmButtonText: 'Export',
    );
    if (destination == null) {
      return;
    }
    await File(destination.path).writeAsString(markdown);
  }

  String _exportFileName(SessionRowViewModel row) {
    final base = [
      row.lastMessageAtUtc.toUtc().toIso8601String().replaceAll(':', '-'),
      row.project.trim(),
      row.title.trim(),
      row.sessionId.trim(),
    ].where((part) => part.isNotEmpty).join('-');
    final sanitized = base
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .trim();
    return '${sanitized.isEmpty ? row.id : sanitized}.md';
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
    final db = openFileBackedDatabase(widget.databaseFile);
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
    final repository = SettingsRepository(widget.settingsFile);
    final settings = await repository.loadOrCreate();
    final next = settings.copyWith(
      ui: settings.ui.copyWith(sessionTable: tableState),
    );
    await repository.save(next);
    if (!mounted) {
      return;
    }
    setState(() {
      _settings = next;
    });
  }
}

class _SessionsScreenLoader extends StatefulWidget {
  const _SessionsScreenLoader({
    required this.settings,
    required this.settingsFile,
    required this.databaseFile,
    required this.onRefreshOperation,
    this.onLoadCachedRows,
    required this.deferInitialLoad,
    required this.onOpenSettings,
    required this.onSessionAction,
    required this.onExportMarkdown,
    required this.onTableStateChanged,
  });

  final AppSettings settings;
  final File settingsFile;
  final File databaseFile;
  final SessionsRefreshOperationFactory onRefreshOperation;
  final SessionCachedRowsLoader? onLoadCachedRows;
  final FrameDeferredCallback deferInitialLoad;
  final VoidCallback onOpenSettings;
  final SessionActionCallback onSessionAction;
  final SessionMarkdownExportCallback onExportMarkdown;
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
    widget.deferInitialLoad(_startCachedLoad);
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
    if (!mounted) {
      return;
    }
    final generation = ++_cachedLoadGeneration;
    setState(() {
      _cachedRows = const [];
      _cachedStatusMessage = 'Loading previous sessions...';
    });
    unawaited(_loadCachedRows(generation));
  }

  Future<void> _loadCachedRows(int generation) async {
    try {
      final cachedRowsLoader =
          widget.onLoadCachedRows ?? _controller.loadCachedRowsInBackground;
      final result = await cachedRowsLoader(
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
      onRefreshOperation: widget.onRefreshOperation,
      onOpenSettings: widget.onOpenSettings,
      onSessionAction: _handleSessionAction,
      onLoadSessionDetail: _controller.loadSessionDetail,
      initialTableState: widget.settings.ui.sessionTable,
      onTableStateChanged: widget.onTableStateChanged,
    );
  }

  Future<void> _handleSessionAction(SessionActionRequest request) async {
    await widget.onSessionAction(request);
    if (!mounted || request.action != SessionRowAction.editTags) {
      return;
    }
    _startCachedLoad();
  }
}

void _deferUntilAfterFirstFrame(VoidCallback callback) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Future<void>.microtask(callback);
  });
}

List<String> _parseTagInput(String value) {
  final tags = {
    for (final tag in value.split(',').map((tag) => tag.trim()))
      if (tag.isNotEmpty) tag,
  }.toList()..sort();
  return tags;
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
