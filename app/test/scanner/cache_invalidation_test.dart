import 'dart:io';

import 'package:codex_sessions_viewer/src/parser/codex_session_parser.dart';
import 'package:codex_sessions_viewer/src/path_mapping/path_mapper.dart';
import 'package:codex_sessions_viewer/src/scanner/session_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late CodexPathMapper mapper;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('csv_cache_test_');
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

  test('skips unchanged cached files without reparsing', () async {
    final root = await _createRootWithSession('unchanged', temp);
    final file = File('${root.path}${Platform.pathSeparator}unchanged.json');
    final metadata = await CachedSessionSnapshot.fromFile(
      file,
      status: SessionFileStatus.available,
      parserVersion: CodexSessionParser.currentVersion,
    );
    final parser = _CountingParser();
    final scanner = SessionScanner(parser: parser, pathMapper: mapper);

    final result = await scanner.scan(
      SessionScanRequest(windowsRoot: root.path, cachedSessions: [metadata]),
    );

    expect(parser.parseCount, 0);
    expect(result.progress.filesFound, 1);
    expect(result.progress.filesSkipped, 1);
    expect(result.progress.filesParsed, 0);
    expect(result.skippedFiles.single.sourcePath, file.path);
    expect(result.fileStatuses.single.status, SessionFileStatus.available);
  });

  test('parses when size, modified time, or parser version changes', () async {
    final root = await _createRootWithSession('changed', temp);
    final file = File('${root.path}${Platform.pathSeparator}changed.json');
    final actual = await CachedSessionSnapshot.fromFile(
      file,
      status: SessionFileStatus.available,
      parserVersion: CodexSessionParser.currentVersion,
    );
    final staleSnapshots = [
      actual.copyWith(sourceFileSize: actual.sourceFileSize! - 1),
      actual.copyWith(
        sourceModifiedUtc: actual.sourceModifiedUtc!.subtract(
          const Duration(seconds: 3),
        ),
      ),
      actual.copyWith(sourceFileSize: null),
      actual.copyWith(sourceModifiedUtc: null),
      actual.copyWith(parserVersion: CodexSessionParser.currentVersion - 1),
    ];

    for (final stale in staleSnapshots) {
      final parser = _CountingParser();
      final scanner = SessionScanner(parser: parser, pathMapper: mapper);

      final result = await scanner.scan(
        SessionScanRequest(windowsRoot: root.path, cachedSessions: [stale]),
      );

      expect(parser.parseCount, 1);
      expect(result.progress.filesParsed, 1);
      expect(result.progress.sessionsChanged, 1);
    }
  });

  test(
    'skips same-size files inside timestamp tolerance without hashing content',
    () async {
      final root = await _createRootWithSession('same-size-a', temp);
      final file = File(
        '${root.path}${Platform.pathSeparator}same-size-a.json',
      );
      final actual = await CachedSessionSnapshot.fromFile(
        file,
        status: SessionFileStatus.available,
        parserVersion: CodexSessionParser.currentVersion,
      );
      await file.writeAsString(_validJsonSession('same-size-b'));
      await file.setLastModified(
        actual.sourceModifiedUtc!.add(const Duration(seconds: 1)),
      );
      final parser = _CountingParser();
      final scanner = SessionScanner(parser: parser, pathMapper: mapper);

      final result = await scanner.scan(
        SessionScanRequest(
          windowsRoot: root.path,
          cachedSessions: [
            actual.copyWith(sourceContentHash: 'definitely-stale'),
          ],
        ),
      );

      expect(parser.parseCount, 0);
      expect(result.progress.filesSkipped, 1);
      expect(result.progress.filesParsed, 0);
    },
  );

  test('skips unchanged cached files when content hash is absent', () async {
    final root = await _createRootWithSession('no-hash', temp);
    final file = File('${root.path}${Platform.pathSeparator}no-hash.json');
    final actual = await CachedSessionSnapshot.fromFile(
      file,
      status: SessionFileStatus.available,
      parserVersion: CodexSessionParser.currentVersion,
    );
    final parser = _CountingParser();
    final scanner = SessionScanner(parser: parser, pathMapper: mapper);

    final result = await scanner.scan(
      SessionScanRequest(
        windowsRoot: root.path,
        cachedSessions: [actual.copyWith(sourceContentHash: null)],
      ),
    );

    expect(parser.parseCount, 0);
    expect(result.progress.filesSkipped, 1);
  });

  test('parses cached files whose source status is not available', () async {
    final root = await _createRootWithSession('pending', temp);
    final file = File('${root.path}${Platform.pathSeparator}pending.json');
    final actual = await CachedSessionSnapshot.fromFile(
      file,
      status: SessionFileStatus.parseError,
      parserVersion: CodexSessionParser.currentVersion,
    );
    final parser = _CountingParser();
    final scanner = SessionScanner(parser: parser, pathMapper: mapper);

    final result = await scanner.scan(
      SessionScanRequest(windowsRoot: root.path, cachedSessions: [actual]),
    );

    expect(parser.parseCount, 1);
    expect(result.progress.filesParsed, 1);
  });

  test('matches WSL cache by source UNC path without reparsing', () async {
    final root = await _createRootWithSession('wsl-cached', temp);
    final file = File('${root.path}${Platform.pathSeparator}wsl-cached.json');
    final actual = await CachedSessionSnapshot.fromFile(
      file,
      status: SessionFileStatus.available,
      parserVersion: CodexSessionParser.currentVersion,
    );
    final cached = actual.copyWith(
      sourcePath: '/home/pawel/.codex/sessions/wsl-cached.json',
      sourceFileUncPath: file.path,
    );
    final parser = _CountingParser();
    final scanner = SessionScanner(parser: parser, pathMapper: mapper);

    final result = await scanner.scan(
      SessionScanRequest(wslRoot: root.path, cachedSessions: [cached]),
    );

    expect(parser.parseCount, 0);
    expect(result.progress.filesSkipped, 1);
  });

  test('parses timestamp-only changes outside tolerance', () async {
    final root = await _createRootWithSession('touched', temp);
    final file = File('${root.path}${Platform.pathSeparator}touched.json');
    final actual = await CachedSessionSnapshot.fromFile(
      file,
      status: SessionFileStatus.available,
      parserVersion: CodexSessionParser.currentVersion,
    );
    await file.setLastModified(
      actual.sourceModifiedUtc!.add(const Duration(minutes: 1)),
    );
    final parser = _CountingParser();
    final scanner = SessionScanner(parser: parser, pathMapper: mapper);

    final result = await scanner.scan(
      SessionScanRequest(windowsRoot: root.path, cachedSessions: [actual]),
    );

    expect(parser.parseCount, 1);
    expect(result.progress.filesParsed, 1);
  });
}

Future<Directory> _createRootWithSession(String id, Directory temp) async {
  final root = Directory('${temp.path}${Platform.pathSeparator}win-$id');
  await root.create();
  await File(
    '${root.path}${Platform.pathSeparator}$id.json',
  ).writeAsString(_validJsonSession(id));
  return root;
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

class _CountingParser extends CodexSessionParser {
  int parseCount = 0;

  @override
  Future<CodexParseResult> parseFile(File source) async {
    parseCount++;
    return super.parseFile(source);
  }
}
