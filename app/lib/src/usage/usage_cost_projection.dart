import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../config/app_settings.dart';
import '../database/maintenance_job.dart';
import '../database/database_generation.dart';
import '../pricing/pricing_repository.dart';
import 'usage_summary.dart';

/// Dirty partitions repriced in one durable transaction. Most partitions hold
/// a few hundred events, so a batch stays short enough for queued writers.
const repricePartitionsPerBatch = 16;

class UsageCostProjectionRepository {
  const UsageCostProjectionRepository(this.db);
  final Database db;

  /// Reprices up to [partitionLimit] dirty partitions in one transaction and
  /// returns how many it repriced; 0 when none are left.
  int repriceNextBatch({
    required MaintenanceJobRepository jobs,
    required MaintenanceJobLease lease,
    required PricingSettings settings,
    int partitionLimit = repricePartitionsPerBatch,
  }) {
    final job = jobs.read(lease.jobId)!;
    if (!identical(jobs.db, db) ||
        !{
          'usage_cost_repricing',
          'usage_projection_migration',
        }.contains(job.jobType)) {
      throw StateError('Cost repricing requires its maintenance owner.');
    }
    final active = DatabaseGenerationRepository(db).activeGeneration();
    final shadow = job.jobType == 'usage_projection_migration';
    if (shadow) {
      if (active.targetSchemaVersion >= 16 ||
          db
              .select(
                '''
        select 1 from database_generations
        where id = ? and state = 'building' and target_schema_version = 16
      ''',
                [job.databaseGenerationId],
              )
              .isEmpty) {
        throw StateError(
          'Shadow cost repricing requires an inactive building generation.',
        );
      }
    } else if (active.targetSchemaVersion < 16) {
      throw StateError('Cost repricing requires active daily projections.');
    }
    // A session's partitions travel together, so its events are read once.
    final partitions = db.select(
      '''
      select * from usage_cost_dirty_partitions
      order by session_id, day_utc, model_key limit ?
    ''',
      [partitionLimit < 1 ? 1 : partitionLimit],
    );
    if (partitions.isEmpty) return 0;
    for (final partition in partitions) {
      if (partition['target_cost_projection_version'] !=
          usageCostProjectionVersion) {
        throw StateError(
          'Requested cost algorithm version is not supported by this application.',
        );
      }
    }
    final payload = job.payloadJson == null
        ? <String, dynamic>{}
        : jsonDecode(job.payloadJson!) as Map<String, dynamic>;
    // The maintenance writer owns this run. Count once per run/phase, including
    // a retry after other work may have added dirty partitions while stopped.
    final recount =
        job.phase != 'reprice_costs' ||
        job.totalUnits == null ||
        payload['reprice_counted_run_token'] != lease.runToken;
    final total = recount
        ? job.completedUnits +
              (db
                      .select(
                        'select count(*) n from usage_cost_dirty_partitions',
                      )
                      .single['n']
                  as int)
        : job.totalUnits!;
    payload['reprice_counted_run_token'] = lease.runToken;
    final completed = job.completedUnits + partitions.length;
    jobs.commitBatch(
      lease: lease,
      phase: 'reprice_costs',
      completedUnits: completed,
      totalUnits: total < completed ? completed : total,
      lastProcessedRowId: job.lastProcessedRowId,
      statusMessage: 'Repricing daily partition $completed.',
      payloadJson: jsonEncode(payload),
      apply: (_) => _replacePartitions(partitions, settings, shadow: shadow),
    );
    return partitions.length;
  }

