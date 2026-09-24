import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// A persistent read connection is required: data_version values from separate
/// connections cannot be compared. Polling coalesces a burst of commits, and
/// reopening always invalidates readers so a disconnected interval is caught up.
class ExternalDatabaseChanges {
  ExternalDatabaseChanges(this.file, {required this.onChange});

  final File file;
  final void Function() onChange;
  Database? _database;
  int? _version;
  Timer? _timer;
  bool _closed = false;

  void start({Duration interval = const Duration(seconds: 2)}) {
    if (_closed || _timer != null) return;
    check();
    _timer = Timer.periodic(interval, (_) => check());
  }

  void check() {
    if (_closed) return;
    try {
      final reconnect = _database == null;
      final db = _database ??= sqlite3.open(file.path, mode: OpenMode.readOnly);
      db.execute('pragma query_only = on');
      final version =
          db.select('pragma data_version').single.values.single as int;
      final changed = reconnect || _version != version;
      _version = version;
      if (changed) onChange();
    } on SqliteException {
      disconnect();
    } on Object {
      // Unexpected callback/type errors must not leave a native handle open or
      // repeatedly invoke the same failing callback on the timer.
      dispose();
      rethrow;
    }
  }

  void disconnect() {
    _database?.close();
    _database = null;
    _version = null;
  }

  void dispose() {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    disconnect();
  }
}
