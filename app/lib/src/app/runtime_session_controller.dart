import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../config/app_settings.dart';
import '../database/database_connection.dart';
import '../logging/structured_logger.dart';
import '../parser/codex_session_parser.dart';
import '../path_mapping/path_mapper.dart';
import '../pricing/pricing_repository.dart';
import '../scanner/scan_batching.dart';
import '../scanner/session_scanner.dart';
import '../search/session_search.dart';
import '../usage/usage_summary.dart';
import '../ui/models/conversation_message_view_model.dart';
import '../ui/screens/sessions_screen.dart';
import '../utils/injected_context_filter.dart';
import '../utils/profiling.dart';

class RuntimeSessionController {
  RuntimeSessionController({
    required this.settingsFile,
    required this.databaseFile,
    this.scanBatchingPolicy = defaultScanBatchingPolicy,
    this.wslProjectResolver = const ProcessWslProjectResolver(),
  });

  final File settingsFile;
  final File databaseFile;
  final ScanBatchingPolicy scanBatchingPolicy;
  final WslProjectResolver wslProjectResolver;

  CancellableSessionScanOperation startRefreshOperation({
    SessionsRefreshProgressCallback? onProgress,
  }) {
    final cancellation = ScanCancellationController();
    final result = _refresh(
      onProgress: onProgress,
      cancellationToken: cancellation.token,
    );
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
    );
  }

  Future<SessionsRefreshResult> loadCachedRows() {
    return Profiling.spanAsync('scan.runtime.load_cached_rows', () async {
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
    });
  }

  Future<SessionsRefreshResult> loadCachedRowsInBackground({
    SessionsRefreshProgressCallback? onProgress,
    int batchSize = 250,
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

        messageSubscription = messages.listen((message) {
          if (message is _BackgroundRefreshProgress) {
            onProgress?.call(message.progress);
            return;
          }
          if (message is _BackgroundRefreshDone) {
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
      final settings = await SettingsRepository(settingsFile).loadOrCreate();
      final db = openFileBackedDatabase(databaseFile);
      try {
        _cleanSessionMetadataPlaceholders(db);
        await _backfillAutomaticProjects(
          db,
          wslProjects: _WslProjectResolutionCache(wslProjectResolver),
        );
        final pricing = PricingRepository(db).loadCached(settings.pricing);
        final rows = _loadRowsProfiled(
          db,
          sessionId: sessionId,
          includeMessages: true,
          pricing: pricing,
        );
        if (rows.isEmpty) {
          return null;
        }
        return rows.single;
      } finally {
        db.close();
      }
    });
  }

  Future<SessionsRefreshResult> refreshInBackground({
    SessionsRefreshProgressCallback? onProgress,
  }) {
    return startRefreshInBackgroundOperation(onProgress: onProgress).result;
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
          fullRowSnapshotBatchSize: scanBatchingPolicy.fullRowSnapshotBatchSize,
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

      messageSubscription = messages.listen((message) {
        if (message is _BackgroundRefreshProgress) {
          onProgress?.call(message.progress);
          return;
        }
        if (message is _BackgroundRefreshControl) {
          cancellationHandle.attach(message.cancelPort);
          return;
        }
        if (message is _BackgroundRefreshDone) {
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

  Future<SessionsRefreshResult> _refresh({
    SessionsRefreshProgressCallback? onProgress,
    required ScanCancellationToken cancellationToken,
  }) {
    return Profiling.spanAsync('scan.runtime.refresh', () async {
      final settings = await SettingsRepository(settingsFile).loadOrCreate();
      final db = openFileBackedDatabase(databaseFile);
      final logger = StructuredLogger(db: db, settings: settings.logging);
      final pricing = PricingRepository(db).loadCached(settings.pricing);
      int? scanRunId;
      var latestProgress = ScanProgress(startedAtUtc: DateTime.now().toUtc());
      final pendingParsedSessions = <ScannedSessionFile>[];
      var persistenceFlushCount = 0;
      var fullRowSnapshotCount = 0;
      var lastFullRowSnapshotParsedCount = 0;
      var persistenceFlushQueue = Future<void>.value();
      final projectResolutionCache = _WslProjectResolutionCache(
        wslProjectResolver,
      );
      try {
        _cleanSessionMetadataPlaceholders(db);
        scanRunId = _startScanRun(db);
        final activeScanRunId = scanRunId;

        Future<void> persistParsedBatch(List<ScannedSessionFile> batch) async {
          if (batch.isEmpty) {
            return;
          }
          final currentFlush = persistenceFlushQueue.then((_) {
            return Profiling.spanAsync('scan.runtime.persist_flush', () {
              return _persistParsedSessions(
                db,
                batch,
                wslProjects: projectResolutionCache,
                resolveWslProjects: false,
              );
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

        final cachedRows = _loadRowsProfiled(db, pricing: pricing);
        if (onProgress != null && cachedRows.isNotEmpty) {
          onProgress(
            SessionsRefreshProgress(
              rows: cachedRows,
              statusMessage:
                  'Loaded ${cachedRows.length} of ${cachedRows.length} sessions from the previous scan. Scanning started.',
            ),
          );
        }

        await logger.write(
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
        );
        final mapper = CodexPathMapper(
          wslDistro: settings.wsl.distro,
          wslLinuxHome: settings.wsl.linuxHome,
          wslUncRoot: settings.wsl.linuxRootUnc,
        );
        final parserWorkerCount = _defaultParserWorkerCount();
        final directoryWorkerCount = _defaultDirectoryWorkerCount();
        final metadataWorkerCount = _defaultMetadataWorkerCount();
        final scanner = SessionScanner(
          parser: CodexSessionParser(
            maxToolOutputPreviewChars:
                settings.toolOutput.maxToolOutputPreviewChars,
          ),
          pathMapper: mapper,
          maxConcurrentParses: parserWorkerCount,
          maxConcurrentDirectoryScans: directoryWorkerCount,
          maxConcurrentMetadataChecks: metadataWorkerCount,
          onProgress: onProgress == null
              ? null
              : (progress) {
                  latestProgress = progress;
                  _updateScanRun(
                    db,
                    activeScanRunId,
                    progress,
                    status: _ScanRunStatus.running,
                  );
                  onProgress(
                    SessionsRefreshProgress(
                      statusMessage: _progressStatusMessage(progress),
                    ),
                  );
                },
          onSessionParsed: onProgress == null
              ? null
              : (session, progress) async {
                  pendingParsedSessions.add(session);
                  if (pendingParsedSessions.length >=
                      scanBatchingPolicy.parsedSessionFlushBatchSize) {
                    await flushParsedSessions(progress);
                  }
                },
        );
        final result = await Profiling.spanAsync(
          'scan.runtime.scanner_scan',
          () {
            return scanner.scan(
              SessionScanRequest(
                windowsRoot: _sessionScanRoot(settings.paths.windowsCodexPath),
                wslRoot: _sessionScanRoot(settings.paths.wslCodexUncPath),
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
            beforeFullRowSnapshot: onProgress == null
                ? null
                : () => Profiling.spanAsync(
                    'scan.runtime.apply_resolved_projects',
                    () => _applyResolvedProjectsForParsedSessions(
                      db,
                      result.sessions,
                      wslProjects: projectResolutionCache,
                    ),
                  ),
          );
        });
        await Profiling.spanAsync('scan.runtime.persist_scan', () {
          return _persistScan(
            db,
            result,
            scanRunId: activeScanRunId,
            persistSessions: onProgress == null,
            wslProjects: projectResolutionCache,
          );
        });
        final rows = Profiling.spanSync(
          'scan.runtime.final_load_rows',
          () => _loadRowsProfiled(db, pricing: pricing),
        );
        await Profiling.spanAsync('scan.runtime.write_finish_log', () {
          return logger.write(
            LogEntryDraft(
              level: LogLevel.info,
              category: LogCategory.scanner,
              message: result.cancelled
                  ? 'Session scan cancelled.'
                  : 'Session scan finished.',
              details: {
                ..._progressLogDetails(result.progress),
                'cancelled': result.cancelled,
                'visible_sessions': rows.length,
                'directory_workers': directoryWorkerCount,
                'metadata_workers': metadataWorkerCount,
                'parser_workers': parserWorkerCount,
              },
            ),
          );
        });
        return SessionsRefreshResult(
          rows: rows,
          statusMessage: _statusMessage(
            result,
            visibleSessionCount: rows.length,
          ),
          cancelled: result.cancelled,
          persistenceFlushCount: persistenceFlushCount,
          fullRowSnapshotCount: fullRowSnapshotCount,
        );
      } on Object catch (error) {
        final progress = latestProgress.finish();
        if (scanRunId != null) {
          _updateScanRun(
            db,
            scanRunId,
            progress,
            status: _ScanRunStatus.failed,
          );
        }
        await logger.write(
          LogEntryDraft(
            level: LogLevel.error,
            category: LogCategory.scanner,
            message: 'Session scan failed.',
            details: {
              ..._progressLogDetails(progress),
              'error_type': error.runtimeType.toString(),
            },
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

Future<void> _backgroundRefreshEntry(_BackgroundRefreshRequest request) async {
  final cancelPort = ReceivePort();
  StreamSubscription<Object?>? cancelSubscription;
  try {
    request.sendPort.send(_BackgroundRefreshControl(cancelPort.sendPort));
    final operation =
        RuntimeSessionController(
          settingsFile: File(request.settingsFilePath),
          databaseFile: File(request.databaseFilePath),
          scanBatchingPolicy: ScanBatchingPolicy(
            parsedSessionFlushBatchSize: request.parsedSessionFlushBatchSize,
            fullRowSnapshotBatchSize: request.fullRowSnapshotBatchSize,
          ),
        ).startRefreshOperation(
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
      final rows = <SessionRowViewModel>[];
      var offset = 0;
      while (offset < total) {
        rows.addAll(
          _loadRowsProfiled(db, limit: request.batchSize, offset: offset),
        );
        offset = rows.length;
        request.sendPort.send(
          _BackgroundRefreshProgress(
            SessionsRefreshProgress(
              rows: List.unmodifiable(rows),
              statusMessage:
                  'Loaded ${rows.length} of $total sessions from the previous scan.',
            ),
          ),
        );
      }
      request.sendPort.send(
        _BackgroundRefreshDone(
          SessionsRefreshResult(
            rows: List.unmodifiable(rows),
            statusMessage: '',
          ),
        ),
      );
    } finally {
      db.close();
    }
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
    required this.fullRowSnapshotBatchSize,
  });

  final String settingsFilePath;
  final String databaseFilePath;
  final SendPort sendPort;
  final int parsedSessionFlushBatchSize;
  final int fullRowSnapshotBatchSize;
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

class _BackgroundRefreshProgress {
  const _BackgroundRefreshProgress(this.progress);

  final SessionsRefreshProgress progress;
}

class _BackgroundRefreshDone {
  const _BackgroundRefreshDone(this.result);

  final SessionsRefreshResult result;
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

class _BackgroundSessionScanOperation {
  static CancellableSessionScanOperation start({
    required File settingsFile,
    required File databaseFile,
    required ScanBatchingPolicy scanBatchingPolicy,
    SessionsRefreshProgressCallback? onProgress,
  }) {
    final cancellationHandle = _BackgroundScanCancellationHandle();
    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
      scanBatchingPolicy: scanBatchingPolicy,
    );
    final result = controller._refreshInBackground(
      onProgress: onProgress,
      cancellationHandle: cancellationHandle,
    );
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
  required _WslProjectResolutionCache wslProjects,
  bool resolveWslProjects = true,
}) async {
  final resolver = resolveWslProjects
      ? await _ProjectPathResolver.create(
          _projectPathCandidatesForSessions(sessions),
          wslProjects: wslProjects,
        )
      : _ProjectPathResolver();
  db.execute('begin immediate');
  try {
    final now = DateTime.now().toUtc().toIso8601String();
    for (final session in sessions) {
      _upsertParsedSession(db, session, now, resolver);
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
  required _WslProjectResolutionCache wslProjects,
}) async {
  final resolver = persistSessions
      ? await _ProjectPathResolver.create(
          _projectPathCandidatesForSessions(result.sessions),
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
      for (final session in result.sessions) {
        _upsertParsedSession(db, session, now, resolver!);
      }
    }
    final parsedSessionPaths = {
      for (final session in result.sessions) session.sourcePath,
    };
    final statusesToPersist = [
      for (final status in result.fileStatuses)
        if (!parsedSessionPaths.contains(status.sourcePath) &&
            status.status != SessionFileStatus.available)
          status,
    ];
    _upsertScanStatusesOnly(db, statusesToPersist, now);
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
  _ProjectPathResolver projectResolver,
) {
  final parsed = scannedSession.parsedSession;
  final sourceType = scannedSession.sourceType == SessionSourceType.windows
      ? SessionSearchSourceType.windows
      : SessionSearchSourceType.wsl;
  final stat = File(scannedSession.sourcePath).statSync();
  final hasErrors =
      parsed.messages.any((message) => message.hasError) ||
      parsed.toolCalls.any((tool) => tool.hasError);
  final autoProject = projectResolver.resolve(
    parsed.workingDirectoryDisplay,
    sourceType: scannedSession.sourceType,
  );
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
      threadName: parsed.threadName?.trim() ?? '',
      userMessages: _messagesForAuthor(parsed, CodexMessageAuthorType.user),
      assistantMessages: _messagesForAuthor(
        parsed,
        CodexMessageAuthorType.assistant,
      ),
      toolNames: parsed.toolCalls.map((tool) => tool.toolName).join(' '),
      toolOutput: parsed.toolCalls.map((tool) => tool.outputPreview).join('\n'),
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
      agent_nickname = ?,
      agent_role = ?,
      subagent_depth = ?,
      source_file_unc_path = ?,
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
      project_id = case when project_override = 1 then project_id else ? end,
      project_name_snapshot = case
        when project_override = 1 then project_name_snapshot
        else ?
      end,
      last_scanned_utc = ?,
      last_parsed_utc = ?
    where id = ?
    ''',
    [
      parsed.sessionId,
      parsed.threadName,
      parsed.threadSource,
      parsed.parentThreadId,
      parsed.agentNickname,
      parsed.agentRole,
      parsed.subagentDepth,
      scannedSession.mappedPath.sourceFileUncPath,
      parsed.workingDirectoryDisplay,
      parsed.workingDirectoryPlatform,
      parsed.workingDirectoryUnc,
      stat.size,
      stat.modified.toUtc().toIso8601String(),
      _readHash(scannedSession.sourcePath),
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
      autoProject == null
          ? null
          : _upsertAutoProject(db, autoProject.name, now),
      autoProject?.name,
      now,
      now,
      parsed.internalId,
    ],
  );
  if (autoProject != null) {
    _updateSearchProjectIfAutomatic(db, parsed.internalId, autoProject.name);
  }
  _replaceMessages(db, parsed, now);
  _replaceToolCalls(db, parsed);
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

void _upsertScanStatusesOnly(
  Database db,
  List<ScannedFileStatus> statuses,
  String now,
) {
  if (statuses.isEmpty) {
    return;
  }

  db.execute('''
    create temp table if not exists temp_scan_statuses (
      source_path text primary key,
      status text not null
    )
    ''');
  db.execute('delete from temp_scan_statuses');

  final insertStatus = db.prepare('''
    insert or replace into temp_scan_statuses (source_path, status)
    values (?, ?)
    ''');
  try {
    for (final status in statuses) {
      insertStatus.execute([status.sourcePath, status.status.wireName]);
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
      updated_at_utc = ?,
      last_scanned_utc = ?
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
    select t.source_path, t.status
    from temp_scan_statuses t
    where not exists (
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
      parse_status,
      created_at_utc,
      updated_at_utc,
      last_scanned_utc
    ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    on conflict(id) do update set
      scan_status = excluded.scan_status,
      updated_at_utc = excluded.updated_at_utc,
      last_scanned_utc = excluded.last_scanned_utc
    ''');
  try {
    for (final row in missingStatuses) {
      final sourcePath = row['source_path'] as String;
      final status = row['status'] as String;
      insertMissing.execute([
        _sourceStatusId(sourcePath),
        _sourceTypeLabel(sourcePath),
        sourcePath,
        sourcePath,
        sourcePath,
        status,
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
  final filters = [
    "s.parse_status = 'available'",
    "s.scan_status = 'available'",
    "coalesce(s.session_id, '') <> ''",
    if (sessionId != null) 's.id = ?',
  ];
  final limitClause = limit == null ? '' : 'limit ? offset ?';
  final args = <Object?>[?sessionId];
  if (limit != null) {
    args
      ..add(limit)
      ..add(offset);
  }
  final rows = db.select('''
    select
      s.id,
      s.session_id,
      s.thread_name,
      s.thread_source,
      s.parent_thread_id,
      s.agent_nickname,
      s.agent_role,
      s.subagent_depth,
      s.source_type,
      s.source_file_path,
      s.source_file_unc_path,
      s.display_path,
      s.platform_path,
      s.working_directory_display,
      s.working_directory_unc,
      s.started_at_utc,
      s.last_message_at_utc,
      nullif(trim(s.title), '') as row_title,
      s.title,
      s.summary,
      s.message_count,
      s.user_message_count,
      s.assistant_message_count,
      s.tool_call_count,
      s.input_tokens,
      s.output_tokens,
      s.cached_input_tokens,
      s.total_tokens,
      s.user_message_tokens,
      s.assistant_response_tokens,
      s.tool_call_tokens,
      s.model_primary,
      s.models_used,
      s.project_name_snapshot,
      s.scan_status,
      s.parse_status,
      s.is_pinned,
      s.is_archived,
      s.has_errors
    from sessions s
    where ${filters.join(' and ')}
    order by coalesce(s.last_message_at_utc, s.started_at_utc, s.updated_at_utc) desc,
             s.id asc
    $limitClause
    ''', args);
  final sessionIds = [for (final row in rows) row['id'] as String];
  final tagsBySessionId = _loadTagsBySessionId(db, sessionIds);
  return [
    for (final row in rows)
      _loadRow(
        db,
        row,
        includeMessages: includeMessages,
        pricing: pricing,
        tagsBySessionId: tagsBySessionId,
      ),
  ];
}

int _visibleRowCount(Database db) {
  final row = db.select('''
    select count(*) as count
    from sessions s
    where s.parse_status = 'available'
      and s.scan_status = 'available'
      and coalesce(s.session_id, '') <> ''
    ''').single;
  return row['count'] as int? ?? 0;
}

SessionRowViewModel _loadRow(
  Database db,
  Row row, {
  required bool includeMessages,
  required UsagePricingCatalog pricing,
  required Map<String, List<String>> tagsBySessionId,
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
  final estimate = estimateUsageCost(
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
    model: model,
    modelsUsed: _decodeMembership(row['models_used'] as String?),
    tags: tagsBySessionId[row['id'] as String] ?? const [],
    status: _rowStatus(row),
    isPinned: (row['is_pinned'] as int? ?? 0) == 1,
    isArchived: (row['is_archived'] as int? ?? 0) == 1,
    hasError: (row['has_errors'] as int? ?? 0) == 1,
    conversationMessages: includeMessages
        ? _loadMessages(db, row['id'] as String)
        : const [],
  );
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
  String sessionId,
) {
  final rows = db.select(
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
  );
  return [
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
  ];
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

void _cleanSessionMetadataPlaceholders(Database db) {
  db.execute('begin immediate');
  try {
    db.execute('''
      update sessions
      set title = null
      where lower(trim(coalesce(title, ''))) like '# agents.md%'
      ''');
    db.execute('''
      update sessions
      set summary = null
      where lower(trim(coalesce(summary, ''))) = 'auto'
      ''');
    db.execute('''
      update session_search
      set title = ''
      where lower(trim(coalesce(title, ''))) like '# agents.md%'
      ''');
    db.execute('''
      update session_search
      set summary = ''
      where lower(trim(coalesce(summary, ''))) = 'auto'
      ''');
    db.execute('commit');
  } on Object {
    db.execute('rollback');
    rethrow;
  }
}

void _updateSearchProjectIfAutomatic(
  Database db,
  String sessionId,
  String projectName,
) {
  final rows = db.select(
    'select rowid, project_override from sessions where id = ?',
    [sessionId],
  );
  if (rows.isEmpty || (rows.single['project_override'] as int? ?? 0) == 1) {
    return;
  }
  db.execute('update session_search set project_name = ? where rowid = ?', [
    projectName,
    rows.single['rowid'] as int,
  ]);
}

Future<void> _backfillAutomaticProjects(
  Database db, {
  required _WslProjectResolutionCache wslProjects,
}) async {
  final rows = db.select('''
    select id, source_type, working_directory_display
    from sessions
    where coalesce(project_override, 0) = 0
      and coalesce(trim(project_name_snapshot), '') = ''
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

Future<void> _applyResolvedProjectsForParsedSessions(
  Database db,
  Iterable<ScannedSessionFile> sessions, {
  required _WslProjectResolutionCache wslProjects,
}) async {
  final sessionList = sessions.toList(growable: false);
  if (sessionList.isEmpty) {
    return;
  }
  final resolver = await _ProjectPathResolver.create(
    _projectPathCandidatesForSessions(sessionList),
    wslProjects: wslProjects,
  );
  final resolvedRows = <({String sessionId, String projectName})>[];
  for (final session in sessionList) {
    final autoProject = resolver.resolve(
      session.parsedSession.workingDirectoryDisplay,
      sourceType: session.sourceType,
    );
    final projectName = autoProject?.name.trim() ?? '';
    if (projectName.isNotEmpty) {
      resolvedRows.add((
        sessionId: session.parsedSession.internalId,
        projectName: projectName,
      ));
    }
  }
  if (resolvedRows.isEmpty) {
    return;
  }
  _applyResolvedProjectRows(db, resolvedRows);
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
        set project_id = ?,
            project_name_snapshot = ?,
            updated_at_utc = ?
        where id = ?
          and coalesce(project_override, 0) = 0
        ''',
        [projectId, projectName, now, sessionId],
      );
      _updateSearchProjectIfAutomatic(db, sessionId, projectName);
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

String _messagesForAuthor(
  CodexParsedSession session,
  CodexMessageAuthorType author,
) => session.messages
    .where((message) => message.authorType == author)
    .map((message) => message.contentPlain)
    .join('\n');

String _statusMessage(
  SessionScanResult result, {
  required int visibleSessionCount,
}) {
  final visible = _plural(visibleSessionCount, 'session');
  final parsed = _plural(result.progress.filesParsed, 'new or changed session');
  if (result.cancelled) {
    return 'Scan cancelled. $visible visible. $parsed parsed before cancellation.';
  }
  if (result.errors.any(
    (error) => error.status == SessionFileStatus.pathUnreachable,
  )) {
    final paths = result.errors
        .where((error) => error.status == SessionFileStatus.pathUnreachable)
        .map((error) => error.sourcePath)
        .join('; ');
    return 'Scan finished. $visible visible. $parsed parsed. '
        'Session root is unreachable. Unreachable paths: $paths';
  }
  if (result.progress.filesFound == 0 && visibleSessionCount == 0) {
    return 'Scan finished. No supported files found.';
  }
  return 'Scan finished. $visible visible. $parsed parsed.';
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

String _sessionScanRoot(String rootPath) {
  final sessions = Directory(p.join(rootPath, 'sessions'));
  if (sessions.existsSync()) {
    return sessions.path;
  }
  return rootPath;
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

DateTime? _dateTime(String? value) =>
    value == null ? null : DateTime.tryParse(value)?.toUtc();

String _readHash(String path) {
  return sha256.convert(File(path).readAsBytesSync()).toString();
}

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