  void _replacePartitions(
    ResultSet partitions,
    PricingSettings settings, {
    required bool shadow,
  }) {
    db.createFunction(
      functionName: 'csv_decimal_add',
      argumentCount: const AllowedArgumentCount(2),
      deterministic: true,
      function: (args) => sumEstimatedCostTexts(args.cast<String?>()),
    );
    db.createFunction(
      functionName: 'csv_token_add',
      argumentCount: const AllowedArgumentCount(2),
      deterministic: true,
      function: (args) => _tokenAdd(args[0] as int, args[1] as int),
    );
    final insert = db.prepare('''
      insert into usage_session_daily (
        session_id, day_utc, model_key, path_context_id, branch_scope,
        input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens,
        reasoning_output_tokens, total_tokens, estimated_cost_text, cost_status,
        provider_price_period_id, provider_rule_ids_json, local_override_period_id,
        pricing_resolution_method, pricing_catalog_snapshot_id,
        cost_projection_version, updated_at_utc)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict do update set
        ${_buckets.map((name) => '$name = csv_token_add(usage_session_daily.$name, excluded.$name)').join(', ')},
        estimated_cost_text = csv_decimal_add(usage_session_daily.estimated_cost_text, excluded.estimated_cost_text),
        cost_status = case
          when usage_session_daily.cost_status = 'unknown' or excluded.cost_status = 'unknown' then 'unknown'
          when usage_session_daily.cost_status = 'partial_unsupported_units' or excluded.cost_status = 'partial_unsupported_units'
            then 'partial_unsupported_units' else 'complete' end,
        updated_at_utc = excluded.updated_at_utc
    ''');
    // One ordered pass over a session's events on the batch's days serves
    // all of its partitions; the day and model of each event pick the one.
    final events = db.prepare('''
      select occurred_at_utc, model, path_context_id, branch_scope,
        input_tokens, cached_input_tokens, cache_write_input_tokens,
        output_tokens, reasoning_output_tokens,
        strftime('%Y-%m-%d', occurred_at_utc) as day_utc,
        coalesce(model, '') as model_key
      from ${shadow ? 'usage_events_next' : 'usage_events'}
      where session_row_id = ?
        and strftime('%Y-%m-%d', occurred_at_utc) in (select value from json_each(?))
      order by source_record_ordinal
    ''');
    final deleteDaily = db.prepare('''
      delete from usage_session_daily where session_id = ? and day_utc = ? and model_key = ?
    ''');
    final deleteDirty = db.prepare('''
      delete from usage_cost_dirty_partitions
      where session_id = ? and day_utc = ? and model_key = ?
    ''');
    // Prices cannot change inside this transaction, so they are read once.
    final pricing = HistoricalUsageCostResolver(db, settings);
    final now = DateTime.now().toUtc().toIso8601String();
    try {
      var next = 0;
      while (next < partitions.length) {
        final sessionId = partitions[next]['session_id'];
        final wanted = <String, _Partition>{};
        while (next < partitions.length &&
            partitions[next]['session_id'] == sessionId) {
          final partition = partitions[next++];
          final day = partition['day_utc'] as String;
          final model = partition['model_key'] as String;
          wanted['$day\u0000$model'] = _Partition(
            day: day,
            modelKey: model,
            targetVersion: partition['target_cost_projection_version'],
          );
          deleteDaily.execute([sessionId, day, model]);
        }
        // Events with the same pricing basis land in the same daily row.
        // Their token counts are summed here and priced once per row, which
        // gives exactly the totals that pricing every event and adding the
        // exact decimal results produced.
        final days = jsonEncode(
          wanted.values.map((partition) => partition.day).toSet().toList(),
        );
        final cursor = events.selectCursor([sessionId, days]);
        while (cursor.moveNext()) {
          final event = cursor.current;
          final partition =
              wanted['${event['day_utc']}\u0000${event['model_key']}'];
          if (partition == null) continue;
          final inputTokens = event['input_tokens'] as int;
          final cachedInputTokens = event['cached_input_tokens'] as int;
          final cacheWriteInputTokens =
              event['cache_write_input_tokens'] as int;
          final outputTokens = event['output_tokens'] as int;
          final reasoningOutputTokens = event['reasoning_output_tokens'] as int;
          final basis = pricing.resolveBasis(
            occurredAtUtc: DateTime.parse(event['occurred_at_utc'] as String),
            model: event['model'] as String?,
            inputTokens: inputTokens,
          );
          final row = partition.rows.putIfAbsent(
            (event['path_context_id'], event['branch_scope'], basis),
            () => _DailyRow(
              model: event['model'] as String?,
              pathContextId: event['path_context_id'],
              branchScope: event['branch_scope'],
              basis: basis,
            ),
          );
          row.add(
            inputTokens: inputTokens,
            cachedInputTokens: cachedInputTokens,
            cacheWriteInputTokens: cacheWriteInputTokens,
            outputTokens: outputTokens,
            reasoningOutputTokens: reasoningOutputTokens,
          );
        }
        for (final partition in wanted.values) {
          for (final row in partition.rows.values) {
            final cost = row.price();
            insert.execute([
              sessionId,
              partition.day,
              partition.modelKey,
              row.pathContextId,
              row.branchScope,
              row.inputTokens,
              row.cachedInputTokens,
              row.cacheWriteInputTokens,
              row.outputTokens,
              row.reasoningOutputTokens,
              row.totalTokens,
              cost.estimatedCostText,
              cost.costStatus,
              cost.providerPricePeriodId,
              jsonEncode(cost.providerRuleIds),
              cost.localOverridePeriodId,
              cost.resolutionMethod,
              cost.catalogSnapshotId,
              partition.targetVersion,
              now,
            ]);
          }
          deleteDirty.execute([sessionId, partition.day, partition.modelKey]);
        }
      }
    } finally {
      insert.close();
      events.close();
      deleteDaily.close();
      deleteDirty.close();
    }
  }
}

