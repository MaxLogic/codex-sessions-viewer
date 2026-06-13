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

    for (final label in SettingsDiagnosticAction.values.map(
      (action) => action.label,
    )) {
      expect(find.text(label), findsOneWidget);
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pump();

      expect(find.text('Result: Success. $label checked.'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Diagnostic result: Success. $label checked.'),
        findsOneWidget,
      );
    }

    expect(diagnostics.actions, SettingsDiagnosticAction.values);
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
    return SettingsDiagnosticResult.success('${action.label} checked.');
  }
}
