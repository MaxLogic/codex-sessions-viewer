import 'package:codex_sessions_viewer/src/commands/resume_command_generator.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generates plain and Windows terminal commands with safe quoting', () {
    final commands = ResumeCommandGenerator(settings: _settings()).build(
      const ResumeCommandSession(
        sessionId: 'abc123',
        sourceType: ResumeSessionSourceType.windows,
        workingDirectory: r'C:\Projects\Client App',
      ),
    );

    expect(commands.canResume, isTrue);
    expect(commands.disabledReason, isNull);
    expect(commands.plainResumeCommand, 'codex resume abc123');
    expect(commands.plainForkCommand, 'codex fork abc123');
    expect(commands.platformResumeCommand, 'codex resume abc123');
    expect(commands.platformForkCommand, 'codex fork abc123');
    expect(
      commands.terminalLaunchCommand,
      r'"C:\Program Files\Alacritty\alacritty.exe" --working-directory "C:\Projects\Client App" -e powershell.exe -NoExit -Command "codex resume abc123"',
    );
    expect(
      commands.terminalForkCommand,
      r'"C:\Program Files\Alacritty\alacritty.exe" --working-directory "C:\Projects\Client App" -e powershell.exe -NoExit -Command "codex fork abc123"',
    );
    expect(
      commands.terminalLaunchSpec,
      const TerminalLaunchSpec(
        executable: r'C:\Program Files\Alacritty\alacritty.exe',
        arguments: [
          '--working-directory',
          r'C:\Projects\Client App',
          '-e',
          'powershell.exe',
          '-NoExit',
          '-Command',
          'codex resume abc123',
        ],
      ),
    );
    expect(
      commands.terminalLaunchCommandFor('windows_terminal'),
      r'wt.exe -d "C:\Projects\Client App" powershell.exe -NoExit -Command "codex resume abc123"',
    );
  });

  test('generates WSL platform and terminal commands with distro and Linux cwd', () {
    final commands = ResumeCommandGenerator(settings: _settings()).build(
      const ResumeCommandSession(
        sessionId: 'abc123',
        sourceType: ResumeSessionSourceType.wsl,
        workingDirectory: '/home/pawel/project with spaces',
      ),
    );

    expect(
      commands.platformResumeCommand,
      'wsl.exe -d Ubuntu --cd "/home/pawel/project with spaces" bash -lc "\'codex\' \'resume\' \'abc123\'"',
    );
    expect(
      commands.platformForkCommand,
      'wsl.exe -d Ubuntu --cd "/home/pawel/project with spaces" bash -lc "\'codex\' \'fork\' \'abc123\'"',
    );
    expect(
      commands.terminalLaunchCommand,
      r'''"C:\Program Files\Alacritty\alacritty.exe" -e wsl.exe -d Ubuntu --cd "/home/pawel/project with spaces" bash -lc "'codex' 'resume' 'abc123'"''',
    );
    expect(
      commands.terminalLaunchCommandFor('windows_terminal'),
      'wt.exe wsl.exe -d Ubuntu --cd "/home/pawel/project with spaces" bash -lc "\'codex\' \'resume\' \'abc123\'"',
    );
  });

  test('disables resume variants when no parsed session id is available', () {
    final commands = ResumeCommandGenerator(settings: _settings()).build(
      const ResumeCommandSession(
        sessionId: '',
        sourceType: ResumeSessionSourceType.windows,
        workingDirectory: r'C:\Projects\App',
      ),
    );

    expect(commands.canResume, isFalse);
    expect(
      commands.disabledReason,
      'Resume unavailable: this session has no parsed Codex session ID.',
    );
    expect(commands.plainResumeCommand, isNull);
    expect(commands.plainForkCommand, isNull);
    expect(commands.platformResumeCommand, isNull);
    expect(commands.platformForkCommand, isNull);
    expect(commands.terminalLaunchCommand, isNull);
    expect(commands.terminalForkCommand, isNull);
  });

  test('reports disabled terminal profiles without disabling plain resume', () {
    final settings = _settings().copyWith(
      terminal: const TerminalSettings(
        defaultTerminal: 'alacritty',
        profiles: {
          'alacritty': TerminalProfileSettings(enabled: false, exe: ''),
        },
      ),
    );
    final commands = ResumeCommandGenerator(settings: settings).build(
      const ResumeCommandSession(
        sessionId: 'abc123',
        sourceType: ResumeSessionSourceType.windows,
        workingDirectory: r'C:\Projects\App',
      ),
    );

    expect(commands.canResume, isTrue);
    expect(commands.plainResumeCommand, 'codex resume abc123');
    expect(commands.terminalLaunchCommand, isNull);
    expect(
      commands.terminalDisabledReason,
      'Terminal profile is disabled or missing: alacritty.',
    );
  });

  test('rejects unsafe session ids instead of embedding shell syntax', () {
    final commands = ResumeCommandGenerator(settings: _settings()).build(
      const ResumeCommandSession(
        sessionId: r'abc$(touch /tmp/pwned); Write-Output injected',
        sourceType: ResumeSessionSourceType.windows,
        workingDirectory: r'C:\Projects\App',
      ),
    );

    expect(commands.canResume, isFalse);
    expect(commands.disabledReason, contains('invalid Codex session ID'));
    expect(commands.plainResumeCommand, isNull);
  });

  test('quotes shell metacharacters in Windows paths and WSL distro names', () {
    final settings = _settings().copyWith(
      wsl: const WslSettings(
        distro: 'Ubuntu Dev & Test',
        linuxHome: '/home/pawel',
        linuxRootUnc: r'\\wsl.localhost\Ubuntu Dev & Test\',
      ),
      terminal: const TerminalSettings(
        defaultTerminal: 'alacritty',
        profiles: {
          'alacritty': TerminalProfileSettings(
            enabled: true,
            exe: r'C:\Tools & Apps\Alacritty\',
            windowsCommand:
                '{terminal_exe} --working-directory {working_dir} -e powershell.exe -NoExit -Command {resume_command}',
            wslCommand:
                '{terminal_exe} -e wsl.exe -d {wsl_distro} --cd {wsl_working_dir} bash -lc {resume_command}',
          ),
        },
      ),
    );
    final commands = ResumeCommandGenerator(settings: settings).build(
      const ResumeCommandSession(
        sessionId: 'abc-123_DEF',
        sourceType: ResumeSessionSourceType.wsl,
        workingDirectory: r'/home/pawel/App & Tools',
      ),
    );

    expect(
      commands.platformResumeCommand,
      'wsl.exe -d "Ubuntu Dev & Test" --cd "/home/pawel/App & Tools" bash -lc "\'codex\' \'resume\' \'abc-123_DEF\'"',
    );
    expect(
      commands.terminalLaunchCommand,
      r'''"C:\Tools & Apps\Alacritty\\" -e wsl.exe -d "Ubuntu Dev & Test" --cd "/home/pawel/App & Tools" bash -lc "'codex' 'resume' 'abc-123_DEF'"''',
    );
  });

  test('quotes apostrophes in WSL working directories', () {
    final commands = ResumeCommandGenerator(settings: _settings()).build(
      const ResumeCommandSession(
        sessionId: 'abc123',
        sourceType: ResumeSessionSourceType.wsl,
        workingDirectory: "/home/pawel/O'Brien",
      ),
    );

    expect(
      commands.platformResumeCommand,
      'wsl.exe -d Ubuntu --cd "/home/pawel/O\'Brien" bash -lc "\'codex\' \'resume\' \'abc123\'"',
    );
  });

  test('uses configured terminal command templates for custom profiles', () {
    final settings = _settings().copyWith(
      terminal: const TerminalSettings(
        defaultTerminal: 'custom',
        profiles: {
          'custom': TerminalProfileSettings(
            enabled: true,
            exe: r'C:\Terminals\custom.exe',
            windowsCommand:
                '{terminal_exe} /dir {working_dir} /run {resume_command}',
            wslCommand:
                '{terminal_exe} /wsl {wsl_distro} {wsl_working_dir} {resume_command}',
          ),
        },
      ),
    );
    final commands = ResumeCommandGenerator(settings: settings).build(
      const ResumeCommandSession(
        sessionId: 'abc123',
        sourceType: ResumeSessionSourceType.windows,
        workingDirectory: r'C:\Projects\App',
      ),
    );

    expect(
      commands.terminalLaunchCommand,
      r'C:\Terminals\custom.exe /dir C:\Projects\App /run "codex resume abc123"',
    );
  });

  test('quotes Windows paths with trailing slash and shell metacharacters', () {
    final commands = ResumeCommandGenerator(settings: _settings()).build(
      const ResumeCommandSession(
        sessionId: 'abc123',
        sourceType: ResumeSessionSourceType.windows,
        workingDirectory: r'C:\Projects\App & Tools\',
      ),
    );

    expect(
      commands.terminalLaunchCommand,
      r'"C:\Program Files\Alacritty\alacritty.exe" --working-directory "C:\Projects\App & Tools\\" -e powershell.exe -NoExit -Command "codex resume abc123"',
    );
  });

  test('disables terminal launch for PowerShell-active path values', () {
    final commands = ResumeCommandGenerator(settings: _settings()).build(
      const ResumeCommandSession(
        sessionId: 'abc123',
        sourceType: ResumeSessionSourceType.windows,
        workingDirectory: r'C:\Projects\$(calc)',
      ),
    );

    expect(commands.canResume, isTrue);
    expect(commands.plainResumeCommand, 'codex resume abc123');
    expect(commands.terminalLaunchCommand, isNull);
    expect(
      commands.terminalDisabledReason,
      'Terminal command contains unsafe shell-active characters.',
    );
  });

  test('disables terminal launch for unsafe terminal profile values', () {
    final settings = _settings().copyWith(
      terminal: const TerminalSettings(
        defaultTerminal: 'alacritty',
        profiles: {
          'alacritty': TerminalProfileSettings(
            enabled: true,
            exe: r'C:\Tools\`evil`.exe',
            windowsCommand:
                '{terminal_exe} --working-directory {working_dir} -e powershell.exe -NoExit -Command {resume_command}',
            wslCommand:
                '{terminal_exe} -e wsl.exe -d {wsl_distro} --cd {wsl_working_dir} bash -lc {resume_command}',
          ),
        },
      ),
    );
    final commands = ResumeCommandGenerator(settings: settings).build(
      const ResumeCommandSession(
        sessionId: 'abc123',
        sourceType: ResumeSessionSourceType.windows,
        workingDirectory: r'C:\Projects\App',
      ),
    );

    expect(commands.terminalLaunchCommand, isNull);
    expect(
      commands.terminalDisabledReason,
      'Terminal command contains unsafe shell-active characters.',
    );
  });

  test('disables WSL platform and terminal commands for quoted paths', () {
    final commands = ResumeCommandGenerator(settings: _settings()).build(
      const ResumeCommandSession(
        sessionId: 'abc123',
        sourceType: ResumeSessionSourceType.wsl,
        workingDirectory: r'/home/pawel/Quoted "Project"',
      ),
    );

    expect(commands.canResume, isTrue);
    expect(commands.plainResumeCommand, 'codex resume abc123');
    expect(commands.platformResumeCommand, isNull);
    expect(commands.terminalLaunchCommand, isNull);
    expect(
      commands.terminalDisabledReason,
      'Terminal command contains unsafe shell-active characters.',
    );
  });
}

AppSettings _settings() => AppSettings.defaults().copyWith(
  terminal: const TerminalSettings(
    defaultTerminal: 'alacritty',
    profiles: {
      'alacritty': TerminalProfileSettings(
        enabled: true,
        exe: r'C:\Program Files\Alacritty\alacritty.exe',
        windowsCommand:
            '{terminal_exe} --working-directory {working_dir} -e powershell.exe -NoExit -Command {resume_command}',
        wslCommand:
            '{terminal_exe} -e wsl.exe -d {wsl_distro} --cd {wsl_working_dir} bash -lc {resume_command}',
      ),
      'windows_terminal': TerminalProfileSettings(
        enabled: true,
        exe: 'wt.exe',
        windowsCommand:
            '{terminal_exe} -d {working_dir} powershell.exe -NoExit -Command {resume_command}',
        wslCommand:
            '{terminal_exe} wsl.exe -d {wsl_distro} --cd {wsl_working_dir} bash -lc {resume_command}',
      ),
    },
  ),
);
