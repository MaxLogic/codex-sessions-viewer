import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show sqlite3;

import '../platform/application_working_directory.dart';
import '../platform/app_locations.dart';
import 'database_connection.dart';
import 'database_maintenance_cancelled.dart';
import 'writer_version_agreement.dart';

File defaultDatabaseFile() {
  return AppLocations.current().databaseFile;
}

Directory defaultSqlRoot() {
  final releaseSqlRoot = AppLocations.current().sqlDirectory;
  if (releaseSqlRoot.existsSync()) {
    return releaseSqlRoot;
  }
  final developmentRoot = findDevelopmentRepositoryRoot();
  if (developmentRoot != null) {
    return Directory(p.join(developmentRoot.path, 'sql'));
  }
  return releaseSqlRoot;
}

/// The newest schema this viewer applies and the collector writes
/// (`SUPPORTED_SCHEMA_VERSION` in `collector/src/store/schema.rs`).
const latestSchemaVersion = 28;

class DatabaseMigrator {
  DatabaseMigrator({
    required this.sqlRoot,
    this.supportedSchemaVersion = latestSchemaVersion,
    this.fts5ProbeSql = 'create virtual table temp.fts_probe using fts5(value)',
  });

  final Directory sqlRoot;
  final int supportedSchemaVersion;
  final String fts5ProbeSql;

