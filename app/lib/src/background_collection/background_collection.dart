import 'package:codex_sessions_viewer/src/platform/app_environment.dart';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'collector_autostart.dart';

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
    this.autostartUpdate,
    this.lastScanFinishedUtc,
    this.lastCollectionUtc,
  });

  final Map<CollectionHarness, HookStatus> hooks;
  final ScheduledScanState schedule;
  final bool scheduleSupported;
  final AutostartUpdate? autostartUpdate;

  /// When any scan, from the viewer, a hook or the schedule, last finished.
  final String? lastScanFinishedUtc;
  final String? lastCollectionUtc;

  int get installedHookCount =>
      hooks.values.where((h) => h.state == HookInstallState.installed).length;

  /// Something is broken, not merely absent: an unreadable configuration or
  /// scheduler, or a scheduled scan that failed on its last run.
  bool get needsAttention =>
      hooks.values.any((hook) => hook.state == HookInstallState.error) ||
      autostartUpdate?.error != null ||
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
          'start at sign-in cannot be checked'
        else if (scheduleSupported && !schedule.installed)
          'start at sign-in is not installed'
        else if (schedule.outdated)
          'start at sign-in needs an update'
        else if (schedule.installed && !schedule.enabled)
          'start at sign-in is turned off'
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

class AutostartUpdate {
  AutostartUpdate({
    this.backupPath,
    this.error,
    this.detail,
    this.keptDisabled = false,
  });
  final String? backupPath;
  final String? error;
  final String? detail;
  final bool keptDisabled;
  bool _announced = false;
  String? takeAnnouncement() {
    if (_announced) return null;
    _announced = true;
    return message;
  }

  String get message => error != null
      ? detail != null
            ? error!
            : 'Could not update start at sign-in. $error'
      : 'Start at sign-in was updated. A backup of the previous setting was saved.';
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

  Future<void> installSchedule();

  Future<void> enableSchedule();

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
}) => AppEnvironment.run(executable, arguments, environment: environment);

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
    CollectorAutostart? scheduler,
    CollectorCommandRunner? run,
    bool Function(String path)? fileExists,
    this.environment,
  }) : launcherExecutable =
           launcherExecutable ??
           p.join(
             p.dirname(collectorExecutable),
             'codex-sessions-scan-launcher.exe',
           ),
       _scheduler = scheduler ?? CollectorAutostart.forCurrentPlatform(),
       _run = run ?? _runCollector,
       _fileExists = fileExists ?? ((path) => File(path).existsSync());

  final String collectorExecutable;

  /// The windowless program the scheduled task starts.
  final String launcherExecutable;
  final String databaseFile;
  final String settingsFile;
  final Map<String, String>? environment;
  final CollectorAutostart _scheduler;
  final CollectorCommandRunner _run;
  final bool Function(String path) _fileExists;

  AutostartUpdate? _autostartUpdate;
  Future<void>? _initialization;
  CollectorAutostartRequest get _request => CollectorAutostartRequest(
    launcherExecutable: launcherExecutable,
    databaseFile: databaseFile,
    settingsFile: settingsFile,
  );

  /// Called after the first viewer frame; status shares the same single attempt.
  Future<void> initialize() => _initialization ??= _upgrade();

  Future<void> _upgrade() async {
    try {
      final before = await _scheduler.query(expected: _request);
      if (!before.installed || !before.outdated) {
        _autostartUpdate = null;
        return;
      }
      if (!_fileExists(launcherExecutable)) {
        throw const CollectorAutostartException(
          'A required session collection component is missing. Reinstall Codex Sessions Viewer.',
        );
      }
      final backup = await _scheduler.upgrade(
        _request,
        Directory(p.join(p.dirname(databaseFile), 'logs', 'task-backups')),
      );
      if (backup != null) {
        _autostartUpdate = AutostartUpdate(
          backupPath: backup,
          keptDisabled: !before.enabled,
        );
      }
    } on CollectorAutostartException catch (error) {
      _autostartUpdate = AutostartUpdate(
        error: error.message,
        backupPath: error.backupPath,
        detail: error.detail,
      );
    } on FileSystemException catch (error) {
      _autostartUpdate = AutostartUpdate(
        error: 'The task backup could not be saved: ${error.message}',
      );
    } on ProcessException {
      _autostartUpdate = AutostartUpdate(
        error: 'The Windows task update could not be started.',
      );
    }
  }

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
        'Session collection could not be started. Reinstall Codex '
        'Sessions Viewer to restore its required components.',
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
    await initialize();
    final hooks = <CollectionHarness, HookStatus>{};
    String? lastScan;
    String? lastCollection;
    for (final harness in CollectionHarness.values) {
      final report = await _collector(harness, ['status']);
      if (report == null) {
        hooks[harness] = const HookStatus(
          HookInstallState.error,
          detail: 'Session collection returned no status.',
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
      schedule = await _scheduler.query(expected: _request);
    } on CollectorAutostartException catch (error) {
      schedule = ScheduledScanState(installed: false, error: error.message);
    }
    return BackgroundCollectionStatus(
      hooks: hooks,
      autostartUpdate: _autostartUpdate,
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
            : 'Session collection could not change the configuration.',
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
  Future<void> installSchedule() async {
    if (!_fileExists(launcherExecutable)) {
      throw BackgroundCollectionException(
        'A required session collection component is missing. Reinstall Codex Sessions Viewer.',
      );
    }
    try {
      if (_autostartUpdate?.error != null) {
        await _upgrade();
        if (_autostartUpdate?.error case final error?) {
          throw BackgroundCollectionException(error);
        }
        return;
      }
      final current = await _scheduler.query(expected: _request);
      if (current.installed &&
          (current.outdated || _autostartUpdate?.error != null)) {
        await _upgrade();
        if (_autostartUpdate?.error case final error?) {
          throw BackgroundCollectionException(error);
        }
      } else {
        await _scheduler.install(
          CollectorAutostartRequest(
            launcherExecutable: launcherExecutable,
            databaseFile: databaseFile,
            settingsFile: settingsFile,
            enabled: !current.installed || current.enabled,
          ),
        );
      }
    } on CollectorAutostartException catch (error) {
      throw BackgroundCollectionException(error.message);
    }
  }

  @override
  Future<void> enableSchedule() async {
    try {
      await _scheduler.enable();
    } on CollectorAutostartException catch (error) {
      throw BackgroundCollectionException(error.message);
    }
  }

  @override
  Future<void> removeSchedule() async {
    try {
      await _scheduler.remove();
    } on CollectorAutostartException catch (error) {
      throw BackgroundCollectionException(error.message);
    }
  }
}
