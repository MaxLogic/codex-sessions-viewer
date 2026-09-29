import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

typedef SchedulerProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// What the operating system's per-user scheduler holds for the periodic scan.
class ScheduledScanState {
  const ScheduledScanState({
    required this.installed,
    this.intervalMinutes,
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
class ScanSchedulerException implements Exception {
  const ScanSchedulerException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Everything the periodic scan needs; paths are never shell-parsed.
class ScanScheduleRequest {
  const ScanScheduleRequest({
    required this.launcherExecutable,
    required this.databaseFile,
    required this.settingsFile,
    required this.intervalMinutes,
  });

  /// The windowless launcher that runs both scans; it finds the collector
  /// next to itself.
  final String launcherExecutable;
  final String databaseFile;
  final String settingsFile;
  final int intervalMinutes;
}

/// A per-user periodic job that runs `codex scan` and `claude scan`, then
/// exits. Each operating system supplies one implementation; the rest of the
/// app depends only on this interface and [ScanScheduler.forCurrentPlatform].
abstract interface class ScanScheduler {
  factory ScanScheduler.forCurrentPlatform() => Platform.isWindows
      ? WindowsTaskScheduler()
      : const UnsupportedScanScheduler();

  /// False when this platform has no implementation; [query] then reports
  /// nothing installed and [install] throws.
  bool get isSupported;

  /// Throws [ScanSchedulerException] when the scheduler cannot be read.
  Future<ScheduledScanState> query();

  Future<void> install(ScanScheduleRequest request);

  Future<void> remove();
}

class UnsupportedScanScheduler implements ScanScheduler {
  const UnsupportedScanScheduler();

  @override
  bool get isSupported => false;

  @override
  Future<ScheduledScanState> query() async =>
      const ScheduledScanState(installed: false);

  @override
  Future<void> install(ScanScheduleRequest request) async {
    throw const ScanSchedulerException(
      'Periodic scans are not available on this operating system yet.',
    );
  }

  @override
  Future<void> remove() async {}
}

/// Windows Task Scheduler through `schtasks.exe`, in the user's own task
/// folder and with the user's own token: no elevation, no stored password.
class WindowsTaskScheduler implements ScanScheduler {
  WindowsTaskScheduler({
    this.taskName = defaultTaskName,
    SchedulerProcessRunner? runProcess,
    this.temporaryDirectory,
  }) : _run = runProcess ?? Process.run;

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
      throw const ScanSchedulerException(
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
      throw ScanSchedulerException(
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
  Future<ScheduledScanState> query() async {
    final definition = await _schtasks(['/Query', '/TN', taskName, '/XML']);
    if (definition.exitCode != 0) {
      if (!await _taskExists()) {
        return const ScheduledScanState(installed: false);
      }
      throw ScanSchedulerException(
        'Task Scheduler could not read the task: ${_message(definition)}',
      );
    }
    final interval = parseIntervalMinutes(definition.stdout.toString());
    final info = await _lastRun();
    return ScheduledScanState(
      installed: true,
      intervalMinutes: interval,
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
  Future<void> install(ScanScheduleRequest request) async {
    final xml = buildTaskXml(request);
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
        throw ScanSchedulerException(
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
  Future<void> remove() async {
    // A failed query is an error, not "nothing to remove".
    if (!(await query()).installed) return;
    final result = await _schtasks(['/Delete', '/TN', taskName, '/F']);
    if (result.exitCode != 0) {
      throw ScanSchedulerException(
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
    } on ScanSchedulerException {
      // The empty folder stays; it is invisible clutter only.
    }
  }

  static String _message(ProcessResult result) {
    final text = '${result.stderr}${result.stdout}'.trim();
    return text.isEmpty ? 'exit code ${result.exitCode}.' : text;
  }

  /// The task definition: one windowless launcher that runs both scans, one
  /// run at a time, missed runs made up when the user signs in.
  static String buildTaskXml(ScanScheduleRequest request) {
    if (request.intervalMinutes < 1 || request.intervalMinutes > 1440) {
      throw const ScanSchedulerException(
        'The scan interval must be from 1 to 1440 minutes.',
      );
    }
    for (final value in [
      request.launcherExecutable,
      request.databaseFile,
      request.settingsFile,
    ]) {
      if (value.contains('"') || value.contains(RegExp(r'[\r\n]'))) {
        throw const ScanSchedulerException(
          'A collector path contains a quote or a line break, which a '
          'scheduled task cannot carry.',
        );
      }
    }
    final arguments =
        '--db "${request.databaseFile}" --settings "${request.settingsFile}"';
    final start = DateTime.now().toIso8601String().substring(0, 19);
    return '<?xml version="1.0" encoding="UTF-16"?>'
        '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
        '<Triggers><TimeTrigger><Repetition><Interval>PT${request.intervalMinutes}M</Interval>'
        '<StopAtDurationEnd>false</StopAtDurationEnd></Repetition>'
        '<StartBoundary>$start</StartBoundary><Enabled>true</Enabled></TimeTrigger></Triggers>'
        '<Principals><Principal id="Author"><LogonType>InteractiveToken</LogonType>'
        '<RunLevel>LeastPrivilege</RunLevel></Principal></Principals>'
        '<Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'
        '<DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
        '<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
        '<StartWhenAvailable>true</StartWhenAvailable>'
        '<ExecutionTimeLimit>PT1H</ExecutionTimeLimit></Settings>'
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
