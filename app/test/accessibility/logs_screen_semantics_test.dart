import 'package:codex_sessions_viewer/src/logging/structured_logger.dart';
import 'package:codex_sessions_viewer/src/ui/screens/logs_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('details and clear-old-logs dialog are accessible', (
    tester,
  ) async {
    var cleared = false;

    await tester.pumpWidget(
      MaterialApp(
        home: LogsScreen(
          entries: [
            LogEntry(
              id: 1,
              timeUtc: DateTime.utc(2026, 6, 13, 10),
              level: LogLevel.error,
              category: LogCategory.database,
              message: 'Database error',
              details: '{"safe":"details"}',
            ),
          ],
          onClearOldLogs: () async {
            cleared = true;
          },
        ),
      ),
    );

    expect(find.bySemanticsLabel('Logs table'), findsOneWidget);

    await tester.tap(find.text('Database error'));
    await tester.pump();

    expect(find.bySemanticsLabel('Selected log details'), findsOneWidget);
    expect(find.textContaining('"safe":"details"'), findsOneWidget);

    await tester.tap(find.text('Clear old logs'));
    await tester.pumpAndSettle();

    expect(find.text('Clear old logs?'), findsOneWidget);
    expect(find.bySemanticsLabel('Confirm clearing old logs'), findsOneWidget);

    await tester.tap(find.text('Clear logs'));
    await tester.pumpAndSettle();

    expect(cleared, isTrue);
  });
}
