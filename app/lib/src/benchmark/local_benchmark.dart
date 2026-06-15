import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../parser/codex_session_parser.dart';
import '../path_mapping/path_mapper.dart';
import '../scanner/session_scanner.dart';
import '../search/session_search.dart';

class LocalBenchmarkOptions {
  const LocalBenchmarkOptions({
    required this.fixturesDirectory,
    required this.outputFile,
    this.sqlRoot,
    this.repoRoot,
    this.includeReleaseSteps = true,
  });

  final Directory fixturesDirectory;
  final File outputFile;
  final Directory? sqlRoot;
  final Directory? repoRoot;
  final bool includeReleaseSteps;
}

class LocalBenchmarkRunner {
  LocalBenchmarkRunner({required this.options});

  final LocalBenchmarkOptions options;

  Future<LocalBenchmarkReport> run() async {
    final fixtureFiles = await _fixtureFiles(options.fixturesDirectory);
    final parser = CodexSessionParser();
    final mapper = const CodexPathMapper(
      wslDistro: 'Ubuntu',
      wslLinuxHome: '/home/pawel',
      wslUncRoot: r'\\wsl.localhost\Ubuntu\',
    );
    final scanner = SessionScanner(parser: parser, pathMapper: mapper);

    final scanMeasurement = await _measure(
      () => scanner.scan(
        SessionScanRequest(windowsRoot: options.fixturesDirectory.path),
      ),
    );
    final scanResult = scanMeasurement.value;

    final cachedSnapshots = <CachedSessionSnapshot>[];
    for (final session in scanResult.sessions) {
      cachedSnapshots.add(
        await CachedSessionSnapshot.fromFile(
          File(session.sourcePath),
          status: SessionFileStatus.available,
          parserVersion: CodexSessionParser.currentVersion,
        ),
      );
    }
    final cacheMeasurement = await _measure(
      () => scanner.scan(
        SessionScanRequest(
          windowsRoot: options.fixturesDirectory.path,
          cachedSessions: cachedSnapshots,
        ),
      ),
    );

    var parserSuccesses = 0;
    var parserFailures = 0;
    final parseMeasurement = await _measure(() async {
      for (final file in fixtureFiles) {
        final result = await parser.parseFile(file);
        if (result.isSuccess) {
          parserSuccesses++;
        } else {
          parserFailures++;
        }
      }
    });

    final searchMeasurement = await _measureSync(() {
      final sqlRoot = options.sqlRoot ?? Directory('../sql');
      final db = sqlite3.openInMemory();
      try {
        db.execute(
          File(
            p.join(sqlRoot.path, 'init', '001_initial_schema.sql'),
          ).readAsStringSync(),
        );
        db.execute(
          File(
            p.join(sqlRoot.path, 'migration', '002_search_filter_schema.sql'),
          ).readAsStringSync(),
        );
        final index = SessionSearchIndex(db);
        final documents = scanResult.sessions.isEmpty
            ? [_syntheticDocument()]
            : [
                for (final session in scanResult.sessions)
                  _documentFromSession(session),
              ];
        for (final document in documents) {
          index.upsert(document);
        }
        final hits = index.search(const SessionSearchQuery(text: 'session'));
        return SearchBenchmarkResult(
          documentsIndexed: documents.length,
          searchHits: hits.length,
        );
      } finally {
        db.close();
      }
    });

    final release = options.includeReleaseSteps
        ? await _runReleaseBenchmarks(options.repoRoot ?? Directory('..'))
        : const ReleaseBenchmarkResult.skipped();

    final report = LocalBenchmarkReport(
      generatedAtUtc: DateTime.now().toUtc(),
      fixtures: FixtureBenchmarkSummary(totalFiles: fixtureFiles.length),
      scan: ScanBenchmarkResult(
        elapsed: scanMeasurement.elapsed,
        filesFound: scanResult.progress.filesFound,
        filesParsed: scanResult.progress.filesParsed,
        filesFailed: scanResult.progress.filesFailed,
        sessionsAvailable: scanResult.sessions.length,
      ),
      parser: ParserBenchmarkResult(
        elapsed: parseMeasurement.elapsed,
        filesParsed: fixtureFiles.length,
        successes: parserSuccesses,
        failures: parserFailures,
      ),
      cache: CacheBenchmarkResult(
        elapsed: cacheMeasurement.elapsed,
        filesFound: cacheMeasurement.value.progress.filesFound,
        filesSkipped: cacheMeasurement.value.progress.filesSkipped,
        filesParsed: cacheMeasurement.value.progress.filesParsed,
      ),
      search: searchMeasurement.value.copyWith(
        elapsed: searchMeasurement.elapsed,
      ),
      release: release,
    );
    await options.outputFile.parent.create(recursive: true);
    await options.outputFile.writeAsString(report.renderMarkdown());
    return report;
  }
}

