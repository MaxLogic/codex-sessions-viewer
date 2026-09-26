import 'package:codex_sessions_viewer/src/commands/resume_command_generator.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/command_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/fixture_settings.dart';

void main() {
  testWidgets('shows plain, platform, and terminal launch command variants', (
    tester,
  ) async {
    final commandSet =
        ResumeCommandGenerator(settings: fixtureDefaultSettings()).build(
          const ResumeCommandSession(
            sessionId: 'abc123',
            sourceType: ResumeSessionSourceType.wsl,
            workingDirectory: '/home/pawel/project',
          ),
        );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CommandPreview(commandSet: commandSet)),
      ),
    );

    expect(find.text('Command preview'), findsOneWidget);
    expect(find.text('Plain resume command:'), findsOneWidget);
    expect(find.text('codex resume abc123'), findsOneWidget);
    expect(find.text('Platform resume command:'), findsOneWidget);
    expect(
      find.text(
        'wsl.exe -d Ubuntu --cd /home/pawel/project bash -lc "\'codex\' \'resume\' \'abc123\'"',
      ),
      findsOneWidget,
    );
    expect(find.text('Terminal launch command:'), findsOneWidget);
    expect(find.textContaining('alacritty.exe'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Copy'), findsNWidgets(3));
    expect(find.bySemanticsLabel('Copy plain resume command'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Copy platform resume command'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Copy terminal launch command'),
      findsOneWidget,
    );
    expect(find.widgetWithText(OutlinedButton, 'Run'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Edit and run'), findsOneWidget);
  });

  testWidgets('explains why resume commands are unavailable', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CommandPreview(
            commandSet: ResumeCommandSet.unavailable(
              disabledReason:
                  'Resume unavailable: this session has no parsed Codex session ID.',
            ),
          ),
        ),
      ),
    );

    expect(
      find.text(
        'Resume unavailable: this session has no parsed Codex session ID.',
      ),
      findsOneWidget,
    );
    expect(find.text('Plain resume command:'), findsNothing);
  });

  testWidgets('runs and edits terminal launch command through callbacks', (
    tester,
  ) async {
    final commandSet =
        ResumeCommandGenerator(settings: fixtureDefaultSettings()).build(
          const ResumeCommandSession(
            sessionId: 'abc123',
            sourceType: ResumeSessionSourceType.windows,
            workingDirectory: r'F:\project',
          ),
        );
    final ran = <String>[];
    final edited = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CommandPreview(
            commandSet: commandSet,
            onRunTerminalCommand: (command) async {
              ran.add(command);
            },
            onEditTerminalCommand: (command) async {
              edited.add(command);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Run'));
    await tester.pumpAndSettle();
    expect(ran.single, contains('codex resume abc123'));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Edit and run'));
    await tester.pumpAndSettle();
    expect(find.text('Edit terminal command'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'custom terminal command');
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await tester.pumpAndSettle();

    expect(edited.single, 'custom terminal command');
  });
}
