import 'dart:async';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

/// A persistent read connection is required: data_version values from separate
/// connections cannot be compared. Polling coalesces a burst of commits.
///
/// The first connection only records a baseline; the loaders read the
/// database themselves. A reconnect after a lost connection reports one
/// change, because commits made while disconnected cannot be seen otherwise.
/// A busy database (an exclusive maintenance operation) keeps the
/// connection, so its baseline survives instead of resetting every poll.
class ExternalDatabaseChanges {
  ExternalDatabaseChanges(
    this.file, {
    required this.onChange,
    this.busyTimeout = const Duration(milliseconds: 250),
  });

  final File file;
  final void Function() onChange;
  final Duration busyTimeout;
  Database? _database;
  int? _version;
  var _connectedBefore = false;
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
      final db = _database ??= _open();
      final version =
          db.select('pragma data_version').single.values.single as int;
      final changed = reconnect ? _connectedBefore : _version != version;
      _version = version;
      _connectedBefore = true;
      if (changed) onChange();
    } on SqliteException catch (error) {
      // SQLITE_BUSY (5) and SQLITE_LOCKED (6): try again on the next poll
      // with the same connection and baseline.
      final primary = error.extendedResultCode & 0xff;
      if (_database != null && (primary == 5 || primary == 6)) return;
      disconnect();
    } on Object {
      // Unexpected callback/type errors must not leave a native handle open or
      // repeatedly invoke the same failing callback on the timer.
      dispose();
      rethrow;
    }
  }

  Database _open() {
    final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      db.execute('pragma busy_timeout = ${busyTimeout.inMilliseconds}');
      db.execute('pragma query_only = on');
      return db;
    } on Object {
      db.close();
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
