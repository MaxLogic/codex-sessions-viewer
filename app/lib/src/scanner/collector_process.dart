import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'session_scanner.dart';

/// The installed collector is the only writer of parsed session state.
class CollectorProcess {
  CollectorProcess({String? executable})
    : executable =
          executable ??
          Platform.environment['CODEX_SESSIONS_COLLECTOR_EXE'] ??
          p.join(
            p.dirname(Platform.resolvedExecutable),
            'codex-sessions-collector.exe',
          );

  final String executable;
  int persistenceFlushCount = 0;

  Future<void> applyProjectHints(
    File databaseFile,
    List<Map<String, Object?>> sessions,
    Map<String, String> hints,
  ) async {
    if (hints.isEmpty) return;
    final process = await Process.start(executable, [
      'apply',
      '--json',
      '--db',
      databaseFile.absolute.path,
    ]);
    final output = process.stdout.drain<void>();
    final errors = process.stderr.transform(utf8.decoder).join();
    process.stdin.writeln(
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
    );
    await process.stdin.close();
    final exit = await process.exitCode;
    await output;
    final stderr = await errors;
    if (exit != 0) {
      throw StateError('Collector project hints failed ($exit): $stderr');
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
    final result = await Process.run(executable, [
      harness,
      'ingest',
      '--json',
      '--settings',
      settingsFile.absolute.path,
      '--db',
      databaseFile.absolute.path,
      sourcePath,
    ], runInShell: false);
    if (result.exitCode != 0) {
      throw StateError(
        'Collector reparse failed (${result.exitCode}): ${result.stderr}',
      );
    }
  }

  Future<SessionScanResult> scan({
    required File settingsFile,
    required File databaseFile,
    required ScanCancellationToken cancellation,
    required Future<void> Function(Future<void> Function()) write,
    required void Function(ScanProgress, int) onProgress,
    int? parserWorkers,
    int flushSessions = 64,
    int flushBytes = 8 * 1024 * 1024,
  }) async {
    final started = DateTime.now().toUtc();
    final process = await Process.start(executable, [
      'codex',
      'scan',
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
    ], runInShell: false);
    // Drain stderr immediately so errors cannot fill the pipe and deadlock.
    final errors = process.stderr.transform(utf8.decoder).join();
    var cancelSent = false;
    void sendCancel() {
      if (!cancelSent && cancellation.isCancellationRequested) {
        cancelSent = true;
        process.stdin.writeln('cancel');
      }
    }

    final timer = Timer.periodic(
      const Duration(milliseconds: 25),
      (_) => sendCancel(),
    );
    Completer<void>? released;
    Future<void>? lease;
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
            lease =
                write(() async {
                  process.stdin.writeln('grant');
                  await process.stdin.flush();
                  await release.future;
                }).catchError((Object error) {
                  leaseError = error;
                  process.kill();
                });
          case 'write_released':
            released?.complete();
            released = null;
            await lease;
            lease = null;
          case 'progress':
            final counts = event['counts'] as Map<String, dynamic>;
            onProgress(
              _progress(counts, started),
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
      if (leaseError != null) {
        throw StateError('Collector writer failed: $leaseError');
      }
      if (exit != 0) {
        throw StateError('Collector exited with code $exit. $stderr');
      }
      if (terminal == null) {
        throw const FormatException('Collector exited without a scan result.');
      }
      final report = terminal;
      persistenceFlushCount = report['persistence_flushes'] as int;
      final cancelled = report['cancelled'] == true;
      final failures = [
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
      final progress = _progress(report, started)..finish(cancelled: cancelled);
      onProgress(progress, report['sessions_written'] as int);
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
    } finally {
      timer.cancel();
      if (released != null && !released.isCompleted) released.complete();
      await lease;
      await process.stdin.close();
      // On malformed output or a UI callback failure, the owning process must
      // not keep writing after the controller reports failure.
      process.kill();
      await process.exitCode;
      await errors;
    }
  }

  static ScanProgress _progress(
    Map<String, dynamic> counts,
    DateTime started,
  ) => ScanProgress(startedAtUtc: started)
    ..directoriesScanned = counts['directories_scanned'] as int
    ..filesFound = counts['files_found'] as int
    ..filesSkipped = counts['files_skipped'] as int
    ..filesParsed = counts['files_parsed'] as int
    ..filesFailed = counts['files_failed'] as int
    ..sessionsMissing = counts['sessions_missing'] as int;
}
