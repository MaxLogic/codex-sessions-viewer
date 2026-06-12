import 'dart:async';
import 'dart:io';

import '../parser/codex_session_parser.dart';
import '../path_mapping/path_mapper.dart';

enum SessionFileStatus {
  available,
  missing,
  pathUnreachable,
  parseError,
  permissionDenied,
  unsupportedFormat,
  changedPendingParse,
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
  }) : assert(maxConcurrentParses > 0);

  final CodexSessionParser parser;
  final CodexPathMapper pathMapper;
  final int maxConcurrentParses;
  bool _isScanning = false;

  Future<SessionScanResult> scan(SessionScanRequest request) async {
    if (_isScanning) {
      throw const ScanAlreadyRunningException();
    }
    _isScanning = true;
    try {
      final progress = ScanProgress(startedAtUtc: DateTime.now().toUtc());
      final sessions = <ScannedSessionFile>[];
      final errors = <ScanFileError>[];
      final fileStatuses = <ScannedFileStatus>[];
      final statusEvents = <ScannedFileStatus>[];
      final candidates = <_ScanCandidate>[];
      final reachableRoots = <String>[];

      if (await _collectRoot(
        rootPath: request.windowsRoot,
        sourceType: SessionSourceType.windows,
        progress: progress,
        errors: errors,
        fileStatuses: fileStatuses,
        statusEvents: statusEvents,
        candidates: candidates,
      )) {
        reachableRoots.add(request.windowsRoot!);
      }
      if (await _collectRoot(
        rootPath: request.wslRoot,
        sourceType: SessionSourceType.wsl,
        progress: progress,
        errors: errors,
        fileStatuses: fileStatuses,
        statusEvents: statusEvents,
        candidates: candidates,
      )) {
        reachableRoots.add(request.wslRoot!);
      }

      candidates.sort(_compareCandidates);

      for (final candidate in candidates) {
        progress.sessionsChanged++;
        statusEvents.add(
          ScannedFileStatus(
            sourcePath: candidate.file.path,
            status: SessionFileStatus.changedPendingParse,
          ),
        );
      }
      final parsed = await _parseCandidates(candidates, progress);
      for (final parsedFile in parsed) {
        if (parsedFile.error == null) {
          sessions.add(parsedFile.session!);
          fileStatuses.add(
            ScannedFileStatus(
              sourcePath: parsedFile.session!.sourcePath,
              status: SessionFileStatus.available,
            ),
          );
          statusEvents.add(
            ScannedFileStatus(
              sourcePath: parsedFile.session!.sourcePath,
              status: SessionFileStatus.available,
            ),
          );
        } else {
          errors.add(parsedFile.error!);
          fileStatuses.add(
            ScannedFileStatus(
              sourcePath: parsedFile.error!.sourcePath,
              status: parsedFile.error!.status,
            ),
          );
          statusEvents.add(
            ScannedFileStatus(
              sourcePath: parsedFile.error!.sourcePath,
              status: parsedFile.error!.status,
            ),
          );
        }
      }
      if (reachableRoots.isNotEmpty) {
        _recordMissingCachedSessions(
          request.cachedSessions,
          candidates,
          reachableRoots,
          progress,
          errors,
          fileStatuses,
          statusEvents,
        );
      }

      sessions.sort(_compareScannedSessions);
      errors.sort(_compareErrors);
      fileStatuses.sort(_compareStatuses);
      return SessionScanResult(
        progress: progress.finish(),
        sessions: List.unmodifiable(sessions),
        errors: List.unmodifiable(errors),
        fileStatuses: List.unmodifiable(fileStatuses),
        statusEvents: List.unmodifiable(statusEvents),
        cachedSessions: List.unmodifiable(request.cachedSessions),
      );
    } finally {
      _isScanning = false;
    }
  }

  Future<bool> _collectRoot({
    required String? rootPath,
    required SessionSourceType sourceType,
    required ScanProgress progress,
    required List<ScanFileError> errors,
    required List<ScannedFileStatus> fileStatuses,
    required List<ScannedFileStatus> statusEvents,
    required List<_ScanCandidate> candidates,
  }) async {
    if (rootPath == null || rootPath.isEmpty) {
      return false;
    }
    final root = Directory(rootPath);
    if (!await root.exists()) {
      progress.filesFailed++;
      errors.add(
        ScanFileError(
          sourcePath: rootPath,
          status: SessionFileStatus.pathUnreachable,
          message: 'Session root is unreachable.',
        ),
      );
      fileStatuses.add(
        ScannedFileStatus(
          sourcePath: rootPath,
          status: SessionFileStatus.pathUnreachable,
        ),
      );
      statusEvents.add(
        ScannedFileStatus(
          sourcePath: rootPath,
          status: SessionFileStatus.pathUnreachable,
        ),
      );
      return false;
    }
    try {
      await for (final entity in root.list(recursive: true)) {
        if (entity is! File) {
          continue;
        }
        if (!_isSupportedSessionFile(entity.path)) {
          progress.filesSkipped++;
          progress.filesFailed++;
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
            ),
          );
          statusEvents.add(
            ScannedFileStatus(
              sourcePath: entity.path,
              status: SessionFileStatus.unsupportedFormat,
            ),
          );
          continue;
        }
        progress.filesFound++;
        candidates.add(_ScanCandidate(file: entity, sourceType: sourceType));
      }
      return true;
    } on FileSystemException catch (error) {
      progress.filesFailed++;
      errors.add(
        ScanFileError(
          sourcePath: rootPath,
          status: _statusFromFileSystemError(error),
          message: error.message,
        ),
      );
      fileStatuses.add(
        ScannedFileStatus(
          sourcePath: rootPath,
          status: _statusFromFileSystemError(error),
        ),
      );
      statusEvents.add(
        ScannedFileStatus(
          sourcePath: rootPath,
          status: _statusFromFileSystemError(error),
        ),
      );
      return false;
    }
  }

  Future<List<_ParsedCandidate>> _parseCandidates(
    List<_ScanCandidate> candidates,
    ScanProgress progress,
  ) async {
    final results = List<_ParsedCandidate?>.filled(candidates.length, null);
    var nextIndex = 0;

    Future<void> worker() async {
      while (true) {
        final index = nextIndex;
        if (index >= candidates.length) {
          return;
        }
        nextIndex++;
        results[index] = await _parseCandidate(candidates[index], progress);
      }
    }

    final workerCount = candidates.length < maxConcurrentParses
        ? candidates.length
        : maxConcurrentParses;
    await Future.wait([for (var i = 0; i < workerCount; i++) worker()]);
    return results.whereType<_ParsedCandidate>().toList(growable: false);
  }

  Future<_ParsedCandidate> _parseCandidate(
    _ScanCandidate candidate,
    ScanProgress progress,
  ) async {
    final mappedPath = candidate.sourceType == SessionSourceType.windows
        ? pathMapper.mapWindowsPath(candidate.file.path)
        : pathMapper.mapWslUncPath(candidate.file.path);
    final parseResult = await parser.parseFile(candidate.file);
    if (!parseResult.isSuccess) {
      progress.filesFailed++;
      final error = parseResult.error;
      return _ParsedCandidate.error(
        ScanFileError(
          sourcePath: candidate.file.path,
          status: _statusFromParseError(error),
          message: error?.message ?? 'Parse failed.',
        ),
      );
    }
    progress.filesParsed++;
    return _ParsedCandidate.session(
      ScannedSessionFile(
        sourcePath: candidate.file.path,
        sourceType: candidate.sourceType,
        status: SessionFileStatus.available,
        mappedPath: mappedPath,
        parsedSession: parseResult.session!,
      ),
    );
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
      if (foundPaths.contains(_canonicalScanPath(cached.sourcePath))) {
        continue;
      }
      if (!reachableRoots.any(
        (root) => _isPathUnderRoot(cached.sourcePath, root),
      )) {
        continue;
      }
      progress.sessionsMissing++;
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
        ),
      );
      statusEvents.add(
        ScannedFileStatus(
          sourcePath: cached.sourcePath,
          status: SessionFileStatus.missing,
        ),
      );
    }
  }
}

