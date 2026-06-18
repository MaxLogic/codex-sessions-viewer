import 'dart:io';

import 'package:codex_sessions_viewer/src/benchmark/local_benchmark.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
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

  test(
    'copies configured sessions into private corpus and reports gate metrics',
    () async {
      final sourceRoot = Directory(
        '${temp.path}${Platform.pathSeparator}source',
      );
      final sessionsRoot = Directory(
        '${sourceRoot.path}${Platform.pathSeparator}sessions',
      );
      final wslRoot = Directory('${temp.path}${Platform.pathSeparator}wsl');
      final wslSessionsRoot = Directory(
        '${wslRoot.path}${Platform.pathSeparator}sessions',
      );
      await sessionsRoot.create(recursive: true);
      await wslSessionsRoot.create(recursive: true);
      await File(
        '${sessionsRoot.path}${Platform.pathSeparator}private-session.jsonl',
      ).writeAsString('''
{"type":"session_meta","payload":{"id":"private-jsonl","cwd":"C:\\\\Users\\\\pawel\\\\private\\\\project"}}
{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"private prompt text"}]}}
''');
      await File(
        '${wslSessionsRoot.path}${Platform.pathSeparator}private-wsl-session.jsonl',
      ).writeAsString('''
{"type":"session_meta","payload":{"id":"private-wsl-jsonl","cwd":"/home/pawel/private/project"}}
{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"private wsl answer"}]}}
''');
      final settingsFile = File(
        '${temp.path}${Platform.pathSeparator}settings.toml',
      );
      await SettingsRepository(settingsFile).save(
        AppSettings.defaults().copyWith(
          paths: PathSettings(
            windowsCodexPath: sourceRoot.path,
            wslCodexUncPath: wslRoot.path,
          ),
          logging: LoggingSettings(
            level: 'info',
            logFile:
                '${temp.path}${Platform.pathSeparator}logs${Platform.pathSeparator}benchmark.log',
            maxLogFiles: 2,
            maxLogSizeMb: 1,
          ),
        ),
      );
      final privateCorpus = Directory(
        '${temp.path}${Platform.pathSeparator}.agents${Platform.pathSeparator}private-session-corpus',
      );
      final outFile = File(
        '${temp.path}${Platform.pathSeparator}.agents${Platform.pathSeparator}benchmark-results${Platform.pathSeparator}session-scan-baseline.md',
      );

      final report = await LocalBenchmarkRunner(
        options: LocalBenchmarkOptions(
          fixturesDirectory: Directory(
            '${temp.path}${Platform.pathSeparator}unused',
          ),
          outputFile: outFile,
          settingsFile: settingsFile,
          privateCorpusDirectory: privateCorpus,
          copyFromSettings: true,
          includeReleaseSteps: false,
        ),
      ).run();

      expect(report.fixtures.totalFiles, 2);
      expect(report.privateCorpus?.filesCopied, 2);
      expect(report.scan.windowsSessionsAvailable, 1);
      expect(report.scan.wslSessionsAvailable, 1);
      expect(await privateCorpus.exists(), isTrue);
      expect(
        await privateCorpus
            .list(recursive: true)
            .where((entity) => entity is File)
            .length,
        2,
      );

      final text = await outFile.readAsString();
      for (final required in const [
        'cold_scan_elapsed_ms',
        'warm_noop_scan_elapsed_ms',
        'parsed_count',
        'skipped_count',
        'full_content_hash_read_count: 0',
        'wsl_process_invocation_count: not_available',
        'persistence_flush_count: 1',
        'full_row_snapshot_count: 1',
        'row_load_elapsed_ms',
        'cancel_request_to_idle_ms',
      ]) {
        expect(text, contains(required));
      }
      for (final forbidden in const [
        'private-jsonl',
        'private-session.jsonl',
        'private-wsl-session.jsonl',
        'C:\\\\Users\\\\pawel\\\\private\\\\project',
        'private prompt text',
        'private wsl answer',
      ]) {
        expect(text, isNot(contains(forbidden)));
      }
    },
  );

  test('does not copy arbitrary json outside a sessions directory', () async {
    final sourceRoot = Directory('${temp.path}${Platform.pathSeparator}source');
    final wslRoot = Directory('${temp.path}${Platform.pathSeparator}wsl');
    await sourceRoot.create(recursive: true);
    await wslRoot.create(recursive: true);
    await File(
      '${sourceRoot.path}${Platform.pathSeparator}private-auth.json',
    ).writeAsString('{"token":"do-not-copy"}');
    await File(
      '${wslRoot.path}${Platform.pathSeparator}private-config.jsonl',
    ).writeAsString('{"secret":"do-not-copy"}');
    final settingsFile = File(
      '${temp.path}${Platform.pathSeparator}settings.toml',
    );
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: sourceRoot.path,
          wslCodexUncPath: wslRoot.path,
        ),
      ),
    );
    final privateCorpus = Directory(
      '${temp.path}${Platform.pathSeparator}.agents${Platform.pathSeparator}private-session-corpus',
    );
    final outFile = File(
      '${temp.path}${Platform.pathSeparator}.agents${Platform.pathSeparator}benchmark-results${Platform.pathSeparator}session-scan-baseline.md',
    );

    final report = await LocalBenchmarkRunner(
      options: LocalBenchmarkOptions(
        fixturesDirectory: Directory(
          '${temp.path}${Platform.pathSeparator}unused',
        ),
        outputFile: outFile,
        settingsFile: settingsFile,
        privateCorpusDirectory: privateCorpus,
        copyFromSettings: true,
        includeReleaseSteps: false,
      ),
    ).run();

    expect(report.privateCorpus?.filesCopied, 0);
    expect(report.fixtures.totalFiles, 0);
    expect(
      await privateCorpus
          .list(recursive: true)
          .where((entity) => entity is File)
          .length,
      0,
    );
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
