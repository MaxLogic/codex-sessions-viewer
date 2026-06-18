import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory tempDir;
  late File dbFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('csv_db_connection_test_');
    dbFile = File('${tempDir.path}${Platform.pathSeparator}viewer.sqlite');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('file-backed connections enable WAL and busy timeout', () {
    final db = openFileBackedDatabase(dbFile);
    addTearDown(db.close);

    final journalMode = db.select('pragma journal_mode').single.values.single;
    final busyTimeout = db.select('pragma busy_timeout').single.values.single;

    expect(journalMode, 'wal');
    expect(busyTimeout, greaterThan(0));
  });

  test('configuration fails when SQLite does not enable WAL', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);

    expect(
      () => configureFileBackedDatabase(db),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('WAL journal mode'),
        ),
      ),
    );
  });
}
