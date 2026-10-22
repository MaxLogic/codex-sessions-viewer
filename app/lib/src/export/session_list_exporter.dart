import 'dart:convert';
import 'dart:isolate';
import 'first_instruction.dart';

import '../commands/resume_command_generator.dart';
import '../config/app_settings.dart';
import '../ui/models/conversation_message_view_model.dart';
import '../ui/models/session_row_view_model.dart';

Future<String> formatSessionListMarkdown(
  AppSettings settings,
  List<SessionRowViewModel> rows, {
  bool includeFirstMessage = false,
  bool includeLastMessage = false,
}) {
  if (rows.length < 100) {
    return Future.value(
      SessionListExporter(settings: settings).exportMarkdown(
        rows,
        includeFirstMessage: includeFirstMessage,
        includeLastMessage: includeLastMessage,
      ),
    );
  }
  return Isolate.run(
    () => SessionListExporter(settings: settings).exportMarkdown(
      rows,
      includeFirstMessage: includeFirstMessage,
      includeLastMessage: includeLastMessage,
    ),
  );
}

class SessionListExporter {
  const SessionListExporter({required this.settings});

  final AppSettings settings;

  String exportMarkdown(
    List<SessionRowViewModel> rows, {
    bool includeFirstMessage = false,
    bool includeLastMessage = false,
  }) {
    final buffer = StringBuffer('# Sessions (${rows.length})');
    for (final row in rows) {
      buffer
        ..writeln()
        ..writeln()
        ..writeln('## ${_heading(row)}')
        ..writeln()
        ..writeln(_inlineCode(row.workingDirectoryForCommands))
        ..writeln()
        ..writeln(switch (row.platform) {
          SessionRowPlatform.macos || SessionRowPlatform.linux => '```text',
          SessionRowPlatform.windows ||
          SessionRowPlatform.wsl => '```powershell',
        })
        ..writeln(_resumeCommand(row))
        ..writeln('```');
      if (row.platform == SessionRowPlatform.wsl) {
        buffer
          ..writeln()
          ..writeln('```bash')
          ..writeln(_resumeCommand(row, plain: true))
          ..writeln('```');
      }
      buffer
        ..writeln()
        ..write(_metadata(row));
      _writeRequestedMessages(
        buffer,
        row,
        includeFirstMessage: includeFirstMessage,
        includeLastMessage: includeLastMessage,
      );
      if (row != rows.last) {
        buffer
          ..writeln()
          ..writeln()
          ..write('---');
      }
    }
    if (rows.isNotEmpty && (includeFirstMessage || includeLastMessage)) {
      buffer
        ..writeln()
        ..writeln()
        ..write(
          '**Legend:** 👤 User · 🤖 Assistant · ⚙ Tool · 💭 Reasoning · ℹ System',
        );
    }
    return buffer.toString();
  }

  void _writeRequestedMessages(
    StringBuffer buffer,
    SessionRowViewModel row, {
    required bool includeFirstMessage,
    required bool includeLastMessage,
  }) {
    if ((!includeFirstMessage && !includeLastMessage) ||
        row.conversationMessages.isEmpty) {
      return;
    }
    final messages =
        row.conversationMessages
            .where((message) => messageContent(message) != null)
            .toList()
          ..sort((left, right) => left.number.compareTo(right.number));
    if (messages.isEmpty) return;
    if (includeFirstMessage) {
      for (final message in messages) {
        if (message.author == ConversationAuthor.user) {
          _writeMessage(buffer, 'First message', message);
          break;
        }
      }
    }
    if (includeLastMessage) {
      for (final message in messages.reversed) {
        if (messageContent(message)?.author == ConversationAuthor.assistant) {
          _writeMessage(buffer, 'Last message', message);
          break;
        }
      }
    }
  }

