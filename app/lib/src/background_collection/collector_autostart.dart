import 'package:codex_sessions_viewer/src/platform/app_environment.dart';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

typedef SchedulerProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// The installed per-user resident autostart task.
class ScheduledScanState {
  const ScheduledScanState({
    required this.installed,
    this.intervalMinutes,
    this.outdated = false,
    this.enabled = true,
    this.lastRun,
    this.lastResult,
    this.error,
  });

  /// Task Scheduler's result while the task is running.
  static const runningResult = 267009;

  /// Task Scheduler's result when the run was stopped (by the user, or by
  /// the execution time limit).
  static const stoppedResult = 267014;

  /// Task Scheduler's result before the task has ever run.
  static const neverRunResult = 267011;

  final bool installed;
  final bool outdated;
  final bool enabled;
  final int? intervalMinutes;

  /// The last run in local time; null when it never ran or is unknown.
  final DateTime? lastRun;

  /// The exit code of the last run; null when it never ran or is unknown.
  final int? lastResult;

  /// A safe explanation when the scheduler could not be read at all.
  final String? error;

  bool get running => lastResult == runningResult;

  bool get stopped => lastResult == stoppedResult;

  /// The last run finished with a failure. A running or never-run task has
  /// not failed.
  bool get lastRunFailed =>
      lastResult != null &&
      lastResult != 0 &&
      lastResult != runningResult &&
      lastResult != stoppedResult &&
      lastResult != neverRunResult;
}

/// The scheduler cannot do what was asked; the message is safe to show.
class CollectorAutostartException implements Exception {
  const CollectorAutostartException(
    this.message, {
    this.backupPath,
    this.detail,
  });

  final String message;
  final String? backupPath;
  final String? detail;

  @override
  String toString() => message;
}

/// Everything the resident launcher needs; paths are never shell-parsed.
class CollectorAutostartRequest {
  const CollectorAutostartRequest({
    required this.launcherExecutable,
    required this.databaseFile,
    required this.settingsFile,
    this.enabled = true,
  });

  /// The windowless launcher that starts the resident; it finds the collector
  /// next to itself.
  final String launcherExecutable;
  final String databaseFile;
  final String settingsFile;
  final bool enabled;
}

/// Starts the resident at login and watches for an exited resident. Each operating system supplies one implementation; the rest of the
/// app depends only on this interface and [CollectorAutostart.forCurrentPlatform].
abstract interface class CollectorAutostart {
  factory CollectorAutostart.forCurrentPlatform() => Platform.isWindows
      ? WindowsTaskScheduler()
      : const UnsupportedCollectorAutostart();

  /// False when this platform has no implementation; [query] then reports
  /// nothing installed and [install] throws.
  bool get isSupported;

  /// Throws [CollectorAutostartException] when the scheduler cannot be read.
  Future<ScheduledScanState> query({CollectorAutostartRequest? expected});

  /// Back up before replacing an installed definition; verify the replacement.
  Future<String?> upgrade(CollectorAutostartRequest request, Directory backups);

  Future<void> install(CollectorAutostartRequest request);

  Future<void> enable();

  Future<void> remove();
}

class UnsupportedCollectorAutostart implements CollectorAutostart {
  const UnsupportedCollectorAutostart();

  @override
  bool get isSupported => false;

  @override
  Future<ScheduledScanState> query({
    CollectorAutostartRequest? expected,
  }) async => const ScheduledScanState(installed: false);

  @override
  Future<void> install(CollectorAutostartRequest request) async {
    throw const CollectorAutostartException(
      'Start at sign-in is not available on this operating system yet.',
    );
  }

  @override
  Future<String?> upgrade(
    CollectorAutostartRequest request,
    Directory backups,
  ) async => null;

  @override
  Future<void> enable() async => throw const CollectorAutostartException(
    'Start at sign-in is not available on this operating system yet.',
  );

  @override
  Future<void> remove() async {}
}

/// Windows Task Scheduler through `schtasks.exe`, in the user's own task
/// folder and with the user's own token: no elevation, no stored password.
class WindowsTaskScheduler implements CollectorAutostart {
  WindowsTaskScheduler({
    this.taskName = defaultTaskName,
    SchedulerProcessRunner? runProcess,
    this.temporaryDirectory,
  }) : _run = runProcess ?? AppEnvironment.run;

