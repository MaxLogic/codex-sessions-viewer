import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import '../usage/usage_summary.dart';
import 'maintenance_job.dart';

/// Builds the inactive read model while the startup gate excludes writers.
/// The encompassing migration owns backup verification, stop/yield boundaries,
/// pricing initialization, final validation, and activation.
class UsageProjectionMigration {
  const UsageProjectionMigration(this.db);

  final Database db;

  int rebuildNextBatch({
    required MaintenanceJobRepository jobs,
    required MaintenanceJobLease lease,
  }) {
    final job = jobs.read(lease.jobId)!;
    final generationId = job.databaseGenerationId;
    if (!identical(jobs.db, db) ||
        job.jobType != 'usage_projection_migration' ||
        generationId == null ||
        !{'contexts_validated', 'project_usage'}.contains(job.phase)) {
      throw StateError(
        'Daily initialization requires the context-validated migration owner.',
      );
    }
    final payload = job.payloadJson == null
        ? <String, dynamic>{}
        : jsonDecode(job.payloadJson!) as Map<String, dynamic>;
    final cursor = payload['projection_session_cursor'] as String?;
    final sessions = db.select(
      '''
      select id from sessions ${cursor == null ? '' : 'where id > ?'}
      order by id limit 512
    ''',
      [?cursor],
    );
    if (sessions.isEmpty) return 0;
    final previouslyProjected = payload['projected_session_count'] as int? ?? 0;
    final completed = previouslyProjected + sessions.length;
    final total =
        db.select('select count(*) n from sessions').single['n'] as int;
    payload['projection_session_cursor'] = sessions.last['id'];
    payload['projected_session_count'] = completed;
    jobs.commitBatch(
      lease: lease,
      phase: 'project_usage',
      completedUnits: job.completedUnits + sessions.length,
      totalUnits: job.completedUnits - previouslyProjected + total,
      lastProcessedRowId: job.lastProcessedRowId,
      statusMessage: 'Daily usage projected for $completed of $total sessions.',
      payloadJson: jsonEncode(payload),
      apply: (_) => UsageSummaryRepository(db)
          .replaceDailyProjectionsInCurrentTransaction(
            sessions.map((row) => row['id'] as String),
            shadowGenerationId: generationId,
          ),
    );
    return sessions.length;
  }

  /// One-time migration audit, never part of a Usage-screen read. Compare every
  /// daily grain and token bucket, not just global sums that can hide swaps.
  /// Price-basis rows may split one token grain after historical repricing.
  Map<String, Object?> validateShadowParity() {
    const dimensions =
        'session_id, day_utc, model_key, path_context_id, branch_scope';
    const buckets = [
      'input_tokens',
      'cached_input_tokens',
      'cache_write_input_tokens',
      'output_tokens',
      'reasoning_output_tokens',
      'total_tokens',
    ];
    final sums = buckets.map((name) => 'sum($name) as $name').join(', ');
    final mismatch = db.select('''
      with expected as (
        select session_row_id as session_id,
          strftime('%Y-%m-%d', occurred_at_utc) as day_utc,
          coalesce(model, '') as model_key, path_context_id, branch_scope,
          sum(input_tokens) as input_tokens,
          sum(cached_input_tokens) as cached_input_tokens,
          sum(cache_write_input_tokens) as cache_write_input_tokens,
          sum(output_tokens) as output_tokens,
          sum(reasoning_output_tokens) as reasoning_output_tokens,
          sum(input_tokens + output_tokens) as total_tokens
        from usage_events_next
        where strftime('%Y-%m-%d', occurred_at_utc) is not null
        group by $dimensions
      ), actual as (
        select $dimensions, $sums from usage_session_daily group by $dimensions
      )
      select 1 from (select * from expected except select * from actual)
      union all
      select 1 from (select * from actual except select * from expected)
      limit 1
    ''');
    if (mismatch.isNotEmpty) {
      throw StateError(
        'Daily projection token facts differ from the shadow events.',
      );
    }
    if (db.select('''
      select 1 from sessions s where s.usage_local_event_count is not (
        select count(*) from usage_events_next e
        where e.session_row_id = s.id and e.branch_scope = 'local'
      ) limit 1
    ''').isNotEmpty) {
      throw StateError(
        'Daily projection coverage differs from the shadow events.',
      );
    }
    if (db
        .select('select * from pragma_foreign_key_check limit 1')
        .isNotEmpty) {
      throw StateError('Daily projection has invalid foreign keys.');
    }
    // JSON rule references need an explicit audit in addition to foreign keys.
    if (db.select('''
      select 1 from usage_session_daily daily where case
        when not json_valid(daily.provider_rule_ids_json) then 1
        when json_type(daily.provider_rule_ids_json) <> 'array' then 1
        else daily.provider_rule_ids_json <> (
          select json_group_array(id) from (
            select rule.id from provider_price_rules rule
            where rule.price_period_id = daily.provider_price_period_id
              and rule.id in (
                select value from json_each(daily.provider_rule_ids_json)
                where type = 'integer' and value > 0
              )
            order by rule.provider_order
          )
        ) end limit 1
    ''').isNotEmpty) {
      throw StateError('Daily projection has an invalid provider rule basis.');
    }
    return {
      'session_count': db.select('select count(*) n from sessions').single['n'],
      'daily_row_count': db
          .select('select count(*) n from usage_session_daily')
          .single['n'],
    };
  }
}
