import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/config/default_session_folders.dart';
import 'package:codex_sessions_viewer/src/platform/wsl_default_distro_detector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

void main() {
  test('session pane split fraction round trips through settings', () {
    final settings = AppSettings.fromTomlMap({
      'ui': {
        'session_table': {'pane_fraction': 0.62},
      },
    });
    expect(settings.ui.sessionTable.paneFraction, 0.62);
    expect(
      ((settings.toTomlMap()['ui'] as Map)['session_table']
          as Map)['pane_fraction'],
      0.62,
    );
    expect(AppSettings.fromTomlMap(settings.toTomlMap()), settings);
  });

  test(
    'maintenance schedules migrate legacy keys and round trip new settings',
    () {
      final defaults = AppSettings.defaults().toTomlMap();
      expect(defaults['maintenance'], {
        'database_optimize_enabled': true,
        'database_optimize_interval_days': 7,
      });
      expect((defaults['pricing'] as Map)['automatic_refresh_enabled'], isTrue);
      expect((defaults['pricing'] as Map)['refresh_interval_hours'], 6);
      expect(AppSettings.defaults().pricing.refreshUtcSlots, isTrue);
      expect(AppSettings.fromTomlMap({}).pricing.refreshUtcSlots, isTrue);
      for (final (input, hours) in [
        (<String, dynamic>{'cache_pricing_hours': 72}, 72),
        (
          <String, dynamic>{
            'cache_pricing_hours': 72,
            'refresh_interval_hours': 48,
          },
          48,
        ),
        (
          <String, dynamic>{
            'cache_pricing_hours': 'ignored',
            'refresh_interval_hours': 1,
          },
          1,
        ),
        (<String, dynamic>{'refresh_interval_hours': 720}, 720),
        (<String, dynamic>{'refresh_interval_hours': 6}, 6),
        (<String, dynamic>{'cache_pricing_hours': 24}, 24),
      ]) {
        final loaded = AppSettings.fromTomlMap({
          'pricing': {...input, 'automatic_refresh_enabled': false},
          'maintenance': {
            'database_optimize_enabled': false,
            'database_optimize_interval_days': 365,
          },
        });
        expect(loaded.pricing.refreshUtcSlots, isFalse);
        final encoded = loaded.copyWith().toTomlMap();
        expect((encoded['pricing'] as Map)['refresh_interval_hours'], hours);
        expect(
          (encoded['pricing'] as Map).containsKey('cache_pricing_hours'),
          isFalse,
        );
        expect(
          (encoded['pricing'] as Map)['automatic_refresh_enabled'],
          isFalse,
        );
        expect(encoded['maintenance'], {
          'database_optimize_enabled': false,
          'database_optimize_interval_days': 365,
        });
        expect(AppSettings.fromTomlMap(encoded), loaded);
      }
      expect(
        AppSettings.fromTomlMap({
          'maintenance': {'database_optimize_interval_days': 1},
        }).toTomlMap()['maintenance'],
        {
          'database_optimize_enabled': true,
          'database_optimize_interval_days': 1,
        },
      );
    },
  );

  test(
    'maintenance schedule ranges reject invalid values even when disabled',
    () {
      for (final (group, field, maximum) in [
        ('pricing', 'refresh_interval_hours', 720),
        ('pricing', 'cache_pricing_hours', 720),
        ('maintenance', 'database_optimize_interval_days', 365),
      ]) {
        for (final value in <Object>[0, -1, maximum + 1, 1.5, '24', false]) {
          expect(
            () => AppSettings.fromTomlMap({
              group: {
                field: value,
                if (group == 'pricing') 'automatic_refresh_enabled': false,
                if (group == 'maintenance') 'database_optimize_enabled': false,
              },
            }),
            throwsA(isA<SettingsValidationException>()),
            reason: '$group.$field=$value',
          );
        }
      }
      for (final (group, field) in [
        ('pricing', 'automatic_refresh_enabled'),
        ('maintenance', 'database_optimize_enabled'),
      ]) {
        expect(
          () => AppSettings.fromTomlMap({
            group: {field: 'true'},
          }),
          throwsA(isA<SettingsValidationException>()),
        );
      }
    },
  );

  late Directory tempDir;
  late File settingsFile;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('csv_settings_test_');
    settingsFile = File(
      '${tempDir.path}${Platform.pathSeparator}settings.toml',
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('creates default settings.toml when missing', () async {
    final repository = SettingsRepository(settingsFile);

    final settings = await repository.loadOrCreate();

    expect(settingsFile.existsSync(), isTrue);
    expect(
      settings.paths.windowsCodexPath,
      DefaultSessionFolders.current().windowsCodexPath,
    );
    // Without a detector the WSL defaults stay empty.
    expect(settings.wsl.distro, isEmpty);
    expect(settings.app.startWithWindows, isTrue);

    final tomlText = await settingsFile.readAsString();
    for (final header in [
      '[app]',
      '[paths]',
      '[wsl]',
      '[scanner]',
      '[ui]',
      '[terminal]',
      '[terminal.alacritty]',
      '[terminal.windows_terminal]',
      '[tool_output]',
      '[voice_over]',
      '[pricing]',
      '[pricing.openrouter]',
      '[logging]',
    ]) {
      expect(tomlText, contains(header));
    }
    expect(tomlText, contains('start_with_windows = true'));
    expect(tomlText, isNot(contains('[project')));
  });

  test('saves and loads required settings groups without data loss', () async {
    final repository = SettingsRepository(settingsFile);
    final defaults = AppSettings.defaults();
    final original = defaults.copyWith(
      app: const GeneralAppSettings(firstRun: true, startWithWindows: false),
      paths: const PathSettings(
        windowsCodexPath: r'D:\Codex Sessions',
        wslCodexUncPath: r'\\wsl.localhost\Debian\home\dev\.codex',
      ),
      wsl: const WslSettings(
        distro: 'Debian',
        linuxHome: '/home/dev',
        linuxRootUnc: r'\\wsl.localhost\Debian\',
      ),
      scanner: const ScannerSettings(
        backgroundRescanEnabled: false,
        backgroundRescanIntervalSeconds: 900,
      ),
      ui: const UiSettings(
        theme: AppThemeMode.highContrastDark,
        useSystemAccentColor: false,
        fontSize: 18,
        density: UiDensity.compact,
        showTextOnButtons: false,
        showIcons: true,
        window: WindowPlacementSettings(
          x: 20,
          y: 30,
          width: 1200,
          height: 800,
          isMaximized: true,
        ),
        sessionTable: SessionTableSettings(
          columnWidths: {'path': 320},
          newestPerProjectOnly: true,
          sorts: [
            SessionTableSortSettings(
              column: 'last_message_at',
              ascending: false,
            ),
            SessionTableSortSettings(column: 'project', ascending: true),
          ],
        ),
      ),
      terminal: const TerminalSettings(
        defaultTerminal: 'windows_terminal',
        profiles: {
          'alacritty': TerminalProfileSettings(
            enabled: false,
            exe: r'C:\Tools\Alacritty\alacritty.exe',
          ),
          'windows_terminal': TerminalProfileSettings(
            enabled: true,
            exe: r'C:\Users\dev\AppData\Local\Microsoft\WindowsApps\wt.exe',
          ),
        },
      ),
      toolOutput: const ToolOutputSettings(
        indexToolOutput: true,
        maxToolOutputPreviewChars: 500,
        maxToolOutputStoreChars: 750,
        collapseToolOutputByDefault: false,
      ),
      voiceOver: VoiceOverSettings(
        enabled: false,
        preferWav: false,
        fallbackToScreenReader: true,
        events: {
          ...defaults.voiceOver.events,
          'scan_started': const VoiceOverEventSettings(
            text: 'Begin scan',
            wav: r'assets\voice\begin.wav',
          ),
          'export_finished': const VoiceOverEventSettings(
            text: 'Export complete',
            wav: r'D:\Sounds\export.wav',
          ),
        },
      ),
      pricing: PricingSettings(
        provider: 'openrouter',
        useExternalPricing: false,
        cachePricingHours: 72,
        fallbackToOverrides: true,
        openRouter: const OpenRouterSettings(
          modelsEndpoint: 'https://openrouter.ai/api/v1/models',
          apiKey: 'local-secret',
        ),
        overrides: {
          ...defaults.pricing.overrides,
          'openai/gpt-5.5-thinking': const PricingOverrideSettings(
            prompt: '0.000001',
            completion: '0.000002',
            inputCacheRead: '0.0000001',
            inputCacheWrite: '0.0000005',
            internalReasoning: '0.000003',
          ),
        },
      ),
      logging: const LoggingSettings(
        level: 'debug',
        logFile: r'D:\Logs\codex-viewer.log',
        maxLogFiles: 9,
        maxLogSizeMb: 25,
      ),
    );

    await repository.save(original);
    final loaded = await repository.loadOrCreate();

    expect(loaded, original);
  });

  test('parses and saves start with Windows preference', () async {
    await settingsFile.writeAsString('''
[app]
start_with_windows = false
''');

    final repository = SettingsRepository(settingsFile);
    final loaded = await repository.loadOrCreate();

    expect(loaded.app.startWithWindows, isFalse);

    await repository.save(
      loaded.copyWith(app: loaded.app.copyWith(startWithWindows: true)),
    );
    final savedText = await settingsFile.readAsString();
    expect(savedText, contains('start_with_windows = true'));

    await settingsFile.writeAsString('[app]\n');
    final defaulted = await repository.loadOrCreate();
    expect(defaulted.app.startWithWindows, isTrue);
  });

  test('rejects invalid enum values with a field-specific error', () async {
    await settingsFile.writeAsString('''
[ui]
theme = "sepia"
''');

    final repository = SettingsRepository(settingsFile);

    expect(
      repository.loadOrCreate,
      throwsA(
        isA<SettingsValidationException>().having(
          (error) => error.field,
          'field',
          'ui.theme',
        ),
      ),
    );
  });

  test('parses and saves ui motion preference', () async {
    await settingsFile.writeAsString('''
[ui]
motion = "normal"
''');

    final repository = SettingsRepository(settingsFile);
    final loaded = await repository.loadOrCreate();

    expect(loaded.ui.motion, AppMotionMode.normal);

    await repository.save(
      loaded.copyWith(ui: loaded.ui.copyWithMotion(AppMotionMode.reduced)),
    );
    final savedText = await settingsFile.readAsString();
    expect(savedText, contains("motion = 'reduced'"));

    await settingsFile.writeAsString('[ui]\n');
    final defaulted = await repository.loadOrCreate();
    expect(defaulted.ui.motion, AppMotionMode.system);

    await settingsFile.writeAsString('''
[ui]
motion = "spinning"
''');

    expect(
      repository.loadOrCreate,
      throwsA(
        isA<SettingsValidationException>().having(
          (error) => error.field,
          'field',
          'ui.motion',
        ),
      ),
    );
  });

  test('partial nested tables overlay defaults', () async {
    await settingsFile.writeAsString(r'''
[terminal.alacritty]
exe = 'D:\Apps\alacritty.exe'

[voice_over.events.copied]
text = 'Copied item'

[pricing.overrides.'local/model']
prompt = '0.5'
''');

    final repository = SettingsRepository(settingsFile);
    final settings = await repository.loadOrCreate();

    expect(settings.terminal.profiles['alacritty']?.enabled, isTrue);
    expect(
      settings.terminal.profiles['alacritty']?.exe,
      r'D:\Apps\alacritty.exe',
    );
    expect(settings.terminal.profiles, contains('windows_terminal'));
    expect(settings.voiceOver.events['copied']?.text, 'Copied item');
    expect(
      settings.voiceOver.events['copied']?.wav,
      r'assets\voice\copied.wav',
    );
    expect(settings.voiceOver.events, contains('scan_started'));
    expect(settings.pricing.overrides['local/model']?.prompt, '0.5');
    expect(settings.pricing.overrides['local/model']?.completion, '0');
    expect(settings.pricing.overrides, contains('openai/gpt-5.5-thinking'));
  });

  test('packaged sample refreshes public prices in six-hour UTC slots', () {
    final sample = File('../settings.sample.toml').readAsStringSync();
    final settings = AppSettings.fromTomlMap(
      TomlDocument.parse(sample).toMap(),
    );
    expect(settings.pricing.useExternalPricing, isTrue);
    expect(settings.pricing.automaticRefreshEnabled, isTrue);
    expect(settings.pricing.refreshIntervalHours, 6);
    expect(settings.pricing.refreshUtcSlots, isTrue);
    // Public catalog only: no provider key and no hub credential.
    expect(settings.pricing.openRouter.apiKey, isEmpty);
    expect(sample, isNot(contains('hub_token')));
    expect(sample, isNot(contains('hub_url')));
    expect(settings.hub, const HubSettings());
  });

  test(
    'one hub setting: legacy pricing hub URL migrates and a legacy token is kept untouched',
    () async {
      final legacy = AppSettings.fromTomlMap({
        'pricing': {
          'hub_url': 'https://hub.example.test/base',
          'hub_token': 'legacy-machine-secret',
          'hub_machine_id': 'laptop-1',
        },
      });
      expect(legacy.hub.url, 'https://hub.example.test/base');
      expect(legacy.hasLegacyHubToken, isTrue);
      expect(AppSettings.defaults().hasLegacyHubToken, isFalse);
      final encoded = legacy.toTomlMap();
      final pricing = encoded['pricing'] as Map;
      expect(pricing.keys, isNot(contains('hub_url')));
      // Price sync no longer reads them, but secrets are never rewritten or
      // dropped without an explicit request.
      expect(pricing['hub_token'], 'legacy-machine-secret');
      expect(pricing['hub_machine_id'], 'laptop-1');
      expect((encoded['hub'] as Map)['url'], 'https://hub.example.test/base');
      // Edits made through copyWith keep the legacy keys.
      final edited = legacy.copyWith(
        pricing: PricingSettings(
          provider: legacy.pricing.provider,
          useExternalPricing: false,
          fallbackToOverrides: legacy.pricing.fallbackToOverrides,
          openRouter: legacy.pricing.openRouter,
          overrides: legacy.pricing.overrides,
        ),
      );
      expect(
        (edited.toTomlMap()['pricing'] as Map)['hub_token'],
        'legacy-machine-secret',
      );
      // An explicit [hub] URL wins over the legacy key.
      expect(
        AppSettings.fromTomlMap({
          'hub': {'url': 'https://current.example.test'},
          'pricing': {'hub_url': 'https://legacy.example.test'},
        }).hub.url,
        'https://current.example.test',
      );
      final temp = await Directory.systemTemp.createTemp('hub_settings_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.toml');
      await SettingsRepository(file).save(legacy);
      final saved = await file.readAsString();
      expect(saved, contains('https://hub.example.test/base'));
      final reloaded = await SettingsRepository(file).loadOrCreate();
      expect(reloaded.hasLegacyHubToken, isTrue);
      // A later load-modify-save through the repository keeps them too.
      await SettingsRepository(file).update(
        (current) => current.copyWith(
          app: current.app.copyWith(startWithWindows: false),
        ),
      );
      final stored =
          TomlDocument.parse(await file.readAsString()).toMap()['pricing']
              as Map;
      expect(stored['hub_token'], 'legacy-machine-secret');
      expect(stored['hub_machine_id'], 'laptop-1');
    },
  );

  group('default session folders', () {
    final windows = p.windows;

    test('follow USERPROFILE and name no particular user', () {
      final folders = DefaultSessionFolders.fromEnvironment({
        'USERPROFILE': r'D:\Profiles\ada',
      }, pathContext: windows);
      expect(folders.windowsCodexPath, r'D:\Profiles\ada\.codex');
      expect(folders.claudeProjectsRoot, r'D:\Profiles\ada\.claude\projects');
      expect(folders.wslDistro, isEmpty);
      expect(folders.wslLinuxHome, isEmpty);
      expect(folders.wslLinuxRootUnc, isEmpty);
      expect(folders.wslCodexUncPath, isEmpty);

      final settings = AppSettings.defaults(folders: folders);
      expect(settings.paths.windowsCodexPath, r'D:\Profiles\ada\.codex');
      expect(settings.paths.wslCodexUncPath, isEmpty);
      expect(settings.wsl.distro, isEmpty);
      expect(settings.wsl.linuxHome, isEmpty);
      expect(settings.wsl.linuxRootUnc, isEmpty);
      final toml = settings.toTomlMap().toString().toLowerCase();
      expect(toml, isNot(contains('pawel')));
      expect(toml, isNot(contains('ubuntu')));
    });

    test('CODEX_HOME wins over the profile folder; HOME is the fallback', () {
      expect(
        DefaultSessionFolders.fromEnvironment({
          'USERPROFILE': r'C:\Users\ada',
          'CODEX_HOME': r'E:\codex-home',
        }, pathContext: windows).windowsCodexPath,
        r'E:\codex-home',
      );
      final posix = DefaultSessionFolders.fromEnvironment({
        'HOME': '/Users/ada',
      }, pathContext: p.posix);
      expect(posix.windowsCodexPath, '/Users/ada/.codex');
      expect(posix.claudeProjectsRoot, '/Users/ada/.claude/projects');
      final none = DefaultSessionFolders.fromEnvironment(
        const {},
        pathContext: windows,
      );
      expect(none.windowsCodexPath, isEmpty);
      expect(none.claudeProjectsRoot, isEmpty);
    });

    test('a detected WSL distribution fills the WSL defaults', () {
      final folders = DefaultSessionFolders.fromEnvironment(
        {'USERPROFILE': r'C:\Users\ada'},
        wsl: const WslDistroDefaults(distro: 'Debian', linuxHome: '/home/ada'),
        pathContext: windows,
      );
      final settings = AppSettings.defaults(folders: folders);
      expect(settings.wsl.distro, 'Debian');
      expect(settings.wsl.linuxHome, '/home/ada');
      expect(settings.wsl.linuxRootUnc, r'\\wsl.localhost\Debian\');
      expect(
        settings.paths.wslCodexUncPath,
        r'\\wsl.localhost\Debian\home\ada\.codex',
      );
      expect(folders.withWsl(null).wslCodexUncPath, isEmpty);
    });

    test('the environment defaults are built once', () {
      expect(identical(AppSettings.defaults(), AppSettings.defaults()), isTrue);
    });

    test('parses the WSL environment probe and rejects unusable output', () {
      final parsed = WslDistroDefaults.parse('Debian\r\n/home/ada\r\n');
      expect(parsed?.distro, 'Debian');
      expect(parsed?.linuxHome, '/home/ada');
      expect(WslDistroDefaults.parse(''), isNull);
      expect(WslDistroDefaults.parse('/home/ada\n'), isNull);
      expect(WslDistroDefaults.parse('Debian\nrelative\n'), isNull);
      expect(
        WslDistroDefaults.parse(
          r'bad\name'
          '\n/home/ada\n',
        ),
        isNull,
      );
    });

    test('explicit settings still win over the derived defaults', () {
      final loaded = AppSettings.fromTomlMap({
        'paths': {
          'windows_codex_path': r'X:\explicit\.codex',
          'wsl_codex_unc_path': '',
        },
        'wsl': {'distro': 'Alpine'},
      });
      expect(loaded.paths.windowsCodexPath, r'X:\explicit\.codex');
      expect(loaded.paths.wslCodexUncPath, isEmpty);
      expect(loaded.wsl.distro, 'Alpine');
    });

    test('a new settings file stores the detected WSL defaults', () async {
      final temp = await Directory.systemTemp.createTemp('default_folders_');
      addTearDown(() => temp.delete(recursive: true));
      final file = File(p.join(temp.path, 'settings.toml'));
      final created = await SettingsRepository(
        file,
        wslDetector: const _FixedWslDetector(
          WslDistroDefaults(distro: 'Debian', linuxHome: '/home/ada'),
        ),
      ).loadOrCreate();
      expect(created.wsl.distro, 'Debian');
      expect(
        created.paths.wslCodexUncPath,
        r'\\wsl.localhost\Debian\home\ada\.codex',
      );
      final reloaded = await SettingsRepository(file).loadOrCreate();
      expect(reloaded.wsl.distro, 'Debian');
      expect(
        reloaded.paths.windowsCodexPath,
        DefaultSessionFolders.current().windowsCodexPath,
      );
    });
  });
}

final class _FixedWslDetector implements WslDefaultDistroDetector {
  const _FixedWslDetector(this.result);

  final WslDistroDefaults? result;

  @override
  Future<WslDistroDefaults?> detect() async => result;
}
