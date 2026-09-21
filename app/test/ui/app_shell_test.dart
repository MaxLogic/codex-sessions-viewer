import 'dart:ui' show SemanticsAction, SemanticsFlag, Tristate;

import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/ui/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('main navigation exposes required areas and switches screens', (
    tester,
  ) async {
    await tester.pumpWidget(CodexSessionsViewerApp());
    await tester.pump();

    expect(find.byType(NavigationRail), findsOneWidget);
    for (final area in CodexAppSection.values) {
      expect(find.text(area.label), findsWidgets);
      expect(
        find.bySemanticsLabel(RegExp('^${area.label} navigation\\nTab ')),
        findsOneWidget,
      );
    }
    expect(find.text('Sessions'), findsWidgets);
    expect(find.text('Session table'), findsNothing);

    await tester.tap(find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')));
    await tester.pumpAndSettle();
    expect(find.text('Usage'), findsWidgets);
    expect(find.text('Usage summary'), findsOneWidget);

    await tester.tap(
      find.bySemanticsLabel(RegExp('^Settings navigation\\nTab ')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Save settings'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(RegExp('^Logs navigation\\nTab ')));
    await tester.pumpAndSettle();
    expect(find.text('Logs'), findsWidgets);
    expect(find.text('Log table'), findsOneWidget);
  });

  testWidgets('navigation rail is keyboard reachable', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: CodexAppShell(
            sessionsScreenBuilder: (_, _) => const Text('Sessions content'),
            evalsScreen: const Text('Evals content'),
            contextScreen: const Text('Context content'),
            usageScreen: const Text('Usage content'),
            settingsScreen: const Text('Settings content'),
            logsScreen: const Text('Logs content'),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      for (final area in CodexAppSection.values) {
        await tester.pumpAndSettle();
        final focused = find.semantics
            .byFlag(SemanticsFlag.isFocused)
            .evaluate();
        expect(focused, hasLength(1));
        final data = focused.single.getSemanticsData();
        expect(data.label, contains(area.label));
        expect(data.label, contains('Tab ${area.index + 1} of 6'));
        expect(data.hasAction(SemanticsAction.tap), isTrue);
        expect(data.flagsCollection.isFocused, Tristate.isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(
          find.semantics
              .byFlag(SemanticsFlag.isFocused)
              .evaluate()
              .single
              .getSemanticsData()
              .flagsCollection
              .isSelected,
          Tristate.isTrue,
        );
        expect(find.text('${area.label} content'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      }
    } finally {
      semantics.dispose();
    }
  });
}
