import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show sqlite3;

void main() {
  late Directory temp;
  late File file;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('csv_optimize_');
    file = File('${temp.path}/viewer.sqlite');
  });
  tearDown(() async => temp.delete(recursive: true));

  test('each committed migration is optimized before the next migration', () async {
    final root = Directory('${temp.path}/sql');
    var lastFixtureVersion = 0;
    for (final folder in ['init', 'migration']) {
      await Directory('${root.path}/$folder').create(recursive: true);
      for (final source in Directory(
        '../sql/$folder',
      ).listSync().whereType<File>()) {
        if (source.path.endsWith('.sql')) {
          final version = int.parse(
            source.uri.pathSegments.last.split('_').first,
          );
          if (version > lastFixtureVersion) lastFixtureVersion = version;
          await source.copy(
            '${root.path}/$folder/${source.uri.pathSegments.last}',
          );
        }
      }
    }
    final probeVersion = lastFixtureVersion + 1;
    final auditVersion = probeVersion + 1;
    await File(
      '${root.path}/migration/${probeVersion.toString().padLeft(3, '0')}_optimize_probe.sql',
    ).writeAsString('''
      create table optimize_probe (id integer primary key, value integer);
      create index idx_optimize_probe_value on optimize_probe(value);
      with recursive n(i) as (select 1 union all select i + 1 from n where i < 1000)
      insert into optimize_probe select i, i % 100 from n;
      select count(*) from optimize_probe where value = 42;
    ''');
    await File(
      '${root.path}/migration/${auditVersion.toString().padLeft(3, '0')}_optimize_audit.sql',
    ).writeAsString('''
      create table optimize_steps as select
        (select last_optimized_schema_version from database_state) previous_version,
        (select stat from sqlite_stat1 where idx = 'idx_optimize_probe_value') previous_stats;
    ''');
    final result = await DatabaseMigrator(
      sqlRoot: root,
      supportedSchemaVersion: auditVersion,
    ).openAndMigrate(file);
    expect(result.canStartNormalUi, isTrue, reason: result.fatalError?.details);
    final db = openFileBackedDatabase(file);
    addTearDown(db.close);
    final step = db.select('select * from optimize_steps').single;
    expect(step['previous_version'], probeVersion);
    expect(step['previous_stats'], '1000 10');
    expect(
      db
          .select(
            'explain query plan select id from optimize_probe where value = 42',
          )
          .single['detail'],
      contains('idx_optimize_probe_value'),
    );
    expect(
      db
          .select('select last_optimized_schema_version v from database_state')
          .single['v'],
      auditVersion,
    );
  });

  test(
    'migration optimization advances its durable watermark and recovers failure',
    () async {
      // SQLite 3.46 introduced the bounded modern optimize behavior we require.
      expect(sqlite3.version.versionNumber, greaterThanOrEqualTo(3046000));
      final migrator = DatabaseMigrator(sqlRoot: Directory('../sql'));
      expect((await migrator.openAndMigrate(file)).canStartNormalUi, isTrue);
      var db = openFileBackedDatabase(file);
      try {
        expect(
          db
              .select(
                'select last_optimized_schema_version v from database_state',
              )
              .single['v'],
          latestSchemaVersion,
        );
        db.execute('''
      update database_state set last_optimized_schema_version = 15;
      create trigger fail_optimize_watermark before update of last_optimized_schema_version on database_state
      begin select raise(abort, 'injected watermark failure'); end;
      ''');
      } finally {
        db.close();
      }
      // Failure must not undo, or relabel, a committed schema migration.
      expect((await migrator.openAndMigrate(file)).canStartNormalUi, isTrue);
      db = openFileBackedDatabase(file);
      try {
        expect(
          db
              .select('select success from schema_version where version = 16')
              .single['success'],
          1,
        );
        expect(
          db
              .select(
                'select last_optimized_schema_version v from database_state',
              )
              .single['v'],
          15,
        );
        expect(
          db
              .select(
                "select last_error from maintenance_schedules where job_type = 'database_optimize'",
              )
              .single['last_error'],
          isNotEmpty,
        );
        db.execute('drop trigger fail_optimize_watermark');
      } finally {
        db.close();
      }
      expect((await migrator.openAndMigrate(file)).canStartNormalUi, isTrue);
      db = openFileBackedDatabase(file);
      addTearDown(db.close);
      expect(
        db
            .select(
              'select last_optimized_schema_version v from database_state',
            )
            .single['v'],
        latestSchemaVersion,
      );
      expect(
        db
            .select(
              "select last_error from maintenance_schedules where job_type = 'database_optimize'",
            )
            .single['last_error'],
        isNull,
      );
    },
  );
}
