import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show AppExitResponse;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../config/app_settings.dart';
import '../config/settings_diagnostics.dart';
import '../commands/resume_command_generator.dart';
import '../database/database_connection.dart';
import '../database/application_maintenance.dart';
import '../database/database_maintenance.dart';
import '../database/database_migrator.dart';
import '../database/project_tag_state.dart';
import '../database/session_eval_state.dart';
import '../app/runtime_session_controller.dart';
import '../export/eval_dataset_exporter.dart';
import '../parser/codex_session_parser.dart';
import '../platform/terminal_launcher.dart';
import '../pricing/pricing_repository.dart';
import '../search/message_search.dart';
import '../ui/app_shell.dart';
import '../ui/screens/context_search_screen.dart';
import '../ui/screens/evals_screen.dart';
import '../ui/screens/logs_screen.dart';
import '../ui/screens/sessions_screen.dart';
import '../ui/screens/settings_screen.dart';
import '../ui/screens/usage_screen.dart';
import '../ui/themes.dart';
import '../ui/widgets/database_migration_progress.dart';
import '../usage/usage_summary.dart';

typedef SessionCachedRowsLoader =
    Future<SessionsRefreshResult> Function(
      SessionsRefreshProgressCallback onProgress,
    );
typedef FrameDeferredCallback = void Function(VoidCallback callback);
typedef UsageSummaryLoader =
    Future<UsageSummary?> Function(
      AppSettings settings,
      UsageSummaryRequest request,
    );
typedef StartupPreferenceApplier = Future<void> Function(bool enabled);
typedef TerminalLaunchCallback = Future<int> Function(TerminalLaunchSpec spec);
typedef DatabaseMaintenanceStartup =
    Future<DatabaseMaintenanceOperation?> Function();

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
    this.databaseMaintenanceStartup,
    this.writerCoordinator,
    this.applicationMaintenance,
    this.startupPreferenceApplier = _ignoreStartupPreference,
    this.terminalLaunch = _launchTerminal,
    this.now = DateTime.now,
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
  final DatabaseMaintenanceStartup? databaseMaintenanceStartup;
  final DatabaseMaintenanceCoordinator? writerCoordinator;
  final ApplicationMaintenance? applicationMaintenance;
  final StartupPreferenceApplier startupPreferenceApplier;
  final TerminalLaunchCallback terminalLaunch;
  final DateTime Function() now;

  @override
  State<CodexSessionsViewerApp> createState() => _CodexSessionsViewerAppState();
}

