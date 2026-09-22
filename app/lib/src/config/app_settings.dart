import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import '../platform/application_working_directory.dart';

File defaultSettingsFile() {
  final executableDirectory = applicationExecutableDirectory();
  final executableSettings = File(
    p.join(executableDirectory.path, 'settings.toml'),
  );
  if (executableSettings.existsSync()) {
    return executableSettings;
  }
  final developmentRoot = findDevelopmentRepositoryRoot();
  if (developmentRoot != null) {
    final repoRootSettings = File(
      p.join(developmentRoot.path, 'settings.toml'),
    );
    if (repoRootSettings.existsSync()) {
      return repoRootSettings;
    }
  }
  return executableSettings;
}

enum AppThemeMode {
  system('system'),
  light('light'),
  dark('dark'),
  highContrastLight('high_contrast_light'),
  highContrastDark('high_contrast_dark');

  const AppThemeMode(this.tomlValue);

  final String tomlValue;

  static AppThemeMode parse(String value) => AppThemeMode.values.firstWhere(
    (mode) => mode.tomlValue == value,
    orElse: () => throw SettingsValidationException(
      'ui.theme',
      'Unsupported theme: $value',
    ),
  );
}

enum UiDensity {
  comfortable('comfortable'),
  compact('compact');

  const UiDensity(this.tomlValue);

  final String tomlValue;

  static UiDensity parse(String value) => UiDensity.values.firstWhere(
    (density) => density.tomlValue == value,
    orElse: () => throw SettingsValidationException(
      'ui.density',
      'Unsupported density: $value',
    ),
  );
}

enum AppMotionMode {
  system('system'),
  reduced('reduced'),
  normal('normal');

  const AppMotionMode(this.tomlValue);

  final String tomlValue;

  static AppMotionMode parse(String value) => AppMotionMode.values.firstWhere(
    (mode) => mode.tomlValue == value,
    orElse: () => throw SettingsValidationException(
      'ui.motion',
      'Unsupported motion mode: $value',
    ),
  );
}

class SettingsValidationException implements Exception {
  const SettingsValidationException(this.field, this.message);

  final String field;
  final String message;

  @override
  String toString() => 'SettingsValidationException($field): $message';
}

class SettingsRepository {
  SettingsRepository(this.file);

  final File file;

  /// Pending operations per settings file. Window placement, table layout,
  /// and the Settings screen all write the same file; each load-modify-save
  /// runs alone so one writer cannot drop another's change.
  static final _queues = <String, Future<void>>{};

  Future<T> _serialized<T>(Future<T> Function() action) {
    final key = file.absolute.path.toLowerCase();
    final previous = _queues[key] ?? Future<void>.value();
    final result = previous.then((_) => action());
    final done = result.then<void>((_) {}, onError: (Object _) {});
    _queues[key] = done;
    unawaited(
      done.whenComplete(() {
        if (identical(_queues[key], done)) {
          _queues.remove(key);
        }
      }),
    );
    return result;
  }

  Future<AppSettings> loadOrCreate() => _serialized(_loadOrCreate);

  Future<void> save(AppSettings settings) => _serialized(() => _save(settings));

  /// Loads the current file, applies [change], and saves the result as one
  /// step. Returns the saved settings.
  Future<AppSettings> update(AppSettings Function(AppSettings current) change) {
    return _serialized(() async {
      final next = change(await _loadOrCreate());
      await _save(next);
      return next;
    });
  }

  Future<AppSettings> _loadOrCreate() async {
    if (!await file.exists()) {
      final settings = AppSettings.defaults();
      await _save(settings);
      return settings;
    }

    final text = await file.readAsString();
    final map = TomlDocument.parse(text).toMap();
    return AppSettings.fromTomlMap(map);
  }

  /// Writes a temporary file and renames it over the settings file, so a
  /// reader never sees a truncated file.
  Future<void> _save(AppSettings settings) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(
      _encodeToml(settings.toTomlMap()),
      flush: true,
    );
    await temporary.rename(file.path);
  }

  String _encodeToml(Map<String, Object?> map) {
    final document = TomlAstBuilder().buildDocument(map);
    final printer = TomlPrettyPrinter();
    printer.visitDocument(document);
    return printer.toString();
  }
}

class AppSettings {
  const AppSettings({
    required this.app,
    required this.paths,
    required this.wsl,
    required this.scanner,
    required this.ui,
    required this.terminal,
    required this.toolOutput,
    required this.voiceOver,
    required this.pricing,
    required this.logging,
    this.maintenance = const MaintenanceSettings(),
  });

  final GeneralAppSettings app;
  final PathSettings paths;
  final WslSettings wsl;
  final ScannerSettings scanner;
  final UiSettings ui;
  final TerminalSettings terminal;
  final ToolOutputSettings toolOutput;
  final VoiceOverSettings voiceOver;
  final PricingSettings pricing;
  final LoggingSettings logging;
  final MaintenanceSettings maintenance;

