import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../config/app_settings.dart';
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
    this.settingsFile,
    this.privateCorpusDirectory,
    this.copyFromSettings = false,
    this.includeReleaseSteps = true,
  });

  final Directory fixturesDirectory;
  final File outputFile;
  final Directory? sqlRoot;
  final Directory? repoRoot;
  final File? settingsFile;
  final Directory? privateCorpusDirectory;
  final bool copyFromSettings;
  final bool includeReleaseSteps;
}

class LocalBenchmarkRunner {
  LocalBenchmarkRunner({required this.options});

  final LocalBenchmarkOptions options;

  Future<LocalBenchmarkReport> run() async {
    final privateCorpus = options.copyFromSettings
        ? await _copyPrivateCorpusFromSettings()
        : null;
    final benchmarkDirectory =
        privateCorpus?.directory ?? options.fixturesDirectory;
    final scanRoots = _BenchmarkScanRoots.from(
      privateCorpus: privateCorpus,
      fixturesDirectory: options.fixturesDirectory,
    );
    final fixtureFiles = await _fixtureFiles(benchmarkDirectory);
    final parser = CodexSessionParser();
    final mapper = const CodexPathMapper(
      wslDistro: 'Ubuntu',
      wslLinuxHome: '/home/pawel',
      wslUncRoot: r'\\wsl.localhost\Ubuntu\',
    );
    final scanner = SessionScanner(parser: parser, pathMapper: mapper);

    final scanMeasurement = await _measure(
      () => scanner.scan(scanRoots.request()),
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
      () => scanner.scan(scanRoots.request(cachedSessions: cachedSnapshots)),
    );

    late final ParserBenchmarkResult parserResult;
    if (options.copyFromSettings) {
      parserResult = ParserBenchmarkResult(
        elapsed: scanMeasurement.elapsed,
        filesParsed: scanResult.progress.filesParsed,
        successes: scanResult.sessions.length,
        failures: scanResult.progress.filesFailed,
      );
    } else {
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
      parserResult = ParserBenchmarkResult(
        elapsed: parseMeasurement.elapsed,
        filesParsed: fixtureFiles.length,
        successes: parserSuccesses,
        failures: parserFailures,
      );
    }

    final searchMeasurement = _measureSync(() {
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
                  _documentFromSession(
                    session,
                    includeMessageText: !options.copyFromSettings,
                  ),
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

    final rowLoad = _measureRowLoad(scanResult.sessions);

    final release = options.includeReleaseSteps
        ? await _runReleaseBenchmarks(options.repoRoot ?? Directory('..'))
        : const ReleaseBenchmarkResult.skipped();

    final report = LocalBenchmarkReport(
      generatedAtUtc: DateTime.now().toUtc(),
      privateCorpus: privateCorpus,
      fullContentHashReadCount: 0,
      fixtures: FixtureBenchmarkSummary(totalFiles: fixtureFiles.length),
      scan: ScanBenchmarkResult(
        elapsed: scanMeasurement.elapsed,
        filesFound: scanResult.progress.filesFound,
        filesParsed: scanResult.progress.filesParsed,
        filesFailed: scanResult.progress.filesFailed,
        sessionsAvailable: scanResult.sessions.length,
        windowsSessionsAvailable: scanResult.sessions
            .where((session) => session.sourceType == SessionSourceType.windows)
            .length,
        wslSessionsAvailable: scanResult.sessions
            .where((session) => session.sourceType == SessionSourceType.wsl)
            .length,
      ),
      parser: parserResult,
      cache: CacheBenchmarkResult(
        elapsed: cacheMeasurement.elapsed,
        filesFound: cacheMeasurement.value.progress.filesFound,
        filesSkipped: cacheMeasurement.value.progress.filesSkipped,
        filesParsed: cacheMeasurement.value.progress.filesParsed,
      ),
      search: searchMeasurement.value.copyWith(
        elapsed: searchMeasurement.elapsed,
      ),
      rowLoad: rowLoad,
      release: release,
    );
    await options.outputFile.parent.create(recursive: true);
    await options.outputFile.writeAsString(report.renderMarkdown());
    return report;
  }

  Future<PrivateCorpusBenchmarkSummary> _copyPrivateCorpusFromSettings() async {
    final settingsFile = options.settingsFile;
    final target = options.privateCorpusDirectory;
    if (settingsFile == null || target == null) {
      throw ArgumentError(
        'Private corpus copy requires settingsFile and privateCorpusDirectory.',
      );
    }
    final settings = await SettingsRepository(settingsFile).loadOrCreate();
    final sources = [
      _PrivateCorpusSource(
        name: 'windows',
        directory: _sessionDirectory(settings.paths.windowsCodexPath),
      ),
      _PrivateCorpusSource(
        name: 'wsl',
        directory: _sessionDirectory(settings.paths.wslCodexUncPath),
      ),
    ];
    await target.create(recursive: true);
    var filesCopied = 0;
    var rootsAvailable = 0;
    for (final source in sources) {
      final sourceTarget = Directory(p.join(target.path, source.name));
      if (await sourceTarget.exists()) {
        await sourceTarget.delete(recursive: true);
      }
      await sourceTarget.create(recursive: true);
      final sourceDirectory = source.directory;
      if (sourceDirectory == null || !await sourceDirectory.exists()) {
        continue;
      }
      rootsAvailable++;
      await for (final entity in sourceDirectory.list(recursive: true)) {
        if (entity is! File || !_isSupportedSessionFile(entity.path)) {
          continue;
        }
        filesCopied++;
        final extension = p.extension(entity.path).toLowerCase();
        final copyName =
            filesCopied.toString().padLeft(8, '0') +
            (extension.isEmpty ? '.jsonl' : extension);
        await entity.copy(p.join(sourceTarget.path, copyName));
      }
    }
    return PrivateCorpusBenchmarkSummary(
      directory: target,
      filesCopied: filesCopied,
      rootsAvailable: rootsAvailable,
    );
  }

  RowLoadBenchmarkResult _measureRowLoad(List<ScannedSessionFile> sessions) {
    if (sessions.isEmpty) {
      return const RowLoadBenchmarkResult(
        elapsed: Duration.zero,
        rowsLoaded: 0,
        skipped: true,
      );
    }
    final db = sqlite3.openInMemory();
    try {
      _createRowLoadSchema(db);
      _seedRowLoadData(db, sessions);
      final measurement = _measureSync(
        () => db.select('''
          select
            s.id,
            s.session_id,
            s.source_type,
            s.message_count,
            s.user_message_count,
            s.assistant_message_count,
            s.tool_call_count,
            s.input_tokens,
            s.output_tokens,
            s.cached_input_tokens,
            s.total_tokens,
            coalesce((
              select sum(coalesce(m.token_total, 0))
              from messages m
              where m.session_id = s.id
                and m.author_type = 'user'
            ), 0) as user_message_tokens,
            coalesce((
              select sum(coalesce(m.token_total, 0))
              from messages m
              where m.session_id = s.id
                and m.author_type = 'assistant'
            ), 0) as assistant_response_tokens,
            coalesce((
              select sum(coalesce(m.token_total, 0))
              from messages m
              where m.session_id = s.id
                and m.author_type = 'tool'
            ), 0) as tool_call_tokens
          from sessions s
          where s.parse_status = 'available'
            and s.scan_status = 'available'
            and coalesce(s.session_id, '') <> ''
          order by coalesce(s.last_message_at_utc, s.started_at_utc, s.updated_at_utc) desc,
                   s.id asc
          '''),
      );
      return RowLoadBenchmarkResult(
        elapsed: measurement.elapsed,
        rowsLoaded: measurement.value.length,
      );
    } finally {
      db.close();
    }
  }
}

class LocalBenchmarkReport {
  const LocalBenchmarkReport({
    required this.generatedAtUtc,
    this.privateCorpus,
    this.fullContentHashReadCount = 0,
    this.wslProcessInvocationCount,
    required this.fixtures,
    required this.scan,
    required this.parser,
    required this.cache,
    required this.search,
    required this.rowLoad,
    required this.release,
  });

  final DateTime generatedAtUtc;
  final PrivateCorpusBenchmarkSummary? privateCorpus;
  final int fullContentHashReadCount;
  final int? wslProcessInvocationCount;
  final FixtureBenchmarkSummary fixtures;
  final ScanBenchmarkResult scan;
  final ParserBenchmarkResult parser;
  final CacheBenchmarkResult cache;
  final SearchBenchmarkResult search;
  final RowLoadBenchmarkResult rowLoad;
  final ReleaseBenchmarkResult release;

  String renderMarkdown() {
    final command = privateCorpus == null
        ? '`dart run bin/benchmark_local.dart --fixtures <fixtures> --out <out>`'
        : '`dart run bin/benchmark_local.dart --copy-from-settings --private-corpus <ignored-private-corpus> --out <ignored-report> --skip-release`';
    final wslProcessMetric =
        wslProcessInvocationCount?.toString() ?? 'not_available';
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
      ..writeln(command)
      ..writeln()
      ..writeln('The report records aggregate counts and durations only.')
      ..writeln(
        'Coverage: scanner, parser, cache, search, row-load, build, package.',
      )
      ..writeln()
      ..writeln('## Private corpus')
      ..writeln()
      ..writeln(
        '- Mode: ${privateCorpus == null ? 'fixture' : 'ignored private copy'}',
      )
      ..writeln('- Files copied: ${privateCorpus?.filesCopied ?? 0}')
      ..writeln(
        '- Source roots available: ${privateCorpus?.rootsAvailable ?? 0}',
      )
      ..writeln()
      ..writeln('## Scanner throughput')
      ..writeln()
      ..writeln('- Elapsed: ${_ms(scan.elapsed)}')
      ..writeln('- Files found: ${scan.filesFound}')
      ..writeln('- Files parsed: ${scan.filesParsed}')
      ..writeln('- Files failed: ${scan.filesFailed}')
      ..writeln('- Sessions available: ${scan.sessionsAvailable}')
      ..writeln(
        '- Windows sessions available: ${scan.windowsSessionsAvailable}',
      )
      ..writeln('- WSL sessions available: ${scan.wslSessionsAvailable}')
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
      ..writeln('## Row loading')
      ..writeln()
      ..writeln('- Elapsed: ${_ms(rowLoad.elapsed)}')
      ..writeln('- Rows loaded: ${rowLoad.rowsLoaded}')
      ..writeln('- Skipped: ${rowLoad.skipped}')
      ..writeln()
      ..writeln('## Quantitative gate metrics')
      ..writeln()
      ..writeln('- cold_scan_elapsed_ms: ${scan.elapsed.inMilliseconds}')
      ..writeln('- warm_noop_scan_elapsed_ms: ${cache.elapsed.inMilliseconds}')
      ..writeln('- parsed_count: ${scan.filesParsed}')
      ..writeln('- skipped_count: ${cache.filesSkipped}')
      ..writeln('- full_content_hash_read_count: $fullContentHashReadCount')
      ..writeln('- wsl_process_invocation_count: $wslProcessMetric')
      ..writeln('- unique_wsl_path_count: not_available')
      ..writeln('- persistence_flush_count: not_available')
      ..writeln('- full_row_snapshot_count: not_available')
      ..writeln('- row_load_elapsed_ms: ${rowLoad.elapsed.inMilliseconds}')
      ..writeln('- cancel_request_to_idle_ms: not_available')
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
      )
      ..writeln('Row load elapsed: ${rowLoad.elapsed.inMilliseconds} ms');
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

class PrivateCorpusBenchmarkSummary {
  const PrivateCorpusBenchmarkSummary({
    required this.directory,
    required this.filesCopied,
    required this.rootsAvailable,
  });

  final Directory directory;
  final int filesCopied;
  final int rootsAvailable;
}

class ScanBenchmarkResult {
  const ScanBenchmarkResult({
    required this.elapsed,
    required this.filesFound,
    required this.filesParsed,
    required this.filesFailed,
    required this.sessionsAvailable,
    this.windowsSessionsAvailable = 0,
    this.wslSessionsAvailable = 0,
  });

  final Duration elapsed;
  final int filesFound;
  final int filesParsed;
  final int filesFailed;
  final int sessionsAvailable;
  final int windowsSessionsAvailable;
  final int wslSessionsAvailable;
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

class RowLoadBenchmarkResult {
  const RowLoadBenchmarkResult({
    required this.elapsed,
    required this.rowsLoaded,
    this.skipped = false,
  });

  final Duration elapsed;
  final int rowsLoaded;
  final bool skipped;
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

_Measurement<T> _measureSync<T>(T Function() action) {
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

bool _isSupportedSessionFile(String path) =>
    path.endsWith('.json') || path.endsWith('.jsonl');

Directory? _sessionDirectory(String rootPath) {
  if (rootPath.trim().isEmpty) {
    return null;
  }
  final root = Directory(rootPath);
  final sessions = Directory(p.join(root.path, 'sessions'));
  if (sessions.existsSync()) {
    return sessions;
  }
  if (p.basename(root.path).toLowerCase() == 'sessions') {
    return root;
  }
  return null;
}

class _BenchmarkScanRoots {
  const _BenchmarkScanRoots({required this.windowsRoot, this.wslRoot});

  factory _BenchmarkScanRoots.from({
    required PrivateCorpusBenchmarkSummary? privateCorpus,
    required Directory fixturesDirectory,
  }) {
    if (privateCorpus == null) {
      return _BenchmarkScanRoots(windowsRoot: fixturesDirectory);
    }
    return _BenchmarkScanRoots(
      windowsRoot: Directory(p.join(privateCorpus.directory.path, 'windows')),
      wslRoot: Directory(p.join(privateCorpus.directory.path, 'wsl')),
    );
  }

  final Directory windowsRoot;
  final Directory? wslRoot;

  SessionScanRequest request({
    List<CachedSessionSnapshot> cachedSessions = const [],
  }) => SessionScanRequest(
    windowsRoot: windowsRoot.path,
    wslRoot: wslRoot?.path,
    cachedSessions: cachedSessions,
  );
}

class _PrivateCorpusSource {
  const _PrivateCorpusSource({required this.name, required this.directory});

  final String name;
  final Directory? directory;
}

void _createRowLoadSchema(Database db) {
  db.execute('''
    create table sessions (
      id text primary key,
      session_id text,
      source_type text not null,
      parse_status text not null,
      scan_status text not null,
      started_at_utc text,
      last_message_at_utc text,
      updated_at_utc text not null,
      message_count integer not null default 0,
      user_message_count integer not null default 0,
      assistant_message_count integer not null default 0,
      tool_call_count integer not null default 0,
      input_tokens integer,
      output_tokens integer,
      cached_input_tokens integer,
      total_tokens integer
    );

    create table messages (
      id integer primary key autoincrement,
      session_id text not null,
      author_type text not null,
      token_total integer
    );

    create index idx_messages_session on messages(session_id);
  ''');
}

void _seedRowLoadData(Database db, List<ScannedSessionFile> sessions) {
  final now = DateTime.now().toUtc().toIso8601String();
  db.execute('begin immediate');
  try {
    for (final scanned in sessions) {
      final parsed = scanned.parsedSession;
      db.execute(
        '''
        insert into sessions (
          id,
          session_id,
          source_type,
          parse_status,
          scan_status,
          started_at_utc,
          last_message_at_utc,
          updated_at_utc,
          message_count,
          user_message_count,
          assistant_message_count,
          tool_call_count,
          input_tokens,
          output_tokens,
          cached_input_tokens,
          total_tokens
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          parsed.internalId,
          parsed.sessionId,
          scanned.sourceType == SessionSourceType.wsl ? 'wsl' : 'windows',
          'available',
          scanned.status.wireName,
          parsed.startedAtUtc?.toIso8601String(),
          parsed.lastMessageAtUtc?.toIso8601String(),
          now,
          parsed.messages.length,
          parsed.messages
              .where(
                (message) => message.authorType == CodexMessageAuthorType.user,
              )
              .length,
          parsed.messages
              .where(
                (message) =>
                    message.authorType == CodexMessageAuthorType.assistant,
              )
              .length,
          parsed.toolCalls.length,
          parsed.usage.inputTokens,
          parsed.usage.outputTokens,
          parsed.usage.cachedInputTokens,
          parsed.usage.totalTokens,
        ],
      );
      for (final message in parsed.messages) {
        db.execute(
          '''
          insert into messages (
            session_id,
            author_type,
            token_total
          ) values (?, ?, ?)
          ''',
          [
            parsed.internalId,
            message.authorType.name,
            message.usage.totalTokens,
          ],
        );
      }
    }
    db.execute('commit');
  } on Object {
    db.execute('rollback');
    rethrow;
  }
}

SessionSearchDocument _documentFromSession(
  ScannedSessionFile session, {
  bool includeMessageText = true,
}) {
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
    userMessages: includeMessageText
        ? parsed.messages
              .where(
                (message) => message.authorType == CodexMessageAuthorType.user,
              )
              .map((message) => message.firstLine)
              .join(' ')
        : '',
    assistantMessages: includeMessageText
        ? parsed.messages
              .where(
                (message) =>
                    message.authorType == CodexMessageAuthorType.assistant,
              )
              .map((message) => message.firstLine)
              .join(' ')
        : '',
    toolNames: includeMessageText
        ? parsed.toolCalls.map((call) => call.toolName).join(' ')
        : '',
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
