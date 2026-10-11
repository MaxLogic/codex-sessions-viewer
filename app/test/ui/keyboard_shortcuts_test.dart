import 'package:codex_sessions_viewer/src/ui/app_shell.dart';
import 'package:codex_sessions_viewer/src/ui/dialogs/keyboard_shortcuts_dialog.dart';
import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_sessions_screen.dart';

Widget _shell({TargetPlatform? platform}) {
  return MaterialApp(
    theme: ThemeData(platform: platform),
    home: CodexAppShell(
      sessionsScreenBuilder: (_, _) => const Text('Sessions content'),
      evalsScreen: const Text('Evals content'),
      contextScreen: const Text('Context content'),
      usageScreen: const Text('Usage content'),
      settingsScreen: const Text('Settings content'),
      logsScreen: const Text('Logs content'),
      projectsScreen: const Text('Projects content'),
    ),
  );
}

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ]) {
    group('$platform', () {
      testWidgets('Shortcuts button lists every shortcut group', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(1400, 1400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(_shell(platform: platform));

        await tester.tap(find.text('Shortcuts'));
        await tester.pumpAndSettle();

        expect(find.text('Keyboard shortcuts'), findsOneWidget);
        // The list is virtualized; later groups appear as it scrolls.
        for (final group in keyboardShortcutGroups) {
          await tester.scrollUntilVisible(
            find.descendant(
              of: find.byType(Dialog),
              matching: find.text(group.title),
            ),
            200,
            scrollable: find
                .descendant(
                  of: find.byType(Dialog),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(find.text(group.title), findsWidgets);
        }
        await tester.scrollUntilVisible(
          find.bySemanticsLabel(
            '${platform == TargetPlatform.macOS ? 'Cmd' : 'Ctrl'}+F: Find in the conversation',
          ),
          -200,
          scrollable: find
              .descendant(
                of: find.byType(Dialog),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(
          find.bySemanticsLabel(
            '${platform == TargetPlatform.macOS ? 'Cmd' : 'Ctrl'}+F: Find in the conversation',
          ),
          findsOneWidget,
        );

        await tester.tap(find.widgetWithText(FilledButton, 'Close'));
        await tester.pumpAndSettle();
        expect(find.text('Keyboard shortcuts'), findsNothing);
      });

      testWidgets('F1 opens the shortcuts once, even without focus', (
        tester,
      ) async {
        await tester.pumpWidget(_shell(platform: platform));

        await tester.sendKeyEvent(LogicalKeyboardKey.f1);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.f1);
        await tester.pumpAndSettle();

        expect(find.byType(KeyboardShortcutsDialog), findsOneWidget);
      });

      testWidgets('Ctrl+E exports the selected session and Ctrl+L goes to '
          'the filters', (tester) async {
        await tester.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final exported = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: Scaffold(
              body: TestSessionsScreen(
                initialRows: [
                  SessionRowViewModel(
                    id: 'one',
                    sessionId: 'one',
                    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
                    lastMessageAtUtc: DateTime.utc(2026, 6, 12, 10),
                    platform: SessionRowPlatform.windows,
                    project: 'Viewer',
                    path: r'F:\projects\viewer',
                    title: 'Export me',
                    summary: 'Export me',
                    messageCount: 1,
                    totalTokens: 10,
                    model: 'gpt-5.4',
                    tags: const [],
                    status: 'Available',
                    conversationMessages: [
                      ConversationMessageViewModel(
                        id: 'm1',
                        number: 1,
                        author: ConversationAuthor.user,
                        createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                        preview: 'Hello',
                        body: 'Hello there',
                        tokenCount: 3,
                      ),
                    ],
                  ),
                ],
                onExportMarkdown: (row, markdown) async =>
                    exported.add(markdown),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Export me').first);
        await tester.pumpAndSettle();

        await tester.sendKeyDownEvent(
          platform == TargetPlatform.macOS
              ? LogicalKeyboardKey.metaLeft
              : LogicalKeyboardKey.controlLeft,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
        await tester.sendKeyUpEvent(
          platform == TargetPlatform.macOS
              ? LogicalKeyboardKey.metaLeft
              : LogicalKeyboardKey.controlLeft,
        );
        await tester.pumpAndSettle();
        expect(exported.single, contains('# Export me'));
        expect(exported.single, contains('Hello there'));

        await tester.sendKeyDownEvent(
          platform == TargetPlatform.macOS
              ? LogicalKeyboardKey.metaLeft
              : LogicalKeyboardKey.controlLeft,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
        await tester.sendKeyUpEvent(
          platform == TargetPlatform.macOS
              ? LogicalKeyboardKey.metaLeft
              : LogicalKeyboardKey.controlLeft,
        );
        await tester.pump();
        final focused = FocusManager.instance.primaryFocus?.context;
        expect(focused, isNotNull);
        expect(
          find
              .ancestor(
                of: find.byWidget(focused!.widget),
                matching: find.bySemanticsLabel('Project filter'),
              )
              .evaluate()
              .isNotEmpty,
          isTrue,
        );
      });

      testWidgets('Ctrl+F focuses session search right after startup', (
        tester,
      ) async {
        await tester.binding.setSurfaceSize(const Size(1600, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: platform),
            home: TestSessionsScreen(),
          ),
        );
        await tester.pumpAndSettle();

        await tester.sendKeyDownEvent(
          platform == TargetPlatform.macOS
              ? LogicalKeyboardKey.metaLeft
              : LogicalKeyboardKey.controlLeft,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
        await tester.sendKeyUpEvent(
          platform == TargetPlatform.macOS
              ? LogicalKeyboardKey.metaLeft
              : LogicalKeyboardKey.controlLeft,
        );
        await tester.pump();

        final field = tester.widget<TextField>(
          find.descendant(
            of: find.bySemanticsLabel('Session search'),
            matching: find.byType(TextField),
          ),
        );
        expect(field.focusNode?.hasFocus, isTrue);
      });
    });
  }
}
