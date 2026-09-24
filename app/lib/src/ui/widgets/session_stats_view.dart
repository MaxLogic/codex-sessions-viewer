import 'dart:io';

import 'package:flutter/material.dart';

import '../../database/session_activity_reader.dart';
import '../../usage/session_activity.dart';
import '../models/session_row_view_model.dart';
import '../number_formatting.dart';

/// Activity for a session and its subagents, keyed by row id.
class SessionActivityBundle {
  const SessionActivityBundle({required this.main, required this.subagents});

  final SessionActivityStats? main;
  final Map<String, SessionActivityStats> subagents;
}

typedef SessionActivityLoader =
    Future<SessionActivityBundle> Function(
      SessionRowViewModel row,
      List<SessionRowViewModel> subagents,
    );

/// No activity source: the Stats tab shows what the session row holds.
Future<SessionActivityBundle> noSessionActivity(
  SessionRowViewModel row,
  List<SessionRowViewModel> subagents,
) async => const SessionActivityBundle(main: null, subagents: {});

/// Reads activity from the messages and tool calls the collector stored, on
/// a background isolate, for sessions of every harness.
///
/// Results are cached per row and last-message time, so switching tabs or
/// sessions does not re-read unchanged sessions.
SessionActivityLoader storedSessionActivityLoader(File databaseFile) {
  return (row, subagents) async {
    final all = [row, ...subagents];
    final missing = [
      for (final item in all)
        if (!_activityCache.containsKey(_cacheKey(databaseFile, item))) item.id,
    ];
    if (missing.isNotEmpty) {
      final loaded = await loadSessionActivity(databaseFile, missing);
      for (final item in all) {
        if (loaded[item.id] case final stats?) {
          _rememberActivity(_cacheKey(databaseFile, item), stats);
        }
      }
    }
    return SessionActivityBundle(
      main: _activityCache[_cacheKey(databaseFile, row)],
      subagents: {
        for (final child in subagents)
          child.id: ?_activityCache[_cacheKey(databaseFile, child)],
      },
    );
  };
}

final _activityCache = <String, SessionActivityStats>{};

String _cacheKey(File databaseFile, SessionRowViewModel row) =>
    '${databaseFile.path}|${row.id}|${row.lastMessageAtUtc.microsecondsSinceEpoch}';

void _rememberActivity(String key, SessionActivityStats stats) {
  _activityCache.remove(key);
  _activityCache[key] = stats;
  while (_activityCache.length > 200) {
    _activityCache.remove(_activityCache.keys.first);
  }
}

/// Supplies the activity loader to every Stats tab below it, so the screens
/// between the app and the tab need not pass it along.
class SessionActivityScope extends InheritedWidget {
  const SessionActivityScope({
    super.key,
    required this.loadActivity,
    required super.child,
  });

  final SessionActivityLoader loadActivity;

  static SessionActivityLoader? maybeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<SessionActivityScope>()
      ?.loadActivity;

  @override
  bool updateShouldNotify(SessionActivityScope oldWidget) =>
      loadActivity != oldWidget.loadActivity;
}

/// The session Stats tab: time split, token split, tools, subagents, models.
class SessionStatsView extends StatefulWidget {
  const SessionStatsView({
    super.key,
    required this.row,
    this.subagents = const [],
    this.loadActivity,
    this.onOpenSession,
  });

  final SessionRowViewModel row;
  final List<SessionRowViewModel> subagents;

  /// Null uses the nearest [SessionActivityScope], else no activity.
  final SessionActivityLoader? loadActivity;
  final ValueChanged<String>? onOpenSession;

  @override
  State<SessionStatsView> createState() => _SessionStatsViewState();
}

class _SessionStatsViewState extends State<SessionStatsView> {
  late Future<SessionActivityBundle> _activity;

  @override
  void initState() {
    super.initState();
    _activity = _load();
  }

