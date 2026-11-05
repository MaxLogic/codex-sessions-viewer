import 'dart:ffi';

import '../third_party/sqlite_interrupt.g.dart' as native;

bool _unavailable = false;

/// Interrupts the statement running on [handle] and returns whether the
/// loaded SQLite could do so.
///
/// package:sqlite3 3.9.0 and later export `sqlite3_interrupt` on Linux too.
/// If a custom SQLite library omits it, a stop takes effect when the running
/// statement finishes instead of aborting it.
bool interruptSqlite(Pointer<NativeType> handle) {
  if (_unavailable) return false;
  try {
    native.sqlite3_interrupt(handle.cast());
    return true;
  } on ArgumentError {
    _unavailable = true;
    return false;
  }
}
