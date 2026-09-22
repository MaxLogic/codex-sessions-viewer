import 'package:codex_sessions_viewer/src/commands/resume_command_generator.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/command_preview.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/conversation_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_sessions_screen.dart';

Future<void> _pressCtrlC(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

/// Records text written to the system clipboard.
List<String> _captureClipboard(WidgetTester tester) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

void main() {
  group('sessions screen', () {
    Future<List<SessionActionRequest>> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(5000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final actions = <SessionActionRequest>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TestSessionsScreen(
              initialRows: [_row()],
              onSessionAction: (request) async => actions.add(request),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return actions;
    }

    testWidgets('Ctrl+C after clicking a session copies its path', (
      tester,
    ) async {
      final actions = await pump(tester);
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Session .*Status')));
      await tester.pumpAndSettle();

      await _pressCtrlC(tester);

      expect(actions.map((action) => action.action), [
        SessionRowAction.copyPath,
      ]);
      expect(actions.single.payload, r'F:\projects\viewer');
      expect(find.text('Copied session path.'), findsOneWidget);
    });

    testWidgets('Ctrl+C in the search field stays with the field', (
      tester,
    ) async {
      final actions = await pump(tester);
      await tester.tap(find.bySemanticsLabel(RegExp(r'^Session .*Status')));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      await _pressCtrlC(tester);

      expect(actions, isEmpty);
    });
  });

  group('conversation', () {
    final messages = [
      for (var i = 1; i <= 3; i++)
        ConversationMessageViewModel(
          id: 'm$i',
          number: i,
          author: i.isOdd
              ? ConversationAuthor.user
              : ConversationAuthor.assistant,
          createdAtUtc: DateTime.utc(2026, 6, 12, 9, i),
          preview: 'Body $i',
          body: 'Body $i',
          tokenCount: i,
        ),
    ];

    Future<List<String>> pump(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final copied = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationView(
              messages: messages,
              initialToolCallVisibility: ToolCallVisibility.hide,
              onCopyMessageMarkdown: (text) async => copied.add(text),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return copied;
    }

    testWidgets('Ctrl+C copies the selected message', (tester) async {
      final copied = await pump(tester);
      await tester.tap(
        find.byKey(const Key('message-card-icon-2')),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      await _pressCtrlC(tester);

      expect(copied, [conversationMessageMarkdown(messages[1])]);
      expect(find.text('Message 2 copied.'), findsOneWidget);
    });

    testWidgets('Ctrl+C in the find field stays with the field', (
      tester,
    ) async {
      final copied = await pump(tester);
      await tester.tap(find.byKey(const Key('conversation-find-field')));
      await tester.pumpAndSettle();

      await _pressCtrlC(tester);

      expect(copied, isEmpty);
    });
  });

  testWidgets('Ctrl+C in a command preview copies the whole command', (
    tester,
  ) async {
    final copied = _captureClipboard(tester);
    final commandSet = ResumeCommandGenerator(settings: AppSettings.defaults())
        .build(
          const ResumeCommandSession(
            sessionId: 'abc123',
            sourceType: ResumeSessionSourceType.windows,
            workingDirectory: r'F:\projects\viewer',
          ),
        );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CommandPreview(commandSet: commandSet)),
      ),
    );
    await tester.tap(find.text('codex resume abc123').first);
    await tester.pumpAndSettle();

    await _pressCtrlC(tester);

    expect(copied, ['codex resume abc123']);
  });
}

SessionRowViewModel _row() {
  return SessionRowViewModel(
    id: 'active',
    sessionId: 'abc123',
    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
    lastMessageAtUtc: DateTime.utc(2026, 6, 12, 10),
    platform: SessionRowPlatform.windows,
    project: 'Codex Viewer',
    path: r'F:\projects\viewer',
    sourceFilePath: '',
    displayPath: r'F:\projects\viewer',
    workingDirectory: r'F:\projects\viewer',
    openablePath: r'F:\projects\viewer',
    title: 'Parser cache',
    summary: 'Parser cache',
    messageCount: 7,
    totalTokens: 1200,
    model: 'gpt-5.4',
    tags: const ['parser'],
    status: 'Available',
  );
}
