import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../config/app_settings.dart';
import '../usage/usage_summary.dart';

class PricingRepository {
  const PricingRepository(this.db);

  final Database db;

  Future<PricingLoadResult> load(
    PricingSettings settings, {
    OpenRouterModelsClient? client,
    DateTime? nowUtc,
  }) async {
    final now = (nowUtc ?? DateTime.now().toUtc()).toUtc();
    _upsertOverrides(settings, now);
    if (!settings.useExternalPricing) {
      return PricingLoadResult.success(
        _loadCatalog(settings, includeOpenRouter: false),
      );
    }
    final cutoff = _openRouterCutoff(settings, now);
    if (_hasFreshOpenRouterCache(settings, now)) {
      return PricingLoadResult.success(_loadCatalog(settings, cutoff: cutoff));
    }
    try {
      await _fetchAndCache(
        settings,
        client ?? const OpenRouterHttpClient(),
        now,
      );
      return PricingLoadResult.success(_loadCatalog(settings, cutoff: cutoff));
    } on Object catch (error) {
      _recordPricingError(error);
      return PricingLoadResult.failure(
        _loadCatalog(settings, staleOpenRouterOverrideCutoff: cutoff),
        errorMessage: error.toString(),
      );
    }
  }

  Future<PricingLoadResult> refresh(
    PricingSettings settings, {
    OpenRouterModelsClient? client,
    DateTime? nowUtc,
  }) async {
    final now = (nowUtc ?? DateTime.now().toUtc()).toUtc();
    _upsertOverrides(settings, now);
    if (!settings.useExternalPricing) {
      return PricingLoadResult.success(
        _loadCatalog(settings, includeOpenRouter: false),
      );
    }
    final cutoff = _openRouterCutoff(settings, now);
    try {
      await _fetchAndCache(
        settings,
        client ?? const OpenRouterHttpClient(),
        now,
      );
      return PricingLoadResult.success(_loadCatalog(settings, cutoff: cutoff));
    } on Object catch (error) {
      _recordPricingError(error);
      return PricingLoadResult.failure(
        _loadCatalog(settings, staleOpenRouterOverrideCutoff: cutoff),
        errorMessage: error.toString(),
      );
    }
  }

  Future<void> _fetchAndCache(
    PricingSettings settings,
    OpenRouterModelsClient client,
    DateTime now,
  ) async {
    final endpoint = Uri.parse(settings.openRouter.modelsEndpoint);
    _validateOpenRouterCatalogEndpoint(endpoint);
    final response = await client.fetchModels(
      OpenRouterModelsRequest(
        endpoint: endpoint,
        apiKey: settings.openRouter.apiKey,
      ),
    );
    db.execute('begin immediate');
    try {
      db.execute("delete from model_pricing_cache where source = 'openrouter'");
      for (final model in response.models) {
        _upsertOpenRouterModel(model, now);
      }
      db.execute('commit');
    } on Object {
      try {
        db.execute('rollback');
      } on Object {
        // Keep the original failure if SQLite already rolled back.
      }
      rethrow;
    }
  }

  bool _hasFreshOpenRouterCache(PricingSettings settings, DateTime now) {
    final cutoff = _openRouterCutoff(settings, now);
    final rows = db.select(
      '''
      select 1
      from model_pricing_cache
      where source = 'openrouter'
        and fetched_at_utc >= ?
      limit 1
      ''',
      [cutoff.toIso8601String()],
    );
    return rows.isNotEmpty;
  }

  DateTime _openRouterCutoff(PricingSettings settings, DateTime now) =>
      now.subtract(Duration(hours: settings.cachePricingHours));

  void _validateOpenRouterCatalogEndpoint(Uri endpoint) {
    if (endpoint.scheme != 'https' ||
        endpoint.host != 'openrouter.ai' ||
        endpoint.path != '/api/v1/models' ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        endpoint.userInfo.isNotEmpty) {
      throw const PricingFetchException(
        'OpenRouter catalog endpoint must be https://openrouter.ai/api/v1/models.',
      );
    }
  }

  void _upsertOpenRouterModel(OpenRouterModelPricing model, DateTime now) {
    db.execute(
      '''
      insert into model_pricing_cache (
        model_id, model_name, provider, prompt_price_per_token,
        completion_price_per_token, input_cache_read_price_per_token,
        input_cache_write_price_per_token,
        internal_reasoning_price_per_token, request_price, raw_pricing_json,
        fetched_at_utc, source
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'openrouter')
      on conflict(model_id) do update set
        model_name = excluded.model_name,
        provider = excluded.provider,
        prompt_price_per_token = excluded.prompt_price_per_token,
        completion_price_per_token = excluded.completion_price_per_token,
        input_cache_read_price_per_token =
          excluded.input_cache_read_price_per_token,
        input_cache_write_price_per_token =
          excluded.input_cache_write_price_per_token,
        internal_reasoning_price_per_token =
          excluded.internal_reasoning_price_per_token,
        request_price = excluded.request_price,
        raw_pricing_json = excluded.raw_pricing_json,
        fetched_at_utc = excluded.fetched_at_utc,
        source = excluded.source
      ''',
      [
        model.modelId,
        model.modelName,
        model.provider,
        model.promptPricePerToken,
        model.completionPricePerToken,
        model.inputCacheReadPricePerToken,
        model.inputCacheWritePricePerToken,
        model.internalReasoningPricePerToken,
        model.requestPrice,
        model.rawPricingJson,
        now.toIso8601String(),
      ],
    );
  }

