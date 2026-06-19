import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../accessibility/announcement_service.dart';
import '../../config/app_settings.dart';
import '../models/conversation_message_view_model.dart';
import '../motion.dart';
import 'svg_icon.dart';

typedef CopyTextCallback = Future<void> Function(String text);

class ConversationView extends StatefulWidget {
  const ConversationView({
    super.key,
    required this.messages,
    this.onCopyMessageMarkdown,
    this.motionMode = AppMotionMode.system,
    this.announcer,
  });

  final List<ConversationMessageViewModel> messages;
  final CopyTextCallback? onCopyMessageMarkdown;
  final AppMotionMode motionMode;
  final ScreenReaderAnnouncer? announcer;

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  final _messageListController = ScrollController();
  var _selectedNumber = 1;
  final _expanded = <String>{};

  @override
  void dispose() {
    _messageListController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.messages;
    final motionPolicy = CodexMotionPolicy.fromContext(
      context,
      mode: widget.motionMode,
    );
    if (messages.isEmpty) {
      return const Center(child: Text('No conversation messages'));
    }
    final selected = _selectedMessage;
    return Semantics(
      key: const Key('conversation-view-semantics'),
      container: true,
      explicitChildNodes: true,
      label: 'Conversation view',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 260,
            child: _MessageIndex(
              messages: messages,
              selectedNumber: _selectedNumber,
              onSelect: _selectMessage,
            ),
          ),
          VerticalDivider(
            width: 1,
            thickness: 1,
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text('Selected message ${selected.number}'),
                ),
                Expanded(
                  child: ListView.builder(
                    controller: _messageListController,
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      return _ConversationMessageCard(
                        key: ValueKey(message.id),
                        message: message,
                        expanded: _expanded.contains(message.id),
                        selected: message.number == _selectedNumber,
                        motionPolicy: motionPolicy,
                        onCopyMarkdown: widget.onCopyMessageMarkdown,
                        onToggleExpanded: () {
                          final willExpand = !_expanded.contains(message.id);
                          setState(() {
                            if (!_expanded.add(message.id)) {
                              _expanded.remove(message.id);
                            }
                          });
                          unawaited(
                            widget.announcer?.announce(
                              willExpand
                                  ? 'Tool output expanded for message ${message.number}.'
                                  : 'Tool output collapsed for message ${message.number}.',
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  ConversationMessageViewModel get _selectedMessage {
    return widget.messages.firstWhere(
      (message) => message.number == _selectedNumber,
      orElse: () => widget.messages.first,
    );
  }

  void _selectMessage(int number) {
    final index = widget.messages.indexWhere(
      (message) => message.number == number,
    );
    if (index < 0) {
      return;
    }
    setState(() {
      _selectedNumber = number;
    });
    if (_messageListController.hasClients) {
      _messageListController.animateTo(
        index * 210,
        duration: const Duration(milliseconds: 1),
        curve: Curves.linear,
      );
    }
  }
}

class _MessageIndex extends StatelessWidget {
  const _MessageIndex({
    required this.messages,
    required this.selectedNumber,
    required this.onSelect,
  });

  final List<ConversationMessageViewModel> messages;
  final int selectedNumber;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final selected = message.number == selectedNumber;
        final markers = [
          if (message.hasToolOutput) 'tool',
          if (message.hasError) 'error',
        ].join(', ');
        return Semantics(
          label:
              '#${message.number} ${message.authorLabel}, ${message.tokenCount} tokens',
          button: true,
          selected: selected,
          child: ListTile(
            leading: _MessageKindIcon(
              key: Key('message-index-icon-${message.number}'),
              message: message,
              selected: selected,
            ),
            selected: selected,
            dense: true,
            title: Text('#${message.number} ${message.authorLabel}'),
            subtitle: Text(
              [
                message.createdAtUtc.shortTime,
                message.preview,
                '${message.tokenCount} tokens',
                if (markers.isNotEmpty) markers,
              ].join(' | '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => onSelect(message.number),
          ),
        );
      },
    );
  }
}

class _ConversationMessageCard extends StatelessWidget {
  const _ConversationMessageCard({
    super.key,
    required this.message,
    required this.expanded,
    required this.selected,
    required this.motionPolicy,
    required this.onCopyMarkdown,
    required this.onToggleExpanded,
  });

  final ConversationMessageViewModel message;
  final bool expanded;
  final bool selected;
  final CodexMotionPolicy motionPolicy;
  final CopyTextCallback? onCopyMarkdown;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final collapsedToolOutput = message.hasToolOutput && !expanded;
    final collapsedLongMessage = message.isLong && !expanded;
    final body = collapsedToolOutput || collapsedLongMessage
        ? message.preview
        : message.body;
    return Semantics(
      container: true,
      label: _messageSemanticsLabel(
        message,
        collapsedToolOutput
            ? 'Tool output collapsed, ${message.lineCount} lines.'
            : body,
      ),
      explicitChildNodes: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? scheme.primaryContainer : scheme.surface,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outline,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _MessageKindIcon(
                      key: Key('message-card-icon-${message.number}'),
                      message: message,
                      selected: selected,
                    ),
                    const SizedBox(width: 8),
                    Text('#${message.number} ${message.authorLabel}'),
                  ],
                ),
                const SizedBox(height: 6),
                if (collapsedToolOutput)
                  CodexMotion.expandCollapse(
                    policy: motionPolicy,
                    child: Semantics(
                      label:
                          'Tool output collapsed, ${message.lineCount} lines. Press Enter to expand.',
                      button: true,
                      container: true,
                      child: ExcludeSemantics(
                        child: Text(
                          'Tool output collapsed, ${message.lineCount} lines.',
                        ),
                      ),
                    ),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 150),
                    child: CodexMotion.expandCollapse(
                      policy: motionPolicy,
                      child: SingleChildScrollView(child: SelectableText(body)),
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (message.isLong || message.hasToolOutput)
                      OutlinedButton.icon(
                        onPressed: onToggleExpanded,
                        icon: AppSvgIcon(
                          expanded ? AppIcons.collapse : AppIcons.expand,
                        ),
                        label: Text(
                          expanded
                              ? 'Collapse'
                              : message.hasToolOutput
                              ? 'Expand tool output'
                              : 'Show full message',
                        ),
                      ),
                    OutlinedButton.icon(
                      onPressed: () => _copyMarkdown(context),
                      icon: const AppSvgIcon(AppIcons.copy),
                      label: const Text('Copy message Markdown'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _copyMarkdown(BuildContext context) async {
    final callback = onCopyMarkdown;
    final text = _messageMarkdown(message);
    if (callback != null) {
      await callback(text);
    } else {
      await Clipboard.setData(ClipboardData(text: text));
    }
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Message Markdown copied.')));
  }

  String _messageMarkdown(ConversationMessageViewModel message) {
    return [
      '### Message ${message.number} - ${message.authorLabel}',
      '',
      message.body,
      '',
    ].join('\n');
  }

  String _messageSemanticsLabel(
    ConversationMessageViewModel message,
    String body,
  ) {
    final normalizedBody = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalizedBody.isEmpty) {
      return 'Message ${message.number} ${message.authorLabel}. Empty message.';
    }
    final readableBody = normalizedBody.length <= 1000
        ? normalizedBody
        : '${normalizedBody.substring(0, 1000)} truncated.';
    return 'Message ${message.number} ${message.authorLabel}. $readableBody';
  }
}

class _MessageKindIcon extends StatelessWidget {
  const _MessageKindIcon({
    super.key,
    required this.message,
    required this.selected,
  });

  final ConversationMessageViewModel message;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = switch (message.author) {
      ConversationAuthor.user => scheme.primary,
      ConversationAuthor.assistant => scheme.tertiary,
      ConversationAuthor.tool => scheme.secondary,
    };
    final background = selected
        ? color.withValues(alpha: 0.22)
        : color.withValues(alpha: 0.12);
    return Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: AppSvgIcon(_messageIcon(message.author), size: 15, color: color),
    );
  }
}

String _messageIcon(ConversationAuthor author) {
  return switch (author) {
    ConversationAuthor.user => AppIcons.messageUser,
    ConversationAuthor.assistant => AppIcons.messageAssistant,
    ConversationAuthor.tool => AppIcons.messageTool,
  };
}

extension on DateTime {
  String get shortTime {
    final local = toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }
}
