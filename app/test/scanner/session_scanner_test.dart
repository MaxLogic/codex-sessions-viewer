import 'dart:async';
import 'dart:io';

import 'package:codex_sessions_viewer/src/parser/codex_session_parser.dart';
import 'package:codex_sessions_viewer/src/path_mapping/path_mapper.dart';
import 'package:codex_sessions_viewer/src/scanner/session_scanner.dart';
import 'package:codex_sessions_viewer/src/utils/profiling.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late CodexPathMapper mapper;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('csv_scanner_test_');
    mapper = const CodexPathMapper(
      wslDistro: 'Ubuntu',
      wslLinuxHome: '/home/pawel',
      wslUncRoot: r'\\wsl.localhost\Ubuntu\',
    );
  });

  tearDown(() async {
    if (await temp.exists()) {
      await temp.delete(recursive: true);
    }
  });

  test(
    'scans Windows and WSL roots and reports available and failed files',
    () async {
      final windowsRoot = Directory('${temp.path}${Platform.pathSeparator}win');
      final wslRoot = Directory('${temp.path}${Platform.pathSeparator}wsl');
      await windowsRoot.create();
      await wslRoot.create();
      await File(
        '${windowsRoot.path}${Platform.pathSeparator}ok.json',
      ).writeAsString(_validJsonSession('win-1'));
      await File(
        '${wslRoot.path}${Platform.pathSeparator}ok.json',
      ).writeAsString(_validJsonSession('wsl-1'));
      await File(
        '${wslRoot.path}${Platform.pathSeparator}bad.json',
      ).writeAsString('{ "session_id": ');
      await File(
        '${wslRoot.path}${Platform.pathSeparator}notes.txt',
      ).writeAsString('not a session');

      final scanner = SessionScanner(
        parser: CodexSessionParser(),
        pathMapper: mapper,
      );

      final result = await scanner.scan(
        SessionScanRequest(
          windowsRoot: windowsRoot.path,
          wslRoot: wslRoot.path,
        ),
      );

      expect(result.progress.filesFound, 3);
      expect(result.progress.filesSkipped, 1);
      expect(result.progress.filesParsed, 2);
      expect(result.progress.filesFailed, 1);
      expect(result.sessions, hasLength(2));
      expect(
        result.sessions.map((session) => session.sourceType),
        containsAll([SessionSourceType.windows, SessionSourceType.wsl]),
      );
      expect(
        result.sessions
            .singleWhere(
              (session) => session.sourceType == SessionSourceType.wsl,
            )
            .mappedPath
            .platformPath,
        contains('/'),
      );
      expect(
        result.errors.map((error) => error.status),
        containsAll([
          SessionFileStatus.parseError,
          SessionFileStatus.unsupportedFormat,
        ]),
      );
      expect(
        result.statusEvents.map((status) => status.status),
        containsAll([
          SessionFileStatus.available,
          SessionFileStatus.parseError,
          SessionFileStatus.unsupportedFormat,
          SessionFileStatus.changedPendingParse,
        ]),
      );
      expect(
        result.fileStatuses.map((status) => status.status),
        containsAll([
          SessionFileStatus.available,
          SessionFileStatus.parseError,
          SessionFileStatus.unsupportedFormat,
        ]),
      );
      expect(
        result.fileStatuses.map((status) => status.sourcePath).toSet(),
        hasLength(result.fileStatuses.length),
      );
      final wslEvents = result.statusEvents
          .where(
            (status) =>
                status.sourcePath.endsWith('${Platform.pathSeparator}ok.json'),
          )
          .map((status) => status.status)
          .toList();
      expect(wslEvents.first, SessionFileStatus.changedPendingParse);
      expect(wslEvents.last, SessionFileStatus.available);
    },
  );

  test('reports path-unreachable while preserving cached sessions', () async {
    final cached = [
      CachedSessionSnapshot(
        sourcePath: r'C:\cached\session.jsonl',
        status: SessionFileStatus.available,
      ),
    ];
    final scanner = SessionScanner(
      parser: CodexSessionParser(),
      pathMapper: mapper,
    );

    final result = await scanner.scan(
      SessionScanRequest(
        windowsRoot: '${temp.path}${Platform.pathSeparator}missing',
        cachedSessions: cached,
      ),
    );

    expect(result.cachedSessions, cached);
    expect(result.errors.single.status, SessionFileStatus.pathUnreachable);
    expect(result.progress.filesFailed, 1);
  });

  test(
    'reports cached sessions missing when no matching file is found',
    () async {
      final root = Directory('${temp.path}${Platform.pathSeparator}win');
      await root.create();
      final cached = [
        CachedSessionSnapshot(
          sourcePath: '${root.path}${Platform.pathSeparator}missing.jsonl',
          status: SessionFileStatus.available,
        ),
      ];
      final scanner = SessionScanner(
        parser: CodexSessionParser(),
        pathMapper: mapper,
      );

      final result = await scanner.scan(
        SessionScanRequest(windowsRoot: root.path, cachedSessions: cached),
      );

      expect(result.progress.sessionsMissing, 1);
      expect(result.errors.single.status, SessionFileStatus.missing);
      expect(result.errors.single.sourcePath, cached.single.sourcePath);
    },
  );

  test(
    'does not mark cached sessions missing for an unreachable source root',
    () async {
      final windowsRoot = Directory('${temp.path}${Platform.pathSeparator}win');
      await windowsRoot.create();
      await File(
        '${windowsRoot.path}${Platform.pathSeparator}ok.json',
      ).writeAsString(_validJsonSession('win-1'));
      final missingWslRoot = '${temp.path}${Platform.pathSeparator}missing-wsl';
      final cachedWslPath =
          '$missingWslRoot${Platform.pathSeparator}cached.jsonl';
      final scanner = SessionScanner(
        parser: CodexSessionParser(),
        pathMapper: mapper,
      );

      final result = await scanner.scan(
        SessionScanRequest(
          windowsRoot: windowsRoot.path,
          wslRoot: missingWslRoot,
          cachedSessions: [
            CachedSessionSnapshot(
              sourcePath: cachedWslPath,
              status: SessionFileStatus.available,
            ),
          ],
        ),
      );

      expect(result.cachedSessions.single.sourcePath, cachedWslPath);
      expect(
        result.errors.map((error) => error.status),
        isNot(contains(SessionFileStatus.missing)),
      );
      expect(result.progress.sessionsMissing, 0);
    },
  );

  test('matches cached paths by normalized scan path', () async {
    final root = Directory('${temp.path}${Platform.pathSeparator}Win');
    await root.create();
    final sessionFile = File('${root.path}${Platform.pathSeparator}ok.json');
    await sessionFile.writeAsString(_validJsonSession('win-1'));
    final scanner = SessionScanner(
      parser: CodexSessionParser(),
      pathMapper: mapper,
    );

    final result = await scanner.scan(
      SessionScanRequest(
        windowsRoot: '${root.path}${Platform.pathSeparator}',
        cachedSessions: [
          CachedSessionSnapshot(
            sourcePath: sessionFile.path.replaceAll(
              Platform.pathSeparator,
              '/',
            ),
            status: SessionFileStatus.available,
          ),
        ],
      ),
    );

    expect(result.progress.sessionsMissing, 0);
    expect(
      result.errors.map((error) => error.status),
      isNot(contains(SessionFileStatus.missing)),
    );
  });

  test('maps parser unsupported roots to unsupported format', () async {
    final root = Directory('${temp.path}${Platform.pathSeparator}win');
    await root.create();
    await File(
      '${root.path}${Platform.pathSeparator}unsupported.json',
    ).writeAsString('[1, 2, 3]');
    final scanner = SessionScanner(
      parser: CodexSessionParser(),
      pathMapper: mapper,
    );

    final result = await scanner.scan(
      SessionScanRequest(windowsRoot: root.path),
    );

    expect(result.errors.single.status, SessionFileStatus.unsupportedFormat);
    expect(
      result.fileStatuses.single.status,
      SessionFileStatus.unsupportedFormat,
    );
  });

  test('returns deterministic session and status order', () async {
    final root = Directory('${temp.path}${Platform.pathSeparator}win');
    await root.create();
    await File(
      '${root.path}${Platform.pathSeparator}b.json',
    ).writeAsString(_validJsonSession('win-b'));
    await File(
      '${root.path}${Platform.pathSeparator}a.json',
    ).writeAsString(_validJsonSession('win-a'));
    final scanner = SessionScanner(
      parser: CodexSessionParser(),
      pathMapper: mapper,
    );

    final result = await scanner.scan(
      SessionScanRequest(windowsRoot: root.path),
    );

    expect(
      result.sessions.map((session) => session.sourcePath).toList(),
      orderedEquals([
        '${root.path}${Platform.pathSeparator}a.json',
        '${root.path}${Platform.pathSeparator}b.json',
      ]),
    );
    expect(
      result.fileStatuses.map((status) => status.sourcePath).toList(),
      orderedEquals([
        '${root.path}${Platform.pathSeparator}a.json',
        '${root.path}${Platform.pathSeparator}b.json',
      ]),
    );
  });

  test('serializes statuses with spec snake-case names', () {
    expect(SessionFileStatus.available.wireName, 'available');
    expect(SessionFileStatus.missing.wireName, 'missing');
    expect(SessionFileStatus.pathUnreachable.wireName, 'path_unreachable');
    expect(SessionFileStatus.parseError.wireName, 'parse_error');
    expect(SessionFileStatus.permissionDenied.wireName, 'permission_denied');
    expect(SessionFileStatus.unsupportedFormat.wireName, 'unsupported_format');
    expect(
      SessionFileStatus.changedPendingParse.wireName,
      'changed_pending_parse',
    );
  });

  test('maps parser IO permission failures to permission denied', () async {
    final root = Directory('${temp.path}${Platform.pathSeparator}win');
    await root.create();
    await File(
      '${root.path}${Platform.pathSeparator}denied.json',
    ).writeAsString(_validJsonSession('denied'));
    final scanner = SessionScanner(
      parser: _PermissionDeniedParser(),
      pathMapper: mapper,
    );

    final result = await scanner.scan(
      SessionScanRequest(windowsRoot: root.path),
    );

    expect(result.errors.single.status, SessionFileStatus.permissionDenied);
    expect(result.progress.filesFailed, 1);
  });

  test('allows only one active scan at a time', () async {
    final root = Directory('${temp.path}${Platform.pathSeparator}win');
    await root.create();
    await File(
      '${root.path}${Platform.pathSeparator}ok.json',
    ).writeAsString(_validJsonSession('win-1'));
    final parser = _BlockingParser();
    final scanner = SessionScanner(parser: parser, pathMapper: mapper);

    final firstScan = scanner.scan(SessionScanRequest(windowsRoot: root.path));
    await parser.started.future;

    expect(
      () => scanner.scan(SessionScanRequest(windowsRoot: root.path)),
      throwsA(isA<ScanAlreadyRunningException>()),
    );

    parser.release.complete();
    await firstScan;
  });

  test('parses changed files with bounded concurrency', () async {
    final root = Directory('${temp.path}${Platform.pathSeparator}win');
    await root.create();
    for (var i = 0; i < 5; i++) {
      await File(
        '${root.path}${Platform.pathSeparator}$i.json',
      ).writeAsString(_validJsonSession('win-$i'));
    }
    final parser = _CountingParser();
    final scanner = SessionScanner(
      parser: parser,
      pathMapper: mapper,
      maxConcurrentParses: 2,
    );

    final result = await scanner.scan(
      SessionScanRequest(windowsRoot: root.path),
    );

    expect(result.progress.filesParsed, 5);
    expect(parser.maxActiveParses, 2);
  });

  test('starts parsing before directory discovery completes', () async {
    final root = Directory('${temp.path}${Platform.pathSeparator}win');
    await root.create();
    for (var i = 0; i < 200; i++) {
      await File(
        '${root.path}${Platform.pathSeparator}${i.toString().padLeft(3, '0')}.json',
      ).writeAsString(_validJsonSession('win-$i'));
    }
    final events = <ScanProgress>[];
    final parser = _ProgressCapturingParser(
      filesFound: () => events.last.filesFound,
    );
    final scanner = SessionScanner(
      parser: parser,
      pathMapper: mapper,
      maxConcurrentParses: 1,
      maxConcurrentDirectoryScans: 1,
      progressEveryWorkItems: 1,
      useParserIsolates: false,
      onProgress: events.add,
    );

    final result = await scanner.scan(
      SessionScanRequest(windowsRoot: root.path),
    );

    expect(result.progress.filesFound, 200);
    expect(parser.filesFoundAtFirstParse, isNotNull);
    expect(
      parser.filesFoundAtFirstParse!,
      lessThan(result.progress.filesFound),
    );
  });

  test('throttles progress callbacks while scanning many files', () async {
    final root = Directory('${temp.path}${Platform.pathSeparator}win');
    await root.create();
    for (var i = 0; i < 250; i++) {
      await File(
        '${root.path}${Platform.pathSeparator}notes_$i.txt',
      ).writeAsString('not a session');
    }
    final events = <ScanProgress>[];
    final scanner = SessionScanner(
      parser: CodexSessionParser(),
      pathMapper: mapper,
      onProgress: events.add,
    );

    await scanner.scan(SessionScanRequest(windowsRoot: root.path));

    expect(events.length, lessThanOrEqualTo(8));
    expect(events.first.directoriesScanned, 0);
    expect(events.last.finishedAtUtc, isNotNull);
  });

  test('emits profiling spans for major scan phases', () async {
    final root = Directory('${temp.path}${Platform.pathSeparator}win');
    await root.create();
    await File(
      '${root.path}${Platform.pathSeparator}ok.json',
    ).writeAsString(_validJsonSession('profiled'));
    final events = <ProfilingEvent>[];
    final scanner = SessionScanner(
      parser: CodexSessionParser(),
      pathMapper: mapper,
      useParserIsolates: false,
    );

    await Profiling.captureAsync(events.add, () {
      return scanner.scan(SessionScanRequest(windowsRoot: root.path));
    });

    final spanNames = {
      for (final event in events)
        if (event.kind == ProfilingEventKind.start) event.name,
    };
    expect(spanNames, contains('scan.scanner.scan'));
    expect(spanNames, contains('scan.scanner.root_discovery'));
    expect(spanNames, contains('scan.scanner.directory'));
    expect(spanNames, contains('scan.scanner.parse_decision'));
    expect(spanNames, contains('scan.scanner.parse_file'));
  });
}