class LocalBenchmarkReport {
  const LocalBenchmarkReport({
    required this.generatedAtUtc,
    required this.fixtures,
    required this.scan,
    required this.parser,
    required this.cache,
    required this.search,
    required this.release,
  });

  final DateTime generatedAtUtc;
  final FixtureBenchmarkSummary fixtures;
  final ScanBenchmarkResult scan;
  final ParserBenchmarkResult parser;
  final CacheBenchmarkResult cache;
  final SearchBenchmarkResult search;
  final ReleaseBenchmarkResult release;

  String renderMarkdown() {
    final buffer = StringBuffer()
      ..writeln('# Local Benchmark Results')
      ..writeln()
      ..writeln('Generated UTC: ${generatedAtUtc.toIso8601String()}')
      ..writeln()
      ..writeln('## Machine and Toolchain')
      ..writeln()
      ..writeln('- Operating system: ${Platform.operatingSystem}')
      ..writeln('- Dart version: ${Platform.version.split('\n').first}')
      ..writeln('- Dataset: ${fixtures.totalFiles} supported fixture files')
      ..writeln()
      ..writeln('## Command')
      ..writeln()
      ..writeln(
        '`dart run bin/benchmark_local.dart --fixtures <fixtures> --out <out>`',
      )
      ..writeln()
      ..writeln(
        'The report is content-safe: it records aggregate counts and durations only, with no raw session paths, prompts, messages, tool output, or token values.',
      )
      ..writeln('Coverage: scanner, parser, cache, search, build, package.')
      ..writeln()
      ..writeln('## Scanner throughput')
      ..writeln()
      ..writeln('- Elapsed: ${_ms(scan.elapsed)}')
      ..writeln('- Files found: ${scan.filesFound}')
      ..writeln('- Files parsed: ${scan.filesParsed}')
      ..writeln('- Files failed: ${scan.filesFailed}')
      ..writeln('- Sessions available: ${scan.sessionsAvailable}')
      ..writeln()
      ..writeln('## Parser throughput')
      ..writeln()
      ..writeln('- Elapsed: ${_ms(parser.elapsed)}')
      ..writeln('- Files parsed: ${parser.filesParsed}')
      ..writeln('- Successful parses: ${parser.successes}')
      ..writeln('- Failed parses: ${parser.failures}')
      ..writeln()
      ..writeln('## Cache invalidation skip time')
      ..writeln()
      ..writeln('- Elapsed: ${_ms(cache.elapsed)}')
      ..writeln('- Files found: ${cache.filesFound}')
      ..writeln('- Files skipped: ${cache.filesSkipped}')
      ..writeln('- Files parsed: ${cache.filesParsed}')
      ..writeln()
      ..writeln('## SQLite upsert/search')
      ..writeln()
      ..writeln('- Elapsed: ${_ms(search.elapsed)}')
      ..writeln('- Documents indexed: ${search.documentsIndexed}')
      ..writeln('- Search hits for benchmark query: ${search.searchHits}')
      ..writeln()
      ..writeln('## Release build/package timing')
      ..writeln()
      ..writeln(
        '- Build script: ${release.buildSkipped ? 'skipped' : _ms(release.buildElapsed)}',
      )
      ..writeln(
        '- Package script: ${release.packageSkipped ? 'skipped' : _ms(release.packageElapsed)}',
      );
    return buffer.toString();
  }

