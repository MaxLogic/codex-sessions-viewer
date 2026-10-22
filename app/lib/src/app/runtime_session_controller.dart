import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart' show sqlite3, OpenMode;

import '../config/app_settings.dart';
import '../config/default_session_folders.dart';
import '../database/collector_versions.dart';
import '../database/database_connection.dart';
import '../database/database_maintenance.dart';
import '../database/project_tag_state.dart';
import '../database/session_list_query.dart';
import '../logging/structured_logger.dart';
import '../pricing/pricing_repository.dart';
import '../platform/app_locations.dart';
import '../scanner/scan_batching.dart';
import '../scanner/collector_process.dart';
import '../scanner/scan_types.dart';
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

/// A snapshot or a journal delta; omitted changed IDs are tombstones or rows
/// that no longer match the cached list's availability predicate.
class ExternalSessionRows {
  const ExternalSessionRows({
    required this.revision,
    required this.rows,
    this.reset = false,
    this.changedIds = const {},
  });
  final int? revision;
  final List<SessionRowViewModel> rows;
  final bool reset;
  final Set<String> changedIds;

  List<SessionRowViewModel> merge(List<SessionRowViewModel> previous) {
    if (reset) return rows;
    if (changedIds.isEmpty) return previous;
    final replacements = {for (final row in rows) row.id: row};
    return [
      for (final row in previous)
        if (!changedIds.contains(row.id)) row else ?replacements.remove(row.id),
      ...replacements.values,
    ];
  }
}

class RuntimeSessionController implements ProjectsRepository {
  RuntimeSessionController({
    required this.settingsFile,
    required this.databaseFile,
    this.scanBatchingPolicy = defaultScanBatchingPolicy,
    this.wslProjectResolver = const ProcessWslProjectResolver(),
    this.parserWorkerCountOverride,
    this.writerCoordinator,
    this.claudeProjectRoots,
    this.collectorExecutable,
    this.collectorLeaseTimeout = CollectorProcess.defaultLeaseTimeout,
  }) : assert(
         parserWorkerCountOverride == null || parserWorkerCountOverride > 0,
       );

  /// Claude Code projects folders a refresh collects when
  /// [claudeProjectRoots] is null. Tests replace it so they never read the
  /// developer's own transcripts.
  static List<String> Function() defaultClaudeProjectRoots =
      _existingDefaultClaudeProjectRoots;

  final File settingsFile;
  final File databaseFile;
  final ScanBatchingPolicy scanBatchingPolicy;
  final WslProjectResolver wslProjectResolver;
  final int? parserWorkerCountOverride;
  final DatabaseMaintenanceCoordinator? writerCoordinator;

  /// Claude Code projects folders to collect; empty skips Claude.
  final List<String>? claudeProjectRoots;

  /// The collector executable; null uses [CollectorProcess]'s default.
  final String? collectorExecutable;
  final Duration collectorLeaseTimeout;
  SendPort? _backgroundWriterPort;

  List<String> get _claudeRoots =>
      claudeProjectRoots ?? defaultClaudeProjectRoots();

