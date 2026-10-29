import 'dart:io';

import 'package:codex_sessions_viewer/src/database/sqlite_interrupt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('interruptSqlite reports whether the loaded SQLite can abort', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    // package:sqlite3's Linux library does not export sqlite3_interrupt.
    final abortable = !Platform.isLinux;

    expect(interruptSqlite(db.handle.cast()), abortable);
    // A missing symbol is remembered instead of failing on every stop.
    expect(interruptSqlite(db.handle.cast()), abortable);
    // An interrupt while idle does not affect the next statement.
    expect(db.select('select 1 as value').single['value'], 1);
  });
}
