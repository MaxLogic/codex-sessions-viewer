import 'package:flutter/material.dart';

import '../../accessibility/announcement_service.dart';
import '../../usage/usage_summary.dart';
import '../number_formatting.dart';

class UsageScreen extends StatefulWidget {
  // ignore: prefer_const_constructors_in_immutables
  UsageScreen({
    super.key,
    this.summary,
    this.announcer,
    this.isRefreshing = false,
    this.refreshFailed = false,
    this.onPeriodChanged,
    this.request,
  });

  final UsageSummary? summary;
  final ScreenReaderAnnouncer? announcer;
  final bool isRefreshing;
  final bool refreshFailed;
  final ValueChanged<UsageSummaryRequest>? onPeriodChanged;
  final UsageSummaryRequest? request;

  @override
  State<UsageScreen> createState() => _UsageScreenState();
}

class _UsageScreenState extends State<UsageScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  UsagePeriod _localPeriod = UsagePeriod.last30Days;
  UsagePeriod get _selectedPeriod => widget.request?.period ?? _localPeriod;
  DateTimeRange? _customRange;
  String _announcement = '';

  UsageSummary get _summary => widget.summary ?? _emptySummary;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: _UsageTab.values.length,
      vsync: this,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _selectPeriod(UsagePeriod period) async {
    final now = DateTime.now().toUtc();
    DateTime? customStart;
    DateTime? customEnd;
    if (period == UsagePeriod.custom) {
      final previous = widget.request;
      final previousRange = previous?.period == UsagePeriod.custom
          ? previous!.resolve()
          : null;
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(1),
        lastDate: DateTime(9999, 12, 31),
        currentDate: DateTime(now.year, now.month, now.day),
        initialDateRange: previousRange == null
            ? _customRange
            : DateTimeRange(
                start: previousRange.startUtc,
                end: previousRange.endExclusiveUtc.subtract(
                  const Duration(days: 1),
                ),
              ),
        helpText: 'Select usage dates (UTC)',
      );
      if (!mounted || range == null) return;
      _customRange = range;
      customStart = DateTime.utc(
        range.start.year,
        range.start.month,
        range.start.day,
      );
      customEnd = DateTime.utc(
        range.end.year,
        range.end.month,
        range.end.day,
      ).add(const Duration(days: 1));
    }
    setState(() {
      _localPeriod = period;
      _announcement = 'Usage period changed to ${period.label}.';
    });
    widget.onPeriodChanged?.call(
      UsageSummaryRequest(
        period: period,
        nowUtc: now,
        customStartUtc: customStart,
        customEndExclusiveUtc: customEnd,
      ),
    );
    await widget.announcer?.announce(_announcement);
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    final scheme = Theme.of(context).colorScheme;
    return FocusTraversalGroup(
      child: Material(
        color: scheme.surface,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Usage', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              Semantics(
                label: 'Period filter',
                container: true,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final period in UsagePeriod.values)
                      FilterChip(
                        label: Text(period.label),
                        selected: _selectedPeriod == period,
                        onSelected: (_) => _selectPeriod(period),
                      ),
                  ],
                ),
              ),
              Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _announcement,
                    key: const Key('usage-period-announcement'),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Usage summary',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      _UsageStatus(
                        summary: summary,
                        isRefreshing: widget.isRefreshing,
                        refreshFailed: widget.refreshFailed,
                        hasSummary: widget.summary != null,
                      ),
                      const SizedBox(height: 12),
                      _SummaryCards(summary: summary),
                      const SizedBox(height: 20),
                      TabBar(
                        controller: _tabController,
                        isScrollable: true,
                        tabs: [
                          for (final tab in _UsageTab.values)
                            Tab(text: tab.label),
                        ],
                      ),
                      SizedBox(
                        height: 560,
                        child: TabBarView(
                          controller: _tabController,
                          children: [
                            _UsageChartsPanel(
                              charts: [
                                _UsageChartSpec(
                                  title: 'Tokens over time',
                                  rows: summary.byDay,
                                  valueLabel: 'tokens',
                                ),
                                _UsageChartSpec(
                                  title: 'Cost over time',
                                  rows: summary.byDay,
                                  valueLabel: 'cost',
                                  rowSummary: _costRowSummary,
                                ),
                                _UsageChartSpec(
                                  title: 'Usage by week',
                                  rows: summary.byWeek,
                                  valueLabel: 'tokens',
                                ),
                                _UsageChartSpec(
                                  title: 'Usage by month',
                                  rows: summary.byMonth,
                                  valueLabel: 'tokens',
                                ),
                                _UsageChartSpec(
                                  title: 'Input vs output vs cached tokens',
                                  rows: _tokenTypeRows(summary),
                                  valueLabel: 'tokens',
                                ),
                              ],
                            ),
                            _UsageChartsPanel(
                              charts: [
                                _UsageChartSpec(
                                  title: 'Tokens by model',
                                  rows: summary.byModel,
                                  valueLabel: 'tokens',
                                ),
                              ],
                            ),
                            _UsageChartsPanel(
                              charts: [
                                _UsageChartSpec(
                                  title: 'Tokens by project',
                                  rows: summary.byProject,
                                  valueLabel: 'tokens',
                                ),
                                _UsageChartSpec(
                                  title: 'Sessions by project',
                                  rows: summary.byProject,
                                  valueLabel: 'sessions',
                                  rowSummary: _sessionsRowSummary,
                                  barValue: _sessionBarValue,
                                ),
                              ],
                            ),
                            _UsageChartsPanel(
                              charts: [
                                _UsageChartSpec(
                                  title: 'Usage by platform',
                                  rows: summary.byPlatform,
                                  valueLabel: 'tokens',
                                ),
                                _UsageChartSpec(
                                  title: 'Usage by origin',
                                  rows: summary.byOrigin,
                                  valueLabel: 'tokens',
                                ),
                                _UsageChartSpec(
                                  title: 'Usage by archived state',
                                  rows: summary.byArchiveState,
                                  valueLabel: 'tokens',
                                ),
                              ],
                            ),
                            _TopSessionsPanel(summary: summary),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UsageStatus extends StatelessWidget {
  const _UsageStatus({
    required this.summary,
    required this.isRefreshing,
    required this.refreshFailed,
    required this.hasSummary,
  });

  final UsageSummary summary;
  final bool isRefreshing;
  final bool refreshFailed;
  final bool hasSummary;

  @override
  Widget build(BuildContext context) {
    final coverage = summary.projectionCoverage;
    final pricing = summary.pricingStatus;
    final zeroUsageUnit = coverage.completeZeroUsageSessions == 1
        ? 'session'
        : 'sessions';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          key: const Key('usage-status-semantics'),
          liveRegion: true,
          container: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (coverage.projectionVersion case final version?)
                Text('Usage projection version $version'),
              if (coverage.projectionVersion != null)
                Text(
                  '${coverage.currentCompleteSessions} of '
                  '${coverage.availableSessions} sessions current and complete',
                ),
              if (isRefreshing) const Text('Refreshing usage status…'),
              if (refreshFailed)
                Text(
                  hasSummary
                      ? 'Usage status refresh failed; showing the last '
                            'successful snapshot.'
                      : 'Usage status refresh failed.',
                ),
            ],
          ),
        ),
        if (coverage.projectionVersion != null)
          Text(
            'Omitted: ${coverage.legacyPendingSessions} pending, '
            '${coverage.ambiguousSessions} ambiguous, '
            '${coverage.missingParentSessions} missing parent',
          ),
        if (coverage.outdatedProjectionSessions > 0)
          Text(
            '${coverage.outdatedProjectionSessions} outdated '
            '${coverage.outdatedProjectionSessions == 1 ? 'projection' : 'projections'}',
          ),
        if (coverage.projectionVersion != null)
          Text(
            '${coverage.completeZeroUsageSessions} complete zero-usage '
            '$zeroUsageUnit',
          ),
        Semantics(
          container: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pricing.usesHistoricalCosts
                    ? 'Historical estimates at last observed rates'
                    : 'Estimated cost at current cached/override rates',
              ),
              if (pricing.updating)
                Semantics(
                  container: true,
                  liveRegion: true,
                  child: const Text('Pricing update in progress'),
                ),
              if (pricing.partialUnsupportedUnits)
                const Text(
                  'Partial estimate: charges for unmeasured units are excluded.',
                ),
              if (!pricing.refreshSucceeded)
                Text(
                  pricing.usesHistoricalCosts
                      ? 'Pricing refresh failed; stored price history is unchanged.'
                      : 'Pricing refresh failed; cached/override rates are being shown.',
                ),
              if (pricing.openRouterFetchedAtUtc case final fetchedAt?)
                Text(
                  'OpenRouter cache fetched '
                  '${_formatUtcMinute(fetchedAt)}',
                ),
              for (final model in pricing.models.take(8))
                Text(
                  _pricingModelStatus(
                    model,
                    historical: pricing.usesHistoricalCosts,
                  ),
                ),
              if (pricing.models.length > 8)
                Text('${pricing.models.length - 8} more pricing models'),
            ],
          ),
        ),
      ],
    );
  }
}

