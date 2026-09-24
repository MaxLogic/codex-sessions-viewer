import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../config/app_settings.dart';
import '../database/maintenance_job.dart';
import '../usage/usage_summary.dart';
import 'openrouter_price_rules.dart';
import 'hub_price_history.dart';

class PricingRepository {
  const PricingRepository(this.db);

  final Database db;

  int migrateCachedHistoryNextBatch({
    required MaintenanceJobRepository jobs,
    required MaintenanceJobLease lease,
    required PricingSettings settings,
    required DateTime migrationTimeUtc,
  }) {
    final job = jobs.read(lease.jobId)!;
    final payload = job.payloadJson == null
        ? <String, dynamic>{}
        : jsonDecode(job.payloadJson!) as Map<String, dynamic>;
    if (!identical(jobs.db, db) ||
        job.jobType != 'usage_projection_migration' ||
        job.phase != 'initialize_prices' ||
        payload['backup'] is! Map ||
        db
            .select(
              '''
          select 1 from database_generations building
          where building.id = ? and building.state = 'building'
            and building.target_schema_version = 16 and exists (
              select 1 from database_state state join database_generations active
                on active.id = state.active_usage_generation_id
              where active.target_schema_version < 16)
        ''',
              [job.databaseGenerationId],
            )
            .isEmpty) {
      throw StateError(
        'Price migration requires its verified inactive-generation owner.',
      );
    }
    final cursor = payload['price_model_cursor'] as String?;
    final rows = db.select(
      '''
      select * from model_pricing_cache where source = 'openrouter'
        ${cursor == null ? '' : 'and model_id > ?'}
      order by model_id limit 512
    ''',
      [?cursor],
    );
    final localInitialized = payload['local_prices_initialized'] == true;
    if (rows.isEmpty && localInitialized) return 0;
    payload['price_migration_observed_at_utc'] ??= _priceTimestamp(
      migrationTimeUtc,
    );
    final initialTime = DateTime.parse(
      payload['price_migration_observed_at_utc'] as String,
    );
    final prior = payload['migrated_price_count'] as int? ?? 0;
    final total =
        payload['cached_price_count'] as int? ??
        db
                .select(
                  "select count(*) n from model_pricing_cache where source = 'openrouter'",
                )
                .single['n']
            as int;
    payload['cached_price_count'] = total;
    payload['migrated_price_count'] = prior + rows.length;
    payload['local_prices_initialized'] = true;
    if (rows.isNotEmpty) payload['price_model_cursor'] = rows.last['model_id'];
    jobs.commitBatch(
      lease: lease,
      phase: 'initialize_prices',
      completedUnits: job.completedUnits + rows.length,
      totalUnits: job.completedUnits - prior + total,
      lastProcessedRowId: job.lastProcessedRowId,
      statusMessage:
          'Preserving observed prices ${prior + rows.length} of $total.',
      payloadJson: jsonEncode(payload),
      apply: (_) {
        if (!localInitialized) {
          _recordLocalOverrideHistory(
            settings,
            initialTime,
            ownsTransaction: false,
          );
        }
        for (final row in rows) {
          final observed = _dateTimeUtc(row['fetched_at_utc']);
          if (observed == null) {
            throw const PricingFetchException(
              'Cached pricing observation time is invalid.',
            );
          }
          final raw = row['raw_pricing_json'] as String?;
          OpenRouterModelPricing? evidence;
          if (raw != null) {
            final parsed = jsonDecode(raw);
            if (parsed is Map && parsed['pricing'] is Map) {
              evidence = OpenRouterModelPricing.fromJson(parsed);
              if (evidence.modelId != row['model_id']) {
                throw const PricingFetchException(
                  'Cached pricing identity is inconsistent.',
                );
              }
            }
          }
          final model = OpenRouterModelPricing(
            modelId: row['model_id'] as String,
            modelName: row['model_name'] as String?,
            provider: row['provider'] as String,
            promptPricePerToken: _stringOrNumber(row['prompt_price_per_token']),
            completionPricePerToken: _stringOrNumber(
              row['completion_price_per_token'],
            ),
            inputCacheReadPricePerToken: _stringOrNumber(
              row['input_cache_read_price_per_token'],
            ),
            inputCacheWritePricePerToken: _stringOrNumber(
              row['input_cache_write_price_per_token'],
            ),
            internalReasoningPricePerToken: _stringOrNumber(
              row['internal_reasoning_price_per_token'],
            ),
            requestPrice: _stringOrNumber(row['request_price']),
            imagePrice: evidence?.imagePrice,
            webSearchPrice: evidence?.webSearchPrice,
            canonicalSlug: evidence?.canonicalSlug,
            additionalRates: evidence?.additionalRates ?? const {},
            rules: evidence?.rules ?? const [],
            rawPricingJson: raw,
          );
          _recordCatalogHistory(
            OpenRouterModelsResponse([model]),
            started: observed,
            observed: observed,
          );
        }
      },
    );
    return rows.length;
  }

