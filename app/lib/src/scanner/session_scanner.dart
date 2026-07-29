import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import '../parser/codex_session_parser.dart';
import '../path_mapping/path_mapper.dart';
import '../utils/profiling.dart';

typedef SessionFileStatReader = Future<FileStat> Function(File file);
typedef SessionRootExists = Future<bool> Function(Directory directory);
typedef SessionSourceRootTypeReader =
    Future<FileSystemEntityType> Function(String path);
typedef ScanRetryDelay = Future<void> Function(Duration delay);
typedef SessionRootRetryPredicate = bool Function(String rootPath);
typedef SessionParserIsolateEntrypoint = void Function(Object? start);

const defaultWslRootRetryDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 15),
];

enum SessionFileStatus {
  available,
  missing,
  pathUnreachable,
  parseError,
  permissionDenied,
  unsupportedFormat,
  changedPendingParse,
}

enum SessionSourceState { active, codexArchived, missing }

extension SessionSourceStateName on SessionSourceState {
  String get wireName => switch (this) {
    SessionSourceState.active => 'active',
    SessionSourceState.codexArchived => 'codex_archived',
    SessionSourceState.missing => 'missing',
  };
}

class SessionScanRoot {
  const SessionScanRoot({
    required this.path,
    required this.sourceType,
    required this.sourceState,
    this.availabilityRootPath,
  });

  final String path;
  final SessionSourceType sourceType;
  final SessionSourceState sourceState;
  final String? availabilityRootPath;
}

extension SessionFileStatusName on SessionFileStatus {
  String get wireName => switch (this) {
    SessionFileStatus.available => 'available',
    SessionFileStatus.missing => 'missing',
    SessionFileStatus.pathUnreachable => 'path_unreachable',
    SessionFileStatus.parseError => 'parse_error',
    SessionFileStatus.permissionDenied => 'permission_denied',
    SessionFileStatus.unsupportedFormat => 'unsupported_format',
    SessionFileStatus.changedPendingParse => 'changed_pending_parse',
  };
}

class SessionScanner {
  SessionScanner({
    required this.parser,
    required this.pathMapper,
    this.maxConcurrentParses = 4,
    this.maxConcurrentDirectoryScans = 4,
    this.maxConcurrentMetadataChecks = 32,
    this.useParserIsolates = true,
    this.parserIsolateEntrypoint = _parserWorkerEntry,
    this.parserWorkerStartupTimeout = const Duration(seconds: 30),
    this.retainParsedSessions = true,
    this.onProgress,
    this.onSessionParsed,
    this.onParserPoolClosing,
    SessionFileStatReader? fileStatReader,
    SessionRootExists? rootExists,
    SessionSourceRootTypeReader? sourceRootTypeReader,
    ScanRetryDelay? retryDelay,
    SessionRootRetryPredicate? shouldRetryWslRoot,
    this.wslRootRetryDelays = defaultWslRootRetryDelays,
    this.progressEveryWorkItems = 100,
    this.cacheModifiedTolerance = const Duration(seconds: 2),
  }) : assert(maxConcurrentParses > 0),
       assert(maxConcurrentDirectoryScans > 0),
       assert(maxConcurrentMetadataChecks > 0),
       assert(parserWorkerStartupTimeout > Duration.zero),
       assert(retainParsedSessions || onSessionParsed != null),
       fileStatReader = fileStatReader ?? _defaultFileStatReader,
       rootExists = rootExists ?? _defaultRootExists,
       sourceRootTypeReader =
           sourceRootTypeReader ?? _defaultSourceRootTypeReader,
       retryDelay = retryDelay ?? Future<void>.delayed,
       shouldRetryWslRoot = shouldRetryWslRoot ?? _isWslUncPath,
       assert(!cacheModifiedTolerance.isNegative);

  final CodexSessionParser parser;
  final CodexPathMapper pathMapper;
  final int maxConcurrentParses;
  final int maxConcurrentDirectoryScans;
  final int maxConcurrentMetadataChecks;
  final bool useParserIsolates;
  final SessionParserIsolateEntrypoint parserIsolateEntrypoint;
  final Duration parserWorkerStartupTimeout;
  final bool retainParsedSessions;
  final void Function(ScanProgress progress)? onProgress;
  final Future<void> Function(
    ScannedSessionFile session,
    ScanProgress progress,
  )?
  onSessionParsed;
  final Future<void> Function()? onParserPoolClosing;
  final SessionFileStatReader fileStatReader;
  final SessionRootExists rootExists;
  final SessionSourceRootTypeReader sourceRootTypeReader;
  final ScanRetryDelay retryDelay;
  final SessionRootRetryPredicate shouldRetryWslRoot;
  final List<Duration> wslRootRetryDelays;
  final int progressEveryWorkItems;
  final Duration cacheModifiedTolerance;
  bool _isScanning = false;
  int _lastProgressWorkItems = 0;