class _SummaryCards extends StatelessWidget {
  const _SummaryCards({required this.summary});

  final UsageSummary summary;

  @override
  Widget build(BuildContext context) {
    final values = [
      ('Total sessions', _formatInt(summary.totalSessions)),
      ('Total messages', _formatInt(summary.totalMessages)),
      ('Input tokens', _formatInt(summary.inputTokens)),
      ('Output tokens', _formatInt(summary.outputTokens)),
      ('Cached input tokens', _formatInt(summary.cachedInputTokens)),
      ('Total tokens', _formatInt(summary.totalTokens)),
      ('Estimated cost', summary.estimatedCostDisplay),
      ('Most used model', summary.mostUsedModel ?? 'Unknown'),
      ('Most active project', summary.mostActiveProject ?? 'Unknown'),
      ('Most active platform', summary.mostActivePlatform ?? 'Unknown'),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth >= 1000
            ? (constraints.maxWidth - 48) / 4
            : constraints.maxWidth >= 700
            ? (constraints.maxWidth - 32) / 3
            : constraints.maxWidth;
        return Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            for (final item in values)
              SizedBox(
                width: width,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border.all(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.$1,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.$2,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _UsageChartsPanel extends StatelessWidget {
  const _UsageChartsPanel({required this.charts});

  final List<_UsageChartSpec> charts;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(top: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final chart in charts) ...[
              _UsageChartSection(spec: chart),
              const SizedBox(height: 24),
            ],
          ],
        ),
      ),
    );
  }
}

