import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/config/default_session_folders.dart';
import 'package:codex_sessions_viewer/src/platform/wsl_default_distro_detector.dart';
import 'package:codex_sessions_viewer/src/window/window_state.dart';
import 'package:codex_sessions_viewer/main.dart' as app;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart' as wm;

void main() {
  test('window state storage round-trips through settings.toml', () async {
    final temp = await Directory.systemTemp.createTemp('csv_window_state_');
    addTearDown(() async {
      if (await temp.exists()) {
        await temp.delete(recursive: true);
      }
    });

    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    await SettingsRepository(settingsFile).save(AppSettings.defaults());
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

  test('restoring the window before the first frame never creates settings '
      'or runs WSL detection', () async {
    final temp = await Directory.systemTemp.createTemp('csv_window_first_');
    addTearDown(() => temp.delete(recursive: true));
    final settingsFile = File(p.join(temp.path, 'settings.toml'));
    final detector = _CountingWslDetector();
    final store = WindowStateStore(
      SettingsRepository(settingsFile, wslDetector: detector),
    );

    expect(await store.load(), isNull);
    await store.save(
      const PersistedWindowState(
        x: 1,
        y: 2,
        width: 800,
        height: 600,
        isMaximized: false,
      ),
    );
    expect(settingsFile.existsSync(), isFalse);
    expect(detector.calls, 0);

    // The settings startup after the first frame creates the file, runs the
    // detection once, and later window moves are saved.
    await SettingsRepository(
      settingsFile,
      wslDetector: detector,
    ).loadOrCreate();
    expect(detector.calls, 1);
    await store.save(
      const PersistedWindowState(
        x: 1,
        y: 2,
        width: 800,
        height: 600,
        isMaximized: false,
      ),
    );
    expect((await store.load())?.width, 800);
    expect(detector.calls, 1);
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

  test(
    'maximized state is saved without overwriting restored bounds',
    () async {
      final store = _MemoryWindowStateStore(
        const PersistedWindowState(
          x: 40,
          y: 50,
          width: 1280,
          height: 820,
          isMaximized: false,
        ),
      );
      final manager = _FakeWindowManager()
        ..position = const Offset(0, 0)
        ..size = const Size(1920, 1080)
        ..maximized = true;
      final controller = AppWindowStateController(
        store: store,
        manager: manager,
        displayProvider: const _FakeDisplayProvider([
          Rect.fromLTWH(0, 0, 1920, 1080),
        ]),
      );

      controller.onWindowMaximize();
      await _flushMicrotasks();

      expect(
        store.saved.single,
        const PersistedWindowState(
          x: 40,
          y: 50,
          width: 1280,
          height: 820,
          isMaximized: true,
        ),
      );
    },
  );

  test(
    'first maximize saves a centered normal size, not the full screen',
    () async {
      final store = _MemoryWindowStateStore(null);
      final manager = _FakeWindowManager()
        ..position = const Offset(-8, -8)
        ..size = const Size(1936, 1096)
        ..maximized = true;
      final controller = AppWindowStateController(
        store: store,
        manager: manager,
        displayProvider: const _FakeDisplayProvider([
          Rect.fromLTWH(0, 0, 1920, 1080),
        ]),
      );

      controller.onWindowMaximize();
      await _flushMicrotasks();

      expect(
        store.saved.single,
        const PersistedWindowState(
          x: 192,
          y: 108,
          width: 1536,
          height: 864,
          isMaximized: true,
        ),
      );
    },
  );

  test('concurrent settings updates keep every change', () async {
    final temp = await Directory.systemTemp.createTemp('csv_settings_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.toml');
    final windowStore = WindowStateStore(SettingsRepository(file));
    await SettingsRepository(file).save(AppSettings.defaults());

    const table = SessionTableSettings(
      columnWidths: {'project': 200},
      newestPerProjectOnly: true,
      sorts: [SessionTableSortSettings(column: 'project', ascending: true)],
    );
    await Future.wait([
      windowStore.save(
        const PersistedWindowState(
          x: 1,
          y: 2,
          width: 1000,
          height: 700,
          isMaximized: true,
        ),
      ),
      SettingsRepository(file).update(
        (settings) =>
            settings.copyWith(ui: settings.ui.copyWith(sessionTable: table)),
      ),
    ]);

    final saved = await SettingsRepository(file).loadOrCreate();
    expect(saved.ui.window?.isMaximized, isTrue);
    expect(saved.ui.sessionTable.newestPerProjectOnly, isTrue);
    expect(File('${file.path}.tmp').existsSync(), isFalse);
  });

  test('normal state saves current restored bounds', () async {
    final store = _MemoryWindowStateStore(null);
    final manager = _FakeWindowManager()
      ..position = const Offset(80, 90)
      ..size = const Size(1000, 700)
      ..maximized = false;
    final controller = AppWindowStateController(
      store: store,
      manager: manager,
      displayProvider: const _FakeDisplayProvider([
        Rect.fromLTWH(0, 0, 1920, 1080),
      ]),
    );

    controller.onWindowResized();
    await _flushMicrotasks();

    expect(
      store.saved.single,
      const PersistedWindowState(
        x: 80,
        y: 90,
        width: 1000,
        height: 700,
        isMaximized: false,
      ),
    );
  });

  test(
    'restore keeps valid maximized state and clamps off-screen bounds',
    () async {
      final store = _MemoryWindowStateStore(
        const PersistedWindowState(
          x: 5000,
          y: 5000,
          width: 1400,
          height: 900,
          isMaximized: true,
        ),
      );
      final manager = _FakeWindowManager();
      final controller = AppWindowStateController(
        store: store,
        manager: manager,
        displayProvider: const _FakeDisplayProvider([
          Rect.fromLTWH(0, 0, 1920, 1080),
        ]),
      );

      await controller.restoreAndTrack();

      expect(manager.positions.single, const Offset(80, 80));
      expect(manager.sizes.single, const Size(1400, 900));
      expect(manager.maximizeCount, 1);
      expect(manager.listenerAdded, isTrue);
    },
  );

  test('first launch starts maximized without saved placement', () async {
    final manager = _FakeWindowManager();
    final controller = AppWindowStateController(
      store: _MemoryWindowStateStore(null),
      manager: manager,
    );

    await controller.restoreAndTrack();

    expect(manager.maximizeCount, 1);
    expect(manager.listenerAdded, isTrue);
  });

  test('damaged placement still starts maximized', () async {
    final manager = _FakeWindowManager();
    final controller = AppWindowStateController(
      store: _ThrowingWindowStateStore(),
      manager: manager,
    );

    await controller.restoreAndTrack();

    expect(manager.maximizeCount, 1);
    expect(manager.listenerAdded, isTrue);
  });

  test('restore treats barely visible windows as off-screen', () async {
    final store = _MemoryWindowStateStore(
      const PersistedWindowState(
        x: 1919,
        y: 100,
        width: 1200,
        height: 700,
        isMaximized: false,
      ),
    );
    final manager = _FakeWindowManager();
    final controller = AppWindowStateController(
      store: store,
      manager: manager,
      displayProvider: const _FakeDisplayProvider([
        Rect.fromLTWH(0, 0, 1920, 1080),
      ]),
    );

    await controller.restoreAndTrack();

    expect(manager.positions.single, const Offset(80, 80));
    expect(manager.sizes.single, const Size(1200, 700));
    expect(
      manager.maximizeCount,
      0,
      reason: 'A window saved in its normal state must reopen restored.',
    );
    expect(manager.listenerAdded, isTrue);
  });

  test('restore fallback keeps oversized windows inside the display', () async {
    final store = _MemoryWindowStateStore(
      const PersistedWindowState(
        x: 5000,
        y: 5000,
        width: 4000,
        height: 3000,
        isMaximized: false,
      ),
    );
    final manager = _FakeWindowManager();
    final controller = AppWindowStateController(
      store: store,
      manager: manager,
      displayProvider: const _FakeDisplayProvider([
        Rect.fromLTWH(0, 0, 1920, 1080),
      ]),
    );

    await controller.restoreAndTrack();

    expect(manager.positions.single, const Offset(80, 80));
    expect(manager.sizes.single, const Size(1760, 920));
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

Future<void> _flushMicrotasks() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _MemoryWindowStateStore implements WindowStatePersistence {
  _MemoryWindowStateStore(this.state);

  PersistedWindowState? state;
  final saved = <PersistedWindowState>[];

  @override
  Future<PersistedWindowState?> load() async => state;

  @override
  Future<void> save(PersistedWindowState state) async {
    this.state = state;
    saved.add(state);
  }
}

class _ThrowingWindowStateStore implements WindowStatePersistence {
  @override
  Future<PersistedWindowState?> load() async =>
      throw const FormatException('bad placement');

  @override
  Future<void> save(PersistedWindowState state) async {}
}

class _FakeDisplayProvider implements WindowDisplayProvider {
  const _FakeDisplayProvider(this.frames);

  final List<Rect> frames;

  @override
  Future<List<Rect>> visibleFrames() async => frames;
}

class _FakeWindowManager implements AppWindowManager {
  Offset position = Offset.zero;
  Size size = const Size(800, 600);
  bool maximized = false;
  final positions = <Offset>[];
  final sizes = <Size>[];
  var maximizeCount = 0;
  var listenerAdded = false;

  @override
  void addListener(wm.WindowListener listener) {
    listenerAdded = true;
  }

  @override
  Future<void> ensureInitialized() async {}

  @override
  Future<Offset> getPosition() async => position;

  @override
  Future<Size> getSize() async => size;

  @override
  Future<bool> isMaximized() async => maximized;

  @override
  Future<void> maximize() async {
    maximizeCount++;
    maximized = true;
  }

  @override
  void removeListener(wm.WindowListener listener) {}

  @override
  Future<void> setPosition(Offset position) async {
    this.position = position;
    positions.add(position);
  }

  @override
  Future<void> setSize(Size size) async {
    this.size = size;
    sizes.add(size);
  }
}

final class _CountingWslDetector implements WslDefaultDistroDetector {
  int calls = 0;

  @override
  Future<WslDistroDefaults?> detect() async {
    calls++;
    return const WslDistroDefaults(distro: 'Debian', linuxHome: '/home/ada');
  }
}
