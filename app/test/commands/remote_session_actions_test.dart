import 'dart:io';

import 'package:codex_sessions_viewer/src/commands/remote_session_actions.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory root;
  late File file;
  late Database db;
  final row = <String, dynamic>{
    'machine_id': 'here',
    'reference': 'history://here/codex/session',
  };
  setUp(() async {
    root = await Directory.systemTemp.createTemp('remote-actions-');
    file = File('${root.path}/test.sqlite');
    db = sqlite3.open(file.path);
    db.execute(
      "create table app_metadata(key text, value text); insert into app_metadata values ('machine_id', 'here')",
    );
    db.execute(
      'create table history_sessions(reference text, source_file_path text, working_directory text, environment text, harness text, session_id text)',
    );
    db.execute('insert into history_sessions values (?, ?, ?, ?, ?, ?)', [
      row['reference'],
      r'C:\sessions\s.jsonl',
      r'C:\project',
      'windows',
      'codex',
      'session',
    ]);
  });
  tearDown(() async {
    db.close();
    await root.delete(recursive: true);
  });
  RemoteSessionActions actions({
    bool sourceExists = true,
    bool harness = true,
  }) => RemoteSessionActions(
    databaseFile: file,
    settings: AppSettings.defaults(),
    fileExists: (_) async => sourceExists,
    directoryExists: (_) async => true,
    harnessAvailable: (_, _) async => harness,
  );

  test(
    'foreign machine cannot resume or use equal-looking local path without mapping',
    () async {
      final remote = {
        ...row,
        'machine_id': 'foreign',
        'working_directory': r'C:\project',
      };
      final result = await actions().inspect(remote);
      expect(result.resume, isNull);
      expect(result.directory, isNull);
      final mapped = await actions().inspect(
        remote,
        explicitLocalMapping: r'C:\project',
      );
      expect(mapped.directory, r'C:\project');
      expect(mapped.resume, isNull);
    },
  );
  test('resume requires local identity, file and installed harness', () async {
    expect((await actions().inspect(row)).resume, isNotNull);
    expect((await actions(sourceExists: false).inspect(row)).resume, isNull);
    expect((await actions(harness: false).inspect(row)).resume, isNull);
  });
  test('recorded WSL distro cannot silently use configured default', () async {
    db.execute(
      'update history_sessions set environment = ?, source_file_path = ?, working_directory = ?',
      ['wsl', r'\\wsl.localhost\Other\home\s.jsonl', '/home/project'],
    );
    final result = await actions().inspect(row);
    expect(result.resume, isNull);
    expect(result.resumeReason, contains('distribution'));
  });
  test('same recorded WSL environment permits verified local resume', () async {
    db.execute(
      'update history_sessions set environment = ?, source_file_path = ?, working_directory = ?',
      ['wsl', r'\\wsl.localhost\Ubuntu\home\s.jsonl', '/home/project'],
    );
    final result = await actions().inspect(row);
    expect(result.resume, isNotNull);
    expect(result.directory, r'\\wsl.localhost\Ubuntu\home\project');
  });
}
