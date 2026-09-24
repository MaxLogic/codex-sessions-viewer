import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/database_generation.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migration_preflight.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:codex_sessions_viewer/src/database/usage_path_context_migration.dart';
import 'package:codex_sessions_viewer/src/search/session_search.dart';
import '../support/session_search_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

void main() {
  late Directory temp;
  late Database db;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('csv_context_migration_');
    final file = File('${temp.path}/viewer.sqlite');
    final startup = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(file);
    expect(startup.canStartNormalUi, isTrue);
    db = openFileBackedDatabase(file, maintenanceWriter: true);
  });

  tearDown(() async {
    db.close();
    await temp.delete(recursive: true);
  });

  test(
    'worker prepares contexts without activating an incomplete generation',
    () async {
      db.execute('''
      insert into sessions (id, source_type, source_file_path, display_path,
        platform_path, created_at_utc, updated_at_utc)
      values ('s', 'windows', 'fixture', 'fixture', 'fixture', '2026-01-01', '2026-01-01');
      with recursive ord(n) as (select 1 union all select n + 1 from ord where n < 519)
      insert into sessions (id, source_type, source_file_path, display_path,
        platform_path, created_at_utc, updated_at_utc)
      select printf('s%04d', n), 'windows', printf('fixture%d', n),
        'fixture', 'fixture', '2026-01-01', '2026-01-01' from ord;
      with recursive ord(n) as (select 1 union all select n + 1 from ord where n < 520)
      insert into usage_events (session_row_id, source_record_ordinal, epoch,
        working_directory_display, input_tokens, cached_input_tokens,
        cache_write_input_tokens, output_tokens, reasoning_output_tokens,
        total_tokens, branch_scope, derivation, event_fingerprint)
      select 's', n, 0, 'c:/fixture', 1, 0, 0, 0, 0, 1,
        'local', 'last_token_usage', printf('%064d', n) from ord;
    ''');
      final generation = DatabaseGenerationRepository(db).createBuilding(
        sourceSchemaVersion: 15,
        targetSchemaVersion: 16,
        sourceFingerprint: 'fixture',
      );
      db.execute(r'''
        create trigger stop_copy after insert on usage_events_next
        when new.source_record_ordinal = 512 begin
          update maintenance_jobs set payload_json = json_set(payload_json, '$.stop_requested', json('true'))
          where job_type = 'usage_projection_migration';
        end;
      ''');
      final operation =
          await DatabaseMaintenanceCoordinator(
            File('${temp.path}/viewer.sqlite'),
          ).start(
            jobType: 'usage_projection_migration',
            initialPhase: 'preflight',
            databaseGenerationId: generation.id,
            worker: _prepareContextWorker,
          );
      final progress = <DatabaseMaintenanceProgress>[];
      final subscription = operation.progress.listen(progress.add);
      final result = await operation.result;
      await subscription.cancel();
      expect(result.errorMessage, isNull);
      expect(result.state, DatabaseMaintenanceState.interrupted);
      expect(
        MaintenanceJobRepository(
          db,
        ).latestForType('usage_projection_migration')!.phase,
        'copy_events',
      );
      expect(
        db.select('select count(*) n from usage_events_next').single['n'],
        512,
      );
      db.execute('drop trigger stop_copy');
      final resumed =
          await DatabaseMaintenanceCoordinator(
            File('${temp.path}/viewer.sqlite'),
          ).start(
            jobType: 'usage_projection_migration',
            initialPhase: 'preflight',
            databaseGenerationId: generation.id,
            worker: _prepareContextWorker,
          );
      final resumedSubscription = resumed.progress.listen(progress.add);
      final resumedResult = await resumed.result;
      await resumedSubscription.cancel();
      expect(resumedResult.errorMessage, isNull);
      expect(resumedResult.state, DatabaseMaintenanceState.interrupted);
      expect(
        MaintenanceJobRepository(
          db,
        ).latestForType('usage_projection_migration')!.phase,
        'contexts_validated',
      );
      expect(
        db.select('select count(*) n from usage_events_next').single['n'],
        520,
      );
      expect(
        db.select('select state from database_generations where id = ?', [
          generation.id,
        ]).single['state'],
        'building',
      );
      expect(
        DatabaseGenerationRepository(db).activeGeneration().targetSchemaVersion,
        15,
      );
      final report =
          jsonDecode(
                db.select(
                      'select validation_report_json from database_generations where id = ?',
                      [generation.id],
                    ).single['validation_report_json']
                    as String,
              )
              as Map;
      expect(report['mask_merges'], isEmpty);
      expect(report['project_conflicts'], isEmpty);
      expect((report['context_parity'] as Map)['event_count'], 520);
      expect(
        progress.where((p) => p.phase == 'resolve_contexts').first.fraction,
        lessThan(1),
        reason:
            'Context resolution must not show complete while sessions remain.',
      );
      expect(
        progress
            .where((p) => p.phase == 'copy_events')
            .map((p) => p.completedUnits),
        containsAllInOrder([0, 512, 520]),
      );
      expect(
        progress
            .where(
              (p) => p.phase == 'resolve_contexts' && p.unitLabel == 'records',
            )
            .last
            .completedUnits,
        522,
      );
    },
  );

  test('legacy session fallback resumes and survives mask removal', () {
    var store = ProjectTagStateStore(db);
    final imported = store.upsertProject(name: 'Imported');
    final existing = store.upsertProject(name: 'Existing discovery');
    final manual = store.upsertProject(name: 'Manual');
    final masked = store.upsertProject(name: 'Masked');
    final index = SessionSearchIndex(db);
    for (final id in [
      for (var i = 0; i < 520; i++) 's${i.toString().padLeft(4, '0')}',
      'z-existing',
      'z-manual',
      'z-stale',
    ]) {
      index.upsert(
        SessionSearchDocument(
          id: id,
          sourceType: SessionSearchSourceType.windows,
          sourceFilePath: 'c:/legacy/$id.jsonl',
          displayPath: 'c:/legacy/$id.jsonl',
          platformPath: 'c:/legacy/$id.jsonl',
        ),
      );
    }
    db.execute(
      'update sessions set project_id = ?, project_name_snapshot = ?',
      [imported, 'Imported'],
    );
    db.execute(
      "update sessions set detected_project_id = ? where id = 'z-existing'",
      [existing],
    );
    store.setSessionProject('z-manual', manual);
    db.execute("update sessions set project_id = 999999 where id = 'z-stale'");
    final mask = store.upsertProjectMask(
      projectId: masked,
      pathMask: 'c:/legacy/*',
    );
    final generation = DatabaseGenerationRepository(db).createBuilding(
      sourceSchemaVersion: 15,
      targetSchemaVersion: 16,
      sourceFingerprint: 'fixture',
    );
    var jobs = MaintenanceJobRepository(db);
    final job = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'copy_events',
      databaseGenerationId: generation.id,
    );
    final lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 1),
    )!;
    UsagePathContextMigration(
      db,
    ).resolveNextContextBatch(jobs: jobs, lease: lease);
    expect(
      db.select(
        'select count(*) n from sessions where detected_project_id = ?',
        [imported],
      ).single['n'],
      512,
    );
    db.execute('''
      create trigger fail_session_fallback before update of detected_project_id on sessions
      when new.id = 's0517'
      begin select raise(abort, 'injected session fallback failure'); end
    ''');
    expect(
      () => UsagePathContextMigration(
        db,
      ).resolveNextContextBatch(jobs: jobs, lease: lease),
      throwsA(isA<SqliteException>()),
    );
    expect(
      db.select(
        'select count(*) n from sessions where detected_project_id = ?',
        [imported],
      ).single['n'],
      512,
    );
    expect(
      (jsonDecode(jobs.read(job.id)!.payloadJson!)
          as Map)['session_fallback_cursor'],
      's0511',
    );
    db.execute('drop trigger fail_session_fallback');
    db.close();
    db = openFileBackedDatabase(
      File('${temp.path}/viewer.sqlite'),
      maintenanceWriter: true,
    );
    jobs = MaintenanceJobRepository(db);
    final migration = UsagePathContextMigration(db);
    expect(migration.resolveNextContextBatch(jobs: jobs, lease: lease), 11);
    expect(migration.resolveNextContextBatch(jobs: jobs, lease: lease), 0);
    store = ProjectTagStateStore(db);
    expect(
      SessionSearchIndex(
        db,
      ).search(const SessionSearchQuery(projectNames: {'Masked'})),
      hasLength(522),
    );
    db.execute('delete from project_path_masks where id = ?', [mask]);
    store.recalculateSessionProjects();
    final reopenedIndex = SessionSearchIndex(db);
    expect(
      reopenedIndex.search(
        const SessionSearchQuery(projectNames: {'Imported'}),
      ),
      hasLength(520),
    );
    expect(
      reopenedIndex.search(
        const SessionSearchQuery(projectNames: {'Existing discovery'}),
      ),
      ['z-existing'],
    );
    expect(
      reopenedIndex.search(const SessionSearchQuery(projectNames: {'Manual'})),
      ['z-manual'],
    );
    expect(
      db
          .select(
            "select detected_project_id from sessions where id = 'z-manual'",
          )
          .single['detected_project_id'],
      isNull,
    );
    expect(
      db
          .select("select project_id from sessions where id = 'z-stale'")
          .single['project_id'],
      isNull,
    );
    expect(db.select('pragma foreign_key_check'), isEmpty);
  });

  test('context resolution resumes its own cursor beyond one batch', () {
    final store = ProjectTagStateStore(db);
    final project = store.upsertProject(name: 'Imported');
    final generation = DatabaseGenerationRepository(db).createBuilding(
      sourceSchemaVersion: 15,
      targetSchemaVersion: 16,
      sourceFingerprint: 'fixture',
    );
    for (var i = 0; i < 520; i++) {
      final contextId = store.resolveUsagePathContext(
        displayPath: 'c:/context/$i',
      );
      db.execute(
        '''
        insert into usage_context_project_candidates (generation_id, path_context_id,
          historical_project_id, project_name_snapshot, event_count, malformed_timestamp_count,
          latest_source_rowid, latest_session_id_snapshot, latest_source_record_ordinal)
        values (?, ?, ?, 'Imported', 1, 0, ?, 'fixture', ?)
      ''',
        [generation.id, contextId, project, i + 1, i + 1],
      );
    }
    var jobs = MaintenanceJobRepository(db);
    final job = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'copy_events',
      databaseGenerationId: generation.id,
    );
    final lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 1),
    )!;
    expect(
      UsagePathContextMigration(
        db,
      ).resolveNextContextBatch(jobs: jobs, lease: lease),
      512,
    );
    db.execute('''
      create trigger fail_resolution before update on usage_path_contexts when new.id = 518
      begin select raise(abort, 'injected resolution failure'); end
    ''');
    expect(
      () => UsagePathContextMigration(
        db,
      ).resolveNextContextBatch(jobs: jobs, lease: lease),
      throwsA(isA<SqliteException>()),
    );
    expect(
      db
          .select(
            'select count(*) n from usage_path_contexts where detected_project_id is not null',
          )
          .single['n'],
      511,
    );
    expect(
      (jsonDecode(jobs.read(job.id)!.payloadJson!)
          as Map)['context_resolution_cursor'],
      512,
    );
    db.execute('drop trigger fail_resolution');
    db.close();
    db = openFileBackedDatabase(
      File('${temp.path}/viewer.sqlite'),
      maintenanceWriter: true,
    );
    jobs = MaintenanceJobRepository(db);
    expect(
      UsagePathContextMigration(
        db,
      ).resolveNextContextBatch(jobs: jobs, lease: lease),
      9,
    );
    expect(
      UsagePathContextMigration(
        db,
      ).resolveNextContextBatch(jobs: jobs, lease: lease),
      0,
    );
    expect(
      db
          .select(
            'select count(*) n from usage_path_contexts where detected_project_id is not null',
          )
          .single['n'],
      520,
    );
    expect(db.select('pragma foreign_key_check'), isEmpty);
  });

  test('historical choices compare instants and retain fallback beneath masks', () {
    final store = ProjectTagStateStore(db);
    final first = store.upsertProject(name: 'First');
    final second = store.upsertProject(name: 'Second');
    final masked = store.upsertProject(name: 'Mask');
    db.execute(
      "insert into projects (id, name, created_at_utc, updated_at_utc) values (0, 'Zero', '2026-01-01', '2026-01-01')",
    );
    final maskId = store.upsertProjectMask(
      projectId: masked,
      pathMask: 'c:/equal',
    );
    db.execute('''
      insert into sessions (id, source_type, source_file_path, display_path,
        platform_path, created_at_utc, updated_at_utc)
      values ('s', 'windows', 'fixture', 'fixture', 'fixture', '2026-01-01', '2026-01-01')
    ''');
    var ordinal = 0;
    for (final (path, time, project) in <(String, String?, int?)>[
      ('equal', '2026-09-04T12:00:00Z', first),
      ('equal', '2026-09-04T14:00:00.000+02:00', second),
      ('undated', null, first),
      ('undated', null, second),
      ('malformed', '2026-09-04T12:00:00Z', first),
      ('malformed', 'bad timestamp', second),
      ('unassigned', '2026-09-04T12:00:00Z', null),
      ('zero', '2026-09-04T12:00:00Z', 0),
      ('zero', '2026-09-05T12:00:00Z', null),
    ]) {
      db.execute(
        '''
        insert into usage_events (session_row_id, source_record_ordinal, epoch,
          occurred_at_utc, working_directory_display, project_id, input_tokens,
          cached_input_tokens, cache_write_input_tokens, output_tokens,
          reasoning_output_tokens, total_tokens, branch_scope, derivation, event_fingerprint)
        values ('s', ?, 0, ?, ?, ?, 1, 0, 0, 0, 0, 1, 'local', 'last_token_usage', ?)
      ''',
        [
          ++ordinal,
          time,
          'c:/$path',
          project,
          ordinal.toString().padLeft(64, '0'),
        ],
      );
    }
    final generation = DatabaseGenerationRepository(db).createBuilding(
      sourceSchemaVersion: 15,
      targetSchemaVersion: 16,
      sourceFingerprint: 'fixture',
    );
    final jobs = MaintenanceJobRepository(db);
    final job = jobs.enqueue(
      jobType: 'usage_projection_migration',
      phase: 'copy_events',
      databaseGenerationId: generation.id,
    );
    final lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 1),
    )!;
    final migration = UsagePathContextMigration(db);
    expect(
      () => migration.resolveNextContextBatch(jobs: jobs, lease: lease),
      throwsStateError,
    );
    expect(migration.copyNextBatch(jobs: jobs, lease: lease), 9);
    db.execute('''
      create trigger fail_resolution before update on usage_path_contexts
      when new.display_path_key = 'c:/malformed'
      begin select raise(abort, 'injected resolution failure'); end
    ''');
    expect(
      () => migration.resolveNextContextBatch(jobs: jobs, lease: lease),
      throwsA(isA<SqliteException>()),
    );
    expect(jobs.read(job.id)!.phase, 'copy_events');
    expect(
      db
          .select(
            "select detected_project_id from usage_path_contexts where display_path_key = 'c:/equal'",
          )
          .single
          .values
          .single,
      isNull,
    );
    db.execute('drop trigger fail_resolution');
    expect(migration.resolveNextContextBatch(jobs: jobs, lease: lease), 7);
    final contexts = {
      for (final row in db.select('select * from usage_path_contexts'))
        row['display_path_key']: row,
    };
    expect(contexts['c:/equal']!['detected_project_id'], second);
    expect(contexts['c:/equal']!['effective_project_id'], masked);
    expect(contexts['c:/equal']!['resolution_source'], 'mask');
    expect(contexts['c:/undated']!['effective_project_id'], second);
    expect(contexts['c:/malformed']!['effective_project_id'], first);
    expect(contexts['c:/unassigned']!['effective_project_id'], isNull);
    expect(contexts['c:/zero']!['effective_project_id'], 0);
    expect(
      db
          .select(
            'select sum(malformed_timestamp_count) n from usage_context_project_candidates',
          )
          .single['n'],
      1,
    );
    db.execute('delete from project_path_masks where id = ?', [maskId]);
    store.recalculateSessionProjects();
    final equal = db
        .select(
          "select * from usage_path_contexts where display_path_key = 'c:/equal'",
        )
        .single;
    expect(equal['effective_project_id'], second);
    expect(equal['resolution_source'], 'legacy_import');
    expect(db.select('pragma foreign_key_check'), isEmpty);
  });

  test(
    'shadow batches resume without duplicating facts aliases or candidate counts',
    () async {
      final store = ProjectTagStateStore(db);
      final oldProject = store.upsertProject(name: 'Older');
      final newestProject = store.upsertProject(name: 'Newest');
      db.execute('''
      insert into sessions (id, source_type, source_file_path, display_path,
        platform_path, created_at_utc, updated_at_utc)
      values ('s', 'windows', 'fixture', 'fixture', 'fixture', '2026-01-01', '2026-01-01')
    ''');
      for (var i = 1; i <= 520; i++) {
        db.execute(
          '''
        insert into usage_events (session_row_id, source_record_ordinal,
          rollout_ordinal, turn_ordinal, epoch, occurred_at_utc, model,
          working_directory_display, project_id, input_tokens, cached_input_tokens,
          cache_write_input_tokens, output_tokens, reasoning_output_tokens,
          total_tokens, branch_scope, derivation, event_fingerprint)
        values ('s', ?, ?, ?, 2, ?, 'test', ?, ?, 10, 2, 1, 5, 3, 15, ?, 'cumulative_delta', ?)
      ''',
          [
            i,
            i + 2,
            i + 3,
            i == 1
                ? '2026-09-04T12:00:00Z'
                : i == 520
                ? null
                : '2026-09-03T12:00:00Z',
            i.isEven ? r'C:\Work\Client' : 'c:/work/client',
            i == 1
                ? newestProject
                : i == 520
                ? null
                : oldProject,
            ['local', 'inherited', 'ambiguous'][i % 3],
            i.toString().padLeft(64, '0'),
          ],
        );
      }
      final generation = DatabaseGenerationRepository(db).createBuilding(
        sourceSchemaVersion: 15,
        targetSchemaVersion: 16,
        sourceFingerprint: 'fixture',
      );
      var jobs = MaintenanceJobRepository(db);
      final job = jobs.enqueue(
        jobType: 'usage_projection_migration',
        phase: 'copy_events',
        databaseGenerationId: generation.id,
        totalUnits: 520,
      );
      final lease = jobs.claim(
        jobType: job.jobType,
        leaseDuration: const Duration(minutes: 1),
      )!;
      final migration = UsagePathContextMigration(db);
      expect(migration.copyNextBatch(jobs: jobs, lease: lease), 512);
      expect(jobs.read(job.id)!.lastProcessedRowId, 512);
      db.execute('''
      create trigger fail_copy before insert on usage_events_next
      when new.source_record_ordinal = 518 begin select raise(abort, 'injected copy failure'); end
    ''');
      expect(
        () => migration.copyNextBatch(jobs: jobs, lease: lease),
        throwsA(isA<SqliteException>()),
      );
      expect(jobs.read(job.id)!.lastProcessedRowId, 512);
      expect(
        db.select('select count(*) n from usage_events_next').single['n'],
        512,
      );
      expect(
        db
            .select(
              'select sum(event_count) n from usage_context_project_candidates',
            )
            .single['n'],
        512,
      );
      db.execute('drop trigger fail_copy');
      db.close();
      db = openFileBackedDatabase(
        File('${temp.path}/viewer.sqlite'),
        maintenanceWriter: true,
      );
      jobs = MaintenanceJobRepository(db);
      expect(
        UsagePathContextMigration(db).copyNextBatch(jobs: jobs, lease: lease),
        8,
      );
      expect(
        UsagePathContextMigration(db).copyNextBatch(jobs: jobs, lease: lease),
        0,
      );
      expect(jobs.read(job.id)!.completedUnits, 520);
      final validation = UsagePathContextMigration(db).validateShadowParity();
      expect(validation['event_count'], 520);
      expect(validation['total_tokens'], 7800);
      db.execute(
        'update usage_events_next set input_tokens = 11 where source_record_ordinal = 518',
      );
      expect(
        () => UsagePathContextMigration(db).validateShadowParity(),
        throwsStateError,
      );
      db.execute(
        'update usage_events_next set input_tokens = 10 where source_record_ordinal = 518',
      );
      db.execute(
        "update usage_events_next set branch_scope = 'local' where source_record_ordinal = 518",
      );
      expect(
        () => UsagePathContextMigration(db).validateShadowParity(),
        throwsStateError,
      );
      db.execute(
        "update usage_events_next set branch_scope = 'ambiguous' where source_record_ordinal = 518",
      );
      expect(UsagePathContextMigration(db).validateShadowParity(), validation);
      expect(
        db
            .select('select count(*) n from usage_path_context_aliases')
            .single['n'],
        2,
      );
      expect(
        db
            .select(
              'select count(distinct path_context_id) n from usage_events_next',
            )
            .single['n'],
        1,
      );
      final unchangedColumns =
          '''session_row_id, source_record_ordinal, rollout_ordinal,
      turn_ordinal, epoch, occurred_at_utc, model, input_tokens, cached_input_tokens,
      cache_write_input_tokens, output_tokens, reasoning_output_tokens, total_tokens,
      branch_scope, derivation, event_fingerprint''';
      expect(
        db.select(
          'select $unchangedColumns from usage_events_next order by source_record_ordinal',
        ),
        db.select(
          'select $unchangedColumns from usage_events order by source_record_ordinal',
        ),
      );
      final candidates = db.select(
        'select * from usage_context_project_candidates order by historical_project_id',
      );
      expect(candidates.map((row) => row['event_count']), [518, 1]);
      expect(candidates.last['latest_source_rowid'], 1);
      expect(
        candidates.last['latest_event_epoch_us'],
        DateTime.utc(2026, 9, 4, 12).microsecondsSinceEpoch,
      );
      expect(candidates.last['project_name_snapshot'], 'Newest');
      final reopenedMigration = UsagePathContextMigration(db);
      expect(
        reopenedMigration.resolveNextContextBatch(jobs: jobs, lease: lease),
        3,
      );
      expect(
        reopenedMigration.resolveNextContextBatch(jobs: jobs, lease: lease),
        0,
      );
      final context = db
          .select('select * from usage_path_contexts where id <> 1')
          .single;
      expect(context['detected_project_id'], newestProject);
      expect(context['effective_project_id'], newestProject);
      expect(context['resolution_source'], 'legacy_import');
      final report =
          jsonDecode(
                db
                        .select(
                          'select validation_report_json from database_generations where id = ?',
                          [generation.id],
                        )
                        .single
                        .values
                        .single
                    as String,
              )
              as Map<String, dynamic>;
      final choice = (report['project_conflicts'] as List).single;
      expect(choice['chosen_fallback_project_id'], newestProject);
      expect(choice['candidate_count'], 2);
      expect(choice['attributed_event_count'], 519);
      db.execute('delete from projects where id = ?', [newestProject]);
      expect(
        db
            .select(
              'select project_name_snapshot from usage_context_project_candidates where historical_project_id = ?',
              [newestProject],
            )
            .single
            .values
            .single,
        'Newest',
      );
      expect(db.select('pragma foreign_key_check'), isEmpty);
      expect(DatabaseGenerationRepository(db).activeGeneration().id, 1);
      final generations = DatabaseGenerationRepository(db);
      // This fixture certifies the structural cutover only. Production readiness
      // additionally requires T110/T111 projection and pricing validation.
      generations.markReady(
        generation.id,
        validationReportJson: jsonEncode(report),
      );
      generations.activate(generation.id);
      expect(db.select('select count(*) n from usage_events').single['n'], 520);
      expect(
        db
            .select(
              'select count(*) n, sum(total_tokens) tokens from billable_usage_events',
            )
            .single,
        {'n': 173, 'tokens': 2595},
      );
      expect(db.select('pragma foreign_key_check'), isEmpty);
      db.close();
      final reopened = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(File('${temp.path}/viewer.sqlite'));
      db = openFileBackedDatabase(
        File('${temp.path}/viewer.sqlite'),
        maintenanceWriter: true,
      );
      expect(
        reopened.canStartNormalUi,
        isTrue,
        reason: reopened.fatalError?.details,
      );
      expect(DatabaseGenerationRepository(db).rollbackTo(1), isTrue);
      expect(db.select('select count(*) n from usage_events').single['n'], 520);
      db.close();
      final rolledBack = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(File('${temp.path}/viewer.sqlite'));
      db = openFileBackedDatabase(
        File('${temp.path}/viewer.sqlite'),
        maintenanceWriter: true,
      );
      expect(
        rolledBack.canStartNormalUi,
        isTrue,
        reason: rolledBack.fatalError?.details,
      );
    },
  );

  test(
    'legacy mask merges preserve originals and roll back with their audit',
    () {
      final store = ProjectTagStateStore(db);
      final project = store.upsertProject(name: 'Client');
      final other = store.upsertProject(name: 'Other');
      for (final (owner, mask, priority, active) in [
        (project, r'C:\Work\\Client\*', 90, 0),
        (project, 'c:/work/client/*', 10, 1),
        (project, r'c:\work\CLIENT\*', 50, 0),
        (other, 'c:/work/client/*', 20, 1),
      ]) {
        db.execute(
          '''
        insert into project_path_masks (
          project_id, path_mask, priority, is_active, created_at_utc, updated_at_utc
        ) values (?, ?, ?, ?, '2026-01-01', '2026-01-01')
      ''',
          [owner, mask, priority, active],
        );
      }
      final originals = [
        for (final row in db.select(
          'select * from project_path_masks order by id',
        ))
          Map<String, Object?>.from(row),
      ];
      final migration = UsagePathContextMigration(db);
      expect(
        () => migration.normalizeLegacyMasks(generationId: 1),
        throwsStateError,
      );
      db.execute('begin immediate');
      migration.normalizeLegacyMasks(generationId: 1);
      expect(db.select('select id from project_path_masks'), hasLength(2));
      db.execute('rollback');
      expect(db.select('select * from project_path_masks'), originals);
      expect(
        db
            .select('select validation_report_json from database_generations')
            .single
            .values
            .single,
        isNull,
      );

      db.execute('begin immediate');
      migration.normalizeLegacyMasks(generationId: 1);
      db.execute('commit');
      final rows = db.select('select * from project_path_masks order by id');
      expect(rows.map((row) => row['id']), [1, 4]);
      expect(rows.first['priority'], 10);
      expect(rows.first['is_active'], 1);
      expect(rows.first['path_mask'], originals.first['path_mask']);
      expect(
        rows.map((row) => row['normalized_mask']),
        everyElement('c:/work/client/*'),
      );
      final report =
          db
                  .select(
                    'select validation_report_json from database_generations',
                  )
                  .single
                  .values
                  .single
              as String;
      final audit = jsonDecode(report) as Map<String, dynamic>;
      expect(
        (audit['mask_merges'] as List).single['originals'],
        originals.take(3).toList(),
      );
      expect((audit['mask_merges'] as List).single['retained_id'], 1);
      db.execute('begin immediate');
      migration.normalizeLegacyMasks(generationId: 1);
      db.execute('commit');
      expect(
        db
            .select('select validation_report_json from database_generations')
            .single
            .values
            .single,
        report,
      );
      expect(
        store.upsertProjectMask(
          projectId: project,
          pathMask: r'C:\work\client\*',
        ),
        1,
      );
      expect(db.select('pragma foreign_key_check'), isEmpty);
    },
  );
}

Future<DatabaseMaintenanceWorkerOutcome> _prepareContextWorker(
  DatabaseMaintenanceWorkerContext context,
) async {
  if (context.jobs.read(context.lease.jobId)!.phase == 'preflight') {
    await DatabaseMigrationPreflight(
      diskSpaceProbe: (_) async =>
          const DiskVolumeSpace(volumeKey: 'fixture', availableBytes: 1 << 40),
    ).run(
      database: context.database,
      jobs: context.jobs,
      lease: context.lease,
      databaseFile: context.databaseFile,
      backupDirectory: Directory('${context.databaseFile.parent.path}/backup'),
      temporaryDirectory: context.databaseFile.parent,
    );
  }
  await prepareUsagePathContexts(context);
  // Only the context phases are under test. The real encompassing worker must
  // continue through projections and pricing before whole-job success.
  return DatabaseMaintenanceWorkerOutcome.interrupted;
}