String _validJsonSession(String id) =>
    '''
{
  "session_id": "$id",
  "source_type": "windows",
  "messages": [
    { "type": "user", "content": "hello" }
  ]
}
''';

class _BlockingParser extends CodexSessionParser {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<CodexParseResult> parseFile(File source) async {
    if (!started.isCompleted) {
      started.complete();
    }
    await release.future;
    return super.parseFile(source);
  }
}

class _CountingParser extends CodexSessionParser {
  int activeParses = 0;
  int maxActiveParses = 0;

  @override
  Future<CodexParseResult> parseFile(File source) async {
    activeParses++;
    if (activeParses > maxActiveParses) {
      maxActiveParses = activeParses;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final result = await super.parseFile(source);
    activeParses--;
    return result;
  }
}

class _ProgressCapturingParser extends CodexSessionParser {
  _ProgressCapturingParser({required this.filesFound});

  final int Function() filesFound;
  int? filesFoundAtFirstParse;

  @override
  Future<CodexParseResult> parseFile(File source) async {
    filesFoundAtFirstParse ??= filesFound();
    await Future<void>.delayed(Duration.zero);
    return super.parseFile(source);
  }
}

class _PermissionDeniedParser extends CodexSessionParser {
  @override
  Future<CodexParseResult> parseFile(File source) async {
    return CodexParseResult.failure(
      CodexParseError(
        sourcePath: source.path,
        kind: CodexParseErrorKind.io,
        message: 'Access is denied.',
      ),
    );
  }
}