  factory AppSettings.defaults() => const AppSettings(
    app: GeneralAppSettings(firstRun: false, startWithWindows: true),
    paths: PathSettings(
      windowsCodexPath: r'C:\Users\pawel\.codex',
      wslCodexUncPath: r'\\wsl.localhost\Ubuntu\home\pawel\.codex',
    ),
    wsl: WslSettings(
      distro: 'Ubuntu',
      linuxHome: '/home/pawel',
      linuxRootUnc: r'\\wsl.localhost\Ubuntu\',
    ),
    scanner: ScannerSettings(
      backgroundRescanEnabled: true,
      backgroundRescanIntervalSeconds: 300,
    ),
    ui: UiSettings(
      theme: AppThemeMode.system,
      useSystemAccentColor: true,
      fontSize: 14,
      density: UiDensity.comfortable,
      motion: AppMotionMode.system,
      showTextOnButtons: true,
      showIcons: true,
      window: null,
      sessionTable: SessionTableSettings(
        columnWidths: {},
        newestPerProjectOnly: false,
        sorts: [
          SessionTableSortSettings(column: 'last_message_at', ascending: false),
        ],
      ),
    ),
    terminal: TerminalSettings(
      defaultTerminal: 'alacritty',
      profiles: {
        'alacritty': TerminalProfileSettings(
          enabled: true,
          exe: r'C:\Program Files\Alacritty\alacritty.exe',
          windowsCommand:
              '{terminal_exe} --working-directory {working_dir} -e powershell.exe -NoExit -Command {resume_command}',
          wslCommand:
              '{terminal_exe} -e wsl.exe -d {wsl_distro} --cd {wsl_working_dir} bash -lc {resume_command}',
        ),
        'windows_terminal': TerminalProfileSettings(
          enabled: true,
          exe: 'wt.exe',
          windowsCommand:
              '{terminal_exe} -d {working_dir} powershell.exe -NoExit -Command {resume_command}',
          wslCommand:
              '{terminal_exe} wsl.exe -d {wsl_distro} --cd {wsl_working_dir} bash -lc {resume_command}',
        ),
      },
    ),
    toolOutput: ToolOutputSettings(
      indexToolOutput: false,
      maxToolOutputPreviewChars: 2000,
      maxToolOutputStoreChars: 10000,
      collapseToolOutputByDefault: true,
    ),
    voiceOver: VoiceOverSettings(
      enabled: true,
      preferWav: true,
      fallbackToScreenReader: true,
      events: {
        'scan_started': VoiceOverEventSettings(
          text: 'Scanning started',
          wav: r'assets\voice\scan_started.wav',
        ),
        'scan_finished': VoiceOverEventSettings(
          text: 'Scanning finished',
          wav: r'assets\voice\scan_finished.wav',
        ),
        'copied': VoiceOverEventSettings(
          text: 'Copied',
          wav: r'assets\voice\copied.wav',
        ),
        'export_finished': VoiceOverEventSettings(
          text: 'Export finished',
          wav: r'assets\voice\export_finished.wav',
        ),
        'parse_error': VoiceOverEventSettings(
          text: 'Some sessions could not be parsed',
          wav: r'assets\voice\parse_error.wav',
        ),
        'database_error': VoiceOverEventSettings(
          text: 'Database error',
          wav: r'assets\voice\database_error.wav',
        ),
      },
    ),
    pricing: PricingSettings(
      provider: 'openrouter',
      useExternalPricing: true,
      cachePricingHours: 24,
      fallbackToOverrides: true,
      openRouter: OpenRouterSettings(
        modelsEndpoint: 'https://openrouter.ai/api/v1/models',
        apiKey: '',
      ),
      overrides: {
        'openai/gpt-5.5-thinking': PricingOverrideSettings(
          prompt: '0',
          completion: '0',
          inputCacheRead: '0',
          inputCacheWrite: '0',
          internalReasoning: '0',
        ),
      },
    ),
    logging: LoggingSettings(
      level: 'info',
      logFile: r'logs\codex-session-viewer.log',
      maxLogFiles: 5,
      maxLogSizeMb: 10,
    ),
  );

  factory AppSettings.fromTomlMap(Map<String, dynamic> map) {
    final defaults = AppSettings.defaults();
    return defaults.copyWith(
      app: GeneralAppSettings.fromMap(_table(map, 'app'), defaults.app),
      paths: PathSettings.fromMap(_table(map, 'paths'), defaults.paths),
      wsl: WslSettings.fromMap(_table(map, 'wsl'), defaults.wsl),
      scanner: ScannerSettings.fromMap(
        _table(map, 'scanner'),
        defaults.scanner,
      ),
      ui: UiSettings.fromMap(_table(map, 'ui'), defaults.ui),
      terminal: TerminalSettings.fromMap(
        _table(map, 'terminal'),
        defaults.terminal,
      ),
      toolOutput: ToolOutputSettings.fromMap(
        _table(map, 'tool_output'),
        defaults.toolOutput,
      ),
      voiceOver: VoiceOverSettings.fromMap(
        _table(map, 'voice_over'),
        defaults.voiceOver,
      ),
      pricing: PricingSettings.fromMap(
        _table(map, 'pricing'),
        defaults.pricing,
      ),
      maintenance: MaintenanceSettings.fromMap(_table(map, 'maintenance')),
      logging: LoggingSettings.fromMap(
        _table(map, 'logging'),
        defaults.logging,
      ),
    );
  }

  AppSettings copyWith({
    GeneralAppSettings? app,
    PathSettings? paths,
    WslSettings? wsl,
    ScannerSettings? scanner,
    UiSettings? ui,
    TerminalSettings? terminal,
    ToolOutputSettings? toolOutput,
    VoiceOverSettings? voiceOver,
    PricingSettings? pricing,
    LoggingSettings? logging,
    MaintenanceSettings? maintenance,
  }) => AppSettings(
    app: app ?? this.app,
    paths: paths ?? this.paths,
    wsl: wsl ?? this.wsl,
    scanner: scanner ?? this.scanner,
    ui: ui ?? this.ui,
    terminal: terminal ?? this.terminal,
    toolOutput: toolOutput ?? this.toolOutput,
    voiceOver: voiceOver ?? this.voiceOver,
    pricing: pricing ?? this.pricing,
    logging: logging ?? this.logging,
    maintenance: maintenance ?? this.maintenance,
  );

