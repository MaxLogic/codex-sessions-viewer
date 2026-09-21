import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
};

const _agentWaitTools = {'wait_agent', 'wait'};

/// A silence longer than this inside a turn, with no tool call running, is
/// idle time (for example an unanswered approval prompt), not agent work.
const _idleGap = Duration(minutes: 30);

/// A task_started this soon after the open turn began restates that turn.
const _duplicateTurnStart = Duration(seconds: 10);

/// How much of a tool output is searched for a failure marker.
const _failureScanChars = 20000;

/// Top of a JSONL record: timestamp, optional ordinal, record type, and the
/// payload type when it is the first payload key.
final _recordHead = RegExp(
  r'^\{"timestamp":"([^"]+)"(?:,"ordinal":\d+)?,"type":"(\w+)"'
  r'(?:,"payload":\{"type":"(\w+)")?',
);
final _callIdPattern = RegExp(r'"call_id":"([^"]+)"');

/// Failure markers in tool output, matched in raw JSON (quotes may be
/// escaped) or in decoded text.
final _failurePattern = RegExp(
  r'\\*"exit_code\\*"\s*:\s*[1-9]|Exit code: [1-9]|Script failed',
);

const _decodedEvents = {
  'task_started',
  'task_complete',
  'turn_aborted',
  'token_count',
  'thread_settings_applied',
};

const _toolCallItems = {
  'function_call',
  'custom_tool_call',
  'local_shell_call',
  'web_search_call',
};

const _toolOutputItems = {'function_call_output', 'custom_tool_call_output'};

/// Activity facts derived from one Codex JSONL session file.
///
/// Durations are wall-clock intervals. Parallel tool calls are merged, so
/// [toolTime] never exceeds [activeTime] for well-formed files.
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

  /// Number of agent turns (task_started ... task_complete).
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

  /// Subagent address such as `/root/eval3_skill`, when this file is a
  /// subagent thread.
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

/// A `spawn_agent` call made by this session.
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

/// Reads a JSONL session file on a background isolate.
///
/// Returns null when the file is missing, is not JSONL, or cannot be read.
Future<SessionActivityStats?> analyzeSessionActivityFile(String path) {
  return Isolate.run(() => _analyzeFile(path));
}

/// Analyzes several files in one isolate hop, keyed by the input path.
Future<Map<String, SessionActivityStats>> analyzeSessionActivityFiles(
  List<String> paths,
) {
  return Isolate.run(() async {
    final results = <String, SessionActivityStats>{};
    for (final path in paths) {
      final stats = await _analyzeFile(path);
      if (stats != null) {
        results[path] = stats;
      }
    }
    return results;
  });
}

Future<SessionActivityStats?> _analyzeFile(String path) async {
  if (path.trim().isEmpty || !path.toLowerCase().endsWith('.jsonl')) {
    return null;
  }
  final file = File(path);
  try {
    if (!file.existsSync()) {
      return null;
    }
    final analyzer = SessionActivityAnalyzer();
    final lines = file
        .openRead()
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter());
    await for (final line in lines) {
      analyzer.addLine(line);
    }
    return analyzer.finish();
  } on FileSystemException {
    return null;
  }
}

/// Incremental analyzer; feed it JSONL lines in file order.
class SessionActivityAnalyzer {
  DateTime? _sessionStart;
  DateTime? _first;
  DateTime? _last;
  DateTime? _openTurnStart;
  var _turnCount = 0;
  final _turnIntervals = <_Interval>[];
  final _pendingCalls = <String, _PendingCall>{};
  final _toolIntervals = <_Interval>[];
  final _waitIntervals = <_Interval>[];
  final _toolTotals = <String, _ToolAccumulator>{};
  final _modelTurns = <String, int>{};
  String? _currentModel;
  String? _currentEffort;
  final _spawned = <SessionSpawnedAgent>[];
  int? _reasoningTokens;
  String? _agentPath;
  String? _agentRole;

