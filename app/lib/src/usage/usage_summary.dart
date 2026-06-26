import 'package:sqlite3/sqlite3.dart';

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
  }) {
    final range = request.resolve();
    final sessions = _loadSessions(range, includeSessionIds);
    return _summarizeSessions(sessions, pricing, range);
  }

  void rebuildDailyUsage({
    UsagePricingCatalog pricing = const UsagePricingCatalog({}),
  }) {
    final sessions = _loadSessions(null, const {});
    final groups = <_DailyUsageKey, List<_UsageSession>>{};
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
      groups.putIfAbsent(key, () => []).add(session);
    }

    final rows = [
      for (final entry in groups.entries)
        (key: entry.key, aggregate: _aggregateRows(entry.value, pricing)),
    ];
    db.execute('begin immediate');
    try {
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
}

class UsageSummaryRequest {
  const UsageSummaryRequest({
    required this.period,
    required this.nowUtc,
    this.customStartUtc,
    this.customEndExclusiveUtc,
  });

  final UsagePeriod period;
  final DateTime nowUtc;
  final DateTime? customStartUtc;
  final DateTime? customEndExclusiveUtc;

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

  UsageModelPricing? operator [](String? modelId) =>
      modelId == null ? null : models[modelId];
}

class UsageModelPricing {
  const UsageModelPricing({
    this.promptPricePerToken,
    this.completionPricePerToken,
    this.cachedInputPricePerToken,
  });

  final String? promptPricePerToken;
  final String? completionPricePerToken;
  final String? cachedInputPricePerToken;
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
  required String? model,
  required UsagePricingCatalog pricing,
}) {
  final cost = _costForTokenUsage(
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cachedInputTokens: cachedInputTokens,
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
  UsagePricingCatalog pricing,
  UsageDateRange range,
) {
  final aggregate = _aggregateRows(sessions, pricing);
  final byModel = _breakdown(
    sessions,
    pricing,
    (session) => session.modelPrimary ?? 'Unknown',
  );
  final byProject = _breakdown(
    sessions,
    pricing,
    (session) => session.projectName ?? 'Unknown',
  );
  final byPlatform = _breakdown(
    sessions,
    pricing,
    (session) => session.sourceType,
  );
  final byOrigin = _breakdown(sessions, pricing, _originLabel);
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
    mostUsedModel: _mostActive(byModel),
    mostActiveProject: _mostActive(byProject),
    mostActivePlatform: _mostActive(byPlatform),
    byDay: _breakdown(
      sessions,
      pricing,
      (session) => _dayKey(session.startedAtUtc) ?? 'Unknown',
    ),
    byWeek: _breakdown(
      sessions,
      pricing,
      (session) => _weekKey(session.startedAtUtc) ?? 'Unknown',
    ),
    byMonth: _breakdown(
      sessions,
      pricing,
      (session) => _monthKey(session.startedAtUtc) ?? 'Unknown',
    ),
    byModel: byModel,
    byProject: byProject,
    byPlatform: byPlatform,
    byOrigin: byOrigin,
    byArchiveState: _breakdown(
      sessions,
      pricing,
      (session) => session.isArchived ? 'archived' : 'active',
    ),
    topSessionsByTokens: _topSessions(
      sessions,
      pricing,
      (left, right) =>
          (right.totalTokens ?? 0).compareTo(left.totalTokens ?? 0),
    ),
    topSessionsByMessageCount: _topSessions(
      sessions,
      pricing,
      (left, right) => right.messageCount.compareTo(left.messageCount),
    ),
    topSessionsByEstimatedCost: _topSessionsByCost(sessions, pricing),
  );
}

