import 'package:codex_sessions_viewer/src/config/app_settings.dart';
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
      expect(find.bySemanticsLabel('Archived filter'), findsOneWidget);
      expect(find.text('Advanced filters'), findsOneWidget);
      expect(find.bySemanticsLabel('Path filter'), findsNothing);
      await tester.tap(find.text('Advanced filters'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Project filter'), findsOneWidget);
      expect(find.bySemanticsLabel('Path filter'), findsOneWidget);
      expect(find.bySemanticsLabel('Tags filter'), findsOneWidget);
      expect(find.bySemanticsLabel('Model filter'), findsOneWidget);
      expect(find.bySemanticsLabel('Sessions, 2 visible'), findsOneWidget);
      expect(find.text('(2)'), findsOneWidget);
      expect(find.text('2 sessions visible'), findsNothing);
      expect(find.text('Archived session'), findsNothing);

      for (final column in const [
        'Last Message',
        'Project',
        'Path',
        'Summary',
        'Messages',
        'Tokens',
        'Model',
        'Tags',
        'Actions',
      ]) {
        expect(find.text(column), findsWidgets);
      }
      expect(find.text('Status'), findsNothing);
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
      expect(find.text('Parse error'), findsNothing);
      expect(
        find.bySemanticsLabel(
          'Session Parser cache. Status Pinned, Available.',
        ),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('Session Broken JSONL. Status Parse error.'),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('Add tag to Parser cache'), findsOneWidget);
      expect(
        find.bySemanticsLabel('More actions for Parser cache'),
        findsOneWidget,
      );
      expect(
        find.bySemanticsLabel('More actions for Broken JSONL'),
        findsOneWidget,
      );
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

  testWidgets('default origin filter exposes subagent-only rows', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(
              id: 'subagent',
              title: 'Subagent-only session',
              threadSource: 'subagent',
              parentThreadId: 'parent-session',
            ),
          ],
        ),
      ),
    );

    expect(
      find.bySemanticsLabel(
        'Session Subagent, Subagent-only session. Status Available.',
      ),
      findsNothing,
    );
    expect(
      find.text('Only subagent sessions match the current filters.'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(OutlinedButton, 'Show all origins'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Show all origins'));
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(
        'Session Subagent, Subagent-only session. Status Available.',
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'stale status sort settings are ignored after status column removal',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SessionsScreen(
            initialTableState: const SessionTableSettings(
              columnWidths: {},
              sorts: [
                SessionTableSortSettings(column: 'status', ascending: true),
              ],
              newestPerProjectOnly: false,
            ),
            initialRows: [_row(id: 'active', title: 'Parser cache')],
          ),
        ),
      );

      await tester.tap(
        find.bySemanticsLabel('Last Message column descending priority 1'),
      );
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('Last Message column ascending priority 1'),
        findsOneWidget,
      );
      expect(find.text('Status'), findsNothing);
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
  String threadSource = '',
  String parentThreadId = '',
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
    threadSource: threadSource,
    parentThreadId: parentThreadId,
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
