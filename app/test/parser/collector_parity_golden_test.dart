import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/parser/codex_session_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Rust collector ports this parser. Both parse the fixtures in
/// `samples/collector-parity/sessions` and must produce the JSON retained in
/// `samples/collector-parity/expected`; `cargo test --test local_ingestion`
/// checks the Rust side. Regenerate after an intended parser change with
/// `CODEX_PARITY_UPDATE=1 flutter test test/parser/collector_parity_golden_test.dart`.
const _fixtureDir = '../samples/collector-parity/sessions';
const _expectedDir = '../samples/collector-parity/expected';

void main() {
  final names =
      Directory(_fixtureDir)
          .listSync()
          .whereType<File>()
          .map((file) => file.uri.pathSegments.last)
          .toList()
        ..sort();

  test('parity fixtures exist', () {
    expect(names, isNotEmpty);
  });

  for (final name in names) {
    test(
      'Dart parser output matches the retained parity golden: $name',
      () async {
        final result = await CodexSessionParser().parseFile(
          File('$_fixtureDir/$name'),
        );
        final actual = const JsonEncoder.withIndent(
          '  ',
        ).convert(parityView(result));
        final golden = File('$_expectedDir/$name.json');
        if (Platform.environment['CODEX_PARITY_UPDATE'] == '1') {
          await golden.parent.create(recursive: true);
          await golden.writeAsString('$actual\n');
          return;
        }
        expect(
          golden.existsSync(),
          isTrue,
          reason: 'Missing ${golden.path}; run with CODEX_PARITY_UPDATE=1.',
        );
        expect('$actual\n', await golden.readAsString());
      },
    );
  }
}

/// What SQLite stores for a Dart string: lone surrogates left by a UTF-16
/// cut become U+FFFD when the sqlite3 package encodes UTF-8.
String? _stored(String? value) =>
    value == null ? null : utf8.decode(utf8.encode(value));

String? _time(DateTime? value) => value?.toUtc().toIso8601String();

Map<String, Object?> _usage(CodexUsage usage) => {
  'input_tokens': usage.inputTokens,
  'cached_input_tokens': usage.cachedInputTokens,
  'cache_write_input_tokens': usage.cacheWriteInputTokens,
  'output_tokens': usage.outputTokens,
  'reasoning_output_tokens': usage.reasoningOutputTokens,
  'total_tokens': usage.totalTokens,
  'is_empty': usage.isEmpty,
};

Map<String, Object?> parityView(CodexParseResult result) {
  final error = result.error;
  if (error != null) {
    return {
      'error': {'kind': error.kind.name, 'line': error.line},
    };
  }
  final session = result.session!;
  return {
    'internal_id': _stored(session.internalId),
    'session_id': _stored(session.sessionId),
    'thread_name': _stored(session.threadName),
    'thread_source': _stored(session.threadSource),
    'parent_thread_id': _stored(session.parentThreadId),
    'forked_from_id': _stored(session.forkedFromId),
    'history_base_thread_id': _stored(session.historyBaseThreadId),
    'history_base_end_ordinal_exclusive':
        session.historyBaseEndOrdinalExclusive,
    'history_base_end_byte_offset': session.historyBaseEndByteOffset,
    'subagent_history_start_ordinal': session.subagentHistoryStartOrdinal,
    'usage_projection_status': session.usageProjectionStatus,
    'agent_nickname': _stored(session.agentNickname),
    'agent_role': _stored(session.agentRole),
    'subagent_depth': session.subagentDepth,
    'source_type': session.sourceType.name,
    'source_path': _stored(session.sourcePath),
    'source_file_unc_path': _stored(session.sourceFileUncPath),
    'display_path': _stored(session.displayPath),
    'platform_path': _stored(session.platformPath),
    'working_directory_display': _stored(session.workingDirectoryDisplay),
    'working_directory_platform': _stored(session.workingDirectoryPlatform),
    'working_directory_unc': _stored(session.workingDirectoryUnc),
    'title': _stored(session.title),
    'summary': _stored(session.summary),
    'started_at_utc': _time(session.startedAtUtc),
    'last_message_at_utc': _time(session.lastMessageAtUtc),
    'model_ids': [for (final model in session.modelIds) _stored(model)],
    'usage': _usage(session.usage),
    'last_turn_usage': _usage(session.lastTurnUsage),
    'messages': [
      for (final message in session.messages)
        {
          'index': message.index,
          'author_type': message.authorType.name,
          'raw_type': _stored(message.rawType),
          'created_at_utc': _time(message.createdAtUtc),
          'first_line': _stored(message.firstLine),
          'content_plain': _stored(message.contentPlain),
          'content_preview': _stored(message.contentPreview),
          'content_truncated': message.contentTruncated,
          'usage': _usage(message.usage),
          'model': _stored(message.model),
          'has_tool_calls': message.hasToolCalls,
          'has_error': message.hasError,
        },
    ],
    'tool_calls': [
      for (final tool in session.toolCalls)
        {
          'message_index': tool.messageIndex,
          'tool_index': tool.toolIndex,
          'tool_name': _stored(tool.toolName),
          'status': _stored(tool.status),
          'started_at_utc': _time(tool.startedAtUtc),
          'finished_at_utc': _time(tool.finishedAtUtc),
          'input_preview': _stored(tool.inputPreview),
          'output_preview': _stored(tool.outputPreview),
          'output_truncated': tool.outputTruncated,
          'error_message': _stored(tool.errorMessage),
        },
    ],
    'usage_events': [
      for (final event in session.usageEvents)
        {
          'source_record_ordinal': event.sourceRecordOrdinal,
          'rollout_ordinal': event.rolloutOrdinal,
          'turn_ordinal': event.turnOrdinal,
          'counter_epoch': event.counterEpoch,
          'occurred_at_utc': _time(event.occurredAtUtc),
          'model': _stored(event.model),
          'working_directory': _stored(event.workingDirectory),
          'working_directory_unc': _stored(event.workingDirectoryUnc),
          'usage': _usage(event.usage),
          'derivation': event.derivation,
          'branch_scope': event.branchScope,
          'cumulative_usage': _usage(event.cumulativeUsage),
          'event_fingerprint': event.eventFingerprint,
          'provider': _stored(event.provider),
          'request_input_tokens': event.requestInputTokens,
          'model_context_window': event.modelContextWindow,
        },
    ],
    'warnings': [
      for (final warning in session.warnings)
        {
          'code': warning.code,
          'record_type': _stored(warning.recordType),
          'payload_type': _stored(warning.payloadType),
          'message': warning.message,
        },
    ],
  };
}
