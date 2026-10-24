import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/platform/app_environment.dart';
import 'package:codex_sessions_viewer/src/platform/app_locations.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

/// One boundary for unit, widget and integration fixtures, including defaults
/// computed in-process. Never mutate the test runner's global environment.
class TestEnvironment {
  TestEnvironment._(this.root, this.environment, this.realProfileRoots);

  final Directory root;
  final Map<String, String> environment;
  final List<String> realProfileRoots;
  late final List<String> _physicalRealProfileRoots = realProfileRoots
      .map(_physical)
      .toList();
  static final Object _key = Object();
  static TestEnvironment? _installed;
  static TestEnvironment get current =>
      Zone.current[_key] as TestEnvironment? ??
      _installed ??
      (throw StateError('Test environment was not installed'));
  static Future<void> testMain(FutureOr<void> Function() body) async {
    if (Zone.current[_key] != null) {
      await body();
      return;
    }
    final sandbox = create();
    _installed = sandbox;
    sandbox.install();
    await sandbox.run(body);
  }

  void install() {
    _installed = this;
    AppEnvironment.installTestBoundary(
      environment: environment,
      admit: admit,
      workingDirectory: root.path,
      initializeChildIsolate: install,
    );
    IOOverrides.global = _TestIOOverrides(Directory(environment['TEMP']!));
    AppLocations.testLocations = locations;
  }

  static const profileKeys = [
    'LOCALAPPDATA',
    'APPDATA',
    'USERPROFILE',
    'HOME',
    'XDG_CONFIG_HOME',
    'XDG_DATA_HOME',
    'XDG_STATE_HOME',
    'XDG_CACHE_HOME',
    'XDG_RUNTIME_DIR',
    'XDG_CONFIG_DIRS',
    'XDG_DATA_DIRS',
    'CODEX_HOME',
    'CLAUDE_CONFIG_DIR',
    'CLAUDE_HOME',
    'CODEX_SESSIONS_COLLECTOR_QUEUE',
    'TEMP',
    'TMP',
    'TMPDIR',
  ];

  static const systemKeys = {
    'SYSTEMROOT',
    'WINDIR',
    'COMSPEC',
    'SYSTEMDRIVE',
    'PATHEXT',
    'PROGRAMFILES',
    'PROGRAMFILES(X86)',
    'PROGRAMW6432',
    'PROGRAMDATA',
    'ALLUSERSPROFILE',
    'COMMONPROGRAMFILES',
    'COMMONPROGRAMFILES(X86)',
    'COMMONPROGRAMW6432',
  };
  static final _machineSystem = {
    for (final e in Platform.environment.entries)
      if (systemKeys.contains(e.key.toUpperCase()))
        e.key.toUpperCase(): e.value,
  };
  final Set<String> _fixtureOrigins = {};

