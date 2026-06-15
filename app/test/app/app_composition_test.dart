import 'package:codex_sessions_viewer/src/ui/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app shell renders injected screen composition', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CodexAppShell(
          sessionsScreenBuilder: (context, onOpenSettings) {
            return Column(
              children: [
                const Text('Injected sessions screen'),
                TextButton(
                  onPressed: onOpenSettings,
                  child: const Text('Open injected settings'),
                ),
              ],
            );
          },
          usageScreen: const Text('Injected usage screen'),
          settingsScreen: const Text('Injected settings screen'),
          logsScreen: const Text('Injected logs screen'),
        ),
      ),
    );

    expect(find.text('Injected sessions screen'), findsOneWidget);

    await tester.tap(find.text('Open injected settings'));
    await tester.pumpAndSettle();
    expect(find.text('Injected settings screen'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Usage navigation'));
    await tester.pumpAndSettle();
    expect(find.text('Injected usage screen'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Logs navigation'));
    await tester.pumpAndSettle();
    expect(find.text('Injected logs screen'), findsOneWidget);
  });
}
