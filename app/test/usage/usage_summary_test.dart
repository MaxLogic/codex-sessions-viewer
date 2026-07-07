import 'dart:io';

import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late UsageSummaryRepository repository;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute(File('../sql/init/001_initial_schema.sql').readAsStringSync());
    db.execute(
      File('../sql/migration/002_search_filter_schema.sql').readAsStringSync(),
    );
    db.execute(
      File('../sql/migration/003_project_override.sql').readAsStringSync(),
    );
    db.execute(
      File('../sql/migration/006_session_origin.sql').readAsStringSync(),
    );
    repository = UsageSummaryRepository(db);
  });

  tearDown(() {
    db.close();
  });

  test('aggregates period totals, breakdowns, and top sessions', () {
    _insertSession(
      db,
      id: 'alpha',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 11, 9),
      title: 'Alpha',
      messageCount: 4,
      inputTokens: 100,
      outputTokens: 50,
      cachedInputTokens: 10,
      totalTokens: 160,
      modelPrimary: 'openai/gpt-a',
      projectName: 'Viewer',
    );
    _insertSession(
      db,
      id: 'beta',
      sourceType: 'wsl',
      startedAtUtc: DateTime.utc(2026, 6, 12, 10),
      title: 'Beta',
      messageCount: 2,
      inputTokens: 20,
      outputTokens: 30,
      cachedInputTokens: 0,
      totalTokens: 50,
      modelPrimary: 'openai/gpt-b',
      projectName: 'Parser',
      isArchived: true,
    );
    _insertSession(
      db,
      id: 'old',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 5, 1),
      title: 'Old',
      messageCount: 100,
      totalTokens: 9999,
      modelPrimary: 'openai/gpt-a',
      projectName: 'Viewer',
    );

    final summary = repository.summarize(
      UsageSummaryRequest(
        period: UsagePeriod.last30Days,
        nowUtc: DateTime.utc(2026, 6, 12, 12),
      ),
      pricing: const UsagePricingCatalog({
        'openai/gpt-a': UsageModelPricing(
          promptPricePerToken: '0.001',
          completionPricePerToken: '0.002',
          cachedInputPricePerToken: '0.0005',
        ),
        'openai/gpt-b': UsageModelPricing(
          promptPricePerToken: '0.010',
          completionPricePerToken: '0.020',
          cachedInputPricePerToken: '0',
        ),
      }),
    );

    expect(summary.totalSessions, 2);
    expect(summary.totalMessages, 6);
    expect(summary.inputTokens, 120);
    expect(summary.outputTokens, 80);
    expect(summary.cachedInputTokens, 10);
    expect(summary.totalTokens, 210);
    expect(summary.estimatedCostText, '1.005');
    expect(summary.costUnknown, isFalse);
    expect(summary.mostUsedModel, 'GPT A');
    expect(summary.mostActiveProject, 'Viewer');
    expect(summary.mostActivePlatform, 'Windows');
    expect(summary.byPlatform.map((row) => row.key), ['Windows', 'WSL']);
    expect(summary.byArchiveState.map((row) => row.key), [
      'active',
      'archived',
    ]);
    expect(summary.topSessionsByTokens.first.sessionId, 'alpha');
    expect(summary.topSessionsByMessageCount.first.sessionId, 'alpha');
    expect(summary.topSessionsByEstimatedCost.first.sessionId, 'beta');
  });

  test('breaks down origin without double-counting raw totals', () {
    _insertSession(
      db,
      id: 'main',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 12, 8),
      title: 'Main',
      messageCount: 4,
      inputTokens: 50,
      outputTokens: 30,
      cachedInputTokens: 20,
      totalTokens: 100,
      modelPrimary: 'openai/model',
      projectName: 'Viewer',
      threadSource: 'user',
    );
    _insertSession(
      db,
      id: 'subagent',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 12, 9),
      title: 'Subagent',
      messageCount: 2,
      inputTokens: 30,
      outputTokens: 15,
      cachedInputTokens: 5,
      totalTokens: 50,
      modelPrimary: 'openai/model',
      projectName: 'Viewer',
      threadSource: 'subagent',
    );
    _insertSession(
      db,
      id: 'unknown-origin',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 12, 10),
      title: 'Unknown origin',
      messageCount: 1,
      inputTokens: 10,
      outputTokens: 10,
      cachedInputTokens: 5,
      totalTokens: 25,
      modelPrimary: 'openai/model',
      projectName: 'Viewer',
      threadSource: 'custom-agent',
    );

    final summary = repository.summarize(
      UsageSummaryRequest(
        period: UsagePeriod.today,
        nowUtc: DateTime.utc(2026, 6, 12, 12),
      ),
      pricing: const UsagePricingCatalog({
        'openai/model': UsageModelPricing(
          promptPricePerToken: '0.01',
          completionPricePerToken: '0.02',
          cachedInputPricePerToken: '0.005',
        ),
      }),
    );

    expect(summary.totalSessions, 3);
    expect(summary.totalTokens, 175);
    expect(summary.byProject.single.totalTokens, 175);
    expect(
      summary.byOrigin.map(
        (row) => (row.key, row.sessionCount, row.totalTokens),
      ),
      [('User', 1, 100), ('Subagent', 1, 50), ('Unknown', 1, 25)],
    );
    expect(summary.topSessionsByTokens[1].originLabel, 'Subagent');
  });

  test(
    'uses exact decimal arithmetic and reports unknown incomplete pricing',
    () {
      _insertSession(
        db,
        id: 'precise',
        sourceType: 'windows',
        startedAtUtc: DateTime.utc(2026, 6, 12, 8),
        title: 'Precise',
        inputTokens: 3,
        outputTokens: 2,
        cachedInputTokens: 1,
        totalTokens: 6,
        modelPrimary: 'openai/precise',
      );
      _insertSession(
        db,
        id: 'unknown',
        sourceType: 'windows',
        startedAtUtc: DateTime.utc(2026, 6, 12, 9),
        title: 'Unknown',
        inputTokens: 1,
        outputTokens: 1,
        cachedInputTokens: 0,
        totalTokens: 2,
        modelPrimary: 'openai/missing',
      );

      final preciseOnly = repository.summarize(
        UsageSummaryRequest(
          period: UsagePeriod.today,
          nowUtc: DateTime.utc(2026, 6, 12, 12),
        ),
        pricing: const UsagePricingCatalog({
          'openai/precise': UsageModelPricing(
            promptPricePerToken: '0.000000000000000003',
            completionPricePerToken: '0.000000000000000002',
            cachedInputPricePerToken: '0.000000000000000001',
          ),
        }),
        includeSessionIds: const {'precise'},
      );
      expect(preciseOnly.estimatedCostText, '0.000000000000000014');

      final withUnknown = repository.summarize(
        UsageSummaryRequest(
          period: UsagePeriod.today,
          nowUtc: DateTime.utc(2026, 6, 12, 12),
        ),
        pricing: const UsagePricingCatalog({
          'openai/precise': UsageModelPricing(
            promptPricePerToken: '0.000000000000000003',
            completionPricePerToken: '0.000000000000000002',
            cachedInputPricePerToken: '0.000000000000000001',
          ),
        }),
      );
      expect(withUnknown.estimatedCostText, isNull);
      expect(withUnknown.costUnknown, isTrue);
      expect(withUnknown.estimatedCostDisplay, 'Cost unknown');
    },
  );

  test('aggregates decimal costs without double rounding', () {
    expect(
      sumEstimatedCostTexts(const [
        '0.000000000000000014',
        '0.000000000000000006',
        '1.25',
      ]),
      '1.25000000000000002',
    );
    expect(sumEstimatedCostTexts(const ['0.1', null]), isNull);
    expect(sumEstimatedCostTexts(const ['0.1', 'not-a-decimal']), isNull);
  });

  test('estimates a single session cost from cached model pricing', () {
    final estimate = estimateUsageCost(
      inputTokens: 24,
      outputTokens: 16,
      cachedInputTokens: 3,
      model: 'openai/session-model',
      pricing: const UsagePricingCatalog({
        'openai/session-model': UsageModelPricing(
          promptPricePerToken: '0.001',
          completionPricePerToken: '0.002',
          cachedInputPricePerToken: '0.0005',
        ),
      }),
    );

    expect(estimate.estimatedCostText, '0.0575');
    expect(estimate.costUnknown, isFalse);
    expect(estimate.estimatedCostDisplay, '\$0.0575');
  });

  test('rebuilds usage_daily with persisted decimal cost text', () {
    _insertSession(
      db,
      id: 'daily-a',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 12, 8),
      inputTokens: 10,
      outputTokens: 5,
      cachedInputTokens: 2,
      totalTokens: 17,
      modelPrimary: 'openai/gpt-a',
      projectId: 7,
      projectName: 'Viewer',
    );
    _insertSession(
      db,
      id: 'daily-b',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 12, 9),
      inputTokens: 1,
      outputTokens: 1,
      cachedInputTokens: 0,
      totalTokens: 2,
      modelPrimary: 'openai/gpt-a',
      projectId: 7,
      projectName: 'Viewer',
    );

    repository.rebuildDailyUsage(
      pricing: const UsagePricingCatalog({
        'openai/gpt-a': UsageModelPricing(
          promptPricePerToken: '0.1',
          completionPricePerToken: '0.2',
          cachedInputPricePerToken: '0.05',
        ),
      }),
    );

    final row = db.select('select * from usage_daily').single;
    expect(row['day_utc'], '2026-06-12');
    expect(row['model'], 'openai/gpt-a');
    expect(row['project_id'], 7);
    expect(row['source_type'], 'windows');
    expect(row['session_count'], 2);
    expect(row['message_count'], 0);
    expect(row['input_tokens'], 11);
    expect(row['output_tokens'], 6);
    expect(row['cached_input_tokens'], 2);
    expect(row['total_tokens'], 19);
    expect(row['estimated_cost_text'], '2.4');
  });

  test('treats malformed prices and partial token usage as cost unknown', () {
    _insertSession(
      db,
      id: 'bad-price',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 12, 8),
      inputTokens: 10,
      outputTokens: 1,
      cachedInputTokens: 0,
      totalTokens: 11,
      modelPrimary: 'openai/bad-price',
    );
    _insertSession(
      db,
      id: 'partial',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 12, 9),
      inputTokens: 10,
      outputTokens: null,
      cachedInputTokens: 0,
      totalTokens: 20,
      modelPrimary: 'openai/partial',
    );

    final summary = repository.summarize(
      UsageSummaryRequest(
        period: UsagePeriod.today,
        nowUtc: DateTime.utc(2026, 6, 12, 12),
      ),
      pricing: const UsagePricingCatalog({
        'openai/bad-price': UsageModelPricing(
          promptPricePerToken: '.',
          completionPricePerToken: '0.1',
          cachedInputPricePerToken: '0',
        ),
        'openai/partial': UsageModelPricing(
          promptPricePerToken: '0.1',
          completionPricePerToken: '0.1',
          cachedInputPricePerToken: '0',
        ),
      }),
    );

    expect(summary.inputTokens, 20);
    expect(summary.outputTokens, 1);
    expect(summary.totalTokens, 31);
    expect(summary.costUnknown, isTrue);
    expect(summary.estimatedCostDisplay, 'Cost unknown');
  });

  test('uses ISO week year at calendar year boundaries', () {
    _insertSession(
      db,
      id: 'iso-week',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2024, 12, 30, 8),
      totalTokens: 1,
    );

    final summary = repository.summarize(
      UsageSummaryRequest(
        period: UsagePeriod.custom,
        nowUtc: DateTime.utc(2025, 1, 1),
        customStartUtc: DateTime.utc(2024, 12, 29),
        customEndExclusiveUtc: DateTime.utc(2025, 1, 2),
      ),
    );

    expect(summary.byWeek.single.key, '2025-W01');
  });
}

