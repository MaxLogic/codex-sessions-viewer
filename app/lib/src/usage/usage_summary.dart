import 'package:sqlite3/sqlite3.dart';

import '../ui/models/session_label_formatter.dart';

enum UsagePeriod {
  today,
  yesterday,
  thisWeek,
  lastWeek,
  thisMonth,
  lastMonth,
  last30Days,
  custom,
}

class UsageSummaryRepository {
  const UsageSummaryRepository(this.db);

  final Database db;

  UsageSummary summarize(
    UsageSummaryRequest request, {
    UsagePricingCatalog pricing = const UsagePricingCatalog({}),
    Set<String> includeSessionIds = const {},
    bool pricingRefreshSucceeded = true,
  }) {
    final range = request.resolve();
    final sessions = _loadSessions(range, includeSessionIds);
    final usageGroups = _loadUsageEventGroups(
      range,
      includeSessionIds,
      request.projectionVersion,
    );
    final coverage = request.projectionVersion == null
        ? const UsageProjectionCoverage.empty()
        : _loadProjectionCoverage(
            range,
            includeSessionIds,
            request.projectionVersion!,
          );
    return _summarizeSessions(
      sessions,
      usageGroups,
      pricing,
      range,
      coverage,
      pricingRefreshSucceeded,
    );
  }