  Future<SessionScanResult> scan(SessionScanRequest request) {
    return Profiling.spanAsync('scan.scanner.scan', () async {
      if (_isScanning) {
        throw const ScanAlreadyRunningException();
      }
      _isScanning = true;
      try {
        final progress = ScanProgress(startedAtUtc: DateTime.now().toUtc());
        _lastProgressWorkItems = 0;
        _emitProgress(progress, force: true);
        final sessions = <ScannedSessionFile>[];
        final errors = <ScanFileError>[];
        final fileStatuses = <ScannedFileStatus>[];
        final statusEvents = <ScannedFileStatus>[];
        final skippedFiles = <ScannedFileStatus>[];
        final candidates = <_ScanCandidate>[];
        final parsed = <_ParsedCandidate>[];
        final reachableRoots = <String>[];
        final failedRoots = <String>{};
        final forcedReparse = request.forceReparsePlan.apply(
          request.cachedSessions,
        );
        final cachedIndex = _CachedSessionIndex(request.cachedSessions);
        final cancellationToken = request.cancellationToken;
        final directoryQueue = _WorkQueue<_ScanDirectory>();
        final metadataQueue = _AsyncQueue<_ScanCandidate>();
        final parseQueue = _AsyncQueue<_ScanCandidate>();
        _ParserIsolatePool? parserPool;
        Future<void>? parserPoolCloseFuture;
        Future<void> closeParserPool() {
          final pool = parserPool;
          if (pool == null) {
            return Future.value();
          }
          return parserPoolCloseFuture ??= pool.close();
        }

        void stopQueues() {
          directoryQueue.cancel();
          metadataQueue.cancel();
          parseQueue.cancel();
          unawaited(closeParserPool());
        }

        final removeCancelListener = cancellationToken?._addListener(
          stopQueues,
        );
        parserPool = await Profiling.spanAsync(
          'scan.scanner.parser_pool.start',
          _createParserPool,
        );
        if (cancellationToken?.isCancellationRequested ?? false) {
          stopQueues();
        }

        try {
          await Profiling.spanAsync('scan.scanner.root_discovery', () async {
            if (cancellationToken?.isCancellationRequested ?? false) {
              return;
            }
            final availabilityByOwner = <String, bool>{};
            final reportedUnavailableOwners = <String>{};
            for (final root in request.effectiveRoots) {
              await _enqueueRoot(
                root: root,
                progress: progress,
                errors: errors,
                fileStatuses: fileStatuses,
                statusEvents: statusEvents,
                reachableRoots: reachableRoots,
                availabilityByOwner: availabilityByOwner,
                reportedUnavailableOwners: reportedUnavailableOwners,
                failedRoots: failedRoots,
                directoryQueue: directoryQueue,
                cancellationToken: cancellationToken,
              );
              if (cancellationToken?.isCancellationRequested ?? false) {
                return;
              }
            }
          });
          directoryQueue.closeWhenIdle();

          final directoryWorkers = [
            for (var i = 0; i < maxConcurrentDirectoryScans; i++)
              _directoryWorker(
                directoryQueue: directoryQueue,
                metadataQueue: metadataQueue,
                progress: progress,
                errors: errors,
                fileStatuses: fileStatuses,
                statusEvents: statusEvents,
                candidates: candidates,
                failedRoots: failedRoots,
                cancellationToken: cancellationToken,
              ),
          ];
          final metadataWorkers = [
            for (var i = 0; i < maxConcurrentMetadataChecks; i++)
              _metadataWorker(
                metadataQueue: metadataQueue,
                parseQueue: parseQueue,
                progress: progress,
                fileStatuses: fileStatuses,
                skippedFiles: skippedFiles,
                cachedIndex: cachedIndex,
                forcedReparse: forcedReparse,
                cancellationToken: cancellationToken,
              ),
          ];
          final parserWorkers = [
            for (var i = 0; i < maxConcurrentParses; i++)
              _parserWorker(
                parseQueue: parseQueue,
                progress: progress,
                parsed: parsed,
                fileStatuses: fileStatuses,
                statusEvents: statusEvents,
                parserPool: parserPool,
                cancellationToken: cancellationToken,
              ),
          ];

          await Future.wait(directoryWorkers);
          metadataQueue.close();
          await Future.wait(metadataWorkers);
          parseQueue.close();
          await Future.wait(parserWorkers);
        } finally {
          removeCancelListener?.call();
          await closeParserPool();
        }

        for (final parsedFile in parsed) {
          if (parsedFile.error == null) {
            sessions.add(parsedFile.session!);
          } else {
            errors.add(parsedFile.error!);
          }
        }
        final cancelled = cancellationToken?.isCancellationRequested ?? false;
        final ownerByRoot = {
          for (final root in request.effectiveRoots)
            _canonicalScanPath(root.path): _canonicalScanPath(
              root.availabilityRootPath ?? root.path,
            ),
        };
        final completeRoots = reachableRoots
            .where(
              (root) => !failedRoots.contains(
                ownerByRoot[_canonicalScanPath(root)] ??
                    _canonicalScanPath(root),
              ),
            )
            .toList(growable: false);
        final requestedOwners = {
          for (final root in request.effectiveRoots)
            _canonicalScanPath(root.availabilityRootPath ?? root.path),
        };
        final completeOwners = {
          for (final root in completeRoots)
            ownerByRoot[_canonicalScanPath(root)] ?? _canonicalScanPath(root),
        };
        final allConfiguredRootsReachable =
            !cancelled &&
            requestedOwners.isNotEmpty &&
            requestedOwners.every(completeOwners.contains);
        if (!cancelled && completeRoots.isNotEmpty) {
          Profiling.spanSync('scan.scanner.missing_cached', () {
            _recordMissingCachedSessions(
              request.cachedSessions,
              candidates,
              completeRoots,
              progress,
              errors,
              fileStatuses,
              statusEvents,
            );
          });
        }

        sessions.sort(_compareScannedSessions);
        errors.sort(_compareErrors);
        fileStatuses.sort(_compareStatuses);
        final finishedProgress = progress.finish(cancelled: cancelled);
        _emitProgress(finishedProgress, force: true);
        final result = SessionScanResult(
          progress: finishedProgress,
          cancelled: finishedProgress.cancelled,
          allConfiguredRootsReachable: allConfiguredRootsReachable,
          sessions: List.unmodifiable(sessions),
          errors: List.unmodifiable(errors),
          fileStatuses: List.unmodifiable(fileStatuses),
          statusEvents: List.unmodifiable(statusEvents),
          skippedFiles: List.unmodifiable(skippedFiles),
          cachedSessions: List.unmodifiable(request.cachedSessions),
        );
        if (finishedProgress.cancelled) {
          cancellationToken?._acknowledge();
        }
        return result;
      } finally {
        _isScanning = false;
      }
    });
  }

  Future<void> _enqueueRoot({
    required SessionScanRoot root,
    required ScanProgress progress,
    required List<ScanFileError> errors,
    required List<ScannedFileStatus> fileStatuses,
    required List<ScannedFileStatus> statusEvents,
    required List<String> reachableRoots,
    required Map<String, bool> availabilityByOwner,
    required Set<String> reportedUnavailableOwners,
    required Set<String> failedRoots,
    required _WorkQueue<_ScanDirectory> directoryQueue,
    required ScanCancellationToken? cancellationToken,
  }) async {
    if (cancellationToken?.isCancellationRequested ?? false) {
      return;
    }
    final rootPath = root.path;
    if (rootPath.isEmpty) {
      return;
    }
    final directory = Directory(rootPath);
    final availabilityRootPath = root.availabilityRootPath ?? rootPath;
    final availabilityRoot = Directory(availabilityRootPath);
    final availabilityKey = _canonicalScanPath(availabilityRootPath);

    void reportUnavailable({
      required String sourcePath,
      required SessionFileStatus status,
      required String message,
    }) {
      failedRoots.add(availabilityKey);
      if (!reportedUnavailableOwners.add(availabilityKey)) {
        return;
      }
      progress.filesFailed++;
      _emitProgress(progress);
      errors.add(
        ScanFileError(sourcePath: sourcePath, status: status, message: message),
      );
      final fileStatus = ScannedFileStatus(
        sourcePath: sourcePath,
        status: status,
        sourceState: root.sourceState,
      );
      fileStatuses.add(fileStatus);
      statusEvents.add(fileStatus);
    }

    Future<bool> ownerExists() async {
      try {
        return await rootExists(availabilityRoot);
      } on FileSystemException {
        return false;
      }
    }

    late bool reachable;
    if (availabilityByOwner.containsKey(availabilityKey)) {
      reachable = availabilityByOwner[availabilityKey]!;
    } else {
      final retryDelays =
          root.sourceType == SessionSourceType.wsl &&
              shouldRetryWslRoot(availabilityRootPath)
          ? wslRootRetryDelays
          : const <Duration>[];
      reachable = await ownerExists();
      for (final delay in retryDelays) {
        if (reachable ||
            (cancellationToken?.isCancellationRequested ?? false)) {
          break;
        }
        await _waitForRetry(delay, cancellationToken);
        if (cancellationToken?.isCancellationRequested ?? false) {
          return;
        }
        reachable = await ownerExists();
      }
      availabilityByOwner[availabilityKey] = reachable;
    }
    if (cancellationToken?.isCancellationRequested ?? false) {
      return;
    }
    if (!reachable) {
      reportUnavailable(
        sourcePath: availabilityRootPath,
        status: SessionFileStatus.pathUnreachable,
        message: 'Session root is unreachable.',
      );
      return;
    }
    if (availabilityRootPath != rootPath) {
      late FileSystemEntityType sourceRootType;
      try {
        sourceRootType = await sourceRootTypeReader(rootPath);
      } on FileSystemException catch (error) {
        if (cancellationToken?.isCancellationRequested ?? false) {
          return;
        }
        reportUnavailable(
          sourcePath: rootPath,
          status: _statusFromFileSystemError(error),
          message: error.message,
        );
        return;
      }
      if (cancellationToken?.isCancellationRequested ?? false) {
        return;
      }
      if (sourceRootType == FileSystemEntityType.notFound) {
        if (!await ownerExists()) {
          if (cancellationToken?.isCancellationRequested ?? false) {
            return;
          }
          reportUnavailable(
            sourcePath: availabilityRootPath,
            status: SessionFileStatus.pathUnreachable,
            message: 'Session root became unreachable during discovery.',
          );
          return;
        }
        if (cancellationToken?.isCancellationRequested ?? false) {
          return;
        }
        reachableRoots.add(rootPath);
        return;
      }
      if (sourceRootType != FileSystemEntityType.directory) {
        reportUnavailable(
          sourcePath: rootPath,
          status: SessionFileStatus.pathUnreachable,
          message: 'Session source root is not a directory.',
        );
        return;
      }
    }
    if (cancellationToken?.isCancellationRequested ?? false) {
      return;
    }
    reachableRoots.add(rootPath);
    if (cancellationToken?.isCancellationRequested ?? false) {
      return;
    }
    directoryQueue.add(
      _ScanDirectory(
        directory: directory,
        sourceRootPath: rootPath,
        availabilityRootPath: availabilityRootPath,
        sourceType: root.sourceType,
        sourceState: root.sourceState,
      ),
    );
  }

