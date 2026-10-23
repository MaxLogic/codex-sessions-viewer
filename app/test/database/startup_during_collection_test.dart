import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codex_sessions_viewer/src/scanner/resident_collector_client.dart';
import '../support/scripted_collector_bridge.dart';

void _hold((String, int, int, SendPort) args) {
  final (path, milliseconds, repeats, reply) = args;
  final db = openFileBackedDatabase(File(path), maintenanceWriter: true);
  try {
    for (var i = 0; i < repeats; i++) {
      db.execute('begin immediate');
      if (i == 0) reply.send('holding');
      sleep(Duration(milliseconds: milliseconds));
      db.execute('commit');
      sleep(const Duration(milliseconds: 150));
    }
  } finally {
    db.close();
    reply.send('done');
  }
}

void main() {
  test('up-to-date startup does not pause or connect collection', () async {
    final root = await Directory.systemTemp.createTemp('cxv184-current-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/viewer.sqlite');
    await DatabaseMigrator(sqlRoot: Directory('../sql')).openAndMigrate(file);
    var pauses = 0;
    final result = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
      pauseCollector: () async {
        pauses++;
        return CollectorPauseHandle(() async {});
      },
    ).openAndMigrate(file);
    expect(result.canStartNormalUi, isTrue);
    expect(pauses, 0);
  });

  test(
    'startup migration falls back to SQLite locking when pause has no ack',
    () async {
      final root = await Directory.systemTemp.createTemp('cxv184-no-ack-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/viewer.sqlite');
      final bridge = ScriptedBridge();
      int? schemaAtPause;
      bridge.onRequest = (request) {
        if (request['op'] != 'pause') return;
        final db = openFileBackedDatabase(file, maintenanceWriter: true);
        try {
          schemaAtPause =
              db
                      .select(
                        'select count(*) n from schema_version where success=1',
                      )
                      .single['n']
                  as int;
        } finally {
          db.close();
        }
      };
      final client = ResidentCollectorClient(
        databaseFile: file,
        settingsFile: File('${root.path}/settings.toml'),
        start: (_, _) async {
          bridge.emit({'event': 'bridge', 'state': 'connected'});
          return bridge;
        },
      );
      addTearDown(client.dispose);
      final wait = Stopwatch()..start();
      final pauseWait = Stopwatch();
      final result = await DatabaseMigrator(
        sqlRoot: Directory('../sql'),
        pauseCollector: () {
          pauseWait.start();
          return client.pause().whenComplete(pauseWait.stop);
        },
      ).openAndMigrate(file).timeout(const Duration(seconds: 15));
      expect(
        result.canStartNormalUi,
        isTrue,
        reason: result.fatalError?.details,
      );
      // The courtesy deadline covers connecting and waiting for the ack.
      // Discovery and all 30 SQL migrations also contribute to total startup.
      expect(pauseWait.isRunning, isFalse);
      expect(pauseWait.elapsed, lessThan(const Duration(seconds: 5)));
      expect(
        schemaAtPause,
        0,
        reason:
            'No schema migration may run before ack or the explicit locking fallback.',
      );
      expect(bridge.killed, isTrue);
      expect(bridge.received.map((r) => r['op']), ['pause']);
      // ignore: avoid_print
      print(
        'no_ack_pause_ms=${pauseWait.elapsedMilliseconds} startup_ms=${wait.elapsedMilliseconds} schema_migrations_at_pause=$schemaAtPause ready=true disconnected_pending_owner=true',
      );
    },
  );

  test('missing collection cannot block startup migration', () async {
    final root = await Directory.systemTemp.createTemp('cxv184-missing-');
    addTearDown(() => root.delete(recursive: true));
    final result = await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
      pauseCollector: () async => throw const CollectorDisconnectedException(),
    ).openAndMigrate(File('${root.path}/viewer.sqlite'));
    expect(result.canStartNormalUi, isTrue, reason: result.fatalError?.details);
  });

  test('startup releases the collector pause on migration failure', () async {
    final root = await Directory.systemTemp.createTemp(
      'cxv184-migration-pause-',
    );
    addTearDown(() => root.delete(recursive: true));
    var held = false;
    var released = false;
    final sql = await Directory(
      '${root.path}/sql/init',
    ).create(recursive: true);
    await File(
      '${sql.path}/001_invalid.sql',
    ).writeAsString('invalid migration sql;');
    final result = await DatabaseMigrator(
      sqlRoot: Directory('${root.path}/sql'),
      pauseCollector: () async {
        held = true;
        return CollectorPauseHandle(() async {
          released = true;
        });
      },
    ).openAndMigrate(File('${root.path}/viewer.sqlite'));
    expect(result.canStartNormalUi, isFalse);
    expect(held, isTrue);
    expect(released, isTrue);
  });

  for (final hold in [1000, 6000]) {
    test('real startup with ${hold}ms collector holds', () async {
      final root = await Directory.systemTemp.createTemp('cxv184-startup-');
      final file = File('${root.path}/viewer.sqlite');
      final migrator = DatabaseMigrator(sqlRoot: Directory('../sql'));
      expect((await migrator.openAndMigrate(file)).canStartNormalUi, isTrue);
      final messages = ReceivePort();
      final stream = StreamIterator<dynamic>(messages);
      final isolate = await Isolate.spawn(_hold, (
        file.path,
        hold,
        hold == 1000 ? 3 : 1,
        messages.sendPort,
      ));
      try {
        expect(await stream.moveNext(), isTrue);
        expect(stream.current, 'holding');
        final wait = Stopwatch()..start();
        final startup = await migrator.openAndMigrate(file);
        wait.stop();
        if (hold == 1000) {
          expect(
            startup.canStartNormalUi,
            isTrue,
            reason: startup.fatalError?.details,
          );
          expect(wait.elapsedMilliseconds, lessThan(5000));
          final db = openFileBackedDatabase(file);
          try {
            expect(
              db.select(
                "select value from app_metadata where key='sqlite_version'",
              ),
              hasLength(1),
            );
          } finally {
            db.close();
          }
        } else {
          expect(startup.canStartNormalUi, isFalse);
          expect(startup.fatalError!.details, contains('SqliteException(5)'));
        }
        // Retained test output is the timing receipt and the negative control.
        // ignore: avoid_print
        print(
          'hold_ms=$hold startup_ms=${wait.elapsedMilliseconds} ready=${startup.canStartNormalUi} error=${startup.fatalError?.details}',
        );
        expect(await stream.moveNext(), isTrue);
        expect(stream.current, 'done');
      } finally {
        isolate.kill(priority: Isolate.immediate);
        await stream.cancel();
        messages.close();
        await root.delete(recursive: true);
      }
    });
  }
}
