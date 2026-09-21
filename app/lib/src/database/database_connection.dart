import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

export 'package:sqlite3/sqlite3.dart' show Database, Row;

const defaultSqliteBusyTimeoutMs = 5000;

/// Normal connections stay read-only while bootstrap recovery is pending or
/// until the latest usage migration succeeds.
///
/// [maintenanceWriter] is reserved for schema startup and the maintenance owner.
/// This is an open-time guard, not revocation of existing connections.
/// Long migrations must start behind the startup/single-instance gate, before
/// normal connections exist. Runtime migration would require joining existing
/// writers and excluding new ones before enqueueing the migration.
Database openFileBackedDatabase(
  File file, {
  int busyTimeoutMs = defaultSqliteBusyTimeoutMs,
  bool maintenanceWriter = false,
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
    // Bootstrap begins before schema 16 creates maintenance_jobs. Presence is
    // sufficient: an incomplete or damaged receipt must not reopen writers.
    if (!maintenanceWriter &&
        db.select('''
          select 1 from sqlite_schema
          where type = 'table' and name = 'app_metadata'
        ''').isNotEmpty &&
        db.select('''
          select 1 from app_metadata where key = 'usage_migration_bootstrap'
        ''').isNotEmpty) {
      db.execute('pragma query_only = on');
    }
    if (!maintenanceWriter &&
        db.select('''
          select 1 from sqlite_schema
          where type = 'table' and name = 'maintenance_jobs'
        ''').isNotEmpty) {
      final latest = db.select('''
        select state from maintenance_jobs
        where job_type = 'usage_projection_migration'
        order by id desc limit 1
      ''');
      if (latest.isNotEmpty && latest.single['state'] != 'succeeded') {
        db.execute('pragma query_only = on');
      }
    }
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

  db.execute('pragma foreign_keys = on');
  final foreignKeys = db.select('pragma foreign_keys').single.values.single;
  if (foreignKeys != 1) {
    throw StateError('SQLite foreign key enforcement was not configured.');
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