  String _loopbackOrigin(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        !['127.0.0.1', '::1', '[::1]'].contains(uri.host) ||
        !uri.hasPort ||
        uri.port == 0 ||
        uri.userInfo.isNotEmpty) {
      throw StateError('Test isolation rejected network endpoint: $value');
    }
    return uri.origin;
  }

  /// Register only an endpoint bound by a fixture in this test process.
  void ownEndpoint(Uri uri) => _fixtureOrigins.add(_loopbackOrigin('$uri'));

  void guardEndpoint(String value) {
    if (!_fixtureOrigins.contains(_loopbackOrigin(value))) {
      throw StateError(
        'Test isolation rejected unowned network endpoint: $value',
      );
    }
  }

  void _guardSystem(Map<String, String> values) {
    for (final key in systemKeys) {
      final value = values[key];
      if (value == null) continue;
      if (_machineSystem[key] != value) {
        throw StateError('Test isolation rejected system variable: $key');
      }
      if (key == 'PATHEXT') {
        if (!RegExp(r'^\.[A-Za-z0-9]+(;\.[A-Za-z0-9]+)*$').hasMatch(value)) {
          throw StateError('Test isolation rejected system PATHEXT');
        }
        continue;
      }
      final location =
          key == 'SYSTEMDRIVE' && RegExp(r'^[A-Za-z]:$').hasMatch(value)
          ? '$value\\'
          : value;
      if (!p.isAbsolute(location)) {
        throw StateError(
          'Test isolation rejected relative system variable: $key',
        );
      }
      final resolved = _physical(location);
      for (final profile in _physicalRealProfileRoots) {
        if (p.equals(profile, resolved) || p.isWithin(profile, resolved)) {
          throw StateError(
            'Test isolation rejected profile system variable: $key',
          );
        }
      }
      final home = Platform.environment['USERPROFILE'];
      if (Platform.isWindows &&
          home != null &&
          p.isWithin(_physical(p.dirname(home)), resolved)) {
        throw StateError(
          'Test isolation rejected user-profile system variable: $key',
        );
      }
    }
  }

  static TestEnvironment create({Map<String, String>? inherited}) {
    final original = <String, String>{
      for (final entry in (inherited ?? Platform.environment).entries)
        (Platform.isWindows ? entry.key.toUpperCase() : entry.key): entry.value,
    };
    final real = profileKeys
        .map((key) => original[key])
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toList();
    TestEnvironment._(Directory.current, const {}, real)._guardSystem(original);
    final parent = Directory(
      original['CXV_TEST_SANDBOX_PARENT'] ??
          p.absolute('build', 'test-sandboxes'),
    );
    TestEnvironment._(parent, const {}, real).guard(parent.path);
    parent.createSync(recursive: true);
    final root = parent.createTempSync('dart-');
    // Only operating-system/tool inputs required by these fixtures cross the boundary.
    final env = <String, String>{
      for (final key in [
        'PATH',
        'SYSTEMROOT',
        'WINDIR',
        'COMSPEC',
        'PATHEXT',
        'SYSTEMDRIVE',
        'PROGRAMFILES',
        'PROGRAMFILES(X86)',
        'PROGRAMW6432',
        'PROGRAMDATA',
        'ALLUSERSPROFILE',
        'COMMONPROGRAMFILES',
        'COMMONPROGRAMFILES(X86)',
        'COMMONPROGRAMW6432',
        'INCLUDE',
        'LIB',
        'LIBPATH',
        'FLUTTER_ROOT',
        'CARGO_HOME',
        'RUSTUP_HOME',
        'PUB_CACHE',
        'CODEX_SESSIONS_COLLECTOR_EXE',
        'CODEX_SESSIONS_HUB_EXE',
      ])
        if (original[key] != null) key: original[key]!,
    };
    for (final key in profileKeys) {
      final folder = Directory(p.join(root.path, key))
        ..createSync(recursive: true);
      env[key] = folder.path;
    }
    env.putIfAbsent(
      'CARGO_HOME',
      () => p.join(original['USERPROFILE'] ?? original['HOME']!, '.cargo'),
    );
    env.putIfAbsent(
      'RUSTUP_HOME',
      () => p.join(original['USERPROFILE'] ?? original['HOME']!, '.rustup'),
    );
    if (Platform.isWindows) {
      env['PSMODULEPATH'] = [
        r'C:\Program Files\PowerShell\7\Modules',
        p.join(
          original['SYSTEMROOT']!,
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'Modules',
        ),
      ].join(';');
    }
    // Windows and POSIX defaults agree on the same synthetic home.
    env['HOME'] = env['USERPROFILE']!;
    final sandbox = TestEnvironment._(root, Map.unmodifiable(env), real);
    sandbox.guard(root.path);

    return sandbox;
  }

  Map<String, String> fixtureEnvironment(
    Directory fixture, {
    String? queue,
    String? codex,
  }) {
    guard(fixture.path);
    final values = <String, String>{
      for (final key in profileKeys) key: p.join(fixture.path, key),
    };
    values['HOME'] = values['USERPROFILE']!;
    values['CODEX_SESSIONS_COLLECTOR_QUEUE'] =
        queue ?? p.join(fixture.path, 'queue');
    values['CODEX_HOME'] = codex ?? p.join(fixture.path, 'codex');
    for (final value in values.values) {
      guard(value);
      Directory(value).createSync(recursive: true);
    }
    return values;
  }

  String _physical(String path) {
    var cursor = p.normalize(p.absolute(path));
    final tail = <String>[];
    while (FileSystemEntity.typeSync(cursor, followLinks: false) ==
        FileSystemEntityType.notFound) {
      tail.insert(0, p.basename(cursor));
      final parent = p.dirname(cursor);
      if (parent == cursor) break;
      cursor = parent;
    }
    final resolved = FileSystemEntity.isDirectorySync(cursor)
        ? Directory(cursor).resolveSymbolicLinksSync()
        : File(cursor).resolveSymbolicLinksSync();
    return p.joinAll([resolved, ...tail]);
  }

  void guard(String path, {String? cwd}) {
    if (path.isEmpty) return;
    final resolved = _physical(
      p.isAbsolute(path) ? path : p.join(cwd ?? root.path, path),
    );
    final owned = _physical(root.path);
    if (!p.equals(owned, resolved) && !p.isWithin(owned, resolved)) {
      throw StateError(
        'Test profile isolation rejected an unowned path: $path',
      );
    }
    for (final real in _physicalRealProfileRoots) {
      // Root allocation must itself avoid inherited profile folders.
      final absolute = real;
      if (p.equals(absolute, resolved) || p.isWithin(absolute, resolved)) {
        throw StateError(
          'Test profile isolation rejected an inherited profile path: $path',
        );
      }
    }
  }

  void admit(
    String executable,
    List<String> args,
    Map<String, String> env,
    String cwd,
  ) {
    env = {
      for (final entry in env.entries)
        (Platform.isWindows ? entry.key.toUpperCase() : entry.key): entry.value,
    };
    _guardSystem(env);
    const scalarKeys = {
      'CODEX_SESSIONS_COLLECTOR_BUSY_TIMEOUT_MS',
      'CODEX_SESSIONS_COLLECTOR_TIMINGS',
      'CODEX_SESSIONS_HUB_OWNER_TOKEN',
      'CODEX_SESSIONS_HUB_MACHINE_TOKEN',
      'CSV_TEST_FIXTURE_ROOT',
      'CSV_TEST_FIXTURE_PIDS',
    };
    for (final key in env.keys) {
      if (!environment.containsKey(key) && !scalarKeys.contains(key)) {
        throw StateError(
          'Test profile isolation rejected environment key: $key',
        );
      }
      if (environment.containsKey(key) &&
          !profileKeys.contains(key) &&
          env[key] != environment[key]) {
        throw StateError(
          'Test profile isolation rejected tool environment override: $key',
        );
      }
    }
    for (final key in profileKeys) {
      final value = env[key];
      if (value == null || value.isEmpty || !p.isAbsolute(value)) {
        throw StateError('Test profile isolation requires $key');
      }
      guard(value);
    }
    for (final entry in env.entries) {
      if (entry.key.startsWith('CODEX_SESSIONS_COLLECTOR_') &&
          !const [
            'CODEX_SESSIONS_COLLECTOR_EXE',
            'CODEX_SESSIONS_COLLECTOR_BUSY_TIMEOUT_MS',
            'CODEX_SESSIONS_COLLECTOR_TIMINGS',
          ].contains(entry.key)) {
        guard(entry.value);
      }
    }
    final name = p.basename(executable).toLowerCase();
    for (final key in ['CSV_TEST_FIXTURE_ROOT']) {
      if (env[key] != null) guard(env[key]!);
    }
    _admitExecutable(executable, args, cwd);
    const flags = {
      '--db',
      '--standalone',
      '--settings',
      '--input',
      '--root',
      '--work',
      '--result',
      '--windows-root',
      '--wsl-root',
      '--wsl-unc-root',
      '--claude-root',
      '--claude-wsl-root',
      '--queue',
      '--log',
      '--data-dir',
      '--config',
      '--output',
    };
    for (var i = 0; i < args.length; i++) {
      final parts = args[i].split('=');
      if (parts.first == '--bind') {
        final value = parts.length > 1 ? parts.skip(1).join('=') : args[i + 1];
        final address = Uri.tryParse('http://$value');
        if (address == null ||
            !['127.0.0.1', '::1', '[::1]'].contains(address.host) ||
            !address.hasPort) {
          throw StateError('Test isolation rejected network bind endpoint');
        }
      }
      if (['--hub-url', '--hub'].contains(parts.first)) {
        guardEndpoint(parts.length > 1 ? parts.skip(1).join('=') : args[i + 1]);
      }
      if (!flags.contains(parts.first)) continue;
      final value = parts.length > 1
          ? parts.skip(1).join('=')
          : i + 1 < args.length
          ? args[++i]
          : '';
      guard(value, cwd: cwd);
      if (parts.first == '--settings' &&
          File(p.isAbsolute(value) ? value : p.join(cwd, value)).existsSync()) {
        _settings(File(p.isAbsolute(value) ? value : p.join(cwd, value)), cwd);
      }
    }
    // Hub's data and configuration arguments are positional.
    if (args.length >= 2 &&
        const ['codex', 'claude'].contains(args[0]) &&
        const ['ingest', 'parse'].contains(args[1])) {
      const switches = {
        '--no-drain',
        '--no-wait',
        '--no-wsl-projects',
        '--force',
        '--json',
        '--progress-json',
        '--cancel-stdin',
      };
      for (var i = 2; i < args.length; i++) {
        final arg = args[i];
        if (arg.startsWith('--')) {
          if (!arg.contains('=') && !switches.contains(arg)) {
            i++;
          }
        } else {
          guard(arg, cwd: cwd);
        }
      }
    }
    if (name.contains('sessions-hub') && args.length >= 3) {
      guard(args[1], cwd: cwd);
      guard(args[2], cwd: cwd);
    }
    if ((name.contains('collector') || name.contains('scan-launcher')) &&
        !args.any(
          (arg) => arg == '--settings' || arg.startsWith('--settings='),
        )) {
      final defaults = AppLocations.resolve(
        platform: AppLocations.currentPlatform,
        environment: env,
        executablePath: p.absolute(executable),
      );
      guard(defaults.settingsFile.path, cwd: cwd);
      if (defaults.settingsFile.existsSync()) {
        _settings(defaults.settingsFile, cwd);
      }
    }
    for (final path in [
      p.join(
        env['LOCALAPPDATA']!,
        'CodexSessionViewer',
        'collector',
        'resident.log',
      ),
      p.join(
        env['LOCALAPPDATA']!,
        'CodexSessionViewer',
        'collector',
        'resident.log.1',
      ),
      p.join(env['LOCALAPPDATA']!, 'CodexSessionViewer', 'run'),
      p.join(
        env['APPDATA']!,
        'CodexSessionViewer',
        'codex_sessions_viewer.sqlite',
      ),
      p.join(env['USERPROFILE']!, '.claude', 'projects'),
      p.join(env['CODEX_HOME']!, 'config.toml'),
      p.join(env['CLAUDE_CONFIG_DIR']!, 'settings.json'),
    ]) {
      guard(path);
    }
    // Guard every default mutable location, including adjacent-settings lookup
    // and lifecycle logs (which do not use the hook queue).
    for (final key in [
      'APPDATA',
      'LOCALAPPDATA',
      'XDG_CONFIG_HOME',
      'XDG_DATA_HOME',
      'XDG_STATE_HOME',
      'XDG_CACHE_HOME',
      'XDG_RUNTIME_DIR',
      'USERPROFILE',
      'HOME',
    ]) {
      guard(p.join(env[key]!, 'CodexSessionViewer'));
    }
    if (name.contains('collector') && p.isAbsolute(executable)) {
      final adjacent = File(p.join(p.dirname(executable), 'settings.toml'));
      if (!args.any((a) => a == '--settings' || a.startsWith('--settings=')) &&
          adjacent.existsSync()) {
        guard(adjacent.path);
      }
    }
  }

  void _admitExecutable(String executable, List<String> args, String cwd) {
    Never reject() => throw StateError(
      'Test profile isolation rejected executable or arguments: $executable $args',
    );
    final suffix = Platform.isWindows ? '.exe' : '';
    final repo = p.absolute('..');
    final target = p.join(repo, 'collector', 'target');
    final native = [
      for (final mode in ['debug', 'release'])
        for (final name in ['collector', 'hub', 'scan-launcher'])
          p.join(target, mode, 'codex-sessions-$name$suffix'),
    ];
    String physical;
    try {
      physical = _physical(executable);
    } catch (_) {
      reject();
    }
    final matching = native.where(
      (path) => p.equals(p.absolute(executable), path),
    );
    if (matching.isNotEmpty && p.isWithin(_physical(target), physical)) {
      guard(cwd);
      if (p.basename(executable).contains('sessions-hub')) {
        if (args.length != 3 ||
            !args[0].startsWith('127.0.0.1:') ||
            int.tryParse(args[0].split(':').last) == null) {
          reject();
        }
        guard(args[1], cwd: cwd);
        guard(args[2], cwd: cwd);
        return;
      }
      if (p.basename(executable).contains('sessions-collector')) {
        const commands = {
          'codex',
          'claude',
          'query',
          'hub',
          'resident',
          'serve',
          'client',
          'drain',
          'apply',
          'version',
          '--help',
        };
        if (args.isEmpty || !commands.contains(args[0])) reject();
        if (const ['codex', 'claude'].contains(args[0]) &&
            (args.length < 2 ||
                !const {
                  'setup',
                  'verify',
                  'status',
                  'scan',
                  'ingest',
                  'parse',
                  'notify',
                  'hook',
                }.contains(args[1]))) {
          reject();
        }
        if (args[0] == 'resident' &&
            (args.length < 2 ||
                !const {'info', 'status', 'stop'}.contains(args[1]))) {
          reject();
        }
      }
      // Unknown options are refused; all path options are checked by admit().
      const values = {
        '--db',
        '--standalone',
        '--settings',
        '--input',
        '--root',
        '--config',
        '--windows-root',
        '--wsl-root',
        '--wsl-unc-root',
        '--claude-root',
        '--claude-wsl-root',
        '--queue',
        '--log',
        '--data-dir',
        '--output',
        '--lifetime',
        '--parser-workers',
        '--flush-sessions',
        '--flush-bytes',
        '--hub-url',
        '--bind',
      };
      const switches = {
        '--no-drain',
        '--no-wait',
        '--no-wsl-projects',
        '--force',
        '--json',
        '--progress-json',
        '--cancel-stdin',
        '--help',
        '--apply',
        '--remove',
        '--local-proof',
        '--check-hub',
      };
      for (var i = 0; i < args.length; i++) {
        final flag = args[i].split('=').first;
        if (!flag.startsWith('--')) continue;
        if (switches.contains(flag)) continue;
        if (!values.contains(flag)) reject();
        if (!args[i].contains('=') && ++i >= args.length) reject();
      }
      return;
    }
    if (executable.toLowerCase().endsWith('pwsh.exe')) {
      final known = Platform.isWindows
          ? r'C:\Program Files\PowerShell\7\pwsh.exe'
          : '/usr/bin/pwsh';
      if (!p.equals(_physical(known), physical)) {
        reject();
      }
      if (args.length != 4 ||
          args[0] != '-NoProfile' ||
          args[1] != '-NonInteractive' ||
          args[2] != '-File' ||
          ![
            for (var i = 0; i < 3; i++)
              p.absolute('test/support/fixture_process_$i.ps1'),
          ].contains(args[3])) {
        reject();
      }
      return;
    }
    final cargoHome = environment['CARGO_HOME'];
    if (cargoHome != null &&
        p.equals(
          physical,
          _physical(p.join(cargoHome, 'bin', 'cargo$suffix')),
        )) {
      final expected = [
        'build',
        '--quiet',
        '--manifest-path',
        p.join(repo, 'collector', 'Cargo.toml'),
        '--bin',
        'codex-sessions-collector',
      ];
      if (args.join('|') != expected.join('|')) reject();
      return;
    }
    if (!Platform.isWindows) {
      if (executable == '/usr/bin/ln' && args.length == 2) {
        for (final path in args) {
          guard(path, cwd: cwd);
        }
        return;
      }
      if (executable == '/bin/ps' &&
          (args.join('|') == '-eo|pid=,args=' ||
              args.length == 4 &&
                  args[0] == '-p' &&
                  int.tryParse(args[1]) != null &&
                  args[2] == '-o' &&
                  args[3] == 'pid=')) {
        return;
      }
    }
    final flutter = environment['FLUTTER_ROOT'];
    if (flutter != null &&
        p.equals(
          physical,
          _physical(
            p.join(flutter, 'bin', 'cache', 'dart-sdk', 'bin', 'dart$suffix'),
          ),
        )) {
      var index = 0;
      if (args.isNotEmpty && args.first.startsWith('--packages=')) {
        if (!p.equals(
          p.absolute(args.first.substring(11)),
          p.absolute('.dart_tool/package_config.json'),
        )) {
          reject();
        }
        index++;
      }
      if (index >= args.length) reject();
      final script = args[index++];
      final helper = p.absolute(
        'test/database/helpers/database_process_actor.dart',
      );
      if (!p.equals(p.absolute(script), helper)) guard(script, cwd: cwd);
      for (final arg in args.skip(index)) {
        if (arg.contains('/') || arg.contains(r'\')) guard(arg, cwd: cwd);
      }
      return;
    }
    final system = environment['SYSTEMROOT'];
    if (system != null &&
        p.equals(
          physical,
          _physical(p.join(system, 'System32', 'fsutil.exe')),
        ) &&
        args.length == 4 &&
        args[0] == 'hardlink' &&
        args[1] == 'create') {
      guard(args[2], cwd: cwd);
      guard(args[3], cwd: cwd);
      return;
    }
    // Native builds are prepared by the outer proof runner, never by arbitrary child shells.
    reject();
  }

  void _settings(File file, String cwd) {
    final map = TomlDocument.parse(file.readAsStringSync()).toMap();
    final hub = map['hub'];
    if (hub is Map &&
        hub['url'] is String &&
        (hub['url'] as String).isNotEmpty) {
      guardEndpoint(hub['url'] as String);
    }
    for (final section in ['paths', 'logging', 'wsl']) {
      final values = map[section];
      if (values is! Map) continue;
      for (final entry in values.entries) {
        if (entry.value is String &&
            (entry.key.toString().endsWith('_path') ||
                entry.key.toString().contains('root') ||
                entry.key == 'log_file' ||
                entry.key == 'linux_root_unc')) {
          guard(entry.value as String, cwd: cwd);
        }
      }
    }
  }

  AppLocations get locations {
    final repo = p.absolute('..');
    return AppLocations(
      databaseFile: File(p.join(root.path, 'app', 'viewer.sqlite')),
      settingsFile: File(p.join(root.path, 'app', 'settings.toml')),
      logDirectory: Directory(p.join(root.path, 'logs')),
      queueDirectory: Directory(environment['CODEX_SESSIONS_COLLECTOR_QUEUE']!),
      backupDirectory: Directory(p.join(root.path, 'backups')),
      sqlDirectory: Directory(p.join(repo, 'sql')),
      assetsDirectory: Directory(p.join(repo, 'assets')),
      sampleSettingsFile: File(p.join(repo, 'settings.sample.toml')),
    );
  }

  Future<void> run(FutureOr<void> Function() body) async {
    for (final path in [
      locations.databaseFile.path,
      locations.settingsFile.path,
      locations.logDirectory.path,
      locations.queueDirectory.path,
      locations.backupDirectory.path,
    ]) {
      guard(path);
    }
    await runZoned(
      () => AppEnvironment.scoped(
        environment: environment,
        admit: admit,
        workingDirectory: root.path,
        initializeChildIsolate: install,
        body: () => AppLocations.scoped(
          locations,
          () => IOOverrides.runZoned(
            () async => await body(),
            getSystemTempDirectory: () => Directory(environment['TEMP']!),
          ),
        ),
      ),
      zoneValues: {_key: this},
    );
  }
}

String _testExecutable(String executable) {
  if (executable == 'cargo') {
    return p.join(
      TestEnvironment.current.environment['CARGO_HOME']!,
      'bin',
      Platform.isWindows ? 'cargo.exe' : 'cargo',
    );
  }
  if (!Platform.isWindows && executable == 'ln') return '/usr/bin/ln';
  if (!Platform.isWindows && executable == 'ps') return '/bin/ps';
  return executable;
}

Future<Process> startTestProcess(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
  String? workingDirectory,
  bool runInShell = false,
  bool includeParentEnvironment = true,
  ProcessStartMode mode = ProcessStartMode.normal,
  Map<String, dynamic>? hookInput,
}) async {
  TestEnvironment.current; // Fail closed if this harness omitted its config.
  final transcript = hookInput?['transcript_path'];
  if (transcript is String) {
    TestEnvironment.current.guard(transcript, cwd: workingDirectory);
  }
  final process = await AppEnvironment.start(
    _testExecutable(executable),
    arguments,
    environment: environment,
    workingDirectory: workingDirectory,
    runInShell: runInShell,
    includeParentEnvironment: includeParentEnvironment,
    mode: mode,
  );
  if (hookInput != null) {
    process.stdin.writeln(jsonEncode(hookInput));
    await process.stdin.close();
  }
  return process;
}

