import 'dart:convert';
import 'dart:io';

import '../config/app_settings.dart';
import '../pricing/pricing_repository.dart';
import '../usage/usage_cost_projection.dart';
import '../usage/usage_summary.dart' show usageCostProjectionVersion;
import 'database_connection.dart';
import 'database_generation.dart';
import 'database_maintenance.dart';
import 'database_maintenance_cancelled.dart';
import 'database_migrator.dart';
import 'maintenance_job.dart';
import 'usage_migration_bootstrap.dart';
import 'usage_path_context_migration.dart';
import 'usage_projection_migration.dart';

Future<DatabaseMaintenanceOperation?> startUsageMigration(
  File file, {
  Directory? sqlRoot,
  PricingSettings? pricingSettings,
  DatabaseMaintenanceCoordinator? coordinator,
}) async {
  MaintenanceJobRecord? pending;
  var cleanupCommitted = false;
  final db = openFileBackedDatabase(file, maintenanceWriter: true);
  try {
    final version =
        db
                .select(
                  'select max(version) v from schema_version where success=1',
                )
                .single['v']
            as int;
    if (version >= 16) {
      pending = MaintenanceJobRepository(
        db,
      ).latestForType('usage_projection_migration');
      final active = DatabaseGenerationRepository(db).activeGeneration();
      if (active.targetSchemaVersion == 16 &&
          active.state == DatabaseGenerationState.complete) {
        _verifyCleanup(db, active.id);
        if (pending?.state == MaintenanceJobState.succeeded) return null;
        cleanupCommitted =
            pending?.databaseGenerationId == active.id &&
            pending?.phase == 'cleanup_complete';
      }
    }
  } finally {
    db.close();
  }
  final bootstrap = UsageMigrationBootstrap(
    migrator: DatabaseMigrator(sqlRoot: sqlRoot ?? defaultSqlRoot()),
    settings: pricingSettings ?? AppSettings.defaults().pricing,
    backupDirectory: Directory('${file.parent.path}/backups'),
  );
  final migration = StartupUsageMigration(bootstrap);
  return (coordinator ?? DatabaseMaintenanceCoordinator(file)).start(
    jobType: 'usage_projection_migration',
    initialPhase: pending?.phase ?? 'bootstrap',
    databaseGenerationId: pending?.databaseGenerationId,
    payloadJson: pending?.payloadJson,
    bootstrapWorker: cleanupCommitted ? null : bootstrap.run,
    worker: migration.run,
  );
}

/// The startup gate retains ownership until every migration phase is verified.
final class StartupUsageMigration {
  const StartupUsageMigration(this.bootstrap);

  final UsageMigrationBootstrap bootstrap;