  void addLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) {
      return;
    }
    if (_addLineFast(trimmed)) {
      return;
    }
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, Object?>) {
      return;
    }
    addRecord(decoded);
  }

  /// Handles bulky records (messages, reasoning, tool output, UI events)
  /// without decoding their JSON. Session files can be hundreds of megabytes,
  /// and only a few record kinds need their full content.
  bool _addLineFast(String line) {
    final head = _recordHead.firstMatch(
      line.length > 400 ? line.substring(0, 400) : line,
    );
    if (head == null) {
      return false;
    }
    final type = head.group(2);
    final payloadType = head.group(3);
    if (payloadType == null) {
      return false;
    }
    final isOutput =
        type == 'response_item' && _toolOutputItems.contains(payloadType);
    final isSkippable =
        (type == 'response_item' &&
            !_toolCallItems.contains(payloadType) &&
            !isOutput) ||
        (type == 'event_msg' && !_decodedEvents.contains(payloadType));
    if (!isOutput && !isSkippable) {
      return false;
    }
    final timestamp = _parseTime(head.group(1));
    if (timestamp == null || !_accept(timestamp)) {
      return true;
    }
    if (isOutput) {
      final callId = _callIdPattern.firstMatch(line)?.group(1);
      final pending = callId == null ? null : _pendingCalls.remove(callId);
      if (pending != null) {
        final scanned = line.length > _failureScanChars
            ? line.substring(0, _failureScanChars)
            : line;
        _recordCall(
          pending.name,
          pending.startedAt,
          timestamp,
          failed: _failurePattern.hasMatch(scanned),
        );
      }
    }
    return true;
  }

  /// Tracks the time span and idle gaps; false when the record belongs to a
  /// parent thread's copied history.
  bool _accept(DateTime timestamp, {bool startsTurn = false}) {
    final start = _sessionStart;
    if (start != null &&
        timestamp.isBefore(start.subtract(const Duration(seconds: 1)))) {
      return false;
    }
    final previous = _last;
    final openStart = _openTurnStart;
    if (openStart != null &&
        previous != null &&
        timestamp.difference(previous) > _idleGap &&
        !_hasRecentPendingCall(timestamp)) {
      _turnIntervals.add(_Interval(openStart, previous));
      if (startsTurn) {
        // The open turn never recorded its end; the new one starts here.
        _turnCount++;
        _openTurnStart = null;
      } else {
        // Split the turn around the silence; it stays one turn.
        _openTurnStart = timestamp;
      }
    }
    _first ??= timestamp;
    if (previous == null || timestamp.isAfter(previous)) {
      _last = timestamp;
    }
    return true;
  }

  bool _hasRecentPendingCall(DateTime now) {
    for (final call in _pendingCalls.values) {
      if (now.difference(call.startedAt) < const Duration(hours: 2)) {
        return true;
      }
    }
    return false;
  }

  void addRecord(Map<String, Object?> record) {
    final type = record['type'];
    final payload = record['payload'];
    final timestamp = _parseTime(record['timestamp']);
    if (type == 'session_meta' && payload is Map<String, Object?>) {
      // Forked subagent files can embed the parent's meta record; the first
      // one belongs to this file.
      if (_sessionStart == null) {
        _sessionStart = _parseTime(payload['timestamp']) ?? timestamp;
        final spawn = _threadSpawn(payload['source']);
        _agentPath =
            _string(payload['agent_path']) ?? _string(spawn?['agent_path']);
        _agentRole =
            _string(payload['agent_role']) ?? _string(spawn?['agent_role']);
      }
      return;
    }
    if (timestamp == null) {
      return;
    }
    final previous = _last;
    final startsTurn =
        type == 'event_msg' &&
        payload is Map<String, Object?> &&
        payload['type'] == 'task_started';
    if (!_accept(timestamp, startsTurn: startsTurn)) {
      return;
    }
    if (payload is! Map<String, Object?>) {
      return;
    }
    switch (type) {
      case 'turn_context':
        _currentModel = _string(payload['model']) ?? _currentModel;
        _currentEffort =
            _string(payload['effort']) ??
            _string(payload['reasoning_effort']) ??
            _currentEffort;
        _countModelTurn();
      case 'event_msg':
        _addEvent(payload, timestamp, previous);
      case 'response_item':
        _addResponseItem(payload, timestamp);
    }
  }

  void _countModelTurn() {
    final model = _currentModel;
    if (model == null) {
      return;
    }
    final key = '$model\u0000${_currentEffort ?? ''}';
    _modelTurns[key] = (_modelTurns[key] ?? 0) + 1;
  }

  void _addEvent(
    Map<String, Object?> payload,
    DateTime timestamp,
    DateTime? previous,
  ) {
    switch (payload['type']) {
      case 'task_started':
        final open = _openTurnStart;
        if (open == null) {
          _openTurnStart = timestamp;
        } else if (timestamp.difference(open) > _duplicateTurnStart &&
            previous != null) {
          // The open turn never recorded its end (for example after an
          // interruption); it ended with its last record.
          _turnIntervals.add(_Interval(open, previous));
          _turnCount++;
          _openTurnStart = timestamp;
        }
      case 'task_complete' || 'turn_aborted':
        final start = _openTurnStart;
        if (start != null) {
          _turnIntervals.add(_Interval(start, timestamp));
          _turnCount++;
          _openTurnStart = null;
        }
      case 'token_count':
        final info = payload['info'];
        if (info is Map<String, Object?>) {
          final total = info['total_token_usage'];
          if (total is Map<String, Object?>) {
            final reasoning = total['reasoning_output_tokens'];
            if (reasoning is int) {
              _reasoningTokens = reasoning;
            }
          }
        }
      case 'thread_settings_applied':
        final settings = payload['thread_settings'];
        if (settings is Map<String, Object?>) {
          _currentModel = _string(settings['model']) ?? _currentModel;
          _currentEffort =
              _string(settings['reasoning_effort']) ?? _currentEffort;
        }
    }
  }

  void _addResponseItem(Map<String, Object?> payload, DateTime timestamp) {
    final itemType = payload['type'];
    switch (itemType) {
      case 'function_call' ||
          'custom_tool_call' ||
          'local_shell_call' ||
          'web_search_call':
        final name =
            _string(payload['name']) ??
            (itemType == 'local_shell_call'
                ? 'shell'
                : itemType == 'web_search_call'
                ? 'web_search'
                : 'tool');
        final callId = _string(payload['call_id']) ?? _string(payload['id']);
        if (name == 'spawn_agent') {
          _spawned.add(_spawnedAgent(payload['arguments'], timestamp));
        }
        final status = _string(payload['status']);
        if (callId == null || itemType == 'web_search_call') {
          _recordCall(name, timestamp, timestamp, failed: status == 'failed');
        } else {
          _pendingCalls[callId] = _PendingCall(name, timestamp);
        }
      case 'function_call_output' || 'custom_tool_call_output':
        final callId = _string(payload['call_id']);
        final pending = callId == null ? null : _pendingCalls.remove(callId);
        if (pending == null) {
          return;
        }
        _recordCall(
          pending.name,
          pending.startedAt,
          timestamp,
          failed: _outputLooksFailed(payload['output']),
        );
    }
  }

  void _recordCall(
    String name,
    DateTime start,
    DateTime end, {
    required bool failed,
  }) {
    final safeEnd = end.isBefore(start) ? start : end;
    final accumulator = _toolTotals.putIfAbsent(name, () => _ToolAccumulator());
    accumulator.count++;
    if (failed) {
      accumulator.failed++;
    }
    accumulator.total += safeEnd.difference(start);
    final interval = _Interval(start, safeEnd);
    if (_agentWaitTools.contains(name)) {
      _waitIntervals.add(interval);
    } else if (!_agentCoordinationTools.contains(name)) {
      _toolIntervals.add(interval);
    }
  }

  SessionActivityStats finish() {
    final last = _last;
    final openStart = _openTurnStart;
    final turns = [..._turnIntervals];
    var turnCount = _turnCount;
    if (openStart != null && last != null) {
      turns.add(_Interval(openStart, last));
      turnCount++;
    }
    final activeTime = turns.isEmpty ? _spanOrZero() : _mergedDuration(turns);
    final waitTime = _mergedDuration(_waitIntervals);
    // Tool time is bounded by the time left after subagent waits so the split
    // always adds up to the active time.
    final rawToolTime = _mergedDuration(_toolIntervals);
    final toolBudget = activeTime - waitTime;
    final toolTime = toolBudget.isNegative
        ? Duration.zero
        : rawToolTime > toolBudget
        ? toolBudget
        : rawToolTime;
    final tools = [
      for (final entry in _toolTotals.entries)
        SessionToolUsage(
          name: entry.key,
          callCount: entry.value.count,
          failedCount: entry.value.failed,
          totalTime: entry.value.total,
          isAgentCoordination: _agentCoordinationTools.contains(entry.key),
        ),
    ]..sort((a, b) => b.totalTime.compareTo(a.totalTime));
    final models = [
      for (final entry in _modelTurns.entries)
        SessionModelUsage(
          model: entry.key.split('\u0000').first,
          reasoningEffort: _emptyToNull(entry.key.split('\u0000').last),
          turnCount: entry.value,
        ),
    ]..sort((a, b) => b.turnCount.compareTo(a.turnCount));
    return SessionActivityStats(
      firstEventAtUtc: _first,
      lastEventAtUtc: last,
      turnCount: turnCount,
      activeTime: activeTime > waitTime ? activeTime : waitTime,
      toolTime: toolTime,
      agentWaitTime: waitTime,
      tools: List.unmodifiable(tools),
      models: List.unmodifiable(models),
      spawnedAgents: List.unmodifiable(_spawned),
      reasoningOutputTokens: _reasoningTokens,
      agentPath: _agentPath,
      agentRole: _agentRole,
    );
  }

  Duration _spanOrZero() {
    final first = _first;
    final last = _last;
    if (first == null || last == null) {
      return Duration.zero;
    }
    return last.difference(first);
  }
}

