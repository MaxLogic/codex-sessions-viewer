import 'dart:io';

import 'package:codex_sessions_viewer/src/benchmark/local_benchmark.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('csv_benchmark_test_');
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test('writes aggregate content-safe benchmark report', () async {
    final fixtures = Directory('${temp.path}${Platform.pathSeparator}fixtures');
    await fixtures.create();
    await File(
      '${fixtures.path}${Platform.pathSeparator}private-session.json',
    ).writeAsString('''
{
  "session_id": "secret-session-id",
  "source_type": "windows",
  "display_path": "C:\\\\Users\\\\pawel\\\\private\\\\project",
  "messages": [
    { "type": "user", "content": "private prompt text" },
    { "type": "assistant", "content": "private answer text" }
  ],
  "usage": { "input_tokens": 10, "output_tokens": 20 }
}
''');
    final outFile = File('${temp.path}${Platform.pathSeparator}report.md');

    final report = await LocalBenchmarkRunner(
      options: LocalBenchmarkOptions(
        fixturesDirectory: fixtures,
        outputFile: outFile,
        includeReleaseSteps: false,
      ),
    ).run();

    expect(report.fixtures.totalFiles, 1);
    expect(report.scan.filesFound, 1);
    expect(report.parser.filesParsed, 1);
    expect(report.cache.filesSkipped, 1);
    expect(report.search.documentsIndexed, 1);
    expect(await outFile.exists(), isTrue);

    final text = await outFile.readAsString();
    for (final required in const [
      'Scanner throughput',
      'Parser throughput',
      'Cache invalidation skip time',
      'SQLite upsert/search',
      'Release build/package timing',
      'dart run bin/benchmark_local.dart --fixtures <fixtures> --out <out>',
    ]) {
      expect(text, contains(required));
    }
    for (final forbidden in const [
      'secret-session-id',
      'private-session.json',
      'C:\\\\Users\\\\pawel\\\\private\\\\project',
      'private prompt text',
      'private answer text',
      'input_tokens',
      'output_tokens',
    ]) {
      expect(text, isNot(contains(forbidden)));
    }
  });

  test('CLI summary does not print paths or session content', () async {
    final fixtures = Directory('${temp.path}${Platform.pathSeparator}fixtures');
    await fixtures.create();
    await File(
      '${fixtures.path}${Platform.pathSeparator}session.json',
    ).writeAsString('''
{
  "session_id": "secret-cli-session",
  "source_type": "windows",
  "messages": [
    { "type": "user", "content": "private cli prompt" }
  ]
}
''');
    final outFile = File('${temp.path}${Platform.pathSeparator}cli-report.md');

    final report = await LocalBenchmarkRunner(
      options: LocalBenchmarkOptions(
        fixturesDirectory: fixtures,
        outputFile: outFile,
        includeReleaseSteps: false,
      ),
    ).run();

    final stdoutText = report.renderCliSummary();
    expect(
      stdoutText,
      contains('Benchmark report written to requested output file.'),
    );
    for (final forbidden in [
      fixtures.path,
      outFile.path,
      'session.json',
      'secret-cli-session',
      'private cli prompt',
    ]) {
      expect(stdoutText, isNot(contains(forbidden)));
    }
  });

  test('CLI failure summary is path-free', () {
    final text = LocalBenchmarkReport.renderCliFailureSummary();

    expect(text, contains('Benchmark failed.'));
    for (final forbidden in const [
      r'C:\Users\pawel\AppData\Local\Temp\codex_benchmark_out_dir',
      'session.json',
      'secret-cli-session',
      'private cli prompt',
    ]) {
      expect(text, isNot(contains(forbidden)));
    }
  });
}
