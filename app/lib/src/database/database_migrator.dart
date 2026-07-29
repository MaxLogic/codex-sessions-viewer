import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../platform/application_working_directory.dart';
import 'database_connection.dart';

File defaultDatabaseFile() {
  final appData = Platform.environment['APPDATA'];
  final basePath = appData == null || appData.isEmpty
      ? applicationExecutableDirectory().path
      : p.join(appData, 'CodexSessionViewer');
  return File(p.join(basePath, 'codex_sessions_viewer.sqlite'));
}

Directory defaultSqlRoot() {
  final executableDir = applicationExecutableDirectory();
  final releaseSqlRoot = Directory(p.join(executableDir.path, 'sql'));
  if (releaseSqlRoot.existsSync()) {
    return releaseSqlRoot;
  }
  final developmentRoot = findDevelopmentRepositoryRoot();
  if (developmentRoot != null) {
    return Directory(p.join(developmentRoot.path, 'sql'));
  }
  return releaseSqlRoot;
}

class DatabaseMigrator {
  DatabaseMigrator({
    required this.sqlRoot,
    this.supportedSchemaVersion = 14,
    this.fts5ProbeSql = 'create virtual table temp.fts_probe using fts5(value)',
  });

  final Directory sqlRoot;
  final int supportedSchemaVersion;
  final String fts5ProbeSql;

  Future<DatabaseStartupResult> openAndMigrate(File databaseFile) async {
    Database? db;
    try {
      await databaseFile.parent.create(recursive: true);
      db = openFileBackedDatabase(databaseFile);
      final ftsResult = _verifyFts5(db, databaseFile.path);
      if (ftsResult != null) {
        return DatabaseStartupResult.blocked(ftsResult);
      }

      _ensureSchemaVersionTable(db);
      final migrations = await _loadMigrations();
      final checksumError = _validateAppliedChecksums(
        db,
        migrations,
        databaseFile.path,
      );
      if (checksumError != null) {
        return DatabaseStartupResult.blocked(checksumError);
      }

      final versionError = _validateSupportedVersion(db, databaseFile.path);
      if (versionError != null) {
        return DatabaseStartupResult.blocked(versionError);
      }

      for (final migration in migrations) {
        if (_isApplied(db, migration.version)) {
          continue;
        }
        final migrationError = _applyMigration(
          db,
          migration,
          databaseFile.path,
        );
        if (migrationError != null) {
          return DatabaseStartupResult.blocked(migrationError);
        }
      }

      final schemaError = _validateSchema(db, databaseFile.path);
      if (schemaError != null) {
        return DatabaseStartupResult.blocked(schemaError);
      }

      _recoverInterruptedScanRuns(db);

      return DatabaseStartupResult.ready(
        lastAppliedSchemaVersion: _lastAppliedVersion(db),
      );
    } on Object catch (error) {
      return DatabaseStartupResult.blocked(
        DatabaseFatalError(
          summary: 'SQLite database startup failed.',
          databasePath: databaseFile.path,
          lastAppliedSchemaVersion: db == null
              ? 0
              : _safeLastAppliedVersion(db),
          details: error.toString(),
        ),
      );
    } finally {
      db?.close();
    }
  }

  void _recoverInterruptedScanRuns(Database db) {
    final hasStatusColumn = db
        .select("pragma table_info('scan_runs')")
        .any((row) => row['name'] == 'status');
    if (!hasStatusColumn) {
      return;
    }
    db.execute(
      '''
      update scan_runs
      set status = 'failed',
          finished_at_utc = coalesce(finished_at_utc, ?)
      where status = 'running'
      ''',
      [DateTime.now().toUtc().toIso8601String()],
    );
  }

