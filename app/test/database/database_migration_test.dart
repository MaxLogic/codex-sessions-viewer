import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:flutter_test/flutter_test.dart';
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

  test('applies initial SQL schema and records migration metadata', () async {
    final result = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(dbFile);

    expect(result.canStartNormalUi, isTrue);
    expect(result.fatalError, isNull);

    final db = sqlite3.open(dbFile.path);
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
    expect(versionRows.length, 1);
    expect(versionRows.first['version'], 1);
    expect(versionRows.first['filename'], '001_initial_schema.sql');
    expect(versionRows.first['checksum_length'], greaterThan(20));
    expect(versionRows.first['success'], 1);
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
      expect(secondRun.fatalError?.lastAppliedSchemaVersion, 1);
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

    final db = sqlite3.open(dbFile.path);
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