  void _upsertOverrides(PricingSettings settings, DateTime now) {
    if (!settings.fallbackToOverrides) {
      return;
    }
    for (final entry in settings.overrides.entries) {
      final existing = db.select(
        'select source from model_pricing_cache where model_id = ?',
        [entry.key],
      );
      if (settings.useExternalPricing &&
          existing.isNotEmpty &&
          existing.single['source'] == 'openrouter') {
        continue;
      }
      final override = entry.value;
      db.execute(
        '''
        insert into model_pricing_cache (
          model_id, provider, prompt_price_per_token,
          completion_price_per_token, input_cache_read_price_per_token,
          input_cache_write_price_per_token,
          internal_reasoning_price_per_token, fetched_at_utc, source
        ) values (?, 'override', ?, ?, ?, ?, ?, ?, 'override')
        on conflict(model_id) do update set
          provider = excluded.provider,
          prompt_price_per_token = excluded.prompt_price_per_token,
          completion_price_per_token = excluded.completion_price_per_token,
          input_cache_read_price_per_token =
            excluded.input_cache_read_price_per_token,
          input_cache_write_price_per_token =
            excluded.input_cache_write_price_per_token,
          internal_reasoning_price_per_token =
            excluded.internal_reasoning_price_per_token,
          fetched_at_utc = excluded.fetched_at_utc,
          source = excluded.source
        ''',
        [
          entry.key,
          override.prompt,
          override.completion,
          override.inputCacheRead,
          override.inputCacheWrite,
          override.internalReasoning,
          now.toIso8601String(),
        ],
      );
    }
  }

  UsagePricingCatalog _loadCatalog(
    PricingSettings settings, {
    bool includeOpenRouter = true,
    DateTime? cutoff,
    DateTime? staleOpenRouterOverrideCutoff,
  }) {
    final where = <String>[];
    final args = <Object?>[];
    if (!includeOpenRouter) {
      where.add("source != 'openrouter'");
    }
    if (cutoff != null) {
      where.add("(source != 'openrouter' or fetched_at_utc >= ?)");
      args.add(cutoff.toIso8601String());
    }
    final rows = db.select('''
      select
        model_id, prompt_price_per_token, completion_price_per_token,
        input_cache_read_price_per_token, source, fetched_at_utc
      from model_pricing_cache
      ${where.isEmpty ? '' : 'where ${where.join(' and ')}'}
      order by case source when 'openrouter' then 0 else 1 end, model_id
      ''', args);
    final models = <String, UsageModelPricing>{};
    final staleOpenRouterModels = <String>{};
    for (final row in rows) {
      final modelId = row['model_id'] as String;
      if (staleOpenRouterOverrideCutoff != null &&
          row['source'] == 'openrouter' &&
          _isBeforeCutoff(
            row['fetched_at_utc'],
            staleOpenRouterOverrideCutoff,
          )) {
        staleOpenRouterModels.add(modelId);
      }
      models.putIfAbsent(
        modelId,
        () => UsageModelPricing(
          promptPricePerToken: row['prompt_price_per_token'] as String?,
          completionPricePerToken: row['completion_price_per_token'] as String?,
          cachedInputPricePerToken:
              row['input_cache_read_price_per_token'] as String?,
        ),
      );
    }
    if (settings.fallbackToOverrides) {
      for (final entry in settings.overrides.entries) {
        if (!models.containsKey(entry.key) ||
            staleOpenRouterModels.contains(entry.key)) {
          final override = entry.value;
          models[entry.key] = UsageModelPricing(
            promptPricePerToken: override.prompt,
            completionPricePerToken: override.completion,
            cachedInputPricePerToken: override.inputCacheRead,
          );
        }
      }
    }
    return UsagePricingCatalog(Map.unmodifiable(models));
  }

  bool _isBeforeCutoff(Object? value, DateTime cutoff) {
    if (value is! String) {
      return true;
    }
    final parsed = DateTime.tryParse(value)?.toUtc();
    return parsed == null || parsed.isBefore(cutoff);
  }

  void _recordPricingError(Object error) {
    db.execute(
      '''
      insert into logs (time_utc, level, category, message, details)
      values (?, 'error', 'pricing', 'Pricing fetch failed.', ?)
      ''',
      [DateTime.now().toUtc().toIso8601String(), error.toString()],
    );
  }
}

