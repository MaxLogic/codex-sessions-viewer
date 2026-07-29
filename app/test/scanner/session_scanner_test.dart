import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:codex_sessions_viewer/src/parser/codex_session_parser.dart';
import 'package:codex_sessions_viewer/src/path_mapping/path_mapper.dart';
import 'package:codex_sessions_viewer/src/scanner/session_scanner.dart';
import 'package:codex_sessions_viewer/src/utils/profiling.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

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
    'maps parser snapshot metadata into a pending scanned session',
    () async {
      final source = File(p.join(temp.path, 'snapshot.json'));
      await source.writeAsString(_validJsonSession('snapshot'));
      final parsed = await CodexSessionParser().parseFile(source);
      final snapshotModifiedUtc = DateTime.utc(2026, 7, 27, 12);

      final scanned = ScannedSessionFile.fromParseResult(
        sourcePath: source.path,
        sourceType: SessionSourceType.windows,
        sourceState: SessionSourceState.active,
        mappedPath: mapper.mapWindowsPath(source.path),
        parseResult: CodexParseResult.success(
          parsed.session!,
          sourceSnapshotSize: 123,
          sourceSnapshotModifiedUtc: snapshotModifiedUtc,
          sourceChangedDuringParse: true,
        ),
      );

      expect(scanned.status, SessionFileStatus.changedPendingParse);
      expect(scanned.sourceSnapshotSize, 123);
      expect(scanned.sourceSnapshotModifiedUtc, snapshotModifiedUtc);
      expect(scanned.sourceChangedDuringParse, isTrue);
    },
  );

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
      expect(result.canRunCacheRepair, isFalse);
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

  test('scans explicit active and archived roots', () async {
    final codexRoot = Directory(p.join(temp.path, 'windows-codex'));
    final activeRoot = Directory(p.join(codexRoot.path, 'sessions'));
    final archivedRoot = Directory(p.join(codexRoot.path, 'archived_sessions'));
    final unrelatedRoot = Directory(p.join(codexRoot.path, 'plugins'));
    final wslCodexRoot = Directory(p.join(temp.path, 'wsl-codex'));
    final wslActiveRoot = Directory(p.join(wslCodexRoot.path, 'sessions'));
    final wslArchivedRoot = Directory(
      p.join(wslCodexRoot.path, 'archived_sessions'),
    );
    final wslUnrelatedRoot = Directory(p.join(wslCodexRoot.path, 'plugins'));
    await activeRoot.create(recursive: true);
    await archivedRoot.create();
    await unrelatedRoot.create();
    await wslActiveRoot.create(recursive: true);
    await wslArchivedRoot.create();
    await wslUnrelatedRoot.create();
    await File(
      p.join(activeRoot.path, 'active.json'),
    ).writeAsString(_validJsonSession('active-session'));
    await File(
      p.join(archivedRoot.path, 'archived.json'),
    ).writeAsString(_validJsonSession('archived-session'));
    await File(
      p.join(unrelatedRoot.path, 'not-a-session.json'),
    ).writeAsString(_validJsonSession('unrelated-session'));
    await File(
      p.join(wslActiveRoot.path, 'wsl-active.json'),
    ).writeAsString(_validJsonSession('wsl-active-session'));
    await File(
      p.join(wslArchivedRoot.path, 'wsl-archived.json'),
    ).writeAsString(_validJsonSession('wsl-archived-session'));
    await File(
      p.join(wslUnrelatedRoot.path, 'not-a-session.json'),
    ).writeAsString(_validJsonSession('wsl-unrelated-session'));

    final result =
        await SessionScanner(
          parser: CodexSessionParser(),
          pathMapper: mapper,
        ).scan(
          SessionScanRequest(
            roots: [
              SessionScanRoot(
                path: activeRoot.path,
                availabilityRootPath: codexRoot.path,
                sourceType: SessionSourceType.windows,
                sourceState: SessionSourceState.active,
              ),
              SessionScanRoot(
                path: archivedRoot.path,
                availabilityRootPath: codexRoot.path,
                sourceType: SessionSourceType.windows,
                sourceState: SessionSourceState.codexArchived,
              ),
              SessionScanRoot(
                path: wslActiveRoot.path,
                availabilityRootPath: wslCodexRoot.path,
                sourceType: SessionSourceType.wsl,
                sourceState: SessionSourceState.active,
              ),
              SessionScanRoot(
                path: wslArchivedRoot.path,
                availabilityRootPath: wslCodexRoot.path,
                sourceType: SessionSourceType.wsl,
                sourceState: SessionSourceState.codexArchived,
              ),
            ],
          ),
        );

    expect(result.progress.filesFound, 4);
    expect(result.allConfiguredRootsReachable, isTrue);
    expect(result.canRunCacheRepair, isTrue);
    expect(
      {
        for (final session in result.sessions)
          session.parsedSession.sessionId: session.sourceState,
      },
      {
        'active-session': SessionSourceState.active,
        'archived-session': SessionSourceState.codexArchived,
        'wsl-active-session': SessionSourceState.active,
        'wsl-archived-session': SessionSourceState.codexArchived,
      },
    );
    final sessionIds = result.sessions.map(
      (session) => session.parsedSession.sessionId,
    );
    expect(sessionIds, isNot(contains('unrelated-session')));
    expect(sessionIds, isNot(contains('wsl-unrelated-session')));
    expect(
      {
        for (final session in result.sessions)
          session.parsedSession.sessionId: session.sourceType,
      },
      {
        'active-session': SessionSourceType.windows,
        'archived-session': SessionSourceType.windows,
        'wsl-active-session': SessionSourceType.wsl,
        'wsl-archived-session': SessionSourceType.wsl,
      },
    );
  });

  test(
    'treats a missing archive directory as a reachable empty source',
    () async {
      final codexRoot = Directory(p.join(temp.path, 'codex'));
      final archivedRoot = p.join(codexRoot.path, 'archived_sessions');
      await codexRoot.create(recursive: true);
      final cachedPath = p.join(archivedRoot, 'moved-away.jsonl');

      final result =
          await SessionScanner(
            parser: CodexSessionParser(),
            pathMapper: mapper,
          ).scan(
            SessionScanRequest(
              roots: [
                SessionScanRoot(
                  path: archivedRoot,
                  availabilityRootPath: codexRoot.path,
                  sourceType: SessionSourceType.windows,
                  sourceState: SessionSourceState.codexArchived,
                ),
              ],
              cachedSessions: [
                CachedSessionSnapshot(
                  sourcePath: cachedPath,
                  status: SessionFileStatus.available,
                  sourceState: SessionSourceState.codexArchived,
                ),
              ],
            ),
          );

      expect(result.progress.sessionsMissing, 1);
      expect(result.allConfiguredRootsReachable, isTrue);
      final missing = result.fileStatuses.singleWhere(
        (status) => status.sourcePath == cachedPath,
      );
      expect(missing.status, SessionFileStatus.missing);
      expect(missing.sourceState, SessionSourceState.missing);
      expect(
        result.errors,
        isNot(
          contains(
            isA<ScanFileError>().having(
              (error) => error.status,
              'status',
              SessionFileStatus.pathUnreachable,
            ),
          ),
        ),
      );
    },
  );

  test(
    'disconnect during child source probe preserves cached source state',
    () async {
      final codexRoot = p.join(temp.path, 'wsl-codex');
      final activeRoot = p.join(codexRoot, 'sessions');
      final cached = CachedSessionSnapshot(
        sourcePath: p.join(activeRoot, 'cached.jsonl'),
        status: SessionFileStatus.available,
        sourceState: SessionSourceState.active,
      );
      var ownerChecks = 0;

      final result =
          await SessionScanner(
            parser: CodexSessionParser(),
            pathMapper: mapper,
            rootExists: (directory) async {
              if (p.equals(directory.path, codexRoot)) {
                ownerChecks++;
                return ownerChecks == 1;
              }
              return false;
            },
          ).scan(
            SessionScanRequest(
              roots: [
                SessionScanRoot(
                  path: activeRoot,
                  availabilityRootPath: codexRoot,
                  sourceType: SessionSourceType.wsl,
                  sourceState: SessionSourceState.active,
                ),
              ],
              cachedSessions: [cached],
            ),
          );

      expect(ownerChecks, 2);
      expect(result.progress.sessionsMissing, 0);
      expect(result.cachedSessions, [cached]);
      expect(
        result.errors.map((error) => error.status),
        contains(SessionFileStatus.pathUnreachable),
      );
    },
  );

  test('child source access failure preserves cached source state', () async {
    final codexRoot = p.join(temp.path, 'wsl-codex');
    final activeRoot = p.join(codexRoot, 'sessions');
    final cached = CachedSessionSnapshot(
      sourcePath: p.join(activeRoot, 'cached.jsonl'),
      status: SessionFileStatus.available,
      sourceState: SessionSourceState.active,
    );

    final result =
        await SessionScanner(
          parser: CodexSessionParser(),
          pathMapper: mapper,
          rootExists: (_) async => true,
          sourceRootTypeReader: (_) async => throw FileSystemException(
            'Access is denied.',
            activeRoot,
            const OSError('Access is denied.', 5),
          ),
        ).scan(
          SessionScanRequest(
            roots: [
              SessionScanRoot(
                path: activeRoot,
                availabilityRootPath: codexRoot,
                sourceType: SessionSourceType.wsl,
                sourceState: SessionSourceState.active,
              ),
            ],
            cachedSessions: [cached],
          ),
        );

    expect(result.progress.sessionsMissing, 0);
    expect(result.cachedSessions, [cached]);
    expect(result.errors.single.status, SessionFileStatus.permissionDenied);
  });

  test(
    'cancellation during child source probe returns a cancelled scan',
    () async {
      final codexRoot = p.join(temp.path, 'wsl-codex');
      final activeRoot = p.join(codexRoot, 'sessions');
      final cancellation = ScanCancellationController();
      final cached = CachedSessionSnapshot(
        sourcePath: p.join(activeRoot, 'cached.jsonl'),
        status: SessionFileStatus.available,
        sourceState: SessionSourceState.active,
      );

      final result =
          await SessionScanner(
            parser: CodexSessionParser(),
            pathMapper: mapper,
            rootExists: (_) async => true,
            sourceRootTypeReader: (_) async {
              cancellation.cancel();
              return FileSystemEntityType.directory;
            },
          ).scan(
            SessionScanRequest(
              roots: [
                SessionScanRoot(
                  path: activeRoot,
                  availabilityRootPath: codexRoot,
                  sourceType: SessionSourceType.wsl,
                  sourceState: SessionSourceState.active,
                ),
              ],
              cachedSessions: [cached],
              cancellationToken: cancellation.token,
            ),
          );

      expect(result.cancelled, isTrue);
      expect(result.progress.sessionsMissing, 0);
      expect(result.cachedSessions, [cached]);
      expect(result.errors, isEmpty);
    },
  );

  test('unreachable or cancelled roots preserve cached source state', () async {
    final codexRoot = p.join(temp.path, 'missing-codex');
    final activePath = p.join(codexRoot, 'sessions', 'active.jsonl');
    final archivedPath = p.join(
      codexRoot,
      'archived_sessions',
      'archived.jsonl',
    );
    var availabilityChecks = 0;
    final cached = [
      CachedSessionSnapshot(
        sourcePath: activePath,
        status: SessionFileStatus.available,
        sourceState: SessionSourceState.active,
      ),
      CachedSessionSnapshot(
        sourcePath: archivedPath,
        status: SessionFileStatus.available,
        sourceState: SessionSourceState.codexArchived,
      ),
    ];

    final result =
        await SessionScanner(
          parser: CodexSessionParser(),
          pathMapper: mapper,
          rootExists: (_) async {
            availabilityChecks++;
            return false;
          },
        ).scan(
          SessionScanRequest(
            roots: [
              SessionScanRoot(
                path: p.dirname(activePath),
                availabilityRootPath: codexRoot,
                sourceType: SessionSourceType.windows,
                sourceState: SessionSourceState.active,
              ),
              SessionScanRoot(
                path: p.dirname(archivedPath),
                availabilityRootPath: codexRoot,
                sourceType: SessionSourceType.windows,
                sourceState: SessionSourceState.codexArchived,
              ),
            ],
            cachedSessions: cached,
          ),
        );

    expect(availabilityChecks, 1);
    expect(result.progress.sessionsMissing, 0);
    expect(result.cachedSessions, orderedEquals(cached));
    expect(result.errors, hasLength(1));
    expect(result.errors.single.sourcePath, codexRoot);
    expect(result.errors.single.status, SessionFileStatus.pathUnreachable);
    expect(result.allConfiguredRootsReachable, isFalse);
    expect(result.canRunCacheRepair, isFalse);

    final cancellation = ScanCancellationController();
    final cancelledResult =
        await SessionScanner(
          parser: CodexSessionParser(),
          pathMapper: mapper,
          rootExists: (_) async {
            cancellation.cancel();
            return true;
          },
        ).scan(
          SessionScanRequest(
            roots: [
              SessionScanRoot(
                path: p.dirname(activePath),
                availabilityRootPath: codexRoot,
                sourceType: SessionSourceType.windows,
                sourceState: SessionSourceState.active,
              ),
              SessionScanRoot(
                path: p.dirname(archivedPath),
                availabilityRootPath: codexRoot,
                sourceType: SessionSourceType.windows,
                sourceState: SessionSourceState.codexArchived,
              ),
            ],
            cachedSessions: cached,
            cancellationToken: cancellation.token,
          ),
        );

    expect(cancelledResult.cancelled, isTrue);
    expect(cancelledResult.allConfiguredRootsReachable, isFalse);
    expect(cancelledResult.canRunCacheRepair, isFalse);
    expect(cancelledResult.progress.sessionsMissing, 0);
    expect(cancelledResult.cachedSessions, orderedEquals(cached));
    expect(
      cancelledResult.fileStatuses.where(
        (status) => status.status == SessionFileStatus.missing,
      ),
      isEmpty,
    );
  });

  test(
    'does not mark cached sessions missing after partial root enumeration',
    () async {
      final invalidRoot = File(p.join(temp.path, 'not-a-directory'));
      await invalidRoot.writeAsString('not a directory');
      final cachedPath = p.join(invalidRoot.path, 'cached.jsonl');

      final result =
          await SessionScanner(
            parser: CodexSessionParser(),
            pathMapper: mapper,
            rootExists: (_) async => true,
          ).scan(
            SessionScanRequest(
              roots: [
                SessionScanRoot(
                  path: invalidRoot.path,
                  sourceType: SessionSourceType.windows,
                  sourceState: SessionSourceState.active,
                ),
              ],
              cachedSessions: [
                CachedSessionSnapshot(
                  sourcePath: cachedPath,
                  status: SessionFileStatus.available,
                ),
              ],
            ),
          );

      expect(result.progress.sessionsMissing, 0);
      expect(result.allConfiguredRootsReachable, isFalse);
      expect(
        result.fileStatuses.where(
          (status) => status.status == SessionFileStatus.missing,
        ),
        isEmpty,
      );
      expect(result.errors, isNotEmpty);
    },
  );

  test(
    'partial sibling source suppresses owner missing reconciliation',
    () async {
      final codexRoot = Directory(p.join(temp.path, 'codex'));
      final activeRoot = Directory(p.join(codexRoot.path, 'sessions'));
      final invalidArchive = File(p.join(codexRoot.path, 'archived_sessions'));
      await activeRoot.create(recursive: true);
      await invalidArchive.writeAsString('not a directory');
      final cachedPath = p.join(activeRoot.path, 'cached.jsonl');

      final result =
          await SessionScanner(
            parser: CodexSessionParser(),
            pathMapper: mapper,
            rootExists: (_) async => true,
          ).scan(
            SessionScanRequest(
              roots: [
                SessionScanRoot(
                  path: activeRoot.path,
                  availabilityRootPath: codexRoot.path,
                  sourceType: SessionSourceType.windows,
                  sourceState: SessionSourceState.active,
                ),
                SessionScanRoot(
                  path: invalidArchive.path,
                  availabilityRootPath: codexRoot.path,
                  sourceType: SessionSourceType.windows,
                  sourceState: SessionSourceState.codexArchived,
                ),
              ],
              cachedSessions: [
                CachedSessionSnapshot(
                  sourcePath: cachedPath,
                  status: SessionFileStatus.available,
                ),
              ],
            ),
          );

      expect(result.progress.sessionsMissing, 0);
      expect(
        result.fileStatuses.where(
          (status) => status.status == SessionFileStatus.missing,
        ),
        isEmpty,
      );
    },
  );

  test('uses cached UNC path when classifying missing WSL sources', () async {
    final wslRoot = Directory(p.join(temp.path, 'wsl-sessions'));
    await wslRoot.create();
    final missingUncPath = p.join(wslRoot.path, 'missing.jsonl');

    final result =
        await SessionScanner(
          parser: CodexSessionParser(),
          pathMapper: mapper,
        ).scan(
          SessionScanRequest(
            roots: [
              SessionScanRoot(
                path: wslRoot.path,
                sourceType: SessionSourceType.wsl,
                sourceState: SessionSourceState.active,
              ),
            ],
            cachedSessions: [
              CachedSessionSnapshot(
                sourcePath: '/home/pawel/.codex/sessions/missing.jsonl',
                sourceFileUncPath: missingUncPath,
                status: SessionFileStatus.available,
              ),
            ],
          ),
        );

    expect(result.progress.sessionsMissing, 1);
    expect(result.fileStatuses.single.status, SessionFileStatus.missing);
    expect(result.fileStatuses.single.sourceState, SessionSourceState.missing);
  });

  test(
    'streams parsed sessions without retaining successful results',
    () async {
      final windowsRoot = Directory('${temp.path}${Platform.pathSeparator}win');
      await windowsRoot.create();
      await File(
        '${windowsRoot.path}${Platform.pathSeparator}one.json',
      ).writeAsString(_validJsonSession('streamed-1'));
      await File(
        '${windowsRoot.path}${Platform.pathSeparator}two.json',
      ).writeAsString(_validJsonSession('streamed-2'));
      final streamedIds = <String>[];
      final scanner = SessionScanner(
        parser: CodexSessionParser(),
        pathMapper: mapper,
        useParserIsolates: false,
        retainParsedSessions: false,
        onSessionParsed: (session, _) async {
          streamedIds.add(session.parsedSession.sessionId!);
        },
      );

      final result = await scanner.scan(
        SessionScanRequest(windowsRoot: windowsRoot.path, wslRoot: null),
      );

      expect(streamedIds, containsAll(['streamed-1', 'streamed-2']));
      expect(result.progress.filesParsed, 2);
      expect(result.sessions, isEmpty);
      expect(result.errors, isEmpty);
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

  test('retries a temporarily unavailable WSL root', () async {
    final wslRoot = Directory('${temp.path}${Platform.pathSeparator}wsl');
    await wslRoot.create();
    await File(
      '${wslRoot.path}${Platform.pathSeparator}ok.json',
    ).writeAsString(_validJsonSession('wsl-retry'));
    var availabilityChecks = 0;
    final requestedDelays = <Duration>[];
    final scanner = SessionScanner(
      parser: CodexSessionParser(),
      pathMapper: mapper,
      wslRootRetryDelays: const [Duration(seconds: 1), Duration(seconds: 2)],
      shouldRetryWslRoot: (_) => true,
      rootExists: (directory) async {
        availabilityChecks++;
        return availabilityChecks >= 3;
      },
      retryDelay: (delay) async {
        requestedDelays.add(delay);
      },
    );

    final result = await scanner.scan(
      SessionScanRequest(wslRoot: wslRoot.path),
    );

    expect(availabilityChecks, 3);
    expect(requestedDelays, const [Duration(seconds: 1), Duration(seconds: 2)]);
    expect(result.sessions.single.parsedSession.sessionId, 'wsl-retry');
    expect(
      result.errors.map((error) => error.status),
      isNot(contains(SessionFileStatus.pathUnreachable)),
    );
  });

  test('reports an unreachable WSL root after exhausting retries', () async {
    var availabilityChecks = 0;
    final requestedDelays = <Duration>[];
    final scanner = SessionScanner(
      parser: CodexSessionParser(),
      pathMapper: mapper,
      wslRootRetryDelays: const [Duration(seconds: 1), Duration(seconds: 2)],
      rootExists: (_) async {
        availabilityChecks++;
        return false;
      },
      retryDelay: (delay) async {
        requestedDelays.add(delay);
      },
    );

    final result = await scanner.scan(
      const SessionScanRequest(wslRoot: r'\\wsl.localhost\Ubuntu\missing'),
    );

    expect(availabilityChecks, 3);
    expect(requestedDelays, const [Duration(seconds: 1), Duration(seconds: 2)]);
    expect(result.errors.single.status, SessionFileStatus.pathUnreachable);
  });

  test('does not retry an unreachable Windows root', () async {
    var availabilityChecks = 0;
    final scanner = SessionScanner(
      parser: CodexSessionParser(),
      pathMapper: mapper,
      wslRootRetryDelays: const [Duration(seconds: 1)],
      rootExists: (_) async {
        availabilityChecks++;
        return false;
      },
      retryDelay: (_) => fail('Windows roots must not be retried.'),
    );

    final result = await scanner.scan(
      const SessionScanRequest(windowsRoot: r'C:\missing'),
    );

    expect(availabilityChecks, 1);
    expect(result.errors.single.status, SessionFileStatus.pathUnreachable);
  });

  test('cancels promptly while waiting to retry a WSL root', () async {
    final retryStarted = Completer<void>();
    final neverFinishes = Completer<void>();
    final cancellation = ScanCancellationController();
    final scanner = SessionScanner(
      parser: CodexSessionParser(),
      pathMapper: mapper,
      wslRootRetryDelays: const [Duration(seconds: 30)],
      rootExists: (_) async => false,
      retryDelay: (_) {
        retryStarted.complete();
        return neverFinishes.future;
      },
    );

    final scan = scanner.scan(
      SessionScanRequest(
        wslRoot: r'\\wsl.localhost\Ubuntu\missing',
        cancellationToken: cancellation.token,
      ),
    );
    await retryStarted.future;
    cancellation.cancel();
    final result = await scan.timeout(const Duration(seconds: 1));

    expect(result.cancelled, isTrue);
    expect(result.errors, isEmpty);
  });

  test(
    'does not report an unreachable root when cancelled during lookup',
    () async {
      final cancellation = ScanCancellationController();
      final scanner = SessionScanner(
        parser: CodexSessionParser(),
        pathMapper: mapper,
        wslRootRetryDelays: const [Duration(seconds: 1)],
        rootExists: (_) async {
          cancellation.cancel();
          return false;
        },
        retryDelay: (_) => fail('A cancelled scan must not wait to retry.'),
      );

      final result = await scanner.scan(
        SessionScanRequest(
          wslRoot: r'\\wsl.localhost\Ubuntu\missing',
          cancellationToken: cancellation.token,
        ),
      );

      expect(result.cancelled, isTrue);
      expect(result.errors, isEmpty);
    },
  );

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
        wslRootRetryDelays: const [],
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

  test('cancels active scans and stops queued parse work', () async {
    final root = Directory('${temp.path}${Platform.pathSeparator}win');
    await root.create();
    for (var i = 0; i < 5; i++) {
      await File(
        '${root.path}${Platform.pathSeparator}$i.json',
      ).writeAsString(_validJsonSession('cancel-$i'));
    }
    final cancellation = ScanCancellationController();
    var parsedCallbacks = 0;
    final scanner = SessionScanner(
      parser: CodexSessionParser(),
      pathMapper: mapper,
      maxConcurrentParses: 1,
      useParserIsolates: false,
      onSessionParsed: (_, _) async {
        parsedCallbacks++;
        cancellation.cancel();
      },
    );

    final result = await scanner.scan(
      SessionScanRequest(
        windowsRoot: root.path,
        cancellationToken: cancellation.token,
      ),
    );

    expect(result.cancelled, isTrue);
    expect(result.progress.cancelled, isTrue);
    expect(parsedCallbacks, 1);
    expect(result.sessions, hasLength(1));
    await expectLater(cancellation.acknowledged, completes);

    final followUp = await scanner.scan(
      SessionScanRequest(windowsRoot: root.path),
    );
    expect(followUp.cancelled, isFalse);
    expect(followUp.sessions, hasLength(5));
  });

  test(
    'cancellation acknowledgement waits for parser isolate pool close',
    () async {
      final root = Directory('${temp.path}${Platform.pathSeparator}win');
      await root.create();
      for (var i = 0; i < 20; i++) {
        await File(
          '${root.path}${Platform.pathSeparator}$i.json',
        ).writeAsString(_validJsonSession('isolate-cancel-$i'));
      }
      final cancellation = ScanCancellationController();
      final closeStarted = Completer<void>();
      final releaseClose = Completer<void>();
      var cancelRequested = false;
      final scanner = SessionScanner(
        parser: CodexSessionParser(),
        pathMapper: mapper,
        maxConcurrentParses: 1,
        progressEveryWorkItems: 1,
        onParserPoolClosing: () async {
          if (!closeStarted.isCompleted) {
            closeStarted.complete();
          }
          await releaseClose.future;
        },
        onProgress: (progress) {
          if (!cancelRequested && progress.filesFound > 0) {
            cancelRequested = true;
            cancellation.cancel();
          }
        },
      );

      final scan = scanner.scan(
        SessionScanRequest(
          windowsRoot: root.path,
          cancellationToken: cancellation.token,
        ),
      );

      await closeStarted.future;
      var acknowledged = false;
      unawaited(cancellation.acknowledged.then((_) => acknowledged = true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(acknowledged, isFalse);

      releaseClose.complete();
      final result = await scan;
      await cancellation.acknowledged;

      expect(result.cancelled, isTrue);
      expect(acknowledged, isTrue);
    },
  );

  test(
    'fails promptly when a parser worker exits during startup',
    () async {
      final root = Directory('${temp.path}${Platform.pathSeparator}win');
      await root.create();
      await File(
        '${root.path}${Platform.pathSeparator}session.json',
      ).writeAsString(_validJsonSession('worker-exit'));
      final scanner = SessionScanner(
        parser: CodexSessionParser(),
        pathMapper: mapper,
        maxConcurrentParses: 1,
        parserIsolateEntrypoint: _exitParserWorkerImmediately,
        parserWorkerStartupTimeout: const Duration(milliseconds: 100),
      );

      await expectLater(
        scanner.scan(SessionScanRequest(windowsRoot: root.path)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('exited before becoming ready'),
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 2)),
  );

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

  test(
    'checks cached file metadata without occupying parser workers',
    () async {
      final root = Directory('${temp.path}${Platform.pathSeparator}win');
      await root.create();
      final cached = <CachedSessionSnapshot>[];
      for (var i = 0; i < 20; i++) {
        final file = File(
          '${root.path}${Platform.pathSeparator}cached-$i.json',
        );
        await file.writeAsString(_validJsonSession('cached-$i'));
        cached.add(
          await CachedSessionSnapshot.fromFile(
            file,
            status: SessionFileStatus.available,
            parserVersion: CodexSessionParser.currentVersion,
          ),
        );
      }
      await File(
        '${root.path}${Platform.pathSeparator}changed.json',
      ).writeAsString(_validJsonSession('changed'));

      var activeStats = 0;
      var maxActiveStats = 0;
      final statRelease = Completer<void>();
      final parser = _CountingParser();
      final scanner = SessionScanner(
        parser: parser,
        pathMapper: mapper,
        useParserIsolates: false,
        maxConcurrentParses: 1,
        maxConcurrentMetadataChecks: 5,
        fileStatReader: (file) async {
          activeStats++;
          if (activeStats > maxActiveStats) {
            maxActiveStats = activeStats;
          }
          await statRelease.future;
          try {
            return await file.stat();
          } finally {
            activeStats--;
          }
        },
      );

      final scan = scanner.scan(
        SessionScanRequest(windowsRoot: root.path, cachedSessions: cached),
      );
      while (maxActiveStats < 5) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      statRelease.complete();
      final result = await scan;

      expect(maxActiveStats, 5);
      expect(parser.maxActiveParses, 1);
      expect(result.progress.filesSkipped, 20);
      expect(result.progress.filesParsed, 1);
    },
  );

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

  test('append during parse never caches an unread suffix', () async {
    final root = Directory(p.join(temp.path, 'append-race'));
    await root.create();
    final source = File(p.join(root.path, 'growing.jsonl'));
    await source.writeAsString(
      [
        '{"timestamp":"2026-07-27T10:00:00Z","type":"session_meta","payload":{"id":"growing-snapshot","cwd":"F:\\\\repo"}}',
        '{"timestamp":"2026-07-27T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":"before append"}}',
      ].join('\n'),
    );
    final initialStat = await source.stat();
    var appended = false;
    final parser = CodexSessionParser(
      jsonlByteStreamReader: (file, endExclusive) async* {
        final bytes = await file
            .openRead(0, endExclusive)
            .fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
        final split = bytes.length ~/ 2;
        yield bytes.sublist(0, split);
        await file.writeAsString(
          '\n{"timestamp":"2026-07-27T10:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":"unread append"}}',
          mode: FileMode.append,
          flush: true,
        );
        appended = true;
        yield bytes.sublist(split);
      },
    );

    final first = await SessionScanner(
      parser: parser,
      pathMapper: mapper,
      useParserIsolates: false,
    ).scan(SessionScanRequest(windowsRoot: root.path));

    expect(appended, isTrue);
    expect(first.sessions, hasLength(1));
    final parsed = first.sessions.single;
    expect(parsed.parsedSession.messages, hasLength(1));
    expect(parsed.sourceSnapshotSize, initialStat.size);
    expect(parsed.sourceSnapshotModifiedUtc, initialStat.modified.toUtc());
    expect(parsed.sourceChangedDuringParse, isTrue);
    expect(parsed.status, SessionFileStatus.changedPendingParse);
    expect(
      first.fileStatuses.single.status,
      SessionFileStatus.changedPendingParse,
    );
    expect(first.canRunCacheRepair, isTrue);
    expect(await source.length(), greaterThan(initialStat.size));

    final second =
        await SessionScanner(
          parser: CodexSessionParser(),
          pathMapper: mapper,
          useParserIsolates: false,
        ).scan(
          SessionScanRequest(
            windowsRoot: root.path,
            cachedSessions: [
              CachedSessionSnapshot(
                sourcePath: source.path,
                status: SessionFileStatus.available,
                sourceFileSize: parsed.sourceSnapshotSize,
                sourceModifiedUtc: parsed.sourceSnapshotModifiedUtc,
                parserVersion: CodexSessionParser.currentVersion,
              ),
            ],
          ),
        );

    expect(second.progress.filesParsed, 1);
    expect(second.sessions.single.parsedSession.messages, hasLength(2));
  });
}

void _exitParserWorkerImmediately(Object? _) => Isolate.exit();

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