class _CodexSessionsViewerAppState extends State<CodexSessionsViewerApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  late final DatabaseMaintenanceCoordinator _writerCoordinator;
  AppSettings? _settings;
  UsageSummary? _usageSummary;
  UsageSummaryRequest? _usageRequest;
  var _usageIsRefreshing = false;
  var _usageRefreshFailed = false;
  var _usageLoadGeneration = 0;
  var _usageLoadScheduled = false;
  bool? _lastSyncedStartupPreference;
  CodexAppSection? _requestedSection;
  var _sectionRequestSerial = 0;
  SessionOpenTarget? _sessionOpenTarget;
  var _sessionOpenTargetSerial = 0;
  CancellableMessageSearchBackfillOperation? _messageSearchBackfill;
  SessionsRefreshOperation? _activeSessionRefreshOperation;
  final _databaseMaintenanceProgress =
      ValueNotifier<DatabaseMaintenanceProgress?>(null);
  Future<DatabaseMaintenanceResult?>? _databaseMaintenanceFuture;
  Future<void>? _scheduleStartup;
  DatabaseMaintenanceOperation? _databaseMaintenanceOperation;
  StreamSubscription<DatabaseMaintenanceProgress>?
  _databaseMaintenanceSubscription;
  late final AppLifecycleListener _lifecycleListener;
  Future<AppExitResponse>? _exitPreparation;
  var _exitRequested = false;
  var _seenMaintenanceRevision = 0;
  var _pricingRevision = 0;
  var _pricingUpdating = false;
  var _synchronizingPricing = false;
  var _maintenanceUsageReloadScheduled = false;

  @override
  void initState() {
    super.initState();
    assert(
      widget.writerCoordinator == null ||
          widget.applicationMaintenance == null ||
          identical(
            widget.writerCoordinator,
            widget.applicationMaintenance!.coordinator,
          ),
      'writerCoordinator must match applicationMaintenance.coordinator.',
    );
    _writerCoordinator =
        widget.applicationMaintenance?.coordinator ??
        widget.writerCoordinator ??
        DatabaseMaintenanceCoordinator(widget.databaseFile);
    _lifecycleListener = AppLifecycleListener(onExitRequested: _prepareForExit);
    _seenMaintenanceRevision = widget.applicationMaintenance?.dataRevision ?? 0;
    widget.applicationMaintenance?.addListener(_maintenanceChanged);
  }

  void _maintenanceChanged() {
    if (!mounted || _exitRequested) return;
    final maintenance = widget.applicationMaintenance;
    final progress = maintenance?.progress;
    final updating =
        _synchronizingPricing ||
        (progress?.state == DatabaseMaintenanceState.running &&
            (progress?.phase == 'catalog_apply' ||
                progress?.phase == 'reprice_costs'));
    final revision = maintenance?.dataRevision ?? 0;
    final changed = revision != _seenMaintenanceRevision;
    final wasUpdating = _pricingUpdating;
    setState(() {
      _pricingUpdating = updating;
      _seenMaintenanceRevision = revision;
      if (changed) _pricingRevision++;
      if (changed || updating != wasUpdating) {
        _usageSummary = null;
        _usageLoadGeneration++;
        _usageIsRefreshing = updating;
      }
    });
    if (!updating &&
        (changed || wasUpdating) &&
        !_maintenanceUsageReloadScheduled) {
      _maintenanceUsageReloadScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _maintenanceUsageReloadScheduled = false;
        final settings = _settings;
        if (mounted && !_exitRequested && settings != null) {
          unawaited(_loadUsageSummary(settings));
        }
      });
    }
  }

  Future<AppExitResponse> _prepareForExit() =>
      _exitPreparation ??= _prepareForExitOnce();

  Future<AppExitResponse> _prepareForExitOnce() async {
    _exitRequested = true;
    final refreshStop = _cancelAndJoinRefresh(_activeSessionRefreshOperation);
    final backfillStop = _messageSearchBackfill?.cancel();
    final startupMaintenanceStop = _databaseMaintenanceOperation?.requestStop();
    final scheduledMaintenanceStop = widget.applicationMaintenance?.stop();
    await Future.wait([
      refreshStop,
      ?backfillStop,
      ?startupMaintenanceStop,
      ?scheduledMaintenanceStop,
    ]);
    try {
      await _databaseMaintenanceFuture;
    } on Object {
      // Startup failures leave the prior database generation intact.
    }
    await _writerCoordinator.idle;
    return AppExitResponse.exit;
  }

  Future<void> _cancelAndJoinRefresh(
    SessionsRefreshOperation? operation,
  ) async {
    if (operation == null) return;
    try {
      await operation.cancel();
    } on Object {
      // The result join below still owns graceful shutdown.
    }
    try {
      await operation.result;
    } on Object {
      // A failed or cancelled refresh has still released its database handle.
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _scaffoldMessengerKey,
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
          return FutureBuilder<DatabaseMaintenanceResult?>(
            future: widget.databaseMaintenanceStartup == null
                ? null
                : _ensureDatabaseMaintenanceStarted(),
            builder: (context, maintenanceSnapshot) {
              if (maintenanceSnapshot.hasError) {
                return FatalDatabaseScreen(
                  error: DatabaseFatalError(
                    summary: 'Database maintenance startup failed.',
                    databasePath: widget.databaseFile.path,
                    lastAppliedSchemaVersion: result.lastAppliedSchemaVersion,
                    details: maintenanceSnapshot.error.toString(),
                  ),
                );
              }
              final maintenanceResult = maintenanceSnapshot.data;
              if (widget.databaseMaintenanceStartup != null &&
                  (maintenanceSnapshot.connectionState !=
                          ConnectionState.done ||
                      (maintenanceResult != null &&
                          !maintenanceResult.succeeded))) {
                return DatabaseMigrationProgressHost(
                  progress: _databaseMaintenanceProgress,
                  onStop: () async =>
                      _databaseMaintenanceOperation?.requestStop(),
                  onResume: _restartDatabaseMaintenance,
                  onRetry: _restartDatabaseMaintenance,
                  child: const Scaffold(
                    body: Center(
                      child: Text('Preparing database maintenance...'),
                    ),
                  ),
                );
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
                        lastAppliedSchemaVersion:
                            result.lastAppliedSchemaVersion,
                        details: settingsSnapshot.error.toString(),
                      ),
                    );
                  }
                  final settings =
                      _settings ??
                      settingsSnapshot.data ??
                      AppSettings.defaults();
                  Widget readyShell() {
                    if (_settings == null &&
                        settingsSnapshot.connectionState ==
                            ConnectionState.done) {
                      _settings = settings;
                      _syncStartupPreferenceLater(settings);
                    }
                    _startUsageSummaryLoad(settings);
                    _startMessageSearchBackfill();
                    return CodexAppShell(
                      motionMode: settings.ui.motion,
                      requestedSection: _requestedSection,
                      sectionRequestSerial: _sectionRequestSerial,
                      sessionsScreenBuilder: (context, onOpenSettings) =>
                          _SessionsScreenLoader(
                            settings: settings,
                            settingsFile: widget.settingsFile,
                            databaseFile: widget.databaseFile,
                            writerCoordinator: _writerCoordinator,
                            pricingRevision: _pricingRevision,
                            pricingUpdating: _pricingUpdating,
                            onRefreshOperation: _sessionRefreshOperation,
                            onLoadCachedRows: widget.sessionCachedRowsLoader,
                            deferInitialLoad: widget.deferInitialSessionLoad,
                            onOpenSettings: onOpenSettings,
                            onSessionAction: (request) =>
                                _handleSessionAction(request),
                            onExportMarkdown: _exportConversationMarkdown,
                            onSaveSessionListCsv: _saveSessionListCsv,
                            onTableStateChanged: (state) {
                              unawaited(_saveSessionTableState(state));
                            },
                            openTarget: _sessionOpenTarget,
                            openTargetSerial: _sessionOpenTargetSerial,
                            now: widget.now,
                          ),
                      evalsScreen: _EvalsScreenLoader(
                        settingsFile: widget.settingsFile,
                        databaseFile: widget.databaseFile,
                        writerCoordinator: _writerCoordinator,
                        onLoadCachedRows: widget.sessionCachedRowsLoader,
                        deferInitialLoad: widget.deferInitialSessionLoad,
                        onUpdateEvalMetadata: (row, metadata) async =>
                            _updateEvalMetadata(row.id, metadata),
                        onExport: _exportEvalDataset,
                      ),
                      contextScreen: _ContextSearchLoader(
                        settingsFile: widget.settingsFile,
                        databaseFile: widget.databaseFile,
                        writerCoordinator: _writerCoordinator,
                        onLoadCachedRows: widget.sessionCachedRowsLoader,
                        deferInitialLoad: widget.deferInitialSessionLoad,
                        onOpenResult: _openContextResult,
                      ),
                      usageScreen: UsageScreen(
                        summary: _usageSummary,
                        request: _usageRequest,
                        isRefreshing: _usageIsRefreshing,
                        refreshFailed: _usageRefreshFailed,
                        onPeriodChanged: (request) {
                          _usageRequest = request;
                          // A snapshot from another range must not appear under
                          // the new selection, even if the reload fails.
                          _usageSummary = null;
                          unawaited(_loadUsageSummary(settings));
                        },
                      ),
                      settingsScreen: SettingsScreen(
                        initialSettings: settings,
                        diagnostics: DatabaseSettingsDiagnostics(
                          widget.databaseFile,
                          refreshPrices:
                              widget.applicationMaintenance?.refreshPrices,
                        ),
                        maintenanceSchedules:
                            widget.applicationMaintenance?.schedules ??
                            const [],
                        maintenanceProgress:
                            widget.applicationMaintenance?.progress,
                        onSave: _saveSettings,
                        onReload: _reloadSettings,
                      ),
                      logsScreen: LogsScreen(),
                    );
                  }

                  final maintenance = widget.applicationMaintenance;
                  if (maintenance == null) return readyShell();
                  if (settingsSnapshot.connectionState !=
                      ConnectionState.done) {
                    return const Scaffold(
                      body: Center(child: Text('Loading settings...')),
                    );
                  }
                  _scheduleStartup ??= maintenance.configure(settings).then((
                    _,
                  ) {
                    if (mounted && !_exitRequested) maintenance.start();
                  });
                  return FutureBuilder<void>(
                    future: _scheduleStartup,
                    builder: (context, scheduleSnapshot) {
                      if (scheduleSnapshot.hasError) {
                        return FatalDatabaseScreen(
                          error: DatabaseFatalError(
                            summary:
                                'Database maintenance configuration failed.',
                            databasePath: widget.databaseFile.path,
                            lastAppliedSchemaVersion:
                                result.lastAppliedSchemaVersion,
                            details:
                                'Saved pricing policy could not be synchronized. Normal database access remains disabled.',
                          ),
                        );
                      }
                      if (scheduleSnapshot.connectionState !=
                          ConnectionState.done) {
                        return const Scaffold(
                          body: Center(
                            child: Text(
                              'Synchronizing pricing and maintenance...',
                            ),
                          ),
                        );
                      }
                      return readyShell();
                    },
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    widget.applicationMaintenance?.removeListener(_maintenanceChanged);
    _lifecycleListener.dispose();
    unawaited(widget.applicationMaintenance?.stop());
    unawaited(_databaseMaintenanceOperation?.requestStop());
    unawaited(_messageSearchBackfill?.cancel());
    unawaited(_cancelAndJoinRefresh(_activeSessionRefreshOperation));
    unawaited(_databaseMaintenanceSubscription?.cancel());
    _databaseMaintenanceProgress.dispose();
    super.dispose();
  }

  Future<DatabaseMaintenanceResult?> _ensureDatabaseMaintenanceStarted() {
    final existing = _databaseMaintenanceFuture;
    if (existing != null) {
      return existing;
    }
    _databaseMaintenanceProgress.value = const DatabaseMaintenanceProgress(
      state: DatabaseMaintenanceState.running,
      phase: 'Preparing',
      currentWork: 'Checking whether database maintenance is required.',
      unitLabel: 'items',
      completedUnits: 0,
      totalUnits: null,
      ratePerSecond: null,
      elapsed: Duration.zero,
      estimatedRemaining: null,
      walBytes: 0,
    );
    return _databaseMaintenanceFuture = _runDatabaseMaintenance();
  }

  Future<DatabaseMaintenanceResult?> _runDatabaseMaintenance() async {
    final operation = await widget.databaseMaintenanceStartup!();
    if (operation == null) {
      if (mounted) _databaseMaintenanceProgress.value = null;
      return null;
    }
    if (!mounted || _exitRequested) {
      await operation.requestStop();
      if (!mounted) return operation.result;
    }
    _databaseMaintenanceOperation = operation;
    await _databaseMaintenanceSubscription?.cancel();
    _databaseMaintenanceSubscription = operation.progress.listen((progress) {
      if (mounted) _databaseMaintenanceProgress.value = progress;
    });
    final result = await operation.result;
    if (mounted &&
        !result.succeeded &&
        _databaseMaintenanceProgress.value?.state ==
            DatabaseMaintenanceState.running) {
      _databaseMaintenanceProgress.value = DatabaseMaintenanceProgress(
        state: result.state,
        phase: result.state == DatabaseMaintenanceState.failed
            ? 'Failed'
            : 'Interrupted',
        currentWork:
            result.errorMessage ??
            'Database maintenance stopped at a durable checkpoint.',
        unitLabel: 'items',
        completedUnits: _databaseMaintenanceProgress.value?.completedUnits ?? 0,
        totalUnits: _databaseMaintenanceProgress.value?.totalUnits,
        ratePerSecond: null,
        elapsed: _databaseMaintenanceProgress.value?.elapsed ?? Duration.zero,
        estimatedRemaining: null,
        walBytes: _databaseMaintenanceProgress.value?.walBytes ?? 0,
        errorMessage: result.errorMessage,
      );
    }
    return result;
  }

  Future<void> _restartDatabaseMaintenance() async {
    await _databaseMaintenanceSubscription?.cancel();
    _databaseMaintenanceSubscription = null;
    _databaseMaintenanceOperation = null;
    setState(() {
      _databaseMaintenanceFuture = null;
    });
  }

  void _startMessageSearchBackfill() {
    if (_exitRequested || _messageSearchBackfill != null) {
      return;
    }
    _messageSearchBackfill = RuntimeSessionController(
      settingsFile: widget.settingsFile,
      databaseFile: widget.databaseFile,
      writerCoordinator: _writerCoordinator,
    ).startMessageSearchBackfillInBackgroundOperation();
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
          writerCoordinator: _writerCoordinator,
        ).startRefreshInBackgroundOperation(onProgress: onProgress);
        operation = SessionsRefreshOperation(
          result: runtimeOperation.result,
          cancel: runtimeOperation.cancel,
        );
      }
    }
    late final SessionsRefreshOperation trackedOperation;
    Future<void>? cancellation;
    trackedOperation = SessionsRefreshOperation(
      result: operation.result
          .then((result) {
            unawaited(_loadUsageSummary(_settings ?? AppSettings.defaults()));
            return result;
          })
          .whenComplete(() {
            if (identical(_activeSessionRefreshOperation, trackedOperation)) {
              _activeSessionRefreshOperation = null;
            }
          }),
      cancel: () => cancellation ??= Future<void>.sync(operation.cancel),
    );
    _activeSessionRefreshOperation = trackedOperation;
    return trackedOperation;
  }

  Future<void> _saveSettings(AppSettings settings) async {
    final save = widget.settingsSave;
    if (save == null) {
      await SettingsRepository(widget.settingsFile).save(settings);
    } else {
      await save(settings);
    }
    await _synchronizeMaintenanceSettings(settings);
    await _syncStartupPreference(settings);
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
    await _synchronizeMaintenanceSettings(settings);
    await _syncStartupPreference(settings);
    if (mounted) {
      setState(() {
        _settings = settings;
      });
      unawaited(_loadUsageSummary(settings));
    }
    return settings;
  }

  Future<void> _synchronizeMaintenanceSettings(AppSettings settings) async {
    final maintenance = widget.applicationMaintenance;
    if (maintenance == null) return;
    if (mounted) {
      setState(() {
        _synchronizingPricing = true;
        _pricingUpdating = true;
        _usageSummary = null;
        _usageLoadGeneration++;
      });
    }
    try {
      await maintenance.configure(settings);
    } finally {
      if (mounted) {
        setState(() {
          _synchronizingPricing = false;
          _pricingUpdating = false;
          _pricingRevision++;
        });
      }
    }
  }

  void _syncStartupPreferenceLater(AppSettings settings) {
    unawaited(
      _syncStartupPreference(settings).catchError((
        Object error,
        StackTrace stack,
      ) {
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
      }),
    );
  }

  Future<void> _syncStartupPreference(AppSettings settings) async {
    final enabled = settings.app.startWithWindows;
    if (_lastSyncedStartupPreference == enabled) {
      return;
    }
    await widget.startupPreferenceApplier(enabled);
    _lastSyncedStartupPreference = enabled;
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
    if (_pricingUpdating || _exitRequested) return;
    final generation = ++_usageLoadGeneration;
    final request = UsageSummaryRequest(
      period: _usageRequest?.period ?? UsagePeriod.last30Days,
      nowUtc: DateTime.now().toUtc(),
      customStartUtc: _usageRequest?.customStartUtc,
      customEndExclusiveUtc: _usageRequest?.customEndExclusiveUtc,
      projectionVersion: CodexSessionParser.currentVersion,
    );
    if (mounted) {
      setState(() {
        _usageIsRefreshing = true;
        _usageRefreshFailed = false;
      });
    }
    try {
      final loader = widget.usageSummaryLoader;
      final summary = loader == null
          ? await _loadUsageSummaryFromDatabase(settings, request)
          : await loader(settings, request);
      if (!mounted || generation != _usageLoadGeneration) {
        return;
      }
      setState(() {
        _usageSummary = summary;
      });
    } on Object {
      if (mounted && generation == _usageLoadGeneration) {
        setState(() {
          _usageRefreshFailed = true;
        });
      }
    } finally {
      if (mounted && generation == _usageLoadGeneration) {
        setState(() {
          _usageIsRefreshing = false;
        });
      }
    }
  }

  Future<UsageSummary> _loadUsageSummaryFromDatabase(
    AppSettings settings,
    UsageSummaryRequest request,
  ) async {
    final databasePath = widget.databaseFile.path;
    return Isolate.run(() {
      final db = openFileBackedDatabase(File(databasePath));
      try {
        db.execute('pragma query_only = on');
        return UsageSummaryRepository(db).summarize(
          request,
          pricing: PricingRepository(db).loadCached(settings.pricing),
        );
      } finally {
        db.close();
      }
    });
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
        final launchSpec = request.launchSpec;
        if (launchSpec == null) {
          await _showTerminalLaunchFailure(
            request,
            'No safe terminal launch arguments were generated.',
          );
        } else {
          await _runTerminal(request, launchSpec);
        }
        return;
      case SessionRowAction.togglePin:
        await _updateSessionFlag(
          request.row.id,
          column: 'is_pinned',
          value: !request.row.isPinned,
        );
        return;
      case SessionRowAction.toggleArchive:
        await _updateSessionFlag(
          request.row.id,
          column: 'is_archived',
          value: !request.row.isArchived,
        );
        return;
      case SessionRowAction.updateEvalMetadata:
        await _updateEvalMetadata(request.row.id, request.evalMetadata);
        return;
      case SessionRowAction.reparse:
        await RuntimeSessionController(
          settingsFile: widget.settingsFile,
          databaseFile: widget.databaseFile,
          writerCoordinator: _writerCoordinator,
        ).refresh();
        return;
    }
  }

  Future<void> _openContextResult(ContextOpenRequest request) async {
    setState(() {
      _sessionOpenTarget = SessionOpenTarget(
        sessionId: request.sessionId,
        messageIndex: request.messageIndex,
      );
      _sessionOpenTargetSerial++;
      _requestedSection = CodexAppSection.sessions;
      _sectionRequestSerial++;
    });
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
    await _writerCoordinator.runWriter(() async {
      final db = openFileBackedDatabase(widget.databaseFile);
      try {
        ProjectTagStateStore(db).setSessionTags(row.id, tags);
      } finally {
        db.close();
      }
    });
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

  Future<void> _saveSessionListCsv(String csv) async {
    final timestamp = widget.now().toUtc().toIso8601String().replaceAll(
      ':',
      '-',
    );
    final destination = await getSaveLocation(
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CSV', extensions: ['csv']),
      ],
      suggestedName: 'sessions-$timestamp.csv',
      confirmButtonText: 'Save',
    );
    if (destination == null) {
      return;
    }
    await File(destination.path).writeAsString(csv);
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

  Future<EvalsScreenExportResult> _exportEvalDataset(
    EvalsScreenExportRequest request,
  ) async {
    final destination = await getDirectoryPath(confirmButtonText: 'Export');
    if (destination == null) {
      return const EvalsScreenExportResult.cancelled();
    }
    final sessions = <EvalDatasetSession>[];
    var skipped = 0;
    final parser = CodexSessionParser();
    for (final row in request.rows) {
      final sourcePath = row.sourcePathForDisplay.trim();
      if (sourcePath.isEmpty) {
        skipped++;
        continue;
      }
      final result = await parser.parseFile(File(sourcePath));
      final session = result.session;
      if (session == null) {
        skipped++;
        continue;
      }
      sessions.add(
        EvalDatasetSession(
          session: session,
          expectedOutput: row.evalExpectedOutput.trim().isEmpty
              ? null
              : row.evalExpectedOutput,
          status: row.evalStatus.trim().isEmpty ? null : row.evalStatus,
          notes: row.evalNotes.trim().isEmpty ? null : row.evalNotes,
        ),
      );
    }
    final files = const EvalDatasetExporter().export(
      EvalDatasetExportRequest(
        sessions: sessions,
        format: request.format,
        turnMode: request.turnMode,
        options: request.options,
      ),
    );
    for (final entry in files.entries) {
      final file = File(p.join(destination, entry.key));
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    return EvalsScreenExportResult.completed(
      exportedCount: sessions.length,
      skippedCount: skipped,
    );
  }

  Future<void> _runTerminal(
    SessionActionRequest request,
    TerminalLaunchSpec launchSpec,
  ) async {
    try {
      await widget.terminalLaunch(launchSpec);
    } on Object catch (error) {
      await _showTerminalLaunchFailure(request, error.toString());
      return;
    }
    if (!mounted) {
      return;
    }
    _scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text('Opening terminal for ${request.row.primaryIdentity}.'),
      ),
    );
  }

  Future<void> _showTerminalLaunchFailure(
    SessionActionRequest request,
    String details,
  ) async {
    if (!mounted) {
      return;
    }
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) {
      return;
    }
    await showDialog<void>(
      context: dialogContext,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Could not open terminal'),
        content: SelectableText(
          'The terminal could not be started.\n\n$details',
        ),
        actions: [
          if (request.payload case final command?)
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: command));
              },
              child: const Text('Copy resume command'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _updateSessionFlag(
    String sessionId, {
    required String column,
    required bool value,
  }) async {
    assert(column == 'is_pinned' || column == 'is_archived');
    await _writerCoordinator.runWriter(() async {
      final db = openFileBackedDatabase(widget.databaseFile);
      try {
        db.execute(
          'update sessions set $column = ?, updated_at_utc = ? where id = ?',
          [value ? 1 : 0, DateTime.now().toUtc().toIso8601String(), sessionId],
        );
      } finally {
        db.close();
      }
    });
  }

  Future<void> _updateEvalMetadata(
    String sessionId,
    SessionEvalMetadata? metadata,
  ) async {
    if (metadata == null) {
      return;
    }
    await _writerCoordinator.runWriter(() async {
      final db = openFileBackedDatabase(widget.databaseFile);
      try {
        SessionEvalStateStore(db).setEvalMetadata(
          sessionId,
          evalReady: metadata.evalReady,
          status: metadata.status,
          notes: metadata.notes,
          expectedOutput: metadata.expectedOutput,
          reviewedAtUtc: metadata.reviewedAtUtc,
        );
      } finally {
        db.close();
      }
    });
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

Future<void> _ignoreStartupPreference(bool enabled) async {}

Future<int> _launchTerminal(TerminalLaunchSpec spec) {
  return const TerminalLauncher().launch(spec);
}

class _SessionsScreenLoader extends StatefulWidget {
  const _SessionsScreenLoader({
    required this.settings,
    required this.settingsFile,
    required this.databaseFile,
    required this.writerCoordinator,
    required this.pricingRevision,
    required this.pricingUpdating,
    required this.onRefreshOperation,
    this.onLoadCachedRows,
    required this.deferInitialLoad,
    required this.onOpenSettings,
    required this.onSessionAction,
    required this.onExportMarkdown,
    required this.onSaveSessionListCsv,
    required this.onTableStateChanged,
    required this.openTarget,
    required this.openTargetSerial,
    required this.now,
  });

  final AppSettings settings;
  final File settingsFile;
  final File databaseFile;
  final DatabaseMaintenanceCoordinator writerCoordinator;
  final int pricingRevision;
  final bool pricingUpdating;
  final SessionsRefreshOperationFactory onRefreshOperation;
  final SessionCachedRowsLoader? onLoadCachedRows;
  final FrameDeferredCallback deferInitialLoad;
  final VoidCallback onOpenSettings;
  final SessionActionCallback onSessionAction;
  final SessionMarkdownExportCallback onExportMarkdown;
  final SessionListCsvExportCallback onSaveSessionListCsv;
  final SessionTableStateChanged onTableStateChanged;
  final SessionOpenTarget? openTarget;
  final int openTargetSerial;
  final DateTime Function() now;

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
    writerCoordinator: widget.writerCoordinator,
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
      pricingRevision: widget.pricingRevision,
      pricingUpdating: widget.pricingUpdating,
      onLoadPersistedCosts: _controller.loadPersistedSessionCosts,
      onRefreshOperation: widget.onRefreshOperation,
      onOpenSettings: widget.onOpenSettings,
      onSessionAction: _handleSessionAction,
      onSaveSessionListCsv: widget.onSaveSessionListCsv,
      onLoadSessionDetail: _controller.loadSessionDetail,
      onReloadSessionDetailFromSource:
          _controller.reloadSessionDetailFromSource,
      onLoadMessagePage: _controller.loadMessagePage,
      onLoadAllMessages: _controller.loadAllMessages,
      initialTableState: widget.settings.ui.sessionTable,
      onTableStateChanged: widget.onTableStateChanged,
      openTarget: widget.openTarget,
      openTargetSerial: widget.openTargetSerial,
      now: widget.now,
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

class _ContextSearchLoader extends StatefulWidget {
  const _ContextSearchLoader({
    required this.settingsFile,
    required this.databaseFile,
    required this.writerCoordinator,
    this.onLoadCachedRows,
    required this.deferInitialLoad,
    required this.onOpenResult,
  });

  final File settingsFile;
  final File databaseFile;
  final DatabaseMaintenanceCoordinator writerCoordinator;
  final SessionCachedRowsLoader? onLoadCachedRows;
  final FrameDeferredCallback deferInitialLoad;
  final ContextOpenCallback onOpenResult;

  @override
  State<_ContextSearchLoader> createState() => _ContextSearchLoaderState();
}

class _ContextSearchLoaderState extends State<_ContextSearchLoader> {
  var _cachedRows = <SessionRowViewModel>[];
  var _cachedStatusMessage = '';
  var _cachedLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.deferInitialLoad(_startCachedLoad);
  }

  @override
  void didUpdateWidget(covariant _ContextSearchLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settingsFile.path != widget.settingsFile.path ||
        oldWidget.databaseFile.path != widget.databaseFile.path) {
      _startCachedLoad();
    }
  }

  RuntimeSessionController get _controller => RuntimeSessionController(
    settingsFile: widget.settingsFile,
    databaseFile: widget.databaseFile,
    writerCoordinator: widget.writerCoordinator,
  );

  void _startCachedLoad() {
    if (!mounted) {
      return;
    }
    final generation = ++_cachedLoadGeneration;
    setState(() {
      _cachedRows = const [];
      _cachedStatusMessage = 'Loading context sessions...';
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
      });
    } on Object catch (error) {
      if (!mounted || generation != _cachedLoadGeneration) {
        return;
      }
      setState(() {
        _cachedStatusMessage = 'Failed to load context sessions. $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ContextSearchScreen(
      initialSessionRows: _cachedRows,
      statusMessage: _cachedStatusMessage,
      onSearchMessages: _searchMessages,
      onOpenResult: widget.onOpenResult,
    );
  }

  Future<List<MessageSearchResult>> _searchMessages(
    MessageSearchQuery query,
  ) async {
    final db = openFileBackedDatabase(widget.databaseFile);
    try {
      return MessageSearchIndex(db).search(query);
    } finally {
      db.close();
    }
  }
}

class _EvalsScreenLoader extends StatefulWidget {
  const _EvalsScreenLoader({
    required this.settingsFile,
    required this.databaseFile,
    required this.writerCoordinator,
    this.onLoadCachedRows,
    required this.deferInitialLoad,
    required this.onUpdateEvalMetadata,
    required this.onExport,
  });

  final File settingsFile;
  final File databaseFile;
  final DatabaseMaintenanceCoordinator writerCoordinator;
  final SessionCachedRowsLoader? onLoadCachedRows;
  final FrameDeferredCallback deferInitialLoad;
  final EvalMetadataUpdateCallback onUpdateEvalMetadata;
  final EvalsExportCallback onExport;

  @override
  State<_EvalsScreenLoader> createState() => _EvalsScreenLoaderState();
}

class _EvalsScreenLoaderState extends State<_EvalsScreenLoader> {
  var _cachedRows = <SessionRowViewModel>[];
  var _cachedStatusMessage = '';
  var _cachedLoadGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.deferInitialLoad(_startCachedLoad);
  }

  @override
  void didUpdateWidget(covariant _EvalsScreenLoader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settingsFile.path != widget.settingsFile.path ||
        oldWidget.databaseFile.path != widget.databaseFile.path) {
      _startCachedLoad();
    }
  }

  RuntimeSessionController get _controller => RuntimeSessionController(
    settingsFile: widget.settingsFile,
    databaseFile: widget.databaseFile,
    writerCoordinator: widget.writerCoordinator,
  );

  void _startCachedLoad() {
    if (!mounted) {
      return;
    }
    final generation = ++_cachedLoadGeneration;
    setState(() {
      _cachedRows = const [];
      _cachedStatusMessage = 'Loading eval sessions...';
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
      });
    } on Object catch (error) {
      if (!mounted || generation != _cachedLoadGeneration) {
        return;
      }
      setState(() {
        _cachedStatusMessage = 'Failed to load eval sessions. $error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return EvalsScreen(
      initialRows: _cachedRows,
      statusMessage: _cachedStatusMessage,
      onUpdateEvalMetadata: widget.onUpdateEvalMetadata,
      onExport: widget.onExport,
    );
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
