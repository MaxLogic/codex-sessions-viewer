import 'dart:io';

import 'package:codex_sessions_viewer/src/benchmark/local_benchmark.dart';

Future<void> main(List<String> args) async {
  final copyFromSettings = args.contains('--copy-from-settings');
  final privateCorpus = Directory(
    _option(args, '--private-corpus') ?? '../.agents/private-session-corpus',
  );
  final fixtures = Directory(
    _option(args, '--fixtures') ??
        (copyFromSettings ? privateCorpus.path : '../samples/sessions'),
  );
  final output = File(
    _option(args, '--out') ??
        (copyFromSettings
            ? '../.agents/benchmark-results/session-scan-baseline.md'
            : '../docs/benchmark-results.md'),
  );
  final settingsFile = File(_option(args, '--settings') ?? '../settings.toml');
  final includeReleaseSteps = !args.contains('--skip-release');

  try {
    final report = await LocalBenchmarkRunner(
      options: LocalBenchmarkOptions(
        fixturesDirectory: fixtures,
        outputFile: output,
        settingsFile: settingsFile,
        privateCorpusDirectory: privateCorpus,
        copyFromSettings: copyFromSettings,
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
