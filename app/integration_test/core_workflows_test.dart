import 'dart:io';

import 'package:codex_sessions_viewer/src/commands/resume_command_generator.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/export/markdown_exporter.dart';
import 'package:codex_sessions_viewer/src/parser/codex_session_parser.dart';
import 'package:codex_sessions_viewer/src/path_mapping/path_mapper.dart';
import 'package:codex_sessions_viewer/src/scanner/session_scanner.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('core local workflows work together on fixtures', () async {
    final temp = await Directory.systemTemp.createTemp('csv_integration_');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    final settings = await SettingsRepository(settingsFile).loadOrCreate();
    expect(settingsFile.existsSync(), isTrue);
    expect(settings.paths.windowsCodexPath, isNotEmpty);

    final dbFile = File(p.join(temp.path, 'viewer.sqlite'));
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(dbFile);
    expect(startup.canStartNormalUi, isTrue);

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    final windowsFixture = await _copyFixture(
      'sample_windows_session.json',
      windowsRoot,
    );
    final wslFixture = await _copyFixture('sample_wsl_session.json', wslRoot);

    final scanner = SessionScanner(
      parser: CodexSessionParser(),
      pathMapper: const CodexPathMapper(
        wslDistro: 'Ubuntu',
        wslLinuxHome: '/home/pawel',
        wslUncRoot: r'\\wsl.localhost\Ubuntu\',
      ),
      maxConcurrentParses: 2,
    );

    final firstScan = await scanner.scan(
      SessionScanRequest(windowsRoot: windowsRoot.path, wslRoot: wslRoot.path),
    );
    expect(
      firstScan.sessions.map((session) => session.sourceType),
      containsAll([SessionSourceType.windows, SessionSourceType.wsl]),
    );
    expect(firstScan.errors, isEmpty);

    final cached = [
      await CachedSessionSnapshot.fromFile(
        windowsFixture,
        status: SessionFileStatus.available,
        parserVersion: CodexSessionParser.currentVersion,
      ),
      await CachedSessionSnapshot.fromFile(
        wslFixture,
        status: SessionFileStatus.available,
        parserVersion: CodexSessionParser.currentVersion,
      ),
    ];
    final unchangedScan = await scanner.scan(
      SessionScanRequest(
        windowsRoot: windowsRoot.path,
        wslRoot: wslRoot.path,
        cachedSessions: cached,
      ),
    );
    expect(unchangedScan.progress.filesSkipped, 2);
    expect(unchangedScan.sessions, isEmpty);

    final selectedReparse = await scanner.scan(
      SessionScanRequest(
        windowsRoot: windowsRoot.path,
        wslRoot: wslRoot.path,
        cachedSessions: cached,
        forceReparsePlan: ForceReparsePlan.selected(windowsFixture.path),
      ),
    );
    expect(
      selectedReparse.sessions.single.sourceType,
      SessionSourceType.windows,
    );

    final allReparse = await scanner.scan(
      SessionScanRequest(
        windowsRoot: windowsRoot.path,
        wslRoot: wslRoot.path,
        cachedSessions: cached,
        forceReparsePlan: const ForceReparsePlan.all(),
      ),
    );
    expect(allReparse.sessions, hasLength(2));

    final filteredReparse = await scanner.scan(
      SessionScanRequest(
        windowsRoot: windowsRoot.path,
        wslRoot: wslRoot.path,
        cachedSessions: cached,
        forceReparsePlan: ForceReparsePlan.filtered(
          (snapshot) => snapshot.sourcePath == wslFixture.path,
        ),
      ),
    );
    expect(filteredReparse.sessions.single.sourceType, SessionSourceType.wsl);

    final parsed = firstScan.sessions.first.parsedSession;
    final markdown = const MarkdownSessionExporter().exportMarkdown(
      parsed,
      const MarkdownExportRequest(scope: MarkdownExportScope.all()),
    );
    expect(markdown, contains('## Conversation'));

    final commandSet = ResumeCommandGenerator(settings: settings).build(
      ResumeCommandSession(
        sessionId: parsed.sessionId ?? 'fallback-session',
        sourceType: ResumeSessionSourceType.windows,
        workingDirectory: parsed.workingDirectoryDisplay ?? temp.path,
      ),
    );
    expect(commandSet.plainResumeCommand, startsWith('codex resume '));
    expect(commandSet.terminalLaunchCommand, isNotNull);

    final db = sqlite3.open(dbFile.path);
    addTearDown(db.close);
    _insertUsageSession(db, id: 'windows', sourceType: 'windows');
    _insertUsageSession(db, id: 'wsl', sourceType: 'wsl', isArchived: true);
    final summary = UsageSummaryRepository(db).summarize(
      UsageSummaryRequest(
        period: UsagePeriod.today,
        nowUtc: DateTime.utc(2026, 6, 13, 12),
      ),
    );
    expect(summary.totalSessions, 2);
    expect(
      summary.byPlatform.map((row) => row.key),
      containsAll(['windows', 'wsl']),
    );
    expect(
      summary.byArchiveState.map((row) => row.key),
      containsAll(['active', 'archived']),
    );
  });

  testWidgets('refresh preserves active filters in the sessions screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [_row('windows', SessionRowPlatform.windows)],
          onRefresh: () async => [
            _row('windows-2', SessionRowPlatform.windows),
            _row('wsl-2', SessionRowPlatform.wsl),
          ],
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Platform filter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Windows').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(find.text('windows-2'), findsOneWidget);
    expect(find.text('wsl-2'), findsNothing);
  });
}

Future<File> _copyFixture(String name, Directory destination) async {
  final source = File(p.normalize(p.join('..', 'samples', 'sessions', name)));
  final target = File(p.join(destination.path, name));
  await source.copy(target.path);
  return target;
}

SessionRowViewModel _row(String title, SessionRowPlatform platform) {
  return SessionRowViewModel(
    id: title,
    startedAtUtc: DateTime.utc(2026, 6, 13, 9),
    lastMessageAtUtc: DateTime.utc(2026, 6, 13, 10),
    platform: platform,
    project: 'Codex Viewer',
    path: platform == SessionRowPlatform.windows
        ? r'F:\projects\MaxLogic\codex-sessions-viewer'
        : '/home/pawel/.codex/sessions/2026/06/13/session.jsonl',
    title: title,
    summary: 'summary',
    messageCount: 1,
    totalTokens: 10,
    model: 'gpt-5.4',
    tags: const [],
    status: 'Available',
  );
}

void _insertUsageSession(
  Database db, {
  required String id,
  required String sourceType,
  bool isArchived = false,
}) {
  final now = DateTime.utc(2026, 6, 13, 12).toIso8601String();
  db.execute(
    '''
    insert into sessions (
      id, source_type, source_file_path, display_path, platform_path,
      parse_status, scan_status, started_at_utc, last_message_at_utc,
      title, message_count, input_tokens, output_tokens, cached_input_tokens,
      total_tokens, model_primary, models_used, project_name_snapshot,
      is_archived, created_at_utc, updated_at_utc
    ) values (?, ?, ?, ?, ?, 'available', 'available', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    [
      id,
      sourceType,
      '$id.jsonl',
      '$id.jsonl',
      '$id.jsonl',
      DateTime.utc(2026, 6, 13, 9).toIso8601String(),
      DateTime.utc(2026, 6, 13, 10).toIso8601String(),
      id,
      2,
      10,
      5,
      1,
      16,
      'gpt-5.4',
      '|gpt-5.4|',
      'Codex Viewer',
      isArchived ? 1 : 0,
      now,
      now,
    ],
  );
}
