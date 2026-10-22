import 'dart:io';

import 'package:codex_sessions_viewer/src/commands/resume_command_generator.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/export/session_list_exporter.dart';
import 'package:codex_sessions_viewer/src/search/message_search.dart';
import 'package:codex_sessions_viewer/src/ui/screens/context_search_screen.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/menu_header_entry.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/session_detail_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../helpers/test_sessions_screen.dart';

void main() {
  test('message search carries the stored harness from SQLite into results', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    for (final file in [
      'init/001_initial_schema.sql',
      'migration/007_session_thread_name.sql',
      'migration/009_message_search.sql',
      'migration/012_external_content_search.sql',
    ]) {
      db.execute(File('../sql/$file').readAsStringSync());
    }
    db.execute(
      "alter table sessions add column harness text not null default 'codex'",
    );
    db.execute(
      '''insert into sessions (id, source_type, source_file_path, display_path,
      platform_path, created_at_utc, updated_at_utc, harness)
      values ('claude:session:id', 'windows', 'fixture.jsonl', 'fixture.jsonl',
      'fixture.jsonl', '2026-06-15', '2026-06-15', 'claude')''',
    );
    db.execute(
      '''insert into messages (session_id, message_index, author_type,
      content_plain, first_line, content_preview, created_at_db_utc, updated_at_db_utc)
      values ('claude:session:id', 0, 'user', 'needle', 'needle', 'needle', '2026-06-15', '2026-06-15')''',
    );
    final results = MessageSearchIndex(
      db,
    ).search(const MessageSearchQuery(text: 'needle'));
    expect(results.single.harness, 'claude');
  });
  testWidgets(
    'mixed rows expose harness labels, correct commands and supported actions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(5000, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();
      try {
        final actions = <SessionActionRequest>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: TestSessionsScreen(
                initialRows: [_row('codex'), _row('claude')],
                onSessionAction: (request) async => actions.add(request),
              ),
            ),
          ),
        );
        expect(
          tester
              .getSemantics(
                find.bySemanticsLabel(
                  RegExp(r'Session identity claude fixture'),
                ),
              )
              .getSemanticsData()
              .value,
          'Harness Claude Code',
        );
        expect(
          tester
              .getSemantics(
                find.bySemanticsLabel(
                  RegExp(r'Session identity codex fixture'),
                ),
              )
              .getSemanticsData()
              .value,
          'Harness Codex',
        );
        for (final harness in ['codex', 'claude']) {
          await tester.tap(
            find.bySemanticsLabel('More actions for $harness fixture'),
          );
          await tester.pumpAndSettle();
          expect(
            find.widgetWithText(
              MenuHeaderEntry<SessionRowAction>,
              harness == 'claude' ? 'Claude Code' : 'Codex',
            ),
            findsOneWidget,
          );
          expect(
            find.text('Open terminal and fork'),
            harness == 'codex' ? findsOneWidget : findsNothing,
          );
          expect(
            find.text('Re-parse session'),
            harness == 'codex' ? findsOneWidget : findsNothing,
          );
          await tester.tap(find.text('Copy plain resume command'));
          await tester.pumpAndSettle();
        }
        expect(actions.map((r) => r.payload), [
          'codex resume same-id',
          r'pushd "C:\project" && claude --resume same-id',
        ]);

        final filter = find.bySemanticsLabel('Harness filter');
        final data = tester.getSemantics(filter).getSemanticsData();
        expect(data.value, 'All harnesses');
        expect(data.hasAction(SemanticsAction.tap), isTrue);
        await tester.tap(filter);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byWidgetPredicate((w) => w is CheckedPopupMenuItem),
            matching: find.text('Claude Code'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSemantics(filter).getSemanticsData().value,
          'Claude Code',
        );
        expect(
          find.bySemanticsLabel('More actions for codex fixture'),
          findsNothing,
        );
        expect(
          find.bySemanticsLabel('More actions for claude fixture'),
          findsOneWidget,
        );
        await tester.tap(filter);
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byWidgetPredicate((w) => w is CheckedPopupMenuItem),
            matching: find.text('All harnesses'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.bySemanticsLabel('More actions for codex fixture'),
          findsOneWidget,
        );
        expect(
          find.bySemanticsLabel('More actions for claude fixture'),
          findsOneWidget,
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'Claude detail shows harness and omits fork in commands and menus',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionDetailPane(
              row: _row('claude'),
              initialTab: SessionDetailTab.details,
              onSessionAction: (_) async {},
            ),
          ),
        ),
      );
      expect(find.text('Claude Code'), findsWidgets);
      expect(find.text('Open in terminal and fork'), findsNothing);
      expect(find.text('Re-parse this session'), findsNothing);
      await tester.tap(
        find.byTooltip('More actions for selected session').first,
      );
      await tester.pumpAndSettle();
      expect(find.text('Open in terminal and fork'), findsNothing);
    },
  );

  testWidgets(
    'Claude selection never starts the Codex source-file reparse watcher',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var watched = 0;
      var reparsed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TestSessionsScreen(
              initialRows: [_row('claude', sourceFilePath: 'claude.jsonl')],
              watchSessionFile: (_) {
                watched++;
                return const Stream<FileSystemEvent>.empty();
              },
              onReloadSessionDetailFromSource: (_) async {
                reparsed++;
                return _row('claude');
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('claude fixture').first);
      await tester.pumpAndSettle();
      expect(find.byType(SessionDetailPane), findsOneWidget);
      expect(watched, 0);
      expect(reparsed, 0);
    },
  );

  test(
    'Windows and WSL commands preserve harness and reject unsupported IDs',
    () {
      final generator = ResumeCommandGenerator(
        settings: AppSettings.defaults(),
      );
      for (final platform in ResumeSessionSourceType.values) {
        final result = generator.build(
          ResumeCommandSession(
            sessionId: 'same-id',
            sourceType: platform,
            workingDirectory: platform == ResumeSessionSourceType.wsl
                ? '/home/test/project'
                : r'C:\project',
            harness: 'claude',
          ),
        );
        expect(
          result.plainResumeCommand,
          platform == ResumeSessionSourceType.wsl
              ? "cd '/home/test/project' && claude --resume same-id"
              : r'pushd "C:\project" && claude --resume same-id',
        );
        expect(result.platformResumeCommand, contains('claude'));
        expect(result.terminalLaunchCommand, contains('claude'));
        expect(result.plainForkCommand, isNull);
        expect(result.platformForkCommand, isNull);
        expect(result.terminalForkLaunchSpec, isNull);
      }
      for (final harness in ['claude', 'unsupported']) {
        final result = generator.build(
          ResumeCommandSession(
            sessionId: 'bad; echo injected',
            sourceType: ResumeSessionSourceType.windows,
            workingDirectory: r'C:\project',
            harness: harness,
          ),
        );
        expect(result.canResume, isFalse);
        expect(result.disabledReason, isNotEmpty);
      }
    },
  );

  test(
    'list and conversation exports identify the harness and use its commands',
    () {
      final exporter = SessionListExporter(settings: AppSettings.defaults());
      final rows = [_row('codex'), _row('claude')];
      final markdown = exporter.exportMarkdown(rows);
      expect(markdown, contains('Harness: Codex'));
      expect(markdown, contains('Harness: Claude Code'));
      expect(markdown, contains('claude --resume same-id'));
      final csv = exporter.exportCsv(rows);
      expect(csv.split('\n').first, contains('harness'));
      expect(csv, contains('Claude Code'));
      expect(
        sessionConversationMarkdown(_row('claude'), []),
        contains('**Harness:** Claude Code'),
      );
    },
  );

  testWidgets('message search results expose and copy their harness', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final copied = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContextSearchScreen(
            initialSessionRows: const [],
            onSearchMessages: (_) async => [
              const MessageSearchResult(
                sessionId: 'claude:session:same-id',
                messageIndex: 1,
                author: 'user',
                snippet: 'needle',
                sessionIdentity: 'Claude fixture',
                sessionTitle: 'Claude fixture',
                projectName: 'Project',
                sourceType: 'windows',
                timestampUtc: null,
                harness: 'claude',
              ),
            ],
            onCopyContext: (text) async => copied.add(text),
          ),
        ),
      ),
    );
    await tester.enterText(find.bySemanticsLabel('Context query'), 'needle');
    await tester.tap(find.bySemanticsLabel('Search context'));
    await tester.pumpAndSettle();
    expect(find.text('Claude Code'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'Claude fixture message 1.*Claude Code')),
      findsOneWidget,
    );
    await tester.tap(
      find.bySemanticsLabel('Select context result Claude fixture message 1'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Copy selected context results'));
    await tester.pumpAndSettle();
    expect(copied.single, contains('Claude Code'));
  });
}

SessionRowViewModel _row(String harness, {String sourceFilePath = ''}) =>
    SessionRowViewModel(
      id: '$harness:session:same-id',
      sessionId: 'same-id',
      harness: harness,
      sourceFilePath: sourceFilePath,
      startedAtUtc: DateTime.utc(2026, 6, 15, 10),
      lastMessageAtUtc: DateTime.utc(2026, 6, 15, 11),
      platform: SessionRowPlatform.windows,
      project: 'Project',
      path: r'C:\project',
      title: '$harness fixture',
      summary: '',
      messageCount: 1,
      totalTokens: 10,
      model: 'test-model',
      tags: const [],
      status: 'Ready',
    );
