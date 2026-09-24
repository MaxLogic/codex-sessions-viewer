import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'session_scanner.dart';

/// Starts the collector; tests substitute a scripted process.
typedef CollectorProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

Future<Process> _startProcess(String executable, List<String> arguments) =>
    Process.start(executable, arguments, runInShell: false);

/// The collector executable is missing or cannot run.
class CollectorUnavailableException implements Exception {
  const CollectorUnavailableException(this.executable, this.reason);

  final String executable;
  final String reason;

  @override
  String toString() =>
      'The session collector could not be started. Expected '
      '${p.basename(executable)} at $executable. Reinstall Codex Sessions '
      'Viewer so the collector sits next to the viewer, or set '
      'CODEX_SESSIONS_COLLECTOR_EXE to its location. ($reason)';
}

/// The collector held the database writer lease longer than allowed.
class CollectorLeaseTimeoutException implements Exception {
  const CollectorLeaseTimeoutException(this.timeout);

  final Duration timeout;

  @override
  String toString() =>
      'The session collector held the database writer for more than '
      '${timeout.inSeconds} s and was stopped. Other database work continues; '
      'refresh again to finish collecting.';
}

/// The installed collector is the only writer of parsed session state.
class CollectorProcess {
  CollectorProcess({
    String? executable,
    CollectorProcessStarter? start,
    this.leaseTimeout = defaultLeaseTimeout,
  }) : executable =
           executable ??
           Platform.environment['CODEX_SESSIONS_COLLECTOR_EXE'] ??
           p.join(
             p.dirname(Platform.resolvedExecutable),
             'codex-sessions-collector.exe',
           ),
       _start = start ?? _startProcess;

  /// A write batch holds the lease for well under a second; the one-time
  /// cache repair also copies the database. Anything longer is a hang.
  static const defaultLeaseTimeout = Duration(minutes: 5);

  final String executable;
  final CollectorProcessStarter _start;
  final Duration leaseTimeout;
  int persistenceFlushCount = 0;

  /// The collector's report of the legacy session cache repair, when the
  /// last scan ran it.
  Map<String, dynamic>? cacheRepair;

  Future<Process> _launch(List<String> arguments) async {
    try {
      return await _start(executable, arguments);
    } on ProcessException catch (error) {
      throw CollectorUnavailableException(executable, error.message);
    }
  }

  /// Runs a one-shot collector command, writing [input] lines to stdin.
  Future<({int exitCode, String stderr})> _run(
    List<String> arguments, {
    List<String> input = const [],
  }) async {
    final process = await _launch(arguments);
    final stdin = _LineWriter(process.stdin);
    final output = process.stdout.drain<void>();
    final errors = process.stderr.transform(utf8.decoder).join();
    input.forEach(stdin.send);
    await stdin.close();
    final exitCode = await process.exitCode;
    await output;
    return (exitCode: exitCode, stderr: await errors);
  }

  Future<void> applyProjectHints(
    File databaseFile,
    List<Map<String, Object?>> sessions,
    Map<String, String> hints,
  ) async {
    if (hints.isEmpty) return;
    final result = await _run(
      ['apply', '--json', '--db', databaseFile.absolute.path],
      input: [
        jsonEncode({
          'contract': 'codex-sessions-viewer.ingest',
          'version': 1,
          'kind': 'project_hints',
          'record': {
            'harness': 'codex',
            'sessions': sessions,
            'hints': [
              for (final hint in hints.entries)
                {'working_directory': hint.key, 'project_name': hint.value},
            ],
          },
        }),
      ],
    );
    if (result.exitCode != 0) {
      throw StateError(
        'Collector project hints failed (${result.exitCode}): ${result.stderr}',
      );
    }
  }

  Future<void> ingest({
    required File settingsFile,
    required File databaseFile,
    required String sourcePath,
    required String harness,
  }) async {
    if (harness != 'codex' && harness != 'claude') {
      throw UnsupportedError('No collector for harness $harness.');
    }
    final result = await _run([
      harness,
      'ingest',
      '--json',
      '--settings',
      settingsFile.absolute.path,
      '--db',
      databaseFile.absolute.path,
      sourcePath,
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'Collector reparse failed (${result.exitCode}): ${result.stderr}',
      );
    }
  }

