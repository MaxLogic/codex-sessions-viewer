import 'dart:ui' show Tristate;

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_sessions_screen.dart';

void main() {
  Future<void> setSize(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  String filterValue(WidgetTester tester, String label) =>
      tester.widget<Semantics>(find.bySemanticsLabel(label)).properties.value!;

  Finder menuItem(String text) => find.descendant(
    of: find.byWidgetPredicate((widget) => widget is CheckedPopupMenuItem),
    matching: find.text(text),
  );

  testWidgets(
    'filter menu applies the chosen value when options change while it is open',
    (tester) async {
      await setSize(tester);
      final rows = [
        _row(id: 'a', title: 'Alpha work', project: 'Alpha'),
        _row(id: 'c', title: 'Gamma work', project: 'Gamma'),
      ];
      await tester.pumpWidget(
        MaterialApp(home: TestSessionsScreen(initialRows: rows)),
      );
      await tester.tap(find.bySemanticsLabel('Project filter'));
      await tester.pumpAndSettle();

      // A collector commit adds a project that sorts before Gamma.
      await tester.pumpWidget(
        MaterialApp(
          home: TestSessionsScreen(
            initialRows: [
              ...rows,
              _row(id: 'b', title: 'Beta work', project: 'Beta'),
            ],
          ),
        ),
      );
      await tester.pump();
      await tester.tap(menuItem('Gamma'));
      await tester.pumpAndSettle();

      expect(filterValue(tester, 'Project filter'), 'Gamma');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('filter menu survives options shrinking while it is open', (
    tester,
  ) async {
    await setSize(tester);
    final rows = [
      _row(id: 'a', title: 'Alpha work', project: 'Alpha'),
      _row(id: 'c', title: 'Gamma work', project: 'Gamma'),
    ];
    await tester.pumpWidget(
      MaterialApp(home: TestSessionsScreen(initialRows: rows)),
    );
    await tester.tap(find.bySemanticsLabel('Project filter'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(home: TestSessionsScreen(initialRows: [rows.first])),
    );
    await tester.pump();
    await tester.tap(menuItem('Gamma'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(filterValue(tester, 'Project filter'), 'Gamma');
  });

  testWidgets('row and list action menus keep keyboard focus across rebuilds', (
    tester,
  ) async {
    await setSize(tester);
    List<SessionRowViewModel> rows() => [
      _row(id: 'one', title: 'First task'),
      _row(id: 'two', title: 'Second task'),
    ];
    Future<void> show() => tester.pumpWidget(
      MaterialApp(
        home: TestSessionsScreen(initialRows: rows(), onCopyText: (_) async {}),
      ),
    );
    await show();

    FocusNode nodeInside(Finder menu) => Focus.of(
      tester.element(
        find.descendant(of: menu, matching: find.byType(Icon)).first,
      ),
    );

    Finder menuUnder(String label) => find.descendant(
      of: find.bySemanticsLabel(label),
      matching: find.byWidgetPredicate((widget) => widget is PopupMenuButton),
    );
    for (final menu in [
      menuUnder('Session list actions'),
      menuUnder('More actions for First task'),
    ]) {
      expect(menu, findsOneWidget);
      nodeInside(menu).requestFocus();
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNotNull);

      await show();
      await tester.pump();

      expect(
        FocusManager.instance.primaryFocus,
        same(focused),
        reason: 'A rebuild must not replace the focused menu button.',
      );
      expect(nodeInside(menu).hasPrimaryFocus, isTrue);
    }
  });

  group('session ID search', () {
    Future<void> searchFor(WidgetTester tester, String value) async {
      await tester.enterText(find.bySemanticsLabel('Session search'), value);
      await tester.pump(const Duration(milliseconds: 221));
      await tester.pumpAndSettle();
    }

    Future<void> pumpRows(WidgetTester tester) async {
      await setSize(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: TestSessionsScreen(
            initialRows: [
              _row(
                id: 'session:codex-internal',
                sessionId: '01a0c847-6277-7652-8ac0-b67bd2253042',
                title: 'Codex row',
                summary: 'Work notes',
              ),
              _row(
                id: 'claude:session:claude-internal',
                sessionId: 'b2c3d4e5-0000-4000-8000-000000000001',
                title: 'Claude row',
                summary: 'Work notes',
                harness: 'claude',
              ),
            ],
          ),
        ),
      );
    }

    testWidgets('namespace words do not match every row', (tester) async {
      await pumpRows(tester);
      for (final query in ['session', 'claude', 'claude:', 'session:']) {
        await searchFor(tester, query);
        expect(
          find.text('Codex row'),
          findsNothing,
          reason: '"$query" must not match the internal ID prefix.',
        );
      }
      await searchFor(tester, 'claude:session');
      expect(find.text('Codex row'), findsNothing);
      expect(find.text('Claude row'), findsNothing);
    });

    testWidgets('provider IDs, full IDs, and ID prefixes still match', (
      tester,
    ) async {
      await pumpRows(tester);
      for (final (query, match, other) in [
        ('7652-8ac0', 'Codex row', 'Claude row'),
        ('session:codex-internal', 'Codex row', 'Claude row'),
        ('codex-inter', 'Codex row', 'Claude row'),
        ('claude:session:claude-int', 'Claude row', 'Codex row'),
        ('claude-internal', 'Claude row', 'Codex row'),
      ]) {
        await searchFor(tester, query);
        expect(find.text(match), findsWidgets, reason: query);
        expect(find.text(other), findsNothing, reason: query);
      }
    });
  });

  testWidgets('session rows are selectable list items, not buttons', (
    tester,
  ) async {
    await setSize(tester);
    final handle = tester.ensureSemantics();
    final loaded = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: TestSessionsScreen(
          initialRows: [
            _row(id: 'one', title: 'First task', summary: 'First summary'),
            _row(id: 'two', title: 'Second task', summary: 'Second summary'),
          ],
          onLoadSessionDetail: (id) async {
            loaded.add(id);
            return null;
          },
        ),
      ),
    );
    final rowNode = find.bySemanticsLabel(RegExp(r'^Session First task'));
    final data = tester.getSemantics(rowNode).getSemanticsData();
    expect(data.flagsCollection.isButton, isFalse);
    expect(data.hasAction(SemanticsAction.tap), isTrue);
    expect(data.flagsCollection.isSelected, Tristate.isFalse);
    expect(
      find.bySemanticsLabel('More actions for First task'),
      findsOneWidget,
      reason: 'Nested row controls stay separate screen-reader nodes.',
    );

    Focus.of(tester.element(find.text('Second summary'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 300));
    expect(loaded, contains('two'));
    expect(
      tester
          .getSemantics(find.bySemanticsLabel(RegExp(r'^Session Second task')))
          .getSemanticsData()
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    handle.dispose();
  });

  group('external revisions', () {
    testWidgets('reload selected detail only when that session changed', (
      tester,
    ) async {
      await setSize(tester);
      final loads = <String>[];
      Future<void> show(int revision, {int messages = 7, String other = ''}) =>
          tester.pumpWidget(
            MaterialApp(
              home: SessionsScreen(
                initialRows: [
                  _row(id: 'one', title: 'First task', messageCount: messages),
                  _row(id: 'two', title: 'Second task$other'),
                ],
                externalRevision: revision,
                now: fixedSessionsNow,
                onLoadSessionDetail: (id) async {
                  loads.add(id);
                  return null;
                },
                watchSessionFile: (_) => const Stream.empty(),
              ),
            ),
          );
      await show(0);
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Session First task')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(loads, ['one']);

      await show(1, other: ' renamed');
      await tester.pump(const Duration(milliseconds: 300));
      expect(loads, [
        'one',
      ], reason: 'An unrelated commit must not reload the selected detail.');

      await show(2, messages: 8, other: ' renamed');
      await tester.pump(const Duration(milliseconds: 300));
      expect(loads, ['one', 'one']);
    });

    testWidgets(
      'refresh-owned rows ignore stale parent rows until a new external revision',
      (tester) async {
        await setSize(tester);
        Future<void> show(int revision, List<SessionRowViewModel> rows) =>
            tester.pumpWidget(
              MaterialApp(
                home: SessionsScreen(
                  initialRows: rows,
                  externalRevision: revision,
                  now: fixedSessionsNow,
                  onRefresh: () async => [
                    _row(id: 'fresh', title: 'Fresh scan row'),
                  ],
                  watchSessionFile: (_) => const Stream.empty(),
                ),
              ),
            );
        await show(1, [_row(id: 'cached', title: 'Cached row')]);
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(find.text('Fresh scan row'), findsWidgets);

        await show(1, [_row(id: 'stale', title: 'Stale cached row')]);
        await tester.pump();
        expect(find.text('Stale cached row'), findsNothing);
        expect(find.text('Fresh scan row'), findsWidgets);

        await show(2, [_row(id: 'collector', title: 'Collector row')]);
        await tester.pump();
        expect(find.text('Collector row'), findsWidgets);
      },
    );
  });

  testWidgets('harness chip uses the shared harness label', (tester) async {
    await setSize(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: TestSessionsScreen(
          initialRows: [
            _row(id: 'one', title: 'Claude work', harness: 'claude'),
          ],
        ),
      ),
    );
    await tester.tap(find.bySemanticsLabel('Harness filter'));
    await tester.pumpAndSettle();
    await tester.tap(menuItem('Claude Code'));
    await tester.pumpAndSettle();
    expect(filterValue(tester, 'Harness filter'), 'Claude Code');
    expect(find.text('Claude Code'), findsWidgets);
  });

  testWidgets('split handle puts usage text in the hint, not the value', (
    tester,
  ) async {
    await setSize(tester);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(home: TestSessionsScreen(initialRows: const [])),
    );
    final data = tester
        .getSemantics(
          find.bySemanticsLabel('Resize session table and detail panes'),
        )
        .getSemanticsData();
    expect(data.value, isNot(contains('Arrow')));
    expect(data.hint, contains('Left and Right Arrow'));
    handle.dispose();
  });

  testWidgets('keyboard pane nudges save the table state once, debounced', (
    tester,
  ) async {
    await setSize(tester);
    final saved = <SessionTableSettings>[];
    await tester.pumpWidget(
      MaterialApp(
        home: TestSessionsScreen(
          initialRows: const [],
          onTableStateChanged: saved.add,
        ),
      ),
    );
    final splitter = find.byKey(const Key('sessions-pane-splitter'));
    Focus.of(tester.element(splitter)).requestFocus();
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(saved, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(saved, hasLength(1));
    expect(saved.single.paneFraction, isNotNull);
  });
}

SessionRowViewModel _row({
  required String id,
  required String title,
  String sessionId = '',
  String project = 'Codex Viewer',
  String summary = 'Session summary',
  String harness = 'codex',
  int messageCount = 7,
}) {
  return SessionRowViewModel(
    id: id,
    sessionId: sessionId,
    harness: harness,
    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
    lastMessageAtUtc: DateTime.utc(2026, 6, 12, 10),
    platform: SessionRowPlatform.windows,
    project: project,
    path: r'C:\work\app',
    title: title,
    summary: summary,
    messageCount: messageCount,
    totalTokens: 1200,
    model: 'gpt-5.4',
    tags: const ['parser'],
    status: 'Available',
    threadName: title,
  );
}
