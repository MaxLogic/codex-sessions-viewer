import 'dart:io';

import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  testWidgets('app applies startup preference on load and save', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync(
      'csv_startup_registration_app_',
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final initialSettings = AppSettings.defaults().copyWith(
      app: const GeneralAppSettings(firstRun: false, startWithWindows: false),
    );
    var storedSettings = initialSettings;
    final applied = <bool>[];

    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 5),
        ),
        settingsFile: File(p.join(temp.path, 'settings.toml')),
        settingsStartup: Future.value(initialSettings),
        settingsSave: (settings) async {
          storedSettings = settings;
        },
        startupPreferenceApplier: (enabled) async {
          applied.add(enabled);
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(applied, [false]);

    await tester.tap(
      find.bySemanticsLabel(RegExp('^Settings navigation\\nTab ')),
    );
    await _pumpFrames(tester);
    await tester.tap(find.bySemanticsLabel('Open viewer at sign-in setting'));
    await tester.pump();
    await tester.tap(find.text('Save settings'));
    await _pumpFrames(tester);

    expect(storedSettings.app.startWithWindows, isTrue);
    expect(applied, [false, true]);
  });
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 250));
}
