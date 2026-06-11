import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    expect(settings.paths.windowsCodexPath, r'C:\Users\pawel\.codex');
    expect(settings.wsl.distro, 'Ubuntu');
    expect(settings.ui.nativeTitleBar, isTrue);

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
    expect(tomlText, isNot(contains('[project')));
  });

  test('saves and loads required settings groups without data loss', () async {
    final repository = SettingsRepository(settingsFile);
    final defaults = AppSettings.defaults();
    final original = defaults.copyWith(
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
        nativeTitleBar: true,
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
}