  static const defaultTaskName = r'Codex Session Viewer\Background collection';

  final String taskName;
  final SchedulerProcessRunner _run;

  /// Where the task definition is staged; a fresh temporary folder if null.
  final Directory? temporaryDirectory;

  @override
  bool get isSupported => true;

  Future<ProcessResult> _schtasks(List<String> arguments) async {
    try {
      return await _run('schtasks', arguments);
    } on ProcessException {
      throw const CollectorAutostartException(
        'Windows Task Scheduler (schtasks.exe) could not be started.',
      );
    }
  }

  String get _folder => taskName.contains(r'\')
      ? taskName.substring(0, taskName.lastIndexOf(r'\'))
      : '';

  /// Whether the task is registered. `schtasks` words a missing task in the
  /// user's language, so this reads the task list instead of an error text;
  /// a list that cannot be read is an error, never "absent".
  Future<bool> _taskExists() async {
    final list = await _schtasks(['/Query', '/FO', 'CSV', '/NH']);
    if (list.exitCode != 0) {
      throw CollectorAutostartException(
        'Task Scheduler could not be read: ${_message(list)}',
      );
    }
    final wanted = '\\$taskName'.toLowerCase();
    return _taskNames(
      list.stdout.toString(),
    ).any((name) => name.toLowerCase() == wanted);
  }

  static Iterable<String> _taskNames(String csv) sync* {
    for (final line in csv.split(RegExp(r'\r?\n'))) {
      final fields = parseVerboseCsv(line);
      if (fields.isNotEmpty) yield fields.first;
    }
  }

  @override
  Future<ScheduledScanState> query({
    CollectorAutostartRequest? expected,
  }) async {
    final definition = await _schtasks(['/Query', '/TN', taskName, '/XML']);
    if (definition.exitCode != 0) {
      if (!await _taskExists()) {
        return const ScheduledScanState(installed: false);
      }
      throw CollectorAutostartException(
        'Task Scheduler could not read the task: ${_message(definition)}',
      );
    }
    final xml = definition.stdout.toString();
    final interval = parseIntervalMinutes(xml);
    final userId = await _currentUser();
    final (outdated, enabled) = inspectDefinition(
      xml,
      userId: userId,
      expected: expected,
    );
    final info = await _lastRun();
    return ScheduledScanState(
      installed: true,
      intervalMinutes: interval,
      outdated: outdated,
      enabled: enabled,
      lastRun: info?.$1,
      lastResult: info?.$2,
    );
  }

  /// The last run and result from `Get-ScheduledTaskInfo`, whose ISO times
  /// do not depend on the user's language. Null when unknown.
  Future<(DateTime?, int?)?> _lastRun() async {
    final slash = taskName.lastIndexOf(r'\');
    final path = slash < 0 ? r'\' : '\\${taskName.substring(0, slash + 1)}';
    final name = taskName.substring(slash + 1);
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    final script =
        '\$i = Get-ScheduledTaskInfo -TaskPath ${quote(path)} '
        '-TaskName ${quote(name)} -ErrorAction Stop; '
        "\$t = ''; if (\$i.LastRunTime) { \$t = \$i.LastRunTime.ToString('o') }; "
        r'"$t|$($i.LastTaskResult)"';
    final ProcessResult result;
    try {
      result = await _run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]);
    } on ProcessException {
      return null;
    }
    return parseTaskInfo(result.exitCode == 0 ? result.stdout.toString() : '');
  }

  /// `<ISO time>|<result>`; a task that never ran has no time or a 1999 one.
  static (DateTime?, int?)? parseTaskInfo(String output) {
    final parts = output.trim().split('|');
    if (parts.length != 2) return null;
    final result = int.tryParse(parts[1]);
    final time = DateTime.tryParse(parts[0]);
    if (result == ScheduledScanState.neverRunResult ||
        time == null ||
        time.year <= 2000) {
      return (null, null);
    }
    return (time.toLocal(), result);
  }

  @override
  Future<void> install(CollectorAutostartRequest request) async {
    await _registerXml(buildTaskXml(request, userId: await _currentUser()));
  }

  Future<void> _registerXml(String xml) async {
    final directory =
        temporaryDirectory ?? await Directory.systemTemp.createTemp('cxv-');
    final file = File(p.join(directory.path, 'background-collection.xml'));
    try {
      // Task Scheduler reads UTF-16 with a byte order mark.
      final bytes = <int>[0xFF, 0xFE];
      for (final unit in xml.codeUnits) {
        bytes
          ..add(unit & 0xFF)
          ..add(unit >> 8);
      }
      await file.writeAsBytes(bytes, flush: true);
      final result = await _schtasks([
        '/Create',
        '/TN',
        taskName,
        '/XML',
        file.path,
        '/F',
      ]);
      if (result.exitCode != 0) {
        throw CollectorAutostartException(
          'Task Scheduler refused the task: ${_message(result)}',
        );
      }
    } finally {
      try {
        if (temporaryDirectory == null) {
          await directory.delete(recursive: true);
        } else if (await file.exists()) {
          await file.delete();
        }
      } on FileSystemException {
        // A leftover temporary definition holds no secrets.
      }
    }
  }

  @override
  Future<void> enable() async {
    if (!(await query()).installed) {
      throw const CollectorAutostartException(
        'Start at sign-in is not installed.',
      );
    }
    final result = await _schtasks(['/Change', '/TN', taskName, '/ENABLE']);
    if (result.exitCode != 0) {
      throw CollectorAutostartException(
        'Windows could not turn on Background collection: ${_message(result)}',
      );
    }
    final verified = await query();
    if (!verified.installed || !verified.enabled) {
      throw const CollectorAutostartException(
        'Windows did not confirm that Background collection was turned on.',
      );
    }
  }

  @override
  Future<void> remove() async {
    // A failed query is an error, not "nothing to remove".
    if (!(await query()).installed) return;
    final result = await _schtasks(['/Delete', '/TN', taskName, '/F']);
    if (result.exitCode != 0) {
      throw CollectorAutostartException(
        'Task Scheduler could not remove the task: ${_message(result)}',
      );
    }
    await _removeEmptyFolder();
  }

  /// Deletes the task folder once nothing else lives in it. Never deletes a
  /// folder that still holds a task, and a failure here is harmless.
  Future<void> _removeEmptyFolder() async {
    if (_folder.isEmpty) return;
    try {
      final list = await _schtasks(['/Query', '/FO', 'CSV', '/NH']);
      if (list.exitCode != 0) return;
      final prefix = '\\$_folder\\'.toLowerCase();
      if (_taskNames(
        list.stdout.toString(),
      ).any((name) => name.toLowerCase().startsWith(prefix))) {
        return;
      }
      await _schtasks(['/Delete', '/TN', '\\$_folder', '/F']);
    } on CollectorAutostartException {
      // The empty folder stays; it is invisible clutter only.
    }
  }

  String? _userId;
  Future<String> _currentUser() async {
    if (_userId case final user?) return user;
    final result = await _run('whoami.exe', ['/user', '/fo', 'csv', '/nh']);
    final sid = RegExp(
      r'S-1-[0-9-]+',
    ).firstMatch(result.stdout.toString())?.group(0);
    if (result.exitCode != 0 || sid == null) {
      throw const CollectorAutostartException(
        'The current Windows user could not be identified.',
      );
    }
    return _userId = sid;
  }

  /// Read actual XML elements, independent of namespace prefixes and whitespace.
  static (bool, bool) inspectDefinition(
    String xml, {
    required String userId,
    CollectorAutostartRequest? expected,
  }) {
    try {
      final task = XmlDocument.parse(xml).rootElement;
      XmlElement? child(XmlElement? parent, String name) =>
          parent?.childElements.where((e) => e.name.local == name).firstOrNull;
      String? value(XmlElement? parent, String name) =>
          child(parent, name)?.innerText.trim();
      final settings = child(task, 'Settings');
      final triggers = child(task, 'Triggers');
      final logon = child(triggers, 'LogonTrigger');
      final timer = child(triggers, 'TimeTrigger');
      final repetition = child(timer, 'Repetition');
      final principal = child(child(task, 'Principals'), 'Principal');
      final actions = child(task, 'Actions');
      final exec = child(actions, 'Exec');
      final enabled = value(settings, 'Enabled') != 'false';
      final good =
          task.name.local == 'Task' &&
          logon != null &&
          value(logon, 'UserId') == userId &&
          value(logon, 'Enabled') == 'true' &&
          value(timer, 'Enabled') == 'true' &&
          value(repetition, 'Interval') == 'PT5M' &&
          value(repetition, 'StopAtDurationEnd') == 'false' &&
          value(settings, 'ExecutionTimeLimit') == 'PT0S' &&
          value(settings, 'MultipleInstancesPolicy') == 'IgnoreNew' &&
          value(settings, 'StartWhenAvailable') == 'true' &&
          value(settings, 'DisallowStartIfOnBatteries') == 'false' &&
          value(settings, 'StopIfGoingOnBatteries') == 'false' &&
          value(principal, 'UserId') == userId &&
          value(principal, 'LogonType') == 'InteractiveToken' &&
          value(principal, 'RunLevel') == 'LeastPrivilege' &&
          actions?.childElements.length == 1 &&
          (expected == null ||
              (value(exec, 'Command') == expected.launcherExecutable &&
                  value(exec, 'Arguments') ==
                      '--db "${expected.databaseFile}" --settings "${expected.settingsFile}"'));
      return (!good, enabled);
    } on XmlException {
      throw const CollectorAutostartException(
        'The installed task definition is invalid XML; it was not changed.',
      );
    }
  }

  @override
  Future<String?> upgrade(
    CollectorAutostartRequest request,
    Directory backups,
  ) async {
    final state = await query(expected: request);
    if (!state.installed || !state.outdated) return null;
    // Re-read immediately before backup. Never register without a durable backup.
    final old = await _schtasks(['/Query', '/TN', taskName, '/XML']);
    if (old.exitCode != 0) {
      throw CollectorAutostartException(
        'Could not back up the installed task: ${_message(old)}',
      );
    }
    final (_, enabled) = inspectDefinition(
      old.stdout.toString(),
      userId: await _currentUser(),
      expected: request,
    );
    await backups.create(recursive: true);
    final stamp = DateTime.now().toUtc().toIso8601String().replaceAll(':', '-');
    final backup = File(
      p.join(backups.path, 'background-collection-$stamp.xml'),
    );
    await backup.writeAsString(
      old.stdout.toString().replaceFirst(
        RegExp(r'encoding="[^"]+"'),
        'encoding="UTF-8"',
      ),
      flush: true,
    );
    try {
      await install(
        CollectorAutostartRequest(
          launcherExecutable: request.launcherExecutable,
          databaseFile: request.databaseFile,
          settingsFile: request.settingsFile,
          enabled: enabled,
        ),
      );
    } on CollectorAutostartException catch (error) {
      throw CollectorAutostartException(error.message, backupPath: backup.path);
    } on FileSystemException catch (error) {
      throw CollectorAutostartException(
        'Could not stage the update: ${error.message}.',
        backupPath: backup.path,
      );
    }
    String? rejectedDefinition;
    String failure;
    try {
      rejectedDefinition = await _readDefinition();
      final (outdated, actualEnabled) = inspectDefinition(
        rejectedDefinition,
        userId: await _currentUser(),
        expected: request,
      );
      if (!outdated && actualEnabled == enabled) return backup.path;
      failure = 'The updated setting could not be verified.';
    } on CollectorAutostartException catch (error) {
      failure = error.message;
    }
    try {
      // Avoid overwriting a separate edit observed after failed verification.
      if (rejectedDefinition != null &&
          _definitionKey(await _readDefinition()) !=
              _definitionKey(rejectedDefinition)) {
        throw const CollectorAutostartException(
          'The setting changed again before recovery.',
        );
      }
      await _registerXml(old.stdout.toString());
      if (_definitionKey(await _readDefinition()) !=
          _definitionKey(old.stdout.toString())) {
        throw const CollectorAutostartException(
          'The restored setting could not be verified.',
        );
      }
    } on Object catch (error) {
      final detail = error is CollectorAutostartException
          ? error.message
          : 'Windows could not restore the saved setting.';
      throw CollectorAutostartException(
        'Start at sign-in could not be updated, and the previous setting could not be put back, so it may not run. Choose Retry update. If that fails, import the saved backup shown below in Windows Task Scheduler.',
        backupPath: backup.path,
        detail: '$failure $detail',
      );
    }
    throw CollectorAutostartException(
      'Could not update start at sign-in. The previous setting was restored. Choose Retry update.',
      backupPath: backup.path,
      detail: failure,
    );
  }

  Future<String> _readDefinition() async {
    final result = await _schtasks(['/Query', '/TN', taskName, '/XML']);
    if (result.exitCode != 0) {
      throw CollectorAutostartException(
        'The installed setting could not be read: ${_message(result)}',
      );
    }
    return result.stdout.toString();
  }

  static String _definitionKey(String xml) {
    Object key(XmlElement element) {
      final attributes =
          element.attributes
              .where((a) => a.name.prefix != 'xmlns' && a.name.local != 'xmlns')
              .map((a) => '${a.name.local}=${a.value}')
              .toList()
            ..sort();
      return [
        element.name.local,
        attributes,
        if (element.childElements.isEmpty)
          element.innerText
        else
          element.childElements.map(key).toList(),
      ];
    }

    return jsonEncode(key(XmlDocument.parse(xml).rootElement));
  }

  static String _message(ProcessResult result) {
    final text = '${result.stderr}${result.stdout}'.trim();
    return text.isEmpty ? 'exit code ${result.exitCode}.' : text;
  }

  /// One windowless resident launcher, at login and every five minutes.
  static String buildTaskXml(
    CollectorAutostartRequest request, {
    required String userId,
  }) {
    for (final value in [
      request.launcherExecutable,
      request.databaseFile,
      request.settingsFile,
    ]) {
      if (value.contains('"') || value.contains(RegExp(r'[\r\n]'))) {
        throw const CollectorAutostartException(
          'A session collection path contains a quote or a line break, which a '
          'scheduled task cannot carry.',
        );
      }
    }
    final arguments =
        '--db "${request.databaseFile}" --settings "${request.settingsFile}"';
    final start = DateTime.now().toIso8601String().substring(0, 19);
    return '<?xml version="1.0" encoding="UTF-16"?>'
        '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
        '<Triggers><LogonTrigger><Enabled>true</Enabled><UserId>${_escape(userId)}</UserId></LogonTrigger>'
        '<TimeTrigger><Repetition><Interval>PT5M</Interval>'
        '<StopAtDurationEnd>false</StopAtDurationEnd></Repetition>'
        '<StartBoundary>$start</StartBoundary><Enabled>true</Enabled></TimeTrigger></Triggers>'
        '<Principals><Principal id="Author"><UserId>${_escape(userId)}</UserId><LogonType>InteractiveToken</LogonType>'
        '<RunLevel>LeastPrivilege</RunLevel></Principal></Principals>'
        '<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'
        '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
        '<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
        '<StartWhenAvailable>true</StartWhenAvailable>'
        '<Enabled>${request.enabled}</Enabled><ExecutionTimeLimit>PT0S</ExecutionTimeLimit></Settings>'
        '<Actions Context="Author"><Exec>'
        '<Command>${_escape(request.launcherExecutable)}</Command>'
        '<Arguments>${_escape(arguments)}</Arguments></Exec></Actions></Task>';
  }

  static String _escape(String value) =>
      const HtmlEscape(HtmlEscapeMode.element).convert(value);

  /// The repeat interval of a task definition, in minutes.
  static int? parseIntervalMinutes(String xml) {
    final match = RegExp(
      r'<Interval>PT(?:(\d+)H)?(?:(\d+)M)?</Interval>',
    ).firstMatch(xml);
    if (match == null) return null;
    final minutes =
        (int.tryParse(match.group(1) ?? '') ?? 0) * 60 +
        (int.tryParse(match.group(2) ?? '') ?? 0);
    return minutes == 0 ? null : minutes;
  }

  /// The quoted fields of the first non-blank `/FO CSV /NH` row.
  static List<String> parseVerboseCsv(String output) {
    final line = output
        .split(RegExp(r'\r?\n'))
        .firstWhere((line) => line.trim().isNotEmpty, orElse: () => '');
    if (line.isEmpty) return const [];
    final trimmed = line.trim();
    final inner = trimmed.startsWith('"') && trimmed.endsWith('"')
        ? trimmed.substring(1, trimmed.length - 1)
        : trimmed;
    return inner.split('","');
  }
}
