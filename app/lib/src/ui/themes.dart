import 'package:flutter/material.dart';

enum CodexThemeMode { system, light, dark, highContrastLight, highContrastDark }

class CodexFocusStyle {
  const CodexFocusStyle({required this.color, required this.width});

  final Color color;
  final double width;
}

class CodexAppTheme {
  const CodexAppTheme._();

  static ThemeMode themeMode(CodexThemeMode mode) {
    return switch (mode) {
      CodexThemeMode.system => ThemeMode.system,
      CodexThemeMode.light ||
      CodexThemeMode.highContrastLight => ThemeMode.light,
      CodexThemeMode.dark || CodexThemeMode.highContrastDark => ThemeMode.dark,
    };
  }

  static ThemeData themeData(CodexThemeMode mode) {
    return switch (mode) {
      CodexThemeMode.system || CodexThemeMode.light => _normalLight(),
      CodexThemeMode.dark => _normalDark(),
      CodexThemeMode.highContrastLight => _highContrastLight(),
      CodexThemeMode.highContrastDark => _highContrastDark(),
    };
  }

  static CodexFocusStyle focusStyle(CodexThemeMode mode) {
    return switch (mode) {
      CodexThemeMode.highContrastLight => const CodexFocusStyle(
        color: Colors.black,
        width: 4,
      ),
      CodexThemeMode.highContrastDark => const CodexFocusStyle(
        color: Colors.white,
        width: 4,
      ),
      _ => const CodexFocusStyle(color: Color(0xFF005FB8), width: 2),
    };
  }

  static ThemeData _normalLight() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF0F6CBD),
      brightness: Brightness.light,
    );
    return _baseTheme(scheme, focusStyle(CodexThemeMode.light));
  }

  static ThemeData _normalDark() {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF60CDFF),
      brightness: Brightness.dark,
    );
    return _baseTheme(scheme, focusStyle(CodexThemeMode.dark));
  }

  static ThemeData _highContrastLight() {
    const scheme = ColorScheme.highContrastLight(
      surface: Colors.white,
      onSurface: Colors.black,
      primary: Colors.black,
      onPrimary: Colors.white,
      outline: Colors.black,
    );
    return _baseTheme(scheme, focusStyle(CodexThemeMode.highContrastLight));
  }

  static ThemeData _highContrastDark() {
    const scheme = ColorScheme.highContrastDark(
      surface: Colors.black,
      onSurface: Colors.white,
      primary: Colors.white,
      onPrimary: Colors.black,
      outline: Colors.white,
    );
    return _baseTheme(scheme, focusStyle(CodexThemeMode.highContrastDark));
  }

  static ThemeData _baseTheme(ColorScheme scheme, CodexFocusStyle focus) {
    return ThemeData(
      colorScheme: scheme,
      brightness: scheme.brightness,
      useMaterial3: true,
      focusColor: focus.color,
      scaffoldBackgroundColor: scheme.surface,
      visualDensity: VisualDensity.standard,
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: scheme.surface,
        selectedIconTheme: IconThemeData(color: scheme.onPrimary),
        selectedLabelTextStyle: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.onSurface),
        indicatorColor: scheme.primary,
      ),
    );
  }
}