  Future<DatabaseMaintenanceWorkerOutcome> run(
    DatabaseMaintenanceWorkerContext context,
  ) async {
    final db = context.database;
    final jobs = context.jobs;
    final lease = context.lease;
    MaintenanceJobRecord job() => jobs.read(lease.jobId)!;
    Map<String, dynamic> payload() =>
        jsonDecode(job().payloadJson!) as Map<String, dynamic>;
    final generationId = job().databaseGenerationId!;
    final generations = DatabaseGenerationRepository(db);
    final settings = UsageMigrationBootstrap.readPricingSettings(payload());
    final observed = DateTime.parse(payload()['observed_at_utc'] as String);

    void checkpoint(
      String phase,
      String message, {
      Map<String, dynamic>? data,
      void Function(Database)? apply,
    }) {
      final previous = job();
      jobs.commitBatch(
        lease: lease,
        phase: phase,
        completedUnits: previous.completedUnits,
        totalUnits: null,
        lastProcessedRowId: previous.lastProcessedRowId,
        statusMessage: message,
        payloadJson: data == null ? null : jsonEncode(data),
        apply: apply ?? (_) {},
      );
    }

    Future<void> boundary({bool checkSpace = false}) async {
      await Future<void>.delayed(Duration.zero);
      if (context.stopRequested) throw const DatabaseMaintenanceCancelled();
      jobs.renew(lease);
      db.select('pragma wal_checkpoint(passive)');
      if (checkSpace) {
        await bootstrap.preflight.checkSpace(
          database: db,
          databaseFile: context.databaseFile,
          backupDirectory: File(
            (payload()['backup'] as Map)['path'] as String,
          ).parent,
          temporaryDirectory: Directory.systemTemp,
          backupAlreadyPresent: true,
        );
      }
    }

    try {
      final active = generations.activeGeneration();
      if (active.targetSchemaVersion < 16) {
        // Rollback restores the ready shadow and the legacy pointer atomically.
        // Its earlier reopen checkpoint can survive a crash before job updates.
        if (job().phase == 'reopen_validate' &&
            db.select(
              "select id from database_generations where id=? and state='ready'",
              [generationId],
            ).isNotEmpty) {
          checkpoint(
            'cutover',
            'Retrying activation after verification rollback.',
          );
        }
        await boundary(checkSpace: true);
        if (const {
          'backup_complete',
          'copy_events',
          'resolve_contexts',
          'validate_contexts',
          'contexts_validated',
        }.contains(job().phase)) {
          if (!await prepareUsagePathContexts(context)) {
            return DatabaseMaintenanceWorkerOutcome.interrupted;
          }
          checkpoint('project_usage', 'Building persisted daily usage.');
        }
        if (job().phase == 'project_usage') {
          final total =
              db.select('select count(*) n from sessions').single['n'] as int;
          _publish(
            context,
            'project_usage',
            'Building persisted daily usage.',
            'sessions',
            completed: payload()['projected_session_count'] as int? ?? 0,
            total: total,
          );
          await boundary(checkSpace: true);
          final migration = UsageProjectionMigration(db);
          while (migration.rebuildNextBatch(jobs: jobs, lease: lease) != 0) {
            _publish(
              context,
              'project_usage',
              job().statusMessage!,
              'sessions',
              completed: payload()['projected_session_count'] as int,
              total: total,
            );
            await boundary();
          }
          checkpoint('initialize_prices', 'Preserving historical pricing.');
        }
        if (job().phase == 'initialize_prices') {
          _publish(
            context,
            'initialize_prices',
            'Preserving historical pricing.',
            'models',
            completed: payload()['migrated_price_count'] as int? ?? 0,
            total:
                payload()['cached_price_count'] as int? ??
                db
                        .select(
                          "select count(*) n from model_pricing_cache where source='openrouter'",
                        )
                        .single['n']
                    as int,
          );
          await boundary(checkSpace: true);
          final pricing = PricingRepository(db);
          while (pricing.migrateCachedHistoryNextBatch(
                jobs: jobs,
                lease: lease,
                settings: settings,
                migrationTimeUtc: observed,
              ) !=
              0) {
            final progress = payload();
            _publish(
              context,
              'initialize_prices',
              job().statusMessage!,
              'models',
              completed: progress['migrated_price_count'] as int,
              total: progress['cached_price_count'] as int,
            );
            await boundary();
          }
          checkpoint('reprice_costs', 'Calculating stored historical costs.');
        }
        if (job().phase == 'reprice_costs') {
          _publish(
            context,
            'reprice_costs',
            'Calculating stored historical costs.',
            'partitions',
          );
          await boundary(checkSpace: true);
          final costs = UsageCostProjectionRepository(db);
          final total =
              db
                      .select(
                        'select count(*) n from usage_cost_dirty_partitions',
                      )
                      .single['n']
                  as int;
          var completed = 0;
          while (costs.repriceNextBatch(
                jobs: jobs,
                lease: lease,
                settings: settings,
              ) !=
              0) {
            _publish(
              context,
              'reprice_costs',
              'Historical cost partition committed.',
              'partitions',
              completed: ++completed,
              total: total,
            );
            await boundary();
          }
          checkpoint('final_statistics', 'Updating final index statistics.');
        }
        if (job().phase == 'final_statistics') {
          await boundary(checkSpace: true);
          for (
            var index = payload()['statistics_table_cursor'] as int? ?? 0;
            index < _statisticsTables.length;
            index++
          ) {
            final table = _statisticsTables[index];
            _publish(
              context,
              'final_statistics',
              'Analyzing $table (${index + 1} of ${_statisticsTables.length}).',
              'tables',
              completed: index,
            );
            await context.runAtomic(() => db.execute('analyze $table'));
            checkpoint(
              'final_statistics',
              'Statistics committed for $table.',
              data: payload()..['statistics_table_cursor'] = index + 1,
            );
            await boundary();
          }
          await context.runAtomic(() => db.execute('pragma optimize'));
          checkpoint(
            'validate_usage',
            'Validating event, token, pricing, and path evidence.',
          );
        }
        if (job().phase == 'validate_usage') {
          _publish(
            context,
            'validate_usage',
            'Validating event, token, pricing, and path evidence.',
            'checks',
          );
          await boundary();
          final report = await context.runAtomic(() {
            final raw =
                db.select(
                      'select validation_report_json from database_generations where id=?',
                      [generationId],
                    ).single['validation_report_json']
                    as String?;
            final report = raw == null
                ? <String, dynamic>{}
                : jsonDecode(raw) as Map<String, dynamic>;
            report['context_parity'] = UsagePathContextMigration(
              db,
            ).validateShadowParity();
            report['daily_parity'] = UsageProjectionMigration(
              db,
            ).validateShadowParity();
            _verifyCurrentCosts(db);
            report['cost_projection_version'] = usageCostProjectionVersion;
            return report;
          });
          checkpoint(
            'cutover',
            'Validated generation is ready for activation.',
            apply: (_) => generations.markReady(
              generationId,
              validationReportJson: jsonEncode(report),
            ),
          );
        }
        if (job().phase != 'cutover') {
          throw StateError('Unknown startup migration phase: ${job().phase}.');
        }
        _publish(
          context,
          'cutover',
          'Activating the verified usage generation.',
          'steps',
        );
        await boundary(checkSpace: true);
        await generations.activateInterruptibly(
          generationId,
          runAtomic: context.runAtomic,
        );
        checkpoint(
          'reopen_validate',
          'Reopening the active generation for verification.',
        );
      } else if (active.id != generationId ||
          !const {
            'cutover',
            'reopen_validate',
            'cleanup_complete',
          }.contains(job().phase)) {
        throw StateError(
          'Active generation and migration checkpoint are inconsistent.',
        );
      }

      if (job().phase == 'cleanup_complete') {
        _verifyCleanup(db, generationId);
        return DatabaseMaintenanceWorkerOutcome.succeeded;
      }
      _publish(
        context,
        'final_statistics',
        'Updating statistics for the activated usage table.',
        'tables',
      );
      await boundary();
      await context.runAtomic(() {
        // ALTER TABLE does not migrate sqlite_stat1's table/index identities.
        // Replace the former active table's stats and discard the shadow name.
        db.execute("delete from sqlite_stat1 where tbl='usage_events_next'");
        db.execute('analyze usage_events');
        db.execute('pragma optimize');
      });
      _publish(
        context,
        'reopen_validate',
        'Verifying the reopened generation. Stop takes effect after verification.',
        'checks',
      );
      await boundary();
      // This is an independently owned verification connection, not the worker's
      // borrowed handle. Keep normal writes gated until this connection closes.
      final reopened = openFileBackedDatabase(context.databaseFile);
      try {
        final current = DatabaseGenerationRepository(
          reopened,
        ).activeGeneration();
        if (current.id != generationId ||
            current.targetSchemaVersion != 16 ||
            current.state != DatabaseGenerationState.active ||
            reopened.select('pragma query_only').single.values.single != 1 ||
            reopened
                .select("pragma table_info('usage_events')")
                .every((row) => row['name'] != 'path_context_id') ||
            reopened
                .select(
                  "select name from sqlite_schema where name='usage_events_next'",
                )
                .isNotEmpty) {
          throw StateError(
            'Reopened usage generation does not match the cutover.',
          );
        }
        final check = reopened.select('pragma quick_check');
        if (check.length != 1 ||
            check.single.values.single != 'ok' ||
            reopened
                .select('select * from pragma_foreign_key_check limit 1')
                .isNotEmpty) {
          throw StateError(
            'Reopened usage generation failed integrity verification.',
          );
        }
        _verifyCurrentCosts(reopened);
        final report =
            jsonDecode(
                  reopened.select(
                        'select validation_report_json from database_generations where id=?',
                        [generationId],
                      ).single['validation_report_json']
                      as String,
                )
                as Map;
        final totals = report['context_parity'] as Map;
        if (reopened
                .select('select count(*) n from usage_events')
                .single['n'] !=
            totals['event_count']) {
          throw StateError(
            'Reopened event count differs from the verified generation.',
          );
        }
      } finally {
        reopened.close();
      }
      await boundary();
      _publish(
        context,
        'verify_backup',
        'Rechecking the recovery backup before cleanup. Stop takes effect after verification.',
        'checks',
      );
      await bootstrap.verifyReceipt(payload());
      await boundary();
      _publish(
        context,
        'cleanup',
        'Removing retired event storage and sealing the verified generation.',
        'steps',
      );
      checkpoint(
        'cleanup_complete',
        'Verified migration cleanup is committed.',
        apply: (db) {
          db.execute('drop table usage_events_legacy');
          db.execute(
            "update database_generations set state='complete', completed_at_utc=? where id=? or state='cleanup_pending'",
            [DateTime.now().toUtc().toIso8601String(), generationId],
          );
          generations.markNormalWritesResumed();
          db.execute(
            "delete from app_metadata where key='usage_migration_bootstrap'",
          );
        },
      );
      _verifyCleanup(db, generationId);
      return DatabaseMaintenanceWorkerOutcome.succeeded;
    } on DatabaseMaintenanceCancelled {
      // A requested stop retains the committed phase for an ordinary resume.
      rethrow;
    } on Object catch (error) {
      try {
        final current = generations.activeGeneration();
        if (current.id == generationId &&
            current.state == DatabaseGenerationState.active) {
          // Verification can outlive a lease. Only its current owner may
          // restore generation storage after an independent validation error.
          jobs.renew(lease);
          final legacy = db.select(
            "select id from database_generations where state='cleanup_pending' and target_schema_version<16 limit 2",
          );
          if (legacy.length != 1 ||
              !generations.rollbackTo(legacy.single['id'] as int)) {
            throw StateError('The legacy generation could not be restored.');
          }
        }
      } on StaleMaintenanceLeaseException {
        // A replacement worker owns recovery; preserve this worker's error.
      } on Object catch (rollbackError) {
        throw StateError(
          'Migration failed: $error. Recovery rollback also failed: $rollbackError',
        );
      }
      rethrow;
    }
  }
}

