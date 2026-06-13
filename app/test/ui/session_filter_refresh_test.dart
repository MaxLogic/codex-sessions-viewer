import 'dart:async';

import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('defaults to active sessions and preserves filters on refresh', (
    tester,
  ) async {
    final refresh = Completer<List<SessionRowViewModel>>();
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(id: 'keep', title: 'Keep selected', project: 'Viewer'),
            _row(id: 'other', title: 'Other active', project: 'Viewer'),
            _row(
              id: 'archived',
              title: 'Archived selected',
              project: 'Archive',
              isArchived: true,
            ),
          ],
          onRefresh: () => refresh.future,
        ),
      ),
    );

    expect(find.text('2 sessions visible'), findsOneWidget);
    expect(find.text('Archived selected'), findsNothing);

    await tester.enterText(find.bySemanticsLabel('Session search'), 'Other');
    await tester.pumpAndSettle();
    expect(find.text('1 session visible'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
    await tester.pumpAndSettle();
    expect(find.text('2 sessions visible'), findsOneWidget);

    await tester.enterText(find.bySemanticsLabel('Session search'), 'Keep');
    await tester.pumpAndSettle();
    expect(find.text('1 session visible'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Select session Keep selected'));
    await tester.pumpAndSettle();
    expect(find.text('Selected: Keep selected'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Refresh'));
    await tester.pump();
    expect(find.widgetWithText(ElevatedButton, 'Scanning...'), findsOneWidget);
    expect(find.text('Scanning started'), findsOneWidget);

    refresh.complete([
      _row(id: 'keep', title: 'Keep selected updated', project: 'Viewer'),
      _row(id: 'new', title: 'New active', project: 'Viewer'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Keep'), findsOneWidget);
    expect(find.text('1 session visible'), findsOneWidget);
    expect(find.text('Keep selected updated'), findsWidgets);
    expect(find.text('Selected: Keep selected updated'), findsOneWidget);
    expect(find.text('Scan finished. 2 sessions found.'), findsOneWidget);
  });
}

SessionRowViewModel _row({
  required String id,
  required String title,
  required String project,
  bool isArchived = false,
}) {
  return SessionRowViewModel(
    id: id,
    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
    lastMessageAtUtc: DateTime.utc(2026, 6, 12, 10),
    platform: SessionRowPlatform.windows,
    project: project,
    path: r'F:\projects\MaxLogic\codex-sessions-viewer',
    title: title,
    summary: 'Session summary',
    messageCount: 3,
    totalTokens: 900,
    model: 'gpt-5.4',
    tags: const ['ui'],
    status: 'Available',
    isArchived: isArchived,
  );
}
