import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import '../utils/injected_context_filter.dart';

enum CodexSessionSourceType { windows, wsl, unknown }

enum CodexMessageAuthorType {
  user,
  assistant,
  system,
  tool,
  reasoning,
  unknown,
}

typedef CodexJsonlByteStreamReader =
    Stream<List<int>> Function(File source, int endExclusive);

class CodexSessionParser {
  CodexSessionParser({
    this.maxToolOutputPreviewChars = 2000,
    this.maxMessageContentChars = 12000,
    this.maxLegacyJsonBytes = 8 * 1024 * 1024,
    this.jsonFormatProbeBytes = 64 * 1024,
    CodexJsonlByteStreamReader? jsonlByteStreamReader,
  }) : assert(maxLegacyJsonBytes > 0),
       assert(jsonFormatProbeBytes > 0),
       jsonlByteStreamReader =
           jsonlByteStreamReader ?? _defaultJsonlByteStreamReader;

  static const int currentVersion = 4;

  final int maxToolOutputPreviewChars;
  final int maxMessageContentChars;
  final int maxLegacyJsonBytes;
  final int jsonFormatProbeBytes;
  final CodexJsonlByteStreamReader jsonlByteStreamReader;

  Future<CodexParseResult> parseFile(File source) async {
    try {
      final snapshot = await source.stat();
      if (source.path.toLowerCase().endsWith('.jsonl')) {
        return await _parseJsonlSnapshot(source, snapshot);
      }
      final probeEnd = math.min(snapshot.size, jsonFormatProbeBytes);
      final probe = await _readUtf8Snapshot(
        source,
        probeEnd,
        allowMalformed: probeEnd < snapshot.size,
      );
      if (_looksLikeJsonl(probe)) {
        return await _parseJsonlSnapshot(source, snapshot);
      }
      if (snapshot.size > maxLegacyJsonBytes) {
        return CodexParseResult.failure(
          CodexParseError(
            sourcePath: source.path,
            kind: CodexParseErrorKind.unsupportedRoot,
            message:
                'Legacy JSON session exceeds the configured size limit of '
                '$maxLegacyJsonBytes bytes and was not recognized as JSONL.',
          ),
        );
      }
      final text = snapshot.size <= jsonFormatProbeBytes
          ? probe
          : await _readUtf8Snapshot(source, snapshot.size);
      final decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) {
        final afterParse = await source.stat();
        return CodexParseResult.success(
          _parseJsonObjectSession(source, decoded),
          sourceSnapshotSize: snapshot.size,
          sourceSnapshotModifiedUtc: snapshot.modified.toUtc(),
          sourceChangedDuringParse:
              afterParse.size != snapshot.size ||
              afterParse.modified.toUtc() != snapshot.modified.toUtc(),
        );
      }
      return CodexParseResult.failure(
        CodexParseError(
          sourcePath: source.path,
          kind: CodexParseErrorKind.unsupportedRoot,
          message: 'Session root must be a JSON object or JSONL records.',
        ),
      );
    } on _JsonlParseException catch (error) {
      return CodexParseResult.failure(error.error);
    } on FormatException catch (error) {
      return CodexParseResult.failure(
        CodexParseError.fromFormatException(source.path, error),
      );
    } on Object catch (error) {
      return CodexParseResult.failure(
        CodexParseError(
          sourcePath: source.path,
          kind: CodexParseErrorKind.io,
          message: error.toString(),
        ),
      );
    }
  }

  Future<String> _readUtf8Snapshot(
    File source,
    int endExclusive, {
    bool allowMalformed = false,
  }) async {
    var bytesRead = 0;
    final text = await source
        .openRead(0, endExclusive)
        .map((chunk) {
          bytesRead += chunk.length;
          return chunk;
        })
        .transform(Utf8Decoder(allowMalformed: allowMalformed))
        .join();
    if (bytesRead != endExclusive) {
      throw FileSystemException(
        'Session source changed while being parsed.',
        source.path,
      );
    }
    return text;
  }

  Future<CodexParseResult> _parseJsonlSnapshot(
    File source,
    FileStat snapshot,
  ) async {
    final session = await _parseJsonlSession(
      source,
      _decodeJsonl(source, snapshot.size),
    );
    final afterParse = await source.stat();
    return CodexParseResult.success(
      session,
      sourceSnapshotSize: snapshot.size,
      sourceSnapshotModifiedUtc: snapshot.modified.toUtc(),
      sourceChangedDuringParse:
          afterParse.size != snapshot.size ||
          afterParse.modified.toUtc() != snapshot.modified.toUtc(),
    );
  }

  CodexParsedSession _parseJsonObjectSession(
    File source,
    Map<String, Object?> json,
  ) {
    final sourcePath = _string(json['source_file_path']) ?? source.path;
    final sourceType = _sourceType(_string(json['source_type']), sourcePath);
    final displayPath = _string(json['display_path']) ?? sourcePath;
    final platformPath = _string(json['platform_path']) ?? displayPath;
    final workingDirectory = _string(json['working_directory']);
    final rawMessages = json['messages'] is List<Object?>
        ? json['messages'] as List<Object?>
        : const <Object?>[];
    final messages = <CodexParsedMessage>[];
    final toolCalls = <CodexParsedToolCall>[];
    final warnings = <CodexParseWarning>[];
    var usage = const CodexUsage.empty();
    final modelIds = <String>{};
    DateTime? lastMessageAtUtc;
    final topLevelModel = _string(json['model']);
    if (topLevelModel != null && topLevelModel.isNotEmpty) {
      modelIds.add(topLevelModel);
    }
    usage = usage + CodexUsage.fromJson(json['usage']);

    for (var index = 0; index < rawMessages.length; index++) {
      final rawMessage = rawMessages[index];
      final messageMap = rawMessage is Map
          ? rawMessage.cast<String, Object?>()
          : <String, Object?>{'content': rawMessage?.toString()};
      final rawType = _string(messageMap['type']);
      final authorType = _authorType(rawType);
      final messageUsage = CodexUsage.fromJson(messageMap['usage']);
      usage = usage + messageUsage;
      final model = _string(messageMap['model']);
      if (model != null && model.isNotEmpty) {
        modelIds.add(model);
      }
      final toolCall = _toolCallFromMessage(
        messageMap,
        index,
        toolCalls.length,
      );
      if (toolCall != null) {
        toolCalls.add(toolCall);
      }
      final createdAtUtc = _dateTime(messageMap['created_at']);
      lastMessageAtUtc = _maxDateTime(lastMessageAtUtc, createdAtUtc);
      final content = _content(messageMap);
      if (authorType == CodexMessageAuthorType.user &&
          isInjectedEnvironmentContextMessage(content)) {
        continue;
      }
      final storedContent = _truncate(content, maxMessageContentChars);
      messages.add(
        CodexParsedMessage(
          index: index,
          authorType: authorType,
          rawType: rawType,
          createdAtUtc: createdAtUtc,
          firstLine: _firstLine(content),
          contentPlain: storedContent.value,
          contentPreview: _truncate(content, 200).value,
          contentTruncated: storedContent.truncated,
          usage: messageUsage,
          model: model,
          hasToolCalls: toolCall != null,
          hasError: _string(messageMap['error']) != null,
        ),
      );
    }

    return CodexParsedSession(
      internalId: _internalId(
        sourcePath: sourcePath,
        sessionId: _string(json['session_id']),
      ),
      sessionId: _string(json['session_id']),
      threadName: _cleanThreadName(
        _string(json['thread_name']) ?? _string(json['session_name']),
      ),
      threadSource: _string(json['thread_source']),
      parentThreadId: _string(json['parent_thread_id']),
      agentNickname: _string(json['agent_nickname']),
      agentRole: _string(json['agent_role']),
      subagentDepth: _int(json['subagent_depth']),
      sourceType: sourceType,
      sourcePath: sourcePath,
      sourceFileUncPath: _string(json['source_file_unc_path']),
      displayPath: displayPath,
      platformPath: platformPath,
      workingDirectoryDisplay: workingDirectory,
      workingDirectoryPlatform: workingDirectory,
      workingDirectoryUnc: _string(json['working_directory_unc']),
      title: _cleanTitle(_string(json['title'])),
      summary: _cleanSummary(_string(json['summary'])),
      startedAtUtc: _dateTime(json['created_at']),
      lastMessageAtUtc: lastMessageAtUtc,
      modelIds: Set.unmodifiable(modelIds),
      messages: List.unmodifiable(messages),
      toolCalls: List.unmodifiable(toolCalls),
      warnings: List.unmodifiable(warnings),
      usage: usage,
      lastTurnUsage: const CodexUsage.empty(),
      usageProjectionStatus: _hasPositiveUsage(usage)
          ? 'ambiguous'
          : 'complete',
    );
  }

  Future<CodexParsedSession> _parseJsonlSession(
    File source,
    Stream<Map<String, Object?>> records,
  ) async {
    var sourcePath = source.path;
    String? sourceFileUncPath;
    String? displayPath;
    String? platformPath;
    String? workingDirectory;
    String? workingDirectoryUnc;
    String? title;
    String? summary;
    String? sessionId;
    String? threadName;
    String? threadSource;
    String? parentThreadId;
    String? forkedFromId;
    String? historyBaseThreadId;
    int? historyBaseEndOrdinalExclusive;
    int? historyBaseEndByteOffset;
    int? subagentHistoryStartOrdinal;
    String? agentNickname;
    String? agentRole;
    int? subagentDepth;
    DateTime? startedAtUtc;
    DateTime? lastMessageAtUtc;
    final messages = <CodexParsedMessage>[];
    final toolCalls = <CodexParsedToolCall>[];
    final warnings = <CodexParseWarning>[];
    final usageEvents = <CodexParsedUsageEvent>[];
    final modelIds = <String>{};
    final pendingToolCalls = <String, CodexParsedToolCall>{};
    var usage = const CodexUsage.empty();
    var hasAggregateUsage = false;
    var lastTurnUsage = const CodexUsage.empty();
    var previousCumulativeUsage = const CodexUsage.zero();
    var hasCumulativeUsage = false;
    var sourceRecordOrdinal = -1;
    int? turnOrdinal;
    var counterEpoch = 0;
    var pendingCounterReset = false;
    String? effectiveModel;
    String? effectiveWorkingDirectory;
    String? effectiveWorkingDirectoryUnc;
    var usageProjectionStatus = 'complete';

    await for (final record in records) {
      sourceRecordOrdinal++;
      final recordType = _string(record['type']);
      final timestamp = _dateTime(record['timestamp']);
      final payload = _map(record['payload']);
      if (recordType == 'session_meta') {
        final metadataSessionId = _string(payload['id']);
        if (metadataSessionId == null ||
            metadataSessionId.trim().isEmpty ||
            sessionId != null) {
          continue;
        }
        sessionId = metadataSessionId;
        threadName =
            _cleanThreadName(
              _string(payload['thread_name']) ??
                  _string(payload['session_name']) ??
                  _string(payload['name']) ??
                  _string(payload['title']),
            ) ??
            threadName;
        threadSource = _string(payload['thread_source']) ?? threadSource;
        parentThreadId = _string(payload['parent_thread_id']) ?? parentThreadId;
        forkedFromId = _string(payload['forked_from_id']);
        final historyBase = _map(payload['history_base']);
        historyBaseThreadId = _string(historyBase['thread_id']);
        historyBaseEndOrdinalExclusive = _int(
          historyBase['end_ordinal_exclusive'],
        );
        historyBaseEndByteOffset = _int(historyBase['end_byte_offset']);
        subagentHistoryStartOrdinal = _int(
          payload['subagent_history_start_ordinal'],
        );
        agentNickname = _string(payload['agent_nickname']) ?? agentNickname;
        agentRole = _string(payload['agent_role']) ?? agentRole;
        subagentDepth = _int(payload['subagent_depth']) ?? subagentDepth;
        final source = _map(payload['source']);
        final subagent = _map(source['subagent']);
        final threadSpawn = _map(subagent['thread_spawn']);
        if (subagent.isNotEmpty || threadSpawn.isNotEmpty) {
          threadSource = 'subagent';
          parentThreadId =
              _string(threadSpawn['parent_thread_id']) ?? parentThreadId;
          agentNickname =
              _string(threadSpawn['agent_nickname']) ?? agentNickname;
          agentRole = _string(threadSpawn['agent_role']) ?? agentRole;
          subagentDepth = _int(threadSpawn['depth']) ?? subagentDepth;
        }
        if (historyBaseThreadId == null &&
            subagentHistoryStartOrdinal == null &&
            (forkedFromId != null || parentThreadId != null)) {
          usageProjectionStatus = 'legacy_pending';
        }
        final ownerWorkingDirectory = _string(payload['cwd']);
        workingDirectory = ownerWorkingDirectory ?? workingDirectory;
        if (ownerWorkingDirectory != null) {
          workingDirectoryUnc = _string(payload['working_directory_unc']);
          effectiveWorkingDirectory = ownerWorkingDirectory;
          effectiveWorkingDirectoryUnc = workingDirectoryUnc;
        }
        title = _cleanTitle(_string(payload['title'])) ?? title;
        sourceFileUncPath = _string(payload['source_file_unc_path']);
        startedAtUtc =
            _dateTime(payload['timestamp']) ?? timestamp ?? startedAtUtc;
        continue;
      }
      if (recordType == 'turn_context') {
        if (_isInheritedProjectedRecord(
          record,
          historyBaseThreadId: historyBaseThreadId,
          subagentHistoryStartOrdinal: subagentHistoryStartOrdinal,
        )) {
          continue;
        }
        turnOrdinal = (turnOrdinal ?? -1) + 1;
        final contextWorkingDirectory = _string(payload['cwd']);
        final contextWorkingDirectoryUnc = _string(
          payload['working_directory_unc'],
        );
        if (contextWorkingDirectory != null) {
          workingDirectory = contextWorkingDirectory;
          workingDirectoryUnc = contextWorkingDirectoryUnc;
          effectiveWorkingDirectory = contextWorkingDirectory;
          effectiveWorkingDirectoryUnc = contextWorkingDirectoryUnc;
        } else if (contextWorkingDirectoryUnc != null) {
          workingDirectoryUnc = contextWorkingDirectoryUnc;
          effectiveWorkingDirectoryUnc = contextWorkingDirectoryUnc;
        }
        threadName =
            _cleanThreadName(
              _string(payload['thread_name']) ??
                  _string(payload['session_name']) ??
                  _string(payload['name']) ??
                  _string(payload['title']),
            ) ??
            threadName;
        title = _cleanTitle(_string(payload['title'])) ?? title;
        summary = _cleanSummary(_string(payload['summary'])) ?? summary;
        final model = _string(payload['model']);
        if (model != null && model.isNotEmpty) {
          effectiveModel = model;
          modelIds.add(model);
        }
        continue;
      }
      if (recordType == 'event_msg' &&
          payload['type'] == 'thread_settings_applied') {
        if (_isInheritedProjectedRecord(
          record,
          historyBaseThreadId: historyBaseThreadId,
          subagentHistoryStartOrdinal: subagentHistoryStartOrdinal,
        )) {
          continue;
        }
        final settings = _map(payload['thread_settings']);
        final model = _string(settings['model']);
        if (model != null && model.isNotEmpty) {
          effectiveModel = model;
          modelIds.add(model);
        }
        final settingsWorkingDirectory = _string(settings['cwd']);
        final settingsWorkingDirectoryUnc = _string(
          settings['working_directory_unc'],
        );
        if (settingsWorkingDirectory != null) {
          effectiveWorkingDirectory = settingsWorkingDirectory;
          effectiveWorkingDirectoryUnc = settingsWorkingDirectoryUnc;
        } else if (settingsWorkingDirectoryUnc != null) {
          effectiveWorkingDirectoryUnc = settingsWorkingDirectoryUnc;
        }
        continue;
      }
      if (recordType == 'event_msg' && payload['type'] == 'model_reroute') {
        if (_isInheritedProjectedRecord(
          record,
          historyBaseThreadId: historyBaseThreadId,
          subagentHistoryStartOrdinal: subagentHistoryStartOrdinal,
        )) {
          continue;
        }
        final model = _string(payload['to_model']);
        if (model != null && model.isNotEmpty) {
          effectiveModel = model;
          modelIds.add(model);
        }
        continue;
      }
      if (recordType == 'event_msg' && payload['type'] == 'token_count') {
        final info = _map(payload['info']);
        final totalTokenUsage = CodexUsage.fromJson(info['total_token_usage']);
        if (!totalTokenUsage.isEmpty) {
          usage = totalTokenUsage;
          hasAggregateUsage = true;
        }
        final lastTokenUsage = CodexUsage.fromJson(info['last_token_usage']);
        if (!lastTokenUsage.isEmpty) {
          lastTurnUsage = lastTokenUsage;
        }
        if (!totalTokenUsage.isEmpty && !totalTokenUsage.hasPositiveValue) {
          if (!hasCumulativeUsage) {
            previousCumulativeUsage = totalTokenUsage;
            hasCumulativeUsage = true;
          } else if (!totalTokenUsage.hasSameVector(previousCumulativeUsage)) {
            previousCumulativeUsage = totalTokenUsage;
            pendingCounterReset = true;
          }
        }
        if (!totalTokenUsage.isEmpty &&
            totalTokenUsage.hasPositiveValue &&
            (!hasCumulativeUsage ||
                !totalTokenUsage.hasSameVector(previousCumulativeUsage))) {
          final resetFromZero = pendingCounterReset;
          final counterReset =
              resetFromZero ||
              (hasCumulativeUsage &&
                  !totalTokenUsage.isComponentwiseAtLeast(
                    previousCumulativeUsage,
                  ));
          final delta = counterReset
              ? totalTokenUsage.nonNegative()
              : totalTokenUsage.differenceFrom(previousCumulativeUsage);
          final firstLegacyEvent =
              usageEvents.isEmpty && usageProjectionStatus == 'legacy_pending';
          final useLastTokenUsage =
              !lastTokenUsage.isEmpty &&
              lastTokenUsage.isNonNegative &&
              (counterReset
                  ? resetFromZero
                        ? lastTokenUsage.hasSameVector(delta)
                        : totalTokenUsage.isComponentwiseAtLeast(lastTokenUsage)
                  : firstLegacyEvent
                  ? totalTokenUsage.isComponentwiseAtLeast(lastTokenUsage)
                  : lastTokenUsage.hasSameVector(delta));
          if (counterReset) {
            counterEpoch++;
            pendingCounterReset = false;
          }
          final eventUsage = (useLastTokenUsage ? lastTokenUsage : delta)
              .withComponentTotal();
          final rolloutOrdinal = _int(record['rollout_ordinal']);
          final branchScope = historyBaseThreadId != null
              ? 'local'
              : switch (subagentHistoryStartOrdinal) {
                  int _ when rolloutOrdinal == null => 'ambiguous',
                  int boundary when rolloutOrdinal! < boundary => 'inherited',
                  _
                      when subagentHistoryStartOrdinal == null &&
                          (forkedFromId != null || parentThreadId != null) =>
                    'ambiguous',
                  _ => 'local',
                };
          if (branchScope == 'ambiguous' &&
              subagentHistoryStartOrdinal != null) {
            usageProjectionStatus = 'ambiguous';
          }
          usageEvents.add(
            CodexParsedUsageEvent(
              sourceRecordOrdinal: sourceRecordOrdinal,
              rolloutOrdinal: rolloutOrdinal,
              turnOrdinal: turnOrdinal,
              counterEpoch: counterEpoch,
              occurredAtUtc: timestamp,
              model: effectiveModel,
              workingDirectory: effectiveWorkingDirectory,
              workingDirectoryUnc: effectiveWorkingDirectoryUnc,
              usage: eventUsage,
              branchScope: branchScope,
              derivation: counterReset
                  ? 'counter_reset'
                  : useLastTokenUsage
                  ? 'last_token_usage'
                  : 'cumulative_delta',
              cumulativeUsage: totalTokenUsage,
              eventFingerprint: _usageEventFingerprint(
                timestamp: timestamp,
                cumulativeUsage: totalTokenUsage,
              ),
            ),
          );
          previousCumulativeUsage = totalTokenUsage;
          hasCumulativeUsage = true;
        }
        continue;
      }
      if (recordType != 'response_item' && recordType != 'event_msg') {
        if (recordType != 'compacted') {
          warnings.add(
            CodexParseWarning(
              code: 'unknown_record_type',
              recordType: recordType ?? 'unknown',
              payloadType: _string(payload['type']),
              message: 'Unknown JSONL record type.',
            ),
          );
        }
        continue;
      }

      final payloadType = _string(payload['type']);
      if (recordType == 'response_item' && payloadType == 'message') {
        final content = _contentFromResponsePayload(payload);
        final role = _string(payload['role']);
        final authorType = _authorType(role);
        if (authorType == CodexMessageAuthorType.user &&
            isInjectedEnvironmentContextMessage(content)) {
          continue;
        }
        final messageUsage = CodexUsage.fromJson(payload['usage']);
        if (!hasAggregateUsage) {
          usage = usage + messageUsage;
        }
        final model = _string(payload['model']);
        if (model != null && model.isNotEmpty) {
          modelIds.add(model);
        }
        final storedContent = _truncate(content, maxMessageContentChars);
        _addMessage(
          messages,
          CodexParsedMessage(
            index: messages.length,
            authorType: authorType,
            rawType: payloadType,
            createdAtUtc: timestamp,
            firstLine: _firstLine(content),
            contentPlain: storedContent.value,
            contentPreview: _truncate(content, 200).value,
            contentTruncated: storedContent.truncated,
            usage: messageUsage,
            model: model,
            hasToolCalls: false,
            hasError: false,
          ),
        );
        lastMessageAtUtc = _maxDateTime(lastMessageAtUtc, timestamp);
        continue;
      }
      if (recordType == 'event_msg' &&
          (payloadType == 'user_message' || payloadType == 'agent_message')) {
        final content = _string(payload['message']) ?? '';
        final authorType = payloadType == 'user_message'
            ? CodexMessageAuthorType.user
            : CodexMessageAuthorType.assistant;
        if (authorType == CodexMessageAuthorType.user &&
            isInjectedEnvironmentContextMessage(content)) {
          continue;
        }
        final storedContent = _truncate(content, maxMessageContentChars);
        _addMessage(
          messages,
          CodexParsedMessage(
            index: messages.length,
            authorType: authorType,
            rawType: payloadType,
            createdAtUtc: timestamp,
            firstLine: _firstLine(content),
            contentPlain: storedContent.value,
            contentPreview: _truncate(content, 200).value,
            contentTruncated: storedContent.truncated,
            usage: const CodexUsage.empty(),
            model: null,
            hasToolCalls: false,
            hasError: false,
          ),
        );
        lastMessageAtUtc = _maxDateTime(lastMessageAtUtc, timestamp);
        continue;
      }
      if (recordType == 'response_item' && _isToolCallPayload(payloadType)) {
        final callId = _string(payload['call_id']);
        final toolCall = CodexParsedToolCall(
          messageIndex: messages.length,
          toolIndex: toolCalls.length,
          toolName: _toolName(payload, payloadType),
          status: 'started',
          startedAtUtc: timestamp,
          finishedAtUtc: null,
          inputPreview: _truncate(_toolInput(payload), 200).value,
          outputPreview: '',
          outputTruncated: false,
          errorMessage: null,
        );
        toolCalls.add(toolCall);
        if (callId != null) {
          pendingToolCalls[callId] = toolCall;
        }
        continue;
      }
      if (recordType == 'response_item' && _isToolOutputPayload(payloadType)) {
        final callId = _string(payload['call_id']);
        final prior = callId == null ? null : pendingToolCalls[callId];
        final output = _string(payload['output']) ?? '';
        final preview = _truncate(output, maxToolOutputPreviewChars);
        final updated = CodexParsedToolCall(
          messageIndex: prior?.messageIndex ?? messages.length,
          toolIndex: prior?.toolIndex ?? toolCalls.length,
          toolName: prior?.toolName ?? 'unknown',
          status: _string(payload['status']) ?? 'finished',
          startedAtUtc: prior?.startedAtUtc,
          finishedAtUtc: timestamp,
          inputPreview: prior?.inputPreview ?? '',
          outputPreview: preview.value,
          outputTruncated: preview.truncated,
          errorMessage: _string(payload['error']),
        );
        if (prior == null) {
          toolCalls.add(updated);
        } else {
          toolCalls[prior.toolIndex] = updated;
        }
        continue;
      }

      if (recordType == 'response_item' && payloadType == 'reasoning') {
        final content = _reasoningContent(payload);
        final storedContent = _truncate(content, maxMessageContentChars);
        _addMessage(
          messages,
          CodexParsedMessage(
            index: messages.length,
            authorType: CodexMessageAuthorType.reasoning,
            rawType: payloadType,
            createdAtUtc: timestamp,
            firstLine: _firstLine(content),
            contentPlain: storedContent.value,
            contentPreview: _truncate(content, 200).value,
            contentTruncated: storedContent.truncated,
            usage: const CodexUsage.empty(),
            model: null,
            hasToolCalls: false,
            hasError: false,
          ),
        );
        lastMessageAtUtc = _maxDateTime(lastMessageAtUtc, timestamp);
        continue;
      }

      if (recordType == 'response_item' &&
          !_knownPassiveResponsePayloadTypes.contains(payloadType)) {
        warnings.add(
          CodexParseWarning(
            code: 'unknown_response_item_type',
            recordType: recordType ?? 'unknown',
            payloadType: payloadType,
            message: 'Unknown response item payload type.',
          ),
        );
      } else if (recordType == 'response_item') {
        continue;
      } else if (recordType == 'event_msg' &&
          !_knownEventPayloadTypes.contains(payloadType)) {
        warnings.add(
          CodexParseWarning(
            code: 'unknown_event_message_type',
            recordType: recordType ?? 'unknown',
            payloadType: payloadType,
            message: 'Unknown event message payload type.',
          ),
        );
      }

      final content = jsonEncode(payload);
      final storedContent = _truncate(content, maxMessageContentChars);
      _addMessage(
        messages,
        CodexParsedMessage(
          index: messages.length,
          authorType: CodexMessageAuthorType.unknown,
          rawType: payloadType ?? recordType,
          createdAtUtc: timestamp,
          firstLine: _firstLine(content),
          contentPlain: storedContent.value,
          contentPreview: _truncate(content, 200).value,
          contentTruncated: storedContent.truncated,
          usage: const CodexUsage.empty(),
          model: null,
          hasToolCalls: false,
          hasError: false,
        ),
      );
      lastMessageAtUtc = _maxDateTime(lastMessageAtUtc, timestamp);
    }

    displayPath ??= sourcePath;
    platformPath ??= displayPath;
    if (usageEvents.isEmpty) {
      usageProjectionStatus = _hasPositiveUsage(usage)
          ? 'ambiguous'
          : 'complete';
    }
    return CodexParsedSession(
      internalId: _internalId(sourcePath: sourcePath, sessionId: sessionId),
      sessionId: sessionId,
      threadName: threadName,
      threadSource: threadSource,
      parentThreadId: parentThreadId,
      forkedFromId: forkedFromId,
      historyBaseThreadId: historyBaseThreadId,
      historyBaseEndOrdinalExclusive: historyBaseEndOrdinalExclusive,
      historyBaseEndByteOffset: historyBaseEndByteOffset,
      subagentHistoryStartOrdinal: subagentHistoryStartOrdinal,
      usageEvents: List.unmodifiable(usageEvents),
      usageProjectionStatus: usageProjectionStatus,
      agentNickname: agentNickname,
      agentRole: agentRole,
      subagentDepth: subagentDepth,
      sourceType: _sourceType(null, sourcePath),
      sourcePath: sourcePath,
      sourceFileUncPath: sourceFileUncPath,
      displayPath: displayPath,
      platformPath: platformPath,
      workingDirectoryDisplay: workingDirectory,
      workingDirectoryPlatform: workingDirectory,
      workingDirectoryUnc: workingDirectoryUnc,
      title: _cleanTitle(title),
      summary: _cleanSummary(summary),
      startedAtUtc: startedAtUtc,
      lastMessageAtUtc: lastMessageAtUtc,
      modelIds: Set.unmodifiable(modelIds),
      messages: List.unmodifiable(messages),
      toolCalls: List.unmodifiable(toolCalls),
      warnings: List.unmodifiable(warnings),
      usage: usage,
      lastTurnUsage: lastTurnUsage,
    );
  }

  CodexParsedToolCall? _toolCallFromMessage(
    Map<String, Object?> message,
    int messageIndex,
    int toolIndex,
  ) {
    if (_string(message['type']) != 'tool_call') {
      return null;
    }
    final output = _string(message['output']) ?? '';
    final outputPreview = _truncate(output, maxToolOutputPreviewChars);
    return CodexParsedToolCall(
      messageIndex: messageIndex,
      toolIndex: toolIndex,
      toolName: _string(message['tool_name']) ?? 'unknown',
      status: _string(message['status']) ?? 'unknown',
      startedAtUtc: _dateTime(message['started_at']),
      finishedAtUtc: _dateTime(message['finished_at']),
      inputPreview: _truncate(_string(message['input']) ?? '', 200).value,
      outputPreview: outputPreview.value,
      outputTruncated: outputPreview.truncated,
      errorMessage: _string(message['error']),
    );
  }

  bool _looksLikeJsonl(String text) {
    final trimmed = text.trimLeft();
    final firstLineEnd = trimmed.indexOf('\n');
    if (firstLineEnd < 0) {
      return false;
    }
    final following = trimmed.substring(firstLineEnd + 1).trimLeft();
    if (!following.startsWith('{')) {
      return false;
    }
    try {
      return jsonDecode(trimmed.substring(0, firstLineEnd).trimRight())
          is Map<String, Object?>;
    } on FormatException {
      return false;
    }
  }

  String _internalId({required String sourcePath, required String? sessionId}) {
    final stableSessionId = sessionId?.trim();
    if (stableSessionId != null && stableSessionId.isNotEmpty) {
      return 'session:$stableSessionId';
    }
    return 'source:$sourcePath';
  }

  Stream<Map<String, Object?>> _decodeJsonl(
    File source,
    int endExclusive,
  ) async* {
    var offset = 0;
    var lineNumber = 0;
    var bytesRead = 0;
    final byteStream = jsonlByteStreamReader(source, endExclusive).map((chunk) {
      bytesRead += chunk.length;
      return chunk;
    });
    final lines = byteStream
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      lineNumber++;
      final normalizedLine = _stripLeadingNulPadding(line);
      final leadingPadding = line.length - normalizedLine.length;
      if (normalizedLine.trim().isEmpty) {
        offset += line.length + 1;
        continue;
      }
      try {
        final decoded = jsonDecode(normalizedLine);
        if (decoded is! Map<String, Object?>) {
          throw _JsonlParseException(
            CodexParseError(
              sourcePath: source.path,
              kind: CodexParseErrorKind.unsupportedRoot,
              message: 'JSONL record must be a JSON object.',
              offset: offset,
              line: lineNumber,
              column: 1,
            ),
          );
        }
        yield decoded;
      } on FormatException catch (error) {
        final column = error.offset == null
            ? null
            : leadingPadding + error.offset! + 1;
        throw _JsonlParseException(
          CodexParseError(
            sourcePath: source.path,
            kind: CodexParseErrorKind.malformedJson,
            message: error.message,
            offset: offset + leadingPadding + (error.offset ?? 0),
            line: lineNumber,
            column: column,
          ),
        );
      }
      offset += line.length + 1;
    }
    if (bytesRead != endExclusive) {
      throw _JsonlParseException(
        CodexParseError(
          sourcePath: source.path,
          kind: CodexParseErrorKind.io,
          message: 'Session file changed while being parsed.',
        ),
      );
    }
  }

  String _stripLeadingNulPadding(String line) {
    var firstJsonChar = 0;
    while (firstJsonChar < line.length && line.codeUnitAt(firstJsonChar) == 0) {
      firstJsonChar++;
    }
    return firstJsonChar == 0 ? line : line.substring(firstJsonChar);
  }
}

