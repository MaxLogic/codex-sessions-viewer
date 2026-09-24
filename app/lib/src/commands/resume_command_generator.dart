// ignore_for_file: prefer_initializing_formals

import 'package:codex_sessions_viewer/src/config/app_settings.dart';

enum ResumeSessionSourceType { windows, wsl }

class ResumeCommandSession {
  const ResumeCommandSession({
    required this.sessionId,
    required this.sourceType,
    required this.workingDirectory,
    this.harness = 'codex',
  });

  final String sessionId;
  final ResumeSessionSourceType sourceType;
  final String workingDirectory;
  final String harness;
}

class ResumeCommandGenerator {
  const ResumeCommandGenerator({required this.settings});

  final AppSettings settings;

  ResumeCommandSet build(ResumeCommandSession session) {
    final harness = session.harness.trim().toLowerCase();
    final harnessLabel = harness == 'claude' ? 'Claude Code' : 'Codex';
    if (harness != 'codex' && harness != 'claude') {
      return ResumeCommandSet.unavailable(
        disabledReason:
            'Resume unavailable: unsupported harness ${session.harness}.',
      );
    }
    final sessionId = session.sessionId.trim();
    if (sessionId.isEmpty) {
      return ResumeCommandSet.unavailable(
        disabledReason:
            'Resume unavailable: this session has no parsed $harnessLabel session ID.',
      );
    }
    if (!_isSafeSessionId(sessionId)) {
      return ResumeCommandSet.unavailable(
        disabledReason:
            'Resume unavailable: invalid $harnessLabel session ID for command generation.',
      );
    }

    // Terminal profiles start in the session folder, so they run the bare
    // command. Claude Code looks sessions up per project folder, so copied
    // commands change to that folder first.
    final bareCommand = harness == 'claude'
        ? 'claude --resume $sessionId'
        : _plainCodexCommand('resume', sessionId);
    final plainCommand = harness == 'claude'
        ? _inWorkingDirectory(session, bareCommand)
        : bareCommand;
    final plainForkCommand = _plainCodexCommand('fork', sessionId);
    final bashResumeCommand = harness == 'claude'
        ? _bashCommand(['claude', '--resume', sessionId])
        : _bashCodexCommand('resume', sessionId);
    final bashForkCommand = _bashCodexCommand('fork', sessionId);
    final platformCommand = _platformCommand(
      session,
      plainCommand,
      bashResumeCommand,
    );
    final platformForkCommand = _platformCommand(
      session,
      plainForkCommand,
      bashForkCommand,
    );
    final terminalCommand = _terminalCommand(
      settings.terminal.defaultTerminal,
      session,
      bareCommand,
      bashResumeCommand,
    );
    final terminalForkCommand = _terminalCommand(
      settings.terminal.defaultTerminal,
      session,
      plainForkCommand,
      bashForkCommand,
    );

    return ResumeCommandSet(
      plainResumeCommand: plainCommand,
      plainForkCommand: harness == 'codex' ? plainForkCommand : null,
      platformResumeCommand: platformCommand,
      platformForkCommand: harness == 'codex' ? platformForkCommand : null,
      defaultTerminalProfile: settings.terminal.defaultTerminal,
      terminalLaunchCommand: terminalCommand.command,
      terminalForkCommand: harness == 'codex'
          ? terminalForkCommand.command
          : null,
      terminalLaunchSpec: terminalCommand.launchSpec,
      terminalForkLaunchSpec: harness == 'codex'
          ? terminalForkCommand.launchSpec
          : null,
      terminalDisabledReason: terminalCommand.disabledReason,
      terminalLaunchCommandFor: (profileName) => _terminalCommand(
        profileName,
        session,
        bareCommand,
        bashResumeCommand,
      ).command,
    );
  }

  /// Prefixes a folder change that works in cmd.exe and PowerShell 7
  /// (`pushd`) for Windows sessions, or in bash for WSL sessions. Without a
  /// folder that can be quoted safely the bare command is returned.
  String _inWorkingDirectory(ResumeCommandSession session, String command) {
    final folder = session.workingDirectory.trim();
    if (folder.isEmpty || _hasUnsafeShellActiveChars(folder)) {
      return command;
    }
    return switch (session.sourceType) {
      // cmd.exe expands %NAME% even inside double quotes.
      ResumeSessionSourceType.windows =>
        folder.contains('%') ? command : 'pushd "$folder" && $command',
      ResumeSessionSourceType.wsl => 'cd ${_quoteBashArg(folder)} && $command',
    };
  }

