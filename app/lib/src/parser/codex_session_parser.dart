import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

enum CodexSessionSourceType { windows, wsl, unknown }

enum CodexMessageAuthorType { user, assistant, system, tool, unknown }

class CodexSessionParser {
  CodexSessionParser({
    this.maxToolOutputPreviewChars = 2000,
    this.maxMessageContentChars = 12000,
  });

  static const int currentVersion = 1;

  final int maxToolOutputPreviewChars;
  final int maxMessageContentChars;

  Future<CodexParseResult> parseFile(File source) async {
    try {
      final text = await source.readAsString();
      if (_looksLikeJsonl(source, text)) {
        final jsonl = _decodeJsonl(source, text);
        if (jsonl.error != null) {
          return CodexParseResult.failure(jsonl.error!);
        }
        return CodexParseResult.success(
          _parseJsonlSession(source, jsonl.records, text),
        );
      }
      final decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) {
        return CodexParseResult.success(
          _parseJsonObjectSession(source, decoded, text),
        );
      }
      return CodexParseResult.failure(
        CodexParseError(
          sourcePath: source.path,
          kind: CodexParseErrorKind.unsupportedRoot,
          message: 'Session root must be a JSON object or JSONL records.',
        ),
      );
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

  CodexParsedSession _parseJsonObjectSession(
    File source,
    Map<String, Object?> json,
    String rawText,
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
      internalId: sha256
          .convert(utf8.encode('$sourcePath\n$rawText'))
          .toString(),
      sessionId: _string(json['session_id']),
      sourceType: sourceType,
      sourcePath: sourcePath,
      sourceFileUncPath: _string(json['source_file_unc_path']),
      displayPath: displayPath,
      platformPath: platformPath,
      workingDirectoryDisplay: workingDirectory,
      workingDirectoryPlatform: workingDirectory,
      workingDirectoryUnc: _string(json['working_directory_unc']),
      title: _string(json['title']),
      summary: _string(json['summary']),
      startedAtUtc: _dateTime(json['created_at']),
      lastMessageAtUtc: lastMessageAtUtc,
      modelIds: Set.unmodifiable(modelIds),
      messages: List.unmodifiable(messages),
      toolCalls: List.unmodifiable(toolCalls),
      warnings: List.unmodifiable(warnings),
      usage: usage,
      lastTurnUsage: const CodexUsage.empty(),
    );
  }

