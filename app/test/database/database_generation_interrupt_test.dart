import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_generation.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance_cancelled.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

void main() {
  late Directory temp;
  late Database db;
  late DatabaseGenerationRepository generations;
  late int targetId;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('csv_generation_interrupt_');
    final file = File('${temp.path}/viewer.sqlite');
    final startup = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(file);
    expect(startup.canStartNormalUi, isTrue);
    db = openFileBackedDatabase(file, maintenanceWriter: true);
    generations = DatabaseGenerationRepository(db);
    targetId = generations
        .createBuilding(
          sourceSchemaVersion: 15,
          targetSchemaVersion: 16,
          sourceFingerprint: 'verified-test-source',
        )
        .id;
    generations.markReady(targetId, validationReportJson: '{}');
  });

  tearDown(() async {
    db.close();
    await temp.delete(recursive: true);
  });

  Object snapshot() => [
    for (final sql in [
      '''select name, type, sql from sqlite_schema
         where name in ('usage_events', 'usage_events_next',
           'usage_events_legacy', 'billable_usage_events') order by name''',
      'select * from database_state order by id',
      'select * from database_generations order by id',
    ])
      db.select(sql).map((row) => Map<String, Object?>.from(row)).toList(),
  ];

  test('cancelled activation restores storage and pointer before retry', () async {
    final before = snapshot();
    var changedInsideSection = false;
    await expectLater(
      generations.activateInterruptibly(
        targetId,
        runAtomic: (action) async {
          action();
          changedInsideSection =
              generations.activeGeneration().id == targetId &&
              db
                  .select(
                    "select name from sqlite_schema where name = 'usage_events_legacy'",
                  )
                  .isNotEmpty &&
              db
                  .select("pragma table_info('billable_usage_events')")
                  .any((row) => row['name'] == 'path_context_id');
          // The section has finished and disarmed; cancellation arrives before
          // the adapter may commit. This is the production runAtomic contract.
          throw const DatabaseMaintenanceCancelled();
        },
      ),
      throwsA(isA<DatabaseMaintenanceCancelled>()),
    );
    expect(changedInsideSection, isTrue);
    expect(snapshot(), before);
    expect(db.autocommit, isTrue);
    expect(db.select('pragma foreign_key_check'), isEmpty);

    await generations.activateInterruptibly(
      targetId,
      runAtomic: (action) async {
        expect(
          db.autocommit,
          isFalse,
          reason: 'BEGIN belongs outside the section.',
        );
        action();
        expect(
          db.autocommit,
          isFalse,
          reason: 'COMMIT belongs after disarmed exit.',
        );
      },
    );
    expect(db.autocommit, isTrue);
    expect(generations.activeGeneration().id, targetId);
    expect(
      db.select(
        "select name from sqlite_schema where name = 'usage_events_next'",
      ),
      isEmpty,
    );
    expect(
      db.select("pragma table_info('usage_events')").map((row) => row['name']),
      contains('path_context_id'),
    );
    expect(db.select('pragma integrity_check').single.values.single, 'ok');
  });

  test(
    'activation SQL failure rolls back after the section has exited',
    () async {
      final before = snapshot();
      db.execute('''
      create trigger reject_activation before update on database_state
      begin select raise(abort, 'injected pointer failure'); end
    ''');
      var sectionExited = false;
      await expectLater(
        generations.activateInterruptibly(
          targetId,
          runAtomic: (action) async {
            try {
              action();
            } finally {
              expect(
                db.autocommit,
                isFalse,
                reason: 'Recovery must wait until the interrupt section exits.',
              );
              sectionExited = true;
            }
          },
        ),
        throwsA(
          isA<SqliteException>().having(
            (error) => error.message,
            'original failure',
            contains('injected pointer failure'),
          ),
        ),
      );
      expect(sectionExited, isTrue);
      expect(db.autocommit, isTrue);
      expect(snapshot(), before);
      expect(db.select('pragma foreign_key_check'), isEmpty);
      db.execute('drop trigger reject_activation');
      // The synchronous entrypoint shares the same cutover body and still works.
      generations.activate(targetId);
      expect(generations.activeGeneration().id, targetId);
    },
  );
}
