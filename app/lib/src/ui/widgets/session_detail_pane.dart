import 'package:flutter/material.dart';

import '../../commands/resume_command_generator.dart';
import '../../config/app_settings.dart';
import '../models/session_row_view_model.dart';
import 'command_preview.dart';
import 'conversation_view.dart';

class SessionDetailPane extends StatelessWidget {
  const SessionDetailPane({super.key, required this.row, this.settings});

  final SessionRowViewModel row;
  final AppSettings? settings;

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
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Selected: ${row.title}'),
          const SizedBox(height: 8),
          Text(row.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          _MetadataGrid(row: row),
          const SizedBox(height: 16),
          _ActionArea(row: row, commandSet: commandSet),
          const SizedBox(height: 16),
          CommandPreview(commandSet: commandSet),
          const SizedBox(height: 16),
          Text('Conversation', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SizedBox(
            height: 420,
            child: ConversationView(messages: row.conversationMessages),
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
      spacing: 16,
      runSpacing: 8,
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
        _DetailText('User messages', row.userMessageCount.toString()),
        _DetailText('Assistant messages', row.assistantMessageCount.toString()),
        _DetailText('Tool calls', row.toolCallCount.toString()),
        _DetailText(
          'Tokens',
          '${row.inputTokens} input, ${row.outputTokens} output, '
              '${row.cachedInputTokens} cached, ${row.totalTokens} total',
        ),
        _DetailText('Models', row.modelsUsedForDetail.join(', ')),
        _DetailText('Status', row.status),
        _DetailText('Tags', row.tags.join(', ')),
        _DetailText('Pinned', row.isPinned ? 'Yes' : 'No'),
        _DetailText('Archived', row.isArchived ? 'Yes' : 'No'),
      ],
    );
  }
}

class _DetailText extends StatelessWidget {
  const _DetailText(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 320,
      child: Text('$label: $value', overflow: TextOverflow.ellipsis),
    );
  }
}

class _ActionArea extends StatelessWidget {
  const _ActionArea({required this.row, required this.commandSet});

  final SessionRowViewModel row;
  final ResumeCommandSet commandSet;

  @override
  Widget build(BuildContext context) {
    final canResume = commandSet.canResume;
    final terminalEnabled = commandSet.terminalLaunchCommand != null;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _action('Copy session path'),
        _action('Copy working directory'),
        _action('Copy plain resume command', enabled: canResume),
        _action(
          'Copy platform resume command',
          enabled: commandSet.platformResumeCommand != null,
        ),
        _action('Open containing folder'),
        _action('Open terminal here'),
        _action('Open in terminal and resume', enabled: terminalEnabled),
        _action('Copy terminal launch command', enabled: terminalEnabled),
        _action('Export Markdown'),
        _action('Copy conversation Markdown'),
        _action('Re-parse this session'),
        _action(row.isPinned ? 'Unpin session' : 'Pin session'),
        _action(row.isArchived ? 'Unarchive session' : 'Archive session'),
        _action('Add/remove tags'),
        _action('Assign/change project'),
      ],
    );
  }

  Widget _action(String label, {bool enabled = true}) {
    return OutlinedButton(
      onPressed: enabled ? () {} : null,
      child: Text(label),
    );
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
