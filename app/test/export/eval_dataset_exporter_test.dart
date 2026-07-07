import 'dart:convert';

import 'package:codex_sessions_viewer/src/export/eval_dataset_exporter.dart';
import 'package:codex_sessions_viewer/src/parser/codex_session_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports DeepEval JSON with expected output and anonymized paths', () {
    final files = const EvalDatasetExporter().export(
      EvalDatasetExportRequest(
        sessions: [
          EvalDatasetSession(
            session: _session(),
            expectedOutput: 'Cache entries are invalidated after writes.',
            status: 'needs_review',
            notes: 'Regression target',
          ),
        ],
        format: EvalDatasetFormat.deepEvalJson,
        turnMode: EvalTurnMode.finalAssistantAnswer,
      ),
    );

    expect(files.keys, ['deepeval.json']);
    expect(files.singleContent, isNot(contains('/home/pawel/')));
    final decoded = jsonDecode(files.singleContent) as Map<String, Object?>;
    final cases = decoded['test_cases'] as List<Object?>;
    expect(cases, hasLength(1));
    final entry = cases.single as Map<String, Object?>;
    expect(entry['id'], 'internal-demo-final');
    expect(entry['input'], 'Please add cache invalidation.');
    expect(entry['actual_output'], contains('Implemented it.'));
    expect(entry['actual_output'], contains('```dart'));
    expect(
      entry['expected_output'],
      'Cache entries are invalidated after writes.',
    );
    final metadata = entry['metadata'] as Map<String, Object?>;
    expect(metadata['path'], '<path:1>');
    expect(metadata['session_id'], 'demo-session');
    expect(metadata['source'], 'wsl');
    expect(metadata['total_tokens'], 22);
    expect(metadata['eval_status'], 'needs_review');
    expect(metadata['eval_notes'], 'Regression target');
  });

  test('exports OpenAI and Promptfoo JSONL turn cases', () {
    final exporter = const EvalDatasetExporter();
    final openAiFiles = exporter.export(
      EvalDatasetExportRequest(
        sessions: [
          EvalDatasetSession(
            session: _session(messages: _twoTurnMessages()),
            expectedOutput: 'Second expected answer.',
          ),
        ],
        format: EvalDatasetFormat.openAiJsonl,
        turnMode: EvalTurnMode.perUserAssistantTurn,
      ),
    );

    expect(openAiFiles.keys, ['openai_eval.jsonl']);
    final openAiLines = openAiFiles.singleContent
        .split('\n')
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .toList();
    expect(openAiLines, hasLength(2));
    expect(openAiLines.first['custom_id'], 'internal-demo-turn-1');
    expect(openAiLines.last['custom_id'], 'internal-demo-turn-2');
    final firstMessages = openAiLines.first['messages'] as List<Object?>;
    expect(firstMessages.single, {
      'role': 'user',
      'content': 'First question?',
    });
    expect(openAiLines.first['ideal'], 'Second expected answer.');

    final promptfooFiles = exporter.export(
      EvalDatasetExportRequest(
        sessions: [
          EvalDatasetSession(
            session: _session(messages: _twoTurnMessages()),
            expectedOutput: 'Final expected answer.',
          ),
        ],
        format: EvalDatasetFormat.promptfooJsonl,
        turnMode: EvalTurnMode.finalAssistantAnswer,
      ),
    );

    expect(promptfooFiles.keys, ['promptfoo.jsonl']);
    final promptfoo =
        jsonDecode(promptfooFiles.singleContent) as Map<String, Object?>;
    expect(promptfoo['description'], 'Build cache invalidation');
    expect(promptfoo['vars'], {
      'prompt': 'First question?\n\nSecond question?',
    });
    expect(promptfoo['assert'], [
      {'type': 'equals', 'value': 'Final expected answer.'},
    ]);
  });

  test('writes filesystem markdown and plain text datasets', () {
    final exporter = const EvalDatasetExporter();
    final request = EvalDatasetExportRequest(
      sessions: [
        EvalDatasetSession(
          session: _session(),
          expectedOutput: 'Cache entries are invalidated after writes.',
        ),
      ],
      format: EvalDatasetFormat.markdownFiles,
      turnMode: EvalTurnMode.finalAssistantAnswer,
    );

    final markdownFiles = exporter.export(request);
    expect(markdownFiles.keys, ['markdown/internal-demo-final.md']);
    expect(markdownFiles.singleContent, contains('# Build cache invalidation'));
    expect(markdownFiles.singleContent, contains('## Input'));
    expect(markdownFiles.singleContent, contains('## Actual Output'));
    expect(markdownFiles.singleContent, contains('## Expected Output'));
    expect(markdownFiles.singleContent, isNot(contains('/home/pawel/')));

    final plainFiles = exporter.export(
      request.copyWith(format: EvalDatasetFormat.plainTextFiles),
    );
    expect(plainFiles.keys, ['plain_text/internal-demo-final.txt']);
    expect(plainFiles.singleContent, contains('Input:'));
    expect(plainFiles.singleContent, contains('Actual output:'));
    expect(plainFiles.singleContent, contains('Expected output:'));
  });

  test(
    'options control metadata, token usage, code blocks, and tool calls',
    () {
      final files = const EvalDatasetExporter().export(
        EvalDatasetExportRequest(
          sessions: [
            EvalDatasetSession(
              session: _session(),
              expectedOutput: 'Expected answer.',
            ),
          ],
          format: EvalDatasetFormat.deepEvalJson,
          turnMode: EvalTurnMode.finalAssistantAnswer,
          options: const EvalDatasetExportOptions(
            anonymizePaths: false,
            includeMetadata: true,
            includeTokenUsage: false,
            includeCodeBlocks: false,
            includeToolCalls: true,
          ),
        ),
      );

      expect(
        files.singleContent,
        contains('/home/pawel/.codex/sessions/demo.jsonl'),
      );
      final decoded = jsonDecode(files.singleContent) as Map<String, Object?>;
      final entry =
          (decoded['test_cases'] as List<Object?>).single
              as Map<String, Object?>;
      expect(entry['actual_output'], isNot(contains('```dart')));
      final metadata = entry['metadata'] as Map<String, Object?>;
      expect(metadata.containsKey('total_tokens'), isFalse);
      expect(entry['tool_calls'], [
        {
          'message_index': 1,
          'tool_name': 'shell_command',
          'status': 'success',
          'input': 'Get-ChildItem',
          'output_preview': 'TASKS.md',
        },
      ]);
    },
  );

  test('default anonymization redacts paths embedded in content', () {
    final files = const EvalDatasetExporter().export(
      EvalDatasetExportRequest(
        sessions: [
          EvalDatasetSession(
            session: _session(
              messages: [
                _message(
                  0,
                  CodexMessageAuthorType.user,
                  r'Inspect F:\projects\secret\TASKS.md and /home/pawel/private/log.txt',
                ),
                _message(
                  1,
                  CodexMessageAuthorType.assistant,
                  r'Updated F:\projects\secret\TASKS.md and D:\Research and Development\Private Notes\plan.md.',
                  hasToolCalls: true,
                ),
              ],
              toolCalls: [
                _toolCall(outputPreview: r'Wrote /home/pawel/private/log.txt'),
              ],
            ),
            expectedOutput:
                r'F:\projects\secret\TASKS.md should not be visible.',
          ),
        ],
        format: EvalDatasetFormat.deepEvalJson,
        turnMode: EvalTurnMode.finalAssistantAnswer,
        options: const EvalDatasetExportOptions(includeToolCalls: true),
      ),
    );

    expect(files.singleContent, isNot(contains(r'F:\projects\secret')));
    expect(
      files.singleContent,
      isNot(contains(r'D:\Research and Development')),
    );
    expect(files.singleContent, isNot(contains('/home/pawel/private')));
    expect(files.singleContent, contains('<path:'));
    final decoded = jsonDecode(files.singleContent) as Map<String, Object?>;
    final entry =
        (decoded['test_cases'] as List<Object?>).single as Map<String, Object?>;
    expect(entry['actual_output'], isNot(contains('SpZOO')));
    expect(entry['actual_output'], isNot(contains('Research and Development')));
    expect(entry['actual_output'], isNot(contains('Private Notes')));
  });

  test('excludes injected environment context from user-authored prompts', () {
    final files = const EvalDatasetExporter().export(
      EvalDatasetExportRequest(
        sessions: [
          EvalDatasetSession(
            session: _session(
              messages: [
                _message(0, CodexMessageAuthorType.user, '''
<environment_context>
  <current_date>2026-07-07</current_date>
  <filesystem><workspace_roots><root>F:\\repo</root></workspace_roots></filesystem>
</environment_context>'''),
                _message(
                  1,
                  CodexMessageAuthorType.user,
                  'Explain the cache behavior.',
                ),
                _message(
                  2,
                  CodexMessageAuthorType.assistant,
                  'The cache is invalidated after writes.',
                ),
              ],
            ),
          ),
        ],
        format: EvalDatasetFormat.openAiJsonl,
        turnMode: EvalTurnMode.fullConversation,
      ),
    );

    expect(files.singleContent, isNot(contains('<environment_context>')));
    expect(files.singleContent, contains('Explain the cache behavior.'));
  });
}

