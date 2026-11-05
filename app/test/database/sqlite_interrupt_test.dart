import 'package:codex_sessions_viewer/src/database/sqlite_interrupt.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('interruptSqlite is available in the packaged SQLite', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    expect(interruptSqlite(db.handle.cast()), isTrue);
    expect(interruptSqlite(db.handle.cast()), isTrue);
    // An interrupt while idle does not affect the next statement.
    expect(db.select('select 1 as value').single['value'], 1);
  });
}