  @override
  void didUpdateWidget(covariant SessionStatsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.row.id != widget.row.id ||
        oldWidget.row.lastMessageAtUtc != widget.row.lastMessageAtUtc ||
        oldWidget.subagents.length != widget.subagents.length) {
      _activity = _load();
    }
  }

  Future<SessionActivityBundle> _load() {
    final load =
        widget.loadActivity ??
        SessionActivityScope.maybeOf(context) ??
        noSessionActivity;
    return load(widget.row, widget.subagents).catchError(
      (Object _) => const SessionActivityBundle(main: null, subagents: {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SessionActivityBundle>(
      future: _activity,
      builder: (context, snapshot) {
        final loading = snapshot.connectionState != ConnectionState.done;
        final bundle = snapshot.data;
        return _StatsContent(
          row: widget.row,
          subagents: widget.subagents,
          activity: bundle?.main,
          subagentActivity: bundle?.subagents ?? const {},
          loading: loading,
          onOpenSession: widget.onOpenSession,
        );
      },
    );
  }
}

class _StatsContent extends StatelessWidget {
  const _StatsContent({
    required this.row,
    required this.subagents,
    required this.activity,
    required this.subagentActivity,
    required this.loading,
    required this.onOpenSession,
  });

  final SessionRowViewModel row;
  final List<SessionRowViewModel> subagents;
  final SessionActivityStats? activity;
  final Map<String, SessionActivityStats> subagentActivity;
  final bool loading;
  final ValueChanged<String>? onOpenSession;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activity = this.activity;
    final mainTokens = row.totalTokens;
    final subagentTokens = subagents.fold<int>(
      0,
      (total, child) => total + child.totalTokens,
    );
    final totalTokens = mainTokens + subagentTokens;
    final subagentActive = subagents.fold<Duration>(
      Duration.zero,
      (total, child) =>
          total + (subagentActivity[child.id]?.activeTime ?? _rowSpan(child)),
    );
    final tools = activity?.tools ?? const <SessionToolUsage>[];
    // Share of tool time excludes subagent coordination calls, matching the
    // Running tools figure in the time split.
    final toolTimeTotal = tools
        .where((tool) => !tool.isAgentCoordination)
        .fold<Duration>(Duration.zero, (total, tool) => total + tool.totalTime);
    final sortedSubagents = [...subagents]
      ..sort((a, b) => b.totalTokens.compareTo(a.totalTokens));

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Session statistics',
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (loading)
                    Semantics(
                      liveRegion: true,
                      label: 'Reading session activity from the session file.',
                      child: const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                    ),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      _StatTile(
                        label: 'Active time',
                        value: activity == null
                            ? _humanDuration(_rowSpan(row))
                            : _humanDuration(activity.activeTime),
                        detail: activity == null
                            ? 'session span'
                            : '${activity.turnCount} ${activity.turnCount == 1 ? 'turn' : 'turns'} · '
                                  '${_humanDuration(activity.span)} span',
                      ),
                      _StatTile(
                        label: 'Tokens',
                        value: formatCompactInt(totalTokens),
                        detail: subagents.isEmpty
                            ? '${formatCompactInt(row.cachedInputTokens)} cached input'
                            : '${_percent(subagentTokens, totalTokens)} in subagents',
                      ),
                      _StatTile(
                        label: 'Tool calls',
                        value: formatGroupedInt(
                          activity?.toolCallCount ?? row.toolCallCount,
                        ),
                        detail: activity == null
                            ? null
                            : activity.failedToolCallCount == 0
                            ? 'none failed'
                            : '${activity.failedToolCallCount} failed',
                      ),
                      if (subagents.isNotEmpty || !row.isSubagentSession)
                        _StatTile(
                          label: 'Subagents',
                          value: formatGroupedInt(subagents.length),
                          detail: subagents.isEmpty
                              ? null
                              : '${_humanDuration(subagentActive)} of work',
                        ),
                      _StatTile(
                        label: 'Estimated cost',
                        value:
                            row.displayEstimatedCost.toLowerCase().contains(
                              'unknown',
                            )
                            ? '—'
                            : row.displayEstimatedCost,
                        detail:
                            row.displayEstimatedCost.toLowerCase().contains(
                              'unknown',
                            )
                            ? 'no price for this model'
                            : null,
                      ),
                      _StatTile(
                        label: 'Messages',
                        value: formatGroupedInt(row.messageCount),
                        detail:
                            '${formatGroupedInt(row.userMessageCount)} prompts · '
                            '${formatGroupedInt(row.assistantMessageCount)} replies · '
                            '${formatGroupedInt(_otherMessageCount(row))} other',
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _SectionHeading('Where the time went'),
                  if (activity == null)
                    Text(
                      loading
                          ? 'Reading timing from the session file…'
                          : 'Timing is unavailable: the session file could not be read.',
                      style: theme.textTheme.bodySmall,
                    )
                  else
                    _Breakdown(
                      label: 'Active time split',
                      total: activity.activeTime.inMilliseconds,
                      valueFormatter: (ms) =>
                          _humanDuration(Duration(milliseconds: ms)),
                      parts: [
                        _Part(
                          'Model thinking and writing',
                          activity.modelTime.inMilliseconds,
                        ),
                        _Part(
                          'Running tools',
                          activity.toolTime.inMilliseconds,
                        ),
                        _Part(
                          'Waiting on subagents',
                          activity.agentWaitTime.inMilliseconds,
                        ),
                      ],
                      footnote: [
                        'Idle between turns: ${_humanDuration(activity.idleTime)}, not counted.',
                        if (subagents.isNotEmpty)
                          'Subagents worked ${_humanDuration(subagentActive)} in total, partly in parallel with the main agent.',
                      ].join(' '),
                    ),
                  const SizedBox(height: 20),
                  _SectionHeading('Where the tokens went'),
                  if (subagents.isNotEmpty) ...[
                    _Breakdown(
                      label: 'Tokens by agent',
                      total: totalTokens,
                      valueFormatter: formatCompactInt,
                      parts: [
                        _Part('Main agent', mainTokens),
                        _Part('Subagents', subagentTokens),
                      ],
                    ),
                    const SizedBox(height: 12),
                  ],
                  _Breakdown(
                    label: subagents.isEmpty
                        ? 'Tokens by type'
                        : 'Main agent tokens by type',
                    total: mainTokens,
                    valueFormatter: formatCompactInt,
                    parts: [
                      _Part(
                        'Cached input',
                        row.cachedInputTokens.clamp(0, row.inputTokens),
                      ),
                      _Part(
                        'Uncached input',
                        (row.inputTokens - row.cachedInputTokens).clamp(
                          0,
                          row.inputTokens,
                        ),
                      ),
                      _Part('Output', row.outputTokens),
                    ],
                    footnote:
                        activity?.reasoningOutputTokens == null ||
                            row.outputTokens == 0
                        ? null
                        : '${formatCompactInt(activity!.reasoningOutputTokens!)} of the output tokens were reasoning.',
                  ),
                  if (activity != null && activity.models.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _SectionHeading('Models and reasoning effort'),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (final model in activity.models)
                          _Chip(
                            '${model.label} · ${model.turnCount} '
                            '${model.turnCount == 1 ? 'turn' : 'turns'}',
                          ),
                      ],
                    ),
                  ],
                  if (tools.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _SectionHeading('Tools'),
                    const _TableHeader(
                      columns: ['Tool', 'Calls', 'Failed', 'Time', 'Share'],
                      flex: [4, 2, 2, 2, 2],
                    ),
                  ],
                ],
              ),
            ),
          ),
          if (tools.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList.builder(
                itemCount: tools.length,
                itemBuilder: (context, index) {
                  final tool = tools[index];
                  return _TableRow(
                    semanticsLabel:
                        '${tool.name}: ${tool.callCount} calls, '
                        '${tool.failedCount} failed, '
                        '${_humanDuration(tool.totalTime)}.',
                    flex: const [4, 2, 2, 2, 2],
                    cells: [
                      tool.isAgentCoordination
                          ? '${tool.name} (subagents)'
                          : tool.name,
                      formatGroupedInt(tool.callCount),
                      tool.failedCount == 0
                          ? '–'
                          : formatGroupedInt(tool.failedCount),
                      _humanDuration(tool.totalTime),
                      tool.isAgentCoordination
                          ? '–'
                          : _percent(
                              tool.totalTime.inMilliseconds,
                              toolTimeTotal.inMilliseconds,
                            ),
                    ],
                  );
                },
              ),
            ),
          if (sortedSubagents.isNotEmpty) ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SectionHeading('Subagents'),
                    const _TableHeader(
                      columns: [
                        'Agent',
                        'Kind',
                        'Model',
                        'Tokens',
                        'Tools',
                        'Active',
                        'Cost',
                      ],
                      flex: [5, 3, 4, 3, 2, 2, 2],
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              sliver: SliverList.builder(
                itemCount: sortedSubagents.length,
                itemBuilder: (context, index) {
                  final child = sortedSubagents[index];
                  final childActivity = subagentActivity[child.id];
                  final name = _subagentName(child, childActivity);
                  final kind = _subagentKind(child, childActivity);
                  final model = _subagentModel(child, childActivity);
                  final active = _humanDuration(
                    childActivity?.activeTime ?? _rowSpan(child),
                  );
                  final tokens =
                      '${formatCompactInt(child.totalTokens)} '
                      '(${_percent(child.totalTokens, totalTokens)})';
                  return _TableRow(
                    semanticsLabel:
                        'Subagent $name, $kind, $model, $tokens tokens, '
                        '${child.toolCallCount} tool calls, active $active, '
                        'cost ${child.estimatedCostDisplay}.',
                    flex: const [5, 3, 4, 3, 2, 2, 2],
                    onTap: onOpenSession == null
                        ? null
                        : () => onOpenSession!(child.id),
                    tooltip: onOpenSession == null
                        ? null
                        : 'Open subagent session',
                    cells: [
                      name,
                      kind,
                      model,
                      tokens,
                      formatGroupedInt(
                        childActivity?.toolCallCount ?? child.toolCallCount,
                      ),
                      active,
                      _costCell(child.estimatedCostDisplay),
                    ],
                  );
                },
              ),
            ),
          ],
          const SliverPadding(padding: EdgeInsets.only(bottom: 24)),
        ],
      ),
    );
  }
}