  Future<void> _waitForRetry(
    Duration delay,
    ScanCancellationToken? cancellationToken,
  ) async {
    if (cancellationToken == null) {
      await retryDelay(delay);
      return;
    }
    final cancelled = Completer<void>();
    final removeListener = cancellationToken._addListener(() {
      if (!cancelled.isCompleted) {
        cancelled.complete();
      }
    });
    try {
      await Future.any([retryDelay(delay), cancelled.future]);
    } finally {
      removeListener();
    }
  }

  Future<void> _directoryWorker({
    required _WorkQueue<_ScanDirectory> directoryQueue,
    required _AsyncQueue<_ScanCandidate> metadataQueue,
    required ScanProgress progress,
    required List<ScanFileError> errors,
    required List<ScannedFileStatus> fileStatuses,
    required List<ScannedFileStatus> statusEvents,
    required List<_ScanCandidate> candidates,
    required Set<String> failedRoots,
    required ScanCancellationToken? cancellationToken,
  }) async {
    while (true) {
      if (cancellationToken?.isCancellationRequested ?? false) {
        return;
      }
      final scanDirectory = await directoryQueue.take();
      if (scanDirectory == null) {
        return;
      }
      try {
        await _scanDirectory(
          scanDirectory: scanDirectory,
          directoryQueue: directoryQueue,
          metadataQueue: metadataQueue,
          progress: progress,
          errors: errors,
          fileStatuses: fileStatuses,
          statusEvents: statusEvents,
          candidates: candidates,
          failedRoots: failedRoots,
          cancellationToken: cancellationToken,
        );
      } finally {
        directoryQueue.completeItem();
      }
    }
  }

  Future<void> _scanDirectory({
    required _ScanDirectory scanDirectory,
    required _WorkQueue<_ScanDirectory> directoryQueue,
    required _AsyncQueue<_ScanCandidate> metadataQueue,
    required ScanProgress progress,
    required List<ScanFileError> errors,
    required List<ScannedFileStatus> fileStatuses,
    required List<ScannedFileStatus> statusEvents,
    required List<_ScanCandidate> candidates,
    required Set<String> failedRoots,
    required ScanCancellationToken? cancellationToken,
  }) {
    return Profiling.spanAsync('scan.scanner.directory', () async {
      final root = scanDirectory.directory;
      try {
        progress.directoriesScanned++;
        _emitProgress(progress);
        await for (final entity in root.list(followLinks: false)) {
          if (cancellationToken?.isCancellationRequested ?? false) {
            break;
          }
          if (entity is Directory) {
            try {
              directoryQueue.add(
                _ScanDirectory(
                  directory: entity,
                  sourceRootPath: scanDirectory.sourceRootPath,
                  availabilityRootPath: scanDirectory.availabilityRootPath,
                  sourceType: scanDirectory.sourceType,
                  sourceState: scanDirectory.sourceState,
                ),
              );
            } on StateError {
              if (cancellationToken?.isCancellationRequested ?? false) {
                break;
              }
              rethrow;
            }
            continue;
          }
          if (entity is! File) {
            continue;
          }
          if (!_isSupportedSessionFile(entity.path)) {
            progress.filesSkipped++;
            _emitProgress(progress);
            errors.add(
              ScanFileError(
                sourcePath: entity.path,
                status: SessionFileStatus.unsupportedFormat,
                message: 'Unsupported session file format.',
              ),
            );
            fileStatuses.add(
              ScannedFileStatus(
                sourcePath: entity.path,
                status: SessionFileStatus.unsupportedFormat,
                sourceState: scanDirectory.sourceState,
              ),
            );
            statusEvents.add(
              ScannedFileStatus(
                sourcePath: entity.path,
                status: SessionFileStatus.unsupportedFormat,
                sourceState: scanDirectory.sourceState,
              ),
            );
            continue;
          }
          progress.filesFound++;
          _emitProgress(progress);
          final candidate = _ScanCandidate(
            file: entity,
            sourceType: scanDirectory.sourceType,
            sourceState: scanDirectory.sourceState,
          );
          candidates.add(candidate);
          try {
            metadataQueue.add(candidate);
          } on StateError {
            if (cancellationToken?.isCancellationRequested ?? false) {
              break;
            }
            rethrow;
          }
        }
      } on FileSystemException catch (error) {
        failedRoots.add(_canonicalScanPath(scanDirectory.availabilityRootPath));
        progress.filesFailed++;
        _emitProgress(progress);
        errors.add(
          ScanFileError(
            sourcePath: root.path,
            status: _statusFromFileSystemError(error),
            message: error.message,
          ),
        );
        fileStatuses.add(
          ScannedFileStatus(
            sourcePath: root.path,
            status: _statusFromFileSystemError(error),
            sourceState: scanDirectory.sourceState,
          ),
        );
        statusEvents.add(
          ScannedFileStatus(
            sourcePath: root.path,
            status: _statusFromFileSystemError(error),
            sourceState: scanDirectory.sourceState,
          ),
        );
      }
    });
  }

  Future<void> _metadataWorker({
    required _AsyncQueue<_ScanCandidate> metadataQueue,
    required _AsyncQueue<_ScanCandidate> parseQueue,
    required ScanProgress progress,
    required List<ScannedFileStatus> fileStatuses,
    required List<ScannedFileStatus> skippedFiles,
    required _CachedSessionIndex cachedIndex,
    required ForceReparseSelection forcedReparse,
    required ScanCancellationToken? cancellationToken,
  }) async {
    while (true) {
      if (cancellationToken?.isCancellationRequested ?? false) {
        return;
      }
      final candidate = await metadataQueue.take();
      if (candidate == null) {
        return;
      }
      if (cancellationToken?.isCancellationRequested ?? false) {
        return;
      }
      final decision = await _parseDecision(
        candidate.file,
        cachedIndex,
        forcedReparse,
      );
      if (cancellationToken?.isCancellationRequested ?? false) {
        return;
      }
      if (!decision.shouldParse) {
        progress.filesSkipped++;
        _emitProgress(progress);
        final status = ScannedFileStatus(
          sourcePath: candidate.file.path,
          status: SessionFileStatus.available,
          sourceState: candidate.sourceState,
        );
        skippedFiles.add(status);
        fileStatuses.add(status);
        continue;
      }
      try {
        parseQueue.add(candidate);
      } on StateError {
        if (cancellationToken?.isCancellationRequested ?? false) {
          return;
        }
        rethrow;
      }
    }
  }

