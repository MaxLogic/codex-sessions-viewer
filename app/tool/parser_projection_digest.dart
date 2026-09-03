import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/parser/codex_session_parser.dart';
import 'package:crypto/crypto.dart';

Future<void> main() async {
  final separator = Platform.isWindows ? ';' : ':';
  final files = (Platform.environment['CSV_PARSER_FILES'] ?? '')
      .split(separator)
      .map((path) => path.trim())
      .where((path) => path.isNotEmpty)
      .map(File.new)
      .toList();
  if (files.isEmpty) {
    stderr.writeln('CSV_PARSER_FILES must contain at least one file.');
    exitCode = 64;
    return;
  }
  final entries = <({int bytes, String digest})>[];
  final failures = <String, int>{};
  final parser = CodexSessionParser();
  var totalBytes = 0;
  var largestBytes = 0;
  for (final file in files) {
    final bytes = await file.length();
    totalBytes += bytes;
    if (bytes > largestBytes) {
      largestBytes = bytes;
    }
    final result = await parser.parseFile(file);
    if (!result.isSuccess) {
      final kind = result.error?.kind.name ?? 'unknown';
      failures[kind] = (failures[kind] ?? 0) + 1;
      continue;
    }
    final projection = jsonEncode(_projection(result.session!));
    entries.add((bytes: bytes, digest: _sha256(projection)));
  }
  final aggregateInput = [
    for (var index = 0; index < entries.length; index++)
      '$index:${entries[index].bytes}:${entries[index].digest}',
  ].join('\n');
  stdout.writeln(
    jsonEncode({
      'projection_version': 3,
      'parser_version': CodexSessionParser.currentVersion,
      'requested_files': files.length,
      'parsed_files': entries.length,
      'failed_files': failures.values.fold<int>(0, (sum, count) => sum + count),
      'failure_kinds': failures,
      'total_bytes': totalBytes,
      'largest_bytes': largestBytes,
      'aggregate_sha256': _sha256(aggregateInput),
    }),
  );
  if (failures.isNotEmpty) {
    exitCode = 1;
  }
}

String _sha256(String value) => sha256.convert(utf8.encode(value)).toString();

Map<String, Object?> _projection(CodexParsedSession session) => {
  'internal_id': session.internalId,
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
  'source_type': session.sourceType.name,
  'source_path': session.sourcePath,
  'source_file_unc_path': session.sourceFileUncPath,
  'display_path': session.displayPath,
  'platform_path': session.platformPath,
  'working_directory_display': session.workingDirectoryDisplay,
  'working_directory_platform': session.workingDirectoryPlatform,
  'working_directory_unc': session.workingDirectoryUnc,
  'title': session.title,
  'summary': session.summary,
  'started_at_utc': session.startedAtUtc?.toIso8601String(),
  'last_message_at_utc': session.lastMessageAtUtc?.toIso8601String(),
  'models': session.modelIds.toList()..sort(),
  'usage': _usage(session.usage),
  'last_turn_usage': _usage(session.lastTurnUsage),
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
        'usage': _usage(event.usage),
        'cumulative_usage': _usage(event.cumulativeUsage),
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
        'content_plain': message.contentPlain,
        'content_preview': message.contentPreview,
        'content_truncated': message.contentTruncated,
        'usage': _usage(message.usage),
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
        'input_preview': tool.inputPreview,
        'output_preview': tool.outputPreview,
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
        'message': warning.message,
      },
  ],
};

Map<String, Object?> _usage(CodexUsage usage) => {
  'input_tokens': usage.inputTokens,
  'output_tokens': usage.outputTokens,
  'cached_input_tokens': usage.cachedInputTokens,
  'cache_write_input_tokens': usage.cacheWriteInputTokens,
  'reasoning_output_tokens': usage.reasoningOutputTokens,
  'total_tokens': usage.totalTokens,
};
