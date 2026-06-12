import 'dart:io';

import 'package:codex_sessions_viewer/src/parser/codex_session_parser.dart';
import 'package:codex_sessions_viewer/src/path_mapping/path_mapper.dart';
import 'package:codex_sessions_viewer/src/scanner/session_scanner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('marks a selected session for forced parsing', () {
    final sessions = [_cached('a.json'), _cached('b.json')];

    final plan = ForceReparsePlan.selected('b.json').apply(sessions);

    expect(plan.filesToParse, ['b.json']);
    expect(plan.shouldForceParse('a.json'), isFalse);
    expect(plan.shouldForceParse('b.json'), isTrue);
  });

  test('marks all sessions for forced parsing', () {
    final sessions = [_cached('a.json'), _cached('b.json')];

    final plan = ForceReparsePlan.all().apply(sessions);

    expect(plan.filesToParse, ['a.json', 'b.json']);
    expect(plan.shouldForceParse('a.json'), isTrue);
    expect(plan.shouldForceParse('b.json'), isTrue);
  });

  test('marks filtered sessions for forced parsing', () {
    final sessions = [
      _cached('project-a.json'),
      _cached('project-b.json'),
      _cached('notes.txt'),
    ];

    final plan = ForceReparsePlan.filtered(
      (session) => session.sourcePath.startsWith('project-'),
    ).apply(sessions);

    expect(plan.filesToParse, ['project-a.json', 'project-b.json']);
    expect(plan.shouldForceParse('project-a.json'), isTrue);
    expect(plan.shouldForceParse('notes.txt'), isFalse);
  });

  group('scanner force reparse', () {
    late Directory temp;
    late CodexPathMapper mapper;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('csv_force_test_');
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

    test('selected plan reparses an unchanged cached file', () async {
      final root = await _createRootWithSessions(temp, ['a', 'b']);
      final a = File('${root.path}${Platform.pathSeparator}a.json');
      final b = File('${root.path}${Platform.pathSeparator}b.json');
      final cached = [
        await CachedSessionSnapshot.fromFile(
          a,
          status: SessionFileStatus.available,
          parserVersion: CodexSessionParser.currentVersion,
        ),
        await CachedSessionSnapshot.fromFile(
          b,
          status: SessionFileStatus.available,
          parserVersion: CodexSessionParser.currentVersion,
        ),
      ];
      final parser = _CountingParser();
      final scanner = SessionScanner(parser: parser, pathMapper: mapper);

      final result = await scanner.scan(
        SessionScanRequest(
          windowsRoot: root.path,
          cachedSessions: cached,
          forceReparsePlan: ForceReparsePlan.selected(b.path),
        ),
      );

      expect(parser.parseCount, 1);
      expect(result.sessions.single.sourcePath, b.path);
      expect(result.skippedFiles.single.sourcePath, a.path);
    });

    test('all plan reparses every unchanged cached file', () async {
      final root = await _createRootWithSessions(temp, ['a', 'b']);
      final files = [
        File('${root.path}${Platform.pathSeparator}a.json'),
        File('${root.path}${Platform.pathSeparator}b.json'),
      ];
      final cached = [
        for (final file in files)
          await CachedSessionSnapshot.fromFile(
            file,
            status: SessionFileStatus.available,
            parserVersion: CodexSessionParser.currentVersion,
          ),
      ];
      final parser = _CountingParser();
      final scanner = SessionScanner(parser: parser, pathMapper: mapper);

      final result = await scanner.scan(
        SessionScanRequest(
          windowsRoot: root.path,
          cachedSessions: cached,
          forceReparsePlan: const ForceReparsePlan.all(),
        ),
      );

      expect(parser.parseCount, 2);
      expect(result.progress.filesParsed, 2);
      expect(result.skippedFiles, isEmpty);
    });

    test(
      'filtered plan reparses only matching unchanged cached files',
      () async {
        final root = await _createRootWithSessions(temp, [
          'project-a',
          'notes',
        ]);
        final project = File(
          '${root.path}${Platform.pathSeparator}project-a.json',
        );
        final notes = File('${root.path}${Platform.pathSeparator}notes.json');
        final cached = [
          await CachedSessionSnapshot.fromFile(
            project,
            status: SessionFileStatus.available,
            parserVersion: CodexSessionParser.currentVersion,
          ),
          await CachedSessionSnapshot.fromFile(
            notes,
            status: SessionFileStatus.available,
            parserVersion: CodexSessionParser.currentVersion,
          ),
        ];
        final parser = _CountingParser();
        final scanner = SessionScanner(parser: parser, pathMapper: mapper);

        final result = await scanner.scan(
          SessionScanRequest(
            windowsRoot: root.path,
            cachedSessions: cached,
            forceReparsePlan: ForceReparsePlan.filtered(
              (session) => session.sourcePath.contains('project-'),
            ),
          ),
        );

        expect(parser.parseCount, 1);
        expect(result.sessions.single.sourcePath, project.path);
        expect(result.skippedFiles.single.sourcePath, notes.path);
      },
    );
  });
}

CachedSessionSnapshot _cached(String path) => CachedSessionSnapshot(
  sourcePath: path,
  status: SessionFileStatus.available,
  sourceFileSize: 1,
  sourceModifiedUtc: DateTime.utc(2026, 1, 1),
  sourceContentHash: 'hash-$path',
  parserVersion: 1,
);

Future<Directory> _createRootWithSessions(
  Directory temp,
  List<String> ids,
) async {
  final root = Directory('${temp.path}${Platform.pathSeparator}win');
  await root.create();
  for (final id in ids) {
    await File('${root.path}${Platform.pathSeparator}$id.json').writeAsString(
      '''
{
  "session_id": "$id",
  "source_type": "windows",
  "messages": [
    { "type": "user", "content": "hello" }
  ]
}
''',
    );
  }
  return root;
}

class _CountingParser extends CodexSessionParser {
  int parseCount = 0;

  @override
  Future<CodexParseResult> parseFile(File source) async {
    parseCount++;
    return super.parseFile(source);
  }
}