  Future<void> _parserWorker({
    required _AsyncQueue<_ScanCandidate> parseQueue,
    required ScanProgress progress,
    required List<_ParsedCandidate> parsed,
    required List<ScannedFileStatus> fileStatuses,
    required List<ScannedFileStatus> statusEvents,
    required _ParserIsolatePool? parserPool,
    required ScanCancellationToken? cancellationToken,
  }) async {
    while (true) {
      if (cancellationToken?.isCancellationRequested ?? false) {
        return;
      }
      final candidate = await parseQueue.take();
      if (candidate == null) {
        return;
      }
      if (cancellationToken?.isCancellationRequested ?? false) {
        return;
      }
      progress.sessionsChanged++;
      _emitProgress(progress);
      statusEvents.add(
        ScannedFileStatus(
          sourcePath: candidate.file.path,
          status: SessionFileStatus.changedPendingParse,
          sourceState: candidate.sourceState,
        ),
      );
      final _ParsedCandidate parsedFile;
      try {
        parsedFile = await _parseCandidate(
          candidate,
          progress,
          parserPool: parserPool,
        );
      } on StateError {
        if (cancellationToken?.isCancellationRequested ?? false) {
          return;
        }
        rethrow;
      }
      if (retainParsedSessions || parsedFile.error != null) {
        parsed.add(parsedFile);
      }
      if (parsedFile.error == null) {
        final status = ScannedFileStatus(
          sourcePath: parsedFile.session!.sourcePath,
          status: parsedFile.session!.status,
          sourceState: parsedFile.session!.sourceState,
        );
        fileStatuses.add(status);
        statusEvents.add(status);
      } else {
        final status = ScannedFileStatus(
          sourcePath: parsedFile.error!.sourcePath,
          status: parsedFile.error!.status,
          sourceState: candidate.sourceState,
        );
        fileStatuses.add(status);
        statusEvents.add(status);
      }
    }
  }

  Future<_ParsedCandidate> _parseCandidate(
    _ScanCandidate candidate,
    ScanProgress progress, {
    required _ParserIsolatePool? parserPool,
  }) {
    return Profiling.spanAsync('scan.scanner.parse_file', () async {
      final mappedPath = candidate.sourceType == SessionSourceType.windows
          ? pathMapper.mapWindowsPath(candidate.file.path)
          : pathMapper.mapWslUncPath(candidate.file.path);
      final parseResult = parserPool == null
          ? await parser.parseFile(candidate.file)
          : await parserPool.parseFile(candidate.file.path);
      if (!parseResult.isSuccess) {
        progress.filesFailed++;
        _emitProgress(progress);
        final error = parseResult.error;
        return _ParsedCandidate.error(
          ScanFileError(
            sourcePath: candidate.file.path,
            status: _statusFromParseError(error),
            message: _parseErrorMessage(error),
          ),
        );
      }
      progress.filesParsed++;
      final session = ScannedSessionFile.fromParseResult(
        sourcePath: candidate.file.path,
        sourceType: candidate.sourceType,
        sourceState: candidate.sourceState,
        mappedPath: mappedPath,
        parseResult: parseResult,
      );
      await onSessionParsed?.call(session, progress.snapshot());
      _emitProgress(progress);
      return _ParsedCandidate.session(session);
    });
  }

  void _recordMissingCachedSessions(
    List<CachedSessionSnapshot> cachedSessions,
    List<_ScanCandidate> candidates,
    List<String> reachableRoots,
    ScanProgress progress,
    List<ScanFileError> errors,
    List<ScannedFileStatus> fileStatuses,
    List<ScannedFileStatus> statusEvents,
  ) {
    if (cachedSessions.isEmpty) {
      return;
    }
    final foundPaths = candidates
        .map((candidate) => candidate.file.path)
        .map(_canonicalScanPath)
        .toSet();
    for (final cached in cachedSessions) {
      final cachedPathKeys = _snapshotPathKeys(cached);
      if (cachedPathKeys.any(foundPaths.contains)) {
        continue;
      }
      if (!cachedPathKeys.any(
        (cachedPath) =>
            reachableRoots.any((root) => _isPathUnderRoot(cachedPath, root)),
      )) {
        continue;
      }
      progress.sessionsMissing++;
      _emitProgress(progress);
      errors.add(
        ScanFileError(
          sourcePath: cached.sourcePath,
          status: SessionFileStatus.missing,
          message: 'Previously cached session file is missing.',
        ),
      );
      fileStatuses.add(
        ScannedFileStatus(
          sourcePath: cached.sourcePath,
          status: SessionFileStatus.missing,
          sourceState: SessionSourceState.missing,
        ),
      );
      statusEvents.add(
        ScannedFileStatus(
          sourcePath: cached.sourcePath,
          status: SessionFileStatus.missing,
          sourceState: SessionSourceState.missing,
        ),
      );
    }
  }

  Future<_ParseDecision> _parseDecision(
    File file,
    _CachedSessionIndex cachedSessions,
    ForceReparseSelection forcedReparse,
  ) {
    return Profiling.spanAsync('scan.scanner.parse_decision', () async {
      if (forcedReparse.shouldForceParse(file.path)) {
        return const _ParseDecision.parse();
      }
      final cached = cachedSessions.lookup(file.path);
      if (cached == null || !cached.hasCompleteInvalidationMetadata) {
        return const _ParseDecision.parse();
      }
      if (cached.status != SessionFileStatus.available) {
        return const _ParseDecision.parse();
      }
      if (cached.parserVersion != CodexSessionParser.currentVersion) {
        return const _ParseDecision.parse();
      }

      final FileStat stat;
      try {
        stat = await fileStatReader(file);
      } on Object {
        return const _ParseDecision.parse();
      }
      final currentSize = stat.size;
      final sizeChanged = currentSize != cached.sourceFileSize;
      if (sizeChanged) {
        return const _ParseDecision.parse();
      }
      if (!_isModifiedWithinTolerance(
        stat.modified.toUtc(),
        cached.sourceModifiedUtc!,
        cacheModifiedTolerance,
      )) {
        return const _ParseDecision.parse();
      }
      return const _ParseDecision.skip();
    });
  }

  Future<_ParserIsolatePool?> _createParserPool() async {
    if (!useParserIsolates || parser.runtimeType != CodexSessionParser) {
      return null;
    }
    final pool = _ParserIsolatePool(
      workerCount: maxConcurrentParses,
      maxToolOutputPreviewChars: parser.maxToolOutputPreviewChars,
      maxMessageContentChars: parser.maxMessageContentChars,
      isolateEntrypoint: parserIsolateEntrypoint,
      workerStartupTimeout: parserWorkerStartupTimeout,
      onClosing: onParserPoolClosing,
    );
    await pool.start();
    return pool;
  }

  void _emitProgress(ScanProgress progress, {bool force = false}) {
    if (onProgress == null) {
      return;
    }
    final workItems = progress.workItems;
    if (!force &&
        progressEveryWorkItems > 0 &&
        workItems - _lastProgressWorkItems < progressEveryWorkItems) {
      return;
    }
    _lastProgressWorkItems = workItems;
    onProgress?.call(progress.snapshot());
  }
}