  void _writeMessage(
    StringBuffer buffer,
    String label,
    ConversationMessageViewModel message,
  ) {
    final content = messageContent(message)!;
    final symbol = switch (content.author) {
      ConversationAuthor.user => '👤',
      ConversationAuthor.assistant => '🤖',
      ConversationAuthor.tool => '⚙',
      ConversationAuthor.reasoning => '💭',
      ConversationAuthor.system => 'ℹ',
    };
    buffer
      ..writeln()
      ..writeln()
      ..writeln('### $label $symbol')
      ..writeln()
      ..write(
        const LineSplitter()
            .convert(content.body)
            .where((line) => line.trim().isNotEmpty)
            .join('\n'),
      );
  }

  /// Shared by endpoint loading and rendering so skipped events do not leave
  /// the actual first/last message with only a truncated preview.
  static ({ConversationAuthor author, String body})? messageContent(
    ConversationMessageViewModel message,
  ) {
    final body =
        (message.body.trim().isNotEmpty ? message.body : message.preview)
            .trim();
    if (body.isEmpty) return null;
    if (message.author == ConversationAuthor.user) {
      final instruction = firstInstruction(body);
      return instruction == null
          ? null
          : (author: message.author, body: instruction);
    }
    if (message.author == ConversationAuthor.tool ||
        message.author == ConversationAuthor.system) {
      Object? decoded;
      try {
        decoded = jsonDecode(body);
      } on FormatException {
        // Ordinary tool output is not necessarily JSON.
      }
      if (decoded is Map<String, dynamic>) {
        if (decoded['type'] == 'task_complete') {
          final text = decoded['last_agent_message'];
          return text is String && text.trim().isNotEmpty
              ? (author: ConversationAuthor.assistant, body: text.trim())
              : null;
        }
      }
    }
    return switch (message.author) {
      ConversationAuthor.user ||
      ConversationAuthor.assistant => (author: message.author, body: body),
      _ => null,
    };
  }

  String exportCsv(List<SessionRowViewModel> rows) {
    const columns = [
      'name',
      'thread_name',
      'title',
      'project',
      'working_directory',
      'resume_command',
      'started_utc',
      'last_message_utc',
      'duration_minutes',
      'message_count',
      'total_tokens',
      'estimated_cost',
      'model',
      'platform',
      'tags',
      'status',
      'session_id',
      'harness',
    ];
    final buffer = StringBuffer('\ufeff${columns.join(',')}\r\n');
    for (final row in rows) {
      final duration =
          row.duration ?? row.lastMessageAtUtc.difference(row.startedAtUtc);
      final values = [
        _displayName(row),
        row.threadName,
        row.title,
        row.project,
        row.workingDirectoryForCommands,
        _resumeCommand(row),
        row.startedAtUtc.toUtc().toIso8601String(),
        row.lastMessageAtUtc.toUtc().toIso8601String(),
        duration.inMinutes.toString(),
        row.messageCount.toString(),
        row.displayTotalTokens.toString(),
        row.costUnknown ? '' : row.estimatedCostText ?? '0',
        row.model,
        row.platformLabel,
        row.tags.join('; '),
        row.status,
        row.sessionId,
        row.harnessLabel,
      ];
      buffer
        ..write(values.map(_csvValue).join(','))
        ..write('\r\n');
    }
    return buffer.toString();
  }

  String _heading(SessionRowViewModel row) {
    return _markdownHeadingText(_displayName(row));
  }

  String _displayName(SessionRowViewModel row) {
    final directory = _directoryName(row.workingDirectoryForCommands);
    final identity = [
      row.threadName.trim(),
      row.title.trim(),
      row.project.trim(),
      row.sessionId.trim(),
      row.id.trim(),
    ].firstWhere((value) => value.isNotEmpty, orElse: () => 'Untitled session');
    final parts = <String>[identity];
    if (directory.isNotEmpty &&
        directory.toLowerCase() != identity.toLowerCase()) {
      parts.add(directory);
    }
    return parts.join(' — ');
  }

