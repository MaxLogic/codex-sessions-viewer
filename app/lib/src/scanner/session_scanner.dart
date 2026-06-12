import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

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
      final skippedFiles = <ScannedFileStatus>[];
      final candidates = <_ScanCandidate>[];
      final reachableRoots = <String>[];
      final forcedReparse = request.forceReparsePlan.apply(
        request.cachedSessions,
      );

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

      final parseCandidates = <_ScanCandidate>[];
      for (final candidate in candidates) {
        final decision = await _parseDecision(
          candidate.file,
          request.cachedSessions,
          forcedReparse,
        );
        if (!decision.shouldParse) {
          progress.filesSkipped++;
          skippedFiles.add(
            ScannedFileStatus(
              sourcePath: candidate.file.path,
              status: SessionFileStatus.available,
            ),
          );
          fileStatuses.add(
            ScannedFileStatus(
              sourcePath: candidate.file.path,
              status: SessionFileStatus.available,
            ),
          );
          continue;
        }
        progress.sessionsChanged++;
        statusEvents.add(
          ScannedFileStatus(
            sourcePath: candidate.file.path,
            status: SessionFileStatus.changedPendingParse,
          ),
        );
        parseCandidates.add(candidate);
      }
      final parsed = await _parseCandidates(parseCandidates, progress);
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
        skippedFiles: List.unmodifiable(skippedFiles),
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

  Future<_ParseDecision> _parseDecision(
    File file,
    List<CachedSessionSnapshot> cachedSessions,
    ForceReparseSelection forcedReparse,
  ) async {
    if (forcedReparse.shouldForceParse(file.path)) {
      return const _ParseDecision.parse();
    }
    final cached = _cachedForPath(cachedSessions, file.path);
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
    final String currentHash;
    try {
      stat = await file.stat();
      currentHash = await _contentHash(file);
    } on Object {
      return const _ParseDecision.parse();
    }
    final currentSize = stat.size;
    final currentModifiedUtc = stat.modified.toUtc();
    final sizeChanged = currentSize != cached.sourceFileSize;
    final modifiedChanged = currentModifiedUtc != cached.sourceModifiedUtc;
    final hashChanged = currentHash != cached.sourceContentHash;
    if (!sizeChanged && !modifiedChanged && !hashChanged) {
      return const _ParseDecision.skip();
    }
    if (hashChanged) {
      return const _ParseDecision.parse();
    }
    return const _ParseDecision.skip();
  }
}

class SessionScanRequest {
  const SessionScanRequest({
    this.windowsRoot,
    this.wslRoot,
    this.cachedSessions = const [],
    this.forceReparsePlan = const ForceReparsePlan.none(),
  });

  final String? windowsRoot;
  final String? wslRoot;
  final List<CachedSessionSnapshot> cachedSessions;
  final ForceReparsePlan forceReparsePlan;
}

class SessionScanResult {
  const SessionScanResult({
    required this.progress,
    required this.sessions,
    required this.errors,
    required this.fileStatuses,
    required this.statusEvents,
    required this.skippedFiles,
    required this.cachedSessions,
  });

  final ScanProgress progress;
  final List<ScannedSessionFile> sessions;
  final List<ScanFileError> errors;
  final List<ScannedFileStatus> fileStatuses;
  final List<ScannedFileStatus> statusEvents;
  final List<ScannedFileStatus> skippedFiles;
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
  const CachedSessionSnapshot({
    required this.sourcePath,
    required this.status,
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
    String? sourceFileUncPath,
    DateTime? lastScannedUtc,
    DateTime? lastParsedUtc,
  }) async {
    final stat = await file.stat();
    return CachedSessionSnapshot(
      sourcePath: file.path,
      status: status,
      sourceFileUncPath: sourceFileUncPath,
      sourceFileSize: stat.size,
      sourceModifiedUtc: stat.modified.toUtc(),
      sourceContentHash: await _contentHash(file),
      parserVersion: parserVersion,
      lastScannedUtc: lastScannedUtc,
      lastParsedUtc: lastParsedUtc,
    );
  }

  final String sourcePath;
  final SessionFileStatus status;
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
      sourceContentHash != null &&
      parserVersion != null;

  CachedSessionSnapshot copyWith({
    String? sourcePath,
    SessionFileStatus? status,
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

class _ParseDecision {
  const _ParseDecision.parse() : shouldParse = true;

  const _ParseDecision.skip() : shouldParse = false;

  final bool shouldParse;
}

bool _isSupportedSessionFile(String path) =>
    path.endsWith('.json') || path.endsWith('.jsonl');

CachedSessionSnapshot? _cachedForPath(
  List<CachedSessionSnapshot> cachedSessions,
  String sourcePath,
) {
  final key = _canonicalScanPath(sourcePath);
  for (final cached in cachedSessions) {
    if (_snapshotPathKeys(cached).contains(key)) {
      return cached;
    }
  }
  return null;
}

Set<String> _snapshotPathKeys(CachedSessionSnapshot snapshot) => {
  _canonicalScanPath(snapshot.sourcePath),
  if (snapshot.sourceFileUncPath != null)
    _canonicalScanPath(snapshot.sourceFileUncPath!),
};

Future<String> _contentHash(File file) async {
  final bytes = await file.readAsBytes();
  return sha256.convert(bytes).toString();
}

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
