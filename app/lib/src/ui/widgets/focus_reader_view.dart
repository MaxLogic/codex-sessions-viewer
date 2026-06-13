import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/conversation_message_view_model.dart';

class FocusReaderView extends StatefulWidget {
  const FocusReaderView({super.key, required this.messages});

  final List<ConversationMessageViewModel> messages;

  @override
  State<FocusReaderView> createState() => _FocusReaderViewState();
}

class _FocusReaderViewState extends State<FocusReaderView> {
  var _selectedIndex = 0;
  final _expanded = <String>{};

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return const Center(child: Text('No messages'));
    }
    final message = widget.messages[_selectedIndex];
    return Focus(
      autofocus: true,
      onKeyEvent: _handleKey,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Semantics(
              key: const Key('focus-reader-announcement'),
              liveRegion: true,
              container: true,
              excludeSemantics: true,
              label:
                  'Selected message ${_selectedIndex + 1} of ${widget.messages.length}. ${message.authorLabel}.',
              child: Text(
                'Message ${_selectedIndex + 1} of ${widget.messages.length}',
              ),
            ),
            const SizedBox(height: 8),
            _Metadata(message: message),
            const SizedBox(height: 12),
            Expanded(
              child: _MessageBody(
                message: message,
                expanded: _expanded.contains(message.id),
              ),
            ),
            const SizedBox(height: 12),
            _NavigationButtons(
              onPrevious: () => _moveRelative(-1),
              onNext: () => _moveRelative(1),
              onPreviousUser: () => _moveToPrevious(_isUser),
              onNextUser: () => _moveToNext(_isUser),
              onPreviousAssistant: () => _moveToPrevious(_isAssistant),
              onNextAssistant: () => _moveToNext(_isAssistant),
              onPreviousTool: () => _moveToPrevious(_isTool),
              onNextTool: () => _moveToNext(_isTool),
              onPreviousError: () => _moveToPrevious(_isToolOrError),
              onNextError: () => _moveToNext(_isToolOrError),
              onToggleToolOutput: message.hasToolOutput
                  ? () {
                      setState(() {
                        if (!_expanded.add(message.id)) {
                          _expanded.remove(message.id);
                        }
                      });
                    }
                  : null,
              expanded: _expanded.contains(message.id),
            ),
          ],
        ),
      ),
    );
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final shift = HardwareKeyboard.instance.isShiftPressed;
    if (event.logicalKey == LogicalKeyboardKey.keyU) {
      shift ? _moveToPrevious(_isUser) : _moveToNext(_isUser);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyA) {
      shift ? _moveToPrevious(_isAssistant) : _moveToNext(_isAssistant);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyT) {
      shift ? _moveToPrevious(_isTool) : _moveToNext(_isTool);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.keyE) {
      shift ? _moveToPrevious(_isToolOrError) : _moveToNext(_isToolOrError);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveRelative(int delta) {
    final next = (_selectedIndex + delta).clamp(0, widget.messages.length - 1);
    setState(() {
      _selectedIndex = next;
    });
  }

  void _moveToNext(bool Function(ConversationMessageViewModel) predicate) {
    for (var i = _selectedIndex + 1; i < widget.messages.length; i++) {
      if (predicate(widget.messages[i])) {
        setState(() {
          _selectedIndex = i;
        });
        return;
      }
    }
  }

  void _moveToPrevious(bool Function(ConversationMessageViewModel) predicate) {
    for (var i = _selectedIndex - 1; i >= 0; i--) {
      if (predicate(widget.messages[i])) {
        setState(() {
          _selectedIndex = i;
        });
        return;
      }
    }
  }
}

class _Metadata extends StatelessWidget {
  const _Metadata({required this.message});

  final ConversationMessageViewModel message;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        Text('Author: ${message.authorLabel}'),
        Text('Time: ${message.createdAtUtc.shortDateTime}'),
        Text('Tokens: ${message.tokenCount}'),
      ],
    );
  }
}

class _MessageBody extends StatelessWidget {
  const _MessageBody({required this.message, required this.expanded});

  final ConversationMessageViewModel message;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    if (message.hasToolOutput && !expanded) {
      return Semantics(
        key: const Key('focus-reader-message'),
        label:
            'Tool output collapsed, ${message.lineCount} lines. Press Enter to expand.',
        button: true,
        child: ExcludeSemantics(
          child: Align(
            alignment: Alignment.topLeft,
            child: Text('Tool output collapsed, ${message.lineCount} lines.'),
          ),
        ),
      );
    }
    return Semantics(
      key: const Key('focus-reader-message'),
      label: message.body,
      child: SingleChildScrollView(child: SelectableText(message.body)),
    );
  }
}

class _NavigationButtons extends StatelessWidget {
  const _NavigationButtons({
    required this.onPrevious,
    required this.onNext,
    required this.onPreviousUser,
    required this.onNextUser,
    required this.onPreviousAssistant,
    required this.onNextAssistant,
    required this.onPreviousTool,
    required this.onNextTool,
    required this.onPreviousError,
    required this.onNextError,
    required this.onToggleToolOutput,
    required this.expanded,
  });

  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onPreviousUser;
  final VoidCallback onNextUser;
  final VoidCallback onPreviousAssistant;
  final VoidCallback onNextAssistant;
  final VoidCallback onPreviousTool;
  final VoidCallback onNextTool;
  final VoidCallback onPreviousError;
  final VoidCallback onNextError;
  final VoidCallback? onToggleToolOutput;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _button('Previous', onPrevious),
        _button('Next', onNext),
        _button('Previous user', onPreviousUser),
        _button('Next user', onNextUser),
        _button('Previous assistant', onPreviousAssistant),
        _button('Next assistant', onNextAssistant),
        _button('Previous tool', onPreviousTool),
        _button('Next tool', onNextTool),
        _button('Previous error', onPreviousError),
        _button('Next error', onNextError),
        if (onToggleToolOutput != null)
          _button(
            expanded ? 'Collapse tool output' : 'Expand tool output',
            onToggleToolOutput!,
          ),
        _button('Copy Markdown', () {}),
        _button('Copy text', () {}),
      ],
    );
  }

  Widget _button(String label, VoidCallback onPressed) =>
      OutlinedButton(onPressed: onPressed, child: Text(label));
}

bool _isUser(ConversationMessageViewModel message) =>
    message.author == ConversationAuthor.user;

bool _isAssistant(ConversationMessageViewModel message) =>
    message.author == ConversationAuthor.assistant;

bool _isTool(ConversationMessageViewModel message) =>
    message.author == ConversationAuthor.tool;

bool _isToolOrError(ConversationMessageViewModel message) =>
    message.author == ConversationAuthor.tool || message.hasError;

extension on DateTime {
  String get shortDateTime {
    final local = toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
