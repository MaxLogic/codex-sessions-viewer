import 'package:codex_sessions_viewer/src/commands/resume_command_generator.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/ui/themes.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/command_preview.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/conversation_view.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/focus_reader_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('important command actions expose specific semantics labels', (
    tester,
  ) async {
    final commandSet = ResumeCommandGenerator(settings: AppSettings.defaults())
        .build(
          const ResumeCommandSession(
            sessionId: 'abc123',
            sourceType: ResumeSessionSourceType.windows,
            workingDirectory: r'C:\projects\viewer',
          ),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CommandPreview(commandSet: commandSet)),
      ),
    );

    expect(find.bySemanticsLabel('Copy plain resume command'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Copy platform resume command'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Copy terminal launch command'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Run terminal launch command'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Edit terminal launch command before running'),
      findsOneWidget,
    );
  });

  testWidgets('session table rows and action menus are discoverable', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            SessionRowViewModel(
              id: 'session-1',
              startedAtUtc: DateTime.utc(2026, 6, 12, 9),
              lastMessageAtUtc: DateTime.utc(2026, 6, 12, 9, 5),
              title: 'Parser review',
              summary: 'Reviewed JSONL formats',
              project: 'Codex Viewer',
              path: r'F:\projects\MaxLogic\codex-sessions-viewer',
              platform: SessionRowPlatform.windows,
              messageCount: 4,
              totalTokens: 1200,
              model: 'gpt-5',
              tags: const ['parser'],
              status: 'Parsed',
            ),
          ],
        ),
      ),
    );

    expect(
      find.bySemanticsLabel('Summary Reviewed JSONL formats'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^Last Message Date \d')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('More actions for Parser review'),
      findsOneWidget,
    );
  });

  testWidgets(
    'sessions table does not announce empty summaries for every blank row',
    (tester) async {
      final now = DateTime.now().toUtc();
      await tester.pumpWidget(
        MaterialApp(
          home: SessionsScreen(
            initialRows: [
              SessionRowViewModel(
                id: 'session-1',
                startedAtUtc: now.subtract(const Duration(hours: 2)),
                lastMessageAtUtc: now.subtract(const Duration(hours: 1)),
                title: 'Parser review',
                summary: '',
                project: 'Codex Viewer',
                path: r'F:\projects\MaxLogic\codex-sessions-viewer',
                platform: SessionRowPlatform.windows,
                messageCount: 4,
                totalTokens: 1200,
                model: 'gpt-5',
                tags: const ['parser'],
                status: 'Parsed',
              ),
              SessionRowViewModel(
                id: 'session-2',
                startedAtUtc: now.subtract(const Duration(hours: 3)),
                lastMessageAtUtc: now.subtract(const Duration(hours: 2)),
                title: 'UI review',
                summary: '',
                project: 'Codex Viewer',
                path: r'F:\projects\MaxLogic\codex-sessions-viewer',
                platform: SessionRowPlatform.windows,
                messageCount: 3,
                totalTokens: 900,
                model: 'gpt-5',
                tags: const ['ui'],
                status: 'Parsed',
              ),
            ],
          ),
        ),
      );

      expect(find.bySemanticsLabel('Summary empty'), findsNothing);
      expect(
        find.bySemanticsLabel('Session Parser review. Status Parsed.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('session row actions have distinct accessible names', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            SessionRowViewModel(
              id: 'session-1',
              sessionId: 'abc123',
              startedAtUtc: now.subtract(const Duration(hours: 2)),
              lastMessageAtUtc: now.subtract(const Duration(hours: 1)),
              title: 'Parser review',
              summary: 'Reviewed JSONL formats',
              project: 'Codex Viewer',
              path: r'F:\projects\MaxLogic\codex-sessions-viewer',
              platform: SessionRowPlatform.windows,
              messageCount: 4,
              totalTokens: 1200,
              model: 'gpt-5',
              tags: const ['parser'],
              status: 'Parsed',
            ),
          ],
        ),
      ),
    );

    expect(
      find.bySemanticsLabel('Copy path for Parser review'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Open terminal and resume for Parser review'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('More actions for Parser review'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Actions for Parser review'), findsNothing);
  });

  testWidgets('empty session detail has accessible heading and guidance', (
    tester,
  ) async {
    final now = DateTime.now().toUtc();
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            SessionRowViewModel(
              id: 'session-1',
              startedAtUtc: now.subtract(const Duration(hours: 2)),
              lastMessageAtUtc: now.subtract(const Duration(hours: 1)),
              title: 'Parser review',
              summary: 'Reviewed JSONL formats',
              project: 'Codex Viewer',
              path: r'F:\projects\MaxLogic\codex-sessions-viewer',
              platform: SessionRowPlatform.windows,
              messageCount: 4,
              totalTokens: 1200,
              model: 'gpt-5',
              tags: const ['parser'],
              status: 'Parsed',
            ),
          ],
        ),
      ),
    );

    final heading = tester.getSemantics(find.text('Session detail'));
    expect(heading.flagsCollection.isHeader, isTrue);
    expect(
      find.bySemanticsLabel('Select a session from the table to view details.'),
      findsOneWidget,
    );
  });

  testWidgets('conversation index and collapsed tool output stay accessible', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            messages: [
              ConversationMessageViewModel(
                id: 'user',
                number: 1,
                author: ConversationAuthor.user,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                preview: 'Prompt preview',
                body: 'Prompt body',
                tokenCount: 10,
              ),
              ConversationMessageViewModel(
                id: 'tool',
                number: 2,
                author: ConversationAuthor.tool,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9, 1),
                preview: 'shell_command',
                body: 'line 1\nline 2\nline 3',
                tokenCount: 20,
                hasToolOutput: true,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('#1 User, 10 tokens'), findsOneWidget);
    expect(find.bySemanticsLabel('#2 Tool, 20 tokens'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Tool output collapsed, 3 lines. Use the Expand tool output button to show it.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('focus reader supports keyboard jumps by message type', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FocusReaderView(
            messages: [
              ConversationMessageViewModel(
                id: 'user',
                number: 1,
                author: ConversationAuthor.user,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                preview: 'Prompt preview',
                body: 'Prompt body',
                tokenCount: 10,
              ),
              ConversationMessageViewModel(
                id: 'assistant',
                number: 2,
                author: ConversationAuthor.assistant,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9, 1),
                preview: 'Answer preview',
                body: 'Answer body',
                tokenCount: 20,
              ),
              ConversationMessageViewModel(
                id: 'tool',
                number: 3,
                author: ConversationAuthor.tool,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9, 2),
                preview: 'shell_command',
                body: 'line 1\nline 2',
                tokenCount: 30,
                hasToolOutput: true,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pumpAndSettle();

    expect(
      tester
          .getSemantics(find.byKey(const Key('focus-reader-announcement')))
          .label,
      'Selected message 2 of 3. Assistant.',
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pumpAndSettle();

    expect(
      tester
          .getSemantics(find.byKey(const Key('focus-reader-announcement')))
          .label,
      'Selected message 3 of 3. Tool.',
    );
    expect(
      tester.getSemantics(find.byKey(const Key('focus-reader-message'))).label,
      contains('Tool output collapsed, 2 lines. Press X to expand.'),
    );
  });

  test('high contrast focus indicators remain stronger than normal themes', () {
    final normal = CodexAppTheme.focusStyle(CodexThemeMode.light);
    final highLight = CodexAppTheme.focusStyle(
      CodexThemeMode.highContrastLight,
    );
    final highDark = CodexAppTheme.focusStyle(CodexThemeMode.highContrastDark);

    expect(highLight.width, greaterThan(normal.width));
    expect(highDark.width, greaterThan(normal.width));
    expect(highLight.color, Colors.black);
    expect(highDark.color, Colors.white);
  });
}
