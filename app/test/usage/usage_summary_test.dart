import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_generation.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/usage/usage_cost_projection.dart';
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
    db.execute(
      File('../sql/migration/015_branch_aware_usage.sql').readAsStringSync(),
    );
    // From 018: parser versions are compared per harness.
    db.execute(
      "alter table sessions add column harness text not null default 'codex'",
    );
    repository = UsageSummaryRepository(db);
  });

  tearDown(() {
    db.close();
  });

  test('repricing visits dirty partitions in model day session order', () {
    final day = DateTime.utc(2026, 9, 7);
    for (final id in ['a', 'b']) {
      _insertSession(db, id: id, sourceType: 'windows', startedAtUtc: day);
    }
    _activatePersistedUsage(db);
    db.execute('''
      insert into usage_cost_dirty_partitions (session_id, day_utc, model_key,
        reason, target_cost_projection_version, created_at_utc, updated_at_utc)
      values ('a', '2026-09-06', 'z-model', 'fixture', 1, '2026-09-07', '2026-09-07'),
        ('a', '2026-09-07', 'a-model', 'fixture', 1, '2026-09-07', '2026-09-07'),
        ('b', '2026-09-06', 'a-model', 'fixture', 1, '2026-09-07', '2026-09-07');
    ''');
    final jobs = MaintenanceJobRepository(db);
    final job = jobs.enqueue(
      jobType: 'usage_cost_repricing',
      phase: 'reprice_costs',
    );
    final lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 5),
    )!;
    final settings = PricingSettings(
      provider: 'openrouter',
      useExternalPricing: false,
      cachePricingHours: 24,
      fallbackToOverrides: false,
      openRouter: const OpenRouterSettings(
        modelsEndpoint: 'https://openrouter.ai/api/v1/models',
        apiKey: '',
      ),
      overrides: const {},
    );
    // Empty partitions still need clearing after source deletion. Their order
    // deliberately differs from the session-first deduplication key.
    for (final (session, day, model) in [
      ('b', '2026-09-06', 'a-model'),
      ('a', '2026-09-07', 'a-model'),
      ('a', '2026-09-06', 'z-model'),
    ]) {
      expect(
        UsageCostProjectionRepository(db).repriceNextBatch(
          jobs: jobs,
          lease: lease,
          settings: settings,
          partitionLimit: 1,
        ),
        1,
      );
      expect(
        db.select(
          'select 1 from usage_cost_dirty_partitions where session_id=? and day_utc=? and model_key=?',
          [session, day, model],
        ),
        isEmpty,
      );
    }
    expect(jobs.read(job.id)!.completedUnits, 3);
  });

  test('reprices dirty usage partitions from events', () {
    final day = DateTime.utc(2026, 9, 7);
    for (final id in ['a', 'b']) {
      _insertSession(db, id: id, sourceType: 'windows', startedAtUtc: day);
    }
    for (final (id, ordinal, minute, input, output) in [
      ('a', 1, 599, 100, 10),
      ('a', 2, 600, 100, 10),
      ('b', 1, 600, 1, 1),
      for (var ordinal = 2; ordinal <= 520; ordinal++)
        ('b', ordinal, 600, 1, 1),
    ]) {
      _insertUsageEvent(
        db,
        sessionId: id,
        ordinal: ordinal,
        occurredAtUtc: day.add(Duration(minutes: minute)),
        model: 'provider/model',
        projectId: null,
        inputTokens: input,
        outputTokens: output,
        totalTokens: input + output,
      );
    }
    _activatePersistedUsage(db);
    db.execute('pragma foreign_keys = on');
    db.execute('''
      insert into price_catalog_snapshots (source, started_at_utc, finished_at_utc,
        status, completeness_status) values ('openrouter', '2026-09-01T00:00:00.000000Z',
        '2026-09-01T00:00:00.000000Z', 'succeeded', 'complete_for_updates');
      insert into model_price_periods (source, model_id, provider,
        prompt_price_per_token, completion_price_per_token, pricing_fingerprint,
        raw_pricing_json, valid_from_utc, first_snapshot_id, last_seen_snapshot_id)
      values ('openrouter', 'provider/model', 'provider', '0.001', '0.002',
        'fixture', '{}', '2026-09-01T00:00:00.000000Z', 1, 1);
      insert into provider_price_rules (price_period_id, provider_order,
        prompt_tokens_min, utc_start_minute, utc_end_minute, prompt_price_per_token,
        pricing_fingerprint, raw_rule_json)
      values (1, 0, 99, 600, 720, '0.003', 'rule-fixture', '{}');
      insert into provider_price_rules (price_period_id, provider_order,
        completion_price_per_token, pricing_fingerprint, raw_rule_json)
      values (1, 1, '0.004', 'second-rule-fixture', '{}');
      begin immediate;
    ''');
    repository.replaceDailyProjectionsInCurrentTransaction(['a', 'b']);
    db.execute('''
      update usage_session_daily set estimated_cost_text = '99', cost_status = 'complete',
        provider_price_period_id = 1, pricing_catalog_snapshot_id = 1;
      update usage_cost_dirty_partitions set reason = 'price_history';
      commit;
    ''');
    final settings = PricingSettings(
      provider: 'openrouter',
      useExternalPricing: true,
      cachePricingHours: 24,
      fallbackToOverrides: false,
      openRouter: const OpenRouterSettings(
        modelsEndpoint: 'https://openrouter.ai/api/v1/models',
        apiKey: '',
      ),
      overrides: const {},
    );
    final jobs = MaintenanceJobRepository(db);
    final job = jobs.enqueue(
      jobType: 'usage_cost_repricing',
      phase: 'reprice_costs',
    );
    var lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 5),
    )!;
    final before = db.select('select * from usage_session_daily order by id');
    // One partition per transaction, so a stop between them is observable.
    int reprice() => UsageCostProjectionRepository(db).repriceNextBatch(
      jobs: jobs,
      lease: lease,
      settings: settings,
      partitionLimit: 1,
    );
    db.execute(
      'update usage_cost_dirty_partitions set target_cost_projection_version = 2',
    );
    expect(reprice, throwsStateError);
    expect(db.select('select * from usage_session_daily order by id'), before);
    expect(jobs.read(job.id)!.completedUnits, 0);
    db.execute(
      'update usage_cost_dirty_partitions set target_cost_projection_version = 1',
    );
    db.execute('''
      create trigger reject_reprice before delete on usage_cost_dirty_partitions
      begin select raise(abort, 'injected dirty removal failure'); end;
    ''');
    expect(reprice, throwsA(isA<SqliteException>()));
    expect(db.select('select * from usage_session_daily order by id'), before);
    expect(
      db.select('select * from usage_cost_dirty_partitions'),
      hasLength(2),
    );
    expect(jobs.read(job.id)!.completedUnits, 0);
    db.execute('drop trigger reject_reprice');
    expect(reprice(), 1);
    final priced = db.select(
      "select * from usage_session_daily where session_id = 'a' order by estimated_cost_text",
    );
    expect(priced.map((row) => row['estimated_cost_text']), ['0.14', '0.34']);
    // Same last rule, different earlier matches: never merge their audit basis.
    expect(priced.map((row) => row['provider_rule_ids_json']), [
      '[2]',
      '[1,2]',
    ]);
    expect(
      priced.every(
        (row) =>
            row['provider_price_period_id'] == 1 &&
            row['pricing_catalog_snapshot_id'] == 1,
      ),
      isTrue,
    );
    expect(
      db
          .select('select sum(total_tokens) n from usage_session_daily')
          .single['n'],
      1260,
    );
    expect(
      db
          .select('select session_id from usage_cost_dirty_partitions')
          .single['session_id'],
      'b',
    );
    expect(jobs.read(job.id)!.completedUnits, 1);
    jobs.markInterrupted(
      lease,
      statusMessage: 'Stopped at committed partition.',
    );
    lease = MaintenanceJobRepository(
      db,
    ).claim(jobType: job.jobType, leaseDuration: const Duration(minutes: 5))!;
    expect(reprice(), 1);
    expect(reprice(), 0);
    expect(
      db
          .select(
            "select estimated_cost_text from usage_session_daily where session_id = 'b'",
          )
          .single['estimated_cost_text'],
      '2.6',
    );
    expect(jobs.read(job.id)!.completedUnits, 2);
    expect(db.select('pragma foreign_key_check'), isEmpty);
  });

  test('a batch reprices several partitions atomically, like one by one', () {
    final day = DateTime.utc(2026, 9, 7);
    for (final id in ['a', 'b', 'c']) {
      _insertSession(db, id: id, sourceType: 'windows', startedAtUtc: day);
    }
    var ordinal = 0;
    for (final (id, offset, model, input, output) in [
      ('a', 0, 'model', 100, 10),
      ('a', 1, 'model', 7, 3),
      ('a', 25, 'model', 50, 5),
      ('b', 0, 'model', 1, 1),
      ('b', 0, 'other', 2, 2),
      ('c', 2, 'model', 9, 9),
    ]) {
      _insertUsageEvent(
        db,
        sessionId: id,
        ordinal: ++ordinal,
        occurredAtUtc: day.add(Duration(hours: offset)),
        model: model,
        projectId: null,
        inputTokens: input,
        outputTokens: output,
        totalTokens: input + output,
      );
    }
    _activatePersistedUsage(db);
    db.execute('''
      insert into local_price_override_periods (model_id, prompt_price_per_token,
        completion_price_per_token, settings_fingerprint, valid_from_utc,
        valid_to_utc, first_settings_revision, last_seen_settings_revision)
      values ('model', '0.01', '0.02', 'first', '2026-01-01T00:00:00.000000Z',
        '2026-09-08T00:00:00.000000Z', 1, 1),
        ('model', '0.03', '0.04', 'second', '2026-09-08T00:00:00.000000Z',
        null, 2, 2);
      begin immediate;
    ''');
    repository.replaceDailyProjectionsInCurrentTransaction(['a', 'b', 'c']);
    db.execute('commit');
    final settings = PricingSettings(
      provider: 'openrouter',
      useExternalPricing: false,
      cachePricingHours: 24,
      fallbackToOverrides: true,
      openRouter: const OpenRouterSettings(
        modelsEndpoint: 'https://openrouter.ai/api/v1/models',
        apiKey: '',
      ),
      overrides: const {},
    );
    final jobs = MaintenanceJobRepository(db);
    List<Map<String, Object?>> daily() => [
      for (final row in db.select('''
        select * from usage_session_daily
        order by session_id, day_utc, model_key, path_context_id
      '''))
        {...row}
          ..remove('id')
          ..remove('updated_at_utc'),
    ];
    const partitions = 5;
    int run({required int limit}) {
      final job = jobs.enqueue(
        jobType: 'usage_cost_repricing',
        phase: 'reprice_costs',
      );
      final lease = jobs.claim(
        jobType: job.jobType,
        leaseDuration: const Duration(minutes: 5),
      )!;
      var calls = 0;
      while (UsageCostProjectionRepository(db).repriceNextBatch(
            jobs: jobs,
            lease: lease,
            settings: settings,
            partitionLimit: limit,
          ) !=
          0) {
        calls++;
      }
      expect(jobs.read(job.id)!.completedUnits, partitions);
      jobs.markSucceeded(lease, phase: 'complete', statusMessage: 'done');
      return calls;
    }

    void markAllDirty() => db.execute('''
      insert or ignore into usage_cost_dirty_partitions (session_id, day_utc,
        model_key, reason, target_cost_projection_version, created_at_utc,
        updated_at_utc)
      select distinct session_id, day_utc, model_key, 'fixture', 1, 'x', 'x'
      from usage_session_daily
    ''');

    markAllDirty();
    expect(run(limit: 1), partitions);
    final oneByOne = daily();
    // The second day of session a is priced by the later override period.
    expect(oneByOne.map((row) => row['estimated_cost_text']), [
      '1.33',
      '1.7',
      '0.03',
      null,
      '0.27',
    ]);
    expect(oneByOne.map((row) => row['local_override_period_id']), [
      1,
      2,
      1,
      null,
      1,
    ]);

    markAllDirty();
    db.execute('''
      update usage_session_daily set estimated_cost_text = '999'
      where estimated_cost_text is not null
    ''');
    db.execute('''
      create trigger reject_last before delete on usage_cost_dirty_partitions
      when old.session_id = 'c'
      begin select raise(abort, 'injected failure'); end;
    ''');
    final job = jobs.enqueue(
      jobType: 'usage_cost_repricing',
      phase: 'reprice_costs',
    );
    final lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 5),
    )!;
    expect(
      () => UsageCostProjectionRepository(
        db,
      ).repriceNextBatch(jobs: jobs, lease: lease, settings: settings),
      throwsA(isA<SqliteException>()),
    );
    expect(
      db.select('select * from usage_cost_dirty_partitions'),
      hasLength(partitions),
      reason: 'a failed batch rolls back every partition in it',
    );
    expect(
      db
          .select(
            "select count(*) n from usage_session_daily where estimated_cost_text = '999'",
          )
          .single['n'],
      oneByOne.where((row) => row['estimated_cost_text'] != null).length,
    );
    expect(jobs.read(job.id)!.completedUnits, 0);
    jobs.markInterrupted(lease, statusMessage: 'Injected failure.');
    db.execute('drop trigger reject_last');

    expect(run(limit: repricePartitionsPerBatch), 1);
    expect(daily(), oneByOne);
  });

  test(
    'rejects overlapping token buckets even when their sum would overflow',
    () {
      final estimate = estimateUsageCost(
        inputTokens: 9223372036854775807,
        cachedInputTokens: 9223372036854775807,
        cacheWriteInputTokens: 1,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        model: 'overflow-fixture',
        pricing: const UsagePricingCatalog({
          'overflow-fixture': UsageModelPricing(
            promptPricePerToken: '1',
            completionPricePerToken: '0',
            cachedInputPricePerToken: '0',
            cacheWriteInputPricePerToken: '0',
          ),
        }),
      );
      expect(estimate.costUnknown, isTrue);
      expect(estimate.estimatedCostText, isNull);
    },
  );

  test('repricing preserves unknown costs and rolls back token overflow', () {
    final day = DateTime.utc(2026, 9, 7);
    _insertSession(db, id: 's', sourceType: 'windows', startedAtUtc: day);
    for (var ordinal = 1; ordinal <= 2; ordinal++) {
      _insertUsageEvent(
        db,
        sessionId: 's',
        ordinal: ordinal,
        occurredAtUtc: day,
        model: 'model',
        projectId: null,
        inputTokens: 10,
        outputTokens: 0,
        cachedInputTokens: ordinal == 2 ? 11 : 0,
        totalTokens: 10,
      );
    }
    _activatePersistedUsage(db);
    db.execute('''
      insert into local_price_override_periods (model_id, prompt_price_per_token,
        settings_fingerprint, valid_from_utc, first_settings_revision, last_seen_settings_revision)
      values ('model', '0.01', 'fixture', '2026-01-01T00:00:00.000000Z', 1, 1);
      begin immediate;
    ''');
    repository.replaceDailyProjectionsInCurrentTransaction(['s']);
    db.execute('commit');
    final jobs = MaintenanceJobRepository(db);
    final job = jobs.enqueue(
      jobType: 'usage_cost_repricing',
      phase: 'reprice_costs',
    );
    var lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 5),
    )!;
    final settings = PricingSettings(
      provider: 'openrouter',
      useExternalPricing: false,
      cachePricingHours: 24,
      fallbackToOverrides: true,
      openRouter: const OpenRouterSettings(
        modelsEndpoint: 'https://openrouter.ai/api/v1/models',
        apiKey: '',
      ),
      overrides: const {},
    );
    int reprice() => UsageCostProjectionRepository(
      db,
    ).repriceNextBatch(jobs: jobs, lease: lease, settings: settings);
    expect(reprice(), 1);
    final unknown = db.select('select * from usage_session_daily').single;
    expect(unknown['total_tokens'], 20);
    expect(unknown['cost_status'], 'unknown');
    expect(unknown['estimated_cost_text'], isNull);
    expect(unknown['local_override_period_id'], 1);
    db.execute('''
      update usage_events set cached_input_tokens = 0,
        input_tokens = case when source_record_ordinal = 1 then 9223372036854775807 else 1 end,
        total_tokens = case when source_record_ordinal = 1 then 9223372036854775807 else 1 end;
      insert into usage_cost_dirty_partitions (session_id, day_utc, model_key, reason,
        target_cost_projection_version, created_at_utc, updated_at_utc)
      values ('s', '2026-09-07', 'model', 'fixture', 1, '2026-09-07', '2026-09-07');
    ''');
    jobs.markInterrupted(lease, statusMessage: 'Next fixture update.');
    lease = jobs.claim(
      jobType: job.jobType,
      leaseDuration: const Duration(minutes: 5),
    )!;
    expect(
      reprice,
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('exceeds SQLite integer range'),
        ),
      ),
    );
    expect(db.select('select * from usage_session_daily').single, unknown);
    expect(
      db.select('select * from usage_cost_dirty_partitions'),
      hasLength(1),
    );
    expect(jobs.read(job.id)!.completedUnits, 1);
    expect(db.select('pragma foreign_key_check'), isEmpty);
  });

  test('usage ranges reject subday boundaries instead of truncating them', () {
    _activatePersistedUsage(db);
    final start = DateTime.utc(2026, 9, 1);
    final end = DateTime.utc(2026, 9, 5);
    for (final (from, to) in [
      (DateTime.utc(2026, 9, 1, 12), end),
      (start, DateTime.utc(2026, 9, 5, 12)),
      (start.add(const Duration(microseconds: 1)), end),
      (start, end.add(const Duration(microseconds: 1))),
    ]) {
      final request = UsageSummaryRequest(
        period: UsagePeriod.custom,
        nowUtc: end,
        customStartUtc: from,
        customEndExclusiveUtc: to,
      );
      expect(() => repository.summarize(request), throwsArgumentError);
      expect(
        () => repository.explainUsageEventAggregation(request),
        throwsArgumentError,
      );
    }
    final normalized = UsageSummaryRequest(
      period: UsagePeriod.custom,
      nowUtc: end,
      customStartUtc: DateTime.parse('2026-09-01T02:00:00+02:00'),
      customEndExclusiveUtc: DateTime.parse('2026-09-05T02:00:00+02:00'),
    );
    expect(normalized.resolve().startUtc, start);
    expect(normalized.resolve().endExclusiveUtc, end);
    expect(repository.summarize(normalized).totalTokens, 0);
  });

  test(
    'active context generation reads persisted daily tokens and unknown costs',
    () {
      _insertSession(
        db,
        id: 'persisted',
        sourceType: 'windows',
        startedAtUtc: DateTime.utc(2026, 6, 12),
        inputTokens: 10,
        totalTokens: 10,
        modelPrimary: 'model',
      );
      _activatePersistedUsage(db);
      db.execute('''
      insert into usage_session_daily (
        session_id, day_utc, model_key, path_context_id, branch_scope,
        input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens,
        reasoning_output_tokens, total_tokens, cost_status, pricing_resolution_method,
        cost_projection_version, updated_at_utc)
      values ('persisted', '2026-06-12', 'model', 1, 'local',
        37, 0, 0, 0, 0, 37, 'unknown', 'unknown', 1, '2026-06-12T00:00:00Z');
    ''');
      final summary = repository.summarize(
        UsageSummaryRequest(
          period: UsagePeriod.today,
          nowUtc: DateTime.utc(2026, 6, 12),
        ),
        pricing: const UsagePricingCatalog({
          'model': UsageModelPricing(
            promptPricePerToken: '1',
            completionPricePerToken: '1',
          ),
        }),
      );
      expect(summary.totalTokens, 37);
      expect(summary.inputTokens, 37);
      expect(
        summary.costUnknown,
        isTrue,
        reason:
            'Current catalog must not silently replace persisted historical costs.',
      );
      expect(summary.estimatedCostText, isNull);
    },
  );

  test(
    'persisted coverage retains undated and zero-token local event evidence',
    () {
      const ids = ['zero', 'inherited', 'dated', 'undated', 'zero-token'];
      for (final id in ids) {
        _insertSession(
          db,
          id: id,
          sourceType: 'windows',
          startedAtUtc: DateTime.utc(2026, 6, 12),
        );
        if (id != 'zero') {
          final tokens = id == 'zero-token' ? 0 : 1;
          _insertUsageEvent(
            db,
            sessionId: id,
            ordinal: 1,
            occurredAtUtc: DateTime.utc(2026, 6, 12),
            model: null,
            projectId: null,
            inputTokens: tokens,
            outputTokens: 0,
            totalTokens: tokens,
            branchScope: id == 'inherited' ? 'inherited' : 'local',
          );
        }
      }
      db.execute('update sessions set parser_version = 3');
      db.execute(
        "update usage_events set occurred_at_utc = null where session_row_id = 'undated'",
      );
      _activatePersistedUsage(db);
      db.execute('begin immediate');
      repository.replaceDailyProjectionsInCurrentTransaction(ids);
      db.execute('commit');
      // Production reads must use persisted coverage, not inspect raw events.
      // Removing this fixture's facts makes accidental raw reads observable.
      db.execute('delete from usage_events');
      final summary = repository.summarize(
        UsageSummaryRequest(
          period: UsagePeriod.today,
          nowUtc: DateTime.utc(2026, 6, 12),
          projectionVersion: 3,
        ),
      );
      expect(summary.projectionCoverage.currentCompleteSessions, 5);
      expect(summary.projectionCoverage.completeZeroUsageSessions, 2);
      expect(summary.totalTokens, 1);
    },
  );

  test('dirty persisted costs are excluded without recalculating tokens', () {
    _insertSession(
      db,
      id: 'paid',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 12),
      inputTokens: 10,
      totalTokens: 10,
      modelPrimary: 'gpt-fixture',
    );
    _activatePersistedUsage(db);
    db.execute('begin immediate');
    repository.replaceDailyProjectionsInCurrentTransaction(['paid']);
    db.execute('commit');
    db.execute('''
      insert into local_price_override_periods (model_id, prompt_price_per_token,
        settings_fingerprint, valid_from_utc, first_settings_revision, last_seen_settings_revision)
      values ('openai/gpt-fixture', '0.037', 'fixture', '2026-06-01T00:00:00Z', 1, 1);
      update usage_session_daily set estimated_cost_text = '0.37', cost_status = 'complete',
        local_override_period_id = last_insert_rowid(), pricing_resolution_method = 'local_openai_exact';
      delete from usage_cost_dirty_partitions where session_id = 'paid';
    ''');
    final request = UsageSummaryRequest(
      period: UsagePeriod.today,
      nowUtc: DateTime.utc(2026, 6, 12),
    );
    const catalog = UsagePricingCatalog({
      'gpt-fixture': UsageModelPricing(
        promptPricePerToken: '1',
        completionPricePerToken: '1',
      ),
    });
    final historical = repository.summarize(request, pricing: catalog);
    expect(historical.estimatedCostText, '0.37');
    expect(historical.pricingStatus.models.single.source, 'override');
    expect(historical.pricingStatus.usesHistoricalCosts, isTrue);
    expect(historical.pricingStatus.updating, isFalse);
    expect(
      historical.pricingStatus.models.single.resolvedModelId,
      'openai/gpt-fixture',
    );
    expect(historical.pricingStatus.models.single.rawModelId, 'gpt-fixture');
    expect(
      historical.pricingStatus.models.single.resolutionMethod,
      UsageModelResolutionMethod.openAiExact,
    );
    expect(
      historical.pricingStatus.models.single.fetchedAtUtc,
      DateTime.utc(2026, 6, 1),
    );
    db.execute(
      "update usage_session_daily set cost_status = 'partial_unsupported_units'",
    );
    final partial = repository.summarize(request, pricing: catalog);
    expect(partial.estimatedCostText, '0.37');
    expect(partial.pricingStatus.partialUnsupportedUnits, isTrue);
    db.execute('''
      insert into usage_cost_dirty_partitions (session_id, day_utc, model_key,
        reason, target_cost_projection_version, created_at_utc, updated_at_utc)
      values ('paid', '2026-06-12', 'gpt-fixture', 'price_changed', 2, '2026-06-12', '2026-06-12');
    ''');
    final dirty = repository.summarize(request, pricing: catalog);
    expect(dirty.costUnknown, isTrue);
    expect(dirty.pricingStatus.updating, isTrue);
    expect(dirty.estimatedCostText, isNull);
    expect(dirty.totalTokens, 10);
    expect(dirty.byModel.single.costUnknown, isTrue);
    expect(dirty.topSessionsByTokens.single.costUnknown, isTrue);
    db.execute('delete from usage_cost_dirty_partitions');
    db.execute('update usage_session_daily set cost_projection_version = 2');
    final unsupported = repository.summarize(request, pricing: catalog);
    expect(unsupported.estimatedCostText, isNull);
    expect(unsupported.pricingStatus.updating, isTrue);
  });

  test('active16 preserves nonmonetary summaries across periods and filters', () {
    final automatic = _insertProject(db, 'Automatic');
    final other = _insertProject(db, 'Other');
    final manual = _insertProject(db, 'Manual');
    final sessionIds = [
      'month-edge',
      'week-edge',
      'yesterday',
      'manual',
      'zero',
    ];
    final starts = [
      DateTime.utc(2026, 5, 31, 23),
      DateTime.utc(2026, 6, 7, 23),
      DateTime.utc(2026, 6, 11, 9),
      DateTime.utc(2026, 6, 12, 10),
      DateTime.utc(2026, 6, 12, 11),
    ];
    for (var index = 0; index < sessionIds.length; index++) {
      final tokens = index == 4 ? 0 : index + 1;
      _insertSession(
        db,
        id: sessionIds[index],
        sourceType: index.isEven ? 'windows' : 'wsl',
        startedAtUtc: starts[index],
        title: 'Session $index',
        messageCount: index + 2,
        inputTokens: tokens * 10,
        outputTokens: tokens,
        cachedInputTokens: tokens,
        // Cached input is a subset, not an additional total-token bucket.
        totalTokens: tokens * 12,
        modelPrimary: index.isEven ? 'gpt-5.5' : 'gpt-5.6-sol',
        projectId: index == 3 ? manual : automatic,
        projectName: index == 3 ? 'Manual' : 'Automatic',
        projectOverride: index == 3,
        isArchived: index == 1,
        threadSource: index == 1 ? 'subagent' : 'cli',
      );
    }
    // Activity is selected by event time, not the session's start date or
    // current automatic project. A manual session override still wins.
    for (final (id, ordinal, day, project, input, output, scope) in [
      ('week-edge', 1, 12, other, 5, 2, 'local'),
      ('manual', 1, 12, other, 100, 50, 'inherited'),
      ('manual', 2, 13, other, 1000, 500, 'local'),
    ]) {
      _insertUsageEvent(
        db,
        sessionId: id,
        ordinal: ordinal,
        occurredAtUtc: DateTime.utc(2026, 6, day),
        model: 'gpt-5.6-terra',
        projectId: project,
        inputTokens: input,
        outputTokens: output,
        totalTokens: input + output,
        branchScope: scope,
      );
    }
    db.execute(
      "update usage_events set project_id = ? where session_row_id = 'manual'",
      [other],
    );
    db.execute('update sessions set parser_version = 3');
    final requests = [
      for (final period in UsagePeriod.values)
        UsageSummaryRequest(
          period: period,
          nowUtc: DateTime.utc(2026, 6, 12, 15),
          customStartUtc: DateTime.utc(2026, 5, 31),
          customEndExclusiveUtc: DateTime.utc(2026, 6, 13),
          projectionVersion: 3,
        ),
    ];
    final filters = <Set<String>>[
      {},
      {'week-edge', 'manual', 'zero'},
      {'not-present'},
    ];
    final legacy = [
      for (final request in requests)
        for (final filter in filters)
          repository.summarize(request, includeSessionIds: filter),
    ];
    expect(legacy.first.totalTokens, 51);
    expect(legacy.first.totalSessions, 2);
    expect(legacy.first.byProject.map((row) => (row.key, row.totalTokens)), [
      ('Manual', 44),
      ('Other', 7),
      ('Automatic', 0),
    ]);

    _activatePersistedUsage(db);
    db.execute('begin immediate');
    repository.replaceDailyProjectionsInCurrentTransaction(sessionIds);
    db.execute('commit');
    // Remove raw facts after initialization to make a raw-reader fallback fail.
    db.execute('delete from usage_events');
    var index = 0;
    for (final request in requests) {
      for (final filter in filters) {
        expect(
          _nonmonetarySummary(
            repository.summarize(request, includeSessionIds: filter),
          ),
          _nonmonetarySummary(legacy[index++]),
          reason: '${request.period.name}, includeSessionIds: $filter',
        );
      }
    }
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
    expect(summary.totalTokens, 200);
    expect(summary.estimatedCostText, '0.995');
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

  test('aggregates branch-local usage by event time model and project', () {
    final autoA = _insertProject(db, 'Auto A');
    final autoB = _insertProject(db, 'Auto B');
    final manual = _insertProject(db, 'Manual');
    _insertSession(
      db,
      id: 'parent',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 11, 23),
      messageCount: 9,
      modelPrimary: 'gpt-5.5',
      projectId: autoA,
      projectName: 'Auto A',
    );
    _insertSession(
      db,
      id: 'child',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 12, 9),
      messageCount: 4,
      modelPrimary: 'gpt-5.6-sol',
      projectId: autoA,
      projectName: 'Auto A',
    );
    _insertSession(
      db,
      id: 'manual-child',
      sourceType: 'wsl',
      startedAtUtc: DateTime.utc(2026, 6, 12, 10),
      messageCount: 2,
      modelPrimary: 'gpt-5.5',
      projectId: manual,
      projectName: 'Manual',
      projectOverride: true,
    );
    _insertSession(
      db,
      id: 'grandchild',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 12, 11),
      messageCount: 1,
      modelPrimary: 'gpt-5.6-terra',
      projectId: autoA,
      projectName: 'Auto A',
    );
    db.execute("update sessions set usage_projection_status = 'complete'");

    _insertUsageEvent(
      db,
      sessionId: 'parent',
      ordinal: 1,
      occurredAtUtc: DateTime.utc(2026, 6, 12),
      model: 'gpt-5.5',
      projectId: autoA,
      inputTokens: 10,
      cachedInputTokens: 2,
      cacheWriteInputTokens: 1,
      outputTokens: 5,
      totalTokens: 15,
    );
    _insertUsageEvent(
      db,
      sessionId: 'parent',
      ordinal: 2,
      occurredAtUtc: DateTime.utc(2026, 6, 13),
      model: 'gpt-5.5',
      projectId: autoA,
      inputTokens: 1000,
      outputTokens: 1000,
      totalTokens: 2000,
    );
    _insertUsageEvent(
      db,
      sessionId: 'child',
      ordinal: 1,
      occurredAtUtc: DateTime.utc(2026, 6, 12, 8),
      model: 'gpt-5.5',
      projectId: autoA,
      inputTokens: 100,
      outputTokens: 50,
      totalTokens: 150,
      branchScope: 'inherited',
    );
    _insertUsageEvent(
      db,
      sessionId: 'child',
      ordinal: 2,
      occurredAtUtc: DateTime.utc(2026, 6, 12, 10),
      model: 'gpt-5.6-sol',
      projectId: autoB,
      inputTokens: 20,
      cachedInputTokens: 4,
      cacheWriteInputTokens: 2,
      outputTokens: 10,
      totalTokens: 30,
    );
    _insertUsageEvent(
      db,
      sessionId: 'child',
      ordinal: 3,
      occurredAtUtc: DateTime.utc(2026, 6, 12, 11),
      model: 'gpt-5.6-terra',
      projectId: autoB,
      inputTokens: 8,
      cachedInputTokens: 1,
      outputTokens: 4,
      totalTokens: 12,
    );
    _insertUsageEvent(
      db,
      sessionId: 'manual-child',
      ordinal: 1,
      occurredAtUtc: DateTime.utc(2026, 6, 12, 12),
      model: 'gpt-5.5',
      projectId: autoB,
      inputTokens: 5,
      outputTokens: 2,
      totalTokens: 7,
    );
    _insertUsageEvent(
      db,
      sessionId: 'grandchild',
      ordinal: 1,
      occurredAtUtc: DateTime.utc(2026, 6, 12, 11, 30),
      model: 'gpt-5.6-terra',
      projectId: autoA,
      inputTokens: 8,
      outputTokens: 4,
      totalTokens: 12,
      branchScope: 'inherited',
    );
    _insertUsageEvent(
      db,
      sessionId: 'grandchild',
      ordinal: 2,
      occurredAtUtc: DateTime.utc(2026, 6, 12, 12, 30),
      model: 'gpt-5.6-terra',
      projectId: autoA,
      inputTokens: 3,
      outputTokens: 1,
      totalTokens: 4,
    );

    final summary = repository.summarize(
      UsageSummaryRequest(
        period: UsagePeriod.today,
        nowUtc: DateTime.utc(2026, 6, 12, 15),
      ),
      pricing: const UsagePricingCatalog({
        'openai/gpt-5.5': UsageModelPricing(
          promptPricePerToken: '0.01',
          completionPricePerToken: '0.02',
          cachedInputPricePerToken: '0.001',
          cacheWriteInputPricePerToken: '0.02',
        ),
        'openai/gpt-5.6-sol': UsageModelPricing(
          promptPricePerToken: '0.02',
          completionPricePerToken: '0.03',
          cachedInputPricePerToken: '0.002',
          cacheWriteInputPricePerToken: '0.04',
        ),
        'openai/gpt-5.6-terra': UsageModelPricing(
          promptPricePerToken: '0.005',
          completionPricePerToken: '0.01',
          cachedInputPricePerToken: '0.001',
          cacheWriteInputPricePerToken: '0.02',
        ),
      }),
    );

    expect(summary.totalSessions, 3);
    expect(summary.totalMessages, 7);
    expect(summary.inputTokens, 46);
    expect(summary.outputTokens, 22);
    expect(summary.cachedInputTokens, 7);
    expect(summary.totalTokens, 68);
    expect(summary.estimatedCostText, '1.051');
    expect(summary.byModel.map((row) => (row.key, row.totalTokens)), [
      ('GPT 5.6 Sol', 30),
      ('GPT 5.5', 22),
      ('GPT 5.6 Terra', 16),
    ]);
    expect(summary.byProject.map((row) => (row.key, row.totalTokens)), [
      ('Auto B', 42),
      ('Auto A', 19),
      ('Manual', 7),
    ]);
    expect(summary.byPlatform.map((row) => (row.key, row.totalTokens)), [
      ('Windows', 61),
      ('WSL', 7),
    ]);
    expect(summary.topSessionsByTokens.first.sessionId, 'child');
    expect(summary.topSessionsByTokens.first.totalTokens, 42);
    expect(summary.topSessionsByEstimatedCost.first.sessionId, 'child');
  });

  test('reports projection coverage and pricing diagnostics', () {
    for (final id in const [
      'current',
      'zero',
      'inherited-only',
      'stale',
      'pending',
      'ambiguous',
      'missing',
    ]) {
      final hasUsage = id == 'current' || id == 'stale';
      _insertSession(
        db,
        id: id,
        sourceType: 'windows',
        startedAtUtc: DateTime.utc(2026, 6, 12, 8),
        modelPrimary: id == 'current'
            ? 'gpt-5.6-sol'
            : id == 'stale'
            ? 'gpt-stale'
            : null,
        inputTokens: hasUsage ? 10 : 0,
        outputTokens: hasUsage ? 5 : 0,
        totalTokens: hasUsage ? 15 : 0,
      );
    }
    db.execute(
      "update sessions set parser_version = 3 where id in ('current', 'zero', 'inherited-only')",
    );
    db.execute("update sessions set parser_version = 2 where id = 'stale'");
    db.execute(
      "update sessions set parser_version = 3, usage_projection_status = 'legacy_pending' where id = 'pending'",
    );
    db.execute(
      "update sessions set parser_version = 3, usage_projection_status = 'ambiguous' where id = 'ambiguous'",
    );
    db.execute(
      "update sessions set parser_version = 3, usage_projection_status = 'missing_parent' where id = 'missing'",
    );
    _insertUsageEvent(
      db,
      sessionId: 'inherited-only',
      ordinal: 1,
      occurredAtUtc: DateTime.utc(2026, 6, 12, 9),
      model: 'gpt-5.5',
      projectId: null,
      inputTokens: 100,
      outputTokens: 50,
      totalTokens: 150,
      branchScope: 'inherited',
    );
    final fetchedAt = DateTime.utc(2026, 7, 29, 8);

    final summary = repository.summarize(
      UsageSummaryRequest(
        period: UsagePeriod.today,
        nowUtc: DateTime.utc(2026, 6, 12, 12),
        projectionVersion: 3,
      ),
      pricing: UsagePricingCatalog({
        'openai/gpt-5.6-sol': UsageModelPricing(
          promptPricePerToken: '0.000005',
          completionPricePerToken: '0.00003',
          source: 'openrouter',
          fetchedAtUtc: fetchedAt,
        ),
      }),
    );

    expect(
      summary.projectionCoverage,
      isA<UsageProjectionCoverage>()
          .having((value) => value.projectionVersion, 'version', 3)
          .having((value) => value.availableSessions, 'available', 7)
          .having((value) => value.currentCompleteSessions, 'complete', 3)
          .having((value) => value.outdatedProjectionSessions, 'outdated', 1)
          .having((value) => value.legacyPendingSessions, 'pending', 1)
          .having((value) => value.ambiguousSessions, 'ambiguous', 1)
          .having((value) => value.missingParentSessions, 'missing parent', 1)
          .having((value) => value.completeZeroUsageSessions, 'zero usage', 2),
    );
    expect(summary.pricingStatus.openRouterFetchedAtUtc, fetchedAt);
    expect(summary.totalTokens, 15);
    expect(summary.byModel.where((row) => row.totalTokens > 0), hasLength(1));
    expect(summary.pricingStatus.models, hasLength(1));
    expect(
      summary.pricingStatus.models.single,
      isA<UsageModelPricingStatus>()
          .having((value) => value.rawModelId, 'raw model', 'gpt-5.6-sol')
          .having(
            (value) => value.effectiveModelId,
            'effective model',
            'gpt-5.6-sol',
          )
          .having(
            (value) => value.resolvedModelId,
            'resolved model',
            'openai/gpt-5.6-sol',
          )
          .having(
            (value) => value.resolutionMethod,
            'method',
            UsageModelResolutionMethod.openAiExact,
          )
          .having((value) => value.cacheState, 'cache state', 'cached')
          .having((value) => value.fetchedAtUtc, 'fetched at', fetchedAt),
    );
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
    expect(summary.totalTokens, 145);
    expect(summary.byProject.single.totalTokens, 145);
    expect(
      summary.byOrigin.map(
        (row) => (row.key, row.sessionCount, row.totalTokens),
      ),
      [('User', 1, 80), ('Subagent', 1, 45), ('Unknown', 1, 20)],
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
      expect(preciseOnly.estimatedCostText, '0.000000000000000011');

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

  test('preserves provider precision across mixed-scale costs', () {
    const rate = '0.0000000833333333333333';
    final estimate = estimateUsageCost(
      inputTokens: 7,
      outputTokens: 0,
      cachedInputTokens: 0,
      cacheWriteInputTokens: 7,
      model: 'provider/precise',
      pricing: const UsagePricingCatalog({
        'provider/precise': UsageModelPricing(
          promptPricePerToken: '0.1',
          completionPricePerToken: '0.2',
          cacheWriteInputPricePerToken: rate,
        ),
      }),
    );
    expect(estimate.estimatedCostText, '0.0000005833333333333331');
    expect(estimate.costUnknown, isFalse);
    for (final amounts in [
      ['1.25', rate, '-0.0000000416666666666667'],
      [rate, '-0.0000000416666666666667', '1.25'],
    ]) {
      expect(sumEstimatedCostTexts(amounts), '1.2500000416666666666666');
    }
    expect(sumEstimatedCostTexts([rate, '-$rate']), '0');
    expect(
      sumEstimatedCostTexts(['-0.00000000000000000000001']),
      '-0.00000000000000000000001',
    );
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

    expect(estimate.estimatedCostText, '0.0545');
    expect(estimate.costUnknown, isFalse);
    expect(estimate.estimatedCostDisplay, '\$0.0545');
  });

  test('prices mutually exclusive input and output buckets exactly once', () {
    const pricing = UsagePricingCatalog({
      'openai/gpt-current': UsageModelPricing(
        promptPricePerToken: '0.01',
        completionPricePerToken: '0.02',
        cachedInputPricePerToken: '0.001',
        cacheWriteInputPricePerToken: '0.02',
        internalReasoningPricePerToken: '0.03',
      ),
    });

    final estimate = estimateUsageCost(
      inputTokens: 100,
      cachedInputTokens: 20,
      cacheWriteInputTokens: 10,
      outputTokens: 30,
      reasoningOutputTokens: 5,
      model: 'openai/gpt-current',
      pricing: pricing,
    );

    // 70*.01 + 20*.001 + 10*.02 + 25*.02 + 5*.03.
    expect(estimate.estimatedCostText, '1.57');
    expect(estimate.costUnknown, isFalse);
    for (final (reasoningRate, expected) in [
      (null, '0.6'),
      ('0', '0.5'),
      ('0.03', '0.65'),
      ('invalid', null),
    ]) {
      final cost = estimateUsageCost(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 30,
        reasoningOutputTokens: 5,
        model: 'model',
        pricing: UsagePricingCatalog({
          'model': UsageModelPricing(
            completionPricePerToken: '0.02',
            internalReasoningPricePerToken: reasoningRate,
          ),
        }),
      );
      expect(
        cost.estimatedCostText,
        expected,
        reason: 'Reasoning rate $reasoningRate',
      );
      expect(cost.costUnknown, expected == null);
    }

    final invalidOverlap = estimateUsageCost(
      inputTokens: 10,
      cachedInputTokens: 7,
      cacheWriteInputTokens: 4,
      outputTokens: 0,
      reasoningOutputTokens: 0,
      model: 'openai/gpt-current',
      pricing: pricing,
    );
    expect(invalidOverlap.costUnknown, isTrue);

    final invalidReasoning = estimateUsageCost(
      inputTokens: 0,
      cachedInputTokens: 0,
      cacheWriteInputTokens: 0,
      outputTokens: 3,
      reasoningOutputTokens: 4,
      model: 'openai/gpt-current',
      pricing: pricing,
    );
    expect(invalidReasoning.costUnknown, isTrue);

    final unpricedWrite = estimateUsageCost(
      inputTokens: 1,
      cachedInputTokens: 0,
      cacheWriteInputTokens: 1,
      outputTokens: 0,
      reasoningOutputTokens: 0,
      model: 'openai/no-write-price',
      pricing: const UsagePricingCatalog({
        'openai/no-write-price': UsageModelPricing(
          promptPricePerToken: '0.01',
          completionPricePerToken: '0.02',
          cachedInputPricePerToken: '0.001',
        ),
      }),
    );
    expect(unpricedWrite.costUnknown, isTrue);

    final zeroWriteNeedsNoWritePrice = estimateUsageCost(
      inputTokens: 1,
      cachedInputTokens: 0,
      cacheWriteInputTokens: 0,
      outputTokens: 0,
      reasoningOutputTokens: 0,
      model: 'openai/no-write-price',
      pricing: const UsagePricingCatalog({
        'openai/no-write-price': UsageModelPricing(promptPricePerToken: '0.01'),
      }),
    );
    expect(zeroWriteNeedsNoWritePrice.estimatedCostText, '0.01');
    expect(zeroWriteNeedsNoWritePrice.costUnknown, isFalse);

    final negativePrice = estimateUsageCost(
      inputTokens: 1,
      cachedInputTokens: 0,
      cacheWriteInputTokens: 0,
      outputTokens: 0,
      reasoningOutputTokens: 0,
      model: 'openai/negative',
      pricing: const UsagePricingCatalog({
        'openai/negative': UsageModelPricing(promptPricePerToken: '-0.01'),
      }),
    );
    expect(negativePrice.costUnknown, isTrue);
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
    _insertSession(
      db,
      id: 'daily-stale',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 12, 10),
      inputTokens: 100,
      outputTokens: 50,
      cachedInputTokens: 0,
      totalTokens: 150,
      modelPrimary: 'openai/gpt-a',
      projectId: 7,
      projectName: 'Viewer',
    );
    db.execute(
      "update sessions set parser_version = 3 where id in ('daily-a', 'daily-b')",
    );
    db.execute(
      "update sessions set parser_version = 2 where id = 'daily-stale'",
    );

    repository.rebuildDailyUsage(
      projectionVersion: 3,
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
    expect(row['session_count'], 3);
    expect(row['message_count'], 0);
    expect(row['input_tokens'], 11);
    expect(row['output_tokens'], 6);
    expect(row['cached_input_tokens'], 2);
    expect(row['total_tokens'], 17);
    expect(row['estimated_cost_text'], '2.2');
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

    expect(summary.inputTokens, 10);
    expect(summary.outputTokens, 1);
    expect(summary.totalTokens, 11);
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

  test('uses indexed SQLite aggregation for usage events', () {
    final projectId = _insertProject(db, 'Large');
    _insertSession(
      db,
      id: 'large',
      sourceType: 'windows',
      startedAtUtc: DateTime.utc(2026, 6, 12),
      modelPrimary: 'gpt-5.6-sol',
      projectId: projectId,
      projectName: 'Large',
    );
    db.execute('begin');
    try {
      for (var ordinal = 0; ordinal < 2000; ordinal++) {
        _insertUsageEvent(
          db,
          sessionId: 'large',
          ordinal: ordinal,
          occurredAtUtc: DateTime.utc(
            2026,
            6,
            12,
            1,
          ).add(Duration(milliseconds: ordinal)),
          model: 'gpt-5.6-sol',
          projectId: projectId,
          inputTokens: 1,
          outputTokens: 1,
          totalTokens: 2,
        );
      }
      db.execute('commit');
    } on Object {
      db.execute('rollback');
      rethrow;
    }

    final request = UsageSummaryRequest(
      period: UsagePeriod.today,
      nowUtc: DateTime.utc(2026, 6, 12, 12),
    );
    final summary = repository.summarize(request);
    final plan = repository.explainUsageEventAggregation(request).join('\n');

    expect(summary.totalTokens, 4000);
    expect(summary.byModel.single.totalTokens, 4000);
    expect(plan, contains('idx_usage_events_time_project'));
    expect(plan, contains('sqlite_autoindex_sessions_1'));
    expect(plan, isNot(contains('SCAN usage_events')));
  });
}

void _activatePersistedUsage(Database db) {
  db.execute(
    File(
      '../sql/migration/016_persisted_usage_pricing_maintenance.sql',
    ).readAsStringSync(),
  );
  // Distinct fixture projects represent distinct path contexts. Migration
  // identity and conflict resolution have their own database-level tests.
  db.execute('''
    insert into usage_path_contexts (
      display_path_raw, platform_path_raw, unc_path_raw,
      display_path_key, platform_path_key, unc_path_key,
      normalization_version, detected_project_id, effective_project_id,
      resolution_source, project_rules_version, created_at_utc, updated_at_utc)
    select 'fixture-project-' || project_id, '', '',
      'fixture-project-' || project_id, '', '',
      1, project_id, project_id, 'detected', 0,
      '2026-06-12T00:00:00Z', '2026-06-12T00:00:00Z'
    from usage_events where project_id is not null group by project_id;
  ''');
  db.execute('''
    insert into usage_events_next (
      session_row_id, source_record_ordinal, rollout_ordinal, turn_ordinal,
      epoch, occurred_at_utc, model, path_context_id, input_tokens,
      cached_input_tokens, cache_write_input_tokens, output_tokens,
      reasoning_output_tokens, total_tokens, branch_scope, derivation, event_fingerprint)
    select session_row_id, source_record_ordinal, rollout_ordinal, turn_ordinal,
      epoch, occurred_at_utc, model,
      coalesce((select id from usage_path_contexts
        where effective_project_id = usage_events.project_id), 1),
      input_tokens, cached_input_tokens,
      cache_write_input_tokens, output_tokens, reasoning_output_tokens,
      total_tokens, branch_scope, derivation, event_fingerprint from usage_events;
  ''');
  final generations = DatabaseGenerationRepository(db);
  final generation = generations.createBuilding(
    sourceSchemaVersion: 15,
    targetSchemaVersion: 16,
    sourceFingerprint: 'fixture',
  );
  generations.markReady(generation.id, validationReportJson: '{}');
  generations.activate(generation.id);
}

Map<String, Object?> _nonmonetarySummary(UsageSummary summary) {
  List<Object> breakdown(List<UsageBreakdownRow> rows) => [
    for (final row in rows)
      (
        row.key,
        row.sessionCount,
        row.messageCount,
        row.inputTokens,
        row.outputTokens,
        row.cachedInputTokens,
        row.totalTokens,
      ),
  ];
  List<Object> top(List<UsageTopSession> rows) => [
    for (final row in rows)
      (
        row.sessionId,
        row.title,
        row.messageCount,
        row.totalTokens,
        row.originLabel,
      ),
  ];
  final coverage = summary.projectionCoverage;
  return {
    'period': (summary.period.startUtc, summary.period.endExclusiveUtc),
    'totals': (
      summary.totalSessions,
      summary.totalMessages,
      summary.inputTokens,
      summary.outputTokens,
      summary.cachedInputTokens,
      summary.totalTokens,
    ),
    'mostActive': (
      summary.mostUsedModel,
      summary.mostActiveProject,
      summary.mostActivePlatform,
    ),
    'coverage': (
      coverage.projectionVersion,
      coverage.availableSessions,
      coverage.currentCompleteSessions,
      coverage.outdatedProjectionSessions,
      coverage.legacyPendingSessions,
      coverage.ambiguousSessions,
      coverage.missingParentSessions,
      coverage.completeZeroUsageSessions,
    ),
    'day': breakdown(summary.byDay),
    'week': breakdown(summary.byWeek),
    'month': breakdown(summary.byMonth),
    'model': breakdown(summary.byModel),
    'project': breakdown(summary.byProject),
    'platform': breakdown(summary.byPlatform),
    'origin': breakdown(summary.byOrigin),
    'archive': breakdown(summary.byArchiveState),
    'topTokens': top(summary.topSessionsByTokens),
    'topMessages': top(summary.topSessionsByMessageCount),
  };
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
  bool projectOverride = false,
}) {
  final now = DateTime.utc(2026, 6, 12, 12).toIso8601String();
  final effectiveProjectId =
      projectId ??
      (projectName == null ? null : _ensureProject(db, projectName));
  db.execute(
    '''
    insert into sessions (
      id, source_type, source_file_path, display_path, platform_path,
      parse_status, scan_status, started_at_utc, last_message_at_utc,
      title, message_count, input_tokens, output_tokens, cached_input_tokens,
      total_tokens, model_primary, models_used, project_id,
      project_name_snapshot, project_override, is_archived, thread_source, created_at_utc,
      updated_at_utc
    ) values (?, ?, ?, ?, ?, 'available', 'available', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
      effectiveProjectId,
      projectName,
      projectOverride ? 1 : 0,
      isArchived ? 1 : 0,
      threadSource,
      now,
      now,
    ],
  );
  db.execute(
    "update sessions set usage_projection_status = 'complete' where id = ?",
    [id],
  );
  if (inputTokens != null &&
      outputTokens != null &&
      cachedInputTokens != null &&
      inputTokens + outputTokens + cachedInputTokens > 0) {
    _insertUsageEvent(
      db,
      sessionId: id,
      ordinal: 999,
      occurredAtUtc: startedAtUtc,
      model: modelPrimary,
      projectId: effectiveProjectId,
      inputTokens: inputTokens,
      cachedInputTokens: cachedInputTokens,
      outputTokens: outputTokens,
      totalTokens: totalTokens ?? inputTokens + outputTokens,
    );
  }
}

int _insertProject(Database db, String name) {
  final now = DateTime.utc(2026, 6, 12).toIso8601String();
  db.execute(
    '''
    insert into projects (name, is_active, created_at_utc, updated_at_utc)
    values (?, 1, ?, ?)
    ''',
    [name, now, now],
  );
  return db.lastInsertRowId;
}

int _ensureProject(Database db, String name) {
  final existing = db.select('select id from projects where name = ?', [name]);
  return existing.isEmpty
      ? _insertProject(db, name)
      : existing.single['id'] as int;
}

void _insertUsageEvent(
  Database db, {
  required String sessionId,
  required int ordinal,
  required DateTime occurredAtUtc,
  required String? model,
  required int? projectId,
  required int inputTokens,
  int cachedInputTokens = 0,
  int cacheWriteInputTokens = 0,
  required int outputTokens,
  int reasoningOutputTokens = 0,
  required int totalTokens,
  String branchScope = 'local',
}) {
  db.execute(
    '''
    insert into usage_events (
      session_row_id, source_record_ordinal, epoch, occurred_at_utc, model,
      project_id, input_tokens, cached_input_tokens,
      cache_write_input_tokens, output_tokens, reasoning_output_tokens,
      total_tokens, branch_scope, derivation, event_fingerprint
    ) values (?, ?, 0, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'last_token_usage', ?)
    ''',
    [
      sessionId,
      ordinal,
      occurredAtUtc.toIso8601String(),
      model,
      projectId,
      inputTokens,
      cachedInputTokens,
      cacheWriteInputTokens,
      outputTokens,
      reasoningOutputTokens,
      totalTokens,
      branchScope,
      '$sessionId:$ordinal'.padRight(64, '0').substring(0, 64),
    ],
  );
}