  HistoricalUsageCost resolveHistoricalUsageCost({
    required PricingSettings settings,
    required DateTime occurredAtUtc,
    required String? model,
    required int inputTokens,
    required int cachedInputTokens,
    required int cacheWriteInputTokens,
    required int outputTokens,
    required int reasoningOutputTokens,
  }) {
    if (model == null || model.isEmpty) return const HistoricalUsageCost();
    final at = occurredAtUtc.toUtc();
    final keys = [
      model,
      if (model.startsWith('gpt-') && !model.contains('/')) 'openai/$model',
    ];
    Row? period;
    var provider = false;
    var method = 'unknown';
    for (final useProvider in [true, false]) {
      if (useProvider && !settings.useExternalPricing) continue;
      if (!useProvider &&
          settings.useExternalPricing &&
          !settings.fallbackToOverrides) {
        continue;
      }
      for (final key in keys) {
        final canonicalSource =
            useProvider && PriceObservationStore(db).available
            ? db.select(
                '''select source from price_history_model_sources
                 where revision = (select revision from price_history_state where id = 1)
                   and model_id = ?''',
                [key],
              )
            : const <Row>[];
        final rows = db.select(
          '''
          select * from ${useProvider ? 'model_price_periods' : 'local_price_override_periods'}
          where ${useProvider ? "source in ('openrouter', ?) and" : ''}
            model_id = ? and valid_from_utc <= ?
          order by ${useProvider ? "case when source = 'openrouter' then 1 else 0 end," : ''} valid_from_utc desc limit 1
        ''',
          [
            if (useProvider)
              canonicalSource.isEmpty
                  ? 'openrouter'
                  : canonicalSource.single['source'],
            key,
            _priceTimestamp(at),
          ],
        );
        if (rows.isEmpty) continue;
        final row = rows.single;
        if (useProvider &&
            (jsonDecode(row['raw_pricing_json'] as String) as Map)['removed'] ==
                true) {
          continue;
        }
        final end = _dateTimeUtc(row['valid_to_utc']);
        if (end != null && !at.isBefore(end)) continue;
        period = row;
        provider = useProvider;
        method =
            '${useProvider ? 'openrouter' : 'local'}_${key == model ? 'exact' : 'openai_exact'}';
        break;
      }
      if (period != null) break;
    }
    if (period == null) return const HistoricalUsageCost();
    final rates = <String, String?>{
      for (final entry in _priceColumns.entries)
        entry.key: period[entry.value] as String?,
    };
    final additional = provider
        ? (jsonDecode(period['additional_prices_json'] as String) as Map)
              .cast<String, String>()
        : <String, String>{};
    final ruleIds = <int>[];
    if (provider) {
      final rules = db.select(
        '''
        select * from provider_price_rules where price_period_id = ?
        order by provider_order
      ''',
        [period['id']],
      );
      for (final row in rules) {
        final rule = OpenRouterPriceRule(
          providerOrder: row['provider_order'] as int,
          minPromptTokens: row['prompt_tokens_min'] as int?,
          utcStartMinute: row['utc_start_minute'] as int?,
          utcEndMinute: row['utc_end_minute'] as int?,
          utcWeekdays: row['utc_weekdays'] == null
              ? null
              : (jsonDecode(row['utc_weekdays'] as String) as List)
                    .cast<int>()
                    .toSet(),
          rateOverrides: const {},
          rawRuleJson: row['raw_rule_json'] as String,
        );
        if (!rule.matches(promptTokens: inputTokens, occurredAtUtc: at)) {
          continue;
        }
        ruleIds.add(row['id'] as int);
        for (final entry in _priceColumns.entries) {
          final override = row[entry.value] as String?;
          if (override != null) rates[entry.key] = override;
        }
        additional.addAll(
          (jsonDecode(row['additional_prices_json'] as String) as Map)
              .cast<String, String>(),
        );
      }
    }
    final estimate = estimateUsageCost(
      inputTokens: inputTokens,
      cachedInputTokens: cachedInputTokens,
      cacheWriteInputTokens: cacheWriteInputTokens,
      outputTokens: outputTokens,
      reasoningOutputTokens: reasoningOutputTokens,
      model: model,
      pricing: UsagePricingCatalog({
        model: UsageModelPricing(
          promptPricePerToken: rates['prompt'],
          completionPricePerToken: rates['completion'],
          cachedInputPricePerToken: rates['input_cache_read'],
          cacheWriteInputPricePerToken: rates['input_cache_write'],
          internalReasoningPricePerToken: rates['internal_reasoning'],
        ),
      }),
    );
    final excluded = [
      rates['request'],
      rates['image'],
      rates['web_search'],
      ...additional.values,
    ].any((rate) => rate != null && rate != '0');
    return HistoricalUsageCost(
      estimatedCostText: estimate.estimatedCostText,
      costStatus: estimate.costUnknown
          ? 'unknown'
          : excluded
          ? 'partial_unsupported_units'
          : 'complete',
      providerPricePeriodId: provider ? period['id'] as int : null,
      providerRuleIds: List.unmodifiable(ruleIds),
      localOverridePeriodId: provider ? null : period['id'] as int,
      catalogSnapshotId: provider ? period['first_snapshot_id'] as int : null,
      resolutionMethod: method,
    );
  }

  Future<PricingLoadResult> load(
    PricingSettings settings, {
    OpenRouterModelsClient? client,
    DateTime? nowUtc,
  }) async {
    final now = (nowUtc ?? DateTime.now().toUtc()).toUtc();
    final cutoff = settings.useExternalPricing
        ? _openRouterCutoff(settings, now)
        : null;
    try {
      _upsertOverrides(settings, now);
      if (!settings.useExternalPricing) {
        return PricingLoadResult.success(
          _loadCatalog(settings, includeOpenRouter: false),
        );
      }
      if (_hasFreshOpenRouterCache(settings, now)) {
        return PricingLoadResult.success(
          _loadCatalog(settings, cutoff: cutoff),
        );
      }
      await _fetchAndCache(
        settings,
        client ?? const OpenRouterHttpClient(),
        now,
        observationTimeOverride: nowUtc,
      );
      return PricingLoadResult.success(_loadCatalog(settings, cutoff: cutoff));
    } on Object catch (error) {
      _recordPricingError(error);
      return PricingLoadResult.failure(
        _loadCatalog(
          settings,
          includeOpenRouter: settings.useExternalPricing,
          staleOpenRouterOverrideCutoff: cutoff,
        ),
        errorMessage: _safePricingError(error),
      );
    }
  }

  Future<PricingLoadResult> refresh(
    PricingSettings settings, {
    OpenRouterModelsClient? client,
    DateTime? nowUtc,
  }) async {
    final now = (nowUtc ?? DateTime.now().toUtc()).toUtc();
    final cutoff = settings.useExternalPricing
        ? _openRouterCutoff(settings, now)
        : null;
    try {
      _upsertOverrides(settings, now);
      if (!settings.useExternalPricing) {
        return PricingLoadResult.success(
          _loadCatalog(settings, includeOpenRouter: false),
        );
      }
      await _fetchAndCache(
        settings,
        client ?? const OpenRouterHttpClient(),
        now,
        observationTimeOverride: nowUtc,
      );
      return PricingLoadResult.success(_loadCatalog(settings, cutoff: cutoff));
    } on Object catch (error) {
      _recordPricingError(error);
      return PricingLoadResult.failure(
        _loadCatalog(
          settings,
          includeOpenRouter: settings.useExternalPricing,
          staleOpenRouterOverrideCutoff: cutoff,
        ),
        errorMessage: _safePricingError(error),
      );
    }
  }

  UsagePricingCatalog loadCached(PricingSettings settings, {DateTime? nowUtc}) {
    final now = (nowUtc ?? DateTime.now().toUtc()).toUtc();
    if (!settings.useExternalPricing) {
      return _loadCatalog(settings, includeOpenRouter: false);
    }
    return _loadCatalog(settings, cutoff: _openRouterCutoff(settings, now));
  }

  /// Synchronize local history and cost policy without making a network request.
  void synchronizeSettings(PricingSettings settings, {DateTime? nowUtc}) =>
      _upsertOverrides(settings, (nowUtc ?? DateTime.now()).toUtc());

  /// Apply a fully downloaded catalog while the application owns the writer.
  void applyCatalog(
    OpenRouterModelsResponse response, {
    required DateTime startedAtUtc,
    required DateTime observedAtUtc,
    String origin = 'local',
  }) {
    response.validateComplete();
    db.execute('begin immediate');
    try {
      if (_hasPriceHistory) {
        _recordCatalogHistory(
          response,
          started: startedAtUtc.toUtc(),
          observed: observedAtUtc.toUtc(),
        );
      } else {
        db.execute(
          "delete from model_pricing_cache where source = 'openrouter'",
        );
      }
      for (final model in response.models) {
        _upsertOpenRouterModel(model, observedAtUtc.toUtc());
      }
      final observations = PriceObservationStore(db);
      if (observations.available) {
        for (final model in response.models) {
          observations.insert(
            PriceObservation(
              origin: origin,
              authority: 'local',
              observedAtUtc: observedAtUtc,
              provider: model.provider,
              modelId: model.modelId,
              model: _modelObservationJson(model),
            ),
          );
        }
        if (response.declaredTotalCount != null) {
          final present = response.models.map((model) => model.modelId).toSet();
          for (final row in db.select(
            "select model_id, provider from model_price_periods where source = 'openrouter' and valid_to_utc = ?",
            [_priceTimestamp(observedAtUtc)],
          )) {
            if (!present.contains(row['model_id'])) {
              observations.insert(
                _removedPriceObservation(
                  row['model_id'] as String,
                  row['provider'] as String,
                  observedAtUtc,
                  origin,
                ),
              );
            }
          }
        }
        if (db
            .select(
              "select 1 from price_observations where authority = 'hub' limit 1",
            )
            .isNotEmpty) {
          _materializeCanonicalHistory();
        }
      }
      db.execute('commit');
    } on Object {
      if (!db.autocommit) db.execute('rollback');
      rethrow;
    }
  }