class _UsageChartSection extends StatelessWidget {
  const _UsageChartSection({required this.spec});

  final _UsageChartSpec spec;

  @override
  Widget build(BuildContext context) {
    final visibleRows = spec.rows.isEmpty
        ? const <UsageBreakdownRow>[]
        : spec.rows.take(6).toList(growable: false);
    final maxValue = visibleRows.fold<int>(
      0,
      (max, row) => spec.barValue(row) > max ? spec.barValue(row) : max,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(spec.title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(_chartSummary(spec.title, visibleRows, spec.rowSummary)),
        const SizedBox(height: 12),
        for (final row in visibleRows) Text(spec.rowSummary(row)),
        const SizedBox(height: 12),
        Semantics(
          label: '${spec.title} chart',
          container: true,
          child: ExcludeSemantics(
            child: Column(
              children: [
                for (final row in visibleRows)
                  _UsageBarRow(
                    row: row,
                    maxValue: maxValue,
                    value: spec.barValue(row),
                    valueLabel: spec.valueLabel,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _BreakdownTable(
          rows: visibleRows,
          semanticLabel: '${spec.title} table equivalent',
        ),
      ],
    );
  }
}

class _UsageChartSpec {
  const _UsageChartSpec({
    required this.title,
    required this.rows,
    required this.valueLabel,
    this.rowSummary = _tokenRowSummary,
    this.barValue = _tokenBarValue,
  });

  final String title;
  final List<UsageBreakdownRow> rows;
  final String valueLabel;
  final String Function(UsageBreakdownRow row) rowSummary;
  final int Function(UsageBreakdownRow row) barValue;
}

class _UsageBarRow extends StatelessWidget {
  const _UsageBarRow({
    required this.row,
    required this.maxValue,
    required this.value,
    required this.valueLabel,
  });

  final UsageBreakdownRow row;
  final int maxValue;
  final int value;
  final String valueLabel;

  @override
  Widget build(BuildContext context) {
    final ratio = maxValue == 0 ? 0.0 : value / maxValue;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 180,
            child: Text(row.key, overflow: TextOverflow.ellipsis),
          ),
          Expanded(
            child: Stack(
              children: [
                Container(height: 18, color: scheme.surfaceContainerHighest),
                FractionallySizedBox(
                  widthFactor: ratio.clamp(0.0, 1.0),
                  child: Container(height: 18, color: scheme.primary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 140,
            child: Text(
              '${_formatInt(value)} $valueLabel',
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}

class _BreakdownTable extends StatelessWidget {
  const _BreakdownTable({required this.rows, required this.semanticLabel});

  final List<UsageBreakdownRow> rows;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticLabel,
      container: true,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Label')),
            DataColumn(label: Text('Sessions')),
            DataColumn(label: Text('Messages')),
            DataColumn(label: Text('Input')),
            DataColumn(label: Text('Output')),
            DataColumn(label: Text('Cached')),
            DataColumn(label: Text('Tokens')),
            DataColumn(label: Text('Cost')),
          ],
          rows: [
            for (final row in rows)
              DataRow(
                cells: [
                  DataCell(Text(row.key)),
                  DataCell(Text(_formatInt(row.sessionCount))),
                  DataCell(Text(_formatInt(row.messageCount))),
                  DataCell(Text(_formatInt(row.inputTokens))),
                  DataCell(Text(_formatInt(row.outputTokens))),
                  DataCell(Text(_formatInt(row.cachedInputTokens))),
                  DataCell(Text(_formatInt(row.totalTokens))),
                  DataCell(
                    Text(
                      row.costUnknown
                          ? 'Unknown'
                          : row.estimatedCostText ?? '0',
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _TopSessionsPanel extends StatelessWidget {
  const _TopSessionsPanel({required this.summary});

  final UsageSummary summary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TopSessionSection(
              title: 'Top sessions by tokens',
              rows: summary.topSessionsByTokens,
              summaryValue: (session) =>
                  '${_formatInt(session.totalTokens)} tokens',
            ),
            const SizedBox(height: 24),
            _TopSessionSection(
              title: 'Top sessions by message count',
              rows: summary.topSessionsByMessageCount,
              summaryValue: (session) =>
                  '${_formatInt(session.messageCount)} messages',
            ),
            const SizedBox(height: 24),
            _TopSessionSection(
              title: 'Top sessions by estimated cost',
              rows: summary.topSessionsByEstimatedCost,
              summaryValue: (session) => session.costUnknown
                  ? 'cost unknown'
                  : session.estimatedCostText ?? '0',
            ),
          ],
        ),
      ),
    );
  }
}

class _TopSessionSection extends StatelessWidget {
  const _TopSessionSection({
    required this.title,
    required this.rows,
    required this.summaryValue,
  });

  final String title;
  final List<UsageTopSession> rows;
  final String Function(UsageTopSession session) summaryValue;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(_topSessionsSummary(title, rows, summaryValue)),
        const SizedBox(height: 12),
        Semantics(
          label: '$title chart',
          container: true,
          child: ExcludeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final session in rows.take(6))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(_topSessionRowSummary(session, summaryValue)),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Semantics(
          label: '$title table equivalent',
          container: true,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Title')),
                DataColumn(label: Text('Origin')),
                DataColumn(label: Text('Messages')),
                DataColumn(label: Text('Tokens')),
                DataColumn(label: Text('Cost')),
              ],
              rows: [
                for (final session in rows)
                  DataRow(
                    cells: [
                      DataCell(Text(session.title)),
                      DataCell(Text(session.originLabel)),
                      DataCell(Text(_formatInt(session.messageCount))),
                      DataCell(Text(_formatInt(session.totalTokens))),
                      DataCell(
                        Text(
                          session.costUnknown
                              ? 'Unknown'
                              : session.estimatedCostText ?? '0',
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

enum _UsageTab {
  overview('Overview'),
  models('Models'),
  projects('Projects'),
  platforms('Platforms'),
  top('Top');

  const _UsageTab(this.label);

  final String label;
}

extension on UsagePeriod {
  String get label {
    return switch (this) {
      UsagePeriod.today => 'Today',
      UsagePeriod.yesterday => 'Yesterday',
      UsagePeriod.thisWeek => 'This week',
      UsagePeriod.lastWeek => 'Last week',
      UsagePeriod.thisMonth => 'This month',
      UsagePeriod.lastMonth => 'Last month',
      UsagePeriod.last30Days => 'Last 30 days',
      UsagePeriod.custom => 'Custom range',
    };
  }
}

String _chartSummary(
  String title,
  List<UsageBreakdownRow> rows,
  String Function(UsageBreakdownRow row) rowSummary,
) {
  if (rows.isEmpty) {
    return '$title: no usage for this period.';
  }
  final details = rows.map(rowSummary).join('; ');
  return '$title: $details.';
}

String _tokenRowSummary(UsageBreakdownRow row) {
  return '${row.key}, ${_compactSessionText(row.sessionCount)}, ${_formatInt(row.totalTokens)} tokens';
}

String _costRowSummary(UsageBreakdownRow row) {
  final cost = row.costUnknown ? 'cost unknown' : row.estimatedCostText ?? '0';
  return '${row.key}, ${_compactSessionText(row.sessionCount)}, $cost';
}

String _sessionsRowSummary(UsageBreakdownRow row) {
  return '${row.key}, ${_compactSessionText(row.sessionCount)}';
}

int _tokenBarValue(UsageBreakdownRow row) => row.totalTokens;

int _sessionBarValue(UsageBreakdownRow row) => row.sessionCount;

List<UsageBreakdownRow> _tokenTypeRows(UsageSummary summary) {
  return [
    UsageBreakdownRow(
      key: 'Input',
      sessionCount: summary.totalSessions,
      messageCount: summary.totalMessages,
      inputTokens: summary.inputTokens,
      outputTokens: 0,
      cachedInputTokens: 0,
      totalTokens: summary.inputTokens,
      estimatedCostText: summary.estimatedCostText,
      costUnknown: summary.costUnknown,
    ),
    UsageBreakdownRow(
      key: 'Output',
      sessionCount: summary.totalSessions,
      messageCount: summary.totalMessages,
      inputTokens: 0,
      outputTokens: summary.outputTokens,
      cachedInputTokens: 0,
      totalTokens: summary.outputTokens,
      estimatedCostText: summary.estimatedCostText,
      costUnknown: summary.costUnknown,
    ),
    UsageBreakdownRow(
      key: 'Cached input',
      sessionCount: summary.totalSessions,
      messageCount: summary.totalMessages,
      inputTokens: 0,
      outputTokens: 0,
      cachedInputTokens: summary.cachedInputTokens,
      totalTokens: summary.cachedInputTokens,
      estimatedCostText: summary.estimatedCostText,
      costUnknown: summary.costUnknown,
    ),
  ];
}

String _topSessionsSummary(
  String title,
  List<UsageTopSession> rows,
  String Function(UsageTopSession session) summaryValue,
) {
  if (rows.isEmpty) {
    return '$title: no usage for this period.';
  }
  final details = rows
      .take(6)
      .map((row) => _topSessionRowSummary(row, summaryValue))
      .join('; ');
  return '$title: $details.';
}

String _topSessionRowSummary(
  UsageTopSession row,
  String Function(UsageTopSession session) summaryValue,
) {
  return '${row.title}, Origin: ${row.originLabel}, ${summaryValue(row)}';
}

String _compactSessionText(int count) =>
    count == 1 ? '1 session' : '${_formatInt(count)} sessions';

String _formatInt(int value) {
  return formatCompactInt(value);
}

String _formatUtcMinute(DateTime value) {
  final utc = value.toUtc();
  String twoDigits(int part) => part.toString().padLeft(2, '0');
  return '${utc.year}-${twoDigits(utc.month)}-${twoDigits(utc.day)} '
      '${twoDigits(utc.hour)}:${twoDigits(utc.minute)} UTC';
}

String _pricingModelStatus(
  UsageModelPricingStatus model, {
  bool historical = false,
}) {
  final fetched = model.fetchedAtUtc == null
      ? historical
            ? 'historical coverage unavailable'
            : 'fetch time unavailable'
      : '${historical ? 'observed' : 'fetched'} ${_formatUtcMinute(model.fetchedAtUtc!)}';
  return 'Raw: ${model.rawModelId}; '
      'effective: ${model.effectiveModelId}; resolved: '
      '${model.resolvedModelId ?? 'unresolved'}; '
      '${model.resolutionMethod.name}; ${historical ? 'stored basis' : model.cacheState}; '
      '${model.source ?? 'unavailable'}; $fetched';
}

final _emptySummary = UsageSummary(
  period: UsageDateRange(
    startUtc: DateTime.utc(1970),
    endExclusiveUtc: DateTime.utc(1970, 1, 2),
  ),
  totalSessions: 0,
  totalMessages: 0,
  inputTokens: 0,
  outputTokens: 0,
  cachedInputTokens: 0,
  totalTokens: 0,
  estimatedCostText: '0',
  costUnknown: false,
  mostUsedModel: null,
  mostActiveProject: null,
  mostActivePlatform: null,
  byDay: const [],
  byWeek: const [],
  byMonth: const [],
  byModel: const [],
  byProject: const [],
  byPlatform: const [],
  byOrigin: const [],
  byArchiveState: const [],
  topSessionsByTokens: const [],
  topSessionsByMessageCount: const [],
  topSessionsByEstimatedCost: const [],
);
