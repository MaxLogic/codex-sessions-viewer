import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show sqlite3, OpenMode;

import '../config/app_settings.dart';
import '../database/database_connection.dart';
import '../database/database_generation.dart';
import '../database/database_maintenance.dart';
import '../database/project_tag_state.dart';
import '../database/session_cache_repair.dart';
import '../database/session_list_query.dart';
import '../logging/structured_logger.dart';
import '../parser/codex_session_parser.dart';
import '../path_mapping/path_mapper.dart';
import '../pricing/pricing_repository.dart';
import '../scanner/scan_batching.dart';
import '../scanner/session_index_reader.dart';
import '../scanner/session_scanner.dart';
import '../search/message_search.dart';
import '../search/session_search.dart';
import '../usage/usage_summary.dart';
import '../ui/models/conversation_message_view_model.dart';
import '../ui/models/projects_repository.dart';
import '../ui/models/session_project_change.dart';
import '../ui/screens/sessions_screen.dart';
import '../utils/injected_context_filter.dart';
import '../utils/profiling.dart';

const _conversationTailBodyPageSize = 50;
const _conversationMessagePageRadius = 25;

class RuntimeSessionController implements ProjectsRepository {
  RuntimeSessionController({
    required this.settingsFile,
    required this.databaseFile,
    this.scanBatchingPolicy = defaultScanBatchingPolicy,
    this.wslProjectResolver = const ProcessWslProjectResolver(),
    this.parserWorkerCountOverride,
    this.writerCoordinator,
  }) : assert(
         parserWorkerCountOverride == null || parserWorkerCountOverride > 0,
       );

  final File settingsFile;
  final File databaseFile;
  final ScanBatchingPolicy scanBatchingPolicy;
  final WslProjectResolver wslProjectResolver;
  final int? parserWorkerCountOverride;
  final DatabaseMaintenanceCoordinator? writerCoordinator;
  SendPort? _backgroundWriterPort;

  /// Whether the UI already holds the cached session rows, so a rescan can
  /// skip resending the full list before it starts scanning.
  var _rowsDelivered = false;

  /// Whether a scan first reports every cached row. Background scans turn
  /// this off once the UI has rows.
  var emitCachedRowsAtScanStart = true;

  Future<T> _runWrite<T>(Future<T> Function() work) =>
      writerCoordinator?.runWriter(work) ?? work();

  Future<T> _writeScan<T>(Future<T> Function() work) async {
    final owner = _backgroundWriterPort;
    if (owner == null) {
      return writerCoordinator?.runWriter(
            work,
            priority: DatabaseWriterPriority.scan,
          ) ??
          work();
    }
    final granted = ReceivePort();
    SendPort? release;
    try {
      owner.send(_BackgroundScanWriteRequest(granted.sendPort));
      release = await granted.first as SendPort;
      return await work();
    } finally {
      release?.send(null);
      granted.close();
    }
  }

  CancellableSessionScanOperation startRefreshOperation({
    SessionsRefreshProgressCallback? onProgress,
  }) {
    final cancellation = ScanCancellationController();
    Future<SessionsRefreshResult> work() =>
        _refresh(onProgress: onProgress, cancellationToken: cancellation.token);
    final result = writerCoordinator?.runScan(work) ?? work();
    return CancellableSessionScanOperation._(result, cancellation.cancel);
  }

  CancellableSessionScanOperation startRefreshInBackgroundOperation({
    SessionsRefreshProgressCallback? onProgress,
  }) {
    return _BackgroundSessionScanOperation.start(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
      scanBatchingPolicy: scanBatchingPolicy,
      onProgress: onProgress,
      writerCoordinator: writerCoordinator,
    );
  }

  Future<Map<String, UsageCostEstimate>?> loadPersistedSessionCosts(
    Iterable<String> sessionIds,
  ) {
    final path = databaseFile.path;
    final ids = sessionIds.toList(growable: false);
    return Isolate.run(() {
      final db = sqlite3.open(path, mode: OpenMode.readOnly);
      try {
        db.execute('pragma busy_timeout = $defaultSqliteBusyTimeoutMs');
        return UsageSummaryRepository(db).loadPersistedSessionCosts(
          ids,
          projectionVersion: CodexSessionParser.currentVersion,
        );
      } finally {
        db.close();
      }
    });
  }

  Future<SessionsRefreshResult> loadCachedRows() {
    return _runWrite(
      () => Profiling.spanAsync('scan.runtime.load_cached_rows', () async {
        final db = openFileBackedDatabase(databaseFile);
        try {
          _cleanSessionMetadataPlaceholders(db);
          await _backfillAutomaticProjects(
            db,
            wslProjects: _WslProjectResolutionCache(wslProjectResolver),
          );
          final rows = _loadRowsProfiled(db);
          return SessionsRefreshResult(
            rows: rows,
            statusMessage: rows.isEmpty
                ? ''
                : 'Loaded ${rows.length} of ${rows.length} sessions from the previous scan.',
          );
        } finally {
          db.close();
        }
      }),
    );
  }

  Future<SessionsRefreshResult> loadCachedRowsInBackground({
    SessionsRefreshProgressCallback? onProgress,
    int batchSize = 250,
  }) => _runWrite(
    () => _loadCachedRowsInBackground(
      onProgress: onProgress,
      batchSize: batchSize,
    ),
  );

  Future<SessionsRefreshResult> _loadCachedRowsInBackground({
    SessionsRefreshProgressCallback? onProgress,
    required int batchSize,
  }) {
    return Profiling.spanAsync('scan.runtime.load_cached_rows', () async {
      final messages = ReceivePort();
      final errors = ReceivePort();
      final exits = ReceivePort();
      Isolate? isolate;
      try {
        isolate = await Isolate.spawn<_BackgroundCachedRowsRequest>(
          _backgroundCachedRowsEntry,
          _BackgroundCachedRowsRequest(
            databaseFilePath: databaseFile.path,
            sendPort: messages.sendPort,
            batchSize: batchSize,
          ),
          onError: errors.sendPort,
          onExit: exits.sendPort,
        );

        final result = Completer<SessionsRefreshResult>();
        late StreamSubscription<Object?> messageSubscription;
        late StreamSubscription<Object?> errorSubscription;
        late StreamSubscription<Object?> exitSubscription;

        void finishError(Object error, [StackTrace? stackTrace]) {
          if (!result.isCompleted) {
            result.completeError(error, stackTrace);
          }
        }

        final loaded = <SessionRowViewModel>[];
        var loadedTotal = 0;
        var reportedCount = 0;
        final sinceReport = Stopwatch();
        void report() {
          reportedCount = loaded.length;
          sinceReport
            ..reset()
            ..start();
          onProgress?.call(
            SessionsRefreshProgress(
              rows: List.unmodifiable(loaded),
              statusMessage:
                  'Loaded ${loaded.length} of $loadedTotal sessions from the previous scan.',
            ),
          );
        }

        messageSubscription = messages.listen((message) {
          if (message is _BackgroundCachedRowsBatch) {
            loaded.addAll(message.rows);
            loadedTotal = message.total;
            // The first batch shows immediately; later ones are coalesced so
            // the list is not rebuilt for every 250 rows.
            if (reportedCount == 0 ||
                sinceReport.elapsed >= _cachedRowsProgressInterval) {
              report();
            }
            return;
          }
          if (message is _BackgroundCachedRowsDone) {
            if (loaded.length != reportedCount) {
              report();
            }
            _rowsDelivered = true;
            if (!result.isCompleted) {
              result.complete(
                SessionsRefreshResult(
                  rows: List.unmodifiable(loaded),
                  statusMessage: '',
                ),
              );
            }
            return;
          }
          if (message is _BackgroundRefreshError) {
            finishError(
              StateError(message.error),
              StackTrace.fromString(message.stackTrace),
            );
          }
        });
        errorSubscription = errors.listen((message) {
          finishError(
            StateError('Background cached session load failed. $message'),
          );
        });
        exitSubscription = exits.listen((_) {
          if (!result.isCompleted) {
            finishError(
              StateError(
                'Background cached session load exited before completion.',
              ),
            );
          }
        });

        return await result.future.whenComplete(() async {
          await messageSubscription.cancel();
          await errorSubscription.cancel();
          await exitSubscription.cancel();
        });
      } finally {
        messages.close();
        errors.close();
        exits.close();
        isolate?.kill(priority: Isolate.immediate);
      }
    });
  }

  Future<SessionRowViewModel?> loadSessionDetail(String sessionId) {
    return Profiling.spanAsync('scan.runtime.load_session_detail', () async {
      return _loadSessionDetailInBackground(
        sessionId: sessionId,
        reloadFromSource: false,
      );
    }, arguments: {'session_id': sessionId});
  }

  /// Loads every message body of a session, for export and
  /// find-in-conversation over paged sessions.
  Future<List<ConversationMessageViewModel>> loadAllMessages(String sessionId) {
    return Profiling.spanAsync('scan.runtime.load_all_messages', () async {
      final db = openFileBackedDatabase(databaseFile);
      try {
        return _loadMessages(db, sessionId, tailBodyPageSize: null);
      } finally {
        db.close();
      }
    }, arguments: {'session_id': sessionId});
  }

  Future<List<ConversationMessageViewModel>> loadMessagePage(
    String sessionId,
    int anchorMessageNumber,
  ) {
    return Profiling.spanAsync(
      'scan.runtime.load_message_page',
      () async {
        final db = openFileBackedDatabase(databaseFile);
        try {
          return _loadMessagePage(db, sessionId, anchorMessageNumber);
        } finally {
          db.close();
        }
      },
      arguments: {
        'session_id': sessionId,
        'anchor_message_number': anchorMessageNumber,
      },
    );
  }