const _statisticsTables = [
  'sessions',
  'usage_events_next',
  'usage_path_contexts',
  'usage_path_context_aliases',
  'usage_context_project_candidates',
  'usage_session_daily',
  'price_catalog_snapshots',
  'model_price_periods',
  'provider_price_rules',
  'local_price_override_periods',
];

void _verifyCurrentCosts(Database db) {
  if (db
          .select('select 1 from usage_cost_dirty_partitions limit 1')
          .isNotEmpty ||
      db.select(
        'select 1 from usage_session_daily where cost_projection_version<>? limit 1',
        [usageCostProjectionVersion],
      ).isNotEmpty) {
    throw StateError(
      'Usage costs are still dirty or use an unsupported calculation version.',
    );
  }
}

void _verifyCleanup(Database db, int generationId) {
  final active = DatabaseGenerationRepository(db).activeGeneration();
  if (active.id != generationId ||
      active.state != DatabaseGenerationState.complete ||
      db
              .select(
                'select normal_writes_resumed_at_utc from database_state where id=1',
              )
              .single
              .values
              .single ==
          null ||
      db
          .select(
            "select name from sqlite_schema where name in ('usage_events_legacy','usage_events_next')",
          )
          .isNotEmpty ||
      db
          .select(
            "select value from app_metadata where key='usage_migration_bootstrap'",
          )
          .isNotEmpty) {
    throw StateError('Completed migration cleanup is inconsistent.');
  }
}

void _publish(
  DatabaseMaintenanceWorkerContext context,
  String phase,
  String work,
  String unit, {
  int completed = 0,
  int? total,
}) => context.publish(
  state: DatabaseMaintenanceState.running,
  phase: phase,
  currentWork: work,
  unitLabel: unit,
  completedUnits: completed,
  totalUnits: total,
);