void _addMessage(
  List<CodexParsedMessage> messages,
  CodexParsedMessage message,
) {
  if (messages.isNotEmpty && _isDuplicateMessage(messages.last, message)) {
    if (_isEchoRecord(messages.last) && !_isEchoRecord(message)) {
      messages[messages.length - 1] = message.withIndex(messages.last.index);
    }
    return;
  }
  messages.add(message);
}

bool _isDuplicateMessage(CodexParsedMessage left, CodexParsedMessage right) {
  return left.authorType == right.authorType &&
      _normalizedMessageContent(left.contentPlain) ==
          _normalizedMessageContent(right.contentPlain);
}

bool _isEchoRecord(CodexParsedMessage message) {
  return message.rawType == 'user_message' ||
      message.rawType == 'agent_message';
}

String _normalizedMessageContent(String value) {
  return value.trim().replaceAll(RegExp(r'\s+'), ' ');
}

String _reasoningContent(Map<String, Object?> payload) {
  final encrypted = _string(payload['encrypted_content']);
  if (encrypted != null && encrypted.trim().isNotEmpty) {
    return 'Reasoning content is encrypted and cannot be displayed.';
  }
  final summary = _reasoningSummary(payload['summary']).trim();
  return summary.isEmpty ? 'Reasoning content is unavailable.' : summary;
}

