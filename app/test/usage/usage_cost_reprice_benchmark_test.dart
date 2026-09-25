import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:codex_sessions_viewer/src/usage/usage_cost_projection.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toml/toml.dart';

/// Measures cost repricing on a copy of a real database. Skipped unless
/// `CSV_REPRICE_BENCH_DB` names that copy; never point it at a live database.
/// `CSV_REPRICE_BENCH_SETTINGS` names the settings.toml whose pricing to use,
/// and `CSV_REPRICE_BENCH_SAMPLE` keeps every n-th partition (default 20).
void main() {
  final path = Platform.environment['CSV_REPRICE_BENCH_DB'];
  test(
    'reprices a fixed sample of partitions and reports the rate',
    () {
      final settingsPath = Platform.environment['CSV_REPRICE_BENCH_SETTINGS'];
      final settings = settingsPath == null
          ? AppSettings.defaults().pricing
          : AppSettings.fromTomlMap(
              TomlDocument.parse(File(settingsPath).readAsStringSync()).toMap(),
            ).pricing;
      final sample =
          int.tryParse(
            Platform.environment['CSV_REPRICE_BENCH_SAMPLE'] ?? '',
          ) ??
          20;
      final db = openFileBackedDatabase(File(path!), maintenanceWriter: true);
      addTearDown(db.close);
      db.execute('delete from usage_cost_dirty_partitions');
      db.execute(
        '''
        insert into usage_cost_dirty_partitions (session_id, day_utc, model_key,
          reason, target_cost_projection_version, created_at_utc, updated_at_utc)
        select session_id, day_utc, model_key, 'benchmark', ?, 'bench', 'bench'
        from (select distinct session_id, day_utc, model_key from usage_session_daily)
        where abs(unicode(session_id) + length(session_id) * 7 + unicode(substr(session_id, -1))
          + unicode(substr(day_utc, -1)) * 13) % ? = 0
        ''',
        [usageCostProjectionVersion, sample],
      );
      // Stale values the repricing must replace, so an unchanged result
      // proves the rows were rebuilt, not left alone.
      db.execute('''
        update usage_session_daily set estimated_cost_text = null,
          cost_status = 'unknown', input_tokens = 0, total_tokens = 0
        where exists (select 1 from usage_cost_dirty_partitions d
          where d.session_id = usage_session_daily.session_id
            and d.day_utc = usage_session_daily.day_utc
            and d.model_key = usage_session_daily.model_key)
      ''');
      final dirty =
          db
                  .select('select count(*) n from usage_cost_dirty_partitions')
                  .single['n']
              as int;
      final events =
          db.select('''
            select count(*) n from usage_events e join usage_cost_dirty_partitions d
              on d.session_id = e.session_row_id
              and d.day_utc = strftime('%Y-%m-%d', e.occurred_at_utc)
              and d.model_key = coalesce(e.model, '')
          ''').single['n']
              as int;
      final jobs = MaintenanceJobRepository(db);
      final job = jobs.enqueue(
        jobType: 'usage_cost_repricing',
        phase: 'reprice_costs',
      );
      final lease = jobs.claim(
        jobType: job.jobType,
        leaseDuration: const Duration(hours: 5),
      )!;
      final costs = UsageCostProjectionRepository(db);
      final watch = Stopwatch()..start();
      var calls = 0;
      while (costs.repriceNextBatch(
            jobs: jobs,
            lease: lease,
            settings: settings,
          ) !=
          0) {
        calls++;
      }
      watch.stop();
      final completed = jobs.read(job.id)!.completedUnits;
      final rows = db.select('''
        select d.session_id, d.day_utc, d.model_key, d.path_context_id,
          d.branch_scope, d.input_tokens, d.cached_input_tokens,
          d.cache_write_input_tokens, d.output_tokens,
          d.reasoning_output_tokens, d.total_tokens, d.estimated_cost_text,
          d.cost_status, d.provider_price_period_id, d.provider_rule_ids_json,
          d.local_override_period_id, d.pricing_resolution_method,
          d.pricing_catalog_snapshot_id, d.cost_projection_version
        from usage_session_daily d
        order by d.session_id, d.day_utc, d.model_key, d.path_context_id,
          d.branch_scope
      ''');
      final digest = sha256.convert(
        utf8.encode(rows.map((row) => jsonEncode(row.values)).join('\n')),
      );
      jobs.markSucceeded(lease, phase: 'complete', statusMessage: 'bench');
      final seconds = watch.elapsedMicroseconds / 1e6;
      // ignore: avoid_print
      print(
        'partitions=$dirty completed=$completed calls=$calls events=$events '
        'seconds=${seconds.toStringAsFixed(2)} '
        'partitions_per_second=${(dirty / seconds).toStringAsFixed(1)} '
        'rows=${rows.length} sha256=$digest',
      );
      expect(
        db
            .select('select count(*) n from usage_cost_dirty_partitions')
            .single['n'],
        0,
      );
    },
    skip: path == null ? 'Set CSV_REPRICE_BENCH_DB to a database copy.' : false,
    timeout: const Timeout(Duration(hours: 3)),
  );
}
