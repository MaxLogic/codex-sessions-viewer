import 'dart:io';

import 'package:codex_sessions_viewer/src/platform/app_locations.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/config/default_session_folders.dart';
import 'package:codex_sessions_viewer/src/platform/wsl_default_distro_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'Windows keeps roaming database and local queue with adjacent settings',
    () {
      final root = Directory.systemTemp.createTempSync('locations-win-');
      addTearDown(() => root.deleteSync(recursive: true));
      final exe = p.join(root.path, 'viewer.exe');
      File(p.join(root.path, 'settings.toml')).writeAsStringSync('');
      final locations = AppLocations.resolve(
        platform: AppHostPlatform.windows,
        environment: {
          'APPDATA': p.join(root.path, 'Roaming'),
          'LOCALAPPDATA': p.join(root.path, 'Local'),
        },
        executablePath: exe,
      );
      expect(
        locations.databaseFile.path,
        p.join(
          root.path,
          'Roaming',
          'CodexSessionViewer',
          'codex_sessions_viewer.sqlite',
        ),
      );
      expect(locations.settingsFile.path, p.join(root.path, 'settings.toml'));
      expect(
        locations.queueDirectory.path,
        p.join(root.path, 'Local', 'CodexSessionViewer', 'collector', 'queue'),
      );
      expect(locations.sqlDirectory.path, p.join(root.path, 'sql'));
      expect(locations.assetsDirectory.path, p.join(root.path, 'assets'));
      expect(
        locations.backupDirectory.path,
        p.join(root.path, 'Roaming', 'CodexSessionViewer', 'backups'),
      );
      expect(locations.logDirectory.path, 'logs');
      File(p.join(root.path, 'settings.toml')).deleteSync();
      final fresh = AppLocations.resolve(
        platform: AppHostPlatform.windows,
        environment: {
          'APPDATA': p.join(root.path, 'Roaming'),
          'LOCALAPPDATA': p.join(root.path, 'Local'),
        },
        executablePath: exe,
      );
      expect(
        fresh.settingsFile.path,
        p.join(root.path, 'Roaming', 'CodexSessionViewer', 'settings.toml'),
      );
    },
    // The adjacent-settings probe needs Windows paths on a Windows disk.
    skip: Platform.isWindows ? false : 'Windows locations need a Windows host.',
  );

  test('macOS uses user support, logs, caches and app resources', () {
    final locations = AppLocations.resolve(
      platform: AppHostPlatform.macos,
      environment: {'HOME': '/Users/tester'},
      executablePath: '/Applications/Viewer.app/Contents/MacOS/viewer',
    );
    expect(
      p.posix.normalize(locations.databaseFile.path.replaceAll('\\', '/')),
      '/Users/tester/Library/Application Support/CodexSessionViewer/codex_sessions_viewer.sqlite',
    );
    expect(
      locations.settingsFile.path.replaceAll('\\', '/'),
      '/Users/tester/Library/Application Support/CodexSessionViewer/settings.toml',
    );
    expect(
      locations.logDirectory.path.replaceAll('\\', '/'),
      '/Users/tester/Library/Logs/CodexSessionViewer',
    );
    expect(
      locations.queueDirectory.path.replaceAll('\\', '/'),
      '/Users/tester/Library/Caches/CodexSessionViewer/collector/queue',
    );
    expect(
      locations.sqlDirectory.path.replaceAll('\\', '/'),
      '/Applications/Viewer.app/Contents/Resources/sql',
    );
  });

  test('Linux honors XDG folders and bundled data', () {
    final locations = AppLocations.resolve(
      platform: AppHostPlatform.linux,
      environment: {
        'HOME': '/home/tester',
        'XDG_DATA_HOME': '/custom/data',
        'XDG_CONFIG_HOME': '/custom/config',
        'XDG_STATE_HOME': '/custom/state',
        'XDG_CACHE_HOME': '/custom/cache',
      },
      executablePath: '/opt/viewer/bin/viewer',
    );
    expect(
      locations.databaseFile.path.replaceAll('\\', '/'),
      '/custom/data/CodexSessionViewer/codex_sessions_viewer.sqlite',
    );
    expect(
      locations.settingsFile.path.replaceAll('\\', '/'),
      '/custom/config/CodexSessionViewer/settings.toml',
    );
    expect(
      locations.logDirectory.path.replaceAll('\\', '/'),
      '/custom/state/CodexSessionViewer/logs',
    );
    expect(
      locations.queueDirectory.path.replaceAll('\\', '/'),
      '/custom/cache/CodexSessionViewer/collector/queue',
    );
    expect(
      locations.sqlDirectory.path.replaceAll('\\', '/'),
      '/opt/viewer/bin/data/sql',
    );
    expect(
      locations.assetsDirectory.path.replaceAll('\\', '/'),
      '/opt/viewer/bin/data/assets',
    );
    expect(
      locations.backupDirectory.path.replaceAll('\\', '/'),
      '/custom/data/CodexSessionViewer/backups',
    );
    expect(
      () => AppLocations.resolve(
        platform: AppHostPlatform.linux,
        environment: const {},
        executablePath: '/opt/viewer/bin/viewer',
      ),
      throwsStateError,
    );
  });

  test(
    'first-run sample fills blank session roots and preserves an existing file',
    () async {
      final root = await Directory.systemTemp.createTemp('locations-sample-');
      addTearDown(() => root.delete(recursive: true));
      final locations = AppLocations.resolve(
        platform: AppLocations.currentPlatform,
        environment: {
          'APPDATA': p.join(root.path, 'Roaming'),
          'LOCALAPPDATA': p.join(root.path, 'Local'),
          'HOME': p.join(root.path, 'home'),
        },
        executablePath: p.join(
          root.path,
          Platform.isWindows ? 'viewer.exe' : 'viewer',
        ),
      );
      final sample = locations.sampleSettingsFile;
      await sample.parent.create(recursive: true);
      await sample.writeAsString(
        '[app]\nfirst_run = true\n[paths]\nwindows_codex_path = ""\nwsl_codex_unc_path = ""\n[wsl]\ndistro = ""\nlinux_home = ""\nlinux_root_unc = ""\n',
      );
      final original = await sample.readAsString();
      final settings = locations.settingsFile;
      final repository = SettingsRepository(
        settings,
        locations: locations,
        wslDetector: const _FixedWslDetector(),
      );
      final first = await repository.loadOrCreate();
      expect(first.app.firstRun, isTrue);
      expect(
        first.paths.windowsCodexPath,
        DefaultSessionFolders.current().windowsCodexPath,
      );
      expect(first.wsl.distro, 'Ubuntu');
      expect(first.wsl.linuxHome, '/home/tester');
      expect((await repository.loadOrCreate()).wsl.distro, 'Ubuntu');
      expect(await sample.readAsString(), original);

      await settings.writeAsString(
        '[paths]\nwindows_codex_path = ""\n[wsl]\ndistro = ""\n',
      );
      final explicit = await repository.loadOrCreate();
      expect(explicit.paths.windowsCodexPath, isEmpty);
      expect(explicit.wsl.distro, isEmpty);
      expect(
        await settings.readAsString(),
        '[paths]\nwindows_codex_path = ""\n[wsl]\ndistro = ""\n',
      );
    },
  );
}

final class _FixedWslDetector implements WslDefaultDistroDetector {
  const _FixedWslDetector();

  @override
  Future<WslDistroDefaults?> detect() async =>
      const WslDistroDefaults(distro: 'Ubuntu', linuxHome: '/home/tester');
}
