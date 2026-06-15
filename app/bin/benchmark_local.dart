import 'dart:io';

import 'package:codex_sessions_viewer/src/benchmark/local_benchmark.dart';

Future<void> main(List<String> args) async {
  final fixtures = Directory(
    _option(args, '--fixtures') ?? '../samples/sessions',
  );
  final output = File(_option(args, '--out') ?? '../docs/benchmark-results.md');
  final includeReleaseSteps = !args.contains('--skip-release');

  try {
    final report = await LocalBenchmarkRunner(
      options: LocalBenchmarkOptions(
        fixturesDirectory: fixtures,
        outputFile: output,
        includeReleaseSteps: includeReleaseSteps,
      ),
    ).run();
    stdout.write(report.renderCliSummary());
  } on Object {
    stderr.writeln(LocalBenchmarkReport.renderCliFailureSummary());
    exitCode = 1;
  }
}

String? _option(List<String> args, String name) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == name && i + 1 < args.length) {
      return args[i + 1];
    }
    if (arg.startsWith('$name=')) {
      return arg.substring(name.length + 1);
    }
  }
  return null;
}