Map<String, Object?>? _threadSpawn(Object? source) {
  if (source is! Map<String, Object?>) {
    return null;
  }
  final subagent = source['subagent'];
  if (subagent is! Map<String, Object?>) {
    return null;
  }
  final spawn = subagent['thread_spawn'];
  return spawn is Map<String, Object?> ? spawn : null;
}

SessionSpawnedAgent _spawnedAgent(Object? arguments, DateTime timestamp) {
  Map<String, Object?> args = const {};
  if (arguments is String) {
    try {
      final decoded = jsonDecode(arguments);
      if (decoded is Map<String, Object?>) {
        args = decoded;
      }
    } on FormatException {
      // Arguments are optional detail.
    }
  } else if (arguments is Map<String, Object?>) {
    args = arguments;
  }
  return SessionSpawnedAgent(
    taskName: _string(args['task_name']),
    agentType: _string(args['agent_type']),
    model: _string(args['model']),
    reasoningEffort: _string(args['reasoning_effort']),
    requestedAtUtc: timestamp,
  );
}

bool _outputLooksFailed(Object? output) {
  final buffer = StringBuffer();
  if (output is String) {
    buffer.write(output);
  } else if (output is List) {
    for (final part in output) {
      if (part is Map && part['text'] is String) {
        buffer.write(part['text'] as String);
      }
      if (buffer.length >= _failureScanChars) {
        break;
      }
    }
  }
  final text = buffer.toString();
  return _failurePattern.hasMatch(
    text.length > _failureScanChars
        ? text.substring(0, _failureScanChars)
        : text,
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

DateTime? _parseTime(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  return DateTime.tryParse(value)?.toUtc();
}

String? _string(Object? value) {
  if (value is! String) {
    return null;
  }
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String? _emptyToNull(String value) => value.isEmpty ? null : value;

class _Interval {
  const _Interval(this.start, this.end);

  final DateTime start;
  final DateTime end;
}

class _PendingCall {
  const _PendingCall(this.name, this.startedAt);

  final String name;
  final DateTime startedAt;
}

class _ToolAccumulator {
  var count = 0;
  var failed = 0;
  var total = Duration.zero;
}
