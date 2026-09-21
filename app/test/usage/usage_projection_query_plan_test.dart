import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_generation.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test(
    'day-only billable index preserves production Usage summaries',
    () {
      final directory = Directory.systemTemp.createTempSync('usage-index-ab-');
      final db = sqlite3.open('${directory.path}/synthetic.db');
      addTearDown(() {
        db.close();
        directory.deleteSync(recursive: true);
      });
      db.execute('pragma foreign_keys=on');
      db.execute('pragma journal_mode=wal');
      final scripts =
          [
            ...Directory('../sql/init').listSync().whereType<File>(),
            ...Directory('../sql/migration').listSync().whereType<File>(),
          ].where((file) => file.path.endsWith('.sql')).toList()..sort(
            (a, b) =>
                a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
          );
      for (final script in scripts) {
        db.execute(script.readAsStringSync());
      }
      final generations = DatabaseGenerationRepository(db);
      final generation = generations.createBuilding(
        sourceSchemaVersion: 15,
        targetSchemaVersion: 16,
        sourceFingerprint: 'synthetic-index-ab',
      );
      generations.markReady(generation.id, validationReportJson: '{}');
      generations.activate(generation.id);
      db.execute('''
      begin immediate;
      with recursive n(i) as (select 1 union all select i+1 from n where i<255)
      insert into usage_path_contexts (display_path_raw,platform_path_raw,unc_path_raw,
        display_path_key,platform_path_key,unc_path_key,normalization_version,
        resolution_source,project_rules_version,created_at_utc,updated_at_utc)
      select 'synthetic/'||i,'','','synthetic/'||i,'','',1,'unassigned',0,
        '2026-09-07','2026-09-07' from n;
      with recursive n(i) as (select 0 union all select i+1 from n where i<999)
      insert into sessions (id,session_id,source_type,source_file_path,display_path,
        platform_path,parse_status,usage_projection_status,parser_version,
        started_at_utc,created_at_utc,updated_at_utc,title,message_count,
        model_primary,usage_local_event_count,is_archived)
      select printf('s%04d',i),printf('logical%04d',i),
        case when i%2=0 then 'windows' else 'wsl' end,
        'synthetic/'||i,'synthetic','synthetic','available','complete',3,
        '2025-11-12T00:00:00.000Z','2025-11-12','2025-11-12',
        'Synthetic '||i,i+1,'model-'||(i%8),270,i%2 from n;
      with recursive days(d) as (select 0 union all select d+1 from days where d<299)
      insert into usage_session_daily (session_id,day_utc,model_key,path_context_id,
        branch_scope,input_tokens,cached_input_tokens,cache_write_input_tokens,
        output_tokens,reasoning_output_tokens,total_tokens,cost_status,
        pricing_resolution_method,cost_projection_version,updated_at_utc)
      select s.id,date('2026-09-07','-'||d||' days'),
        'model-'||((s.rowid+d)%8),1+((s.rowid+d)%256),
        case when (s.rowid+d)%10=0 then 'inherited' else 'local' end,
        s.rowid*100+d%17,10,0,s.rowid,0,s.rowid*101+d%17,
        'unknown','pending_history',1,'2026-09-07'
      from sessions s cross join days;
      commit;
    ''');
      // Sparse usage is important to planner choice: 90% of known sessions
      // have no local usage, while 1000 sessions retain all 300000 daily rows.
      db.execute('''
        with recursive n(i) as (select 0 union all select i+1 from n where i<8999)
        insert into sessions (id,session_id,source_type,source_file_path,display_path,
          platform_path,parse_status,usage_projection_status,parser_version,
          started_at_utc,created_at_utc,updated_at_utc,usage_local_event_count)
        select printf('zero%04d',i),printf('logicalzero%04d',i),'windows',
          'synthetic-zero/'||i,'synthetic-zero','synthetic-zero','available',
          'complete',3,'2025-11-12T00:00:00.000Z','2025-11-12','2025-11-12',0 from n;
      ''');
      expect(
        db.select('select count(*) from sessions').single.values.single,
        10000,
      );
      expect(
        db
            .select('select count(*) from usage_session_daily')
            .single
            .values
            .single,
        300000,
      );
      final repository = UsageSummaryRepository(db);
      final requests = [
        for (final period in [UsagePeriod.last30Days, UsagePeriod.today])
          UsageSummaryRequest(
            period: period,
            nowUtc: DateTime.utc(2026, 9, 7),
            projectionVersion: 3,
          ),
      ];
      final references = <Object?>[];
      final measurements = <Object?>[];
      for (final columns in [
        'day_utc,path_context_id,model_key,session_id',
        'day_utc',
      ]) {
        db.execute('drop index idx_usage_session_daily_billable_day');
        final build = Stopwatch()..start();
        db.execute(
          "create index idx_usage_session_daily_billable_day on usage_session_daily($columns) where branch_scope='local'",
        );
        build.stop();
        db.execute('analyze');
        final bytes = db
            .select(
              "select sum(pgsize) from dbstat where name='idx_usage_session_daily_billable_day'",
            )
            .single
            .values
            .single;
        final periods = <Object?>[];
        for (var index = 0; index < requests.length; index++) {
          final request = requests[index];
          final warmup = repository.summarize(request);
          final snapshot = _summarySnapshot(warmup);
          if (columns == 'day_utc') {
            expect(snapshot, references[index]);
          } else {
            references.add(snapshot);
          }
          final plan = repository.explainUsageEventAggregation(request);
          expect(plan.join('\n'), isNot(contains('usage_events')));
          final samples = <int>[];
          for (var sample = 0; sample < 7; sample++) {
            final watch = Stopwatch()..start();
            final summary = repository.summarize(request);
            watch.stop();
            samples.add(watch.elapsedMicroseconds);
            // Verification stays outside the production reader's timed region.
            expect(_summarySnapshot(summary), references[index]);
          }
          final sorted = [...samples]..sort();
          periods.add({
            'period': request.period.name,
            'rawUs': samples,
            'medianUs': sorted[3],
            'p95Us': sorted[6],
            'totalTokens': warmup.totalTokens,
            'plan': plan,
          });
        }
        measurements.add({
          'columns': columns,
          'buildUs': build.elapsedMicroseconds,
          'bytes': bytes,
          'periods': periods,
        });
      }
      expect(db.select('pragma foreign_key_check'), isEmpty);
      // ignore: avoid_print
      print(
        'Production Usage index A/B: synthetic file-backed Windows SQLite, '
        '10000 sessions (90% zero-usage),300000 daily rows,256 contexts,8 models,90% local; '
        'Flutter-test JIT;1 excluded warmup+7 samples;nearest-rank p95. $measurements',
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'active usage query searches persisted projections without raw events',
    () {
      final db = sqlite3.openInMemory();
      addTearDown(db.close);
      db.execute('pragma foreign_keys = on');
      final scripts =
          [
            ...Directory('../sql/init').listSync().whereType<File>(),
            ...Directory('../sql/migration').listSync().whereType<File>(),
          ].where((f) => f.path.endsWith('.sql')).toList()..sort(
            (a, b) =>
                a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
          );
      for (final script in scripts) {
        db.execute(script.readAsStringSync());
      }
      final generations = DatabaseGenerationRepository(db);
      final generation = generations.createBuilding(
        sourceSchemaVersion: 15,
        targetSchemaVersion: 16,
        sourceFingerprint: 'query-plan-fixture',
      );
      generations.markReady(generation.id, validationReportJson: '{}');
      generations.activate(generation.id);
      db.execute('''
      insert into sessions (id, source_type, source_file_path, display_path,
        platform_path, parse_status, usage_projection_status, parser_version,
        started_at_utc, created_at_utc, updated_at_utc)
      values ('s', 'windows', 'fixture', 'fixture', 'fixture', 'available',
        'complete', 3, '2026-06-12T00:00:00Z', '2026-06-12', '2026-06-12');
      with recursive days(n) as (select 0 union all select n + 1 from days where n < 999)
      insert into usage_session_daily (session_id, day_utc, model_key,
        path_context_id, branch_scope, input_tokens, cached_input_tokens,
        cache_write_input_tokens, output_tokens, reasoning_output_tokens,
        total_tokens, cost_status, pricing_resolution_method, cost_projection_version, updated_at_utc)
      select 's', date('2026-01-01', '+' || n || ' days'), 'model', 1, 'local',
        1, 0, 0, 0, 0, 1, 'unknown', 'pending_history', 1, '2026-06-12' from days;
      analyze;
    ''');
      final repository = UsageSummaryRepository(db);
      final request = UsageSummaryRequest(
        period: UsagePeriod.today,
        nowUtc: DateTime.utc(2026, 6, 12),
        projectionVersion: 3,
      );
      final plan = repository.explainUsageEventAggregation(request);
      expect(
        plan.any(
          (line) =>
              line.contains('SEARCH d USING INDEX idx_usage_session_daily_') &&
              line.contains('day_utc'),
        ),
        isTrue,
        reason: plan.join('\n'),
      );
      expect(
        plan.any(
          (line) => RegExp(
            r'\b(?:usage_events|usage_events_legacy|e)\b',
          ).hasMatch(line),
        ),
        isFalse,
        reason: 'The production projection query must not access raw events.',
      );
      expect(repository.summarize(request).totalTokens, 1);
      // With many candidate sessions, the day-first partial index becomes the
      // cheaper entry point. Do not force it for the single-session case above.
      db.execute('''
      with recursive extra(n) as (select 1 union all select n + 1 from extra where n < 999)
      insert into sessions (id, source_type, source_file_path, display_path,
        platform_path, parse_status, usage_projection_status, parser_version,
        started_at_utc, created_at_utc, updated_at_utc)
      select 's' || n, 'windows', 'fixture' || n, 'fixture', 'fixture', 'available',
        'complete', 3, '2026-01-01T00:00:00Z', '2026-06-12', '2026-06-12' from extra;
      analyze;
    ''');
      final manySessionPlan = repository.explainUsageEventAggregation(request);
      expect(
        manySessionPlan.any(
          (line) => line.contains('idx_usage_session_daily_billable_day'),
        ),
        isTrue,
        reason: manySessionPlan.join('\n'),
      );
      final coveragePlan = repository.explainUsageProjectionCoverage(request);
      expect(coveragePlan, isNotEmpty);
      expect(
        coveragePlan.every(
          (line) => RegExp(r'^(SCAN|SEARCH) s\b').hasMatch(line),
        ),
        isTrue,
        reason:
            'Coverage should read only persisted session metadata: $coveragePlan',
      );
    },
  );
}

Object _summarySnapshot(UsageSummary summary) {
  List<Object?> breakdown(List<UsageBreakdownRow> rows) => [
    for (final row in rows)
      [
        row.key,
        row.sessionCount,
        row.messageCount,
        row.inputTokens,
        row.outputTokens,
        row.cachedInputTokens,
        row.totalTokens,
        row.estimatedCostText,
        row.costUnknown,
      ],
  ];
  List<Object?> top(List<UsageTopSession> rows) => [
    for (final row in rows)
      [
        row.sessionId,
        row.title,
        row.messageCount,
        row.totalTokens,
        row.estimatedCostText,
        row.costUnknown,
        row.originLabel,
      ],
  ];
  final coverage = summary.projectionCoverage;
  final pricing = summary.pricingStatus;
  return [
    summary.period.startUtc,
    summary.period.endExclusiveUtc,
    summary.totalSessions,
    summary.totalMessages,
    summary.inputTokens,
    summary.cachedInputTokens,
    summary.outputTokens,
    summary.totalTokens,
    summary.estimatedCostText,
    summary.costUnknown,
    summary.mostUsedModel,
    summary.mostActiveProject,
    summary.mostActivePlatform,
    [
      coverage.projectionVersion,
      coverage.availableSessions,
      coverage.currentCompleteSessions,
      coverage.outdatedProjectionSessions,
      coverage.legacyPendingSessions,
      coverage.ambiguousSessions,
      coverage.missingParentSessions,
      coverage.completeZeroUsageSessions,
    ],
    [
      pricing.openRouterFetchedAtUtc,
      pricing.refreshSucceeded,
      pricing.usesHistoricalCosts,
      pricing.updating,
      pricing.partialUnsupportedUnits,
      for (final model in pricing.models)
        [
          model.rawModelId,
          model.effectiveModelId,
          model.resolvedModelId,
          model.resolutionMethod,
          model.source,
          model.fetchedAtUtc,
        ],
    ],
    for (final rows in [
      summary.byDay,
      summary.byWeek,
      summary.byMonth,
      summary.byModel,
      summary.byProject,
      summary.byPlatform,
      summary.byOrigin,
      summary.byArchiveState,
    ])
      breakdown(rows),
    top(summary.topSessionsByTokens),
    top(summary.topSessionsByMessageCount),
    top(summary.topSessionsByEstimatedCost),
  ];
}
