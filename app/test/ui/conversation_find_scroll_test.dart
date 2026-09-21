import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/conversation_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('find scrolls a distant match into view', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final messages = [
      for (var i = 1; i <= 60; i++)
        ConversationMessageViewModel(
          id: 'm$i',
          number: i,
          author: i.isOdd
              ? ConversationAuthor.user
              : ConversationAuthor.assistant,
          createdAtUtc: DateTime.utc(2026, 6, 12, 9, i % 60),
          preview: 'Message $i',
          // Uneven heights make offset estimates unreliable.
          body: [
            'Message $i',
            for (var line = 0; line < (i % 7) * 3; line++) 'filler line $line',
            if (i == 9) 'needle here',
          ].join('\n'),
          tokenCount: i,
        ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            messages: messages,
            initialToolCallVisibility: ToolCallVisibility.hide,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Message 60 of 60'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('conversation-find-field')),
      'needle',
    );
    await tester.pumpAndSettle();

    expect(find.text('1 of 1'), findsOneWidget);
    final card = find.byKey(const Key('message-card-9'));
    expect(card, findsOneWidget);
    final listRect = tester.getRect(
      find.bySemanticsLabel('Conversation messages'),
    );
    final cardRect = tester.getRect(card);
    expect(cardRect.overlaps(listRect), isTrue);
    expect(cardRect.top, greaterThanOrEqualTo(listRect.top - cardRect.height));
    expect(cardRect.top, lessThan(listRect.bottom));
  });

  testWidgets('find scrolls to a match found after loading paged bodies', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    ConversationMessageViewModel message(int i, {required bool loaded}) {
      final body = [
        'Message $i',
        for (var line = 0; line < (i % 7) * 3; line++) 'filler line $line',
        if (i == 9) 'needle here',
      ].join('\n');
      return ConversationMessageViewModel(
        id: 'm$i',
        number: i,
        author: i.isOdd
            ? ConversationAuthor.user
            : ConversationAuthor.assistant,
        createdAtUtc: DateTime.utc(2026, 6, 12, 9, i % 60),
        preview: 'Message $i',
        body: loaded ? body : '',
        tokenCount: i,
        isBodyLoaded: loaded,
      );
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            messages: [
              for (var i = 1; i <= 60; i++) message(i, loaded: i > 50),
            ],
            initialToolCallVisibility: ToolCallVisibility.hide,
            onLoadAllMessages: () async => [
              for (var i = 1; i <= 60; i++) message(i, loaded: true),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('conversation-find-field')),
      'needle',
    );
    await tester.pumpAndSettle();

    expect(find.text('1 of 1'), findsOneWidget);
    final card = find.byKey(const Key('message-card-9'));
    expect(card, findsOneWidget);
    final listRect = tester.getRect(
      find.bySemanticsLabel('Conversation messages'),
    );
    final cardRect = tester.getRect(card);
    expect(cardRect.overlaps(listRect), isTrue);
  });
}
