import 'package:flutter/material.dart';

import '../../accessibility/announcement_service.dart';
import '../../config/app_settings.dart';
import '../../config/settings_diagnostics.dart';

typedef SettingsSaveCallback = Future<void> Function(AppSettings settings);
typedef SettingsReloadCallback = Future<AppSettings> Function();

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    this.initialSettings,
    this.onSave,
    this.onReload,
    this.announcer,
    this.diagnostics = const DefaultSettingsDiagnostics(),
  });

  final AppSettings? initialSettings;
  final SettingsSaveCallback? onSave;
  final SettingsReloadCallback? onReload;
  final ScreenReaderAnnouncer? announcer;
  final SettingsDiagnostics diagnostics;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late AppSettings _settings;
  late AppSettings _savedSettings;
  String _status = '';
  String _diagnosticResult = '';

  final _windowsCodexPath = TextEditingController();
  final _wslCodexUncPath = TextEditingController();
  final _wslDistro = TextEditingController();
  final _wslLinuxHome = TextEditingController();
  final _wslUncRoot = TextEditingController();
  final _defaultTerminal = TextEditingController();
  final _alacrittyPath = TextEditingController();
  final _windowsTerminalPath = TextEditingController();
  final _scanInterval = TextEditingController();
  final _fontSize = TextEditingController();
  final _voiceOverFiles = TextEditingController();
  final _pricingCacheDuration = TextEditingController();
  final _pricingOverrides = TextEditingController();
  final _cacheDatabaseLocation = TextEditingController();
  final _exportFolder = TextEditingController();

  @override
  void initState() {
    super.initState();
    _savedSettings = widget.initialSettings ?? AppSettings.defaults();
    _settings = _savedSettings;
    _loadControllers(_settings);
  }

  @override
  void dispose() {
    for (final controller in [
      _windowsCodexPath,
      _wslCodexUncPath,
      _wslDistro,
      _wslLinuxHome,
      _wslUncRoot,
      _defaultTerminal,
      _alacrittyPath,
      _windowsTerminalPath,
      _scanInterval,
      _fontSize,
      _voiceOverFiles,
      _pricingCacheDuration,
      _pricingOverrides,
      _cacheDatabaseLocation,
      _exportFolder,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _loadControllers(AppSettings settings) {
    _windowsCodexPath.text = settings.paths.windowsCodexPath;
    _wslCodexUncPath.text = settings.paths.wslCodexUncPath;
    _wslDistro.text = settings.wsl.distro;
    _wslLinuxHome.text = settings.wsl.linuxHome;
    _wslUncRoot.text = settings.wsl.linuxRootUnc;
    _defaultTerminal.text = settings.terminal.defaultTerminal;
    _alacrittyPath.text = settings.terminal.profiles['alacritty']?.exe ?? '';
    _windowsTerminalPath.text =
        settings.terminal.profiles['windows_terminal']?.exe ?? '';
    _scanInterval.text = settings.scanner.backgroundRescanIntervalSeconds
        .toString();
    _fontSize.text = settings.ui.fontSize.toString();
    _voiceOverFiles.text = settings.voiceOver.events.entries
        .map((entry) => '${entry.key}: ${entry.value.wav}')
        .join('\n');
    _pricingCacheDuration.text = settings.pricing.cachePricingHours.toString();
    _pricingOverrides.text = settings.pricing.overrides.keys.join('\n');
    _cacheDatabaseLocation.text = 'Default local database';
    _exportFolder.text = 'Default export folder';
  }

  Future<void> _save() async {
    final next = _settingsFromControllers();
    await widget.onSave?.call(next);
    setState(() {
      _settings = next;
      _savedSettings = next;
      _status = 'Settings saved.';
    });
    await widget.announcer?.announce(_status);
  }

  void _cancel() {
    setState(() {
      _settings = _savedSettings;
      _loadControllers(_settings);
      _status = 'Changes canceled.';
    });
  }

  Future<void> _reload() async {
    final next = await widget.onReload?.call();
    if (next == null) {
      setState(() {
        _status = 'Settings reloaded.';
      });
      return;
    }
    setState(() {
      _settings = next;
      _savedSettings = next;
      _loadControllers(next);
      _status = 'Settings reloaded.';
    });
  }

  Future<void> _runDiagnostic(SettingsDiagnosticAction action) async {
    final result = await widget.diagnostics.run(
      action,
      _settingsFromControllers(),
    );
    setState(() {
      _diagnosticResult = result.display;
    });
  }

  AppSettings _settingsFromControllers() {
    final alacritty =
        _settings.terminal.profiles['alacritty'] ??
        const TerminalProfileSettings(enabled: true, exe: '');
    final windowsTerminal =
        _settings.terminal.profiles['windows_terminal'] ??
        const TerminalProfileSettings(enabled: true, exe: 'wt.exe');
    return _settings.copyWith(
      paths: PathSettings(
        windowsCodexPath: _windowsCodexPath.text,
        wslCodexUncPath: _wslCodexUncPath.text,
      ),
      wsl: WslSettings(
        distro: _wslDistro.text,
        linuxHome: _wslLinuxHome.text,
        linuxRootUnc: _wslUncRoot.text,
      ),
      scanner: ScannerSettings(
        backgroundRescanEnabled: _settings.scanner.backgroundRescanEnabled,
        backgroundRescanIntervalSeconds:
            int.tryParse(_scanInterval.text) ??
            _settings.scanner.backgroundRescanIntervalSeconds,
      ),
      ui: UiSettings(
        theme: _settings.ui.theme,
        useSystemAccentColor: _settings.ui.useSystemAccentColor,
        fontSize: int.tryParse(_fontSize.text) ?? _settings.ui.fontSize,
        density: _settings.ui.density,
        showTextOnButtons: _settings.ui.showTextOnButtons,
        showIcons: _settings.ui.showIcons,
        nativeTitleBar: _settings.ui.nativeTitleBar,
      ),
      terminal: TerminalSettings(
        defaultTerminal: _defaultTerminal.text,
        profiles: {
          ..._settings.terminal.profiles,
          'alacritty': TerminalProfileSettings(
            enabled: alacritty.enabled,
            exe: _alacrittyPath.text,
            windowsCommand: alacritty.windowsCommand,
            wslCommand: alacritty.wslCommand,
          ),
          'windows_terminal': TerminalProfileSettings(
            enabled: windowsTerminal.enabled,
            exe: _windowsTerminalPath.text,
            windowsCommand: windowsTerminal.windowsCommand,
            wslCommand: windowsTerminal.wslCommand,
          ),
        },
      ),
      pricing: PricingSettings(
        provider: _settings.pricing.provider,
        useExternalPricing: _settings.pricing.useExternalPricing,
        cachePricingHours:
            int.tryParse(_pricingCacheDuration.text) ??
            _settings.pricing.cachePricingHours,
        fallbackToOverrides: _settings.pricing.fallbackToOverrides,
        openRouter: _settings.pricing.openRouter,
        overrides: _settings.pricing.overrides,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Settings', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save),
                  label: const Text('Save settings'),
                ),
                OutlinedButton.icon(
                  onPressed: _cancel,
                  icon: const Icon(Icons.undo),
                  label: const Text('Cancel changes'),
                ),
                OutlinedButton.icon(
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reload from file'),
                ),
              ],
            ),
            Semantics(
              liveRegion: true,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_status, key: const Key('settings-status')),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Section(
                      title: 'Paths',
                      children: [
                        _TextSetting(
                          label: 'Windows Codex path',
                          semanticsLabel: 'Windows Codex path input',
                          helperText:
                              'Folder containing native Windows Codex session files.',
                          controller: _windowsCodexPath,
                        ),
                        _TextSetting(
                          label: 'WSL Codex UNC path',
                          semanticsLabel: 'WSL Codex UNC path input',
                          helperText:
                              'UNC folder used to read WSL Codex sessions from Windows.',
                          controller: _wslCodexUncPath,
                        ),
                      ],
                    ),
                    _Section(
                      title: 'WSL',
                      children: [
                        _TextSetting(
                          label: 'WSL distro name',
                          controller: _wslDistro,
                        ),
                        _TextSetting(
                          label: 'WSL Linux home path',
                          controller: _wslLinuxHome,
                        ),
                        _TextSetting(
                          label: 'WSL UNC root',
                          controller: _wslUncRoot,
                        ),
                      ],
                    ),
                    _Section(
                      title: 'Terminal',
                      children: [
                        _TextSetting(
                          label: 'Default terminal',
                          helperText:
                              'Command profile used when launching resume commands.',
                          controller: _defaultTerminal,
                        ),
                        _TextSetting(
                          label: 'Alacritty executable path',
                          controller: _alacrittyPath,
                        ),
                        _TextSetting(
                          label: 'Windows Terminal executable path',
                          controller: _windowsTerminalPath,
                        ),
                      ],
                    ),
                    _Section(
                      title: 'Scanner',
                      children: [
                        _TextSetting(
                          label: 'Scan interval (seconds)',
                          controller: _scanInterval,
                        ),
                        _SwitchSetting(
                          label: 'Background scan enabled',
                          value: _settings.scanner.backgroundRescanEnabled,
                          onChanged: (value) {
                            setState(() {
                              _settings = _settings.copyWith(
                                scanner: ScannerSettings(
                                  backgroundRescanEnabled: value,
                                  backgroundRescanIntervalSeconds: _settings
                                      .scanner
                                      .backgroundRescanIntervalSeconds,
                                ),
                              );
                            });
                          },
                        ),
                      ],
                    ),
                    _Section(
                      title: 'Appearance',
                      children: [
                        _ChoiceSetting(
                          label: 'Theme',
                          value: _settings.ui.theme.tomlValue,
                          values: AppThemeMode.values
                              .map((mode) => mode.tomlValue)
                              .toList(growable: false),
                          onChanged: (value) {
                            setState(() {
                              _settings = _settings.copyWith(
                                ui: _settings.ui.copyWithTheme(
                                  AppThemeMode.parse(value),
                                ),
                              );
                            });
                          },
                        ),
                        _TextSetting(
                          label: 'Font size (pixels)',
                          controller: _fontSize,
                        ),
                        _ChoiceSetting(
                          label: 'UI density',
                          value: _settings.ui.density.tomlValue,
                          values: UiDensity.values
                              .map((density) => density.tomlValue)
                              .toList(growable: false),
                          onChanged: (value) {
                            setState(() {
                              _settings = _settings.copyWith(
                                ui: _settings.ui.copyWithDensity(
                                  UiDensity.parse(value),
                                ),
                              );
                            });
                          },
                        ),
                        _SwitchSetting(
                          label: 'Show icons',
                          value: _settings.ui.showIcons,
                          onChanged: (value) => _replaceUi(showIcons: value),
                        ),
                        _SwitchSetting(
                          label: 'Show text on buttons',
                          value: _settings.ui.showTextOnButtons,
                          onChanged: (value) =>
                              _replaceUi(showTextOnButtons: value),
                        ),
                        _SwitchSetting(
                          label: 'Native title bar',
                          value: _settings.ui.nativeTitleBar,
                          onChanged: (value) =>
                              _replaceUi(nativeTitleBar: value),
                        ),
                      ],
                    ),
                    _Section(
                      title: 'Voice-over',
                      children: [
                        _SwitchSetting(
                          label: 'Voice-over enabled',
                          value: _settings.voiceOver.enabled,
                          onChanged: (value) {
                            setState(() {
                              _settings = _settings.copyWith(
                                voiceOver: VoiceOverSettings(
                                  enabled: value,
                                  preferWav: _settings.voiceOver.preferWav,
                                  fallbackToScreenReader: _settings
                                      .voiceOver
                                      .fallbackToScreenReader,
                                  events: _settings.voiceOver.events,
                                ),
                              );
                            });
                          },
                        ),
                        _TextSetting(
                          label: 'Voice-over file paths',
                          helperText: 'One voice-over event WAV path per line.',
                          controller: _voiceOverFiles,
                          maxLines: 3,
                        ),
                      ],
                    ),
                    _Section(
                      title: 'Pricing',
                      children: [
                        _SwitchSetting(
                          label: 'OpenRouter pricing enabled',
                          value: _settings.pricing.useExternalPricing,
                          onChanged: (value) {
                            setState(() {
                              _settings = _settings.copyWith(
                                pricing: PricingSettings(
                                  provider: _settings.pricing.provider,
                                  useExternalPricing: value,
                                  cachePricingHours:
                                      _settings.pricing.cachePricingHours,
                                  fallbackToOverrides:
                                      _settings.pricing.fallbackToOverrides,
                                  openRouter: _settings.pricing.openRouter,
                                  overrides: _settings.pricing.overrides,
                                ),
                              );
                            });
                          },
                        ),
                        _TextSetting(
                          label: 'Pricing cache duration (hours)',
                          helperText:
                              'Public model-pricing metadata only; no session content is sent.',
                          controller: _pricingCacheDuration,
                        ),
                        _TextSetting(
                          label: 'Pricing overrides',
                          controller: _pricingOverrides,
                          maxLines: 3,
                        ),
                      ],
                    ),
                    _Section(
                      title: 'Data and cache',
                      children: [
                        _TextSetting(
                          label: 'Cache/database location',
                          controller: _cacheDatabaseLocation,
                        ),
                        _TextSetting(
                          label: 'Export folder',
                          controller: _exportFolder,
                        ),
                      ],
                    ),
                    _Section(
                      title: 'Diagnostics',
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final action
                                in SettingsDiagnosticAction.values)
                              OutlinedButton(
                                onPressed: () => _runDiagnostic(action),
                                child: Text(action.label),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Semantics(
                          label: _diagnosticResult.isEmpty
                              ? 'Diagnostic result'
                              : 'Diagnostic result: $_diagnosticResult',
                          liveRegion: true,
                          container: true,
                          child: ExcludeSemantics(
                            child: Text(
                              _diagnosticResult.isEmpty
                                  ? 'Result: Not run.'
                                  : 'Result: $_diagnosticResult',
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _replaceUi({
    bool? showIcons,
    bool? showTextOnButtons,
    bool? nativeTitleBar,
  }) {
    setState(() {
      final ui = _settings.ui;
      _settings = _settings.copyWith(
        ui: UiSettings(
          theme: ui.theme,
          useSystemAccentColor: ui.useSystemAccentColor,
          fontSize: ui.fontSize,
          density: ui.density,
          showTextOnButtons: showTextOnButtons ?? ui.showTextOnButtons,
          showIcons: showIcons ?? ui.showIcons,
          nativeTitleBar: nativeTitleBar ?? ui.nativeTitleBar,
        ),
      );
    });
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _TextSetting extends StatelessWidget {
  const _TextSetting({
    required this.label,
    required this.controller,
    this.semanticsLabel,
    this.helperText,
    this.maxLines = 1,
  });

  final String label;
  final TextEditingController controller;
  final String? semanticsLabel;
  final String? helperText;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 220, child: Text(label)),
          Expanded(
            child: Semantics(
              label: semanticsLabel ?? '$label input',
              textField: true,
              child: TextField(
                controller: controller,
                maxLines: maxLines,
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  helperText: helperText,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SwitchSetting extends StatelessWidget {
  const _SwitchSetting({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(width: 220, child: Text(label)),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _ChoiceSetting extends StatelessWidget {
  const _ChoiceSetting({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
  });

  final String label;
  final String value;
  final List<String> values;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(width: 220, child: Text(label)),
          Expanded(
            child: DropdownButton<String>(
              value: value,
              isExpanded: true,
              items: [
                for (final item in values)
                  DropdownMenuItem(value: item, child: Text(item)),
              ],
              onChanged: (value) {
                if (value != null) {
                  onChanged(value);
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

extension on UiSettings {
  UiSettings copyWithTheme(AppThemeMode theme) => UiSettings(
    theme: theme,
    useSystemAccentColor: useSystemAccentColor,
    fontSize: fontSize,
    density: density,
    showTextOnButtons: showTextOnButtons,
    showIcons: showIcons,
    nativeTitleBar: nativeTitleBar,
  );

  UiSettings copyWithDensity(UiDensity density) => UiSettings(
    theme: theme,
    useSystemAccentColor: useSystemAccentColor,
    fontSize: fontSize,
    density: density,
    showTextOnButtons: showTextOnButtons,
    showIcons: showIcons,
    nativeTitleBar: nativeTitleBar,
  );
}