  Future<SessionRowViewModel?> _loadSessionDetailInBackground({
    required String sessionId,
    required bool reloadFromSource,
  }) async {
    final messages = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<_BackgroundSessionDetailRequest>(
        _backgroundSessionDetailEntry,
        _BackgroundSessionDetailRequest(
          settingsFilePath: settingsFile.path,
          databaseFilePath: databaseFile.path,
          sessionId: sessionId,
          reloadFromSource: reloadFromSource,
          sendPort: messages.sendPort,
        ),
        onError: errors.sendPort,
        onExit: exits.sendPort,
      );

      final result = Completer<SessionRowViewModel?>();
      late StreamSubscription<Object?> messageSubscription;
      late StreamSubscription<Object?> errorSubscription;
      late StreamSubscription<Object?> exitSubscription;

      void finishError(Object error, [StackTrace? stackTrace]) {
        if (!result.isCompleted) {
          result.completeError(error, stackTrace);
        }
      }

      messageSubscription = messages.listen((message) {
        if (message is _BackgroundSessionDetailDone) {
          if (!result.isCompleted) {
            result.complete(message.row);
          }
          return;
        }
        if (message is _BackgroundRefreshError) {
          finishError(
            StateError(message.error),
            StackTrace.fromString(message.stackTrace),
          );
        }
      });
      errorSubscription = errors.listen((message) {
        finishError(
          StateError('Background session detail load failed. $message'),
        );
      });
      exitSubscription = exits.listen((_) {
        if (!result.isCompleted) {
          finishError(
            StateError(
              'Background session detail load exited before completion.',
            ),
          );
        }
      });

      return await result.future.whenComplete(() async {
        await messageSubscription.cancel();
        await errorSubscription.cancel();
        await exitSubscription.cancel();
      });
    } finally {
      messages.close();
      errors.close();
      exits.close();
      isolate?.kill(priority: Isolate.immediate);
    }
  }

  static Future<SessionRowViewModel?> _loadSessionDetailOnWorker({
    required File settingsFile,
    required File databaseFile,
    required String sessionId,
  }) {
    return Profiling.spanAsync(
      'scan.runtime.load_session_detail.worker',
      () async {
        final settings = await Profiling.spanAsync(
          'scan.runtime.load_session_detail.settings',
          () => SettingsRepository(settingsFile).loadOrCreate(),
        );
        final db = Profiling.spanSync(
          'scan.runtime.load_session_detail.open_db',
          () => openFileBackedDatabase(databaseFile),
        );
        try {
          final pricing = Profiling.spanSync(
            'scan.runtime.load_session_detail.pricing',
            () => PricingRepository(db).loadCached(settings.pricing),
          );
          final rows = Profiling.spanSync(
            'scan.runtime.load_session_detail.row_and_messages',
            () => _loadRowsProfiled(
              db,
              sessionId: sessionId,
              includeMessages: true,
              pricing: pricing,
            ),
          );
          if (rows.isEmpty) {
            return null;
          }
          return rows.single;
        } finally {
          db.close();
        }
      },
    );
  }

  Future<SessionRowViewModel?> reloadSessionDetailFromSource(String sessionId) {
    return _runWrite(
      () => Profiling.spanAsync('scan.runtime.reload_session_detail', () async {
        return _loadSessionDetailInBackground(
          sessionId: sessionId,
          reloadFromSource: true,
        );
      }, arguments: {'session_id': sessionId}),
    );
  }

  static Future<SessionRowViewModel?> _reloadSessionDetailFromSourceOnWorker({
    required File settingsFile,
    required File databaseFile,
    required String sessionId,
  }) {
    return Profiling.spanAsync(
      'scan.runtime.reload_session_detail.worker',
      () async {
        final settings = await Profiling.spanAsync(
          'scan.runtime.reload_session_detail.settings',
          () => SettingsRepository(settingsFile).loadOrCreate(),
        );
        final db = Profiling.spanSync(
          'scan.runtime.reload_session_detail.open_db',
          () => openFileBackedDatabase(databaseFile),
        );
        try {
          final sourceRow = Profiling.spanSync(
            'scan.runtime.reload_session_detail.source_row',
            () => db.select(
              '''
            select
              id,
              source_type,
              source_state,
              source_file_path,
              source_file_unc_path,
              display_path,
              platform_path
            from sessions
            where id = ?
            limit 1
            ''',
              [sessionId],
            ),
          );
          if (sourceRow.isEmpty) {
            return null;
          }
          final row = sourceRow.single;
          final sourcePath = row['source_file_path'] as String? ?? '';
          if (sourcePath.trim().isEmpty || !File(sourcePath).existsSync()) {
            return null;
          }
          final parseResult = await Profiling.spanAsync(
            'scan.runtime.reload_session_detail.parse_file',
            () => CodexSessionParser().parseFile(File(sourcePath)),
          );
          if (!parseResult.isSuccess) {
            return null;
          }
          final sourceType = row['source_type'] == 'wsl'
              ? SessionSourceType.wsl
              : SessionSourceType.windows;
          final mappedPath = MappedSessionPath(
            sourceType: sourceType,
            displayPath: row['display_path'] as String? ?? sourcePath,
            sourceFilePath: sourcePath,
            sourceFileUncPath: row['source_file_unc_path'] as String?,
            platformPath: row['platform_path'] as String? ?? sourcePath,
            normalizedPathKeys: {
              normalizePathKey(sourcePath),
              normalizePathKey(row['display_path'] as String? ?? sourcePath),
              normalizePathKey(row['platform_path'] as String? ?? sourcePath),
              if ((row['source_file_unc_path'] as String?) case final unc?)
                normalizePathKey(unc),
            },
          );
          final scannedSession = ScannedSessionFile.fromParseResult(
            sourcePath: sourcePath,
            sourceType: sourceType,
            sourceState: _sourceState(row['source_state'] as String?),
            mappedPath: mappedPath,
            parseResult: parseResult,
          );
          final projectResolver = await Profiling.spanAsync(
            'scan.runtime.reload_session_detail.project_resolver',
            () => _ProjectPathResolver.create(
              _projectPathCandidatesForSessions([scannedSession]),
              wslProjects: _WslProjectResolutionCache(
                const ProcessWslProjectResolver(),
              ),
            ),
          );
          final now = DateTime.now().toUtc().toIso8601String();
          Profiling.spanSync('scan.runtime.reload_session_detail.upsert', () {
            db.execute('begin');
            try {
              _upsertParsedSession(db, scannedSession, now, projectResolver);
              db.execute('commit');
            } on Object {
              db.execute('rollback');
              rethrow;
            }
          });
          final pricing = Profiling.spanSync(
            'scan.runtime.reload_session_detail.pricing',
            () => PricingRepository(db).loadCached(settings.pricing),
          );
          final rows = Profiling.spanSync(
            'scan.runtime.reload_session_detail.row_and_messages',
            () => _loadRowsProfiled(
              db,
              sessionId: sessionId,
              includeMessages: true,
              pricing: pricing,
            ),
          );
          if (rows.isEmpty) {
            return null;
          }
          return rows.single;
        } finally {
          db.close();
        }
      },
    );
  }

  Future<SessionsRefreshResult> refreshInBackground({
    SessionsRefreshProgressCallback? onProgress,
  }) {
    return startRefreshInBackgroundOperation(onProgress: onProgress).result;
  }

  CancellableMessageSearchBackfillOperation
  startMessageSearchBackfillInBackgroundOperation({
    int batchSize = 500,
    Duration pauseBetweenBatches = const Duration(milliseconds: 10),
  }) {
    return _BackgroundMessageSearchBackfillOperation.start(
      databaseFile: databaseFile,
      batchSize: batchSize,
      pauseBetweenBatches: pauseBetweenBatches,
      writerCoordinator: writerCoordinator,
    );
  }

  Future<SessionsRefreshResult> _refreshInBackground({
    SessionsRefreshProgressCallback? onProgress,
    required _BackgroundScanCancellationHandle cancellationHandle,
  }) async {
    final messages = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<_BackgroundRefreshRequest>(
        _backgroundRefreshEntry,
        _BackgroundRefreshRequest(
          settingsFilePath: settingsFile.path,
          databaseFilePath: databaseFile.path,
          sendPort: messages.sendPort,
          parsedSessionFlushBatchSize:
              scanBatchingPolicy.parsedSessionFlushBatchSize,
          parsedSessionFlushSourceBytes:
              scanBatchingPolicy.parsedSessionFlushSourceBytes,
          fullRowSnapshotBatchSize: scanBatchingPolicy.fullRowSnapshotBatchSize,
          coordinateWrites: writerCoordinator != null,
          emitCachedRowsAtScanStart: !_rowsDelivered,
        ),
        onError: errors.sendPort,
        onExit: exits.sendPort,
      );

      final result = Completer<SessionsRefreshResult>();
      SendPort? activeWriteRelease;
      late StreamSubscription<Object?> messageSubscription;
      late StreamSubscription<Object?> errorSubscription;
      late StreamSubscription<Object?> exitSubscription;

      void finishError(Object error, [StackTrace? stackTrace]) {
        activeWriteRelease?.send(null);
        if (!result.isCompleted) {
          result.completeError(error, stackTrace);
        }
      }

      messageSubscription = messages.listen((message) {
        if (message is _BackgroundScanWriteRequest) {
          unawaited(
            writerCoordinator!.runWriter(() async {
              if (result.isCompleted) return;
              final released = ReceivePort();
              try {
                activeWriteRelease = released.sendPort;
                message.grant.send(released.sendPort);
                // An unexpected worker exit must also release its queue slot.
                await released.first;
              } finally {
                activeWriteRelease = null;
                released.close();
              }
            }, priority: DatabaseWriterPriority.scan),
          );
          return;
        }
        if (message is _BackgroundRefreshProgress) {
          onProgress?.call(message.progress);
          return;
        }
        if (message is _BackgroundRefreshControl) {
          cancellationHandle.attach(message.cancelPort);
          return;
        }
        if (message is _BackgroundRefreshDone) {
          activeWriteRelease?.send(null);
          if (message.result.rows.isNotEmpty) {
            _rowsDelivered = true;
          }
          if (!result.isCompleted) {
            result.complete(message.result);
          }
          return;
        }
        if (message is _BackgroundRefreshError) {
          finishError(
            StateError(message.error),
            StackTrace.fromString(message.stackTrace),
          );
        }
      });
      errorSubscription = errors.listen((message) {
        finishError(StateError('Background scan failed. $message'));
      });
      exitSubscription = exits.listen((_) {
        if (!result.isCompleted) {
          finishError(StateError('Background scan exited before completion.'));
        }
      });

      return await result.future.whenComplete(() async {
        await messageSubscription.cancel();
        await errorSubscription.cancel();
        await exitSubscription.cancel();
      });
    } finally {
      messages.close();
      errors.close();
      exits.close();
      isolate?.kill(priority: Isolate.immediate);
    }
  }

  Future<SessionsRefreshResult> refresh({
    SessionsRefreshProgressCallback? onProgress,
  }) {
    return startRefreshOperation(onProgress: onProgress).result;
  }

  Future<int> upsertProjectMaskAndRecalculate({
    required int projectId,
    required String pathMask,
    int priority = 100,
    bool isActive = true,
  }) => _runWrite(() async {
    final settings = await SettingsRepository(settingsFile).loadOrCreate();
    final db = openFileBackedDatabase(databaseFile);
    try {
      final pricing = PricingRepository(db).loadCached(settings.pricing);
      return ProjectTagStateStore(db).upsertProjectMaskAndRecalculate(
        projectId: projectId,
        pathMask: pathMask,
        priority: priority,
        isActive: isActive,
        projectionVersion: CodexSessionParser.currentVersion,
        pricing: pricing,
      );
    } finally {
      db.close();
    }
  });

  Future<SessionProjectAssignment> loadSessionProjectAssignment(
    String sessionId,
  ) async {
    final db = openFileBackedDatabase(databaseFile);
    try {
      return ProjectTagStateStore(db).loadSessionProjectAssignment(sessionId);
    } finally {
      db.close();
    }
  }

  /// Applies a "Move to project" choice for [sessionId].
  Future<void> changeSessionProject(
    String sessionId,
    SessionProjectChange change,
  ) => _runWrite(() async {
    final settings = await SettingsRepository(settingsFile).loadOrCreate();
    final db = openFileBackedDatabase(databaseFile);
    try {
      final store = ProjectTagStateStore(db);
      final pricing = PricingRepository(db).loadCached(settings.pricing);
      switch (change) {
        case MoveSessionToProject(:final projectName):
          store.assignSessionProject(sessionId, projectName);
        case MoveFolderToProject(:final folder, :final projectName):
          store.assignFolderToProject(
            folder: folder,
            projectName: projectName,
            sessionId: sessionId,
            projectionVersion: CodexSessionParser.currentVersion,
            pricing: pricing,
          );
        case ResetSessionProject():
          store.resetSessionProject(sessionId);
        case RemoveFolderRule(:final folder):
          store.removeFolderRule(
            folder: folder,
            projectionVersion: CodexSessionParser.currentVersion,
            pricing: pricing,
          );
        case ManageProjectRules():
          break;
      }
    } finally {
      db.close();
    }
  });

  @override
  Future<List<ProjectSummary>> loadProjects() async =>
      (await _readProjectsInBackground(databaseFile.path, null))
          as List<ProjectSummary>;

  @override
  Future<ProjectDetail> loadProjectDetail(int projectId) async =>
      (await _readProjectsInBackground(databaseFile.path, projectId))
          as ProjectDetail;

  @override
  Future<ProjectRulesSnapshot> addFolderRule({
    required String folder,
    required String projectName,
  }) => _editProjects(
    (store, version, pricing) => store.assignFolderToProject(
      folder: folder,
      projectName: projectName,
      projectionVersion: version,
      pricing: pricing,
    ),
  );

  @override
  Future<ProjectRulesSnapshot> changeFolderRule({
    required String oldFolder,
    required String newFolder,
    required String projectName,
  }) => _editProjects(
    (store, version, pricing) => store.changeFolderRule(
      oldFolder: oldFolder,
      newFolder: newFolder,
      projectName: projectName,
      projectionVersion: version,
      pricing: pricing,
    ),
  );

  @override
  Future<ProjectRulesSnapshot> moveFolderRule({
    required String folder,
    required String projectName,
  }) => addFolderRule(folder: folder, projectName: projectName);

  @override
  Future<ProjectRulesSnapshot> removeFolderRule(String folder) => _editProjects(
    (store, version, pricing) => store.removeFolderRule(
      folder: folder,
      projectionVersion: version,
      pricing: pricing,
    ),
  );

  @override
  Future<ProjectRulesSnapshot> mergeProject({
    required int sourceProjectId,
    required String targetName,
  }) => _editProjects(
    (store, version, pricing) => store.mergeProject(
      sourceProjectId: sourceProjectId,
      targetName: targetName,
      projectionVersion: version,
      pricing: pricing,
    ),
  );

  @override
  Future<ProjectRulesSnapshot> resetManualSessions(int projectId) =>
      _editProjects(
        (store, version, pricing) =>
            store.resetManualSessions(projectId: projectId),
      );

  @override
  Future<void> restore(ProjectRulesSnapshot snapshot) => _editProjects(
    (store, version, pricing) => store.restoreProjectRules(
      snapshot,
      projectionVersion: version,
      pricing: pricing,
    ),
  );

  /// Runs [edit] in the writer queue and returns the rules from before it.
  Future<ProjectRulesSnapshot> _editProjects(
    void Function(
      ProjectTagStateStore store,
      int projectionVersion,
      UsagePricingCatalog pricing,
    )
    edit,
  ) => _runWrite(() async {
    final settings = await SettingsRepository(settingsFile).loadOrCreate();
    final db = openFileBackedDatabase(databaseFile);
    try {
      final store = ProjectTagStateStore(db);
      final before = store.snapshotProjectRules();
      edit(
        store,
        CodexSessionParser.currentVersion,
        PricingRepository(db).loadCached(settings.pricing),
      );
      return before;
    } finally {
      db.close();
    }
  });

  Future<SessionsRefreshResult> _refresh({
    SessionsRefreshProgressCallback? onProgress,
    required ScanCancellationToken cancellationToken,
  }) {
    return Profiling.spanAsync('scan.runtime.refresh', () async {
      final settings = await SettingsRepository(settingsFile).loadOrCreate();
      final db = openFileBackedDatabase(databaseFile);
      StructuredLogger? logger;
      int? scanRunId;
      var latestProgress = ScanProgress(startedAtUtc: DateTime.now().toUtc());
      try {
        await _writeScan(() async {
          ToolOutputSearchIndex(
            db,
          ).configure(enabled: settings.toolOutput.indexToolOutput);
        });
        final activeLogger = StructuredLogger(
          db: db,
          settings: settings.logging,
        );
        logger = activeLogger;
        final pricing = PricingRepository(db).loadCached(settings.pricing);
        final pendingParsedSessions = <ScannedSessionFile>[];
        var pendingParsedSourceBytes = 0;
        final parsedProjectCandidates = <_ParsedProjectCandidate>[];
        var persistenceFlushCount = 0;
        var fullRowSnapshotCount = 0;
        var lastFullRowSnapshotParsedCount = 0;
        var persistenceFlushQueue = Future<void>.value();
        final threadNamesBySessionId = await _readSessionIndexThreadNames(
          settings.paths,
        );
        final projectResolutionCache = _WslProjectResolutionCache(
          wslProjectResolver,
        );
        final activeScanRunId = await _writeScan(() async {
          _cleanSessionMetadataPlaceholders(db);
          return _startScanRun(db);
        });
        scanRunId = activeScanRunId;

        Future<void> persistParsedBatch(List<ScannedSessionFile> batch) async {
          if (batch.isEmpty) {
            return;
          }
          final currentFlush = persistenceFlushQueue.then((_) {
            return Profiling.spanAsync('scan.runtime.persist_flush', () {
              return _writeScan(() async {
                await _persistParsedSessions(
                  db,
                  batch,
                  threadNamesBySessionId: threadNamesBySessionId,
                  wslProjects: projectResolutionCache,
                  resolveWslProjects: false,
                );
                _updateScanRun(
                  db,
                  activeScanRunId,
                  latestProgress,
                  status: _ScanRunStatus.running,
                );
              });
            });
          });
          persistenceFlushQueue = currentFlush;
          await currentFlush;
          persistenceFlushCount++;
        }

        Future<void> flushParsedSessions(
          ScanProgress progress, {
          bool forceFullRowSnapshot = false,
          Future<void> Function()? beforeFullRowSnapshot,
        }) async {
          if (pendingParsedSessions.isNotEmpty) {
            final batch = List<ScannedSessionFile>.of(pendingParsedSessions);
            pendingParsedSessions.clear();
            pendingParsedSourceBytes = 0;
            await persistParsedBatch(batch);
          } else if (forceFullRowSnapshot) {
            await persistenceFlushQueue;
          }

          if (forceFullRowSnapshot) {
            await persistenceFlushQueue;
          }
          if (forceFullRowSnapshot && pendingParsedSessions.isNotEmpty) {
            final finalBatch = List<ScannedSessionFile>.of(
              pendingParsedSessions,
            );
            pendingParsedSessions.clear();
            pendingParsedSourceBytes = 0;
            await persistParsedBatch(finalBatch);
          }
          if (forceFullRowSnapshot) {
            await persistenceFlushQueue;
          }

          if (forceFullRowSnapshot) {
            await beforeFullRowSnapshot?.call();
          }

          if (onProgress != null &&
              scanBatchingPolicy.shouldEmitFullRowSnapshot(
                parsedCount: progress.filesParsed,
                lastSnapshotParsedCount: lastFullRowSnapshotParsedCount,
                force: forceFullRowSnapshot,
              )) {
            fullRowSnapshotCount++;
            lastFullRowSnapshotParsedCount = progress.filesParsed;
            onProgress(
              SessionsRefreshProgress(
                statusMessage: _progressStatusMessage(progress),
                rows: _loadRowsProfiled(db, pricing: pricing),
              ),
            );
          }
        }

        final cachedRows = emitCachedRowsAtScanStart
            ? _loadRowsProfiled(db, pricing: pricing)
            : const <SessionRowViewModel>[];
        if (onProgress != null && cachedRows.isNotEmpty) {
          onProgress(
            SessionsRefreshProgress(
              rows: cachedRows,
              statusMessage:
                  'Loaded ${cachedRows.length} of ${cachedRows.length} sessions from the previous scan. Scanning started.',
            ),
          );
        }

        await _writeScan(
          () => activeLogger.writeBestEffort(
            LogEntryDraft(
              level: LogLevel.info,
              category: LogCategory.scanner,
              message: 'Session scan started.',
              details: {
                'directory_workers': _defaultDirectoryWorkerCount(),
                'metadata_workers': _defaultMetadataWorkerCount(),
                'parser_workers': _defaultParserWorkerCount(),
                'parser_isolates': true,
              },
            ),
          ),
        );
        final mapper = CodexPathMapper(
          wslDistro: settings.wsl.distro,
          wslLinuxHome: settings.wsl.linuxHome,
          wslUncRoot: settings.wsl.linuxRootUnc,
        );
        final parserWorkerCount =
            parserWorkerCountOverride ?? _defaultParserWorkerCount();
        final directoryWorkerCount = _defaultDirectoryWorkerCount();
        final metadataWorkerCount = _defaultMetadataWorkerCount();
        final scanRoots = [
          ..._sessionScanRoots(
            settings.paths.windowsCodexPath,
            SessionSourceType.windows,
          ),
          ..._sessionScanRoots(
            settings.paths.wslCodexUncPath,
            SessionSourceType.wsl,
          ),
        ];
        final scanner = SessionScanner(
          parser: CodexSessionParser(
            maxToolOutputPreviewChars:
                settings.toolOutput.maxToolOutputPreviewChars,
          ),
          pathMapper: mapper,
          maxConcurrentParses: parserWorkerCount,
          maxConcurrentDirectoryScans: directoryWorkerCount,
          maxConcurrentMetadataChecks: metadataWorkerCount,
          retainParsedSessions: false,
          onProgress: onProgress == null
              ? null
              : (progress) {
                  latestProgress = progress;
                  onProgress(
                    SessionsRefreshProgress(
                      statusMessage: _progressStatusMessage(progress),
                    ),
                  );
                },
          onSessionParsed: (session, progress) async {
            pendingParsedSessions.add(session);
            pendingParsedSourceBytes += session.sourceSnapshotSize ?? 0;
            parsedProjectCandidates.add((
              sessionId: session.parsedSession.internalId,
              workingDirectory: session.parsedSession.workingDirectoryDisplay,
              sourceType: session.sourceType,
            ));
            if (scanBatchingPolicy.shouldFlushParsedSessions(
              pendingCount: pendingParsedSessions.length,
              pendingSourceBytes: pendingParsedSourceBytes,
            )) {
              await flushParsedSessions(progress);
            }
          },
        );
        final result = await Profiling.spanAsync(
          'scan.runtime.scanner_scan',
          () {
            return scanner.scan(
              SessionScanRequest(
                roots: scanRoots,
                cachedSessions: _cachedSessions(db),
                cancellationToken: cancellationToken,
              ),
            );
          },
        );
        onProgress?.call(
          const SessionsRefreshProgress(statusMessage: 'Finalizing scan...'),
        );
        await Profiling.spanAsync('scan.runtime.final_flush', () {
          return flushParsedSessions(
            result.progress,
            forceFullRowSnapshot: true,
            beforeFullRowSnapshot: () => Profiling.spanAsync(
              'scan.runtime.apply_resolved_projects',
              () => _applyResolvedProjectsForParsedCandidates(
                db,
                parsedProjectCandidates,
                wslProjects: projectResolutionCache,
                write: _writeScan,
              ),
            ),
          );
        });
        await Profiling.spanAsync('scan.runtime.persist_scan', () {
          return _writeScan(
            () => _persistScan(
              db,
              result,
              scanRunId: activeScanRunId,
              persistSessions: false,
              threadNamesBySessionId: threadNamesBySessionId,
              wslProjects: projectResolutionCache,
            ),
          );
        });
        await _writeScan(
          () async => _applySessionIndexThreadNames(db, threadNamesBySessionId),
        );
        try {
          final repair = await _writeScan(
            () => SessionCacheRepair(databaseFile: databaseFile).run(
              db: db,
              roots: scanRoots,
              discoveryComplete: result.canRunCacheRepair,
              isCancellationRequested: () =>
                  cancellationToken.isCancellationRequested,
              onProgress: (phase) {
                onProgress?.call(
                  SessionsRefreshProgress(
                    statusMessage: _cacheRepairProgressMessage(phase),
                  ),
                );
              },
            ),
          );
          final audit = repair.audit;
          await _writeScan(
            () => activeLogger.writeBestEffort(
              LogEntryDraft(
                level:
                    repair.status == SessionCacheRepairStatus.postponed &&
                        repair.reasonCode != 'cancelled'
                    ? LogLevel.warning
                    : LogLevel.info,
                category: LogCategory.database,
                message: repair.status == SessionCacheRepairStatus.postponed
                    ? 'Session cache repair postponed.'
                    : 'Session cache repair checked.',
                details: {
                  'status': repair.status.name,
                  'reason_code': repair.reasonCode,
                  'deleted_rows': repair.deletedCount,
                  if (audit != null)
                    for (final entry in audit.categoryCounts.entries)
                      'category_${entry.key.wireName}': entry.value,
                  if (repair.backupFile != null)
                    'backup_file': p.basename(repair.backupFile!.path),
                },
              ),
            ),
          );
        } on Object catch (error) {
          await _writeScan(
            () => activeLogger.writeBestEffort(
              LogEntryDraft(
                level: LogLevel.warning,
                category: LogCategory.database,
                message: 'Session cache repair postponed.',
                details: {
                  'status': 'postponed',
                  'reason_code': 'unexpected_repair_error',
                  'error_type': error.runtimeType.toString(),
                },
              ),
            ),
          );
        }
        final rows = Profiling.spanSync(
          'scan.runtime.final_load_rows',
          () => _loadRowsProfiled(db, pricing: pricing),
        );
        final refreshCancelled =
            result.cancelled || cancellationToken.isCancellationRequested;
        await Profiling.spanAsync('scan.runtime.write_finish_log', () {
          return _writeScan(
            () => activeLogger.writeBestEffort(
              LogEntryDraft(
                level: LogLevel.info,
                category: LogCategory.scanner,
                message: refreshCancelled
                    ? 'Session scan cancelled.'
                    : 'Session scan finished.',
                details: {
                  ..._progressLogDetails(result.progress),
                  'cancelled': refreshCancelled,
                  'visible_sessions': rows.length,
                  'directory_workers': directoryWorkerCount,
                  'metadata_workers': metadataWorkerCount,
                  'parser_workers': parserWorkerCount,
                },
              ),
            ),
          );
        });
        return SessionsRefreshResult(
          rows: rows,
          statusMessage: _statusMessage(
            result,
            visibleSessionCount: rows.length,
            cancelled: refreshCancelled,
          ),
          cancelled: refreshCancelled,
          persistenceFlushCount: persistenceFlushCount,
          fullRowSnapshotCount: fullRowSnapshotCount,
        );
      } on Object catch (error) {
        final progress = latestProgress.finish();
        final failedScanRunId = scanRunId;
        if (failedScanRunId != null) {
          try {
            await _writeScan(
              () async => _updateScanRun(
                db,
                failedScanRunId,
                progress,
                status: _ScanRunStatus.failed,
              ),
            );
          } on Object {
            // Preserve the scan failure even if failure bookkeeping also fails.
          }
        }
        await _writeScan(
          () async => logger?.writeBestEffort(
            LogEntryDraft(
              level: LogLevel.error,
              category: LogCategory.scanner,
              message: 'Session scan failed.',
              details: {
                ..._progressLogDetails(progress),
                'error_type': error.runtimeType.toString(),
              },
            ),
          ),
        );
        rethrow;
      } finally {
        db.close();
      }
    });
  }
}