  /// Scans Codex homes, then Claude Code transcripts under [claudeRoots]
  /// (skipped when empty), under the same writer-lease protocol.
  Future<SessionScanResult> scan({
    required File settingsFile,
    required File databaseFile,
    required ScanCancellationToken cancellation,
    required Future<void> Function(Future<void> Function()) write,
    required void Function(ScanProgress, int) onProgress,
    List<String> claudeRoots = const [],
    bool resolveWslProjects = true,
    int? parserWorkers,
    int flushSessions = 64,
    int flushBytes = 8 * 1024 * 1024,
  }) async {
    final started = DateTime.now().toUtc();
    persistenceFlushCount = 0;
    cacheRepair = null;
    final common = [
      '--settings',
      settingsFile.absolute.path,
      '--db',
      databaseFile.absolute.path,
      '--coordinate-writes',
      '--flush-sessions',
      '$flushSessions',
      '--flush-bytes',
      '$flushBytes',
      if (parserWorkers != null) ...['--parser-workers', '$parserWorkers'],
      if (!resolveWslProjects) '--no-wsl-projects',
    ];
    final reports = <Map<String, dynamic>>[];
    for (final harness in ['codex', if (claudeRoots.isNotEmpty) 'claude']) {
      if (reports.isNotEmpty &&
          (reports.last['cancelled'] == true ||
              cancellation.isCancellationRequested)) {
        break;
      }
      final before = [...reports];
      final report = await _scanHarness(
        [
          harness,
          'scan',
          ...common,
          if (harness == 'claude')
            for (final root in claudeRoots) ...['--claude-root', root],
        ],
        cancellation: cancellation,
        write: write,
        onProgress: (counts, committed) => onProgress(
          _progress([...before, counts], started),
          _sum([...before], 'sessions_written') + committed,
        ),
      );
      reports.add(report);
      if (harness == 'codex') {
        cacheRepair = report['cache_repair'] as Map<String, dynamic>?;
      }
    }
    persistenceFlushCount = _sum(reports, 'persistence_flushes');
    final cancelled = reports.any((report) => report['cancelled'] == true);
    final failures = [
      for (final report in reports)
        for (final entry in report['errors'] as List<dynamic>)
          ScanFileError(
            sourcePath: entry['path'] as String,
            status: SessionFileStatus.values.firstWhere(
              (status) => status.wireName == entry['status'],
              orElse: () => SessionFileStatus.parseError,
            ),
            message: entry['message'] as String? ?? '',
          ),
    ];
    final progress = _progress(reports, started)..finish(cancelled: cancelled);
    onProgress(progress, _sum(reports, 'sessions_written'));
    return SessionScanResult(
      progress: progress,
      cancelled: cancelled,
      allConfiguredRootsReachable: !failures.any(
        (failure) => failure.status == SessionFileStatus.pathUnreachable,
      ),
      sessions: const [],
      errors: failures,
      fileStatuses: const [],
      statusEvents: const [],
      skippedFiles: const [],
      cachedSessions: const [],
    );
  }

