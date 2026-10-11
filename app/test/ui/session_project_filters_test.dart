import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/ui/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_sessions_screen.dart';
import '../helpers/semantics_audit.dart';

void main() {
  testWidgets('project filters remain operable in a narrow scaled window', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.binding.setSurfaceSize(const Size(960, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    for (final mode in [
      CodexThemeMode.light,
      CodexThemeMode.dark,
      CodexThemeMode.highContrastDark,
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: CodexAppTheme.themeData(mode),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: TestSessionsScreen(
            key: ValueKey(mode),
            settings: AppSettings.fromTomlMap({
              'ui': {
                'session_table': {
                  'max_sessions_per_project': 3,
                  'excluded_projects': [
                    'Tools',
                    'A project with a very long descriptive name',
                  ],
                },
              },
            }),
            initialRows: [row('keep', 'Viewer'), row('excluded', 'Tools')],
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('Exclude projects...'));
      await tester.tap(find.text('Exclude projects...'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.bySemanticsLabel('Search projects'),
        'no such project',
      );
      await tester.pumpAndSettle();
      expect(find.text('No projects match your search.'), findsOneWidget);
      await expectSemanticsAuditPasses(
        tester,
        context: 'Scaled exclusion dialog',
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
      expect(find.text('excluded'), findsNothing);
    }
    semantics.dispose();
  });

  testWidgets(
    'saved limits use activity despite table sort and retain matching children',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: TestSessionsScreen(
            settings: AppSettings.fromTomlMap({
              'ui': {
                'session_table': {
                  'max_sessions_per_project': 2,
                  'sorts': [
                    {'column': 'last_message_at', 'ascending': true},
                  ],
                },
              },
            }),
            initialRows: [
              row('needle-old', 'Viewer', hour: 8),
              row('needle-middle', 'Viewer', hour: 9),
              row('new-parent', 'Viewer', hour: 10),
              row('needle-child-one', 'Viewer', parent: 'new-parent'),
              row('needle-child-two', 'Viewer', parent: 'new-parent'),
              row('needle-unassigned-one', '', hour: 8),
              row('needle-unassigned-two', '', hour: 9),
              row('needle-unassigned-three', '', hour: 10),
            ],
          ),
        ),
      );
      await tester.enterText(find.bySemanticsLabel('Session search'), 'needle');
      await tester.pump(const Duration(milliseconds: 221));
      await tester.pumpAndSettle();
      expect(find.text('needle-old'), findsNothing);
      expect(find.text('needle-middle'), findsWidgets);
      expect(find.text('new-parent'), findsWidgets);
      expect(find.textContaining('needle-child-one'), findsWidgets);
      expect(find.textContaining('needle-child-two'), findsWidgets);
      for (final name in [
        'needle-unassigned-one',
        'needle-unassigned-two',
        'needle-unassigned-three',
      ]) {
        expect(find.text(name), findsWidgets);
      }
      expect(
        tester.getTopLeft(find.text('needle-middle').first).dy,
        lessThan(tester.getTopLeft(find.text('new-parent').first).dy),
      );
    },
  );

  testWidgets(
    'project exclusions apply atomically and filter Markdown export',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(1800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? copied;
      final states = <SessionTableSettings>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TestSessionsScreen(
              initialRows: [
                row('keep', 'Viewer'),
                row('hidden', 'Tools'),
                row('hidden-case', ' tools '),
              ],
              onCopyText: (text) async => copied = text,
              onTableStateChanged: states.add,
            ),
          ),
        ),
      );
      await tester.tap(find.text('More filters'));
      await tester.pumpAndSettle();
      expect(find.text('Exclude projects...'), findsOneWidget);
      await expectSemanticsAuditPasses(
        tester,
        context: 'Expanded project filters',
      );
      await tester.tap(find.text('Exclude projects...'));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      await expectSemanticsAuditPasses(
        tester,
        context: 'Project exclusion dialog',
      );
      await tester.enterText(find.bySemanticsLabel('Search projects'), 'Tools');
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Tools'));
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('hidden'), findsWidgets);
      final excludeButton = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Exclude projects...'),
      );
      expect(excludeButton.focusNode!.hasFocus, isTrue);
      await tester.tap(find.text('Exclude projects...'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CheckboxListTile, 'Tools'));
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('hidden'), findsNothing);
      expect(find.text('hidden-case'), findsNothing);
      expect(find.text('Excluded: Tools'), findsOneWidget);
      expect(states.last.toTomlMap()['excluded_projects'], ['Tools']);
      await tester.tap(find.bySemanticsLabel('Session list actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy visible list as Markdown'));
      await tester.pumpAndSettle();
      expect(copied, startsWith('# Sessions (1)'));
      expect(copied, contains('keep'));
      expect(copied, isNot(contains('hidden')));
      final chip = tester.widget<InputChip>(
        find.widgetWithText(InputChip, 'Excluded: Tools'),
      );
      chip.onDeleted!();
      await tester.pumpAndSettle();
      expect(find.text('hidden'), findsWidgets);
      expect(find.text('hidden-case'), findsWidgets);
      semantics.dispose();
    },
  );

  testWidgets(
    'latest N matching sessions survives search and rejects invalid input',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.binding.setSurfaceSize(const Size(1800, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final states = <SessionTableSettings>[];
      await tester.pumpWidget(
        MaterialApp(
          home: TestSessionsScreen(
            initialRows: [
              row('match-old', 'Viewer', hour: 8),
              row('match-middle', 'Viewer', hour: 9),
              row('match-new', 'Viewer', hour: 10),
              row('unrelated-newest', 'Viewer', hour: 11),
              row('match-tools', 'Tools'),
            ],
            onTableStateChanged: states.add,
          ),
        ),
      );
      await tester.tap(find.text('More filters'));
      await tester.pumpAndSettle();
      expect(find.text('Limit sessions per project'), findsOneWidget);
      await tester.tap(find.text('Limit sessions per project'));
      await tester.pumpAndSettle();
      final maximum = find.widgetWithText(TextField, 'Maximum sessions');
      await tester.enterText(maximum, '2');
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.enterText(find.bySemanticsLabel('Session search'), 'match');
      await tester.pump(const Duration(milliseconds: 221));
      await tester.pumpAndSettle();
      expect(find.text('match-new'), findsWidgets);
      expect(find.text('match-middle'), findsWidgets);
      expect(find.text('match-old'), findsNothing);
      expect(find.text('unrelated-newest'), findsNothing);
      expect(find.text('match-tools'), findsWidgets);
      expect(find.text('Latest 2 per project'), findsOneWidget);
      expect(states.last.toTomlMap()['max_sessions_per_project'], 2);
      await expectSemanticsAuditPasses(tester, context: 'Active session limit');
      await tester.enterText(maximum, '0');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Enter a positive whole number.'), findsOneWidget);
      expect(find.text('match-old'), findsNothing);
      expect(states.last.toTomlMap()['max_sessions_per_project'], 2);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
      await tester.pumpAndSettle();
      expect(find.text('match-old'), findsWidgets);
      expect(find.text('Enter a positive whole number.'), findsNothing);
      expect(states.last.toTomlMap()['max_sessions_per_project'], 0);
      semantics.dispose();
    },
  );

  testWidgets('excluded parents cannot return through matching children', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final settings = AppSettings.fromTomlMap({
      'ui': {
        'session_table': {
          'excluded_projects': ['Tools'],
          'max_sessions_per_project': 1,
        },
      },
    });
    await tester.pumpWidget(
      MaterialApp(
        home: TestSessionsScreen(
          settings: settings,
          initialRows: [
            row('excluded-parent', 'Tools'),
            row('needle-child', 'Viewer', parent: 'excluded-parent'),
            row('needle-keep', 'Viewer'),
          ],
        ),
      ),
    );
    await tester.enterText(find.bySemanticsLabel('Session search'), 'needle');
    await tester.pump(const Duration(milliseconds: 221));
    await tester.pumpAndSettle();
    expect(find.text('excluded-parent'), findsNothing);
    expect(find.textContaining('needle-child'), findsNothing);
    expect(find.text('needle-keep'), findsWidgets);
  });
}

SessionRowViewModel row(
  String id,
  String project, {
  int hour = 10,
  String parent = '',
}) => SessionRowViewModel(
  id: id,
  sessionId: id,
  title: id,
  summary: id,
  project: project,
  path: r'F:\projects\fixture',
  startedAtUtc: DateTime.utc(2026, 6, 12, 7),
  lastMessageAtUtc: DateTime.utc(2026, 6, 12, hour),
  platform: SessionRowPlatform.windows,
  model: 'gpt-5.4',
  messageCount: 3,
  totalTokens: 900,
  tags: const [],
  status: 'Available',
  threadSource: parent.isEmpty ? '' : 'subagent',
  parentThreadId: parent,
);