Future<ProcessResult> runTestProcess(
  String executable,
  List<String> arguments, {
  Map<String, String>? environment,
  String? workingDirectory,
  bool runInShell = false,
  bool includeParentEnvironment = true,
  Encoding? stdoutEncoding = systemEncoding,
  Encoding? stderrEncoding = systemEncoding,
}) {
  TestEnvironment.current;
  return AppEnvironment.run(
    _testExecutable(executable),
    arguments,
    environment: environment,
    workingDirectory: workingDirectory,
    runInShell: runInShell,
    includeParentEnvironment: includeParentEnvironment,
    stdoutEncoding: stdoutEncoding,
    stderrEncoding: stderrEncoding,
  );
}

final class _TestIOOverrides extends IOOverrides {
  _TestIOOverrides(this.temp);
  final Directory temp;
  @override
  Directory getSystemTempDirectory() => temp;

  // Dart 3.12's IOOverrides defaults omit the terminator required by the
  // native file-type API. Preserve real file/link checks while redirecting temp.
  @override
  Future<FileSystemEntityType> fseGetType(String path, bool followLinks) =>
      super.fseGetType('$path\u0000', followLinks);
  @override
  FileSystemEntityType fseGetTypeSync(String path, bool followLinks) =>
      super.fseGetTypeSync('$path\u0000', followLinks);
}
