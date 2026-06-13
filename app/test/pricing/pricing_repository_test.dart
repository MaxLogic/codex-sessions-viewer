import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/pricing/pricing_repository.dart';
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
}

PricingSettings _settings({
  bool useExternalPricing = true,
  String endpoint = 'https://openrouter.ai/api/v1/models',
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
    overrides: const {
      'local/model': PricingOverrideSettings(
        prompt: '0.10',
        completion: '0.20',
        inputCacheRead: '0.03',
        inputCacheWrite: '0.04',
        internalReasoning: '0.05',
      ),
    },
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
