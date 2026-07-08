import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/config/settings_diagnostics.dart';
import 'package:codex_sessions_viewer/src/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('required diagnostic buttons report readable results', (
    tester,
  ) async {
    final diagnostics = _RecordingDiagnostics();

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaults(),
          diagnostics: diagnostics,
        ),
      ),
    );

    for (final action in SettingsDiagnosticAction.values) {
      final label = action.label;
      final expectedMessage =
          action == SettingsDiagnosticAction.messageSearchBackfillStatus
          ? 'Message search backfill: 5 indexed, 3 remaining.'
          : '$label checked.';
      expect(find.text(label), findsOneWidget);
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pump();

      expect(find.text('Result: Success. $expectedMessage'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Diagnostic result: Success. $expectedMessage'),
        findsOneWidget,
      );
    }

    expect(diagnostics.actions, SettingsDiagnosticAction.values);
  });

  testWidgets('message search backfill reports progress', (tester) async {
    final diagnostics = _RecordingDiagnostics();

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaults(),
          diagnostics: diagnostics,
        ),
      ),
    );

    await tester.ensureVisible(find.text('Message search backfill status'));
    await tester.tap(find.text('Message search backfill status'));
    await tester.pump();

    expect(
      find.text(
        'Result: Success. Message search backfill: 5 indexed, 3 remaining.',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        'Diagnostic result: Success. Message search backfill: 5 indexed, 3 remaining.',
      ),
      findsOneWidget,
    );
  });
}

class _RecordingDiagnostics implements SettingsDiagnostics {
  final actions = <SettingsDiagnosticAction>[];

  @override
  Future<SettingsDiagnosticResult> run(
    SettingsDiagnosticAction action,
    AppSettings settings,
  ) async {
    actions.add(action);
    if (action == SettingsDiagnosticAction.messageSearchBackfillStatus) {
      return SettingsDiagnosticResult.success(
        'Message search backfill: 5 indexed, 3 remaining.',
      );
    }
    return SettingsDiagnosticResult.success('${action.label} checked.');
  }
}
