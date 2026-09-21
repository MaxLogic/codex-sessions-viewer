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

    expect(find.textContaining('Message 2 of '), findsOneWidget);
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

    expect(
      find.descendant(
        of: find.byKey(const Key('message-card-1')),
        matching: find.text('Long assistant answer preview'),
      ),
      findsOneWidget,
    );
    expect(find.textContaining('full long message full long'), findsNothing);
    expect(
      find.widgetWithText(TextButton, 'Show full message'),
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
      find.bySemanticsLabel(RegExp(r'^Copy message \d+ as Markdown$')),
      findsNWidgets(2),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Expand tool output'));
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

    await tester.tap(find.widgetWithText(TextButton, 'Expand tool output'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Collapse'));
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

    await tester.tap(find.bySemanticsLabel('Copy message 1 as Markdown'));
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
    expect(
      find.bySemanticsLabel('Short answer body for the screen reader.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'preserves reading position and offers jump when new messages arrive',
    (tester) async {
      var messages = _messages(40);
      late StateSetter update;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return ConversationView(messages: messages);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.bySemanticsLabel('#5 Assistant, 5 tokens'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Message 5 of '), findsOneWidget);
      expect(find.text('Message 41 body'), findsNothing);

      update(() {
        messages = _messages(41);
      });
      await tester.pump();
      await tester.pumpAndSettle();

      expect(find.textContaining('Message 5 of '), findsOneWidget);
      expect(find.text('Message 41 body'), findsNothing);
      expect(find.bySemanticsLabel('Jump to newest message'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Jump to newest message'));
      await tester.pumpAndSettle();

      expect(find.text('Message 41 body'), findsOneWidget);
      expect(find.bySemanticsLabel('Jump to newest message'), findsNothing);
    },
  );

  testWidgets('announces new messages without stealing focus', (tester) async {
    final announcer = RecordingScreenReaderAnnouncer();
    var messages = _messages(40);
    late StateSetter update;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ConversationView(messages: messages, announcer: announcer);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('#5 Assistant, 5 tokens'));
    await tester.pumpAndSettle();
    announcer.messages.clear();

    update(() {
      messages = _messages(41);
    });
    await tester.pump();
    await tester.pumpAndSettle();

    expect(announcer.messages, [
      'Newer messages are available. Use Jump to newest to read them.',
    ]);
    expect(find.textContaining('Message 5 of '), findsOneWidget);
    expect(find.bySemanticsLabel('Jump to newest message'), findsOneWidget);
  });

  testWidgets('auto-scrolls when already near bottom', (tester) async {
    var messages = _messages(40);
    late StateSetter update;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ConversationView(messages: messages);
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Message 41 body'), findsNothing);

    update(() {
      messages = _messages(41);
    });
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Message 41 body'), findsOneWidget);
    expect(find.bySemanticsLabel('Jump to newest message'), findsNothing);
  });

  testWidgets('restores conversation position from message anchor', (
    tester,
  ) async {
    final reportedPositions = <ConversationPositionState>[];
    final messages = [
      for (var i = 1; i <= 30; i++)
        ConversationMessageViewModel(
          id: 'm$i',
          number: i,
          author: ConversationAuthor.assistant,
          createdAtUtc: DateTime.utc(2026, 6, 12, 9, i % 60),
          preview: 'Message $i preview',
          body: 'Message $i body',
          tokenCount: i,
        ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            messages: messages,
            initialMessageNumber: 24,
            onPositionChanged: reportedPositions.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Message 24 of '), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('#2 Assistant, 2 tokens'));
    await tester.pumpAndSettle();

    expect(reportedPositions.last.messageNumber, 2);
  });

  testWidgets('applies updated conversation position anchor', (tester) async {
    var initialMessageNumber = 5;
    late StateSetter update;
    final messages = [
      for (var i = 1; i <= 8; i++)
        ConversationMessageViewModel(
          id: 'm$i',
          number: i,
          author: ConversationAuthor.assistant,
          createdAtUtc: DateTime.utc(2026, 6, 12, 9, i),
          preview: 'Message $i preview',
          body: 'Message $i body',
          tokenCount: i,
        ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ConversationView(
                messages: messages,
                initialMessageNumber: initialMessageNumber,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Message 5 of '), findsOneWidget);

    update(() {
      initialMessageNumber = 3;
    });
    await tester.pumpAndSettle();

    expect(find.textContaining('Message 3 of '), findsOneWidget);
  });

  testWidgets('renders message index without loading all message bodies', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            messages: [
              for (var i = 1; i <= 12; i++)
                ConversationMessageViewModel(
                  id: 'metadata-$i',
                  number: i,
                  author: ConversationAuthor.assistant,
                  createdAtUtc: DateTime.utc(2026, 6, 12, 9, i),
                  preview: 'Metadata preview $i',
                  body: '',
                  tokenCount: i,
                  isBodyLoaded: false,
                ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('#1 Assistant, 1 tokens'), findsOneWidget);
    expect(find.textContaining('Metadata preview 1'), findsOneWidget);
    expect(find.text('Message 1 body'), findsNothing);
  });

  testWidgets('shows accessible placeholder for unloaded message body', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            messages: [
              ConversationMessageViewModel(
                id: 'metadata-only',
                number: 1,
                author: ConversationAuthor.assistant,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                preview: 'Metadata preview',
                body: '',
                tokenCount: 12,
                isBodyLoaded: false,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Message body not loaded yet.'), findsOneWidget);
    expect(
      find.bySemanticsLabel(
        'Message 1 Assistant. Message body not loaded yet.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('loads older messages when requested', (tester) async {
    var loadCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            messages: [
              ConversationMessageViewModel(
                id: 'old',
                number: 1,
                author: ConversationAuthor.user,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                preview: 'Older prompt preview',
                body: '',
                tokenCount: 4,
                isBodyLoaded: false,
              ),
              ConversationMessageViewModel(
                id: 'new',
                number: 2,
                author: ConversationAuthor.assistant,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9, 1),
                preview: 'Newest answer preview',
                body: 'Newest answer body',
                tokenCount: 8,
              ),
            ],
            onLoadOlderMessages: () async {
              loadCalls++;
              return [
                ConversationMessageViewModel(
                  id: 'old',
                  number: 1,
                  author: ConversationAuthor.user,
                  createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                  preview: 'Older prompt preview',
                  body: 'Older prompt body',
                  tokenCount: 4,
                ),
              ];
            },
          ),
        ),
      ),
    );

    expect(find.text('Message body not loaded yet.'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Load older conversation messages'),
      findsOneWidget,
    );

    await tester.tap(find.bySemanticsLabel('Load older conversation messages'));
    await tester.pumpAndSettle();

    expect(loadCalls, 1);
    expect(find.text('Older prompt body'), findsOneWidget);
    expect(find.text('Message body not loaded yet.'), findsNothing);
  });

  testWidgets('loads target page when index selects unloaded message', (
    tester,
  ) async {
    final requestedAnchors = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            messages: [
              ConversationMessageViewModel(
                id: 'old',
                number: 1,
                author: ConversationAuthor.user,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                preview: 'Older prompt preview',
                body: '',
                tokenCount: 4,
                isBodyLoaded: false,
              ),
              ConversationMessageViewModel(
                id: 'new',
                number: 2,
                author: ConversationAuthor.assistant,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9, 1),
                preview: 'Newest answer preview',
                body: 'Newest answer body',
                tokenCount: 8,
              ),
            ],
            onLoadMessagePage: (anchor) async {
              requestedAnchors.add(anchor);
              return [
                ConversationMessageViewModel(
                  id: 'old',
                  number: 1,
                  author: ConversationAuthor.user,
                  createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                  preview: 'Older prompt preview',
                  body: 'Older prompt body',
                  tokenCount: 4,
                ),
              ];
            },
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('#1 User, 4 tokens'));
    await tester.pumpAndSettle();

    expect(requestedAnchors, [1]);
    expect(find.textContaining('Message 1 of '), findsOneWidget);
    expect(find.text('Older prompt body'), findsOneWidget);
  });

  testWidgets('user prompts are tinted and assistant replies stay neutral', (
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
                author: ConversationAuthor.user,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                preview: 'Prompt',
                body: 'Prompt',
                tokenCount: 8,
              ),
              ConversationMessageViewModel(
                id: 'm2',
                number: 2,
                author: ConversationAuthor.assistant,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9, 1),
                preview: 'Answer',
                body: 'Answer',
                tokenCount: 12,
              ),
            ],
          ),
        ),
      ),
    );

    final scheme = Theme.of(
      tester.element(find.byType(ConversationView)),
    ).colorScheme;
    final firstCard = tester.widget<DecoratedBox>(
      find.byKey(const Key('message-card-1')),
    );
    final secondCard = tester.widget<DecoratedBox>(
      find.byKey(const Key('message-card-2')),
    );

    expect(
      (firstCard.decoration as BoxDecoration).color,
      isNot(scheme.surface),
    );
    expect((secondCard.decoration as BoxDecoration).color, scheme.surface);
  });
}

List<ConversationMessageViewModel> _messages(int count) {
  return [
    for (var i = 1; i <= count; i++)
      ConversationMessageViewModel(
        id: 'm$i',
        number: i,
        author: ConversationAuthor.assistant,
        createdAtUtc: DateTime.utc(2026, 6, 12, 9, i % 60),
        preview: 'Message $i preview',
        body: 'Message $i body',
        tokenCount: i,
      ),
  ];
}
