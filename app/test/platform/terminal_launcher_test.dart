import 'dart:io';

import 'package:codex_sessions_viewer/src/commands/resume_command_generator.dart';
import 'package:codex_sessions_viewer/src/platform/terminal_launcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'launches the configured executable directly with structured arguments',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_terminal_launch_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final marker = File(p.join(temp.path, 'started with spaces.txt'));
      final actor = File(p.join(temp.path, 'actor.dart'));
      actor.writeAsStringSync(
        "import 'dart:io'; void main(List<String> args) {File(args[0]).writeAsStringSync(args[1]);}",
      );
      final dart = p.join(
        Platform.environment['FLUTTER_ROOT']!,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      );
      final pid = await const TerminalLauncher().launch(
        TerminalLaunchSpec(
          executable: dart,
          arguments: [actor.path, marker.path, 'started with spaces'],
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
      expect(await marker.readAsString(), 'started with spaces');
    },
  );
}
