import 'dart:convert';

import '../ui/models/session_label_formatter.dart';
import '../utils/injected_context_filter.dart';

enum EvalDatasetFormat {
  deepEvalJson,
  openAiJsonl,
  promptfooJsonl,
  markdownFiles,
  plainTextFiles,
}

enum EvalTurnMode {
  fullConversation,
  perUserAssistantTurn,
  finalAssistantAnswer,
}

class EvalDatasetExporter {
  const EvalDatasetExporter();

  Map<String, String> export(EvalDatasetExportRequest request) {
    final anonymizer = _PathAnonymizer();
    final cases = [
      for (final session in request.sessions)
        ..._casesFor(session, request.turnMode, request.options, anonymizer),
    ];
    return switch (request.format) {
      EvalDatasetFormat.deepEvalJson => {
        'deepeval.json': const JsonEncoder.withIndent('  ').convert({
          'test_cases': [
            for (final testCase in cases)
              _deepEvalCase(testCase, request.options),
          ],
        }),
      },
      EvalDatasetFormat.openAiJsonl => {
        'openai_eval.jsonl': cases
            .map(
              (testCase) => jsonEncode(_openAiCase(testCase, request.options)),
            )
            .join('\n'),
      },
      EvalDatasetFormat.promptfooJsonl => {
        'promptfoo.jsonl': cases
            .map(
              (testCase) =>
                  jsonEncode(_promptfooCase(testCase, request.options)),
            )
            .join('\n'),
      },
      EvalDatasetFormat.markdownFiles => {
        for (final testCase in cases)
          'markdown/${_fileStem(testCase.id)}.md': _markdownCase(
            testCase,
            request.options,
          ),
      },
      EvalDatasetFormat.plainTextFiles => {
        for (final testCase in cases)
          'plain_text/${_fileStem(testCase.id)}.txt': _plainTextCase(testCase),
      },
    };
  }

  List<_EvalCase> _casesFor(
    EvalDatasetSession evalSession,
    EvalTurnMode mode,
    EvalDatasetExportOptions options,
    _PathAnonymizer anonymizer,
  ) {
    final visible = evalSession.messages
        .where(_isVisibleEvalMessage)
        .toList(growable: false);
    return switch (mode) {
      EvalTurnMode.fullConversation => [
        _caseFromMessages(
          evalSession,
          idSuffix: 'full',
          inputMessages: visible
              .where((message) => message.author == EvalMessageAuthor.user)
              .toList(growable: false),
          actualMessages: visible
              .where((message) => message.author == EvalMessageAuthor.assistant)
              .toList(growable: false),
          options: options,
          anonymizer: anonymizer,
        ),
      ],
      EvalTurnMode.finalAssistantAnswer => [
        if (_lastAssistant(visible) != null)
          _caseFromMessages(
            evalSession,
            idSuffix: 'final',
            inputMessages: visible
                .takeWhile((message) => message != _lastAssistant(visible))
                .where((message) => message.author == EvalMessageAuthor.user)
                .toList(growable: false),
            actualMessages: [_lastAssistant(visible)!],
            options: options,
            anonymizer: anonymizer,
          ),
      ],
      EvalTurnMode.perUserAssistantTurn => _perTurnCases(
        evalSession,
        visible,
        options,
        anonymizer,
      ),
    };
  }

  List<_EvalCase> _perTurnCases(
    EvalDatasetSession evalSession,
    List<EvalDatasetMessage> visible,
    EvalDatasetExportOptions options,
    _PathAnonymizer anonymizer,
  ) {
    final cases = <_EvalCase>[];
    EvalDatasetMessage? pendingUser;
    var turn = 1;
    for (final message in visible) {
      if (message.author == EvalMessageAuthor.user) {
        pendingUser = message;
        continue;
      }
      if (message.author != EvalMessageAuthor.assistant ||
          pendingUser == null) {
        continue;
      }
      cases.add(
        _caseFromMessages(
          evalSession,
          idSuffix: 'turn-$turn',
          inputMessages: [pendingUser],
          actualMessages: [message],
          options: options,
          anonymizer: anonymizer,
        ),
      );
      pendingUser = null;
      turn++;
    }
    return cases;
  }

