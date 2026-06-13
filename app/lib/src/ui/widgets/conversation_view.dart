import 'package:flutter/material.dart';

import '../models/conversation_message_view_model.dart';

class ConversationView extends StatefulWidget {
  const ConversationView({super.key, required this.messages});

  final List<ConversationMessageViewModel> messages;

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
                    itemExtent: 210,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      return _ConversationMessageCard(
                        key: ValueKey(message.id),
                        message: message,
                        expanded: _expanded.contains(message.id),
                        selected: message.number == _selectedNumber,
                        onToggleExpanded: () {
                          setState(() {
                            if (!_expanded.add(message.id)) {
                              _expanded.remove(message.id);
                            }
                          });
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
    required this.onToggleExpanded,
  });

  final ConversationMessageViewModel message;
  final bool expanded;
  final bool selected;
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
      label: 'Message ${message.number} ${message.authorLabel}',
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
                Text('#${message.number} ${message.authorLabel}'),
                const SizedBox(height: 6),
                if (collapsedToolOutput)
                  Semantics(
                    label:
                        'Tool output collapsed, ${message.lineCount} lines. Press Enter to expand.',
                    button: true,
                    container: true,
                    child: ExcludeSemantics(
                      child: Text(
                        'Tool output collapsed, ${message.lineCount} lines.',
                      ),
                    ),
                  )
                else
                  Expanded(
                    child: SingleChildScrollView(child: SelectableText(body)),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    if (message.isLong || message.hasToolOutput)
                      OutlinedButton(
                        onPressed: onToggleExpanded,
                        child: Text(
                          expanded
                              ? 'Collapse'
                              : message.hasToolOutput
                              ? 'Expand tool output'
                              : 'Show full message',
                        ),
                      ),
                    OutlinedButton(
                      onPressed: () {},
                      child: const Text('Copy message Markdown'),
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
}

extension on DateTime {
  String get shortTime {
    final local = toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}';
  }
}
