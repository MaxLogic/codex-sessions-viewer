import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_sessions_screen.dart';

void main() {
  testWidgets(
    'shows required filters, table columns, row states, and actions',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: TestSessionsScreen(
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
      expect(find.bySemanticsLabel('Viewer archive filter'), findsOneWidget);
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
        home: TestSessionsScreen(
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

  testWidgets('copies the filtered visible session list as Markdown', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? copied;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [
              _row(
                id: 'older',
                title: 'Older session',
                lastMessageAtUtc: DateTime.utc(2026, 6, 12, 9),
              ),
              _row(
                id: 'newer',
                title: 'Newer session',
                lastMessageAtUtc: DateTime.utc(2026, 6, 12, 11),
              ),
              _row(id: 'archived', title: 'Archived session', isArchived: true),
            ],
            onCopyText: (text) async {
              copied = text;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Session list actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy visible list as Markdown'));
    await tester.pumpAndSettle();

    expect(copied, startsWith('# Sessions (2)'));
    expect(copied, contains('## Newer session — codex-sessions-viewer'));
    expect(copied, contains('## Older session — codex-sessions-viewer'));
    expect(copied, isNot(contains('Archived session')));
    expect(
      copied!.indexOf('## Newer session'),
      lessThan(copied!.indexOf('## Older session')),
    );
    expect(find.text('Copied 2 visible sessions as Markdown.'), findsOneWidget);
  });

  testWidgets(
    'copies extended Markdown with first and last messages selected by default',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? copied;
      var detailLoads = 0;
      var pageLoads = 0;
      final row = _row(id: 'visible', title: 'Visible session');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TestSessionsScreen(
              initialRows: [row],
              onCopyText: (text) async {
                copied = text;
              },
              onLoadSessionDetail: (id) async {
                detailLoads++;
                return row.copyWithConversationMessages([
                  _message(
                    id: '$id:first',
                    number: 1,
                    author: ConversationAuthor.user,
                    body: '',
                    preview: 'Explain the failing parser test.',
                    isBodyLoaded: false,
                  ),
                  _message(
                    id: '$id:last',
                    number: 2,
                    author: ConversationAuthor.assistant,
                    body: 'The parser now accepts the fixture.',
                  ),
                ]);
              },
              onLoadMessagePage: (id, anchor) async {
                pageLoads++;
                return [
                  _message(
                    id: '$id:first',
                    number: anchor,
                    author: ConversationAuthor.user,
                    body: 'Explain the failing parser test in full.',
                  ),
                ];
              },
            ),
          ),
        ),
      );

      await tester.tap(find.bySemanticsLabel('Session list actions'));
      await tester.pumpAndSettle();
      expect(
        find.text('Copy visible list as extended Markdown…'),
        findsOneWidget,
      );
      await tester.tap(find.text('Copy visible list as extended Markdown…'));
      await tester.pumpAndSettle();

      expect(find.text('Copy extended Markdown'), findsOneWidget);
      expect(find.text('Include first message'), findsOneWidget);
      expect(find.text('Include last message'), findsOneWidget);
      final dialogCheckboxes = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Checkbox),
      );
      final checkboxes = tester
          .widgetList<Checkbox>(dialogCheckboxes)
          .toList(growable: false);
      expect(checkboxes, hasLength(2));
      expect(checkboxes.every((checkbox) => checkbox.value == true), isTrue);

      await tester.tap(find.widgetWithText(FilledButton, 'Copy'));
      await tester.pumpAndSettle();

      expect(detailLoads, 1);
      expect(pageLoads, 1);
      expect(copied, contains('### First message (User)'));
      expect(copied, contains('Explain the failing parser test in full.'));
      expect(copied, contains('### Last message (Assistant)'));
      expect(copied, contains('The parser now accepts the fixture.'));
      expect(
        find.text('Copied 1 visible session as extended Markdown.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('saves the filtered visible session list as CSV', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [
              _row(id: 'visible', title: 'Visible session'),
              _row(id: 'archived', title: 'Archived session', isArchived: true),
            ],
            onSaveSessionListCsv: (csv) async {
              saved = csv;
            },
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Session list actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save visible list as CSV…'));
    await tester.pumpAndSettle();

    expect(saved, startsWith('\ufeffname,thread_name,title,'));
    expect(saved, contains('Visible session'));
    expect(saved, isNot(contains('Archived session')));
  });

  testWidgets(
    'sorts by last message timestamp and supports multi-sort clicks',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: TestSessionsScreen(
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
        home: TestSessionsScreen(
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
          home: TestSessionsScreen(
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

ConversationMessageViewModel _message({
  required String id,
  required int number,
  required ConversationAuthor author,
  required String body,
  String? preview,
  bool isBodyLoaded = true,
}) {
  return ConversationMessageViewModel(
    id: id,
    number: number,
    author: author,
    createdAtUtc: DateTime.utc(2026, 6, 12, 10),
    preview: preview ?? body,
    body: body,
    tokenCount: null,
    isBodyLoaded: isBodyLoaded,
  );
}

double _textTop(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text).first).dy;
