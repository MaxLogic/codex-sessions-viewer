import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../config/app_settings.dart';

enum LogLevel {
  debug,
  info,
  warning,
  error;

  String get wireName => name;
}

enum LogCategory {
  scanner,
  parser,
  database,
  migration,
  search,
  commands,
  pricing,
  export,
  accessibility,
  voiceOver,
  ui;

  String get wireName => switch (this) {
    LogCategory.voiceOver => 'voice_over',
    _ => name,
  };
}

typedef UtcNow = DateTime Function();

class StructuredLogger {
  StructuredLogger({required this.db, required this.settings, UtcNow? nowUtc})
    : _nowUtc = nowUtc ?? (() => DateTime.now().toUtc());

  final Database db;
  final LoggingSettings settings;
  final UtcNow _nowUtc;

  Future<void> write(LogEntryDraft draft) async {
    if (!_isEnabled(draft.level)) {
      return;
    }
    final time = _nowUtc().toUtc();
    final details = _encodeDetails(draft.details);
    db.execute(
      '''
      insert into logs (time_utc, level, category, message, details)
      values (?, ?, ?, ?, ?)
      ''',
      [
        time.toIso8601String(),
        draft.level.wireName,
        draft.category.wireName,
        _sanitizeMessage(draft.message),
        details,
      ],
    );
    final safeMessage = _sanitizeMessage(draft.message);
    await _writeFileEntry(
      LogEntry(
        id: null,
        timeUtc: time,
        level: draft.level,
        category: draft.category,
        message: safeMessage,
        details: details,
      ),
    );
  }

  List<LogEntry> query(LogQuery query) {
    final where = <String>[];
    final args = <Object?>[];
    if (query.errorsOnly) {
      where.add("level = 'error'");
    }
    if (query.categories.isNotEmpty) {
      where.add(
        'category in (${List.filled(query.categories.length, '?').join(', ')})',
      );
      args.addAll(query.categories.map((category) => category.wireName));
    }
    final rows = db.select(
      '''
      select id, time_utc, level, category, message, details
      from logs
      ${where.isEmpty ? '' : 'where ${where.join(' and ')}'}
      order by time_utc desc, id desc
      limit ?
      ''',
      [...args, query.limit],
    );
    return rows.map(LogEntry.fromRow).toList(growable: false);
  }

  Future<void> _writeFileEntry(LogEntry entry) async {
    final file = File(settings.logFile);
    await file.parent.create(recursive: true);
    final jsonLine = jsonEncode({
      'time_utc': entry.timeUtc.toIso8601String(),
      'level': entry.level.wireName,
      'category': entry.category.wireName,
      'message': entry.message,
      if (entry.details != null) 'details': entry.details,
    });
    await _rotateIfNeeded(file, utf8.encode('$jsonLine\n').length);
    await file.writeAsString('$jsonLine\n', mode: FileMode.append);
  }

  Future<void> _rotateIfNeeded(File file, int incomingBytes) async {
    if (!await file.exists()) {
      return;
    }
    final maxBytes = settings.maxLogSizeMb * 1024 * 1024;
    if (await file.length() + incomingBytes <= maxBytes) {
      return;
    }
    if (settings.maxLogFiles <= 1) {
      await file.delete();
      return;
    }
    for (var index = settings.maxLogFiles - 1; index >= 1; index--) {
      final current = File('${file.path}.$index');
      if (!await current.exists()) {
        continue;
      }
      if (index == settings.maxLogFiles - 1) {
        await current.delete();
      } else {
        await current.rename('${file.path}.${index + 1}');
      }
    }
    await file.rename('${file.path}.1');
  }

  bool _isEnabled(LogLevel level) {
    final configured = _levelFromString(settings.level);
    return level.index >= configured.index;
  }
}

class LogEntryDraft {
  const LogEntryDraft({
    required this.level,
    required this.category,
    required this.message,
    this.details = const {},
  });

  final LogLevel level;
  final LogCategory category;
  final String message;
  final Map<String, Object?> details;
}

class LogQuery {
  const LogQuery({
    this.errorsOnly = false,
    this.categories = const {},
    this.limit = 500,
  });

  final bool errorsOnly;
  final Set<LogCategory> categories;
  final int limit;
}

class LogEntry {
  const LogEntry({
    required this.id,
    required this.timeUtc,
    required this.level,
    required this.category,
    required this.message,
    required this.details,
  });

  factory LogEntry.fromRow(Row row) {
    return LogEntry(
      id: row['id'] as int?,
      timeUtc: DateTime.parse(row['time_utc'] as String).toUtc(),
      level: _levelFromString(row['level'] as String),
      category: _categoryFromString(row['category'] as String),
      message: row['message'] as String,
      details: row['details'] as String?,
    );
  }

  final int? id;
  final DateTime timeUtc;
  final LogLevel level;
  final LogCategory category;
  final String message;
  final String? details;
}

String? _encodeDetails(Map<String, Object?> details) {
  if (details.isEmpty) {
    return null;
  }
  return jsonEncode({
    for (final entry in details.entries) entry.key: _sanitizeDetail(entry),
  });
}

Object? _sanitizeDetail(MapEntry<String, Object?> entry) {
  final key = entry.key.toLowerCase();
  if (_rawDetailKeys.contains(key)) {
    return '[omitted]';
  }
  final value = entry.value;
  if (value is Map) {
    return {
      for (final nested in value.entries)
        nested.key.toString(): _sanitizeDetail(
          MapEntry(nested.key.toString(), nested.value),
        ),
    };
  }
  if (value is Iterable) {
    return [
      for (final item in value)
        item is Map
            ? {
                for (final nested in item.entries)
                  nested.key.toString(): _sanitizeDetail(
                    MapEntry(nested.key.toString(), nested.value),
                  ),
              }
            : item,
    ];
  }
  if (value is String && value.length > 4000) {
    return '${value.substring(0, 4000)}... [truncated]';
  }
  return value;
}

String _sanitizeMessage(String message) {
  final trimmed = message.trimLeft();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    return '[omitted]';
  }
  if (message.length > 500) {
    return '${message.substring(0, 500)}... [truncated]';
  }
  return message;
}

const _rawDetailKeys = {
  'raw_session',
  'raw_session_copy',
  'session_content',
  'prompt',
  'message',
  'tool_output',
};

LogLevel _levelFromString(String value) {
  return switch (value) {
    'debug' => LogLevel.debug,
    'info' => LogLevel.info,
    'warning' || 'warn' => LogLevel.warning,
    'error' => LogLevel.error,
    _ => LogLevel.info,
  };
}

LogCategory _categoryFromString(String value) {
  return switch (value) {
    'scanner' => LogCategory.scanner,
    'parser' => LogCategory.parser,
    'database' => LogCategory.database,
    'migration' => LogCategory.migration,
    'search' => LogCategory.search,
    'commands' => LogCategory.commands,
    'pricing' => LogCategory.pricing,
    'export' => LogCategory.export,
    'accessibility' => LogCategory.accessibility,
    'voice_over' => LogCategory.voiceOver,
    _ => LogCategory.ui,
  };
}
