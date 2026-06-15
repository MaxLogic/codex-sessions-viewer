import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('row action menu invokes callbacks with generated payloads', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionsScreen(
            initialRows: [_row(sessionId: 'abc123')],
            onSessionAction: (request) async {
              actions.add(request);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byType(PopupMenuButton<SessionRowAction>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy path'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<SessionRowAction>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy plain resume command'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<SessionRowAction>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Re-parse session'));
    await tester.pumpAndSettle();

    expect(actions.map((action) => action.action), [
      SessionRowAction.copyPath,
      SessionRowAction.copyPlainResumeCommand,
      SessionRowAction.reparse,
    ]);
    expect(actions[0].payload, r'F:\projects\MaxLogic\codex-sessions-viewer');
    expect(actions[1].payload, 'codex resume abc123');
  });

  testWidgets('resume actions are disabled when session id is unavailable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [_row(sessionId: '')],
          onSessionAction: (request) async {
            actions.add(request);
          },
        ),
      ),
    );

    await tester.tap(find.byType(PopupMenuButton<SessionRowAction>));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<PopupMenuItem<SessionRowAction>>(
            find.widgetWithText(
              PopupMenuItem<SessionRowAction>,
              'Copy plain resume command',
            ),
          )
          .enabled,
      isFalse,
    );
    expect(find.textContaining('Resume unavailable'), findsWidgets);
    expect(actions, isEmpty);
  });

  testWidgets('row command payloads use injected settings', (tester) async {
    await tester.binding.setSurfaceSize(const Size(5000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          settings: AppSettings.defaults().copyWith(
            wsl: const WslSettings(
              distro: 'Debian',
              linuxHome: '/home/pawel',
              linuxRootUnc: r'\\wsl.localhost\Debian\home\pawel\',
            ),
          ),
          initialRows: [
            _row(sessionId: 'abc123', platform: SessionRowPlatform.wsl),
          ],
          onSessionAction: (request) async {
            actions.add(request);
          },
        ),
      ),
    );

    await tester.tap(find.byType(PopupMenuButton<SessionRowAction>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy platform resume command'));
    await tester.pumpAndSettle();

    expect(actions.single.action, SessionRowAction.copyPlatformResumeCommand);
    expect(actions.single.payload, contains('Debian'));
  });

  testWidgets('selected detail command preview routes run actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionsScreen(
            initialRows: [_row(sessionId: 'abc123')],
            onSessionAction: (request) async {
              actions.add(request);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Parser cache').first);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Run'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Edit and run'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'cmd /c echo edited');
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await tester.pumpAndSettle();

    final reparse = find.widgetWithText(
      OutlinedButton,
      'Re-parse this session',
    );
    await tester.ensureVisible(reparse);
    await tester.tap(reparse);
    await tester.pumpAndSettle();

    expect(actions.map((action) => action.action), [
      SessionRowAction.openTerminalResume,
      SessionRowAction.openTerminalResume,
      SessionRowAction.reparse,
    ]);
    expect(actions.first.payload, contains('codex resume abc123'));
    expect(actions[1].payload, 'cmd /c echo edited');

    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Export Markdown'),
          )
          .enabled,
      isFalse,
    );
  });
}

SessionRowViewModel _row({
  required String sessionId,
  SessionRowPlatform platform = SessionRowPlatform.windows,
}) {
  return SessionRowViewModel(
    id: 'active',
    sessionId: sessionId,
    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
    lastMessageAtUtc: DateTime.utc(2026, 6, 12, 10),
    platform: platform,
    project: 'Codex Viewer',
    path: r'F:\projects\MaxLogic\codex-sessions-viewer',
    displayPath: r'F:\projects\MaxLogic\codex-sessions-viewer',
    workingDirectory: r'F:\projects\MaxLogic\codex-sessions-viewer',
    title: 'Parser cache',
    summary: 'Session summary',
    messageCount: 7,
    totalTokens: 1200,
    model: 'gpt-5.4',
    tags: const ['parser'],
    status: 'Available',
  );
}
