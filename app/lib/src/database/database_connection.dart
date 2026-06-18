import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

export 'package:sqlite3/sqlite3.dart' show Database, Row;

const defaultSqliteBusyTimeoutMs = 5000;

Database openFileBackedDatabase(
  File file, {
  int busyTimeoutMs = defaultSqliteBusyTimeoutMs,
}) {
  if (busyTimeoutMs <= 0) {
    throw ArgumentError.value(
      busyTimeoutMs,
      'busyTimeoutMs',
      'must be greater than zero',
    );
  }
  final db = sqlite3.open(file.path);
  try {
    configureFileBackedDatabase(db, busyTimeoutMs: busyTimeoutMs);
    return db;
  } on Object {
    db.close();
    rethrow;
  }
}

void configureFileBackedDatabase(
  Database db, {
  int busyTimeoutMs = defaultSqliteBusyTimeoutMs,
}) {
  if (busyTimeoutMs <= 0) {
    throw ArgumentError.value(
      busyTimeoutMs,
      'busyTimeoutMs',
      'must be greater than zero',
    );
  }
  db.execute('pragma busy_timeout = $busyTimeoutMs');
  final busyTimeout = db.select('pragma busy_timeout').single.values.single;
  if (busyTimeout is! int || busyTimeout <= 0) {
    throw StateError('SQLite busy_timeout was not configured.');
  }

  final journalMode = db
      .select('pragma journal_mode = wal')
      .single
      .values
      .single
      .toString()
      .toLowerCase();
  if (journalMode != 'wal') {
    throw StateError(
      'SQLite did not enable WAL journal mode; active mode is $journalMode.',
    );
  }
}