  void rebuildDailyUsage({
    required int projectionVersion,
    UsagePricingCatalog pricing = const UsagePricingCatalog({}),
  }) {
    db.execute('begin immediate');
    try {
      rebuildDailyUsageInCurrentTransaction(
        projectionVersion: projectionVersion,
        pricing: pricing,
      );
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

  void rebuildDailyUsageInCurrentTransaction({
    required int projectionVersion,
    UsagePricingCatalog pricing = const UsagePricingCatalog({}),
  }) {
    final sessions = _loadSessions(null, const {});
    final sessionGroups = <_DailyUsageKey, List<_UsageSession>>{};
    for (final session in sessions) {
      final day = _dayKey(session.startedAtUtc);
      if (day == null) {
        continue;
      }
      final key = _DailyUsageKey(
        dayUtc: day,
        model: session.modelPrimary,
        projectId: session.projectId,
        sourceType: session.sourceType,
        isArchived: session.isArchived,
      );
      sessionGroups.putIfAbsent(key, () => []).add(session);
    }
    final eventGroups = <_DailyUsageKey, List<_UsageEventGroup>>{};
    for (final event in _loadUsageEventGroups(
      null,
      const {},
      projectionVersion,
    )) {
      final key = _DailyUsageKey(
        dayUtc: event.dayUtc,
        model: event.model,
        projectId: event.projectId,
        sourceType: event.sourceType,
        isArchived: event.isArchived,
      );
      eventGroups.putIfAbsent(key, () => []).add(event);
    }

    final keys = {...sessionGroups.keys, ...eventGroups.keys};
    final rows = [
      for (final key in keys)
        (
          key: key,
          aggregate: _aggregateUsageGroups(
            eventGroups[key] ?? const [],
            pricing,
            sessionCount: sessionGroups[key]?.length ?? 0,
            messageCount: (sessionGroups[key] ?? const []).fold(
              0,
              (sum, row) => sum + row.messageCount,
            ),
          ),
        ),
    ];
    db.execute('delete from usage_daily');
    for (final row in rows) {
      final key = row.key;
      final aggregate = row.aggregate;
      db.execute(
        '''
          insert into usage_daily (
            day_utc, model, project_id, source_type, is_archived, session_count,
            message_count, input_tokens, output_tokens, cached_input_tokens,
            total_tokens, estimated_cost_text
          ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''',
        [
          key.dayUtc,
          key.model,
          key.projectId,
          key.sourceType,
          key.isArchived ? 1 : 0,
          aggregate.sessionCount,
          aggregate.messageCount,
          aggregate.inputTokens,
          aggregate.outputTokens,
          aggregate.cachedInputTokens,
          aggregate.totalTokens,
          aggregate.costUnknown ? null : aggregate.estimatedCostText,
        ],
      );
    }
  }

  List<_UsageSession> _loadSessions(
    UsageDateRange? range,
    Set<String> includeSessionIds,
  ) {
    final where = <String>[
      "parse_status = 'available'",
      'started_at_utc is not null',
    ];
    final args = <Object?>[];
    if (range != null) {
      where.add('started_at_utc >= ?');
      args.add(range.startUtc.toIso8601String());
      where.add('started_at_utc < ?');
      args.add(range.endExclusiveUtc.toIso8601String());
    }
    if (includeSessionIds.isNotEmpty) {
      where.add(
        'id in (${List.filled(includeSessionIds.length, '?').join(', ')})',
      );
      args.addAll(includeSessionIds);
    }
    final rows = db.select('''
      select
        id, source_type, started_at_utc, title, message_count, input_tokens,
        output_tokens, cached_input_tokens, total_tokens, model_primary,
        project_id, project_name_snapshot, is_archived, thread_source
      from sessions
      where ${where.join(' and ')}
      order by started_at_utc, id
      ''', args);
    return rows.map(_UsageSession.fromRow).toList(growable: false);
  }

  List<_UsageEventGroup> _loadUsageEventGroups(
    UsageDateRange? range,
    Set<String> includeSessionIds,
    int? projectionVersion,
  ) {
    final where = <String>[
      "s.parse_status = 'available'",
      "s.usage_projection_status = 'complete'",
      'e.occurred_at_utc is not null',
    ];
    final args = <Object?>[];
    if (range != null) {
      where.add('e.occurred_at_utc >= ?');
      args.add(range.startUtc.toIso8601String());
      where.add('e.occurred_at_utc < ?');
      args.add(range.endExclusiveUtc.toIso8601String());
    }
    if (includeSessionIds.isNotEmpty) {
      where.add(
        'e.session_row_id in '
        '(${List.filled(includeSessionIds.length, '?').join(', ')})',
      );
      args.addAll(includeSessionIds);
    }
    if (projectionVersion != null) {
      where.add('s.parser_version = ?');
      args.add(projectionVersion);
    }
    final rows = db.select(
      _usageEventAggregationSql(where.join(' and ')),
      args,
    );
    return rows.map(_UsageEventGroup.fromRow).toList(growable: false);
  }

  List<String> explainUsageEventAggregation(UsageSummaryRequest request) {
    final range = request.resolve();
    final where = <String>[
      "s.parse_status = 'available'",
      "s.usage_projection_status = 'complete'",
      'e.occurred_at_utc is not null',
      'e.occurred_at_utc >= ?',
      'e.occurred_at_utc < ?',
    ];
    final args = <Object?>[
      range.startUtc.toIso8601String(),
      range.endExclusiveUtc.toIso8601String(),
    ];
    if (request.projectionVersion case final projectionVersion?) {
      where.add('s.parser_version = ?');
      args.add(projectionVersion);
    }
    final sql = _usageEventAggregationSql(where.join(' and '));
    return [
      for (final row in db.select('explain query plan $sql', args))
        row['detail'] as String,
    ];
  }

  UsageProjectionCoverage _loadProjectionCoverage(
    UsageDateRange range,
    Set<String> includeSessionIds,
    int projectionVersion,
  ) {
    final where = <String>[
      "s.parse_status = 'available'",
      's.started_at_utc is not null',
      's.started_at_utc >= ?',
      's.started_at_utc < ?',
    ];
    final args = <Object?>[
      projectionVersion,
      projectionVersion,
      projectionVersion,
      range.startUtc.toIso8601String(),
      range.endExclusiveUtc.toIso8601String(),
    ];
    if (includeSessionIds.isNotEmpty) {
      where.add(
        's.id in (${List.filled(includeSessionIds.length, '?').join(', ')})',
      );
      args.addAll(includeSessionIds);
    }
    final row = db.select('''
      select
        count(*) as available_sessions,
        coalesce(sum(case
          when s.parser_version = ?
            and s.usage_projection_status = 'complete' then 1 else 0
        end), 0) as current_complete_sessions,
        coalesce(sum(case
          when s.parser_version is not ?
            and s.usage_projection_status = 'complete' then 1 else 0
        end), 0) as outdated_projection_sessions,
        coalesce(sum(case
          when s.usage_projection_status = 'legacy_pending' then 1 else 0
        end), 0) as legacy_pending_sessions,
        coalesce(sum(case
          when s.usage_projection_status = 'ambiguous' then 1 else 0
        end), 0) as ambiguous_sessions,
        coalesce(sum(case
          when s.usage_projection_status = 'missing_parent' then 1 else 0
        end), 0) as missing_parent_sessions,
        coalesce(sum(case
          when s.parser_version = ?
            and s.usage_projection_status = 'complete'
            and not exists (
              select 1
              from billable_usage_events e
              where e.session_row_id = s.id
            )
          then 1 else 0
        end), 0) as complete_zero_usage_sessions
      from sessions s
      where ${where.join(' and ')}
      ''', args).single;
    return UsageProjectionCoverage(
      projectionVersion: projectionVersion,
      availableSessions: row['available_sessions'] as int,
      currentCompleteSessions: row['current_complete_sessions'] as int,
      outdatedProjectionSessions: row['outdated_projection_sessions'] as int,
      legacyPendingSessions: row['legacy_pending_sessions'] as int,
      ambiguousSessions: row['ambiguous_sessions'] as int,
      missingParentSessions: row['missing_parent_sessions'] as int,
      completeZeroUsageSessions: row['complete_zero_usage_sessions'] as int,
    );
  }
}

String _usageEventAggregationSql(String whereSql) =>
    '''
  select
    e.session_row_id,
    substr(e.occurred_at_utc, 1, 10) as day_utc,
    e.model,
    case
      when s.project_override = 1 then s.project_id
      else e.project_id
    end as project_id,
    case
      when s.project_override = 1
        then coalesce(effective_project.name, s.project_name_snapshot)
      else effective_project.name
    end as project_name,
    s.source_type,
    s.is_archived,
    s.title,
    s.message_count,
    s.thread_source,
    sum(e.input_tokens) as input_tokens,
    sum(e.cached_input_tokens) as cached_input_tokens,
    sum(e.cache_write_input_tokens) as cache_write_input_tokens,
    sum(e.output_tokens) as output_tokens,
    sum(e.reasoning_output_tokens) as reasoning_output_tokens,
    sum(
      case
        when e.total_tokens = e.input_tokens + e.output_tokens
          then e.total_tokens
        else e.input_tokens + e.output_tokens
      end
    ) as total_tokens,
    sum(
      case
        when e.cached_input_tokens + e.cache_write_input_tokens >
             e.input_tokens
          or e.reasoning_output_tokens > e.output_tokens
        then 1
        else 0
      end
    ) as invalid_bucket_count
  from billable_usage_events e
  cross join sessions s on s.id = e.session_row_id
  left join projects effective_project on effective_project.id = case
    when s.project_override = 1 then s.project_id
    else e.project_id
  end
  where $whereSql
  group by
    e.session_row_id,
    substr(e.occurred_at_utc, 1, 10),
    e.model,
    case
      when s.project_override = 1 then s.project_id
      else e.project_id
    end,
    case
      when s.project_override = 1
        then coalesce(effective_project.name, s.project_name_snapshot)
      else effective_project.name
    end,
    s.source_type,
    s.is_archived,
    s.title,
    s.message_count,
    s.thread_source
  ''';

class UsageSummaryRequest {
  const UsageSummaryRequest({
    required this.period,
    required this.nowUtc,
    this.customStartUtc,
    this.customEndExclusiveUtc,
    this.projectionVersion,
  });

  final UsagePeriod period;
  final DateTime nowUtc;
  final DateTime? customStartUtc;
  final DateTime? customEndExclusiveUtc;
  final int? projectionVersion;

  UsageDateRange resolve() {
    final now = nowUtc.toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    return switch (period) {
      UsagePeriod.today => UsageDateRange(
        startUtc: today,
        endExclusiveUtc: today.add(const Duration(days: 1)),
      ),
      UsagePeriod.yesterday => UsageDateRange(
        startUtc: today.subtract(const Duration(days: 1)),
        endExclusiveUtc: today,
      ),
      UsagePeriod.thisWeek => UsageDateRange(
        startUtc: today.subtract(Duration(days: today.weekday - 1)),
        endExclusiveUtc: today.add(const Duration(days: 1)),
      ),
      UsagePeriod.lastWeek => _lastWeek(today),
      UsagePeriod.thisMonth => UsageDateRange(
        startUtc: DateTime.utc(today.year, today.month),
        endExclusiveUtc: today.add(const Duration(days: 1)),
      ),
      UsagePeriod.lastMonth => _lastMonth(today),
      UsagePeriod.last30Days => UsageDateRange(
        startUtc: today.subtract(const Duration(days: 29)),
        endExclusiveUtc: today.add(const Duration(days: 1)),
      ),
      UsagePeriod.custom => UsageDateRange(
        startUtc: customStartUtc?.toUtc() ?? today,
        endExclusiveUtc:
            customEndExclusiveUtc?.toUtc() ??
            today.add(const Duration(days: 1)),
      ),
    };
  }
}

class UsageDateRange {
  const UsageDateRange({required this.startUtc, required this.endExclusiveUtc});

  final DateTime startUtc;
  final DateTime endExclusiveUtc;
}

class UsagePricingCatalog {
  const UsagePricingCatalog(this.models);

  final Map<String, UsageModelPricing> models;

  UsageModelPricing? operator [](String? modelId) => resolve(modelId).pricing;

  UsageModelResolution resolve(String? modelId) {
    if (modelId == null) {
      return const UsageModelResolution.unknown(null);
    }
    final exact = models[modelId];
    if (exact != null) {
      return UsageModelResolution(
        requestedModelId: modelId,
        resolvedModelId: modelId,
        method: UsageModelResolutionMethod.exact,
        pricing: exact,
      );
    }
    if (modelId.startsWith('gpt-') && !modelId.contains('/')) {
      final openAiModelId = 'openai/$modelId';
      final openAiExact = models[openAiModelId];
      if (openAiExact != null) {
        return UsageModelResolution(
          requestedModelId: modelId,
          resolvedModelId: openAiModelId,
          method: UsageModelResolutionMethod.openAiExact,
          pricing: openAiExact,
        );
      }
    }
    return UsageModelResolution.unknown(modelId);
  }

  DateTime? get openRouterFetchedAtUtc {
    DateTime? latest;
    for (final pricing in models.values) {
      final fetchedAt = pricing.source == 'openrouter'
          ? pricing.fetchedAtUtc
          : null;
      if (fetchedAt != null && (latest == null || fetchedAt.isAfter(latest))) {
        latest = fetchedAt;
      }
    }
    return latest;
  }

  Duration? openRouterCacheAge(DateTime nowUtc) {
    final fetchedAt = openRouterFetchedAtUtc;
    if (fetchedAt == null) {
      return null;
    }
    final age = nowUtc.toUtc().difference(fetchedAt);
    return age.isNegative ? Duration.zero : age;
  }
}

enum UsageModelResolutionMethod { exact, openAiExact, unknown }

class UsageModelResolution {
  const UsageModelResolution({
    required this.requestedModelId,
    required this.resolvedModelId,
    required this.method,
    required this.pricing,
  });

  const UsageModelResolution.unknown(String? requestedModelId)
    : this(
        requestedModelId: requestedModelId,
        resolvedModelId: null,
        method: UsageModelResolutionMethod.unknown,
        pricing: null,
      );

  final String? requestedModelId;
  final String? resolvedModelId;
  final UsageModelResolutionMethod method;
  final UsageModelPricing? pricing;
}

class UsageModelPricing {
  const UsageModelPricing({
    this.promptPricePerToken,
    this.completionPricePerToken,
    this.cachedInputPricePerToken,
    this.cacheWriteInputPricePerToken,
    this.internalReasoningPricePerToken,
    this.source,
    this.fetchedAtUtc,
  });

  final String? promptPricePerToken;
  final String? completionPricePerToken;
  final String? cachedInputPricePerToken;
  final String? cacheWriteInputPricePerToken;
  final String? internalReasoningPricePerToken;
  final String? source;
  final DateTime? fetchedAtUtc;
}

class UsageCostEstimate {
  const UsageCostEstimate({
    required this.estimatedCostText,
    required this.costUnknown,
  });

  final String? estimatedCostText;
  final bool costUnknown;

  String get estimatedCostDisplay =>
      costUnknown ? 'Cost unknown' : '\$${estimatedCostText ?? '0'}';
}

UsageCostEstimate estimateUsageCost({
  required int? inputTokens,
  required int? outputTokens,
  required int? cachedInputTokens,
  int? cacheWriteInputTokens = 0,
  int? reasoningOutputTokens = 0,
  required String? model,
  required UsagePricingCatalog pricing,
}) {
  final cost = _costForTokenUsage(
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cachedInputTokens: cachedInputTokens,
    cacheWriteInputTokens: cacheWriteInputTokens,
    reasoningOutputTokens: reasoningOutputTokens,
    model: model,
    pricingCatalog: pricing,
  );
  return UsageCostEstimate(
    estimatedCostText: cost?.toDecimalString(),
    costUnknown: cost == null,
  );
}

String? sumEstimatedCostTexts(Iterable<String?> values) {
  var total = _DecimalAmount.zero;
  for (final value in values) {
    if (value == null) {
      return null;
    }
    try {
      total += _DecimalAmount.parse(value);
    } on FormatException {
      return null;
    }
  }
  return total.toDecimalString();
}

class UsageSummary {
  const UsageSummary({
    required this.period,
    required this.totalSessions,
    required this.totalMessages,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedInputTokens,
    required this.totalTokens,
    required this.estimatedCostText,
    required this.costUnknown,
    this.projectionCoverage = const UsageProjectionCoverage.empty(),
    this.pricingStatus = const UsagePricingStatus.empty(),
    required this.mostUsedModel,
    required this.mostActiveProject,
    required this.mostActivePlatform,
    required this.byDay,
    required this.byWeek,
    required this.byMonth,
    required this.byModel,
    required this.byProject,
    required this.byPlatform,
    required this.byOrigin,
    required this.byArchiveState,
    required this.topSessionsByTokens,
    required this.topSessionsByMessageCount,
    required this.topSessionsByEstimatedCost,
  });

  final UsageDateRange period;
  final int totalSessions;
  final int totalMessages;
  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;
  final int totalTokens;
  final String? estimatedCostText;
  final bool costUnknown;
  final UsageProjectionCoverage projectionCoverage;
  final UsagePricingStatus pricingStatus;
  final String? mostUsedModel;
  final String? mostActiveProject;
  final String? mostActivePlatform;
  final List<UsageBreakdownRow> byDay;
  final List<UsageBreakdownRow> byWeek;
  final List<UsageBreakdownRow> byMonth;
  final List<UsageBreakdownRow> byModel;
  final List<UsageBreakdownRow> byProject;
  final List<UsageBreakdownRow> byPlatform;
  final List<UsageBreakdownRow> byOrigin;
  final List<UsageBreakdownRow> byArchiveState;
  final List<UsageTopSession> topSessionsByTokens;
  final List<UsageTopSession> topSessionsByMessageCount;
  final List<UsageTopSession> topSessionsByEstimatedCost;

  String get estimatedCostDisplay =>
      costUnknown ? 'Cost unknown' : estimatedCostText ?? '0';
}

class UsageProjectionCoverage {
  const UsageProjectionCoverage({
    required this.projectionVersion,
    required this.availableSessions,
    required this.currentCompleteSessions,
    this.outdatedProjectionSessions = 0,
    required this.legacyPendingSessions,
    required this.ambiguousSessions,
    required this.missingParentSessions,
    required this.completeZeroUsageSessions,
  });

  const UsageProjectionCoverage.empty()
    : projectionVersion = null,
      availableSessions = 0,
      currentCompleteSessions = 0,
      outdatedProjectionSessions = 0,
      legacyPendingSessions = 0,
      ambiguousSessions = 0,
      missingParentSessions = 0,
      completeZeroUsageSessions = 0;

  final int? projectionVersion;
  final int availableSessions;
  final int currentCompleteSessions;
  final int outdatedProjectionSessions;
  final int legacyPendingSessions;
  final int ambiguousSessions;
  final int missingParentSessions;
  final int completeZeroUsageSessions;
}

class UsagePricingStatus {
  const UsagePricingStatus({
    required this.openRouterFetchedAtUtc,
    required this.models,
    this.refreshSucceeded = true,
  });

  const UsagePricingStatus.empty()
    : openRouterFetchedAtUtc = null,
      models = const [],
      refreshSucceeded = true;

  final DateTime? openRouterFetchedAtUtc;
  final List<UsageModelPricingStatus> models;
  final bool refreshSucceeded;
}

class UsageModelPricingStatus {
  const UsageModelPricingStatus({
    required this.rawModelId,
    required this.effectiveModelId,
    required this.resolvedModelId,
    required this.resolutionMethod,
    required this.source,
    this.fetchedAtUtc,
  });

  final String rawModelId;
  final String effectiveModelId;
  final String? resolvedModelId;
  final UsageModelResolutionMethod resolutionMethod;
  final String? source;
  final DateTime? fetchedAtUtc;

  String get cacheState => switch (source) {
    'openrouter' => 'cached',
    'override' => 'override',
    _ => 'unavailable',
  };
}

class UsageBreakdownRow {
  const UsageBreakdownRow({
    required this.key,
    required this.sessionCount,
    required this.messageCount,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedInputTokens,
    required this.totalTokens,
    required this.estimatedCostText,
    required this.costUnknown,
  });

  final String key;
  final int sessionCount;
  final int messageCount;
  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;
  final int totalTokens;
  final String? estimatedCostText;
  final bool costUnknown;
}

class UsageTopSession {
  const UsageTopSession({
    required this.sessionId,
    required this.title,
    required this.messageCount,
    required this.totalTokens,
    required this.estimatedCostText,
    required this.costUnknown,
    required this.originLabel,
  });

  final String sessionId;
  final String title;
  final int messageCount;
  final int totalTokens;
  final String? estimatedCostText;
  final bool costUnknown;
  final String originLabel;
}

UsageSummary _summarizeSessions(
  List<_UsageSession> sessions,
  List<_UsageEventGroup> usageGroups,
  UsagePricingCatalog pricing,
  UsageDateRange range,
  UsageProjectionCoverage projectionCoverage,
  bool pricingRefreshSucceeded,
) {
  final aggregate = _aggregateUsageGroups(
    usageGroups,
    pricing,
    sessionCount: sessions.length,
    messageCount: sessions.fold(0, (sum, row) => sum + row.messageCount),
  );
  final byModel = _breakdown(
    sessions,
    usageGroups,
    pricing,
    (session) => SessionLabelFormatter.model(session.modelPrimary),
    (event) => SessionLabelFormatter.model(event.model),
  );
  final byProject = _breakdown(
    sessions,
    usageGroups,
    pricing,
    (session) => session.projectName ?? 'Unknown',
    (event) => event.projectName ?? 'Unknown',
  );
  final byPlatform = _breakdown(
    sessions,
    usageGroups,
    pricing,
    (session) => SessionLabelFormatter.sourceType(session.sourceType),
    (event) => SessionLabelFormatter.sourceType(event.sourceType),
  );
  final byOrigin = _breakdown(
    sessions,
    usageGroups,
    pricing,
    _originLabel,
    _eventOriginLabel,
  );
  return UsageSummary(
    period: range,
    totalSessions: aggregate.sessionCount,
    totalMessages: aggregate.messageCount,
    inputTokens: aggregate.inputTokens,
    outputTokens: aggregate.outputTokens,
    cachedInputTokens: aggregate.cachedInputTokens,
    totalTokens: aggregate.totalTokens,
    estimatedCostText: aggregate.estimatedCostText,
    costUnknown: aggregate.costUnknown,
    projectionCoverage: projectionCoverage,
    pricingStatus: _pricingStatus(
      usageGroups,
      pricing,
      pricingRefreshSucceeded,
    ),
    mostUsedModel: _mostActive(byModel),
    mostActiveProject: _mostActive(byProject),
    mostActivePlatform: _mostActive(byPlatform),
    byDay: _breakdown(
      sessions,
      usageGroups,
      pricing,
      (session) => _dayKey(session.startedAtUtc) ?? 'Unknown',
      (event) => event.dayUtc,
    ),
    byWeek: _breakdown(
      sessions,
      usageGroups,
      pricing,
      (session) => _weekKey(session.startedAtUtc) ?? 'Unknown',
      (event) => _weekKey(event.day) ?? 'Unknown',
    ),
    byMonth: _breakdown(
      sessions,
      usageGroups,
      pricing,
      (session) => _monthKey(session.startedAtUtc) ?? 'Unknown',
      (event) => event.dayUtc.substring(0, 7),
    ),
    byModel: byModel,
    byProject: byProject,
    byPlatform: byPlatform,
    byOrigin: byOrigin,
    byArchiveState: _breakdown(
      sessions,
      usageGroups,
      pricing,
      (session) => session.isArchived ? 'archived' : 'active',
      (event) => event.isArchived ? 'archived' : 'active',
    ),
    topSessionsByTokens: _topUsageSessions(usageGroups, pricing, byCost: false),
    topSessionsByMessageCount: _topMessageSessions(
      sessions,
      usageGroups,
      pricing,
    ),
    topSessionsByEstimatedCost: _topUsageSessions(
      usageGroups,
      pricing,
      byCost: true,
    ),
  );
}

UsagePricingStatus _pricingStatus(
  List<_UsageEventGroup> usageGroups,
  UsagePricingCatalog pricing,
  bool refreshSucceeded,
) {
  final models = <String?>{
    for (final group in usageGroups) group.model,
  }.toList()..sort((left, right) => (left ?? '').compareTo(right ?? ''));
  return UsagePricingStatus(
    openRouterFetchedAtUtc: pricing.openRouterFetchedAtUtc,
    refreshSucceeded: refreshSucceeded,
    models: [
      for (final model in models)
        _modelPricingStatus(model, pricing.resolve(model)),
    ],
  );
}

UsageModelPricingStatus _modelPricingStatus(
  String? model,
  UsageModelResolution resolution,
) {
  return UsageModelPricingStatus(
    rawModelId: model ?? 'Unknown',
    effectiveModelId: model ?? 'Unknown',
    resolvedModelId: resolution.resolvedModelId,
    resolutionMethod: resolution.method,
    source: resolution.pricing?.source,
    fetchedAtUtc: resolution.pricing?.fetchedAtUtc,
  );
}

List<UsageBreakdownRow> _breakdown(
  List<_UsageSession> sessions,
  List<_UsageEventGroup> usageGroups,
  UsagePricingCatalog pricing,
  String Function(_UsageSession session) sessionKeyOf,
  String Function(_UsageEventGroup event) eventKeyOf,
) {
  final sessionGroups = <String, List<_UsageSession>>{};
  for (final session in sessions) {
    sessionGroups.putIfAbsent(sessionKeyOf(session), () => []).add(session);
  }
  final eventGroups = <String, List<_UsageEventGroup>>{};
  for (final event in usageGroups) {
    eventGroups.putIfAbsent(eventKeyOf(event), () => []).add(event);
  }
  final keys = {...sessionGroups.keys, ...eventGroups.keys};
  final rows = [
    for (final key in keys)
      _breakdownRow(
        key,
        sessionGroups[key] ?? const [],
        eventGroups[key] ?? const [],
        pricing,
      ),
  ];
  rows.sort((left, right) {
    final byTokens = right.totalTokens.compareTo(left.totalTokens);
    if (byTokens != 0) {
      return byTokens;
    }
    final bySessions = right.sessionCount.compareTo(left.sessionCount);
    if (bySessions != 0) {
      return bySessions;
    }
    return left.key.compareTo(right.key);
  });
  return rows;
}

UsageBreakdownRow _breakdownRow(
  String key,
  List<_UsageSession> sessions,
  List<_UsageEventGroup> usageGroups,
  UsagePricingCatalog pricing,
) {
  final aggregate = _aggregateUsageGroups(
    usageGroups,
    pricing,
    sessionCount: sessions.length,
    messageCount: sessions.fold(0, (sum, row) => sum + row.messageCount),
  );
  return UsageBreakdownRow(
    key: key,
    sessionCount: aggregate.sessionCount,
    messageCount: aggregate.messageCount,
    inputTokens: aggregate.inputTokens,
    outputTokens: aggregate.outputTokens,
    cachedInputTokens: aggregate.cachedInputTokens,
    totalTokens: aggregate.totalTokens,
    estimatedCostText: aggregate.estimatedCostText,
    costUnknown: aggregate.costUnknown,
  );
}

_UsageAggregate _aggregateUsageGroups(
  List<_UsageEventGroup> usageGroups,
  UsagePricingCatalog pricing, {
  int sessionCount = 0,
  int messageCount = 0,
}) {
  var inputTokens = 0;
  var outputTokens = 0;
  var cachedInputTokens = 0;
  var totalTokens = 0;
  var cost = _DecimalAmount.zero;
  var costUnknown = false;
  for (final group in usageGroups) {
    inputTokens += group.inputTokens;
    outputTokens += group.outputTokens;
    cachedInputTokens += group.cachedInputTokens;
    totalTokens += group.totalTokens;
    final groupCost = group.invalidBucketCount == 0
        ? _costForTokenUsage(
            inputTokens: group.inputTokens,
            outputTokens: group.outputTokens,
            cachedInputTokens: group.cachedInputTokens,
            cacheWriteInputTokens: group.cacheWriteInputTokens,
            reasoningOutputTokens: group.reasoningOutputTokens,
            model: group.model,
            pricingCatalog: pricing,
          )
        : null;
    if (groupCost == null) {
      costUnknown = true;
    } else {
      cost += groupCost;
    }
  }
  return _UsageAggregate(
    sessionCount: sessionCount,
    messageCount: messageCount,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cachedInputTokens: cachedInputTokens,
    totalTokens: totalTokens,
    estimatedCostText: costUnknown ? null : cost.toDecimalString(),
    costUnknown: costUnknown,
  );
}

_DecimalAmount? _costForTokenUsage({
  required int? inputTokens,
  required int? outputTokens,
  required int? cachedInputTokens,
  required int? cacheWriteInputTokens,
  required int? reasoningOutputTokens,
  required String? model,
  required UsagePricingCatalog pricingCatalog,
}) {
  if (inputTokens == 0 &&
      outputTokens == 0 &&
      cachedInputTokens == 0 &&
      cacheWriteInputTokens == 0 &&
      reasoningOutputTokens == 0) {
    return _DecimalAmount.zero;
  }
  if (inputTokens == null ||
      outputTokens == null ||
      cachedInputTokens == null ||
      cacheWriteInputTokens == null ||
      reasoningOutputTokens == null) {
    return null;
  }
  if (inputTokens < 0 ||
      outputTokens < 0 ||
      cachedInputTokens < 0 ||
      cacheWriteInputTokens < 0 ||
      reasoningOutputTokens < 0 ||
      cachedInputTokens + cacheWriteInputTokens > inputTokens ||
      reasoningOutputTokens > outputTokens) {
    return null;
  }
  final pricing = pricingCatalog[model];
  if (pricing == null) {
    return null;
  }
  final ordinaryInputTokens =
      inputTokens - cachedInputTokens - cacheWriteInputTokens;
  final prompt = _pricedTokens(
    ordinaryInputTokens,
    pricing.promptPricePerToken,
  );
  final completion = _pricedTokens(
    outputTokens,
    pricing.completionPricePerToken,
  );
  final cached = _pricedTokens(
    cachedInputTokens,
    pricing.cachedInputPricePerToken,
  );
  final cacheWrite = _pricedTokens(
    cacheWriteInputTokens,
    pricing.cacheWriteInputPricePerToken,
  );
  if (prompt == null ||
      completion == null ||
      cached == null ||
      cacheWrite == null) {
    return null;
  }
  return prompt + completion + cached + cacheWrite;
}

_DecimalAmount? _pricedTokens(int tokens, String? pricePerToken) {
  if (tokens == 0) {
    return _DecimalAmount.zero;
  }
  if (pricePerToken == null) {
    return null;
  }
  try {
    final price = _DecimalAmount.parse(pricePerToken);
    if (price.compareTo(_DecimalAmount.zero) < 0) {
      return null;
    }
    return price * tokens;
  } on FormatException {
    return null;
  }
}

List<UsageTopSession> _topUsageSessions(
  List<_UsageEventGroup> usageGroups,
  UsagePricingCatalog pricing, {
  required bool byCost,
}) {
  final bySession = <String, List<_UsageEventGroup>>{};
  for (final group in usageGroups) {
    bySession.putIfAbsent(group.sessionId, () => []).add(group);
  }
  final rows = [
    for (final entry in bySession.entries)
      (
        representative: entry.value.first,
        aggregate: _aggregateUsageGroups(entry.value, pricing),
      ),
  ];
  rows.sort((left, right) {
    if (byCost) {
      final leftCost = left.aggregate.costUnknown
          ? null
          : _DecimalAmount.parse(left.aggregate.estimatedCostText ?? '0');
      final rightCost = right.aggregate.costUnknown
          ? null
          : _DecimalAmount.parse(right.aggregate.estimatedCostText ?? '0');
      if (leftCost == null && rightCost != null) {
        return 1;
      }
      if (leftCost != null && rightCost == null) {
        return -1;
      }
      if (leftCost != null && rightCost != null) {
        final costCompare = rightCost.compareTo(leftCost);
        if (costCompare != 0) {
          return costCompare;
        }
      }
    } else {
      final tokenCompare = right.aggregate.totalTokens.compareTo(
        left.aggregate.totalTokens,
      );
      if (tokenCompare != 0) {
        return tokenCompare;
      }
    }
    return left.representative.sessionId.compareTo(
      right.representative.sessionId,
    );
  });
  return rows
      .take(10)
      .map((row) {
        final event = row.representative;
        final aggregate = row.aggregate;
        return UsageTopSession(
          sessionId: event.sessionId,
          title: event.title,
          messageCount: event.messageCount,
          totalTokens: aggregate.totalTokens,
          estimatedCostText: aggregate.estimatedCostText,
          costUnknown: aggregate.costUnknown,
          originLabel: _eventOriginLabel(event),
        );
      })
      .toList(growable: false);
}

List<UsageTopSession> _topMessageSessions(
  List<_UsageSession> sessions,
  List<_UsageEventGroup> usageGroups,
  UsagePricingCatalog pricing,
) {
  final usageBySession = <String, List<_UsageEventGroup>>{};
  for (final group in usageGroups) {
    usageBySession.putIfAbsent(group.sessionId, () => []).add(group);
  }
  final sorted = [...sessions]
    ..sort((left, right) {
      final messageCompare = right.messageCount.compareTo(left.messageCount);
      if (messageCompare != 0) {
        return messageCompare;
      }
      return left.id.compareTo(right.id);
    });
  return sorted
      .take(10)
      .map((session) {
        final aggregate = _aggregateUsageGroups(
          usageBySession[session.id] ?? const [],
          pricing,
        );
        return UsageTopSession(
          sessionId: session.id,
          title: session.title,
          messageCount: session.messageCount,
          totalTokens: aggregate.totalTokens,
          estimatedCostText: aggregate.estimatedCostText,
          costUnknown: aggregate.costUnknown,
          originLabel: _originLabel(session),
        );
      })
      .toList(growable: false);
}

String _eventOriginLabel(_UsageEventGroup event) {
  return SessionLabelFormatter.origin(
    threadSource: event.threadSource,
    agentNickname: null,
  );
}

String _originLabel(_UsageSession session) {
  return SessionLabelFormatter.origin(
    threadSource: session.threadSource,
    agentNickname: null,
  );
}

String? _mostActive(List<UsageBreakdownRow> rows) =>
    rows.isEmpty ? null : rows.first.key;

UsageDateRange _lastWeek(DateTime todayUtc) {
  final thisWeekStart = todayUtc.subtract(Duration(days: todayUtc.weekday - 1));
  return UsageDateRange(
    startUtc: thisWeekStart.subtract(const Duration(days: 7)),
    endExclusiveUtc: thisWeekStart,
  );
}

UsageDateRange _lastMonth(DateTime todayUtc) {
  final thisMonthStart = DateTime.utc(todayUtc.year, todayUtc.month);
  final lastMonthStart = DateTime.utc(todayUtc.year, todayUtc.month - 1);
  return UsageDateRange(
    startUtc: lastMonthStart,
    endExclusiveUtc: thisMonthStart,
  );
}

String? _dayKey(DateTime? value) {
  if (value == null) {
    return null;
  }
  final utc = value.toUtc();
  return '${_fourDigits(utc.year)}-${_twoDigits(utc.month)}-'
      '${_twoDigits(utc.day)}';
}

String? _weekKey(DateTime? value) {
  if (value == null) {
    return null;
  }
  final utc = value.toUtc();
  final monday = DateTime.utc(
    utc.year,
    utc.month,
    utc.day,
  ).subtract(Duration(days: utc.weekday - 1));
  final isoYear = _isoWeekYear(monday);
  return '${_fourDigits(isoYear)}-W${_twoDigits(_isoWeek(monday))}';
}

String? _monthKey(DateTime? value) {
  if (value == null) {
    return null;
  }
  final utc = value.toUtc();
  return '${_fourDigits(utc.year)}-${_twoDigits(utc.month)}';
}

int _isoWeek(DateTime mondayUtc) {
  final thursday = mondayUtc.add(const Duration(days: 3));
  final firstThursday = DateTime.utc(thursday.year, 1, 4);
  final firstMonday = firstThursday.subtract(
    Duration(days: firstThursday.weekday - 1),
  );
  return thursday.difference(firstMonday).inDays ~/ 7 + 1;
}

int _isoWeekYear(DateTime mondayUtc) =>
    mondayUtc.add(const Duration(days: 3)).year;

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _fourDigits(int value) => value.toString().padLeft(4, '0');

class _UsageEventGroup {
  const _UsageEventGroup({
    required this.sessionId,
    required this.dayUtc,
    required this.model,
    required this.projectId,
    required this.projectName,
    required this.sourceType,
    required this.isArchived,
    required this.title,
    required this.messageCount,
    required this.threadSource,
    required this.inputTokens,
    required this.cachedInputTokens,
    required this.cacheWriteInputTokens,
    required this.outputTokens,
    required this.reasoningOutputTokens,
    required this.totalTokens,
    required this.invalidBucketCount,
  });

  factory _UsageEventGroup.fromRow(Row row) => _UsageEventGroup(
    sessionId: row['session_row_id'] as String,
    dayUtc: row['day_utc'] as String,
    model: row['model'] as String?,
    projectId: row['project_id'] as int?,
    projectName: row['project_name'] as String?,
    sourceType: row['source_type'] as String,
    isArchived: _rowInt(row['is_archived']) == 1,
    title: row['title'] as String? ?? '',
    messageCount: _rowInt(row['message_count']),
    threadSource: row['thread_source'] as String?,
    inputTokens: _rowInt(row['input_tokens']),
    cachedInputTokens: _rowInt(row['cached_input_tokens']),
    cacheWriteInputTokens: _rowInt(row['cache_write_input_tokens']),
    outputTokens: _rowInt(row['output_tokens']),
    reasoningOutputTokens: _rowInt(row['reasoning_output_tokens']),
    totalTokens: _rowInt(row['total_tokens']),
    invalidBucketCount: _rowInt(row['invalid_bucket_count']),
  );

  final String sessionId;
  final String dayUtc;
  final String? model;
  final int? projectId;
  final String? projectName;
  final String sourceType;
  final bool isArchived;
  final String title;
  final int messageCount;
  final String? threadSource;
  final int inputTokens;
  final int cachedInputTokens;
  final int cacheWriteInputTokens;
  final int outputTokens;
  final int reasoningOutputTokens;
  final int totalTokens;
  final int invalidBucketCount;

  DateTime get day => DateTime.parse('${dayUtc}T00:00:00Z');
}

class _UsageSession {
  const _UsageSession({
    required this.id,
    required this.sourceType,
    required this.startedAtUtc,
    required this.title,
    required this.messageCount,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedInputTokens,
    required this.totalTokens,
    required this.modelPrimary,
    required this.projectId,
    required this.projectName,
    required this.isArchived,
    required this.threadSource,
  });

  factory _UsageSession.fromRow(Row row) {
    return _UsageSession(
      id: row['id'] as String,
      sourceType: row['source_type'] as String,
      startedAtUtc: DateTime.parse(row['started_at_utc'] as String).toUtc(),
      title: (row['title'] as String?) ?? '',
      messageCount: _rowInt(row['message_count']),
      inputTokens: _rowNullableInt(row['input_tokens']),
      outputTokens: _rowNullableInt(row['output_tokens']),
      cachedInputTokens: _rowNullableInt(row['cached_input_tokens']),
      totalTokens: _rowNullableInt(row['total_tokens']),
      modelPrimary: row['model_primary'] as String?,
      projectId: row['project_id'] as int?,
      projectName: row['project_name_snapshot'] as String?,
      isArchived: _rowInt(row['is_archived']) == 1,
      threadSource: row['thread_source'] as String?,
    );
  }

  final String id;
  final String sourceType;
  final DateTime startedAtUtc;
  final String title;
  final int messageCount;
  final int? inputTokens;
  final int? outputTokens;
  final int? cachedInputTokens;
  final int? totalTokens;
  final String? modelPrimary;
  final int? projectId;
  final String? projectName;
  final bool isArchived;
  final String? threadSource;
}

class _UsageAggregate {
  const _UsageAggregate({
    required this.sessionCount,
    required this.messageCount,
    required this.inputTokens,
    required this.outputTokens,
    required this.cachedInputTokens,
    required this.totalTokens,
    required this.estimatedCostText,
    required this.costUnknown,
  });

  final int sessionCount;
  final int messageCount;
  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;
  final int totalTokens;
  final String? estimatedCostText;
  final bool costUnknown;
}

class _DailyUsageKey {
  const _DailyUsageKey({
    required this.dayUtc,
    required this.model,
    required this.projectId,
    required this.sourceType,
    required this.isArchived,
  });

  final String dayUtc;
  final String? model;
  final int? projectId;
  final String sourceType;
  final bool isArchived;

  @override
  bool operator ==(Object other) =>
      other is _DailyUsageKey &&
      dayUtc == other.dayUtc &&
      model == other.model &&
      projectId == other.projectId &&
      sourceType == other.sourceType &&
      isArchived == other.isArchived;

  @override
  int get hashCode =>
      Object.hash(dayUtc, model, projectId, sourceType, isArchived);
}

class _DecimalAmount implements Comparable<_DecimalAmount> {
  const _DecimalAmount._(this.units);

  factory _DecimalAmount.parse(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw FormatException('Decimal value is empty.', value);
    }
    final negative = trimmed.startsWith('-');
    final unsigned = negative || trimmed.startsWith('+')
        ? trimmed.substring(1)
        : trimmed;
    final parts = unsigned.split('.');
    if (parts.length > 2 ||
        parts.every((part) => part.isEmpty) ||
        parts.any((part) => part.isNotEmpty && !_digits.hasMatch(part))) {
      throw FormatException('Invalid decimal value.', value);
    }
    final whole = parts[0].isEmpty ? '0' : parts[0];
    final fractional = parts.length == 1 ? '' : parts[1];
    if (fractional.length > _scaleDigits) {
      throw FormatException(
        'Decimal value exceeds supported precision.',
        value,
      );
    }
    final paddedFractional = fractional.padRight(_scaleDigits, '0');
    final parsed =
        BigInt.parse(whole) * _scale + BigInt.parse(paddedFractional);
    return _DecimalAmount._(negative ? -parsed : parsed);
  }

  static final _digits = RegExp(r'^[0-9]+$');
  static final _scale = BigInt.from(10).pow(_scaleDigits);
  static const _scaleDigits = 18;
  static final zero = _DecimalAmount._(BigInt.zero);

  final BigInt units;

  _DecimalAmount operator +(_DecimalAmount other) =>
      _DecimalAmount._(units + other.units);

  _DecimalAmount operator *(int multiplier) =>
      _DecimalAmount._(units * BigInt.from(multiplier));

  @override
  int compareTo(_DecimalAmount other) => units.compareTo(other.units);

  String toDecimalString() {
    if (units == BigInt.zero) {
      return '0';
    }
    final negative = units.isNegative;
    final absolute = units.abs();
    final whole = absolute ~/ _scale;
    final fraction = (absolute % _scale).toString().padLeft(_scaleDigits, '0');
    final trimmedFraction = fraction.replaceFirst(RegExp(r'0+$'), '');
    final sign = negative ? '-' : '';
    if (trimmedFraction.isEmpty) {
      return '$sign$whole';
    }
    return '$sign$whole.$trimmedFraction';
  }
}

int _rowInt(Object? value) => value is int ? value : 0;

int? _rowNullableInt(Object? value) => value is int ? value : null;
