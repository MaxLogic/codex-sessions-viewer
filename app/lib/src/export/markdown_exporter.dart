import '../parser/codex_session_parser.dart';
import '../utils/injected_context_filter.dart';

class MarkdownSessionExporter {
  const MarkdownSessionExporter();

  String exportMarkdown(
    CodexParsedSession session,
    MarkdownExportRequest request,
  ) {
    final messages = _selectMessages(
      session.messages,
      request.scope,
      request.options,
      request.selectedMessageIndexes,
    );
    final buffer = StringBuffer();
    buffer.writeln('# ${_sessionTitle(session)}');
    buffer.writeln();

    if (request.options.includeMetadata) {
      for (final line in _metadataLines(session, request.options)) {
        buffer.writeln(line);
      }
      buffer.writeln();
    }

    buffer.writeln('## Conversation');
    buffer.writeln();

    final toolCallsByMessage = _toolCallsByMessage(session.toolCalls);
    for (var i = 0; i < messages.length; i++) {
      final message = messages[i];
      _writeMessage(buffer, message, request.options);
      if (request.options.includeToolCalls) {
        final toolCalls = toolCallsByMessage[message.index] ?? const [];
        if (toolCalls.isNotEmpty) {
          _writeToolCalls(
            buffer,
            toolCalls,
            request.options,
            request.fullToolOutputsByToolIndex,
          );
        }
      }
      if (i != messages.length - 1) {
        buffer.writeln();
      }
    }

    return buffer.toString().trimRight();
  }

  String exportPlainText(
    CodexParsedSession session,
    MarkdownPlainTextExportRequest request,
  ) {
    final message = session.messages
        .where((candidate) => candidate.index == request.messageIndex)
        .firstOrNull;
    if (message == null) {
      return '';
    }
    return message.contentPlain;
  }

  List<CodexParsedMessage> _selectMessages(
    List<CodexParsedMessage> messages,
    MarkdownExportScope scope,
    MarkdownExportOptions options,
    Set<int> selectedMessageIndexes,
  ) {
    final visibleMessages = messages
        .where(_isVisibleExportMessage)
        .toList(growable: false);
    final scoped = switch (scope.kind) {
      MarkdownExportScopeKind.all => visibleMessages,
      MarkdownExportScopeKind.selectedMessage =>
        visibleMessages
            .where((message) => message.index == scope.startIndex)
            .toList(growable: false),
      MarkdownExportScopeKind.range =>
        visibleMessages
            .where(
              (message) =>
                  message.index >= scope.startIndex &&
                  message.index <= scope.endIndex,
            )
            .toList(growable: false),
      MarkdownExportScopeKind.fromMessageOnward =>
        visibleMessages
            .where((message) => message.index >= scope.startIndex)
            .toList(growable: false),
    };
    if (!options.onlySelectedMessages) {
      return scoped;
    }
    return scoped
        .where((message) => selectedMessageIndexes.contains(message.index))
        .toList(growable: false);
  }

  bool _isVisibleExportMessage(CodexParsedMessage message) {
    return message.authorType != CodexMessageAuthorType.user ||
        !isInjectedEnvironmentContextMessage(message.contentPlain);
  }
}

class MarkdownExportRequest {
  const MarkdownExportRequest({
    required this.scope,
    this.options = const MarkdownExportOptions(),
    this.selectedMessageIndexes = const {},
    this.fullToolOutputsByToolIndex = const {},
  });

  final MarkdownExportScope scope;
  final MarkdownExportOptions options;
  final Set<int> selectedMessageIndexes;
  final Map<int, String> fullToolOutputsByToolIndex;
}

class MarkdownPlainTextExportRequest {
  const MarkdownPlainTextExportRequest.selectedMessage(this.messageIndex);

  final int messageIndex;
}

class MarkdownExportOptions {
  const MarkdownExportOptions({
    this.includeMetadata = true,
    this.includeTokenUsage = true,
    this.includeTimestamps = true,
    this.includeToolCalls = true,
    this.includeFullToolOutput = false,
    this.includeCodeBlocks = true,
    this.onlySelectedMessages = false,
  });

  final bool includeMetadata;
  final bool includeTokenUsage;
  final bool includeTimestamps;
  final bool includeToolCalls;
  final bool includeFullToolOutput;
  final bool includeCodeBlocks;
  final bool onlySelectedMessages;
}

enum MarkdownExportScopeKind { all, selectedMessage, range, fromMessageOnward }

class MarkdownExportScope {
  const MarkdownExportScope.all()
    : kind = MarkdownExportScopeKind.all,
      startIndex = 0,
      endIndex = 0;

  const MarkdownExportScope.selectedMessage(this.startIndex)
    : kind = MarkdownExportScopeKind.selectedMessage,
      endIndex = startIndex;

  const MarkdownExportScope.range(this.startIndex, this.endIndex)
    : kind = MarkdownExportScopeKind.range;

  const MarkdownExportScope.fromMessageOnward(this.startIndex)
    : kind = MarkdownExportScopeKind.fromMessageOnward,
      endIndex = 0;

  final MarkdownExportScopeKind kind;
  final int startIndex;
  final int endIndex;
}

void _writeMessage(
  StringBuffer buffer,
  CodexParsedMessage message,
  MarkdownExportOptions options,
) {
  buffer.writeln('<a id="${_messageAnchor(message)}"></a>');
  final title = '${message.index + 1}. ${_authorLabel(message.authorType)}';
  final timestamp = _formatDateMinute(message.createdAtUtc);
  if (options.includeTimestamps && timestamp != null) {
    buffer.writeln('### $title \u2014 $timestamp');
  } else {
    buffer.writeln('### $title');
  }
  buffer.writeln();
  buffer.writeln(_messageContent(message, options));
  if (message.contentTruncated) {
    buffer.writeln();
    buffer.writeln('_Message content is truncated in parsed data._');
  }
  if (options.includeTokenUsage && !message.usage.isEmpty) {
    buffer.writeln();
    buffer.writeln('_Tokens: ${_usageSummary(message.usage)}_');
  }
}

