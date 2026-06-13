import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/conversation_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('does not expose an entire conversation as one semantics node', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConversationView(
            messages: [
              ConversationMessageViewModel(
                id: 'first',
                number: 1,
                author: ConversationAuthor.user,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                preview: 'First private prompt',
                body: 'First private prompt body',
                tokenCount: 10,
              ),
              ConversationMessageViewModel(
                id: 'last',
                number: 2,
                author: ConversationAuthor.assistant,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9, 1),
                preview: 'Last private answer',
                body: 'Last private answer body',
                tokenCount: 20,
              ),
            ],
          ),
        ),
      ),
    );

    final semantics = tester.getSemantics(
      find.byKey(const Key('conversation-view-semantics')),
    );
    expect(
      semantics.label.contains('First private prompt body') ||
          semantics.label.contains('Last private answer body'),
      isFalse,
    );
  });
}