abstract class WslProjectResolver {
  const WslProjectResolver();

  Future<Map<String, String>> resolveProjectNames(
    Iterable<String> workingDirectories,
  );
}

class ProcessWslProjectResolver extends WslProjectResolver {
  const ProcessWslProjectResolver();

  @override
  Future<Map<String, String>> resolveProjectNames(
    Iterable<String> workingDirectories,
  ) async {
    final paths = workingDirectories
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (paths.isEmpty) {
      return const {};
    }

    Process process;
    try {
      process = await Process.start('wsl.exe', [
        'sh',
        '-lc',
        _wslProjectResolutionScript,
      ]);
    } on Object {
      return const {};
    }

    try {
      final stdoutText = process.stdout.transform(utf8.decoder).join();
      final stderrDrain = process.stderr.drain<void>();
      for (final path in paths) {
        process.stdin.writeln(path);
      }
      await process.stdin.close();
      final exitCode = await process.exitCode;
      await stderrDrain;
      if (exitCode != 0) {
        return const {};
      }
      return _parseWslProjectResolutionOutput(await stdoutText, paths.toSet());
    } on Object {
      process.kill();
      return const {};
    }
  }
}

const _wslProjectResolutionScript = r'''
while IFS= read -r path; do
  if [ -z "$path" ]; then
    continue
  fi
  if cd "$path" 2>/dev/null; then
    root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    name=$(basename "$root")
    if [ -n "$name" ]; then
      printf '%s\t%s\n' "$path" "$name"
    fi
  fi
done
''';

Map<String, String> _parseWslProjectResolutionOutput(
  String output,
  Set<String> requestedPaths,
) {
  final resolved = <String, String>{};
  for (final line in const LineSplitter().convert(output)) {
    final separator = line.indexOf('\t');
    if (separator <= 0) {
      continue;
    }
    final path = line.substring(0, separator);
    final name = line.substring(separator + 1).trim();
    if (requestedPaths.contains(path) && name.isNotEmpty) {
      resolved[path] = name;
    }
  }
  return resolved;
}

/// Reads the project list (null [projectId]) or one project's detail on a
/// background isolate; detail counts walk every session.
Future<Object> _readProjectsInBackground(String databasePath, int? projectId) {
  return Isolate.run(() {
    final db = openFileBackedDatabase(File(databasePath));
    try {
      final store = ProjectTagStateStore(db);
      return projectId == null
          ? store.listProjects()
          : store.loadProjectDetail(projectId);
    } finally {
      db.close();
    }
  });
}

Future<void> _backgroundRefreshEntry(_BackgroundRefreshRequest request) async {
  final cancelPort = ReceivePort();
  StreamSubscription<Object?>? cancelSubscription;
  try {
    request.sendPort.send(_BackgroundRefreshControl(cancelPort.sendPort));
    final controller = RuntimeSessionController(
      settingsFile: File(request.settingsFilePath),
      databaseFile: File(request.databaseFilePath),
      scanBatchingPolicy: ScanBatchingPolicy(
        parsedSessionFlushBatchSize: request.parsedSessionFlushBatchSize,
        parsedSessionFlushSourceBytes: request.parsedSessionFlushSourceBytes,
        fullRowSnapshotBatchSize: request.fullRowSnapshotBatchSize,
      ),
    );
    if (request.coordinateWrites) {
      controller._backgroundWriterPort = request.sendPort;
    }
    controller.emitCachedRowsAtScanStart = request.emitCachedRowsAtScanStart;
    final operation = controller.startRefreshOperation(
      onProgress: (progress) {
        request.sendPort.send(_BackgroundRefreshProgress(progress));
      },
    );
    cancelSubscription = cancelPort.listen((message) {
      if (message is _BackgroundRefreshCancel) {
        unawaited(operation.cancel());
      }
    });
    final result = await operation.result;
    request.sendPort.send(_BackgroundRefreshDone(result));
  } on Object catch (error, stackTrace) {
    request.sendPort.send(
      _BackgroundRefreshError(error.toString(), stackTrace.toString()),
    );
  } finally {
    await cancelSubscription?.cancel();
    cancelPort.close();
  }
}

Future<void> _backgroundCachedRowsEntry(
  _BackgroundCachedRowsRequest request,
) async {
  try {
    final db = openFileBackedDatabase(File(request.databaseFilePath));
    try {
      _cleanSessionMetadataPlaceholders(db);
      await _backfillAutomaticProjects(
        db,
        wslProjects: _WslProjectResolutionCache(
          const ProcessWslProjectResolver(),
        ),
      );
      final total = _visibleRowCount(db);
      var offset = 0;
      while (offset < total) {
        final batch = _loadRowsProfiled(
          db,
          limit: request.batchSize,
          offset: offset,
        );
        if (batch.isEmpty) {
          break;
        }
        offset += batch.length;
        // Only the new batch crosses the isolate boundary; the receiver
        // accumulates. Resending the growing list made the UI isolate decode
        // every row once per batch at startup.
        request.sendPort.send(_BackgroundCachedRowsBatch(batch, offset, total));
      }
      request.sendPort.send(const _BackgroundCachedRowsDone());
    } finally {
      db.close();
    }
  } on Object catch (error, stackTrace) {
    request.sendPort.send(
      _BackgroundRefreshError(error.toString(), stackTrace.toString()),
    );
  }
}

Future<void> _backgroundMessageSearchBackfillEntry(
  _BackgroundMessageSearchBackfillRequest request,
) async {
  final cancelPort = ReceivePort();
  StreamSubscription<Object?>? cancelSubscription;
  var cancelRequested = request.initiallyCancelled;
  late Object terminalMessage;
  try {
    request.sendPort.send(_BackgroundRefreshControl(cancelPort.sendPort));
    cancelSubscription = cancelPort.listen((message) {
      if (message is _BackgroundRefreshCancel) {
        cancelRequested = true;
      }
    });
    final db = openFileBackedDatabase(File(request.databaseFilePath));
    try {
      var result = MessageSearchIndex(
        db,
      ).backfillStatus().toResult(indexedInBatch: 0, complete: false);
      while (!cancelRequested) {
        result = MessageSearchIndex(db).backfillBatch(limit: request.batchSize);
        if (result.complete || request.singleBatch) {
          break;
        }
        await Future<void>.delayed(request.pauseBetweenBatches);
      }
      if (cancelRequested) {
        result = MessageSearchIndex(db).backfillStatus().toResult(
          indexedInBatch: 0,
          complete: false,
          cancelled: true,
        );
      }
      terminalMessage = _BackgroundMessageSearchBackfillDone(result);
    } finally {
      db.close();
    }
  } on Object catch (error, stackTrace) {
    terminalMessage = _BackgroundRefreshError(
      error.toString(),
      stackTrace.toString(),
    );
  } finally {
    await cancelSubscription?.cancel();
    cancelPort.close();
  }
  // The parent may dispose the isolate immediately on completion. Publish only
  // after SQLite and control resources are closed, atomically with isolate exit.
  Isolate.exit(request.sendPort, terminalMessage);
}

Future<void> _backgroundSessionDetailEntry(
  _BackgroundSessionDetailRequest request,
) async {
  try {
    final row = request.reloadFromSource
        ? await RuntimeSessionController._reloadSessionDetailFromSourceOnWorker(
            settingsFile: File(request.settingsFilePath),
            databaseFile: File(request.databaseFilePath),
            sessionId: request.sessionId,
          )
        : await RuntimeSessionController._loadSessionDetailOnWorker(
            settingsFile: File(request.settingsFilePath),
            databaseFile: File(request.databaseFilePath),
            sessionId: request.sessionId,
          );
    request.sendPort.send(_BackgroundSessionDetailDone(row));
  } on Object catch (error, stackTrace) {
    request.sendPort.send(
      _BackgroundRefreshError(error.toString(), stackTrace.toString()),
    );
  }
}

List<SessionRowViewModel> _loadRowsProfiled(
  Database db, {
  bool includeMessages = false,
  String? sessionId,
  int? limit,
  int offset = 0,
  UsagePricingCatalog pricing = const UsagePricingCatalog({}),
}) {
  return Profiling.spanSync('scan.runtime.load_rows', () {
    return _loadRows(
      db,
      includeMessages: includeMessages,
      sessionId: sessionId,
      limit: limit,
      offset: offset,
      pricing: pricing,
    );
  });
}

class _BackgroundRefreshRequest {
  const _BackgroundRefreshRequest({
    required this.settingsFilePath,
    required this.databaseFilePath,
    required this.sendPort,
    required this.parsedSessionFlushBatchSize,
    required this.parsedSessionFlushSourceBytes,
    required this.fullRowSnapshotBatchSize,
    required this.coordinateWrites,
    required this.emitCachedRowsAtScanStart,
  });

  final String settingsFilePath;
  final String databaseFilePath;
  final SendPort sendPort;
  final int parsedSessionFlushBatchSize;
  final int parsedSessionFlushSourceBytes;
  final int fullRowSnapshotBatchSize;
  final bool coordinateWrites;
  final bool emitCachedRowsAtScanStart;
}

class _BackgroundScanWriteRequest {
  const _BackgroundScanWriteRequest(this.grant);
  final SendPort grant;
}

const _cachedRowsProgressInterval = Duration(milliseconds: 400);

class _BackgroundCachedRowsBatch {
  const _BackgroundCachedRowsBatch(this.rows, this.loaded, this.total);

  final List<SessionRowViewModel> rows;
  final int loaded;
  final int total;
}

class _BackgroundCachedRowsDone {
  const _BackgroundCachedRowsDone();
}

class _BackgroundCachedRowsRequest {
  const _BackgroundCachedRowsRequest({
    required this.databaseFilePath,
    required this.sendPort,
    required this.batchSize,
  });

  final String databaseFilePath;
  final SendPort sendPort;
  final int batchSize;
}

class _BackgroundMessageSearchBackfillRequest {
  const _BackgroundMessageSearchBackfillRequest({
    required this.databaseFilePath,
    required this.sendPort,
    required this.batchSize,
    required this.pauseBetweenBatches,
    required this.singleBatch,
    required this.initiallyCancelled,
  });

  final String databaseFilePath;
  final SendPort sendPort;
  final int batchSize;
  final Duration pauseBetweenBatches;
  final bool singleBatch;
  final bool initiallyCancelled;
}

class _BackgroundSessionDetailRequest {
  const _BackgroundSessionDetailRequest({
    required this.settingsFilePath,
    required this.databaseFilePath,
    required this.sessionId,
    required this.reloadFromSource,
    required this.sendPort,
  });

  final String settingsFilePath;
  final String databaseFilePath;
  final String sessionId;
  final bool reloadFromSource;
  final SendPort sendPort;
}

class _BackgroundSessionDetailDone {
  const _BackgroundSessionDetailDone(this.row);

  final SessionRowViewModel? row;
}

class _BackgroundRefreshProgress {
  const _BackgroundRefreshProgress(this.progress);

  final SessionsRefreshProgress progress;
}

class _BackgroundRefreshDone {
  const _BackgroundRefreshDone(this.result);

  final SessionsRefreshResult result;
}

class _BackgroundMessageSearchBackfillDone {
  const _BackgroundMessageSearchBackfillDone(this.result);

  final MessageSearchBackfillResult result;
}

class _BackgroundRefreshError {
  const _BackgroundRefreshError(this.error, this.stackTrace);

  final String error;
  final String stackTrace;
}

class CancellableSessionScanOperation {
  CancellableSessionScanOperation._(this.result, void Function() requestCancel)
    : _requestCancel = requestCancel {
    _done = result.then<void>((_) {}, onError: (_) {});
  }

  final Future<SessionsRefreshResult> result;
  final void Function() _requestCancel;
  late final Future<void> _done;
  var _cancelRequested = false;

  Future<void> cancel() {
    if (!_cancelRequested) {
      _cancelRequested = true;
      _requestCancel();
    }
    return _done;
  }
}

class CancellableMessageSearchBackfillOperation {
  CancellableMessageSearchBackfillOperation._(
    this.result,
    void Function() requestCancel,
  ) : _requestCancel = requestCancel {
    _done = result.then<void>((_) {}, onError: (_) {});
  }

  final Future<MessageSearchBackfillResult> result;
  final void Function() _requestCancel;
  late final Future<void> _done;
  var _cancelRequested = false;

  Future<void> cancel() {
    if (!_cancelRequested) {
      _cancelRequested = true;
      _requestCancel();
    }
    return _done;
  }
}

class _BackgroundMessageSearchBackfillOperation {
  static CancellableMessageSearchBackfillOperation start({
    required File databaseFile,
    required int batchSize,
    required Duration pauseBetweenBatches,
    DatabaseMaintenanceCoordinator? writerCoordinator,
  }) {
    final cancellationHandle = _BackgroundScanCancellationHandle();
    Timer? pauseTimer;
    Completer<void>? paused;
    void requestCancel() {
      cancellationHandle.requestCancel();
      pauseTimer?.cancel();
      if (paused != null && !paused!.isCompleted) paused!.complete();
    }

    Future<MessageSearchBackfillResult> work() => _start(
      databaseFile: databaseFile,
      batchSize: batchSize,
      pauseBetweenBatches: pauseBetweenBatches,
      cancellationHandle: cancellationHandle,
      singleBatch: writerCoordinator != null,
    );
    Future<MessageSearchBackfillResult> coordinated() async {
      while (true) {
        final result = await writerCoordinator!.runWriter(
          work,
          priority: DatabaseWriterPriority.repair,
        );
        if (result.complete || result.cancelled) return result;
        if (!cancellationHandle._cancelRequested) {
          // Each committed batch has closed SQLite before yielding the writer
          // slot. The deliberate pause must not retain that slot or a worker.
          paused = Completer<void>();
          pauseTimer = Timer(pauseBetweenBatches, paused!.complete);
          await paused!.future;
          pauseTimer = null;
          paused = null;
        }
        if (cancellationHandle._cancelRequested) {
          return MessageSearchBackfillResult(
            indexed: result.indexed,
            remaining: result.remaining,
            lastMessageRowId: result.lastMessageRowId,
            indexedInBatch: 0,
            complete: false,
            cancelled: true,
          );
        }
      }
    }

    final result = writerCoordinator == null ? work() : coordinated();
    return CancellableMessageSearchBackfillOperation._(result, requestCancel);
  }

