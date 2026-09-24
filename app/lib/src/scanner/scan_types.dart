/// Scan results the viewer reads from the collector's `finished` reports.
/// The collector owns discovery and parsing; these types only describe them.
library;

/// A source file's status as the collector reports it.
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

/// Counts of one refresh, summed over the harness scans.
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

  ScanProgress finish({bool cancelled = false}) {
    finishedAtUtc = DateTime.now().toUtc();
    this.cancelled = cancelled;
    sessionsAdded = filesParsed;
    return this;
  }
}

/// A file the collector could not collect.
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

class SessionScanResult {
  const SessionScanResult({
    required this.progress,
    this.cancelled = false,
    required this.allConfiguredRootsReachable,
    required this.errors,
  });

  final ScanProgress progress;
  final bool cancelled;
  final bool allConfiguredRootsReachable;
  final List<ScanFileError> errors;
}

class ScanCancellationController {
  ScanCancellationController() : token = ScanCancellationToken._();

  final ScanCancellationToken token;

  bool get isCancellationRequested => token.isCancellationRequested;

  void cancel() => token._isCancellationRequested = true;
}

class ScanCancellationToken {
  ScanCancellationToken._();

  var _isCancellationRequested = false;

  bool get isCancellationRequested => _isCancellationRequested;
}
