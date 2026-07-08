import 'dart:io';

import '../database/database_connection.dart';
import '../search/message_search.dart';
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
  messageSearchBackfillStatus('Message search backfill status'),
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

class DatabaseSettingsDiagnostics implements SettingsDiagnostics {
  const DatabaseSettingsDiagnostics(this.databaseFile);

  final File databaseFile;

  @override
  Future<SettingsDiagnosticResult> run(
    SettingsDiagnosticAction action,
    AppSettings settings,
  ) async {
    if (action != SettingsDiagnosticAction.messageSearchBackfillStatus) {
      return const DefaultSettingsDiagnostics().run(action, settings);
    }
    final db = openFileBackedDatabase(databaseFile);
    try {
      final status = MessageSearchIndex(db).backfillStatus();
      return SettingsDiagnosticResult.success(
        'Message search backfill: ${status.indexed} indexed, '
        '${status.remaining} remaining.',
      );
    } finally {
      db.close();
    }
  }
}
