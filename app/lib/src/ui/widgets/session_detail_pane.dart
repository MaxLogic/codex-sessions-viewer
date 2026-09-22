import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../commands/resume_command_generator.dart';
import '../../config/app_settings.dart';
import '../../utils/injected_context_filter.dart';
import '../models/conversation_message_view_model.dart';
import '../models/session_row_view_model.dart';
import '../number_formatting.dart';
import 'command_preview.dart';
import 'conversation_view.dart';
import 'focus_reader_view.dart';
import 'session_stats_view.dart';
import 'svg_icon.dart';
import 'app_button.dart';

typedef DetailCopyCallback = Future<void> Function(String text);
typedef DetailMarkdownExportCallback =
    Future<void> Function(SessionRowViewModel row, String markdown);
typedef FullConversationMessagesLoader =
    Future<List<ConversationMessageViewModel>> Function(
      SessionRowViewModel row,
    );
typedef SessionDetailActionCallback =
    Future<void> Function(SessionDetailAction action);

enum SessionDetailAction {
  openContainingFolder,
  openTerminalResume,
  openTerminalFork,
  exportMarkdown,
  reparse,
  togglePin,
  toggleArchive,
  editTags,
  addToEvals,
  removeFromEvals,
  editEvalMetadata,
}

/// Tabs of the session detail pane, in display order.
enum SessionDetailTab { conversation, stats, details, focusReader }

class SessionDetailPane extends StatelessWidget {
  const SessionDetailPane({
    super.key,
    required this.row,
    this.settings,
    this.subagents = const [],
    this.parentRow,
    this.onOpenSession,
    this.loadActivity,
    this.onCopyText,
    this.onExportMarkdown,
    this.onLoadFullConversationMessages,
    this.onSessionAction,
    this.onRunTerminalCommand,
    this.onEditTerminalCommand,
    this.isLoadingMessages = false,
    this.initialConversationMessageNumber,
    this.onConversationPositionChanged,
    this.onLoadMessagePage,
    this.initialTab = SessionDetailTab.conversation,
    this.onTabChanged,
  });

  final SessionRowViewModel row;
  final AppSettings? settings;

  /// Subagent sessions spawned by [row].
  final List<SessionRowViewModel> subagents;

  /// The session that spawned [row], when [row] is a subagent.
  final SessionRowViewModel? parentRow;
  final ValueChanged<String>? onOpenSession;
  final SessionActivityLoader? loadActivity;
  final DetailCopyCallback? onCopyText;
  final DetailMarkdownExportCallback? onExportMarkdown;
  final FullConversationMessagesLoader? onLoadFullConversationMessages;
  final SessionDetailActionCallback? onSessionAction;
  final TerminalCommandCallback? onRunTerminalCommand;
  final TerminalCommandCallback? onEditTerminalCommand;
  final bool isLoadingMessages;
  final int? initialConversationMessageNumber;
  final ConversationPositionChanged? onConversationPositionChanged;
  final ConversationMessagePageLoader? onLoadMessagePage;

  /// The tab shown first. The sessions screen passes the tab the user last
  /// chose, so comparing stats across sessions keeps the Stats tab open.
  final SessionDetailTab initialTab;
  final ValueChanged<SessionDetailTab>? onTabChanged;