  static Future<MessageSearchBackfillResult> _start({
    required File databaseFile,
    required int batchSize,
    required Duration pauseBetweenBatches,
    required _BackgroundScanCancellationHandle cancellationHandle,
    required bool singleBatch,
  }) async {
    final messages = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<_BackgroundMessageSearchBackfillRequest>(
        _backgroundMessageSearchBackfillEntry,
        _BackgroundMessageSearchBackfillRequest(
          databaseFilePath: databaseFile.path,
          sendPort: messages.sendPort,
          batchSize: batchSize,
          pauseBetweenBatches: pauseBetweenBatches,
          singleBatch: singleBatch,
          initiallyCancelled: cancellationHandle._cancelRequested,
        ),
        onError: errors.sendPort,
        onExit: exits.sendPort,
      );

      final result = Completer<MessageSearchBackfillResult>();
      late StreamSubscription<Object?> messageSubscription;
      late StreamSubscription<Object?> errorSubscription;
      late StreamSubscription<Object?> exitSubscription;

      void finishError(Object error, [StackTrace? stackTrace]) {
        if (!result.isCompleted) {
          result.completeError(error, stackTrace);
        }
      }

      messageSubscription = messages.listen((message) {
        if (message is _BackgroundRefreshControl) {
          cancellationHandle.attach(message.cancelPort);
          return;
        }
        if (message is _BackgroundMessageSearchBackfillDone) {
          if (!result.isCompleted) {
            result.complete(message.result);
          }
          return;
        }
        if (message is _BackgroundRefreshError) {
          finishError(
            StateError(message.error),
            StackTrace.fromString(message.stackTrace),
          );
        }
      });
      errorSubscription = errors.listen((message) {
        finishError(
          StateError('Background message search backfill failed. $message'),
        );
      });
      exitSubscription = exits.listen((_) {
        if (!result.isCompleted) {
          finishError(
            StateError(
              'Background message search backfill exited before completion.',
            ),
          );
        }
      });

      return await result.future.whenComplete(() async {
        await messageSubscription.cancel();
        await errorSubscription.cancel();
        await exitSubscription.cancel();
      });
    } finally {
      messages.close();
      errors.close();
      exits.close();
      isolate?.kill(priority: Isolate.immediate);
    }
  }
}

class _BackgroundSessionScanOperation {
  static CancellableSessionScanOperation start({
    required File settingsFile,
    required File databaseFile,
    required ScanBatchingPolicy scanBatchingPolicy,
    SessionsRefreshProgressCallback? onProgress,
    DatabaseMaintenanceCoordinator? writerCoordinator,
  }) {
    final cancellationHandle = _BackgroundScanCancellationHandle();
    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
      scanBatchingPolicy: scanBatchingPolicy,
      writerCoordinator: writerCoordinator,
    );
    Future<SessionsRefreshResult> work() => controller._refreshInBackground(
      onProgress: onProgress,
      cancellationHandle: cancellationHandle,
    );
    final result = writerCoordinator?.runScan(work) ?? work();
    return CancellableSessionScanOperation._(
      result,
      cancellationHandle.requestCancel,
    );
  }
}

class _BackgroundScanCancellationHandle {
  SendPort? _cancelPort;
  var _cancelRequested = false;

  void attach(SendPort cancelPort) {
    _cancelPort = cancelPort;
    if (_cancelRequested) {
      cancelPort.send(const _BackgroundRefreshCancel());
    }
  }

  void requestCancel() {
    _cancelRequested = true;
    _cancelPort?.send(const _BackgroundRefreshCancel());
  }
}

class _BackgroundRefreshControl {
  const _BackgroundRefreshControl(this.cancelPort);

  final SendPort cancelPort;
}

class _BackgroundRefreshCancel {
  const _BackgroundRefreshCancel();
}

Future<void> _persistParsedSessions(
  Database db,
  List<ScannedSessionFile> sessions, {
  required Map<String, CodexThreadNameEntry> threadNamesBySessionId,
  required _WslProjectResolutionCache wslProjects,
  bool resolveWslProjects = true,
}) async {
  final canonicalSessions = _canonicalScannedSessions(sessions);
  final resolver = resolveWslProjects
      ? await _ProjectPathResolver.create(
          _projectPathCandidatesForSessions(canonicalSessions),
          wslProjects: wslProjects,
        )
      : _ProjectPathResolver();
  db.execute('begin immediate');
  try {
    final now = DateTime.now().toUtc().toIso8601String();
    for (final session in canonicalSessions) {
      _upsertParsedSession(
        db,
        session,
        now,
        resolver,
        threadNamesBySessionId: threadNamesBySessionId,
      );
    }
    db.execute('commit');
  } on Object {
    db.execute('rollback');
    rethrow;
  }
}

int _startScanRun(Database db) {
  db.execute(
    '''
    insert into scan_runs (
      started_at_utc,
      status,
      files_found,
      files_skipped,
      files_parsed,
      files_failed,
      sessions_added,
      sessions_changed,
      sessions_missing
    ) values (?, ?, 0, 0, 0, 0, 0, 0, 0)
    ''',
    [DateTime.now().toUtc().toIso8601String(), _ScanRunStatus.running.name],
  );
  return db.lastInsertRowId;
}

void _updateScanRun(
  Database db,
  int scanRunId,
  ScanProgress progress, {
  required _ScanRunStatus status,
}) {
  db.execute(
    '''
    update scan_runs
    set
      finished_at_utc = ?,
      status = ?,
      files_found = ?,
      files_skipped = ?,
      files_parsed = ?,
      files_failed = ?,
      sessions_added = ?,
      sessions_changed = ?,
      sessions_missing = ?
    where id = ?
    ''',
    [
      progress.finishedAtUtc?.toIso8601String(),
      status.name,
      progress.filesFound,
      progress.filesSkipped,
      progress.filesParsed,
      progress.filesFailed,
      progress.sessionsAdded,
      progress.sessionsChanged,
      progress.sessionsMissing,
      scanRunId,
    ],
  );
}

enum _ScanRunStatus { running, succeeded, cancelled, failed }

List<CachedSessionSnapshot> _cachedSessions(Database db) {
  final rows = db.select('''
    select
      source_file_path,
      source_file_unc_path,
      scan_status,
      source_state,
      file_size,
      modified_utc,
      content_hash,
      parser_version,
      last_scanned_utc,
      last_parsed_utc
    from sessions
    ''');
  return [
    for (final row in rows)
      CachedSessionSnapshot(
        sourcePath: row['source_file_path'] as String,
        sourceFileUncPath: row['source_file_unc_path'] as String?,
        status: _scanStatus(row['scan_status'] as String?),
        sourceState: _sourceState(row['source_state'] as String?),
        sourceFileSize: row['file_size'] as int?,
        sourceModifiedUtc: _dateTime(row['modified_utc'] as String?),
        sourceContentHash: row['content_hash'] as String?,
        parserVersion: row['parser_version'] as int?,
        lastScannedUtc: _dateTime(row['last_scanned_utc'] as String?),
        lastParsedUtc: _dateTime(row['last_parsed_utc'] as String?),
      ),
  ];
}

Future<void> _persistScan(
  Database db,
  SessionScanResult result, {
  required int scanRunId,
  required bool persistSessions,
  required Map<String, CodexThreadNameEntry> threadNamesBySessionId,
  required _WslProjectResolutionCache wslProjects,
}) async {
  final canonicalSessions = _canonicalScannedSessions(result.sessions);
  final resolver = persistSessions
      ? await _ProjectPathResolver.create(
          _projectPathCandidatesForSessions(canonicalSessions),
          wslProjects: wslProjects,
        )
      : null;
  db.execute('begin immediate');
  try {
    final now = DateTime.now().toUtc().toIso8601String();
    _updateScanRun(
      db,
      scanRunId,
      result.progress,
      status: result.cancelled
          ? _ScanRunStatus.cancelled
          : _ScanRunStatus.succeeded,
    );
    for (final error in result.errors) {
      db.execute(
        '''
        insert into scan_errors (
          scan_run_id,
          source_path,
          status,
          message,
          created_at_utc
        ) values (?, ?, ?, ?, ?)
        ''',
        [
          scanRunId,
          error.sourcePath,
          error.status.wireName,
          error.message,
          now,
        ],
      );
    }
    if (persistSessions) {
      for (final session in canonicalSessions) {
        _upsertParsedSession(
          db,
          session,
          now,
          resolver!,
          threadNamesBySessionId: threadNamesBySessionId,
        );
      }
    }
    _upsertScanStatusesOnly(db, result.fileStatuses, now);
    db.execute('commit');
  } on Object {
    db.execute('rollback');
    rethrow;
  }
}

void _upsertParsedSession(
  Database db,
  ScannedSessionFile scannedSession,
  String now,
  _ProjectPathResolver projectResolver, {
  Map<String, CodexThreadNameEntry> threadNamesBySessionId = const {},
}) {
  final parsed = scannedSession.parsedSession;
  final identityMerge = _captureIdentityMergeState(db, scannedSession);
  if (!_candidateShouldReplacePersistedSession(db, scannedSession)) {
    if (identityMerge != null) {
      _applyIdentityMerge(db, parsed.internalId, identityMerge);
      final affected = _reconcileAffectedLegacyUsage(
        db,
        replacedSessionRowId: parsed.internalId,
        replacedLogicalSessionId: parsed.sessionId,
      );
      UsageSummaryRepository(
        db,
      ).replaceDailyProjectionsInCurrentTransaction(affected);
    }
    return;
  }
  final resolvedThreadName =
      threadNamesBySessionId[parsed.sessionId]?.threadName.trim().isNotEmpty ==
          true
      ? threadNamesBySessionId[parsed.sessionId]!.threadName.trim()
      : parsed.threadName?.trim() ?? '';
  final sourceType = scannedSession.sourceType == SessionSourceType.windows
      ? SessionSearchSourceType.windows
      : SessionSearchSourceType.wsl;
  final needsCurrentStat =
      scannedSession.sourceSnapshotSize == null ||
      scannedSession.sourceSnapshotModifiedUtc == null;
  final stat = needsCurrentStat
      ? File(scannedSession.sourcePath).statSync()
      : null;
  final sourceSnapshotSize = scannedSession.sourceSnapshotSize ?? stat!.size;
  final sourceSnapshotModifiedUtc =
      scannedSession.sourceSnapshotModifiedUtc ?? stat!.modified.toUtc();
  final hasErrors =
      parsed.messages.any((message) => message.hasError) ||
      parsed.toolCalls.any((tool) => tool.hasError);
  final autoProject = projectResolver.resolve(
    parsed.workingDirectoryDisplay,
    sourceType: scannedSession.sourceType,
  );
  final detectedProjectId = autoProject == null
      ? null
      : _upsertAutoProject(db, autoProject.name, now);
  final tokenBuckets = _messageTokenBuckets(parsed);
  SessionSearchIndex(db).upsert(
    SessionSearchDocument(
      id: parsed.internalId,
      sourceType: sourceType,
      sourceFilePath: scannedSession.sourcePath,
      displayPath: scannedSession.mappedPath.displayPath,
      platformPath: scannedSession.mappedPath.platformPath,
      title: _cleanDisplayTitle(parsed.title),
      summary: _cleanDisplaySummary(parsed.summary),
      threadName: resolvedThreadName,
      toolNames: parsed.toolCalls.map((tool) => tool.toolName).join(' '),
      normalizedPathKeys: scannedSession.mappedPath.normalizedPathKeys.join(
        ' ',
      ),
      startedAtUtc: parsed.startedAtUtc,
      lastMessageAtUtc: parsed.lastMessageAtUtc,
      modelsUsed: parsed.modelIds.toList(growable: false),
      scanStatus: scannedSession.status.wireName,
      parseStatus: 'available',
      hasCodeBlocks: parsed.messages.any(
        (message) => message.contentPlain.contains('```'),
      ),
      hasToolCalls: parsed.toolCalls.isNotEmpty,
      hasErrors: hasErrors,
      totalTokens: parsed.usage.totalTokens,
      projectName: autoProject?.name ?? '',
    ),
  );
  db.execute(
    '''
    update sessions
    set
      session_id = ?,
      thread_name = ?,
      thread_source = ?,
      parent_thread_id = ?,
      forked_from_id = ?,
      history_base_thread_id = ?,
      history_base_end_ordinal = ?,
      history_base_end_byte_offset = ?,
      subagent_history_start_ordinal = ?,
      usage_projection_status = ?,
      agent_nickname = ?,
      agent_role = ?,
      subagent_depth = ?,
      source_file_unc_path = ?,
      source_state = ?,
      working_directory_display = ?,
      working_directory_platform = ?,
      working_directory_unc = ?,
      file_size = ?,
      modified_utc = ?,
      content_hash = ?,
      parser_version = ?,
      message_count = ?,
      user_message_count = ?,
      assistant_message_count = ?,
      tool_call_count = ?,
      input_tokens = ?,
      output_tokens = ?,
      cached_input_tokens = ?,
      user_message_tokens = ?,
      assistant_response_tokens = ?,
      tool_call_tokens = ?,
      detected_project_id = ?,
      last_scanned_utc = ?,
      last_parsed_utc = ?
    where id = ?
    ''',
    [
      parsed.sessionId,
      resolvedThreadName,
      parsed.threadSource,
      parsed.parentThreadId,
      parsed.forkedFromId,
      parsed.historyBaseThreadId,
      parsed.historyBaseEndOrdinalExclusive,
      parsed.historyBaseEndByteOffset,
      parsed.subagentHistoryStartOrdinal,
      parsed.usageProjectionStatus,
      parsed.agentNickname,
      parsed.agentRole,
      parsed.subagentDepth,
      scannedSession.mappedPath.sourceFileUncPath,
      scannedSession.sourceState.wireName,
      parsed.workingDirectoryDisplay,
      parsed.workingDirectoryPlatform,
      parsed.workingDirectoryUnc,
      sourceSnapshotSize,
      sourceSnapshotModifiedUtc.toIso8601String(),
      null,
      CodexSessionParser.currentVersion,
      parsed.messages.length,
      parsed.messages
          .where((message) => message.authorType == CodexMessageAuthorType.user)
          .length,
      parsed.messages
          .where(
            (message) => message.authorType == CodexMessageAuthorType.assistant,
          )
          .length,
      parsed.toolCalls.length,
      parsed.usage.inputTokens,
      parsed.usage.outputTokens,
      parsed.usage.cachedInputTokens,
      tokenBuckets.user,
      tokenBuckets.assistant,
      tokenBuckets.tool,
      detectedProjectId,
      now,
      now,
      parsed.internalId,
    ],
  );
  _replaceMessages(db, parsed, now);
  _replaceToolCalls(db, parsed);
  _replaceUsageEvents(
    db,
    parsed,
    now,
    projectResolver,
    sourceType: scannedSession.sourceType,
  );
  if (identityMerge != null) {
    _applyIdentityMerge(db, parsed.internalId, identityMerge);
  }
  ProjectTagStateStore(db).refreshSessionProject(parsed.internalId);
  final affected = _reconcileAffectedLegacyUsage(
    db,
    replacedSessionRowId: parsed.internalId,
    replacedLogicalSessionId: parsed.sessionId,
  );
  UsageSummaryRepository(
    db,
  ).replaceDailyProjectionsInCurrentTransaction(affected);
}

