import 'dart:io';

typedef StartupProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class WindowsStartupRegistration {
  WindowsStartupRegistration({
    this.executablePath,
    bool? isWindows,
    StartupProcessRunner? runProcess,
  }) : _isWindows = isWindows ?? Platform.isWindows,
       _runProcess = runProcess ?? Process.run;

  static const runKey = r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const runValueName = 'Codex Session Viewer';

  final String? executablePath;
  final bool _isWindows;
  final StartupProcessRunner _runProcess;

  Future<void> apply({required bool enabled}) async {
    if (!_isWindows) {
      return;
    }
    if (enabled) {
      await _enable();
    } else {
      await _disable();
    }
  }

  Future<void> _enable() async {
    final result = await _runProcess('reg', [
      'add',
      runKey,
      '/v',
      runValueName,
      '/t',
      'REG_SZ',
      '/d',
      _quotedExecutablePath(executablePath ?? Platform.resolvedExecutable),
      '/f',
    ]);
    _throwIfFailed(result, 'enable Windows startup');
  }

  Future<void> _disable() async {
    final query = await _runProcess('reg', [
      'query',
      runKey,
      '/v',
      runValueName,
    ]);
    if (query.exitCode != 0) {
      return;
    }

    final result = await _runProcess('reg', [
      'delete',
      runKey,
      '/v',
      runValueName,
      '/f',
    ]);
    _throwIfFailed(result, 'disable Windows startup');
  }

  static String _quotedExecutablePath(String path) {
    if (path.contains('"')) {
      throw const WindowsStartupRegistrationException(
        operation: 'prepare Windows startup command',
        details: 'Executable path contains a double quote.',
      );
    }
    return '"$path"';
  }

  static void _throwIfFailed(ProcessResult result, String operation) {
    if (result.exitCode == 0) {
      return;
    }
    final stdout = result.stdout.toString().trim();
    final stderr = result.stderr.toString().trim();
    final details = [
      if (stdout.isNotEmpty) stdout,
      if (stderr.isNotEmpty) stderr,
    ].join('\n');
    throw WindowsStartupRegistrationException(
      operation: operation,
      details: details.isEmpty
          ? 'reg.exe exited with ${result.exitCode}.'
          : details,
    );
  }
}

class WindowsStartupRegistrationException implements Exception {
  const WindowsStartupRegistrationException({
    required this.operation,
    required this.details,
  });

  final String operation;
  final String details;

  @override
  String toString() => 'Could not $operation. $details';
}