  @override
  Widget build(BuildContext context) {
    final effectiveSettings = settings ?? AppSettings.defaults();
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
    final fullLoader = onLoadFullConversationMessages;
    return DefaultTabController(
      length: SessionDetailTab.values.length,
      initialIndex: initialTab.index,
      child: Builder(
        builder: (context) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SelectedSessionHeader(
                      row: row,
                      parentRow: parentRow,
                      subagentCount: subagents.length,
                      onOpenSession: onOpenSession,
                    ),
                    const SizedBox(height: 10),
                    _ActionArea(
                      row: row,
                      commandSet: commandSet,
                      onCopyText: onCopyText,
                      onExportMarkdown: onExportMarkdown,
                      onLoadFullConversationMessages:
                          onLoadFullConversationMessages,
                      onSessionAction: onSessionAction,
                      onRunTerminalCommand: onRunTerminalCommand,
                      onEditTerminalCommand: onEditTerminalCommand,
                    ),
                  ],
                ),
              ),
              Semantics(
                label: 'Session detail view selector',
                container: true,
                child: TabBar(
                  onTap: (index) =>
                      onTabChanged?.call(SessionDetailTab.values[index]),
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    const Tab(text: 'Conversation'),
                    Tab(
                      text: subagents.isEmpty
                          ? 'Stats'
                          : 'Stats · ${subagents.length} subagents',
                    ),
                    const Tab(text: 'Details'),
                    const Tab(text: 'Focus reader'),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(
                child: TabBarView(
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _ConversationTab(
                      messages: visibleMessages,
                      isLoadingMessages: isLoadingMessages,
                      onCopyText: onCopyText,
                      motionMode: effectiveSettings.ui.motion,
                      initialMessageNumber: initialConversationMessageNumber,
                      onPositionChanged: onConversationPositionChanged,
                      onLoadMessagePage: onLoadMessagePage,
                      onLoadAllMessages: fullLoader == null
                          ? null
                          : () => fullLoader(row),
                    ),
                    SessionStatsView(
                      row: row,
                      subagents: subagents,
                      loadActivity:
                          loadActivity ?? loadSessionActivityFromFiles,
                      onOpenSession: onOpenSession,
                    ),
                    _DetailsTab(
                      row: row,
                      commandSet: commandSet,
                      onCopyText: onCopyText,
                      onSessionAction: onSessionAction,
                      onRunTerminalCommand: onRunTerminalCommand,
                      onEditTerminalCommand: onEditTerminalCommand,
                    ),
                    FocusReaderView(
                      messages: visibleMessages,
                      onCopyText: onCopyText,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SelectedSessionHeader extends StatelessWidget {
  const _SelectedSessionHeader({
    required this.row,
    required this.parentRow,
    required this.subagentCount,
    required this.onOpenSession,
  });

  final SessionRowViewModel row;
  final SessionRowViewModel? parentRow;
  final int subagentCount;
  final ValueChanged<String>? onOpenSession;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _sessionTitle(row);
    final duration =
        row.duration ?? row.lastMessageAtUtc.difference(row.startedAtUtc);
    final cost = row.displayEstimatedCost;
    final facts = <String>[
      if (row.project.trim().isNotEmpty && row.project.trim() != title)
        row.project.trim(),
      row.platformLabel,
      row.modelLabel,
      '${formatCompactInt(row.messageCount)} messages',
      '${formatCompactInt(row.displayTotalTokens)} tokens',
      if (row.usageRollup != null || !row.costUnknown) cost,
      duration.humanDuration,
      row.lastMessageAtUtc.shortDateTime,
    ];
    final badges = <String>[
      if (row.isSubagentSession) row.originLabel,
      if (row.isPinned) 'Pinned',
      if (row.isArchived) 'Archived',
      if (row.hasError) 'Errors',
      if (row.evalReady) 'Eval-ready',
      ...row.tags,
    ];
    final parent = parentRow;
    return Semantics(
      header: true,
      label: 'Selected session $title',
      container: true,
      explicitChildNodes: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleLarge,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (var i = 0; i < facts.length; i++) ...[
                if (i > 0) const _FactSeparator(),
                Text(
                  facts[i],
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              for (final badge in badges) _HeaderFact(badge),
            ],
          ),
          if (parent != null) ...[
            const SizedBox(height: 4),
            _LinkText(
              text: 'Spawned by: ${_sessionTitle(parent)}',
              semanticsLabel: 'Open parent session ${_sessionTitle(parent)}',
              onTap: onOpenSession == null
                  ? null
                  : () => onOpenSession!(parent.id),
            ),
          ],
          const SizedBox(height: 2),
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
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

String _sessionTitle(SessionRowViewModel row) {
  if (row.threadName.trim().isNotEmpty) {
    return row.threadName.trim();
  }
  if (row.title.trim().isNotEmpty) {
    return row.title.trim();
  }
  final nickname = row.agentNickname.trim();
  if (row.isSubagentSession && nickname.isNotEmpty) {
    return 'Subagent $nickname · ${row.project}';
  }
  return row.project;
}

class _FactSeparator extends StatelessWidget {
  const _FactSeparator();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Text(
        '·',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.outline,
        ),
      ),
    );
  }
}

class _LinkText extends StatelessWidget {
  const _LinkText({
    required this.text,
    required this.semanticsLabel,
    required this.onTap,
  });

  final String text;
  final String semanticsLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(
        color: onTap == null ? null : theme.colorScheme.primary,
        decoration: onTap == null ? null : TextDecoration.underline,
      ),
    );
    if (onTap == null) {
      return label;
    }
    return Semantics(
      label: semanticsLabel,
      button: true,
      onTap: onTap,
      child: ExcludeSemantics(
        child: InkWell(onTap: onTap, child: label),
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
            color: Theme.of(context).colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            child: Text(
              text,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: Theme.of(context).colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConversationTab extends StatelessWidget {
  const _ConversationTab({
    required this.messages,
    required this.isLoadingMessages,
    required this.onCopyText,
    required this.motionMode,
    required this.initialMessageNumber,
    required this.onPositionChanged,
    required this.onLoadMessagePage,
    required this.onLoadAllMessages,
  });

  final List<ConversationMessageViewModel> messages;
  final bool isLoadingMessages;
  final DetailCopyCallback? onCopyText;
  final AppMotionMode motionMode;
  final int? initialMessageNumber;
  final ConversationPositionChanged? onPositionChanged;
  final ConversationMessagePageLoader? onLoadMessagePage;
  final ConversationOlderMessagesLoader? onLoadAllMessages;

  @override
  Widget build(BuildContext context) {
    final loadingBanner = Semantics(
      liveRegion: true,
      container: true,
      excludeSemantics: true,
      label: 'Loading session conversation messages.',
      child: const Padding(
        padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 8),
            Text('Loading conversation messages'),
          ],
        ),
      ),
    );
    if (isLoadingMessages && messages.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          loadingBanner,
          const Expanded(
            child: Center(child: Text('Conversation messages loading')),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isLoadingMessages) loadingBanner,
        Expanded(
          child: ConversationView(
            messages: messages,
            onCopyMessageMarkdown: onCopyText,
            motionMode: motionMode,
            initialToolCallVisibility: ToolCallVisibility.hide,
            initialMessageNumber: initialMessageNumber,
            onPositionChanged: onPositionChanged,
            onLoadMessagePage: onLoadMessagePage,
            onLoadAllMessages: onLoadAllMessages,
          ),
        ),
      ],
    );
  }
}

class _DetailsTab extends StatelessWidget {
  const _DetailsTab({
    required this.row,
    required this.commandSet,
    required this.onCopyText,
    required this.onSessionAction,
    required this.onRunTerminalCommand,
    required this.onEditTerminalCommand,
  });

  final SessionRowViewModel row;
  final ResumeCommandSet commandSet;
  final DetailCopyCallback? onCopyText;
  final SessionDetailActionCallback? onSessionAction;
  final TerminalCommandCallback? onRunTerminalCommand;
  final TerminalCommandCallback? onEditTerminalCommand;

  @override
  Widget build(BuildContext context) {
    final duration =
        row.duration ?? row.lastMessageAtUtc.difference(row.startedAtUtc);
    final notes = row.evalNotes.trim();
    final expected = row.evalExpectedOutput.trim();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        const _DetailsHeading('Session'),
        _DetailGrid(
          children: [
            _DetailText('Platform', row.platformLabel),
            _DetailText('Origin', row.originLabel),
            _DetailText('Project', row.project),
            if (row.hasThreadName) _DetailText('Thread name', row.threadName),
            if (row.parentThreadId.isNotEmpty)
              _DetailText('Parent thread', row.parentThreadId),
            if (row.agentRole.isNotEmpty)
              _DetailText('Agent role', row.agentRole),
            if (row.subagentDepth != null)
              _DetailText(
                'Subagent depth',
                formatGroupedInt(row.subagentDepth!),
              ),
            _DetailText('Started', row.startedAtUtc.shortDateTime),
            _DetailText('Last message', row.lastMessageAtUtc.shortDateTime),
            _DetailText('Duration', duration.humanDuration),
            _DetailText('Status', row.status),
            _DetailText('Tags', row.tags.join(', ')),
            _DetailText('Pinned', row.isPinned ? 'Yes' : 'No'),
            _DetailText('Archived', row.isArchived ? 'Yes' : 'No'),
            _DetailText(
              'Models used',
              row.modelsUsedForDetail.isEmpty
                  ? 'Unknown'
                  : row.modelsUsedForDetail.join(', '),
              width: 532,
            ),
          ],
        ),
        const _DetailsHeading('Messages and tokens'),
        _DetailGrid(
          children: [
            _DetailText('Total messages', formatGroupedInt(row.messageCount)),
            _DetailText(
              'User message count',
              formatGroupedInt(row.userMessageCount),
            ),
            _DetailText(
              'Assistant message count',
              formatGroupedInt(row.assistantMessageCount),
            ),
            _DetailText('Tool call count', formatGroupedInt(row.toolCallCount)),
            if (row.usageRollup case final rollup?) ...[
              _DetailText(
                'Usage total',
                '${formatGroupedInt(rollup.totalTokens)} tokens | ${rollup.totalEstimatedCostDisplay}',
              ),
              _DetailText(
                'Usage main',
                '${formatGroupedInt(rollup.mainTokens)} tokens | ${rollup.mainEstimatedCostDisplay}',
              ),
              _DetailText(
                'Usage subagents',
                '${formatGroupedInt(rollup.subagentTokens)} tokens | ${rollup.subagentEstimatedCostDisplay}',
              ),
            ],
            _DetailText(
              'Total tokens',
              formatGroupedInt(row.displayTotalTokens),
            ),
            _DetailText('Input tokens', formatGroupedInt(row.inputTokens)),
            _DetailText('Output tokens', formatGroupedInt(row.outputTokens)),
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
          ],
        ),
        const _DetailsHeading('Paths'),
        _PathLine(
          label: 'Source file',
          value: row.sourcePathForDisplay,
          onCopyText: onCopyText,
        ),
        _PathLine(
          label: 'Display path',
          value: row.displayPathForDetail,
          onCopyText: onCopyText,
        ),
        _PathLine(
          label: 'Working directory',
          value: row.workingDirectoryForCommands,
          onCopyText: onCopyText,
        ),
        const _DetailsHeading('Resume commands'),
        _CommandActionPanel(
          commandSet: commandSet,
          onCopyText: onCopyText,
          onSessionAction: onSessionAction,
          onRunTerminalCommand: onRunTerminalCommand,
          onEditTerminalCommand: onEditTerminalCommand,
        ),
        const SizedBox(height: 12),
        CommandPreview(
          commandSet: commandSet,
          onRunTerminalCommand: onRunTerminalCommand,
          onEditTerminalCommand: onEditTerminalCommand,
          showInlineActions: false,
        ),
        const _DetailsHeading('Eval'),
        Semantics(
          container: true,
          label: 'Eval metadata ${row.evalStatusLabel}',
          child: _DetailGrid(
            children: [
              _DetailText('Eval-ready', row.evalReady ? 'Yes' : 'No'),
              _DetailText('Eval status', row.evalStatusLabel),
              if (notes.isNotEmpty) _DetailText('Notes', notes, width: 532),
              if (expected.isNotEmpty)
                _DetailText('Expected output', expected, width: 532),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _LabeledButton(
              semanticsLabel: row.evalReady
                  ? 'Remove selected session from evals'
                  : 'Add selected session to evals',
              label: row.evalReady ? 'Remove from Evals' : 'Add to Evals',
              onPressed: onSessionAction == null
                  ? null
                  : () => onSessionAction!(
                      row.evalReady
                          ? SessionDetailAction.removeFromEvals
                          : SessionDetailAction.addToEvals,
                    ),
            ),
            _LabeledButton(
              semanticsLabel: 'Edit eval metadata for selected session',
              label: 'Edit eval details',
              onPressed: onSessionAction == null
                  ? null
                  : () =>
                        onSessionAction!(SessionDetailAction.editEvalMetadata),
            ),
          ],
        ),
      ],
    );
  }

  String _tokensWithShare(SessionRowViewModel row, int tokens) {
    return '${formatGroupedInt(tokens)} (${row.tokenShareText(tokens)})';
  }
}

class _LabeledButton extends StatelessWidget {
  const _LabeledButton({
    required this.semanticsLabel,
    required this.label,
    required this.onPressed,
  });

  final String semanticsLabel;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      button: true,
      enabled: onPressed != null,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: OutlinedButton(onPressed: onPressed, child: Text(label)),
      ),
    );
  }
}

