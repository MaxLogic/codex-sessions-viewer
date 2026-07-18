import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_connection.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 3) {
    stderr.writeln(
      'usage: database_process_actor <database> <hold|write> <signal-base>',
    );
    exitCode = 64;
    return;
  }

  final db = openFileBackedDatabase(File(arguments[0]));
  final signalBase = arguments[2];
  try {
    switch (arguments[1]) {
      case 'hold':
        db.execute('begin immediate');
        db.execute("insert into actor_writes (value) values ('holder')");
        stdout.writeln('locked');
        await stdout.flush();
        await _waitForFile(File('$signalBase.release'));
        db.execute('commit');
        break;
      case 'write':
        stdout.writeln('ready');
        await stdout.flush();
        await _waitForFile(File('$signalBase.start'));
        stdout.writeln('attempting');
        await stdout.flush();
        db.execute("insert into actor_writes (value) values ('contender')");
        stdout.writeln('written');
        await stdout.flush();
        break;
      default:
        stderr.writeln('unknown actor mode: ${arguments[1]}');
        exitCode = 64;
    }
  } finally {
    db.close();
  }
}

Future<void> _waitForFile(File file) async {
  while (!file.existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