void _writeToolCalls(
  StringBuffer buffer,
  List<CodexParsedToolCall> toolCalls,
  MarkdownExportOptions options,
  Map<int, String> fullToolOutputsByToolIndex,
) {
  buffer.writeln();
  buffer.writeln('Tool calls:');
  for (final toolCall in toolCalls) {
    buffer.writeln();
    buffer.writeln('- ${toolCall.toolName} (${toolCall.status})');
    if (toolCall.inputPreview.isNotEmpty) {
      buffer.writeln('  - Input: `${_singleLine(toolCall.inputPreview)}`');
    }
    if (toolCall.errorMessage != null) {
      buffer.writeln('  - Error: ${toolCall.errorMessage}');
    }
    if (options.includeFullToolOutput) {
      final output =
          fullToolOutputsByToolIndex[toolCall.toolIndex] ??
          toolCall.outputPreview;
      if (output.isNotEmpty) {
        buffer.writeln('  - Output:');
        buffer.writeln();
        buffer.writeln(_indentedCodeBlock(output));
      }
      if (toolCall.outputTruncated &&
          !fullToolOutputsByToolIndex.containsKey(toolCall.toolIndex)) {
        buffer.writeln('  - Output is truncated in parsed data.');
      }
    } else if (toolCall.outputPreview.isNotEmpty || toolCall.outputTruncated) {
      buffer.writeln('  - Output omitted by export options.');
    }
  }
}

List<String> _metadataLines(
  CodexParsedSession session,
  MarkdownExportOptions options,
) {
  final lines = <String>[
    '- Source: ${_sourceLabel(session.sourceType)}',
    '- Project: ${_projectName(session)}',
    '- Path: ${session.displayPath}',
  ];
  final started = _formatDateMinute(session.startedAtUtc);
  if (started != null) {
    lines.add('- Started: $started');
  }
  final lastMessage = _formatDateMinute(session.lastMessageAtUtc);
  if (lastMessage != null) {
    lines.add('- Last message: $lastMessage');
  }
  if (options.includeTokenUsage && !session.usage.isEmpty) {
    lines.add('- Tokens: ${_usageSummary(session.usage)}');
  }
  return lines;
}

Map<int, List<CodexParsedToolCall>> _toolCallsByMessage(
  List<CodexParsedToolCall> toolCalls,
) {
  final result = <int, List<CodexParsedToolCall>>{};
  for (final toolCall in toolCalls) {
    result.putIfAbsent(toolCall.messageIndex, () => []).add(toolCall);
  }
  return result;
}

String _sessionTitle(CodexParsedSession session) {
  final title = session.title?.trim();
  if (title != null && title.isNotEmpty) {
    return title;
  }
  return session.sessionId ?? 'Untitled session';
}

String _messageAnchor(CodexParsedMessage message) =>
    'message-${message.index + 1}';

String _messageContent(
  CodexParsedMessage message,
  MarkdownExportOptions options,
) {
  if (options.includeCodeBlocks) {
    return message.contentPlain;
  }
  final lines = message.contentPlain.split(RegExp(r'\r?\n'));
  final kept = <String>[];
  var insideFence = false;
  for (final line in lines) {
    if (line.trimLeft().startsWith('```')) {
      insideFence = !insideFence;
      continue;
    }
    if (!insideFence) {
      kept.add(line);
    }
  }
  return kept.join('\n').trim();
}

String _authorLabel(CodexMessageAuthorType authorType) {
  return switch (authorType) {
    CodexMessageAuthorType.user => 'User',
    CodexMessageAuthorType.assistant => 'Assistant',
    CodexMessageAuthorType.system => 'System',
    CodexMessageAuthorType.tool => 'Tool',
    CodexMessageAuthorType.unknown => 'Unknown',
  };
}

String _sourceLabel(CodexSessionSourceType sourceType) {
  return switch (sourceType) {
    CodexSessionSourceType.windows => 'Windows',
    CodexSessionSourceType.wsl => 'WSL',
    CodexSessionSourceType.unknown => 'Unknown',
  };
}

String _projectName(CodexParsedSession session) {
  final path =
      session.workingDirectoryDisplay ?? session.workingDirectoryPlatform;
  if (path == null || path.trim().isEmpty) {
    return 'Unknown';
  }
  final parts = path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

String? _formatDateMinute(DateTime? value) {
  if (value == null) {
    return null;
  }
  final utc = value.toUtc();
  return '${_fourDigits(utc.year)}-${_twoDigits(utc.month)}-'
      '${_twoDigits(utc.day)} ${_twoDigits(utc.hour)}:'
      '${_twoDigits(utc.minute)}';
}

String _usageSummary(CodexUsage usage) {
  return '${_tokenValue(usage.inputTokens)} / '
      '${_tokenValue(usage.outputTokens)} / '
      '${_tokenValue(usage.cachedInputTokens)} / '
      '${_tokenValue(usage.totalTokens)}';
}

String _tokenValue(int? value) => value?.toString() ?? '-';

String _singleLine(String value) =>
    value.replaceAll(RegExp(r'\s+'), ' ').trim();

String _indentedCodeBlock(String value) {
  final fence = _fenceFor(value);
  return '$fence\n$value\n$fence';
}

String _fenceFor(String value) {
  var fence = '```';
  while (value.contains(fence)) {
    fence = '$fence`';
  }
  return fence;
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _fourDigits(int value) => value.toString().padLeft(4, '0');
