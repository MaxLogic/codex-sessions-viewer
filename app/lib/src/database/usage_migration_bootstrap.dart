import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show sqlite3, OpenMode;

import '../config/app_settings.dart';
import '../usage/usage_summary.dart' show usageCostProjectionVersion;
import 'database_backup.dart';
import 'database_connection.dart';
import 'database_generation.dart';
import 'database_maintenance.dart';
import 'database_maintenance_cancelled.dart';
import 'database_migration_preflight.dart';
import 'database_migrator.dart';

/// Establishes an old-build-compatible recovery point before schema 16.
final class UsageMigrationBootstrap {
  UsageMigrationBootstrap({
    required this.migrator,
    required this.settings,
    required this.backupDirectory,
    DatabaseMigrationPreflight? preflight,
    SqliteBackupService? backupService,
  }) : preflight = preflight ?? DatabaseMigrationPreflight(),
       backupService = backupService ?? SqliteBackupService();

  final DatabaseMigrator migrator;
  final PricingSettings settings;
  final Directory backupDirectory;
  final DatabaseMigrationPreflight preflight;
  final SqliteBackupService backupService;

  static PricingSettings readPricingSettings(Map<String, dynamic> receipt) {
    final policy = receipt['pricing_policy'] as Map;
    if (policy['cost_projection_version'] != usageCostProjectionVersion) {
      throw StateError(
        'Frozen migration cost calculation version is unsupported.',
      );
    }
    return PricingSettings.fromMap(
      Map<String, dynamic>.from(policy),
      const PricingSettings(
        provider: 'openrouter',
        useExternalPricing: false,
        fallbackToOverrides: false,
        overrides: {},
        openRouter: OpenRouterSettings(modelsEndpoint: '', apiKey: ''),
      ),
    );
  }

  Future<DatabaseMaintenanceWorkerOutcome> run(
    DatabaseMaintenanceWorkerContext context,
  ) async {
    final db = context.database;
    final version = db
        .select('select max(version) v from schema_version where success = 1')
        .single['v'];
    if (version is! int ||
        version < 15 ||
        version > migrator.supportedSchemaVersion) {
      throw StateError(
        'Usage bootstrap requires a supported prepared schema, version 15 or later.',
      );
    }
    await _checkStop(context);
    var receipt = _readReceipt(db);
    if (version == 15) {
      // An old build can write between pre-16 attempts. Never reuse its backup,
      // even if an earlier intent and a fully verified file survived the crash.
      final random = Random.secure();
      final identity = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      receipt = {
        'identity': identity,
        'source_schema_version': 15,
        'observed_at_utc':
            receipt?['observed_at_utc'] ??
            DateTime.now().toUtc().toIso8601String(),
        'pricing_policy':
            receipt?['pricing_policy'] ??
            {
              'cost_projection_version': usageCostProjectionVersion,
              'provider': settings.provider,
              'use_external_pricing': settings.useExternalPricing,
              'fallback_to_overrides': settings.fallbackToOverrides,
              'overrides': {
                for (final entry in settings.overrides.entries)
                  entry.key: entry.value.toTomlMap(),
              },
            },
        'backup_path': p.join(
          backupDirectory.absolute.path,
          'usage-pre16-$identity.sqlite',
        ),
      };
      _writeReceipt(db, receipt);
      _publish(
        context,
        'preflight',
        'Checking source integrity and migration disk space.',
      );
      await context.runAtomic(() {
        final check = db.select('pragma quick_check');
        if (check.length != 1 ||
            check.single.values.single != 'ok' ||
            db
                .select('select * from pragma_foreign_key_check limit 1')
                .isNotEmpty) {
          throw StateError(
            'Source database failed migration integrity checks.',
          );
        }
      });
      await preflight.checkSpace(
        database: db,
        databaseFile: context.databaseFile,
        backupDirectory: backupDirectory,
        temporaryDirectory: Directory.systemTemp,
      );
      await _checkStop(context);
      final backup = await backupService.create(
        source: db,
        databaseFile: context.databaseFile,
        backupDirectory: backupDirectory,
        backupName: p.basename(receipt['backup_path'] as String),
        onProgress: (fraction) {
          if (context.stopRequested) throw const DatabaseMaintenanceCancelled();
          context.publish(
            state: DatabaseMaintenanceState.running,
            phase: fraction < 1 ? 'backup' : 'verify_backup',
            currentWork: fraction < 1
                ? 'Copying the pre-upgrade recovery database.'
                : 'Verifying the backup. Stop takes effect after verification.',
            unitLabel: 'percent',
            completedUnits: (fraction * 100).floor(),
            totalUnits: fraction < 1 ? 100 : null,
          );
        },
      );
      receipt['backup'] = {
        'path': backup.file.absolute.path,
        'length_bytes': backup.lengthBytes,
        'sha256': backup.sha256,
        'sqlite_version': backup.sqliteVersion,
        'restore':
            'Close the application and restore this verified backup to a new path. Replacing the current database loses database-only changes made after this backup; rescan original session files afterward.',
      };
      _writeReceipt(db, receipt);
      _publish(
        context,
        'verify_backup',
        'Verifying recovery identity and frozen pricing policy. Stop takes effect after verification.',
      );
      await verifyReceipt(receipt);
      await _checkStop(context);
      _publish(
        context,
        'bootstrap_schema',
        'Preparing persisted usage tables and indexes.',
      );
      final migrated = await migrator.migrateOpenDatabase(
        db,
        context.databaseFile,
        runAtomic: context.runAtomic,
      );
      if (!migrated.canStartNormalUi) {
        throw StateError(migrated.fatalError!.details);
      }
    } else {
      if (receipt == null) {
        throw StateError(
          'Schema 16 has no verified pre-upgrade recovery receipt.',
        );
      }
      _publish(
        context,
        'verify_backup',
        'Verifying the recovery backup. Stop takes effect after verification.',
      );
      await verifyReceipt(receipt);
      await _checkStop(context);
      // Also retries a committed schema whose post-migration optimize stopped.
      final migrated = await migrator.migrateOpenDatabase(
        db,
        context.databaseFile,
        runAtomic: context.runAtomic,
      );
      if (!migrated.canStartNormalUi) {
        throw StateError(migrated.fatalError!.details);
      }
    }
    await _checkStop(context);
    const jobType = 'usage_projection_migration';
    final latest = context.jobs.latestForType(jobType);
    final backup = receipt['backup'] as Map;
    int generationId;
    if (latest != null) {
      generationId =
          latest.databaseGenerationId ??
          (throw StateError('Startup migration job has no generation.'));
      final payload = jsonDecode(latest.payloadJson!) as Map;
      if (const [
        'identity',
        'source_schema_version',
        'observed_at_utc',
        'backup_path',
        'backup',
        'pricing_policy',
      ].any((key) => jsonEncode(payload[key]) != jsonEncode(receipt![key]))) {
        throw StateError('Migration job and recovery receipt do not match.');
      }
    } else {
      final building = db.select('''
        select id, source_fingerprint from database_generations
        where target_schema_version = 16 and state = 'building' order by id limit 2
      ''');
      if (building.length > 1 ||
          (building.isNotEmpty &&
              building.single['source_fingerprint'] != backup['sha256'])) {
        throw StateError(
          'Inactive generation does not match the recovery backup.',
        );
      }
      generationId = building.isEmpty
          ? DatabaseGenerationRepository(db)
                .createBuilding(
                  sourceSchemaVersion: 15,
                  targetSchemaVersion: 16,
                  sourceFingerprint: backup['sha256'] as String,
                )
                .id
          : building.single['id'] as int;
    }
    context.jobs.enqueue(
      jobType: jobType,
      phase: 'backup_complete',
      databaseGenerationId: generationId,
      statusMessage: 'Verified pre-upgrade backup is ready.',
      payloadJson: jsonEncode(receipt),
    );
    return DatabaseMaintenanceWorkerOutcome.succeeded;
  }