String _reasoningSummary(Object? value) {
  if (value is String) {
    return value;
  }
  if (value is Iterable) {
    return value
        .map(_reasoningSummary)
        .where((part) => part.trim().isNotEmpty)
        .join('\n');
  }
  if (value is Map) {
    final map = value.cast<String, Object?>();
    return _string(map['text']) ??
        _string(map['summary']) ??
        _string(map['content']) ??
        '';
  }
  return '';
}

class CodexParseResult {
  const CodexParseResult._({
    this.session,
    this.error,
    this.sourceSnapshotSize,
    this.sourceSnapshotModifiedUtc,
    this.sourceChangedDuringParse = false,
  });

  factory CodexParseResult.success(
    CodexParsedSession session, {
    int? sourceSnapshotSize,
    DateTime? sourceSnapshotModifiedUtc,
    bool sourceChangedDuringParse = false,
  }) => CodexParseResult._(
    session: session,
    sourceSnapshotSize: sourceSnapshotSize,
    sourceSnapshotModifiedUtc: sourceSnapshotModifiedUtc,
    sourceChangedDuringParse: sourceChangedDuringParse,
  );

  factory CodexParseResult.failure(CodexParseError error) =>
      CodexParseResult._(error: error);

  final CodexParsedSession? session;
  final CodexParseError? error;
  final int? sourceSnapshotSize;
  final DateTime? sourceSnapshotModifiedUtc;
  final bool sourceChangedDuringParse;