Future<FileStat> _defaultFileStatReader(File file) => file.stat();
Future<bool> _defaultRootExists(Directory directory) => directory.exists();
Future<FileSystemEntityType> _defaultSourceRootTypeReader(String path) =>
    FileSystemEntity.type(path, followLinks: false);

bool _isWslUncPath(String rootPath) {
  final normalized = rootPath.replaceAll('/', r'\').toLowerCase();
  return normalized.startsWith(r'\\wsl.localhost\') ||
      normalized.startsWith(r'\\wsl$\');
}

class SessionScanRequest {
  const SessionScanRequest({
    this.roots = const [],
    this.windowsRoot,
    this.wslRoot,
    this.cachedSessions = const [],
    this.forceReparsePlan = const ForceReparsePlan.none(),
    this.cancellationToken,
  });

  final List<SessionScanRoot> roots;
  final String? windowsRoot;
  final String? wslRoot;
  final List<CachedSessionSnapshot> cachedSessions;
  final ForceReparsePlan forceReparsePlan;
  final ScanCancellationToken? cancellationToken;

  List<SessionScanRoot> get effectiveRoots {
    if (roots.isNotEmpty) {
      return roots;
    }
    return [
      if (windowsRoot != null && windowsRoot!.isNotEmpty)
        SessionScanRoot(
          path: windowsRoot!,
          sourceType: SessionSourceType.windows,
          sourceState: SessionSourceState.active,
        ),
      if (wslRoot != null && wslRoot!.isNotEmpty)
        SessionScanRoot(
          path: wslRoot!,
          sourceType: SessionSourceType.wsl,
          sourceState: SessionSourceState.active,
        ),
    ];
  }
}

class SessionScanResult {
  const SessionScanResult({
    required this.progress,
    this.cancelled = false,
    required this.allConfiguredRootsReachable,
    required this.sessions,
    required this.errors,
    required this.fileStatuses,
    required this.statusEvents,
    required this.skippedFiles,
    required this.cachedSessions,
  });

  final ScanProgress progress;
  final bool cancelled;
  final bool allConfiguredRootsReachable;
  final List<ScannedSessionFile> sessions;
  final List<ScanFileError> errors;
  final List<ScannedFileStatus> fileStatuses;
  final List<ScannedFileStatus> statusEvents;
  final List<ScannedFileStatus> skippedFiles;
  final List<CachedSessionSnapshot> cachedSessions;

  bool get canRunCacheRepair =>
      allConfiguredRootsReachable &&
      !cancelled &&
      errors.every((error) => error.status == SessionFileStatus.missing);
}

class ScanProgress {
  ScanProgress({required this.startedAtUtc});

  final DateTime startedAtUtc;
  DateTime? finishedAtUtc;
  bool cancelled = false;
  int directoriesScanned = 0;
  int filesFound = 0;
  int filesSkipped = 0;
  int filesParsed = 0;
  int filesFailed = 0;
  int sessionsAdded = 0;
  int sessionsChanged = 0;
  int sessionsMissing = 0;

  int get workItems =>
      directoriesScanned +
      filesFound +
      filesSkipped +
      filesParsed +
      filesFailed +
      sessionsMissing;

  ScanProgress finish({bool cancelled = false}) {
    finishedAtUtc = DateTime.now().toUtc();
    this.cancelled = cancelled;
    sessionsAdded = filesParsed;
    return this;
  }

  ScanProgress snapshot() {
    final copy = ScanProgress(startedAtUtc: startedAtUtc)
      ..finishedAtUtc = finishedAtUtc
      ..cancelled = cancelled
      ..directoriesScanned = directoriesScanned
      ..filesFound = filesFound
      ..filesSkipped = filesSkipped
      ..filesParsed = filesParsed
      ..filesFailed = filesFailed
      ..sessionsAdded = sessionsAdded
      ..sessionsChanged = sessionsChanged
      ..sessionsMissing = sessionsMissing;
    return copy;
  }
}

class ScannedSessionFile {
  const ScannedSessionFile({
    required this.sourcePath,
    required this.sourceType,
    required this.status,
    required this.mappedPath,
    required this.parsedSession,
    this.sourceState = SessionSourceState.active,
    this.sourceSnapshotSize,
    this.sourceSnapshotModifiedUtc,
    this.sourceChangedDuringParse = false,
  });

  factory ScannedSessionFile.fromParseResult({
    required String sourcePath,
    required SessionSourceType sourceType,
    required SessionSourceState sourceState,
    required MappedSessionPath mappedPath,
    required CodexParseResult parseResult,
  }) {
    final parsedSession = parseResult.session;
    if (parsedSession == null) {
      throw ArgumentError.value(
        parseResult,
        'parseResult',
        'A successful parse result is required.',
      );
    }
    return ScannedSessionFile(
      sourcePath: sourcePath,
      sourceType: sourceType,
      sourceState: sourceState,
      status: parseResult.sourceChangedDuringParse
          ? SessionFileStatus.changedPendingParse
          : SessionFileStatus.available,
      mappedPath: mappedPath,
      parsedSession: parsedSession,
      sourceSnapshotSize: parseResult.sourceSnapshotSize,
      sourceSnapshotModifiedUtc: parseResult.sourceSnapshotModifiedUtc,
      sourceChangedDuringParse: parseResult.sourceChangedDuringParse,
    );
  }

  final String sourcePath;
  final SessionSourceType sourceType;
  final SessionFileStatus status;
  final MappedSessionPath mappedPath;
  final CodexParsedSession parsedSession;
  final SessionSourceState sourceState;
  final int? sourceSnapshotSize;
  final DateTime? sourceSnapshotModifiedUtc;
  final bool sourceChangedDuringParse;
}

class ScanFileError {
  const ScanFileError({
    required this.sourcePath,
    required this.status,
    required this.message,
  });

  final String sourcePath;
  final SessionFileStatus status;
  final String message;
}

class ScannedFileStatus {
  const ScannedFileStatus({
    required this.sourcePath,
    required this.status,
    this.sourceState = SessionSourceState.active,
  });

  final String sourcePath;
  final SessionFileStatus status;
  final SessionSourceState sourceState;
}

class CachedSessionSnapshot {
  const CachedSessionSnapshot({
    required this.sourcePath,
    required this.status,
    this.sourceState = SessionSourceState.active,
    this.sourceFileUncPath,
    this.sourceFileSize,
    this.sourceModifiedUtc,
    this.sourceContentHash,
    this.parserVersion,
    this.lastScannedUtc,
    this.lastParsedUtc,
  });

  static Future<CachedSessionSnapshot> fromFile(
    File file, {
    required SessionFileStatus status,
    required int parserVersion,
    SessionSourceState sourceState = SessionSourceState.active,
    String? sourceFileUncPath,
    DateTime? lastScannedUtc,
    DateTime? lastParsedUtc,
  }) async {
    final stat = await file.stat();
    return CachedSessionSnapshot(
      sourcePath: file.path,
      status: status,
      sourceState: sourceState,
      sourceFileUncPath: sourceFileUncPath,
      sourceFileSize: stat.size,
      sourceModifiedUtc: stat.modified.toUtc(),
      parserVersion: parserVersion,
      lastScannedUtc: lastScannedUtc,
      lastParsedUtc: lastParsedUtc,
    );
  }

  final String sourcePath;
  final SessionFileStatus status;
  final SessionSourceState sourceState;
  final String? sourceFileUncPath;
  final int? sourceFileSize;
  final DateTime? sourceModifiedUtc;
  final String? sourceContentHash;
  final int? parserVersion;
  final DateTime? lastScannedUtc;
  final DateTime? lastParsedUtc;

  bool get hasCompleteInvalidationMetadata =>
      sourceFileSize != null &&
      sourceModifiedUtc != null &&
      parserVersion != null;

  CachedSessionSnapshot copyWith({
    String? sourcePath,
    SessionFileStatus? status,
    SessionSourceState? sourceState,
    Object? sourceFileUncPath = _sentinel,
    Object? sourceFileSize = _sentinel,
    Object? sourceModifiedUtc = _sentinel,
    Object? sourceContentHash = _sentinel,
    Object? parserVersion = _sentinel,
    Object? lastScannedUtc = _sentinel,
    Object? lastParsedUtc = _sentinel,
  }) => CachedSessionSnapshot(
    sourcePath: sourcePath ?? this.sourcePath,
    status: status ?? this.status,
    sourceState: sourceState ?? this.sourceState,
    sourceFileUncPath: sourceFileUncPath == _sentinel
        ? this.sourceFileUncPath
        : sourceFileUncPath as String?,
    sourceFileSize: sourceFileSize == _sentinel
        ? this.sourceFileSize
        : sourceFileSize as int?,
    sourceModifiedUtc: sourceModifiedUtc == _sentinel
        ? this.sourceModifiedUtc
        : sourceModifiedUtc as DateTime?,
    sourceContentHash: sourceContentHash == _sentinel
        ? this.sourceContentHash
        : sourceContentHash as String?,
    parserVersion: parserVersion == _sentinel
        ? this.parserVersion
        : parserVersion as int?,
    lastScannedUtc: lastScannedUtc == _sentinel
        ? this.lastScannedUtc
        : lastScannedUtc as DateTime?,
    lastParsedUtc: lastParsedUtc == _sentinel
        ? this.lastParsedUtc
        : lastParsedUtc as DateTime?,
  );
}

class ForceReparsePlan {
  const ForceReparsePlan.none()
    : _mode = _ForceReparseMode.none,
      _selectedPath = null,
      _filter = null;

  const ForceReparsePlan.selected(String sourcePath)
    : _mode = _ForceReparseMode.selected,
      _selectedPath = sourcePath,
      _filter = null;

  const ForceReparsePlan.all()
    : _mode = _ForceReparseMode.all,
      _selectedPath = null,
      _filter = null;

  const ForceReparsePlan.filtered(bool Function(CachedSessionSnapshot) filter)
    : _mode = _ForceReparseMode.filtered,
      _selectedPath = null,
      _filter = filter;

  final _ForceReparseMode _mode;
  final String? _selectedPath;
  final bool Function(CachedSessionSnapshot)? _filter;

  ForceReparseSelection apply(List<CachedSessionSnapshot> sessions) {
    final selected = switch (_mode) {
      _ForceReparseMode.none => const <String>{},
      _ForceReparseMode.selected => _selectedPathKeys(sessions),
      _ForceReparseMode.all => {
        for (final session in sessions) _canonicalScanPath(session.sourcePath),
        for (final session in sessions)
          if (session.sourceFileUncPath != null)
            _canonicalScanPath(session.sourceFileUncPath!),
      },
      _ForceReparseMode.filtered => {
        for (final session in sessions)
          if (_filter!(session)) ..._snapshotPathKeys(session),
      },
    };
    return ForceReparseSelection._(selected);
  }

  Set<String> _selectedPathKeys(List<CachedSessionSnapshot> sessions) {
    final selectedKey = _canonicalScanPath(_selectedPath!);
    final keys = <String>{selectedKey};
    for (final session in sessions) {
      final sessionKeys = _snapshotPathKeys(session);
      if (sessionKeys.contains(selectedKey)) {
        keys.addAll(sessionKeys);
      }
    }
    return keys;
  }
}

class ForceReparseSelection {
  const ForceReparseSelection._(this._paths);

  final Set<String> _paths;

  List<String> get filesToParse => _paths.toList(growable: false)..sort();

  bool shouldForceParse(String sourcePath) =>
      _paths.contains(_canonicalScanPath(sourcePath));
}

enum _ForceReparseMode { none, selected, all, filtered }

class ScanCancellationController {
  ScanCancellationController() : token = ScanCancellationToken._();

  final ScanCancellationToken token;

  bool get isCancellationRequested => token.isCancellationRequested;

  Future<void> get acknowledged => token.acknowledged;

  void cancel() {
    token._requestCancellation();
  }
}

class ScanCancellationToken {
  ScanCancellationToken._();

  final _acknowledged = Completer<void>();
  final _listeners = <void Function()>[];
  var _isCancellationRequested = false;

  bool get isCancellationRequested => _isCancellationRequested;

  Future<void> get acknowledged => _acknowledged.future;

  void _requestCancellation() {
    if (_isCancellationRequested) {
      return;
    }
    _isCancellationRequested = true;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }

  void _acknowledge() {
    if (!_acknowledged.isCompleted) {
      _acknowledged.complete();
    }
  }

  void Function() _addListener(void Function() listener) {
    if (_isCancellationRequested) {
      listener();
      return () {};
    }
    _listeners.add(listener);
    return () {
      _listeners.remove(listener);
    };
  }
}

class ScanAlreadyRunningException implements Exception {
  const ScanAlreadyRunningException();

  @override
  String toString() => 'A scan is already running.';
}

class _ScanCandidate {
  const _ScanCandidate({
    required this.file,
    required this.sourceType,
    required this.sourceState,
  });

  final File file;
  final SessionSourceType sourceType;
  final SessionSourceState sourceState;
}

class _ScanDirectory {
  const _ScanDirectory({
    required this.directory,
    required this.sourceRootPath,
    required this.availabilityRootPath,
    required this.sourceType,
    required this.sourceState,
  });

  final Directory directory;
  final String sourceRootPath;
  final String availabilityRootPath;
  final SessionSourceType sourceType;
  final SessionSourceState sourceState;
}

class _ParsedCandidate {
  const _ParsedCandidate._({this.session, this.error});

  factory _ParsedCandidate.session(ScannedSessionFile session) =>
      _ParsedCandidate._(session: session);

  factory _ParsedCandidate.error(ScanFileError error) =>
      _ParsedCandidate._(error: error);

  final ScannedSessionFile? session;
  final ScanFileError? error;
}

class _ParseDecision {
  const _ParseDecision.parse() : shouldParse = true;

  const _ParseDecision.skip() : shouldParse = false;

  final bool shouldParse;
}

class _CachedSessionIndex {
  _CachedSessionIndex(List<CachedSessionSnapshot> snapshots) {
    for (final snapshot in snapshots) {
      for (final key in _snapshotPathKeys(snapshot)) {
        _byPath[key] = snapshot;
      }
    }
  }

  final Map<String, CachedSessionSnapshot> _byPath = {};

  CachedSessionSnapshot? lookup(String sourcePath) =>
      _byPath[_canonicalScanPath(sourcePath)];
}

class _AsyncQueue<T> {
  final Queue<T> _items = Queue<T>();
  final Queue<Completer<T?>> _waiters = Queue<Completer<T?>>();
  bool _closed = false;

  void add(T item) {
    if (_closed) {
      throw StateError('Cannot add to a closed queue.');
    }
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(item);
      return;
    }
    _items.addLast(item);
  }

  Future<T?> take() {
    if (_items.isNotEmpty) {
      return Future.value(_items.removeFirst());
    }
    if (_closed) {
      return Future.value();
    }
    final waiter = Completer<T?>();
    _waiters.addLast(waiter);
    return waiter.future;
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    }
  }

  void cancel() {
    _items.clear();
    close();
  }
}

class _WorkQueue<T> {
  final Queue<T> _items = Queue<T>();
  final Queue<Completer<T?>> _waiters = Queue<Completer<T?>>();
  var _activeItems = 0;
  var _closeRequested = false;
  var _closed = false;

  void add(T item) {
    if (_closed) {
      throw StateError('Cannot add to a closing queue.');
    }
    if (_waiters.isNotEmpty) {
      _activeItems++;
      _waiters.removeFirst().complete(item);
      return;
    }
    _items.addLast(item);
  }

  Future<T?> take() {
    if (_items.isNotEmpty) {
      _activeItems++;
      return Future.value(_items.removeFirst());
    }
    if (_closed) {
      return Future.value();
    }
    final waiter = Completer<T?>();
    _waiters.addLast(waiter);
    return waiter.future;
  }

  void completeItem() {
    if (_activeItems > 0) {
      _activeItems--;
    }
    _closeIfIdle();
  }

  void closeWhenIdle() {
    _closeRequested = true;
    _closeIfIdle();
  }

  void _closeIfIdle() {
    if (_closed || !_closeRequested || _activeItems != 0 || _items.isNotEmpty) {
      return;
    }
    _closed = true;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    }
  }

  void cancel() {
    if (_closed) {
      return;
    }
    _items.clear();
    _closeRequested = true;
    _closed = true;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete();
    }
  }
}