  void recordCatalogFailure({
    required DateTime startedAtUtc,
    DateTime? nowUtc,
  }) {
    if (!_hasPriceHistory) return;
    db.execute(
      '''
      insert into price_catalog_snapshots (
        source, started_at_utc, finished_at_utc, status,
        completeness_status, error_message)
      values ('openrouter', ?, ?, 'failed', 'failed', 'Catalog refresh failed.')
    ''',
      [
        startedAtUtc.toUtc().toIso8601String(),
        (nowUtc ?? DateTime.now()).toUtc().toIso8601String(),
      ],
    );
  }

  /// Called under the application writer. Observations and the active revision
  /// commit together; existing cost rows keep their immutable snapshot FKs.
  String mergePriceObservations(
    Iterable<PriceObservation> incoming, {
    String? hubUrl,
    int? through,
    String? hubRevision,
    Map<String, DateTime> confirmations = const {},
    int? confirmationSeq,
  }) {
    final store = PriceObservationStore(db);
    if (!store.available) {
      throw StateError('Price-history migration is required.');
    }
    final validated = incoming.toList();
    for (final observation in validated) {
      final model = OpenRouterModelPricing.fromJson(observation.model);
      if (model.provider != observation.provider) {
        throw const FormatException('Price observation provider mismatch.');
      }
    }
    db.execute('begin immediate');
    try {
      final existingIds = db
          .select('select fingerprint from price_observations')
          .map((row) => row['fingerprint'])
          .toSet();
      for (final observation in validated) {
        if (!existingIds.contains(observation.fingerprint)) {
          store.insert(observation);
        }
      }
      _importLegacyPriceObservations();
      final hubFingerprints = {
        for (final item in validated)
          if (item.authority == 'hub') item.fingerprint,
      };
      for (final entry in confirmations.entries) {
        // Only hub evidence can be confirmed by a hub catalog.
        if (hubFingerprints.contains(entry.key)) {
          store.confirm(entry.key, entry.value);
        }
      }
      final revision = _materializeCanonicalHistory();
      if (hubUrl != null) {
        if (through == null ||
            hubRevision == null ||
            CanonicalPriceHistory(validated).revision != hubRevision) {
          throw const FormatException('Invalid acknowledged hub snapshot.');
        }
        final existingMembers = db
            .select(
              'select fingerprint from price_hub_membership where hub_url = ?',
              [hubUrl],
            )
            .map((row) => row['fingerprint'])
            .toSet();
        final incomingIds = validated.map((item) => item.fingerprint).toSet();
        for (final removed in existingMembers.difference(incomingIds)) {
          db.execute(
            'delete from price_hub_membership where hub_url = ? and fingerprint = ?',
            [hubUrl, removed],
          );
        }
        for (final observation in validated) {
          if (!existingMembers.contains(observation.fingerprint)) {
            db.execute(
              'insert into price_hub_membership(hub_url,fingerprint) values (?,?)',
              [hubUrl, observation.fingerprint],
            );
          }
        }
        db.execute(
          '''insert into price_hub_sync_state(hub_url,through_rowid,revision) values (?,?,?)
          on conflict(hub_url) do update set through_rowid=excluded.through_rowid,revision=excluded.revision''',
          [hubUrl, through, hubRevision],
        );
        if (confirmationSeq != null && store.confirmationsAvailable) {
          db.execute(
            'update price_hub_sync_state set confirmation_seq = ? where hub_url = ?',
            [confirmationSeq, hubUrl],
          );
        }
      }
      db.execute('commit');
      return revision;
    } on Object {
      if (!db.autocommit) db.execute('rollback');
      rethrow;
    }
  }

  HubPriceSyncResult hubSyncSnapshot(String url) {
    final state = db.select(
      'select through_rowid,revision from price_hub_sync_state where hub_url = ?',
      [url],
    );
    if (state.isEmpty) return const HubPriceSyncResult([], 0, '');
    final observations = db
        .select(
          '''select o.payload_json from price_hub_membership m
      join price_observations o on o.fingerprint=m.fingerprint where m.hub_url=?''',
          [url],
        )
        .map(
          (row) => PriceObservation.fromJson(
            jsonDecode(row['payload_json'] as String) as Map<String, dynamic>,
          ),
        )
        .toList();
    final confirmationSeq = PriceObservationStore(db).confirmationsAvailable
        ? db.select(
                'select confirmation_seq from price_hub_sync_state where hub_url = ?',
                [url],
              ).single['confirmation_seq']
              as int
        : 0;
    return HubPriceSyncResult(
      observations,
      state.single['through_rowid'] as int,
      state.single['revision'] as String,
      confirmationSeq: confirmationSeq,
    );
  }

  List<PriceObservation> localPriceObservationsForHub(String origin) {
    final store = PriceObservationStore(db);
    if (!store.available) return const [];
    db.execute('begin immediate');
    try {
      _importLegacyPriceObservations();
      for (final item in store.read()) {
        if (item.authority == 'local' &&
            ['local', 'legacy-local'].contains(item.origin)) {
          store.insert(
            PriceObservation(
              origin: origin,
              authority: 'local',
              observedAtUtc: item.observedAtUtc,
              provider: item.provider,
              modelId: item.modelId,
              model: item.model,
            ),
          );
        }
      }
      final result = store
          .read()
          .where((item) => item.authority == 'local' && item.origin == origin)
          .toList();
      db.execute('commit');
      return result;
    } on Object {
      if (!db.autocommit) db.execute('rollback');
      rethrow;
    }
  }

  void _importLegacyPriceObservations() {
    if (db
        .select(
          "select 1 from app_metadata where key = 'price_observations_backfilled'",
        )
        .isNotEmpty) {
      return;
    }
    final store = PriceObservationStore(db);
    for (final row in db.select(
      "select * from model_price_periods where source = 'openrouter' order by id",
    )) {
      final ruleJson = db.select(
        'select raw_rule_json from provider_price_rules where price_period_id = ? order by provider_order',
        [row['id']],
      );
      final model = OpenRouterModelPricing(
        modelId: row['model_id'] as String,
        provider: row['provider'] as String,
        modelName: row['model_name'] as String?,
        canonicalSlug: row['canonical_slug'] as String?,
        promptPricePerToken: row['prompt_price_per_token'] as String?,
        completionPricePerToken: row['completion_price_per_token'] as String?,
        inputCacheReadPricePerToken:
            row['input_cache_read_price_per_token'] as String?,
        inputCacheWritePricePerToken:
            row['input_cache_write_price_per_token'] as String?,
        internalReasoningPricePerToken:
            row['internal_reasoning_price_per_token'] as String?,
        requestPrice: row['request_price'] as String?,
        imagePrice: row['image_price'] as String?,
        webSearchPrice: row['web_search_price'] as String?,
        additionalRates:
            (jsonDecode(row['additional_prices_json'] as String) as Map)
                .cast<String, String>(),
        rules: parseOpenRouterPriceRules([
          for (final rule in ruleJson)
            jsonDecode(rule['raw_rule_json'] as String),
        ]),
        rawPricingJson: row['raw_pricing_json'] as String,
      );
      store.insert(
        PriceObservation(
          origin: 'legacy-local',
          authority: 'local',
          observedAtUtc: DateTime.parse(row['valid_from_utc'] as String),
          provider: model.provider,
          modelId: model.modelId,
          model: _modelObservationJson(model),
        ),
      );
      if (row['valid_to_utc'] != null &&
          db.select(
            "select 1 from model_price_periods where source = 'openrouter' and model_id = ? and valid_from_utc = ?",
            [model.modelId, row['valid_to_utc']],
          ).isEmpty) {
        store.insert(
          _removedPriceObservation(
            model.modelId,
            model.provider,
            DateTime.parse(row['valid_to_utc'] as String),
            'legacy-local',
          ),
        );
      }
    }
    db.execute(
      "insert into app_metadata(key,value,updated_at_utc) values ('price_observations_backfilled','1',?)",
      [DateTime.now().toUtc().toIso8601String()],
    );
  }

