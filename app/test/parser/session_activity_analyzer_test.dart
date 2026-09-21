import 'dart:convert';

import 'package:codex_sessions_viewer/src/parser/session_activity_analyzer.dart';
import 'package:flutter_test/flutter_test.dart';

String _line(String timestamp, String type, Map<String, Object?> payload) =>
    jsonEncode({'timestamp': timestamp, 'type': type, 'payload': payload});

String _t(int minute, [int second = 0]) =>
    '2026-09-10T10:${minute.toString().padLeft(2, '0')}:'
    '${second.toString().padLeft(2, '0')}.000Z';

SessionActivityStats _analyze(List<String> lines) {
  final analyzer = SessionActivityAnalyzer();
  for (final line in lines) {
    analyzer.addLine(line);
  }
  return analyzer.finish();
}

void main() {
  test('splits active time into model, tool, and subagent waits', () {
    final stats = _analyze([
      _line(_t(0), 'session_meta', {'timestamp': _t(0)}),
      _line(_t(0), 'event_msg', {'type': 'task_started'}),
      _line(_t(0), 'turn_context', {'model': 'gpt-5.6', 'effort': 'high'}),
      // Two parallel shell calls: 0:10-0:40 and 0:20-0:50 merge to 40s.
      _line(_t(0, 10), 'response_item', {
        'type': 'function_call',
        'name': 'exec_command',
        'call_id': 'a',
      }),
      _line(_t(0, 20), 'response_item', {
        'type': 'function_call',
        'name': 'exec_command',
        'call_id': 'b',
      }),
      _line(_t(0, 40), 'response_item', {
        'type': 'function_call_output',
        'call_id': 'a',
        'output': '{"exit_code":1}',
      }),
      _line(_t(0, 50), 'response_item', {
        'type': 'function_call_output',
        'call_id': 'b',
        'output': 'ok',
      }),
      _line(_t(1), 'response_item', {
        'type': 'function_call',
        'name': 'spawn_agent',
        'call_id': 'c',
        'arguments': jsonEncode({
          'task_name': 'explore',
          'agent_type': 'explorer',
          'model': 'gpt-5.6-mini',
          'reasoning_effort': 'low',
        }),
      }),
      _line(_t(1), 'response_item', {
        'type': 'function_call_output',
        'call_id': 'c',
        'output': '{}',
      }),
      _line(_t(1), 'response_item', {
        'type': 'function_call',
        'name': 'wait_agent',
        'call_id': 'd',
      }),
      _line(_t(2), 'response_item', {
        'type': 'function_call_output',
        'call_id': 'd',
        'output': 'done',
      }),
      _line(_t(3), 'event_msg', {
        'type': 'token_count',
        'info': {
          'total_token_usage': {'reasoning_output_tokens': 42},
        },
      }),
      _line(_t(3), 'event_msg', {'type': 'task_complete'}),
      // User idles for 7 minutes, then a second turn of one minute.
      _line(_t(10), 'event_msg', {'type': 'task_started'}),
      _line(_t(10), 'turn_context', {'model': 'gpt-5.6', 'effort': 'xhigh'}),
      _line(_t(11), 'event_msg', {'type': 'task_complete'}),
    ]);

    expect(stats.turnCount, 2);
    expect(stats.activeTime, const Duration(minutes: 4));
    expect(stats.toolTime, const Duration(seconds: 40));
    expect(stats.agentWaitTime, const Duration(minutes: 1));
    expect(stats.modelTime, const Duration(minutes: 2, seconds: 20));
    expect(stats.idleTime, const Duration(minutes: 7));
    expect(stats.reasoningOutputTokens, 42);

    final shell = stats.tools.firstWhere((t) => t.name == 'exec_command');
    expect(shell.callCount, 2);
    expect(shell.failedCount, 1);
    expect(shell.totalTime, const Duration(seconds: 60));
    expect(
      stats.tools.firstWhere((t) => t.name == 'wait_agent').isAgentCoordination,
      isTrue,
    );

    expect(stats.models.map((m) => m.label), [
      'gpt-5.6 · high',
      'gpt-5.6 · xhigh',
    ]);
    final spawned = stats.spawnedAgents.single;
    expect(spawned.taskName, 'explore');
    expect(spawned.agentType, 'explorer');
    expect(spawned.model, 'gpt-5.6-mini');
    expect(spawned.reasoningEffort, 'low');
  });

  test('closes an unfinished turn at the last event', () {
    final stats = _analyze([
      _line(_t(0), 'session_meta', {'timestamp': _t(0)}),
      _line(_t(0), 'event_msg', {'type': 'task_started'}),
      _line(_t(5), 'response_item', {'type': 'message', 'role': 'assistant'}),
    ]);

    expect(stats.turnCount, 1);
    expect(stats.activeTime, const Duration(minutes: 5));
  });

  test('ignores records copied from a parent thread before the fork', () {
    final stats = _analyze([
      _line(_t(30), 'session_meta', {'timestamp': _t(30)}),
      _line(_t(1), 'event_msg', {'type': 'task_started'}),
      _line(_t(20), 'event_msg', {'type': 'task_complete'}),
      _line(_t(30), 'event_msg', {'type': 'task_started'}),
      _line(_t(31), 'event_msg', {'type': 'task_complete'}),
    ]);

    expect(stats.turnCount, 1);
    expect(stats.activeTime, const Duration(minutes: 1));
    expect(stats.firstEventAtUtc, DateTime.parse(_t(30)));
  });

  test('a turn without an end record stops at its last record', () {
    final stats = _analyze([
      _line(_t(0), 'session_meta', {'timestamp': _t(0)}),
      _line(_t(0), 'event_msg', {'type': 'task_started'}),
      _line(_t(2), 'response_item', {'type': 'message', 'role': 'assistant'}),
      // Interrupted: no task_complete. The next turn starts much later.
      _line(_t(40), 'event_msg', {'type': 'task_started'}),
      _line(_t(41), 'event_msg', {'type': 'task_complete'}),
    ]);

    expect(stats.turnCount, 2);
    expect(stats.activeTime, const Duration(minutes: 3));
  });

  test('a long silence inside a turn is idle, not active', () {
    final stats = _analyze([
      _line(_t(0), 'session_meta', {'timestamp': _t(0)}),
      _line(_t(0), 'event_msg', {'type': 'task_started'}),
      _line(_t(1), 'response_item', {'type': 'message', 'role': 'assistant'}),
      // 45 minutes waiting for an approval, nothing running.
      _line(_t(46), 'response_item', {'type': 'message', 'role': 'user'}),
      _line(_t(47), 'event_msg', {'type': 'task_complete'}),
    ]);

    expect(stats.turnCount, 1);
    expect(stats.activeTime, const Duration(minutes: 2));
  });

  test('a failure in a later output part counts as failed', () {
    final stats = _analyze([
      _line(_t(0), 'session_meta', {'timestamp': _t(0)}),
      _line(_t(0), 'response_item', {
        'type': 'custom_tool_call',
        'name': 'exec',
        'call_id': 'x',
      }),
      _line(_t(0, 5), 'response_item', {
        'type': 'custom_tool_call_output',
        'call_id': 'x',
        'output': [
          {'type': 'input_text', 'text': 'Script completed\nWall time 1s\n'},
          {'type': 'input_text', 'text': '{"exit_code":1,"output":"boom"}'},
        ],
      }),
    ]);

    expect(stats.tools.single.failedCount, 1);
  });

  test('tolerates malformed lines', () {
    final stats = _analyze(['not json', '[]', '{"type":"event_msg"}']);

    expect(stats.turnCount, 0);
    expect(stats.activeTime, Duration.zero);
  });
}
