import 'package:codex_sessions_viewer/src/accessibility/announcement_service.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/ui/screens/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows required settings groups and saves explicit changes', (
    tester,
  ) async {
    final announcer = RecordingScreenReaderAnnouncer();
    AppSettings? saved;

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaults(),
          announcer: announcer,
          onSave: (settings) async {
            saved = settings;
          },
        ),
      ),
    );

    for (final section in const [
      'Paths',
      'WSL',
      'Terminal',
      'Scanner',
      'Appearance',
      'Voice-over',
      'Pricing',
      'Data and cache',
      'Diagnostics',
    ]) {
      expect(find.text(section), findsOneWidget);
    }

    for (final label in const [
      'Windows Codex path',
      'WSL Codex UNC path',
      'WSL distro name',
      'WSL Linux home path',
      'WSL UNC root',
      'Default terminal',
      'Alacritty executable path',
      'Windows Terminal executable path',
      'Scan interval (seconds)',
      'Background scan enabled',
      'Theme',
      'Font size (pixels)',
      'UI density',
      'Show icons',
      'Show text on buttons',
      'Native title bar',
      'Voice-over enabled',
      'Voice-over file paths',
      'OpenRouter pricing enabled',
      'Pricing cache duration (hours)',
      'Pricing overrides',
      'Cache/database location',
      'Export folder',
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    for (final helper in const [
      'Folder containing native Windows Codex session files.',
      'UNC folder used to read WSL Codex sessions from Windows.',
      'Command profile used when launching resume commands.',
      'One voice-over event WAV path per line.',
      'Public model-pricing metadata only; no session content is sent.',
    ]) {
      expect(find.text(helper), findsOneWidget);
    }

    await tester.enterText(
      find.bySemanticsLabel('Windows Codex path input'),
      r'D:\Codex',
    );
    await tester.tap(find.text('Save settings'));
    await tester.pump();

    expect(saved?.paths.windowsCodexPath, r'D:\Codex');
    expect(find.text('Settings saved.'), findsOneWidget);
    expect(announcer.messages, contains('Settings saved.'));
  });

  testWidgets('cancel and reload make explicit state changes', (tester) async {
    final reloaded = AppSettings.defaults().copyWith(
      paths: const PathSettings(
        windowsCodexPath: r'E:\Reloaded',
        wslCodexUncPath: r'\\wsl.localhost\Ubuntu\home\pawel\.codex',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaults(),
          onReload: () async => reloaded,
        ),
      ),
    );

    await tester.enterText(
      find.bySemanticsLabel('Windows Codex path input'),
      r'D:\Unsaved',
    );
    await tester.tap(find.text('Cancel changes'));
    await tester.pump();

    expect(find.text('Changes canceled.'), findsOneWidget);
    expect(find.text(r'C:\Users\pawel\.codex'), findsOneWidget);

    await tester.tap(find.text('Reload from file'));
    await tester.pump();

    expect(find.text('Settings reloaded.'), findsOneWidget);
    expect(find.text(r'E:\Reloaded'), findsOneWidget);
  });

  testWidgets('settings screen edits motion preference', (tester) async {
    AppSettings? saved;

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          initialSettings: AppSettings.defaults(),
          onSave: (settings) async {
            saved = settings;
          },
        ),
      ),
    );

    expect(find.text('Motion'), findsOneWidget);
    expect(find.text('system'), findsWidgets);

    await tester.ensureVisible(find.text('Motion'));
    await tester.pumpAndSettle();

    final motionRow = find.ancestor(
      of: find.text('Motion'),
      matching: find.byType(Row),
    );
    final motionDropdown = find.descendant(
      of: motionRow,
      matching: find.byType(DropdownButton<String>),
    );

    await tester.tap(motionDropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('normal').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save settings'));
    await tester.pump();

    expect(saved?.ui.motion, AppMotionMode.normal);
  });

  testWidgets('motion choice exposes an accessible control name', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(initialSettings: AppSettings.defaults()),
      ),
    );

    await tester.ensureVisible(find.text('Motion'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Motion setting'), findsOneWidget);

    semantics.dispose();
  });
}
