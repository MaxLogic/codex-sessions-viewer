import 'package:codex_sessions_viewer/src/logging/structured_logger.dart';
import 'package:codex_sessions_viewer/src/ui/screens/logs_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows required columns, filters, details, and actions', (
    tester,
  ) async {
    String? copied;
    var openedLogFile = false;
    var openedLogsFolder = false;

    await tester.pumpWidget(
      MaterialApp(
        home: LogsScreen(
          entries: _entries(),
          onCopySelected: (entry) async {
            copied = entry.message;
          },
          onOpenLogFile: () async {
            openedLogFile = true;
          },
          onOpenLogsFolder: () async {
            openedLogsFolder = true;
          },
        ),
      ),
    );

    for (final column in const [
      'Time',
      'Level',
      'Category',
      'Message',
      'Details',
    ]) {
      expect(find.text(column), findsWidgets);
    }
    expect(find.byType(ListView), findsOneWidget);
    expect(find.byType(DataTable), findsNothing);

    for (final filter in const [
      'Errors only',
      'Scanner',
      'Parser',
      'Database',
      'Migration',
      'Search',
      'Commands',
      'Pricing',
      'Export',
      'Accessibility',
      'Voice-over',
      'UI',
    ]) {
      expect(find.text(filter), findsWidgets);
    }

    expect(find.text('Scanner started'), findsOneWidget);
    expect(find.text('Pricing failed'), findsOneWidget);

    await tester.tap(find.text('Pricing failed'));
    await tester.pump();

    expect(find.text('Selected log details'), findsOneWidget);
    expect(find.textContaining('"code":"network"'), findsOneWidget);

    await tester.tap(find.text('Copy selected'));
    await tester.pump();
    expect(copied, 'Pricing failed');

    await tester.tap(find.text('Open log file'));
    await tester.tap(find.text('Open logs folder'));
    await tester.pump();
    expect(openedLogFile, isTrue);
    expect(openedLogsFolder, isTrue);

    await tester.tap(find.text('Errors only'));
    await tester.pump();
    expect(find.text('Scanner started'), findsNothing);
    expect(find.text('Pricing failed'), findsOneWidget);
  });
}

List<LogEntry> _entries() => [
  LogEntry(
    id: 1,
    timeUtc: DateTime.utc(2026, 6, 13, 10),
    level: LogLevel.info,
    category: LogCategory.scanner,
    message: 'Scanner started',
    details: null,
  ),
  LogEntry(
    id: 2,
    timeUtc: DateTime.utc(2026, 6, 13, 10, 5),
    level: LogLevel.error,
    category: LogCategory.pricing,
    message: 'Pricing failed',
    details: '{"code":"network"}',
  ),
];
