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
      expect(find.bySemanticsLabel('${area.label} navigation'), findsOneWidget);
    }
    expect(find.text('Sessions'), findsWidgets);
    expect(find.text('Session table'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Usage navigation'));
    await tester.pumpAndSettle();
    expect(find.text('Usage'), findsWidgets);
    expect(find.text('Usage summary'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Settings navigation'));
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Settings form'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Logs navigation'));
    await tester.pumpAndSettle();
    expect(find.text('Logs'), findsWidgets);
    expect(find.text('Log table'), findsOneWidget);
  });

  testWidgets('navigation rail is keyboard reachable', (tester) async {
    await tester.pumpWidget(CodexSessionsViewerApp());
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(find.text('Usage summary'), findsOneWidget);
  });
}
