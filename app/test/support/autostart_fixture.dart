import 'dart:io';
import 'package:codex_sessions_viewer/src/background_collection/background_collection.dart';
import 'package:codex_sessions_viewer/src/background_collection/collector_autostart.dart';
import 'package:path/path.dart' as p;

/// Scheduler boundary only: production XML, backup, migration and status code run.
class AutostartFixture {
  AutostartFixture(this.root, {bool enabled = true, bool installed = true}) {
    request = CollectorAutostartRequest(
      launcherExecutable: p.join(root.path, 'launcher.exe'),
      databaseFile: p.join(root.path, 'fixture.sqlite'),
      settingsFile: p.join(root.path, 'settings.toml'),
      enabled: enabled,
    );
    xml = installed
        ? WindowsTaskScheduler.buildTaskXml(
            request,
            userId: sid,
          ).replaceFirst('<ExecutionTimeLimit>PT0S', '<ExecutionTimeLimit>PT1H')
        : null;
    original = xml;
    scheduler = WindowsTaskScheduler(runProcess: run);
    collection = CollectorBackgroundCollection(
      collectorExecutable: p.join(root.path, 'collector.exe'),
      launcherExecutable: request.launcherExecutable,
      databaseFile: request.databaseFile,
      settingsFile: request.settingsFile,
      scheduler: scheduler,
      fileExists: (_) => true,
      run: (exe, args, {environment}) async => ProcessResult(
        0,
        0,
        '{"configuration":{"hook_state":"registered"}}',
        '',
      ),
    );
  }
  static const sid = 'S-1-5-21-123';
  final Directory root;
  late final CollectorAutostartRequest request;
  late final WindowsTaskScheduler scheduler;
  late final CollectorBackgroundCollection collection;
  late final String? original;
  String? xml;
  String? createFailure;
  bool ignoreCreate = false;
  bool disableReplacement = false;
  bool failRestore = false;
  int creates = 0;
  bool backupBeforeCreate = false;
  List<File> get backups =>
      Directory(p.join(root.path, 'logs', 'task-backups')).existsSync()
      ? Directory(
          p.join(root.path, 'logs', 'task-backups'),
        ).listSync().whereType<File>().toList()
      : [];
  Future<ProcessResult> run(String exe, List<String> args) async {
    ProcessResult ok([String out = '']) => ProcessResult(0, 0, out, '');
    if (exe == 'whoami.exe') return ok(sid);
    if (exe == 'powershell.exe') return ok('|267011');
    if (args.first == '/Create') {
      creates++;
      backupBeforeCreate = backups.length == 1;
      if (creates > 1 && failRestore) {
        return ProcessResult(0, 1, '', 'restore denied');
      }
      if (createFailure != null) return ProcessResult(0, 1, '', createFailure!);
      final bytes = File(args[args.indexOf('/XML') + 1]).readAsBytesSync();
      final units = <int>[];
      for (var i = 2; i < bytes.length; i += 2) {
        units.add(bytes[i] | bytes[i + 1] << 8);
      }
      if (!ignoreCreate) {
        xml = String.fromCharCodes(units);
        if (creates == 1 && disableReplacement) {
          xml = xml!.replaceFirst(
            '<Enabled>true</Enabled><ExecutionTimeLimit>',
            '<Enabled>false</Enabled><ExecutionTimeLimit>',
          );
        }
      }
      return ok();
    }
    if (args.first == '/Change' && args.contains('/ENABLE')) {
      xml = xml?.replaceFirst(
        '<Enabled>false</Enabled><ExecutionTimeLimit>',
        '<Enabled>true</Enabled><ExecutionTimeLimit>',
      );
      return ok();
    }
    if (args.contains('/XML')) {
      return xml == null ? ProcessResult(0, 1, '', 'absent') : ok(xml!);
    }
    if (args.first == '/Query') return ok('');
    throw StateError('Unexpected scheduler call: $exe $args');
  }
}