  bool get isSuccess => session != null;
}

class CodexParseError {
  const CodexParseError({
    required this.sourcePath,
    required this.kind,
    required this.message,
    this.offset,
    this.line,
    this.column,
    this.details,
  });

  factory CodexParseError.fromFormatException(
    String sourcePath,
    FormatException error,
  ) {
    return CodexParseError(
      sourcePath: sourcePath,
      kind: CodexParseErrorKind.malformedJson,
      message: error.message,
      offset: error.offset,
      line: error.offset == null ? null : 1,
      column: error.offset == null ? null : error.offset! + 1,
    );
  }

  final String sourcePath;
  final CodexParseErrorKind kind;
  final String message;
  final int? offset;
  final int? line;
  final int? column;
  final String? details;
}

enum CodexParseErrorKind { malformedJson, unsupportedRoot, io }

class CodexParsedSession {
  const CodexParsedSession({
    required this.internalId,
    required this.sessionId,
    required this.sourceType,
    required this.sourcePath,
    required this.sourceFileUncPath,
    required this.displayPath,
    required this.platformPath,
    required this.workingDirectoryDisplay,
    required this.workingDirectoryPlatform,
    required this.workingDirectoryUnc,
    required this.title,
    required this.summary,
    required this.startedAtUtc,
    required this.lastMessageAtUtc,
    required this.modelIds,
    required this.messages,
    required this.toolCalls,
    required this.warnings,
    required this.usage,
    required this.lastTurnUsage,
    this.threadSource,
    this.threadName,
    this.parentThreadId,
    this.forkedFromId,
    this.historyBaseThreadId,
    this.historyBaseEndOrdinalExclusive,
    this.historyBaseEndByteOffset,
    this.subagentHistoryStartOrdinal,
    this.usageEvents = const [],
    this.usageProjectionStatus = 'complete',
    this.agentNickname,
    this.agentRole,
    this.subagentDepth,
  });

