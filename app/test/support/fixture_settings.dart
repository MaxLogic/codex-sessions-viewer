import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/config/default_session_folders.dart';

/// Session folders of a fixed fixture machine with an `Ubuntu` WSL
/// distribution, so tests do not depend on the host's user or WSL setup.
const fixtureSessionFolders = DefaultSessionFolders(
  windowsCodexPath: r'C:\Users\dev\.codex',
  claudeProjectsRoot: r'C:\Users\dev\.claude\projects',
  wslDistro: 'Ubuntu',
  wslLinuxHome: '/home/dev',
);

/// [AppSettings.defaults] for [fixtureSessionFolders].
AppSettings fixtureDefaultSettings() =>
    AppSettings.defaults(folders: fixtureSessionFolders);
