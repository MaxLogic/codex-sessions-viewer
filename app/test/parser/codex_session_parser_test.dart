import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/parser/codex_session_parser.dart';
import 'package:codex_sessions_viewer/src/parser/parsed_session_store.dart';
import 'package:crypto/crypto.dart';
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
      expect(session.usageProjectionStatus, 'ambiguous');
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

  test('marks positive JSONL usage without events ambiguous', () async {
    final temp = await Directory.systemTemp.createTemp(
      'csv_parser_unprojectable_usage_',
    );
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}${Platform.pathSeparator}positive.jsonl');
    await source.writeAsString(
      [
        '{"type":"session_meta","payload":{"id":"positive-jsonl"}}',
        '{"type":"response_item","payload":{"type":"message",'
            '"role":"assistant","content":[{"type":"output_text",'
            '"text":"response"}],"usage":{"input_tokens":4,'
            '"output_tokens":2}}}',
      ].join('\n'),
    );

    final result = await parser.parseFile(source);

    expect(result.isSuccess, isTrue);
    expect(result.session!.usageEvents, isEmpty);
    expect(result.session!.usage.totalTokens, 6);
    expect(result.session!.usageProjectionStatus, 'ambiguous');
  });

  test('streams a large JSONL session stored with a json extension', () async {
    final temp = await Directory.systemTemp.createTemp('csv_parser_sniff_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}${Platform.pathSeparator}misnamed.json');
    await source.writeAsString(
      [
        '{"type":"session_meta","payload":{"id":"misnamed","cwd":"F:\\\\repo"}}',
        '{"type":"event_msg","payload":{"type":"user_message","message":"stream me"}}',
      ].join('\n'),
    );
    var streamed = false;
    final boundedParser = CodexSessionParser(
      maxLegacyJsonBytes: 32,
      jsonFormatProbeBytes: 128,
      jsonlByteStreamReader: (file, endExclusive) {
        streamed = true;
        return file.openRead(0, endExclusive);
      },
    );

    final result = await boundedParser.parseFile(source);

    expect(result.isSuccess, isTrue);
    expect(result.session!.sessionId, 'misnamed');
    expect(streamed, isTrue);
  });

  test(
    'rejects an oversized legacy JSON object before materializing it',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_parser_limit_');
      addTearDown(() => temp.delete(recursive: true));
      final source = File('${temp.path}${Platform.pathSeparator}legacy.json');
      await source.writeAsString(
        '{"messages":[{"type":"user","content":"${List.filled(128, 'x').join()}"}]}',
      );
      final boundedParser = CodexSessionParser(
        maxLegacyJsonBytes: 32,
        jsonFormatProbeBytes: 32,
      );

      final result = await boundedParser.parseFile(source);

      expect(result.isSuccess, isFalse);
      expect(result.error!.kind, CodexParseErrorKind.unsupportedRoot);
      expect(result.error!.message, contains('size limit'));
    },
  );

  test('bounded format probe may end inside a UTF-8 scalar', () async {
    final temp = await Directory.systemTemp.createTemp('csv_parser_utf8_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}${Platform.pathSeparator}legacy.json');
    await source.writeAsString('{"title":"€","messages":[]}');
    final boundedParser = CodexSessionParser(
      jsonFormatProbeBytes: utf8.encode('{"title":"').length + 1,
    );

    final result = await boundedParser.parseFile(source);

    expect(result.isSuccess, isTrue);
    expect(result.session!.title, '€');
  });

  test('streaming JSONL matches canonical persisted projection', () async {
    expect(CodexSessionParser.currentVersion, 4);
    final temp = await Directory.systemTemp.createTemp('csv_parser_oracle_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}${Platform.pathSeparator}oracle.jsonl');
    final records = <Map<String, Object?>>[
      {
        'timestamp': '2026-07-27T10:00:00Z',
        'type': 'session_meta',
        'payload': {
          'id': 'oracle-session',
          'cwd': r'F:\repo',
          'title': ' Oracle title ',
          'source_file_unc_path': r'\\localhost\F$\oracle.jsonl',
          'source': {
            'subagent': {
              'thread_spawn': {
                'parent_thread_id': 'parent',
                'agent_nickname': 'Ada',
                'agent_role': 'reviewer',
                'depth': 2,
              },
            },
          },
        },
      },
      {
        'timestamp': '2026-07-27T10:00:01Z',
        'type': 'turn_context',
        'payload': {
          'cwd': r'F:\repo\child',
          'working_directory_unc': r'\\localhost\F$\repo\child',
          'summary': ' Oracle summary ',
          'model': 'gpt-oracle',
        },
      },
      {
        'timestamp': '2026-07-27T10:00:02Z',
        'type': 'event_msg',
        'payload': {'type': 'user_message', 'message': 'same prompt'},
      },
      {
        'timestamp': '2026-07-27T10:00:03Z',
        'type': 'response_item',
        'payload': {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'same prompt'},
          ],
          'usage': {'input_tokens': 3},
        },
      },
      {
        'timestamp': '2026-07-27T10:00:04Z',
        'type': 'response_item',
        'payload': {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'assistant output beyond limit'},
          ],
          'usage': {'output_tokens': 5},
          'model': 'gpt-oracle',
        },
      },
      {
        'timestamp': '2026-07-27T10:00:05Z',
        'type': 'response_item',
        'payload': {
          'type': 'reasoning',
          'summary': [
            {'text': 'reason one'},
            {'text': 'reason two'},
          ],
        },
      },
      {
        'timestamp': '2026-07-27T10:00:06Z',
        'type': 'response_item',
        'payload': {
          'type': 'function_call',
          'call_id': 'call-1',
          'name': 'shell_command',
          'arguments': '1234567890',
        },
      },
      {
        'timestamp': '2026-07-27T10:00:07Z',
        'type': 'response_item',
        'payload': {
          'type': 'function_call_output',
          'call_id': 'call-1',
          'output': 'abcdefghijk',
          'status': 'success',
        },
      },
      {
        'timestamp': '2026-07-27T10:00:08Z',
        'type': 'response_item',
        'payload': {
          'type': 'custom_tool_call_output',
          'call_id': 'orphan',
          'output': 'orphan',
          'error': 'failed',
        },
      },
      {
        'timestamp': '2026-07-27T10:00:09Z',
        'type': 'response_item',
        'payload': {
          'type': 'tool_search_call',
          'call_id': 'search-1',
          'query': 'search me',
        },
      },
      {
        'timestamp': '2026-07-27T10:00:10Z',
        'type': 'event_msg',
        'payload': {
          'type': 'token_count',
          'info': {
            'total_token_usage': {
              'input_tokens': 10,
              'output_tokens': 20,
              'cached_input_tokens': 2,
              'reasoning_output_tokens': 4,
              'total_tokens': 36,
            },
            'last_token_usage': {
              'input_tokens': 1,
              'output_tokens': 2,
              'total_tokens': 3,
            },
          },
        },
      },
      {
        'timestamp': '2026-07-27T10:00:11Z',
        'type': 'response_item',
        'payload': {'type': 'ghost_snapshot', 'ignored': true},
      },
      {
        'timestamp': '2026-07-27T10:00:12Z',
        'type': 'event_msg',
        'payload': {'type': 'context_compacted', 'detail': 'kept as unknown'},
      },
      {
        'timestamp': '2026-07-27T10:00:13Z',
        'type': 'response_item',
        'payload': {'type': 'future_response', 'value': 7},
      },
      {
        'timestamp': '2026-07-27T10:00:14Z',
        'type': 'event_msg',
        'payload': {'type': 'future_event', 'value': 8},
      },
      {
        'timestamp': '2026-07-27T10:00:15Z',
        'type': 'future_record',
        'payload': {'type': 'future_container'},
      },
      {
        'timestamp': '2026-07-27T10:00:16Z',
        'type': 'compacted',
        'payload': {'type': 'ignored'},
      },
    ];
    await source.writeAsString(records.map(jsonEncode).join('\n'));

    final result = await CodexSessionParser(
      maxMessageContentChars: 12,
      maxToolOutputPreviewChars: 8,
    ).parseFile(source);

    expect(result.isSuccess, isTrue);
    final projectionJson = jsonEncode(_persistedProjection(result.session!));
    expect(
      sha256.convert(utf8.encode(projectionJson)).toString(),
      '870a3d0b8687b5677a84a2def7f954ec78af6339e15118c4393817ebd2540f5e',
    );
  });

  test('keeps owning fork metadata authoritative', () async {
    final temp = await Directory.systemTemp.createTemp('csv_parser_test_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File(
      '${temp.path}${Platform.pathSeparator}first-session.jsonl',
    );
    await source.writeAsString('''
{"timestamp":"2026-06-10T09:59:59Z","type":"session_meta","payload":{"id":"","cwd":"F:\\\\invalid","thread_source":"subagent"}}
{"timestamp":"2026-06-10T10:00:00Z","type":"session_meta","payload":{"id":"first-session","cwd":"F:\\\\first","thread_source":"user","parent_thread_id":"fork-parent","forked_from_id":"original-session","history_base":{"thread_id":"original-session","end_ordinal_exclusive":42,"end_byte_offset":4096},"subagent_history_start_ordinal":37}}
{"timestamp":"2026-06-10T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"First session message."}]}}
{"timestamp":"2026-06-10T10:00:02Z","type":"session_meta","payload":{"id":"embedded-session","cwd":"F:\\\\embedded","thread_source":"subagent","parent_thread_id":"wrong-parent"}}
''');

    final result = await parser.parseFile(source);

    expect(result.isSuccess, isTrue);
    expect(result.session!.sessionId, 'first-session');
    expect(result.session!.internalId, 'session:first-session');
    expect(result.session!.threadSource, 'user');
    expect(result.session!.parentThreadId, 'fork-parent');
    expect(result.session!.forkedFromId, 'original-session');
    expect(result.session!.historyBaseThreadId, 'original-session');
    expect(result.session!.historyBaseEndOrdinalExclusive, 42);
    expect(result.session!.historyBaseEndByteOffset, 4096);
    expect(result.session!.subagentHistoryStartOrdinal, 37);
    expect(result.session!.workingDirectoryPlatform, r'F:\first');
    expect(result.session!.startedAtUtc, DateTime.utc(2026, 6, 10, 10));

    final subagentSource = File(
      '${temp.path}${Platform.pathSeparator}subagent-fork.jsonl',
    );
    await subagentSource.writeAsString('''
{"timestamp":"2026-06-10T11:00:00Z","type":"session_meta","payload":{"id":"subagent-session","cwd":"F:\\\\repo","forked_from_id":"first-session","subagent_history_start_ordinal":12,"source":{"subagent":{"thread_spawn":{"parent_thread_id":"first-session","depth":1,"agent_nickname":"Lovelace","agent_role":"default"}}}}}
''');

    final subagentResult = await parser.parseFile(subagentSource);

    expect(subagentResult.isSuccess, isTrue);
    expect(subagentResult.session!.threadSource, 'subagent');
    expect(subagentResult.session!.parentThreadId, 'first-session');
    expect(subagentResult.session!.forkedFromId, 'first-session');
    expect(subagentResult.session!.subagentHistoryStartOrdinal, 12);

    final forkOfForkSource = File(
      '${temp.path}${Platform.pathSeparator}fork-of-fork.jsonl',
    );
    await forkOfForkSource.writeAsString('''
{"timestamp":"2026-06-10T12:00:00Z","type":"session_meta","payload":{"id":"grandchild-session","cwd":"F:\\\\repo","forked_from_id":"subagent-session","history_base":{"thread_id":"subagent-session","end_ordinal_exclusive":9,"end_byte_offset":2048}}}
''');

    final forkOfForkResult = await parser.parseFile(forkOfForkSource);

    expect(forkOfForkResult.isSuccess, isTrue);
    expect(forkOfForkResult.session!.forkedFromId, 'subagent-session');
    expect(forkOfForkResult.session!.historyBaseThreadId, 'subagent-session');
    expect(forkOfForkResult.session!.historyBaseEndOrdinalExclusive, 9);
  });

  test('emits each distinct branch-local usage advancement once', () async {
    final temp = await Directory.systemTemp.createTemp('csv_parser_test_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File(
      '${temp.path}${Platform.pathSeparator}usage-advancements.jsonl',
    );
    await source.writeAsString('''
{"timestamp":"2026-07-29T10:00:00Z","type":"session_meta","payload":{"id":"usage-session","cwd":"F:\\\\repo","working_directory_unc":"\\\\\\\\wsl.localhost\\\\Ubuntu\\\\home\\\\user\\\\repo"}}
{"timestamp":"2026-07-29T10:00:01Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.5","cwd":"F:\\\\pre-turn"}}}
{"timestamp":"2026-07-29T10:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"cache_write_input_tokens":1,"output_tokens":3,"reasoning_output_tokens":1,"total_tokens":13},"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"cache_write_input_tokens":1,"output_tokens":3,"reasoning_output_tokens":1,"total_tokens":13}}}}
{"timestamp":"2026-07-29T10:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"cached_input_tokens":2,"cache_write_input_tokens":1,"output_tokens":3,"reasoning_output_tokens":1,"total_tokens":13},"last_token_usage":{"input_tokens":10,"cached_input_tokens":2,"cache_write_input_tokens":1,"output_tokens":3,"reasoning_output_tokens":1,"total_tokens":13}}}}
{"timestamp":"2026-07-29T10:00:04Z","type":"turn_context","payload":{"cwd":"F:\\\\repo","model":"gpt-5.6-sol"}}
{"timestamp":"2026-07-29T10:00:05Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":18,"cached_input_tokens":4,"cache_write_input_tokens":2,"output_tokens":7,"reasoning_output_tokens":3,"total_tokens":25},"last_token_usage":{"input_tokens":8,"cached_input_tokens":2,"cache_write_input_tokens":1,"output_tokens":4,"reasoning_output_tokens":2,"total_tokens":12}}}}
{"timestamp":"2026-07-29T10:00:06Z","type":"event_msg","payload":{"type":"model_reroute","from_model":"gpt-5.6-sol","to_model":"gpt-5.6-terra"}}
{"timestamp":"2026-07-29T10:00:07Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":25,"cached_input_tokens":5,"cache_write_input_tokens":3,"output_tokens":10,"reasoning_output_tokens":4,"total_tokens":35},"last_token_usage":{"input_tokens":99,"cached_input_tokens":99,"cache_write_input_tokens":99,"output_tokens":99,"reasoning_output_tokens":99,"total_tokens":198}}}}
{"timestamp":"2026-07-29T10:00:08Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"gpt-5.5","cwd":"F:\\\\other"}}}
{"timestamp":"2026-07-29T10:00:09Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4,"cached_input_tokens":1,"cache_write_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":6},"last_token_usage":{"input_tokens":4,"cached_input_tokens":1,"cache_write_input_tokens":0,"output_tokens":2,"reasoning_output_tokens":1,"total_tokens":6}}}}
''');

    final result = await parser.parseFile(source);

    expect(result.isSuccess, isTrue);
    expect(result.session!.warnings, isEmpty);
    expect(result.session!.messages, isEmpty);
    expect(
      const CodexUsage(
        inputTokens: 10,
        cachedInputTokens: 5,
        cacheWriteInputTokens: 2,
        outputTokens: 3,
        reasoningOutputTokens: 2,
      ).totalTokens,
      13,
    );
    final events = result.session!.usageEvents;
    expect(events, hasLength(4));
    expect(events.map((event) => event.sourceRecordOrdinal), [2, 5, 7, 9]);
    expect(events.map((event) => event.usage.inputTokens), [10, 8, 7, 4]);
    expect(events.map((event) => event.derivation), [
      'last_token_usage',
      'last_token_usage',
      'cumulative_delta',
      'counter_reset',
    ]);
    expect(events.map((event) => event.turnOrdinal), [null, 0, 0, 0]);
    expect(events.map((event) => event.rolloutOrdinal), everyElement(isNull));
    expect(events.map((event) => event.counterEpoch), [0, 0, 0, 1]);
    expect(events.map((event) => event.model), [
      'gpt-5.5',
      'gpt-5.6-sol',
      'gpt-5.6-terra',
      'gpt-5.5',
    ]);
    expect(events.map((event) => event.workingDirectory), [
      r'F:\pre-turn',
      r'F:\repo',
      r'F:\repo',
      r'F:\other',
    ]);
    expect(
      events.map((event) => event.workingDirectoryUnc),
      everyElement(isNull),
    );
    expect(events.map((event) => event.branchScope), everyElement('local'));
    expect(events.first.occurredAtUtc, DateTime.utc(2026, 7, 29, 10, 0, 2));
    expect(events.first.cumulativeUsage.cacheWriteInputTokens, 1);
    expect(
      events.map((event) => event.eventFingerprint).toSet(),
      hasLength(events.length),
    );
    expect(
      events.map((event) => event.eventFingerprint),
      everyElement(isNotEmpty),
    );
    expect(
      events.expand(
        (event) => [
          event.usage.inputTokens,
          event.usage.cachedInputTokens,
          event.usage.cacheWriteInputTokens,
          event.usage.outputTokens,
          event.usage.reasoningOutputTokens,
          event.usage.totalTokens,
        ],
      ),
      everyElement(isNonNegative),
    );
    expect(result.session!.usageProjectionStatus, 'complete');

    Future<CodexParsedSession> parseBranch(String name, String records) async {
      final branchSource = File(
        '${temp.path}${Platform.pathSeparator}$name.jsonl',
      );
      await branchSource.writeAsString(records);
      final branchResult = await parser.parseFile(branchSource);
      expect(branchResult.isSuccess, isTrue);
      return branchResult.session!;
    }

    final paginatedFork = await parseBranch('paginated-fork', '''
{"timestamp":"2026-07-29T11:00:00Z","type":"session_meta","payload":{"id":"paginated-child","cwd":"F:\\\\base","forked_from_id":"parent","history_base":{"thread_id":"parent","end_ordinal_exclusive":500,"end_byte_offset":9000},"subagent_history_start_ordinal":100}}
{"rollout_ordinal":90,"timestamp":"2026-07-29T11:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6},"last_token_usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}}}
''');
    expect(paginatedFork.usageProjectionStatus, 'complete');
    expect(paginatedFork.usageEvents.single.branchScope, 'local');
    expect(paginatedFork.usageEvents.single.workingDirectory, r'F:\base');

    final projectedSubagent = await parseBranch('projected-subagent', '''
{"timestamp":"2026-07-29T12:00:00Z","type":"session_meta","payload":{"id":"projected-child","cwd":"F:\\\\child-base","forked_from_id":"parent","subagent_history_start_ordinal":100}}
{"rollout_ordinal":70,"timestamp":"2026-07-29T12:00:00.250Z","type":"event_msg","payload":{"type":"thread_settings_applied","thread_settings":{"model":"parent-settings-model","cwd":"F:\\\\parent-settings"}}}
{"rollout_ordinal":75,"timestamp":"2026-07-29T12:00:00.375Z","type":"event_msg","payload":{"type":"model_reroute","from_model":"parent-settings-model","to_model":"parent-reroute-model"}}
{"rollout_ordinal":80,"timestamp":"2026-07-29T12:00:00.500Z","type":"turn_context","payload":{"cwd":"F:\\\\parent","model":"parent-model"}}
{"rollout_ordinal":90,"timestamp":"2026-07-29T12:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12},"last_token_usage":{"input_tokens":10,"output_tokens":2,"total_tokens":12}}}}
{"rollout_ordinal":105,"timestamp":"2026-07-29T12:00:01.500Z","type":"turn_context","payload":{"cwd":"F:\\\\child","model":"child-model"}}
{"rollout_ordinal":110,"timestamp":"2026-07-29T12:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":15,"output_tokens":3,"total_tokens":18},"last_token_usage":{"input_tokens":5,"output_tokens":1,"total_tokens":6}}}}
''');
    expect(projectedSubagent.usageProjectionStatus, 'complete');
    expect(projectedSubagent.usageEvents.map((event) => event.branchScope), [
      'inherited',
      'local',
    ]);
    expect(projectedSubagent.usageEvents.map((event) => event.rolloutOrdinal), [
      90,
      110,
    ]);
    expect(projectedSubagent.usageEvents.map((event) => event.turnOrdinal), [
      null,
      0,
    ]);
    expect(projectedSubagent.usageEvents.first.model, isNull);
    expect(
      projectedSubagent.usageEvents.first.workingDirectory,
      r'F:\child-base',
    );
    expect(projectedSubagent.usageEvents.last.model, 'child-model');
    expect(projectedSubagent.usageEvents.last.workingDirectory, r'F:\child');
    expect(projectedSubagent.workingDirectoryPlatform, r'F:\child');

    final unprojectedSubagent = await parseBranch('unprojected-subagent', '''
{"timestamp":"2026-07-29T13:00:00Z","type":"session_meta","payload":{"id":"unprojected-child","cwd":"F:\\\\base","forked_from_id":"parent","subagent_history_start_ordinal":100}}
{"timestamp":"2026-07-29T13:00:00.500Z","type":"turn_context","payload":{"cwd":"F:\\\\unproven","model":"unproven-model"}}
{"timestamp":"2026-07-29T13:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6},"last_token_usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}}}
''');
    expect(unprojectedSubagent.usageProjectionStatus, 'ambiguous');
    expect(unprojectedSubagent.usageEvents.single.branchScope, 'ambiguous');
    expect(unprojectedSubagent.usageEvents.single.turnOrdinal, isNull);
    expect(unprojectedSubagent.workingDirectoryPlatform, r'F:\base');

    final legacyFork = await parseBranch('legacy-fork', '''
{"timestamp":"2026-07-29T14:00:00Z","type":"session_meta","payload":{"id":"legacy-child","cwd":"F:\\\\child","forked_from_id":"parent"}}
{"timestamp":"2026-07-29T14:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"output_tokens":10,"total_tokens":50},"last_token_usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}}}
''');
    expect(legacyFork.usageProjectionStatus, 'legacy_pending');
    expect(legacyFork.usageEvents.single.branchScope, 'ambiguous');
    expect(legacyFork.usageEvents.single.usage.inputTokens, 4);

    final nestedOnlyFork = await parseBranch('nested-only-fork', '''
{"timestamp":"2026-07-29T14:30:00Z","type":"session_meta","payload":{"id":"nested-child","cwd":"F:\\\\child","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent","depth":1}}}}}
{"timestamp":"2026-07-29T14:30:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6},"last_token_usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}}}
''');
    expect(nestedOnlyFork.parentThreadId, 'parent');
    expect(nestedOnlyFork.usageProjectionStatus, 'legacy_pending');
    expect(nestedOnlyFork.usageEvents.single.branchScope, 'ambiguous');

    final legacyParent = await parseBranch('legacy-parent', '''
{"timestamp":"2026-07-29T14:00:00Z","type":"session_meta","payload":{"id":"parent","cwd":"F:\\\\parent"}}
{"timestamp":"2026-07-29T14:00:00.500Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":36,"output_tokens":8,"total_tokens":44},"last_token_usage":{"input_tokens":36,"output_tokens":8,"total_tokens":44}}}}
{"timestamp":"2026-07-29T14:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":40,"output_tokens":10,"total_tokens":50},"last_token_usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}}}
''');
    expect(
      legacyParent.usageEvents.last.eventFingerprint,
      legacyFork.usageEvents.single.eventFingerprint,
    );

    final zeroWorkFork = await parseBranch('zero-work-fork', '''
{"timestamp":"2026-07-29T15:00:00Z","type":"session_meta","payload":{"id":"zero-work-child","forked_from_id":"parent"}}
{"timestamp":"2026-07-29T15:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0},"last_token_usage":{"input_tokens":0,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":0}}}}
''');
    expect(zeroWorkFork.usageEvents, isEmpty);
    expect(zeroWorkFork.usageProjectionStatus, 'complete');

    final zeroReset = await parseBranch('zero-reset', '''
{"timestamp":"2026-07-29T16:00:00Z","type":"session_meta","payload":{"id":"zero-reset"}}
{"timestamp":"2026-07-29T16:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6},"last_token_usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}}}
{"timestamp":"2026-07-29T16:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":0,"output_tokens":0,"total_tokens":0},"last_token_usage":{"input_tokens":0,"output_tokens":0,"total_tokens":0}}}}
{"timestamp":"2026-07-29T16:00:03Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":10,"output_tokens":4,"total_tokens":14},"last_token_usage":{"input_tokens":3,"output_tokens":1,"total_tokens":4}}}}
''');
    expect(zeroReset.usageEvents.map((event) => event.usage.inputTokens), [
      4,
      10,
    ]);
    expect(zeroReset.usageEvents.map((event) => event.counterEpoch), [0, 1]);
    expect(zeroReset.usageEvents.last.derivation, 'counter_reset');
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
    expect(result.session!.threadName, 'Renamed session');
    expect(result.session!.summary, isNull);
    expect(
      result.session!.messages.single.firstLine,
      '# AGENTS.md instructions',
    );
  });

  test('invalid explicit token total falls back to components', () async {
    final temp = await Directory.systemTemp.createTemp('csv_parser_test_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File(
      '${temp.path}${Platform.pathSeparator}invalid-total.jsonl',
    );
    await source.writeAsString('''
{"timestamp":"2026-07-29T17:00:00Z","type":"session_meta","payload":{"id":"invalid-total"}}
{"timestamp":"2026-07-29T17:00:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":0,"output_tokens":0,"total_tokens":121600},"last_token_usage":{"input_tokens":0,"output_tokens":0,"total_tokens":121600},"model_context_window":121600}}}
{"timestamp":"2026-07-29T17:00:02Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":4,"output_tokens":2,"total_tokens":121600},"last_token_usage":{"input_tokens":4,"output_tokens":2,"total_tokens":121600}}}}
''');

    final result = await parser.parseFile(source);

    expect(result.isSuccess, isTrue);
    expect(result.session!.usage.totalTokens, 121600);
    expect(result.session!.usageEvents, hasLength(1));
    expect(result.session!.usageEvents.single.usage.totalTokens, 6);
  });

  test('extracts subagent origin metadata from JSONL session_meta', () async {
    final temp = await Directory.systemTemp.createTemp('csv_parser_test_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}${Platform.pathSeparator}subagent.jsonl');
    await source.writeAsString('''
{"timestamp":"2026-06-18T22:06:02Z","type":"session_meta","payload":{"id":"child-session","parent_thread_id":"parent-session","cwd":"F:\\\\projects\\\\OEC\\\\_git\\\\TE5","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-session","depth":1,"agent_nickname":"Russell","agent_role":"default"}}},"thread_source":"subagent","agent_nickname":"Russell","agent_role":"default"}}
{"timestamp":"2026-06-18T22:06:03Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Subagent report."}]}}
''');

    final result = await parser.parseFile(source);

    expect(result.isSuccess, isTrue);
    final session = result.session!;
    expect(session.threadSource, 'subagent');
    expect(session.parentThreadId, 'parent-session');
    expect(session.agentNickname, 'Russell');
    expect(session.agentRole, 'default');
    expect(session.subagentDepth, 1);
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

  test(
    'hides injected AGENTS instructions and deduplicates echoed user messages',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_parser_test_');
      addTearDown(() => temp.delete(recursive: true));
      final source = File('${temp.path}${Platform.pathSeparator}agents.jsonl');
      await source.writeAsString('''
{"timestamp":"2026-06-18T10:00:00Z","type":"session_meta","payload":{"id":"agents-session","cwd":"F:\\\\repo"}}
{"timestamp":"2026-06-18T10:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions for F:\\\\repo\\n\\n<INSTRUCTIONS>\\nPreserve secrets.\\n</INSTRUCTIONS>"}]}}
{"timestamp":"2026-06-18T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Please explain the parser output."}]}}
{"timestamp":"2026-06-18T10:00:03Z","type":"event_msg","payload":{"type":"user_message","message":"Please explain the parser output."}}
{"timestamp":"2026-06-18T10:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Parser explanation."}]}}
''');

      final result = await parser.parseFile(source);

      expect(result.isSuccess, isTrue);
      final messages = result.session!.messages;
      expect(messages.map((message) => message.contentPlain), [
        'Please explain the parser output.',
        'Parser explanation.',
      ]);
      expect(messages.first.authorType, CodexMessageAuthorType.user);
      expect(messages.last.authorType, CodexMessageAuthorType.assistant);
    },
  );

  test(
    'shows encrypted reasoning as unavailable and keeps message indexes unique',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_parser_test_');
      addTearDown(() => temp.delete(recursive: true));
      final source = File(
        '${temp.path}${Platform.pathSeparator}reasoning.jsonl',
      );
      await source.writeAsString('''
{"timestamp":"2026-06-18T10:00:00Z","type":"session_meta","payload":{"id":"reasoning-session","cwd":"F:\\\\repo"}}
{"timestamp":"2026-06-18T10:00:01Z","type":"event_msg","payload":{"type":"user_message","message":"Find the bug."}}
{"timestamp":"2026-06-18T10:00:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Find the bug."}]}}
{"timestamp":"2026-06-18T10:00:03Z","type":"response_item","payload":{"type":"reasoning","summary":[],"encrypted_content":"opaque"}}
{"timestamp":"2026-06-18T10:00:04Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Found it."}]}}
''');

      final result = await parser.parseFile(source);

      expect(result.isSuccess, isTrue);
      final messages = result.session!.messages;
      expect(messages.map((message) => message.contentPlain), [
        'Find the bug.',
        'Reasoning content is encrypted and cannot be displayed.',
        'Found it.',
      ]);
      expect(messages.map((message) => message.index), [0, 1, 2]);
      expect(messages.map((message) => message.rawType), [
        'message',
        'reasoning',
        'message',
      ]);
      expect(messages.map((message) => message.authorType), [
        CodexMessageAuthorType.user,
        CodexMessageAuthorType.reasoning,
        CodexMessageAuthorType.assistant,
      ]);
      expect(messages[1].hasToolCalls, isFalse);
      expect(result.session!.warnings, isEmpty);
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

  test('rejects a short read of the fixed JSONL snapshot', () async {
    final temp = await Directory.systemTemp.createTemp('csv_parser_short_');
    addTearDown(() => temp.delete(recursive: true));
    final source = File('${temp.path}${Platform.pathSeparator}short.jsonl');
    const first = '{"type":"session_meta","payload":{"id":"short-read"}}';
    const second =
        '{"type":"response_item","payload":{"type":"message","role":"user","content":"must be read"}}';
    await source.writeAsString('$first\n$second');
    final parser = CodexSessionParser(
      jsonlByteStreamReader: (file, endExclusive) =>
          file.openRead(0, utf8.encode('$first\n').length),
    );

    final result = await parser.parseFile(source);

    expect(result.isSuccess, isFalse);
    expect(result.error?.kind, CodexParseErrorKind.io);
    expect(result.error?.message, contains('changed while being parsed'));
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

Map<String, Object?> _persistedProjection(CodexParsedSession session) => {
  'session_id': session.sessionId,
  'thread_name': session.threadName,
  'thread_source': session.threadSource,
  'parent_thread_id': session.parentThreadId,
  'forked_from_id': session.forkedFromId,
  'history_base_thread_id': session.historyBaseThreadId,
  'history_base_end_ordinal_exclusive': session.historyBaseEndOrdinalExclusive,
  'history_base_end_byte_offset': session.historyBaseEndByteOffset,
  'subagent_history_start_ordinal': session.subagentHistoryStartOrdinal,
  'usage_projection_status': session.usageProjectionStatus,
  'agent_nickname': session.agentNickname,
  'agent_role': session.agentRole,
  'subagent_depth': session.subagentDepth,
  'source_file_unc_path': session.sourceFileUncPath,
  'working_directory_display': session.workingDirectoryDisplay,
  'working_directory_unc': session.workingDirectoryUnc,
  'title': session.title,
  'summary': session.summary,
  'started_at_utc': session.startedAtUtc?.toIso8601String(),
  'last_message_at_utc': session.lastMessageAtUtc?.toIso8601String(),
  'models': session.modelIds.toList()..sort(),
  'usage': _usageProjection(session.usage),
  'last_turn_usage': _usageProjection(session.lastTurnUsage),
  'usage_events': [
    for (final event in session.usageEvents)
      {
        'source_record_ordinal': event.sourceRecordOrdinal,
        'rollout_ordinal': event.rolloutOrdinal,
        'turn_ordinal': event.turnOrdinal,
        'counter_epoch': event.counterEpoch,
        'occurred_at_utc': event.occurredAtUtc?.toIso8601String(),
        'model': event.model,
        'working_directory': event.workingDirectory,
        'working_directory_unc': event.workingDirectoryUnc,
        'usage': _usageProjection(event.usage),
        'cumulative_usage': _usageProjection(event.cumulativeUsage),
        'branch_scope': event.branchScope,
        'derivation': event.derivation,
        'event_fingerprint': event.eventFingerprint,
      },
  ],
  'messages': [
    for (final message in session.messages)
      {
        'index': message.index,
        'author': message.authorType.name,
        'raw_type': message.rawType,
        'created_at_utc': message.createdAtUtc?.toIso8601String(),
        'first_line': message.firstLine,
        'content': message.contentPlain,
        'preview': message.contentPreview,
        'truncated': message.contentTruncated,
        'usage': _usageProjection(message.usage),
        'model': message.model,
        'has_tool_calls': message.hasToolCalls,
        'has_error': message.hasError,
      },
  ],
  'tools': [
    for (final tool in session.toolCalls)
      {
        'message_index': tool.messageIndex,
        'tool_index': tool.toolIndex,
        'name': tool.toolName,
        'status': tool.status,
        'started_at_utc': tool.startedAtUtc?.toIso8601String(),
        'finished_at_utc': tool.finishedAtUtc?.toIso8601String(),
        'input': tool.inputPreview,
        'output': tool.outputPreview,
        'output_truncated': tool.outputTruncated,
        'error': tool.errorMessage,
      },
  ],
  'warnings': [
    for (final warning in session.warnings)
      {
        'code': warning.code,
        'record_type': warning.recordType,
        'payload_type': warning.payloadType,
      },
  ],
};

Map<String, Object?> _usageProjection(CodexUsage usage) => {
  'input': usage.inputTokens,
  'output': usage.outputTokens,
  'cached': usage.cachedInputTokens,
  'cache_write': usage.cacheWriteInputTokens,
  'reasoning': usage.reasoningOutputTokens,
  'total': usage.totalTokens,
};
