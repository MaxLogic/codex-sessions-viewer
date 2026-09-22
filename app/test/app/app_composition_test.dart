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
          evalsScreen: const Text('Injected evals screen'),
          contextScreen: const Text('Injected context screen'),
          usageScreen: const Text('Injected usage screen'),
          settingsScreen: const Text('Injected settings screen'),
          logsScreen: const Text('Injected logs screen'),
          projectsScreen: const Text('Projects content'),
        ),
      ),
    );

    expect(find.text('Injected sessions screen'), findsOneWidget);

    await tester.tap(find.text('Open injected settings'));
    await tester.pumpAndSettle();
    expect(find.text('Injected settings screen'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(RegExp('^Evals navigation\\nTab ')));
    await tester.pumpAndSettle();
    expect(find.text('Injected evals screen'), findsOneWidget);

    await tester.tap(
      find.bySemanticsLabel(RegExp('^Context navigation\\nTab ')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Injected context screen'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')));
    await tester.pumpAndSettle();
    expect(find.text('Injected usage screen'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(RegExp('^Logs navigation\\nTab ')));
    await tester.pumpAndSettle();
    expect(find.text('Injected logs screen'), findsOneWidget);
  });
}