class SessionScanRequest {
  const SessionScanRequest({
    this.windowsRoot,
    this.wslRoot,
    this.cachedSessions = const [],
  });

  final String? windowsRoot;
  final String? wslRoot;
  final List<CachedSessionSnapshot> cachedSessions;
}

class SessionScanResult {
  const SessionScanResult({
    required this.progress,
    required this.sessions,
    required this.errors,
    required this.fileStatuses,
    required this.statusEvents,
    required this.cachedSessions,
  });

  final ScanProgress progress;
  final List<ScannedSessionFile> sessions;
  final List<ScanFileError> errors;
  final List<ScannedFileStatus> fileStatuses;
  final List<ScannedFileStatus> statusEvents;
  final List<CachedSessionSnapshot> cachedSessions;
}

class ScanProgress {
  ScanProgress({required this.startedAtUtc});

  final DateTime startedAtUtc;
  DateTime? finishedAtUtc;
  int filesFound = 0;
  int filesSkipped = 0;
  int filesParsed = 0;
  int filesFailed = 0;
  int sessionsAdded = 0;
  int sessionsChanged = 0;
  int sessionsMissing = 0;

  ScanProgress finish() {
    finishedAtUtc = DateTime.now().toUtc();
    sessionsAdded = filesParsed;
    return this;
  }
}

class ScannedSessionFile {
  const ScannedSessionFile({
    required this.sourcePath,
    required this.sourceType,
    required this.status,
    required this.mappedPath,
    required this.parsedSession,
  });

  final String sourcePath;
  final SessionSourceType sourceType;
  final SessionFileStatus status;
  final MappedSessionPath mappedPath;
  final CodexParsedSession parsedSession;
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
  const ScannedFileStatus({required this.sourcePath, required this.status});

  final String sourcePath;
  final SessionFileStatus status;
}

class CachedSessionSnapshot {
  const CachedSessionSnapshot({required this.sourcePath, required this.status});

  final String sourcePath;
  final SessionFileStatus status;
}

class ScanAlreadyRunningException implements Exception {
  const ScanAlreadyRunningException();

  @override
  String toString() => 'A scan is already running.';
}

class _ScanCandidate {
  const _ScanCandidate({required this.file, required this.sourceType});

  final File file;
  final SessionSourceType sourceType;
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

bool _isSupportedSessionFile(String path) =>
    path.endsWith('.json') || path.endsWith('.jsonl');

int _compareCandidates(_ScanCandidate left, _ScanCandidate right) {
  final sourceCompare = left.sourceType.index.compareTo(right.sourceType.index);
  if (sourceCompare != 0) {
    return sourceCompare;
  }
  return _normalizedSortPath(
    left.file.path,
  ).compareTo(_normalizedSortPath(right.file.path));
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
