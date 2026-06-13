import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/focus_reader_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'announces selected message changes without a giant message node',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusReaderView(
              messages: [
                ConversationMessageViewModel(
                  id: 'first',
                  number: 1,
                  author: ConversationAuthor.user,
                  createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                  preview: 'First prompt',
                  body: 'First prompt body',
                  tokenCount: 10,
                ),
                ConversationMessageViewModel(
                  id: 'second',
                  number: 2,
                  author: ConversationAuthor.assistant,
                  createdAtUtc: DateTime.utc(2026, 6, 12, 9, 1),
                  preview: 'Second answer',
                  body: 'Second answer body',
                  tokenCount: 20,
                ),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.widgetWithText(OutlinedButton, 'Next'));
      await tester.pumpAndSettle();

      final announcement = tester.getSemantics(
        find.byKey(const Key('focus-reader-announcement')),
      );
      expect(announcement.label, 'Selected message 2 of 2. Assistant.');

      final readable = tester.getSemantics(
        find.byKey(const Key('focus-reader-message')),
      );
      expect(readable.label, contains('Second answer body'));
      expect(readable.label, isNot(contains('First prompt body')));
    },
  );
}