class _ParserIsolatePool {
  _ParserIsolatePool({
    required this.workerCount,
    required this.maxToolOutputPreviewChars,
    required this.maxMessageContentChars,
    required this.isolateEntrypoint,
    required this.workerStartupTimeout,
    this.onClosing,
  });

  final int workerCount;
  final int maxToolOutputPreviewChars;
  final int maxMessageContentChars;
  final SessionParserIsolateEntrypoint isolateEntrypoint;
  final Duration workerStartupTimeout;
  final Future<void> Function()? onClosing;
  final Queue<_ParserWorker> _available = Queue<_ParserWorker>();
  final Queue<_ParserJob> _pending = Queue<_ParserJob>();
  final Map<int, Completer<CodexParseResult>> _completers = {};
  final Map<int, _ParserWorker> _busyWorkers = {};
  final List<_ParserWorker> _workers = [];
  var _nextJobId = 0;
  var _closed = false;
  Future<void>? _closeFuture;

  Future<void> start() async {
    final count = math.max(1, workerCount);
    try {
      for (var index = 0; index < count; index++) {
        final worker = await _ParserWorker.start(
          maxToolOutputPreviewChars: maxToolOutputPreviewChars,
          maxMessageContentChars: maxMessageContentChars,
          isolateEntrypoint: isolateEntrypoint,
          startupTimeout: workerStartupTimeout,
          onResult: _handleResult,
          onFailure: _handleWorkerFailure,
        );
        _workers.add(worker);
        _available.add(worker);
      }
    } on Object {
      _closed = true;
      await _shutdownWorkers(notifyClosing: false);
      rethrow;
    }
  }