List<UsageBreakdownRow> _breakdown(
  List<_UsageSession> sessions,
  UsagePricingCatalog pricing,
  String Function(_UsageSession session) keyOf,
) {
  final groups = <String, List<_UsageSession>>{};
  for (final session in sessions) {
    groups.putIfAbsent(keyOf(session), () => []).add(session);
  }
  final rows = [
    for (final entry in groups.entries)
      _breakdownRow(entry.key, entry.value, pricing),
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
  UsagePricingCatalog pricing,
) {
  final aggregate = _aggregateRows(sessions, pricing);
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

_UsageAggregate _aggregateRows(
  List<_UsageSession> sessions,
  UsagePricingCatalog pricing,
) {
  var messageCount = 0;
  var inputTokens = 0;
  var outputTokens = 0;
  var cachedInputTokens = 0;
  var totalTokens = 0;
  var cost = _DecimalAmount.zero;
  var costUnknown = false;
  for (final session in sessions) {
    messageCount += session.messageCount;
    inputTokens += session.inputTokens ?? 0;
    outputTokens += session.outputTokens ?? 0;
    cachedInputTokens += session.cachedInputTokens ?? 0;
    totalTokens += session.totalTokens ?? 0;
    final sessionCost = _sessionCost(session, pricing);
    if (sessionCost == null) {
      costUnknown = true;
    } else {
      cost += sessionCost;
    }
  }
  return _UsageAggregate(
    sessionCount: sessions.length,
    messageCount: messageCount,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cachedInputTokens: cachedInputTokens,
    totalTokens: totalTokens,
    estimatedCostText: costUnknown ? null : cost.toDecimalString(),
    costUnknown: costUnknown,
  );
}

_DecimalAmount? _sessionCost(
  _UsageSession session,
  UsagePricingCatalog pricingCatalog,
) => _costForTokenUsage(
  inputTokens: session.inputTokens,
  outputTokens: session.outputTokens,
  cachedInputTokens: session.cachedInputTokens,
  model: session.modelPrimary,
  pricingCatalog: pricingCatalog,
);

_DecimalAmount? _costForTokenUsage({
  required int? inputTokens,
  required int? outputTokens,
  required int? cachedInputTokens,
  required String? model,
  required UsagePricingCatalog pricingCatalog,
}) {
  if (inputTokens == 0 && outputTokens == 0 && cachedInputTokens == 0) {
    return _DecimalAmount.zero;
  }
  if (inputTokens == null ||
      outputTokens == null ||
      cachedInputTokens == null) {
    return null;
  }
  final pricing = pricingCatalog[model];
  if (pricing == null) {
    return null;
  }
  final prompt = _pricedTokens(inputTokens, pricing.promptPricePerToken);
  final completion = _pricedTokens(
    outputTokens,
    pricing.completionPricePerToken,
  );
  final cached = _pricedTokens(
    cachedInputTokens,
    pricing.cachedInputPricePerToken,
  );
  if (prompt == null || completion == null || cached == null) {
    return null;
  }
  return prompt + completion + cached;
}

_DecimalAmount? _pricedTokens(int tokens, String? pricePerToken) {
  if (tokens == 0) {
    return _DecimalAmount.zero;
  }
  if (pricePerToken == null) {
    return null;
  }
  try {
    return _DecimalAmount.parse(pricePerToken) * tokens;
  } on FormatException {
    return null;
  }
}

List<UsageTopSession> _topSessions(
  List<_UsageSession> sessions,
  UsagePricingCatalog pricing,
  int Function(_UsageSession left, _UsageSession right) compare,
) {
  final sorted = [...sessions]
    ..sort((left, right) {
      final primary = compare(left, right);
      if (primary != 0) {
        return primary;
      }
      return left.id.compareTo(right.id);
    });
  return sorted
      .take(10)
      .map((session) {
        final cost = _sessionCost(session, pricing);
        return UsageTopSession(
          sessionId: session.id,
          title: session.title,
          messageCount: session.messageCount,
          totalTokens: session.totalTokens ?? 0,
          estimatedCostText: cost?.toDecimalString(),
          costUnknown: cost == null,
          originLabel: _originLabel(session),
        );
      })
      .toList(growable: false);
}

List<UsageTopSession> _topSessionsByCost(
  List<_UsageSession> sessions,
  UsagePricingCatalog pricing,
) {
  final rows = [
    for (final session in sessions)
      (session: session, cost: _sessionCost(session, pricing)),
  ];
  rows.sort((left, right) {
    if (left.cost == null && right.cost != null) {
      return 1;
    }
    if (left.cost != null && right.cost == null) {
      return -1;
    }
    if (left.cost != null && right.cost != null) {
      final byCost = right.cost!.compareTo(left.cost!);
      if (byCost != 0) {
        return byCost;
      }
    }
    return left.session.id.compareTo(right.session.id);
  });
  return rows
      .take(10)
      .map((row) {
        return UsageTopSession(
          sessionId: row.session.id,
          title: row.session.title,
          messageCount: row.session.messageCount,
          totalTokens: row.session.totalTokens ?? 0,
          estimatedCostText: row.cost?.toDecimalString(),
          costUnknown: row.cost == null,
          originLabel: _originLabel(row.session),
        );
      })
      .toList(growable: false);
}

String _originLabel(_UsageSession session) {
  final source = session.threadSource?.trim().toLowerCase();
  return switch (source) {
    'subagent' => 'Subagent',
    null || '' || 'user' => 'User',
    _ => 'Unknown',
  };
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
