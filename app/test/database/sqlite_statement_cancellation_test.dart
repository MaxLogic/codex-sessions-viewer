import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'owner interrupts a statement running on the borrowed connection',
    () async {
      final owner = sqlite3.openInMemory();
      addTearDown(owner.close);
      owner.execute('create table probe(value integer)');

      final started = ReceivePort();
      addTearDown(started.close);
      final address = owner.handle.address;
      final notifyStarted = started.sendPort;
      final statement = Isolate.run(() => _insertRows(address, notifyStarted));

      try {
        await started.first.timeout(const Duration(seconds: 5));
        owner.interrupt();
        expect(
          await statement.timeout(const Duration(seconds: 2)),
          SqlError.SQLITE_INTERRUPT,
        );
        expect(owner.autocommit, isTrue);
        expect(owner.select('select value from probe'), isEmpty);
      } finally {
        // Even if the assertion times out, wait for the borrower before closing.
        await statement;
      }
    },
  );

  test('interrupt while idle leaves the next statement runnable', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.interrupt();
    db.interrupt();
    expect(db.select('select 1 as value').single['value'], 1);
  });
}

int _insertRows(int address, SendPort started) {
  final db = sqlite3.fromPointer(
    Pointer<Void>.fromAddress(address),
    borrowed: true,
  );
  try {
    db.createFunction(
      functionName: 'slow_value',
      argumentCount: const AllowedArgumentCount(1),
      function: (args) {
        final value = args.single;
        // Signal from inside SQLite, after it has started the statement.
        if (value == 1) started.send(true);
        sleep(const Duration(milliseconds: 20));
        return value;
      },
    );
    db.execute('begin');
    db.execute('insert into probe values (0)');
    db.execute('''
      with recursive values_to_insert(value) as (
        select 1 union all select value + 1 from values_to_insert where value < 200
      )
      insert into probe select slow_value(value) from values_to_insert
    ''');
    db.execute('commit');
    return 0;
  } on SqliteException catch (error) {
    return error.resultCode;
  } finally {
    db.close();
  }
}
