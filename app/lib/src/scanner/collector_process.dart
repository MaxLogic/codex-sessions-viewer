import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../platform/app_locations.dart';
import '../platform/app_environment.dart';

/// Starts the collector; tests substitute a scripted process.
typedef CollectorProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

Future<Process> startCollectorProcess(
  String executable,
  List<String> arguments,
) => AppEnvironment.start(executable, arguments);

/// The collector executable is missing or cannot run.
class CollectorUnavailableException implements Exception {
  const CollectorUnavailableException(this.executable, this.reason);

  final String executable;
  final String reason;

  static const recoveryMessage =
      'Session collection could not start. Saved sessions are still shown. Reinstall Codex Sessions Viewer to restore session collection.';

  @override
  String toString() =>
      'The session collector could not be started. Expected '
      '${p.basename(executable)} at $executable. Reinstall Codex Sessions '
      'Viewer so the collector sits next to the viewer, or set '
      'CODEX_SESSIONS_COLLECTOR_EXE to its location. ($reason)';
}

/// The installed collector is the only writer of parsed session state.
class CollectorProcess {
  CollectorProcess({String? executable, CollectorProcessStarter? start})
    : executable = executable ?? defaultExecutable(),
      _start = start ?? startCollectorProcess;

  /// The collector that sits next to the viewer, or the one named by
  /// `CODEX_SESSIONS_COLLECTOR_EXE`.
  static String defaultExecutable({
    AppHostPlatform? hostPlatform,
    Map<String, String>? environment,
    String? viewerExecutable,
  }) {
    final platform = hostPlatform ?? AppLocations.currentPlatform;
    final variables = environment ?? AppEnvironment.current;
    final context = p.Context(
      style: platform == AppHostPlatform.windows
          ? p.Style.windows
          : p.Style.posix,
    );
    return variables['CODEX_SESSIONS_COLLECTOR_EXE'] ??
        context.join(
          context.dirname(viewerExecutable ?? Platform.resolvedExecutable),
          platform == AppHostPlatform.windows
              ? 'codex-sessions-collector.exe'
              : 'codex-sessions-collector',
        );
  }

  final String executable;
  final CollectorProcessStarter _start;

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
          'version': 2,
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