class _DetailsHeading extends StatelessWidget {
  const _DetailsHeading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Semantics(
        header: true,
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      ),
    );
  }
}

class _DetailGrid extends StatelessWidget {
  const _DetailGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Wrap(spacing: 12, runSpacing: 6, children: children);
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
      child: Tooltip(
        message: value,
        waitDuration: const Duration(milliseconds: 600),
        child: Text('$label: $value', overflow: TextOverflow.ellipsis),
      ),
    );
  }
}

class _PathLine extends StatelessWidget {
  const _PathLine({
    required this.label,
    required this.value,
    required this.onCopyText,
  });

  final String label;
  final String value;
  final DetailCopyCallback? onCopyText;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Tooltip(
            message: value,
            waitDuration: const Duration(milliseconds: 600),
            child: Text(
              '$label: $value',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copy ${label.toLowerCase()}',
          visualDensity: VisualDensity.compact,
          onPressed: value.trim().isEmpty
              ? null
              : () => _copyWithFeedback(
                  context,
                  onCopyText,
                  value,
                  'Copied ${label.toLowerCase()}.',
                ),
          icon: const AppSvgIcon(AppIcons.copy),
        ),
      ],
    );
  }
}

Future<void> _copyWithFeedback(
  BuildContext context,
  DetailCopyCallback? callback,
  String text,
  String message,
) async {
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

/// The always-visible action row: the few actions used on almost every visit,
/// with everything else in the More menu.
class _ActionArea extends StatelessWidget {
  const _ActionArea({
    required this.row,
    required this.commandSet,
    required this.onCopyText,
    required this.onExportMarkdown,
    required this.onLoadFullConversationMessages,
    required this.onSessionAction,
    required this.onRunTerminalCommand,
    required this.onEditTerminalCommand,
  });

  final SessionRowViewModel row;
  final ResumeCommandSet commandSet;
  final DetailCopyCallback? onCopyText;
  final DetailMarkdownExportCallback? onExportMarkdown;
  final FullConversationMessagesLoader? onLoadFullConversationMessages;
  final SessionDetailActionCallback? onSessionAction;
  final TerminalCommandCallback? onRunTerminalCommand;
  final TerminalCommandCallback? onEditTerminalCommand;

  @override
  Widget build(BuildContext context) {
    final hasConversation = row.conversationMessages.isNotEmpty;
    final resumeCommand =
        commandSet.platformResumeCommand ?? commandSet.plainResumeCommand;
    final canRunTerminal =
        commandSet.terminalLaunchCommand != null && onSessionAction != null;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Tooltip(
          message: canRunTerminal
              ? 'Open a terminal in the working directory and resume'
              : commandSet.terminalDisabledReason ??
                    commandSet.disabledReason ??
                    'Terminal resume is not available.',
          child: AppButton.filled(
            onPressed: canRunTerminal
                ? () => onSessionAction!(SessionDetailAction.openTerminalResume)
                : null,
            icon: const AppSvgIcon(AppIcons.terminal),
            label: const Text('Resume in terminal'),
          ),
        ),
        AppButton.outlined(
          onPressed: resumeCommand == null
              ? null
              : () => _copyWithFeedback(
                  context,
                  onCopyText,
                  resumeCommand,
                  'Copied resume command.',
                ),
          icon: const AppSvgIcon(AppIcons.copy),
          label: const Text('Copy resume command'),
        ),
        _callbackAction(
          row.isPinned ? 'Unpin session' : 'Pin session',
          SessionDetailAction.togglePin,
          iconAsset: AppIcons.pin,
          shortLabel: row.isPinned ? 'Unpin' : 'Pin',
        ),
        _callbackAction(
          row.isArchived ? 'Unarchive session' : 'Archive session',
          SessionDetailAction.toggleArchive,
          iconAsset: AppIcons.archive,
          shortLabel: row.isArchived ? 'Unarchive' : 'Archive',
        ),
        PopupMenuButton<String>(
          tooltip: 'More actions for selected session',
          onSelected: (value) => _handleMoreAction(context, value),
          itemBuilder: (context) => [
            _moreItem(
              'open-folder',
              'Open containing folder',
              AppIcons.folderOpen,
              enabled: row.canOpenContainingFolder && onSessionAction != null,
              disabledReason:
                  'This WSL path cannot be opened from Windows Explorer.',
            ),
            _moreItem(
              'fork',
              'Open in terminal and fork',
              AppIcons.fork,
              enabled:
                  commandSet.terminalForkCommand != null &&
                  onSessionAction != null,
            ),
            _moreItem(
              'edit-run',
              'Edit and run terminal command…',
              AppIcons.edit,
              enabled: commandSet.terminalLaunchCommand != null,
            ),
            const PopupMenuDivider(),
            _moreItem(
              'export-markdown',
              'Export Markdown…',
              AppIcons.export,
              enabled: hasConversation && onExportMarkdown != null,
              disabledReason: hasConversation
                  ? 'Markdown file export is not available yet.'
                  : 'Conversation messages are not loaded yet.',
            ),
            _moreItem(
              'copy-conversation-markdown',
              'Copy conversation Markdown',
              AppIcons.copy,
              enabled: hasConversation,
            ),
            _moreItem('copy-session-path', 'Copy session path', AppIcons.copy),
            _moreItem(
              'copy-working-directory',
              'Copy working directory',
              AppIcons.copy,
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
            const PopupMenuDivider(),
            _moreItem('edit-tags', 'Add/remove tags', AppIcons.tag),
            _moreItem(
              'toggle-eval',
              row.evalReady ? 'Remove from Evals' : 'Add to Evals',
              null,
            ),
            _moreItem('edit-eval', 'Edit eval details…', AppIcons.edit),
            _moreItem('reparse', 'Re-parse this session', AppIcons.reparse),
          ],
          child: const Tooltip(
            message: 'More actions for selected session',
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('More'),
                  SizedBox(width: 2),
                  Icon(Icons.arrow_drop_down, size: 18),
                ],
              ),
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
        SizedBox(
          width: 26,
          child: iconAsset == null ? null : AppSvgIcon(iconAsset),
        ),
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
      case 'open-folder':
        await _invokeAction(SessionDetailAction.openContainingFolder);
      case 'fork':
        await _invokeAction(SessionDetailAction.openTerminalFork);
      case 'edit-run':
        await _editTerminalCommand(
          context,
          commandSet,
          onEditTerminalCommand ?? onRunTerminalCommand,
        );
      case 'export-markdown':
        await _invokeAction(SessionDetailAction.exportMarkdown);
      case 'copy-session-path':
        await _copyWithFeedback(
          context,
          onCopyText,
          row.sourcePathForDisplay,
          'Copied session path.',
        );
      case 'copy-working-directory':
        await _copyWithFeedback(
          context,
          onCopyText,
          row.workingDirectoryForCommands,
          'Copied working directory.',
        );
      case 'copy-conversation-markdown':
        final markdown = await _conversationMarkdown(row);
        if (!context.mounted) {
          return;
        }
        await _copyWithFeedback(
          context,
          onCopyText,
          markdown,
          'Copied conversation Markdown.',
        );
      case 'copy-plain-resume':
        if (commandSet.plainResumeCommand case final command?) {
          await _copyWithFeedback(
            context,
            onCopyText,
            command,
            'Copied plain resume command.',
          );
        }
      case 'copy-platform-resume':
        if (commandSet.platformResumeCommand case final command?) {
          await _copyWithFeedback(
            context,
            onCopyText,
            command,
            'Copied platform resume command.',
          );
        }
      case 'copy-terminal-command':
        if (commandSet.terminalLaunchCommand case final command?) {
          await _copyWithFeedback(
            context,
            onCopyText,
            command,
            'Copied terminal command.',
          );
        }
      case 'edit-tags':
        await _invokeAction(SessionDetailAction.editTags);
      case 'toggle-eval':
        await _invokeAction(
          row.evalReady
              ? SessionDetailAction.removeFromEvals
              : SessionDetailAction.addToEvals,
        );
      case 'edit-eval':
        await _invokeAction(SessionDetailAction.editEvalMetadata);
      case 'reparse':
        await _invokeAction(SessionDetailAction.reparse);
    }
  }

  Widget _callbackAction(
    String label,
    SessionDetailAction action, {
    required String iconAsset,
    required String shortLabel,
  }) {
    final onPressed = onSessionAction != null
        ? () => _invokeAction(action)
        : null;
    return Semantics(
      label: label,
      button: true,
      enabled: onPressed != null,
      onTap: onPressed,
      child: ExcludeSemantics(
        child: Tooltip(
          message: label,
          child: AppButton.outlined(
            onPressed: onPressed,
            icon: AppSvgIcon(iconAsset),
            label: Text(shortLabel),
          ),
        ),
      ),
    );
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
      await callback(row, await _conversationMarkdown(row));
    }
  }

  Future<String> _conversationMarkdown(SessionRowViewModel row) async {
    return sessionConversationMarkdown(
      row,
      await _conversationMessagesForFullAction(row),
    );
  }

  Future<List<ConversationMessageViewModel>> _conversationMessagesForFullAction(
    SessionRowViewModel row,
  ) async {
    if (!row.conversationMessages.any((message) => !message.isBodyLoaded)) {
      return row.conversationMessages;
    }
    final loader = onLoadFullConversationMessages;
    if (loader == null) {
      return row.conversationMessages;
    }
    return loader(row);
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
        ),
        if (!duplicatePlatformResumeCommand)
          _copyAction(
            context,
            'Copy platform resume command',
            commandSet.platformResumeCommand,
            enabled: commandSet.platformResumeCommand != null,
          ),
        _copyAction(
          context,
          'Copy terminal launch command',
          commandSet.terminalLaunchCommand,
          enabled: terminalEnabled,
        ),
        AppButton.outlined(
          onPressed: terminalEnabled
              ? () => _runTerminalCommand(context)
              : null,
          icon: const AppSvgIcon(AppIcons.play),
          label: const Text('Run'),
        ),
        AppButton.outlined(
          onPressed: terminalEnabled
              ? () => _editTerminalCommand(
                  context,
                  commandSet,
                  onEditTerminalCommand ?? onRunTerminalCommand,
                )
              : null,
          icon: const AppSvgIcon(AppIcons.edit),
          label: const Text('Edit and run'),
        ),
        AppButton.outlined(
          onPressed: terminalForkEnabled && onSessionAction != null
              ? () => onSessionAction!(SessionDetailAction.openTerminalFork)
              : null,
          icon: const AppSvgIcon(AppIcons.fork),
          label: const Text('Open in terminal and fork'),
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
    return AppButton.outlined(
      onPressed: enabled && text != null
          ? () => _copyWithFeedback(
              context,
              onCopyText,
              text,
              _copySuccessMessage(label),
            )
          : null,
      icon: const AppSvgIcon(AppIcons.copy),
      label: Text(label),
    );
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

  String _copySuccessMessage(String label) {
    return switch (label) {
      'Copy plain resume command' => 'Copied plain resume command.',
      'Copy platform resume command' => 'Copied platform resume command.',
      'Copy terminal launch command' => 'Copied terminal launch command.',
      _ => 'Copied.',
    };
  }
}

Future<void> _editTerminalCommand(
  BuildContext context,
  ResumeCommandSet commandSet,
  TerminalCommandCallback? callback,
) async {
  final command = commandSet.terminalLaunchCommand;
  if (command == null) {
    return;
  }
  final controller = TextEditingController(text: command);
  final edited = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Edit terminal command'),
      content: SizedBox(
        width: 560,
        child: TextField(
          controller: controller,
          maxLines: 4,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Command'),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        AppButton.filled(
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
  if (callback != null) {
    await callback(edited);
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Edited terminal command run requested.')),
    );
  }
}

/// The Markdown written by Export Markdown and Copy conversation Markdown.
String sessionConversationMarkdown(
  SessionRowViewModel row,
  List<ConversationMessageViewModel> messages,
) {
  return [
    if (row.title.trim().isNotEmpty) ...['# ${row.title}', ''],
    for (final message in messages)
      if (!_isInjectedContextMessage(message)) ...[
        '## Message ${message.number} - ${message.authorLabel}',
        '',
        message.body,
        '',
      ],
  ].join('\n');
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
