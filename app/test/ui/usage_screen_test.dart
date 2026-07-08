import 'package:codex_sessions_viewer/src/accessibility/announcement_service.dart';
import 'package:codex_sessions_viewer/src/ui/number_formatting.dart';
import 'package:codex_sessions_viewer/src/ui/screens/usage_screen.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

UsageSummary _summary() {
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
    costUnknown: false,
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