  Map<String, Object?> toTomlMap() => {
    'app': app.toTomlMap(),
    'paths': paths.toTomlMap(),
    'wsl': wsl.toTomlMap(),
    'scanner': scanner.toTomlMap(),
    'ui': ui.toTomlMap(),
    'terminal': terminal.toTomlMap(),
    'tool_output': toolOutput.toTomlMap(),
    'voice_over': voiceOver.toTomlMap(),
    'pricing': pricing.toTomlMap(),
    'logging': logging.toTomlMap(),
    'maintenance': maintenance.toTomlMap(),
  };

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      app == other.app &&
      paths == other.paths &&
      wsl == other.wsl &&
      scanner == other.scanner &&
      ui == other.ui &&
      terminal == other.terminal &&
      toolOutput == other.toolOutput &&
      voiceOver == other.voiceOver &&
      pricing == other.pricing &&
      maintenance == other.maintenance &&
      logging == other.logging;

  @override
  int get hashCode => Object.hash(
    app,
    paths,
    wsl,
    scanner,
    ui,
    terminal,
    toolOutput,
    voiceOver,
    maintenance,
    pricing,
    logging,
  );
}

class GeneralAppSettings {
  const GeneralAppSettings({
    required this.firstRun,
    required this.startWithWindows,
  });

  final bool firstRun;
  final bool startWithWindows;

  GeneralAppSettings copyWith({bool? firstRun, bool? startWithWindows}) =>
      GeneralAppSettings(
        firstRun: firstRun ?? this.firstRun,
        startWithWindows: startWithWindows ?? this.startWithWindows,
      );

  factory GeneralAppSettings.fromMap(
    Map<String, dynamic> map,
    GeneralAppSettings defaults,
  ) => GeneralAppSettings(
    firstRun: _bool(map, 'first_run', defaults.firstRun, 'app.first_run'),
    startWithWindows: _bool(
      map,
      'start_with_windows',
      defaults.startWithWindows,
      'app.start_with_windows',
    ),
  );

  Map<String, Object?> toTomlMap() => {
    'first_run': firstRun,
    'start_with_windows': startWithWindows,
  };

  @override
  bool operator ==(Object other) =>
      other is GeneralAppSettings &&
      firstRun == other.firstRun &&
      startWithWindows == other.startWithWindows;

  @override
  int get hashCode => Object.hash(firstRun, startWithWindows);
}

class PathSettings {
  const PathSettings({
    required this.windowsCodexPath,
    required this.wslCodexUncPath,
  });

  final String windowsCodexPath;
  final String wslCodexUncPath;

  factory PathSettings.fromMap(
    Map<String, dynamic> map,
    PathSettings defaults,
  ) => PathSettings(
    windowsCodexPath: _string(
      map,
      'windows_codex_path',
      defaults.windowsCodexPath,
      'paths.windows_codex_path',
    ),
    wslCodexUncPath: _string(
      map,
      'wsl_codex_unc_path',
      defaults.wslCodexUncPath,
      'paths.wsl_codex_unc_path',
    ),
  );

  Map<String, Object?> toTomlMap() => {
    'windows_codex_path': windowsCodexPath,
    'wsl_codex_unc_path': wslCodexUncPath,
  };

  @override
  bool operator ==(Object other) =>
      other is PathSettings &&
      windowsCodexPath == other.windowsCodexPath &&
      wslCodexUncPath == other.wslCodexUncPath;

  @override
  int get hashCode => Object.hash(windowsCodexPath, wslCodexUncPath);
}

class WslSettings {
  const WslSettings({
    required this.distro,
    required this.linuxHome,
    required this.linuxRootUnc,
  });

  final String distro;
  final String linuxHome;
  final String linuxRootUnc;

  factory WslSettings.fromMap(Map<String, dynamic> map, WslSettings defaults) =>
      WslSettings(
        distro: _string(map, 'distro', defaults.distro, 'wsl.distro'),
        linuxHome: _string(
          map,
          'linux_home',
          defaults.linuxHome,
          'wsl.linux_home',
        ),
        linuxRootUnc: _string(
          map,
          'linux_root_unc',
          defaults.linuxRootUnc,
          'wsl.linux_root_unc',
        ),
      );

  Map<String, Object?> toTomlMap() => {
    'distro': distro,
    'linux_home': linuxHome,
    'linux_root_unc': linuxRootUnc,
  };

  @override
  bool operator ==(Object other) =>
      other is WslSettings &&
      distro == other.distro &&
      linuxHome == other.linuxHome &&
      linuxRootUnc == other.linuxRootUnc;

  @override
  int get hashCode => Object.hash(distro, linuxHome, linuxRootUnc);
}

class ScannerSettings {
  const ScannerSettings({
    required this.backgroundRescanEnabled,
    required this.backgroundRescanIntervalSeconds,
  });

  final bool backgroundRescanEnabled;
  final int backgroundRescanIntervalSeconds;

  factory ScannerSettings.fromMap(
    Map<String, dynamic> map,
    ScannerSettings defaults,
  ) => ScannerSettings(
    backgroundRescanEnabled: _bool(
      map,
      'background_rescan_enabled',
      defaults.backgroundRescanEnabled,
      'scanner.background_rescan_enabled',
    ),
    backgroundRescanIntervalSeconds: _positiveInt(
      map,
      'background_rescan_interval_seconds',
      defaults.backgroundRescanIntervalSeconds,
      'scanner.background_rescan_interval_seconds',
    ),
  );

  Map<String, Object?> toTomlMap() => {
    'background_rescan_enabled': backgroundRescanEnabled,
    'background_rescan_interval_seconds': backgroundRescanIntervalSeconds,
  };

  @override
  bool operator ==(Object other) =>
      other is ScannerSettings &&
      backgroundRescanEnabled == other.backgroundRescanEnabled &&
      backgroundRescanIntervalSeconds == other.backgroundRescanIntervalSeconds;

  @override
  int get hashCode =>
      Object.hash(backgroundRescanEnabled, backgroundRescanIntervalSeconds);
}

