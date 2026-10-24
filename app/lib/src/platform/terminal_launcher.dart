import 'package:codex_sessions_viewer/src/platform/app_environment.dart';
import 'dart:io';

import '../commands/resume_command_generator.dart';

class TerminalLauncher {
  const TerminalLauncher();

  Future<int> launch(TerminalLaunchSpec spec) async {
    final process = await AppEnvironment.start(
      spec.executable,
      spec.arguments,
      mode: ProcessStartMode.detached,
    );
    return process.pid;
  }
}
