import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
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
      expect(result.errorMessage, contains('network down'));
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
    expect(result.errorMessage, contains('OpenRouter catalog endpoint'));
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
    expect(result.errorMessage, contains('rejected test override'));
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
      expect(result.errorMessage, contains('network down'));
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
      expect(result.errorMessage, contains('readonly database'));
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