  final String internalId;
  final String? sessionId;
  final String? threadName;
  final String? threadSource;
  final String? parentThreadId;
  final String? forkedFromId;
  final String? historyBaseThreadId;
  final int? historyBaseEndOrdinalExclusive;
  final int? historyBaseEndByteOffset;
  final int? subagentHistoryStartOrdinal;
  final List<CodexParsedUsageEvent> usageEvents;
  final String usageProjectionStatus;
  final String? agentNickname;
  final String? agentRole;
  final int? subagentDepth;
  final CodexSessionSourceType sourceType;
  final String sourcePath;
  final String? sourceFileUncPath;
  final String displayPath;
  final String platformPath;
  final String? workingDirectoryDisplay;
  final String? workingDirectoryPlatform;
  final String? workingDirectoryUnc;
  final String? title;
  final String? summary;
  final DateTime? startedAtUtc;
  final DateTime? lastMessageAtUtc;
  final Set<String> modelIds;
  final List<CodexParsedMessage> messages;
  final List<CodexParsedToolCall> toolCalls;
  final List<CodexParseWarning> warnings;
  final CodexUsage usage;
  final CodexUsage lastTurnUsage;
}

class CodexParsedUsageEvent {
  const CodexParsedUsageEvent({
    required this.sourceRecordOrdinal,
    required this.usage,
    required this.derivation,
    this.rolloutOrdinal,
    this.turnOrdinal,
    this.counterEpoch = 0,
    this.occurredAtUtc,
    this.model,
    this.workingDirectory,
    this.workingDirectoryUnc,
    this.branchScope = 'local',
    this.cumulativeUsage = const CodexUsage.empty(),
    this.eventFingerprint = '',
  });

