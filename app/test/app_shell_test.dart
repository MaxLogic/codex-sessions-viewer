import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/ui/app_shell.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('launches a minimal app shell', (tester) async {
    await tester.pumpWidget(CodexSessionsViewerApp());
    await tester.pump();

    expect(find.text(CodexSessionsViewerApp.appTitle), findsOneWidget);
    expect(CodexSessionsViewerApp.nativeTitleBarEnabled, isTrue);
  });

  testWidgets('defers cached session loading until after first shell frame', (
    tester,
  ) async {
    var loadCalls = 0;
    VoidCallback? deferredInitialLoad;

    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 5),
        ),
        settingsStartup: Future.value(AppSettings.defaults()),
        sessionCachedRowsLoader: (_) {
          loadCalls++;
          return Future.value(SessionsRefreshResult.scanFinished(const []));
        },
        deferInitialSessionLoad: (callback) {
          deferredInitialLoad = callback;
        },
      ),
    );

    await tester.pump();
    await tester.pump();

    expect(find.text(CodexSessionsViewerApp.appTitle), findsOneWidget);
    expect(find.text('Refresh'), findsOneWidget);
    expect(deferredInitialLoad, isNotNull);
    expect(loadCalls, 0);
  });

  testWidgets('app shell animates section changes using motion policy', (
    tester,
  ) async {
    await tester.pumpWidget(
      _shellHost(
        motionMode: AppMotionMode.normal,
        sessions: const Text('Sessions content'),
        evals: const Text('Evals content'),
        context: const Text('Context content'),
        usage: const Text('Usage content'),
        settings: const Text('Settings content'),
        logs: const Text('Logs content'),
      ),
    );

    await tester.tap(find.text('Usage'));
    await tester.pump();

    expect(find.byType(AnimatedSwitcher), findsOneWidget);
    expect(find.byType(FadeTransition), findsWidgets);
    expect(find.byType(SlideTransition), findsWidgets);
    expect(find.text('Sessions content'), findsWidgets);
    expect(find.text('Usage content'), findsWidgets);

    await tester.pumpAndSettle();
    expect(find.text('Usage content'), findsOneWidget);
  });

  testWidgets('app shell preserves navigation semantics with motion', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();

    await tester.pumpWidget(
      _shellHost(
        motionMode: AppMotionMode.normal,
        sessions: const Text('Sessions content'),
        evals: const Text('Evals content'),
        context: const Text('Context content'),
        usage: const Text('Usage content'),
        settings: const Text('Settings content'),
        logs: const Text('Logs content'),
      ),
    );

    expect(
      find.bySemanticsLabel(RegExp('^Sessions navigation\\nTab ')),
      findsWidgets,
    );
    expect(
      find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')),
      findsWidgets,
    );

    await tester.tap(find.text('Usage'));
    await tester.pump();

    expect(find.bySemanticsLabel('Sessions content'), findsNothing);

    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(RegExp('^Usage navigation\\nTab ')),
      findsWidgets,
    );
    expect(find.text('Usage content'), findsOneWidget);

    semantics.dispose();
  });

  testWidgets('app shell reduces section transition movement', (tester) async {
    await tester.pumpWidget(
      _shellHost(
        motionMode: AppMotionMode.reduced,
        sessions: const Text('Sessions content'),
        evals: const Text('Evals content'),
        context: const Text('Context content'),
        usage: const Text('Usage content'),
        settings: const Text('Settings content'),
        logs: const Text('Logs content'),
      ),
    );

    await tester.tap(find.text('Usage'));
    await tester.pump();

    expect(find.byType(AnimatedSwitcher), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AnimatedSwitcher),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );

    await tester.pumpAndSettle();
    expect(find.text('Usage content'), findsOneWidget);
  });
}

Widget _shellHost({
  required AppMotionMode motionMode,
  required Widget sessions,
  required Widget evals,
  required Widget context,
  required Widget usage,
  required Widget settings,
  required Widget logs,
}) {
  return MaterialApp(
    home: CodexAppShell(
      motionMode: motionMode,
      sessionsScreenBuilder: (_, _) => sessions,
      evalsScreen: evals,
      contextScreen: context,
      usageScreen: usage,
      settingsScreen: settings,
      logsScreen: logs,
    ),
  );
}