const _buckets = [
  'input_tokens',
  'cached_input_tokens',
  'cache_write_input_tokens',
  'output_tokens',
  'reasoning_output_tokens',
  'total_tokens',
];

/// Adds token counts, refusing a total outside SQLite's integer range.
int _tokenAdd(int left, int right) {
  final sum = left + right;
  // A sum past 2^63 wraps negative; two negative counts cannot be a total.
  if (sum < 0 || (left < 0 && right < 0)) {
    throw StateError('Projected token total exceeds SQLite integer range.');
  }
  return sum;
}

/// One dirty partition of a session and the daily rows being summed for it.
final class _Partition {
  _Partition({
    required this.day,
    required this.modelKey,
    required this.targetVersion,
  });

  final String day;
  final String modelKey;
  final Object? targetVersion;
  final rows = <(Object?, Object?, UsagePricingBasis), _DailyRow>{};
}

/// One daily row being summed. Every event in it shares [basis], so the
/// row is priced once from its totals.
final class _DailyRow {
  _DailyRow({
    required this.model,
    required this.pathContextId,
    required this.branchScope,
    required this.basis,
  });

  final String? model;
  final Object? pathContextId;
  final Object? branchScope;
  final UsagePricingBasis basis;
  int inputTokens = 0;
  int cachedInputTokens = 0;
  int cacheWriteInputTokens = 0;
  int outputTokens = 0;
  int reasoningOutputTokens = 0;
  int totalTokens = 0;

  /// Whether every event so far could be priced on its own. A request whose
  /// counts contradict each other makes the whole row's cost unknown, as
  /// pricing it alone would have.
  bool priceable = true;

  void add({
    required int inputTokens,
    required int cachedInputTokens,
    required int cacheWriteInputTokens,
    required int outputTokens,
    required int reasoningOutputTokens,
  }) {
    priceable =
        priceable &&
        tokenCountsArePriceable(
          inputTokens: inputTokens,
          outputTokens: outputTokens,
          cachedInputTokens: cachedInputTokens,
          cacheWriteInputTokens: cacheWriteInputTokens,
          reasoningOutputTokens: reasoningOutputTokens,
        );
    this.inputTokens = _tokenAdd(this.inputTokens, inputTokens);
    this.cachedInputTokens = _tokenAdd(
      this.cachedInputTokens,
      cachedInputTokens,
    );
    this.cacheWriteInputTokens = _tokenAdd(
      this.cacheWriteInputTokens,
      cacheWriteInputTokens,
    );
    this.outputTokens = _tokenAdd(this.outputTokens, outputTokens);
    this.reasoningOutputTokens = _tokenAdd(
      this.reasoningOutputTokens,
      reasoningOutputTokens,
    );
    totalTokens = _tokenAdd(totalTokens, _tokenAdd(inputTokens, outputTokens));
  }

  HistoricalUsageCost price() {
    final cost = basis.price(
      model: model,
      inputTokens: inputTokens,
      cachedInputTokens: cachedInputTokens,
      cacheWriteInputTokens: cacheWriteInputTokens,
      outputTokens: outputTokens,
      reasoningOutputTokens: reasoningOutputTokens,
    );
    if (priceable || cost.estimatedCostText == null) return cost;
    return HistoricalUsageCost(
      costStatus: 'unknown',
      providerPricePeriodId: cost.providerPricePeriodId,
      providerRuleIds: cost.providerRuleIds,
      localOverridePeriodId: cost.localOverridePeriodId,
      catalogSnapshotId: cost.catalogSnapshotId,
      resolutionMethod: cost.resolutionMethod,
    );
  }
}