_IdentityMergeState? _captureIdentityMergeState(
  Database db,
  ScannedSessionFile candidate,
) {
  final stableSessionId = candidate.parsedSession.sessionId?.trim() ?? '';
  if (stableSessionId.isEmpty) {
    return null;
  }
  final canonicalId = candidate.parsedSession.internalId;
  final caseSensitivePaths = candidate.sourceType == SessionSourceType.wsl;
  final pathKeys =
      <String>{
            candidate.sourcePath,
            candidate.mappedPath.sourceFilePath,
            candidate.mappedPath.displayPath,
            candidate.mappedPath.platformPath,
            if (!caseSensitivePaths) ...candidate.mappedPath.normalizedPathKeys,
            ?candidate.mappedPath.sourceFileUncPath,
          }
          .map(
            (path) =>
                _normalizeIdentityPath(path, caseSensitive: caseSensitivePaths),
          )
          .where((path) => path.isNotEmpty)
          .toList();
  final pathParameters = List.filled(pathKeys.length, '?').join(', ');
  String normalizedSqlPath(String column) => caseSensitivePaths
      ? "replace(coalesce($column, ''), '\\', '/')"
      : "replace(lower(coalesce($column, '')), '\\', '/')";
  final rows = db.select(
    '''
    select rowid as session_rowid, *
    from sessions
    where id = ?
       or (
         id <> ?
         and (
           trim(coalesce(session_id, '')) = ?
           or (
             trim(coalesce(session_id, '')) = ''
             and source_type = ?
             and (
               ${normalizedSqlPath('source_file_path')}
                 in ($pathParameters)
               or ${normalizedSqlPath('source_file_unc_path')}
                 in ($pathParameters)
               or ${normalizedSqlPath('display_path')}
                 in ($pathParameters)
               or ${normalizedSqlPath('platform_path')}
                 in ($pathParameters)
               or (
                 id like 'source:%'
                 and source_type = 'windows'
                 and ${caseSensitivePaths ? "replace(substr(id, 8), '\\', '/')" : "replace(lower(substr(id, 8)), '\\', '/')"}
                   in ($pathParameters)
               )
               or (
                 id like 'source-status:%'
                 and source_type = 'windows'
                 and ${caseSensitivePaths ? "replace(substr(id, 15), '\\', '/')" : "replace(lower(substr(id, 15)), '\\', '/')"}
                   in ($pathParameters)
               )
             )
           )
         )
       )
    ''',
    [
      canonicalId,
      canonicalId,
      stableSessionId,
      candidate.sourceType == SessionSourceType.wsl ? 'wsl' : 'windows',
      for (var repeat = 0; repeat < 6; repeat++) ...pathKeys,
    ],
  );
  final alternateRows = rows
      .where((row) => row['id'] != canonicalId)
      .toList(growable: false);
  if (alternateRows.isEmpty) {
    return null;
  }
  final snapshots = [
    for (final row in rows) _SessionMetadataSnapshot.fromRow(row),
  ];
  _SessionMetadataSnapshot? canonical;
  for (final snapshot in snapshots) {
    if (snapshot.id == canonicalId) {
      canonical = snapshot;
      break;
    }
  }
  final project = _latestMetadataSnapshot(
    snapshots,
    canonical: canonical,
    timestamp: (snapshot) => snapshot.updatedAtUtc,
  );
  final archive = _latestMetadataSnapshot(
    snapshots,
    canonical: canonical,
    timestamp: (snapshot) => snapshot.archivedAtUtc,
  );
  final evaluation = _latestMetadataSnapshot(
    snapshots,
    canonical: canonical,
    timestamp: (snapshot) => snapshot.evalUpdatedAtUtc,
  );
  final ownerIds = snapshots.map((snapshot) => snapshot.id).toList();
  final ownerParameters = List.filled(ownerIds.length, '?').join(', ');
  final tagCreatedAtById = <int, String>{};
  for (final row in db.select('''
    select tag_id, created_at_utc
    from session_tags
    where session_id in ($ownerParameters)
    ''', ownerIds)) {
    final tagId = row['tag_id'] as int;
    final createdAt = row['created_at_utc'] as String;
    final existing = tagCreatedAtById[tagId];
    if (existing == null || createdAt.compareTo(existing) < 0) {
      tagCreatedAtById[tagId] = createdAt;
    }
  }
  final pathAliases = <String>{
    for (final row in db.select('''
      select path_key
      from session_path_keys
      where session_id in ($ownerParameters)
      ''', ownerIds))
      row['path_key'] as String,
  };
  return _IdentityMergeState(
    alternateIds: [for (final row in alternateRows) row['id'] as String],
    alternateRowIds: [
      for (final row in alternateRows) row['session_rowid'] as int,
    ],
    isPinned: snapshots.any((snapshot) => snapshot.isPinned),
    project: project,
    archive: archive,
    evaluation: evaluation,
    tagCreatedAtById: tagCreatedAtById,
    pathAliases: pathAliases,
  );
}

_SessionMetadataSnapshot _latestMetadataSnapshot(
  List<_SessionMetadataSnapshot> snapshots, {
  required _SessionMetadataSnapshot? canonical,
  required DateTime? Function(_SessionMetadataSnapshot snapshot) timestamp,
}) {
  var winner = canonical ?? snapshots.first;
  for (final snapshot in snapshots) {
    if (identical(snapshot, winner)) {
      continue;
    }
    final candidateTime = timestamp(snapshot);
    final winnerTime = timestamp(winner);
    final timestampCompare = _compareNullableDateTime(
      candidateTime,
      winnerTime,
    );
    if (timestampCompare > 0 ||
        (canonical == null &&
            timestampCompare == 0 &&
            _compareMetadataTieBreak(snapshot, winner) > 0)) {
      winner = snapshot;
    }
  }
  return winner;
}

int _compareMetadataTieBreak(
  _SessionMetadataSnapshot left,
  _SessionMetadataSnapshot right,
) {
  int identityPreference(String id) {
    if (id.startsWith('source:')) {
      return 2;
    }
    if (id.startsWith('source-status:')) {
      return 1;
    }
    return 0;
  }

  final identityCompare = identityPreference(
    left.id,
  ).compareTo(identityPreference(right.id));
  if (identityCompare != 0) {
    return identityCompare;
  }
  final idCompare = right.id.compareTo(left.id);
  if (idCompare != 0) {
    return idCompare;
  }
  return right.rowId.compareTo(left.rowId);
}

void _applyIdentityMerge(
  Database db,
  String canonicalId,
  _IdentityMergeState merge,
) {
  db.execute(
    '''
    update sessions
    set is_pinned = ?,
        project_override = ?,
        project_id = ?,
        project_name_snapshot = ?,
        is_archived = ?,
        archived_at_utc = ?,
        archive_reason = ?,
        eval_ready = ?,
        eval_status = ?,
        eval_notes = ?,
        eval_expected_output = ?,
        eval_reviewed_at_utc = ?,
        eval_updated_at_utc = ?,
        updated_at_utc = case
          when julianday(?) > julianday(updated_at_utc) then ?
          else updated_at_utc
        end
    where id = ?
    ''',
    [
      merge.isPinned ? 1 : 0,
      merge.project.projectOverride ? 1 : 0,
      merge.project.projectId,
      merge.project.projectName,
      merge.archive.isArchived ? 1 : 0,
      merge.archive.archivedAtValue,
      merge.archive.archiveReason,
      merge.evaluation.evalReady ? 1 : 0,
      merge.evaluation.evalStatus,
      merge.evaluation.evalNotes,
      merge.evaluation.evalExpectedOutput,
      merge.evaluation.evalReviewedAtValue,
      merge.evaluation.evalUpdatedAtValue,
      merge.project.updatedAtValue,
      merge.project.updatedAtValue,
      canonicalId,
    ],
  );

  for (final alternateId in merge.alternateIds) {
    db.execute('delete from usage_events where session_row_id = ?', [
      alternateId,
    ]);
    db.execute('delete from tool_calls where session_id = ?', [alternateId]);
    db.execute('delete from messages where session_id = ?', [alternateId]);
    db.execute('delete from session_tags where session_id = ?', [alternateId]);
    db.execute('delete from session_path_keys where session_id = ?', [
      alternateId,
    ]);
  }
  for (final rowId in merge.alternateRowIds) {
    db.execute('delete from session_search where rowid = ?', [rowId]);
  }
  for (final alternateId in merge.alternateIds) {
    db.execute('delete from sessions where id = ?', [alternateId]);
  }
  for (final entry in merge.tagCreatedAtById.entries) {
    db.execute(
      '''
      insert or ignore into session_tags (session_id, tag_id, created_at_utc)
      values (?, ?, ?)
      ''',
      [canonicalId, entry.key, entry.value],
    );
  }
  for (final pathAlias in merge.pathAliases) {
    db.execute(
      '''
      insert or ignore into session_path_keys (session_id, path_key)
      values (?, ?)
      ''',
      [canonicalId, pathAlias],
    );
  }
  _refreshSessionSearchRow(db, canonicalId);
  final foreignKeyErrors = db.select('pragma foreign_key_check');
  if (foreignKeyErrors.isNotEmpty) {
    throw StateError(
      'Session identity reconciliation left foreign-key violations.',
    );
  }
}

void _refreshSessionSearchRow(Database db, String sessionId) {
  final rows = db.select(
    '''
    select
      s.rowid as session_rowid,
      coalesce(s.title, '') as title,
      coalesce(s.summary, '') as summary,
      coalesce((
        select group_concat(tc.tool_name, ' ')
        from tool_calls tc where tc.session_id = s.id
      ), '') as tool_names,
      coalesce(s.display_path, '') as display_path,
      coalesce((
        select group_concat(pk.path_key, ' ')
        from session_path_keys pk where pk.session_id = s.id
      ), '') as normalized_path_keys,
      coalesce(s.project_name_snapshot, p.name, '') as project_name,
      coalesce((
        select group_concat(t.name, ' ')
        from session_tags st
        join tags t on t.id = st.tag_id
        where st.session_id = s.id
      ), '') as tags
    from sessions s
    left join projects p on p.id = s.project_id
    where s.id = ?
    ''',
    [sessionId],
  );
  if (rows.isEmpty) {
    return;
  }
  final row = rows.single;
  final rowId = row['session_rowid'] as int;
  db.execute('delete from session_search where rowid = ?', [rowId]);
  db.execute(
    '''
    insert into session_search (
      rowid, title, summary, tool_names, display_path,
      normalized_path_keys, project_name, tags
    ) values (?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    [
      rowId,
      row['title'],
      row['summary'],
      row['tool_names'],
      row['display_path'],
      row['normalized_path_keys'],
      row['project_name'],
      row['tags'],
    ],
  );
}

String _normalizeIdentityPath(String path, {required bool caseSensitive}) {
  final normalized = path.trim().replaceAll(r'\', '/');
  return caseSensitive ? normalized : normalized.toLowerCase();
}

class _IdentityMergeState {
  const _IdentityMergeState({
    required this.alternateIds,
    required this.alternateRowIds,
    required this.isPinned,
    required this.project,
    required this.archive,
    required this.evaluation,
    required this.tagCreatedAtById,
    required this.pathAliases,
  });

  final List<String> alternateIds;
  final List<int> alternateRowIds;
  final bool isPinned;
  final _SessionMetadataSnapshot project;
  final _SessionMetadataSnapshot archive;
  final _SessionMetadataSnapshot evaluation;
  final Map<int, String> tagCreatedAtById;
  final Set<String> pathAliases;
}

class _SessionMetadataSnapshot {
  const _SessionMetadataSnapshot({
    required this.rowId,
    required this.id,
    required this.isPinned,
    required this.projectOverride,
    required this.projectId,
    required this.projectName,
    required this.updatedAtValue,
    required this.isArchived,
    required this.archivedAtValue,
    required this.archiveReason,
    required this.evalReady,
    required this.evalStatus,
    required this.evalNotes,
    required this.evalExpectedOutput,
    required this.evalReviewedAtValue,
    required this.evalUpdatedAtValue,
  });

  factory _SessionMetadataSnapshot.fromRow(Row row) => _SessionMetadataSnapshot(
    rowId: row['session_rowid'] as int,
    id: row['id'] as String,
    isPinned: (row['is_pinned'] as int? ?? 0) == 1,
    projectOverride: (row['project_override'] as int? ?? 0) == 1,
    projectId: row['project_id'] as int?,
    projectName: row['project_name_snapshot'] as String?,
    updatedAtValue: row['updated_at_utc'] as String?,
    isArchived: (row['is_archived'] as int? ?? 0) == 1,
    archivedAtValue: row['archived_at_utc'] as String?,
    archiveReason: row['archive_reason'] as String?,
    evalReady: (row['eval_ready'] as int? ?? 0) == 1,
    evalStatus: row['eval_status'] as String?,
    evalNotes: row['eval_notes'] as String?,
    evalExpectedOutput: row['eval_expected_output'] as String?,
    evalReviewedAtValue: row['eval_reviewed_at_utc'] as String?,
    evalUpdatedAtValue: row['eval_updated_at_utc'] as String?,
  );

  final int rowId;
  final String id;
  final bool isPinned;
  final bool projectOverride;
  final int? projectId;
  final String? projectName;
  final String? updatedAtValue;
  final bool isArchived;
  final String? archivedAtValue;
  final String? archiveReason;
  final bool evalReady;
  final String? evalStatus;
  final String? evalNotes;
  final String? evalExpectedOutput;
  final String? evalReviewedAtValue;
  final String? evalUpdatedAtValue;

  DateTime? get updatedAtUtc => _dateTime(updatedAtValue);
  DateTime? get archivedAtUtc => _dateTime(archivedAtValue);
  DateTime? get evalUpdatedAtUtc => _dateTime(evalUpdatedAtValue);
}

List<ScannedSessionFile> _canonicalScannedSessions(
  Iterable<ScannedSessionFile> sessions,
) {
  final winners = <String, _SessionCandidateEvidence>{};
  for (final session in sessions) {
    final evidence = _SessionCandidateEvidence.fromScanned(session);
    final existing = winners[session.parsedSession.internalId];
    if (existing == null || _compareSessionCandidates(evidence, existing) > 0) {
      winners[session.parsedSession.internalId] = evidence;
    }
  }
  final result = winners.values
      .map((evidence) => evidence.scannedSession!)
      .toList(growable: false);
  result.sort(
    (left, right) =>
        left.parsedSession.internalId.compareTo(right.parsedSession.internalId),
  );
  return result;
}

bool _candidateShouldReplacePersistedSession(
  Database db,
  ScannedSessionFile candidate,
) {
  final rows = db.select(
    '''
    select source_type, source_file_path, source_state, parse_status,
           coalesce(last_message_at_utc, started_at_utc) as last_evidence_utc,
           modified_utc, file_size
    from sessions
    where id = ?
    ''',
    [candidate.parsedSession.internalId],
  );
  if (rows.isEmpty) {
    return true;
  }
  final row = rows.single;
  final existing = _SessionCandidateEvidence(
    sourcePath: row['source_file_path'] as String,
    sourceType: row['source_type'] == 'wsl'
        ? SessionSourceType.wsl
        : SessionSourceType.windows,
    sourceState: _sourceState(row['source_state'] as String?),
    isValidParse: row['parse_status'] == 'available',
    lastEvidenceUtc: _dateTime(row['last_evidence_utc'] as String?),
    modifiedUtc: _dateTime(row['modified_utc'] as String?),
    fileSize: row['file_size'] as int? ?? 0,
  );
  return _compareSessionCandidates(
        _SessionCandidateEvidence.fromScanned(candidate),
        existing,
      ) >=
      0;
}

int _compareSessionCandidates(
  _SessionCandidateEvidence left,
  _SessionCandidateEvidence right,
) {
  final validityCompare = (left.isValidParse ? 1 : 0).compareTo(
    right.isValidParse ? 1 : 0,
  );
  if (validityCompare != 0) {
    return validityCompare;
  }
  final evidenceCompare = _compareNullableDateTime(
    left.lastEvidenceUtc,
    right.lastEvidenceUtc,
  );
  if (evidenceCompare != 0) {
    return evidenceCompare;
  }
  final modifiedCompare = _compareNullableDateTime(
    left.modifiedUtc,
    right.modifiedUtc,
  );
  if (modifiedCompare != 0) {
    return modifiedCompare;
  }
  final sizeCompare = left.fileSize.compareTo(right.fileSize);
  if (sizeCompare != 0) {
    return sizeCompare;
  }
  final lifecycleCompare = _sourceLifecyclePreference(
    left.sourceState,
  ).compareTo(_sourceLifecyclePreference(right.sourceState));
  if (lifecycleCompare != 0) {
    return lifecycleCompare;
  }
  final caseSensitivePaths =
      left.sourceType == SessionSourceType.wsl ||
      right.sourceType == SessionSourceType.wsl;
  final leftPath = caseSensitivePaths
      ? left.sourcePath
      : left.sourcePath.toLowerCase();
  final rightPath = caseSensitivePaths
      ? right.sourcePath
      : right.sourcePath.toLowerCase();
  return rightPath.compareTo(leftPath);
}

int _compareNullableDateTime(DateTime? left, DateTime? right) {
  if (left == null) {
    return right == null ? 0 : -1;
  }
  if (right == null) {
    return 1;
  }
  return left.compareTo(right);
}

int _sourceLifecyclePreference(SessionSourceState state) => switch (state) {
  SessionSourceState.active => 2,
  SessionSourceState.codexArchived => 1,
  SessionSourceState.missing => 0,
};

class _SessionCandidateEvidence {
  const _SessionCandidateEvidence({
    required this.sourcePath,
    required this.sourceType,
    required this.sourceState,
    required this.isValidParse,
    required this.lastEvidenceUtc,
    required this.modifiedUtc,
    required this.fileSize,
    this.scannedSession,
  });

  factory _SessionCandidateEvidence.fromScanned(ScannedSessionFile session) {
    FileStat? liveStat;
    if (session.sourceSnapshotSize == null ||
        session.sourceSnapshotModifiedUtc == null) {
      try {
        liveStat = File(session.sourcePath).statSync();
      } on FileSystemException {
        liveStat = null;
      }
    }
    return _SessionCandidateEvidence(
      sourcePath: session.sourcePath,
      sourceType: session.sourceType,
      sourceState: session.sourceState,
      isValidParse: true,
      lastEvidenceUtc:
          session.parsedSession.lastMessageAtUtc ??
          session.parsedSession.startedAtUtc,
      modifiedUtc:
          session.sourceSnapshotModifiedUtc ?? liveStat?.modified.toUtc(),
      fileSize: session.sourceSnapshotSize ?? liveStat?.size ?? 0,
      scannedSession: session,
    );
  }

  final String sourcePath;
  final SessionSourceType sourceType;
  final SessionSourceState sourceState;
  final bool isValidParse;
  final DateTime? lastEvidenceUtc;
  final DateTime? modifiedUtc;
  final int fileSize;
  final ScannedSessionFile? scannedSession;
}

({int user, int assistant, int tool}) _messageTokenBuckets(
  CodexParsedSession parsed,
) {
  var user = 0;
  var assistant = 0;
  var tool = 0;
  for (final message in parsed.messages) {
    final totalTokens = message.usage.totalTokens ?? 0;
    switch (message.authorType) {
      case CodexMessageAuthorType.user:
        user += totalTokens;
      case CodexMessageAuthorType.assistant:
        assistant += totalTokens;
      case CodexMessageAuthorType.tool:
        tool += totalTokens;
      case CodexMessageAuthorType.system:
      case CodexMessageAuthorType.reasoning:
      case CodexMessageAuthorType.unknown:
        break;
    }
  }
  if (user + assistant + tool == 0) {
    return (
      user: parsed.usage.inputTokens ?? 0,
      assistant: parsed.usage.outputTokens ?? 0,
      tool: 0,
    );
  }
  return (user: user, assistant: assistant, tool: tool);
}

void _replaceMessages(Database db, CodexParsedSession parsed, String now) {
  db.execute('delete from messages where session_id = ?', [parsed.internalId]);
  for (final message in parsed.messages) {
    db.execute(
      '''
      insert into messages (
        session_id,
        message_index,
        author_type,
        created_at_utc,
        first_line,
        content_plain,
        content_preview,
        content_truncated,
        token_input,
        token_output,
        token_cached,
        token_total,
        model,
        has_tool_calls,
        has_error,
        raw_type,
        created_at_db_utc,
        updated_at_db_utc
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        parsed.internalId,
        message.index,
        message.authorType.name,
        message.createdAtUtc?.toIso8601String(),
        message.firstLine,
        message.contentPlain,
        message.contentPreview,
        message.contentTruncated ? 1 : 0,
        message.usage.inputTokens,
        message.usage.outputTokens,
        message.usage.cachedInputTokens,
        message.usage.totalTokens,
        message.model,
        message.hasToolCalls ? 1 : 0,
        message.hasError ? 1 : 0,
        message.rawType,
        now,
        now,
      ],
    );
  }
}

