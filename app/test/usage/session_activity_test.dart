import 'package:codex_sessions_viewer/src/usage/session_activity.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime _at(int minutes, [int seconds = 0]) => DateTime.utc(
  2026,
  9,
  24,
  10,
).add(Duration(minutes: minutes, seconds: seconds));

void main() {
  test('turns, tools, waits, and idle time come from stored rows', () {
    final stats = computeSessionActivity(
      messages: [
        ActivityMessage(
          author: 'user',
          createdAtUtc: _at(0),
          content:
              '<environment_context>\n  <cwd>C:/x</cwd>\n</environment_context>',
        ),
        ActivityMessage(
          author: 'user',
          createdAtUtc: _at(1),
          content: 'Fix it',
        ),
        ActivityMessage(
          author: 'assistant',
          createdAtUtc: _at(2),
          model: 'gpt-5.5',
        ),
        ActivityMessage(author: 'assistant', createdAtUtc: _at(10)),
        // The user comes back after lunch: a second turn.
        ActivityMessage(author: 'user', createdAtUtc: _at(90), content: 'More'),
        ActivityMessage(
          author: 'assistant',
          createdAtUtc: _at(91),
          model: 'gpt-5.5',
        ),
        // An unanswered approval prompt: an idle gap inside the turn.
        ActivityMessage(author: 'assistant', createdAtUtc: _at(140)),
      ],
      toolCalls: [
        ActivityToolCall(
          name: 'shell',
          status: 'finished',
          startedAtUtc: _at(3),
          finishedAtUtc: _at(5),
        ),
        ActivityToolCall(
          name: 'shell',
          status: 'finished',
          startedAtUtc: _at(4),
          finishedAtUtc: _at(6),
          outputPreview: '{"exit_code": 2}',
        ),
        ActivityToolCall(
          name: 'wait_agent',
          status: 'finished',
          startedAtUtc: _at(6),
          finishedAtUtc: _at(9),
        ),
        ActivityToolCall(
          name: 'spawn_agent',
          status: 'finished',
          startedAtUtc: _at(2, 30),
          finishedAtUtc: _at(2, 30),
          inputPreview: '{"task_name": "explore", "agent_type": "explorer"}',
        ),
      ],
      reasoningOutputTokens: 42,
      agentRole: 'worker',
    );
    // The injected context is not a turn.
    expect(stats.turnCount, 2);
    expect(stats.firstEventAtUtc, _at(0));
    expect(stats.lastEventAtUtc, _at(140));
    // 1..10 in the first turn; 90..91 and 140..140 in the second.
    expect(stats.activeTime, const Duration(minutes: 10));
    // Parallel shell calls merge into 3..6.
    expect(stats.toolTime, const Duration(minutes: 3));
    expect(stats.agentWaitTime, const Duration(minutes: 3));
    expect(stats.toolCallCount, 4);
    expect(stats.failedToolCallCount, 1);
    expect(stats.models.single.model, 'gpt-5.5');
    expect(stats.models.single.turnCount, 2);
    expect(stats.spawnedAgents.single.taskName, 'explore');
    expect(stats.spawnedAgents.single.agentType, 'explorer');
    expect(stats.reasoningOutputTokens, 42);
    expect(stats.agentRole, 'worker');
    expect(stats.idleTime, stats.span - stats.activeTime);
  });

  test('a long-running tool call is work, not an idle gap', () {
    final stats = computeSessionActivity(
      messages: [
        ActivityMessage(author: 'user', createdAtUtc: _at(0), content: 'Go'),
        ActivityMessage(author: 'assistant', createdAtUtc: _at(60)),
      ],
      toolCalls: [
        ActivityToolCall(
          name: 'build',
          status: 'error',
          startedAtUtc: _at(1),
          finishedAtUtc: _at(59),
        ),
      ],
    );
    expect(stats.activeTime, const Duration(minutes: 60));
    expect(stats.toolTime, const Duration(minutes: 58));
    expect(stats.failedToolCallCount, 1);
  });

  test('sessions without prompts or times report their span or nothing', () {
    expect(
      computeSessionActivity(messages: const [], toolCalls: const []).span,
      Duration.zero,
    );
    final stats = computeSessionActivity(
      messages: [
        ActivityMessage(author: 'assistant', createdAtUtc: _at(0)),
        ActivityMessage(author: 'assistant', createdAtUtc: _at(5)),
      ],
      toolCalls: const [],
    );
    expect(stats.turnCount, 0);
    expect(stats.activeTime, const Duration(minutes: 5));
  });
}
