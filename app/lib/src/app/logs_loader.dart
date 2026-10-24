import 'package:codex_sessions_viewer/src/platform/app_environment.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_settings.dart';
import '../database/database_connection.dart';
import '../database/database_maintenance.dart';
import '../logging/structured_logger.dart';
import '../ui/screens/logs_screen.dart';

/// How long the Logs screen keeps entries when "Clear old logs" is used.
const logRetentionAfterClear = Duration(days: 7);

/// Loads recent log entries from the database for the Logs screen and wires
/// its copy, open, and clear actions.
class LogsLoader extends StatefulWidget {
  const LogsLoader({
    super.key,
    required this.databaseFile,
    required this.settings,
    required this.writerCoordinator,
    this.nowUtc,
  });

  final File databaseFile;
  final LoggingSettings settings;
  final DatabaseMaintenanceCoordinator writerCoordinator;
  final DateTime Function()? nowUtc;

  @override
  State<LogsLoader> createState() => _LogsLoaderState();
}

class _LogsLoaderState extends State<LogsLoader> {
  var _entries = const <LogEntry>[];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final path = widget.databaseFile.path;
    final settings = widget.settings;
    List<LogEntry> entries;
    try {
      entries = await AppEnvironment.runIsolate(_logQueryJob(path, settings));
    } on Object {
      entries = const [];
    }
    if (mounted) {
      setState(() => _entries = entries);
    }
  }

  File get _logFile => File(widget.settings.logFile).absolute;

  Future<void> _copy(LogEntry entry) async {
    final details = entry.details;
    await Clipboard.setData(
      ClipboardData(
        text: [
          '${entry.timeUtc.toIso8601String()} ${entry.level.wireName} '
              '${entry.category.wireName} ${entry.message}',
          if (details != null && details.isNotEmpty) details,
        ].join('\n'),
      ),
    );
    _notify('Log entry copied.');
  }

  Future<void> _openLogFile() async {
    final file = _logFile;
    if (!file.existsSync()) {
      _notify('The log file has not been created yet: ${file.path}');
      return;
    }
    await AppEnvironment.start('explorer.exe', ['/select,', file.path]);
  }

  Future<void> _openLogsFolder() async {
    final folder = _logFile.parent;
    if (!folder.existsSync()) {
      _notify('The logs folder does not exist yet: ${folder.path}');
      return;
    }
    await AppEnvironment.start('explorer.exe', [folder.path]);
  }

  Future<void> _clearOldLogs() async {
    final now = (widget.nowUtc ?? () => DateTime.now().toUtc())();
    final cutoff = now.subtract(logRetentionAfterClear).toIso8601String();
    final path = widget.databaseFile.path;
    final removed = await widget.writerCoordinator.runWriter(() async {
      final db = openFileBackedDatabase(File(path));
      try {
        db.execute('delete from logs where time_utc < ?', [cutoff]);
        return db.updatedRows;
      } finally {
        db.close();
      }
    });
    await _load();
    _notify(
      removed == 0
          ? 'No log entries older than 7 days.'
          : 'Removed $removed log entries older than 7 days.',
    );
  }

  void _notify(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return LogsScreen(
      entries: _entries,
      onCopySelected: _copy,
      onOpenLogFile: _openLogFile,
      onOpenLogsFolder: _openLogsFolder,
      onClearOldLogs: _clearOldLogs,
    );
  }
}

/// Built outside the async caller so the isolate closure captures only the
/// path and settings, not the caller's pending future.
List<LogEntry> Function() _logQueryJob(String path, LoggingSettings settings) {
  return () {
    final db = openFileBackedDatabase(File(path));
    try {
      return StructuredLogger(
        db: db,
        settings: settings,
      ).query(const LogQuery(limit: 1000));
    } finally {
      db.close();
    }
  };
}
