import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../accessibility/announcement_service.dart';
import '../../config/app_settings.dart';
import '../models/conversation_message_view_model.dart';
import '../motion.dart';
import 'svg_icon.dart';

typedef CopyTextCallback = Future<void> Function(String text);
typedef ConversationPositionChanged =
    void Function(ConversationPositionState position);

enum ToolCallVisibility { show, collapse, hide }

class ConversationPositionState {
  const ConversationPositionState({
    required this.messageNumber,
    required this.wasNearBottom,
    required this.messageCount,
  });

  final int messageNumber;
  final bool wasNearBottom;
  final int messageCount;
}

class ConversationView extends StatefulWidget {
  const ConversationView({
    super.key,
    required this.messages,
    this.onCopyMessageMarkdown,
    this.motionMode = AppMotionMode.system,
    this.initialToolCallVisibility = ToolCallVisibility.collapse,
    this.initialMessageNumber,
    this.onPositionChanged,
    this.announcer,
  });

  final List<ConversationMessageViewModel> messages;
  final CopyTextCallback? onCopyMessageMarkdown;
  final AppMotionMode motionMode;
  final ToolCallVisibility initialToolCallVisibility;
  final int? initialMessageNumber;
  final ConversationPositionChanged? onPositionChanged;
  final ScreenReaderAnnouncer? announcer;

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  final _messageListController = ScrollController();
  var _selectedNumber = 1;
  late ToolCallVisibility _toolCallVisibility;
  final _expanded = <String>{};
  var _lastVisibleMessageCount = 0;
  var _showJumpToNewest = false;

  @override
  void initState() {
    super.initState();
    _toolCallVisibility = widget.initialToolCallVisibility;
    _lastVisibleMessageCount = _visibleMessages.length;
    _selectedNumber = _initialSelectedNumber(_visibleMessages);
    _scrollToSelectedMessage();
  }

  @override
  void didUpdateWidget(covariant ConversationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final wasNearBottom = _isNearBottom();
    final visibleCount = _visibleMessages.length;
    if (widget.initialMessageNumber != oldWidget.initialMessageNumber) {
      _selectedNumber = _initialSelectedNumber(_visibleMessages);
      _scrollToSelectedMessage();
    } else if (!_visibleMessages.any(
      (message) => message.number == _selectedNumber,
    )) {
      _selectedNumber = _initialSelectedNumber(_visibleMessages);
      _scrollToSelectedMessage();
    }
    if (visibleCount > _lastVisibleMessageCount) {
      if (wasNearBottom) {
        _showJumpToNewest = false;
        final messages = _visibleMessages;
        if (messages.isNotEmpty) {
          _selectedNumber = messages.last.number;
        }
        _scrollMessagesToBottom();
        _notifyPositionChanged();
      } else {
        if (!_showJumpToNewest) {
          unawaited(
            widget.announcer?.announce(
              'Newer messages are available. Use Jump to newest to read them.',
            ),
          );
        }
        _showJumpToNewest = true;
      }
    }
    _lastVisibleMessageCount = visibleCount;
  }

  int _initialSelectedNumber(List<ConversationMessageViewModel> messages) {
    final initialNumber = widget.initialMessageNumber;
    if (initialNumber != null &&
        messages.any((message) => message.number == initialNumber)) {
      return initialNumber;
    }
    if (messages.isEmpty) {
      return 1;
    }
    return messages.last.number;
  }

  @override
  void dispose() {
    _messageListController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = _visibleMessages;
    final motionPolicy = CodexMotionPolicy.fromContext(
      context,
      mode: widget.motionMode,
    );
    if (messages.isEmpty) {
      return const Center(child: Text('No conversation messages'));
    }
    final selected = _selectedMessage(messages);
    return Semantics(
      key: const Key('conversation-view-semantics'),
      container: true,
      explicitChildNodes: true,
      label: 'Conversation view',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 230,
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
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text('Selected message ${selected.number}'),
                      Semantics(
                        label: 'Tool call visibility filter',
                        child: SegmentedButton<ToolCallVisibility>(
                          segments: const [
                            ButtonSegment(
                              value: ToolCallVisibility.show,
                              label: Text('Show tools'),
                            ),
                            ButtonSegment(
                              value: ToolCallVisibility.collapse,
                              label: Text('Collapse tools'),
                            ),
                            ButtonSegment(
                              value: ToolCallVisibility.hide,
                              label: Text('Hide tools'),
                            ),
                          ],
                          selected: {_toolCallVisibility},
                          onSelectionChanged: (selection) {
                            setState(() {
                              _toolCallVisibility = selection.single;
                              final visibleAfterChange = _messagesForVisibility(
                                _toolCallVisibility,
                              );
                              _lastVisibleMessageCount =
                                  visibleAfterChange.length;
                              if (!visibleAfterChange.any(
                                (message) => message.number == _selectedNumber,
                              )) {
                                if (visibleAfterChange.isNotEmpty) {
                                  _selectedNumber =
                                      visibleAfterChange.first.number;
                                }
                              }
                            });
                          },
                        ),
                      ),
                      if (_showJumpToNewest)
                        Semantics(
                          label: 'Jump to newest message',
                          button: true,
                          child: FilledButton.icon(
                            onPressed: _jumpToNewest,
                            icon: const Icon(Icons.keyboard_arrow_down),
                            label: const Text('Jump to newest'),
                          ),
                        ),
                    ],
                  ),
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
                        toolCallVisibility: _toolCallVisibility,
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