class UiSettings {
  const UiSettings({
    required this.theme,
    required this.useSystemAccentColor,
    required this.fontSize,
    required this.density,
    required this.showTextOnButtons,
    required this.showIcons,
    required this.window,
    required this.sessionTable,
    this.motion = AppMotionMode.system,
  });

  final AppThemeMode theme;
  final bool useSystemAccentColor;
  final int fontSize;
  final UiDensity density;
  final AppMotionMode motion;
  final bool showTextOnButtons;
  final bool showIcons;
  final WindowPlacementSettings? window;
  final SessionTableSettings sessionTable;

  UiSettings copyWith({
    AppThemeMode? theme,
    bool? useSystemAccentColor,
    int? fontSize,
    UiDensity? density,
    AppMotionMode? motion,
    bool? showTextOnButtons,
    bool? showIcons,
    Object? window = _sentinel,
    SessionTableSettings? sessionTable,
  }) => UiSettings(
    theme: theme ?? this.theme,
    useSystemAccentColor: useSystemAccentColor ?? this.useSystemAccentColor,
    fontSize: fontSize ?? this.fontSize,
    density: density ?? this.density,
    motion: motion ?? this.motion,
    showTextOnButtons: showTextOnButtons ?? this.showTextOnButtons,
    showIcons: showIcons ?? this.showIcons,
    window: window == _sentinel
        ? this.window
        : window as WindowPlacementSettings?,
    sessionTable: sessionTable ?? this.sessionTable,
  );

  UiSettings copyWithMotion(AppMotionMode motion) => copyWith(motion: motion);

  factory UiSettings.fromMap(
    Map<String, dynamic> map,
    UiSettings defaults,
  ) => UiSettings(
    theme: AppThemeMode.parse(
      _string(map, 'theme', defaults.theme.tomlValue, 'ui.theme'),
    ),
    useSystemAccentColor: _bool(
      map,
      'use_system_accent_color',
      defaults.useSystemAccentColor,
      'ui.use_system_accent_color',
    ),
    fontSize: _positiveInt(map, 'font_size', defaults.fontSize, 'ui.font_size'),
    density: UiDensity.parse(
      _string(map, 'density', defaults.density.tomlValue, 'ui.density'),
    ),
    motion: AppMotionMode.parse(
      _string(map, 'motion', defaults.motion.tomlValue, 'ui.motion'),
    ),
    showTextOnButtons: _bool(
      map,
      'show_text_on_buttons',
      defaults.showTextOnButtons,
      'ui.show_text_on_buttons',
    ),
    showIcons: _bool(map, 'show_icons', defaults.showIcons, 'ui.show_icons'),
    window: WindowPlacementSettings.fromMap(_table(map, 'window')),
    sessionTable: SessionTableSettings.fromMap(
      _table(map, 'session_table'),
      defaults.sessionTable,
    ),
  );

  Map<String, Object?> toTomlMap() => {
    'theme': theme.tomlValue,
    'use_system_accent_color': useSystemAccentColor,
    'font_size': fontSize,
    'density': density.tomlValue,
    'motion': motion.tomlValue,
    'show_text_on_buttons': showTextOnButtons,
    'show_icons': showIcons,
    if (window != null) 'window': window!.toTomlMap(),
    'session_table': sessionTable.toTomlMap(),
  };

  @override
  bool operator ==(Object other) =>
      other is UiSettings &&
      theme == other.theme &&
      useSystemAccentColor == other.useSystemAccentColor &&
      fontSize == other.fontSize &&
      density == other.density &&
      motion == other.motion &&
      showTextOnButtons == other.showTextOnButtons &&
      showIcons == other.showIcons &&
      window == other.window &&
      sessionTable == other.sessionTable;

  @override
  int get hashCode => Object.hash(
    theme,
    useSystemAccentColor,
    fontSize,
    density,
    motion,
    showTextOnButtons,
    showIcons,
    window,
    sessionTable,
  );
}

class SessionTableSettings {
  const SessionTableSettings({
    required this.columnWidths,
    required this.sorts,
    this.newestPerProjectOnly = false,
  });

  final Map<String, double> columnWidths;
  final List<SessionTableSortSettings> sorts;
  final bool newestPerProjectOnly;

  factory SessionTableSettings.fromMap(
    Map<String, dynamic> map,
    SessionTableSettings defaults,
  ) {
    final widthsMap = _table(map, 'column_widths');
    final widths = <String, double>{...defaults.columnWidths};
    for (final entry in widthsMap.entries) {
      final value = entry.value;
      if (value is num && value > 0) {
        widths[entry.key] = value.toDouble();
      }
    }
    final sortMaps = _listOfMaps(map, 'sorts', 'ui.session_table.sorts');
    final sorts = sortMaps
        .map(SessionTableSortSettings.fromMap)
        .where((sort) => sort.column.isNotEmpty)
        .toList(growable: false);
    return SessionTableSettings(
      columnWidths: Map.unmodifiable(widths),
      sorts: sorts.isEmpty ? defaults.sorts : List.unmodifiable(sorts),
      newestPerProjectOnly: _bool(
        map,
        'newest_per_project_only',
        defaults.newestPerProjectOnly,
        'ui.session_table.newest_per_project_only',
      ),
    );
  }

  Map<String, Object?> toTomlMap() => {
    'column_widths': columnWidths,
    'newest_per_project_only': newestPerProjectOnly,
    'sorts': [for (final sort in sorts) sort.toTomlMap()],
  };

  @override
  bool operator ==(Object other) =>
      other is SessionTableSettings &&
      _mapEquals(columnWidths, other.columnWidths) &&
      _listEquals(sorts, other.sorts) &&
      newestPerProjectOnly == other.newestPerProjectOnly;

  @override
  int get hashCode => Object.hash(
    _mapHash(columnWidths),
    Object.hashAll(sorts),
    newestPerProjectOnly,
  );
}

