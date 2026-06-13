import 'app_settings.dart';

enum SettingsDiagnosticAction {
  testWindowsCodexPath('Test Windows Codex path'),
  testWslCodexPath('Test WSL Codex path'),
  testWslCommand('Test WSL command'),
  testAlacritty('Test Alacritty'),
  testWindowsTerminal('Test Windows Terminal'),
  testCodexCommand('Test Codex command'),
  testVoiceOverSounds('Test voice-over sounds'),
  testOpenRouterPricingFetch('Test OpenRouter pricing fetch'),
  openDatabaseFolder('Open database folder'),
  openLogsFolder('Open logs folder');

  const SettingsDiagnosticAction(this.label);

  final String label;
}

class SettingsDiagnosticResult {
  const SettingsDiagnosticResult({
    required this.success,
    required this.message,
  });

  factory SettingsDiagnosticResult.success(String message) =>
      SettingsDiagnosticResult(success: true, message: message);

  factory SettingsDiagnosticResult.failure(String message) =>
      SettingsDiagnosticResult(success: false, message: message);

  final bool success;
  final String message;

  String get display => '${success ? 'Success' : 'Failed'}. $message';
}

abstract interface class SettingsDiagnostics {
  Future<SettingsDiagnosticResult> run(
    SettingsDiagnosticAction action,
    AppSettings settings,
  );
}

class DefaultSettingsDiagnostics implements SettingsDiagnostics {
  const DefaultSettingsDiagnostics();

  @override
  Future<SettingsDiagnosticResult> run(
    SettingsDiagnosticAction action,
    AppSettings settings,
  ) async {
    return SettingsDiagnosticResult.success('${action.label} is available.');
  }
}