  Future<CodexParseResult> parseFile(String sourcePath) {
    if (_closed) {
      throw StateError('Parser pool is closed.');
    }
    final jobId = _nextJobId++;
    final completer = Completer<CodexParseResult>();
    _completers[jobId] = completer;
    _pending.add(_ParserJob(id: jobId, sourcePath: sourcePath));
    _pump();
    return completer.future;
  }

  Future<void> close() {
    return _closeFuture ??= _close();
  }

  Future<void> _close() async {
    if (!_closed) {
      _closed = true;
      for (final completer in _completers.values) {
        if (!completer.isCompleted) {
          completer.completeError(StateError('Parser pool closed.'));
        }
      }
      _completers.clear();
      _pending.clear();
    }
    await _shutdownWorkers();
  }

  Future<void> _shutdownWorkers({bool notifyClosing = true}) async {
    if (notifyClosing) {
      await onClosing?.call();
    }
    for (final worker in _workers) {
      await worker.close();
    }
    _available.clear();
    _busyWorkers.clear();
    _workers.clear();
  }

  void _handleWorkerFailure(
    _ParserWorker worker,
    Object error,
    StackTrace? stackTrace,
  ) {
    if (_closed) {
      return;
    }
    _closed = true;
    final failure = StateError('Parser worker terminated unexpectedly: $error');
    for (final completer in _completers.values) {
      if (!completer.isCompleted) {
        completer.completeError(failure, stackTrace ?? StackTrace.current);
      }
    }
    _completers.clear();
    _pending.clear();
    _closeFuture ??= _shutdownWorkers();
  }

  void _pump() {
    while (_available.isNotEmpty && _pending.isNotEmpty) {
      final worker = _available.removeFirst();
      final job = _pending.removeFirst();
      _busyWorkers[job.id] = worker;
      worker.parse(job);
    }
  }

  void _handleResult(_ParserWorkerResult result) {
    final worker = _busyWorkers.remove(result.id);
    final completer = _completers.remove(result.id);
    if (worker != null && !_closed) {
      _available.add(worker);
    }
    if (completer != null && !completer.isCompleted) {
      completer.complete(result.result);
    }
    if (!_closed) {
      _pump();
    }
  }
}

class _ParserWorker {
  _ParserWorker._({
    required this.isolate,
    required this.port,
    required this.subscription,
    required this.receivePort,
    required this.errorSubscription,
    required this.errorPort,
    required this.exitSubscription,
    required this.exitPort,
  });

  final Isolate isolate;
  final SendPort port;
  final StreamSubscription<Object?> subscription;
  final ReceivePort receivePort;
  final StreamSubscription<Object?> errorSubscription;
  final ReceivePort errorPort;
  final StreamSubscription<Object?> exitSubscription;
  final ReceivePort exitPort;
  var _closing = false;