class SessionTableSortSettings {
  const SessionTableSortSettings({
    required this.column,
    required this.ascending,
  });

  final String column;
  final bool ascending;

  factory SessionTableSortSettings.fromMap(Map<String, dynamic> map) =>
      SessionTableSortSettings(
        column: _string(map, 'column', '', 'ui.session_table.sorts.column'),
        ascending: _bool(
          map,
          'ascending',
          true,
          'ui.session_table.sorts.ascending',
        ),
      );

  Map<String, Object?> toTomlMap() => {
    'column': column,
    'ascending': ascending,
  };

  @override
  bool operator ==(Object other) =>
      other is SessionTableSortSettings &&
      column == other.column &&
      ascending == other.ascending;

  @override
  int get hashCode => Object.hash(column, ascending);
}

class WindowPlacementSettings {
  const WindowPlacementSettings({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.isMaximized,
  });

  final double x;
  final double y;
  final double width;
  final double height;
  final bool isMaximized;

  static WindowPlacementSettings? fromMap(Map<String, dynamic> map) {
    if (map.isEmpty) {
      return null;
    }
    return WindowPlacementSettings(
      x: _number(map, 'x', 'ui.window.x'),
      y: _number(map, 'y', 'ui.window.y'),
      width: _number(map, 'width', 'ui.window.width'),
      height: _number(map, 'height', 'ui.window.height'),
      isMaximized: _bool(map, 'is_maximized', false, 'ui.window.is_maximized'),
    );
  }

  Map<String, Object?> toTomlMap() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'is_maximized': isMaximized,
  };

  @override
  bool operator ==(Object other) =>
      other is WindowPlacementSettings &&
      x == other.x &&
      y == other.y &&
      width == other.width &&
      height == other.height &&
      isMaximized == other.isMaximized;

  @override
  int get hashCode => Object.hash(x, y, width, height, isMaximized);
}

class TerminalSettings {
  const TerminalSettings({
    required this.defaultTerminal,
    required this.profiles,
  });

  final String defaultTerminal;
  final Map<String, TerminalProfileSettings> profiles;

  factory TerminalSettings.fromMap(
    Map<String, dynamic> map,
    TerminalSettings defaults,
  ) {
    final profiles = <String, TerminalProfileSettings>{};
    final defaultProfiles = defaults.profiles;
    profiles.addAll(defaultProfiles);
    for (final entry in map.entries) {
      if (entry.value is Map) {
        profiles[entry.key] = TerminalProfileSettings.fromMap(
          _table(map, entry.key),
          defaultProfiles[entry.key] ??
              const TerminalProfileSettings(enabled: false, exe: ''),
          'terminal.${entry.key}',
        );
      }
    }
    final defaultTerminal = _string(
      map,
      'default_terminal',
      defaults.defaultTerminal,
      'terminal.default_terminal',
    );
    if (!profiles.containsKey(defaultTerminal)) {
      throw SettingsValidationException(
        'terminal.default_terminal',
        'Default terminal profile is not configured: $defaultTerminal',
      );
    }
    return TerminalSettings(
      defaultTerminal: defaultTerminal,
      profiles: Map.unmodifiable(profiles),
    );
  }

  Map<String, Object?> toTomlMap() => {
    'default_terminal': defaultTerminal,
    for (final entry in profiles.entries) entry.key: entry.value.toTomlMap(),
  };

  @override
  bool operator ==(Object other) =>
      other is TerminalSettings &&
      defaultTerminal == other.defaultTerminal &&
      _mapEquals(profiles, other.profiles);

  @override
  int get hashCode => Object.hash(defaultTerminal, _mapHash(profiles));
}

class TerminalProfileSettings {
  const TerminalProfileSettings({
    required this.enabled,
    required this.exe,
    this.windowsCommand = '',
    this.wslCommand = '',
  });

  final bool enabled;
  final String exe;
  final String windowsCommand;
  final String wslCommand;

  factory TerminalProfileSettings.fromMap(
    Map<String, dynamic> map,
    TerminalProfileSettings defaults,
    String fieldPrefix,
  ) => TerminalProfileSettings(
    enabled: _bool(map, 'enabled', defaults.enabled, '$fieldPrefix.enabled'),
    exe: _string(map, 'exe', defaults.exe, '$fieldPrefix.exe'),
    windowsCommand: _string(
      map,
      'windows_command',
      defaults.windowsCommand,
      '$fieldPrefix.windows_command',
    ),
    wslCommand: _string(
      map,
      'wsl_command',
      defaults.wslCommand,
      '$fieldPrefix.wsl_command',
    ),
  );

  Map<String, Object?> toTomlMap() => {
    'enabled': enabled,
    'exe': exe,
    'windows_command': windowsCommand,
    'wsl_command': wslCommand,
  };

  @override
  bool operator ==(Object other) =>
      other is TerminalProfileSettings &&
      enabled == other.enabled &&
      exe == other.exe &&
      windowsCommand == other.windowsCommand &&
      wslCommand == other.wslCommand;

  @override
  int get hashCode => Object.hash(enabled, exe, windowsCommand, wslCommand);
}

class ToolOutputSettings {
  const ToolOutputSettings({
    required this.indexToolOutput,
    required this.maxToolOutputPreviewChars,
    required this.maxToolOutputStoreChars,
    required this.collapseToolOutputByDefault,
  });

  final bool indexToolOutput;
  final int maxToolOutputPreviewChars;
  final int maxToolOutputStoreChars;
  final bool collapseToolOutputByDefault;

