import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_generation.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:codex_sessions_viewer/src/pricing/pricing_repository.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late PricingRepository repository;
  late PricingSettings settings;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute(File('../sql/init/001_initial_schema.sql').readAsStringSync());
    repository = PricingRepository(db);
    settings = _settings();
  });

  tearDown(() {
    db.close();
  });

  test(
    'migrates cached observations in checkpointed batches without backdating',
    () {
      _enablePriceHistory(db);
      final generation = DatabaseGenerationRepository(db).createBuilding(
        sourceSchemaVersion: 15,
        targetSchemaVersion: 16,
        sourceFingerprint: 'pricing-fixture',
      );
      final observed = DateTime.utc(2026, 9, 1, 12);
      final migrationTime = DateTime.utc(2026, 9, 5);
      for (var index = 0; index < 520; index++) {
        _insertCachedPrice(
          db,
          modelId: 'provider/model${index.toString().padLeft(4, '0')}',
          prompt: '0.1',
          completion: '0.2',
          inputCacheRead: '0',
          fetchedAtUtc: observed.add(Duration(days: index ~/ 512)),
          source: 'openrouter',
        );
      }
      final jobs = MaintenanceJobRepository(db);
      // A real catalog cache-write rate has 22 fractional digits. Preserve
      // both its raw provider evidence and its migrated canonical value.
      const preciseRate = '0.0000000833333333333333';
      db.execute(
        '''update model_pricing_cache set input_cache_write_price_per_token = ?,
          raw_pricing_json = ? where model_id = 'provider/model0518' ''',
        [
          preciseRate,
          jsonEncode({
            'id': 'provider/model0518',
            'pricing': {
              'prompt': '0.1',
              'completion': '0.2',
              'input_cache_read': '0',
              'input_cache_write': preciseRate,
            },
          }),
        ],
      );
      final job = jobs.enqueue(
        jobType: 'usage_projection_migration',
        phase: 'initialize_prices',
        databaseGenerationId: generation.id,
        payloadJson: '{"backup":{"fixture":true}}',
      );
      final lease = jobs.claim(
        jobType: job.jobType,
        leaseDuration: const Duration(minutes: 5),
      )!;
      int migrate() => repository.migrateCachedHistoryNextBatch(
        jobs: jobs,
        lease: lease,
        settings: settings,
        migrationTimeUtc: migrationTime,
      );
      expect(migrate(), 512);
      expect(
        db.select('select count(*) n from model_price_periods').single['n'],
        512,
      );
      expect(jobs.read(job.id)!.completedUnits, 512);
      expect(
        db
            .select(
              "select valid_from_utc from model_price_periods where model_id = 'provider/model0000'",
            )
            .single['valid_from_utc'],
        '2026-09-01T12:00:00.000000Z',
      );
      expect(
        db
            .select('select valid_from_utc from local_price_override_periods')
            .single['valid_from_utc'],
        '2026-09-05T00:00:00.000000Z',
      );
      db.execute('''
      create trigger reject_last_price before insert on model_price_periods
      when new.model_id = 'provider/model0519'
      begin select raise(abort, 'injected cache migration failure'); end;
    ''');
      expect(migrate, throwsA(isA<SqliteException>()));
      expect(
        db.select('select count(*) n from model_price_periods').single['n'],
        512,
      );
      expect(jobs.read(job.id)!.completedUnits, 512);
      db.execute('drop trigger reject_last_price');
      expect(migrate(), 8);
      expect(migrate(), 0);
      expect(jobs.read(job.id)!.completedUnits, 520);
      expect(
        db.select(
          '''select input_cache_write_price_per_token
          from model_price_periods where model_id = 'provider/model0518' ''',
        ).single['input_cache_write_price_per_token'],
        preciseRate,
      );
      expect(
        db
            .select('select pricing_settings_revision from database_state')
            .single['pricing_settings_revision'],
        1,
      );
      expect(
        db.select('select count(*) n from model_pricing_cache').single['n'],
        520,
      );
      expect(db.select('pragma foreign_key_check'), isEmpty);
    },
  );

  test(
    'does not expose untrusted exception text in pricing diagnostics',
    () async {
      _enablePriceHistory(db);
      final result = await repository.refresh(
        settings,
        client: _FakeOpenRouterClient(
          error: 'Authorization: Bearer secret-key; private transport detail',
        ),
      );
      expect(result.success, isFalse);
      expect(result.errorMessage, isNot(contains('secret-key')));
      expect(result.errorMessage, isNot(contains('private transport detail')));
      for (final row in db.select(
        "select message, details from logs where category = 'pricing'",
      )) {
        expect(
          '${row['message']} ${row['details']}',
          isNot(contains('secret-key')),
        );
        expect(
          '${row['message']} ${row['details']}',
          isNot(contains('private transport detail')),
        );
      }
    },
  );

  test(
    'orders price intervals exactly across microseconds within one millisecond',
    () async {
      _enablePriceHistory(db);
      final policy = _settings(overrides: const {});
      final first = DateTime.utc(2026, 9, 5, 10);
      final changed = first.add(const Duration(microseconds: 1));
      Future<PricingLoadResult> observe(DateTime at, String rate) =>
          repository.refresh(
            policy,
            nowUtc: at,
            client: _FakeOpenRouterClient(
              response: OpenRouterModelsResponse([
                OpenRouterModelPricing(
                  modelId: 'provider/micro',
                  provider: 'provider',
                  promptPricePerToken: rate,
                ),
              ]),
            ),
          );
      HistoricalUsageCost cost(DateTime at) =>
          repository.resolveHistoricalUsageCost(
            settings: policy,
            occurredAtUtc: at,
            model: 'provider/micro',
            inputTokens: 1,
            cachedInputTokens: 0,
            cacheWriteInputTokens: 0,
            outputTokens: 0,
            reasoningOutputTokens: 0,
          );
      expect((await observe(first, '1')).success, isTrue);
      expect(cost(changed).estimatedCostText, '1');
      expect((await observe(changed, '2')).success, isTrue);
      expect(cost(first).estimatedCostText, '1');
      expect(cost(changed).estimatedCostText, '2');
      expect(
        cost(first.subtract(const Duration(microseconds: 1))).estimatedCostText,
        isNull,
      );
      expect(
        db
            .select(
              'select valid_from_utc from model_price_periods order by id',
            )
            .map((row) => row['valid_from_utc']),
        ['2026-09-05T10:00:00.000000Z', '2026-09-05T10:00:00.000001Z'],
      );
    },
  );

  test(
    'resolves each event against its observed interval rule and local fallback',
    () async {
      _enablePriceHistory(db);
      final local = _settings(
        useExternalPricing: false,
        overrides: const {
          'gpt-history': PricingOverrideSettings(
            prompt: '0.0001',
            completion: '0.0002',
            inputCacheRead: '0',
            inputCacheWrite: '0',
            internalReasoning: '0',
          ),
        },
      );
      final external = _settings(overrides: local.overrides);
      expect(
        (await repository.load(
          local,
          nowUtc: DateTime.utc(2026, 9, 1),
        )).success,
        isTrue,
      );
      Future<void> observe(
        DateTime at,
        String prompt, {
        bool rule = true,
      }) async {
        final result = await repository.refresh(
          external,
          nowUtc: at,
          client: _FakeOpenRouterClient(
            response: OpenRouterModelsResponse.fromJsonText(
              jsonEncode({
                'data': [
                  {
                    'id': 'openai/gpt-history',
                    'pricing': {
                      'prompt': prompt,
                      'completion': '0.002',
                      if (rule)
                        'overrides': [
                          {
                            'min_prompt_tokens': 100,
                            'utc_start': 1000,
                            'utc_end': 1200,
                            'prompt': '0.003',
                          },
                        ],
                    },
                  },
                ],
              }),
            ),
          ),
        );
        expect(result.success, isTrue);
      }

      await observe(DateTime.utc(2026, 9, 2, 12), '0.001');
      await observe(DateTime.utc(2026, 9, 2, 13), '0.0010');
      await observe(DateTime.utc(2026, 9, 3, 11), '0.004', rule: false);
      HistoricalUsageCost cost(
        DateTime at, {
        int input = 100,
        PricingSettings? policy,
      }) => repository.resolveHistoricalUsageCost(
        settings: policy ?? external,
        occurredAtUtc: at,
        model: 'gpt-history',
        inputTokens: input,
        cachedInputTokens: 0,
        cacheWriteInputTokens: 0,
        outputTokens: 10,
        reasoningOutputTokens: 0,
      );
      expect(cost(DateTime.utc(2026, 8, 31)).estimatedCostText, isNull);
      final fallback = cost(DateTime.utc(2026, 9, 2, 11));
      expect(fallback.estimatedCostText, '0.012');
      expect(fallback.localOverridePeriodId, isNotNull);
      expect(fallback.providerPricePeriodId, isNull);
      final beforeWindow = cost(DateTime.parse('2026-09-03T09:59:59.999999Z'));
      expect(beforeWindow.estimatedCostText, '0.12');
      expect(beforeWindow.providerRuleIds, isEmpty);
      expect(beforeWindow.catalogSnapshotId, 1);
      expect(beforeWindow.resolutionMethod, 'openrouter_openai_exact');
      expect(
        cost(DateTime.utc(2026, 9, 3, 10), input: 99).estimatedCostText,
        '0.119',
      );
      expect(cost(DateTime.utc(2026, 9, 3, 10)).estimatedCostText, '0.12');
      final conditional = cost(DateTime.utc(2026, 9, 3, 10), input: 101);
      expect(conditional.estimatedCostText, '0.323');
      expect(conditional.providerRuleIds, [1]);
      expect(conditional.costStatus, 'complete');
      expect(cost(DateTime.utc(2026, 9, 3, 11)).estimatedCostText, '0.42');
      expect(
        cost(DateTime.utc(2026, 9, 3, 11), policy: local).estimatedCostText,
        '0.012',
      );
      expect(cost(DateTime.utc(2026, 10, 1)).estimatedCostText, '0.42');
    },
  );

  test(
    'pricing policy changes atomically invalidate all stored partitions',
    () async {
      _enablePriceHistory(db);
      await repository.refresh(
        settings,
        nowUtc: DateTime.utc(2026, 9, 1),
        client: _FakeOpenRouterClient(
          response: OpenRouterModelsResponse([
            OpenRouterModelPricing(
              modelId: 'model',
              provider: 'provider',
              promptPricePerToken: '0.001',
            ),
          ]),
        ),
      );
      db.execute('''
      with recursive n(i) as (select 1 union all select i + 1 from n where i < 520)
      insert into sessions (id, source_type, source_file_path, display_path,
        platform_path, created_at_utc, updated_at_utc)
      select printf('s%04d', i), 'windows', printf('s%04d', i),
        'fixture', 'fixture', '2026-09-01', '2026-09-01' from n;
      insert into usage_session_daily (session_id, day_utc, model_key, path_context_id,
        branch_scope, input_tokens, cached_input_tokens, cache_write_input_tokens,
        output_tokens, reasoning_output_tokens, total_tokens, estimated_cost_text,
        cost_status, provider_price_period_id, pricing_catalog_snapshot_id,
        pricing_resolution_method, cost_projection_version, updated_at_utc)
      select id, '2026-09-01', 'model', 1, 'local', 1, 0, 0, 0, 0, 1,
        '0.001', 'complete', 1, 1, 'openrouter_exact', 1, '2026-09-01' from sessions;
    ''');
      final local = _settings(useExternalPricing: false);
      final previousPolicy = db
          .select('select pricing_policy_json from database_state')
          .single['pricing_policy_json'];
      db.execute('''
      create trigger fail_policy_dirty before insert on usage_cost_dirty_partitions
      when new.session_id = 's0513'
      begin select raise(abort, 'injected policy invalidation failure'); end;
    ''');
      expect(
        (await repository.load(
          local,
          nowUtc: DateTime.utc(2026, 9, 2),
        )).success,
        isFalse,
      );
      expect(db.select('select * from usage_cost_dirty_partitions'), isEmpty);
      expect(
        db
            .select('select pricing_policy_json from database_state')
            .single['pricing_policy_json'],
        previousPolicy,
      );
      db.execute('drop trigger fail_policy_dirty');
      expect(
        (await repository.load(
          local,
          nowUtc: DateTime.utc(2026, 9, 2),
        )).success,
        isTrue,
      );
      expect(
        db
            .select('select count(*) n from usage_cost_dirty_partitions')
            .single['n'],
        520,
      );
      db.execute('delete from usage_cost_dirty_partitions');
      expect(
        (await repository.load(
          local,
          nowUtc: DateTime.utc(2026, 9, 3),
        )).success,
        isTrue,
      );
      expect(db.select('select * from usage_cost_dirty_partitions'), isEmpty);
      // Simulate a prior calculation version without changing current settings.
      db.execute('update database_state set pricing_policy_json = ?', [
        jsonEncode([0, false, local.fallbackToOverrides]),
      ]);
      expect(
        (await repository.load(
          local,
          nowUtc: DateTime.utc(2026, 9, 4),
        )).success,
        isTrue,
      );
      expect(
        db
            .select('select count(*) n from usage_cost_dirty_partitions')
            .single['n'],
        520,
      );
      expect(
        db
            .select(
              'select distinct target_cost_projection_version v from usage_cost_dirty_partitions',
            )
            .single['v'],
        1,
      );
    },
  );

  test(
    'overlays all matching provider rules with later fields winning',
    () async {
      _enablePriceHistory(db);
      final result = await repository.refresh(
        settings,
        nowUtc: DateTime.utc(2026, 9, 1),
        client: _FakeOpenRouterClient(
          response: OpenRouterModelsResponse.fromJsonText(
            jsonEncode({
              'data': [
                {
                  'id': 'provider/layered',
                  'pricing': {
                    'prompt': '0.001',
                    'completion': '0.002',
                    'overrides': [
                      {
                        'min_prompt_tokens': 10,
                        'prompt': '0.003',
                        'completion': '0.004',
                      },
                      {'min_prompt_tokens': 20, 'prompt': '0.005'},
                      {'min_prompt_tokens': 100, 'completion': '9'},
                    ],
                  },
                },
              ],
            }),
          ),
        ),
      );
      expect(result.success, isTrue);
      final cost = repository.resolveHistoricalUsageCost(
        settings: settings,
        occurredAtUtc: DateTime.utc(2026, 9, 2),
        model: 'provider/layered',
        inputTokens: 30,
        cachedInputTokens: 0,
        cacheWriteInputTokens: 0,
        outputTokens: 10,
        reasoningOutputTokens: 0,
      );
      // Second rule replaces prompt only; the first rule's completion survives.
      expect(cost.estimatedCostText, '0.19');
      expect(cost.providerRuleIds, [1, 2]);
    },
  );

  test(
    'versions local overrides independently of provider availability and fallback switches',
    () async {
      _enablePriceHistory(db);
      Future<PricingLoadResult> observe(
        DateTime at,
        Map<String, PricingOverrideSettings> overrides,
      ) => repository.load(
        PricingSettings(
          provider: 'openrouter',
          useExternalPricing: false,
          cachePricingHours: 24,
          fallbackToOverrides: false,
          openRouter: settings.openRouter,
          overrides: overrides,
        ),
        nowUtc: at,
      );
      PricingOverrideSettings rate(String prompt) => PricingOverrideSettings(
        prompt: prompt,
        completion: '0.002',
        inputCacheRead: '0.0001',
        inputCacheWrite: '0.0015',
        internalReasoning: '0.003',
      );
      expect(
        (await observe(DateTime.utc(2026, 9, 1), {
          'local/model': rate('0.001'),
        })).success,
        isTrue,
      );
      final rows = db.select('select * from local_price_override_periods');
      expect(rows, hasLength(1));
      final first = rows.single;
      expect(
        DateTime.parse(first['valid_from_utc'] as String),
        DateTime.utc(2026, 9, 1),
      );
      expect(
        (await observe(DateTime.utc(2026, 9, 2), {
          'local/model': rate('0.0010'),
        })).success,
        isTrue,
      );
      final unchanged = db
          .select('select * from local_price_override_periods')
          .single;
      expect(unchanged['id'], first['id']);
      expect(
        unchanged['first_settings_revision'],
        first['first_settings_revision'],
      );
      expect(
        unchanged['last_seen_settings_revision'],
        greaterThan(first['last_seen_settings_revision'] as int),
      );
      expect(
        (await observe(DateTime.utc(2026, 9, 3, 10), {
          'local/model': rate('0.002'),
        })).success,
        isTrue,
      );
      expect((await observe(DateTime.utc(2026, 9, 3, 11), {})).success, isTrue);
      final history = db.select(
        'select * from local_price_override_periods order by id',
      );
      expect(history, hasLength(2));
      expect(
        DateTime.parse(history.first['valid_to_utc'] as String),
        DateTime.utc(2026, 9, 3, 10),
      );
      expect(
        DateTime.parse(history.last['valid_to_utc'] as String),
        DateTime.utc(2026, 9, 3, 11),
      );
      expect(history.last['prompt_price_per_token'], '0.002');
      expect(db.select('pragma foreign_key_check'), isEmpty);
    },
  );

  test(
    'preserves provider unknown-rate sentinels without negative charges',
    () async {
      _enablePriceHistory(db);
      final result = await repository.refresh(
        settings,
        nowUtc: DateTime.utc(2026, 9, 5),
        client: _FakeOpenRouterClient(
          response: OpenRouterModelsResponse.fromJsonText(
            '{"data":[{"id":"openrouter/auto","pricing":{"prompt":"-1","completion":"-1"}}],"total_count":1}',
          ),
        ),
      );
      expect(result.success, isTrue);
      final period = db.select('select * from model_price_periods').single;
      expect(period['prompt_price_per_token'], isNull);
      expect(period['completion_price_per_token'], isNull);
      expect(
        jsonDecode(period['raw_pricing_json'] as String)['pricing']['prompt'],
        '-1',
      );
      expect(
        () => OpenRouterModelsResponse.fromJsonText(
          '{"data":[{"id":"provider/model","pricing":{"prompt":"-2"}}]}',
        ),
        throwsA(isA<PricingFetchException>()),
      );
    },
  );

  test(
    'versions provider rules and non-token rates with immutable price periods',
    () async {
      _enablePriceHistory(db);
      Future<PricingLoadResult> apply(
        DateTime at, {
        String ruleRate = '0.002',
        String imageRate = '0.01',
        bool reverseKeys = false,
      }) => repository.refresh(
        settings,
        nowUtc: at,
        client: _FakeOpenRouterClient(
          response: OpenRouterModelsResponse.fromJsonText(
            jsonEncode({
              'data': [
                {
                  'id': 'provider/conditional',
                  'canonical_slug': 'provider/canonical',
                  'pricing': {
                    'prompt': '0.001',
                    'image': imageRate,
                    'web_search': '0.02',
                    'audio': '0.03',
                    'overrides': [
                      {
                        if (reverseKeys) 'prompt': ruleRate,
                        'min_prompt_tokens': 100,
                        'utc_start': 1600,
                        'utc_end': 0,
                        'utc_days': reverseKeys
                            ? ['tuesday', 'monday']
                            : ['monday', 'tuesday'],
                        if (!reverseKeys) 'prompt': ruleRate,
                        'audio': '0.04',
                      },
                    ],
                  },
                },
              ],
            }),
          ),
        ),
      );
      expect((await apply(DateTime.utc(2026, 9, 1))).success, isTrue);
      final originalRule = db
          .select('select * from provider_price_rules')
          .single;
      expect(originalRule['provider_order'], 0);
      expect(originalRule['prompt_tokens_min'], 100);
      expect(originalRule['utc_start_minute'], 960);
      expect(originalRule['utc_end_minute'], 0);
      expect(jsonDecode(originalRule['utc_weekdays'] as String), [1, 2]);
      expect(
        jsonDecode(originalRule['raw_rule_json'] as String)['audio'],
        '0.04',
      );
      final original = db.select('select * from model_price_periods').single;
      expect(original['canonical_slug'], 'provider/canonical');
      expect(original['image_price'], '0.01');
      expect(original['web_search_price'], '0.02');
      expect(jsonDecode(original['additional_prices_json'] as String), {
        'audio': '0.03',
      });
      expect(jsonDecode(originalRule['additional_prices_json'] as String), {
        'audio': '0.04',
      });
      expect(
        (await apply(
          DateTime.utc(2026, 9, 2),
          ruleRate: '0.0020',
          reverseKeys: true,
        )).success,
        isTrue,
      );
      expect(
        db.select('select id from model_price_periods').single['id'],
        original['id'],
      );
      expect(
        (await apply(DateTime.utc(2026, 9, 3), ruleRate: '0.003')).success,
        isTrue,
      );
      expect(db.select('select id from model_price_periods'), hasLength(2));
      expect(
        (await apply(
          DateTime.utc(2026, 9, 4),
          ruleRate: '0.003',
          imageRate: '0.02',
        )).success,
        isTrue,
      );
      expect(db.select('select id from model_price_periods'), hasLength(3));
      expect(
        db.select('select * from provider_price_rules where id = ?', [
          originalRule['id'],
        ]).single,
        originalRule,
      );
      expect(db.select('pragma foreign_key_check'), isEmpty);
    },
  );

  test(
    'rejects malformed catalog members instead of silently omitting models',
    () {
      for (final data in [
        [null],
        [
          {'id': 'provider/model', 'pricing': null},
        ],
        [
          {
            'id': 'provider/model',
            'pricing': {'prompt': []},
          },
        ],
      ]) {
        expect(
          () =>
              OpenRouterModelsResponse.fromJsonText(jsonEncode({'data': data})),
          throwsA(isA<PricingFetchException>()),
        );
      }
    },
  );

  test('only an authoritative complete catalog closes absent models', () async {
    _enablePriceHistory(db);
    Future<PricingLoadResult> apply(
      List<String> ids,
      DateTime at, {
      int? total,
    }) => repository.refresh(
      settings,
      nowUtc: at,
      client: _FakeOpenRouterClient(
        response: OpenRouterModelsResponse.fromJsonText(
          jsonEncode({
            'data': [
              for (final id in ids)
                {
                  'id': id,
                  'pricing': {'prompt': '0.001'},
                },
            ],
            'total_count': ?total,
            'links': {'next': null},
          }),
        ),
      ),
    );
    expect(
      (await apply(
        ['provider/a', 'provider/b'],
        DateTime.utc(2026, 9, 1),
        total: 2,
      )).success,
      isTrue,
    );
    expect(
      (await apply(['provider/a'], DateTime.utc(2026, 9, 2))).success,
      isTrue,
    );
    expect(
      db.select(
        'select id from model_price_periods where valid_to_utc is null',
      ),
      hasLength(2),
    );
    expect(
      (await apply(['provider/a'], DateTime.utc(2026, 9, 3), total: 2)).success,
      isFalse,
    );
    expect(
      (await apply(
        ['provider/a', 'provider/a'],
        DateTime.utc(2026, 9, 4),
        total: 2,
      )).success,
      isFalse,
    );
    expect(
      db.select(
        'select id from model_price_periods where valid_to_utc is null',
      ),
      hasLength(2),
    );
    expect(
      (await apply(['provider/a'], DateTime.utc(2026, 9, 5), total: 1)).success,
      isTrue,
    );
    final absent = db
        .select(
          "select * from model_price_periods where model_id = 'provider/b'",
        )
        .single;
    expect(
      DateTime.parse(absent['valid_to_utc'] as String),
      DateTime.utc(2026, 9, 5),
    );
    expect(
      db.select(
        "select * from model_pricing_cache where model_id = 'provider/b'",
      ),
      isEmpty,
    );
    expect(
      db
          .select(
            'select completeness_status from price_catalog_snapshots order by id',
          )
          .map((row) => row['completeness_status']),
      [
        'complete_for_removals',
        'complete_for_updates',
        'failed',
        'failed',
        'complete_for_removals',
      ],
    );
    expect(db.select('pragma foreign_key_check'), isEmpty);
  });

  test(
    'preserves observed price intervals across unchanged failed and changed downloads',
    () async {
      _enablePriceHistory(db);
      Future<PricingLoadResult> refresh(String rate, DateTime at) =>
          repository.refresh(
            settings,
            nowUtc: at,
            client: _FakeOpenRouterClient(
              response: OpenRouterModelsResponse([
                OpenRouterModelPricing(
                  modelId: 'openai/history',
                  provider: 'openai',
                  promptPricePerToken: rate,
                  completionPricePerToken: '0.002',
                ),
              ]),
            ),
          );
      final first = DateTime.utc(2026, 9, 1, 10);
      final unchanged = DateTime.utc(2026, 9, 3, 10);
      final failed = DateTime.utc(2026, 9, 3, 11);
      final changed = DateTime.utc(2026, 9, 3, 12);
      expect((await refresh('0.001', first)).success, isTrue);
      final firstRows = db.select('select * from model_price_periods');
      expect(firstRows, hasLength(1));
      final originalId = firstRows.single['id'];
      expect(
        DateTime.parse(firstRows.single['valid_from_utc'] as String),
        first,
      );
      expect(firstRows.single['valid_to_utc'], isNull);
      expect((await refresh('0.0010', unchanged)).success, isTrue);
      final retained = db.select('select * from model_price_periods').single;
      expect(retained['id'], originalId);
      expect(retained['first_snapshot_id'], 1);
      expect(retained['last_seen_snapshot_id'], 2);
      final failure = await repository.refresh(
        settings,
        nowUtc: failed,
        client: _FakeOpenRouterClient(error: 'download unavailable'),
      );
      expect(failure.success, isFalse);
      expect(
        db
            .select('select valid_to_utc from model_price_periods')
            .single['valid_to_utc'],
        isNull,
      );
      expect((await refresh('0.003', changed)).success, isTrue);
      final periods = db.select(
        'select * from model_price_periods order by valid_from_utc',
      );
      expect(periods, hasLength(2));
      expect(periods.first['id'], originalId);
      expect(DateTime.parse(periods.first['valid_to_utc'] as String), changed);
      expect(DateTime.parse(periods.last['valid_from_utc'] as String), changed);
      expect(periods.last['valid_to_utc'], isNull);
      expect(periods.last['prompt_price_per_token'], '0.003');
      expect(
        db
            .select('select status from price_catalog_snapshots order by id')
            .map((row) => row['status']),
        ['succeeded', 'succeeded', 'failed', 'succeeded'],
      );
      expect(db.select('pragma foreign_key_check'), isEmpty);
    },
  );

  test('price changes and affected dirty partitions commit atomically', () async {
    _enablePriceHistory(db);
    Future<PricingLoadResult> refresh(String price, DateTime at) =>
        repository.refresh(
          settings,
          nowUtc: at,
          client: _FakeOpenRouterClient(
            response: OpenRouterModelsResponse([
              OpenRouterModelPricing(
                modelId: 'openai/gpt-history',
                provider: 'openai',
                promptPricePerToken: price,
              ),
            ]),
          ),
        );
    expect((await refresh('0.001', DateTime.utc(2026, 9, 1))).success, isTrue);
    for (final (id, model, at) in [
      ('before', 'openai/gpt-history', '2026-09-03T11:59:59.999999Z'),
      ('offset-before', 'openai/gpt-history', '2026-09-03T13:00:00+02:00'),
      ('exact', 'openai/gpt-history', '2026-09-03T12:00:00.000Z'),
      ('after-alias', 'gpt-history', '2026-09-03T14:00:00.000Z'),
      ('other', 'other/model', '2026-09-03T14:00:00.000Z'),
    ]) {
      db.execute(
        '''
          insert into sessions (id, source_type, source_file_path, display_path,
            platform_path, created_at_utc, updated_at_utc)
          values (?, 'windows', ?, 'fixture', 'fixture', '2026-09-03', '2026-09-03')
        ''',
        [id, id],
      );
      db.execute(
        '''
          insert into usage_events (session_row_id, source_record_ordinal, epoch,
            occurred_at_utc, model, input_tokens, cached_input_tokens,
            cache_write_input_tokens, output_tokens, reasoning_output_tokens,
            total_tokens, branch_scope, derivation, event_fingerprint)
          values (?, 1, 0, ?, ?, 1, 0, 0, 0, 0, 1, 'local', 'last_token_usage', ?)
        ''',
        [id, at, model, '0' * 64],
      );
      db.execute(
        '''
          insert into usage_session_daily (session_id, day_utc, model_key,
            path_context_id, branch_scope, input_tokens, cached_input_tokens,
            cache_write_input_tokens, output_tokens, reasoning_output_tokens,
            total_tokens, cost_status, pricing_resolution_method,
            cost_projection_version, updated_at_utc)
          values (?, '2026-09-03', ?, 1, 'local', 1, 0, 0, 0, 0, 1,
            'unknown', 'pending_history', 1, '2026-09-03')
        ''',
        [id, model],
      );
    }
    db.execute('''
        create trigger fail_dirty before insert on usage_cost_dirty_partitions
        begin select raise(abort, 'injected dirty failure'); end;
      ''');
    final observed = DateTime.utc(2026, 9, 3, 12);
    expect((await refresh('0.002', observed)).success, isFalse);
    expect(db.select('select * from usage_cost_dirty_partitions'), isEmpty);
    final retained = db.select('select * from model_price_periods').single;
    expect(retained['prompt_price_per_token'], '0.001');
    expect(retained['valid_to_utc'], isNull);
    expect(
      db
          .select(
            "select count(*) n from price_catalog_snapshots where status = 'succeeded'",
          )
          .single['n'],
      1,
    );
    db.execute('drop trigger fail_dirty');
    expect((await refresh('0.002', observed)).success, isTrue);
    expect(
      db
          .select(
            'select session_id from usage_cost_dirty_partitions order by session_id',
          )
          .map((row) => row['session_id']),
      ['after-alias', 'exact'],
    );
    expect(db.select('pragma foreign_key_check'), isEmpty);
  });

  test(
    'fetches only the OpenRouter model catalog and caches model prices',
    () async {
      final client = _FakeOpenRouterClient(
        response: const OpenRouterModelsResponse([
          OpenRouterModelPricing(
            modelId: 'openai/gpt-test',
            modelName: 'GPT Test',
            provider: 'openai',
            promptPricePerToken: '0.000001',
            completionPricePerToken: '0.000002',
            inputCacheReadPricePerToken: '0.0000001',
            inputCacheWritePricePerToken: '0.0000004',
            internalReasoningPricePerToken: '0.000003',
            requestPrice: '0',
            rawPricingJson: '{"pricing":true}',
          ),
        ]),
      );

      final result = await repository.refresh(
        settings,
        client: client,
        nowUtc: DateTime.utc(2026, 6, 13, 10),
      );

      expect(result.success, isTrue);
      expect(client.calls, hasLength(1));
      expect(
        client.calls.single.endpoint.toString(),
        settings.openRouter.modelsEndpoint,
      );
      expect(client.calls.single.apiKey, 'secret-key');
      expect(client.calls.single.body, isNull);
      expect(result.catalog.models, contains('openai/gpt-test'));
      expect(result.catalog.models, contains('local/model'));

      final row = db.select(
        'select * from model_pricing_cache where model_id = ?',
        ['openai/gpt-test'],
      ).single;
      expect(row['model_name'], 'GPT Test');
      expect(row['provider'], 'openai');
      expect(row['prompt_price_per_token'], '0.000001');
      expect(row['completion_price_per_token'], '0.000002');
      expect(row['input_cache_read_price_per_token'], '0.0000001');
      expect(row['source'], 'openrouter');
    },
  );

  test(
    'resolves unqualified Codex GPT models to exact OpenRouter entries',
    () async {
      final fetchedAt = DateTime.utc(2026, 7, 29, 8, 30);
      final result = await repository.refresh(
        settings,
        client: _FakeOpenRouterClient(
          response: const OpenRouterModelsResponse([
            OpenRouterModelPricing(
              modelId: 'openai/gpt-5.5',
              provider: 'openai',
              promptPricePerToken: '0.000005',
              completionPricePerToken: '0.000030',
              inputCacheReadPricePerToken: '0.0000005',
            ),
            OpenRouterModelPricing(
              modelId: 'openai/gpt-5.6-sol',
              provider: 'openai',
              promptPricePerToken: '0.000005',
              completionPricePerToken: '0.000030',
              inputCacheReadPricePerToken: '0.0000005',
              inputCacheWritePricePerToken: '0.00000625',
              internalReasoningPricePerToken: '0.000030',
            ),
            OpenRouterModelPricing(
              modelId: 'openai/gpt-5.6-terra',
              provider: 'openai',
              promptPricePerToken: '0.00000125',
              completionPricePerToken: '0.0000075',
              inputCacheReadPricePerToken: '0.000000125',
              inputCacheWritePricePerToken: '0.0000015625',
            ),
            OpenRouterModelPricing(
              modelId: 'other/gpt-5.6-sol',
              provider: 'other',
              promptPricePerToken: '9',
            ),
          ]),
        ),
        nowUtc: fetchedAt,
      );

      expect(result.success, isTrue);
      expect(
        result.catalog.resolve('openai/gpt-5.5').resolvedModelId,
        'openai/gpt-5.5',
      );
      expect(
        result.catalog.resolve('openai/gpt-5.5').method,
        UsageModelResolutionMethod.exact,
      );
      expect(
        result.catalog.resolve('gpt-5.6-sol').resolvedModelId,
        'openai/gpt-5.6-sol',
      );
      expect(
        result.catalog.resolve('gpt-5.6-sol').method,
        UsageModelResolutionMethod.openAiExact,
      );
      expect(
        result.catalog.resolve('gpt-5.6-terra').resolvedModelId,
        'openai/gpt-5.6-terra',
      );
      expect(result.catalog.resolve('gpt-5.6').pricing, isNull);
      expect(result.catalog.resolve('gpt-5.6-sol-extra').pricing, isNull);
      expect(result.catalog.resolve('GPT-5.6-SOL').pricing, isNull);
      expect(
        result.catalog.resolve('other/gpt-5.6-sol').resolvedModelId,
        'other/gpt-5.6-sol',
      );

      final sol = result.catalog['gpt-5.6-sol'];
      expect(sol?.cacheWriteInputPricePerToken, '0.00000625');
      expect(sol?.internalReasoningPricePerToken, '0.000030');
      expect(sol?.source, 'openrouter');
      expect(sol?.fetchedAtUtc, fetchedAt);
      expect(result.catalog.openRouterFetchedAtUtc, fetchedAt);
      expect(
        result.catalog.openRouterCacheAge(DateTime.utc(2026, 7, 29, 10)),
        const Duration(hours: 1, minutes: 30),
      );

      const exactOverrideWins = UsagePricingCatalog({
        'gpt-5.5': UsageModelPricing(
          promptPricePerToken: '1',
          source: 'override',
        ),
        'openai/gpt-5.5': UsageModelPricing(
          promptPricePerToken: '2',
          source: 'openrouter',
        ),
      });
      expect(exactOverrideWins.resolve('gpt-5.5').resolvedModelId, 'gpt-5.5');
      expect(exactOverrideWins['gpt-5.5']?.promptPricePerToken, '1');
    },
  );

  test('uses fresh cache before overrides and avoids network fetch', () async {
    _insertCachedPrice(
      db,
      modelId: 'openai/cached',
      prompt: '0.01',
      completion: '0.02',
      inputCacheRead: '0.003',
      fetchedAtUtc: DateTime.utc(2026, 6, 13, 9),
      source: 'openrouter',
    );
    final client = _FakeOpenRouterClient(
      response: const OpenRouterModelsResponse([]),
    );

    final result = await repository.load(
      settings,
      client: client,
      nowUtc: DateTime.utc(2026, 6, 13, 10),
    );

    expect(result.success, isTrue);
    expect(client.calls, isEmpty);
    expect(result.catalog.models['openai/cached']?.promptPricePerToken, '0.01');
    expect(result.catalog.models['local/model']?.promptPricePerToken, '0.10');
  });

  test('loads cached pricing without fetching OpenRouter', () async {
    _insertCachedPrice(
      db,
      modelId: 'openai/cached',
      prompt: '0.01',
      completion: '0.02',
      inputCacheRead: '0.003',
      fetchedAtUtc: DateTime.utc(2026, 6, 13, 9),
      source: 'openrouter',
    );
    final client = _FakeOpenRouterClient(
      response: const OpenRouterModelsResponse([]),
    );

    final catalog = repository.loadCached(
      settings,
      nowUtc: DateTime.utc(2026, 6, 13, 10),
    );

    expect(client.calls, isEmpty);
    expect(catalog.models['openai/cached']?.promptPricePerToken, '0.01');
    expect(catalog.models['local/model']?.promptPricePerToken, '0.10');
  });

  test('loads cached pricing without requiring a database write', () {
    db.execute('pragma query_only = on');

    final catalog = repository.loadCached(
      settings,
      nowUtc: DateTime.utc(2026, 6, 13, 10),
    );

    expect(catalog.models['local/model']?.promptPricePerToken, '0.10');
  });

  test(
    'stale cache fetch failure is recoverable and keeps local prices',
    () async {
      _insertCachedPrice(
        db,
        modelId: 'openai/stale',
        prompt: '0.01',
        completion: '0.02',
        inputCacheRead: '0.003',
        fetchedAtUtc: DateTime.utc(2026, 6, 12, 9),
        source: 'openrouter',
      );
      final client = _FakeOpenRouterClient(error: 'network down');

      final result = await repository.load(
        settings,
        client: client,
        nowUtc: DateTime.utc(2026, 6, 13, 10),
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, 'Pricing fetch failed.');
      expect(client.calls, hasLength(1));
      expect(
        result.catalog.models['openai/stale']?.promptPricePerToken,
        '0.01',
      );
      expect(result.catalog.models['local/model']?.promptPricePerToken, '0.10');
    },
  );

  test('stale cache does not suppress same-model local override', () async {
    _insertCachedPrice(
      db,
      modelId: 'local/model',
      prompt: '9.99',
      completion: '9.99',
      inputCacheRead: '9.99',
      fetchedAtUtc: DateTime.utc(2026, 6, 12, 9),
      source: 'openrouter',
    );
    final client = _FakeOpenRouterClient(error: 'network down');

    final result = await repository.load(
      settings,
      client: client,
      nowUtc: DateTime.utc(2026, 6, 13, 10),
    );

    expect(result.success, isFalse);
    expect(result.catalog.models['local/model']?.promptPricePerToken, '0.10');
  });

  test(
    'mixed fresh and stale cache excludes stale rows from fresh loads',
    () async {
      _insertCachedPrice(
        db,
        modelId: 'openai/fresh',
        prompt: '0.01',
        completion: '0.02',
        inputCacheRead: '0.003',
        fetchedAtUtc: DateTime.utc(2026, 6, 13, 9),
        source: 'openrouter',
      );
      _insertCachedPrice(
        db,
        modelId: 'openai/stale',
        prompt: '9.99',
        completion: '9.99',
        inputCacheRead: '9.99',
        fetchedAtUtc: DateTime.utc(2026, 6, 12, 9),
        source: 'openrouter',
      );
      final client = _FakeOpenRouterClient(
        response: const OpenRouterModelsResponse([]),
      );

      final result = await repository.load(
        settings,
        client: client,
        nowUtc: DateTime.utc(2026, 6, 13, 10),
      );

      expect(result.success, isTrue);
      expect(client.calls, isEmpty);
      expect(result.catalog.models, contains('openai/fresh'));
      expect(result.catalog.models, isNot(contains('openai/stale')));
    },
  );

  test('rejects non-OpenRouter endpoints before sending credentials', () async {
    final client = _FakeOpenRouterClient(
      response: const OpenRouterModelsResponse([]),
    );

    final result = await repository.load(
      _settings(endpoint: 'https://example.test/api/v1/models'),
      client: client,
      nowUtc: DateTime.utc(2026, 6, 13, 10),
    );

    expect(result.success, isFalse);
    expect(result.errorMessage, 'Pricing fetch failed.');
    expect(client.calls, isEmpty);
    final log = db.select('select level, category, message from logs').single;
    expect(log['level'], 'error');
    expect(log['category'], 'pricing');
  });

  test('disabled external pricing never calls OpenRouter', () async {
    final client = _FakeOpenRouterClient(
      response: const OpenRouterModelsResponse([]),
    );

    final result = await repository.load(
      _settings(useExternalPricing: false),
      client: client,
      nowUtc: DateTime.utc(2026, 6, 13, 10),
    );

    expect(result.success, isTrue);
    expect(client.calls, isEmpty);
    expect(result.catalog.models.keys, ['local/model']);
    expect(
      db.select('select source from model_pricing_cache where model_id = ?', [
        'local/model',
      ]).single['source'],
      'override',
    );
  });

  test('unchanged overrides do not require the SQLite writer slot', () async {
    final localSettings = _settings(useExternalPricing: false);
    final first = await repository.load(
      localSettings,
      nowUtc: DateTime.utc(2026, 6, 13, 10),
    );
    expect(first.success, isTrue);
    db.execute('pragma query_only = on');

    final second = await repository.load(
      localSettings,
      nowUtc: DateTime.utc(2026, 6, 13, 11),
    );

    expect(second.success, isTrue);
    expect(second.catalog.models['local/model']?.promptPricePerToken, '0.10');
  });

  test('persists changed overrides in one atomic write transaction', () async {
    db.execute('''
      create trigger reject_bad_override
      before insert on model_pricing_cache
      when new.model_id = 'local/bad'
      begin
        select raise(abort, 'rejected test override');
      end
      ''');
    final localSettings = _settings(
      useExternalPricing: false,
      overrides: const {
        'local/good': PricingOverrideSettings(
          prompt: '0.10',
          completion: '0.20',
          inputCacheRead: '0.03',
          inputCacheWrite: '0.04',
          internalReasoning: '0.05',
        ),
        'local/bad': PricingOverrideSettings(
          prompt: '1.10',
          completion: '1.20',
          inputCacheRead: '1.03',
          inputCacheWrite: '1.04',
          internalReasoning: '1.05',
        ),
      },
    );

    final result = await repository.load(
      localSettings,
      nowUtc: DateTime.utc(2026, 6, 13, 10),
    );

    expect(result.success, isFalse);
    expect(result.errorMessage, 'Pricing database update failed.');
    expect(
      db.select(
        "select model_id from model_pricing_cache where source = 'override'",
      ),
      isEmpty,
    );
  });

  test(
    'pricing failure stays recoverable when error logging cannot write',
    () async {
      final localSettings = _settings(useExternalPricing: false);
      final first = await repository.load(
        localSettings,
        nowUtc: DateTime.utc(2026, 6, 13, 10),
      );
      expect(first.success, isTrue);
      db.execute('pragma query_only = on');

      final result = await repository.load(
        settings,
        client: _FakeOpenRouterClient(error: 'network down'),
        nowUtc: DateTime.utc(2026, 6, 15, 10),
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, 'Pricing fetch failed.');
      expect(result.catalog.models['local/model']?.promptPricePerToken, '0.10');
    },
  );

  test(
    'override persistence lock returns in-memory pricing fallback',
    () async {
      db.execute('pragma query_only = on');

      final result = await repository.load(
        _settings(useExternalPricing: false),
        nowUtc: DateTime.utc(2026, 6, 13, 10),
      );

      expect(result.success, isFalse);
      expect(result.errorMessage, 'Pricing database update failed.');
      expect(result.catalog.models['local/model']?.promptPricePerToken, '0.10');
    },
  );
}

