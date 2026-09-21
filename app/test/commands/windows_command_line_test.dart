import 'package:codex_sessions_viewer/src/commands/resume_command_generator.dart';
import 'package:codex_sessions_viewer/src/commands/windows_command_line.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('splits quoted program paths and arguments', () {
    expect(
      splitWindowsCommandLine(
        r'"C:\Program Files\Alacritty\alacritty.exe" -e wsl.exe --cd "/home/p a" bash -lc "codex resume abc"',
      ),
      [
        r'C:\Program Files\Alacritty\alacritty.exe',
        '-e',
        'wsl.exe',
        '--cd',
        '/home/p a',
        'bash',
        '-lc',
        'codex resume abc',
      ],
    );
  });

  test('follows backslash and quote escaping rules', () {
    expect(splitWindowsCommandLine(r'a\\b "c\"d" "e\\" f'), [
      r'a\\b',
      'c"d',
      r'e\',
      'f',
    ]);
    expect(splitWindowsCommandLine('"say ""hi"""'), ['say "hi"']);
    expect(splitWindowsCommandLine('x ""'), ['x', '']);
  });

  test('parsing a generated terminal command yields its launch spec', () {
    final generator = ResumeCommandGenerator(settings: AppSettings.defaults());
    for (final session in const [
      ResumeCommandSession(
        sessionId: 'abc123',
        sourceType: ResumeSessionSourceType.windows,
        workingDirectory: r'C:\Projects\Client App',
      ),
      ResumeCommandSession(
        sessionId: 'abc123',
        sourceType: ResumeSessionSourceType.wsl,
        workingDirectory: '/home/pawel/project with spaces',
      ),
    ]) {
      final commands = generator.build(session);
      expect(
        parseWindowsCommandLine(commands.terminalLaunchCommand!),
        commands.terminalLaunchSpec,
      );
    }
  });

  test('empty input has no launch spec', () {
    expect(parseWindowsCommandLine('   '), isNull);
    final spec = parseWindowsCommandLine('wt.exe -d .');
    expect(spec?.executable, 'wt.exe');
    expect(spec?.arguments, ['-d', '.']);
  });
}
