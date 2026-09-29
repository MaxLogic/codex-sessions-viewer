import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'scan_scheduler.dart';

enum CollectionHarness {
  codex('codex', 'Codex notify hook'),
  claude('claude', 'Claude Code hooks');

  const CollectionHarness(this.id, this.label);

  final String id;
  final String label;
}

enum HookInstallState {
  /// The managed hook is registered exactly as this viewer would write it.
  installed,

  /// A managed hook exists but points at other roots, another database or a
  /// collector that has moved.
  outdated,
  notInstalled,

  /// The harness configuration could not be read or is invalid.
  error,
}

class HookStatus {
  const HookStatus(this.state, {this.detail, this.configPath});

  final HookInstallState state;

  /// A safe explanation for [HookInstallState.error]; never file content.
  final String? detail;

  /// The harness configuration file the hook lives in, when known.
  final String? configPath;
}

enum BackgroundCollectionSummary { off, partial, on, attention }

class BackgroundCollectionStatus {
  const BackgroundCollectionStatus({
    required this.hooks,
    required this.schedule,
    required this.scheduleSupported,
    this.lastScanFinishedUtc,
    this.lastCollectionUtc,
  });

  final Map<CollectionHarness, HookStatus> hooks;
  final ScheduledScanState schedule;
  final bool scheduleSupported;

  /// When any scan, from the viewer, a hook or the schedule, last finished.
  final String? lastScanFinishedUtc;
  final String? lastCollectionUtc;

  int get installedHookCount =>
      hooks.values.where((h) => h.state == HookInstallState.installed).length;

  /// Something is broken, not merely absent: an unreadable configuration or
  /// scheduler, or a scheduled scan that failed on its last run.
  bool get needsAttention =>
      hooks.values.any((hook) => hook.state == HookInstallState.error) ||
      schedule.error != null ||
      schedule.lastRunFailed;

  /// What keeps background collection from being fully on, in words.
  List<String> get gaps =>
      [
        for (final entry in hooks.entries)
          switch (entry.value.state) {
            HookInstallState.installed => null,
            HookInstallState.outdated => '${entry.key.label} are out of date',
            HookInstallState.notInstalled => '${entry.key.label} not installed',
            HookInstallState.error =>
              '${entry.key.label} cannot be checked (configuration problem)',
          },
      ].whereType<String>().toList() +
      [
        if (scheduleSupported && schedule.error != null)
          'the periodic scan cannot be checked'
        else if (scheduleSupported && !schedule.installed)
          'the periodic scan is not scheduled'
        else if (schedule.lastRunFailed)
          'the last scheduled scan failed (code ${schedule.lastResult})',
      ];

  BackgroundCollectionSummary get summary {
    if (needsAttention) return BackgroundCollectionSummary.attention;
    final parts = installedHookCount + (schedule.installed ? 1 : 0);
    final anyOutdated = hooks.values.any(
      (hook) => hook.state == HookInstallState.outdated,
    );
    if (parts == 0 && !anyOutdated) return BackgroundCollectionSummary.off;
    return gaps.isEmpty
        ? BackgroundCollectionSummary.on
        : BackgroundCollectionSummary.partial;
  }
}

/// A change to the background collection failed; the message is safe to show.
class BackgroundCollectionException implements Exception {
  const BackgroundCollectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// What the settings screen needs; tests substitute a fake.
abstract interface class BackgroundCollection {
  bool get scheduleSupported;

  Future<BackgroundCollectionStatus> status();

  Future<void> installHook(CollectionHarness harness);

  /// Removes the managed hook and restores the one it replaced. Returns
  /// whether a previous hook was restored.
  Future<bool> removeHook(CollectionHarness harness);

  Future<void> installSchedule(int intervalMinutes);

  Future<void> removeSchedule();
}

typedef CollectorCommandRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      Map<String, String>? environment,
    });

Future<ProcessResult> _runCollector(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
}) => Process.run(executable, arguments, environment: environment);

/// Installs and removes the collector's `setup` hooks and the scheduled scan.
/// Configuration content never passes through here: the collector edits its
/// own harness files, keeps a backup, preserves permissions and reports only
/// safe fields.
class CollectorBackgroundCollection implements BackgroundCollection {
  CollectorBackgroundCollection({
    required this.collectorExecutable,
    required this.databaseFile,
    required this.settingsFile,
    String? launcherExecutable,
    ScanScheduler? scheduler,
    CollectorCommandRunner? run,
    bool Function(String path)? fileExists,
    this.environment,
  }) : launcherExecutable =
           launcherExecutable ??
           p.join(
             p.dirname(collectorExecutable),
             'codex-sessions-scan-launcher.exe',
           ),
       _scheduler = scheduler ?? ScanScheduler.forCurrentPlatform(),
       _run = run ?? _runCollector,
       _fileExists = fileExists ?? ((path) => File(path).existsSync());