  _EvalCase _caseFromMessages(
    EvalDatasetSession evalSession, {
    required String idSuffix,
    required List<EvalDatasetMessage> inputMessages,
    required List<EvalDatasetMessage> actualMessages,
    required EvalDatasetExportOptions options,
    required _PathAnonymizer anonymizer,
  }) {
    final input = inputMessages
        .map((message) => _messageContent(message, options))
        .where((content) => content.isNotEmpty)
        .join('\n\n');
    final actualOutput = actualMessages
        .map((message) => _messageContent(message, options))
        .where((content) => content.isNotEmpty)
        .join('\n\n');
    final metadata = _metadata(evalSession, options, anonymizer);
    return _EvalCase(
      id: '${evalSession.id}-$idSuffix',
      title: _exportText(_sessionTitle(evalSession), options, anonymizer),
      input: _exportText(input, options, anonymizer),
      actualOutput: _exportText(actualOutput, options, anonymizer),
      expectedOutput: _blankToNull(
        _exportText(evalSession.expectedOutput ?? '', options, anonymizer),
      ),
      messages: [
        for (final message in inputMessages)
          if (_openAiRole(message) != null)
            {
              'role': _openAiRole(message)!,
              'content': _exportText(
                _messageContent(message, options),
                options,
                anonymizer,
              ),
            },
      ],
      metadata: metadata,
      toolCalls: options.includeToolCalls
          ? _toolCalls(evalSession.toolCalls, options, anonymizer)
          : const [],
    );
  }
}

class EvalDatasetExportRequest {
  const EvalDatasetExportRequest({
    required this.sessions,
    required this.format,
    required this.turnMode,
    this.options = const EvalDatasetExportOptions(),
  });

  final List<EvalDatasetSession> sessions;
  final EvalDatasetFormat format;
  final EvalTurnMode turnMode;
  final EvalDatasetExportOptions options;

  EvalDatasetExportRequest copyWith({
    List<EvalDatasetSession>? sessions,
    EvalDatasetFormat? format,
    EvalTurnMode? turnMode,
    EvalDatasetExportOptions? options,
  }) {
    return EvalDatasetExportRequest(
      sessions: sessions ?? this.sessions,
      format: format ?? this.format,
      turnMode: turnMode ?? this.turnMode,
      options: options ?? this.options,
    );
  }
}

/// Who wrote a stored message, as the collector records `author_type`.
enum EvalMessageAuthor { user, assistant, reasoning, system, tool }

EvalMessageAuthor evalMessageAuthor(String? value) => switch (value) {
  'user' => EvalMessageAuthor.user,
  'assistant' => EvalMessageAuthor.assistant,
  'reasoning' => EvalMessageAuthor.reasoning,
  'system' => EvalMessageAuthor.system,
  _ => EvalMessageAuthor.tool,
};

/// A stored message, read from the `messages` table.
class EvalDatasetMessage {
  const EvalDatasetMessage({
    required this.index,
    required this.author,
    required this.contentPlain,
  });

  final int index;
  final EvalMessageAuthor author;
  final String contentPlain;
}

/// A stored tool call, read from the `tool_calls` table.
class EvalDatasetToolCall {
  const EvalDatasetToolCall({
    required this.toolName,
    required this.status,
    this.messageIndex,
    this.inputPreview = '',
    this.outputPreview = '',
  });

  /// The message the call belongs to, when its time places it; null
  /// otherwise.
  final int? messageIndex;
  final String toolName;
  final String status;
  final String inputPreview;
  final String outputPreview;
}

/// One stored session of any harness with its local eval annotations.
class EvalDatasetSession {
  const EvalDatasetSession({
    required this.id,
    required this.sourceType,
    required this.displayPath,
    this.sessionId,
    this.title,
    this.modelIds = const {},
    this.totalTokens,
    this.messages = const [],
    this.toolCalls = const [],
    this.expectedOutput,
    this.status,
    this.notes,
  });

  /// The `sessions.id` row identity.
  final String id;
  final String? sessionId;
  final String? title;

  /// `windows` or `wsl`.
  final String sourceType;
  final String displayPath;
  final Set<String> modelIds;
  final int? totalTokens;
  final List<EvalDatasetMessage> messages;
  final List<EvalDatasetToolCall> toolCalls;
  final String? expectedOutput;
  final String? status;
  final String? notes;
}

class EvalDatasetExportOptions {
  const EvalDatasetExportOptions({
    this.anonymizePaths = true,
    this.includeMetadata = true,
    this.includeTokenUsage = true,
    this.includeToolCalls = false,
    this.includeCodeBlocks = true,
  });

  final bool anonymizePaths;
  final bool includeMetadata;
  final bool includeTokenUsage;
  final bool includeToolCalls;
  final bool includeCodeBlocks;
}