  final int sourceRecordOrdinal;
  final int? rolloutOrdinal;
  final int? turnOrdinal;
  final int counterEpoch;
  final DateTime? occurredAtUtc;
  final String? model;
  final String? workingDirectory;
  final String? workingDirectoryUnc;
  final CodexUsage usage;
  final String derivation;
  final String branchScope;
  final CodexUsage cumulativeUsage;
  final String eventFingerprint;
}

class CodexParseWarning {
  const CodexParseWarning({
    required this.code,
    required this.recordType,
    required this.message,
    this.payloadType,
  });

  final String code;
  final String recordType;
  final String? payloadType;
  final String message;
}

class CodexParsedMessage {
  const CodexParsedMessage({
    required this.index,
    required this.authorType,
    required this.rawType,
    required this.createdAtUtc,
    required this.firstLine,
    required this.contentPlain,
    required this.contentPreview,
    required this.contentTruncated,
    required this.usage,
    required this.model,
    required this.hasToolCalls,
    required this.hasError,
  });

  final int index;
  final CodexMessageAuthorType authorType;
  final String? rawType;
  final DateTime? createdAtUtc;
  final String firstLine;
  final String contentPlain;
  final String contentPreview;
  final bool contentTruncated;
  final CodexUsage usage;
  final String? model;
  final bool hasToolCalls;
  final bool hasError;