  static Future<_ParserWorker> start({
    required int maxToolOutputPreviewChars,
    required int maxMessageContentChars,
    required SessionParserIsolateEntrypoint isolateEntrypoint,
    required Duration startupTimeout,
    required void Function(_ParserWorkerResult result) onResult,
    required void Function(
      _ParserWorker worker,
      Object error,
      StackTrace? stackTrace,
    )
    onFailure,
  }) async {
    final receivePort = ReceivePort();
    final errorPort = ReceivePort();
    final exitPort = ReceivePort();
    final ready = Completer<SendPort>();
    _ParserWorker? worker;
    (Object, StackTrace?)? pendingFailure;

    void reportFailure(Object error, StackTrace? stackTrace) {
      if (!ready.isCompleted) {
        ready.completeError(error, stackTrace ?? StackTrace.current);
        return;
      }
      final startedWorker = worker;
      if (startedWorker == null) {
        pendingFailure = (error, stackTrace);
        return;
      }
      onFailure(startedWorker, error, stackTrace);
    }

    late StreamSubscription<Object?> subscription;
    subscription = receivePort.listen((message) {
      if (message is _ParserWorkerReady) {
        if (!ready.isCompleted) {
          ready.complete(message.port);
        }
        return;
      }
      if (message is _ParserWorkerResult) {
        onResult(message);
      }
    });
    final errorSubscription = errorPort.listen((message) {
      final errorMessage = switch (message) {
        [final Object error, ...] => error.toString(),
        _ => message?.toString() ?? 'Unknown isolate error',
      };
      final stackTrace = switch (message) {
        [_, final Object stack, ...] => StackTrace.fromString(stack.toString()),
        _ => null,
      };
      reportFailure(
        StateError('Parser worker failed: $errorMessage'),
        stackTrace,
      );
    });
    final exitSubscription = exitPort.listen((_) {
      reportFailure(
        StateError(
          ready.isCompleted
              ? 'Parser worker exited unexpectedly.'
              : 'Parser worker exited before becoming ready.',
        ),
        null,
      );
    });
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<Object?>(
        isolateEntrypoint,
        _ParserWorkerStart(
          replyPort: receivePort.sendPort,
          maxToolOutputPreviewChars: maxToolOutputPreviewChars,
          maxMessageContentChars: maxMessageContentChars,
        ),
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
        errorsAreFatal: true,
      );
      final startedWorker = _ParserWorker._(
        isolate: isolate,
        port: await ready.future.timeout(
          startupTimeout,
          onTimeout: () => throw StateError(
            'Parser worker did not become ready within '
            '${startupTimeout.inMilliseconds} ms.',
          ),
        ),
        subscription: subscription,
        receivePort: receivePort,
        errorSubscription: errorSubscription,
        errorPort: errorPort,
        exitSubscription: exitSubscription,
        exitPort: exitPort,
      );
      worker = startedWorker;
      final startupFailure = pendingFailure;
      if (startupFailure != null) {
        await startedWorker.close();
        Error.throwWithStackTrace(
          startupFailure.$1,
          startupFailure.$2 ?? StackTrace.current,
        );
      }
      return startedWorker;
    } on Object {
      isolate?.kill(priority: Isolate.immediate);
      await subscription.cancel();
      await errorSubscription.cancel();
      await exitSubscription.cancel();
      receivePort.close();
      errorPort.close();
      exitPort.close();
      rethrow;
    }
  }

  void parse(_ParserJob job) {
    port.send(_ParserWorkerParse(id: job.id, sourcePath: job.sourcePath));
  }

  Future<void> close() async {
    if (_closing) {
      return;
    }
    _closing = true;
    port.send(const _ParserWorkerStop());
    isolate.kill(priority: Isolate.immediate);
    await subscription.cancel();
    await errorSubscription.cancel();
    await exitSubscription.cancel();
    receivePort.close();
    errorPort.close();
    exitPort.close();
  }
}

class _ParserJob {
  const _ParserJob({required this.id, required this.sourcePath});

  final int id;
  final String sourcePath;
}

class _ParserWorkerStart {
  const _ParserWorkerStart({
    required this.replyPort,
    required this.maxToolOutputPreviewChars,
    required this.maxMessageContentChars,
  });

  final SendPort replyPort;
  final int maxToolOutputPreviewChars;
  final int maxMessageContentChars;
}

class _ParserWorkerReady {
  const _ParserWorkerReady(this.port);

  final SendPort port;
}

class _ParserWorkerParse {
  const _ParserWorkerParse({required this.id, required this.sourcePath});

  final int id;
  final String sourcePath;
}

class _ParserWorkerStop {
  const _ParserWorkerStop();
}

class _ParserWorkerResult {
  const _ParserWorkerResult({required this.id, required this.result});

  final int id;
  final CodexParseResult result;
}

Future<void> _parserWorkerEntry(Object? message) async {
  final start = message! as _ParserWorkerStart;
  final receivePort = ReceivePort();
  final parser = CodexSessionParser(
    maxToolOutputPreviewChars: start.maxToolOutputPreviewChars,
    maxMessageContentChars: start.maxMessageContentChars,
  );
  start.replyPort.send(_ParserWorkerReady(receivePort.sendPort));
  await for (final message in receivePort) {
    if (message is _ParserWorkerStop) {
      receivePort.close();
      return;
    }
    if (message is _ParserWorkerParse) {
      final result = await parser.parseFile(File(message.sourcePath));
      start.replyPort.send(_ParserWorkerResult(id: message.id, result: result));
    }
  }
}

bool _isSupportedSessionFile(String path) =>
    path.endsWith('.json') || path.endsWith('.jsonl');

Set<String> _snapshotPathKeys(CachedSessionSnapshot snapshot) => {
  _canonicalScanPath(snapshot.sourcePath),
  if (snapshot.sourceFileUncPath != null)
    _canonicalScanPath(snapshot.sourceFileUncPath!),
};

bool _isModifiedWithinTolerance(
  DateTime currentModifiedUtc,
  DateTime cachedModifiedUtc,
  Duration tolerance,
) {
  return currentModifiedUtc
          .toUtc()
          .difference(cachedModifiedUtc.toUtc())
          .abs() <=
      tolerance;
}

int _compareScannedSessions(
  ScannedSessionFile left,
  ScannedSessionFile right,
) => _normalizedSortPath(
  left.sourcePath,
).compareTo(_normalizedSortPath(right.sourcePath));

int _compareErrors(ScanFileError left, ScanFileError right) {
  final pathCompare = _normalizedSortPath(
    left.sourcePath,
  ).compareTo(_normalizedSortPath(right.sourcePath));
  if (pathCompare != 0) {
    return pathCompare;
  }
  return left.status.index.compareTo(right.status.index);
}

int _compareStatuses(ScannedFileStatus left, ScannedFileStatus right) {
  final pathCompare = _normalizedSortPath(
    left.sourcePath,
  ).compareTo(_normalizedSortPath(right.sourcePath));
  if (pathCompare != 0) {
    return pathCompare;
  }
  return left.status.index.compareTo(right.status.index);
}

String _normalizedSortPath(String path) => _canonicalScanPath(path);

String _canonicalScanPath(String path) {
  var normalized = path.replaceAll(r'\', '/').toLowerCase();
  while (normalized.contains('//')) {
    normalized = normalized.replaceAll('//', '/');
  }
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

bool _isPathUnderRoot(String path, String root) {
  final normalizedPath = _normalizedSortPath(path);
  final normalizedRoot = _normalizedSortPath(root);
  return normalizedPath == normalizedRoot ||
      normalizedPath.startsWith('$normalizedRoot/');
}

const Object _sentinel = Object();

SessionFileStatus _statusFromFileSystemError(FileSystemException error) {
  if (error.osError?.errorCode == 5) {
    return SessionFileStatus.permissionDenied;
  }
  return SessionFileStatus.pathUnreachable;
}

SessionFileStatus _statusFromParseError(CodexParseError? error) {
  if (error?.kind == CodexParseErrorKind.unsupportedRoot) {
    return SessionFileStatus.unsupportedFormat;
  }
  if (error?.kind != CodexParseErrorKind.io) {
    return SessionFileStatus.parseError;
  }
  final message = error?.message.toLowerCase() ?? '';
  if (message.contains('denied') || message.contains('permission')) {
    return SessionFileStatus.permissionDenied;
  }
  return SessionFileStatus.pathUnreachable;
}

String _parseErrorMessage(CodexParseError? error) {
  if (error == null) {
    return 'Parse failed.';
  }
  final line = error.line;
  if (line == null) {
    return error.message;
  }
  final column = error.column;
  if (column == null) {
    return '${error.message} at line $line.';
  }
  return '${error.message} at line $line, column $column.';
}