  String renderCliSummary() {
    final buffer = StringBuffer()
      ..writeln('Benchmark report written to requested output file.')
      ..writeln('Fixtures measured: ${fixtures.totalFiles}')
      ..writeln('Scanner elapsed: ${scan.elapsed.inMilliseconds} ms')
      ..writeln('Parser elapsed: ${parser.elapsed.inMilliseconds} ms')
      ..writeln('Cache skip elapsed: ${cache.elapsed.inMilliseconds} ms')
      ..writeln(
        'SQLite upsert/search elapsed: ${search.elapsed.inMilliseconds} ms',
      );
    if (release.buildSkipped) {
      buffer.writeln('Release build/package timing skipped.');
    } else {
      buffer
        ..writeln(
          'Release build elapsed: ${release.buildElapsed.inMilliseconds} ms',
        )
        ..writeln(
          'Release package elapsed: ${release.packageElapsed.inMilliseconds} ms',
        );
    }
    return buffer.toString();
  }

  static String renderCliFailureSummary() =>
      'Benchmark failed. Check fixture/output arguments and local toolchain.';
}

class FixtureBenchmarkSummary {
  const FixtureBenchmarkSummary({required this.totalFiles});

  final int totalFiles;
}

class ScanBenchmarkResult {
  const ScanBenchmarkResult({
    required this.elapsed,
    required this.filesFound,
    required this.filesParsed,
    required this.filesFailed,
    required this.sessionsAvailable,
  });

  final Duration elapsed;
  final int filesFound;
  final int filesParsed;
  final int filesFailed;
  final int sessionsAvailable;
}

class ParserBenchmarkResult {
  const ParserBenchmarkResult({
    required this.elapsed,
    required this.filesParsed,
    required this.successes,
    required this.failures,
  });

  final Duration elapsed;
  final int filesParsed;
  final int successes;
  final int failures;
}

class CacheBenchmarkResult {
  const CacheBenchmarkResult({
    required this.elapsed,
    required this.filesFound,
    required this.filesSkipped,
    required this.filesParsed,
  });

  final Duration elapsed;
  final int filesFound;
  final int filesSkipped;
  final int filesParsed;
}

class SearchBenchmarkResult {
  const SearchBenchmarkResult({
    this.elapsed = Duration.zero,
    required this.documentsIndexed,
    required this.searchHits,
  });

  final Duration elapsed;
  final int documentsIndexed;
  final int searchHits;

  SearchBenchmarkResult copyWith({Duration? elapsed}) => SearchBenchmarkResult(
    elapsed: elapsed ?? this.elapsed,
    documentsIndexed: documentsIndexed,
    searchHits: searchHits,
  );
}

class ReleaseBenchmarkResult {
  const ReleaseBenchmarkResult({
    required this.buildElapsed,
    required this.packageElapsed,
    this.buildSkipped = false,
    this.packageSkipped = false,
  });

  const ReleaseBenchmarkResult.skipped()
    : buildElapsed = Duration.zero,
      packageElapsed = Duration.zero,
      buildSkipped = true,
      packageSkipped = true;

  final Duration buildElapsed;
  final Duration packageElapsed;
  final bool buildSkipped;
  final bool packageSkipped;
}

class _Measurement<T> {
  const _Measurement({required this.elapsed, required this.value});

  final Duration elapsed;
  final T value;
}

Future<_Measurement<T>> _measure<T>(Future<T> Function() action) async {
  final stopwatch = Stopwatch()..start();
  final value = await action();
  stopwatch.stop();
  return _Measurement(elapsed: stopwatch.elapsed, value: value);
}

