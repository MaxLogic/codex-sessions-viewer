import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../commands/resume_command_generator.dart';
import '../../config/app_settings.dart';
import '../models/session_row_view_model.dart';
import 'command_preview.dart';
import 'conversation_view.dart';
import 'focus_reader_view.dart';

typedef DetailCopyCallback = Future<void> Function(String text);
typedef SessionDetailActionCallback =
    Future<void> Function(SessionDetailAction action);

enum SessionDetailAction {
  openContainingFolder,
  openTerminalHere,
  openTerminalResume,
  exportMarkdown,
  reparse,
  togglePin,
  toggleArchive,
  editTags,
  assignProject,
}

class SessionDetailPane extends StatelessWidget {
  const SessionDetailPane({
    super.key,
    required this.row,
    this.settings,
    this.onCopyText,
    this.onSessionAction,
    this.onRunTerminalCommand,
    this.onEditTerminalCommand,
    this.isLoadingMessages = false,
  });

  final SessionRowViewModel row;
  final AppSettings? settings;
  final DetailCopyCallback? onCopyText;
  final SessionDetailActionCallback? onSessionAction;
  final TerminalCommandCallback? onRunTerminalCommand;
  final TerminalCommandCallback? onEditTerminalCommand;
  final bool isLoadingMessages;

  @override
  Widget build(BuildContext context) {
    final commandSet =
        ResumeCommandGenerator(
          settings: settings ?? AppSettings.defaults(),
        ).build(
          ResumeCommandSession(
            sessionId: row.sessionId,
            sourceType: switch (row.platform) {
              SessionRowPlatform.windows => ResumeSessionSourceType.windows,
              SessionRowPlatform.wsl => ResumeSessionSourceType.wsl,
            },
            workingDirectory: row.workingDirectoryForCommands,
          ),
        );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Selected: ${row.title}'),
          const SizedBox(height: 4),
          Text(row.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          _MetadataGrid(row: row),
          const SizedBox(height: 10),
          _ActionArea(
            row: row,
            commandSet: commandSet,
            onCopyText: onCopyText,
            onSessionAction: onSessionAction,
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text(
              'Commands',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            children: [
              CommandPreview(
                commandSet: commandSet,
                onRunTerminalCommand: onRunTerminalCommand,
                onEditTerminalCommand: onEditTerminalCommand,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (isLoadingMessages)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: LinearProgressIndicator(),
            ),
          Text('Conversation', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 420,
            child: ConversationView(
              messages: row.conversationMessages,
              onCopyMessageMarkdown: onCopyText,
            ),
          ),
          const SizedBox(height: 16),
          Text('Focus reader', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 420,
            child: FocusReaderView(messages: row.conversationMessages),
          ),
        ],
      ),
    );
  }
}

class _MetadataGrid extends StatelessWidget {
  const _MetadataGrid({required this.row});

  final SessionRowViewModel row;

  @override
  Widget build(BuildContext context) {
    final duration =
        row.duration ?? row.lastMessageAtUtc.difference(row.startedAtUtc);
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      children: [
        _DetailText('Platform', row.platformLabel),
        _DetailText('Project', row.project),
        _DetailText('Source file', row.sourcePathForDisplay),
        _DetailText('Display path', row.displayPathForDetail),
        _DetailText('Working directory', row.workingDirectoryForCommands),
        _DetailText('Started', row.startedAtUtc.shortDateTime),
        _DetailText('Last message', row.lastMessageAtUtc.shortDateTime),
        _DetailText('Duration', duration.humanDuration),
        _DetailText('Total messages', row.messageCount.toString()),
        _DetailText('User message count', row.userMessageCount.toString()),
        _DetailText(
          'Assistant message count',
          row.assistantMessageCount.toString(),
        ),
        _DetailText('Tool call count', row.toolCallCount.toString()),
        _DetailText('Total tokens', row.totalTokens.toString()),
        _DetailText('Input tokens', row.inputTokens.toString()),
        _DetailText('Output tokens', row.outputTokens.toString()),
        _DetailText(
          'Cached input tokens',
          _tokensWithShare(row, row.cachedInputTokens),
        ),
        _DetailText(
          'User message tokens',
          _tokensWithShare(row, row.userMessageTokens),
        ),
        _DetailText(
          'AI response tokens',
          _tokensWithShare(row, row.assistantResponseTokens),
        ),
        _DetailText(
          'Tool call tokens',
          _tokensWithShare(row, row.toolCallTokens),
        ),
        _DetailText('Estimated cost', row.estimatedCostDisplay),
        _DetailText(
          'Models used',
          row.modelsUsedForDetail.isEmpty
              ? 'Unknown'
              : row.modelsUsedForDetail.join(', '),
          width: 532,
        ),
        _DetailText('Status', row.status),
        _DetailText('Tags', row.tags.join(', ')),
        _DetailText('Pinned', row.isPinned ? 'Yes' : 'No'),
        _DetailText('Archived', row.isArchived ? 'Yes' : 'No'),
      ],
    );
  }

  String _tokensWithShare(SessionRowViewModel row, int tokens) {
    return '$tokens (${row.tokenShareText(tokens)})';
  }
}

