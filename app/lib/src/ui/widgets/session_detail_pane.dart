import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../commands/resume_command_generator.dart';
import '../../config/app_settings.dart';
import '../../utils/injected_context_filter.dart';
import '../models/conversation_message_view_model.dart';
import '../models/session_row_view_model.dart';
import '../motion.dart';
import 'command_preview.dart';
import 'conversation_view.dart';
import 'focus_reader_view.dart';
import 'svg_icon.dart';

typedef DetailCopyCallback = Future<void> Function(String text);
typedef DetailMarkdownExportCallback =
    Future<void> Function(SessionRowViewModel row, String markdown);
typedef SessionDetailActionCallback =
    Future<void> Function(SessionDetailAction action);

enum SessionDetailAction {
  openContainingFolder,
  openTerminalHere,
  openTerminalResume,
  openTerminalFork,
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
    this.onExportMarkdown,
    this.onSessionAction,
    this.onRunTerminalCommand,
    this.onEditTerminalCommand,
    this.isLoadingMessages = false,
    this.initialConversationMessageNumber,
    this.onConversationPositionChanged,
  });

  final SessionRowViewModel row;
  final AppSettings? settings;
  final DetailCopyCallback? onCopyText;
  final DetailMarkdownExportCallback? onExportMarkdown;
  final SessionDetailActionCallback? onSessionAction;
  final TerminalCommandCallback? onRunTerminalCommand;
  final TerminalCommandCallback? onEditTerminalCommand;
  final bool isLoadingMessages;
  final int? initialConversationMessageNumber;
  final ConversationPositionChanged? onConversationPositionChanged;

  @override
  Widget build(BuildContext context) {
    final effectiveSettings = settings ?? AppSettings.defaults();
    final motionPolicy = CodexMotionPolicy.fromContext(
      context,
      mode: effectiveSettings.ui.motion,
    );
    final commandSet = ResumeCommandGenerator(settings: effectiveSettings)
        .build(
          ResumeCommandSession(
            sessionId: row.sessionId,
            sourceType: switch (row.platform) {
              SessionRowPlatform.windows => ResumeSessionSourceType.windows,
              SessionRowPlatform.wsl => ResumeSessionSourceType.wsl,
            },
            workingDirectory: row.workingDirectoryForCommands,
          ),
        );
    final visibleMessages = row.conversationMessages
        .where((message) => !_isInjectedContextMessage(message))
        .toList(growable: false);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SelectedSessionHeader(row: row),
          const SizedBox(height: 8),
          _ActionArea(
            row: row,
            commandSet: commandSet,
            onCopyText: onCopyText,
            onExportMarkdown: onExportMarkdown,
            onSessionAction: onSessionAction,
          ),
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text(
              'Details',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            subtitle: Text(_detailsSummary(row)),
            children: [_MetadataGrid(row: row)],
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
              CodexMotion.expandCollapse(
                policy: motionPolicy,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CommandActionPanel(
                      commandSet: commandSet,
                      onCopyText: onCopyText,
                      onSessionAction: onSessionAction,
                      onRunTerminalCommand: onRunTerminalCommand,
                      onEditTerminalCommand: onEditTerminalCommand,
                    ),
                    const SizedBox(height: 8),
                    ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: EdgeInsets.zero,
                      title: const Text('Show command preview'),
                      children: [
                        CommandPreview(
                          commandSet: commandSet,
                          onRunTerminalCommand: onRunTerminalCommand,
                          onEditTerminalCommand: onEditTerminalCommand,
                          showInlineActions: false,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (isLoadingMessages)
            Semantics(
              liveRegion: true,
              container: true,
              excludeSemantics: true,
              label: 'Loading session conversation messages.',
              child: const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Loading conversation messages'),
                  ],
                ),
              ),
            ),
          if (isLoadingMessages && visibleMessages.isEmpty)
            const SizedBox(
              height: 420,
              child: Center(child: Text('Conversation messages loading')),
            )
          else
            _ConversationTabs(
              messages: visibleMessages,
              onCopyText: onCopyText,
              motionMode: effectiveSettings.ui.motion,
              initialMessageNumber: initialConversationMessageNumber,
              onPositionChanged: onConversationPositionChanged,
            ),
        ],
      ),
    );
  }

  String _detailsSummary(SessionRowViewModel row) {
    final duration =
        row.duration ?? row.lastMessageAtUtc.difference(row.startedAtUtc);
    return [
      row.status,
      row.displayTotalTokens > 0 ? '${row.displayTotalTokens} tokens' : null,
      '${row.messageCount} messages',
      duration.humanDuration,
    ].whereType<String>().join(' | ');
  }
}