  String? _platformCommand(
    ResumeCommandSession session,
    String plainCommand,
    String bashCommand,
  ) {
    return switch (session.sourceType) {
      ResumeSessionSourceType.windows => plainCommand,
      ResumeSessionSourceType.wsl =>
        _hasUnsafeShellActiveChars(settings.wsl.distro) ||
                _hasUnsafeShellActiveChars(session.workingDirectory)
            ? null
            : 'wsl.exe -d ${_quoteWindowsArg(settings.wsl.distro)} '
                  '--cd ${_quoteWindowsArg(session.workingDirectory)} '
                  'bash -lc ${_quoteWindowsArg(bashCommand)}',
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
    final rawValues = {
      'terminal_exe': profile.exe,
      'working_dir': session.workingDirectory,
      'wsl_distro': settings.wsl.distro,
      'wsl_working_dir': session.workingDirectory,
      'resume_command': resumeCommand,
    };
    final templateTokens = _splitCommandTemplate(template);
    if (templateTokens == null ||
        templateTokens.isEmpty ||
        templateTokens.first != '{terminal_exe}') {
      return _TerminalCommand.disabled(
        'Terminal profile command template cannot be launched safely: '
        '$profileName.',
      );
    }
    return _TerminalCommand(
      command: _expandTemplate(template, {
        'terminal_exe': _quoteWindowsArg(profile.exe),
        'working_dir': _quoteWindowsArg(session.workingDirectory),
        'wsl_distro': _quoteWindowsArg(settings.wsl.distro),
        'wsl_working_dir': _quoteWindowsArg(session.workingDirectory),
        'resume_command': _quoteWindowsArg(resumeCommand),
      }),
      launchSpec: TerminalLaunchSpec(
        executable: profile.exe,
        arguments: [
          for (final token in templateTokens.skip(1))
            _expandTemplate(token, rawValues),
        ],
      ),
    );
  }
}

class ResumeCommandSet {
  const ResumeCommandSet({
    required this.plainResumeCommand,
    required this.plainForkCommand,
    required this.platformResumeCommand,
    required this.platformForkCommand,
    required this.defaultTerminalProfile,
    required this.terminalLaunchCommand,
    required this.terminalForkCommand,
    required this.terminalLaunchSpec,
    required this.terminalForkLaunchSpec,
    required this.terminalDisabledReason,
    required String? Function(String profileName) terminalLaunchCommandFor,
  }) : disabledReason = null,
       _terminalLaunchCommandFor = terminalLaunchCommandFor;

  const ResumeCommandSet.unavailable({required this.disabledReason})
    : plainResumeCommand = null,
      plainForkCommand = null,
      platformResumeCommand = null,
      platformForkCommand = null,
      defaultTerminalProfile = null,
      terminalLaunchCommand = null,
      terminalForkCommand = null,
      terminalLaunchSpec = null,
      terminalForkLaunchSpec = null,
      terminalDisabledReason = null,
      _terminalLaunchCommandFor = null;

  final String? disabledReason;
  final String? plainResumeCommand;
  final String? plainForkCommand;
  final String? platformResumeCommand;
  final String? platformForkCommand;
  final String? defaultTerminalProfile;
  final String? terminalLaunchCommand;
  final String? terminalForkCommand;
  final TerminalLaunchSpec? terminalLaunchSpec;
  final TerminalLaunchSpec? terminalForkLaunchSpec;
  final String? terminalDisabledReason;
  final String? Function(String profileName)? _terminalLaunchCommandFor;

  bool get canResume => disabledReason == null;

  String? terminalLaunchCommandFor(String profileName) =>
      _terminalLaunchCommandFor?.call(profileName);
}

class _TerminalCommand {
  const _TerminalCommand({required this.command, required this.launchSpec})
    : disabledReason = null;

  const _TerminalCommand.disabled(this.disabledReason)
    : command = null,
      launchSpec = null;

  final String? command;
  final TerminalLaunchSpec? launchSpec;
  final String? disabledReason;
}

class TerminalLaunchSpec {
  const TerminalLaunchSpec({required this.executable, required this.arguments});

  final String executable;
  final List<String> arguments;

  @override
  bool operator ==(Object other) =>
      other is TerminalLaunchSpec &&
      executable == other.executable &&
      _listEquals(arguments, other.arguments);

  @override
  int get hashCode => Object.hash(executable, Object.hashAll(arguments));
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

String _plainCodexCommand(String action, String sessionId) =>
    'codex $action $sessionId';

String _bashCodexCommand(String action, String sessionId) =>
    _bashCommand(['codex', action, sessionId]);

String _quoteBashArg(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

String _expandTemplate(String template, Map<String, String> values) {
  var result = template;
  for (final entry in values.entries) {
    result = result.replaceAll('{${entry.key}}', entry.value);
  }
  return result;
}

List<String>? _splitCommandTemplate(String template) {
  final result = <String>[];
  final token = StringBuffer();
  String? quote;
  void finishToken() {
    if (token.isNotEmpty) {
      result.add(token.toString());
      token.clear();
    }
  }

  for (final rune in template.runes) {
    final char = String.fromCharCode(rune);
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        token.write(char);
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (RegExp(r'\s').hasMatch(char)) {
      finishToken();
      continue;
    }
    token.write(char);
  }
  if (quote != null) {
    return null;
  }
  finishToken();
  return result;
}

bool _listEquals(List<String> left, List<String> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) {
      return false;
    }
  }
  return true;
}