extension on Map<String, String> {
  String get singleContent => values.single;
}

List<CodexParsedMessage> _twoTurnMessages() {
  return [
    _message(0, CodexMessageAuthorType.user, 'First question?'),
    _message(1, CodexMessageAuthorType.assistant, 'First answer.'),
    _message(2, CodexMessageAuthorType.user, 'Second question?'),
    _message(3, CodexMessageAuthorType.assistant, 'Second answer.'),
  ];
}

CodexParsedSession _session({
  List<CodexParsedMessage>? messages,
  List<CodexParsedToolCall>? toolCalls,
}) {
  return CodexParsedSession(
    internalId: 'internal-demo',
    sessionId: 'demo-session',
    sourceType: CodexSessionSourceType.wsl,
    sourcePath: '/home/pawel/.codex/sessions/demo.jsonl',
    sourceFileUncPath:
        r'\\wsl.localhost\Ubuntu\home\pawel\.codex\sessions\demo.jsonl',
    displayPath: '/home/pawel/.codex/sessions/demo.jsonl',
    platformPath: '/home/pawel/.codex/sessions/demo.jsonl',
    workingDirectoryDisplay: '/home/pawel/projects/codex-sessions-viewer',
    workingDirectoryPlatform: '/home/pawel/projects/codex-sessions-viewer',
    workingDirectoryUnc:
        r'\\wsl.localhost\Ubuntu\home\pawel\projects\codex-sessions-viewer',
    title: 'Build cache invalidation',
    summary: 'Synthetic eval export session',
    startedAtUtc: DateTime.utc(2026, 6, 10, 9, 42),
    lastMessageAtUtc: DateTime.utc(2026, 6, 10, 9, 50),
    modelIds: const {'gpt-5.5-thinking'},
    messages:
        messages ??
        [
          _message(
            0,
            CodexMessageAuthorType.user,
            'Please add cache invalidation.',
            usage: const CodexUsage(inputTokens: 12),
          ),
          _message(
            1,
            CodexMessageAuthorType.assistant,
            'Implemented it.\n\n```dart\nprint("done")\n```',
            usage: const CodexUsage(outputTokens: 8),
            model: 'gpt-5.5-thinking',
            hasToolCalls: true,
          ),
          _message(2, CodexMessageAuthorType.tool, 'Tool call completed.'),
        ],
    toolCalls: toolCalls ?? [_toolCall()],
    warnings: const [],
    usage: const CodexUsage(
      inputTokens: 12,
      outputTokens: 8,
      cachedInputTokens: 2,
      totalTokens: 22,
    ),
    lastTurnUsage: const CodexUsage.empty(),
  );
}

CodexParsedToolCall _toolCall({String outputPreview = 'TASKS.md'}) {
  return CodexParsedToolCall(
    messageIndex: 1,
    toolIndex: 0,
    toolName: 'shell_command',
    status: 'success',
    startedAtUtc: DateTime.utc(2026, 6, 10, 9, 43, 30),
    finishedAtUtc: DateTime.utc(2026, 6, 10, 9, 43, 35),
    inputPreview: 'Get-ChildItem',
    outputPreview: outputPreview,
    outputTruncated: true,
    errorMessage: null,
  );
}

CodexParsedMessage _message(
  int index,
  CodexMessageAuthorType authorType,
  String content, {
  CodexUsage usage = const CodexUsage.empty(),
  String? model,
  bool hasToolCalls = false,
}) {
  return CodexParsedMessage(
    index: index,
    authorType: authorType,
    rawType: 'message',
    createdAtUtc: DateTime.utc(2026, 6, 10, 9, 42 + index),
    firstLine: content.split('\n').first,
    contentPlain: content,
    contentPreview: content,
    contentTruncated: false,
    usage: usage,
    model: model,
    hasToolCalls: hasToolCalls,
    hasError: false,
  );
}
