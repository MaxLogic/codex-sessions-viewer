import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance_cancelled.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:codex_sessions_viewer/src/search/message_search.dart';
import 'package:codex_sessions_viewer/src/search/session_search.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('csv_db_test_');
    dbFile = File('${tempDir.path}${Platform.pathSeparator}viewer.sqlite');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'startup can defer schema 16 without rejecting an existing upgrade',
    () async {
      final migrator = DatabaseMigrator(sqlRoot: Directory('../sql'));
      final deferred = await migrator.openAndMigrate(
        dbFile,
        deferUsageMigration: true,
      );
      expect(deferred.canStartNormalUi, isTrue);
      expect(deferred.lastAppliedSchemaVersion, 15);
      final legacy = openFileBackedDatabase(dbFile);
      try {
        expect(_tableExists(legacy, 'usage_events_next'), isFalse);
      } finally {
        legacy.close();
      }
      final oldCompatible = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
        supportedSchemaVersion: 15,
      ).openAndMigrate(dbFile);
      expect(oldCompatible.canStartNormalUi, isTrue);
      expect(
        (await migrator.openAndMigrate(dbFile)).lastAppliedSchemaVersion,
        23,
      );
      final reopened = await migrator.openAndMigrate(
        dbFile,
        deferUsageMigration: true,
      );
      expect(reopened.canStartNormalUi, isTrue);
      expect(reopened.lastAppliedSchemaVersion, 23);
    },
  );

  test(
    'worker migration borrows its connection on success and failure',
    () async {
      final borrowed = openFileBackedDatabase(dbFile, maintenanceWriter: true);
      addTearDown(borrowed.close);
      borrowed.createFunction(
        functionName: 'bootstrap_connection_marker',
        argumentCount: const AllowedArgumentCount(0),
        function: (_) => 73,
      );
      final result = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
        fts5ProbeSql: 'select bootstrap_connection_marker()',
      ).migrateOpenDatabase(borrowed, dbFile);
      expect(
        result.canStartNormalUi,
        isTrue,
        reason: result.fatalError?.details,
      );
      expect(result.lastAppliedSchemaVersion, 23);
      expect(
        borrowed
            .select('select bootstrap_connection_marker()')
            .single
            .values
            .single,
        73,
      );
      final failed = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
        fts5ProbeSql: 'select nonexistent_bootstrap_function()',
      ).migrateOpenDatabase(borrowed, dbFile);
      expect(failed.canStartNormalUi, isFalse);
      expect(
        borrowed
            .select('select bootstrap_connection_marker()')
            .single
            .values
            .single,
        73,
      );
      expect(borrowed.autocommit, isTrue);
    },
  );

  test(
    'interrupted schema SQL rolls back before recording recovery metadata',
    () async {
      final migrator = DatabaseMigrator(sqlRoot: Directory('../sql'));
      await migrator.openAndMigrate(dbFile, deferUsageMigration: true);
      final borrowed = openFileBackedDatabase(dbFile, maintenanceWriter: true);
      addTearDown(borrowed.close);
      var atomicCalls = 0;
      final result = await migrator.migrateOpenDatabase(
        borrowed,
        dbFile,
        runAtomic: (action) async {
          atomicCalls++;
          expect(borrowed.autocommit, isFalse);
          action();
          throw StateError('Injected interruption before schema commit.');
        },
      );
      expect(result.canStartNormalUi, isFalse);
      expect(atomicCalls, 1);
      expect(result.lastAppliedSchemaVersion, 15);
      expect(borrowed.autocommit, isTrue);
      expect(_tableExists(borrowed, 'usage_events_next'), isFalse);
      expect(
        borrowed
            .select('select success from schema_version where version = 16')
            .single['success'],
        0,
      );
      final retried = await migrator.migrateOpenDatabase(borrowed, dbFile);
      expect(
        retried.canStartNormalUi,
        isTrue,
        reason: retried.fatalError?.details,
      );
    },
  );

  test(
    'schema cancellation rolls back without recording migration failure',
    () async {
      final migrator = DatabaseMigrator(sqlRoot: Directory('../sql'));
      await migrator.openAndMigrate(dbFile, deferUsageMigration: true);
      final borrowed = openFileBackedDatabase(dbFile, maintenanceWriter: true);
      addTearDown(borrowed.close);
      Object? caught;
      try {
        await migrator.migrateOpenDatabase(
          borrowed,
          dbFile,
          runAtomic: (action) async {
            expect(borrowed.autocommit, isFalse);
            action();
            throw const DatabaseMaintenanceCancelled();
          },
        );
      } on Object catch (error) {
        caught = error;
      }

      expect(caught, isA<DatabaseMaintenanceCancelled>());
      expect(borrowed.autocommit, isTrue);
      expect(_tableExists(borrowed, 'usage_events_next'), isFalse);
      expect(
        borrowed.select(
          'select success from schema_version where version = 16',
        ),
        isEmpty,
      );

      final retried = await migrator.migrateOpenDatabase(borrowed, dbFile);
      expect(
        retried.canStartNormalUi,
        isTrue,
        reason: retried.fatalError?.details,
      );
      expect(retried.lastAppliedSchemaVersion, 23);
    },
  );

  test(
    'post migration optimize cancellation preserves committed schema',
    () async {
      final migrator = DatabaseMigrator(
        sqlRoot: Directory('../sql'),
        supportedSchemaVersion: 16,
      );
      await migrator.openAndMigrate(dbFile, deferUsageMigration: true);
      final borrowed = openFileBackedDatabase(dbFile, maintenanceWriter: true);
      addTearDown(borrowed.close);
      var atomicCalls = 0;
      final result = await migrator.migrateOpenDatabase(
        borrowed,
        dbFile,
        runAtomic: (action) async {
          atomicCalls++;
          if (atomicCalls >= 2) {
            throw StateError('Injected optimization interruption.');
          }
          action();
        },
      );
      expect(result.canStartNormalUi, isTrue);
      expect(atomicCalls, greaterThanOrEqualTo(2));
      expect(result.lastAppliedSchemaVersion, 16);
      expect(borrowed.autocommit, isTrue);
      expect(
        borrowed
            .select('select success from schema_version where version = 16')
            .single['success'],
        1,
      );
      expect(
        borrowed
            .select(
              'select last_optimized_schema_version v from database_state',
            )
            .single['v'],
        0,
      );
      expect(
        borrowed
            .select(
              "select last_error from maintenance_schedules where job_type='database_optimize'",
            )
            .single['last_error'],
        'Post-migration optimization failed.',
      );
      final retry = await migrator.migrateOpenDatabase(borrowed, dbFile);
      expect(retry.canStartNormalUi, isTrue);
      expect(
        borrowed
            .select(
              'select last_optimized_schema_version v from database_state',
            )
            .single['v'],
        16,
      );
    },
  );

  test(
    'optimize cancellation rolls back without recording schedule failure',
    () async {
      final migrator = DatabaseMigrator(
        sqlRoot: Directory('../sql'),
        supportedSchemaVersion: 16,
      );
      await migrator.openAndMigrate(dbFile, deferUsageMigration: true);
      final borrowed = openFileBackedDatabase(dbFile, maintenanceWriter: true);
      addTearDown(borrowed.close);
      var atomicCalls = 0;
      Object? caught;
      try {
        await migrator.migrateOpenDatabase(
          borrowed,
          dbFile,
          runAtomic: (action) async {
            atomicCalls++;
            action();
            if (atomicCalls >= 2) {
              throw const DatabaseMaintenanceCancelled();
            }
          },
        );
      } on Object catch (error) {
        caught = error;
      }

      expect(caught, isA<DatabaseMaintenanceCancelled>());
      expect(atomicCalls, 2);
      expect(borrowed.autocommit, isTrue);
      expect(
        borrowed
            .select('select success from schema_version where version = 16')
            .single['success'],
        1,
      );
      expect(
        borrowed
            .select(
              'select last_optimized_schema_version v from database_state',
            )
            .single['v'],
        0,
      );
      expect(
        borrowed.select(
          "select * from maintenance_schedules where job_type = 'database_optimize'",
        ),
        isEmpty,
      );

      final retried = await migrator.migrateOpenDatabase(borrowed, dbFile);
      expect(
        retried.canStartNormalUi,
        isTrue,
        reason: retried.fatalError?.details,
      );
      expect(
        borrowed
            .select(
              'select last_optimized_schema_version v from database_state',
            )
            .single['v'],
        16,
      );
    },
  );

  test(
    'migration 018 adds machine and harness identity without touching annotations',
    () async {
      final at17 = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
        supportedSchemaVersion: 17,
      ).openAndMigrate(dbFile);
      expect(at17.lastAppliedSchemaVersion, 17);
      var db = openFileBackedDatabase(dbFile, maintenanceWriter: true);
      try {
        db.execute("""
          insert into projects (name, is_active, created_at_utc, updated_at_utc)
          values ('Mine', 1, 'now', 'now');
          insert into sessions (id, session_id, source_type, source_file_path,
            display_path, platform_path, scan_status, parse_status, is_pinned,
            project_override, project_id, project_name_snapshot, eval_notes,
            created_at_utc, updated_at_utc)
          values ('session:old', 'old', 'windows', 'C:/a.jsonl', 'C:/a.jsonl',
            'C:/a.jsonl', 'available', 'available', 1, 1, 1, 'Mine', 'keep',
            'now', 'now');
        """);
      } finally {
        db.close();
      }

      final result = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(dbFile);
      expect(result.lastAppliedSchemaVersion, 23);
      db = openFileBackedDatabase(dbFile);
      try {
        final machineId =
            db
                    .select(
                      "select value from app_metadata where key = 'machine_id'",
                    )
                    .single['value']
                as String;
        expect(machineId, matches(RegExp(r'^[0-9a-f]{32}$')));
        expect(
          db
              .select(
                "select value from app_metadata where key = 'database_owner'",
              )
              .single['value'],
          'viewer',
        );
        final old = db
            .select("select * from sessions where id = 'session:old'")
            .single;
        expect(old['harness'], 'codex');
        expect(old['machine_id'], machineId);
        expect(old['is_pinned'], 1);
        expect(old['project_override'], 1);
        expect(old['project_name_snapshot'], 'Mine');
        expect(old['eval_notes'], 'keep');
        db.execute("""
          insert into sessions (id, source_type, source_file_path, display_path,
            platform_path, created_at_utc, updated_at_utc)
          values ('session:new', 'windows', 'x', 'x', 'x', 'now', 'now')
        """);
        expect(
          db
              .select(
                "select machine_id from sessions where id = 'session:new'",
              )
              .single['machine_id'],
          machineId,
        );
        expect(_tableExists(db, 'usage_event_inputs'), isTrue);
      } finally {
        db.close();
      }
    },
  );

  test('applies initial SQL schema and records migration metadata', () async {
    final result = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(dbFile);

    expect(
      result.canStartNormalUi,
      isTrue,
      reason: '${result.fatalError?.summary}: ${result.fatalError?.details}',
    );
    expect(result.fatalError, isNull);

    final db = openFileBackedDatabase(dbFile);
    addTearDown(db.close);

    for (final table in [
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
      'tool_output_search',
      'session_cache_repair_manifest',
    ]) {
      expect(_tableExists(db, table), isTrue, reason: '$table should exist');
    }

    final versionRows = db.select(
      'select version, filename, length(checksum) as checksum_length, success '
      'from schema_version order by version',
    );
    expect(versionRows.length, 23);
    expect(versionRows.first['version'], 1);
    expect(versionRows.first['filename'], '001_initial_schema.sql');
    expect(versionRows.first['checksum_length'], greaterThan(20));
    expect(versionRows.first['success'], 1);
    expect(versionRows[1]['version'], 2);
    expect(versionRows[1]['filename'], '002_search_filter_schema.sql');
    expect(versionRows[1]['checksum_length'], greaterThan(20));
    expect(versionRows[1]['success'], 1);
    expect(versionRows[2]['version'], 3);
    expect(versionRows[2]['filename'], '003_project_override.sql');
    expect(versionRows[2]['checksum_length'], greaterThan(20));
    expect(versionRows[2]['success'], 1);
    expect(versionRows[3]['version'], 4);
    expect(versionRows[3]['filename'], '004_session_token_buckets.sql');
    expect(versionRows[3]['checksum_length'], greaterThan(20));
    expect(versionRows[3]['success'], 1);
    expect(versionRows[4]['version'], 5);
    expect(versionRows[4]['filename'], '005_scan_run_status.sql');
    expect(versionRows[4]['checksum_length'], greaterThan(20));
    expect(versionRows[4]['success'], 1);
    expect(versionRows[5]['version'], 6);
    expect(versionRows[5]['filename'], '006_session_origin.sql');
    expect(versionRows[5]['checksum_length'], greaterThan(20));
    expect(versionRows[5]['success'], 1);
    expect(versionRows[6]['version'], 7);
    expect(versionRows[6]['filename'], '007_session_thread_name.sql');
    expect(versionRows[6]['checksum_length'], greaterThan(20));
    expect(versionRows[6]['success'], 1);
    expect(versionRows[7]['version'], 8);
    expect(versionRows[7]['filename'], '008_local_eval_metadata.sql');
    expect(versionRows[7]['checksum_length'], greaterThan(20));
    expect(versionRows[7]['success'], 1);
    expect(versionRows[8]['version'], 9);
    expect(versionRows[8]['filename'], '009_message_search.sql');
    expect(versionRows[8]['checksum_length'], greaterThan(20));
    expect(versionRows[8]['success'], 1);
    expect(versionRows[9]['version'], 10);
    expect(versionRows[9]['filename'], '010_session_id_lookup_index.sql');
    expect(versionRows[9]['checksum_length'], greaterThan(20));
    expect(versionRows[9]['success'], 1);
    expect(versionRows[10]['version'], 11);
    expect(versionRows[10]['filename'], '011_stable_session_identity.sql');
    expect(versionRows[10]['checksum_length'], greaterThan(20));
    expect(versionRows[10]['success'], 1);
    expect(versionRows[11]['version'], 12);
    expect(versionRows[11]['filename'], '012_external_content_search.sql');
    expect(versionRows[11]['checksum_length'], greaterThan(20));
    expect(versionRows[11]['success'], 1);
    expect(versionRows[12]['version'], 13);
    expect(versionRows[12]['filename'], '013_session_source_state.sql');
    expect(versionRows[12]['checksum_length'], greaterThan(20));
    expect(versionRows[12]['success'], 1);
    expect(versionRows[13]['version'], 14);
    expect(
      versionRows[13]['filename'],
      '014_session_cache_repair_manifest.sql',
    );
    expect(versionRows[13]['checksum_length'], greaterThan(20));
    expect(versionRows[13]['success'], 1);
    expect(versionRows[14]['version'], 15);
    expect(versionRows[14]['filename'], '015_branch_aware_usage.sql');
    expect(versionRows[14]['checksum_length'], greaterThan(20));
    expect(versionRows[14]['success'], 1);
    expect(versionRows[15]['version'], 16);
    expect(
      versionRows[15]['filename'],
      '016_persisted_usage_pricing_maintenance.sql',
    );
    expect(versionRows[15]['checksum_length'], greaterThan(20));
    expect(versionRows[15]['success'], 1);
    expect(versionRows[16]['version'], 17);
    expect(
      versionRows[16]['filename'],
      '017_message_delete_foreign_key_index.sql',
    );
    expect(versionRows[16]['checksum_length'], greaterThan(20));
    expect(versionRows[16]['success'], 1);
    expect(versionRows[17]['version'], 18);
    expect(
      versionRows[17]['filename'],
      '018_collector_identity_and_usage_inputs.sql',
    );
    expect(versionRows[17]['success'], 1);
    expect(versionRows[18]['version'], 19);
    expect(versionRows[18]['filename'], '019_session_history_views.sql');
    expect(versionRows[18]['success'], 1);
    expect(versionRows[19]['version'], 20);
    expect(
      versionRows[19]['filename'],
      '020_harness_scoped_session_identity.sql',
    );
    expect(versionRows[19]['success'], 1);
    expect(versionRows[20]['version'], 21);
    expect(versionRows[20]['filename'], '021_session_change_journal.sql');
    expect(versionRows[20]['success'], 1);
    expect(versionRows[21]['version'], 22);
    expect(versionRows[21]['filename'], '022_collector_upload_outbox.sql');
    expect(versionRows[21]['success'], 1);
    expect(versionRows[22]['version'], 23);
    expect(versionRows[22]['filename'], '023_price_history_sync.sql');
    expect(versionRows[22]['success'], 1);
    expect(_columnExists(db, 'scan_runs', 'status'), isTrue);
    expect(_columnExists(db, 'sessions', 'thread_name'), isTrue);
    expect(_columnExists(db, 'sessions', 'thread_source'), isTrue);
    expect(_columnExists(db, 'sessions', 'parent_thread_id'), isTrue);
    expect(_columnExists(db, 'sessions', 'agent_nickname'), isTrue);
    expect(_columnExists(db, 'sessions', 'agent_role'), isTrue);
    expect(_columnExists(db, 'sessions', 'subagent_depth'), isTrue);
    expect(_columnExists(db, 'sessions', 'eval_ready'), isTrue);
    expect(_columnExists(db, 'sessions', 'eval_status'), isTrue);
    expect(_columnExists(db, 'sessions', 'eval_notes'), isTrue);
    expect(_columnExists(db, 'sessions', 'eval_expected_output'), isTrue);
    expect(_columnExists(db, 'sessions', 'source_state'), isTrue);
    expect(_indexExists(db, 'idx_sessions_source_state'), isFalse);
    expect(_columnExists(db, 'sessions', 'eval_reviewed_at_utc'), isTrue);
    expect(_columnExists(db, 'sessions', 'eval_updated_at_utc'), isTrue);
    expect(_indexExists(db, 'idx_sessions_session_id'), isTrue);
  });

  test('migration 15 adds branch-aware usage schema', () async {
    final result = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
      supportedSchemaVersion: 15,
    ).openAndMigrate(dbFile);

    expect(
      result.canStartNormalUi,
      isTrue,
      reason: '${result.fatalError?.summary}: ${result.fatalError?.details}',
    );
    expect(result.lastAppliedSchemaVersion, 15);

    final db = openFileBackedDatabase(dbFile);
    addTearDown(db.close);

    for (final column in [
      'forked_from_id',
      'history_base_thread_id',
      'history_base_end_ordinal',
      'history_base_end_byte_offset',
      'subagent_history_start_ordinal',
      'usage_projection_status',
    ]) {
      expect(_columnExists(db, 'sessions', column), isTrue, reason: column);
    }
    expect(_tableExists(db, 'usage_events'), isTrue);
    expect(_tableExists(db, 'billable_usage_events'), isTrue);
    for (final index in [
      'idx_sessions_forked_from_id',
      'idx_sessions_parent_thread_id',
      'idx_usage_events_time_project',
      'idx_usage_events_model_time',
    ]) {
      expect(_indexExists(db, index), isTrue, reason: index);
    }
    for (final expectation in [
      (
        sql: "select id from sessions where forked_from_id = 'parent'",
        index: 'idx_sessions_forked_from_id',
      ),
      (
        sql: "select id from sessions where parent_thread_id = 'parent'",
        index: 'idx_sessions_parent_thread_id',
      ),
    ]) {
      final plan = db
          .select('explain query plan ${expectation.sql}')
          .map((row) => row['detail'])
          .join(' ');
      expect(plan, contains(expectation.index));
    }

    final usageColumns = db.select('pragma table_info(usage_events)');
    expect(
      usageColumns
          .where((row) => (row['pk'] as int) > 0)
          .map((row) => row['name'])
          .toList(),
      ['session_row_id', 'source_record_ordinal'],
    );
    final sessionForeignKey = db
        .select('pragma foreign_key_list(usage_events)')
        .singleWhere((row) => row['from'] == 'session_row_id');
    expect(sessionForeignKey['table'], 'sessions');
    expect(sessionForeignKey['from'], 'session_row_id');
    expect(sessionForeignKey['to'], 'id');
    expect((sessionForeignKey['on_delete'] as String).toLowerCase(), 'cascade');

    final viewSql =
        db.select(
              "select sql from sqlite_master where type = 'view' and name = ?",
              ['billable_usage_events'],
            ).single['sql']
            as String;
    expect(viewSql.toLowerCase(), contains("branch_scope = 'local'"));

    db.execute('''
      insert into sessions (
        id, source_type, source_file_path, display_path, platform_path,
        created_at_utc, updated_at_utc
      ) values (
        'legacy-row', 'windows', 'legacy.jsonl', 'legacy.jsonl',
        'legacy.jsonl', '2026-07-29T10:00:00Z', '2026-07-29T10:00:00Z'
      )
      ''');
    expect(
      db.select('select usage_projection_status from sessions where id = ?', [
        'legacy-row',
      ]).single['usage_projection_status'],
      'legacy_pending',
    );

    db.execute(
      '''
      insert into usage_events (
        session_row_id, source_record_ordinal, epoch, input_tokens,
        cached_input_tokens, cache_write_input_tokens, output_tokens,
        reasoning_output_tokens, total_tokens, branch_scope, derivation,
        event_fingerprint
      ) values (?, 7, 0, 10, 2, 1, 4, 1, 14, 'local',
        'last_token_usage', ?)
      ''',
      ['legacy-row', 'a' * 64],
    );
    expect(
      db
          .select('select count(*) as count from billable_usage_events')
          .single['count'],
      1,
    );
    expect(
      () => db.execute(
        '''
        insert into usage_events (
          session_row_id, source_record_ordinal, epoch, input_tokens,
          cached_input_tokens, cache_write_input_tokens, output_tokens,
          reasoning_output_tokens, total_tokens, branch_scope, derivation,
          event_fingerprint
        ) values (?, 8, 0, -1, 0, 0, 0, 0, 0, 'local',
          'cumulative_delta', ?)
        ''',
        ['legacy-row', 'b' * 64],
      ),
      throwsA(isA<SqliteException>()),
    );

    final upgradeSqlRoot = await _copySqlRoot(tempDir);
    final copiedMigration = File(
      '${upgradeSqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}015_branch_aware_usage.sql',
    );
    await copiedMigration.delete();
    final upgradeDbFile = File(
      '${tempDir.path}${Platform.pathSeparator}upgrade-from-14.sqlite',
    );
    final version14 = await DatabaseMigrator(
      sqlRoot: upgradeSqlRoot,
      supportedSchemaVersion: 14,
    ).openAndMigrate(upgradeDbFile);
    expect(version14.canStartNormalUi, isTrue);
    expect(version14.lastAppliedSchemaVersion, 14);
    final version14Db = openFileBackedDatabase(upgradeDbFile);
    version14Db.execute('''
      insert into sessions (
        id, session_id, source_type, source_file_path, display_path,
        platform_path, parser_version, created_at_utc, updated_at_utc
      ) values (
        'legacy-upgrade', 'legacy-upgrade', 'windows', 'legacy.jsonl',
        'legacy.jsonl', 'legacy.jsonl', 2,
        '2026-07-28T10:00:00Z', '2026-07-28T10:00:00Z'
      )
      ''');
    version14Db.close();
    await File(
      '../sql/migration/015_branch_aware_usage.sql',
    ).copy(copiedMigration.path);

    final upgraded = await DatabaseMigrator(
      sqlRoot: upgradeSqlRoot,
      supportedSchemaVersion: 15,
    ).openAndMigrate(upgradeDbFile);
    expect(upgraded.canStartNormalUi, isTrue);
    expect(upgraded.lastAppliedSchemaVersion, 15);
    final upgradedDb = openFileBackedDatabase(upgradeDbFile);
    addTearDown(upgradedDb.close);
    expect(
      upgradedDb.select(
        'select session_id, parser_version, usage_projection_status '
        'from sessions where id = ?',
        ['legacy-upgrade'],
      ).single,
      containsPair('usage_projection_status', 'legacy_pending'),
    );
    expect(
      upgradedDb
          .select('select count(*) as count from usage_events')
          .single['count'],
      0,
    );
  });

  test('adds persisted usage pricing and maintenance schema', () async {
    final freshResult = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(dbFile);

    expect(
      freshResult.canStartNormalUi,
      isTrue,
      reason: freshResult.fatalError?.details,
    );
    expect(freshResult.lastAppliedSchemaVersion, 23);

    final freshDb = openFileBackedDatabase(dbFile);
    addTearDown(freshDb.close);
    _expectPersistedUsageSchema(freshDb);

    final upgradeSqlRoot = await _copySqlRoot(tempDir);
    final copiedMigration = File(
      p.join(
        upgradeSqlRoot.path,
        'migration',
        '016_persisted_usage_pricing_maintenance.sql',
      ),
    );
    final migrationBytes = await copiedMigration.readAsBytes();
    await copiedMigration.delete();
    final upgradeDbFile = File(p.join(tempDir.path, 'upgrade.sqlite'));
    final legacyResult = await DatabaseMigrator(
      sqlRoot: upgradeSqlRoot,
      supportedSchemaVersion: 15,
    ).openAndMigrate(upgradeDbFile);
    expect(legacyResult.canStartNormalUi, isTrue);
    expect(legacyResult.lastAppliedSchemaVersion, 15);
    await copiedMigration.writeAsBytes(migrationBytes);

    final upgradedResult = await DatabaseMigrator(
      sqlRoot: upgradeSqlRoot,
    ).openAndMigrate(upgradeDbFile);
    expect(
      upgradedResult.canStartNormalUi,
      isTrue,
      reason: upgradedResult.fatalError?.details,
    );
    expect(upgradedResult.lastAppliedSchemaVersion, 23);

    final upgradedDb = openFileBackedDatabase(upgradeDbFile);
    addTearDown(upgradedDb.close);
    _expectPersistedUsageSchema(upgradedDb);
    upgradedDb.execute('drop table usage_path_context_aliases');
    upgradedDb.close();
    final missingEvidenceTable = await DatabaseMigrator(
      sqlRoot: upgradeSqlRoot,
    ).openAndMigrate(upgradeDbFile);
    expect(missingEvidenceTable.canStartNormalUi, isFalse);
    expect(
      missingEvidenceTable.fatalError?.details,
      contains('usage_path_context_aliases'),
    );
  });

  test('does not apply migrations newer than its supported schema', () async {
    final result = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
      supportedSchemaVersion: 15,
    ).openAndMigrate(dbFile);

    expect(result.canStartNormalUi, isTrue, reason: result.fatalError?.details);
    expect(result.lastAppliedSchemaVersion, 15);
    final db = openFileBackedDatabase(dbFile);
    addTearDown(db.close);
    expect(_tableExists(db, 'database_generations'), isFalse);
  });

  test('migration drops unused usage model time index', () async {
    final sqlRoot = await _copySqlRoot(tempDir);
    final migration = File(
      p.join(
        sqlRoot.path,
        'migration',
        '016_persisted_usage_pricing_maintenance.sql',
      ),
    );
    final migrationBytes = await migration.readAsBytes();
    await migration.delete();
    final legacyResult = await DatabaseMigrator(
      sqlRoot: sqlRoot,
      supportedSchemaVersion: 15,
    ).openAndMigrate(dbFile);
    expect(legacyResult.canStartNormalUi, isTrue);
    final db = openFileBackedDatabase(dbFile);
    db.execute(
      '''
      insert into sessions (
        id, source_type, source_file_path, display_path, platform_path,
        created_at_utc, updated_at_utc
      ) values ('index-session', 'windows', 'index.jsonl', 'index.jsonl',
                'index.jsonl', ?, ?)
      ''',
      ['2026-09-04T08:00:00Z', '2026-09-04T08:00:00Z'],
    );
    db.execute(
      '''
      insert into usage_events (
        session_row_id, source_record_ordinal, epoch, occurred_at_utc, model,
        input_tokens, cached_input_tokens, cache_write_input_tokens,
        output_tokens, reasoning_output_tokens, total_tokens, branch_scope,
        derivation, event_fingerprint
      ) values ('index-session', 1, 0, ?, 'model', 1, 0, 0, 1, 0, 2,
                'local', 'last_token_usage', ?)
      ''',
      ['2026-09-04T08:00:00Z', 'a' * 64],
    );
    expect(_indexExists(db, 'idx_usage_events_model_time'), isTrue);
    expect(
      db
          .select('select count(*) as count from billable_usage_events')
          .single['count'],
      1,
    );
    db.close();

    await migration.writeAsBytes(migrationBytes);
    final result = await DatabaseMigrator(
      sqlRoot: sqlRoot,
    ).openAndMigrate(dbFile);
    expect(result.canStartNormalUi, isTrue, reason: result.fatalError?.details);
    final migrated = openFileBackedDatabase(dbFile);
    addTearDown(migrated.close);
    expect(_indexExists(migrated, 'idx_usage_events_model_time'), isFalse);
    expect(
      migrated
          .select('pragma table_info(usage_events)')
          .where((row) => (row['pk'] as int) > 0)
          .map((row) => row['name'])
          .toList(),
      ['session_row_id', 'source_record_ordinal'],
    );
    expect(
      migrated
          .select('select count(*) as count from usage_events')
          .single['count'],
      1,
    );
    expect(
      migrated
          .select('select count(*) as count from billable_usage_events')
          .single['count'],
      1,
    );
  });

  test('marks interrupted scan runs failed on the next startup', () async {
    final migrator = DatabaseMigrator(sqlRoot: Directory('../sql'));
    final firstStartup = await migrator.openAndMigrate(dbFile);
    expect(firstStartup.canStartNormalUi, isTrue);

    final db = openFileBackedDatabase(dbFile);
    db.execute(
      '''
      insert into scan_runs (started_at_utc, status)
      values (?, 'running')
      ''',
      ['2026-07-26T10:00:00Z'],
    );
    db.close();

    final recoveredStartup = await migrator.openAndMigrate(dbFile);

    expect(recoveredStartup.canStartNormalUi, isTrue);
    final recovered = openFileBackedDatabase(dbFile);
    addTearDown(recovered.close);
    final run = recovered
        .select(
          'select status, finished_at_utc from scan_runs order by id desc limit 1',
        )
        .single;
    expect(run['status'], 'failed');
    expect(run['finished_at_utc'], isNotNull);
  });

  test(
    'migrates session source lifecycle separately from local archive state',
    () async {
      final sqlRoot = await _copySqlRoot(tempDir);
      final db = openFileBackedDatabase(dbFile);
      final sqlFiles = <File>[
        File(p.join(sqlRoot.path, 'init', '001_initial_schema.sql')),
        ...await Directory(p.join(sqlRoot.path, 'migration'))
            .list()
            .where((entity) => entity is File)
            .cast<File>()
            .where((file) => p.extension(file.path) == '.sql')
            .where(
              (file) => int.parse(p.basename(file.path).split('_').first) <= 12,
            )
            .toList(),
      ]..sort((left, right) => left.path.compareTo(right.path));
      for (final file in sqlFiles) {
        await _applySqlFile(db, file);
      }
      for (final row in [
        (
          id: 'active-source',
          path: r'C:\Users\pawel\.codex\sessions\active.jsonl',
          scanStatus: 'available',
          localArchived: 1,
        ),
        (
          id: 'codex-archived-source',
          path: r'C:\Users\pawel\.codex\archived_sessions\archived.jsonl',
          scanStatus: 'available',
          localArchived: 0,
        ),
        (
          id: 'missing-source',
          path: '/home/pawel/.codex/sessions/missing.jsonl',
          scanStatus: 'missing',
          localArchived: 1,
        ),
      ]) {
        db.execute(
          '''
          insert into sessions (
            id, source_type, source_file_path, display_path, platform_path,
            scan_status, is_archived, created_at_utc, updated_at_utc
          ) values (?, 'windows', ?, ?, ?, ?, ?, ?, ?)
          ''',
          [
            row.id,
            row.path,
            row.path,
            row.path,
            row.scanStatus,
            row.localArchived,
            '2026-07-27T10:00:00Z',
            '2026-07-27T10:00:00Z',
          ],
        );
      }
      db.execute(r'''
        insert into sessions (
          id, source_type, source_file_path, source_file_unc_path,
          display_path, platform_path, scan_status, is_archived,
          created_at_utc, updated_at_utc
        ) values (
          'archived-wsl-unc', 'wsl',
          '/home/pawel/.codex/sessions/stale.jsonl',
          '\\wsl.localhost\Ubuntu\home\pawel\.codex\archived_sessions\stale.jsonl',
          '/home/pawel/.codex/sessions/stale.jsonl',
          '/home/pawel/.codex/sessions/stale.jsonl',
          'available', 1, '2026-07-27T10:00:00Z', '2026-07-27T10:00:00Z'
        )
        ''');
      db.execute(r'''
        insert into sessions (
          id, source_type, source_file_path, display_path, platform_path,
          scan_status, is_archived, created_at_utc, updated_at_utc
        ) values (
          'archived-empty-primary', 'wsl', '',
          '/home/pawel/.codex/archived_sessions/empty-primary.jsonl',
          '/home/pawel/.codex/sessions/empty-primary.jsonl',
          'available', 0, '2026-07-27T10:00:00Z', '2026-07-27T10:00:00Z'
        )
        ''');
      db.close();

      final result = await DatabaseMigrator(
        sqlRoot: sqlRoot,
      ).openAndMigrate(dbFile);

      expect(
        result.canStartNormalUi,
        isTrue,
        reason: result.fatalError?.summary,
      );
      expect(result.lastAppliedSchemaVersion, 23);
      final migrated = openFileBackedDatabase(dbFile);
      addTearDown(migrated.close);
      final rows = migrated.select(
        'select id, source_state, is_archived from sessions order by id',
      );
      expect(
        {for (final row in rows) row['id']: row['source_state']},
        {
          'active-source': 'active',
          'archived-empty-primary': 'codex_archived',
          'archived-wsl-unc': 'codex_archived',
          'codex-archived-source': 'codex_archived',
          'missing-source': 'missing',
        },
      );
      expect(
        {for (final row in rows) row['id']: row['is_archived']},
        {
          'active-source': 1,
          'archived-empty-primary': 0,
          'archived-wsl-unc': 1,
          'codex-archived-source': 0,
          'missing-source': 1,
        },
      );
      expect(
        () => migrated.execute(
          "update sessions set source_state = 'invalid' where id = 'active-source'",
        ),
        throwsA(isA<SqliteException>()),
      );
    },
  );

  test(
    'migration 012 removes copied conversation text from search indexes',
    () async {
      final result = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
      ).openAndMigrate(dbFile);

      expect(
        result.canStartNormalUi,
        isTrue,
        reason: result.fatalError?.summary,
      );
      expect(result.lastAppliedSchemaVersion, 23);

      final db = openFileBackedDatabase(dbFile);
      addTearDown(db.close);
      final messageSearchSql =
          db
                  .select(
                    "select sql from sqlite_master where name = 'message_search'",
                  )
                  .single['sql']
              as String;
      final toolOutputSearchSql =
          db
                  .select(
                    "select sql from sqlite_master where name = 'tool_output_search'",
                  )
                  .single['sql']
              as String;
      final sessionSearchColumns = db
          .select('pragma table_info(session_search)')
          .map((row) => row['name'])
          .toList();

      expect(messageSearchSql.toLowerCase(), contains("content='messages'"));
      expect(_tableExists(db, 'message_search_content'), isFalse);
      expect(
        toolOutputSearchSql.toLowerCase(),
        contains("content='tool_calls'"),
      );
      expect(_tableExists(db, 'tool_output_search_content'), isFalse);
      expect(
        sessionSearchColumns,
        containsAll([
          'title',
          'summary',
          'tool_names',
          'display_path',
          'normalized_path_keys',
          'project_name',
          'tags',
        ]),
      );
      expect(sessionSearchColumns, isNot(contains('user_messages')));
      expect(sessionSearchColumns, isNot(contains('assistant_messages')));
      expect(sessionSearchColumns, isNot(contains('tool_output')));
    },
  );

  test(
    'blocks normal startup when an applied migration checksum changes',
    () async {
      final sqlRoot = await _copySqlRoot(tempDir);
      final migrator = DatabaseMigrator(sqlRoot: sqlRoot);
      final firstRun = await migrator.openAndMigrate(dbFile);
      expect(firstRun.canStartNormalUi, isTrue);

      final migration = File(
        '${sqlRoot.path}${Platform.pathSeparator}init'
        '${Platform.pathSeparator}001_initial_schema.sql',
      );
      await migration.writeAsString(
        '${await migration.readAsString()}\n-- local drift\n',
      );

      final secondRun = await migrator.openAndMigrate(dbFile);

      expect(secondRun.canStartNormalUi, isFalse);
      expect(secondRun.fatalError?.summary, contains('checksum'));
      expect(secondRun.fatalError?.databasePath, dbFile.path);
      expect(secondRun.fatalError?.lastAppliedSchemaVersion, 23);
      expect(
        secondRun.fatalError?.failingMigrationFile,
        '001_initial_schema.sql',
      );
    },
  );

  test('blocks normal startup when FTS5 is unavailable', () async {
    final result = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
      fts5ProbeSql: 'create virtual table temp.fts_probe using missing_fts(x)',
    ).openAndMigrate(dbFile);

    expect(result.canStartNormalUi, isFalse);
    expect(result.fatalError?.summary, contains('FTS5'));
    expect(result.fatalError?.databasePath, dbFile.path);
  });

  test('migration 002 backfills search rows and filter flags', () async {
    final sqlRoot = await _copySqlRoot(tempDir);
    final copiedMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}002_search_filter_schema.sql',
    );
    final copiedProjectOverrideMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}003_project_override.sql',
    );
    final copiedStableIdentityMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}011_stable_session_identity.sql',
    );
    final copiedExternalContentMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}012_external_content_search.sql',
    );
    final copiedSourceStateMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}013_session_source_state.sql',
    );
    final copiedRepairManifestMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}014_session_cache_repair_manifest.sql',
    );
    final copiedBranchUsageMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}015_branch_aware_usage.sql',
    );
    await copiedMigration.delete();
    await copiedProjectOverrideMigration.delete();
    await copiedStableIdentityMigration.delete();
    await copiedExternalContentMigration.delete();
    await copiedSourceStateMigration.delete();
    await copiedRepairManifestMigration.delete();
    await copiedBranchUsageMigration.delete();
    final firstRun = await DatabaseMigrator(
      sqlRoot: sqlRoot,
      supportedSchemaVersion: 10,
    ).openAndMigrate(dbFile);
    expect(
      firstRun.canStartNormalUi,
      isTrue,
      reason:
          '${firstRun.fatalError?.summary}: ${firstRun.fatalError?.details}',
    );

    final db = openFileBackedDatabase(dbFile);
    db.execute('''
      insert into projects (id, name, created_at_utc, updated_at_utc)
      values (1, 'Migrated Project', '2026-06-12T00:00:00Z', '2026-06-12T00:00:00Z')
      ''');
    db.execute('''
      insert into sessions (
        id,
        source_type,
        source_file_path,
        display_path,
        platform_path,
        title,
        summary,
        project_id,
        project_name_snapshot,
        scan_status,
        parse_status,
        tool_call_count,
        created_at_utc,
        updated_at_utc
      ) values (
        'existing',
        'windows',
        'C:\\sessions\\existing.jsonl',
        'C:\\sessions\\existing.jsonl',
        'C:\\sessions\\existing.jsonl',
        'Migration title',
        'Migration summary',
        1,
        'Migrated Snapshot',
        'available',
        'available',
        1,
        '2026-06-12T00:00:00Z',
        '2026-06-12T00:00:00Z'
      )
      ''');
    db.execute('''
      insert into messages (
        session_id,
        message_index,
        author_type,
        first_line,
        content_plain,
        content_preview,
        has_tool_calls,
        has_error,
        created_at_db_utc,
        updated_at_db_utc
      ) values (
        'existing',
        0,
        'user',
        'Find migrated needle',
        'Find migrated needle',
        'Find migrated needle',
        1,
        0,
        '2026-06-12T00:00:00Z',
        '2026-06-12T00:00:00Z'
      )
      ''');
    db.execute('''
      insert into messages (
        session_id,
        message_index,
        author_type,
        first_line,
        content_plain,
        content_preview,
        has_tool_calls,
        has_error,
        created_at_db_utc,
        updated_at_db_utc
      ) values (
        'existing',
        1,
        'assistant',
        '```dart',
        '```dart\nthrow Exception("boom");\n```',
        '```dart',
        0,
        1,
        '2026-06-12T00:00:00Z',
        '2026-06-12T00:00:00Z'
      )
      ''');
    db.execute('''
      insert into tool_calls (
        session_id,
        tool_index,
        tool_name,
        status,
        output_preview,
        error_message
      ) values (
        'existing',
        0,
        'shell_command',
        'failed',
        'preview-token',
        'boom'
      )
      ''');
    db.execute('''
      insert into tags (id, name, created_at_utc, updated_at_utc)
      values (1, 'migrated-tag', '2026-06-12T00:00:00Z', '2026-06-12T00:00:00Z')
      ''');
    db.execute('''
      insert into session_tags (session_id, tag_id, created_at_utc)
      values ('existing', 1, '2026-06-12T00:00:00Z')
      ''');
    db.execute('''
      insert into session_path_keys (session_id, path_key)
      values ('existing', 'c:/sessions/existing.jsonl')
      ''');
    db.close();
    await File(
      '../sql/migration/002_search_filter_schema.sql',
    ).copy(copiedMigration.path);
    await File(
      '../sql/migration/003_project_override.sql',
    ).copy(copiedProjectOverrideMigration.path);
    await File(
      '../sql/migration/011_stable_session_identity.sql',
    ).copy(copiedStableIdentityMigration.path);
    await File(
      '../sql/migration/012_external_content_search.sql',
    ).copy(copiedExternalContentMigration.path);
    await File(
      '../sql/migration/013_session_source_state.sql',
    ).copy(copiedSourceStateMigration.path);
    await File(
      '../sql/migration/014_session_cache_repair_manifest.sql',
    ).copy(copiedRepairManifestMigration.path);
    await File(
      '../sql/migration/015_branch_aware_usage.sql',
    ).copy(copiedBranchUsageMigration.path);

    final result = await DatabaseMigrator(
      sqlRoot: sqlRoot,
      supportedSchemaVersion: 15,
    ).openAndMigrate(dbFile);
    expect(
      result.canStartNormalUi,
      isTrue,
      reason: '${result.fatalError?.summary}: ${result.fatalError?.details}',
    );

    final migrated = openFileBackedDatabase(dbFile);
    addTearDown(migrated.close);

    // The historical migration has passed above. Current search uses the
    // persisted activity column introduced by the current schema.
    migrated.execute(
      File(
        '../sql/migration/016_persisted_usage_pricing_maintenance.sql',
      ).readAsStringSync(),
    );
    MessageSearchIndex(migrated).backfillBatch(limit: 10);
    expect(
      SessionSearchIndex(migrated).search(
        const SessionSearchQuery(
          text: 'migrated',
          textScopes: {SearchTextScope.userMessages},
        ),
      ),
      [r'source:C:\sessions\existing.jsonl'],
    );
    final row = migrated.select(
      'select has_code_blocks, has_tool_calls, has_errors '
      'from sessions where id = ?',
      [r'source:C:\sessions\existing.jsonl'],
    ).single;
    expect(row['has_code_blocks'], 1);
    expect(row['has_tool_calls'], 1);
    expect(row['has_errors'], 1);
  });

  test(
    'migration 003 preserves existing project assignments as overrides',
    () async {
      final sqlRoot = await _copySqlRoot(tempDir);
      final copiedProjectOverrideMigration = File(
        '${sqlRoot.path}${Platform.pathSeparator}migration'
        '${Platform.pathSeparator}003_project_override.sql',
      );
      final copiedStableIdentityMigration = File(
        '${sqlRoot.path}${Platform.pathSeparator}migration'
        '${Platform.pathSeparator}011_stable_session_identity.sql',
      );
      final copiedExternalContentMigration = File(
        '${sqlRoot.path}${Platform.pathSeparator}migration'
        '${Platform.pathSeparator}012_external_content_search.sql',
      );
      final copiedSourceStateMigration = File(
        '${sqlRoot.path}${Platform.pathSeparator}migration'
        '${Platform.pathSeparator}013_session_source_state.sql',
      );
      final copiedRepairManifestMigration = File(
        '${sqlRoot.path}${Platform.pathSeparator}migration'
        '${Platform.pathSeparator}014_session_cache_repair_manifest.sql',
      );
      final copiedBranchUsageMigration = File(
        '${sqlRoot.path}${Platform.pathSeparator}migration'
        '${Platform.pathSeparator}015_branch_aware_usage.sql',
      );
      await copiedProjectOverrideMigration.delete();
      await copiedStableIdentityMigration.delete();
      await copiedExternalContentMigration.delete();
      await copiedSourceStateMigration.delete();
      await copiedRepairManifestMigration.delete();
      await copiedBranchUsageMigration.delete();
      final firstRun = await DatabaseMigrator(
        sqlRoot: sqlRoot,
        supportedSchemaVersion: 10,
      ).openAndMigrate(dbFile);
      expect(
        firstRun.canStartNormalUi,
        isTrue,
        reason:
            '${firstRun.fatalError?.summary}: ${firstRun.fatalError?.details}',
      );

      final db = openFileBackedDatabase(dbFile);
      db.execute('''
      insert into projects (id, name, created_at_utc, updated_at_utc)
      values (1, 'Manual Project', '2026-06-12T00:00:00Z', '2026-06-12T00:00:00Z')
      ''');
      db.execute('''
      insert into projects (id, name, created_at_utc, updated_at_utc)
      values (2, 'Mask Project', '2026-06-12T00:00:00Z', '2026-06-12T00:00:00Z')
      ''');
      db.execute('''
      insert into project_path_masks (
        project_id,
        path_mask,
        priority,
        is_active,
        created_at_utc,
        updated_at_utc
      ) values (
        2,
        'c:/work/*',
        1,
        1,
        '2026-06-12T00:00:00Z',
        '2026-06-12T00:00:00Z'
      )
      ''');
      db.execute('''
      insert into sessions (
        id,
        source_type,
        source_file_path,
        display_path,
        platform_path,
        project_id,
        project_name_snapshot,
        created_at_utc,
        updated_at_utc
      ) values (
        'existing-project',
        'windows',
        'C:\\work\\session.jsonl',
        'C:\\work\\session.jsonl',
        'C:\\work\\session.jsonl',
        1,
        'Manual Project',
        '2026-06-12T00:00:00Z',
        '2026-06-12T00:00:00Z'
      )
      ''');
      db.close();

      await File(
        '../sql/migration/003_project_override.sql',
      ).copy(copiedProjectOverrideMigration.path);
      await File(
        '../sql/migration/011_stable_session_identity.sql',
      ).copy(copiedStableIdentityMigration.path);
      await File(
        '../sql/migration/012_external_content_search.sql',
      ).copy(copiedExternalContentMigration.path);
      await File(
        '../sql/migration/013_session_source_state.sql',
      ).copy(copiedSourceStateMigration.path);
      await File(
        '../sql/migration/014_session_cache_repair_manifest.sql',
      ).copy(copiedRepairManifestMigration.path);
      await File(
        '../sql/migration/015_branch_aware_usage.sql',
      ).copy(copiedBranchUsageMigration.path);

      final result = await DatabaseMigrator(
        sqlRoot: sqlRoot,
        supportedSchemaVersion: 15,
      ).openAndMigrate(dbFile);
      expect(
        result.canStartNormalUi,
        isTrue,
        reason: result.fatalError?.summary,
      );

      final migrated = openFileBackedDatabase(dbFile);
      addTearDown(migrated.close);
      expect(
        migrated.select('select project_override from sessions where id = ?', [
          r'source:C:\work\session.jsonl',
        ]).single['project_override'],
        1,
      );

      // Exercise today's project repository after proving the historical upgrade.
      migrated.execute(
        File(
          '../sql/migration/016_persisted_usage_pricing_maintenance.sql',
        ).readAsStringSync(),
      );
      ProjectTagStateStore(migrated).recalculateSessionProjects();

      final row = migrated.select(
        'select project_id, project_name_snapshot from sessions where id = ?',
        [r'source:C:\work\session.jsonl'],
      ).single;
      expect(row['project_id'], 1);
      expect(row['project_name_snapshot'], 'Manual Project');
    },
  );

  test('migration 004 backfills persisted token bucket totals', () async {
    final sqlRoot = await _copySqlRoot(tempDir);
    final tokenBucketMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}004_session_token_buckets.sql',
    );
    if (await tokenBucketMigration.exists()) {
      await tokenBucketMigration.delete();
    }
    final firstRun = await DatabaseMigrator(
      sqlRoot: sqlRoot,
      supportedSchemaVersion: 15,
    ).openAndMigrate(dbFile);
    expect(
      firstRun.canStartNormalUi,
      isTrue,
      reason:
          '${firstRun.fatalError?.summary}: ${firstRun.fatalError?.details}',
    );

    final db = openFileBackedDatabase(dbFile);
    db.execute('''
      insert into sessions (
        id,
        source_type,
        source_file_path,
        display_path,
        platform_path,
        created_at_utc,
        updated_at_utc
      ) values (
        'bucketed',
        'windows',
        'C:\\sessions\\bucketed.jsonl',
        'C:\\sessions\\bucketed.jsonl',
        'C:\\sessions\\bucketed.jsonl',
        '2026-06-12T00:00:00Z',
        '2026-06-12T00:00:00Z'
      )
      ''');
    var messageIndex = 0;
    for (final row in [
      ('user', 11),
      ('user', 7),
      ('assistant', 13),
      ('tool', 17),
    ]) {
      db.execute(
        '''
        insert into messages (
          session_id,
          message_index,
          author_type,
          first_line,
          content_plain,
          content_preview,
          token_total,
          created_at_db_utc,
          updated_at_db_utc
        ) values (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          'bucketed',
          messageIndex++,
          row.$1,
          row.$1,
          row.$1,
          row.$1,
          row.$2,
          '2026-06-12T00:00:00Z',
          '2026-06-12T00:00:00Z',
        ],
      );
    }
    db.execute('''
      insert into sessions (
        id,
        source_type,
        source_file_path,
        display_path,
        platform_path,
        input_tokens,
        output_tokens,
        cached_input_tokens,
        created_at_utc,
        updated_at_utc
      ) values (
        'aggregate-only',
        'windows',
        'C:\\sessions\\aggregate-only.jsonl',
        'C:\\sessions\\aggregate-only.jsonl',
        'C:\\sessions\\aggregate-only.jsonl',
        42,
        21,
        7,
        '2026-06-12T00:00:00Z',
        '2026-06-12T00:00:00Z'
      )
      ''');
    db.close();

    await File(
      '../sql/migration/004_session_token_buckets.sql',
    ).copy(tokenBucketMigration.path);

    final result = await DatabaseMigrator(
      sqlRoot: sqlRoot,
    ).openAndMigrate(dbFile);
    expect(result.canStartNormalUi, isTrue, reason: result.fatalError?.summary);

    final migrated = openFileBackedDatabase(dbFile);
    addTearDown(migrated.close);
    final bucketed = migrated
        .select(
          '''
          select user_message_tokens,
                 assistant_response_tokens,
                 tool_call_tokens
          from sessions
          where id = ?
          ''',
          ['bucketed'],
        )
        .single;
    expect(bucketed['user_message_tokens'], 18);
    expect(bucketed['assistant_response_tokens'], 13);
    expect(bucketed['tool_call_tokens'], 17);
    final aggregateOnly = migrated
        .select(
          '''
          select user_message_tokens,
                 assistant_response_tokens,
                 tool_call_tokens
          from sessions
          where id = ?
          ''',
          ['aggregate-only'],
        )
        .single;
    expect(aggregateOnly['user_message_tokens'], 42);
    expect(aggregateOnly['assistant_response_tokens'], 21);
    expect(aggregateOnly['tool_call_tokens'], 0);
  });

  test(
    'migration 005 adds scan run status without rewriting old rows',
    () async {
      final sqlRoot = await _copySqlRoot(tempDir);
      final scanRunStatusMigration = File(
        '${sqlRoot.path}${Platform.pathSeparator}migration'
        '${Platform.pathSeparator}005_scan_run_status.sql',
      );
      if (await scanRunStatusMigration.exists()) {
        await scanRunStatusMigration.delete();
      }
      final firstRun = await DatabaseMigrator(
        sqlRoot: sqlRoot,
        supportedSchemaVersion: 4,
      ).openAndMigrate(dbFile);
      expect(firstRun.canStartNormalUi, isTrue);

      final db = openFileBackedDatabase(dbFile);
      db.execute(
        '''
      insert into scan_runs (
        started_at_utc,
        finished_at_utc,
        files_found
      ) values (?, ?, ?)
      ''',
        ['2026-06-18T10:00:00Z', '2026-06-18T10:00:01Z', 7],
      );
      db.close();

      await File(
        '../sql/migration/005_scan_run_status.sql',
      ).copy(scanRunStatusMigration.path);

      final result = await DatabaseMigrator(
        sqlRoot: sqlRoot,
      ).openAndMigrate(dbFile);
      expect(
        result.canStartNormalUi,
        isTrue,
        reason: result.fatalError?.summary,
      );

      final migrated = openFileBackedDatabase(dbFile);
      addTearDown(migrated.close);
      expect(_columnExists(migrated, 'scan_runs', 'status'), isTrue);
      final existing = migrated.select(
        'select status from scan_runs where files_found = ?',
        [7],
      ).single;
      expect(existing['status'], 'succeeded');
      migrated.execute(
        '''
      insert into scan_runs (
        started_at_utc,
        status
      ) values (?, ?)
      ''',
        ['2026-06-18T10:01:00Z', 'cancelled'],
      );
      expect(
        migrated
            .select('select status from scan_runs order by id desc limit 1')
            .single['status'],
        'cancelled',
      );
    },
  );

  test('migrates local eval metadata', () async {
    final sqlRoot = await _copySqlRoot(tempDir);
    final evalMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}008_local_eval_metadata.sql',
    );
    final stableIdentityMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}011_stable_session_identity.sql',
    );
    final externalContentMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}012_external_content_search.sql',
    );
    final sourceStateMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}013_session_source_state.sql',
    );
    final repairManifestMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}014_session_cache_repair_manifest.sql',
    );
    final branchUsageMigration = File(
      '${sqlRoot.path}${Platform.pathSeparator}migration'
      '${Platform.pathSeparator}015_branch_aware_usage.sql',
    );
    if (await evalMigration.exists()) {
      await evalMigration.delete();
    }
    if (await stableIdentityMigration.exists()) {
      await stableIdentityMigration.delete();
    }
    if (await externalContentMigration.exists()) {
      await externalContentMigration.delete();
    }
    if (await sourceStateMigration.exists()) {
      await sourceStateMigration.delete();
    }
    if (await repairManifestMigration.exists()) {
      await repairManifestMigration.delete();
    }
    if (await branchUsageMigration.exists()) {
      await branchUsageMigration.delete();
    }
    final firstRun = await DatabaseMigrator(
      sqlRoot: sqlRoot,
      supportedSchemaVersion: 10,
    ).openAndMigrate(dbFile);
    expect(
      firstRun.canStartNormalUi,
      isTrue,
      reason:
          '${firstRun.fatalError?.summary}: ${firstRun.fatalError?.details}',
    );

    final db = openFileBackedDatabase(dbFile);
    db.execute('''
      insert into sessions (
        id,
        source_type,
        source_file_path,
        display_path,
        platform_path,
        created_at_utc,
        updated_at_utc
      ) values (
        'eval-existing',
        'windows',
        'C:\\sessions\\eval-existing.jsonl',
        'C:\\sessions\\eval-existing.jsonl',
        'C:\\sessions\\eval-existing.jsonl',
        '2026-07-07T10:00:00Z',
        '2026-07-07T10:00:00Z'
      )
      ''');
    db.close();

    await File(
      '../sql/migration/008_local_eval_metadata.sql',
    ).copy(evalMigration.path);
    await File(
      '../sql/migration/011_stable_session_identity.sql',
    ).copy(stableIdentityMigration.path);
    await File(
      '../sql/migration/012_external_content_search.sql',
    ).copy(externalContentMigration.path);
    await File(
      '../sql/migration/013_session_source_state.sql',
    ).copy(sourceStateMigration.path);
    await File(
      '../sql/migration/014_session_cache_repair_manifest.sql',
    ).copy(repairManifestMigration.path);
    await File(
      '../sql/migration/015_branch_aware_usage.sql',
    ).copy(branchUsageMigration.path);

    final migrator = DatabaseMigrator(sqlRoot: sqlRoot);
    expect(migrator.supportedSchemaVersion, 23);
    final result = await migrator.openAndMigrate(dbFile);
    expect(result.canStartNormalUi, isTrue, reason: result.fatalError?.summary);
    expect(result.lastAppliedSchemaVersion, 23);

    final migrated = openFileBackedDatabase(dbFile);
    addTearDown(migrated.close);
    for (final column in [
      'eval_ready',
      'eval_status',
      'eval_notes',
      'eval_expected_output',
      'eval_reviewed_at_utc',
      'eval_updated_at_utc',
    ]) {
      expect(_columnExists(migrated, 'sessions', column), isTrue);
    }
    expect(_indexExists(migrated, 'idx_sessions_eval_ready'), isTrue);
    expect(_indexExists(migrated, 'idx_sessions_eval_status'), isTrue);

    final row = migrated
        .select(
          '''
      select eval_ready,
             eval_status,
             eval_notes,
             eval_expected_output,
             eval_reviewed_at_utc,
             eval_updated_at_utc
      from sessions
          where id = ?
      ''',
          [r'source:C:\sessions\eval-existing.jsonl'],
        )
        .single;
    expect(row['eval_ready'], 0);
    expect(row['eval_status'], isNull);
    expect(row['eval_notes'], isNull);
    expect(row['eval_expected_output'], isNull);
    expect(row['eval_reviewed_at_utc'], isNull);
    expect(row['eval_updated_at_utc'], isNull);
  });

  test(
    'migration 009 creates message search without startup backfill',
    () async {
      final sqlRoot = await _copySqlRoot(tempDir);
      final db = openFileBackedDatabase(dbFile);
      for (final path in [
        ['init', '001_initial_schema.sql'],
        ['migration', '002_search_filter_schema.sql'],
        ['migration', '003_project_override.sql'],
        ['migration', '004_session_token_buckets.sql'],
        ['migration', '005_scan_run_status.sql'],
        ['migration', '006_session_origin.sql'],
        ['migration', '007_session_thread_name.sql'],
        ['migration', '008_local_eval_metadata.sql'],
      ]) {
        await _applySqlFile(
          db,
          File(
            '${sqlRoot.path}${Platform.pathSeparator}${path[0]}'
            '${Platform.pathSeparator}${path[1]}',
          ),
        );
      }
      expect(_tableExists(db, 'message_search'), isFalse);
      db.execute('''
      insert into sessions (
        id,
        source_type,
        source_file_path,
        display_path,
        platform_path,
        title,
        thread_name,
        project_name_snapshot,
        created_at_utc,
        updated_at_utc
      ) values (
        'message-search-existing',
        'windows',
        'C:\\sessions\\message-search-existing.jsonl',
        'C:\\sessions\\message-search-existing.jsonl',
        'C:\\sessions\\message-search-existing.jsonl',
        'Message search title',
        'Message search thread',
        'Migration Project',
        '2026-07-07T10:00:00.000Z',
        '2026-07-07T10:00:00.000Z'
      )
      ''');
      db.execute('''
      insert into messages (
        session_id,
        message_index,
        author_type,
        created_at_utc,
        first_line,
        content_plain,
        content_preview,
        created_at_db_utc,
        updated_at_db_utc
      ) values (
        'message-search-existing',
        4,
        'assistant',
        '2026-07-07T10:05:00.000Z',
        'Migration context needle',
        'Migration context needle with enough words for a useful snippet',
        'Migration context needle',
        '2026-07-07T10:05:00.000Z',
        '2026-07-07T10:05:00.000Z'
      )
      ''');
      db.close();

      final result = await DatabaseMigrator(
        sqlRoot: sqlRoot,
      ).openAndMigrate(dbFile);
      expect(
        result.canStartNormalUi,
        isTrue,
        reason: '${result.fatalError?.summary}: ${result.fatalError?.details}',
      );
      expect(result.lastAppliedSchemaVersion, 23);

      final migrated = openFileBackedDatabase(dbFile);
      addTearDown(migrated.close);
      final rows = migrated.select('''
      select
        rowid
      from message_search
      where message_search match 'migration'
      ''');
      expect(rows, isEmpty);
      expect(_indexExists(migrated, 'idx_sessions_session_id'), isTrue);
    },
  );

  test('collapses duplicate session snapshots', () async {
    final sqlRoot = await _copySqlRoot(tempDir);
    final db = openFileBackedDatabase(dbFile);
    for (final path in [
      ['init', '001_initial_schema.sql'],
      ['migration', '002_search_filter_schema.sql'],
      ['migration', '003_project_override.sql'],
      ['migration', '004_session_token_buckets.sql'],
      ['migration', '005_scan_run_status.sql'],
      ['migration', '006_session_origin.sql'],
      ['migration', '007_session_thread_name.sql'],
      ['migration', '008_local_eval_metadata.sql'],
      ['migration', '009_message_search.sql'],
      ['migration', '010_session_id_lookup_index.sql'],
    ]) {
      await _applySqlFile(
        db,
        File(
          '${sqlRoot.path}${Platform.pathSeparator}${path[0]}'
          '${Platform.pathSeparator}${path[1]}',
        ),
      );
    }
    db.execute('''
      insert into tags (id, name, created_at_utc, updated_at_utc)
      values (7, 'important', '2026-07-07T10:00:00Z', '2026-07-07T10:00:00Z')
      ''');
    db.execute('''
      insert into projects (id, name, created_at_utc, updated_at_utc)
      values (3, 'Manual Project', '2026-07-07T10:00:00Z', '2026-07-07T10:00:00Z')
      ''');
    for (final row in [
      ('old-snapshot', 10, 1, 1, 1, 1, 3, 'Manual Project'),
      ('new-snapshot', 30, 0, 0, 0, 0, null, null),
    ]) {
      db.execute(
        '''
        insert into sessions (
          id,
          session_id,
          source_type,
          source_file_path,
          display_path,
          platform_path,
          file_size,
          message_count,
          is_pinned,
          is_archived,
          project_override,
          project_id,
          project_name_snapshot,
          archived_at_utc,
          archive_reason,
          eval_ready,
          eval_status,
          eval_notes,
          eval_expected_output,
          eval_reviewed_at_utc,
          eval_updated_at_utc,
          created_at_utc,
          updated_at_utc
        ) values (?, 'duplicate-session', 'windows', 'C:\\sessions\\duplicate.jsonl',
          'C:\\sessions\\duplicate.jsonl', 'C:\\sessions\\duplicate.jsonl',
          ?, ?, ?, ?, ?, ?, ?, '2026-07-07T10:03:00Z',
          'archived duplicate', ?, 'correct', 'needs review',
          'expected answer', '2026-07-07T10:04:00Z',
          '2026-07-07T10:05:00Z', '2026-07-07T10:00:00Z',
          '2026-07-07T10:00:00Z')
        ''',
        [
          row.$1,
          row.$2,
          row.$2,
          row.$3,
          row.$4,
          row.$6,
          row.$7,
          row.$8,
          row.$5,
        ],
      );
      db.execute(
        '''
        insert into messages (
          session_id,
          message_index,
          author_type,
          first_line,
          content_preview,
          created_at_db_utc,
          updated_at_db_utc
        ) values (?, 0, 'user', ?, ?, '2026-07-07T10:00:00Z',
          '2026-07-07T10:00:00Z')
        ''',
        [row.$1, row.$1, row.$1],
      );
    }
    db.execute(
      'insert into session_tags (session_id, tag_id, created_at_utc) '
      "values ('old-snapshot', 7, '2026-07-07T10:00:00Z')",
    );
    db.execute(
      'insert into session_path_keys (session_id, path_key) '
      "values ('old-snapshot', 'c:/sessions/duplicate.jsonl')",
    );
    db.close();

    final result = await DatabaseMigrator(
      sqlRoot: sqlRoot,
    ).openAndMigrate(dbFile);
    expect(
      result.canStartNormalUi,
      isTrue,
      reason: '${result.fatalError?.summary}: ${result.fatalError?.details}',
    );

    final migrated = openFileBackedDatabase(dbFile);
    addTearDown(migrated.close);
    final rows = migrated.select(
      "select id, session_id, message_count, is_pinned, is_archived, "
      "project_override, project_id, project_name_snapshot, archived_at_utc, "
      "archive_reason, eval_ready, eval_status, eval_notes, "
      "eval_expected_output, eval_reviewed_at_utc, eval_updated_at_utc "
      "from sessions where session_id = "
      "'duplicate-session'",
    );
    expect(rows, hasLength(1));
    expect(rows.single['id'], 'session:duplicate-session');
    expect(rows.single['message_count'], 30);
    expect(rows.single['is_pinned'], 1);
    expect(rows.single['is_archived'], 1);
    expect(rows.single['project_override'], 1);
    expect(rows.single['project_id'], 3);
    expect(rows.single['project_name_snapshot'], 'Manual Project');
    expect(rows.single['archived_at_utc'], '2026-07-07T10:03:00Z');
    expect(rows.single['archive_reason'], 'archived duplicate');
    expect(rows.single['eval_ready'], 1);
    expect(rows.single['eval_status'], 'correct');
    expect(rows.single['eval_notes'], 'needs review');
    expect(rows.single['eval_expected_output'], 'expected answer');
    expect(rows.single['eval_reviewed_at_utc'], '2026-07-07T10:04:00Z');
    expect(rows.single['eval_updated_at_utc'], '2026-07-07T10:05:00Z');
    expect(
      migrated
          .select(
            "select count(*) as count from messages where session_id = "
            "'session:duplicate-session'",
          )
          .single['count'],
      1,
    );
    expect(
      migrated
          .select(
            "select count(*) as count from session_tags where session_id = "
            "'session:duplicate-session'",
          )
          .single['count'],
      1,
    );
    expect(
      migrated
          .select(
            "select count(*) as count from session_path_keys where session_id = "
            "'session:duplicate-session'",
          )
          .single['count'],
      1,
    );
  });

  test('source fallback identity prefers source file path', () async {
    final sqlRoot = await _copySqlRoot(tempDir);
    final db = openFileBackedDatabase(dbFile);
    for (final path in [
      ['init', '001_initial_schema.sql'],
      ['migration', '002_search_filter_schema.sql'],
      ['migration', '003_project_override.sql'],
      ['migration', '004_session_token_buckets.sql'],
      ['migration', '005_scan_run_status.sql'],
      ['migration', '006_session_origin.sql'],
      ['migration', '007_session_thread_name.sql'],
      ['migration', '008_local_eval_metadata.sql'],
      ['migration', '009_message_search.sql'],
      ['migration', '010_session_id_lookup_index.sql'],
    ]) {
      await _applySqlFile(
        db,
        File(
          '${sqlRoot.path}${Platform.pathSeparator}${path[0]}'
          '${Platform.pathSeparator}${path[1]}',
        ),
      );
    }
    db.execute('''
      insert into sessions (
        id,
        source_type,
        source_file_path,
        source_file_unc_path,
        display_path,
        platform_path,
        created_at_utc,
        updated_at_utc
      ) values (
        'source-snapshot',
        'wsl',
        '/home/pawel/.codex/sessions/source.jsonl',
        '\\\\wsl.localhost\\Ubuntu\\home\\pawel\\.codex\\sessions\\source.jsonl',
        '/home/pawel/.codex/sessions/source.jsonl',
        '/home/pawel/.codex/sessions/source.jsonl',
        '2026-07-07T10:00:00Z',
        '2026-07-07T10:00:00Z'
      )
      ''');
    db.close();

    final result = await DatabaseMigrator(
      sqlRoot: sqlRoot,
    ).openAndMigrate(dbFile);
    expect(result.canStartNormalUi, isTrue, reason: result.fatalError?.summary);

    final migrated = openFileBackedDatabase(dbFile);
    addTearDown(migrated.close);
    expect(
      migrated.select('select id from sessions').single['id'],
      'source:/home/pawel/.codex/sessions/source.jsonl',
    );
  });

  test('rolls back failed migrations and records failure metadata', () async {
    final sqlRoot = Directory(
      '${tempDir.path}${Platform.pathSeparator}bad_sql',
    );
    final initDir = Directory('${sqlRoot.path}${Platform.pathSeparator}init');
    await initDir.create(recursive: true);
    await File(
      '${initDir.path}${Platform.pathSeparator}001_bad.sql',
    ).writeAsString('create table broken (id integer primary key;');

    final result = await DatabaseMigrator(
      sqlRoot: sqlRoot,
    ).openAndMigrate(dbFile);

    expect(result.canStartNormalUi, isFalse);
    expect(result.fatalError?.summary, contains('migration failed'));
    expect(result.fatalError?.failingMigrationFile, '001_bad.sql');

    final db = openFileBackedDatabase(dbFile);
    addTearDown(db.close);
    expect(_tableExists(db, 'broken'), isFalse);
    final rows = db.select(
      'select version, filename, success, error_message from schema_version',
    );
    expect(rows.length, 1);
    expect(rows.first['version'], 1);
    expect(rows.first['filename'], '001_bad.sql');
    expect(rows.first['success'], 0);
    expect(rows.first['error_message'], isNotNull);
  });
}

bool _tableExists(Database db, String tableName) {
  final result = db.select(
    "select 1 from sqlite_master where name = ? and type in ('table', 'view')",
    [tableName],
  );
  return result.isNotEmpty;
}

bool _columnExists(Database db, String tableName, String columnName) {
  final result = db.select('pragma table_info($tableName)');
  return result.any((row) => row['name'] == columnName);
}

bool _indexExists(Database db, String indexName) {
  final result = db.select(
    "select 1 from sqlite_master where name = ? and type = 'index'",
    [indexName],
  );
  return result.isNotEmpty;
}

void _expectPersistedUsageSchema(Database db) {
  const expectedColumns = <String, List<String>>{
    'database_generations': [
      'id',
      'source_schema_version',
      'target_schema_version',
      'source_fingerprint',
      'state',
      'created_at_utc',
      'activated_at_utc',
      'completed_at_utc',
      'validation_report_json',
      'error_message',
    ],
    'database_state': [
      'id',
      'active_usage_generation_id',
      'last_optimized_schema_version',
      'project_rules_version',
      'pricing_settings_revision',
      'pricing_policy_json',
      'normal_writes_resumed_at_utc',
      'updated_at_utc',
    ],
    'maintenance_jobs': [
      'id',
      'job_type',
      'database_generation_id',
      'state',
      'phase',
      'completed_units',
      'total_units',
      'last_processed_rowid',
      'status_message',
      'run_token',
      'owner_process_id',
      'heartbeat_at_utc',
      'lease_expires_at_utc',
      'attempt_count',
      'started_at_utc',
      'updated_at_utc',
      'finished_at_utc',
      'error_message',
      'payload_json',
      'created_at_utc',
    ],
    'maintenance_schedules': [
      'job_type',
      'enabled',
      'interval_seconds',
      'last_attempt_at_utc',
      'last_success_at_utc',
      'next_due_at_utc',
      'retry_count',
      'last_error',
      'updated_at_utc',
    ],
    'usage_path_contexts': [
      'id',
      'display_path_raw',
      'platform_path_raw',
      'unc_path_raw',
      'display_path_key',
      'platform_path_key',
      'unc_path_key',
      'normalization_version',
      'detected_project_id',
      'detected_project_source',
      'mask_project_id',
      'effective_project_id',
      'resolution_source',
      'project_rules_version',
      'created_at_utc',
      'updated_at_utc',
    ],
    'usage_events_next': [
      'session_row_id',
      'source_record_ordinal',
      'rollout_ordinal',
      'turn_ordinal',
      'epoch',
      'occurred_at_utc',
      'model',
      'path_context_id',
      'input_tokens',
      'cached_input_tokens',
      'cache_write_input_tokens',
      'output_tokens',
      'reasoning_output_tokens',
      'total_tokens',
      'branch_scope',
      'derivation',
      'event_fingerprint',
    ],
    'price_catalog_snapshots': [
      'id',
      'source',
      'started_at_utc',
      'finished_at_utc',
      'status',
      'http_status',
      'model_count',
      'declared_total_count',
      'page_count',
      'completeness_status',
      'catalog_generation',
      'payload_sha256',
      'error_message',
      'canonical_revision',
    ],
    'model_price_periods': [
      'id',
      'source',
      'model_id',
      'canonical_slug',
      'model_name',
      'provider',
      'prompt_price_per_token',
      'completion_price_per_token',
      'input_cache_read_price_per_token',
      'input_cache_write_price_per_token',
      'internal_reasoning_price_per_token',
      'request_price',
      'image_price',
      'web_search_price',
      'additional_prices_json',
      'pricing_fingerprint',
      'raw_pricing_json',
      'valid_from_utc',
      'valid_to_utc',
      'first_snapshot_id',
      'last_seen_snapshot_id',
    ],
    'provider_price_rules': [
      'id',
      'price_period_id',
      'provider_order',
      'prompt_tokens_min',
      'utc_start_minute',
      'utc_end_minute',
      'utc_weekdays',
      'prompt_price_per_token',
      'completion_price_per_token',
      'input_cache_read_price_per_token',
      'input_cache_write_price_per_token',
      'internal_reasoning_price_per_token',
      'request_price',
      'image_price',
      'web_search_price',
      'additional_prices_json',
      'pricing_fingerprint',
      'raw_rule_json',
    ],
    'local_price_override_periods': [
      'id',
      'model_id',
      'prompt_price_per_token',
      'completion_price_per_token',
      'input_cache_read_price_per_token',
      'input_cache_write_price_per_token',
      'internal_reasoning_price_per_token',
      'request_price',
      'image_price',
      'web_search_price',
      'settings_fingerprint',
      'valid_from_utc',
      'valid_to_utc',
      'first_settings_revision',
      'last_seen_settings_revision',
    ],
    'usage_path_context_aliases': [
      'path_context_id',
      'display_path_raw',
      'platform_path_raw',
      'unc_path_raw',
    ],
    'usage_context_project_candidates': [
      'generation_id',
      'path_context_id',
      'historical_project_id',
      'project_name_snapshot',
      'event_count',
      'malformed_timestamp_count',
      'latest_event_epoch_us',
      'latest_event_time_raw',
      'latest_source_rowid',
      'latest_session_id_snapshot',
      'latest_source_record_ordinal',
    ],
    'usage_session_daily': [
      'id',
      'session_id',
      'day_utc',
      'model_key',
      'path_context_id',
      'branch_scope',
      'input_tokens',
      'cached_input_tokens',
      'cache_write_input_tokens',
      'output_tokens',
      'reasoning_output_tokens',
      'total_tokens',
      'estimated_cost_text',
      'cost_status',
      'provider_price_period_id',
      'provider_rule_ids_json',
      'local_override_period_id',
      'pricing_resolution_method',
      'pricing_catalog_snapshot_id',
      'cost_projection_version',
      'updated_at_utc',
    ],
    'usage_cost_dirty_partitions': [
      'session_id',
      'day_utc',
      'model_key',
      'reason',
      'target_cost_projection_version',
      'created_at_utc',
      'updated_at_utc',
    ],
  };
  for (final MapEntry(key: table, value: columns) in expectedColumns.entries) {
    expect(_tableExists(db, table), isTrue, reason: '$table should exist');
    expect(
      db.select('pragma table_info($table)').map((row) => row['name']).toList(),
      columns,
      reason: '$table columns should match the version-16 contract',
    );
  }

  final generation = db.select('''
        select g.state, s.active_usage_generation_id
        from database_state s
        join database_generations g
          on g.id = s.active_usage_generation_id
        where s.id = 1
        ''').single;
  expect(generation['state'], 'legacy');
  expect(generation['active_usage_generation_id'], isNotNull);

  for (final index in [
    'idx_maintenance_jobs_active_type',
    'idx_maintenance_jobs_running',
    'idx_usage_path_contexts_identity',
    'idx_project_path_masks_identity',
    'idx_usage_session_daily_basis',
    'idx_usage_session_daily_billable_day',
    'idx_usage_session_daily_model_day',
    'idx_model_price_period_current',
    'idx_model_price_period_start',
    'idx_provider_price_rules_period_order',
    'idx_local_price_override_current',
    'idx_local_price_override_start',
    'idx_usage_cost_dirty_worker',
  ]) {
    expect(_indexExists(db, index), isTrue, reason: '$index should exist');
  }
  expect(_indexExists(db, 'idx_usage_session_daily_session'), isFalse);
  expect(_indexExists(db, 'idx_model_price_period_lookup'), isFalse);
  for (final obsolete in [
    'idx_maintenance_jobs_state_updated',
    'idx_price_catalog_snapshots_source_finished',
    'idx_session_cache_repair_manifest_category',
    'idx_messages_session',
    'idx_sessions_thread_source',
    'idx_sessions_source_state',
    'idx_sessions_thread_name',
  ]) {
    expect(
      _indexExists(db, obsolete),
      isFalse,
      reason: '$obsolete has no independent production query benefit',
    );
  }
  expect(_columnExists(db, 'sessions', 'detected_project_id'), isTrue);
  expect(
    _columnExists(db, 'database_state', 'last_optimized_schema_version'),
    isTrue,
  );
  expect(_columnExists(db, 'database_generations', 'completed_at_utc'), isTrue);
  expect(_columnExists(db, 'database_generations', 'error_message'), isTrue);
  expect(
    _schemaSql(db, 'index', 'idx_maintenance_jobs_active_type'),
    contains("where state in ('pending', 'running')"),
  );
  expect(
    _schemaSql(db, 'index', 'idx_usage_session_daily_basis'),
    allOf(
      contains('ifnull(provider_price_period_id, 0)'),
      contains('provider_rule_ids_json'),
      contains('ifnull(local_override_period_id, 0)'),
    ),
  );
  expect(
    _schemaSql(db, 'index', 'idx_usage_session_daily_billable_day'),
    contains("where branch_scope = 'local'"),
  );

  final contextProjectForeignKeys = db
      .select('pragma foreign_key_list(usage_path_contexts)')
      .where(
        (row) => const {
          'detected_project_id',
          'mask_project_id',
          'effective_project_id',
        }.contains(row['from']),
      );
  expect(contextProjectForeignKeys, hasLength(3));
  expect(
    contextProjectForeignKeys.every(
      (row) => (row['on_delete'] as String).toLowerCase() == 'set null',
    ),
    isTrue,
  );

  final sessionForeignKey = db
      .select('pragma foreign_key_list(usage_session_daily)')
      .singleWhere((row) => row['from'] == 'session_id');
  expect((sessionForeignKey['on_delete'] as String).toLowerCase(), 'cascade');
  final contextForeignKey = db
      .select('pragma foreign_key_list(usage_events_next)')
      .singleWhere((row) => row['from'] == 'path_context_id');
  expect(contextForeignKey['table'], 'usage_path_contexts');

  expect(
    () => db.execute(
      '''
      insert into maintenance_jobs (
        job_type, state, phase, completed_units, attempt_count,
        created_at_utc, updated_at_utc
      ) values ('usage_migration', 'pending', 'preflight', 0, 0, ?, ?)
      ''',
      ['2026-09-04T08:00:00Z', '2026-09-04T08:00:00Z'],
    ),
    returnsNormally,
  );
  expect(
    () => db.execute(
      '''
      insert into maintenance_jobs (
        job_type, state, phase, completed_units, attempt_count,
        created_at_utc, updated_at_utc
      ) values ('usage_migration', 'running', 'copy', 0, 1, ?, ?)
      ''',
      ['2026-09-04T08:01:00Z', '2026-09-04T08:01:00Z'],
    ),
    throwsA(isA<SqliteException>()),
  );

  expect(
    () => db.execute(
      '''
      insert into usage_path_contexts (
        display_path_raw, platform_path_raw, unc_path_raw,
        display_path_key, platform_path_key, unc_path_key,
        normalization_version, resolution_source, project_rules_version,
        created_at_utc, updated_at_utc
      ) values ('', '', '', '', '', '', 1, 'unassigned', 1, ?, ?)
      ''',
      ['2026-09-04T08:00:00Z', '2026-09-04T08:00:00Z'],
    ),
    throwsA(isA<SqliteException>()),
    reason: 'the all-empty sentinel context is inserted by the migration',
  );

  db.execute(
    '''
    insert into price_catalog_snapshots (
      source, started_at_utc, finished_at_utc, status, model_count,
      page_count, completeness_status
    ) values ('openrouter', ?, ?, 'succeeded', 1, 1, 'complete_for_updates')
    ''',
    ['2026-09-04T08:00:00Z', '2026-09-04T08:00:01Z'],
  );
  final snapshotId = db.lastInsertRowId;

  expect(
    () => db.execute(
      '''
        insert into model_price_periods (
          source, model_id, provider, pricing_fingerprint, raw_pricing_json,
          valid_from_utc, valid_to_utc, first_snapshot_id,
          last_seen_snapshot_id
        ) values ('openrouter', 'invalid', 'provider', 'hash', '{}',
                  '2026-09-04T09:00:00Z', '2026-09-04T08:00:00Z', ?, ?)
        ''',
      [snapshotId, snapshotId],
    ),
    throwsA(isA<SqliteException>()),
  );

  db.execute(
    '''
    insert into model_price_periods (
      source, model_id, provider, pricing_fingerprint, raw_pricing_json,
      valid_from_utc, first_snapshot_id, last_seen_snapshot_id
    ) values ('openrouter', 'model', 'provider', 'provider-hash', '{}', ?, ?, ?)
    ''',
    ['2026-09-04T08:00:00Z', snapshotId, snapshotId],
  );
  final providerPeriodId = db.lastInsertRowId;
  expect(
    () => db.execute(
      '''
      insert into model_price_periods (
        source, model_id, provider, pricing_fingerprint, raw_pricing_json,
        valid_from_utc, valid_to_utc, first_snapshot_id, last_seen_snapshot_id
      ) values ('openrouter', 'model', 'provider', 'overlap', '{}', ?, ?, ?, ?)
      ''',
      ['2026-09-04T08:30:00Z', '2026-09-04T08:45:00Z', snapshotId, snapshotId],
    ),
    throwsA(isA<SqliteException>()),
    reason: 'provider price periods cannot overlap',
  );
  db.execute('update model_price_periods set valid_to_utc = ? where id = ?', [
    '2026-09-04T09:00:00Z',
    providerPeriodId,
  ]);
  db.execute(
    '''
    insert into model_price_periods (
      source, model_id, provider, pricing_fingerprint, raw_pricing_json,
      valid_from_utc, first_snapshot_id, last_seen_snapshot_id
    ) values ('openrouter', 'model', 'provider', 'next-hash', '{}', ?, ?, ?)
    ''',
    ['2026-09-04T09:00:00Z', snapshotId, snapshotId],
  );
  final nextProviderPeriodId = db.lastInsertRowId;
  expect(
    () => db.execute(
      'update model_price_periods set valid_from_utc = ? where id = ?',
      ['2026-09-04T08:59:00Z', nextProviderPeriodId],
    ),
    throwsA(isA<SqliteException>()),
    reason: 'provider price period updates cannot create overlaps',
  );
  db.execute(
    '''
    insert into provider_price_rules (
      price_period_id, provider_order, pricing_fingerprint, raw_rule_json
    ) values (?, 0, 'rule-hash', '{}')
    ''',
    [providerPeriodId],
  );
  final providerRuleId = db.lastInsertRowId;
  db.execute(
    '''
    insert into local_price_override_periods (
      model_id, prompt_price_per_token, settings_fingerprint,
      valid_from_utc, first_settings_revision, last_seen_settings_revision
    ) values ('model', '0.000001', 'local-hash', ?, 1, 1)
    ''',
    ['2026-09-04T08:00:00Z'],
  );
  final localPeriodId = db.lastInsertRowId;
  expect(
    () => db.execute(
      '''
      insert into local_price_override_periods (
        model_id, prompt_price_per_token, settings_fingerprint,
        valid_from_utc, valid_to_utc,
        first_settings_revision, last_seen_settings_revision
      ) values ('model', '0.000002', 'local-overlap', ?, ?, 2, 2)
      ''',
      ['2026-09-04T08:30:00Z', '2026-09-04T08:45:00Z'],
    ),
    throwsA(isA<SqliteException>()),
    reason: 'local override periods cannot overlap',
  );
  db.execute(
    'update local_price_override_periods set valid_to_utc = ? where id = ?',
    ['2026-09-04T09:00:00Z', localPeriodId],
  );
  db.execute(
    '''
    insert into local_price_override_periods (
      model_id, prompt_price_per_token, settings_fingerprint,
      valid_from_utc, first_settings_revision, last_seen_settings_revision
    ) values ('model', '0.000002', 'local-next', ?, 2, 2)
    ''',
    ['2026-09-04T09:00:00Z'],
  );
  final nextLocalPeriodId = db.lastInsertRowId;
  expect(
    () => db.execute(
      'update local_price_override_periods set valid_from_utc = ? where id = ?',
      ['2026-09-04T08:59:00Z', nextLocalPeriodId],
    ),
    throwsA(isA<SqliteException>()),
    reason: 'local override updates cannot create overlaps',
  );

  db.execute(
    '''
    insert into sessions (
      id, source_type, source_file_path, display_path, platform_path,
      created_at_utc, updated_at_utc
    ) values ('projection-session', 'windows', 'projection.jsonl',
              'projection.jsonl', 'projection.jsonl', ?, ?)
    ''',
    ['2026-09-04T08:00:00Z', '2026-09-04T08:00:00Z'],
  );
  final sentinelContextId =
      db.select('''
        select id from usage_path_contexts
        where normalization_version = 1
          and display_path_key = ''
          and platform_path_key = ''
          and unc_path_key = ''
        ''').single['id']
          as int;

  expect(
    () => db.execute(
      '''
      insert into usage_session_daily (
        session_id, day_utc, model_key, path_context_id, branch_scope,
        input_tokens, cached_input_tokens, cache_write_input_tokens,
        output_tokens, reasoning_output_tokens, total_tokens,
        estimated_cost_text, cost_status, provider_price_period_id,
        pricing_resolution_method, pricing_catalog_snapshot_id,
        cost_projection_version, updated_at_utc
      ) values ('projection-session', '2026-09-04', 'known-basis', ?, 'local',
                1, 0, 0, 0, 0, 1, null, 'unknown', ?, 'provider', ?, 1, ?)
      ''',
      [
        sentinelContextId,
        nextProviderPeriodId,
        snapshotId,
        '2026-09-04T09:00:00Z',
      ],
    ),
    returnsNormally,
    reason: 'unknown cost retains its resolved historical price basis',
  );

  expect(
    () => db.execute(
      '''
      insert into usage_session_daily (
        session_id, day_utc, model_key, path_context_id, branch_scope,
        input_tokens, cached_input_tokens, cache_write_input_tokens,
        output_tokens, reasoning_output_tokens, total_tokens,
        estimated_cost_text, cost_status, provider_price_period_id,
        provider_rule_ids_json, pricing_resolution_method,
        pricing_catalog_snapshot_id, cost_projection_version, updated_at_utc
      ) values ('projection-session', '2026-09-04', 'mismatched-rule', ?,
                'local', 1, 0, 0, 0, 0, 1, '0.000001', 'complete', ?, ?,
                'provider_rule', ?, 1, ?)
      ''',
      [
        sentinelContextId,
        nextProviderPeriodId,
        '[$providerRuleId]',
        snapshotId,
        '2026-09-04T09:00:00Z',
      ],
    ),
    throwsA(isA<SqliteException>()),
    reason: 'the recorded provider rule must belong to the recorded period',
  );

  db.execute(
    '''
    insert into usage_session_daily (
      session_id, day_utc, model_key, path_context_id, branch_scope,
      input_tokens, cached_input_tokens, cache_write_input_tokens,
      output_tokens, reasoning_output_tokens, total_tokens,
      estimated_cost_text, cost_status, provider_price_period_id,
      provider_rule_ids_json, pricing_resolution_method,
      pricing_catalog_snapshot_id, cost_projection_version, updated_at_utc
    ) values ('projection-session', '2026-09-04', 'rule-reference', ?,
              'local', 1, 0, 0, 0, 0, 1, '0.000001', 'complete', ?, ?,
              'provider_rule', ?, 1, ?)
    ''',
    [
      sentinelContextId,
      providerPeriodId,
      '[$providerRuleId]',
      snapshotId,
      '2026-09-04T08:30:00Z',
    ],
  );
  expect(
    () => db.execute(
      'update provider_price_rules set price_period_id = ? where id = ?',
      [nextProviderPeriodId, providerRuleId],
    ),
    throwsA(isA<SqliteException>()),
    reason: 'provider price rules are immutable historical basis records',
  );
  db.execute(
    '''
    insert into provider_price_rules (
      price_period_id, provider_order, pricing_fingerprint, raw_rule_json
    ) values (?, 1, 'second-rule', '{}')
  ''',
    [providerPeriodId],
  );
  final secondRuleId = db.lastInsertRowId;
  void updateBasis(String basis) => db.execute(
    '''
    update usage_session_daily set provider_rule_ids_json = ?
    where model_key = 'rule-reference'
  ''',
    [basis],
  );
  for (final invalid in [
    '[999999]',
    '[$providerRuleId,$providerRuleId]',
    '[$secondRuleId,$providerRuleId]',
    '["$providerRuleId"]',
    '[$providerRuleId.0]',
    '[0]',
    '[-1]',
    '{}',
    'null',
    'not-json',
    '[$providerRuleId, $secondRuleId]',
  ]) {
    expect(
      () => updateBasis(invalid),
      throwsA(isA<SqliteException>()),
      reason:
          'basis must be a canonical ordered set of valid period rule IDs: $invalid',
    );
  }
  updateBasis('[$providerRuleId,$secondRuleId]');
  expect(
    () => db.execute('delete from provider_price_rules where id = ?', [
      secondRuleId,
    ]),
    throwsA(isA<SqliteException>()),
    reason: 'historical rule evidence cannot be deleted while referenced',
  );
  updateBasis('[$providerRuleId]');
  db.execute('delete from provider_price_rules where id = ?', [secondRuleId]);

  expect(
    () => db.execute(
      '''
      insert into usage_session_daily (
        session_id, day_utc, model_key, path_context_id, branch_scope,
        input_tokens, cached_input_tokens, cache_write_input_tokens,
        output_tokens, reasoning_output_tokens, total_tokens,
        estimated_cost_text, cost_status, pricing_resolution_method,
        cost_projection_version, updated_at_utc
      ) values ('projection-session', '2026-09-04', '', ?, 'local',
                -1, 0, 0, 0, 0, 0, null, 'unknown', 'unknown', 1, ?)
      ''',
      [sentinelContextId, '2026-09-04T08:00:00Z'],
    ),
    throwsA(isA<SqliteException>()),
  );

  expect(
    () => db.execute(
      '''
      insert into usage_session_daily (
        session_id, day_utc, model_key, path_context_id, branch_scope,
        input_tokens, cached_input_tokens, cache_write_input_tokens,
        output_tokens, reasoning_output_tokens, total_tokens,
        estimated_cost_text, cost_status, provider_price_period_id,
        local_override_period_id, pricing_resolution_method,
        pricing_catalog_snapshot_id, cost_projection_version, updated_at_utc
      ) values ('projection-session', '2026-09-04', 'model', ?, 'local',
                1, 0, 0, 0, 0, 1, '0.000001', 'complete', ?, ?,
                'provider', ?, 1, ?)
      ''',
      [
        sentinelContextId,
        providerPeriodId,
        localPeriodId,
        snapshotId,
        '2026-09-04T08:00:00Z',
      ],
    ),
    throwsA(isA<SqliteException>()),
    reason: 'provider and local price bases are mutually exclusive',
  );

  db.execute(
    '''
    insert into usage_session_daily (
      session_id, day_utc, model_key, path_context_id, branch_scope,
      input_tokens, cached_input_tokens, cache_write_input_tokens,
      output_tokens, reasoning_output_tokens, total_tokens,
      estimated_cost_text, cost_status, pricing_resolution_method,
      cost_projection_version, updated_at_utc
    ) values ('projection-session', '2026-09-04', '', ?, 'local',
              1, 0, 0, 0, 0, 1, null, 'unknown', 'unknown', 1, ?)
    ''',
    [sentinelContextId, '2026-09-04T08:00:00Z'],
  );
  expect(
    () => db.execute(
      '''
      insert into usage_session_daily (
        session_id, day_utc, model_key, path_context_id, branch_scope,
        input_tokens, cached_input_tokens, cache_write_input_tokens,
        output_tokens, reasoning_output_tokens, total_tokens,
        estimated_cost_text, cost_status, pricing_resolution_method,
        cost_projection_version, updated_at_utc
      ) values ('projection-session', '2026-09-04', '', ?, 'local',
                1, 0, 0, 0, 0, 1, null, 'unknown', 'unknown', 1, ?)
      ''',
      [sentinelContextId, '2026-09-04T08:01:00Z'],
    ),
    throwsA(isA<SqliteException>()),
  );

  db.execute(
    '''
    insert into usage_cost_dirty_partitions (
      session_id, day_utc, model_key, reason,
      target_cost_projection_version, created_at_utc, updated_at_utc
    ) values ('projection-session', '2026-09-04', '', 'algorithm', 2, ?, ?)
    ''',
    ['2026-09-04T08:00:00Z', '2026-09-04T08:00:00Z'],
  );
  db.execute("delete from sessions where id = 'projection-session'");
  expect(
    db
        .select('select count(*) as count from usage_session_daily')
        .single['count'],
    0,
  );
  expect(
    db
        .select('select count(*) as count from usage_cost_dirty_partitions')
        .single['count'],
    0,
  );
}

String _schemaSql(Database db, String type, String name) =>
    (db.select('select sql from sqlite_master where type = ? and name = ?', [
              type,
              name,
            ]).single['sql']
            as String)
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');

Future<Directory> _copySqlRoot(Directory tempDir) async {
  final target = Directory('${tempDir.path}${Platform.pathSeparator}sql');
  for (final folder in ['init', 'migration']) {
    final sourceDir = Directory('../sql/$folder');
    final targetDir = Directory(
      '${target.path}${Platform.pathSeparator}$folder',
    );
    await targetDir.create(recursive: true);
    await for (final entity in sourceDir.list()) {
      if (entity is File) {
        await entity.copy(
          '${targetDir.path}${Platform.pathSeparator}'
          '${entity.uri.pathSegments.last}',
        );
      }
    }
  }
  return target;
}

Future<void> _applySqlFile(Database db, File file) async {
  final filename = file.uri.pathSegments.last;
  final version = int.parse(filename.split('_').first);
  final sql = await file.readAsString();
  db.execute(sql);
  db.execute(
    '''
    insert into schema_version (
      version,
      filename,
      checksum,
      applied_at_utc,
      success,
      error_message
    ) values (?, ?, ?, ?, 1, null)
    ''',
    [
      version,
      filename,
      sha256.convert(utf8.encode(sql)).toString(),
      '2026-07-07T10:00:00.000Z',
    ],
  );
}
