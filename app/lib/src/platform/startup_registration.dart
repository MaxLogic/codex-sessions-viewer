import 'package:codex_sessions_viewer/src/platform/app_environment.dart';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_locations.dart';
import 'windows_startup_registration.dart';

/// Registers this executable for the next user login without launching it now.
abstract interface class StartupRegistration {
  factory StartupRegistration.forCurrentPlatform({
    AppHostPlatform? platform,
    Map<String, String>? environment,
    String? executablePath,
    StartupProcessRunner? runProcess,
    File Function(String path)? fileForPath,
    Future<void> Function(File file, String content)? writeReplacementFile,
  }) {
    final host = platform ?? AppLocations.currentPlatform;
    if (host == AppHostPlatform.windows) {
      return WindowsStartupRegistration(
        executablePath: executablePath,
        isWindows: true,
        runProcess: runProcess,
      );
    }
    final env = environment ?? AppEnvironment.current;
    String home() {
      final value = env['HOME'] ?? '';
      if (!p.posix.isAbsolute(value)) {
        throw ArgumentError(
          'An absolute HOME is required for startup registration.',
        );
      }
      return value;
    }

    final String destination;
    if (host == AppHostPlatform.macos) {
      destination = p.posix.join(
        home(),
        'Library',
        'LaunchAgents',
        '${_FileStartupRegistration.identifier}.plist',
      );
    } else {
      final config = env['XDG_CONFIG_HOME'] ?? '';
      destination = p.posix.join(
        p.posix.isAbsolute(config) ? config : p.posix.join(home(), '.config'),
        'autostart',
        '${_FileStartupRegistration.identifier}.desktop',
      );
    }
    return _FileStartupRegistration(
      platform: host,
      executablePath: executablePath ?? Platform.resolvedExecutable,
      file: (fileForPath ?? File.new)(destination),
      writeReplacementFile: writeReplacementFile ?? _writeAndFlush,
    );
  }

  Future<void> apply({required bool enabled});
}

Future<void> _writeAndFlush(File file, String content) async {
  await file.writeAsString(content, flush: true);
}

class _FileStartupRegistration implements StartupRegistration {
  const _FileStartupRegistration({
    required this.platform,
    required this.executablePath,
    required this.file,
    required this.writeReplacementFile,
  });

  static const identifier = 'eu.maxlogic.codexsessionsviewer';
  final AppHostPlatform platform;
  final String executablePath;
  final File file;
  final Future<void> Function(File file, String content) writeReplacementFile;

  @override
  Future<void> apply({required bool enabled}) async {
    if (!enabled) {
      try {
        await file.delete();
      } on FileSystemException catch (error) {
        // Only suppress absence; permissions and other I/O failures must surface.
        if (error.osError?.errorCode != 2 && error.osError?.errorCode != 3) {
          rethrow;
        }
      }
      return;
    }
    if (!p.posix.isAbsolute(executablePath) ||
        executablePath.runes.any(
          (rune) =>
              rune < 32 ||
              rune == 127 ||
              (rune >= 0xd800 && rune <= 0xdfff) ||
              rune == 0xfffe ||
              rune == 0xffff,
        )) {
      throw ArgumentError(
        'Startup executable must be an absolute path without control characters.',
      );
    }
    final content = platform == AppHostPlatform.macos
        ? _launchAgent()
        : _desktopEntry();
    await file.parent.create(recursive: true);
    // A fresh file avoids truncating an unrelated hard-link or symlink target.
    // Rename replaces the owned entry, and refuses an existing directory.
    final stagingDirectory = await file.parent.createTemp('.startup-');
    final replacement = File(p.join(stagingDirectory.path, 'registration'));
    Object? operationError;
    try {
      await writeReplacementFile(replacement, content);
      await replacement.rename(file.path);
    } on Object catch (error) {
      operationError = error;
      rethrow;
    } finally {
      try {
        if (await replacement.exists()) await replacement.delete();
        await stagingDirectory.delete();
      } on FileSystemException {
        // A cleanup error must not replace the original write/rename failure.
        if (operationError == null) rethrow;
      }
    }
  }

  String _launchAgent() {
    final executable = const HtmlEscape(
      HtmlEscapeMode.element,
    ).convert(executablePath);
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$identifier</string>
  <key>ProgramArguments</key>
  <array><string>$executable</string></array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
''';
  }

  String _desktopEntry() {
    if (executablePath.contains('=')) {
      throw ArgumentError(
        'A desktop startup executable path cannot contain "=".',
      );
    }
    // Exec quoting is undone after desktop string escaping. Each layer needs
    // its own backslashes; percent signs must not become desktop field codes.
    final quoted = executablePath
        .replaceAllMapped(RegExp(r'["`$\\]'), (match) => '\\${match[0]}')
        .replaceAll('%', '%%');
    final value = '"$quoted"'.replaceAll(r'\', r'\\');
    return '[Desktop Entry]\nType=Application\nName=Codex Session Viewer\nExec=$value\nTerminal=false\n';
  }
}
