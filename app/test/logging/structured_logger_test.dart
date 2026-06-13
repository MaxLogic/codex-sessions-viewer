import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/logging/structured_logger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late Directory temp;
  late File logFile;
  late StructuredLogger logger;

  setUp(() async {
    db = sqlite3.openInMemory();
    db.execute(File('../sql/init/001_initial_schema.sql').readAsStringSync());
    temp = await Directory.systemTemp.createTemp('csv_logging_test_');
    logFile = File('${temp.path}${Platform.pathSeparator}viewer.log');
    logger = StructuredLogger(
      db: db,
      settings: LoggingSettings(
        level: 'info',
        logFile: logFile.path,
        maxLogFiles: 3,
        maxLogSizeMb: 1,
      ),
      nowUtc: () => DateTime.utc(2026, 6, 13, 10),
    );
  });

  tearDown(() async {
    db.close();
    await temp.delete(recursive: true);
  });

  test(
    'writes structured entries for required categories to sqlite and file',
    () async {
      for (final category in LogCategory.values) {
        await logger.write(
          LogEntryDraft(
            level: LogLevel.info,
            category: category,
            message: 'category ${category.wireName}',
            details: {'step': category.wireName},
          ),
        );
      }

      final rows = db.select(
        'select level, category, message, details from logs',
      );
      expect(rows, hasLength(LogCategory.values.length));
      expect(
        rows.map((row) => row['category']),
        containsAll(LogCategory.values.map((category) => category.wireName)),
      );
      expect(await logFile.exists(), isTrue);
      final lines = await logFile.readAsLines();
      expect(lines, hasLength(LogCategory.values.length));
      expect(jsonDecode(lines.first), containsPair('level', 'info'));
    },
  );

  test('honors configured level and supports Logs screen queries', () async {
    logger = StructuredLogger(
      db: db,
      settings: LoggingSettings(
        level: 'warning',
        logFile: logFile.path,
        maxLogFiles: 3,
        maxLogSizeMb: 1,
      ),
      nowUtc: () => DateTime.utc(2026, 6, 13, 10),
    );

    await logger.write(
      const LogEntryDraft(
        level: LogLevel.info,
        category: LogCategory.scanner,
        message: 'ignored',
      ),
    );
    await logger.write(
      const LogEntryDraft(
        level: LogLevel.warning,
        category: LogCategory.parser,
        message: 'kept warning',
      ),
    );
    await logger.write(
      const LogEntryDraft(
        level: LogLevel.error,
        category: LogCategory.pricing,
        message: 'kept error',
      ),
    );

    expect(logger.query(const LogQuery()).map((entry) => entry.message), [
      'kept error',
      'kept warning',
    ]);
    expect(
      logger.query(const LogQuery(errorsOnly: true)).single.message,
      'kept error',
    );
    expect(
      logger
          .query(const LogQuery(categories: {LogCategory.parser}))
          .single
          .message,
      'kept warning',
    );
  });

  test('rotates before an entry would exceed the configured size', () async {
    await logFile.writeAsString(''.padRight(1024 * 1024 - 8, 'x'));

    await logger.write(
      const LogEntryDraft(
        level: LogLevel.error,
        category: LogCategory.database,
        message: 'entry forces rotation',
      ),
    );

    expect(await File('${logFile.path}.1').readAsString(), startsWith('x'));
    expect(await logFile.readAsString(), contains('entry forces rotation'));
  });

  test('rotates log files using configured file count', () async {
    await logFile.writeAsString(''.padRight(1024 * 1024 + 1, 'x'));
    await File('${logFile.path}.1').writeAsString('older');

    await logger.write(
      const LogEntryDraft(
        level: LogLevel.error,
        category: LogCategory.database,
        message: 'after rotation',
      ),
    );

    expect(await File('${logFile.path}.1').readAsString(), startsWith('x'));
    expect(await File('${logFile.path}.2').readAsString(), 'older');
    expect(await logFile.readAsString(), contains('after rotation'));
  });

  test('max log files of one keeps only the active log file', () async {
    logger = StructuredLogger(
      db: db,
      settings: LoggingSettings(
        level: 'info',
        logFile: logFile.path,
        maxLogFiles: 1,
        maxLogSizeMb: 1,
      ),
      nowUtc: () => DateTime.utc(2026, 6, 13, 10),
    );
    await logFile.writeAsString(''.padRight(1024 * 1024 + 1, 'x'));

    await logger.write(
      const LogEntryDraft(
        level: LogLevel.error,
        category: LogCategory.database,
        message: 'single active file',
      ),
    );

    expect(await File('${logFile.path}.1').exists(), isFalse);
    expect(await logFile.readAsString(), contains('single active file'));
  });

  test('omits raw session content from details and unsafe messages', () async {
    await logger.write(
      const LogEntryDraft(
        level: LogLevel.error,
        category: LogCategory.parser,
        message: '{"private":"session"}',
        details: {
          'record_type': 'response_item',
          'parse_error': {
            'raw_session': '{"private":"session"}',
            'nested': [
              {'tool_output': 'private output'},
            ],
          },
        },
      ),
    );

    final row = db.select('select message, details from logs').single;
    expect(row['message'], '[omitted]');
    final details = row['details'] as String;
    expect(details, contains('response_item'));
    expect(details, contains('[omitted]'));
    expect(details, isNot(contains('private')));
    expect(await logFile.readAsString(), isNot(contains('private')));
  });
}
