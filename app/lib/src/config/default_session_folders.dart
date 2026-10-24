import 'package:codex_sessions_viewer/src/platform/app_environment.dart';

import 'package:path/path.dart' as p;

/// The default WSL distribution and its Linux home, as detected on the host.
final class WslDistroDefaults {
  const WslDistroDefaults({required this.distro, required this.linuxHome});

  final String distro;

  /// Absolute Linux path such as `/home/me`.
  final String linuxHome;

  /// Parses `printenv WSL_DISTRO_NAME HOME` output (one value per line), or
  /// returns null when it does not describe a usable distribution.
  static WslDistroDefaults? parse(String output) {
    final lines = output
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    if (lines.length != 2) return null;
    final [distro, home] = lines;
    if (distro.contains(RegExp(r'[\\/:*?"<>|]')) || !home.startsWith('/')) {
      return null;
    }
    return WslDistroDefaults(distro: distro, linuxHome: home);
  }
}

/// Session folders used when the settings file does not name them.
///
/// Derived from the current user's environment so no default names one
/// particular user. The collector applies the same rules
/// (`collector/src/settings.rs`, `collector/src/claude/mod.rs`).
final class DefaultSessionFolders {
  const DefaultSessionFolders({
    this.windowsCodexPath = '',
    this.claudeProjectsRoot = '',
    this.wslDistro = '',
    this.wslLinuxHome = '',
  });

  /// Uses `CODEX_HOME` when set, else `<home>\.codex`; the Claude projects
  /// root is `<home>\.claude\projects`. The home folder is `USERPROFILE`,
  /// falling back to `HOME`. WSL values come only from [wsl].
  factory DefaultSessionFolders.fromEnvironment(
    Map<String, String> environment, {
    WslDistroDefaults? wsl,
    p.Context? pathContext,
  }) {
    final path = pathContext ?? p.context;
    String nonEmpty(String name) => environment[name]?.trim() ?? '';
    final home = nonEmpty('USERPROFILE').isNotEmpty
        ? nonEmpty('USERPROFILE')
        : nonEmpty('HOME');
    final codexHome = nonEmpty('CODEX_HOME');
    return DefaultSessionFolders(
      windowsCodexPath: codexHome.isNotEmpty
          ? codexHome
          : home.isEmpty
          ? ''
          : path.join(home, '.codex'),
      claudeProjectsRoot: home.isEmpty
          ? ''
          : path.join(home, '.claude', 'projects'),
      wslDistro: wsl?.distro ?? '',
      wslLinuxHome: wsl?.linuxHome ?? '',
    );
  }

  static DefaultSessionFolders? _current;

  /// The defaults for this process's environment, without WSL detection.
  static DefaultSessionFolders current() => _current ??=
      DefaultSessionFolders.fromEnvironment(AppEnvironment.current);

  final String windowsCodexPath;
  final String claudeProjectsRoot;
  final String wslDistro;
  final String wslLinuxHome;

  /// `\\wsl.localhost\<distro>\`, or empty without a detected distribution.
  String get wslLinuxRootUnc =>
      wslDistro.isEmpty ? '' : '\\\\wsl.localhost\\$wslDistro\\';

  /// `<linux root>\home\me\.codex`, or empty without a detected distribution.
  String get wslCodexUncPath {
    if (wslDistro.isEmpty || wslLinuxHome.isEmpty) return '';
    final segments = wslLinuxHome.split('/').where((part) => part.isNotEmpty);
    return '$wslLinuxRootUnc${[...segments, '.codex'].join('\\')}';
  }

  DefaultSessionFolders withWsl(WslDistroDefaults? wsl) =>
      DefaultSessionFolders(
        windowsCodexPath: windowsCodexPath,
        claudeProjectsRoot: claudeProjectsRoot,
        wslDistro: wsl?.distro ?? '',
        wslLinuxHome: wsl?.linuxHome ?? '',
      );
}