void _insertSession(
  Database db, {
  required String id,
  required String sourceType,
  required DateTime startedAtUtc,
  String title = '',
  int messageCount = 0,
  int? inputTokens = 0,
  int? outputTokens = 0,
  int? cachedInputTokens = 0,
  int? totalTokens = 0,
  String? modelPrimary,
  int? projectId,
  String? projectName,
  bool isArchived = false,
  String? threadSource,
}) {
  final now = DateTime.utc(2026, 6, 12, 12).toIso8601String();
  db.execute(
    '''
    insert into sessions (
      id, source_type, source_file_path, display_path, platform_path,
      parse_status, scan_status, started_at_utc, last_message_at_utc,
      title, message_count, input_tokens, output_tokens, cached_input_tokens,
      total_tokens, model_primary, models_used, project_id,
      project_name_snapshot, is_archived, thread_source, created_at_utc,
      updated_at_utc
    ) values (?, ?, ?, ?, ?, 'available', 'available', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ''',
    [
      id,
      sourceType,
      '$id.jsonl',
      '$id.jsonl',
      '$id.jsonl',
      startedAtUtc.toIso8601String(),
      startedAtUtc.toIso8601String(),
      title,
      messageCount,
      inputTokens,
      outputTokens,
      cachedInputTokens,
      totalTokens,
      modelPrimary,
      modelPrimary == null ? null : '|$modelPrimary|',
      projectId,
      projectName,
      isArchived ? 1 : 0,
      threadSource,
      now,
      now,
    ],
  );
}