class _SelectedSessionHeader extends StatelessWidget {
  const _SelectedSessionHeader({required this.row});

  final SessionRowViewModel row;

  @override
  Widget build(BuildContext context) {
    final title = row.threadName.trim().isNotEmpty
        ? row.threadName.trim()
        : row.title.trim().isEmpty
        ? row.project
        : row.title.trim();
    final duration =
        row.duration ?? row.lastMessageAtUtc.difference(row.startedAtUtc);
    return Semantics(
      header: true,
      label: 'Selected session $title',
      container: true,
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              _HeaderFact(row.platformLabel),
              _HeaderFact(row.originLabel),
              if (row.hasThreadName) _HeaderFact('Thread ${row.threadName}'),
              _HeaderFact(row.model.isEmpty ? 'Model unknown' : row.model),
              _HeaderFact('${row.messageCount} messages'),
              _HeaderFact('${row.displayTotalTokens} tokens'),
              if (row.usageRollup != null)
                _HeaderFact(row.displayEstimatedCost),
              _HeaderFact(row.lastMessageAtUtc.shortDateTime),
              _HeaderFact(duration.humanDuration),
              if (row.isPinned) const _HeaderFact('Pinned'),
              if (row.isArchived) const _HeaderFact('Archived'),
              if (row.hasError) const _HeaderFact('Errors'),
            ],
          ),
          const SizedBox(height: 6),
          Semantics(
            label: 'Working directory ${row.workingDirectoryForCommands}',
            readOnly: true,
            child: ExcludeSemantics(
              child: Tooltip(
                message: row.workingDirectoryForCommands,
                child: Text(
                  row.workingDirectoryForCommands,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConversationTabs extends StatelessWidget {
  const _ConversationTabs({
    required this.messages,
    required this.onCopyText,
    required this.motionMode,
    required this.initialMessageNumber,
    required this.onPositionChanged,
  });

  final List<ConversationMessageViewModel> messages;
  final DetailCopyCallback? onCopyText;
  final AppMotionMode motionMode;
  final int? initialMessageNumber;
  final ConversationPositionChanged? onPositionChanged;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            label: 'Conversation view selector',
            container: true,
            child: const TabBar(
              tabs: [
                Tab(text: 'Conversation'),
                Tab(text: 'Focus reader'),
              ],
            ),
          ),
          SizedBox(
            height: 420,
            child: TabBarView(
              children: [
                ConversationView(
                  messages: messages,
                  onCopyMessageMarkdown: onCopyText,
                  motionMode: motionMode,
                  initialMessageNumber: initialMessageNumber,
                  onPositionChanged: onPositionChanged,
                ),
                FocusReaderView(messages: messages, onCopyText: onCopyText),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderFact extends StatelessWidget {
  const _HeaderFact(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: text,
      readOnly: true,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Text(text, style: Theme.of(context).textTheme.bodySmall),
          ),
        ),
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
        _DetailText('Origin', row.originLabel),
        if (row.hasThreadName) _DetailText('Thread name', row.threadName),
        if (row.parentThreadId.isNotEmpty)
          _DetailText('Parent thread', row.parentThreadId),
        if (row.agentRole.isNotEmpty) _DetailText('Agent role', row.agentRole),
        if (row.subagentDepth != null)
          _DetailText('Subagent depth', row.subagentDepth.toString()),
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
        if (row.usageRollup case final rollup?) ...[
          _DetailText(
            'Usage total',
            '${rollup.totalTokens} tokens | ${rollup.totalEstimatedCostDisplay}',
          ),
          _DetailText(
            'Usage main',
            '${rollup.mainTokens} tokens | ${rollup.mainEstimatedCostDisplay}',
          ),
          _DetailText(
            'Usage subagents',
            '${rollup.subagentTokens} tokens | ${rollup.subagentEstimatedCostDisplay}',
          ),
        ],
        _DetailText('Total tokens', row.displayTotalTokens.toString()),
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
        _DetailText('Estimated cost', row.displayEstimatedCost),
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
    required this.onExportMarkdown,
    required this.onSessionAction,
  });

  final SessionRowViewModel row;
  final ResumeCommandSet commandSet;
  final DetailCopyCallback? onCopyText;
  final DetailMarkdownExportCallback? onExportMarkdown;
  final SessionDetailActionCallback? onSessionAction;

  @override
  Widget build(BuildContext context) {
    final hasConversation = row.conversationMessages.isNotEmpty;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _callbackAction(
          'Open containing folder',
          SessionDetailAction.openContainingFolder,
          enabled: row.canOpenContainingFolder,
          iconAsset: AppIcons.folderOpen,
          disabledReason:
              'This WSL path cannot be opened from Windows Explorer.',
        ),
        _callbackAction(
          'Export Markdown',
          SessionDetailAction.exportMarkdown,
          enabled: hasConversation && onExportMarkdown != null,
          iconAsset: AppIcons.export,
          disabledReason: hasConversation
              ? 'Markdown file export is not available yet.'
              : 'Conversation messages are not loaded yet.',
        ),
        _callbackAction(
          'Re-parse this session',
          SessionDetailAction.reparse,
          iconAsset: AppIcons.reparse,
        ),
        _callbackAction(
          row.isPinned ? 'Unpin session' : 'Pin session',
          SessionDetailAction.togglePin,
          iconAsset: AppIcons.pin,
        ),
        _callbackAction(
          row.isArchived ? 'Unarchive session' : 'Archive session',
          SessionDetailAction.toggleArchive,
          iconAsset: AppIcons.archive,
        ),
        PopupMenuButton<String>(
          tooltip: 'More actions for selected session',
          onSelected: (value) => _handleMoreAction(context, value),
          itemBuilder: (context) => [
            _moreItem('copy-session-path', 'Copy session path', AppIcons.copy),
            _moreItem(
              'copy-working-directory',
              'Copy working directory',
              AppIcons.copy,
            ),
            _moreItem(
              'copy-conversation-markdown',
              'Copy conversation Markdown',
              AppIcons.copy,
              enabled: hasConversation,
            ),
            _moreItem(
              'copy-plain-resume',
              'Copy plain resume command',
              AppIcons.copy,
              enabled: commandSet.plainResumeCommand != null,
            ),
            _moreItem(
              'copy-platform-resume',
              'Copy platform resume command',
              AppIcons.copy,
              enabled: commandSet.platformResumeCommand != null,
            ),
            _moreItem(
              'copy-terminal-command',
              'Copy terminal command',
              AppIcons.copy,
              enabled: commandSet.terminalLaunchCommand != null,
            ),
            _moreItem('edit-tags', 'Add/remove tags', AppIcons.tag),
            _moreItem(
              'assign-project',
              'Assign/change project',
              null,
              enabled: false,
              disabledReason: 'Project assignment is not available yet.',
            ),
          ],
          child: const Tooltip(
            message: 'More actions for selected session',
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text('More'),
            ),
          ),
        ),
      ],
    );
  }

  PopupMenuItem<String> _moreItem(
    String value,
    String label,
    String? iconAsset, {
    bool enabled = true,
    String? disabledReason,
  }) {
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (iconAsset != null) ...[
          AppSvgIcon(iconAsset),
          const SizedBox(width: 10),
        ],
        Flexible(
          child: Text(
            enabled || disabledReason == null
                ? label
                : '$label\n$disabledReason',
          ),
        ),
      ],
    );
    return PopupMenuItem<String>(value: value, enabled: enabled, child: child);
  }

