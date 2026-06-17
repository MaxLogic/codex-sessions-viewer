import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'shows required filters, table columns, row states, and actions',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SessionsScreen(
            initialRows: [
              _row(
                id: 'active',
                title: 'Parser cache',
                platform: SessionRowPlatform.windows,
                isPinned: true,
              ),
              _row(
                id: 'parse-error',
                title: 'Broken JSONL',
                platform: SessionRowPlatform.wsl,
                status: 'Parse error',
                hasError: true,
              ),
              _row(id: 'archived', title: 'Archived session', isArchived: true),
            ],
          ),
        ),
      );

      expect(find.bySemanticsLabel('Session search'), findsOneWidget);
      expect(find.bySemanticsLabel('Platform filter'), findsOneWidget);
      expect(find.bySemanticsLabel('Time range filter'), findsOneWidget);
      expect(find.bySemanticsLabel('Project filter'), findsOneWidget);
      expect(find.bySemanticsLabel('Path filter'), findsOneWidget);
      expect(find.bySemanticsLabel('Tags filter'), findsOneWidget);
      expect(find.bySemanticsLabel('Model filter'), findsOneWidget);
      expect(find.bySemanticsLabel('Status filter'), findsOneWidget);
      expect(find.bySemanticsLabel('Archived filter'), findsOneWidget);
      expect(
        find.text('Additional time ranges are not available yet.'),
        findsOneWidget,
      );
      for (final text in const [
        'Project values are not available yet.',
        'Tags values are not available yet.',
        'Model values are not available yet.',
        'Status values are not available yet.',
      ]) {
        expect(find.text(text), findsOneWidget);
      }
      expect(
        find
            .byType(Tooltip)
            .evaluate()
            .map((element) => element.widget)
            .whereType<Tooltip>()
            .map((tooltip) => tooltip.message),
        contains('Advanced filters are not available yet.'),
      );
      expect(find.bySemanticsLabel('Sessions, 2 visible'), findsOneWidget);
      expect(find.text('(2)'), findsOneWidget);
      expect(find.text('2 sessions visible'), findsNothing);
      expect(find.text('Archived session'), findsNothing);

      for (final column in const [
        'Last Message Date',
        'Project',
        'Path',
        'Summary',
        'Messages',
        'Tokens',
        'Model',
        'Tags',
        'Status',
        'Actions',
      ]) {
        expect(find.text(column), findsWidgets);
      }
      expect(find.text('Title'), findsNothing);

      expect(
        find.bySemanticsLabel(
          r'Windows path F:\projects\MaxLogic\codex-sessions-viewer',
        ),
        findsOneWidget,
      );
      expect(find.text('Windows'), findsNothing);
      expect(find.text('WSL'), findsNothing);
      expect(
        find.bySemanticsLabel(
          'WSL path /home/pawel/.codex/sessions/2026/06/12/session.jsonl',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Copy path for Parser cache'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Copy path for Broken JSONL'),
        findsOneWidget,
      );
      expect(find.text('Pinned | Available'), findsOneWidget);
      expect(find.text('Parse error'), findsWidgets);
      expect(find.bySemanticsLabel('Actions for Parser cache'), findsOneWidget);
      expect(find.bySemanticsLabel('Actions for Broken JSONL'), findsOneWidget);
    },
  );

  testWidgets('shows transient cached-load status below Sessions header', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [_row(id: 'active', title: 'Parser cache')],
          initialStatusMessage:
              'Loaded 250 of 7843 sessions from the previous scan.',
        ),
      ),
    );

    expect(find.bySemanticsLabel('Sessions, 1 visible'), findsOneWidget);
    expect(
      find.text('Loaded 250 of 7843 sessions from the previous scan.'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets(
    'sorts by last message timestamp and supports multi-sort clicks',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: SessionsScreen(
            initialRows: [
              _row(
                id: 'old',
                title: 'Alpha session',
                summary: 'Alpha summary',
                lastMessageAtUtc: DateTime.utc(2026, 6, 12, 9),
              ),
              _row(
                id: 'new',
                title: 'Beta session',
                summary: 'Beta summary',
                lastMessageAtUtc: DateTime.utc(2026, 6, 12, 11),
              ),
            ],
          ),
        ),
      );

      expect(
        _textTop(tester, 'Beta summary'),
        lessThan(_textTop(tester, 'Alpha summary')),
      );

      await tester.tap(find.bySemanticsLabel('Summary column'));
      await tester.pumpAndSettle();

      expect(
        _textTop(tester, 'Beta summary'),
        greaterThan(_textTop(tester, 'Alpha summary')),
      );
      expect(
        find.bySemanticsLabel('Summary column ascending priority 1'),
        findsOneWidget,
      );

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.bySemanticsLabel('Project column'));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('Summary column ascending priority 1'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Project column ascending priority 2'),
        findsOneWidget,
      );
    },
  );
}

SessionRowViewModel _row({
  required String id,
  required String title,
  SessionRowPlatform platform = SessionRowPlatform.windows,
  bool isPinned = false,
  bool isArchived = false,
  bool hasError = false,
  String status = 'Available',
  DateTime? lastMessageAtUtc,
  String summary = 'Session summary',
}) {
  return SessionRowViewModel(
    id: id,
    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
    lastMessageAtUtc: lastMessageAtUtc ?? DateTime.utc(2026, 6, 12, 10),
    platform: platform,
    project: 'Codex Viewer',
    path: platform == SessionRowPlatform.windows
        ? r'F:\projects\MaxLogic\codex-sessions-viewer'
        : '/home/pawel/.codex/sessions/2026/06/12/session.jsonl',
    title: title,
    summary: summary,
    messageCount: 7,
    totalTokens: 1200,
    model: 'gpt-5.4',
    tags: const ['parser'],
    status: status,
    isPinned: isPinned,
    isArchived: isArchived,
    hasError: hasError,
  );
}

double _textTop(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text).first).dy;