  String _resumeCommand(SessionRowViewModel row, {bool plain = false}) {
    if (row.platform == SessionRowPlatform.macos ||
        row.platform == SessionRowPlatform.linux) {
      return 'Resume is unavailable for this source platform.';
    }
    final commandSet = ResumeCommandGenerator(settings: settings).build(
      ResumeCommandSession(
        sessionId: row.sessionId,
        harness: row.harness,
        sourceType: row.platform == SessionRowPlatform.wsl
            ? ResumeSessionSourceType.wsl
            : ResumeSessionSourceType.windows,
        workingDirectory: row.workingDirectoryForCommands,
      ),
    );
    return (plain ? null : commandSet.platformResumeCommand) ??
        commandSet.plainResumeCommand ??
        'Resume unavailable';
  }

  String _metadata(SessionRowViewModel row) {
    final duration =
        row.duration ?? row.lastMessageAtUtc.difference(row.startedAtUtc);
    final cachedPercent = row.inputTokens > 0
        ? '${(row.cachedInputTokens * 100 / row.inputTokens).toStringAsFixed(1).replaceFirst(RegExp(r'\.0$'), '')}%'
        : '0%';
    final cost = row.displayEstimatedCost;
    final estimated = cost.startsWith(r'$') ? '$cost (estimate)' : cost;
    final inputLabel =
        row.usageRollup != null && row.displayTotalTokens != row.totalTokens
        ? 'session in'
        : 'in';
    return '**Stats**\n\n'
        'Started: ${_dateMinute(row.startedAtUtc)}  \n'
        'Last: ${_dateMinute(row.lastMessageAtUtc)}  \n'
        'Duration: ${_duration(duration)}  \n'
        'Messages: ${_compactInt(row.messageCount)}  \n'
        'Tokens: ${_compactInt(row.displayTotalTokens)}, '
        '$inputLabel: ${_compactInt(row.inputTokens)} '
        '(${_compactInt(row.cachedInputTokens)} cached, $cachedPercent), '
        'out: ${_compactInt(row.outputTokens)}  \n'
        'Cost: $estimated  \n'
        'Model: ${row.modelLabel}  \n'
        'Platform: ${row.platformLabel}  \n'
        'Harness: ${row.harnessLabel}';
  }
}

String _directoryName(String path) {
  final parts = path
      .trim()
      .split(RegExp(r'[\\/]+'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  return parts.isEmpty ? '' : parts.last;
}

String _markdownHeadingText(String value) => value
    .replaceAll(RegExp(r'\s+'), ' ')
    .replaceAll(r'\', r'\\')
    .replaceAll('#', r'\#')
    .replaceAll('*', r'\*')
    .replaceAll('_', r'\_')
    .trim();

String _inlineCode(String value) {
  final trimmed = value.trim();
  if (!trimmed.contains('`')) {
    return '`$trimmed`';
  }
  return '``$trimmed``';
}

String _csvValue(String value) {
  if (!RegExp('[,"\\r\\n]').hasMatch(value)) {
    return value;
  }
  return '"${value.replaceAll('"', '""')}"';
}

String _dateMinute(DateTime value) {
  final local = value.toLocal();
  return '${_fourDigits(local.year)}-${_twoDigits(local.month)}-'
      '${_twoDigits(local.day)} ${_twoDigits(local.hour)}:'
      '${_twoDigits(local.minute)}';
}

String _duration(Duration value) {
  final duration = value.isNegative ? Duration.zero : value;
  final days = duration.inDays;
  final hours = days > 0 ? duration.inHours.remainder(24) : duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  return [
    if (days > 0) '${days}d',
    if (hours > 0) '${hours}h',
    if (minutes > 0 || (days == 0 && hours == 0)) '${minutes}m',
  ].join(' ');
}

String _compactInt(int value) {
  for (final unit in [
    (1000000000000, 'T'),
    (1000000000, 'B'),
    (1000000, 'M'),
    (1000, 'k'),
  ]) {
    if (value.abs() >= unit.$1) {
      final scaled = value / unit.$1;
      final digits = scaled.abs() >= 100 ? 0 : 1;
      return '${scaled.toStringAsFixed(digits).replaceFirst(RegExp(r'\.0$'), '')}${unit.$2}';
    }
  }
  return value.toString();
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

String _fourDigits(int value) => value.toString().padLeft(4, '0');
