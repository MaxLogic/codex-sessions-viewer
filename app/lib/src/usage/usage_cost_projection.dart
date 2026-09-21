import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../config/app_settings.dart';
import '../database/maintenance_job.dart';
import '../database/database_generation.dart';
import '../pricing/pricing_repository.dart';
import 'usage_summary.dart';

class UsageCostProjectionRepository {
  const UsageCostProjectionRepository(this.db);
  final Database db;

  int repriceNextBatch({
    required MaintenanceJobRepository jobs,
    required MaintenanceJobLease lease,
    required PricingSettings settings,
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
    final partitions = db.select('''
      select * from usage_cost_dirty_partitions
      order by model_key, day_utc, session_id limit 1
    ''');
    if (partitions.isEmpty) return 0;
    final partition = partitions.single;
    if (partition['target_cost_projection_version'] !=
        usageCostProjectionVersion) {
      throw StateError(
        'Requested cost algorithm version is not supported by this application.',
      );
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
    jobs.commitBatch(
      lease: lease,
      phase: 'reprice_costs',
      completedUnits: job.completedUnits + 1,
      totalUnits: total,
      lastProcessedRowId: job.lastProcessedRowId,
      statusMessage: 'Repricing daily partition ${job.completedUnits + 1}.',
      payloadJson: jsonEncode(payload),
      apply: (_) => _replacePartition(partition, settings, shadow: shadow),
    );
    return 1;
  }

  void _replacePartition(
    Row partition,
    PricingSettings settings, {
    required bool shadow,
  }) {
    final key = [
      partition['session_id'],
      partition['day_utc'],
      partition['model_key'],
    ];
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
      function: (args) {
        final sum = BigInt.from(args[0] as int) + BigInt.from(args[1] as int);
        if (sum.isNegative || sum.bitLength > 63) {
          throw StateError(
            'Projected token total exceeds SQLite integer range.',
          );
        }
        return sum.toInt();
      },
    );
    db.execute('''
      delete from usage_session_daily where session_id = ? and day_utc = ? and model_key = ?
    ''', key);
    const buckets = [
      'input_tokens',
      'cached_input_tokens',
      'cache_write_input_tokens',
      'output_tokens',
      'reasoning_output_tokens',
      'total_tokens',
    ];
    final insert = db.prepare('''
      insert into usage_session_daily (
        session_id, day_utc, model_key, path_context_id, branch_scope,
        input_tokens, cached_input_tokens, cache_write_input_tokens, output_tokens,
        reasoning_output_tokens, total_tokens, estimated_cost_text, cost_status,
        provider_price_period_id, provider_rule_ids_json, local_override_period_id,
        pricing_resolution_method, pricing_catalog_snapshot_id,
        cost_projection_version, updated_at_utc)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, csv_token_add(?, ?), ?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict do update set
        ${buckets.map((name) => '$name = csv_token_add(usage_session_daily.$name, excluded.$name)').join(', ')},
        estimated_cost_text = csv_decimal_add(usage_session_daily.estimated_cost_text, excluded.estimated_cost_text),
        cost_status = case
          when usage_session_daily.cost_status = 'unknown' or excluded.cost_status = 'unknown' then 'unknown'
          when usage_session_daily.cost_status = 'partial_unsupported_units' or excluded.cost_status = 'partial_unsupported_units'
            then 'partial_unsupported_units' else 'complete' end,
        updated_at_utc = excluded.updated_at_utc
    ''');
    final pricing = PricingRepository(db);
    final now = DateTime.now().toUtc().toIso8601String();
    var ordinal = -1;
    try {
      while (true) {
        final events = db.select(
          '''
          select * from ${shadow ? 'usage_events_next' : 'usage_events'}
          where session_row_id = ? and strftime('%Y-%m-%d', occurred_at_utc) = ?
            and coalesce(model, '') = ? and source_record_ordinal > ?
          order by source_record_ordinal limit 512
        ''',
          [...key, ordinal],
        );
        if (events.isEmpty) break;
        for (final event in events) {
          final cost = pricing.resolveHistoricalUsageCost(
            settings: settings,
            occurredAtUtc: DateTime.parse(event['occurred_at_utc'] as String),
            model: event['model'] as String?,
            inputTokens: event['input_tokens'] as int,
            cachedInputTokens: event['cached_input_tokens'] as int,
            cacheWriteInputTokens: event['cache_write_input_tokens'] as int,
            outputTokens: event['output_tokens'] as int,
            reasoningOutputTokens: event['reasoning_output_tokens'] as int,
          );
          insert.execute([
            ...key,
            event['path_context_id'],
            event['branch_scope'],
            for (final bucket in buckets.take(5)) event[bucket],
            event['input_tokens'],
            event['output_tokens'],
            cost.estimatedCostText,
            cost.costStatus,
            cost.providerPricePeriodId,
            jsonEncode(cost.providerRuleIds),
            cost.localOverridePeriodId,
            cost.resolutionMethod,
            cost.catalogSnapshotId,
            partition['target_cost_projection_version'],
            now,
          ]);
        }
        ordinal = events.last['source_record_ordinal'] as int;
      }
    } finally {
      insert.close();
    }
    db.execute('''
      delete from usage_cost_dirty_partitions
      where session_id = ? and day_utc = ? and model_key = ?
    ''', key);
  }
}