  DatabaseFatalError? _verifyFts5(Database db, String databasePath) {
    try {
      db.execute(fts5ProbeSql);
      db.execute('drop table if exists temp.fts_probe');
      return null;
    } on Object catch (error) {
      return DatabaseFatalError(
        summary: 'SQLite FTS5 is unavailable.',
        databasePath: databasePath,
        lastAppliedSchemaVersion: _safeLastAppliedVersion(db),
        details: error.toString(),
      );
    }
  }

  void _ensureSchemaVersionTable(Database db) {
    db.execute('''
      create table if not exists schema_version (
        version integer primary key,
        filename text not null,
        checksum text not null,
        applied_at_utc text not null,
        success integer not null check (success in (0, 1)),
        error_message text
      )
    ''');
  }

  Future<List<SqlMigration>> _loadMigrations() async {
    final files = <File>[];
    for (final folder in ['init', 'migration']) {
      final dir = Directory(p.join(sqlRoot.path, folder));
      if (!await dir.exists()) {
        continue;
      }
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.sql')) {
          files.add(entity);
        }
      }
    }
    files.sort(
      (left, right) => p.basename(left.path).compareTo(p.basename(right.path)),
    );
    final migrations = <SqlMigration>[];
    for (final file in files) {
      final filename = p.basename(file.path);
      final version = int.tryParse(filename.split('_').first);
      if (version == null) {
        throw DatabaseMigrationException(
          'Migration filename must start with a numeric version: $filename',
        );
      }
      final sql = await file.readAsString();
      migrations.add(
        SqlMigration(
          version: version,
          filename: filename,
          sql: sql,
          checksum: sha256.convert(utf8.encode(sql)).toString(),
        ),
      );
    }
    return migrations;
  }

  DatabaseFatalError? _validateAppliedChecksums(
    Database db,
    List<SqlMigration> migrations,
    String databasePath,
  ) {
    final byVersion = {
      for (final migration in migrations) migration.version: migration,
    };
    final rows = db.select(
      'select version, filename, checksum from schema_version where success = 1',
    );
    for (final row in rows) {
      final version = row['version'] as int;
      final migration = byVersion[version];
      if (migration == null) {
        return DatabaseFatalError(
          summary: 'Applied migration file is missing.',
          databasePath: databasePath,
          lastAppliedSchemaVersion: _lastAppliedVersion(db),
          failingMigrationFile: row['filename'] as String?,
          details: 'No local SQL file exists for schema version $version.',
        );
      }
      if (row['checksum'] != migration.checksum) {
        return DatabaseFatalError(
          summary: 'Applied migration checksum changed.',
          databasePath: databasePath,
          lastAppliedSchemaVersion: _lastAppliedVersion(db),
          failingMigrationFile: migration.filename,
          details:
              'The local SQL file no longer matches the applied migration.',
        );
      }
    }
    return null;
  }

  DatabaseFatalError? _validateSupportedVersion(
    Database db,
    String databasePath,
  ) {
    final lastVersion = _lastAppliedVersion(db);
    if (lastVersion > supportedSchemaVersion) {
      return DatabaseFatalError(
        summary: 'Database schema version is newer than this app supports.',
        databasePath: databasePath,
        lastAppliedSchemaVersion: lastVersion,
        details: 'Supported schema version: $supportedSchemaVersion.',
      );
    }
    return null;
  }

  bool _isApplied(Database db, int version) {
    final rows = db.select(
      'select 1 from schema_version where version = ? and success = 1',
      [version],
    );
    return rows.isNotEmpty;
  }

  DatabaseFatalError? _applyMigration(
    Database db,
    SqlMigration migration,
    String databasePath,
  ) {
    try {
      db.execute('begin immediate');
      db.execute(migration.sql);
      db.execute(
        '''
        insert into schema_version
          (version, filename, checksum, applied_at_utc, success, error_message)
        values (?, ?, ?, ?, 1, null)
        ''',
        [
          migration.version,
          migration.filename,
          migration.checksum,
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
      db.execute('commit');
      return null;
    } on Object catch (error) {
      try {
        db.execute('rollback');
      } on Object {
        // If SQLite already rolled back, preserve the original failure.
      }
      db.execute(
        '''
        insert or replace into schema_version
          (version, filename, checksum, applied_at_utc, success, error_message)
        values (?, ?, ?, ?, 0, ?)
        ''',
        [
          migration.version,
          migration.filename,
          migration.checksum,
          DateTime.now().toUtc().toIso8601String(),
          error.toString(),
        ],
      );
      return DatabaseFatalError(
        summary: 'SQLite migration failed.',
        databasePath: databasePath,
        lastAppliedSchemaVersion: _lastAppliedVersion(db),
        failingMigrationFile: migration.filename,
        details: error.toString(),
      );
    }
  }

  DatabaseFatalError? _validateSchema(Database db, String databasePath) {
    final lastAppliedVersion = _lastAppliedVersion(db);
    final requiredTables = [
      ..._requiredTables,
      if (lastAppliedVersion >= 12) 'tool_output_search',
      if (lastAppliedVersion >= 14) 'session_cache_repair_manifest',
    ];
    for (final table in requiredTables) {
      final rows = db.select(
        "select 1 from sqlite_master where name = ? and type in ('table', 'view')",
        [table],
      );
      if (rows.isEmpty) {
        return DatabaseFatalError(
          summary: 'SQLite schema validation failed.',
          databasePath: databasePath,
          lastAppliedSchemaVersion: _lastAppliedVersion(db),
          details: 'Required table is missing: $table.',
        );
      }
    }
    return null;
  }

  int _lastAppliedVersion(Database db) {
    final rows = db.select(
      'select coalesce(max(version), 0) as version from schema_version where success = 1',
    );
    return rows.first['version'] as int;
  }

  int _safeLastAppliedVersion(Database db) {
    try {
      return _lastAppliedVersion(db);
    } on Object {
      return 0;
    }
  }
}

class DatabaseStartupResult {
  const DatabaseStartupResult._({
    required this.canStartNormalUi,
    required this.lastAppliedSchemaVersion,
    this.fatalError,
  });

  factory DatabaseStartupResult.ready({
    required int lastAppliedSchemaVersion,
  }) => DatabaseStartupResult._(
    canStartNormalUi: true,
    lastAppliedSchemaVersion: lastAppliedSchemaVersion,
  );

  factory DatabaseStartupResult.blocked(DatabaseFatalError error) =>
      DatabaseStartupResult._(
        canStartNormalUi: false,
        lastAppliedSchemaVersion: error.lastAppliedSchemaVersion,
        fatalError: error,
      );

  final bool canStartNormalUi;
  final int lastAppliedSchemaVersion;
  final DatabaseFatalError? fatalError;
}

class DatabaseFatalError {
  const DatabaseFatalError({
    required this.summary,
    required this.databasePath,
    required this.lastAppliedSchemaVersion,
    required this.details,
    this.failingMigrationFile,
  });

  final String summary;
  final String databasePath;
  final int lastAppliedSchemaVersion;
  final String? failingMigrationFile;
  final String details;
}

class SqlMigration {
  const SqlMigration({
    required this.version,
    required this.filename,
    required this.sql,
    required this.checksum,
  });

  final int version;
  final String filename;
  final String sql;
  final String checksum;
}

class DatabaseMigrationException implements Exception {
  const DatabaseMigrationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class DatabaseStartupException implements Exception {
  const DatabaseStartupException({
    required this.databasePath,
    required this.message,
  });

  final String databasePath;
  final String message;

  @override
  String toString() => message;
}

const _requiredTables = [
  'schema_version',
  'app_metadata',
  'sessions',
  'messages',
  'tool_calls',
  'projects',
  'project_path_masks',
  'tags',
  'session_tags',
  'session_path_keys',
  'usage_daily',
  'scan_runs',
  'scan_errors',
  'model_pricing_cache',
  'logs',
  'session_search',
  'message_search',
];
