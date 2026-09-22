import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:screen_retriever/screen_retriever.dart';
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

abstract interface class WindowStatePersistence {
  Future<PersistedWindowState?> load();
  Future<void> save(PersistedWindowState state);
}

class WindowStateStore implements WindowStatePersistence {
  const WindowStateStore(this.repository);

  final SettingsRepository repository;

  @override
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

  @override
  Future<void> save(PersistedWindowState state) async {
    await repository.update(
      (settings) => settings.copyWith(
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

abstract interface class AppWindowManager {
  Future<void> ensureInitialized();
  Future<void> setSize(Size size);
  Future<void> setPosition(Offset position);
  Future<void> maximize();
  Future<bool> isMaximized();
  Future<Offset> getPosition();
  Future<Size> getSize();
  void addListener(wm.WindowListener listener);
  void removeListener(wm.WindowListener listener);
}

class PluginAppWindowManager implements AppWindowManager {
  PluginAppWindowManager([wm.WindowManager? manager])
    : _manager = manager ?? wm.windowManager;

  final wm.WindowManager _manager;

  @override
  void addListener(wm.WindowListener listener) =>
      _manager.addListener(listener);

  @override
  Future<void> ensureInitialized() => _manager.ensureInitialized();

  @override
  Future<Offset> getPosition() => _manager.getPosition();

  @override
  Future<Size> getSize() => _manager.getSize();

  @override
  Future<bool> isMaximized() => _manager.isMaximized();

  @override
  Future<void> maximize() => _manager.maximize();

  @override
  void removeListener(wm.WindowListener listener) =>
      _manager.removeListener(listener);

  @override
  Future<void> setPosition(Offset position) => _manager.setPosition(position);

  @override
  Future<void> setSize(Size size) => _manager.setSize(size);
}

abstract interface class WindowDisplayProvider {
  Future<List<Rect>> visibleFrames();
}

class ScreenRetrieverDisplayProvider implements WindowDisplayProvider {
  const ScreenRetrieverDisplayProvider();

  @override
  Future<List<Rect>> visibleFrames() async {
    final displays = await screenRetriever.getAllDisplays();
    return [
      for (final display in displays)
        Rect.fromLTWH(
          (display.visiblePosition ?? Offset.zero).dx,
          (display.visiblePosition ?? Offset.zero).dy,
          (display.visibleSize ?? display.size).width,
          (display.visibleSize ?? display.size).height,
        ),
    ];
  }
}

class AppWindowStateController with wm.WindowListener {
  AppWindowStateController({
    required this.store,
    AppWindowManager? manager,
    this.displayProvider = const ScreenRetrieverDisplayProvider(),
  }) : windowManager = manager ?? PluginAppWindowManager(),
       super();

  final WindowStatePersistence store;
  final AppWindowManager windowManager;
  final WindowDisplayProvider displayProvider;

  Future<void> restoreAndTrack() async {
    await windowManager.ensureInitialized();
    final state = await store.load();
    if (state != null) {
      final placement = await _validatedPlacement(state);
      await windowManager.setSize(Size(placement.width, placement.height));
      await windowManager.setPosition(Offset(placement.x, placement.y));
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
    unawaited(_saveBestEffort(preserveBoundsWhenMaximized: true));
  }

  @override
  void onWindowResized() {
    unawaited(_saveBestEffort(preserveBoundsWhenMaximized: true));
  }

  @override
  void onWindowMaximize() {
    unawaited(
      _saveBestEffort(
        maximizedOverride: true,
        preserveBoundsWhenMaximized: true,
      ),
    );
  }

  @override
  void onWindowUnmaximize() {
    unawaited(_saveBestEffort(maximizedOverride: false));
  }

  /// Window events fire during drags and resizes; a failed save must not
  /// surface as an unhandled error.
  Future<void> _saveBestEffort({
    bool? maximizedOverride,
    bool preserveBoundsWhenMaximized = false,
  }) async {
    try {
      await _saveCurrent(
        maximizedOverride: maximizedOverride,
        preserveBoundsWhenMaximized: preserveBoundsWhenMaximized,
      );
    } on Object {
      // The next move or resize saves again.
    }
  }

  Future<void> _saveCurrent({
    bool? maximizedOverride,
    bool preserveBoundsWhenMaximized = false,
  }) async {
    final isMaximized = maximizedOverride ?? await windowManager.isMaximized();
    if (isMaximized && preserveBoundsWhenMaximized) {
      // Keep the restored (normal) bounds so un-maximizing after a restart
      // returns to them. Without earlier bounds, use a centered default
      // rather than the maximized size.
      final previous = await store.load() ?? await _defaultNormalPlacement();
      if (previous != null) {
        await store.save(
          PersistedWindowState(
            x: previous.x,
            y: previous.y,
            width: previous.width,
            height: previous.height,
            isMaximized: true,
          ),
        );
        return;
      }
    }
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

  Future<PersistedWindowState?> _defaultNormalPlacement() async {
    final frames = await displayProvider.visibleFrames();
    if (frames.isEmpty) {
      return null;
    }
    final frame = frames.first;
    final width = (frame.width * 0.8).roundToDouble();
    final height = (frame.height * 0.8).roundToDouble();
    return PersistedWindowState(
      x: (frame.left + (frame.width - width) / 2).roundToDouble(),
      y: (frame.top + (frame.height - height) / 2).roundToDouble(),
      width: width,
      height: height,
      isMaximized: false,
    );
  }

  Future<PersistedWindowState> _validatedPlacement(
    PersistedWindowState state,
  ) async {
    final frames = await displayProvider.visibleFrames();
    if (frames.isEmpty) {
      return state;
    }
    final saved = Rect.fromLTWH(state.x, state.y, state.width, state.height);
    if (frames.any((frame) => _isMeaningfullyVisible(saved, frame))) {
      return state;
    }
    final frame = frames.first;
    final inset = _fallbackInset(frame);
    final maxWidth = (frame.width - inset * 2).clamp(1, frame.width);
    final maxHeight = (frame.height - inset * 2).clamp(1, frame.height);
    final minWidth = 640.0.clamp(1, maxWidth).toDouble();
    final minHeight = 480.0.clamp(1, maxHeight).toDouble();
    final width = state.width.clamp(minWidth, maxWidth).toDouble();
    final height = state.height.clamp(minHeight, maxHeight).toDouble();
    return PersistedWindowState(
      x: (frame.left + inset).clamp(frame.left, frame.right - width).toDouble(),
      y: (frame.top + inset).clamp(frame.top, frame.bottom - height).toDouble(),
      width: width,
      height: height,
      isMaximized: state.isMaximized,
    );
  }
}

bool _isMeaningfullyVisible(Rect saved, Rect frame) {
  final visible = saved.intersect(frame);
  if (visible.isEmpty) {
    return false;
  }
  return visible.width >= 160 && visible.height >= 120;
}

double _fallbackInset(Rect frame) =>
    frame.width >= 320 && frame.height >= 240 ? 80 : 0;
