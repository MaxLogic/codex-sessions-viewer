import 'dart:async';

import 'package:codex_sessions_viewer/src/app/runtime_session_controller.dart';

/// Runs before every test file in `test/`.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // A refresh collects Claude Code transcripts from the user's profile by
  // default. Tests pass their own roots so they never read the developer's.
  RuntimeSessionController.defaultClaudeProjectRoots = () => const [];
  await testMain();
}
