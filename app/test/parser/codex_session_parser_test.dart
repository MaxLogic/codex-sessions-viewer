import 'dart:io';

import 'package:codex_sessions_viewer/src/parser/codex_session_parser.dart';
import 'package:codex_sessions_viewer/src/parser/parsed_session_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  final parser = CodexSessionParser(maxToolOutputPreviewChars: 24);

  test(
    'extracts identity, paths, messages, tool calls, model, and usage',
    () async {
      final result = await parser.parseFile(
        _fixture('sample_windows_session.json'),
      );

      expect(result.isSuccess, isTrue);
      final session = result.session!;
      expect(session.sessionId, 'win-session-001');
      expect(session.sourceType, CodexSessionSourceType.windows);
      expect(session.sourcePath, contains(r'win-session-001.json'));
      expect(session.displayPath, startsWith(r'C:\Users\pawel'));
      expect(session.platformPath, startsWith(r'C:\Users\pawel'));
      expect(
        session.workingDirectoryDisplay,
        r'F:\projects\MaxLogic\codex-sessions-viewer',
      );
      expect(session.title, 'Windows parser fixture');
      expect(session.modelIds, contains('gpt-5.5-thinking'));
      expect(session.startedAtUtc, DateTime.utc(2026, 6, 10, 8));
      expect(session.messages, hasLength(3));
      expect(session.messages.first.authorType, CodexMessageAuthorType.user);
      expect(session.messages[1].usage.outputTokens, 16);
      expect(session.toolCalls.single.toolName, 'shell');
      expect(session.toolCalls.single.status, 'success');
      expect(session.toolCalls.single.toolIndex, 0);
      expect(session.usage.inputTokens, 24);
      expect(session.usage.outputTokens, 16);
      expect(session.usage.cachedInputTokens, 3);
      expect(session.lastMessageAtUtc, DateTime.utc(2026, 6, 10, 8, 0, 4));
    },
  );

  test(
    'extracts WSL display and platform paths separately from UNC source',
    () async {
      final result = await parser.parseFile(
        _fixture('sample_wsl_session.json'),
      );

      expect(result.isSuccess, isTrue);
      final session = result.session!;
      expect(session.sourceType, CodexSessionSourceType.wsl);
      expect(session.sourcePath, startsWith(r'\\wsl.localhost\Ubuntu'));
      expect(session.sourceFileUncPath, startsWith(r'\\wsl.localhost\Ubuntu'));
      expect(session.displayPath, startsWith('/home/pawel/.codex'));
      expect(session.platformPath, startsWith('/home/pawel/.codex'));
      expect(
        session.workingDirectoryPlatform,
        '/home/pawel/projects/codex-sessions-viewer',
      );
      expect(session.toolCalls.single.hasError, isTrue);
    },
  );

  test('preserves unknown message types as unknown messages', () async {
    final result = await parser.parseFile(
      _fixture('unknown_message_session.json'),
    );

    expect(result.isSuccess, isTrue);
    final unknown = result.session!.messages.last;
    expect(unknown.authorType, CodexMessageAuthorType.unknown);
    expect(unknown.rawType, 'future_codex_event');
    expect(unknown.contentPreview, contains('new-format'));
  });

  test('returns structured parse failure for malformed JSON', () async {
    final source = _fixture('malformed_session.json');
    final result = await parser.parseFile(source);

    expect(result.isSuccess, isFalse);
    expect(result.session, isNull);
    expect(result.error?.sourcePath, source.path);
    expect(result.error?.kind, CodexParseErrorKind.malformedJson);
    expect(result.error?.offset, isNotNull);
    expect(result.error?.line, 1);
    expect(result.error?.message, contains('Unexpected end of input'));
    expect(result.error?.details, isNull);
  });

  test('parses Codex JSONL records and partial usage data', () async {
    final result = await parser.parseFile(
      _fixture('sample_codex_jsonl_session.jsonl'),
    );

    expect(result.isSuccess, isTrue);
    final session = result.session!;
    expect(session.sessionId, 'jsonl-session-001');
    expect(session.sourceType, CodexSessionSourceType.windows);
    expect(
      session.workingDirectoryDisplay,
      r'F:\projects\MaxLogic\codex-sessions-viewer',
    );
    expect(
      session.workingDirectoryUnc,
      r'\\localhost\F$\projects\MaxLogic\codex-sessions-viewer',
    );
    expect(session.summary, 'Synthetic JSONL parser fixture');
    expect(session.title, isNull);
    expect(session.modelIds, contains('gpt-5.5-thinking'));
    expect(session.startedAtUtc, DateTime.utc(2026, 6, 10, 10));
    expect(session.lastMessageAtUtc, DateTime.utc(2026, 6, 10, 10, 0, 7));
    expect(session.messages.first.firstLine, 'Open the viewer task list.');
    expect(session.messages.first.usage.inputTokens, isNull);
    expect(session.messages[1].usage.outputTokens, 17);
    expect(session.messages.last.authorType, CodexMessageAuthorType.unknown);
    expect(session.messages.last.rawType, 'future_payload');
    expect(
      session.warnings.map((warning) => warning.recordType),
      contains('future_record'),
    );
    expect(session.toolCalls.single.toolIndex, 0);
    expect(session.toolCalls.single.toolName, 'shell_command');
    expect(
      session.toolCalls.single.startedAtUtc,
      DateTime.utc(2026, 6, 10, 10, 0, 4),
    );
    expect(
      session.toolCalls.single.finishedAtUtc,
      DateTime.utc(2026, 6, 10, 10, 0, 5),
    );
    expect(session.toolCalls.single.outputPreview, 'TASKS.md');
    expect(session.usage.inputTokens, 42);
    expect(session.usage.outputTokens, 21);
    expect(session.usage.cachedInputTokens, isNull);
    expect(session.usage.totalTokens, 63);
  });

  test('uses explicit JSONL title metadata and ignores auto summary', () async {
    final temp = await Directory.systemTemp.createTemp('csv_parser_test_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}${Platform.pathSeparator}renamed.jsonl');
    await source.writeAsString('''
{"timestamp":"2026-06-10T12:00:00Z","type":"session_meta","payload":{"id":"renamed-session","cwd":"F:\\\\repo","title":"Renamed session"}}
{"timestamp":"2026-06-10T12:00:01Z","type":"turn_context","payload":{"summary":"auto","model":"gpt-5.5-thinking"}}
{"timestamp":"2026-06-10T12:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}
''');

    final result = await parser.parseFile(source);

    expect(result.isSuccess, isTrue);
    expect(result.session!.title, 'Renamed session');
    expect(result.session!.summary, isNull);
    expect(
      result.session!.messages.single.firstLine,
      '# AGENTS.md instructions',
    );
  });

  test(
    'does not classify injected environment context as user prompt',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_parser_test_');
      addTearDown(() => temp.delete(recursive: true));
      final source = File('${temp.path}${Platform.pathSeparator}context.jsonl');
      await source.writeAsString('''
{"timestamp":"2026-06-18T10:00:00Z","type":"session_meta","payload":{"id":"context-session","cwd":"F:\\\\repo"}}
{"timestamp":"2026-06-18T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>\\n  <current_date>2026-06-18</current_date>\\n  <filesystem><workspace_roots><root>F:\\\\repo</root></workspace_roots></filesystem>\\n</environment_context>"}]}}
{"timestamp":"2026-06-18T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Please explain this environment_context tag."}]}}
''');

      final result = await parser.parseFile(source);

      expect(result.isSuccess, isTrue);
      final messages = result.session!.messages;
      expect(messages, hasLength(1));
      expect(messages.single.authorType, CodexMessageAuthorType.user);
      expect(
        messages.single.contentPlain,
        'Please explain this environment_context tag.',
      );
    },
  );

  test('captures observed token usage fields and custom tool calls', () async {
    final temp = await Directory.systemTemp.createTemp('csv_parser_test_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}${Platform.pathSeparator}observed.jsonl');
    await source.writeAsString('''
{"timestamp":"2026-06-10T11:00:00Z","type":"session_meta","payload":{"id":"observed-session","cwd":"F:\\\\repo"}}
{"timestamp":"2026-06-10T11:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","call_id":"custom_1","name":"shell_command","input":"dir"}}
{"timestamp":"2026-06-10T11:00:02Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"custom_1","output":"done","status":"success"}}
{"timestamp":"2026-06-10T11:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":4,"total_tokens":19},"last_token_usage":{"input_tokens":1,"output_tokens":2,"reasoning_output_tokens":3,"total_tokens":6}}}}
{"timestamp":"2026-06-10T11:00:04Z","type":"response_item","payload":{"type":"tool_search_call","call_id":"search_1","name":"tool_search","query":"ignored content"}}
''');

    final result = await parser.parseFile(source);

    expect(result.isSuccess, isTrue);
    final session = result.session!;
    expect(session.toolCalls, hasLength(2));
    expect(session.toolCalls.first.toolName, 'shell_command');
    expect(session.toolCalls.first.status, 'success');
    expect(session.toolCalls.first.outputPreview, 'done');
    expect(session.toolCalls.last.toolName, 'tool_search');
    expect(session.toolCalls.last.status, 'started');
    expect(session.usage.inputTokens, 10);
    expect(session.usage.cachedInputTokens, 2);
    expect(session.usage.outputTokens, 3);
    expect(session.usage.reasoningOutputTokens, 4);
    expect(session.usage.totalTokens, 19);
    expect(session.lastTurnUsage.inputTokens, 1);
    expect(session.lastTurnUsage.outputTokens, 2);
    expect(session.lastTurnUsage.reasoningOutputTokens, 3);
    expect(session.lastTurnUsage.totalTokens, 6);
    expect(session.warnings, isEmpty);
  });

  test('returns line and column for malformed JSONL records', () async {
    final temp = await Directory.systemTemp.createTemp('csv_parser_test_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}${Platform.pathSeparator}broken.jsonl');
    await source.writeAsString('''
{"type":"session_meta","payload":{"id":"broken"}}
{"type":"response_item","payload":
''');

    final result = await parser.parseFile(source);

    expect(result.isSuccess, isFalse);
    expect(result.error?.sourcePath, source.path);
    expect(result.error?.kind, CodexParseErrorKind.malformedJson);
    expect(result.error?.line, 2);
    expect(result.error?.column, isPositive);
    expect(result.error?.details, isNull);
  });

  test('tolerates NUL-padded JSONL records from interrupted writes', () async {
    final temp = await Directory.systemTemp.createTemp('csv_parser_test_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}${Platform.pathSeparator}nul.jsonl');
    await source.writeAsString(
      [
        '{"timestamp":"2026-06-10T11:00:00Z","type":"session_meta","payload":{"id":"nul-session","cwd":"F:\\\\repo"}}',
        '\u0000\u0000',
        '\u0000\u0000{"timestamp":"2026-06-10T11:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"Prompt after padding"}}',
      ].join('\n'),
    );

    final result = await parser.parseFile(source);

    expect(result.isSuccess, isTrue);
    expect(result.session!.sessionId, 'nul-session');
    expect(
      result.session!.messages.single.contentPlain,
      'Prompt after padding',
    );
  });

  test(
    'tolerates missing optional fields and truncates large tool output',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_parser_test_');
      addTearDown(() => temp.delete(recursive: true));
      final source = File('${temp.path}${Platform.pathSeparator}minimal.json');
      await source.writeAsString('''
{
  "source_type": "windows",
  "messages": [
    { "type": "assistant", "content": "No title or session id here." },
    {
      "type": "tool_call",
      "tool_name": "shell",
      "status": "success",
      "output": "abcdefghijklmnopqrstuvwxyz0123456789"
    }
  ]
}
''');

      final result = await parser.parseFile(source);

      expect(result.isSuccess, isTrue);
      final session = result.session!;
      expect(session.sessionId, isNull);
      expect(session.internalId, isNotEmpty);
      expect(session.title, isNull);
      expect(session.messages, hasLength(2));
      expect(session.messages.first.contentTruncated, isFalse);
      expect(session.toolCalls.single.outputPreview, hasLength(24));
      expect(session.toolCalls.single.outputTruncated, isTrue);
    },
  );

  test(
    'assigns ordered tool indexes for legacy JSON object sessions',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_parser_test_');
      addTearDown(() => temp.delete(recursive: true));
      final source = File('${temp.path}${Platform.pathSeparator}tools.json');
      await source.writeAsString('''
{
  "source_type": "windows",
  "messages": [
    { "type": "tool_call", "tool_name": "shell", "status": "success" },
    { "type": "tool_call", "tool_name": "shell", "status": "success" }
  ]
}
''');

      final result = await parser.parseFile(source);

      expect(result.isSuccess, isTrue);
      expect(result.session!.toolCalls.map((toolCall) => toolCall.toolIndex), [
        0,
        1,
      ]);
    },
  );

  test('records parse failure metadata without raw session copies', () async {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute('''
      create table sessions (
        id text primary key,
        source_type text not null check (source_type in ('windows', 'wsl')),
        source_file_path text not null,
        display_path text not null,
        platform_path text not null,
        parse_status text not null default 'available',
        parse_error text,
        created_at_utc text not null,
        updated_at_utc text not null,
        last_parsed_utc text
      )
    ''');
    const error = CodexParseError(
      sourcePath: r'C:\Users\pawel\.codex\sessions\broken.jsonl',
      kind: CodexParseErrorKind.malformedJson,
      message: 'Unexpected end of input',
      line: 2,
      column: 4,
      details: 'line 2 column 4',
    );

    const ParsedSessionStore().recordParseFailure(db, error);

    final row = db.select('select * from sessions').single;
    expect(row['source_file_path'], error.sourcePath);
    expect(row['parse_status'], 'parse_error');
    expect(row['parse_error'], contains('"kind":"malformedJson"'));
    expect(row['parse_error'], contains('"line":2'));
    expect(row['parse_error'], isNot(contains('details')));
    expect(row['parse_error'], isNot(contains('{"type":"session_meta"')));
    expect(
      db.select(
        "select name from sqlite_master where type = 'table' and name like '%raw%'",
      ),
      isEmpty,
    );
  });
}

File _fixture(String name) {
  return File('../samples/sessions/$name');
}