class _DetailText extends StatelessWidget {
  const _DetailText(this.label, this.value, {this.width = 260});

  final String label;
  final String value;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Text('$label: $value', overflow: TextOverflow.ellipsis),
    );
  }
}

class _ActionArea extends StatelessWidget {
  const _ActionArea({
    required this.row,
    required this.commandSet,
    required this.onCopyText,
    required this.onSessionAction,
  });

  final SessionRowViewModel row;
  final ResumeCommandSet commandSet;
  final DetailCopyCallback? onCopyText;
  final SessionDetailActionCallback? onSessionAction;

  @override
  Widget build(BuildContext context) {
    final canResume = commandSet.canResume;
    final terminalEnabled = commandSet.terminalLaunchCommand != null;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _copyAction(context, 'Copy session path', row.sourcePathForDisplay),
        _copyAction(
          context,
          'Copy working directory',
          row.workingDirectoryForCommands,
        ),
        _copyAction(
          context,
          'Copy plain resume command',
          commandSet.plainResumeCommand,
          enabled: canResume,
        ),
        _copyAction(
          context,
          'Copy platform resume command',
          commandSet.platformResumeCommand,
          enabled: commandSet.platformResumeCommand != null,
        ),
        _callbackAction(
          'Open containing folder',
          SessionDetailAction.openContainingFolder,
        ),
        _callbackAction(
          'Open terminal here',
          SessionDetailAction.openTerminalHere,
          enabled: false,
          disabledReason:
              'Opening a terminal without resume is not available yet.',
        ),
        _callbackAction(
          'Open in terminal and resume',
          SessionDetailAction.openTerminalResume,
          enabled: terminalEnabled,
        ),
        _copyAction(
          context,
          'Copy terminal launch command',
          commandSet.terminalLaunchCommand,
          enabled: terminalEnabled,
        ),
        _callbackAction(
          'Export Markdown',
          SessionDetailAction.exportMarkdown,
          enabled: false,
          disabledReason: 'Markdown file export is not available yet.',
        ),
        _copyAction(
          context,
          'Copy conversation Markdown',
          _conversationMarkdown(row),
        ),
        _callbackAction('Re-parse this session', SessionDetailAction.reparse),
        _callbackAction(
          row.isPinned ? 'Unpin session' : 'Pin session',
          SessionDetailAction.togglePin,
        ),
        _callbackAction(
          row.isArchived ? 'Unarchive session' : 'Archive session',
          SessionDetailAction.toggleArchive,
        ),
        _callbackAction(
          'Add/remove tags',
          SessionDetailAction.editTags,
          enabled: false,
          disabledReason: 'Tag editing is not available yet.',
        ),
        _callbackAction(
          'Assign/change project',
          SessionDetailAction.assignProject,
          enabled: false,
          disabledReason: 'Project assignment is not available yet.',
        ),
      ],
    );
  }

  Widget _copyAction(
    BuildContext context,
    String label,
    String? text, {
    bool enabled = true,
  }) {
    return OutlinedButton(
      onPressed: enabled && text != null
          ? () => _copyText(context, _copySuccessMessage(label), text)
          : null,
      child: Text(label),
    );
  }

  Widget _callbackAction(
    String label,
    SessionDetailAction action, {
    bool enabled = true,
    String? disabledReason,
  }) {
    final button = OutlinedButton(
      onPressed: enabled && onSessionAction != null
          ? () => _invokeAction(action)
          : null,
      child: Text(label),
    );
    if (enabled || disabledReason == null) {
      return button;
    }
    return Tooltip(message: disabledReason, child: button);
  }

  Future<void> _copyText(
    BuildContext context,
    String message,
    String text,
  ) async {
    final callback = onCopyText;
    if (callback != null) {
      await callback(text);
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _invokeAction(SessionDetailAction action) async {
    final callback = onSessionAction;
    if (callback != null) {
      await callback(action);
    }
  }

  String _conversationMarkdown(SessionRowViewModel row) {
    return [
      '# ${row.title}',
      '',
      for (final message in row.conversationMessages) ...[
        '## Message ${message.number} - ${message.authorLabel}',
        '',
        message.body,
        '',
      ],
    ].join('\n');
  }

  String _copySuccessMessage(String label) {
    return switch (label) {
      'Copy session path' => 'Copied session path.',
      'Copy working directory' => 'Copied working directory.',
      'Copy plain resume command' => 'Copied plain resume command.',
      'Copy platform resume command' => 'Copied platform resume command.',
      'Copy terminal launch command' => 'Copied terminal launch command.',
      'Copy conversation Markdown' => 'Copied conversation Markdown.',
      _ => 'Copied.',
    };
  }
}

extension on DateTime {
  String get shortDateTime {
    final local = toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

extension on Duration {
  String get humanDuration {
    final hours = inHours;
    final minutes = inMinutes.remainder(60);
    if (hours > 0 && minutes > 0) {
      return '${hours}h ${minutes}m';
    }
    if (hours > 0) {
      return '${hours}h';
    }
    return '${minutes}m';
  }
}