  Future<DatabaseStartupResult> openAndMigrate(
    File databaseFile, {
    bool deferUsageMigration = false,
  }) async {
    Database? db;
    try {
      await databaseFile.parent.create(recursive: true);
      // Startup owns schema and scan-recovery housekeeping before normal
      // application writers are constructed, including migration resumption.
      db = openFileBackedDatabase(databaseFile, maintenanceWriter: true);
      return await migrateOpenDatabase(
        db,
        databaseFile,
        deferUsageMigration: deferUsageMigration,
      );
    } on DatabaseMaintenanceCancelled {
      rethrow;
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

  /// Uses the startup worker's connection without closing or replacing it.
  /// The caller excludes normal application access for the entire operation.
  Future<DatabaseStartupResult> migrateOpenDatabase(
    Database db,
    File databaseFile, {
    bool deferUsageMigration = false,
    Future<void> Function(void Function())? runAtomic,
  }) async {
    try {
      if (sqlite3.version.versionNumber < 3046000) {
        throw StateError(
          'SQLite 3.46 or newer is required for bounded database optimization.',
        );
      }
      final ftsResult = _verifyFts5(db, databaseFile.path);
      if (ftsResult != null) {
        return DatabaseStartupResult.blocked(ftsResult);
      }

      final ownerError = _validateOwner(db, databaseFile.path);
      if (ownerError != null) {
        return DatabaseStartupResult.blocked(ownerError);
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

      final deferPendingUsage =
          deferUsageMigration && _lastAppliedVersion(db) < 16;
      for (final migration in migrations) {
        if (migration.version > supportedSchemaVersion ||
            (deferPendingUsage && migration.version >= 16)) {
          continue;
        }
        if (_isApplied(db, migration.version)) {
          continue;
        }
        final migrationError = await _applyMigration(
          db,
          migration,
          databaseFile.path,
          runAtomic: runAtomic,
        );
        if (migrationError != null) {
          return DatabaseStartupResult.blocked(migrationError);
        }
        await _optimizeAfterMigration(
          db,
          migration.version,
          runAtomic: runAtomic,
        );
      }

      final schemaError = _validateSchema(db, databaseFile.path);
      if (schemaError != null) {
        return DatabaseStartupResult.blocked(schemaError);
      }

      if (_lastAppliedVersion(db) >= 16 &&
          (db
                      .select(
                        'select last_optimized_schema_version v from database_state where id = 1',
                      )
                      .single['v']
                  as int) <
              _lastAppliedVersion(db)) {
        await _optimizeAfterMigration(
          db,
          _lastAppliedVersion(db),
          runAtomic: runAtomic,
        );
      }
      db.execute(
        '''
        insert into app_metadata (key, value, updated_at_utc)
        values ('sqlite_version', ?, ?)
        on conflict(key) do update set value = excluded.value, updated_at_utc = excluded.updated_at_utc
      ''',
        [sqlite3.version.libVersion, DateTime.now().toUtc().toIso8601String()],
      );

      _recoverInterruptedScanRuns(db);
      recordViewerWriterVersions(db);

      return DatabaseStartupResult.ready(
        lastAppliedSchemaVersion: _lastAppliedVersion(db),
      );
    } on DatabaseMaintenanceCancelled {
      rethrow;
    } on Object catch (error) {
      return DatabaseStartupResult.blocked(
        DatabaseFatalError(
          summary: 'SQLite database startup failed.',
          databasePath: databaseFile.path,
          lastAppliedSchemaVersion: _safeLastAppliedVersion(db),
          details: error.toString(),
        ),
      );
    }
  }

  Future<void> _optimizeAfterMigration(
    Database db,
    int schemaVersion, {
    Future<void> Function(void Function())? runAtomic,
  }) async {
    final now = DateTime.now().toUtc();
    final stamp = now.toIso8601String();
    final hasMaintenance = schemaVersion >= 16;
    try {
      db.execute('begin immediate');
      // Use the schema-changing connection so SQLite retains its planner hints.
      if (runAtomic == null) {
        db.execute('pragma optimize');
      } else {
        await runAtomic(() => db.execute('pragma optimize'));
      }
      if (hasMaintenance) {
        db.execute(
          '''
          update database_state set last_optimized_schema_version = ?, updated_at_utc = ? where id = 1
        ''',
          [schemaVersion, stamp],
        );
        db.execute(
          '''
          insert into maintenance_schedules (job_type, enabled, interval_seconds,
            last_attempt_at_utc, last_success_at_utc, next_due_at_utc, updated_at_utc)
          values ('database_optimize', 1, 604800, ?, ?, ?, ?)
          on conflict(job_type) do update set
            last_attempt_at_utc = excluded.last_attempt_at_utc,
            last_success_at_utc = excluded.last_success_at_utc,
            next_due_at_utc = strftime('%Y-%m-%dT%H:%M:%fZ', ?, '+' || interval_seconds || ' seconds'),
            retry_count = 0, last_error = null, updated_at_utc = excluded.updated_at_utc
        ''',
          [
            stamp,
            stamp,
            now.add(const Duration(days: 7)).toIso8601String(),
            stamp,
            stamp,
          ],
        );
      }
      db.execute('commit');
    } on DatabaseMaintenanceCancelled {
      try {
        if (!db.autocommit) db.execute('rollback');
      } on Object {
        // Preserve cancellation if SQLite already rolled back.
      }
      rethrow;
    } on Object {
      if (!db.autocommit) db.execute('rollback');
      // A committed schema remains successful even when statistics maintenance
      // fails. A lagging watermark retries this step on the next startup.
      if (hasMaintenance) {
        db.execute(
          '''
          insert into maintenance_schedules (job_type, enabled, interval_seconds,
            last_attempt_at_utc, next_due_at_utc, retry_count, last_error, updated_at_utc)
          values ('database_optimize', 1, 604800, ?, ?, 1, 'Post-migration optimization failed.', ?)
          on conflict(job_type) do update set
            last_attempt_at_utc = excluded.last_attempt_at_utc,
            next_due_at_utc = excluded.next_due_at_utc,
            retry_count = maintenance_schedules.retry_count + 1,
            last_error = excluded.last_error, updated_at_utc = excluded.updated_at_utc
        ''',
          [
            stamp,
            now.add(const Duration(minutes: 15)).toIso8601String(),
            stamp,
          ],
        );
      }
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

  /// A standalone collector creates and migrates its own database; the
  /// viewer must not migrate it out from under that collector.
  DatabaseFatalError? _validateOwner(Database db, String databasePath) {
    final hasMetadata = db
        .select(
          "select 1 from sqlite_schema where type = 'table' and name = 'app_metadata'",
        )
        .isNotEmpty;
    if (!hasMetadata) {
      return null;
    }
    final owner = db.select(
      "select value from app_metadata where key = 'database_owner'",
    );
    if (owner.isEmpty || owner.single['value'] == 'viewer') {
      return null;
    }
    return DatabaseFatalError(
      summary: 'This database belongs to a standalone collector.',
      databasePath: databasePath,
      lastAppliedSchemaVersion: _safeLastAppliedVersion(db),
      details:
          'A standalone collector created this database and owns its '
          'migrations. Open the viewer with its own database instead.',
    );
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

  Future<DatabaseFatalError?> _applyMigration(
    Database db,
    SqlMigration migration,
    String databasePath, {
    Future<void> Function(void Function())? runAtomic,
  }) async {
    try {
      db.execute('begin immediate');
      db.execute('pragma defer_foreign_keys = on');
      if (runAtomic == null) {
        db.execute(migration.sql);
      } else {
        // Only native schema work is interruptible. The worker disarms its
        // interrupt timer before commit, rollback, or failure-record SQL.
        await runAtomic(() => db.execute(migration.sql));
      }
      db.execute(
        '''
        insert into schema_version
          (version, filename, checksum, applied_at_utc, success, error_message)
        values (?, ?, ?, ?, 1, null)
        on conflict(version) do update set
          filename = excluded.filename,
          checksum = excluded.checksum,
          applied_at_utc = excluded.applied_at_utc,
          success = 1,
          error_message = null
        where schema_version.success = 0
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
    } on DatabaseMaintenanceCancelled {
      try {
        db.execute('rollback');
      } on Object {
        // Preserve cancellation if SQLite already rolled back.
      }
      rethrow;
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
      if (lastAppliedVersion >= 9) 'message_search',
      if (lastAppliedVersion >= 12) 'tool_output_search',
      if (lastAppliedVersion >= 14) 'session_cache_repair_manifest',
      if (lastAppliedVersion >= 15) ...[
        'usage_events',
        'billable_usage_events',
      ],
      if (lastAppliedVersion >= 16) ...[
        'database_generations',
        'database_state',
        'maintenance_jobs',
        'maintenance_schedules',
        'usage_path_contexts',
        'usage_path_context_aliases',
        'usage_context_project_candidates',
        'price_catalog_snapshots',
        'model_price_periods',
        'provider_price_rules',
        'local_price_override_periods',
        'usage_session_daily',
        'usage_cost_dirty_partitions',
      ],
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
    if (lastAppliedVersion >= 16) {
      DatabaseFatalError generationError(String details) => DatabaseFatalError(
        summary: 'SQLite usage generation validation failed.',
        databasePath: databasePath,
        lastAppliedSchemaVersion: lastAppliedVersion,
        details: details,
      );
      final active = db.select('''
        select g.target_schema_version, g.state from database_state s
        join database_generations g on g.id = s.active_usage_generation_id
        where s.id = 1
      ''');
      if (active.length != 1 ||
          !{'legacy', 'active', 'complete'}.contains(active.single['state'])) {
        return generationError(
          'The active usage generation is missing or not readable.',
        );
      }
      final contextBased =
          (active.single['target_schema_version'] as int) >= 16;
      final hasShadow = db
          .select(
            "select 1 from sqlite_master where type = 'table' and name = 'usage_events_next'",
          )
          .isNotEmpty;
      if (hasShadow == contextBased) {
        return generationError(
          contextBased
              ? 'An active context generation still has an unswapped usage_events_next table.'
              : 'Required table is missing: usage_events_next.',
        );
      }
      final columns = db
          .select("pragma table_info('usage_events')")
          .map((row) => row['name'])
          .toSet();
      final viewColumns = db
          .select("pragma table_info('billable_usage_events')")
          .map((row) => row['name'])
          .toSet();
      final requiredEventColumns = contextBased
          ? {'path_context_id'}
          : {
              'project_id',
              'working_directory_display',
              'working_directory_platform',
              'working_directory_unc',
            };
      if (!columns.containsAll(requiredEventColumns) ||
          (contextBased && columns.contains('project_id')) ||
          !viewColumns.contains('project_id') ||
          (contextBased && !viewColumns.contains('path_context_id'))) {
        return generationError(
          'Usage table or billable view does not match the active generation.',
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
];
