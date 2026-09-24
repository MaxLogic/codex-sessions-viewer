import 'dart:io';

import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:codex_sessions_viewer/src/search/session_search.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/session_search_fixture.dart';
import 'package:path/path.dart' as p;

/// Fixture sessions shared by the isolated database and the Sessions rows:
/// a resumable Codex session, a Claude Code session, and a session without a
/// parsed session ID (resume unavailable).
List<SessionRowViewModel> isolatedAppRows() => [
  _row(
    id: 'session:codex-fixture',
    sessionId: '01a0c847-6277-7652-8ac0-b67bd2253042',
    title: 'Codex fixture',
    harness: 'codex',
  ),
  _row(
    id: 'claude:session:claude-fixture',
    sessionId: 'b2c3d4e5-0000-4000-8000-000000000001',
    title: 'Claude fixture',
    harness: 'claude',
  ),
  _row(
    id: 'session:unsafe-id-fixture',
    sessionId: 'unsafe id & more',
    title: 'Unsafe ID fixture',
  ),
  // Cached database rows need a session ID, so the app shows this row only
  // after a refresh; widget tests use it directly.
  _row(id: 'session:no-id-fixture', sessionId: '', title: 'No ID fixture'),
];

/// An app wired to a temporary settings file, log file and migrated database
/// holding [isolatedAppRows]. Cached rows load from that database and refresh
/// returns the fixture rows, so the test never scans or opens the user's real
/// sessions, settings or database.
Future<CodexSessionsViewerApp> createIsolatedApp(WidgetTester tester) async {
  final temp = Directory.systemTemp.createTempSync('csv_isolated_app_');
  final settingsFile = File(p.join(temp.path, 'settings.toml'));
  final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
  final settings = AppSettings.defaults().copyWith(
    paths: PathSettings(
      windowsCodexPath: p.join(temp.path, 'codex'),
      wslCodexUncPath: p.join(temp.path, 'absent-wsl'),
    ),
    scanner: const ScannerSettings(
      backgroundRescanEnabled: false,
      backgroundRescanIntervalSeconds: 3600,
    ),
    logging: LoggingSettings(
      level: 'info',
      logFile: p.join(temp.path, 'logs', 'viewer.log'),
      maxLogFiles: 1,
      maxLogSizeMb: 1,
    ),
  );
  final rows = isolatedAppRows();
  await tester.runAsync(() async {
    await SettingsRepository(settingsFile).save(settings);
    final migrated = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(databaseFile);
    expect(migrated.canStartNormalUi, isTrue);
    final db = openFileBackedDatabase(databaseFile);
    try {
      final store = ProjectTagStateStore(db);
      for (final row in rows) {
        SessionSearchIndex(db).upsert(
          SessionSearchDocument(
            id: row.id,
            sourceType: SessionSearchSourceType.windows,
            sourceFilePath: '${row.title}.jsonl',
            displayPath: '${row.title}.jsonl',
            platformPath: '${row.title}.jsonl',
            title: row.title,
            summary: row.summary,
            startedAtUtc: row.startedAtUtc,
            lastMessageAtUtc: row.lastMessageAtUtc,
            totalTokens: row.totalTokens,
          ),
        );
        final project = store.upsertProject(name: row.project);
        db.execute(
          'update sessions set session_id = ?, harness = ?, '
          'working_directory_display = ?, detected_project_id = ? '
          'where id = ?',
          [
            row.sessionId.isEmpty ? null : row.sessionId,
            row.harness,
            row.path,
            project,
            row.id,
          ],
        );
        store.refreshSessionProject(row.id);
      }
    } finally {
      db.close();
    }
  });
  addTearDown(() async {
    await tester.runAsync(() async {
      for (var attempt = 0; attempt < 10; attempt++) {
        try {
          temp.deleteSync(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    });
  });
  return CodexSessionsViewerApp(
    settingsFile: settingsFile,
    databaseFile: databaseFile,
    settingsStartup: Future.value(settings),
    databaseStartup: Future.value(
      DatabaseStartupResult.ready(lastAppliedSchemaVersion: 0),
    ),
    sessionRefresh: () async => SessionsRefreshResult.scanFinished(rows),
    now: () => DateTime.utc(2026, 6, 15, 12),
  );
}

SessionRowViewModel _row({
  required String id,
  required String sessionId,
  required String title,
  String harness = 'codex',
}) => SessionRowViewModel(
  id: id,
  sessionId: sessionId,
  harness: harness,
  startedAtUtc: DateTime.utc(2026, 6, 15, 9),
  lastMessageAtUtc: DateTime.utc(2026, 6, 15, 10),
  platform: SessionRowPlatform.windows,
  project: 'Fixture project',
  path: r'C:\fixtures\project',
  workingDirectory: r'C:\fixtures\project',
  title: title,
  summary: '$title summary',
  messageCount: 3,
  totalTokens: 1200,
  model: 'gpt-5.4',
  tags: const ['fixture'],
  status: 'Available',
);
