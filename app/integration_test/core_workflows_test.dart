import 'dart:io';

import 'package:codex_sessions_viewer/src/app/runtime_session_controller.dart';
import 'package:codex_sessions_viewer/src/commands/resume_command_generator.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/ui/models/session_label_formatter.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../test/support/collector_fixture.dart';
import '../test/support/test_environment.dart';

/// Runs against the built collector: set CODEX_SESSIONS_COLLECTOR_EXE to
/// `collector\target\debug\codex-sessions-collector.exe` (cargo build).
Future<void> main() => TestEnvironment.testMain(_main);

void _main() {
  test('core local workflows work together on fixtures', () async {
    final temp = await Directory.systemTemp.createTemp('csv_integration_');
    addTearDown(() => deleteCollectorFixture(temp));

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    final defaults = await SettingsRepository(settingsFile).loadOrCreate();
    expect(settingsFile.existsSync(), isTrue);
    expect(defaults.paths.windowsCodexPath, isNotEmpty);

    final windowsRoot = Directory(p.join(temp.path, 'windows'));
    final wslRoot = Directory(p.join(temp.path, 'wsl'));
    await windowsRoot.create();
    await wslRoot.create();
    final windowsFixture = await _copyFixture(
      'sample_windows_session.json',
      windowsRoot,
    );
    await _copyFixture('sample_wsl_session.json', wslRoot);
    final settings = defaults.copyWith(
      paths: PathSettings(
        windowsCodexPath: windowsRoot.path,
        wslCodexUncPath: wslRoot.path,
      ),
    );
    await SettingsRepository(settingsFile).save(settings);

    final dbFile = File(p.join(temp.path, 'viewer.sqlite'));
    final sqlRoot = Directory(p.normalize(p.join('..', 'sql')));
    final startup = await DatabaseMigrator(
      sqlRoot: sqlRoot,
    ).openAndMigrate(dbFile, deferUsageMigration: true);
    expect(startup.canStartNormalUi, isTrue);
    // The collector writes only a database whose persisted-usage migration
    // finished.
    final migration = await startPendingDatabaseMigration(
      dbFile,
      sqlRoot: sqlRoot,
    );
    if (migration != null) {
      expect((await migration.result).succeeded, isTrue);
    }

    // The collector parses and writes; the viewer reads what it stored.
    final controller = RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: dbFile,
      claudeProjectRoots: const [],
      // A fake resolver keeps the scan off the real wsl.exe (T-173).
      wslProjectResolver: const _NoWslProjects(),
    );
    final firstScan = await controller.refresh();
    // The collector reads WSL roots only on Windows hosts; elsewhere the
    // native root holds the host's own sessions.
    final native = Platform.isWindows
        ? SessionRowPlatform.windows
        : Platform.isMacOS
        ? SessionRowPlatform.macos
        : SessionRowPlatform.linux;
    final scanned = Platform.isWindows
        ? [SessionRowPlatform.windows, SessionRowPlatform.wsl]
        : [native];
    expect(
      firstScan.rows.map((row) => row.platform).toSet(),
      containsAll(scanned),
    );

    final db = sqlite3.open(dbFile.path);
    addTearDown(db.close);
    int lastRun(String column) =>
        db
                .select(
                  'select $column from scan_runs order by id desc limit 1',
                )
                .single[column]
            as int;
    expect(lastRun('files_parsed'), scanned.length);

    final unchangedScan = await controller.refresh();
    expect(unchangedScan.rows, hasLength(firstScan.rows.length));
    expect(lastRun('files_skipped'), scanned.length);
    expect(lastRun('files_parsed'), 0);

    final windowsRow = firstScan.rows.firstWhere(
      (row) => row.platform == native,
    );
    final reloaded = await controller.reloadSessionDetailFromSource(
      windowsRow.id,
    );
    expect(reloaded?.id, windowsRow.id);
    expect(windowsFixture.existsSync(), isTrue);

    final commandSet = ResumeCommandGenerator(settings: settings).build(
      ResumeCommandSession(
        sessionId: windowsRow.sessionId,
        sourceType: ResumeSessionSourceType.windows,
        workingDirectory: windowsRow.workingDirectory.isEmpty
            ? temp.path
            : windowsRow.workingDirectory,
      ),
    );
    expect(commandSet.plainResumeCommand, startsWith('codex resume '));
    expect(commandSet.terminalLaunchCommand, isNotNull);

    final summary = UsageSummaryRepository(db).summarize(
      UsageSummaryRequest(
        period: UsagePeriod.custom,
        nowUtc: DateTime.utc(2030),
        customStartUtc: DateTime.utc(2000),
        customEndExclusiveUtc: DateTime.utc(2030),
      ),
    );
    expect(summary.totalSessions, firstScan.rows.length);
    expect(
      summary.byPlatform.map((row) => row.key),
      containsAll(
        Platform.isWindows
            ? ['Windows', 'WSL']
            : [SessionLabelFormatter.sourceType(native.name)],
      ),
    );
  });

  testWidgets('refresh preserves active filters in the sessions screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          now: () => DateTime.utc(2026, 6, 13, 12),
          initialRows: [_row('windows', SessionRowPlatform.windows)],
          onRefresh: () async => [
            _row(
              'windows-2',
              SessionRowPlatform.windows,
              project: 'Windows refreshed',
            ),
            _row('wsl-2', SessionRowPlatform.wsl, project: 'WSL refreshed'),
          ],
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Platform filter'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Windows only').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh'));
    await tester.pumpAndSettle();

    expect(find.text('Windows refreshed'), findsOneWidget);
    expect(find.text('WSL refreshed'), findsNothing);
  });
}

Future<File> _copyFixture(String name, Directory destination) async {
  final source = File(p.normalize(p.join('..', 'samples', 'sessions', name)));
  final target = File(p.join(destination.path, name));
  await source.copy(target.path);
  return target;
}

SessionRowViewModel _row(
  String title,
  SessionRowPlatform platform, {
  String project = 'Codex Viewer',
}) {
  return SessionRowViewModel(
    id: title,
    startedAtUtc: DateTime.utc(2026, 6, 13, 9),
    lastMessageAtUtc: DateTime.utc(2026, 6, 13, 10),
    platform: platform,
    project: project,
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

class _NoWslProjects extends WslProjectResolver {
  const _NoWslProjects();

  @override
  Future<Map<String, String>> resolveProjectNames(
    Iterable<String> workingDirectories,
  ) async => const {};
}
