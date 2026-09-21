import 'dart:io';

import 'package:codex_sessions_viewer/src/benchmark/usage_projection_benchmark.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runUsageProjectionBenchmarkCli(
    arguments,
    output: stdout,
    errors: stderr,
  );
}