  CollectorProcess _collector() => CollectorProcess(
    executable: collectorExecutable,
    leaseTimeout: collectorLeaseTimeout,
  );

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
      controller: RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
        scanBatchingPolicy: scanBatchingPolicy,
        writerCoordinator: writerCoordinator,
        parserWorkerCountOverride: parserWorkerCountOverride,
        claudeProjectRoots: _claudeRoots,
        collectorExecutable: collectorExecutable,
        collectorLeaseTimeout: collectorLeaseTimeout,
      ),
      onProgress: onProgress,
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
          projectionVersion: collectorCodexParserVersion,
        );
      } finally {
        db.close();
      }
    });
  }

  /// Reads the stored rows. The collector cleans placeholders and assigns
  /// projects during scans; loading never writes parsed session state.
  Future<SessionsRefreshResult> loadCachedRows() {
    return Profiling.spanAsync('scan.runtime.load_cached_rows', () async {
      final db = _openReader(databaseFile.path);
      try {
        final revision = _journalRevision(db);
        final rows = _loadRowsProfiled(db);
        return SessionsRefreshResult(
          rows: rows,
          statusMessage: rows.isEmpty
              ? ''
              : 'Loaded ${rows.length} of ${rows.length} sessions from the previous scan.',
          journalRevision: revision,
        );
      } finally {
        db.close();
      }
    });
  }

  /// Read collector commits without metadata repair, scanning, or another writer.
  Future<SessionsRefreshResult> loadExternalRows() async {
    final snapshot = await loadExternalRowChanges();
    return SessionsRefreshResult(rows: snapshot.rows, statusMessage: '');
  }

  Future<ExternalSessionRows> loadExternalRowChanges({int? afterRevision}) {
    final path = databaseFile.path;
    return Isolate.run(() {
      final db = _openReader(path);
      try {
        db.execute('begin');
        final revision = _journalRevision(db);
        if (afterRevision == null ||
            revision == null ||
            revision < afterRevision) {
          return ExternalSessionRows(
            revision: revision,
            rows: _loadRowsProfiled(db),
            reset: true,
          );
        }
        if (revision == afterRevision) {
          return ExternalSessionRows(revision: revision, rows: const []);
        }
        final ids = db
            .select(
              'select session_id from session_changes where revision > ?',
              [afterRevision],
            )
            .map((row) => row['session_id'] as String)
            .toSet();
        final rows = <SessionRowViewModel>[];
        final orderedIds = ids.toList(growable: false);
        for (var offset = 0; offset < orderedIds.length; offset += 400) {
          rows.addAll(
            _loadRows(
              db,
              sessionIds: orderedIds
                  .skip(offset)
                  .take(400)
                  .toList(growable: false),
            ),
          );
        }
        return ExternalSessionRows(
          revision: revision,
          rows: rows,
          changedIds: ids,
        );
      } finally {
        // Closing a read transaction releases its snapshot without writes.
        db.close();
      }
    });
  }

  Future<SessionsRefreshResult> loadCachedRowsInBackground({
    SessionsRefreshProgressCallback? onProgress,
    int batchSize = 250,
  }) =>
      _loadCachedRowsInBackground(onProgress: onProgress, batchSize: batchSize);

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
                  journalRevision: message.journalRevision,
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
    String? collectorExecutable,
  }) async {
    final db = openFileBackedDatabase(databaseFile);
    late String path;
    late String harness;
    try {
      final rows = db.select(
        'select source_file_path, harness from sessions where id = ?',
        [sessionId],
      );
      if (rows.isEmpty) return null;
      path = rows.single['source_file_path'] as String? ?? '';
      harness = rows.single['harness'] as String? ?? 'codex';
    } finally {
      db.close();
    }
    if (path.isEmpty || !File(path).existsSync()) return null;
    await CollectorProcess(executable: collectorExecutable).ingest(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
      sourcePath: path,
      harness: harness,
    );
    return _loadSessionDetailOnWorker(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
      sessionId: sessionId,
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
          parserWorkerCountOverride: parserWorkerCountOverride,
          claudeProjectRoots: _claudeRoots,
          collectorExecutable: collectorExecutable,
          collectorLeaseTimeout: collectorLeaseTimeout,
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
        projectionVersion: collectorCodexParserVersion,
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
            projectionVersion: collectorCodexParserVersion,
            pricing: pricing,
          );
        case ResetSessionProject():
          store.resetSessionProject(sessionId);
        case RemoveFolderRule(:final folder):
          store.removeFolderRule(
            folder: folder,
            projectionVersion: collectorCodexParserVersion,
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
        collectorCodexParserVersion,
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
        var fullRowSnapshotCount = 0;
        var lastSnapshotCommitted = 0;
        final activeScanRunId = await _writeScan(() async => _startScanRun(db));
        scanRunId = activeScanRunId;
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
                'collector_process': true,
                'parser_workers':
                    parserWorkerCountOverride ?? _defaultParserWorkerCount(),
              },
            ),
          ),
        );
        final collector = _collector();
        final result = await Profiling.spanAsync(
          'scan.runtime.collector',
          () => collector.scan(
            settingsFile: settingsFile,
            databaseFile: databaseFile,
            cancellation: cancellationToken,
            claudeRoots: _claudeRoots,
            // An injected resolver supplies WSL names after the scan.
            resolveWslProjects: wslProjectResolver is ProcessWslProjectResolver,
            parserWorkers: parserWorkerCountOverride,
            flushSessions: scanBatchingPolicy.parsedSessionFlushBatchSize,
            flushBytes: scanBatchingPolicy.parsedSessionFlushSourceBytes,
            write: (work) => Profiling.spanAsync(
              'scan.runtime.collector_write',
              () => _writeScan(work),
            ),
            onProgress: (progress, committed) {
              latestProgress = progress;
              final emitRows =
                  committed > lastSnapshotCommitted &&
                  (committed - lastSnapshotCommitted >=
                          scanBatchingPolicy.fullRowSnapshotBatchSize ||
                      progress.finishedAtUtc != null);
              if (emitRows) {
                fullRowSnapshotCount++;
                lastSnapshotCommitted = committed;
              }
              onProgress?.call(
                SessionsRefreshProgress(
                  statusMessage: _progressStatusMessage(progress),
                  rows: emitRows
                      ? _loadRowsProfiled(db, pricing: pricing)
                      : null,
                ),
              );
            },
          ),
        );
        // Alternate resolvers are explicit dependencies (for example an
        // embedded host without wsl.exe). The collector still owns persistence.
        if (AppLocations.currentPlatform == AppHostPlatform.windows &&
            wslProjectResolver is! ProcessWslProjectResolver) {
          final candidates = db.select(
            "select session_id, source_file_path, working_directory_display from sessions where source_type = 'wsl' and harness = 'codex'",
          );
          final hints = await wslProjectResolver.resolveProjectNames(
            candidates
                .map((row) => row['working_directory_display'] as String? ?? '')
                .where((path) => path.isNotEmpty)
                .toSet(),
          );
          await _writeScan(
            () => collector.applyProjectHints(databaseFile, [
              for (final row in candidates)
                {
                  'session_id': row['session_id'],
                  'source_path': row['source_file_path'],
                },
            ], hints),
          );
        }
        await _writeScan(
          () async => _updateScanRun(
            db,
            activeScanRunId,
            result.progress,
            status:
                (result.cancelled || cancellationToken.isCancellationRequested)
                ? _ScanRunStatus.cancelled
                : _ScanRunStatus.succeeded,
          ),
        );
        onProgress?.call(
          const SessionsRefreshProgress(statusMessage: 'Finalizing scan...'),
        );
        if (collector.cacheRepair case final repair?) {
          await _writeScan(() => _logCacheRepair(activeLogger, repair));
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
                  'collector': true,
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
          persistenceFlushCount: collector.persistenceFlushCount,
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
      // `-e` runs sh directly; without it the default shell reparses the
      // script and nothing resolves (T-171). Scans use the collector's copy.
      process = await Process.start('wsl.exe', [
        '-e',
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
      parserWorkerCountOverride: request.parserWorkerCountOverride,
      claudeProjectRoots: request.claudeProjectRoots,
      collectorExecutable: request.collectorExecutable,
      collectorLeaseTimeout: request.collectorLeaseTimeout,
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
    final db = _openReader(request.databaseFilePath);
    try {
      // Read before the rows: a commit after this point is replayed from
      // the journal, so rows are never loaded twice at startup.
      final revision = _journalRevision(db);
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
      request.sendPort.send(_BackgroundCachedRowsDone(revision));
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
    required this.parserWorkerCountOverride,
    required this.claudeProjectRoots,
    required this.collectorExecutable,
    required this.collectorLeaseTimeout,
  });

  final String settingsFilePath;
  final String databaseFilePath;
  final SendPort sendPort;
  final int parsedSessionFlushBatchSize;
  final int parsedSessionFlushSourceBytes;
  final int fullRowSnapshotBatchSize;
  final bool coordinateWrites;
  final bool emitCachedRowsAtScanStart;
  final int? parserWorkerCountOverride;
  final List<String> claudeProjectRoots;
  final String? collectorExecutable;
  final Duration collectorLeaseTimeout;
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
  const _BackgroundCachedRowsDone(this.journalRevision);

  final int? journalRevision;
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
    required RuntimeSessionController controller,
    SessionsRefreshProgressCallback? onProgress,
  }) {
    final cancellationHandle = _BackgroundScanCancellationHandle();
    Future<SessionsRefreshResult> work() => controller._refreshInBackground(
      onProgress: onProgress,
      cancellationHandle: cancellationHandle,
    );
    final result = controller.writerCoordinator?.runScan(work) ?? work();
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

List<SessionRowViewModel> _loadRows(
  Database db, {
  bool includeMessages = false,
  String? sessionId,
  List<String>? sessionIds,
  int? limit,
  int offset = 0,
  UsagePricingCatalog pricing = const UsagePricingCatalog({}),
}) {
  final query = sessionListQuery(
    sessionId: sessionId,
    sessionIds: sessionIds,
    limit: limit,
    offset: offset,
  );
  final rows = db.select(query.sql, query.parameters);
  final loadedSessionIds = [for (final row in rows) row['id'] as String];
  final tagsBySessionId = _loadTagsBySessionId(db, loadedSessionIds);
  final persistedCosts = UsageSummaryRepository(db).loadPersistedSessionCosts(
    loadedSessionIds,
    projectionVersion: collectorCodexParserVersion,
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
    harness: row['harness'] as String? ?? 'codex',
    threadName: row['thread_name'] as String? ?? '',
    threadSource: row['thread_source'] as String? ?? '',
    parentThreadId: row['parent_thread_id'] as String? ?? '',
    forkedFromId: row['forked_from_id'] as String? ?? '',
    t3ParentThreadId: row['t3_parent_thread_id'] as String? ?? '',
    t3ParentSessionId: row['t3_parent_session_id'] as String? ?? '',
    t3Relationship: row['t3_relationship'] as String? ?? '',
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
    platform: switch (sourceType) {
      'wsl' => SessionRowPlatform.wsl,
      'macos' => SessionRowPlatform.macos,
      'linux' => SessionRowPlatform.linux,
      _ => SessionRowPlatform.windows,
    },
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

/// Logs the collector's report of the legacy session cache repair, and each
/// old repair backup the collector deleted after the retention period.
Future<void> _logCacheRepair(
  StructuredLogger logger,
  Map<String, dynamic> repair,
) async {
  final status = repair['status'] as String? ?? 'postponed';
  final reason = repair['reason_code'] as String? ?? '';
  final postponed = status == 'postponed';
  final categories = repair['categories'] as Map<String, dynamic>? ?? const {};
  for (final pruned in repair['pruned_backups'] as List? ?? const []) {
    if (pruned case {'path': final String path, 'bytes': final int bytes}) {
      await logger.writeBestEffort(
        LogEntryDraft(
          level: LogLevel.info,
          category: LogCategory.database,
          message: 'Deleted an old database backup.',
          details: {'path': path, 'bytes': bytes},
        ),
      );
    }
  }
  for (final path in repair['prune_failures'] as List? ?? const []) {
    await logger.writeBestEffort(
      LogEntryDraft(
        level: LogLevel.warning,
        category: LogCategory.database,
        message:
            'An old database backup could not be deleted; it may be open in another program.',
        details: {'path': '$path'},
      ),
    );
  }
  return logger.writeBestEffort(
    LogEntryDraft(
      level: postponed && reason != 'cancelled'
          ? LogLevel.warning
          : LogLevel.info,
      category: LogCategory.database,
      message: postponed
          ? 'Session cache repair postponed.'
          : 'Session cache repair checked.',
      details: {
        'status': status,
        'reason_code': reason,
        'deleted_rows': repair['deleted_rows'] ?? 0,
        for (final entry in categories.entries)
          'category_${entry.key}': entry.value,
        if (repair['backup_file'] case final String backup)
          'backup_file': backup,
      },
    ),
  );
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

/// A read-only connection that waits for writers like the viewer does.
Database _openReader(String path) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    db.execute('pragma busy_timeout = $defaultSqliteBusyTimeoutMs');
    return db;
  } on Object {
    db.close();
    rethrow;
  }
}

/// The session change journal's revision, or null before schema 21.
int? _journalRevision(Database db) {
  final exists = db
      .select("select 1 from sqlite_schema where name = 'session_change_state'")
      .isNotEmpty;
  if (!exists) return null;
  return db
          .select('select revision from session_change_state where id = 1')
          .single['revision']
      as int;
}

List<String> _existingDefaultClaudeProjectRoots() {
  final root = DefaultSessionFolders.current().claudeProjectsRoot;
  if (root.isEmpty) return const [];
  return Directory(root).existsSync() ? [root] : const [];
}

int _defaultParserWorkerCount() {
  final processors = Platform.numberOfProcessors;
  if (processors <= 2) {
    return 1;
  }
  return math.min(8, processors - 1);
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

DateTime? _dateTime(String? value) =>
    value == null ? null : DateTime.tryParse(value)?.toUtc();

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
