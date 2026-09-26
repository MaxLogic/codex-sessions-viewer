import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config/default_session_folders.dart';

/// Finds the host's default WSL distribution for first-run settings.
abstract interface class WslDefaultDistroDetector {
  factory WslDefaultDistroDetector.forCurrentPlatform() => Platform.isWindows
      ? const WindowsWslDefaultDistroDetector()
      : const NoWslDefaultDistroDetector();

  /// The default distribution, or null when WSL is absent or unusable.
  Future<WslDistroDefaults?> detect();
}

/// Platforms without WSL, and callers that must not start a WSL process.
final class NoWslDefaultDistroDetector implements WslDefaultDistroDetector {
  const NoWslDefaultDistroDetector();

  @override
  Future<WslDistroDefaults?> detect() async => null;
}

/// Asks the default distribution for its name and the default user's home.
/// This may start the WSL VM, so it runs only when a settings file is first
/// created, and gives up after [timeout].
final class WindowsWslDefaultDistroDetector
    implements WslDefaultDistroDetector {
  const WindowsWslDefaultDistroDetector({
    this.timeout = const Duration(seconds: 10),
  });

  final Duration timeout;

  @override
  Future<WslDistroDefaults?> detect() async {
    final Process process;
    try {
      process = await Process.start('wsl.exe', [
        '--exec',
        'printenv',
        'WSL_DISTRO_NAME',
        'HOME',
      ]);
    } on ProcessException {
      return null;
    }
    unawaited(process.stderr.drain<void>());
    final output = process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .join();
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      return exitCode == 0 ? WslDistroDefaults.parse(await output) : null;
    } on TimeoutException {
      process.kill();
      return null;
    }
  }
}
