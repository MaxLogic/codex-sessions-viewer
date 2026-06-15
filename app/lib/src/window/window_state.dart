import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart' as wm;

import '../config/app_settings.dart';

class PersistedWindowState {
  const PersistedWindowState({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.isMaximized,
  });

  final double x;
  final double y;
  final double width;
  final double height;
  final bool isMaximized;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PersistedWindowState &&
          x == other.x &&
          y == other.y &&
          width == other.width &&
          height == other.height &&
          isMaximized == other.isMaximized;

  @override
  int get hashCode => Object.hash(x, y, width, height, isMaximized);
}

class WindowStateStore {
  const WindowStateStore(this.repository);

  final SettingsRepository repository;

  Future<PersistedWindowState?> load() async {
    final placement = (await repository.loadOrCreate()).ui.window;
    if (placement == null) {
      return null;
    }
    return PersistedWindowState(
      x: placement.x,
      y: placement.y,
      width: placement.width,
      height: placement.height,
      isMaximized: placement.isMaximized,
    );
  }

  Future<void> save(PersistedWindowState state) async {
    final settings = await repository.loadOrCreate();
    await repository.save(
      settings.copyWith(
        ui: settings.ui.copyWith(
          window: WindowPlacementSettings(
            x: state.x,
            y: state.y,
            width: state.width,
            height: state.height,
            isMaximized: state.isMaximized,
          ),
        ),
      ),
    );
  }
}

class AppWindowStateController with wm.WindowListener {
  AppWindowStateController({required this.store, wm.WindowManager? manager})
    : windowManager = manager ?? wm.windowManager;

  final WindowStateStore store;
  final wm.WindowManager windowManager;

  Future<void> restoreAndTrack() async {
    await windowManager.ensureInitialized();
    final state = await store.load();
    if (state != null) {
      await windowManager.setSize(Size(state.width, state.height));
      await windowManager.setPosition(Offset(state.x, state.y));
      if (state.isMaximized) {
        await windowManager.maximize();
      }
    }
    windowManager.addListener(this);
  }

  Future<void> dispose() async {
    windowManager.removeListener(this);
  }

  @override
  void onWindowMoved() {
    unawaited(_saveCurrent());
  }

  @override
  void onWindowResized() {
    unawaited(_saveCurrent());
  }

  @override
  void onWindowMaximize() {
    unawaited(_saveCurrent());
  }

  @override
  void onWindowUnmaximize() {
    unawaited(_saveCurrent());
  }

  Future<void> _saveCurrent() async {
    final isMaximized = await windowManager.isMaximized();
    final position = await windowManager.getPosition();
    final size = await windowManager.getSize();
    await store.save(
      PersistedWindowState(
        x: position.dx,
        y: position.dy,
        width: size.width,
        height: size.height,
        isMaximized: isMaximized,
      ),
    );
  }
}