  CodexParsedMessage withIndex(int index) {
    return CodexParsedMessage(
      index: index,
      authorType: authorType,
      rawType: rawType,
      createdAtUtc: createdAtUtc,
      firstLine: firstLine,
      contentPlain: contentPlain,
      contentPreview: contentPreview,
      contentTruncated: contentTruncated,
      usage: usage,
      model: model,
      hasToolCalls: hasToolCalls,
      hasError: hasError,
    );
  }
}

class CodexParsedToolCall {
  const CodexParsedToolCall({
    required this.messageIndex,
    required this.toolIndex,
    required this.toolName,
    required this.status,
    required this.startedAtUtc,
    required this.finishedAtUtc,
    required this.inputPreview,
    required this.outputPreview,
    required this.outputTruncated,
    required this.errorMessage,
  });

  final int messageIndex;
  final int toolIndex;
  final String toolName;
  final String status;
  final DateTime? startedAtUtc;
  final DateTime? finishedAtUtc;
  final String inputPreview;
  final String outputPreview;
  final bool outputTruncated;
  final String? errorMessage;

  bool get hasError => errorMessage != null || status == 'error';
}

class CodexUsage {
  const CodexUsage({
    this.inputTokens,
    this.outputTokens,
    this.cachedInputTokens,
    this.cacheWriteInputTokens,
    this.reasoningOutputTokens,
    int? totalTokens,
  }) : _explicitTotalTokens = totalTokens;

  const CodexUsage.empty()
    : inputTokens = null,
      outputTokens = null,
      cachedInputTokens = null,
      cacheWriteInputTokens = null,
      reasoningOutputTokens = null,
      _explicitTotalTokens = null;

  const CodexUsage.zero()
    : inputTokens = 0,
      outputTokens = 0,
      cachedInputTokens = 0,
      cacheWriteInputTokens = 0,
      reasoningOutputTokens = 0,
      _explicitTotalTokens = 0;

  factory CodexUsage.fromJson(Object? json) {
    if (json is! Map) {
      return const CodexUsage.empty();
    }
    final map = json.cast<String, Object?>();
    return CodexUsage(
      inputTokens: _int(map['input_tokens']),
      outputTokens: _int(map['output_tokens']),
      cachedInputTokens: _int(map['cached_input_tokens']),
      cacheWriteInputTokens: _int(map['cache_write_input_tokens']),
      reasoningOutputTokens: _int(map['reasoning_output_tokens']),
      totalTokens: _int(map['total_tokens']),
    );
  }

  final int? inputTokens;
  final int? outputTokens;
  final int? cachedInputTokens;
  final int? cacheWriteInputTokens;
  final int? reasoningOutputTokens;
  final int? _explicitTotalTokens;

  bool get isEmpty =>
      inputTokens == null &&
      outputTokens == null &&
      cachedInputTokens == null &&
      cacheWriteInputTokens == null &&
      reasoningOutputTokens == null &&
      _explicitTotalTokens == null;

  int? get totalTokens {
    if (_explicitTotalTokens != null) {
      return _explicitTotalTokens;
    }
    if (inputTokens == null &&
        outputTokens == null &&
        cachedInputTokens == null &&
        cacheWriteInputTokens == null &&
        reasoningOutputTokens == null) {
      return null;
    }
    return _componentTotalTokens;
  }

  int get _componentTotalTokens => (inputTokens ?? 0) + (outputTokens ?? 0);

  List<int> get _vector => [
    inputTokens ?? 0,
    cachedInputTokens ?? 0,
    cacheWriteInputTokens ?? 0,
    outputTokens ?? 0,
    reasoningOutputTokens ?? 0,
    _componentTotalTokens,
  ];

  bool hasSameVector(CodexUsage other) {
    final left = _vector;
    final right = other._vector;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) {
        return false;
      }
    }
    return true;
  }

  bool isComponentwiseAtLeast(CodexUsage other) {
    final current = _vector;
    final minimum = other._vector;
    for (var index = 0; index < current.length; index++) {
      if (current[index] < minimum[index]) {
        return false;
      }
    }
    return true;
  }

  bool get isNonNegative => _vector.every((value) => value >= 0);

  bool get hasPositiveValue => _vector.any((value) => value > 0);

  CodexUsage nonNegative() => CodexUsage(
    inputTokens: math.max(inputTokens ?? 0, 0),
    cachedInputTokens: math.max(cachedInputTokens ?? 0, 0),
    cacheWriteInputTokens: math.max(cacheWriteInputTokens ?? 0, 0),
    outputTokens: math.max(outputTokens ?? 0, 0),
    reasoningOutputTokens: math.max(reasoningOutputTokens ?? 0, 0),
    totalTokens: math.max(totalTokens ?? 0, 0),
  );

  CodexUsage withComponentTotal() => CodexUsage(
    inputTokens: inputTokens,
    cachedInputTokens: cachedInputTokens,
    cacheWriteInputTokens: cacheWriteInputTokens,
    outputTokens: outputTokens,
    reasoningOutputTokens: reasoningOutputTokens,
    totalTokens: _componentTotalTokens,
  );

  CodexUsage differenceFrom(CodexUsage previous) {
    final current = _vector;
    final before = previous._vector;
    return CodexUsage(
      inputTokens: current[0] - before[0],
      cachedInputTokens: current[1] - before[1],
      cacheWriteInputTokens: current[2] - before[2],
      outputTokens: current[3] - before[3],
      reasoningOutputTokens: current[4] - before[4],
      totalTokens: current[5] - before[5],
    );
  }

  CodexUsage operator +(CodexUsage other) => CodexUsage(
    inputTokens: _sumNullable(inputTokens, other.inputTokens),
    outputTokens: _sumNullable(outputTokens, other.outputTokens),
    cachedInputTokens: _sumNullable(cachedInputTokens, other.cachedInputTokens),
    cacheWriteInputTokens: _sumNullable(
      cacheWriteInputTokens,
      other.cacheWriteInputTokens,
    ),
    reasoningOutputTokens: _sumNullable(
      reasoningOutputTokens,
      other.reasoningOutputTokens,
    ),
    totalTokens: _sumNullable(totalTokens, other.totalTokens),
  );
}

