import 'dart:ffi';

import '../third_party/sqlite_interrupt.g.dart' as native;

bool _unavailable = false;

/// Interrupts the statement running on [handle] and returns whether the
/// loaded SQLite could do so.
///
/// The Linux build of package:sqlite3 exports only the functions that package
/// binds, which excludes `sqlite3_interrupt`. A stop there takes effect when
/// the running statement finishes instead of aborting it.
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