  List<ConversationMessageViewModel> get _visibleMessages {
    return _messagesForVisibility(_toolCallVisibility);
  }

  List<ConversationMessageViewModel> _messagesForVisibility(
    ToolCallVisibility visibility,
  ) {
    return widget.messages
        .where((message) {
          if (visibility != ToolCallVisibility.hide) {
            return true;
          }
          if (!message.hasToolOutput &&
              message.author != ConversationAuthor.tool) {
            return true;
          }
          return message.hasError;
        })
        .toList(growable: false);
  }

  ConversationMessageViewModel _selectedMessage(
    List<ConversationMessageViewModel> messages,
  ) {
    return messages.firstWhere(
      (message) => message.number == _selectedNumber,
      orElse: () => messages.first,
    );
  }

  void _selectMessage(int number) {
    final messages = _visibleMessages;
    final index = messages.indexWhere((message) => message.number == number);
    if (index < 0) {
      return;
    }
    setState(() {
      _selectedNumber = number;
    });
    _notifyPositionChanged();
    if (_messageListController.hasClients) {
      _messageListController.animateTo(
        index * 210,
        duration: const Duration(milliseconds: 1),
        curve: Curves.linear,
      );
    }
  }

  void _jumpToNewest() {
    final messages = _visibleMessages;
    if (messages.isEmpty) {
      return;
    }
    setState(() {
      _selectedNumber = messages.last.number;
      _showJumpToNewest = false;
    });
    _scrollMessagesToBottom();
    _notifyPositionChanged();
  }

  void _scrollToSelectedMessage() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_messageListController.hasClients) {
        return;
      }
      final messages = _visibleMessages;
      final index = messages.indexWhere(
        (message) => message.number == _selectedNumber,
      );
      if (index < 0) {
        return;
      }
      _messageListController.jumpTo(
        (index * 210)
            .clamp(0, _messageListController.position.maxScrollExtent)
            .toDouble(),
      );
    });
  }

  void _notifyPositionChanged() {
    final messages = _visibleMessages;
    widget.onPositionChanged?.call(
      ConversationPositionState(
        messageNumber: _selectedNumber,
        wasNearBottom: _isNearBottom(),
        messageCount: messages.length,
      ),
    );
  }

  bool _isNearBottom() {
    if (!_messageListController.hasClients) {
      return true;
    }
    final position = _messageListController.position;
    return position.maxScrollExtent - position.pixels <= 80;
  }

  void _scrollMessagesToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_messageListController.hasClients) {
        return;
      }
      _messageListController.animateTo(
        _messageListController.position.maxScrollExtent,
        duration: CodexMotionDurations.fast,
        curve: Curves.easeOut,
      );
    });
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
              '#${message.number} ${message.authorLabel}, ${message.tokenLabel}',
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
                message.tokenLabel,
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
    required this.toolCallVisibility,
    required this.motionPolicy,
    required this.onCopyMarkdown,
    required this.onToggleExpanded,
  });

  final ConversationMessageViewModel message;
  final bool expanded;
  final bool selected;
  final ToolCallVisibility toolCallVisibility;
  final CodexMotionPolicy motionPolicy;
  final CopyTextCallback? onCopyMarkdown;
  final VoidCallback onToggleExpanded;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bodyLoaded = message.isBodyLoaded;
    final collapsedToolOutput =
        bodyLoaded &&
        message.hasToolOutput &&
        toolCallVisibility == ToolCallVisibility.collapse &&
        !expanded;
    final collapsedLongMessage = bodyLoaded && message.isLong && !expanded;
    final body = collapsedToolOutput || collapsedLongMessage
        ? message.preview
        : message.body;
    final semanticsBody = bodyLoaded ? body : 'Message body not loaded yet.';
    return Semantics(
      container: true,
      label: _messageSemanticsLabel(
        message,
        collapsedToolOutput
            ? 'Tool output collapsed, ${message.lineCount} lines.'
            : semanticsBody,
      ),
      explicitChildNodes: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
        child: DecoratedBox(
          key: Key('message-card-${message.number}'),
          decoration: BoxDecoration(
            color: scheme.surface,
            border: Border.all(
              color: selected ? scheme.primary : scheme.outline,
              width: selected ? 2 : 1,
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
                if (!bodyLoaded)
                  Semantics(
                    label: 'Message body not loaded yet.',
                    container: true,
                    readOnly: true,
                    child: const Text('Message body not loaded yet.'),
                  )
                else if (collapsedToolOutput)
                  CodexMotion.expandCollapse(
                    policy: motionPolicy,
                    child: Semantics(
                      label:
                          'Tool output collapsed, ${message.lineCount} lines. Use the Expand tool output button to show it.',
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
                      child: Semantics(
                        container: true,
                        label: body,
                        readOnly: true,
                        child: ExcludeSemantics(
                          child: SingleChildScrollView(
                            child: SelectableText(body),
                          ),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (bodyLoaded && (message.isLong || message.hasToolOutput))
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
                    if (bodyLoaded)
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
      ConversationAuthor.reasoning => scheme.outline,
      ConversationAuthor.system => scheme.inverseSurface,
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
    ConversationAuthor.reasoning => AppIcons.messageAssistant,
    ConversationAuthor.system => AppIcons.messageAssistant,
  };
}

extension on DateTime {
  String get shortTime {
    final local = toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }
}
