import 'dart:async';
import 'dart:ui';

import 'package:codex_sessions_viewer/src/app/codex_sessions_viewer_app.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('failed usage refresh retains last successful snapshot', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loadCalls = 0;
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 15),
        ),
        settingsStartup: Future.value(_usageTestSettings()),
        deferInitialSessionLoad: (_) {},
        usageSummaryLoader: (_) {
          loadCalls++;
          return loadCalls == 1
              ? Future.value(
                  _summary(
                    title: 'Retained usage',
                    inputTokens: 11,
                    totalTokens: 12,
                  ),
                )
              : Future.error(StateError('private failure details'));
        },
        sessionRefresh: () async => const SessionsRefreshResult(
          rows: [],
          statusMessage: 'Scan finished.',
        ),
      ),
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('Refresh'));
    await _pumpFrames(tester);
    await tester.tap(find.bySemanticsLabel('Usage navigation'));
    await _pumpFrames(tester);

    expect(
      find.text(
        'Usage status refresh failed; showing the last successful snapshot.',
      ),
      findsOneWidget,
    );
    expect(find.text('12'), findsWidgets);
    expect(find.textContaining('private failure details'), findsNothing);
  });

  testWidgets('usage status refreshes without blocking', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final refreshed = Completer<UsageSummary?>();
    var loadCalls = 0;
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 15),
        ),
        settingsStartup: Future.value(_usageTestSettings()),
        deferInitialSessionLoad: (_) {},
        usageSummaryLoader: (_) {
          loadCalls++;
          return loadCalls == 1
              ? Future.value(
                  _summary(
                    title: 'Retained usage',
                    inputTokens: 11,
                    totalTokens: 12,
                  ),
                )
              : refreshed.future;
        },
        sessionRefresh: () async => const SessionsRefreshResult(
          rows: [],
          statusMessage: 'Scan finished.',
        ),
      ),
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('Refresh'));
    await _pumpFrames(tester, count: 2);
    expect(find.text('Scan finished.'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Usage navigation'));
    await _pumpFrames(tester, count: 2);

    expect(find.text('Refreshing usage status…'), findsOneWidget);
    expect(find.text('12'), findsWidgets);

    refreshed.complete(
      _summary(title: 'Refreshed usage', inputTokens: 20, totalTokens: 25),
    );
    await _pumpFrames(tester);

    expect(find.text('Refreshing usage status…'), findsNothing);
    expect(find.text('25'), findsWidgets);
  });

  testWidgets('usage screen displays refreshed calculated statistics', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 5),
        ),
        settingsStartup: Future.value(_usageTestSettings()),
        deferInitialSessionLoad: (_) {},
        usageSummaryLoader: (_) async =>
            _summary(title: 'Usage existing', inputTokens: 42, totalTokens: 70),
      ),
    );
    await _pumpFrames(tester);

    await tester.tap(find.bySemanticsLabel('Usage navigation'));
    await _pumpFrames(tester);

    expect(find.text('70'), findsWidgets);
    expect(find.text('42'), findsWidgets);
    await tester.tap(find.text('Top'));
    await _pumpFrames(tester);
    expect(find.text('Usage existing'), findsWidgets);
  });

  testWidgets('usage statistics update after refresh', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loadCalls = 0;
    await tester.pumpWidget(
      CodexSessionsViewerApp(
        databaseStartup: Future.value(
          DatabaseStartupResult.ready(lastAppliedSchemaVersion: 5),
        ),
        settingsStartup: Future.value(_usageTestSettings()),
        deferInitialSessionLoad: (_) {},
        usageSummaryLoader: (_) async {
          loadCalls++;
          return loadCalls == 1
              ? _summary(
                  title: 'Before refresh',
                  inputTokens: 1,
                  totalTokens: 2,
                )
              : _summary(title: 'Usage new', inputTokens: 10, totalTokens: 17);
        },
        sessionRefresh: () async => const SessionsRefreshResult(
          rows: [],
          statusMessage: 'Scan finished.',
        ),
      ),
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('Refresh'));
    await _pumpFrames(tester);
    await tester.tap(find.bySemanticsLabel('Usage navigation'));
    await _pumpFrames(tester);

    expect(find.text('17'), findsWidgets);
    expect(find.text('10'), findsWidgets);
    await tester.tap(find.text('Top'));
    await _pumpFrames(tester);
    expect(find.text('Usage new'), findsWidgets);
  });
}

AppSettings _usageTestSettings() => AppSettings.defaults().copyWith(
  scanner: const ScannerSettings(
    backgroundRescanEnabled: false,
    backgroundRescanIntervalSeconds: 60,
  ),
);

UsageSummary _summary({
  required String title,
  required int inputTokens,
  required int totalTokens,
}) {
  return UsageSummary(
    period: UsageDateRange(
      startUtc: DateTime.utc(2026, 6, 1),
      endExclusiveUtc: DateTime.utc(2026, 7, 1),
    ),
    totalSessions: 1,
    totalMessages: 3,
    inputTokens: inputTokens,
    outputTokens: totalTokens - inputTokens,
    cachedInputTokens: 0,
    totalTokens: totalTokens,
    estimatedCostText: '0',
    costUnknown: false,
    mostUsedModel: 'gpt-5.4',
    mostActiveProject: 'Codex Viewer',
    mostActivePlatform: 'Windows',
    byDay: [
      UsageBreakdownRow(
        key: '2026-06-18',
        sessionCount: 1,
        messageCount: 3,
        inputTokens: inputTokens,
        outputTokens: totalTokens - inputTokens,
        cachedInputTokens: 0,
        totalTokens: totalTokens,
        estimatedCostText: '0',
        costUnknown: false,
      ),
    ],
    byWeek: const [],
    byMonth: const [],
    byModel: const [],
    byProject: const [],
    byPlatform: const [],
    byOrigin: const [],
    byArchiveState: const [],
    topSessionsByTokens: [
      UsageTopSession(
        sessionId: title,
        title: title,
        messageCount: 3,
        totalTokens: totalTokens,
        estimatedCostText: '0',
        costUnknown: false,
        originLabel: 'User',
      ),
    ],
    topSessionsByMessageCount: const [],
    topSessionsByEstimatedCost: const [],
  );
}

Future<void> _pumpFrames(WidgetTester tester, {int count = 5}) async {
  for (var i = 0; i < count; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
