import 'package:flutter/material.dart';

import '../../accessibility/announcement_service.dart';
import '../../config/app_settings.dart';
import '../../config/settings_diagnostics.dart';
import '../../database/maintenance_job.dart';
import '../../database/database_maintenance.dart';
import '../motion.dart';
import '../widgets/svg_icon.dart';

typedef SettingsSaveCallback = Future<void> Function(AppSettings settings);
typedef SettingsReloadCallback = Future<AppSettings> Function();

class SettingsScreen extends StatefulWidget {
  // ignore: prefer_const_constructors_in_immutables
  SettingsScreen({
    super.key,
    this.initialSettings,
    this.onSave,
    this.onReload,
    this.announcer,
    this.diagnostics = const DefaultSettingsDiagnostics(),
    this.maintenanceSchedules = const [],
    this.maintenanceProgress,
  });

  final AppSettings? initialSettings;
  final SettingsSaveCallback? onSave;
  final SettingsReloadCallback? onReload;
  final ScreenReaderAnnouncer? announcer;
  final SettingsDiagnostics diagnostics;
  final List<MaintenanceScheduleRecord> maintenanceSchedules;
  final DatabaseMaintenanceProgress? maintenanceProgress;

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
  final _pricingRefreshInterval = TextEditingController();
  final _databaseOptimizeInterval = TextEditingController();
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
      _pricingRefreshInterval,
      _databaseOptimizeInterval,
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
    _pricingRefreshInterval.text = settings.pricing.refreshIntervalHours
        .toString();
    _databaseOptimizeInterval.text = settings
        .maintenance
        .databaseOptimizeIntervalDays
        .toString();
    _pricingOverrides.text = settings.pricing.overrides.keys.join('\n');
    _cacheDatabaseLocation.text = 'Default local database';
    _exportFolder.text = 'Default export folder';
  }

  Future<void> _save() async {
    if (!await _validateScheduleInputs()) return;
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
    if (!await _validateScheduleInputs()) return;
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
        motion: _settings.ui.motion,
        showTextOnButtons: _settings.ui.showTextOnButtons,
        showIcons: _settings.ui.showIcons,
        nativeTitleBar: _settings.ui.nativeTitleBar,
        window: _settings.ui.window,
        sessionTable: _settings.ui.sessionTable,
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
        refreshIntervalHours:
            int.tryParse(_pricingRefreshInterval.text) ??
            _settings.pricing.refreshIntervalHours,
        automaticRefreshEnabled: _settings.pricing.automaticRefreshEnabled,
        fallbackToOverrides: _settings.pricing.fallbackToOverrides,
        openRouter: _settings.pricing.openRouter,
        overrides: _settings.pricing.overrides,
      ),
      maintenance: _settings.maintenance.copyWith(
        databaseOptimizeIntervalDays:
            int.tryParse(_databaseOptimizeInterval.text) ??
            _settings.maintenance.databaseOptimizeIntervalDays,
      ),
    );
  }

  Future<bool> _validateScheduleInputs() async {
    for (final (controller, label, maximum) in [
      (_pricingRefreshInterval, 'Price refresh interval (hours)', 720),
      (_databaseOptimizeInterval, 'Database optimization interval (days)', 365),
    ]) {
      final value = int.tryParse(controller.text.trim());
      if (value == null || value < 1 || value > maximum) {
        final error = '$label must be an integer from 1 to $maximum.';
        setState(() => _status = error);
        await widget.announcer?.announce(error);
        return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final progress = widget.maintenanceProgress;
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
                  icon: const AppSvgIcon(AppIcons.save),
                  label: const Text('Save settings'),
                ),
                OutlinedButton.icon(
                  onPressed: _cancel,
                  icon: const AppSvgIcon(AppIcons.cancel),
                  label: const Text('Cancel changes'),
                ),
                OutlinedButton.icon(
                  onPressed: _reload,
                  icon: const AppSvgIcon(AppIcons.refresh),
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
                    if (progress != null &&
                        progress.state != DatabaseMaintenanceState.succeeded)
                      _maintenanceProgress(progress),
                    _Section(
                      title: 'Application',
                      children: [
                        _SwitchSetting(
                          label: 'Start with Windows',
                          helperText:
                              'Launch Codex Session Viewer after signing in to Windows.',
                          value: _settings.app.startWithWindows,
                          onChanged: (value) {
                            setState(() {
                              _settings = _settings.copyWith(
                                app: _settings.app.copyWith(
                                  startWithWindows: value,
                                ),
                              );
                            });
                          },
                        ),
                      ],
                    ),
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
                        _ChoiceSetting(
                          label: 'Motion',
                          value: _settings.ui.motion.tomlValue,
                          values: AppMotionMode.values
                              .map((mode) => mode.tomlValue)
                              .toList(growable: false),
                          onChanged: (value) {
                            setState(() {
                              _settings = _settings.copyWith(
                                ui: _settings.ui.copyWithMotion(
                                  AppMotionMode.parse(value),
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
                                  automaticRefreshEnabled:
                                      _settings.pricing.automaticRefreshEnabled,
                                  fallbackToOverrides:
                                      _settings.pricing.fallbackToOverrides,
                                  openRouter: _settings.pricing.openRouter,
                                  overrides: _settings.pricing.overrides,
                                ),
                              );
                            });
                          },
                        ),
                        _SwitchSetting(
                          label: 'Automatic OpenRouter price refresh',
                          value: _settings.pricing.automaticRefreshEnabled,
                          onChanged: (value) => setState(() {
                            final pricing = _settings.pricing;
                            _settings = _settings.copyWith(
                              pricing: PricingSettings(
                                provider: pricing.provider,
                                useExternalPricing: pricing.useExternalPricing,
                                automaticRefreshEnabled: value,
                                refreshIntervalHours:
                                    pricing.refreshIntervalHours,
                                fallbackToOverrides:
                                    pricing.fallbackToOverrides,
                                openRouter: pricing.openRouter,
                                overrides: pricing.overrides,
                              ),
                            );
                          }),
                        ),
                        _TextSetting(
                          label: 'Price refresh interval (hours)',
                          helperText:
                              'Public model-pricing metadata only; no session content is sent.',
                          controller: _pricingRefreshInterval,
                        ),
                        _TextSetting(
                          label: 'Pricing overrides',
                          controller: _pricingOverrides,
                          maxLines: 3,
                        ),
                        _maintenanceStatus(
                          'openrouter_price_refresh',
                          'OpenRouter price refresh status',
                        ),
                      ],
                    ),
                    _Section(
                      title: 'Data and cache',
                      children: [
                        _SwitchSetting(
                          label: 'Automatic database optimization',
                          value: _settings.maintenance.databaseOptimizeEnabled,
                          onChanged: (value) => setState(() {
                            _settings = _settings.copyWith(
                              maintenance: _settings.maintenance.copyWith(
                                databaseOptimizeEnabled: value,
                              ),
                            );
                          }),
                        ),
                        _TextSetting(
                          label: 'Database optimization interval (days)',
                          controller: _databaseOptimizeInterval,
                        ),
                        _maintenanceStatus(
                          'database_optimize',
                          'Database optimization status',
                        ),
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

  Widget _maintenanceProgress(DatabaseMaintenanceProgress progress) {
    final running = progress.state == DatabaseMaintenanceState.running;
    final motion = CodexMotionPolicy.fromContext(
      context,
      mode: _settings.ui.motion,
    );
    return _Section(
      title: 'Database maintenance ${progress.state.name}',
      children: [
        Semantics(
          key: const Key('settings-maintenance-announcement'),
          container: true,
          liveRegion: true,
          label: progress.boundedAnnouncement,
          child: ExcludeSemantics(child: Text(progress.phase)),
        ),
        Text(progress.currentWork),
        if (running) ...[
          const SizedBox(height: 8),
          TickerMode(
            enabled: !motion.isReduced,
            child: LinearProgressIndicator(
              value: progress.fraction,
              semanticsLabel: 'Database maintenance progress',
              semanticsValue: progress.percentage == null
                  ? null
                  : '${progress.percentage}%',
            ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          progress.totalUnits == null
              ? '${progress.completedUnits} ${progress.unitLabel}'
              : '${progress.completedUnits} of ${progress.totalUnits} ${progress.unitLabel}',
        ),
        if (progress.errorMessage != null) Text(progress.errorMessage!),
      ],
    );
  }

  Widget _maintenanceStatus(String jobType, String heading) {
    MaintenanceScheduleRecord? schedule;
    for (final row in widget.maintenanceSchedules) {
      if (row.jobType == jobType) {
        schedule = row;
        break;
      }
    }
    String date(DateTime? value, String absent) => value == null
        ? absent
        : '${value.toUtc().toIso8601String().substring(0, 19).replaceFirst('T', ' ')} UTC';
    final nextDue = schedule?.enabled == false
        ? schedule?.nextDueAtUtc == null
              ? 'Disabled'
              : 'Disabled (stored: ${date(schedule!.nextDueAtUtc, 'Not scheduled')})'
        : date(schedule?.nextDueAtUtc, 'Not scheduled');
    return _Section(
      title: heading,
      children: [
        Text(
          'Automatic job: ${schedule == null
              ? 'Not configured'
              : schedule.enabled
              ? 'Enabled'
              : 'Disabled'}',
        ),
        Text('Last attempt: ${date(schedule?.lastAttemptAtUtc, 'Never')}'),
        Text('Last success: ${date(schedule?.lastSuccessAtUtc, 'Never')}'),
        Text('Next due: $nextDue'),
        Text('Last error: ${schedule?.lastError ?? 'None'}'),
      ],
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
          motion: ui.motion,
          showTextOnButtons: showTextOnButtons ?? ui.showTextOnButtons,
          showIcons: showIcons ?? ui.showIcons,
          nativeTitleBar: nativeTitleBar ?? ui.nativeTitleBar,
          window: ui.window,
          sessionTable: ui.sessionTable,
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
    this.helperText,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? helperText;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 220,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                if (helperText != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    helperText!,
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Semantics(
            label: '$label setting',
            toggled: value,
            child: Switch(value: value, onChanged: onChanged),
          ),
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
            child: Semantics(
              label: '$label setting',
              button: true,
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
          ),
        ],
      ),
    );
  }
}

extension on UiSettings {
  UiSettings copyWithTheme(AppThemeMode theme) => copyWith(theme: theme);

  UiSettings copyWithDensity(UiDensity density) => copyWith(density: density);
}