  /// One `<harness> scan --coordinate-writes` run. Returns its `finished`
  /// report; [onProgress] receives the run's own counts.
  Future<Map<String, dynamic>> _scanHarness(
    List<String> arguments, {
    required ScanCancellationToken cancellation,
    required Future<void> Function(Future<void> Function()) write,
    required void Function(Map<String, dynamic>, int) onProgress,
  }) async {
    final process = await _launch(arguments);
    // Every stdin line goes through one writer, so a cancel never interleaves
    // with a grant's flush, and a pipe closed by an exited collector is
    // recorded instead of surfacing as an unhandled error.
    final stdin = _LineWriter(process.stdin);
    // Drain stderr immediately so errors cannot fill the pipe and deadlock.
    final errors = process.stderr.transform(utf8.decoder).join();
    var cancelSent = false;
    void sendCancel() {
      if (!cancelSent && cancellation.isCancellationRequested) {
        cancelSent = true;
        stdin.send('cancel');
      }
    }

    final cancelPoll = Timer.periodic(
      const Duration(milliseconds: 25),
      (_) => sendCancel(),
    );
    Completer<void>? released;
    Future<void>? lease;
    var leaseStarted = false;
    Timer? watchdog;
    var leaseTimedOut = false;
    Map<String, dynamic>? terminal;
    Object? leaseError;
    try {
      sendCancel();
      await for (final line
          in process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        final event = jsonDecode(line) as Map<String, dynamic>;
        switch (event['event']) {
          case 'write_requested':
            sendCancel();
            if (released != null) {
              throw const FormatException(
                'Collector requested overlapping writes.',
              );
            }
            final release = Completer<void>();
            released = release;
            leaseStarted = false;
            lease =
                write(() async {
                  // A request withdrawn before the queue reached it.
                  if (release.isCompleted) return;
                  leaseStarted = true;
                  watchdog = Timer(leaseTimeout, () {
                    leaseTimedOut = true;
                    process.kill();
                    if (!release.isCompleted) release.complete();
                  });
                  await stdin.send('grant');
                  await release.future;
                  watchdog?.cancel();
                }).catchError((Object error) {
                  leaseError = error;
                  process.kill();
                });
          case 'write_released':
            final release = released;
            released = null;
            if (release != null && !release.isCompleted) release.complete();
            // A granted lease ends with the collector's write; a withdrawn
            // request must not wait for the writer queue to reach it.
            if (leaseStarted) await lease;
            lease = null;
          case 'progress':
            onProgress(
              event['counts'] as Map<String, dynamic>,
              event['sessions_written'] as int,
            );
            sendCancel();
          case 'finished':
            terminal = event;
          default:
            throw FormatException('Unknown collector event: ${event['event']}');
        }
      }
      final exit = await process.exitCode;
      final stderr = await errors;
      if (leaseTimedOut) throw CollectorLeaseTimeoutException(leaseTimeout);
      if (leaseError != null) {
        throw StateError('Collector writer failed: $leaseError');
      }
      if (exit != 0) {
        throw StateError('Collector exited with code $exit. $stderr');
      }
      if (terminal == null) {
        throw const FormatException('Collector exited without a scan result.');
      }
      return terminal;
    } finally {
      cancelPoll.cancel();
      watchdog?.cancel();
      final release = released;
      if (release != null && !release.isCompleted) release.complete();
      if (leaseStarted) await lease;
      await stdin.close();
      // On malformed output or a UI callback failure, the owning process must
      // not keep writing after the controller reports failure.
      process.kill();
      await process.exitCode;
      await errors;
    }
  }

  static int _sum(List<Map<String, dynamic>> reports, String key) =>
      reports.fold(0, (sum, report) => sum + (report[key] as int? ?? 0));

  static ScanProgress _progress(
    List<Map<String, dynamic>> counts,
    DateTime started,
  ) => ScanProgress(startedAtUtc: started)
    ..directoriesScanned = _sum(counts, 'directories_scanned')
    ..filesFound = _sum(counts, 'files_found')
    ..filesSkipped = _sum(counts, 'files_skipped')
    ..filesParsed = _sum(counts, 'files_parsed')
    ..filesFailed = _sum(counts, 'files_failed')
    ..sessionsMissing = _sum(counts, 'sessions_missing');
}

/// Writes lines to a process's stdin one at a time. Write and pipe errors
/// (the collector exited) end the stream quietly; the exit code and stdout
/// decide the outcome.
class _LineWriter {
  _LineWriter(this._sink) {
    unawaited(_sink.done.then<void>((_) {}, onError: (Object _) {}));
  }

  final IOSink _sink;
  Future<void> _tail = Future.value();
  var _failed = false;

  Future<void> send(String line) => _tail = _tail.then((_) async {
    if (_failed) return;
    try {
      _sink.writeln(line);
      await _sink.flush();
    } on Object {
      _failed = true;
    }
  });

  Future<void> close() => _tail = _tail.then((_) async {
    try {
      await _sink.close();
    } on Object {
      // Closing a pipe the collector already closed reports the error again.
    }
  });
}