String _subagentName(SessionRowViewModel child, SessionActivityStats? stats) {
  final parts = [
    if (child.agentNickname.trim().isNotEmpty) child.agentNickname.trim(),
    ?stats?.agentTaskName,
  ];
  if (parts.isNotEmpty) {
    return parts.join(' · ');
  }
  if (child.hasThreadName) {
    return child.threadName.trim();
  }
  return child.title.trim().isEmpty ? 'Subagent' : child.title.trim();
}

/// Preconfigured agents carry a role such as `explorer`; generic agents have
/// none (or `default`).
String _subagentKind(SessionRowViewModel child, SessionActivityStats? stats) {
  final role = child.agentRole.trim().isNotEmpty
      ? child.agentRole.trim()
      : (stats?.agentRole ?? '');
  if (role.isEmpty || role.toLowerCase() == 'default') {
    return 'Generic';
  }
  return 'Preconfigured: $role';
}

String _subagentModel(SessionRowViewModel child, SessionActivityStats? stats) {
  final models = stats?.models ?? const <SessionModelUsage>[];
  if (models.isNotEmpty) {
    return models.first.label;
  }
  return child.modelLabel;
}

String _costCell(String display) =>
    display.toLowerCase().contains('unknown') ? '—' : display;

int _otherMessageCount(SessionRowViewModel row) {
  final other =
      row.messageCount - row.userMessageCount - row.assistantMessageCount;
  return other < 0 ? 0 : other;
}

