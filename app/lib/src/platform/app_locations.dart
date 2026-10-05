import 'dart:io';

import 'package:path/path.dart' as p;

enum AppHostPlatform { windows, macos, linux }

/// The only source of platform-specific app storage and bundled resource paths.
class AppLocations {
  const AppLocations({
    required this.databaseFile,
    required this.settingsFile,
    required this.logDirectory,
    required this.queueDirectory,
    required this.backupDirectory,
    required this.sqlDirectory,
    required this.assetsDirectory,
    required this.sampleSettingsFile,
  });

  final File databaseFile;
  final File settingsFile;
  final Directory logDirectory;
  final Directory queueDirectory;
  final Directory backupDirectory;
  final Directory sqlDirectory;
  final Directory assetsDirectory;
  final File sampleSettingsFile;

  static AppHostPlatform get currentPlatform {
    if (Platform.isWindows) return AppHostPlatform.windows;
    if (Platform.isMacOS) return AppHostPlatform.macos;
    if (Platform.isLinux) return AppHostPlatform.linux;
    throw UnsupportedError('Unsupported application platform');
  }

  factory AppLocations.current() => AppLocations.resolve(
    platform: currentPlatform,
    environment: Platform.environment,
    executablePath: Platform.resolvedExecutable,
  );

  factory AppLocations.resolve({
    required AppHostPlatform platform,
    required Map<String, String> environment,
    required String executablePath,
  }) {
    final path = p.Context(
      style: platform == AppHostPlatform.windows
          ? p.Style.windows
          : p.Style.posix,
    );
    final exeDir = path.dirname(executablePath);
    String? nonEmpty(String key) => switch (environment[key]) {
      final String value when value.trim().isNotEmpty => value,
      _ => null,
    };
    String home() =>
        nonEmpty('HOME') ??
        (throw StateError('HOME is required to locate application data'));
    late final String data;
    late final String config;
    late final String logs;
    late final String cache;
    late final String resources;
    switch (platform) {
      case AppHostPlatform.windows:
        final roaming = nonEmpty('APPDATA');
        data = roaming == null
            ? exeDir
            : path.join(roaming, 'CodexSessionViewer');
        config = data;
        cache = path.join(
          nonEmpty('LOCALAPPDATA') ?? Directory.systemTemp.path,
          'CodexSessionViewer',
        );
        logs = path.join('logs');
        resources = exeDir;
      case AppHostPlatform.macos:
        data = path.join(
          home(),
          'Library',
          'Application Support',
          'CodexSessionViewer',
        );
        config = data;
        logs = path.join(home(), 'Library', 'Logs', 'CodexSessionViewer');
        cache = path.join(home(), 'Library', 'Caches', 'CodexSessionViewer');
        final marker =
            '${path.separator}Contents${path.separator}MacOS${path.separator}';
        final markerAt = executablePath.indexOf(marker);
        resources = markerAt < 0
            ? path.join(exeDir, 'data')
            : path.join(
                executablePath.substring(0, markerAt),
                'Contents',
                'Resources',
              );
      case AppHostPlatform.linux:
        data = path.join(
          nonEmpty('XDG_DATA_HOME') ?? path.join(home(), '.local', 'share'),
          'CodexSessionViewer',
        );
        config = path.join(
          nonEmpty('XDG_CONFIG_HOME') ?? path.join(home(), '.config'),
          'CodexSessionViewer',
        );
        logs = path.join(
          nonEmpty('XDG_STATE_HOME') ?? path.join(home(), '.local', 'state'),
          'CodexSessionViewer',
          'logs',
        );
        cache = path.join(
          nonEmpty('XDG_CACHE_HOME') ?? path.join(home(), '.cache'),
          'CodexSessionViewer',
        );
        resources = path.join(exeDir, 'data');
    }
    final adjacentSettings = File(path.join(exeDir, 'settings.toml'));
    final settings =
        platform == AppHostPlatform.windows && adjacentSettings.existsSync()
        ? adjacentSettings
        : File(path.join(config, 'settings.toml'));
    final database = File(path.join(data, 'codex_sessions_viewer.sqlite'));
    return AppLocations(
      databaseFile: database,
      settingsFile: settings,
      logDirectory: Directory(logs),
      queueDirectory: Directory(path.join(cache, 'collector', 'queue')),
      backupDirectory: Directory(path.join(data, 'backups')),
      sqlDirectory: Directory(path.join(resources, 'sql')),
      assetsDirectory: Directory(path.join(resources, 'assets')),
      sampleSettingsFile: File(path.join(resources, 'settings.sample.toml')),
    );
  }
}
