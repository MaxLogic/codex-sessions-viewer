import 'dart:convert';

import '../utils/injected_context_filter.dart';

/// Tool names that coordinate subagents rather than doing work themselves.
///
/// Time spent in these calls is reported as waiting on subagents instead of
/// tool execution.
const _agentCoordinationTools = {
  'spawn_agent',
  'wait_agent',
  'wait',
  'send_message',
  'send_input',
  'followup_task',
  'list_agents',
  'close_agent',
  'interrupt_agent',
  'Task',
  'Agent',
};

const _agentWaitTools = {'wait_agent', 'wait', 'Task', 'Agent'};

/// A silence longer than this inside a turn, with no tool call running, is
/// idle time (for example an unanswered approval prompt), not agent work.
const _idleGap = Duration(minutes: 30);

/// How much of a tool output is searched for a failure marker.
const _failureScanChars = 20000;

/// Failure markers in tool output.
final _failurePattern = RegExp(
  r'\\*"exit_code\\*"\s*:\s*[1-9]|Exit code: [1-9]|Script failed',
);

/// Whether a tool output reports a failure, searching its first
/// [_failureScanChars] characters.
bool toolOutputSignalsFailure(String output) => _failurePattern.hasMatch(
  output.length > _failureScanChars
      ? output.substring(0, _failureScanChars)
      : output,
);

/// Activity facts derived from a session's stored messages and tool calls.
///
/// Durations are wall-clock intervals. Parallel tool calls are merged, so
/// [toolTime] never exceeds [activeTime].
class SessionActivityStats {
  const SessionActivityStats({
    required this.firstEventAtUtc,
    required this.lastEventAtUtc,
    required this.turnCount,
    required this.activeTime,
    required this.toolTime,
    required this.agentWaitTime,
    required this.tools,
    required this.models,
    required this.spawnedAgents,
    required this.reasoningOutputTokens,
    this.agentPath,
    this.agentRole,
  });

  static const empty = SessionActivityStats(
    firstEventAtUtc: null,
    lastEventAtUtc: null,
    turnCount: 0,
    activeTime: Duration.zero,
    toolTime: Duration.zero,
    agentWaitTime: Duration.zero,
    tools: [],
    models: [],
    spawnedAgents: [],
    reasoningOutputTokens: null,
  );

  final DateTime? firstEventAtUtc;
  final DateTime? lastEventAtUtc;

  /// Number of agent turns: each user prompt and the work that follows it.
  final int turnCount;

  /// Time the agent was working on turns. Idle time between turns, while the
  /// user was reading or typing, is excluded.
  final Duration activeTime;

  /// Merged wall time of tool calls, excluding subagent coordination tools.
  final Duration toolTime;

  /// Merged wall time spent blocked in `wait_agent`-style calls.
  final Duration agentWaitTime;

  final List<SessionToolUsage> tools;
  final List<SessionModelUsage> models;
  final List<SessionSpawnedAgent> spawnedAgents;
  final int? reasoningOutputTokens;

  /// Subagent address such as `/root/eval3_skill`, when known.
  final String? agentPath;

  /// Preconfigured agent role such as `explorer`; null for generic agents.
  final String? agentRole;

  /// Last segment of [agentPath]: the task name the parent gave the agent.
  String? get agentTaskName {
    final path = agentPath;
    if (path == null) {
      return null;
    }
    final segments = path.split('/').where((part) => part.isNotEmpty);
    return segments.isEmpty ? null : segments.last;
  }

  Duration get span {
    final first = firstEventAtUtc;
    final last = lastEventAtUtc;
    if (first == null || last == null || last.isBefore(first)) {
      return Duration.zero;
    }
    return last.difference(first);
  }

