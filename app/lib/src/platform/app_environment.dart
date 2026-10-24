import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:convert';

/// Scoped host inputs. Tests provide an environment and a launch admission
/// check; production uses the operating system without changing its process.
class AppEnvironment {
  static void Function()? _initializeChildIsolate;
  static Map<String, String>? _installedEnvironment;
  static ({
    void Function(String, List<String>, Map<String, String>, String) admit,
    String workingDirectory,
  })?
  _installedLaunch;

  /// Installs an isolate-local boundary before the test runner invokes callbacks.
  /// Test callbacks execute in runner-owned zones, outside registration zones.
  static void installTestBoundary({
    required Map<String, String> environment,
    required void Function(String, List<String>, Map<String, String>, String)
    admit,
    required String workingDirectory,
    void Function()? initializeChildIsolate,
  }) {
    _initializeChildIsolate = initializeChildIsolate;
    _installedEnvironment = environment;
    _installedLaunch = (admit: admit, workingDirectory: workingDirectory);
  }

  /// Preserve a test boundary across worker isolates; production has no initializer.
  static Future<T> runIsolate<T>(FutureOr<T> Function() computation) {
    final initialize =
        Zone.current[_initializerKey] as void Function()? ??
        _initializeChildIsolate;
    if (initialize == null) return Isolate.run(computation);
    return Isolate.run(() {
      initialize();
      return computation();
    });
  }

  static Future<Isolate> spawnIsolate<T>(
    void Function(T) entryPoint,
    T message, {
    bool paused = false,
    SendPort? onExit,
    SendPort? onError,
    bool errorsAreFatal = true,
    String? debugName,
  }) {
    final initialize =
        Zone.current[_initializerKey] as void Function()? ??
        _initializeChildIsolate;
    if (initialize == null) {
      return Isolate.spawn<T>(
        entryPoint,
        message,
        paused: paused,
        onExit: onExit,
        onError: onError,
        errorsAreFatal: errorsAreFatal,
        debugName: debugName,
      );
    }
    return Isolate.spawn<T>(
      (message) {
        initialize();
        entryPoint(message);
      },
      message,
      paused: paused,
      onExit: onExit,
      onError: onError,
      errorsAreFatal: errorsAreFatal,
      debugName: debugName,
    );
  }

  static final Object _initializerKey = Object();
  static final Object _environmentKey = Object();
  static final Object _launchKey = Object();

  static Map<String, String> get current =>
      Zone.current[_environmentKey] as Map<String, String>? ??
      _installedEnvironment ??
      Platform.environment;

  static T scoped<T>({
    required Map<String, String> environment,
    required void Function(String, List<String>, Map<String, String>, String)
    admit,
    required String workingDirectory,
    required T Function() body,
    void Function()? initializeChildIsolate,
  }) => runZoned(
    body,
    zoneValues: {
      _initializerKey: initializeChildIsolate,
      _environmentKey: environment,
      _launchKey: (admit: admit, workingDirectory: workingDirectory),
    },
  );

  static Future<Process> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
    bool runInShell = false,
    bool includeParentEnvironment = true,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    final scope =
        Zone.current[_launchKey]
            as ({
              void Function(String, List<String>, Map<String, String>, String)
              admit,
              String workingDirectory,
            })? ??
        _installedLaunch;
    final variables = <String, String>{};
    for (final source in [current, ?environment]) {
      for (final entry in source.entries) {
        variables[Platform.isWindows ? entry.key.toUpperCase() : entry.key] =
            entry.value;
      }
    }
    if (scope != null && runInShell) {
      throw StateError('Test profile isolation rejects shell execution');
    }
    final cwd = workingDirectory ?? scope?.workingDirectory;
    scope?.admit(executable, arguments, variables, cwd!);
    return Process.start(
      executable,
      arguments,
      environment: scope == null ? environment : variables,
      workingDirectory: cwd,
      runInShell: runInShell,
      includeParentEnvironment: scope == null && includeParentEnvironment,
      mode: mode,
    );
  }

  static Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
    bool runInShell = false,
    bool includeParentEnvironment = true,
    Encoding? stdoutEncoding = systemEncoding,
    Encoding? stderrEncoding = systemEncoding,
  }) async {
    if (Zone.current[_launchKey] == null && _installedLaunch == null) {
      return Process.run(
        executable,
        arguments,
        environment: environment,
        workingDirectory: workingDirectory,
        runInShell: runInShell,
        includeParentEnvironment: includeParentEnvironment,
        stdoutEncoding: stdoutEncoding,
        stderrEncoding: stderrEncoding,
      );
    }
    final process = await start(
      executable,
      arguments,
      environment: environment,
      workingDirectory: workingDirectory,
      runInShell: runInShell,
      includeParentEnvironment: includeParentEnvironment,
    );
    final output = process.stdout.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    final errors = process.stderr.fold<List<int>>(
      [],
      (all, part) => all..addAll(part),
    );
    await process.stdin.close();
    final exit = await process.exitCode;
    final out = await output;
    final err = await errors;
    return ProcessResult(
      process.pid,
      exit,
      stdoutEncoding?.decode(out) ?? out,
      stderrEncoding?.decode(err) ?? err,
    );
  }
}