Future<_Measurement<T>> _measureSync<T>(T Function() action) async {
  final stopwatch = Stopwatch()..start();
  final value = action();
  stopwatch.stop();
  return _Measurement(elapsed: stopwatch.elapsed, value: value);
}

Future<List<File>> _fixtureFiles(Directory fixturesDirectory) async {
  final files = <File>[];
  if (!await fixturesDirectory.exists()) {
    throw ArgumentError('Fixtures directory does not exist.');
  }
  await for (final entity in fixturesDirectory.list(recursive: true)) {
    if (entity is File &&
        (entity.path.endsWith('.json') || entity.path.endsWith('.jsonl'))) {
      files.add(entity);
    }
  }
  files.sort((left, right) => left.path.compareTo(right.path));
  return files;
}

SessionSearchDocument _documentFromSession(ScannedSessionFile session) {
  final parsed = session.parsedSession;
  return SessionSearchDocument(
    id: parsed.internalId,
    sourceType: parsed.sourceType == CodexSessionSourceType.wsl
        ? SessionSearchSourceType.wsl
        : SessionSearchSourceType.windows,
    sourceFilePath: '<fixture>',
    displayPath: '<fixture>',
    platformPath: '<fixture>',
    title: parsed.title ?? 'Benchmark session',
    summary: parsed.summary ?? '',
    userMessages: parsed.messages
        .where((message) => message.authorType == CodexMessageAuthorType.user)
        .map((message) => message.firstLine)
        .join(' '),
    assistantMessages: parsed.messages
        .where(
          (message) => message.authorType == CodexMessageAuthorType.assistant,
        )
        .map((message) => message.firstLine)
        .join(' '),
    toolNames: parsed.toolCalls.map((call) => call.toolName).join(' '),
    normalizedPathKeys: '<fixture>',
    modelsUsed: parsed.modelIds.toList(growable: false),
    hasCodeBlocks: parsed.messages.any(
      (message) => message.contentPlain.contains('```'),
    ),
    hasToolCalls: parsed.toolCalls.isNotEmpty,
    hasErrors: parsed.messages.any((message) => message.hasError),
    totalTokens: parsed.usage.totalTokens,
  );
}

SessionSearchDocument _syntheticDocument() => const SessionSearchDocument(
  id: 'benchmark-synthetic',
  sourceType: SessionSearchSourceType.windows,
  sourceFilePath: '<fixture>',
  displayPath: '<fixture>',
  platformPath: '<fixture>',
  title: 'Benchmark session',
  summary: 'Synthetic fallback document',
  normalizedPathKeys: '<fixture>',
);

Future<ReleaseBenchmarkResult> _runReleaseBenchmarks(Directory repoRoot) async {
  final build = await _measure(() {
    return _runPowerShellScript(
      repoRoot,
      p.join('scripts', 'build_windows.ps1'),
      ['-OutputDirectory', p.join('release', 'benchmark', 'windows')],
    );
  });
  final package = await _measure(() {
    return _runPowerShellScript(
      repoRoot,
      p.join('scripts', 'package_release.ps1'),
      [
        '-BuildOutputDirectory',
        p.join('release', 'benchmark', 'windows'),
        '-PackageDirectory',
        p.join('release', 'benchmark', 'package'),
        '-ArchivePath',
        p.join('release', 'benchmark', 'codex_session_viewer_windows.zip'),
      ],
    );
  });
  return ReleaseBenchmarkResult(
    buildElapsed: build.elapsed,
    packageElapsed: package.elapsed,
  );
}

Future<void> _runPowerShellScript(
  Directory repoRoot,
  String script,
  List<String> args,
) async {
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    script,
    ...args,
  ], workingDirectory: repoRoot.path);
  if (result.exitCode != 0) {
    throw ProcessException(
      'powershell',
      ['-File', script],
      'Benchmark release step failed with exit code ${result.exitCode}.',
      result.exitCode,
    );
  }
}

String _ms(Duration duration) => '${duration.inMilliseconds} ms';
