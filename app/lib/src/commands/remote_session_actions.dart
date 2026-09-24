import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../config/app_settings.dart';
import 'resume_command_generator.dart';

class RemoteActionEligibility {
  const RemoteActionEligibility({
    this.directory,
    this.resume,
    this.resumeReason,
    this.directoryReason,
  });
  final String? directory;
  final TerminalLaunchSpec? resume;
  final String? resumeReason;
  final String? directoryReason;
}

/// Resolve identity in this machine's database before trusting any remote path.
class RemoteSessionActions {
  RemoteSessionActions({
    required this.databaseFile,
    required this.settings,
    Future<bool> Function(String)? fileExists,
    Future<bool> Function(String)? directoryExists,
    Future<bool> Function(String, String?)? harnessAvailable,
  }) : fileExists = fileExists ?? ((path) => File(path).exists()),
       directoryExists =
           directoryExists ?? ((path) => Directory(path).exists()),
       harnessAvailable = harnessAvailable ?? _harnessAvailable;

  final File databaseFile;
  final AppSettings settings;
  final Future<bool> Function(String) fileExists;
  final Future<bool> Function(String) directoryExists;
  final Future<bool> Function(String, String?) harnessAvailable;

  Future<RemoteActionEligibility> inspect(
    Map<String, dynamic> remote, {
    String? explicitLocalMapping,
  }) async {
    String? mapped;
    if (explicitLocalMapping != null &&
        await directoryExists(explicitLocalMapping)) {
      mapped = explicitLocalMapping;
    }
    RemoteActionEligibility denied(String reason) => RemoteActionEligibility(
      directory: mapped,
      resumeReason: reason,
      directoryReason: mapped == null
          ? 'Choose an explicit existing local folder for this remote session.'
          : null,
    );
    if (!await databaseFile.exists()) {
      return denied('This machine has no local session database.');
    }
    final db = sqlite3.open(databaseFile.path, mode: OpenMode.readOnly);
    Map<String, Object?>? local;
    try {
      db.execute('pragma query_only = on');
      final identity = db.select(
        "select value from app_metadata where key = 'machine_id'",
      );
      if (identity.isEmpty || identity.first['value'] != remote['machine_id']) {
        return denied(
          'Resume is available only on the session’s original machine.',
        );
      }
      final rows = db.select(
        'select * from history_sessions where reference = ?',
        [remote['reference']],
      );
      if (rows.isEmpty) {
        return denied(
          'The session is not present in this machine’s local history.',
        );
      }
      local = Map<String, Object?>.from(rows.first);
    } catch (_) {
      return denied('The local session could not be verified.');
    } finally {
      db.close();
    }
    final source = local['source_file_path'] as String? ?? '';
    final environment = local['environment'] as String? ?? '';
    final harness = local['harness'] as String? ?? '';
    final isWsl = environment == 'wsl';
    final directory =
        (isWsl ? local['working_directory_platform'] : null) as String? ??
        local['working_directory'] as String? ??
        '';
    // The recorded UNC source determines the distro; never use a foreign or
    // current default distro merely because its Linux path happens to match.
    final distro = isWsl
        ? RegExp(
            r'^\\\\(?:wsl\.localhost|wsl\$)\\([^\\]+)\\',
            caseSensitive: false,
          ).firstMatch(source)?.group(1)
        : null;
    if (environment != 'windows' && !isWsl) {
      return denied('The recorded environment is unsupported.');
    }
    if (isWsl && (distro == null || distro != settings.wsl.distro)) {
      return denied(
        'The recorded WSL distribution is unavailable or differs from the configured distribution.',
      );
    }
    final openDirectory = isWsl && directory.startsWith('/') && distro != null
        ? '\\\\wsl.localhost\\$distro${directory.replaceAll('/', '\\')}'
        : directory;
    if (mapped == null && await directoryExists(openDirectory)) {
      mapped = openDirectory;
    }
    if (!await fileExists(source)) {
      return denied('The local session file no longer exists.');
    }
    if (!await directoryExists(openDirectory)) {
      return denied('The session’s local working directory no longer exists.');
    }
    if (!const ['codex', 'claude'].contains(harness) ||
        !await harnessAvailable(harness, distro)) {
      return denied(
        'The recorded harness is unavailable in the recorded environment.',
      );
    }
    final command = ResumeCommandGenerator(settings: settings).build(
      ResumeCommandSession(
        sessionId: local['session_id'] as String? ?? '',
        sourceType: isWsl
            ? ResumeSessionSourceType.wsl
            : ResumeSessionSourceType.windows,
        workingDirectory: directory,
        harness: harness,
      ),
    );
    return RemoteActionEligibility(
      directory: mapped,
      resume: command.terminalLaunchSpec,
      resumeReason: command.terminalDisabledReason,
      directoryReason: mapped == null
          ? 'The local folder is unavailable.'
          : null,
    );
  }

  static Future<bool> _harnessAvailable(String harness, String? distro) async {
    try {
      final result =
          await (distro == null
                  ? Process.run('where.exe', [harness])
                  : Process.run('wsl.exe', [
                      '-d',
                      distro,
                      '--',
                      'sh',
                      '-lc',
                      'command -v $harness',
                    ]))
              .timeout(const Duration(seconds: 5));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
