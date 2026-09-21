import 'package:codex_sessions_viewer/src/accessibility/announcement_service.dart';
import 'package:codex_sessions_viewer/src/ui/number_formatting.dart';
import 'package:codex_sessions_viewer/src/ui/screens/usage_screen.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('discloses historical partial costs and pending repricing', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          home: UsageScreen(
            summary: _summary(
              pricingStatus: const UsagePricingStatus(
                openRouterFetchedAtUtc: null,
                models: [],
                usesHistoricalCosts: true,
                updating: true,
                partialUnsupportedUnits: true,
              ),
              costUnknown: true,
            ),
          ),
        ),
      );
      expect(
        find.text('Historical estimates at last observed rates'),
        findsOneWidget,
      );
      expect(
        find.text('Estimated cost at current cached/override rates'),
        findsNothing,
      );
      expect(find.text('Pricing update in progress'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Pricing update in progress'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Partial estimate: charges for unmeasured units are excluded.',
        ),
        findsOneWidget,
      );
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('custom period waits for dates and cancel preserves selection', (
    tester,
  ) async {
    final requests = <UsageSummaryRequest>[];
    await tester.pumpWidget(
      MaterialApp(home: UsageScreen(onPeriodChanged: requests.add)),
    );
    await tester.tap(find.text('Custom range'));
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    expect(requests, isEmpty);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(requests, isEmpty);
    final chip = tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, 'Last 30 days'),
    );
    expect(chip.selected, isTrue);
  });

  testWidgets(
    'custom dates load an inclusive selection as a half-open UTC range',
    (tester) async {
      final requests = <UsageSummaryRequest>[];
      await tester.pumpWidget(
        MaterialApp(home: UsageScreen(onPeriodChanged: requests.add)),
      );
      await tester.tap(find.text('Custom range'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Switch to input'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '09/01/2026');
      await tester.enterText(find.byType(TextField).at(1), '09/04/2026');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      expect(requests.single.period, UsagePeriod.custom);
      expect(requests.single.resolve().startUtc, DateTime.utc(2026, 9, 1));
      expect(
        requests.single.resolve().endExclusiveUtc,
        DateTime.utc(2026, 9, 5),
      );
    },
  );

  testWidgets('shows branch-aware coverage and current-rate cost status', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: UsageScreen(
          summary: _summary(
            projectionCoverage: const UsageProjectionCoverage(
              projectionVersion: 3,
              availableSessions: 6,
              currentCompleteSessions: 3,
              legacyPendingSessions: 1,
              ambiguousSessions: 1,
              missingParentSessions: 1,
              completeZeroUsageSessions: 1,
            ),
            pricingStatus: UsagePricingStatus(
              openRouterFetchedAtUtc: DateTime.utc(2026, 7, 29, 8),
              refreshSucceeded: false,
              models: [
                UsageModelPricingStatus(
                  rawModelId: 'gpt-5.6-sol-requested',
                  effectiveModelId: 'gpt-5.6-sol',
                  resolvedModelId: 'openai/gpt-5.6-sol',
                  resolutionMethod: UsageModelResolutionMethod.openAiExact,
                  source: 'openrouter',
                  fetchedAtUtc: DateTime.utc(2026, 7, 29, 7, 30),
                ),
              ],
            ),
            costUnknown: true,
          ),
          isRefreshing: true,
        ),
      ),
    );

    expect(find.text('Usage projection version 3'), findsOneWidget);
    expect(find.text('3 of 6 sessions current and complete'), findsOneWidget);
    expect(
      find.text('Omitted: 1 pending, 1 ambiguous, 1 missing parent'),
      findsOneWidget,
    );
    expect(find.text('1 complete zero-usage session'), findsOneWidget);
    expect(
      find.text('Estimated cost at current cached/override rates'),
      findsOneWidget,
    );
    expect(find.text('Cost unknown'), findsOneWidget);
    expect(find.text('Refreshing usage status…'), findsOneWidget);
    expect(
      find.text(
        'Raw: gpt-5.6-sol-requested; effective: gpt-5.6-sol; '
        'resolved: openai/gpt-5.6-sol; '
        'openAiExact; cached; openrouter; fetched 2026-07-29 07:30 UTC',
      ),
      findsOneWidget,
    );
    expect(
      find.text('OpenRouter cache fetched 2026-07-29 08:00 UTC'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Pricing refresh failed; cached/override rates are being shown.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('shows period filters, summary cards, tabs, and chart content', (
    tester,
  ) async {
    final announcer = RecordingScreenReaderAnnouncer();

    await tester.pumpWidget(
      MaterialApp(
        home: UsageScreen(summary: _summary(), announcer: announcer),
      ),
    );

    expect(find.bySemanticsLabel('Period filter'), findsOneWidget);
    for (final label in const [
      'Today',
      'Yesterday',
      'This week',
      'Last week',
      'This month',
      'Last month',
      'Last 30 days',
      'Custom range',
    ]) {
      expect(find.text(label), findsOneWidget);
    }

    for (final card in const [
      'Total sessions',
      'Total messages',
      'Input tokens',
      'Output tokens',
      'Cached input tokens',
      'Total tokens',
      'Estimated cost',
      'Most used model',
      'Most active project',
      'Most active platform',
    ]) {
      expect(find.text(card), findsOneWidget);
    }

    for (final tab in const [
      'Overview',
      'Models',
      'Projects',
      'Platforms',
      'Top',
    ]) {
      expect(find.text(tab), findsOneWidget);
    }

    expect(find.text('Tokens over time'), findsOneWidget);
    expect(find.textContaining('Tokens over time:'), findsOneWidget);
    expect(find.text('2026-06-12'), findsWidgets);
    expect(find.text('${formatCompactInt(3200)} tokens'), findsWidgets);
    expect(
      find.bySemanticsLabel('Tokens over time table equivalent'),
      findsOneWidget,
    );

    await tester.tap(find.text('Today'));
    await tester.pump();

    expect(find.text('Usage period changed to Today.'), findsOneWidget);
    expect(announcer.messages, contains('Usage period changed to Today.'));

    await tester.ensureVisible(find.text('Top'));
    await tester.ensureVisible(find.text('Platforms'));
    await tester.tap(find.text('Platforms'));
    await tester.pumpAndSettle();

    expect(find.text('Usage by origin'), findsOneWidget);
    expect(
      find.text('User, 3 sessions, ${formatCompactInt(6000)} tokens'),
      findsOneWidget,
    );
    expect(
      find.text('Subagent, 1 session, ${formatCompactInt(1300)} tokens'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Top'));
    await tester.tap(find.text('Top'));
    await tester.pumpAndSettle();

    expect(find.text('Top sessions by tokens'), findsOneWidget);
    expect(find.text('Top sessions by message count'), findsOneWidget);
    expect(find.text('Top sessions by estimated cost'), findsOneWidget);
    expect(
      find.text(
        'Parser cache work, Origin: User, ${formatCompactInt(4100)} tokens',
      ),
      findsOneWidget,
    );
  });
}

UsageSummary _summary({
  UsageProjectionCoverage projectionCoverage =
      const UsageProjectionCoverage.empty(),
  UsagePricingStatus pricingStatus = const UsagePricingStatus.empty(),
  bool costUnknown = false,
}) {
  return UsageSummary(
    period: UsageDateRange(
      startUtc: DateTime.utc(2026, 6, 1),
      endExclusiveUtc: DateTime.utc(2026, 7, 1),
    ),
    totalSessions: 4,
    totalMessages: 41,
    inputTokens: 4300,
    outputTokens: 2100,
    cachedInputTokens: 900,
    totalTokens: 7300,
    estimatedCostText: r'$0.34',
    costUnknown: costUnknown,
    projectionCoverage: projectionCoverage,
    pricingStatus: pricingStatus,
    mostUsedModel: 'gpt-5.4',
    mostActiveProject: 'Codex Viewer',
    mostActivePlatform: 'Windows',
    byDay: const [
      UsageBreakdownRow(
        key: '2026-06-12',
        sessionCount: 2,
        messageCount: 25,
        inputTokens: 1900,
        outputTokens: 900,
        cachedInputTokens: 400,
        totalTokens: 3200,
        estimatedCostText: r'$0.15',
        costUnknown: false,
      ),
      UsageBreakdownRow(
        key: '2026-06-13',
        sessionCount: 2,
        messageCount: 16,
        inputTokens: 2400,
        outputTokens: 1200,
        cachedInputTokens: 500,
        totalTokens: 4100,
        estimatedCostText: r'$0.19',
        costUnknown: false,
      ),
    ],
    byWeek: const [],
    byMonth: const [],
    byModel: const [
      UsageBreakdownRow(
        key: 'gpt-5.4',
        sessionCount: 3,
        messageCount: 31,
        inputTokens: 3300,
        outputTokens: 1600,
        cachedInputTokens: 800,
        totalTokens: 5700,
        estimatedCostText: r'$0.27',
        costUnknown: false,
      ),
    ],
    byProject: const [
      UsageBreakdownRow(
        key: 'Codex Viewer',
        sessionCount: 4,
        messageCount: 41,
        inputTokens: 4300,
        outputTokens: 2100,
        cachedInputTokens: 900,
        totalTokens: 7300,
        estimatedCostText: r'$0.34',
        costUnknown: false,
      ),
    ],
    byPlatform: const [
      UsageBreakdownRow(
        key: 'Windows',
        sessionCount: 3,
        messageCount: 30,
        inputTokens: 3100,
        outputTokens: 1500,
        cachedInputTokens: 600,
        totalTokens: 5200,
        estimatedCostText: r'$0.24',
        costUnknown: false,
      ),
    ],
    byOrigin: const [
      UsageBreakdownRow(
        key: 'User',
        sessionCount: 3,
        messageCount: 34,
        inputTokens: 3600,
        outputTokens: 1700,
        cachedInputTokens: 700,
        totalTokens: 6000,
        estimatedCostText: r'$0.28',
        costUnknown: false,
      ),
      UsageBreakdownRow(
        key: 'Subagent',
        sessionCount: 1,
        messageCount: 7,
        inputTokens: 700,
        outputTokens: 400,
        cachedInputTokens: 200,
        totalTokens: 1300,
        estimatedCostText: r'$0.06',
        costUnknown: false,
      ),
    ],
    byArchiveState: const [
      UsageBreakdownRow(
        key: 'active',
        sessionCount: 3,
        messageCount: 35,
        inputTokens: 3600,
        outputTokens: 1800,
        cachedInputTokens: 700,
        totalTokens: 6100,
        estimatedCostText: r'$0.29',
        costUnknown: false,
      ),
    ],
    topSessionsByTokens: const [
      UsageTopSession(
        sessionId: 'session-a',
        title: 'Parser cache work',
        messageCount: 18,
        totalTokens: 4100,
        estimatedCostText: r'$0.19',
        costUnknown: false,
        originLabel: 'User',
      ),
    ],
    topSessionsByMessageCount: const [],
    topSessionsByEstimatedCost: const [],
  );
}