class PricingLoadResult {
  const PricingLoadResult._({
    required this.success,
    required this.catalog,
    this.errorMessage,
  });

  factory PricingLoadResult.success(UsagePricingCatalog catalog) =>
      PricingLoadResult._(success: true, catalog: catalog);

  factory PricingLoadResult.failure(
    UsagePricingCatalog catalog, {
    required String errorMessage,
  }) => PricingLoadResult._(
    success: false,
    catalog: catalog,
    errorMessage: errorMessage,
  );

  final bool success;
  final UsagePricingCatalog catalog;
  final String? errorMessage;
}

class OpenRouterModelsRequest {
  const OpenRouterModelsRequest({
    required this.endpoint,
    required this.apiKey,
    this.body,
  });

  final Uri endpoint;
  final String apiKey;
  final String? body;
}

abstract interface class OpenRouterModelsClient {
  Future<OpenRouterModelsResponse> fetchModels(OpenRouterModelsRequest request);
}

class OpenRouterHttpClient implements OpenRouterModelsClient {
  const OpenRouterHttpClient();

  @override
  Future<OpenRouterModelsResponse> fetchModels(
    OpenRouterModelsRequest request,
  ) async {
    final httpClient = HttpClient();
    try {
      final httpRequest = await httpClient.getUrl(request.endpoint);
      httpRequest.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (request.apiKey.trim().isNotEmpty) {
        httpRequest.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${request.apiKey}',
        );
      }
      final response = await httpRequest.close();
      final text = await utf8.decoder.bind(response).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw PricingFetchException(
          'OpenRouter returned HTTP ${response.statusCode}.',
        );
      }
      return OpenRouterModelsResponse.fromJsonText(text);
    } finally {
      httpClient.close(force: true);
    }
  }
}

class OpenRouterModelsResponse {
  const OpenRouterModelsResponse(this.models);

  factory OpenRouterModelsResponse.fromJsonText(String text) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      throw const PricingFetchException('OpenRouter catalog root is invalid.');
    }
    final data = decoded['data'];
    if (data is! List) {
      throw const PricingFetchException('OpenRouter catalog data is invalid.');
    }
    return OpenRouterModelsResponse(
      data
          .whereType<Map>()
          .map((model) => OpenRouterModelPricing.fromJson(model))
          .whereType<OpenRouterModelPricing>()
          .toList(growable: false),
    );
  }

  final List<OpenRouterModelPricing> models;
}

class OpenRouterModelPricing {
  const OpenRouterModelPricing({
    required this.modelId,
    this.modelName,
    required this.provider,
    this.promptPricePerToken,
    this.completionPricePerToken,
    this.inputCacheReadPricePerToken,
    this.inputCacheWritePricePerToken,
    this.internalReasoningPricePerToken,
    this.requestPrice,
    this.rawPricingJson,
  });

  factory OpenRouterModelPricing.fromJson(Map<Object?, Object?> json) {
    final id = _string(json['id']);
    if (id == null || id.isEmpty) {
      throw const PricingFetchException('OpenRouter model id is missing.');
    }
    final pricing = json['pricing'] is Map
        ? (json['pricing'] as Map).cast<Object?, Object?>()
        : const <Object?, Object?>{};
    return OpenRouterModelPricing(
      modelId: id,
      modelName: _string(json['name']),
      provider: _providerFromModel(id),
      promptPricePerToken: _stringOrNumber(pricing['prompt']),
      completionPricePerToken: _stringOrNumber(pricing['completion']),
      inputCacheReadPricePerToken: _stringOrNumber(pricing['input_cache_read']),
      inputCacheWritePricePerToken: _stringOrNumber(
        pricing['input_cache_write'],
      ),
      internalReasoningPricePerToken: _stringOrNumber(
        pricing['internal_reasoning'],
      ),
      requestPrice: _stringOrNumber(pricing['request']),
      rawPricingJson: jsonEncode(json),
    );
  }

  final String modelId;
  final String? modelName;
  final String provider;
  final String? promptPricePerToken;
  final String? completionPricePerToken;
  final String? inputCacheReadPricePerToken;
  final String? inputCacheWritePricePerToken;
  final String? internalReasoningPricePerToken;
  final String? requestPrice;
  final String? rawPricingJson;
}

class PricingFetchException implements Exception {
  const PricingFetchException(this.message);

  final String message;

  @override
  String toString() => message;
}

String _providerFromModel(String modelId) {
  final slash = modelId.indexOf('/');
  return slash <= 0 ? 'unknown' : modelId.substring(0, slash);
}

String? _string(Object? value) => value is String ? value : null;

String? _stringOrNumber(Object? value) {
  if (value is String) {
    return value;
  }
  if (value is num) {
    return value.toString();
  }
  return null;
}
