import 'dart:io';

import 'package:codex_sessions_viewer/src/commands/resume_command_generator.dart';
import 'package:codex_sessions_viewer/src/platform/terminal_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const alacritty = r'C:\Program Files\Alacritty\alacritty.exe';
  test(
    'launches the configured executable directly with structured arguments',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_terminal_launch_',
      );
      addTearDown(() async {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      });
      final marker = File('${temp.path}\\started.txt');
      int? pid;
      addTearDown(() {
        if (pid != null) {
          Process.killPid(pid);
        }
      });

      pid = await const TerminalLauncher().launch(
        TerminalLaunchSpec(
          executable: alacritty,
          arguments: [
            '-o',
            'window.position.x=-32000',
            '-o',
            'window.position.y=-32000',
            '--working-directory',
            Directory.current.path,
            '-e',
            'powershell.exe',
            '-NoProfile',
            '-NoExit',
            '-Command',
            "Set-Content -LiteralPath '${marker.path}' -Value started",
          ],
        ),
      );

      expect(pid, greaterThan(0));
      for (
        var attempt = 0;
        attempt < 100 && !await marker.exists();
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await marker.readAsString(), contains('started'));
    },
    skip: !Platform.isWindows || !File(alacritty).existsSync(),
  );
}
