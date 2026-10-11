import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The app's primary modifier, shared by bindings, copy routing and labels.
/// Theme.platform is injectable and defaults to Flutter's host platform.
class PlatformShortcuts {
  const PlatformShortcuts(this.platform);

  factory PlatformShortcuts.of(BuildContext context) =>
      PlatformShortcuts(Theme.of(context).platform);

  final TargetPlatform platform;
  bool get usesMeta => platform == TargetPlatform.macOS;
  String get modifierLabel => usesMeta ? 'Cmd' : 'Ctrl';

  SingleActivator activator(LogicalKeyboardKey key) =>
      SingleActivator(key, meta: usesMeta, control: !usesMeta);

  bool primaryModifierPressed(HardwareKeyboard keyboard) => usesMeta
      ? keyboard.isMetaPressed && !keyboard.isControlPressed
      : keyboard.isControlPressed && !keyboard.isMetaPressed;

  String label(String controlLabel) =>
      controlLabel.replaceAll('Ctrl', modifierLabel);
}