  Future<void> _handleMoreAction(BuildContext context, String value) async {
    switch (value) {
      case 'copy-session-path':
        await _copyText(
          context,
          'Copied session path.',
          row.sourcePathForDisplay,
        );
        return;
      case 'copy-working-directory':
        await _copyText(
          context,
          'Copied working directory.',
          row.workingDirectoryForCommands,
        );
        return;
      case 'copy-conversation-markdown':
        await _copyText(
          context,
          'Copied conversation Markdown.',
          _conversationMarkdown(row),
        );
        return;
      case 'copy-plain-resume':
        final command = commandSet.plainResumeCommand;
        if (command != null) {
          await _copyText(context, 'Copied plain resume command.', command);
        }
        return;
      case 'copy-platform-resume':
        final command = commandSet.platformResumeCommand;
        if (command != null) {
          await _copyText(context, 'Copied platform resume command.', command);
        }
        return;
      case 'copy-terminal-command':
        final command = commandSet.terminalLaunchCommand;
        if (command != null) {
          await _copyText(context, 'Copied terminal command.', command);
        }
        return;
      case 'edit-tags':
        await _invokeAction(SessionDetailAction.editTags);
        return;
      case 'assign-project':
        await _invokeAction(SessionDetailAction.assignProject);
        return;
    }
  }

