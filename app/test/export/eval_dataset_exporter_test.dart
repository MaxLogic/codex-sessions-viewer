import 'dart:convert';

import 'package:codex_sessions_viewer/src/export/eval_dataset_exporter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports DeepEval JSON with expected output and anonymized paths', () {
    final files = const EvalDatasetExporter().export(
      EvalDatasetExportRequest(
        sessions: [
          _evalSession(
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

  test('exports normalized source metadata', () {
    final files = const EvalDatasetExporter().export(
      EvalDatasetExportRequest(
        sessions: [
          _evalSession(
            session: _session(
              sourceType: 'windows',
              modelIds: const {'anthropic/claude-sonnet-4', ''},
            ),
          ),
        ],
        format: EvalDatasetFormat.deepEvalJson,
        turnMode: EvalTurnMode.finalAssistantAnswer,
      ),
    );

    final decoded = jsonDecode(files.singleContent) as Map<String, Object?>;
    final entry =
        (decoded['test_cases'] as List<Object?>).single as Map<String, Object?>;
    final metadata = entry['metadata'] as Map<String, Object?>;

    expect(metadata['source_label'], 'Windows');
    expect(metadata['model_labels'], ['Anthropic / Claude Sonnet 4']);
    expect(metadata['provider_labels'], ['Anthropic']);
  });

  test('exports OpenAI and Promptfoo JSONL turn cases', () {
    final exporter = const EvalDatasetExporter();
    final openAiFiles = exporter.export(
      EvalDatasetExportRequest(
        sessions: [
          _evalSession(
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
          _evalSession(
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
        _evalSession(
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
            _evalSession(
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
          _evalSession(
            session: _session(
              messages: [
                _message(
                  0,
                  EvalMessageAuthor.user,
                  r'Inspect F:\projects\secret\TASKS.md and /home/pawel/private/log.txt',
                ),
                _message(
                  1,
                  EvalMessageAuthor.assistant,
                  r'Updated F:\projects\secret\TASKS.md and D:\Research and Development\Private Notes\plan.md.',
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
          _evalSession(
            session: _session(
              messages: [
                _message(0, EvalMessageAuthor.user, '''
<environment_context>
  <current_date>2026-07-07</current_date>
  <filesystem><workspace_roots><root>F:\\repo</root></workspace_roots></filesystem>
</environment_context>'''),
                _message(
                  1,
                  EvalMessageAuthor.user,
                  'Explain the cache behavior.',
                ),
                _message(
                  2,
                  EvalMessageAuthor.assistant,
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

List<EvalDatasetMessage> _twoTurnMessages() {
  return [
    _message(0, EvalMessageAuthor.user, 'First question?'),
    _message(1, EvalMessageAuthor.assistant, 'First answer.'),
    _message(2, EvalMessageAuthor.user, 'Second question?'),
    _message(3, EvalMessageAuthor.assistant, 'Second answer.'),
  ];
}

EvalDatasetSession _evalSession({
  required EvalDatasetSession session,
  String? expectedOutput,
  String? status,
  String? notes,
}) {
  return EvalDatasetSession(
    id: session.id,
    sessionId: session.sessionId,
    title: session.title,
    sourceType: session.sourceType,
    displayPath: session.displayPath,
    modelIds: session.modelIds,
    totalTokens: session.totalTokens,
    messages: session.messages,
    toolCalls: session.toolCalls,
    expectedOutput: expectedOutput,
    status: status,
    notes: notes,
  );
}

EvalDatasetSession _session({
  List<EvalDatasetMessage>? messages,
  List<EvalDatasetToolCall>? toolCalls,
  String sourceType = 'wsl',
  Set<String> modelIds = const {'gpt-5.5-thinking'},
}) {
  return EvalDatasetSession(
    id: 'internal-demo',
    sessionId: 'demo-session',
    sourceType: sourceType,
    displayPath: '/home/pawel/.codex/sessions/demo.jsonl',
    title: 'Build cache invalidation',
    modelIds: modelIds,
    totalTokens: 22,
    messages:
        messages ??
        [
          _message(0, EvalMessageAuthor.user, 'Please add cache invalidation.'),
          _message(
            1,
            EvalMessageAuthor.assistant,
            'Implemented it.\n\n```dart\nprint("done")\n```',
          ),
          _message(2, EvalMessageAuthor.tool, 'Tool call completed.'),
        ],
    toolCalls: toolCalls ?? [_toolCall()],
  );
}

EvalDatasetToolCall _toolCall({String outputPreview = 'TASKS.md'}) {
  return EvalDatasetToolCall(
    messageIndex: 1,
    toolName: 'shell_command',
    status: 'success',
    inputPreview: 'Get-ChildItem',
    outputPreview: outputPreview,
  );
}

EvalDatasetMessage _message(
  int index,
  EvalMessageAuthor author,
  String content,
) {
  return EvalDatasetMessage(
    index: index,
    author: author,
    contentPlain: content,
  );
}
