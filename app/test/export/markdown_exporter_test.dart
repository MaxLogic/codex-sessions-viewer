import 'package:codex_sessions_viewer/src/export/markdown_exporter.dart';
import 'package:codex_sessions_viewer/src/parser/codex_session_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports whole conversation with metadata, anchors, and usage', () {
    final markdown = const MarkdownSessionExporter().exportMarkdown(
      _session(),
      const MarkdownExportRequest(scope: MarkdownExportScope.all()),
    );

    expect(markdown, startsWith('# Build cache invalidation\n\n'));
    expect(markdown, contains('- Source: WSL\n'));
    expect(markdown, contains('- Project: codex-sessions-viewer\n'));
    expect(
      markdown,
      contains('- Path: /home/pawel/.codex/sessions/demo.jsonl'),
    );
    expect(markdown, contains('- Started: 2026-06-10 09:42\n'));
    expect(markdown, contains('- Last message: 2026-06-10 09:50\n'));
    expect(markdown, contains('- Tokens: 12 / 8 / 2 / 22\n'));
    expect(markdown, contains('## Conversation\n\n'));
    expect(markdown, contains('<a id="message-1"></a>\n'));
    expect(markdown, contains('### 1. User \u2014 2026-06-10 09:42\n'));
    expect(markdown, contains('Please add cache invalidation.'));
    expect(markdown, contains('<a id="message-2"></a>\n'));
    expect(markdown, contains('### 2. Assistant \u2014 2026-06-10 09:43\n'));
    expect(markdown, contains('Implemented it.'));
    expect(markdown, contains('<a id="message-3"></a>\n'));
  });

  test('honors selected message, range, and onward scopes', () {
    final exporter = const MarkdownSessionExporter();

    final selected = exporter.exportMarkdown(
      _session(),
      const MarkdownExportRequest(
        scope: MarkdownExportScope.selectedMessage(1),
      ),
    );
    expect(selected, contains('### 2. Assistant'));
    expect(selected, isNot(contains('### 1. User')));
    expect(selected, isNot(contains('### 3. Tool')));

    final range = exporter.exportMarkdown(
      _session(),
      const MarkdownExportRequest(scope: MarkdownExportScope.range(0, 1)),
    );
    expect(range, contains('### 1. User'));
    expect(range, contains('### 2. Assistant'));
    expect(range, isNot(contains('### 3. Tool')));

    final onward = exporter.exportMarkdown(
      _session(),
      const MarkdownExportRequest(
        scope: MarkdownExportScope.fromMessageOnward(1),
      ),
    );
    expect(onward, isNot(contains('### 1. User')));
    expect(onward, contains('### 2. Assistant'));
    expect(onward, contains('### 3. Tool'));
  });

  test('only selected messages filters the requested export scope', () {
    final markdown = const MarkdownSessionExporter().exportMarkdown(
      _session(),
      const MarkdownExportRequest(
        scope: MarkdownExportScope.all(),
        selectedMessageIndexes: {0, 2},
        options: MarkdownExportOptions(onlySelectedMessages: true),
      ),
    );

    expect(markdown, contains('### 1. User'));
    expect(markdown, isNot(contains('### 2. Assistant')));
    expect(markdown, contains('### 3. Tool'));
  });

  test(
    'options suppress metadata, usage, timestamps, tool calls, and fences',
    () {
      final markdown = const MarkdownSessionExporter().exportMarkdown(
        _session(),
        const MarkdownExportRequest(
          scope: MarkdownExportScope.all(),
          options: MarkdownExportOptions(
            includeMetadata: false,
            includeTokenUsage: false,
            includeTimestamps: false,
            includeToolCalls: false,
            includeCodeBlocks: false,
          ),
        ),
      );

      expect(markdown, isNot(contains('- Source:')));
      expect(markdown, isNot(contains('- Tokens:')));
      expect(markdown, contains('### 1. User\n'));
      expect(markdown, contains('### 2. Assistant\n'));
      expect(markdown, isNot(contains('```')));
      expect(markdown, isNot(contains('Tool calls')));
      expect(markdown, isNot(contains('print("done")')));
    },
  );

  test('tool output is omitted by default and included when requested', () {
    final exporter = const MarkdownSessionExporter();

    final defaultMarkdown = exporter.exportMarkdown(
      _session(),
      const MarkdownExportRequest(scope: MarkdownExportScope.all()),
    );
    expect(defaultMarkdown, contains('- shell_command (success)'));
    expect(defaultMarkdown, contains('Output omitted by export options.'));
    expect(defaultMarkdown, isNot(contains('TASKS.md')));

    final fullOutputMarkdown = exporter.exportMarkdown(
      _session(),
      const MarkdownExportRequest(
        scope: MarkdownExportScope.all(),
        options: MarkdownExportOptions(includeFullToolOutput: true),
        fullToolOutputsByToolIndex: {0: 'TASKS.md\nREADME.md'},
      ),
    );
    expect(fullOutputMarkdown, contains('TASKS.md'));
    expect(fullOutputMarkdown, contains('README.md'));
    expect(
      fullOutputMarkdown,
      isNot(contains('Output is truncated in parsed data.')),
    );
  });

  test('exports selected message as plain text', () {
    final text = const MarkdownSessionExporter().exportPlainText(
      _session(),
      const MarkdownPlainTextExportRequest.selectedMessage(1),
    );

    expect(text, 'Implemented it.\n\n```dart\nprint("done")\n```');
  });

  test('marks truncated message content in Markdown exports', () {
    final session = _session(
      messages: [
        CodexParsedMessage(
          index: 0,
          authorType: CodexMessageAuthorType.assistant,
          rawType: 'message',
          createdAtUtc: DateTime.utc(2026, 6, 10, 9, 42),
          firstLine: 'Partial content',
          contentPlain: 'Partial content',
          contentPreview: 'Partial content',
          contentTruncated: true,
          usage: const CodexUsage.empty(),
          model: null,
          hasToolCalls: false,
          hasError: false,
        ),
      ],
      toolCalls: const [],
    );

    final markdown = const MarkdownSessionExporter().exportMarkdown(
      session,
      const MarkdownExportRequest(scope: MarkdownExportScope.all()),
    );

    expect(markdown, contains('Partial content'));
    expect(
      markdown,
      contains('_Message content is truncated in parsed data._'),
    );
  });
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
    summary: 'Synthetic export session',
    startedAtUtc: DateTime.utc(2026, 6, 10, 9, 42),
    lastMessageAtUtc: DateTime.utc(2026, 6, 10, 9, 50),
    modelIds: const {'gpt-5.5-thinking'},
    messages:
        messages ??
        [
          CodexParsedMessage(
            index: 0,
            authorType: CodexMessageAuthorType.user,
            rawType: 'message',
            createdAtUtc: DateTime.utc(2026, 6, 10, 9, 42),
            firstLine: 'Please add cache invalidation.',
            contentPlain: 'Please add cache invalidation.',
            contentPreview: 'Please add cache invalidation.',
            contentTruncated: false,
            usage: const CodexUsage(inputTokens: 12),
            model: null,
            hasToolCalls: false,
            hasError: false,
          ),
          CodexParsedMessage(
            index: 1,
            authorType: CodexMessageAuthorType.assistant,
            rawType: 'message',
            createdAtUtc: DateTime.utc(2026, 6, 10, 9, 43),
            firstLine: 'Implemented it.',
            contentPlain: 'Implemented it.\n\n```dart\nprint("done")\n```',
            contentPreview: 'Implemented it.',
            contentTruncated: false,
            usage: const CodexUsage(outputTokens: 8),
            model: 'gpt-5.5-thinking',
            hasToolCalls: true,
            hasError: false,
          ),
          CodexParsedMessage(
            index: 2,
            authorType: CodexMessageAuthorType.tool,
            rawType: 'tool_call',
            createdAtUtc: DateTime.utc(2026, 6, 10, 9, 44),
            firstLine: 'Tool call completed.',
            contentPlain: 'Tool call completed.',
            contentPreview: 'Tool call completed.',
            contentTruncated: false,
            usage: const CodexUsage.empty(),
            model: null,
            hasToolCalls: false,
            hasError: false,
          ),
        ],
    toolCalls:
        toolCalls ??
        [
          CodexParsedToolCall(
            messageIndex: 1,
            toolIndex: 0,
            toolName: 'shell_command',
            status: 'success',
            startedAtUtc: DateTime.utc(2026, 6, 10, 9, 43, 30),
            finishedAtUtc: DateTime.utc(2026, 6, 10, 9, 43, 35),
            inputPreview: 'Get-ChildItem',
            outputPreview: 'TASKS.md',
            outputTruncated: true,
            errorMessage: null,
          ),
        ],
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
