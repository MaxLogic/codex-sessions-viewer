import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';

DateTime fixedSessionsNow() => DateTime.utc(2026, 6, 15, 12);

class TestSessionsScreen extends SessionsScreen {
  TestSessionsScreen({
    super.key,
    super.initialRows,
    super.onRefresh,
    super.onRefreshResult,
    super.onRefreshWithProgress,
    super.onRefreshOperation,
    super.onOpenSettings,
    super.onTestWslPath,
    super.onSessionAction,
    super.onCopyText,
    super.onExportMarkdown,
    super.onSaveSessionListCsv,
    super.onLoadSessionListExportMessages,
    super.onLoadSessionDetail,
    super.onReloadSessionDetailFromSource,
    super.onLoadMessagePage,
    super.onLoadAllMessages,
    super.watchSessionFile,
    super.settings,
    super.initialTableState,
    super.onTableStateChanged,
    super.initialStatusMessage,
    super.autoRefreshToken,
    super.openTarget,
    super.openTargetSerial,
    super.projectFilterRequest,
    super.projectFilterSerial,
    super.now = fixedSessionsNow,
  });
}