  /// Verification owns a separate read-only handle; it is not interruptible by
  /// the main database's runAtomic handle. Stop is checked immediately afterward.
  Future<VerifiedSqliteBackup> verifyReceipt(
    Map<String, dynamic> receipt,
  ) async {
    final evidence = receipt['backup'];
    if (receipt['source_schema_version'] != 15 ||
        evidence is! Map ||
        evidence['path'] is! String ||
        !p.isAbsolute(evidence['path'] as String) ||
        evidence['path'] != receipt['backup_path']) {
      throw StateError('Pre-upgrade backup receipt is incomplete.');
    }
    final backup = File(evidence['path'] as String);
    final verified = await backupService.inspect(backup);
    if (verified.sha256 != evidence['sha256'] ||
        verified.lengthBytes != evidence['length_bytes']) {
      throw StateError('Pre-upgrade backup no longer matches its receipt.');
    }
    final db = sqlite3.open(backup.path, mode: OpenMode.readOnly);
    try {
      final intent = _readReceipt(db);
      if (db
                  .select(
                    'select max(version) v from schema_version where success=1',
                  )
                  .single['v'] !=
              15 ||
          intent == null ||
          intent['identity'] != receipt['identity'] ||
          intent['backup_path'] != receipt['backup_path'] ||
          intent['observed_at_utc'] != receipt['observed_at_utc'] ||
          jsonEncode(intent['pricing_policy']) !=
              jsonEncode(receipt['pricing_policy'])) {
        throw StateError(
          'Backup identity or frozen pricing policy does not match.',
        );
      }
    } finally {
      db.close();
    }
    return verified;
  }
}

Map<String, dynamic>? _readReceipt(Database db) {
  final rows = db.select(
    "select value from app_metadata where key='usage_migration_bootstrap'",
  );
  if (rows.isEmpty) return null;
  final receipt = jsonDecode(rows.single['value'] as String);
  if (receipt is! Map<String, dynamic> ||
      receipt['identity'] is! String ||
      receipt['pricing_policy'] is! Map ||
      receipt['observed_at_utc'] is! String) {
    throw StateError('Startup migration receipt is damaged.');
  }
  return receipt;
}

void _writeReceipt(Database db, Map<String, dynamic> receipt) => db.execute(
  '''
  insert into app_metadata(key, value, updated_at_utc) values ('usage_migration_bootstrap', ?, ?)
  on conflict(key) do update set value=excluded.value, updated_at_utc=excluded.updated_at_utc
''',
  [jsonEncode(receipt), DateTime.now().toUtc().toIso8601String()],
);

Future<void> _checkStop(DatabaseMaintenanceWorkerContext context) async {
  await Future<void>.delayed(Duration.zero);
  if (context.stopRequested) throw const DatabaseMaintenanceCancelled();
}

void _publish(
  DatabaseMaintenanceWorkerContext context,
  String phase,
  String work,
) => context.publish(
  state: DatabaseMaintenanceState.running,
  phase: phase,
  currentWork: work,
  unitLabel: 'steps',
  completedUnits: 0,
  totalUnits: null,
);