  factory ToolOutputSettings.fromMap(
    Map<String, dynamic> map,
    ToolOutputSettings defaults,
  ) => ToolOutputSettings(
    indexToolOutput: _bool(
      map,
      'index_tool_output',
      defaults.indexToolOutput,
      'tool_output.index_tool_output',
    ),
    maxToolOutputPreviewChars: _positiveInt(
      map,
      'max_tool_output_preview_chars',
      defaults.maxToolOutputPreviewChars,
      'tool_output.max_tool_output_preview_chars',
    ),
    maxToolOutputStoreChars: _positiveInt(
      map,
      'max_tool_output_store_chars',
      defaults.maxToolOutputStoreChars,
      'tool_output.max_tool_output_store_chars',
    ),
    collapseToolOutputByDefault: _bool(
      map,
      'collapse_tool_output_by_default',
      defaults.collapseToolOutputByDefault,
      'tool_output.collapse_tool_output_by_default',
    ),
  );

  Map<String, Object?> toTomlMap() => {
    'index_tool_output': indexToolOutput,
    'max_tool_output_preview_chars': maxToolOutputPreviewChars,
    'max_tool_output_store_chars': maxToolOutputStoreChars,
    'collapse_tool_output_by_default': collapseToolOutputByDefault,
  };

  @override
  bool operator ==(Object other) =>
      other is ToolOutputSettings &&
      indexToolOutput == other.indexToolOutput &&
      maxToolOutputPreviewChars == other.maxToolOutputPreviewChars &&
      maxToolOutputStoreChars == other.maxToolOutputStoreChars &&
      collapseToolOutputByDefault == other.collapseToolOutputByDefault;

  @override
  int get hashCode => Object.hash(
    indexToolOutput,
    maxToolOutputPreviewChars,
    maxToolOutputStoreChars,
    collapseToolOutputByDefault,
  );
}

class VoiceOverSettings {
  const VoiceOverSettings({
    required this.enabled,
    required this.preferWav,
    required this.fallbackToScreenReader,
    required this.events,
  });

  final bool enabled;
  final bool preferWav;
  final bool fallbackToScreenReader;
  final Map<String, VoiceOverEventSettings> events;

  factory VoiceOverSettings.fromMap(
    Map<String, dynamic> map,
    VoiceOverSettings defaults,
  ) {
    final eventsMap = _table(map, 'events');
    final events = <String, VoiceOverEventSettings>{};
    events.addAll(defaults.events);
    for (final entry in eventsMap.entries) {
      if (entry.value is Map) {
        events[entry.key] = VoiceOverEventSettings.fromMap(
          _table(eventsMap, entry.key),
          defaults.events[entry.key] ??
              const VoiceOverEventSettings(text: '', wav: ''),
          'voice_over.events.${entry.key}',
        );
      }
    }
    return VoiceOverSettings(
      enabled: _bool(map, 'enabled', defaults.enabled, 'voice_over.enabled'),
      preferWav: _bool(
        map,
        'prefer_wav',
        defaults.preferWav,
        'voice_over.prefer_wav',
      ),
      fallbackToScreenReader: _bool(
        map,
        'fallback_to_screen_reader',
        defaults.fallbackToScreenReader,
        'voice_over.fallback_to_screen_reader',
      ),
      events: Map.unmodifiable(events),
    );
  }

  Map<String, Object?> toTomlMap() => {
    'enabled': enabled,
    'prefer_wav': preferWav,
    'fallback_to_screen_reader': fallbackToScreenReader,
    'events': {
      for (final entry in events.entries) entry.key: entry.value.toTomlMap(),
    },
  };

  @override
  bool operator ==(Object other) =>
      other is VoiceOverSettings &&
      enabled == other.enabled &&
      preferWav == other.preferWav &&
      fallbackToScreenReader == other.fallbackToScreenReader &&
      _mapEquals(events, other.events);

  @override
  int get hashCode =>
      Object.hash(enabled, preferWav, fallbackToScreenReader, _mapHash(events));
}

class VoiceOverEventSettings {
  const VoiceOverEventSettings({required this.text, required this.wav});

  final String text;
  final String wav;

  factory VoiceOverEventSettings.fromMap(
    Map<String, dynamic> map,
    VoiceOverEventSettings defaults,
    String fieldPrefix,
  ) => VoiceOverEventSettings(
    text: _string(map, 'text', defaults.text, '$fieldPrefix.text'),
    wav: _string(map, 'wav', defaults.wav, '$fieldPrefix.wav'),
  );

  Map<String, Object?> toTomlMap() => {'text': text, 'wav': wav};

  @override
  bool operator ==(Object other) =>
      other is VoiceOverEventSettings && text == other.text && wav == other.wav;

  @override
  int get hashCode => Object.hash(text, wav);
}

class MaintenanceSettings {
  const MaintenanceSettings({
    this.databaseOptimizeEnabled = true,
    this.databaseOptimizeIntervalDays = 7,
  });

  final bool databaseOptimizeEnabled;
  final int databaseOptimizeIntervalDays;

  factory MaintenanceSettings.fromMap(Map<String, dynamic> map) =>
      MaintenanceSettings(
        databaseOptimizeEnabled: _bool(
          map,
          'database_optimize_enabled',
          true,
          'maintenance.database_optimize_enabled',
        ),
        databaseOptimizeIntervalDays: _boundedPositiveInt(
          map,
          'database_optimize_interval_days',
          7,
          'maintenance.database_optimize_interval_days',
          365,
        ),
      );

  MaintenanceSettings copyWith({
    bool? databaseOptimizeEnabled,
    int? databaseOptimizeIntervalDays,
  }) => MaintenanceSettings(
    databaseOptimizeEnabled:
        databaseOptimizeEnabled ?? this.databaseOptimizeEnabled,
    databaseOptimizeIntervalDays:
        databaseOptimizeIntervalDays ?? this.databaseOptimizeIntervalDays,
  );

  Map<String, Object?> toTomlMap() => {
    'database_optimize_enabled': databaseOptimizeEnabled,
    'database_optimize_interval_days': databaseOptimizeIntervalDays,
  };