  Widget _callbackAction(
    String label,
    SessionDetailAction action, {
    bool enabled = true,
    String? disabledReason,
    String? iconAsset,
  }) {
    final onPressed = enabled && onSessionAction != null
        ? () => _invokeAction(action)
        : null;
    final button = iconAsset == null
        ? OutlinedButton(onPressed: onPressed, child: Text(label))
        : OutlinedButton.icon(
            onPressed: onPressed,
            icon: AppSvgIcon(iconAsset),
            label: Text(label),
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
    if (action == SessionDetailAction.exportMarkdown) {
      await _exportMarkdown();
      return;
    }
    final callback = onSessionAction;
    if (callback != null) {
      await callback(action);
    }
  }

  Future<void> _exportMarkdown() async {
    final callback = onExportMarkdown;
    if (callback != null) {
      await callback(row, _conversationMarkdown(row));
    }
  }

  String _conversationMarkdown(SessionRowViewModel row) {
    return [
      if (row.title.trim().isNotEmpty) ...['# ${row.title}', ''],
      for (final message in row.conversationMessages)
        if (!_isInjectedContextMessage(message)) ...[
          '## Message ${message.number} - ${message.authorLabel}',
          '',
          message.body,
          '',
        ],
    ].join('\n');
  }
}

class _CommandActionPanel extends StatelessWidget {
  const _CommandActionPanel({
    required this.commandSet,
    required this.onCopyText,
    required this.onSessionAction,
    required this.onRunTerminalCommand,
    required this.onEditTerminalCommand,
  });

  final ResumeCommandSet commandSet;
  final DetailCopyCallback? onCopyText;
  final SessionDetailActionCallback? onSessionAction;
  final TerminalCommandCallback? onRunTerminalCommand;
  final TerminalCommandCallback? onEditTerminalCommand;

