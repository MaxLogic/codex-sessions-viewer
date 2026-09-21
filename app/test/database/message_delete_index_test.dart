import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final priorVersion in [15, 16]) {
    test(
      'deferred startup upgrades only a completed schema $priorVersion',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'csv_index_upgrade_',
        );
        addTearDown(() => temp.delete(recursive: true));
        final file = File('${temp.path}/viewer.sqlite');
        final old = await DatabaseMigrator(
          sqlRoot: Directory('../sql'),
          supportedSchemaVersion: priorVersion,
        ).openAndMigrate(file);
        expect(old.canStartNormalUi, isTrue);
        final result = await DatabaseMigrator(
          sqlRoot: Directory('../sql'),
        ).openAndMigrate(file, deferUsageMigration: true);
        expect(
          result.canStartNormalUi,
          isTrue,
          reason: result.fatalError?.details,
        );
        expect(result.lastAppliedSchemaVersion, priorVersion == 15 ? 15 : 17);
        if (priorVersion == 16) {
          final db = openFileBackedDatabase(file);
          try {
            expect(
              db
                  .select(
                    'select last_optimized_schema_version v from database_state',
                  )
                  .single['v'],
              17,
            );
          } finally {
            db.close();
          }
        }
      },
    );
  }
  test('message replacement uses an indexed foreign-key cascade', () async {
    final temp = await Directory.systemTemp.createTemp('csv_message_delete_');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/viewer.sqlite');
    final migrator = DatabaseMigrator(sqlRoot: Directory('../sql'));
    final result = await migrator.openAndMigrate(file);
    expect(result.canStartNormalUi, isTrue, reason: result.fatalError?.details);
    final db = openFileBackedDatabase(file);
    addTearDown(db.close);
    db.execute('''
      insert into sessions(id,source_type,source_file_path,display_path,
        platform_path,created_at_utc,updated_at_utc)
      values('s','windows','fixture','fixture','fixture','2026-01-01','2026-01-01');
      insert into messages(id,session_id,message_index,author_type,
        created_at_db_utc,updated_at_db_utc)
      values(1,'s',0,'user','2026-01-01','2026-01-01'),
            (2,'s',1,'assistant','2026-01-01','2026-01-01');
      insert into tool_calls(id,session_id,message_id,tool_index,tool_name,status)
      values(1,'s',1,0,'linked','complete'),
            (2,'s',2,1,'other','complete'),
            (3,'s',null,2,'unlinked','complete');
    ''');
    final plan = db
        .select('explain query plan delete from messages where id=?', [1])
        .map((row) => row['detail'])
        .join('\n');
    expect(
      plan,
      isNot(contains('SCAN tool_calls')),
      reason: 'Every deleted message must avoid scanning unrelated tool calls.',
    );
    expect(plan, contains('idx_tool_calls_message'));
    db.execute('delete from messages where id=?', [1]);
    expect(
      db
          .select('select id from tool_calls order by id')
          .map((row) => row['id']),
      [2, 3],
    );
    expect(db.select('pragma foreign_key_check'), isEmpty);
  });
}