class _EvalCase {
  const _EvalCase({
    required this.id,
    required this.title,
    required this.input,
    required this.actualOutput,
    required this.expectedOutput,
    required this.messages,
    required this.metadata,
    required this.toolCalls,
  });

  final String id;
  final String title;
  final String input;
  final String actualOutput;
  final String? expectedOutput;
  final List<Map<String, String>> messages;
  final Map<String, Object?> metadata;
  final List<Map<String, Object?>> toolCalls;
}

Map<String, Object?> _deepEvalCase(
  _EvalCase testCase,
  EvalDatasetExportOptions options,
) {
  return {
    'id': testCase.id,
    'input': testCase.input,
    'actual_output': testCase.actualOutput,
    if (testCase.expectedOutput != null)
      'expected_output': testCase.expectedOutput,
    if (options.includeMetadata) 'metadata': testCase.metadata,
    if (testCase.toolCalls.isNotEmpty) 'tool_calls': testCase.toolCalls,
  };
}

Map<String, Object?> _openAiCase(
  _EvalCase testCase,
  EvalDatasetExportOptions options,
) {
  return {
    'custom_id': testCase.id,
    'messages': testCase.messages,
    if (testCase.expectedOutput != null) 'ideal': testCase.expectedOutput,
    if (options.includeMetadata) 'metadata': testCase.metadata,
    if (testCase.toolCalls.isNotEmpty) 'tool_calls': testCase.toolCalls,
  };
}

Map<String, Object?> _promptfooCase(
  _EvalCase testCase,
  EvalDatasetExportOptions options,
) {
  return {
    'description': testCase.title,
    'vars': {'prompt': testCase.input},
    if (testCase.expectedOutput != null)
      'assert': [
        {'type': 'equals', 'value': testCase.expectedOutput},
      ],
    if (options.includeMetadata) 'metadata': testCase.metadata,
    if (testCase.toolCalls.isNotEmpty) 'tool_calls': testCase.toolCalls,
  };
}

String _markdownCase(_EvalCase testCase, EvalDatasetExportOptions options) {
  final buffer = StringBuffer()
    ..writeln('# ${testCase.title}')
    ..writeln();
  if (options.includeMetadata && testCase.metadata.isNotEmpty) {
    for (final entry in testCase.metadata.entries) {
      buffer.writeln('- ${_label(entry.key)}: ${entry.value}');
    }
    buffer.writeln();
  }
  buffer
    ..writeln('## Input')
    ..writeln()
    ..writeln(testCase.input)
    ..writeln()
    ..writeln('## Actual Output')
    ..writeln()
    ..writeln(testCase.actualOutput);
  if (testCase.expectedOutput != null) {
    buffer
      ..writeln()
      ..writeln('## Expected Output')
      ..writeln()
      ..writeln(testCase.expectedOutput);
  }
  if (testCase.toolCalls.isNotEmpty) {
    buffer
      ..writeln()
      ..writeln('## Tool Calls')
      ..writeln();
    for (final toolCall in testCase.toolCalls) {
      buffer.writeln('- ${toolCall['tool_name']} (${toolCall['status']})');
    }
  }
  return buffer.toString().trimRight();
}

String _plainTextCase(_EvalCase testCase) {
  final buffer = StringBuffer()
    ..writeln('Input:')
    ..writeln(testCase.input)
    ..writeln()
    ..writeln('Actual output:')
    ..writeln(testCase.actualOutput);
  if (testCase.expectedOutput != null) {
    buffer
      ..writeln()
      ..writeln('Expected output:')
      ..writeln(testCase.expectedOutput);
  }
  return buffer.toString().trimRight();
}

Map<String, Object?> _metadata(
  EvalDatasetSession evalSession,
  EvalDatasetExportOptions options,
  _PathAnonymizer anonymizer,
) {
  if (!options.includeMetadata) {
    return const {};
  }
  final session = evalSession;
  final metadata = <String, Object?>{
    'session_id': session.sessionId,
    'title': _exportText(_sessionTitle(session), options, anonymizer),
    'source': session.sourceType,
    'source_label': SessionLabelFormatter.sourceType(session.sourceType),
    'path': options.anonymizePaths
        ? anonymizer.pathFor(session.displayPath)
        : session.displayPath,
    'models': session.modelIds.toList()..sort(),
    'model_labels': SessionLabelFormatter.modelLabels(session.modelIds),
    'provider_labels': SessionLabelFormatter.providerLabels(session.modelIds),
  };
  if (options.includeTokenUsage && session.totalTokens != null) {
    metadata['total_tokens'] = session.totalTokens;
  }
  final status = _blankToNull(evalSession.status);
  if (status != null) {
    metadata['eval_status'] = status;
  }
  final notes = _blankToNull(evalSession.notes);
  if (notes != null) {
    metadata['eval_notes'] = _exportText(notes, options, anonymizer);
  }
  return metadata;
}