  @override
  bool operator ==(Object other) =>
      other is MaintenanceSettings &&
      databaseOptimizeEnabled == other.databaseOptimizeEnabled &&
      databaseOptimizeIntervalDays == other.databaseOptimizeIntervalDays;

  @override
  int get hashCode =>
      Object.hash(databaseOptimizeEnabled, databaseOptimizeIntervalDays);
}

class PricingSettings {
  const PricingSettings({
    required this.provider,
    required this.useExternalPricing,
    int? cachePricingHours,
    int? refreshIntervalHours,
    this.automaticRefreshEnabled = true,
    required this.fallbackToOverrides,
    required this.openRouter,
    required this.overrides,
  }) : refreshIntervalHours = refreshIntervalHours ?? cachePricingHours ?? 24;

  final String provider;
  final bool useExternalPricing;
  final int refreshIntervalHours;
  final bool automaticRefreshEnabled;
  // Legacy callers share the canonical refresh interval; TOML writes only the new key.
  int get cachePricingHours => refreshIntervalHours;
  final bool fallbackToOverrides;
  final OpenRouterSettings openRouter;
  final Map<String, PricingOverrideSettings> overrides;

  factory PricingSettings.fromMap(
    Map<String, dynamic> map,
    PricingSettings defaults,
  ) {
    final overridesMap = _table(map, 'overrides');
    final overrides = <String, PricingOverrideSettings>{};
    overrides.addAll(defaults.overrides);
    for (final entry in overridesMap.entries) {
      if (entry.value is Map) {
        overrides[entry.key] = PricingOverrideSettings.fromMap(
          _table(overridesMap, entry.key),
          defaults.overrides[entry.key] ??
              const PricingOverrideSettings(
                prompt: '0',
                completion: '0',
                inputCacheRead: '0',
                inputCacheWrite: '0',
                internalReasoning: '0',
              ),
          'pricing.overrides.${entry.key}',
        );
      }
    }
    return PricingSettings(
      provider: _string(map, 'provider', defaults.provider, 'pricing.provider'),
      useExternalPricing: _bool(
        map,
        'use_external_pricing',
        defaults.useExternalPricing,
        'pricing.use_external_pricing',
      ),
      automaticRefreshEnabled: _bool(
        map,
        'automatic_refresh_enabled',
        defaults.automaticRefreshEnabled,
        'pricing.automatic_refresh_enabled',
      ),
      refreshIntervalHours: _boundedPositiveInt(
        map,
        map.containsKey('refresh_interval_hours')
            ? 'refresh_interval_hours'
            : 'cache_pricing_hours',
        defaults.refreshIntervalHours,
        map.containsKey('refresh_interval_hours')
            ? 'pricing.refresh_interval_hours'
            : 'pricing.cache_pricing_hours',
        720,
      ),
      fallbackToOverrides: _bool(
        map,
        'fallback_to_overrides',
        defaults.fallbackToOverrides,
        'pricing.fallback_to_overrides',
      ),
      openRouter: OpenRouterSettings.fromMap(
        _table(map, 'openrouter'),
        defaults.openRouter,
      ),
      overrides: Map.unmodifiable(overrides),
    );
  }

  Map<String, Object?> toTomlMap() => {
    'provider': provider,
    'use_external_pricing': useExternalPricing,
    'refresh_interval_hours': refreshIntervalHours,
    'automatic_refresh_enabled': automaticRefreshEnabled,
    'fallback_to_overrides': fallbackToOverrides,
    'openrouter': openRouter.toTomlMap(),
    'overrides': {
      for (final entry in overrides.entries) entry.key: entry.value.toTomlMap(),
    },
  };

  @override
  bool operator ==(Object other) =>
      other is PricingSettings &&
      provider == other.provider &&
      useExternalPricing == other.useExternalPricing &&
      cachePricingHours == other.cachePricingHours &&
      automaticRefreshEnabled == other.automaticRefreshEnabled &&
      fallbackToOverrides == other.fallbackToOverrides &&
      openRouter == other.openRouter &&
      _mapEquals(overrides, other.overrides);

  @override
  int get hashCode => Object.hash(
    provider,
    useExternalPricing,
    cachePricingHours,
    automaticRefreshEnabled,
    fallbackToOverrides,
    openRouter,
    _mapHash(overrides),
  );
}

class OpenRouterSettings {
  const OpenRouterSettings({
    required this.modelsEndpoint,
    required this.apiKey,
  });

  final String modelsEndpoint;
  final String apiKey;

  factory OpenRouterSettings.fromMap(
    Map<String, dynamic> map,
    OpenRouterSettings defaults,
  ) => OpenRouterSettings(
    modelsEndpoint: _string(
      map,
      'models_endpoint',
      defaults.modelsEndpoint,
      'pricing.openrouter.models_endpoint',
    ),
    apiKey: _string(
      map,
      'api_key',
      defaults.apiKey,
      'pricing.openrouter.api_key',
    ),
  );

  Map<String, Object?> toTomlMap() => {
    'models_endpoint': modelsEndpoint,
    'api_key': apiKey,
  };

  @override
  bool operator ==(Object other) =>
      other is OpenRouterSettings &&
      modelsEndpoint == other.modelsEndpoint &&
      apiKey == other.apiKey;

  @override
  int get hashCode => Object.hash(modelsEndpoint, apiKey);
}

class PricingOverrideSettings {
  const PricingOverrideSettings({
    required this.prompt,
    required this.completion,
    required this.inputCacheRead,
    required this.inputCacheWrite,
    required this.internalReasoning,
  });

  final String prompt;
  final String completion;
  final String inputCacheRead;
  final String inputCacheWrite;
  final String internalReasoning;

