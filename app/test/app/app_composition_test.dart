import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/ui/app_shell.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app shell renders injected screen composition', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: CodexAppShell(
          sessionsScreenBuilder: (context, onOpenSettings) {
            return Column(
              children: [
                const Text('Injected sessions screen'),
                TextButton(
                  onPressed: onOpenSettings,
                  child: const Text('Open injected settings'),
                ),
              ],
            );
          },
          evalsScreen: const Text('Injected evals screen'),
          contextScreen: const Text('Injected context screen'),
          usageScreen: const Text('Injected usage screen'),
          settingsScreen: const Text('Injected settings screen'),
          logsScreen: const Text('Injected logs screen'),
          projectsScreen: const Text('Projects content'),
        ),
      ),
    );

    expect(find.text('Injected sessions screen'), findsOneWidget);

    await tester.tap(find.text('Open injected settings'));
    await tester.pumpAndSettle();
    expect(find.text('Injected settings screen'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(RegExp('^Evals navigation\\nTab ')));
    await tester.pumpAndSettle();
    expect(find.text('Injected evals screen'), findsOneWidget);

    await tester.tap(
      find.bySemanticsLabel(RegExp('^Context navigation\\nTab ')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Injected context screen'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')));
    await tester.pumpAndSettle();
    expect(find.text('Injected usage screen'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel(RegExp('^Logs navigation\\nTab ')));
    await tester.pumpAndSettle();
    expect(find.text('Injected logs screen'), findsOneWidget);
  });

  testWidgets('an injected cached-rows loader receives progress and rows', (
    tester,
  ) async {
    final row = SessionRowViewModel(
      id: 'injected',
      startedAtUtc: DateTime.utc(2026, 9, 24, 8),
      lastMessageAtUtc: DateTime.utc(2026, 9, 24, 9),
      platform: SessionRowPlatform.windows,
      project: 'Injected',
      path: r'C:\injected.jsonl',
      title: 'Injected row',
      summary: '',
      messageCount: 1,
      totalTokens: 1,
      model: 'model',
      tags: const [],
      status: 'available',
    );
    var progressCalls = 0;
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 5),
        ),
        settingsStartup: Future.value(AppSettings.defaults()),
        sessionCachedRowsLoader: (onProgress) async {
          progressCalls++;
          onProgress(
            SessionsRefreshProgress(rows: [row], statusMessage: 'Loading.'),
          );
          return SessionsRefreshResult(rows: [row], statusMessage: '');
        },
        deferInitialSessionLoad: (callback) => callback(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(progressCalls, 1);
    expect(
      tester.widget<SessionsScreen>(find.byType(SessionsScreen)).initialRows,
      [row],
    );
  });
}