List<Map<String, Object?>> _toolCalls(
  List<EvalDatasetToolCall> toolCalls,
  EvalDatasetExportOptions options,
  _PathAnonymizer anonymizer,
) {
  return [
    for (final toolCall in toolCalls)
      {
        'message_index': toolCall.messageIndex,
        'tool_name': toolCall.toolName,
        'status': toolCall.status,
        'input': _exportText(toolCall.inputPreview, options, anonymizer),
        'output_preview': _exportText(
          toolCall.outputPreview,
          options,
          anonymizer,
        ),
      },
  ];
}

EvalDatasetMessage? _lastAssistant(List<EvalDatasetMessage> messages) {
  for (var index = messages.length - 1; index >= 0; index--) {
    final message = messages[index];
    if (message.author == EvalMessageAuthor.assistant) {
      return message;
    }
  }
  return null;
}

bool _isVisibleEvalMessage(EvalDatasetMessage message) {
  return message.author != EvalMessageAuthor.user ||
      !isInjectedEnvironmentContextMessage(message.contentPlain);
}

String _messageContent(
  EvalDatasetMessage message,
  EvalDatasetExportOptions options,
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

String? _openAiRole(EvalDatasetMessage message) {
  return switch (message.author) {
    EvalMessageAuthor.user => 'user',
    EvalMessageAuthor.assistant => 'assistant',
    EvalMessageAuthor.system => 'system',
    _ => null,
  };
}

String _sessionTitle(EvalDatasetSession session) {
  final title = session.title?.trim();
  if (title != null && title.isNotEmpty) {
    return title;
  }
  final sessionId = session.sessionId?.trim();
  return sessionId == null || sessionId.isEmpty ? session.id : sessionId;
}

String _exportText(
  String value,
  EvalDatasetExportOptions options,
  _PathAnonymizer anonymizer,
) {
  return options.anonymizePaths ? anonymizer.redactText(value) : value;
}

String _fileStem(String value) =>
    value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

String _label(String value) {
  return value
      .split('_')
      .map(
        (part) => part.isEmpty
            ? part
            : '${part[0].toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
}

String? _blankToNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

class _PathAnonymizer {
  final Map<String, String> _paths = {};
  final _pathStartPattern = RegExp(
    r'[A-Za-z]:[\\/]|\\\\|/(?:home|Users|mnt|tmp|var|etc|opt|workspace|projects)(?=[\\/])',
  );

  String redactText(String value) {
    final buffer = StringBuffer();
    var index = 0;
    while (index < value.length) {
      final match = _nextPathStart(value, index);
      if (match == null) {
        buffer.write(value.substring(index));
        break;
      }
      buffer.write(value.substring(index, match.start));
      final end = _pathEnd(value, match.start);
      buffer.write(pathFor(value.substring(match.start, end)));
      index = end;
    }
    return buffer.toString();
  }

  String pathFor(String path) {
    return _paths.putIfAbsent(path, () => '<path:${_paths.length + 1}>');
  }

  Match? _nextPathStart(String value, int start) {
    for (final match in _pathStartPattern.allMatches(value, start)) {
      return match;
    }
    return null;
  }

  int _pathEnd(String value, int start) {
    var end = start;
    while (end < value.length) {
      if (_isPathTerminator(value.codeUnitAt(end))) {
        break;
      }
      end++;
    }
    while (end > start &&
        _isTrailingSentencePunctuation(value.codeUnitAt(end - 1))) {
      end--;
    }
    return end;
  }

  bool _isPathTerminator(int codeUnit) {
    return codeUnit == 10 ||
        codeUnit == 13 ||
        codeUnit == 34 ||
        codeUnit == 39 ||
        codeUnit == 60 ||
        codeUnit == 62 ||
        codeUnit == 124;
  }

  bool _isTrailingSentencePunctuation(int codeUnit) {
    return codeUnit == 41 ||
        codeUnit == 44 ||
        codeUnit == 46 ||
        codeUnit == 58 ||
        codeUnit == 59 ||
        codeUnit == 93;
  }
}
