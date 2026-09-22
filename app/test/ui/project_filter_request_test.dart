import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_sessions_screen.dart';

SessionRowViewModel _row({
  required String id,
  required String project,
  required String title,
  bool isArchived = false,
  DateTime? lastMessageAtUtc,
}) => SessionRowViewModel(
  id: id,
  sessionId: id,
  startedAtUtc: DateTime.utc(2026, 6, 12, 9),
  lastMessageAtUtc: lastMessageAtUtc ?? DateTime.utc(2026, 6, 12, 10),
  platform: SessionRowPlatform.windows,
  project: project,
  path: r'F:\projects\viewer',
  title: title,
  summary: title,
  messageCount: 3,
  totalTokens: 100,
  model: 'gpt-5.4',
  tags: const [],
  status: 'Available',
  isArchived: isArchived,
);

void main() {
  final rows = [
    _row(id: 'a', project: 'viewer', title: 'Main session'),
    _row(id: 'b', project: 'other', title: 'Other session'),
    _row(
      id: 'c',
      project: 'viewer',
      title: 'Old archived session',
      isArchived: true,
      // Older than the default time window, so the request must widen it.
      lastMessageAtUtc: DateTime.utc(2025, 1, 5),
    ),
  ];

  testWidgets('a project request shows that project and relaxes filters', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: rows,
            projectFilterRequest: 'viewer',
            projectFilterSerial: 1,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Project: viewer'), findsOneWidget);
    expect(find.text('Main session'), findsWidgets);
    expect(find.text('Old archived session'), findsWidgets);
    expect(find.text('Other session'), findsNothing);
  });

  testWidgets('a later request replaces the filters again', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Widget build(String? request, int serial) => MaterialApp(
      home: Scaffold(
        body: TestSessionsScreen(
          initialRows: rows,
          projectFilterRequest: request,
          projectFilterSerial: serial,
        ),
      ),
    );

    await tester.pumpWidget(build(null, 0));
    await tester.pumpAndSettle();
    expect(find.text('Other session'), findsWidgets);

    await tester.pumpWidget(build('other', 1));
    await tester.pumpAndSettle();
    expect(find.text('Project: other'), findsOneWidget);
    expect(find.text('Main session'), findsNothing);

    // The same request stays applied while the user changes filters, and a
    // rebuild without one keeps what is on screen.
    await tester.pumpWidget(build(null, 1));
    await tester.pumpAndSettle();
    expect(find.text('Project: other'), findsOneWidget);
  });
}