void _replaceToolCalls(Database db, CodexParsedSession parsed) {
  db.execute('delete from tool_calls where session_id = ?', [
    parsed.internalId,
  ]);
  for (final tool in parsed.toolCalls) {
    db.execute(
      '''
      insert into tool_calls (
        session_id,
        tool_index,
        tool_name,
        status,
        started_at_utc,
        finished_at_utc,
        input_preview,
        output_preview,
        output_truncated,
        error_message
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        parsed.internalId,
        tool.toolIndex,
        tool.toolName,
        tool.status,
        tool.startedAtUtc?.toIso8601String(),
        tool.finishedAtUtc?.toIso8601String(),
        tool.inputPreview,
        tool.outputPreview,
        tool.outputTruncated ? 1 : 0,
        tool.errorMessage,
      ],
    );
  }
}

void _replaceUsageEvents(
  Database db,
  CodexParsedSession parsed,
  String now,
  _ProjectPathResolver projectResolver, {
  required SessionSourceType sourceType,
}) {
  db.execute('delete from usage_events where session_row_id = ?', [
    parsed.internalId,
  ]);
  final recordsInputs = db
      .select(
        "select 1 from sqlite_schema where type = 'table' and name = 'usage_event_inputs'",
      )
      .isNotEmpty;
  if (recordsInputs) {
    db.execute('delete from usage_event_inputs where session_row_id = ?', [
      parsed.internalId,
    ]);
  }
  if (parsed.usageEvents.isEmpty) {
    return;
  }

  final projectIdsByName = <String, int>{};
  final contextIdsByPaths = <(String?, String?), int>{};
  final projectStore = ProjectTagStateStore(db);
  final contextBased =
      DatabaseGenerationRepository(db).activeGeneration().targetSchemaVersion >=
      16;
  final insert = db.prepare('''
    insert into usage_events (
      session_row_id,
      source_record_ordinal,
      rollout_ordinal,
      turn_ordinal,
      epoch,
      occurred_at_utc,
      model,
      ${contextBased ? 'path_context_id,' : '''
      working_directory_display, working_directory_platform, working_directory_unc, project_id,
      '''}
      input_tokens,
      cached_input_tokens,
      cache_write_input_tokens,
      output_tokens,
      reasoning_output_tokens,
      total_tokens,
      branch_scope,
      derivation,
      event_fingerprint
    ) values (${List.filled(contextBased ? 17 : 20, '?').join(', ')})
    ''');
  final insertInputs = recordsInputs
      ? db.prepare('''
          insert into usage_event_inputs (
            session_row_id, source_record_ordinal, provider,
            request_input_tokens, model_context_window
          ) values (?, ?, ?, ?, ?)
          ''')
      : null;
  try {
    for (final event in parsed.usageEvents) {
      final autoProject = projectResolver.resolve(
        event.workingDirectory,
        sourceType: sourceType,
      );
      final projectId = autoProject == null
          ? null
          : projectIdsByName.putIfAbsent(
              autoProject.name,
              () => _upsertAutoProject(db, autoProject.name, now),
            );
      final usage = event.usage;
      final contextId = contextIdsByPaths.putIfAbsent(
        (event.workingDirectory, event.workingDirectoryUnc),
        () => projectStore.resolveUsagePathContext(
          displayPath: event.workingDirectory,
          platformPath: event.workingDirectory,
          uncPath: event.workingDirectoryUnc,
          detectedProjectId: projectId,
        ),
      );
      insert.execute([
        parsed.internalId,
        event.sourceRecordOrdinal,
        event.rolloutOrdinal,
        event.turnOrdinal,
        event.counterEpoch,
        event.occurredAtUtc?.toIso8601String(),
        event.model,
        if (contextBased)
          contextId
        else ...[
          event.workingDirectory,
          event.workingDirectory,
          event.workingDirectoryUnc,
          projectId,
        ],
        usage.inputTokens ?? 0,
        usage.cachedInputTokens ?? 0,
        usage.cacheWriteInputTokens ?? 0,
        usage.outputTokens ?? 0,
        usage.reasoningOutputTokens ?? 0,
        usage.totalTokens ?? 0,
        event.branchScope,
        event.derivation,
        event.eventFingerprint,
      ]);
      if (event.provider != null ||
          event.requestInputTokens != null ||
          event.modelContextWindow != null) {
        insertInputs?.execute([
          parsed.internalId,
          event.sourceRecordOrdinal,
          event.provider,
          event.requestInputTokens,
          event.modelContextWindow,
        ]);
      }
    }
  } finally {
    insert.close();
    insertInputs?.close();
  }
}

Set<String> _reconcileAffectedLegacyUsage(
  Database db, {
  required String replacedSessionRowId,
  required String? replacedLogicalSessionId,
}) {
  const legacyColumns = '''
    id,
    session_id,
    forked_from_id,
    parent_thread_id,
    parser_version,
    usage_projection_status,
    input_tokens,
    output_tokens,
    cached_input_tokens,
    total_tokens
    ''';
  const legacyPredicate = '''
    history_base_thread_id is null
    and subagent_history_start_ordinal is null
    and (
      (forked_from_id is not null and forked_from_id <> '')
      or (parent_thread_id is not null and parent_thread_id <> '')
    )
    ''';
  final affected = <String, _LegacyUsageSession>{};
  for (final row in db.select(
    'select $legacyColumns from sessions '
    'where id = ? and $legacyPredicate',
    [replacedSessionRowId],
  )) {
    final session = _LegacyUsageSession.fromRow(row);
    affected[session.rowId] = session;
  }
  final logicalId = replacedLogicalSessionId?.trim() ?? '';
  final pending = <String>[if (logicalId.isNotEmpty) logicalId];
  final visited = <String>{};
  while (pending.isNotEmpty) {
    final parentId = pending.removeLast();
    if (!visited.add(parentId)) continue;
    for (final row in db.select(
      '''
      select $legacyColumns, ($legacyPredicate) as needs_reconciliation
      from sessions
      where (
          forked_from_id = ?
          or (
            (forked_from_id is null or forked_from_id = '')
            and parent_thread_id = ?
          )
        )
      ''',
      [parentId, parentId],
    )) {
      // Traverse provenance-known nodes too: their own scopes are authoritative,
      // but a legacy descendant can still depend on their ancestry/cycle state.
      if (row['needs_reconciliation'] == 1) {
        final session = _LegacyUsageSession.fromRow(row);
        affected[session.rowId] = session;
      }
      final descendantId = (row['session_id'] as String?)?.trim() ?? '';
      if (descendantId.isNotEmpty && !visited.contains(descendantId)) {
        pending.add(descendantId);
      }
    }
  }

  final parentCache = <String, List<_LegacyUsageSession>>{};
  final fingerprintCache = <String, List<String>>{};
  List<_LegacyUsageSession> parentsFor(String parentLogicalId) {
    return parentCache.putIfAbsent(parentLogicalId, () {
      return db
          .select(
            '''
            select $legacyColumns
            from sessions
            where session_id = ?
            order by id
            ''',
            [parentLogicalId],
          )
          .map(_LegacyUsageSession.fromRow)
          .toList(growable: false);
    });
  }

  List<String> fingerprintsFor(String rowId) {
    return fingerprintCache.putIfAbsent(rowId, () {
      return db
          .select(
            '''
            select event_fingerprint
            from usage_events
            where session_row_id = ?
            order by source_record_ordinal
            ''',
            [rowId],
          )
          .map((row) => row['event_fingerprint'] as String)
          .toList(growable: false);
    });
  }

  bool hasCycle(_LegacyUsageSession child) {
    final visited = <String>{child.rowId};
    var current = child;
    while (current.parentLogicalId.isNotEmpty) {
      final parents = parentsFor(current.parentLogicalId);
      if (parents.length != 1) {
        return false;
      }
      final parent = parents.single;
      if (!visited.add(parent.rowId)) {
        return true;
      }
      current = parent;
    }
    return false;
  }

  for (final child in affected.values) {
    if (child.parserVersion != CodexSessionParser.currentVersion) {
      _markUsageProjectionUnresolved(db, child.rowId, 'legacy_pending');
      continue;
    }
    if (hasCycle(child)) {
      _markUsageProjectionAmbiguous(db, child.rowId);
      continue;
    }
    final childFingerprints = fingerprintsFor(child.rowId);
    if (childFingerprints.isEmpty) {
      if (!child.hasAggregateUsage) {
        _setUsageProjectionStatus(db, child.rowId, 'complete');
      } else {
        _markUsageProjectionAmbiguous(db, child.rowId);
      }
      continue;
    }
    final parents = parentsFor(child.parentLogicalId);
    if (parents.isEmpty) {
      _markUsageProjectionUnresolved(db, child.rowId, 'missing_parent');
      continue;
    }
    if (parents.length != 1) {
      _markUsageProjectionAmbiguous(db, child.rowId);
      continue;
    }
    final parent = parents.single;
    if (parent.parserVersion != CodexSessionParser.currentVersion) {
      _markUsageProjectionUnresolved(db, child.rowId, 'legacy_pending');
      continue;
    }

    final parentFingerprints = fingerprintsFor(parent.rowId);
    if (parentFingerprints.isEmpty &&
        (parent.projectionStatus != 'complete' || parent.hasAggregateUsage)) {
      _markUsageProjectionAmbiguous(db, child.rowId);
      continue;
    }
    var prefixLength = 0;
    final comparableLength = math.min(
      parentFingerprints.length,
      childFingerprints.length,
    );
    while (prefixLength < comparableLength &&
        parentFingerprints[prefixLength] == childFingerprints[prefixLength]) {
      prefixLength++;
    }
    if (parentFingerprints.isNotEmpty && prefixLength == 0) {
      _markUsageProjectionAmbiguous(db, child.rowId);
      continue;
    }

    if (prefixLength == 0) {
      db.execute(
        "update usage_events set branch_scope = 'local' "
        'where session_row_id = ?',
        [child.rowId],
      );
    } else {
      final inheritedEndOrdinal =
          db
                  .select(
                    '''
            select source_record_ordinal
            from usage_events
            where session_row_id = ?
            order by source_record_ordinal
            limit 1 offset ?
            ''',
                    [child.rowId, prefixLength - 1],
                  )
                  .single['source_record_ordinal']
              as int;
      db.execute(
        '''
        update usage_events
        set branch_scope = case
          when source_record_ordinal <= ? then 'inherited'
          else 'local'
        end
        where session_row_id = ?
        ''',
        [inheritedEndOrdinal, child.rowId],
      );
    }
    _setUsageProjectionStatus(db, child.rowId, 'complete');
  }
  return {replacedSessionRowId, ...affected.keys};
}

void _setUsageProjectionStatus(Database db, String rowId, String status) {
  db.execute('update sessions set usage_projection_status = ? where id = ?', [
    status,
    rowId,
  ]);
}

void _markUsageProjectionAmbiguous(Database db, String rowId) {
  _markUsageProjectionUnresolved(db, rowId, 'ambiguous');
}

void _markUsageProjectionUnresolved(Database db, String rowId, String status) {
  db.execute(
    "update usage_events set branch_scope = 'ambiguous' "
    'where session_row_id = ?',
    [rowId],
  );
  _setUsageProjectionStatus(db, rowId, status);
}

class _LegacyUsageSession {
  const _LegacyUsageSession({
    required this.rowId,
    required this.parentLogicalId,
    required this.parserVersion,
    required this.projectionStatus,
    required this.hasAggregateUsage,
  });

  factory _LegacyUsageSession.fromRow(Row row) {
    final forkedFromId = (row['forked_from_id'] as String?)?.trim() ?? '';
    final parentThreadId = (row['parent_thread_id'] as String?)?.trim() ?? '';
    return _LegacyUsageSession(
      rowId: row['id'] as String,
      parentLogicalId: forkedFromId.isNotEmpty ? forkedFromId : parentThreadId,
      parserVersion: row['parser_version'] as int,
      projectionStatus: row['usage_projection_status'] as String,
      hasAggregateUsage:
          (row['input_tokens'] as int? ?? 0) > 0 ||
          (row['output_tokens'] as int? ?? 0) > 0 ||
          (row['cached_input_tokens'] as int? ?? 0) > 0 ||
          (row['total_tokens'] as int? ?? 0) > 0,
    );
  }

  final String rowId;
  final String parentLogicalId;
  final int parserVersion;
  final String projectionStatus;
  final bool hasAggregateUsage;
}

void _upsertScanStatusesOnly(
  Database db,
  List<ScannedFileStatus> statuses,
  String now,
) {
  if (statuses.isEmpty) {
    return;
  }

  db.execute('drop table if exists temp_scan_statuses');
  db.execute('''
    create temp table temp_scan_statuses (
      source_path text primary key,
      status text not null,
      source_state text not null
    )
    ''');

  final insertStatus = db.prepare('''
    insert or replace into temp_scan_statuses (source_path, status, source_state)
    values (?, ?, ?)
    ''');
  try {
    for (final status in statuses) {
      insertStatus.execute([
        status.sourcePath,
        status.status.wireName,
        status.sourceState.wireName,
      ]);
    }
  } finally {
    insertStatus.close();
  }

  db.execute(
    '''
    update sessions
    set
      scan_status = (
        select t.status
        from temp_scan_statuses t
        where t.source_path = sessions.source_file_path
           or t.source_path = sessions.source_file_unc_path
        limit 1
      ),
      source_state = (
        select t.source_state
        from temp_scan_statuses t
        where t.source_path = sessions.source_file_path
           or t.source_path = sessions.source_file_unc_path
        limit 1
      ),
      parse_status = case
        when (
          select t.status
          from temp_scan_statuses t
          where t.source_path = sessions.source_file_path
             or t.source_path = sessions.source_file_unc_path
          limit 1
        ) = 'parse_error' then 'parse_error'
        else parse_status
      end,
      updated_at_utc = case
        when (
          select t.status
          from temp_scan_statuses t
          where t.source_path = sessions.source_file_path
             or t.source_path = sessions.source_file_unc_path
          limit 1
        ) = 'available' then updated_at_utc
        else ?
      end,
      last_scanned_utc = case
        when (
          select t.status
          from temp_scan_statuses t
          where t.source_path = sessions.source_file_path
             or t.source_path = sessions.source_file_unc_path
          limit 1
        ) = 'available' then last_scanned_utc
        else ?
      end
    where exists (
      select 1
      from temp_scan_statuses t
      where t.source_path = sessions.source_file_path
         or t.source_path = sessions.source_file_unc_path
    )
    ''',
    [now, now],
  );

  final missingStatuses = db.select('''
    select t.source_path, t.status, t.source_state
    from temp_scan_statuses t
    where t.status not in ('available', 'missing', 'path_unreachable')
      and
      not exists (
      select 1
      from sessions s
      where s.source_file_path = t.source_path
         or s.source_file_unc_path = t.source_path
    )
    ''');
  final insertMissing = db.prepare('''
    insert into sessions (
      id,
      source_type,
      source_file_path,
      display_path,
      platform_path,
      scan_status,
      source_state,
      parse_status,
      created_at_utc,
      updated_at_utc,
      last_scanned_utc
    ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    on conflict(id) do update set
      scan_status = excluded.scan_status,
      source_state = excluded.source_state,
      updated_at_utc = excluded.updated_at_utc,
      last_scanned_utc = excluded.last_scanned_utc
    ''');
  try {
    for (final row in missingStatuses) {
      final sourcePath = row['source_path'] as String;
      final status = row['status'] as String;
      final sourceState = row['source_state'] as String;
      insertMissing.execute([
        _sourceStatusId(sourcePath),
        _sourceTypeLabel(sourcePath),
        sourcePath,
        sourcePath,
        sourcePath,
        status,
        sourceState,
        status == SessionFileStatus.parseError.wireName
            ? 'parse_error'
            : 'available',
        now,
        now,
        now,
      ]);
    }
  } finally {
    insertMissing.close();
    db.execute('delete from temp_scan_statuses');
  }
}

List<SessionRowViewModel> _loadRows(
  Database db, {
  bool includeMessages = false,
  String? sessionId,
  int? limit,
  int offset = 0,
  UsagePricingCatalog pricing = const UsagePricingCatalog({}),
}) {
  final query = sessionListQuery(
    sessionId: sessionId,
    limit: limit,
    offset: offset,
  );
  final rows = db.select(query.sql, query.parameters);
  final sessionIds = [for (final row in rows) row['id'] as String];
  final tagsBySessionId = _loadTagsBySessionId(db, sessionIds);
  final persistedCosts = UsageSummaryRepository(db).loadPersistedSessionCosts(
    sessionIds,
    projectionVersion: CodexSessionParser.currentVersion,
  );
  return [
    for (final row in rows)
      _loadRow(
        db,
        row,
        includeMessages: includeMessages,
        pricing: pricing,
        tagsBySessionId: tagsBySessionId,
        persistedCost: persistedCosts?[row['id']],
      ),
  ];
}

int _visibleRowCount(Database db) {
  final row = db.select('''
    select count(*) as count
    from sessions s
    where s.parse_status = 'available'
      and s.scan_status = 'available'
      and s.session_id is not null and s.session_id <> ''
    ''').single;
  return row['count'] as int? ?? 0;
}

SessionRowViewModel _loadRow(
  Database db,
  Row row, {
  required bool includeMessages,
  required UsagePricingCatalog pricing,
  required Map<String, List<String>> tagsBySessionId,
  UsageCostEstimate? persistedCost,
}) {
  final inputTokens = row['input_tokens'] as int? ?? 0;
  final outputTokens = row['output_tokens'] as int? ?? 0;
  final cachedInputTokens = row['cached_input_tokens'] as int? ?? 0;
  final storedUserMessageTokens = row['user_message_tokens'] as int? ?? 0;
  final storedAssistantResponseTokens =
      row['assistant_response_tokens'] as int? ?? 0;
  final storedToolCallTokens = row['tool_call_tokens'] as int? ?? 0;
  final hasMessageTokenBreakdown =
      storedUserMessageTokens +
          storedAssistantResponseTokens +
          storedToolCallTokens >
      0;
  final model = row['model_primary'] as String? ?? '';
  final estimate =
      persistedCost ??
      estimateUsageCost(
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        cachedInputTokens: cachedInputTokens,
        model: model.isEmpty ? null : model,
        pricing: pricing,
      );
  final sourceType = row['source_type'] as String?;
  final workingDirectoryDisplay = row['working_directory_display'] as String?;
  final openablePath = sourceType == 'wsl'
      ? row['working_directory_unc'] as String? ?? ''
      : row['working_directory_unc'] as String? ??
            workingDirectoryDisplay ??
            row['source_file_unc_path'] as String? ??
            row['source_file_path'] as String? ??
            '';
  return SessionRowViewModel(
    id: row['id'] as String,
    sessionId: row['session_id'] as String? ?? '',
    threadName: row['thread_name'] as String? ?? '',
    threadSource: row['thread_source'] as String? ?? '',
    parentThreadId: row['parent_thread_id'] as String? ?? '',
    agentNickname: row['agent_nickname'] as String? ?? '',
    agentRole: row['agent_role'] as String? ?? '',
    subagentDepth: row['subagent_depth'] as int?,
    sourceFilePath: row['source_file_path'] as String? ?? '',
    displayPath: row['display_path'] as String? ?? '',
    workingDirectory: workingDirectoryDisplay ?? '',
    openablePath: openablePath,
    startedAtUtc:
        _dateTime(row['started_at_utc'] as String?) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    lastMessageAtUtc:
        _dateTime(row['last_message_at_utc'] as String?) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    platform: sourceType == 'wsl'
        ? SessionRowPlatform.wsl
        : SessionRowPlatform.windows,
    sourceState: _sessionRowSourceState(row['source_state'] as String?),
    project: row['project_name_snapshot'] as String? ?? '',
    path:
        row['working_directory_display'] as String? ??
        row['display_path'] as String? ??
        row['source_file_path'] as String? ??
        '',
    title: _cleanDisplayTitle(row['row_title'] as String?),
    summary: _cleanDisplaySummary(row['summary'] as String?),
    messageCount: row['message_count'] as int? ?? 0,
    userMessageCount: row['user_message_count'] as int? ?? 0,
    assistantMessageCount: row['assistant_message_count'] as int? ?? 0,
    toolCallCount: row['tool_call_count'] as int? ?? 0,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cachedInputTokens: cachedInputTokens,
    userMessageTokens: hasMessageTokenBreakdown
        ? storedUserMessageTokens
        : inputTokens,
    assistantResponseTokens: hasMessageTokenBreakdown
        ? storedAssistantResponseTokens
        : outputTokens,
    toolCallTokens: storedToolCallTokens,
    totalTokens: row['total_tokens'] as int? ?? 0,
    estimatedCostText: estimate.estimatedCostText,
    costUnknown: estimate.costUnknown,
    costUpdating: estimate.updating,
    costPartialUnsupportedUnits: estimate.partialUnsupportedUnits,
    model: model,
    modelsUsed: _decodeMembership(row['models_used'] as String?),
    tags: tagsBySessionId[row['id'] as String] ?? const [],
    status: _rowStatus(row),
    isPinned: (row['is_pinned'] as int? ?? 0) == 1,
    isArchived: (row['is_archived'] as int? ?? 0) == 1,
    hasError: (row['has_errors'] as int? ?? 0) == 1,
    evalReady: (row['eval_ready'] as int? ?? 0) == 1,
    evalStatus: row['eval_status'] as String? ?? '',
    evalNotes: row['eval_notes'] as String? ?? '',
    evalExpectedOutput: row['eval_expected_output'] as String? ?? '',
    evalReviewedAtUtc: _dateTime(row['eval_reviewed_at_utc'] as String?),
    evalUpdatedAtUtc: _dateTime(row['eval_updated_at_utc'] as String?),
    conversationMessages: includeMessages
        ? _loadMessages(db, row['id'] as String)
        : const [],
  );
}

SessionRowSourceState _sessionRowSourceState(String? value) {
  return switch (value) {
    'codex_archived' => SessionRowSourceState.codexArchived,
    'missing' => SessionRowSourceState.missing,
    _ => SessionRowSourceState.active,
  };
}

Map<String, List<String>> _loadTagsBySessionId(
  Database db,
  List<String> sessionIds,
) {
  if (sessionIds.isEmpty) {
    return const {};
  }
  final placeholders = List.filled(sessionIds.length, '?').join(', ');
  final rows = db.select('''
    select st.session_id, t.name
    from session_tags st
    join tags t on t.id = st.tag_id
    where st.session_id in ($placeholders)
    order by st.session_id, t.name
    ''', sessionIds);
  final result = <String, List<String>>{};
  for (final row in rows) {
    (result[row['session_id'] as String] ??= <String>[]).add(
      row['name'] as String,
    );
  }
  return result;
}

List<ConversationMessageViewModel> _loadMessages(
  Database db,
  String sessionId, {
  int? tailBodyPageSize = _conversationTailBodyPageSize,
}) {
  if (tailBodyPageSize == null) {
    return _loadFullMessages(db, sessionId);
  }
  final rows = Profiling.spanSync(
    'scan.runtime.load_session_detail.message_index_query',
    () => db.select(
      '''
      select
        message_index,
        author_type,
        created_at_utc,
        content_preview,
        null as content_plain,
        token_total,
        model,
        has_error,
        has_tool_calls
      from messages
      where session_id = ?
      order by message_index
      ''',
      [sessionId],
    ),
    arguments: {'session_id': sessionId},
  );
  final bodyRows = Profiling.spanSync(
    'scan.runtime.load_session_detail.message_tail_body_query',
    () => db.select(
      '''
      select message_index, content_plain
      from (
        select message_index, content_plain
        from messages
        where session_id = ?
        order by message_index desc
        limit ?
      )
      order by message_index
      ''',
      [sessionId, tailBodyPageSize],
    ),
    arguments: {'session_id': sessionId, 'limit': tailBodyPageSize},
  );
  final bodiesByIndex = {
    for (final row in bodyRows)
      row['message_index'] as int: row['content_plain'] as String?,
  };
  return Profiling.spanSync(
    'scan.runtime.load_session_detail.message_view_models',
    () => [
      for (final row in rows)
        if (!_isInjectedContextRow(row))
          ConversationMessageViewModel(
            id: '$sessionId:${row['message_index']}',
            number: row['message_index'] as int,
            author: _messageAuthor(row['author_type'] as String?),
            createdAtUtc:
                _dateTime(row['created_at_utc'] as String?) ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
            preview: row['content_preview'] as String? ?? '',
            body: bodiesByIndex[row['message_index'] as int] ?? '',
            tokenCount: row['token_total'] as int?,
            hasError: (row['has_error'] as int? ?? 0) == 1,
            hasToolOutput: (row['has_tool_calls'] as int? ?? 0) == 1,
            isBodyLoaded: bodiesByIndex.containsKey(
              row['message_index'] as int,
            ),
          ),
    ],
    arguments: {'session_id': sessionId, 'row_count': rows.length},
  );
}

List<ConversationMessageViewModel> _loadFullMessages(
  Database db,
  String sessionId,
) {
  final rows = Profiling.spanSync(
    'scan.runtime.load_session_detail.full_message_query',
    () => db.select(
      '''
      select
        message_index,
        author_type,
        created_at_utc,
        content_preview,
        content_plain,
        token_total,
        model,
        has_error,
        has_tool_calls
      from messages
      where session_id = ?
      order by message_index
      ''',
      [sessionId],
    ),
    arguments: {'session_id': sessionId},
  );
  return Profiling.spanSync(
    'scan.runtime.load_session_detail.full_message_view_models',
    () => [
      for (final row in rows)
        if (!_isInjectedContextRow(row))
          ConversationMessageViewModel(
            id: '$sessionId:${row['message_index']}',
            number: row['message_index'] as int,
            author: _messageAuthor(row['author_type'] as String?),
            createdAtUtc:
                _dateTime(row['created_at_utc'] as String?) ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
            preview: row['content_preview'] as String? ?? '',
            body:
                row['content_plain'] as String? ??
                row['content_preview'] as String? ??
                '',
            tokenCount: row['token_total'] as int?,
            hasError: (row['has_error'] as int? ?? 0) == 1,
            hasToolOutput: (row['has_tool_calls'] as int? ?? 0) == 1,
          ),
    ],
    arguments: {'session_id': sessionId, 'row_count': rows.length},
  );
}

List<ConversationMessageViewModel> _loadMessagePage(
  Database db,
  String sessionId,
  int anchorMessageNumber,
) {
  final start = math.max(
    0,
    anchorMessageNumber - _conversationMessagePageRadius,
  );
  final end = anchorMessageNumber + _conversationMessagePageRadius;
  final rows = Profiling.spanSync(
    'scan.runtime.load_message_page.query',
    () => db.select(
      '''
      select
        message_index,
        author_type,
        created_at_utc,
        content_preview,
        content_plain,
        token_total,
        model,
        has_error,
        has_tool_calls
      from messages
      where session_id = ?
        and message_index between ? and ?
      order by message_index
      ''',
      [sessionId, start, end],
    ),
    arguments: {
      'session_id': sessionId,
      'anchor_message_number': anchorMessageNumber,
      'start_message_number': start,
      'end_message_number': end,
    },
  );
  return Profiling.spanSync(
    'scan.runtime.load_message_page.view_models',
    () => [
      for (final row in rows)
        if (!_isInjectedContextRow(row))
          ConversationMessageViewModel(
            id: '$sessionId:${row['message_index']}',
            number: row['message_index'] as int,
            author: _messageAuthor(row['author_type'] as String?),
            createdAtUtc:
                _dateTime(row['created_at_utc'] as String?) ??
                DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
            preview: row['content_preview'] as String? ?? '',
            body:
                row['content_plain'] as String? ??
                row['content_preview'] as String? ??
                '',
            tokenCount: row['token_total'] as int?,
            hasError: (row['has_error'] as int? ?? 0) == 1,
            hasToolOutput: (row['has_tool_calls'] as int? ?? 0) == 1,
          ),
    ],
    arguments: {'session_id': sessionId, 'row_count': rows.length},
  );
}

bool _isInjectedContextRow(Row row) {
  return row['author_type'] == 'user' &&
      isInjectedEnvironmentContextMessage(
        row['content_plain'] as String? ??
            row['content_preview'] as String? ??
            '',
      );
}

int _upsertAutoProject(Database db, String name, String now) {
  db.execute(
    '''
    insert into projects (name, description, is_active, created_at_utc, updated_at_utc)
    values (?, ?, 1, ?, ?)
    on conflict(name) do update set updated_at_utc = excluded.updated_at_utc
    ''',
    [name, 'Auto-detected from session working directory.', now, now],
  );
  return db.select('select id from projects where name = ?', [
        name,
      ]).single['id']
      as int;
}

String _cleanDisplayTitle(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return '';
  }
  if (trimmed.toLowerCase().startsWith('# agents.md')) {
    return '';
  }
  return trimmed;
}

String _cleanDisplaySummary(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return '';
  }
  if (trimmed.toLowerCase() == 'auto') {
    return '';
  }
  return trimmed;
}

Future<Map<String, CodexThreadNameEntry>> _readSessionIndexThreadNames(
  PathSettings paths,
) {
  return Profiling.spanAsync('scan.runtime.read_session_index_names', () async {
    final reader = CodexSessionIndexReader();
    final results = await Future.wait([
      reader.read(File(p.join(paths.windowsCodexPath, 'session_index.jsonl'))),
      reader.read(File(p.join(paths.wslCodexUncPath, 'session_index.jsonl'))),
    ]);
    final merged = <String, CodexThreadNameEntry>{};
    for (final result in results) {
      for (final entry in result.entriesById.values) {
        final previous = merged[entry.id];
        if (previous == null ||
            _isNewerThreadNameEntry(
              entry.updatedAtUtc,
              previous.updatedAtUtc,
            )) {
          merged[entry.id] = entry;
        }
      }
    }
    return merged;
  });
}

bool _isNewerThreadNameEntry(DateTime? candidate, DateTime? previous) {
  if (candidate == null) {
    return previous == null;
  }
  if (previous == null) {
    return true;
  }
  return candidate.isAfter(previous);
}

Set<String> _applySessionIndexThreadNames(
  Database db,
  Map<String, CodexThreadNameEntry> threadNamesBySessionId,
) {
  if (threadNamesBySessionId.isEmpty) {
    return const {};
  }
  final changedIds = <String>{};
  db.execute('begin immediate');
  try {
    for (final entry in threadNamesBySessionId.values) {
      final threadName = entry.threadName.trim();
      if (threadName.isEmpty) {
        continue;
      }
      final rows = db.select(
        '''
        select rowid, id, thread_name
        from sessions
        where session_id = ?
        ''',
        [entry.id],
      );
      for (final row in rows) {
        if ((row['thread_name'] as String? ?? '') == threadName) {
          continue;
        }
        final rowid = row['rowid'] as int;
        db.execute('update sessions set thread_name = ? where rowid = ?', [
          threadName,
          rowid,
        ]);
        changedIds.add(row['id'] as String);
      }
    }
    db.execute('commit');
  } on Object {
    db.execute('rollback');
    rethrow;
  }
  return changedIds;
}

void _cleanSessionMetadataPlaceholders(Database db) {
  final rows = db.select('''
    select
      rowid,
      lower(trim(coalesce(title, ''))) like '# agents.md%' as bad_title,
      lower(trim(coalesce(summary, ''))) = 'auto' as bad_summary
    from sessions
    where lower(trim(coalesce(title, ''))) like '# agents.md%'
       or lower(trim(coalesce(summary, ''))) = 'auto'
    ''');
  if (rows.isEmpty) {
    return;
  }
  db.execute('begin immediate');
  try {
    for (final row in rows) {
      final rowid = row['rowid'] as int;
      final badTitle = (row['bad_title'] as int? ?? 0) == 1;
      final badSummary = (row['bad_summary'] as int? ?? 0) == 1;
      db.execute(
        '''
        update sessions
        set title = case when ? then null else title end,
            summary = case when ? then null else summary end
        where rowid = ?
        ''',
        [badTitle ? 1 : 0, badSummary ? 1 : 0, rowid],
      );
      db.execute(
        '''
        update session_search
        set title = case when ? then '' else title end,
            summary = case when ? then '' else summary end
        where rowid = ?
        ''',
        [badTitle ? 1 : 0, badSummary ? 1 : 0, rowid],
      );
    }
    db.execute('commit');
  } on Object {
    db.execute('rollback');
    rethrow;
  }
}

Future<void> _backfillAutomaticProjects(
  Database db, {
  required _WslProjectResolutionCache wslProjects,
}) async {
  final rows = db.select('''
    select id, source_type, working_directory_display
    from sessions
    where (
        detected_project_id is null
        or (
          coalesce(project_override, 0) = 0
          and coalesce(trim(project_name_snapshot), '') = ''
        )
      )
      and coalesce(trim(working_directory_display), '') <> ''
      and parse_status = 'available'
      and scan_status = 'available'
    ''');
  if (rows.isEmpty) {
    return;
  }
  final candidates = [
    for (final row in rows)
      _ProjectPathCandidate(
        row['working_directory_display'] as String?,
        (row['source_type'] as String?) == 'wsl'
            ? SessionSourceType.wsl
            : SessionSourceType.windows,
      ),
  ];
  final resolver = await _ProjectPathResolver.create(
    candidates,
    wslProjects: wslProjects,
  );
  final resolvedRows = <({String sessionId, String projectName})>[];
  for (var i = 0; i < rows.length; i++) {
    final row = rows[i];
    final candidate = candidates[i];
    final autoProject = resolver.resolve(
      candidate.workingDirectory,
      sourceType: candidate.sourceType,
    );
    final projectName = autoProject?.name.trim() ?? '';
    if (projectName.isNotEmpty) {
      resolvedRows.add((
        sessionId: row['id'] as String,
        projectName: projectName,
      ));
    }
  }
  if (resolvedRows.isEmpty) {
    return;
  }
  _applyResolvedProjectRows(db, resolvedRows);
}

typedef _ParsedProjectCandidate = ({
  String sessionId,
  String? workingDirectory,
  SessionSourceType sourceType,
});

Future<void> _applyResolvedProjectsForParsedCandidates(
  Database db,
  Iterable<_ParsedProjectCandidate> parsedCandidates, {
  required _WslProjectResolutionCache wslProjects,
  required Future<void> Function(Future<void> Function()) write,
}) async {
  final sessionIds = parsedCandidates
      .map((candidate) => candidate.sessionId)
      .toSet()
      .toList(growable: false);
  if (sessionIds.isEmpty) {
    return;
  }
  final candidates = <_ParsedProjectCandidate>[];
  const queryBatchSize = 500;
  for (var offset = 0; offset < sessionIds.length; offset += queryBatchSize) {
    final end = math.min(offset + queryBatchSize, sessionIds.length);
    final batch = sessionIds.sublist(offset, end);
    final parameters = List.filled(batch.length, '?').join(', ');
    for (final row in db.select('''
      select id, working_directory_display, source_type
      from sessions
      where id in ($parameters)
      ''', batch)) {
      candidates.add((
        sessionId: row['id'] as String,
        workingDirectory: row['working_directory_display'] as String?,
        sourceType: row['source_type'] == 'wsl'
            ? SessionSourceType.wsl
            : SessionSourceType.windows,
      ));
    }
  }
  final resolver = await _ProjectPathResolver.create([
    for (final candidate in candidates)
      _ProjectPathCandidate(candidate.workingDirectory, candidate.sourceType),
  ], wslProjects: wslProjects);
  final resolvedRows = <({String sessionId, String projectName})>[];
  for (final candidate in candidates) {
    final autoProject = resolver.resolve(
      candidate.workingDirectory,
      sourceType: candidate.sourceType,
    );
    final projectName = autoProject?.name.trim() ?? '';
    if (projectName.isNotEmpty) {
      resolvedRows.add((
        sessionId: candidate.sessionId,
        projectName: projectName,
      ));
    }
  }
  if (resolvedRows.isEmpty) {
    return;
  }
  await write(() async => _applyResolvedProjectRows(db, resolvedRows));
}

void _applyResolvedProjectRows(
  Database db,
  List<({String sessionId, String projectName})> resolvedRows,
) {
  db.execute('begin immediate');
  try {
    final now = DateTime.now().toUtc().toIso8601String();
    for (final row in resolvedRows) {
      final projectName = row.projectName;
      final projectId = _upsertAutoProject(db, projectName, now);
      final sessionId = row.sessionId;
      db.execute(
        '''
        update sessions
        set detected_project_id = ?,
            updated_at_utc = ?
        where id = ?
        ''',
        [projectId, now, sessionId],
      );
      ProjectTagStateStore(db).refreshSessionProject(sessionId);
    }
    db.execute('commit');
  } on Object {
    db.execute('rollback');
    rethrow;
  }
}

class _ResolvedProjectPath {
  const _ResolvedProjectPath(this.name);

  final String name;
}

class _ProjectPathCandidate {
  const _ProjectPathCandidate(this.workingDirectory, this.sourceType);

  final String? workingDirectory;
  final SessionSourceType sourceType;
}

Iterable<_ProjectPathCandidate> _projectPathCandidatesForSessions(
  Iterable<ScannedSessionFile> sessions,
) sync* {
  for (final session in sessions) {
    yield _ProjectPathCandidate(
      session.parsedSession.workingDirectoryDisplay,
      session.sourceType,
    );
    for (final event in session.parsedSession.usageEvents) {
      yield _ProjectPathCandidate(event.workingDirectory, session.sourceType);
    }
  }
}

class _WslProjectResolutionCache {
  _WslProjectResolutionCache(this._resolver);

  final WslProjectResolver _resolver;
  final _attemptedPaths = <String>{};
  final _resolvedNames = <String, String>{};

  Future<Map<String, String>> resolve(
    Iterable<String> workingDirectories,
  ) async {
    final requestedPaths = workingDirectories
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toSet();
    final unresolvedPaths = requestedPaths
        .where((path) => !_attemptedPaths.contains(path))
        .toSet();
    if (unresolvedPaths.isNotEmpty) {
      _attemptedPaths.addAll(unresolvedPaths);
      try {
        final resolved = await Profiling.spanAsync(
          'scan.runtime.resolve_wsl_project',
          () => _resolver.resolveProjectNames(unresolvedPaths),
        );
        for (final entry in resolved.entries) {
          final path = entry.key.trim();
          final name = entry.value.trim();
          if (unresolvedPaths.contains(path) && name.isNotEmpty) {
            _resolvedNames[path] = name;
          }
        }
      } on Object {
        // WSL can be unavailable during startup/tests. Callers use path fallback.
      }
    }
    return {
      for (final path in requestedPaths)
        if ((_resolvedNames[path] ?? '').isNotEmpty)
          path: _resolvedNames[path]!,
    };
  }
}

class _ProjectPathResolver {
  _ProjectPathResolver({this.resolvedWslProjectNames = const {}});

  final Map<String, String> resolvedWslProjectNames;
  final _cache = <String, _ResolvedProjectPath?>{};

  static Future<_ProjectPathResolver> create(
    Iterable<_ProjectPathCandidate> candidates, {
    required _WslProjectResolutionCache wslProjects,
  }) async {
    final wslPaths = <String>{};
    for (final candidate in candidates) {
      final path = candidate.workingDirectory?.trim();
      if (candidate.sourceType == SessionSourceType.wsl &&
          path != null &&
          path.isNotEmpty) {
        wslPaths.add(path);
      }
    }
    return _ProjectPathResolver(
      resolvedWslProjectNames: await wslProjects.resolve(wslPaths),
    );
  }

  _ResolvedProjectPath? resolve(
    String? workingDirectory, {
    required SessionSourceType sourceType,
  }) {
    final path = workingDirectory?.trim();
    if (path == null || path.isEmpty) {
      return null;
    }
    return _cache.putIfAbsent('$sourceType|$path', () {
      return switch (sourceType) {
        SessionSourceType.windows => _resolveWindows(path),
        SessionSourceType.wsl => _resolveWsl(path),
      };
    });
  }

  _ResolvedProjectPath? _resolveWindows(String path) {
    final directory = Directory(path);
    if (!directory.existsSync()) {
      return _projectFromPath(path);
    }
    var current = directory.absolute;
    while (true) {
      if (Directory(p.join(current.path, '.git')).existsSync() ||
          File(p.join(current.path, '.git')).existsSync()) {
        return _projectFromPath(current.path);
      }
      final parent = current.parent;
      if (parent.path == current.path) {
        break;
      }
      current = parent;
    }
    return _projectFromPath(directory.path);
  }

  _ResolvedProjectPath? _resolveWsl(String path) {
    final name = resolvedWslProjectNames[path]?.trim() ?? '';
    if (name.isNotEmpty) {
      return _ResolvedProjectPath(name);
    }
    return _projectFromPath(path);
  }

  _ResolvedProjectPath? _projectFromPath(String path) {
    final segments = path
        .replaceAll(r'\', '/')
        .split('/')
        .where((segment) => segment.trim().isNotEmpty)
        .toList();
    if (segments.isEmpty) {
      return null;
    }
    return _ResolvedProjectPath(segments.last);
  }
}

String _statusMessage(
  SessionScanResult result, {
  required int visibleSessionCount,
  bool? cancelled,
}) {
  final available = _plural(visibleSessionCount, 'session');
  final parsed = _plural(result.progress.filesParsed, 'new or changed session');
  if (cancelled ?? result.cancelled) {
    return 'Scan cancelled. $available available. $parsed parsed before cancellation.';
  }
  if (result.errors.any(
    (error) => error.status == SessionFileStatus.pathUnreachable,
  )) {
    final paths = result.errors
        .where((error) => error.status == SessionFileStatus.pathUnreachable)
        .map((error) => error.sourcePath)
        .join('; ');
    return 'Scan finished. $available available. $parsed parsed. '
        'Session root is unreachable. Unreachable paths: $paths';
  }
  if (result.progress.filesFound == 0 && visibleSessionCount == 0) {
    return 'Scan finished. No supported files found.';
  }
  final failed = result.progress.filesFailed;
  final failures = failed == 0
      ? ''
      : ' ${_plural(failed, 'file')} could not be parsed.';
  return 'Scan finished. $available available. $parsed parsed.$failures';
}

String _cacheRepairProgressMessage(SessionCacheRepairPhase phase) {
  final activity = switch (phase) {
    SessionCacheRepairPhase.auditing => 'auditing cached rows',
    SessionCacheRepairPhase.creatingBackup => 'creating backup',
    SessionCacheRepairPhase.verifyingBackup => 'verifying backup',
    SessionCacheRepairPhase.applying => 'applying verified cleanup',
  };
  return 'Maintaining session cache: $activity...';
}

String _progressStatusMessage(ScanProgress progress) {
  final directories = _plural(progress.directoriesScanned, 'directory');
  final found = _plural(progress.filesFound, 'JSON file');
  final skipped = _plural(progress.filesSkipped, 'unchanged file');
  final parsed = _plural(progress.filesParsed, 'changed JSON file');
  final sessions = _plural(progress.filesParsed, 'valid session');
  final failed = _plural(progress.filesFailed, 'file');
  final percent = _estimatedProgressPercent(progress);
  return 'Scanning... scanned $directories, found $found, skipped $skipped, parsed $parsed, '
      'found $sessions, failed to parse $failed, estimated progress $percent%, '
      'ETA ${_estimatedEta(progress)}.';
}

int _estimatedProgressPercent(ScanProgress progress) {
  if (progress.finishedAtUtc != null) {
    return 100;
  }
  final processed =
      progress.filesParsed + progress.filesSkipped + progress.filesFailed;
  final totalKnown = [
    progress.filesFound,
    processed,
  ].reduce((left, right) => left > right ? left : right);
  if (totalKnown == 0) {
    return 0;
  }
  return ((processed / totalKnown) * 100).clamp(0, 99).round();
}

List<SessionScanRoot> _sessionScanRoots(
  String configuredPath,
  SessionSourceType sourceType,
) {
  final trimmed = configuredPath.trim();
  if (trimmed.isEmpty) {
    return const [];
  }
  final normalized = p.normalize(trimmed);
  final leaf = p.basename(normalized).toLowerCase();
  final isNamedSessionRoot = leaf == 'sessions' || leaf == 'archived_sessions';
  final codexRoot = isNamedSessionRoot ? p.dirname(normalized) : normalized;
  final activePath = p.join(codexRoot, 'sessions');
  final archivedPath = p.join(codexRoot, 'archived_sessions');
  final isCodexRoot =
      isNamedSessionRoot ||
      leaf == '.codex' ||
      Directory(activePath).existsSync() ||
      Directory(archivedPath).existsSync();
  if (!isCodexRoot) {
    return [
      SessionScanRoot(
        path: normalized,
        sourceType: sourceType,
        sourceState: SessionSourceState.active,
      ),
    ];
  }
  return [
    SessionScanRoot(
      path: activePath,
      availabilityRootPath: codexRoot,
      sourceType: sourceType,
      sourceState: SessionSourceState.active,
    ),
    SessionScanRoot(
      path: archivedPath,
      availabilityRootPath: codexRoot,
      sourceType: sourceType,
      sourceState: SessionSourceState.codexArchived,
    ),
  ];
}

Map<String, Object?> _progressLogDetails(ScanProgress progress) => {
  'directories_scanned': progress.directoriesScanned,
  'files_found': progress.filesFound,
  'files_skipped': progress.filesSkipped,
  'files_parsed': progress.filesParsed,
  'files_failed': progress.filesFailed,
  'sessions_added': progress.sessionsAdded,
  'sessions_changed': progress.sessionsChanged,
  'sessions_missing': progress.sessionsMissing,
  'finished': progress.finishedAtUtc != null,
};

int _defaultParserWorkerCount() {
  final processors = Platform.numberOfProcessors;
  if (processors <= 2) {
    return 1;
  }
  return math.min(8, processors - 1);
}

int _defaultDirectoryWorkerCount() {
  final processors = Platform.numberOfProcessors;
  return math.min(8, math.max(2, processors ~/ 2));
}

int _defaultMetadataWorkerCount() {
  final processors = Platform.numberOfProcessors;
  return math.min(64, math.max(16, processors * 4));
}

String _estimatedEta(ScanProgress progress) {
  final percent = _estimatedProgressPercent(progress);
  if (percent >= 100) {
    return '0s';
  }
  if (percent <= 0) {
    return 'calculating';
  }
  final elapsed = DateTime.now().toUtc().difference(progress.startedAtUtc);
  final remainingSeconds = (elapsed.inSeconds * (100 - percent) / percent)
      .round();
  if (remainingSeconds <= 0) {
    return 'calculating';
  }
  if (remainingSeconds < 60) {
    return '${remainingSeconds}s';
  }
  final minutes = remainingSeconds ~/ 60;
  final seconds = remainingSeconds % 60;
  return '${minutes}m ${seconds}s';
}

String _plural(int count, String label) =>
    '$count $label${count == 1 ? '' : 's'}';

SessionFileStatus _scanStatus(String? value) {
  for (final status in SessionFileStatus.values) {
    if (status.wireName == value) {
      return status;
    }
  }
  return SessionFileStatus.available;
}

SessionSourceState _sourceState(String? value) {
  for (final state in SessionSourceState.values) {
    if (state.wireName == value) {
      return state;
    }
  }
  return SessionSourceState.active;
}

DateTime? _dateTime(String? value) =>
    value == null ? null : DateTime.tryParse(value)?.toUtc();

String _sourceStatusId(String sourcePath) =>
    'source-status:${p.normalize(sourcePath).toLowerCase()}';

String _sourceTypeLabel(String sourcePath) {
  if (sourcePath.startsWith(r'\\wsl') || sourcePath.contains('/home/')) {
    return 'wsl';
  }
  return 'windows';
}

List<String> _decodeMembership(String? encoded) {
  if (encoded == null || encoded.isEmpty) {
    return const [];
  }
  return encoded
      .split('|')
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
}

String _rowStatus(Row row) {
  final scanStatus = row['scan_status'] as String? ?? 'available';
  final parseStatus = row['parse_status'] as String? ?? 'available';
  if (parseStatus != 'available') {
    return parseStatus;
  }
  return scanStatus;
}

ConversationAuthor _messageAuthor(String? value) {
  return switch (value) {
    'user' => ConversationAuthor.user,
    'assistant' => ConversationAuthor.assistant,
    'reasoning' => ConversationAuthor.reasoning,
    'system' => ConversationAuthor.system,
    _ => ConversationAuthor.tool,
  };
}