String _usageEventFingerprint({
  required DateTime? timestamp,
  required CodexUsage cumulativeUsage,
}) {
  final safeProjection = jsonEncode([
    timestamp?.toUtc().toIso8601String(),
    ...cumulativeUsage._vector,
  ]);
  return sha256.convert(utf8.encode(safeProjection)).toString();
}

bool _isInheritedProjectedRecord(
  Map<String, Object?> record, {
  required String? historyBaseThreadId,
  required int? subagentHistoryStartOrdinal,
}) {
  if (historyBaseThreadId != null || subagentHistoryStartOrdinal == null) {
    return false;
  }
  final rolloutOrdinal = _int(record['rollout_ordinal']);
  return rolloutOrdinal == null || rolloutOrdinal < subagentHistoryStartOrdinal;
}

CodexSessionSourceType _sourceType(String? value, [String? path]) {
  return switch (value) {
    'windows' => CodexSessionSourceType.windows,
    'wsl' => CodexSessionSourceType.wsl,
    _ when path != null && path.startsWith(r'\\wsl') =>
      CodexSessionSourceType.wsl,
    _ when path != null && path.contains('/home/') =>
      CodexSessionSourceType.wsl,
    _ when path != null && RegExp(r'^[A-Za-z]:\\').hasMatch(path) =>
      CodexSessionSourceType.windows,
    _ => CodexSessionSourceType.windows,
  };
}

CodexMessageAuthorType _authorType(String? value) {
  return switch (value) {
    'user' => CodexMessageAuthorType.user,
    'assistant' => CodexMessageAuthorType.assistant,
    'system' => CodexMessageAuthorType.system,
    'tool' || 'tool_call' => CodexMessageAuthorType.tool,
    _ => CodexMessageAuthorType.unknown,
  };
}

String _content(Map<String, Object?> message) {
  final content = message['content'];
  if (content is String) {
    return content;
  }
  if (content != null) {
    return jsonEncode(content);
  }
  if (_string(message['type']) == 'tool_call') {
    return _string(message['output']) ?? '';
  }
  return jsonEncode(message);
}

String _contentFromResponsePayload(Map<String, Object?> payload) {
  final content = payload['content'];
  if (content is String) {
    return content;
  }
  if (content is List) {
    return content
        .map(_contentPartText)
        .where((part) => part.isNotEmpty)
        .join('\n');
  }
  if (content != null) {
    return jsonEncode(content);
  }
  return '';
}

String _contentPartText(Object? part) {
  if (part is String) {
    return part;
  }
  if (part is Map) {
    final map = part.cast<String, Object?>();
    return _string(map['text']) ??
        _string(map['message']) ??
        _string(map['content']) ??
        '';
  }
  return '';
}

bool _isToolCallPayload(String? payloadType) {
  return payloadType == 'function_call' ||
      payloadType == 'custom_tool_call' ||
      payloadType == 'tool_search_call' ||
      payloadType == 'web_search_call';
}

bool _isToolOutputPayload(String? payloadType) {
  return payloadType == 'function_call_output' ||
      payloadType == 'custom_tool_call_output' ||
      payloadType == 'tool_search_output';
}

String _toolName(Map<String, Object?> payload, String? payloadType) {
  final name = _string(payload['name']);
  if (name != null && name.isNotEmpty) {
    return name;
  }
  return switch (payloadType) {
    'tool_search_call' => 'tool_search',
    'web_search_call' => 'web_search',
    _ => 'unknown',
  };
}

String _toolInput(Map<String, Object?> payload) {
  return _string(payload['arguments']) ??
      _string(payload['input']) ??
      _string(payload['query']) ??
      '';
}

const _knownPassiveResponsePayloadTypes = {'ghost_snapshot', 'reasoning'};

const _knownEventPayloadTypes = {
  'agent_message',
  'agent_reasoning',
  'collab_agent_interaction_end',
  'collab_agent_spawn_end',
  'collab_close_end',
  'collab_resume_end',
  'collab_waiting_end',
  'context_compacted',
  'error',
  'exec_command_end',
  'mcp_tool_call_end',
  'model_reroute',
  'patch_apply_end',
  'task_complete',
  'task_started',
  'thread_goal_updated',
  'thread_settings_applied',
  'token_count',
  'turn_aborted',
  'user_message',
  'view_image_tool_call',
  'web_search_end',
};

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : <String, Object?>{};

String? _string(Object? value) => value is String ? value : null;

bool _hasPositiveUsage(CodexUsage usage) =>
    (usage.inputTokens ?? 0) > 0 ||
    (usage.cachedInputTokens ?? 0) > 0 ||
    (usage.cacheWriteInputTokens ?? 0) > 0 ||
    (usage.outputTokens ?? 0) > 0 ||
    (usage.reasoningOutputTokens ?? 0) > 0 ||
    (usage.totalTokens ?? 0) > 0;

String? _cleanTitle(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  if (trimmed.toLowerCase().startsWith('# agents.md')) {
    return null;
  }
  return trimmed;
}

String? _cleanSummary(String? value) {
  final trimmed = value?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  if (trimmed.toLowerCase() == 'auto') {
    return null;
  }
  return trimmed;
}

String? _cleanThreadName(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

int? _int(Object? value) => value is int ? value : null;

DateTime? _dateTime(Object? value) {
  if (value is! String) {
    return null;
  }
  return DateTime.tryParse(value)?.toUtc();
}

DateTime? _maxDateTime(DateTime? left, DateTime? right) {
  if (left == null) {
    return right;
  }
  if (right == null) {
    return left;
  }
  return left.isAfter(right) ? left : right;
}

int? _sumNullable(int? left, int? right) {
  if (left == null && right == null) {
    return null;
  }
  return (left ?? 0) + (right ?? 0);
}

String _firstLine(String value) {
  final newline = value.indexOf('\n');
  final line = (newline < 0 ? value : value.substring(0, newline)).trim();
  return _truncate(line, 240).value;
}

_TruncatedText _truncate(String value, int maxChars) {
  if (value.length <= maxChars) {
    return _TruncatedText(value: value, truncated: false);
  }
  return _TruncatedText(value: value.substring(0, maxChars), truncated: true);
}

class _TruncatedText {
  const _TruncatedText({required this.value, required this.truncated});

  final String value;
  final bool truncated;
}

class _JsonlParseException implements Exception {
  const _JsonlParseException(this.error);

  final CodexParseError error;
}

Stream<List<int>> _defaultJsonlByteStreamReader(
  File source,
  int endExclusive,
) => source.openRead(0, endExclusive);
