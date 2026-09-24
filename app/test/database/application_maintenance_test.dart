import 'dart:async';
import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/application_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_generation.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:codex_sessions_viewer/src/pricing/pricing_repository.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final disabled in [false, true]) {
    for (final downloadFails in [false, true]) {
      test(
        'superseded downloads do not back off the new provider settings (disabled=$disabled, failure=$downloadFails)',
        () async {
          final temp = await Directory.systemTemp.createTemp(
            'csv_superseded_catalog_',
          );
          final file = File('${temp.path}/viewer.sqlite');
          expect(
            (await DatabaseMigrator(
              sqlRoot: Directory('../sql'),
            ).openAndMigrate(file)).canStartNormalUi,
            isTrue,
          );
          final client = _HeldCatalog();
          final scheduler = ApplicationMaintenance(
            databaseFile: file,
            coordinator: DatabaseMaintenanceCoordinator(file),
            client: client,
          );
          final db = openFileBackedDatabase(file);
          Future<void>? running;
          try {
            await scheduler.configure(
              AppSettings.fromTomlMap({
                'maintenance': {'database_optimize_enabled': false},
              }),
            );
            running = scheduler.runDueJobs();
            await client.started.future;
            await scheduler.configure(
              AppSettings.fromTomlMap({
                'pricing': {
                  'use_external_pricing': !disabled,
                  'openrouter': {'api_key': 'replacement-test-key'},
                },
                'maintenance': {'database_optimize_enabled': false},
              }),
            );
            if (downloadFails) {
              client.response.completeError(
                const PricingFetchException('superseded test failure'),
              );
            } else {
              client.response.complete(const OpenRouterModelsResponse([]));
            }
            await running;
            final status = db
                .select(
                  "select retry_count, last_error from maintenance_schedules where job_type='openrouter_price_refresh'",
                )
                .single;
            expect(status['retry_count'], 0);
            expect(status['last_error'], isNull);
            expect(db.select('select * from price_catalog_snapshots'), isEmpty);
            await scheduler.runDueJobs();
            expect(
              client.calls,
              disabled ? 1 : 2,
              reason: 'only the enabled new request must remain due',
            );
            if (!disabled) {
              expect(client.requests.last.apiKey, 'replacement-test-key');
            }
          } finally {
            if (!client.response.isCompleted) {
              client.response.complete(const OpenRouterModelsResponse([]));
            }
            await running;
            await scheduler.stop();
            scheduler.dispose();
            db.close();
            await temp.delete(recursive: true);
          }
        },
      );
    }
  }

  test(
    'stopping cancels queued configuration without late database writes',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_stop_configure_');
      final file = File('${temp.path}/viewer.sqlite');
      expect(
        (await DatabaseMigrator(
          sqlRoot: Directory('../sql'),
        ).openAndMigrate(file)).canStartNormalUi,
        isTrue,
      );
      final coordinator = DatabaseMaintenanceCoordinator(file);
      final scheduler = ApplicationMaintenance(
        databaseFile: file,
        coordinator: coordinator,
      );
      final db = openFileBackedDatabase(file);
      final release = Completer<void>();
      final entered = Completer<void>();
      final held = coordinator.runWriter(() async {
        entered.complete();
        await release.future;
      });
      Future<void>? configuration;
      try {
        await entered.future;
        final previous = db
            .select('select pricing_policy_json from database_state')
            .single['pricing_policy_json'];
        configuration = scheduler.configure(AppSettings.defaults());
        await scheduler.stop();
        scheduler.dispose();
        release.complete();
        await Future.wait([held, configuration]);
        expect(
          db
              .select('select pricing_policy_json from database_state')
              .single['pricing_policy_json'],
          previous,
        );
        await scheduler.configure(AppSettings.defaults());
        expect(
          db
              .select('select pricing_policy_json from database_state')
              .single['pricing_policy_json'],
          previous,
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await held;
        await configuration;
        await scheduler.stop();
        db.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'disabling provider pricing while queued prevents a stale download',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_disable_schedule_',
      );
      final file = File('${temp.path}/viewer.sqlite');
      final startup = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(file);
      expect(startup.canStartNormalUi, isTrue);
      final client = _HeldCatalog()
        ..response.complete(const OpenRouterModelsResponse([]));
      final coordinator = DatabaseMaintenanceCoordinator(file);
      final scheduler = ApplicationMaintenance(
        databaseFile: file,
        coordinator: coordinator,
        client: client,
      );
      final release = Completer<void>();
      Future<void>? running;
      try {
        await scheduler.configure(AppSettings.defaults());
        final entered = Completer<void>();
        final held = coordinator.runWriter(() async {
          entered.complete();
          await release.future;
        });
        await entered.future;
        running = scheduler.refreshPrices().then((_) {});
        await Future<void>.delayed(Duration.zero);
        final changed = scheduler.configure(
          AppSettings.fromTomlMap({
            'pricing': {'use_external_pricing': false},
            'maintenance': {'database_optimize_enabled': false},
          }),
        );
        release.complete();
        await Future.wait([held, changed, running]);
        expect(
          client.calls,
          0,
          reason: 'the newer privacy setting wins before network I/O',
        );
        expect(scheduler.errorMessage, isNull);
      } finally {
        if (!release.isCompleted) release.complete();
        await running;
        await scheduler.stop();
        scheduler.dispose();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'stopping during a download joins scheduling without late database writes',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_stop_schedule_');
      final file = File('${temp.path}/viewer.sqlite');
      final startup = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(file);
      expect(startup.canStartNormalUi, isTrue);
      final db = openFileBackedDatabase(file);
      final client = _HeldCatalog();
      final scheduler = ApplicationMaintenance(
        databaseFile: file,
        coordinator: DatabaseMaintenanceCoordinator(file),
        client: client,
      );
      Future<void>? running;
      try {
        await scheduler.configure(AppSettings.defaults());
        running = scheduler.runDueJobs();
        await client.started.future.timeout(const Duration(seconds: 3));
        final stopped = await scheduler
            .stop()
            .then((_) => true)
            .timeout(const Duration(milliseconds: 300), onTimeout: () => false);
        expect(stopped, isTrue, reason: 'exit must not wait for the network');
        final snapshotCount = db
            .select('select count(*) n from price_catalog_snapshots')
            .single['n'];
        client.response.complete(
          const OpenRouterModelsResponse([
            OpenRouterModelPricing(
              modelId: 'late/model',
              provider: 'late',
              promptPricePerToken: '0.1',
            ),
          ]),
        );
        await running;
        await Future<void>.delayed(Duration.zero);
        expect(
          db
              .select('select count(*) n from price_catalog_snapshots')
              .single['n'],
          snapshotCount,
        );
        expect(db.select('select * from model_price_periods'), isEmpty);
      } finally {
        if (!client.response.isCompleted) {
          client.response.complete(const OpenRouterModelsResponse([]));
        }
        await running;
        await scheduler.stop();
        scheduler.dispose();
        db.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'manual refresh bypasses disabled automatic cadence and records safe retries',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_manual_schedule_',
      );
      final file = File('${temp.path}/viewer.sqlite');
      final startup = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(file);
      expect(startup.canStartNormalUi, isTrue);
      final db = openFileBackedDatabase(file);
      final client = _HeldCatalog();
      final now = DateTime.utc(2026, 9, 7);
      final scheduler = ApplicationMaintenance(
        databaseFile: file,
        coordinator: DatabaseMaintenanceCoordinator(file),
        client: client,
        clock: () => now,
      );
      Future<bool>? refresh;
      try {
        final settings = AppSettings.fromTomlMap({
          'pricing': {'automatic_refresh_enabled': false},
          'maintenance': {'database_optimize_enabled': false},
        });
        await scheduler.configure(settings);
        PricingRepository(db).applyCatalog(
          const OpenRouterModelsResponse([
            OpenRouterModelPricing(
              modelId: 'test/model',
              provider: 'test',
              promptPricePerToken: '0.01',
            ),
          ]),
          startedAtUtc: now.subtract(const Duration(days: 1)),
          observedAtUtc: now.subtract(const Duration(days: 1)),
        );
        await scheduler.runDueJobs();
        expect(client.calls, 0);
        refresh = scheduler.refreshPrices();
        await client.started.future.timeout(const Duration(seconds: 3));
        client.response.completeError(
          const PricingFetchException(
            'untrusted secret should not persist',
            statusCode: 429,
            retryAfter: Duration(hours: 2),
          ),
        );
        expect(await refresh, isFalse);
        final schedule = db
            .select(
              "select * from maintenance_schedules where job_type='openrouter_price_refresh'",
            )
            .single;
        expect(schedule['retry_count'], 1);
        expect(schedule['last_success_at_utc'], isNull);
        expect(
          DateTime.parse(schedule['next_due_at_utc'] as String).difference(now),
          const Duration(hours: 2),
        );
        expect(schedule['last_error'], 'OpenRouter price refresh failed.');
        expect(
          db
              .select('select valid_to_utc from model_price_periods')
              .single['valid_to_utc'],
          isNull,
        );
      } finally {
        if (!client.response.isCompleted) {
          client.response.complete(const OpenRouterModelsResponse([]));
        }
        await refresh;
        await scheduler.stop();
        scheduler.dispose();
        db.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'disabled downloads still synchronize policy and reprice dirty costs',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_scheduled_reprice_',
      );
      final file = File('${temp.path}/viewer.sqlite');
      final startup = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(file);
      expect(startup.canStartNormalUi, isTrue);
      final db = openFileBackedDatabase(file);
      final client = _HeldCatalog();
      final scheduler = ApplicationMaintenance(
        databaseFile: file,
        coordinator: DatabaseMaintenanceCoordinator(file),
        client: client,
        clock: () => DateTime.utc(2026, 9, 7),
      );
      try {
        final generations = DatabaseGenerationRepository(db);
        final generation = generations.createBuilding(
          sourceSchemaVersion: 15,
          targetSchemaVersion: 16,
          sourceFingerprint: 'scheduler-fixture',
        );
        generations.markReady(generation.id, validationReportJson: '{}');
        generations.activate(generation.id);
        db.execute('''
        insert into sessions(id,source_type,source_file_path,display_path,platform_path,created_at_utc,updated_at_utc)
        values('scheduled','windows','fixture','fixture','fixture','2026-09-07','2026-09-07');
      ''');
        final context = ProjectTagStateStore(
          db,
        ).resolveUsagePathContext(displayPath: 'fixture');
        db.execute(
          '''
        insert into usage_events(session_row_id,source_record_ordinal,epoch,occurred_at_utc,model,path_context_id,
          input_tokens,cached_input_tokens,cache_write_input_tokens,output_tokens,reasoning_output_tokens,
          total_tokens,branch_scope,derivation,event_fingerprint)
        values('scheduled',1,0,'2026-09-07T12:00:00Z','local/model',?,10,0,0,2,0,12,'local','last_token_usage',?)
      ''',
          [context, 'a' * 64],
        );
        db.execute('begin immediate');
        UsageSummaryRepository(
          db,
        ).replaceDailyProjectionsInCurrentTransaction(['scheduled']);
        db.execute('commit');
        final settings = AppSettings.fromTomlMap({
          'pricing': {
            'use_external_pricing': false,
            'automatic_refresh_enabled': false,
            'overrides': {
              'local/model': {'prompt': '0.01', 'completion': '0.02'},
            },
          },
          'maintenance': {'database_optimize_enabled': false},
        });
        await scheduler.configure(settings);
        final beforeRepair = scheduler.dataRevision;
        await scheduler.runDueJobs();
        expect(client.calls, 0);
        expect(db.select('select * from usage_cost_dirty_partitions'), isEmpty);
        expect(
          scheduler.dataRevision,
          greaterThan(beforeRepair),
          reason: 'readers must invalidate cached costs after committed repair',
        );
        final daily = db
            .select(
              'select estimated_cost_text,cost_status from usage_session_daily',
            )
            .single;
        expect(daily['estimated_cost_text'], '0.14');
        expect(daily['cost_status'], 'complete');
        expect(db.select('pragma foreign_key_check'), isEmpty);
      } finally {
        await scheduler.stop();
        scheduler.dispose();
        db.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'weekly optimization considers unused tables after the writer is idle',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_weekly_optimize_',
      );
      final file = File('${temp.path}/viewer.sqlite');
      final startup = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(file);
      expect(startup.canStartNormalUi, isTrue);
      final db = openFileBackedDatabase(file);
      final coordinator = DatabaseMaintenanceCoordinator(file);
      final scheduler = ApplicationMaintenance(
        databaseFile: file,
        coordinator: coordinator,
        client: _HeldCatalog(),
      );
      final release = Completer<void>();
      Future<void>? running;
      try {
        db.execute('''
        analyze sqlite_schema;
        create table weekly_probe(id integer primary key, category integer not null);
        with recursive n(x) as (values(1) union all select x+1 from n where x<1000)
          insert into weekly_probe select x, x%100 from n;
        create index weekly_probe_category on weekly_probe(category);
      ''');
        await scheduler.configure(AppSettings.defaults());
        db.execute(
          "update maintenance_schedules set enabled=0 where job_type='openrouter_price_refresh'",
        );
        db.execute(
          "update maintenance_schedules set next_due_at_utc=null where job_type='database_optimize'",
        );
        final entered = Completer<void>();
        final held = coordinator.runWriter(() async {
          entered.complete();
          await release.future;
        });
        await entered.future;
        running = scheduler.runDueJobs();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          db.select(
            "select stat from sqlite_stat1 where idx='weekly_probe_category'",
          ),
          isEmpty,
        );
        release.complete();
        await held;
        await running;
        expect(
          db
              .select(
                "select stat from sqlite_stat1 where idx='weekly_probe_category'",
              )
              .single['stat'],
          '1000 10',
        );
        expect(
          db
              .select(
                "select state from maintenance_jobs where job_type='database_optimize' order by id desc limit 1",
              )
              .single['state'],
          'succeeded',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        await running;
        await scheduler.stop();
        scheduler.dispose();
        db.close();
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'overdue downloads coalesce and release the writer until catalog apply',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_app_schedule_');
      final file = File('${temp.path}/viewer.sqlite');
      final startup = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(file);
      expect(startup.canStartNormalUi, isTrue);
      final db = openFileBackedDatabase(file);
      final client = _HeldCatalog();
      final coordinator = DatabaseMaintenanceCoordinator(file);
      var now = DateTime.utc(2026, 9, 7);
      final releaseWriter = Completer<void>();
      final writerEntered = Completer<void>();
      Future<void>? heldWriter;
      final scheduler = ApplicationMaintenance(
        databaseFile: file,
        coordinator: coordinator,
        client: client,
        clock: () => now,
      );
      try {
        final settings = AppSettings.defaults();
        await scheduler.configure(settings);
        final first = scheduler.runDueJobs();
        await client.started.future.timeout(const Duration(seconds: 3));
        expect(scheduler.progress?.phase, 'catalog_download');
        final second = scheduler.runDueJobs();
        heldWriter = coordinator.runWriter(() async {
          db.execute(
            "insert into app_metadata(key,value,updated_at_utc) values ('writer_during_download','yes','2026-09-07')",
          );
          writerEntered.complete();
          await releaseWriter.future;
        });
        await writerEntered.future.timeout(const Duration(seconds: 3));
        expect(client.calls, 1);
        final downloaded = Completer<void>();
        scheduler.addListener(() {
          if (scheduler.progress?.phase != 'catalog_download' &&
              !downloaded.isCompleted) {
            downloaded.complete();
          }
        });
        client.response.complete(
          const OpenRouterModelsResponse([
            OpenRouterModelPricing(
              modelId: 'test/model',
              provider: 'test',
              promptPricePerToken: '0.01',
              completionPricePerToken: '0.02',
            ),
          ], declaredTotalCount: 1),
        );
        await downloaded.future.timeout(const Duration(seconds: 3));
        expect(scheduler.progress?.phase, 'catalog_waiting_writer');
        expect(
          scheduler.progress?.currentWork,
          contains('waiting for the database writer'),
        );
        expect(db.select('select * from price_catalog_snapshots'), isEmpty);
        releaseWriter.complete();
        await heldWriter;
        await Future.wait([first, second]);
        expect(
          db.select('select count(*) n from model_price_periods').single['n'],
          1,
        );
        expect(
          db
              .select(
                "select retry_count, last_success_at_utc from maintenance_schedules where job_type='openrouter_price_refresh'",
              )
              .single['retry_count'],
          0,
        );
        now = now.add(const Duration(hours: 5));
        await scheduler.runDueJobs();
        expect(client.calls, 1);
        expect(
          scheduler.schedules
              .firstWhere((row) => row.jobType == 'openrouter_price_refresh')
              .nextDueAtUtc,
          DateTime.utc(2026, 9, 7, 6),
        );
        now = now.add(const Duration(days: 10));
        await scheduler.runDueJobs();
        expect(
          client.calls,
          2,
          reason: 'ten missed days coalesce into one fetch',
        );
        await scheduler.runDueJobs();
        expect(client.calls, 2);
        expect(
          scheduler.schedules
              .firstWhere((row) => row.jobType == 'openrouter_price_refresh')
              .nextDueAtUtc,
          DateTime.utc(2026, 9, 17, 6),
        );
      } finally {
        if (!releaseWriter.isCompleted) releaseWriter.complete();
        await heldWriter;
        if (!client.response.isCompleted) {
          client.response.complete(const OpenRouterModelsResponse([]));
        }
        await scheduler.stop();
        scheduler.dispose();
        db.close();
        await temp.delete(recursive: true);
      }
    },
  );
}

class _HeldCatalog implements OpenRouterModelsClient {
  final requests = <OpenRouterModelsRequest>[];
  final started = Completer<void>();
  final response = Completer<OpenRouterModelsResponse>();
  var calls = 0;
  @override
  Future<OpenRouterModelsResponse> fetchModels(
    OpenRouterModelsRequest request,
  ) {
    calls++;
    requests.add(request);
    if (!started.isCompleted) started.complete();
    return response.future;
  }
}
