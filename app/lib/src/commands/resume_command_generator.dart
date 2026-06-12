// ignore_for_file: prefer_initializing_formals

import 'package:codex_sessions_viewer/src/config/app_settings.dart';

enum ResumeSessionSourceType { windows, wsl }

class ResumeCommandSession {
  const ResumeCommandSession({
    required this.sessionId,
    required this.sourceType,
    required this.workingDirectory,
  });

  final String sessionId;
  final ResumeSessionSourceType sourceType;
  final String workingDirectory;
}

class ResumeCommandGenerator {
  const ResumeCommandGenerator({required this.settings});

  final AppSettings settings;

  ResumeCommandSet build(ResumeCommandSession session) {
    final sessionId = session.sessionId.trim();
    if (sessionId.isEmpty) {
      return const ResumeCommandSet.unavailable(
        disabledReason:
            'Resume unavailable: this session has no parsed Codex session ID.',
      );
    }
    if (!_isSafeSessionId(sessionId)) {
      return const ResumeCommandSet.unavailable(
        disabledReason:
            'Resume unavailable: invalid Codex session ID for command generation.',
      );
    }

    final plainCommand = 'codex resume $sessionId';
    final bashResumeCommand = _bashCommand(['codex', 'resume', sessionId]);
    final platformCommand = _platformCommand(session, plainCommand);
    final terminalCommand = _terminalCommand(
      settings.terminal.defaultTerminal,
      session,
      plainCommand,
      bashResumeCommand,
    );

    return ResumeCommandSet(
      plainResumeCommand: plainCommand,
      platformResumeCommand: platformCommand,
      defaultTerminalProfile: settings.terminal.defaultTerminal,
      terminalLaunchCommand: terminalCommand.command,
      terminalDisabledReason: terminalCommand.disabledReason,
      terminalLaunchCommandFor: (profileName) => _terminalCommand(
        profileName,
        session,
        plainCommand,
        bashResumeCommand,
      ).command,
    );
  }

  String? _platformCommand(ResumeCommandSession session, String plainCommand) {
    final bashResumeCommand = _bashCommand([
      'codex',
      'resume',
      session.sessionId.trim(),
    ]);
    return switch (session.sourceType) {
      ResumeSessionSourceType.windows => plainCommand,
      ResumeSessionSourceType.wsl =>
        _hasUnsafeShellActiveChars(settings.wsl.distro) ||
                _hasUnsafeShellActiveChars(session.workingDirectory)
            ? null
            : 'wsl.exe -d ${_quoteWindowsArg(settings.wsl.distro)} '
                  '--cd ${_quoteWindowsArg(session.workingDirectory)} '
                  'bash -lc ${_quoteWindowsArg(bashResumeCommand)}',
    };
  }

  _TerminalCommand _terminalCommand(
    String profileName,
    ResumeCommandSession session,
    String plainCommand,
    String bashResumeCommand,
  ) {
    final profile = settings.terminal.profiles[profileName];
    if (profile == null || !profile.enabled || profile.exe.trim().isEmpty) {
      return _TerminalCommand.disabled(
        'Terminal profile is disabled or missing: $profileName.',
      );
    }

    final template = switch (session.sourceType) {
      ResumeSessionSourceType.windows => profile.windowsCommand,
      ResumeSessionSourceType.wsl => profile.wslCommand,
    };
    if (template.trim().isEmpty) {
      return _TerminalCommand.disabled(
        'Terminal profile command template is missing: $profileName.',
      );
    }
    if (_hasUnsafeShellActiveChars(profile.exe) ||
        _hasUnsafeShellActiveChars(session.workingDirectory) ||
        (session.sourceType == ResumeSessionSourceType.wsl &&
            _hasUnsafeShellActiveChars(settings.wsl.distro))) {
      return const _TerminalCommand.disabled(
        'Terminal command contains unsafe shell-active characters.',
      );
    }

    final resumeCommand = switch (session.sourceType) {
      ResumeSessionSourceType.windows => plainCommand,
      ResumeSessionSourceType.wsl => bashResumeCommand,
    };
    return _TerminalCommand(
      command: _expandTemplate(template, {
        'terminal_exe': _quoteWindowsArg(profile.exe),
        'working_dir': _quoteWindowsArg(session.workingDirectory),
        'wsl_distro': _quoteWindowsArg(settings.wsl.distro),
        'wsl_working_dir': _quoteWindowsArg(session.workingDirectory),
        'resume_command': _quoteWindowsArg(resumeCommand),
      }),
    );
  }
}

class ResumeCommandSet {
  const ResumeCommandSet({
    required this.plainResumeCommand,
    required this.platformResumeCommand,
    required this.defaultTerminalProfile,
    required this.terminalLaunchCommand,
    required this.terminalDisabledReason,
    required String? Function(String profileName) terminalLaunchCommandFor,
  }) : disabledReason = null,
       _terminalLaunchCommandFor = terminalLaunchCommandFor;

  const ResumeCommandSet.unavailable({required this.disabledReason})
    : plainResumeCommand = null,
      platformResumeCommand = null,
      defaultTerminalProfile = null,
      terminalLaunchCommand = null,
      terminalDisabledReason = null,
      _terminalLaunchCommandFor = null;

  final String? disabledReason;
  final String? plainResumeCommand;
  final String? platformResumeCommand;
  final String? defaultTerminalProfile;
  final String? terminalLaunchCommand;
  final String? terminalDisabledReason;
  final String? Function(String profileName)? _terminalLaunchCommandFor;

  bool get canResume => disabledReason == null;

  String? terminalLaunchCommandFor(String profileName) =>
      _terminalLaunchCommandFor?.call(profileName);
}

class _TerminalCommand {
  const _TerminalCommand({required this.command}) : disabledReason = null;

  const _TerminalCommand.disabled(this.disabledReason) : command = null;

  final String? command;
  final String? disabledReason;
}

String _quoteWindowsArg(String value) {
  if (value.isEmpty) {
    return '""';
  }
  if (!RegExp(r'''[\s'"&|<>^%!;]''').hasMatch(value)) {
    return value;
  }
  final buffer = StringBuffer('"');
  var backslashes = 0;
  for (final codeUnit in value.codeUnits) {
    final char = String.fromCharCode(codeUnit);
    if (char == '\\') {
      backslashes++;
      continue;
    }
    if (char == '"') {
      buffer
        ..write(_repeatBackslash(backslashes * 2 + 1))
        ..write('"');
      backslashes = 0;
      continue;
    }
    if (backslashes > 0) {
      buffer.write(_repeatBackslash(backslashes));
      backslashes = 0;
    }
    buffer.write(char);
  }
  if (backslashes > 0) {
    buffer.write(_repeatBackslash(backslashes * 2));
  }
  buffer.write('"');
  return buffer.toString();
}

String _repeatBackslash(int count) => List.filled(count, '\\').join();

bool _isSafeSessionId(String sessionId) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]*$').hasMatch(sessionId);

bool _hasUnsafeShellActiveChars(String value) =>
    RegExp(r'["$`\r\n]').hasMatch(value);

String _bashCommand(List<String> args) => args.map(_quoteBashArg).join(' ');

String _quoteBashArg(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

String _expandTemplate(String template, Map<String, String> values) {
  var result = template;
  for (final entry in values.entries) {
    result = result.replaceAll('{${entry.key}}', entry.value);
  }
  return result;
}
