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
    final partitions = db.select(
      '''
      select * from usage_cost_dirty_partitions
      order by model_key, day_utc, session_id limit ?
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
    final events = db.prepare('''
      select * from ${shadow ? 'usage_events_next' : 'usage_events'}
      where session_row_id = ? and strftime('%Y-%m-%d', occurred_at_utc) = ?
        and coalesce(model, '') = ? and source_record_ordinal > ?
      order by source_record_ordinal limit 512
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
      for (final partition in partitions) {
        final key = [
          partition['session_id'],
          partition['day_utc'],
          partition['model_key'],
        ];
        deleteDaily.execute(key);
        // Events with the same pricing basis land in the same daily row;
        // summing them here in event order gives exactly the totals that one
        // upsert per event produced.
        final rows = <String, _DailyRow>{};
        var ordinal = -1;
        while (true) {
          final page = events.select([...key, ordinal]);
          if (page.isEmpty) break;
          for (final event in page) {
            final cost = pricing.resolve(
              occurredAtUtc: DateTime.parse(event['occurred_at_utc'] as String),
              model: event['model'] as String?,
              inputTokens: event['input_tokens'] as int,
              cachedInputTokens: event['cached_input_tokens'] as int,
              cacheWriteInputTokens: event['cache_write_input_tokens'] as int,
              outputTokens: event['output_tokens'] as int,
              reasoningOutputTokens: event['reasoning_output_tokens'] as int,
            );
            final ruleIds = jsonEncode(cost.providerRuleIds);
            final basis = jsonEncode([
              event['path_context_id'],
              event['branch_scope'],
              cost.providerPricePeriodId ?? 0,
              ruleIds,
              cost.localOverridePeriodId ?? 0,
              cost.resolutionMethod,
            ]);
            final tokens = [
              for (final bucket in _buckets.take(5)) event[bucket] as int,
              _tokenAdd(
                event['input_tokens'] as int,
                event['output_tokens'] as int,
              ),
            ];
            final row = rows[basis];
            if (row == null) {
              rows[basis] = _DailyRow(
                pathContextId: event['path_context_id'],
                branchScope: event['branch_scope'],
                tokens: tokens,
                costText: cost.estimatedCostText,
                costStatus: cost.costStatus,
                providerPricePeriodId: cost.providerPricePeriodId,
                providerRuleIdsJson: ruleIds,
                localOverridePeriodId: cost.localOverridePeriodId,
                resolutionMethod: cost.resolutionMethod,
                catalogSnapshotId: cost.catalogSnapshotId,
              );
            } else {
              row.add(tokens, cost.estimatedCostText, cost.costStatus);
            }
          }
          ordinal = page.last['source_record_ordinal'] as int;
        }
        for (final row in rows.values) {
          insert.execute([
            ...key,
            row.pathContextId,
            row.branchScope,
            ...row.tokens,
            row.costText,
            row.costStatus,
            row.providerPricePeriodId,
            row.providerRuleIdsJson,
            row.localOverridePeriodId,
            row.resolutionMethod,
            row.catalogSnapshotId,
            partition['target_cost_projection_version'],
            now,
          ]);
        }
        deleteDirty.execute(key);
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

int _tokenAdd(int left, int right) {
  final sum = BigInt.from(left) + BigInt.from(right);
  if (sum.isNegative || sum.bitLength > 63) {
    throw StateError('Projected token total exceeds SQLite integer range.');
  }
  return sum.toInt();
}

/// One daily row being summed; the first event supplies the pricing basis.
final class _DailyRow {
  _DailyRow({
    required this.pathContextId,
    required this.branchScope,
    required this.tokens,
    required this.costText,
    required this.costStatus,
    required this.providerPricePeriodId,
    required this.providerRuleIdsJson,
    required this.localOverridePeriodId,
    required this.resolutionMethod,
    required this.catalogSnapshotId,
  });

  final Object? pathContextId;
  final Object? branchScope;
  final List<int> tokens;
  String? costText;
  String costStatus;
  final int? providerPricePeriodId;
  final String providerRuleIdsJson;
  final int? localOverridePeriodId;
  final String resolutionMethod;
  final int? catalogSnapshotId;

  void add(List<int> more, String? cost, String status) {
    for (var index = 0; index < tokens.length; index++) {
      tokens[index] = _tokenAdd(tokens[index], more[index]);
    }
    costText = sumEstimatedCostTexts([costText, cost]);
    costStatus = costStatus == 'unknown' || status == 'unknown'
        ? 'unknown'
        : costStatus == 'partial_unsupported_units' ||
              status == 'partial_unsupported_units'
        ? 'partial_unsupported_units'
        : 'complete';
  }
}