  @override
  Widget build(BuildContext context) {
    final canResume = commandSet.canResume;
    final terminalEnabled = commandSet.terminalLaunchCommand != null;
    final terminalForkEnabled = commandSet.terminalForkCommand != null;
    final duplicatePlatformResumeCommand =
        commandSet.plainResumeCommand != null &&
        commandSet.plainResumeCommand == commandSet.platformResumeCommand;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        _copyAction(
          context,
          'Copy plain resume command',
          commandSet.plainResumeCommand,
          enabled: canResume,
          iconAsset: AppIcons.copy,
        ),
        if (!duplicatePlatformResumeCommand)
          _copyAction(
            context,
            'Copy platform resume command',
            commandSet.platformResumeCommand,
            enabled: commandSet.platformResumeCommand != null,
            iconAsset: AppIcons.copy,
          ),
        _callbackAction(
          'Open terminal here',
          SessionDetailAction.openTerminalHere,
          enabled: false,
          iconAsset: AppIcons.terminal,
          disabledReason:
              'Opening a terminal without resume is not available yet.',
        ),
        _callbackAction(
          'Open in terminal and resume',
          SessionDetailAction.openTerminalResume,
          enabled: terminalEnabled,
          iconAsset: AppIcons.terminal,
        ),
        _callbackAction(
          'Open in terminal and fork',
          SessionDetailAction.openTerminalFork,
          enabled: terminalForkEnabled,
          iconAsset: AppIcons.fork,
        ),
        _copyAction(
          context,
          'Copy terminal launch command',
          commandSet.terminalLaunchCommand,
          enabled: terminalEnabled,
          iconAsset: AppIcons.copy,
        ),
        _commandAction(
          'Run',
          enabled: terminalEnabled,
          iconAsset: AppIcons.play,
          onPressed: () => _runTerminalCommand(context),
        ),
        _commandAction(
          'Edit and run',
          enabled: terminalEnabled,
          iconAsset: AppIcons.edit,
          onPressed: () => _editTerminalCommand(context),
        ),
      ],
    );
  }

  Widget _copyAction(
    BuildContext context,
    String label,
    String? text, {
    bool enabled = true,
    required String iconAsset,
  }) {
    return OutlinedButton.icon(
      onPressed: enabled && text != null
          ? () => _copyText(context, _copySuccessMessage(label), text)
          : null,
      icon: AppSvgIcon(iconAsset),
      label: Text(label),
    );
  }

  Widget _callbackAction(
    String label,
    SessionDetailAction action, {
    bool enabled = true,
    String? disabledReason,
    String? iconAsset,
  }) {
    final onPressed = enabled && onSessionAction != null
        ? () => onSessionAction!(action)
        : null;
    final button = iconAsset == null
        ? OutlinedButton(onPressed: onPressed, child: Text(label))
        : OutlinedButton.icon(
            onPressed: onPressed,
            icon: AppSvgIcon(iconAsset),
            label: Text(label),
          );
    if (enabled || disabledReason == null) {
      return button;
    }
    return Tooltip(message: disabledReason, child: button);
  }

  Widget _commandAction(
    String label, {
    required bool enabled,
    required String iconAsset,
    required Future<void> Function() onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: enabled ? () => onPressed() : null,
      icon: AppSvgIcon(iconAsset),
      label: Text(label),
    );
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

  Future<void> _runTerminalCommand(BuildContext context) async {
    final command = commandSet.terminalLaunchCommand;
    if (command == null) {
      return;
    }
    final callback = onRunTerminalCommand;
    if (callback != null) {
      await callback(command);
    } else {
      final actionCallback = onSessionAction;
      if (actionCallback != null) {
        await actionCallback(SessionDetailAction.openTerminalResume);
      }
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Terminal command run requested.')),
      );
    }
  }

  Future<void> _editTerminalCommand(BuildContext context) async {
    final command = commandSet.terminalLaunchCommand;
    if (command == null) {
      return;
    }
    final controller = TextEditingController(text: command);
    final edited = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit terminal command'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(labelText: 'Command'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(controller.text),
            icon: const AppSvgIcon(AppIcons.play),
            label: const Text('Run'),
          ),
        ],
      ),
    );
    if (edited == null) {
      return;
    }
    final callback = onEditTerminalCommand ?? onRunTerminalCommand;
    if (callback != null) {
      await callback(edited);
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Edited terminal command run requested.')),
      );
    }
  }

  String _copySuccessMessage(String label) {
    return switch (label) {
      'Copy plain resume command' => 'Copied plain resume command.',
      'Copy platform resume command' => 'Copied platform resume command.',
      'Copy terminal launch command' => 'Copied terminal launch command.',
      _ => 'Copied.',
    };
  }
}

bool _isInjectedContextMessage(ConversationMessageViewModel message) {
  return message.author == ConversationAuthor.user &&
      isInjectedEnvironmentContextMessage(message.body);
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