PricingSettings _settings({
  bool useExternalPricing = true,
  String endpoint = 'https://openrouter.ai/api/v1/models',
  Map<String, PricingOverrideSettings> overrides = const {
    'local/model': PricingOverrideSettings(
      prompt: '0.10',
      completion: '0.20',
      inputCacheRead: '0.03',
      inputCacheWrite: '0.04',
      internalReasoning: '0.05',
    ),
  },
}) {
  return PricingSettings(
    provider: 'openrouter',
    useExternalPricing: useExternalPricing,
    cachePricingHours: 24,
    fallbackToOverrides: true,
    openRouter: OpenRouterSettings(
      modelsEndpoint: endpoint,
      apiKey: 'secret-key',
    ),
    overrides: overrides,
  );
}

void _insertCachedPrice(
  Database db, {
  required String modelId,
  required String prompt,
  required String completion,
  required String inputCacheRead,
  required DateTime fetchedAtUtc,
  required String source,
}) {
  db.execute(
    '''
    insert into model_pricing_cache (
      model_id, provider, prompt_price_per_token,
      completion_price_per_token, input_cache_read_price_per_token,
      fetched_at_utc, source
    ) values (?, 'openai', ?, ?, ?, ?, ?)
    ''',
    [
      modelId,
      prompt,
      completion,
      inputCacheRead,
      fetchedAtUtc.toIso8601String(),
      source,
    ],
  );
}

void _enablePriceHistory(Database db) {
  final migrations =
      Directory('../sql/migration')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.sql'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in migrations) {
    db.execute(file.readAsStringSync());
  }
  db.execute('pragma foreign_keys = on');
}

class _FakeOpenRouterClient implements OpenRouterModelsClient {
  _FakeOpenRouterClient({this.response, this.error});

  final OpenRouterModelsResponse? response;
  final String? error;
  final calls = <OpenRouterModelsRequest>[];

  @override
  Future<OpenRouterModelsResponse> fetchModels(
    OpenRouterModelsRequest request,
  ) async {
    calls.add(request);
    if (error != null) {
      throw PricingFetchException(error!);
    }
    return response ?? const OpenRouterModelsResponse([]);
  }
}
