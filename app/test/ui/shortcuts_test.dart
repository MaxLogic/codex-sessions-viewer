import 'package:codex_sessions_viewer/src/ui/copy_shortcut.dart';
import 'package:codex_sessions_viewer/src/ui/dialogs/keyboard_shortcuts_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_sessions_screen.dart';

void main() {
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform uses its primary modifier for copy', (tester) async {
      var copies = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          home: CopyShortcut(
            autofocus: true,
            onCopy: () {
              copies++;
              return true;
            },
            child: const SizedBox(),
          ),
        ),
      );
      await tester.pump();
      final modifier = platform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(modifier);
      expect(copies, 1);
      final wrong = platform == TargetPlatform.macOS
          ? LogicalKeyboardKey.controlLeft
          : LogicalKeyboardKey.metaLeft;
      await tester.sendKeyDownEvent(wrong);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(wrong);
      expect(copies, 1);
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(modifier);
      expect(copies, 2, reason: 'Copy repeats remain ignored');
      for (final extra in [
        LogicalKeyboardKey.altLeft,
        LogicalKeyboardKey.shiftLeft,
        wrong,
      ]) {
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyDownEvent(extra);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(extra);
        await tester.sendKeyUpEvent(modifier);
        expect(copies, 2, reason: 'Extra modifiers do not trigger app copy');
      }
    });
  }
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    testWidgets('$platform session search binding and label agree', (
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
      final modifier = platform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
      final field = tester.widget<TextField>(
        find.descendant(
          of: find.bySemanticsLabel('Session search'),
          matching: find.byType(TextField),
        ),
      );
      expect(field.focusNode?.hasFocus, isTrue);
      expect(
        field.decoration?.hintText,
        contains(platform == TargetPlatform.macOS ? 'Cmd+F' : 'Ctrl+F'),
      );
    });
  }
  testWidgets('macOS help announces Cmd shortcuts', (tester) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.macOS),
        home: const KeyboardShortcutsDialog(),
      ),
    );
    expect(find.bySemanticsLabel("Cmd+F: Search sessions"), findsOneWidget);
    semantics.dispose();
  });
  testWidgets(
    'focused text keeps native primary copy',
    (tester) async {
      final controller = TextEditingController(text: 'selected text');
      final focus = FocusNode();
      final copied = <String>[];
      var appCopies = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': true};
          }
          return null;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        );
        controller.dispose();
        focus.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: CopyShortcut(
            onCopy: () {
              if (focusedTextOwnsCopy()) return false;
              appCopies++;
              return true;
            },
            child: Material(
              child: TextField(controller: controller, focusNode: focus),
            ),
          ),
        ),
      );
      focus.requestFocus();
      controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: controller.text.length,
      );
      await tester.pump();
      final modifier =
          Theme.of(tester.element(find.byType(TextField))).platform ==
              TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
      expect(appCopies, 0);
      expect(copied, ['selected text']);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.macOS,
      TargetPlatform.windows,
      TargetPlatform.linux,
    }),
  );
}