  factory PricingOverrideSettings.fromMap(
    Map<String, dynamic> map,
    PricingOverrideSettings defaults,
    String fieldPrefix,
  ) => PricingOverrideSettings(
    prompt: _string(map, 'prompt', defaults.prompt, '$fieldPrefix.prompt'),
    completion: _string(
      map,
      'completion',
      defaults.completion,
      '$fieldPrefix.completion',
    ),
    inputCacheRead: _string(
      map,
      'input_cache_read',
      defaults.inputCacheRead,
      '$fieldPrefix.input_cache_read',
    ),
    inputCacheWrite: _string(
      map,
      'input_cache_write',
      defaults.inputCacheWrite,
      '$fieldPrefix.input_cache_write',
    ),
    internalReasoning: _string(
      map,
      'internal_reasoning',
      defaults.internalReasoning,
      '$fieldPrefix.internal_reasoning',
    ),
  );

  Map<String, Object?> toTomlMap() => {
    'prompt': prompt,
    'completion': completion,
    'input_cache_read': inputCacheRead,
    'input_cache_write': inputCacheWrite,
    'internal_reasoning': internalReasoning,
  };

  @override
  bool operator ==(Object other) =>
      other is PricingOverrideSettings &&
      prompt == other.prompt &&
      completion == other.completion &&
      inputCacheRead == other.inputCacheRead &&
      inputCacheWrite == other.inputCacheWrite &&
      internalReasoning == other.internalReasoning;

  @override
  int get hashCode => Object.hash(
    prompt,
    completion,
    inputCacheRead,
    inputCacheWrite,
    internalReasoning,
  );
}

class LoggingSettings {
  const LoggingSettings({
    required this.level,
    required this.logFile,
    required this.maxLogFiles,
    required this.maxLogSizeMb,
  });

  final String level;
  final String logFile;
  final int maxLogFiles;
  final int maxLogSizeMb;

  factory LoggingSettings.fromMap(
    Map<String, dynamic> map,
    LoggingSettings defaults,
  ) => LoggingSettings(
    level: _string(map, 'level', defaults.level, 'logging.level'),
    logFile: _string(map, 'log_file', defaults.logFile, 'logging.log_file'),
    maxLogFiles: _positiveInt(
      map,
      'max_log_files',
      defaults.maxLogFiles,
      'logging.max_log_files',
    ),
    maxLogSizeMb: _positiveInt(
      map,
      'max_log_size_mb',
      defaults.maxLogSizeMb,
      'logging.max_log_size_mb',
    ),
  );

  Map<String, Object?> toTomlMap() => {
    'level': level,
    'log_file': logFile,
    'max_log_files': maxLogFiles,
    'max_log_size_mb': maxLogSizeMb,
  };

  @override
  bool operator ==(Object other) =>
      other is LoggingSettings &&
      level == other.level &&
      logFile == other.logFile &&
      maxLogFiles == other.maxLogFiles &&
      maxLogSizeMb == other.maxLogSizeMb;

  @override
  int get hashCode => Object.hash(level, logFile, maxLogFiles, maxLogSizeMb);
}

Map<String, dynamic> _table(Map<String, dynamic> map, String key) {
  final value = map[key];
  if (value == null) {
    return const {};
  }
  if (value is Map) {
    return value.cast<String, dynamic>();
  }
  throw SettingsValidationException(key, 'Expected a TOML table.');
}

String _string(
  Map<String, dynamic> map,
  String key,
  String defaultValue,
  String field,
) {
  final value = map[key];
  if (value == null) {
    return defaultValue;
  }
  if (value is String) {
    return value;
  }
  throw SettingsValidationException(field, 'Expected a string.');
}

bool _bool(
  Map<String, dynamic> map,
  String key,
  bool defaultValue,
  String field,
) {
  final value = map[key];
  if (value == null) {
    return defaultValue;
  }
  if (value is bool) {
    return value;
  }
  throw SettingsValidationException(field, 'Expected a boolean.');
}

int _positiveInt(
  Map<String, dynamic> map,
  String key,
  int defaultValue,
  String field,
) {
  final value = map[key];
  if (value == null) {
    return defaultValue;
  }
  if (value is int && value > 0) {
    return value;
  }
  throw SettingsValidationException(field, 'Expected a positive integer.');
}

int _boundedPositiveInt(
  Map<String, dynamic> map,
  String key,
  int defaultValue,
  String field,
  int maximum,
) {
  final value = _positiveInt(map, key, defaultValue, field);
  if (value <= maximum) return value;
  throw SettingsValidationException(
    field,
    'Expected an integer from 1 to $maximum.',
  );
}

double _number(Map<String, dynamic> map, String key, String field) {
  final value = map[key];
  if (value is num) {
    return value.toDouble();
  }
  throw SettingsValidationException(field, 'Expected a number.');
}

bool _mapEquals<K, V>(Map<K, V> left, Map<K, V> right) {
  if (left.length != right.length) {
    return false;
  }
  for (final entry in left.entries) {
    if (!right.containsKey(entry.key) || right[entry.key] != entry.value) {
      return false;
    }
  }
  return true;
}

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) {
      return false;
    }
  }
  return true;
}

int _mapHash<K, V>(Map<K, V> map) => Object.hashAll(
  map.entries.map((entry) => Object.hash(entry.key, entry.value)),
);

List<Map<String, dynamic>> _listOfMaps(
  Map<String, dynamic> map,
  String key,
  String field,
) {
  final value = map[key];
  if (value == null) {
    return const [];
  }
  if (value is List) {
    return [
      for (final item in value)
        if (item is Map)
          item.cast<String, dynamic>()
        else
          throw SettingsValidationException(field, 'Expected TOML tables.'),
    ];
  }
  throw SettingsValidationException(field, 'Expected a TOML array.');
}

const Object _sentinel = Object();
