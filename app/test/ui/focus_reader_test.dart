import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/focus_reader_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows one selected message with metadata and copy actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FocusReaderView(messages: _messages())),
      ),
    );

    expect(find.text('Message 1 of 5'), findsOneWidget);
    expect(find.text('Author: User'), findsOneWidget);
    expect(find.text('Tokens: 10'), findsOneWidget);
    expect(find.text('First user body'), findsOneWidget);
    expect(find.text('Assistant body'), findsNothing);
    expect(
      find.widgetWithText(OutlinedButton, 'Copy Markdown (M)'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(OutlinedButton, 'Copy text (C)'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Next (N)'));
    await tester.pumpAndSettle();
    expect(find.text('Message 2 of 5'), findsOneWidget);
    expect(find.text('Assistant body'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Next tool (T)'));
    await tester.pumpAndSettle();
    expect(find.text('Message 3 of 5'), findsOneWidget);
    expect(find.text('Tool output collapsed, 2 lines.'), findsOneWidget);
  });

  testWidgets('navigates by message kind using buttons and shortcuts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: FocusReaderView(messages: _messages())),
      ),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Next assistant (A)'));
    await tester.pumpAndSettle();
    expect(find.text('Message 2 of 5'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyU);
    await tester.pumpAndSettle();
    expect(find.text('Message 5 of 5'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(find.text('Message 2 of 5'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
    await tester.pumpAndSettle();
    expect(find.text('Message 3 of 5'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
    await tester.pumpAndSettle();
    expect(find.text('Message 4 of 5'), findsOneWidget);
  });
}

List<ConversationMessageViewModel> _messages() => [
  ConversationMessageViewModel(
    id: 'user-1',
    number: 1,
    author: ConversationAuthor.user,
    createdAtUtc: DateTime.utc(2026, 6, 12, 9),
    preview: 'First user',
    body: 'First user body',
    tokenCount: 10,
  ),
  ConversationMessageViewModel(
    id: 'assistant-1',
    number: 2,
    author: ConversationAuthor.assistant,
    createdAtUtc: DateTime.utc(2026, 6, 12, 9, 1),
    preview: 'Assistant',
    body: 'Assistant body',
    tokenCount: 20,
  ),
  ConversationMessageViewModel(
    id: 'tool-1',
    number: 3,
    author: ConversationAuthor.tool,
    createdAtUtc: DateTime.utc(2026, 6, 12, 9, 2),
    preview: 'Tool output',
    body: 'line 1\nline 2',
    tokenCount: 30,
    hasToolOutput: true,
  ),
  ConversationMessageViewModel(
    id: 'error-1',
    number: 4,
    author: ConversationAuthor.tool,
    createdAtUtc: DateTime.utc(2026, 6, 12, 9, 3),
    preview: 'Tool error',
    body: 'error',
    tokenCount: 40,
    hasError: true,
  ),
  ConversationMessageViewModel(
    id: 'user-2',
    number: 5,
    author: ConversationAuthor.user,
    createdAtUtc: DateTime.utc(2026, 6, 12, 9, 4),
    preview: 'Second user',
    body: 'Second user body',
    tokenCount: 50,
  ),
];
