import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:flutter_test/flutter_test.dart';

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

  test('applies initial SQL schema and records migration metadata', () async {
    final result = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(dbFile);

    expect(result.canStartNormalUi, isTrue);
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
    ]) {
      expect(_tableExists(db, table), isTrue, reason: '$table should exist');
    }

    final versionRows = db.select(
      'select version, filename, length(checksum) as checksum_length, success '
      'from schema_version order by version',
    );
    expect(versionRows.length, 8);
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
    expect(_columnExists(db, 'sessions', 'eval_reviewed_at_utc'), isTrue);
    expect(_columnExists(db, 'sessions', 'eval_updated_at_utc'), isTrue);
  });

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
      expect(secondRun.fatalError?.lastAppliedSchemaVersion, 8);
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
    await copiedMigration.delete();
    await copiedProjectOverrideMigration.delete();
    final firstRun = await DatabaseMigrator(
      sqlRoot: sqlRoot,
    ).openAndMigrate(dbFile);
    expect(firstRun.canStartNormalUi, isTrue);

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

    final result = await DatabaseMigrator(
      sqlRoot: sqlRoot,
    ).openAndMigrate(dbFile);
    expect(result.canStartNormalUi, isTrue);

    final migrated = openFileBackedDatabase(dbFile);
    addTearDown(migrated.close);

    expect(
      migrated
          .select(
            'select s.id from sessions s join session_search f on f.rowid = s.rowid '
            "where session_search match 'user_messages: migrated'",
          )
          .single['id'],
      'existing',
    );
    final row = migrated.select(
      'select has_code_blocks, has_tool_calls, has_errors '
      'from sessions where id = ?',
      ['existing'],
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
      await copiedProjectOverrideMigration.delete();
      final firstRun = await DatabaseMigrator(
        sqlRoot: sqlRoot,
      ).openAndMigrate(dbFile);
      expect(firstRun.canStartNormalUi, isTrue);

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

      final result = await DatabaseMigrator(
        sqlRoot: sqlRoot,
      ).openAndMigrate(dbFile);
      expect(result.canStartNormalUi, isTrue);

      final migrated = openFileBackedDatabase(dbFile);
      addTearDown(migrated.close);
      expect(
        migrated.select('select project_override from sessions where id = ?', [
          'existing-project',
        ]).single['project_override'],
        1,
      );

      ProjectTagStateStore(migrated).recalculateSessionProjects();

      final row = migrated.select(
        'select project_id, project_name_snapshot from sessions where id = ?',
        ['existing-project'],
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
    ).openAndMigrate(dbFile);
    expect(firstRun.canStartNormalUi, isTrue);

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
    expect(result.canStartNormalUi, isTrue);

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
      expect(result.canStartNormalUi, isTrue);

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
    if (await evalMigration.exists()) {
      await evalMigration.delete();
    }
    final firstRun = await DatabaseMigrator(
      sqlRoot: sqlRoot,
    ).openAndMigrate(dbFile);
    expect(firstRun.canStartNormalUi, isTrue);

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

    final migrator = DatabaseMigrator(sqlRoot: sqlRoot);
    expect(migrator.supportedSchemaVersion, 8);
    final result = await migrator.openAndMigrate(dbFile);
    expect(result.canStartNormalUi, isTrue);
    expect(result.lastAppliedSchemaVersion, 8);

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
          ['eval-existing'],
        )
        .single;
    expect(row['eval_ready'], 0);
    expect(row['eval_status'], isNull);
    expect(row['eval_notes'], isNull);
    expect(row['eval_expected_output'], isNull);
    expect(row['eval_reviewed_at_utc'], isNull);
    expect(row['eval_updated_at_utc'], isNull);
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