  CodexParsedSession _parseJsonlSession(
    File source,
    List<Map<String, Object?>> records,
    String rawText,
  ) {
    var sourcePath = source.path;
    String? sourceFileUncPath;
    String? displayPath;
    String? platformPath;
    String? workingDirectory;
    String? workingDirectoryUnc;
    String? title;
    String? summary;
    String? sessionId;
    DateTime? startedAtUtc;
    DateTime? lastMessageAtUtc;
    final messages = <CodexParsedMessage>[];
    final toolCalls = <CodexParsedToolCall>[];
    final warnings = <CodexParseWarning>[];
    final modelIds = <String>{};
    final pendingToolCalls = <String, CodexParsedToolCall>{};
    var usage = const CodexUsage.empty();
    var hasAggregateUsage = false;
    var lastTurnUsage = const CodexUsage.empty();

    for (final record in records) {
      final recordType = _string(record['type']);
      final timestamp = _dateTime(record['timestamp']);
      final payload = _map(record['payload']);
      if (recordType == 'session_meta') {
        sessionId = _string(payload['id']) ?? sessionId;
        workingDirectory = _string(payload['cwd']) ?? workingDirectory;
        sourceFileUncPath = _string(payload['source_file_unc_path']);
        startedAtUtc =
            _dateTime(payload['timestamp']) ?? timestamp ?? startedAtUtc;
        continue;
      }
      if (recordType == 'turn_context') {
        workingDirectory = _string(payload['cwd']) ?? workingDirectory;
        workingDirectoryUnc =
            _string(payload['working_directory_unc']) ?? workingDirectoryUnc;
        summary = _string(payload['summary']) ?? summary;
        final model = _string(payload['model']);
        if (model != null && model.isNotEmpty) {
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
        final messageUsage = CodexUsage.fromJson(payload['usage']);
        if (!hasAggregateUsage) {
          usage = usage + messageUsage;
        }
        final model = _string(payload['model']);
        if (model != null && model.isNotEmpty) {
          modelIds.add(model);
        }
        final storedContent = _truncate(content, maxMessageContentChars);
        messages.add(
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
        title ??= authorType == CodexMessageAuthorType.user
            ? _firstLine(content)
            : null;
        lastMessageAtUtc = _maxDateTime(lastMessageAtUtc, timestamp);
        continue;
      }
      if (recordType == 'event_msg' &&
          (payloadType == 'user_message' || payloadType == 'agent_message')) {
        final content = _string(payload['message']) ?? '';
        final authorType = payloadType == 'user_message'
            ? CodexMessageAuthorType.user
            : CodexMessageAuthorType.assistant;
        final storedContent = _truncate(content, maxMessageContentChars);
        messages.add(
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
        title ??= authorType == CodexMessageAuthorType.user
            ? _firstLine(content)
            : null;
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
      messages.add(
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
    return CodexParsedSession(
      internalId: sha256
          .convert(utf8.encode('$sourcePath\n$rawText'))
          .toString(),
      sessionId: sessionId,
      sourceType: _sourceType(null, sourcePath),
      sourcePath: sourcePath,
      sourceFileUncPath: sourceFileUncPath,
      displayPath: displayPath,
      platformPath: platformPath,
      workingDirectoryDisplay: workingDirectory,
      workingDirectoryPlatform: workingDirectory,
      workingDirectoryUnc: workingDirectoryUnc,
      title: title,
      summary: summary,
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

  bool _looksLikeJsonl(File source, String text) {
    if (source.path.endsWith('.jsonl')) {
      return true;
    }
    final trimmed = text.trimLeft();
    return trimmed.startsWith('{') &&
        trimmed.contains('\n{') &&
        !trimmed.startsWith('{\n  "');
  }

  _JsonlDecodeResult _decodeJsonl(File source, String text) {
    final records = <Map<String, Object?>>[];
    var offset = 0;
    final lines = const LineSplitter().convert(text);
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final normalizedLine = _stripLeadingNulPadding(line);
      final leadingPadding = line.length - normalizedLine.length;
      if (normalizedLine.trim().isEmpty) {
        offset += line.length + 1;
        continue;
      }
      try {
        final decoded = jsonDecode(normalizedLine);
        if (decoded is! Map<String, Object?>) {
          return _JsonlDecodeResult.error(
            CodexParseError(
              sourcePath: source.path,
              kind: CodexParseErrorKind.unsupportedRoot,
              message: 'JSONL record must be a JSON object.',
              offset: offset,
              line: index + 1,
              column: 1,
            ),
          );
        }
        records.add(decoded);
      } on FormatException catch (error) {
        final column = error.offset == null
            ? null
            : leadingPadding + error.offset! + 1;
        return _JsonlDecodeResult.error(
          CodexParseError(
            sourcePath: source.path,
            kind: CodexParseErrorKind.malformedJson,
            message: error.message,
            offset: offset + leadingPadding + (error.offset ?? 0),
            line: index + 1,
            column: column,
          ),
        );
      }
      offset += line.length + 1;
    }
    return _JsonlDecodeResult.records(records);
  }

  String _stripLeadingNulPadding(String line) {
    var firstJsonChar = 0;
    while (firstJsonChar < line.length && line.codeUnitAt(firstJsonChar) == 0) {
      firstJsonChar++;
    }
    return firstJsonChar == 0 ? line : line.substring(firstJsonChar);
  }
}

class CodexParseResult {
  const CodexParseResult._({this.session, this.error});

  factory CodexParseResult.success(CodexParsedSession session) =>
      CodexParseResult._(session: session);

  factory CodexParseResult.failure(CodexParseError error) =>
      CodexParseResult._(error: error);

  final CodexParsedSession? session;
  final CodexParseError? error;

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
  });

  final String internalId;
  final String? sessionId;
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
    this.reasoningOutputTokens,
    int? totalTokens,
  }) : _explicitTotalTokens = totalTokens;

  const CodexUsage.empty()
    : inputTokens = null,
      outputTokens = null,
      cachedInputTokens = null,
      reasoningOutputTokens = null,
      _explicitTotalTokens = null;

  factory CodexUsage.fromJson(Object? json) {
    if (json is! Map) {
      return const CodexUsage.empty();
    }
    final map = json.cast<String, Object?>();
    return CodexUsage(
      inputTokens: _int(map['input_tokens']),
      outputTokens: _int(map['output_tokens']),
      cachedInputTokens: _int(map['cached_input_tokens']),
      reasoningOutputTokens: _int(map['reasoning_output_tokens']),
      totalTokens: _int(map['total_tokens']),
    );
  }

  final int? inputTokens;
  final int? outputTokens;
  final int? cachedInputTokens;
  final int? reasoningOutputTokens;
  final int? _explicitTotalTokens;

  bool get isEmpty =>
      inputTokens == null &&
      outputTokens == null &&
      cachedInputTokens == null &&
      reasoningOutputTokens == null &&
      _explicitTotalTokens == null;

  int? get totalTokens {
    if (_explicitTotalTokens != null) {
      return _explicitTotalTokens;
    }
    if (inputTokens == null &&
        outputTokens == null &&
        cachedInputTokens == null &&
        reasoningOutputTokens == null) {
      return null;
    }
    return _componentTotalTokens;
  }

  int get _componentTotalTokens =>
      (inputTokens ?? 0) +
      (outputTokens ?? 0) +
      (cachedInputTokens ?? 0) +
      (reasoningOutputTokens ?? 0);

  CodexUsage operator +(CodexUsage other) => CodexUsage(
    inputTokens: _sumNullable(inputTokens, other.inputTokens),
    outputTokens: _sumNullable(outputTokens, other.outputTokens),
    cachedInputTokens: _sumNullable(cachedInputTokens, other.cachedInputTokens),
    reasoningOutputTokens: _sumNullable(
      reasoningOutputTokens,
      other.reasoningOutputTokens,
    ),
    totalTokens: _sumNullable(totalTokens, other.totalTokens),
  );
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
  'patch_apply_end',
  'task_complete',
  'task_started',
  'thread_goal_updated',
  'token_count',
  'turn_aborted',
  'user_message',
  'view_image_tool_call',
  'web_search_end',
};

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : <String, Object?>{};

String? _string(Object? value) => value is String ? value : null;

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
  final line = value.split(RegExp(r'\r?\n')).first.trim();
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

class _JsonlDecodeResult {
  const _JsonlDecodeResult._({required this.records, this.error});

  factory _JsonlDecodeResult.records(List<Map<String, Object?>> records) =>
      _JsonlDecodeResult._(records: records);

  factory _JsonlDecodeResult.error(CodexParseError error) =>
      _JsonlDecodeResult._(records: const [], error: error);

  final List<Map<String, Object?>> records;
  final CodexParseError? error;
}