  final String collectorExecutable;

  /// The windowless program the scheduled task starts.
  final String launcherExecutable;
  final String databaseFile;
  final String settingsFile;
  final Map<String, String>? environment;
  final ScanScheduler _scheduler;
  final CollectorCommandRunner _run;
  final bool Function(String path) _fileExists;

  @override
  bool get scheduleSupported => _scheduler.isSupported;

  Future<Map<String, dynamic>?> _collector(
    CollectionHarness harness,
    List<String> arguments,
  ) async {
    final ProcessResult result;
    try {
      result = await _run(collectorExecutable, [
        harness.id,
        ...arguments,
        '--json',
        '--db',
        databaseFile,
      ], environment: environment);
    } on ProcessException {
      throw const BackgroundCollectionException(
        'The session collector could not be started. Reinstall Codex '
        'Sessions Viewer so the collector sits next to the viewer.',
      );
    }
    try {
      final decoded = jsonDecode(result.stdout.toString().trim());
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // Falls through to the exit-code failure below.
    }
    return result.exitCode == 0 ? const {} : null;
  }

  @override
  Future<BackgroundCollectionStatus> status() async {
    final hooks = <CollectionHarness, HookStatus>{};
    String? lastScan;
    String? lastCollection;
    for (final harness in CollectionHarness.values) {
      final report = await _collector(harness, ['status']);
      if (report == null) {
        hooks[harness] = const HookStatus(
          HookInstallState.error,
          detail: 'The collector returned no status.',
        );
        continue;
      }
      final configuration = report['configuration'];
      final database = report['database'];
      if (database is Map) {
        final scan = database['last_scan_finished_utc'];
        final collected = database['last_collection_utc'];
        if (scan is String &&
            (lastScan == null || scan.compareTo(lastScan) > 0)) {
          lastScan = scan;
        }
        if (collected is String &&
            (lastCollection == null ||
                collected.compareTo(lastCollection) > 0)) {
          lastCollection = collected;
        }
      }
      final state = configuration is Map ? configuration['hook_state'] : null;
      final error = configuration is Map ? configuration['error'] : null;
      final config = configuration is Map ? configuration['config'] : null;
      final path = config is String ? config : null;
      hooks[harness] = switch (state) {
        'registered' => HookStatus(
          HookInstallState.installed,
          configPath: path,
        ),
        'different_arguments' => HookStatus(
          HookInstallState.outdated,
          configPath: path,
        ),
        'absent' => HookStatus(HookInstallState.notInstalled, configPath: path),
        _ => HookStatus(
          HookInstallState.error,
          configPath: path,
          detail: error is String
              ? error
              : 'The harness configuration could not be checked.',
        ),
      };
    }
    // A scheduler that cannot be read must not hide the hook rows.
    ScheduledScanState schedule;
    try {
      schedule = await _scheduler.query();
    } on ScanSchedulerException catch (error) {
      schedule = ScheduledScanState(installed: false, error: error.message);
    }
    return BackgroundCollectionStatus(
      hooks: hooks,
      schedule: schedule,
      scheduleSupported: _scheduler.isSupported,
      lastScanFinishedUtc: lastScan,
      lastCollectionUtc: lastCollection,
    );
  }

  Future<Map<String, dynamic>> _setup(
    CollectionHarness harness,
    List<String> flags,
  ) async {
    final report = await _collector(harness, ['setup', ...flags, '--apply']);
    if (report == null || report['ok'] != true) {
      final error = report?['error'];
      throw BackgroundCollectionException(
        error is String
            ? error
            : 'The collector could not change the configuration.',
      );
    }
    return report;
  }

  @override
  Future<void> installHook(CollectionHarness harness) async {
    await _setup(harness, []);
  }

  @override
  Future<bool> removeHook(CollectionHarness harness) async {
    final report = await _setup(harness, ['--remove']);
    return report['changed'] == true &&
        report['preserves_existing_hook'] == true;
  }

  @override
  Future<void> installSchedule(int intervalMinutes) async {
    if (!_fileExists(launcherExecutable)) {
      throw BackgroundCollectionException(
        'The scan launcher is missing: ${p.basename(launcherExecutable)} '
        'should sit next to the viewer. Reinstall Codex Sessions Viewer.',
      );
    }
    try {
      await _scheduler.install(
        ScanScheduleRequest(
          launcherExecutable: launcherExecutable,
          databaseFile: databaseFile,
          settingsFile: settingsFile,
          intervalMinutes: intervalMinutes,
        ),
      );
    } on ScanSchedulerException catch (error) {
      throw BackgroundCollectionException(error.message);
    }
  }

  @override
  Future<void> removeSchedule() async {
    try {
      await _scheduler.remove();
    } on ScanSchedulerException catch (error) {
      throw BackgroundCollectionException(error.message);
    }
  }
}
