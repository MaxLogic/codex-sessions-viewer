import 'dart:io';

import '../commands/resume_command_generator.dart';

class TerminalLauncher {
  const TerminalLauncher();

  Future<int> launch(TerminalLaunchSpec spec) async {
    final process = await Process.start(
      spec.executable,
      spec.arguments,
      mode: ProcessStartMode.detached,
    );
    return process.pid;
  }
}