  /// Active time not attributed to tools or subagent waits: the model thinking
  /// and writing responses.
  Duration get modelTime {
    final remaining = activeTime - toolTime - agentWaitTime;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  Duration get idleTime {
    final remaining = span - activeTime;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  int get toolCallCount =>
      tools.fold(0, (total, tool) => total + tool.callCount);

  int get failedToolCallCount =>
      tools.fold(0, (total, tool) => total + tool.failedCount);

  /// Reasoning effort used by most turns, or null when unknown.
  String? get primaryReasoningEffort {
    SessionModelUsage? best;
    for (final model in models) {
      if (model.reasoningEffort == null) {
        continue;
      }
      if (best == null || model.turnCount > best.turnCount) {
        best = model;
      }
    }
    return best?.reasoningEffort;
  }
}

class SessionToolUsage {
  const SessionToolUsage({
    required this.name,
    required this.callCount,
    required this.failedCount,
    required this.totalTime,
    required this.isAgentCoordination,
  });

  final String name;
  final int callCount;
  final int failedCount;

  /// Sum of individual call durations; parallel calls are counted separately.
  final Duration totalTime;
  final bool isAgentCoordination;
}

class SessionModelUsage {
  const SessionModelUsage({
    required this.model,
    required this.reasoningEffort,
    required this.turnCount,
  });

  final String model;
  final String? reasoningEffort;
  final int turnCount;

  String get label {
    final effort = reasoningEffort;
    return effort == null || effort.isEmpty ? model : '$model · $effort';
  }
}

/// A subagent this session started.
class SessionSpawnedAgent {
  const SessionSpawnedAgent({
    required this.taskName,
    required this.agentType,
    required this.model,
    required this.reasoningEffort,
    required this.requestedAtUtc,
  });

  final String? taskName;
  final String? agentType;
  final String? model;
  final String? reasoningEffort;
  final DateTime? requestedAtUtc;
}

/// A stored message, as far as activity needs it.
class ActivityMessage {
  const ActivityMessage({
    required this.author,
    required this.createdAtUtc,
    this.model,
    this.content = '',
    this.injectedContext,
  });

  final String author;
  final DateTime? createdAtUtc;
  final String? model;

  /// Enough of the text to recognize injected environment context.
  final String content;

  /// Whether the message is injected environment context, when the caller
  /// already decided it without loading the text; null checks [content].
  final bool? injectedContext;

  bool get isInjectedContext =>
      injectedContext ?? isInjectedEnvironmentContextMessage(content);
}

/// A stored tool call, as far as activity needs it.
class ActivityToolCall {
  const ActivityToolCall({
    required this.name,
    required this.status,
    required this.startedAtUtc,
    required this.finishedAtUtc,
    this.errorMessage,
    this.inputPreview = '',
    this.outputPreview = '',
    this.outputSignalsFailure,
  });

  final String name;
  final String status;
  final DateTime? startedAtUtc;
  final DateTime? finishedAtUtc;
  final String? errorMessage;
  final String inputPreview;
  final String outputPreview;

  /// [toolOutputSignalsFailure] of the output, when the caller already
  /// decided it without loading the output; null checks [outputPreview].
  final bool? outputSignalsFailure;

  bool get failed =>
      status == 'error' ||
      status == 'failed' ||
      (errorMessage?.trim().isNotEmpty ?? false) ||
      (outputSignalsFailure ?? toolOutputSignalsFailure(outputPreview));
}

/// Derives activity from stored messages (in message order) and tool calls.
/// Works for every harness because it reads only what the collector stored.
SessionActivityStats computeSessionActivity({
  required List<ActivityMessage> messages,
  required List<ActivityToolCall> toolCalls,
  int? reasoningOutputTokens,
  String? agentRole,
}) {
  final times = <DateTime>[
    for (final message in messages) ?message.createdAtUtc,
    for (final tool in toolCalls) ...[?tool.startedAtUtc, ?tool.finishedAtUtc],
  ]..sort();
  if (times.isEmpty) {
    return SessionActivityStats(
      firstEventAtUtc: null,
      lastEventAtUtc: null,
      turnCount: 0,
      activeTime: Duration.zero,
      toolTime: Duration.zero,
      agentWaitTime: Duration.zero,
      tools: _toolUsage(toolCalls),
      models: const [],
      spawnedAgents: _spawnedAgents(toolCalls),
      reasoningOutputTokens: reasoningOutputTokens,
      agentRole: agentRole,
    );
  }
  final toolIntervals = <_Interval>[];
  final waitIntervals = <_Interval>[];
  final busy = <_Interval>[];
  for (final tool in toolCalls) {
    final start = tool.startedAtUtc;
    if (start == null) continue;
    final end = tool.finishedAtUtc ?? start;
    final interval = _Interval(start, end.isBefore(start) ? start : end);
    busy.add(interval);
    if (_agentWaitTools.contains(tool.name)) {
      waitIntervals.add(interval);
    } else if (!_agentCoordinationTools.contains(tool.name)) {
      toolIntervals.add(interval);
    }
  }

  // A turn starts at each user prompt; injected environment context is not
  // a prompt.
  final turnStarts = <DateTime>[
    for (final message in messages)
      if (message.author == 'user' &&
          message.createdAtUtc != null &&
          !message.isInjectedContext)
        message.createdAtUtc!,
  ]..sort();
  final turnIntervals = <_Interval>[];
  final modelTurns = <String, int>{};
  for (var turn = 0; turn < turnStarts.length; turn++) {
    final start = turnStarts[turn];
    final next = turn + 1 < turnStarts.length ? turnStarts[turn + 1] : null;
    final inTurn = [
      for (final time in times)
        if (!time.isBefore(start) && (next == null || time.isBefore(next)))
          time,
    ];
    turnIntervals.addAll(_activeIntervals(inTurn, busy));
    final model = _turnModel(messages, start, next);
    if (model != null) modelTurns[model] = (modelTurns[model] ?? 0) + 1;
  }
  final span = _Interval(times.first, times.last);
  final activeTime = turnIntervals.isEmpty
      ? span.duration
      : _mergedDuration(turnIntervals);
  final waitTime = _mergedDuration(waitIntervals);
  // Tool time is bounded by the time left after subagent waits so the split
  // always adds up to the active time.
  final rawToolTime = _mergedDuration(toolIntervals);
  final toolBudget = activeTime - waitTime;
  final toolTime = toolBudget.isNegative
      ? Duration.zero
      : rawToolTime > toolBudget
      ? toolBudget
      : rawToolTime;
  final models = [
    for (final entry in modelTurns.entries)
      SessionModelUsage(
        model: entry.key,
        reasoningEffort: null,
        turnCount: entry.value,
      ),
  ]..sort((a, b) => b.turnCount.compareTo(a.turnCount));
  return SessionActivityStats(
    firstEventAtUtc: times.first,
    lastEventAtUtc: times.last,
    turnCount: turnStarts.length,
    activeTime: activeTime > waitTime ? activeTime : waitTime,
    toolTime: toolTime,
    agentWaitTime: waitTime,
    tools: _toolUsage(toolCalls),
    models: List.unmodifiable(models),
    spawnedAgents: _spawnedAgents(toolCalls),
    reasoningOutputTokens: reasoningOutputTokens,
    agentRole: agentRole,
  );
}

/// The turn's working intervals: consecutive events closer than [_idleGap],
/// or joined by a running tool call.
List<_Interval> _activeIntervals(List<DateTime> times, List<_Interval> busy) {
  if (times.isEmpty) return const [];
  final intervals = <_Interval>[];
  var start = times.first;
  var end = times.first;
  for (final time in times.skip(1)) {
    final covered = busy.any(
      (tool) => !tool.start.isAfter(end) && !tool.end.isBefore(time),
    );
    if (time.difference(end) > _idleGap && !covered) {
      intervals.add(_Interval(start, end));
      start = time;
    }
    end = time;
  }
  intervals.add(_Interval(start, end));
  return intervals;
}

/// The model that answered the turn: its first assistant message with one.
String? _turnModel(
  List<ActivityMessage> messages,
  DateTime start,
  DateTime? next,
) {
  for (final message in messages) {
    final at = message.createdAtUtc;
    final model = message.model?.trim();
    if (message.author != 'assistant' ||
        at == null ||
        at.isBefore(start) ||
        (next != null && !at.isBefore(next)) ||
        model == null ||
        model.isEmpty) {
      continue;
    }
    return model;
  }
  return null;
}

List<SessionToolUsage> _toolUsage(List<ActivityToolCall> toolCalls) {
  final totals = <String, _ToolAccumulator>{};
  for (final tool in toolCalls) {
    final accumulator = totals.putIfAbsent(tool.name, _ToolAccumulator.new);
    accumulator.count++;
    if (tool.failed) accumulator.failed++;
    final start = tool.startedAtUtc;
    final end = tool.finishedAtUtc;
    if (start != null && end != null && end.isAfter(start)) {
      accumulator.total += end.difference(start);
    }
  }
  return List.unmodifiable(
    [
      for (final entry in totals.entries)
        SessionToolUsage(
          name: entry.key,
          callCount: entry.value.count,
          failedCount: entry.value.failed,
          totalTime: entry.value.total,
          isAgentCoordination: _agentCoordinationTools.contains(entry.key),
        ),
    ]..sort((a, b) => b.totalTime.compareTo(a.totalTime)),
  );
}

List<SessionSpawnedAgent> _spawnedAgents(List<ActivityToolCall> toolCalls) {
  return List.unmodifiable([
    for (final tool in toolCalls)
      if (tool.name == 'spawn_agent')
        _spawnedAgent(tool.inputPreview, tool.startedAtUtc),
  ]);
}

SessionSpawnedAgent _spawnedAgent(String input, DateTime? requestedAt) {
  var args = const <String, Object?>{};
  try {
    final decoded = jsonDecode(input);
    if (decoded is Map<String, Object?>) {
      args = decoded;
    }
  } on FormatException {
    // A truncated preview keeps only the time.
  }
  return SessionSpawnedAgent(
    taskName: _string(args['task_name']),
    agentType: _string(args['agent_type']),
    model: _string(args['model']),
    reasoningEffort: _string(args['reasoning_effort']),
    requestedAtUtc: requestedAt,
  );
}

Duration _mergedDuration(List<_Interval> intervals) {
  if (intervals.isEmpty) {
    return Duration.zero;
  }
  final sorted = [...intervals]..sort((a, b) => a.start.compareTo(b.start));
  var total = Duration.zero;
  var currentStart = sorted.first.start;
  var currentEnd = sorted.first.end;
  for (final interval in sorted.skip(1)) {
    if (!interval.start.isAfter(currentEnd)) {
      if (interval.end.isAfter(currentEnd)) {
        currentEnd = interval.end;
      }
      continue;
    }
    total += currentEnd.difference(currentStart);
    currentStart = interval.start;
    currentEnd = interval.end;
  }
  return total + currentEnd.difference(currentStart);
}

String? _string(Object? value) {
  if (value is! String) {
    return null;
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

class _Interval {
  const _Interval(this.start, this.end);

  final DateTime start;
  final DateTime end;

  Duration get duration => end.difference(start);
}

class _ToolAccumulator {
  var count = 0;
  var failed = 0;
  var total = Duration.zero;
}
