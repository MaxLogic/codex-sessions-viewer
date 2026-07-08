import 'package:codex_sessions_viewer/src/ui/number_formatting.dart';
import 'package:codex_sessions_viewer/src/ui/screens/usage_screen.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('charts expose readable summaries and table equivalents', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: UsageScreen(summary: _summary())),
    );

    expect(find.textContaining('Tokens over time:'), findsOneWidget);
    expect(find.text('Cost over time'), findsOneWidget);
    expect(find.text('Usage by week'), findsOneWidget);
    expect(find.text('Usage by month'), findsOneWidget);
    expect(find.text('Input vs output vs cached tokens'), findsOneWidget);
    expect(find.text('2026-06-12, 1 session, 900 tokens'), findsOneWidget);
    expect(
      find.text('2026-06-13, 2 sessions, ${formatCompactInt(1800)} tokens'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Tokens over time chart'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Tokens over time table equivalent'),
      findsOneWidget,
    );

    for (final column in const [
      'Label',
      'Sessions',
      'Messages',
      'Input',
      'Output',
      'Cached',
      'Tokens',
      'Cost',
    ]) {
      expect(find.text(column), findsWidgets);
    }

    await tester.ensureVisible(find.text('Models'));
    await tester.tap(find.text('Models'));
    await tester.pumpAndSettle();

    expect(find.text('Tokens by model'), findsOneWidget);
    expect(find.textContaining('Tokens by model:'), findsOneWidget);
    expect(
      find.text('gpt-5.4, 2 sessions, ${formatCompactInt(1800)} tokens'),
      findsOneWidget,
    );
    expect(
      find.text('claude-sonnet-4.5, 1 session, 900 tokens'),
      findsOneWidget,
    );

    await tester.ensureVisible(find.text('Platforms'));
    await tester.tap(find.text('Platforms'));
    await tester.pumpAndSettle();

    expect(find.text('Usage by platform'), findsOneWidget);
    expect(find.text('Usage by archived state'), findsOneWidget);
    expect(find.text('Usage by origin'), findsOneWidget);
    expect(
      find.text('User, 2 sessions, ${formatCompactInt(1800)} tokens'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Usage by origin chart'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Usage by origin table equivalent'),
      findsOneWidget,
    );
  });
}

UsageSummary _summary() {
  return UsageSummary(
    period: UsageDateRange(
      startUtc: DateTime.utc(2026, 6, 12),
      endExclusiveUtc: DateTime.utc(2026, 6, 14),
    ),
    totalSessions: 3,
    totalMessages: 21,
    inputTokens: 1600,
    outputTokens: 800,
    cachedInputTokens: 300,
    totalTokens: 2700,
    estimatedCostText: r'$0.13',
    costUnknown: false,
    mostUsedModel: 'gpt-5.4',
    mostActiveProject: 'Codex Viewer',
    mostActivePlatform: 'Windows',
    byDay: const [
      UsageBreakdownRow(
        key: '2026-06-12',
        sessionCount: 1,
        messageCount: 7,
        inputTokens: 500,
        outputTokens: 300,
        cachedInputTokens: 100,
        totalTokens: 900,
        estimatedCostText: r'$0.04',
        costUnknown: false,
      ),
      UsageBreakdownRow(
        key: '2026-06-13',
        sessionCount: 2,
        messageCount: 14,
        inputTokens: 1100,
        outputTokens: 500,
        cachedInputTokens: 200,
        totalTokens: 1800,
        estimatedCostText: r'$0.09',
        costUnknown: false,
      ),
    ],
    byWeek: const [],
    byMonth: const [],
    byModel: const [
      UsageBreakdownRow(
        key: 'gpt-5.4',
        sessionCount: 2,
        messageCount: 14,
        inputTokens: 1100,
        outputTokens: 500,
        cachedInputTokens: 200,
        totalTokens: 1800,
        estimatedCostText: r'$0.09',
        costUnknown: false,
      ),
      UsageBreakdownRow(
        key: 'claude-sonnet-4.5',
        sessionCount: 1,
        messageCount: 7,
        inputTokens: 500,
        outputTokens: 300,
        cachedInputTokens: 100,
        totalTokens: 900,
        estimatedCostText: r'$0.04',
        costUnknown: false,
      ),
    ],
    byProject: const [],
    byPlatform: const [],
    byOrigin: const [
      UsageBreakdownRow(
        key: 'User',
        sessionCount: 2,
        messageCount: 14,
        inputTokens: 1100,
        outputTokens: 500,
        cachedInputTokens: 200,
        totalTokens: 1800,
        estimatedCostText: r'$0.09',
        costUnknown: false,
      ),
    ],
    byArchiveState: const [],
    topSessionsByTokens: const [],
    topSessionsByMessageCount: const [],
    topSessionsByEstimatedCost: const [],
  );
}