  String _materializeCanonicalHistory() {
    final store = PriceObservationStore(db);
    final history = CanonicalPriceHistory(
      store.read(),
      confirmations: store.readConfirmations(),
    );
    final previous = db
        .select('select revision from price_history_state where id = 1')
        .single['revision'];
    if (previous == history.materializedRevision) {
      return history.materializedRevision;
    }
    db.execute(
      '''insert or ignore into price_history_revisions
      (revision, observations_json, created_at_utc) values (?, ?, ?)''',
      [
        history.materializedRevision,
        canonicalPriceJson({
          'through_rowid': db
              .select('select coalesce(max(rowid),0) n from price_observations')
              .single['n'],
        }),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    final models = <String, List<PriceObservation>>{};
    for (final observation in history.winners) {
      models.putIfAbsent(observation.modelId, () => []).add(observation);
    }
    for (final entry in models.entries) {
      // Repeated unchanged fetches belong in the evidence log, not in another
      // full copy of every model's periods and snapshots.
      final effective = <PriceObservation>[];
      String? lastPrices;
      for (final item in entry.value) {
        final prices = priceFingerprint({
          'pricing': item.model['pricing'],
          'canonical_slug': item.model['canonical_slug'],
          'removed': item.model['removed'] == true,
        });
        if (prices != lastPrices) effective.add(item);
        lastPrices = prices;
      }
      final source =
          'canonical:${priceFingerprint(effective.map((o) => {'observed_at_utc': priceObservationTimestamp(o.observedAtUtc), 'pricing': o.model['pricing'], 'model_id': o.modelId, 'canonical_slug': o.model['canonical_slug'], 'removed': o.model['removed'] == true}).toList())}';
      final prior = db.select(
        'select source from price_history_model_sources where revision = ? and model_id = ?',
        [previous, entry.key],
      );
      if (db.select(
        'select 1 from model_price_periods where source = ? limit 1',
        [source],
      ).isEmpty) {
        for (final observation in effective) {
          _recordCatalogHistory(
            OpenRouterModelsResponse([
              OpenRouterModelPricing.fromJson(observation.model),
            ]),
            started: observation.observedAtUtc,
            observed: observation.observedAtUtc,
            source: source,
            canonicalRevision: history.materializedRevision,
            markDirty: false,
          );
        }
      }
      db.execute(
        '''insert or ignore into price_history_model_sources
        (revision, model_id, source) values (?, ?, ?)''',
        [history.materializedRevision, entry.key, source],
      );
      if (prior.isEmpty || prior.single['source'] != source) {
        _markChangedPriceIntervals(
          entry.key,
          prior.isEmpty ? 'openrouter' : prior.single['source'] as String,
          source,
        );
      }
      final latest = entry.value.last;
      if (latest.model['removed'] == true) {
        db.execute(
          "delete from model_pricing_cache where model_id = ? and source = 'openrouter'",
          [entry.key],
        );
      } else {
        _upsertOpenRouterModel(
          OpenRouterModelPricing.fromJson(latest.model),
          latest.observedAtUtc,
        );
      }
    }
    db.execute('update price_history_state set revision = ? where id = 1', [
      history.materializedRevision,
    ]);
    return history.materializedRevision;
  }

  void _markChangedPriceIntervals(
    String model,
    String oldSource,
    String newSource,
  ) {
    final old = db.select(
      'select * from model_price_periods where source = ? and model_id = ? order by valid_from_utc',
      [oldSource, model],
    );
    final current = db.select(
      'select * from model_price_periods where source = ? and model_id = ? order by valid_from_utc',
      [newSource, model],
    );
    final boundaries = <DateTime>{};
    for (final row in [...old, ...current]) {
      boundaries.add(DateTime.parse(row['valid_from_utc'] as String));
      if (row['valid_to_utc'] != null) {
        boundaries.add(DateTime.parse(row['valid_to_utc'] as String));
      }
    }
    String? fingerprint(List<Row> rows, DateTime at) {
      for (final row in rows.reversed) {
        final start = DateTime.parse(row['valid_from_utc'] as String);
        final end = row['valid_to_utc'] == null
            ? null
            : DateTime.parse(row['valid_to_utc'] as String);
        if (!at.isBefore(start) && (end == null || at.isBefore(end))) {
          return row['pricing_fingerprint'] as String;
        }
      }
      return null;
    }

    final ordered = boundaries.toList()..sort();
    for (var index = 0; index < ordered.length; index++) {
      final start = ordered[index];
      final before = fingerprint(old, start);
      // Legacy observed history remains applicable before canonical evidence.
      final after = fingerprint(current, start) ?? fingerprint(old, start);
      if (before != after) {
        _markModelCostsDirty(
          model,
          start,
          until: index + 1 < ordered.length ? ordered[index + 1] : null,
        );
      }
    }
  }

  Future<void> _fetchAndCache(
    PricingSettings settings,
    OpenRouterModelsClient client,
    DateTime now, {
    DateTime? observationTimeOverride,
  }) async {
    final endpoint = Uri.parse(settings.openRouter.modelsEndpoint);
    _validateOpenRouterCatalogEndpoint(endpoint);
    try {
      final response = await client.fetchModels(
        OpenRouterModelsRequest(
          endpoint: endpoint,
          apiKey: settings.openRouter.apiKey,
        ),
      );
      final observed = (observationTimeOverride ?? DateTime.now()).toUtc();
      applyCatalog(response, startedAtUtc: now, observedAtUtc: observed);
    } on Object {
      try {
        recordCatalogFailure(
          startedAtUtc: now,
          nowUtc: observationTimeOverride,
        );
      } on Object {
        // Preserve the original failure when the diagnostic write also fails.
      }
      rethrow;
    }
  }

  bool get _hasPriceHistory => db
      .select(
        "select 1 from sqlite_schema where type = 'table' and name = 'model_price_periods'",
      )
      .isNotEmpty;

  void _recordCatalogHistory(
    OpenRouterModelsResponse response, {
    required DateTime started,
    required DateTime observed,
    String source = 'openrouter',
    String? canonicalRevision,
    bool markDirty = true,
  }) {
    final stamp = _priceTimestamp(observed);
    db.execute(
      '''
      insert into price_catalog_snapshots (
        source, started_at_utc, finished_at_utc, status, model_count,
        page_count, completeness_status, declared_total_count, payload_sha256)
      values (?, ?, ?, 'succeeded', ?, ?, ?, ?, ?)
    ''',
      [
        source,
        started.toIso8601String(),
        stamp,
        response.models.length,
        response.pageCount,
        response.declaredTotalCount == null
            ? 'complete_for_updates'
            : 'complete_for_removals',
        response.declaredTotalCount,
        response.payloadSha256,
      ],
    );
    final snapshotId = db.lastInsertRowId;
    if (canonicalRevision != null) {
      db.execute(
        'update price_catalog_snapshots set canonical_revision = ? where id = ?',
        [canonicalRevision, snapshotId],
      );
    }
    // Reuse SQLite's monotonic snapshot identity instead of scanning all prior
    // catalog generations for every imported cache observation.
    db.execute(
      'update price_catalog_snapshots set catalog_generation = id where id = ?',
      [snapshotId],
    );
    for (final model in response.models) {
      final prices =
          [
                model.promptPricePerToken,
                model.completionPricePerToken,
                model.inputCacheReadPricePerToken,
                model.inputCacheWritePricePerToken,
                model.internalReasoningPricePerToken,
                model.requestPrice,
                model.imagePrice,
                model.webSearchPrice,
              ]
              .map((value) {
                if (value == null) return null;
                // Reuse the existing BigInt decimal normalization; no floating point.
                final normalized = sumEstimatedCostTexts([value]);
                if (normalized == null || normalized.startsWith('-')) {
                  throw const PricingFetchException(
                    'Catalog contains an invalid decimal price.',
                  );
                }
                return normalized;
              })
              .toList(growable: false);
      final fingerprint = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                prices,
                model.canonicalSlug,
                model.rawPricingJson != null &&
                    (jsonDecode(model.rawPricingJson!) as Map)['removed'] ==
                        true,
                {
                  for (final key in model.additionalRates.keys.toList()..sort())
                    key: model.additionalRates[key],
                },
                model.rules.map(_normalizedRule).toList(growable: false),
              ]),
            ),
          )
          .toString();
      final current = db.select(
        '''
        select id, pricing_fingerprint from model_price_periods
        where source = ? and model_id = ? and valid_to_utc is null
      ''',
        [source, model.modelId],
      );
      if (current.isNotEmpty &&
          current.single['pricing_fingerprint'] == fingerprint) {
        db.execute(
          'update model_price_periods set last_seen_snapshot_id = ? where id = ?',
          [snapshotId, current.single['id']],
        );
        continue;
      }
      if (current.isNotEmpty) {
        db.execute(
          'update model_price_periods set valid_to_utc = ? where id = ?',
          [stamp, current.single['id']],
        );
      }
      db.execute(
        '''
        insert into model_price_periods (
          source, model_id, model_name, provider, prompt_price_per_token,
          completion_price_per_token, input_cache_read_price_per_token,
          input_cache_write_price_per_token, internal_reasoning_price_per_token,
          request_price, image_price, web_search_price, canonical_slug, additional_prices_json,
          pricing_fingerprint, raw_pricing_json, valid_from_utc,
          first_snapshot_id, last_seen_snapshot_id)
        values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
        [
          source,
          model.modelId,
          model.modelName,
          model.provider,
          ...prices,
          model.canonicalSlug,
          jsonEncode(model.additionalRates),
          fingerprint,
          model.rawPricingJson ??
              jsonEncode({'id': model.modelId, 'prices': prices}),
          stamp,
          snapshotId,
          snapshotId,
        ],
      );
      final periodId = db.lastInsertRowId;
      for (final rule in model.rules) {
        db.execute(
          '''
          insert into provider_price_rules (
            price_period_id, provider_order, prompt_tokens_min,
            utc_start_minute, utc_end_minute, utc_weekdays,
            prompt_price_per_token, completion_price_per_token,
            input_cache_read_price_per_token, input_cache_write_price_per_token,
            internal_reasoning_price_per_token, request_price,
            image_price, web_search_price, additional_prices_json, pricing_fingerprint, raw_rule_json)
          values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
          [
            periodId,
            rule.providerOrder,
            rule.minPromptTokens,
            rule.utcStartMinute,
            rule.utcEndMinute,
            rule.utcWeekdays == null
                ? null
                : jsonEncode(rule.utcWeekdays!.toList()..sort()),
            for (final key in _storedPriceKeys) rule.rateOverrides[key],
            jsonEncode({
              for (final entry in rule.rateOverrides.entries)
                if (!_storedPriceKeys.contains(entry.key))
                  entry.key: entry.value,
            }),
            sha256
                .convert(utf8.encode(jsonEncode(_normalizedRule(rule))))
                .toString(),
            rule.rawRuleJson,
          ],
        );
      }
      if (markDirty) _markModelCostsDirty(model.modelId, observed);
    }
    if (response.declaredTotalCount != null) {
      var cursor = 0;
      while (true) {
        final absent = db.select(
          '''
          select id, model_id from model_price_periods
          where source = 'openrouter' and valid_to_utc is null
            and last_seen_snapshot_id <> ? and id > ?
          order by id limit 512
        ''',
          [snapshotId, cursor],
        );
        if (absent.isEmpty) break;
        for (final row in absent) {
          db.execute(
            'update model_price_periods set valid_to_utc = ? where id = ?',
            [stamp, row['id']],
          );
          db.execute(
            "delete from model_pricing_cache where source = 'openrouter' and model_id = ?",
            [row['model_id']],
          );
          _markModelCostsDirty(row['model_id'] as String, observed);
        }
        cursor = absent.last['id'] as int;
      }
    }
  }

  void _markModelCostsDirty(
    String modelId,
    DateTime observed, {
    DateTime? until,
  }) {
    final keys = [
      modelId,
      if (modelId.startsWith('openai/gpt-')) modelId.substring(7),
    ];
    final stamp = _priceTimestamp(observed);
    var cursor = 0;
    while (true) {
      final partitions = db.select(
        '''
        select id, session_id, day_utc, model_key from usage_session_daily
        where id > ? and day_utc >= ?
          and model_key in (${List.filled(keys.length, '?').join(', ')})
        order by id limit 512
      ''',
        [cursor, stamp.substring(0, 10), ...keys],
      );
      if (partitions.isEmpty) return;
      for (final partition in partitions) {
        if (!_partitionHasEventAtOrAfter(partition, observed, until: until)) {
          continue;
        }
        db.execute(
          '''
          insert into usage_cost_dirty_partitions (
            session_id, day_utc, model_key, reason, target_cost_projection_version,
            created_at_utc, updated_at_utc)
          values (?, ?, ?, 'price_history', $usageCostProjectionVersion, ?, ?)
          on conflict(session_id, day_utc, model_key) do update set
            target_cost_projection_version = max(usage_cost_dirty_partitions.target_cost_projection_version,
              excluded.target_cost_projection_version),
            updated_at_utc = excluded.updated_at_utc
        ''',
          [
            partition['session_id'],
            partition['day_utc'],
            partition['model_key'],
            stamp,
            stamp,
          ],
        );
      }
      cursor = partitions.last['id'] as int;
    }
  }

  bool _partitionHasEventAtOrAfter(
    Row partition,
    DateTime observed, {
    DateTime? until,
  }) {
    var ordinal = -1;
    while (true) {
      final events = db.select(
        '''
        select source_record_ordinal, occurred_at_utc from usage_events
        where session_row_id = ? and source_record_ordinal > ?
          and coalesce(model, '') = ?
          and strftime('%Y-%m-%d', occurred_at_utc) = ?
        order by source_record_ordinal limit 512
      ''',
        [
          partition['session_id'],
          ordinal,
          partition['model_key'],
          partition['day_utc'],
        ],
      );
      if (events.isEmpty) return false;
      for (final event in events) {
        // SQLite Julian-day comparisons lose sub-millisecond precision. Keep
        // exact UTC ordering, including imported offset timestamps, in Dart.
        final raw = event['occurred_at_utc'] as String?;
        final at = raw == null ? null : DateTime.tryParse(raw)?.toUtc();
        if (at != null &&
            !at.isBefore(observed) &&
            (until == null || at.isBefore(until))) {
          return true;
        }
      }
      ordinal = events.last['source_record_ordinal'] as int;
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
    _validateCatalogUri(endpoint, continuation: false);
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
    if (_hasPriceHistory) {
      _recordLocalOverrideHistory(settings, now);
      return;
    }
    if (!settings.fallbackToOverrides) {
      return;
    }
    final pending = <MapEntry<String, PricingOverrideSettings>>[];
    for (final entry in settings.overrides.entries) {
      final existing = db.select(
        '''
        select
          source,
          prompt_price_per_token,
          completion_price_per_token,
          input_cache_read_price_per_token,
          input_cache_write_price_per_token,
          internal_reasoning_price_per_token
        from model_pricing_cache
        where model_id = ?
        ''',
        [entry.key],
      );
      if (settings.useExternalPricing &&
          existing.isNotEmpty &&
          existing.single['source'] == 'openrouter') {
        continue;
      }
      final override = entry.value;
      if (existing.isNotEmpty &&
          existing.single['source'] == 'override' &&
          existing.single['prompt_price_per_token'] == override.prompt &&
          existing.single['completion_price_per_token'] ==
              override.completion &&
          existing.single['input_cache_read_price_per_token'] ==
              override.inputCacheRead &&
          existing.single['input_cache_write_price_per_token'] ==
              override.inputCacheWrite &&
          existing.single['internal_reasoning_price_per_token'] ==
              override.internalReasoning) {
        continue;
      }
      pending.add(entry);
    }
    if (pending.isEmpty) {
      return;
    }

    db.execute('begin immediate');
    try {
      final statement = db.prepare('''
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
        ''');
      try {
        for (final entry in pending) {
          if (settings.useExternalPricing) {
            final current = db.select(
              'select source from model_pricing_cache where model_id = ?',
              [entry.key],
            );
            if (current.isNotEmpty &&
                current.single['source'] == 'openrouter') {
              continue;
            }
          }
          final override = entry.value;
          statement.execute([
            entry.key,
            override.prompt,
            override.completion,
            override.inputCacheRead,
            override.inputCacheWrite,
            override.internalReasoning,
            now.toIso8601String(),
          ]);
        }
      } finally {
        statement.close();
      }
      db.execute('commit');
    } on Object {
      try {
        db.execute('rollback');
      } on Object {
        // Preserve the original failure if SQLite already rolled back.
      }
      rethrow;
    }
  }

  void _recordLocalOverrideHistory(
    PricingSettings settings,
    DateTime observed, {
    bool ownsTransaction = true,
  }) {
    final stamp = _priceTimestamp(observed);
    if (ownsTransaction) {
      db.execute('begin immediate');
    } else if (db.autocommit) {
      throw StateError('Price history requires the caller transaction.');
    }
    try {
      final policy = jsonEncode([
        usageCostProjectionVersion,
        settings.useExternalPricing,
        settings.fallbackToOverrides,
      ]);
      final previousPolicy = db
          .select('select pricing_policy_json from database_state where id = 1')
          .single['pricing_policy_json'];
      if (previousPolicy != policy) {
        // Native INSERT SELECT keeps invalidation out of Dart memory. Policy
        // and algorithm changes invalidate all bases in this same transaction.
        db.execute(
          '''
          insert into usage_cost_dirty_partitions (session_id, day_utc, model_key,
            reason, target_cost_projection_version, created_at_utc, updated_at_utc)
          select session_id, day_utc, model_key, 'pricing_policy',
            max(cost_projection_version, $usageCostProjectionVersion), ?, ?
          from usage_session_daily where true
          on conflict(session_id, day_utc, model_key) do update set
            target_cost_projection_version = max(usage_cost_dirty_partitions.target_cost_projection_version,
              excluded.target_cost_projection_version),
            reason = excluded.reason, updated_at_utc = excluded.updated_at_utc
        ''',
          [stamp, stamp],
        );
        db.execute(
          'update database_state set pricing_policy_json = ? where id = 1',
          [policy],
        );
      }
      final revision =
          db.select('''
        update database_state set pricing_settings_revision = pricing_settings_revision + 1
        where id = 1 returning pricing_settings_revision
      ''').single['pricing_settings_revision']
              as int;
      for (final entry in settings.overrides.entries) {
        final override = entry.value;
        final rates =
            [
                  override.prompt,
                  override.completion,
                  override.inputCacheRead,
                  override.inputCacheWrite,
                  override.internalReasoning,
                ]
                .map((value) {
                  final normalized = sumEstimatedCostTexts([value]);
                  if (normalized == null || normalized.startsWith('-')) {
                    throw const PricingFetchException(
                      'Local override decimal price is invalid.',
                    );
                  }
                  return normalized;
                })
                .toList(growable: false);
        final fingerprint = sha256
            .convert(utf8.encode(jsonEncode(rates)))
            .toString();
        final current = db.select(
          '''
          select id, settings_fingerprint from local_price_override_periods
          where model_id = ? and valid_to_utc is null
        ''',
          [entry.key],
        );
        if (current.isNotEmpty &&
            current.single['settings_fingerprint'] == fingerprint) {
          db.execute(
            'update local_price_override_periods set last_seen_settings_revision = ? where id = ?',
            [revision, current.single['id']],
          );
          continue;
        }
        if (current.isNotEmpty) {
          db.execute(
            'update local_price_override_periods set valid_to_utc = ? where id = ?',
            [stamp, current.single['id']],
          );
        }
        db.execute(
          '''
          insert into local_price_override_periods (model_id, prompt_price_per_token,
            completion_price_per_token, input_cache_read_price_per_token,
            input_cache_write_price_per_token, internal_reasoning_price_per_token,
            settings_fingerprint, valid_from_utc, first_settings_revision,
            last_seen_settings_revision)
          values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
          [entry.key, ...rates, fingerprint, stamp, revision, revision],
        );
        _markModelCostsDirty(entry.key, observed);
      }
      var cursor = 0;
      while (true) {
        final removed = db.select(
          '''
          select id, model_id from local_price_override_periods
          where valid_to_utc is null and last_seen_settings_revision <> ? and id > ?
          order by id limit 512
        ''',
          [revision, cursor],
        );
        if (removed.isEmpty) break;
        for (final row in removed) {
          db.execute(
            '''
            update local_price_override_periods
            set valid_to_utc = ?, last_seen_settings_revision = ? where id = ?
          ''',
            [stamp, revision, row['id']],
          );
          _markModelCostsDirty(row['model_id'] as String, observed);
        }
        cursor = removed.last['id'] as int;
      }
      if (ownsTransaction) db.execute('commit');
    } on Object {
      if (ownsTransaction && !db.autocommit) db.execute('rollback');
      rethrow;
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
        input_cache_read_price_per_token, input_cache_write_price_per_token,
        internal_reasoning_price_per_token, source, fetched_at_utc
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
          cacheWriteInputPricePerToken:
              row['input_cache_write_price_per_token'] as String?,
          internalReasoningPricePerToken:
              row['internal_reasoning_price_per_token'] as String?,
          source: row['source'] as String?,
          fetchedAtUtc: _dateTimeUtc(row['fetched_at_utc']),
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
            cacheWriteInputPricePerToken: override.inputCacheWrite,
            internalReasoningPricePerToken: override.internalReasoning,
            source: 'override',
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
    try {
      db.execute(
        '''
        insert into logs (time_utc, level, category, message, details)
        values (?, 'error', 'pricing', 'Pricing fetch failed.', ?)
        ''',
        [DateTime.now().toUtc().toIso8601String(), _safePricingError(error)],
      );
    } on Object {
      // Pricing failures are recoverable even when another process owns the
      // SQLite writer slot and the diagnostic row cannot be persisted.
    }
  }
}

class HistoricalUsageCost {
  const HistoricalUsageCost({
    this.estimatedCostText,
    this.costStatus = 'unknown',
    this.providerPricePeriodId,
    this.providerRuleIds = const [],
    this.localOverridePeriodId,
    this.catalogSnapshotId,
    this.resolutionMethod = 'unknown',
  });

  final String? estimatedCostText;
  final String costStatus;
  final int? providerPricePeriodId;
  final List<int> providerRuleIds;
  final int? localOverridePeriodId;
  final int? catalogSnapshotId;
  final String resolutionMethod;
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
    this.cancellation,
  });

  final Uri endpoint;
  final String apiKey;
  final String? body;
  final Future<void>? cancellation;
}

abstract interface class OpenRouterModelsClient {
  Future<OpenRouterModelsResponse> fetchModels(OpenRouterModelsRequest request);
}

class OpenRouterHttpClient implements OpenRouterModelsClient {
  const OpenRouterHttpClient({this.clock});

  final DateTime Function()? clock;

  @override
  Future<OpenRouterModelsResponse> fetchModels(
    OpenRouterModelsRequest request,
  ) async {
    _validateCatalogUri(request.endpoint, continuation: false);
    if (request.body != null) {
      throw const PricingFetchException(
        'Catalog requests must not have a body.',
      );
    }
    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    var cancelled = false;
    final cancellation = Completer<OpenRouterModelsResponse>();
    void cancel() {
      cancelled = true;
      if (!cancellation.isCompleted) {
        cancellation.completeError(
          const PricingFetchException('OpenRouter catalog request cancelled.'),
        );
      }
      httpClient.close(force: true);
    }

    final cancellationSubscription = request.cancellation?.asStream().listen(
      (_) => cancel(),
      onError: (Object _) => cancel(),
    );
    try {
      final fetch = () async {
        final models = <OpenRouterModelPricing>[];
        final ids = <String>{};
        final visited = <Uri>{};
        final digest = _CatalogDigest();
        final hash = sha256.startChunkedConversion(digest);
        var endpoint = request.endpoint;
        var totalBytes = 0;
        int? total;
        while (true) {
          if (cancelled) {
            throw const PricingFetchException(
              'OpenRouter catalog request cancelled.',
            );
          }
          _validateCatalogUri(endpoint, continuation: visited.isNotEmpty);
          if (!visited.add(endpoint) || visited.length > 100) {
            throw const PricingFetchException(
              'OpenRouter pagination limit or cycle.',
            );
          }
          final bytes = await _readPage(
            httpClient,
            endpoint,
            request.apiKey,
          ).timeout(const Duration(seconds: 30));
          if (cancelled) {
            throw const PricingFetchException(
              'OpenRouter catalog request cancelled.',
            );
          }
          totalBytes += bytes.length;
          if (totalBytes > 50 * 1024 * 1024) {
            throw const PricingFetchException(
              'OpenRouter catalog exceeds its size limit.',
            );
          }
          hash.add(bytes);
          final page = OpenRouterModelsResponse.fromJsonText(
            utf8.decode(bytes),
          );
          final declared = page.declaredTotalCount;
          if (declared != null) {
            if (declared > 100000 || (total != null && total != declared)) {
              throw const PricingFetchException(
                'OpenRouter page totals are inconsistent.',
              );
            }
            total = declared;
          }
          for (final model in page.models) {
            if (!ids.add(model.modelId) || ids.length > 100000) {
              throw const PricingFetchException(
                'OpenRouter model IDs are repeated or exceed the limit.',
              );
            }
            models.add(model);
          }
          if (page.nextPage == null) break;
          endpoint = endpoint.resolve(page.nextPage!);
        }
        hash.close();
        final catalog = OpenRouterModelsResponse(
          List.unmodifiable(models),
          declaredTotalCount: total,
          pageCount: visited.length,
          payloadSha256: digest.value!.toString(),
        );
        catalog.validateComplete();
        return catalog;
      }();
      return await Future.any([fetch, cancellation.future]);
    } on TimeoutException {
      throw const PricingFetchException(
        'OpenRouter catalog request timed out.',
      );
    } on FormatException {
      throw const PricingFetchException(
        'OpenRouter catalog encoding or continuation is invalid.',
      );
    } on SocketException {
      throw const PricingFetchException(
        'OpenRouter catalog connection failed.',
      );
    } on HttpException {
      throw const PricingFetchException('OpenRouter catalog transport failed.');
    } on HandshakeException {
      throw const PricingFetchException(
        'OpenRouter catalog secure connection failed.',
      );
    } finally {
      httpClient.close(force: true);
      await cancellationSubscription?.cancel();
    }
  }

  Future<Uint8List> _readPage(
    HttpClient client,
    Uri endpoint,
    String apiKey,
  ) async {
    final request = await client.getUrl(endpoint);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (apiKey.trim().isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    }
    final response = await request.close();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PricingFetchException(
        'OpenRouter returned HTTP ${response.statusCode}.',
        statusCode: response.statusCode,
        retryAfter: _retryAfter(response.headers[HttpHeaders.retryAfterHeader]),
      );
    }
    // HttpClient decompresses automatically. Bound decoded bytes, not the
    // advertised compressed Content-Length, before UTF-8/JSON allocation.
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (bytes.length + chunk.length > 5 * 1024 * 1024) {
        throw const PricingFetchException(
          'OpenRouter page exceeds its size limit.',
        );
      }
      bytes.add(chunk);
    }
    return bytes.takeBytes();
  }

  Duration? _retryAfter(List<String>? values) {
    if (values == null || values.length != 1) return null;
    final value = values.single.trim();
    const cap = Duration(hours: 24);
    if (RegExp(r'^[0-9]+$').hasMatch(value)) {
      final seconds = BigInt.parse(value);
      return seconds >= BigInt.from(cap.inSeconds)
          ? cap
          : Duration(seconds: seconds.toInt());
    }
    try {
      final until = HttpDate.parse(value);
      final now = (clock?.call() ?? DateTime.now()).toUtc();
      final delay = until.difference(now);
      return delay.isNegative
          ? Duration.zero
          : delay > cap
          ? cap
          : delay;
    } on HttpException {
      // Invalid header diagnostics contain the raw value; discard them.
      return null;
    }
  }
}

class _CatalogDigest implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

void _validateCatalogUri(Uri endpoint, {required bool continuation}) {
  if (endpoint.scheme != 'https' ||
      endpoint.host != 'openrouter.ai' ||
      endpoint.port != 443 ||
      endpoint.path != '/api/v1/models' ||
      (!continuation && endpoint.hasQuery) ||
      endpoint.hasFragment ||
      endpoint.userInfo.isNotEmpty) {
    throw const PricingFetchException(
      'OpenRouter catalog endpoint must be https://openrouter.ai/api/v1/models.',
    );
  }
}

class OpenRouterModelsResponse {
  const OpenRouterModelsResponse(
    this.models, {
    this.declaredTotalCount,
    this.nextPage,
    this.pageCount = 1,
    this.payloadSha256,
  });

  factory OpenRouterModelsResponse.fromJsonText(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const PricingFetchException('OpenRouter catalog JSON is invalid.');
    }
    if (decoded is! Map) {
      throw const PricingFetchException('OpenRouter catalog root is invalid.');
    }
    final data = decoded['data'];
    if (data is! List) {
      throw const PricingFetchException('OpenRouter catalog data is invalid.');
    }
    final total = decoded['total_count'];
    final links = decoded['links'];
    if ((total != null && (total is! int || total < 0)) ||
        (links != null && links is! Map)) {
      throw const PricingFetchException(
        'OpenRouter catalog metadata is invalid.',
      );
    }
    final next = links is Map ? links['next'] : null;
    if (next != null && (next is! String || next.trim().isEmpty)) {
      throw const PricingFetchException('OpenRouter continuation is invalid.');
    }
    final models = <OpenRouterModelPricing>[];
    for (final model in data) {
      if (model is! Map) {
        throw const PricingFetchException('OpenRouter model entry is invalid.');
      }
      models.add(OpenRouterModelPricing.fromJson(model));
    }
    return OpenRouterModelsResponse(
      List.unmodifiable(models),
      declaredTotalCount: total as int?,
      nextPage: next as String?,
      payloadSha256: sha256.convert(utf8.encode(text)).toString(),
    );
  }

  final List<OpenRouterModelPricing> models;
  final int? declaredTotalCount;
  final String? nextPage;
  final int pageCount;
  final String? payloadSha256;

  void validateComplete() {
    if (nextPage != null ||
        pageCount < 1 ||
        pageCount > 100 ||
        models.length > 100000 ||
        (declaredTotalCount != null && declaredTotalCount != models.length) ||
        models.map((model) => model.modelId).toSet().length != models.length) {
      throw const PricingFetchException(
        'OpenRouter catalog is incomplete or inconsistent.',
      );
    }
  }
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
    this.imagePrice,
    this.webSearchPrice,
    this.canonicalSlug,
    this.additionalRates = const {},
    this.rules = const [],
    this.rawPricingJson,
  });

  factory OpenRouterModelPricing.fromJson(Map<Object?, Object?> json) {
    final id = _string(json['id']);
    if (id == null || id.isEmpty) {
      throw const PricingFetchException('OpenRouter model id is missing.');
    }
    if (json['pricing'] is! Map) {
      throw const PricingFetchException('OpenRouter model pricing is invalid.');
    }
    final pricing = (json['pricing'] as Map).cast<Object?, Object?>();
    final List<OpenRouterPriceRule> rules;
    try {
      rules = parseOpenRouterPriceRules(pricing['overrides']);
    } on FormatException {
      throw const PricingFetchException(
        'OpenRouter conditional pricing is invalid or unsupported.',
      );
    }
    final additional = <String, String>{};
    for (final entry in pricing.entries) {
      if (_storedPriceKeys.contains(entry.key) || entry.key == 'overrides') {
        continue;
      }
      if (entry.key is! String) {
        throw const PricingFetchException('OpenRouter price field is invalid.');
      }
      final rate = _stringOrNumber(entry.value);
      if (rate != null) additional[entry.key as String] = rate;
    }
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
      imagePrice: _stringOrNumber(pricing['image']),
      webSearchPrice: _stringOrNumber(pricing['web_search']),
      canonicalSlug: _string(json['canonical_slug']),
      additionalRates: Map.unmodifiable(additional),
      rules: rules,
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
  final String? imagePrice;
  final String? webSearchPrice;
  final String? canonicalSlug;
  final Map<String, String> additionalRates;
  final List<OpenRouterPriceRule> rules;
  final String? rawPricingJson;
}

const _storedPriceKeys = [
  'prompt',
  'completion',
  'input_cache_read',
  'input_cache_write',
  'internal_reasoning',
  'request',
  'image',
  'web_search',
];

Map<String, dynamic> _modelObservationJson(OpenRouterModelPricing model) => {
  'id': model.modelId,
  if (model.rawPricingJson != null) 'raw_pricing_json': model.rawPricingJson,
  if (model.modelName != null) 'name': model.modelName,
  if (model.canonicalSlug != null) 'canonical_slug': model.canonicalSlug,
  'pricing': {
    if (model.promptPricePerToken != null) 'prompt': model.promptPricePerToken,
    if (model.completionPricePerToken != null)
      'completion': model.completionPricePerToken,
    if (model.inputCacheReadPricePerToken != null)
      'input_cache_read': model.inputCacheReadPricePerToken,
    if (model.inputCacheWritePricePerToken != null)
      'input_cache_write': model.inputCacheWritePricePerToken,
    if (model.internalReasoningPricePerToken != null)
      'internal_reasoning': model.internalReasoningPricePerToken,
    if (model.requestPrice != null) 'request': model.requestPrice,
    if (model.imagePrice != null) 'image': model.imagePrice,
    if (model.webSearchPrice != null) 'web_search': model.webSearchPrice,
    ...model.additionalRates,
    if (model.rules.isNotEmpty)
      'overrides': [
        for (final rule in model.rules) jsonDecode(rule.rawRuleJson),
      ],
  },
};

PriceObservation _removedPriceObservation(
  String model,
  String provider,
  DateTime at,
  String origin,
) => PriceObservation(
  origin: origin,
  authority: 'local',
  observedAtUtc: at,
  provider: provider,
  modelId: model,
  model: {'id': model, 'pricing': <String, Object?>{}, 'removed': true},
);

const _priceColumns = {
  'prompt': 'prompt_price_per_token',
  'completion': 'completion_price_per_token',
  'input_cache_read': 'input_cache_read_price_per_token',
  'input_cache_write': 'input_cache_write_price_per_token',
  'internal_reasoning': 'internal_reasoning_price_per_token',
  'request': 'request_price',
  'image': 'image_price',
  'web_search': 'web_search_price',
};

Map<String, Object?> _normalizedRule(OpenRouterPriceRule rule) => {
  'order': rule.providerOrder,
  'minimum': rule.minPromptTokens,
  'start': rule.utcStartMinute,
  'end': rule.utcEndMinute,
  'days': rule.utcWeekdays?.toList()?..sort(),
  'rates': {
    for (final key in rule.rateOverrides.keys.toList()..sort())
      key: rule.rateOverrides[key],
  },
};

class PricingFetchException implements Exception {
  const PricingFetchException(this.message, {this.statusCode, this.retryAfter});

  final String message;
  final int? statusCode;
  final Duration? retryAfter;

  @override
  String toString() => message;
}

String _providerFromModel(String modelId) {
  final slash = modelId.indexOf('/');
  return slash <= 0 ? 'unknown' : modelId.substring(0, slash);
}

String? _string(Object? value) => value is String ? value : null;

String? _stringOrNumber(Object? value) {
  if (value == null) return null;
  // Provider rates are decimal strings. Reject binary floats and malformed
  // values instead of silently converting an invalid rate into missing data.
  final normalized = value is String ? sumEstimatedCostTexts([value]) : null;
  // Observed routing models use -1 where a fixed rate is unavailable. Retain
  // the original JSON but never turn that sentinel into a negative charge.
  if (normalized == '-1') return null;
  if (normalized == null || normalized.startsWith('-')) {
    throw const PricingFetchException('OpenRouter decimal price is invalid.');
  }
  return normalized;
}

DateTime? _dateTimeUtc(Object? value) =>
    value is String ? DateTime.tryParse(value)?.toUtc() : null;

String _priceTimestamp(DateTime value) {
  final utc = value.toUtc();
  final text = utc.toIso8601String();
  // SQLite's indexed lexical order requires one fractional width. Dart omits
  // the final three digits when microsecond == 0, which otherwise misorders
  // .000Z and .000001Z at a price change inside the same millisecond.
  return utc.microsecond == 0
      ? '${text.substring(0, text.length - 1)}000Z'
      : text;
}

String _safePricingError(Object error) => error is SqliteException
    ? 'Pricing database update failed.'
    : 'Pricing fetch failed.';
