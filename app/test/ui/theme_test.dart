import 'package:codex_sessions_viewer/src/ui/themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('theme modes expose expected brightness and contrast', () {
    expect(CodexAppTheme.themeMode(CodexThemeMode.system), ThemeMode.system);
    expect(CodexAppTheme.themeMode(CodexThemeMode.light), ThemeMode.light);
    expect(CodexAppTheme.themeMode(CodexThemeMode.dark), ThemeMode.dark);
    expect(
      CodexAppTheme.themeMode(CodexThemeMode.highContrastLight),
      ThemeMode.light,
    );
    expect(
      CodexAppTheme.themeMode(CodexThemeMode.highContrastDark),
      ThemeMode.dark,
    );

    final light = CodexAppTheme.themeData(CodexThemeMode.light);
    final dark = CodexAppTheme.themeData(CodexThemeMode.dark);
    final highLight = CodexAppTheme.themeData(CodexThemeMode.highContrastLight);
    final highDark = CodexAppTheme.themeData(CodexThemeMode.highContrastDark);

    expect(light.brightness, Brightness.light);
    expect(dark.brightness, Brightness.dark);
    expect(highLight.brightness, Brightness.light);
    expect(highDark.brightness, Brightness.dark);
    expect(highLight.colorScheme.surface, Colors.white);
    expect(highLight.colorScheme.onSurface, Colors.black);
    expect(highDark.colorScheme.surface, Colors.black);
    expect(highDark.colorScheme.onSurface, Colors.white);
  });

  test('focus indicators are visible in normal and high contrast themes', () {
    final lightFocus = CodexAppTheme.focusStyle(CodexThemeMode.light);
    final highLightFocus = CodexAppTheme.focusStyle(
      CodexThemeMode.highContrastLight,
    );
    final highDarkFocus = CodexAppTheme.focusStyle(
      CodexThemeMode.highContrastDark,
    );

    expect(lightFocus.width, greaterThanOrEqualTo(2));
    expect(lightFocus.color, isNot(equals(Colors.transparent)));
    expect(highLightFocus.width, greaterThanOrEqualTo(4));
    expect(highLightFocus.color, Colors.black);
    expect(highDarkFocus.width, greaterThanOrEqualTo(4));
    expect(highDarkFocus.color, Colors.white);
  });
}