Duration _rowSpan(SessionRowViewModel row) =>
    row.duration ?? row.lastMessageAtUtc.difference(row.startedAtUtc);

String _percent(int part, int total) {
  if (total <= 0) {
    return '0%';
  }
  final value = part * 100 / total;
  if (value > 0 && value < 1) {
    return '<1%';
  }
  return '${value.round()}%';
}

String _humanDuration(Duration duration) {
  if (duration.isNegative || duration == Duration.zero) {
    return '0s';
  }
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  if (hours > 0) {
    return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
  }
  if (minutes > 0) {
    return seconds > 0 ? '${minutes}m ${seconds}s' : '${minutes}m';
  }
  if (duration.inSeconds == 0) {
    return '<1s';
  }
  return '${seconds}s';
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        header: true,
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value, this.detail});

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      container: true,
      label: [label, value, ?detail].join(', '),
      child: ExcludeSemantics(
        child: Container(
          width: 172,
          padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(value, style: theme.textTheme.titleLarge),
              if (detail != null)
                Text(
                  detail!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Part {
  const _Part(this.label, this.value);

  final String label;
  final int value;
}

/// A proportional bar with a labeled legend. The legend carries the numbers,
/// so the bar is decorative for assistive technology.
class _Breakdown extends StatelessWidget {
  const _Breakdown({
    required this.label,
    required this.total,
    required this.parts,
    required this.valueFormatter,
    this.footnote,
  });

  final String label;
  final int total;
  final List<_Part> parts;
  final String Function(int value) valueFormatter;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = _breakdownColors(theme.brightness, highContrast: false);
    final visibleParts = parts.where((part) => part.value > 0).toList();
    final sum = visibleParts.fold<int>(0, (total, part) => total + part.value);
    final denominator = total > 0 ? total : sum;
    return Semantics(
      container: true,
      label:
          '$label: ${[for (final part in parts) '${part.label} ${valueFormatter(part.value)}, ${_percent(part.value, denominator)}'].join('; ')}.',
      child: ExcludeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: theme.textTheme.labelMedium),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 12,
                child: sum == 0
                    ? ColoredBox(color: scheme.surfaceContainerHighest)
                    : Row(
                        children: [
                          for (var i = 0; i < parts.length; i++)
                            if (parts[i].value > 0)
                              Expanded(
                                flex: (parts[i].value * 1000 ~/ sum).clamp(
                                  1,
                                  1000,
                                ),
                                child: Container(
                                  margin: const EdgeInsets.only(right: 1),
                                  color: colors[i % colors.length],
                                ),
                              ),
                        ],
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                for (var i = 0; i < parts.length; i++)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: colors[i % colors.length],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        '${parts[i].label} ${valueFormatter(parts[i].value)} '
                        '(${_percent(parts[i].value, denominator)})',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
              ],
            ),
            if (footnote != null) ...[
              const SizedBox(height: 4),
              Text(
                footnote!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Categorical colors for breakdown bars. Fixed rather than derived from the
/// color scheme, because accent-based schemes can collapse secondary and
/// tertiary into the same hue. The legend always carries the labels.
List<Color> _breakdownColors(
  Brightness brightness, {
  required bool highContrast,
}) {
  if (brightness == Brightness.dark) {
    return const [
      Color(0xFF6CA8FF),
      Color(0xFFF2B84B),
      Color(0xFF4FD1B8),
      Color(0xFFE88BB5),
    ];
  }
  return const [
    Color(0xFF2563C9),
    Color(0xFFC77A00),
    Color(0xFF12877A),
    Color(0xFFB53D78),
  ];
}

class _Chip extends StatelessWidget {
  const _Chip(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

class _TableHeader extends StatelessWidget {
  const _TableHeader({required this.columns, required this.flex});

  final List<String> columns;
  final List<int> flex;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExcludeSemantics(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            for (var i = 0; i < columns.length; i++)
              Expanded(
                flex: flex[i],
                child: Text(
                  columns[i],
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TableRow extends StatelessWidget {
  const _TableRow({
    required this.cells,
    required this.flex,
    required this.semanticsLabel,
    this.onTap,
    this.tooltip,
  });

  final List<String> cells;
  final List<int> flex;
  final String semanticsLabel;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < cells.length; i++)
            Expanded(
              flex: flex[i],
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  cells[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: i == 0
                      ? theme.textTheme.bodyMedium?.copyWith(
                          color: onTap == null
                              ? null
                              : theme.colorScheme.primary,
                        )
                      : theme.textTheme.bodySmall,
                ),
              ),
            ),
        ],
      ),
    );
    if (onTap != null) {
      row = InkWell(onTap: onTap, child: row);
      if (tooltip != null) {
        row = Tooltip(message: tooltip!, child: row);
      }
    }
    return Semantics(
      container: true,
      button: onTap != null,
      label: semanticsLabel,
      onTap: onTap,
      child: ExcludeSemantics(child: row),
    );
  }
}
