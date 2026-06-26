import 'package:codex_sessions_viewer/src/accessibility/announcement_service.dart';
import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/conversation_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders conversation lazily with message index navigation', (
    tester,
  ) async {
    final messages = [
      for (var i = 1; i <= 80; i++)
        ConversationMessageViewModel(
          id: 'm$i',
          number: i,
          author: i.isOdd
              ? ConversationAuthor.user
              : ConversationAuthor.assistant,
          createdAtUtc: DateTime.utc(2026, 6, 12, 9, i % 60),
          preview: 'Message $i preview',
          body: 'Message $i body',
          tokenCount: i * 10,
        ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ConversationView(messages: messages)),
      ),
    );

    expect(find.byType(ListView), findsWidgets);
    expect(find.text('Message 1 body'), findsOneWidget);
    expect(find.text('Message 80 body'), findsNothing);
    expect(find.bySemanticsLabel('#1 User, 10 tokens'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('#2 Assistant, 20 tokens'));
    await tester.pumpAndSettle();

    expect(find.text('Selected message 2'), findsOneWidget);
  });

  testWidgets('collapses long messages and tool output with explicit actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            messages: [
              ConversationMessageViewModel(
                id: 'long',
                number: 1,
                author: ConversationAuthor.assistant,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                preview: 'Long assistant answer preview',
                body: 'full long message ' * 80,
                tokenCount: 500,
                isLong: true,
              ),
              ConversationMessageViewModel(
                id: 'tool',
                number: 2,
                author: ConversationAuthor.tool,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9, 1),
                preview: 'shell_command',
                body: 'line 1\nline 2\nline 3',
                tokenCount: 30,
                hasToolOutput: true,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Long assistant answer preview'), findsOneWidget);
    expect(find.textContaining('full long message full long'), findsNothing);
    expect(
      find.widgetWithText(OutlinedButton, 'Show full message'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Tool output collapsed, 3 lines. Use the Expand tool output button to show it.',
      ),
      findsOneWidget,
    );
    expect(find.text('line 1\nline 2\nline 3'), findsNothing);
    expect(
      find.widgetWithText(OutlinedButton, 'Copy message Markdown'),
      findsNWidgets(2),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Expand tool output'));
    await tester.pumpAndSettle();
    expect(find.text('line 1\nline 2\nline 3'), findsOneWidget);
  });

  testWidgets('announces tool output expansion and collapse', (tester) async {
    final announcer = RecordingScreenReaderAnnouncer();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            announcer: announcer,
            messages: [
              ConversationMessageViewModel(
                id: 'tool',
                number: 1,
                author: ConversationAuthor.tool,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                preview: 'shell_command',
                body: 'line 1\nline 2\nline 3',
                tokenCount: 30,
                hasToolOutput: true,
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Expand tool output'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Collapse'));
    await tester.pumpAndSettle();

    expect(announcer.messages, [
      'Tool output expanded for message 1.',
      'Tool output collapsed for message 1.',
    ]);
  });

  testWidgets('copy message Markdown uses injected copy callback', (
    tester,
  ) async {
    final copied = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            messages: [
              ConversationMessageViewModel(
                id: 'm1',
                number: 1,
                author: ConversationAuthor.user,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                preview: 'Short preview',
                body: 'Full message body',
                tokenCount: 12,
              ),
            ],
            onCopyMessageMarkdown: (markdown) async {
              copied.add(markdown);
            },
          ),
        ),
      ),
    );

    await tester.tap(
      find.widgetWithText(OutlinedButton, 'Copy message Markdown'),
    );
    await tester.pumpAndSettle();

    expect(copied.single, contains('Full message body'));
    expect(find.text('Message Markdown copied.'), findsOneWidget);
  });

  testWidgets('message index reports unknown tokens instead of zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            messages: [
              ConversationMessageViewModel(
                id: 'missing-usage',
                number: 1,
                author: ConversationAuthor.user,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                preview: 'Prompt without message usage',
                body: 'Prompt without message usage',
                tokenCount: null,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.textContaining('tokens unknown'), findsOneWidget);
    expect(find.textContaining('0 tokens'), findsNothing);
    expect(find.bySemanticsLabel('#1 User, tokens unknown'), findsOneWidget);
  });

  testWidgets('message cards expose readable per-message semantics', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            messages: [
              ConversationMessageViewModel(
                id: 'm1',
                number: 1,
                author: ConversationAuthor.assistant,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                preview: 'Short answer body for the screen reader.',
                body: 'Short answer body for the screen reader.',
                tokenCount: 12,
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      find.bySemanticsLabel(
        'Message 1 Assistant. Short answer body for the screen reader.',
      ),
      findsOneWidget,
    );
  });
}
