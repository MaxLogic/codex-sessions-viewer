import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/window/window_state.dart';
import 'package:codex_sessions_viewer/main.dart' as app;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('window state storage round-trips through settings.toml', () async {
    final temp = await Directory.systemTemp.createTemp('csv_window_state_');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    final store = WindowStateStore(SettingsRepository(settingsFile));
    final state = PersistedWindowState(
      x: 40,
      y: 50,
      width: 1280,
      height: 820,
      isMaximized: true,
    );

    await store.save(state);

    expect(await store.load(), state);
    expect(File(p.join(temp.path, 'window_state.json')).existsSync(), isFalse);
    expect(await settingsFile.readAsString(), contains('[ui.window]'));
  });

  test('window state storage ignores missing window placement', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_window_state_empty_',
    );
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final store = WindowStateStore(
      SettingsRepository(File(p.join(temp.path, 'settings.toml'))),
    );

    expect(await store.load(), isNull);
  });

  test('window restore failure is best effort during startup', () async {
    var called = false;

    await app.restoreWindowStateBestEffort(() async {
      called = true;
      throw const FormatException('bad settings');
    });

    expect(called, isTrue);
  });
}
