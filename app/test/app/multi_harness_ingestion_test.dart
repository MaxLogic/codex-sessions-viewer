@TestOn('windows')
library;

import '../support/collector_fixture.dart';

import 'dart:io';

import 'package:codex_sessions_viewer/src/app/runtime_session_controller.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/session_activity_reader.dart';
import 'package:codex_sessions_viewer/src/export/eval_dataset_exporter.dart';
import 'package:codex_sessions_viewer/src/export/eval_dataset_loader.dart';
import 'package:codex_sessions_viewer/src/search/session_search.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/session_detail_pane.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// The Rust collector (T-121) writes Codex and Claude Code sessions into the
/// viewer's database. The viewer's own repositories and widgets must browse,
/// search, and show usage for both, and a Claude session whose ID equals a
/// Codex session's ID must stay a separate session.
const _claudeSession = '11111111-2222-4333-8444-555555555555';
const _sharedId = 'parity-rich-001';

void main() {
  late Directory temp;
  late File settingsFile;
  late File database;
  late Directory claudeRoot;

  setUpAll(() async {
    temp = await Directory.systemTemp.createTemp('csv_multi_harness_');
    final codexHome = Directory(p.join(temp.path, 'codex-home'));
    final day = Directory(
      p.join(codexHome.path, 'sessions', '2026', '09', '01'),
    );
    await day.create(recursive: true);
    await File(
      '../samples/collector-parity/sessions/rich_session.jsonl',
    ).copy(p.join(day.path, 'rich_session.jsonl'));
    claudeRoot = Directory(p.join(temp.path, 'claude-projects'));
    await _copyTree(Directory('../samples/claude/projects'), claudeRoot);
    settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(
      AppSettings.defaults().copyWith(
        paths: PathSettings(
          windowsCodexPath: codexHome.path,
          wslCodexUncPath: p.join(temp.path, 'absent'),
        ),
      ),
    );

    database = File(p.join(temp.path, 'viewer.sqlite'));
    final sqlRoot = Directory('../sql');
    final startup = await DatabaseMigrator(
      sqlRoot: sqlRoot,
    ).openAndMigrate(database, deferUsageMigration: true);
    expect(
      startup.canStartNormalUi,
      isTrue,
      reason: startup.fatalError?.details,
    );
    final migration = await startPendingDatabaseMigration(
      database,
      sqlRoot: sqlRoot,
    );
    if (migration != null) {
      expect((await migration.result).succeeded, isTrue);
    }

    final executable = await _collector();
    for (final harness in [
      ['codex', 'scan'],
      ['claude', 'scan', '--claude-root', claudeRoot.path],
    ]) {
      final result = await Process.run(executable, [
        ...harness,
        '--no-wsl-projects',
        '--settings',
        settingsFile.path,
        '--db',
        database.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }
  });

  tearDownAll(() => deleteCollectorFixture(temp));

  RuntimeSessionController controller() => RuntimeSessionController(
    settingsFile: settingsFile,
    databaseFile: database,
  );

  test('both harnesses keep their own session under one shared ID', () {
    final db = openFileBackedDatabase(database);
    try {
      final rows = db.select(
        'select id, harness from sessions where session_id = ? order by harness',
        [_sharedId],
      );
      expect(
        [for (final row in rows) '${row['harness']} ${row['id']}'],
        ['claude claude:session:$_sharedId', 'codex session:$_sharedId'],
      );
      final search = SessionSearchIndex(db);
      expect(
        search.search(const SessionSearchQuery(text: 'sharing a codex id')),
        ['claude:session:$_sharedId'],
      );
      expect(search.search(const SessionSearchQuery(text: 'race')), [
        'claude:session:$_claudeSession',
      ]);
      expect(
        search.search(const SessionSearchQuery(text: 'parser')),
        contains('session:$_sharedId'),
      );
    } finally {
      db.close();
    }
  });

  test(
    'usage shows known Claude tokens and leaves absent usage unknown',
    () async {
      final result = await controller().loadCachedRows();
      final byId = {for (final row in result.rows) row.id: row};
      final claude = byId['claude:session:$_claudeSession']!;
      expect(claude.title, 'Fix flaky claude fixture');
      expect(claude.totalTokens, greaterThan(0));
      expect(claude.modelsUsed, contains('claude-opus-5-5'));
      expect(claude.costUnknown, isTrue, reason: 'Claude prices are not known');
      final subagent = byId['claude:session:$_claudeSession:agent-a1b2c3']!;
      expect(subagent.totalTokens, greaterThan(0));
      // Absent usage is unknown, never a zero-cost measurement: the row
      // shows no tokens and no cost, and the stored totals stay NULL.
      final absent = byId['claude:session:$_sharedId']!;
      expect(absent.totalTokens, 0);
      expect(absent.costUnknown, isTrue);
      expect(absent.estimatedCostText, isNull);
      expect(byId['session:$_sharedId']!.totalTokens, greaterThan(0));

      final db = openFileBackedDatabase(database);
      try {
        final summary = UsageSummaryRepository(db).summarize(
          UsageSummaryRequest(
            period: UsagePeriod.custom,
            nowUtc: DateTime.utc(2026, 9, 30),
            customStartUtc: DateTime.utc(2026, 8, 1),
            customEndExclusiveUtc: DateTime.utc(2026, 10, 1),
          ),
        );
        final claudeInput = db
            .select(
              "select sum(e.input_tokens) v from usage_events e join sessions s on s.id = e.session_row_id where s.harness = 'claude'",
            )
            .single['v'];
        expect(claudeInput, greaterThan(0));
        expect(summary.inputTokens, greaterThan(claudeInput as int));
      } finally {
        db.close();
      }
    },
  );

  test(
    'stats and eval exports read Claude sessions from stored rows',
    () async {
      final claudeId = 'claude:session:$_claudeSession';
      final activity = await loadSessionActivity(database, [
        claudeId,
        'session:$_sharedId',
      ]);
      final claude = activity[claudeId]!;
      expect(claude.turnCount, greaterThan(0));
      expect(claude.toolCallCount, greaterThan(0));
      expect(claude.span, greaterThan(Duration.zero));
      expect(
        claude.models.map((model) => model.model),
        contains('claude-opus-5-5'),
      );
      expect(activity['session:$_sharedId']!.turnCount, greaterThan(0));

      final sessions = await loadEvalDatasetSessions(database, [claudeId]);
      final session = sessions.single;
      expect(session.messages, isNotEmpty);
      expect(session.toolCalls, isNotEmpty);
      final files = const EvalDatasetExporter().export(
        EvalDatasetExportRequest(
          sessions: sessions,
          format: EvalDatasetFormat.plainTextFiles,
          turnMode: EvalTurnMode.fullConversation,
        ),
      );
      expect(files.values.single, contains('Input:'));
      expect(files.values.single, isNot(endsWith('Actual output:')));
    },
  );

  testWidgets('the Sessions screen browses and opens a Claude session', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sessions = controller();
    late SessionsRefreshResult loaded;
    await tester.runAsync(() async {
      loaded = await sessions.loadCachedRows();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: loaded.rows,
          now: () => DateTime.utc(2026, 9, 22),
          onRefresh: () async => loaded.rows,
          onLoadSessionDetail: sessions.loadSessionDetail,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Both harnesses list side by side; the subagent stays under its parent.
    expect(find.text('3 sessions visible.'), findsOneWidget);
    expect(find.text('Renamed thread'), findsOneWidget);
    expect(find.text('GPT 5.5'), findsOneWidget);
    expect(find.text('Claude Opus 5 5'), findsWidgets);
    await tester.tap(find.text('Fix flaky claude fixture').first);
    // Detail loads off the UI thread; pump until the conversation arrives.
    SessionRowViewModel? row;
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump(const Duration(milliseconds: 50));
      final panes = find.byType(SessionDetailPane);
      if (panes.evaluate().isNotEmpty) {
        row = tester.widget<SessionDetailPane>(panes.last).row;
        if (row.conversationMessages.isNotEmpty) {
          break;
        }
      }
    }
    expect(row, isNotNull);
    row!;
    expect(row.id, 'claude:session:$_claudeSession');
    expect(
      row.conversationMessages.map((message) => message.body),
      containsAll([
        'Fix the flaky claude fixture test',
        'The claude fixture test fails because of a race.',
      ]),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<String> _collector() async {
  final override = Platform.environment['CODEX_SESSIONS_COLLECTOR_EXE'];
  if (override != null && override.isNotEmpty) {
    return override;
  }
  final build = await Process.run('cargo', [
    'build',
    '--quiet',
    '--manifest-path',
    p.join('..', 'collector', 'Cargo.toml'),
    '--bin',
    'codex-sessions-collector',
  ]);
  expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
  return p.join(
    '..',
    'collector',
    'target',
    'debug',
    'codex-sessions-collector.exe',
  );
}

Future<void> _copyTree(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final entity in from.list()) {
    final target = p.join(to.path, p.basename(entity.path));
    if (entity is Directory) {
      await _copyTree(entity, Directory(target));
    } else if (entity is File) {
      await entity.copy(target);
    }
  }
}
