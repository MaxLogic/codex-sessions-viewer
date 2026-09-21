import 'dart:async';
import 'dart:math' as math;

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
typedef ConversationOlderMessagesLoader =
    Future<List<ConversationMessageViewModel>> Function();
typedef ConversationMessagePageLoader =
    Future<List<ConversationMessageViewModel>> Function(
      int anchorMessageNumber,
    );

/// How non-chat activity (tool calls, tool output, reasoning) is shown.
///
/// [hide] is the chat view: only user prompts and assistant replies.
/// [collapse] shows activity with tool output collapsed; [show] expands it.
enum ToolCallVisibility { show, collapse, hide }

enum _AuthorFilter { all, user, assistant }

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
    this.onLoadOlderMessages,
    this.onLoadMessagePage,
    this.onLoadAllMessages,
    this.announcer,
  });

  final List<ConversationMessageViewModel> messages;
  final CopyTextCallback? onCopyMessageMarkdown;
  final AppMotionMode motionMode;
  final ToolCallVisibility initialToolCallVisibility;
  final int? initialMessageNumber;
  final ConversationPositionChanged? onPositionChanged;
  final ConversationOlderMessagesLoader? onLoadOlderMessages;
  final ConversationMessagePageLoader? onLoadMessagePage;

  /// Loads every message body so find-in-conversation can search paged
  /// sessions. Called at most once, when a search starts.
  final ConversationOlderMessagesLoader? onLoadAllMessages;
  final ScreenReaderAnnouncer? announcer;

  @override
  State<ConversationView> createState() => _ConversationViewState();
}

class _ConversationViewState extends State<ConversationView> {
  static const _estimatedItemExtent = 160.0;
  static const _maxFindMatches = 5000;

  var _messageListController = ScrollController();
  var _listGeneration = 0;
  final _findController = TextEditingController();
  final _findFocusNode = FocusNode(debugLabel: 'Find in conversation');
  final _cardContexts = <int, BuildContext>{};
  final _currentMatchKey = GlobalKey(debugLabel: 'current-find-match');
  var _selectedNumber = 1;
  late ToolCallVisibility _toolCallVisibility;
  var _authorFilter = _AuthorFilter.all;
  final _expanded = <String>{};
  final _messageOverridesById = <String, ConversationMessageViewModel>{};
  final _messageOverridesByNumber = <int, ConversationMessageViewModel>{};
  final _loadingMessagePages = <int>{};
  var _lastVisibleMessageCount = 0;
  var _showJumpToNewest = false;
  var _loadingOlderMessages = false;
  var _requestedAllMessages = false;
  var _loadingAllMessages = false;
  var _findQuery = '';
  var _currentMatch = -1;
  List<_FindMatch>? _matchCache;
  var _scrollRequest = 0;

  @override
  void initState() {
    super.initState();
    _toolCallVisibility = widget.initialToolCallVisibility;
    _lastVisibleMessageCount = _visibleMessages.length;
    _selectedNumber = _initialSelectedNumber(_visibleMessages);
    _scrollToSelectedMessage(jump: true);
    unawaited(_loadMessagePageForNumber(_selectedNumber));
  }

  @override
  void didUpdateWidget(covariant ConversationView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _matchCache = null;
    final wasNearBottom = _isNearBottom();
    final visibleCount = _visibleMessages.length;
    if (widget.initialMessageNumber != oldWidget.initialMessageNumber) {
      _selectedNumber = _initialSelectedNumber(_visibleMessages);
      _scrollToSelectedMessage(jump: true);
      unawaited(_loadMessagePageForNumber(_selectedNumber));
    } else if (!_visibleMessages.any(
      (message) => message.number == _selectedNumber,
    )) {
      _selectedNumber = _initialSelectedNumber(_visibleMessages);
      _scrollToSelectedMessage(jump: true);
      unawaited(_loadMessagePageForNumber(_selectedNumber));
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
    _findController.dispose();
    _findFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final messages = _visibleMessages;
    final motionPolicy = CodexMotionPolicy.fromContext(
      context,
      mode: widget.motionMode,
    );
    final matches = _findMatches(messages);
    final matchCounts = <int, int>{};
    for (final match in matches) {
      matchCounts[match.messageNumber] =
          (matchCounts[match.messageNumber] ?? 0) + 1;
    }
    final current = _currentMatch >= 0 && _currentMatch < matches.length
        ? matches[_currentMatch]
        : null;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusFind,
        const SingleActivator(LogicalKeyboardKey.f3): () => _stepMatch(1),
        const SingleActivator(LogicalKeyboardKey.f3, shift: true): () =>
            _stepMatch(-1),
      },
      child: Semantics(
        key: const Key('conversation-view-semantics'),
        container: true,
        explicitChildNodes: true,
        label: 'Conversation view',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildToolbar(context, messages, matches.length),
            Divider(
              height: 1,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            Expanded(
              child: messages.isEmpty
                  ? _buildEmpty(context)
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final showIndex = constraints.maxWidth >= 640;
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (showIndex) ...[
                              SizedBox(
                                width: 220,
                                child: _MessageIndex(
                                  messages: messages,
                                  selectedNumber: _selectedNumber,
                                  matchCounts: matchCounts,
                                  onSelect: _selectMessage,
                                ),
                              ),
                              VerticalDivider(
                                width: 1,
                                thickness: 1,
                                color: Theme.of(
                                  context,
                                ).colorScheme.outlineVariant,
                              ),
                            ],
                            Expanded(
                              child: _buildMessageList(
                                messages,
                                motionPolicy,
                                current,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final hasHiddenActivity =
        _toolCallVisibility == ToolCallVisibility.hide &&
        _mergedMessages().isNotEmpty;
    if (widget.messages.isEmpty) {
      return const Center(child: Text('No conversation messages'));
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              hasHiddenActivity
                  ? 'No user or assistant messages match this view.'
                  : 'No conversation messages',
              textAlign: TextAlign.center,
            ),
            if (hasHiddenActivity) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => _setShowActivity(true),
                child: const Text('Show tool calls and reasoning'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar(
    BuildContext context,
    List<ConversationMessageViewModel> messages,
    int matchCount,
  ) {
    final theme = Theme.of(context);
    final selectedIndex = messages.indexWhere(
      (message) => message.number == _selectedNumber,
    );
    final positionText = messages.isEmpty
        ? 'No messages'
        : 'Message $_selectedNumber of ${_mergedMessages().length}';
    final hasQuery = _findQuery.isNotEmpty;
    final matchText = !hasQuery
        ? null
        : _loadingAllMessages
        ? 'Searching…'
        : matchCount == 0
        ? 'No matches'
        : '${_currentMatch + 1} of $matchCount';
    final children = <Widget>[
      SizedBox(
        width: 300,
        child: Semantics(
          label: 'Find in conversation',
          textField: true,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.enter): () =>
                  _stepMatch(1),
              const SingleActivator(
                LogicalKeyboardKey.enter,
                shift: true,
              ): () =>
                  _stepMatch(-1),
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  _findController.text.isEmpty
                  ? _findFocusNode.unfocus()
                  : _findController.clear(),
            },
            child: TextField(
              key: const Key('conversation-find-field'),
              controller: _findController,
              focusNode: _findFocusNode,
              onChanged: _onFindChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Find in conversation (Ctrl+F)',
                prefixIcon: const Icon(Icons.search, size: 18),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
                suffixIcon: hasQuery
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Semantics(
                            liveRegion: true,
                            child: Text(
                              matchText!,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Previous match (Shift+Enter)',
                            visualDensity: VisualDensity.compact,
                            onPressed: matchCount == 0
                                ? null
                                : () => _stepMatch(-1),
                            icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                          ),
                          IconButton(
                            tooltip: 'Next match (Enter)',
                            visualDensity: VisualDensity.compact,
                            onPressed: matchCount == 0
                                ? null
                                : () => _stepMatch(1),
                            icon: const Icon(
                              Icons.keyboard_arrow_down,
                              size: 18,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Clear find (Escape)',
                            visualDensity: VisualDensity.compact,
                            onPressed: () {
                              _findController.clear();
                              _onFindChanged('');
                            },
                            icon: const Icon(Icons.close, size: 16),
                          ),
                        ],
                      )
                    : null,
              ),
            ),
          ),
        ),
      ),
      Semantics(
        label: 'Message author filter',
        container: true,
        child: SegmentedButton<_AuthorFilter>(
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: _AuthorFilter.all, label: Text('All')),
            ButtonSegment(value: _AuthorFilter.user, label: Text('User')),
            ButtonSegment(
              value: _AuthorFilter.assistant,
              label: Text('Assistant'),
            ),
          ],
          selected: {_authorFilter},
          onSelectionChanged: (selection) => _applyVisibilityChange(() {
            _authorFilter = selection.single;
          }),
        ),
      ),
      _ActivityToggle(
        value: _toolCallVisibility != ToolCallVisibility.hide,
        onChanged: _setShowActivity,
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
      if (_canLoadOlderMessages)
        Semantics(
          label: 'Load older conversation messages',
          button: true,
          child: OutlinedButton.icon(
            onPressed: _loadingOlderMessages ? null : _loadOlderMessages,
            icon: const Icon(Icons.keyboard_arrow_up),
            label: Text(_loadingOlderMessages ? 'Loading older' : 'Load older'),
          ),
        ),
      if (selectedIndex >= 0)
        Text(
          positionText,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // In a narrow pane the controls stay on one scrollable line rather
          // than wrapping into rows that crowd out the messages.
          if (constraints.maxWidth < 560) {
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final child in children) ...[
                    child,
                    const SizedBox(width: 12),
                  ],
                ],
              ),
            );
          }
          return Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: children,
          );
        },
      ),
    );
  }

  Widget _buildMessageList(
    List<ConversationMessageViewModel> messages,
    CodexMotionPolicy motionPolicy,
    _FindMatch? current,
  ) {
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: 'Conversation messages',
      child: ListView.builder(
        key: ValueKey('conversation-list-$_listGeneration'),
        controller: _messageListController,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: messages.length,
        itemBuilder: (context, index) {
          final message = messages[index];
          return _ContextRegistrar(
            key: ValueKey(message.id),
            number: message.number,
            contexts: _cardContexts,
            child: _ConversationMessageCard(
              message: message,
              expanded: _isExpanded(message),
              selected: message.number == _selectedNumber,
              toolCallVisibility: _toolCallVisibility,
              motionPolicy: motionPolicy,
              findQuery: _findQuery,
              currentMatchStart: current?.messageNumber == message.number
                  ? current!.start
                  : null,
              currentMatchKey: _currentMatchKey,
              onCopyMarkdown: widget.onCopyMessageMarkdown,
              onSelect: () => _selectMessage(message.number, scroll: false),
              onToggleExpanded: () {
                final willExpand = !_isExpanded(message);
                setState(() {
                  if (willExpand) {
                    _expanded.add(message.id);
                  } else {
                    _expanded.remove(message.id);
                  }
                });
                if (message.hasToolOutput) {
                  unawaited(
                    widget.announcer?.announce(
                      willExpand
                          ? 'Tool output expanded for message ${message.number}.'
                          : 'Tool output collapsed for message ${message.number}.',
                    ),
                  );
                }
              },
            ),
          );
        },
      ),
    );
  }

  bool _isExpanded(ConversationMessageViewModel message) {
    if (_toolCallVisibility == ToolCallVisibility.show &&
        message.hasToolOutput) {
      return !_expanded.contains(message.id);
    }
    return _expanded.contains(message.id);
  }

  void _setShowActivity(bool show) {
    _applyVisibilityChange(() {
      _toolCallVisibility = show
          ? ToolCallVisibility.collapse
          : ToolCallVisibility.hide;
    });
  }

  void _applyVisibilityChange(VoidCallback change) {
    setState(() {
      change();
      _matchCache = null;
      final visibleAfterChange = _visibleMessages;
      _lastVisibleMessageCount = visibleAfterChange.length;
      if (!visibleAfterChange.any(
            (message) => message.number == _selectedNumber,
          ) &&
          visibleAfterChange.isNotEmpty) {
        _selectedNumber = visibleAfterChange.last.number;
      }
      _currentMatch = _findMatches(visibleAfterChange).isEmpty ? -1 : 0;
    });
    _scrollToSelectedMessage(jump: true);
  }

  void _focusFind() {
    _findFocusNode.requestFocus();
    _findController.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _findController.text.length,
    );
  }

  void _onFindChanged(String value) {
    final query = value.trim().toLowerCase();
    if (query == _findQuery) {
      return;
    }
    setState(() {
      _findQuery = query;
      _matchCache = null;
      _currentMatch = -1;
    });
    if (query.isEmpty) {
      return;
    }
    unawaited(_ensureAllMessagesLoaded());
    _moveToFirstMatchFromSelection();
  }

  void _moveToFirstMatchFromSelection() {
    final matches = _findMatches(_visibleMessages);
    if (matches.isEmpty) {
      return;
    }
    final fromSelection = matches.indexWhere(
      (match) => match.messageNumber >= _selectedNumber,
    );
    _goToMatch(fromSelection < 0 ? 0 : fromSelection, announce: true);
  }

  void _stepMatch(int delta) {
    final matches = _findMatches(_visibleMessages);
    if (matches.isEmpty) {
      return;
    }
    final next = _currentMatch < 0
        ? (delta > 0 ? 0 : matches.length - 1)
        : (_currentMatch + delta) % matches.length;
    _goToMatch(next < 0 ? next + matches.length : next, announce: true);
  }

  void _goToMatch(int index, {bool announce = false}) {
    final matches = _findMatches(_visibleMessages);
    if (index < 0 || index >= matches.length) {
      return;
    }
    final match = matches[index];
    final message = _visibleMessages.firstWhere(
      (message) => message.number == match.messageNumber,
    );
    setState(() {
      _currentMatch = index;
      _selectedNumber = match.messageNumber;
      final needsExpansion =
          message.isBodyLoaded &&
          (message.isLong || message.hasToolOutput) &&
          !_isExpanded(message);
      if (needsExpansion) {
        if (_toolCallVisibility == ToolCallVisibility.show &&
            message.hasToolOutput) {
          _expanded.remove(message.id);
        } else {
          _expanded.add(message.id);
        }
      }
    });
    _notifyPositionChanged();
    _scrollToSelectedMessage(preferMatch: true);
    if (announce) {
      unawaited(
        widget.announcer?.announce(
          'Match ${index + 1} of ${matches.length}, message ${match.messageNumber}, ${message.authorLabel}.',
        ),
      );
    }
  }

  Future<void> _ensureAllMessagesLoaded() async {
    final loader = widget.onLoadAllMessages;
    if (loader == null ||
        _requestedAllMessages ||
        !_mergedMessages().any((message) => !message.isBodyLoaded)) {
      return;
    }
    _requestedAllMessages = true;
    setState(() => _loadingAllMessages = true);
    try {
      final all = await loader();
      if (!mounted) {
        return;
      }
      setState(() {
        _mergeLoadedMessages(all);
        _matchCache = null;
      });
      if (_findQuery.isNotEmpty) {
        _moveToFirstMatchFromSelection();
      }
    } finally {
      if (mounted) {
        setState(() => _loadingAllMessages = false);
      }
    }
  }

  List<_FindMatch> _findMatches(List<ConversationMessageViewModel> messages) {
    final query = _findQuery;
    if (query.isEmpty) {
      return const [];
    }
    final cached = _matchCache;
    if (cached != null) {
      return cached;
    }
    final matches = <_FindMatch>[];
    for (final message in messages) {
      final text = _searchableText(message).toLowerCase();
      var start = text.indexOf(query);
      while (start >= 0 && matches.length < _maxFindMatches) {
        matches.add(_FindMatch(message.number, start));
        start = text.indexOf(query, start + query.length);
      }
      if (matches.length >= _maxFindMatches) {
        break;
      }
    }
    return _matchCache = matches;
  }

  List<ConversationMessageViewModel> get _visibleMessages {
    return _mergedMessages()
        .where((message) {
          switch (_authorFilter) {
            case _AuthorFilter.user:
              if (message.author != ConversationAuthor.user) {
                return false;
              }
            case _AuthorFilter.assistant:
              if (message.author != ConversationAuthor.assistant) {
                return false;
              }
            case _AuthorFilter.all:
              break;
          }
          if (_toolCallVisibility != ToolCallVisibility.hide) {
            return true;
          }
          return _isChatMessage(message);
        })
        .toList(growable: false);
  }

  bool _isChatMessage(ConversationMessageViewModel message) {
    if (message.author != ConversationAuthor.user &&
        message.author != ConversationAuthor.assistant) {
      return false;
    }
    if (message.hasToolOutput && message.author == ConversationAuthor.user) {
      return false;
    }
    if (!message.isBodyLoaded) {
      return message.preview.trim().isNotEmpty || !message.hasToolOutput;
    }
    return message.body.trim().isNotEmpty;
  }

  List<ConversationMessageViewModel> _mergedMessages() {
    final mergedByNumber = <int, ConversationMessageViewModel>{};
    for (final message in widget.messages) {
      mergedByNumber[message.number] =
          _messageOverridesById[message.id] ??
          _messageOverridesByNumber[message.number] ??
          message;
    }
    for (final message in _messageOverridesByNumber.values) {
      mergedByNumber[message.number] =
          _messageOverridesById[message.id] ?? message;
    }
    final messages = mergedByNumber.values.toList(growable: false)
      ..sort((left, right) => left.number.compareTo(right.number));
    return messages;
  }

  bool get _canLoadOlderMessages {
    return widget.onLoadOlderMessages != null &&
        _visibleMessages.any((message) => !message.isBodyLoaded);
  }

  Future<void> _selectMessage(int number, {bool scroll = true}) async {
    final messages = _visibleMessages;
    final index = messages.indexWhere((message) => message.number == number);
    if (index < 0) {
      return;
    }
    final selected = messages[index];
    if (!selected.isBodyLoaded) {
      await _loadMessagePageForNumber(number);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _selectedNumber = number;
    });
    _notifyPositionChanged();
    if (scroll) {
      _scrollToSelectedMessage();
    }
  }

  Future<void> _loadMessagePageForNumber(int number) async {
    final loader = widget.onLoadMessagePage;
    if (loader == null || _loadingMessagePages.contains(number)) {
      return;
    }
    ConversationMessageViewModel? selected;
    for (final message in _visibleMessages) {
      if (message.number == number) {
        selected = message;
        break;
      }
    }
    if (selected == null || selected.isBodyLoaded) {
      return;
    }
    _loadingMessagePages.add(number);
    try {
      final page = await loader(number);
      if (!mounted) {
        return;
      }
      setState(() {
        _mergeLoadedMessages(page);
        _matchCache = null;
      });
    } finally {
      _loadingMessagePages.remove(number);
    }
  }

  Future<void> _loadOlderMessages() async {
    final loader = widget.onLoadOlderMessages;
    if (loader == null || _loadingOlderMessages) {
      return;
    }
    setState(() {
      _loadingOlderMessages = true;
    });
    try {
      final page = await loader();
      if (!mounted) {
        return;
      }
      setState(() {
        _mergeLoadedMessages(page);
        _matchCache = null;
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingOlderMessages = false;
        });
      }
    }
  }

  void _mergeLoadedMessages(List<ConversationMessageViewModel> messages) {
    for (final message in messages) {
      _messageOverridesById[message.id] = message;
      _messageOverridesByNumber[message.number] = message;
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

  /// Scrolls the selected message into view.
  ///
  /// The list is virtualized, so an off-screen card has no context yet. Jump
  /// to an estimated offset first, then refine with [Scrollable.ensureVisible]
  /// once the card is built.
  void _scrollToSelectedMessage({bool jump = false, bool preferMatch = false}) {
    final request = ++_scrollRequest;
    var resetDone = false;
    void attempt(int remaining) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            request != _scrollRequest ||
            !_messageListController.hasClients) {
          return;
        }
        final matchContext = preferMatch
            ? _currentMatchKey.currentContext
            : null;
        final cardContext = _cardContexts[_selectedNumber];
        final target = matchContext ?? cardContext;
        if (target != null && target.mounted) {
          final duration = jump
              ? Duration.zero
              : CodexMotionPolicy.fromContext(
                  context,
                  mode: widget.motionMode,
                ).fastDuration;
          unawaited(
            Scrollable.ensureVisible(
              target,
              alignment: matchContext != null ? 0.3 : 0.05,
              duration: duration,
              curve: Curves.easeOut,
              alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
            ),
          );
          if (matchContext == null && preferMatch && remaining > 0) {
            // The card is visible; the match marker appears next frame.
            attempt(remaining - 1);
          }
          return;
        }
        if (remaining <= 0) {
          return;
        }
        final messages = _visibleMessages;
        final index = messages.indexWhere(
          (message) => message.number == _selectedNumber,
        );
        if (index < 0) {
          return;
        }
        final builtIndices = [
          for (final number in _cardContexts.keys)
            messages.indexWhere((message) => message.number == number),
        ].where((builtIndex) => builtIndex >= 0);
        final firstBuilt = builtIndices.isEmpty
            ? null
            : builtIndices.reduce(math.min);
        if (!resetDone && firstBuilt != null && index < firstBuilt) {
          // Jumping backwards through a virtualized list is unreliable once
          // message heights changed (for example after bodies load): the
          // sliver only corrects a few items per frame. Recreate the list at
          // the top and approach the target with forward jumps, which lay out
          // every intermediate item exactly.
          resetDone = true;
          _resetMessageList();
          attempt(remaining - 1);
          return;
        }
        final position = _messageListController.position;
        final averageExtent = messages.isEmpty
            ? _estimatedItemExtent
            : math.max(
                60.0,
                (position.maxScrollExtent + position.viewportDimension) /
                    messages.length,
              );
        // Step from the nearest card that is already built; message heights
        // vary too much for an absolute estimate to land on the target.
        int? nearestIndex;
        for (final number in _cardContexts.keys) {
          final builtIndex = messages.indexWhere(
            (message) => message.number == number,
          );
          if (builtIndex >= 0 &&
              (nearestIndex == null ||
                  (builtIndex - index).abs() < (nearestIndex - index).abs())) {
            nearestIndex = builtIndex;
          }
        }
        final offset = nearestIndex == null
            ? index * averageExtent
            : position.pixels + (index - nearestIndex) * averageExtent;
        _messageListController.jumpTo(
          offset.clamp(0.0, position.maxScrollExtent).toDouble(),
        );
        attempt(remaining - 1);
      });
    }

    attempt(12);
  }

  void _resetMessageList() {
    final previous = _messageListController;
    setState(() {
      _messageListController = ScrollController();
      _listGeneration++;
      _cardContexts.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
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
    _scrollRequest++;
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

String _searchableText(ConversationMessageViewModel message) =>
    message.isBodyLoaded ? message.body : message.preview;

class _FindMatch {
  const _FindMatch(this.messageNumber, this.start);

  final int messageNumber;
  final int start;
}

/// Records the build context of each visible card so selection can scroll it
/// into view precisely.
class _ContextRegistrar extends StatefulWidget {
  const _ContextRegistrar({
    super.key,
    required this.number,
    required this.contexts,
    required this.child,
  });

  final int number;
  final Map<int, BuildContext> contexts;
  final Widget child;

  @override
  State<_ContextRegistrar> createState() => _ContextRegistrarState();
}

class _ContextRegistrarState extends State<_ContextRegistrar> {
  @override
  Widget build(BuildContext context) {
    widget.contexts[widget.number] = context;
    return widget.child;
  }

  @override
  void dispose() {
    if (identical(widget.contexts[widget.number], context)) {
      widget.contexts.remove(widget.number);
    }
    super.dispose();
  }
}

class _ActivityToggle extends StatelessWidget {
  const _ActivityToggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Show tool calls and reasoning',
      toggled: value,
      container: true,
      child: Tooltip(
        message: 'Off: only your prompts and the assistant replies are shown.',
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => onChanged(!value),
          child: Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: value,
                  visualDensity: VisualDensity.compact,
                  onChanged: (checked) => onChanged(checked ?? false),
                ),
                const ExcludeSemantics(child: Text('Tool calls & reasoning')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MessageIndex extends StatelessWidget {
  const _MessageIndex({
    required this.messages,
    required this.selectedNumber,
    required this.matchCounts,
    required this.onSelect,
  });

  final List<ConversationMessageViewModel> messages;
  final int selectedNumber;
  final Map<int, int> matchCounts;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasQuery = matchCounts.isNotEmpty;
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: messages.length,
      itemBuilder: (context, index) {
        final message = messages[index];
        final selected = message.number == selectedNumber;
        final matchCount = matchCounts[message.number] ?? 0;
        final markers = [
          if (message.hasToolOutput) 'tool',
          if (message.hasError) 'error',
        ].join(', ');
        final dimmed = hasQuery && matchCount == 0;
        return Semantics(
          label:
              '#${message.number} ${message.authorLabel}, ${message.tokenLabel}',
          button: true,
          selected: selected,
          child: Opacity(
            opacity: dimmed ? 0.55 : 1,
            child: ListTile(
              leading: _MessageKindIcon(
                key: Key('message-index-icon-${message.number}'),
                message: message,
                selected: selected,
              ),
              minLeadingWidth: 24,
              horizontalTitleGap: 8,
              selected: selected,
              selectedTileColor: theme.colorScheme.secondaryContainer
                  .withValues(alpha: 0.5),
              dense: true,
              visualDensity: VisualDensity.compact,
              contentPadding: const EdgeInsets.symmetric(horizontal: 8),
              title: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${message.authorLabel} · ${message.createdAtUtc.shortTime}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                  if (matchCount > 0)
                    _Badge(text: '$matchCount')
                  else if (markers.isNotEmpty)
                    Text(markers, style: theme.textTheme.labelSmall),
                ],
              ),
              subtitle: Text(
                message.preview.replaceAll(RegExp(r'\s+'), ' ').trim(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
              onTap: () => onSelect(message.number),
            ),
          ),
        );
      },
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: scheme.onTertiaryContainer),
      ),
    );
  }
}

class _ConversationMessageCard extends StatelessWidget {
  const _ConversationMessageCard({
    required this.message,
    required this.expanded,
    required this.selected,
    required this.toolCallVisibility,
    required this.motionPolicy,
    required this.findQuery,
    required this.currentMatchStart,
    required this.currentMatchKey,
    required this.onCopyMarkdown,
    required this.onSelect,
    required this.onToggleExpanded,
  });

  final ConversationMessageViewModel message;
  final bool expanded;
  final bool selected;
  final ToolCallVisibility toolCallVisibility;
  final CodexMotionPolicy motionPolicy;
  final String findQuery;
  final int? currentMatchStart;
  final GlobalKey currentMatchKey;
  final CopyTextCallback? onCopyMarkdown;
  final VoidCallback onSelect;
  final VoidCallback onToggleExpanded;

  bool get _isChatAuthor =>
      message.author == ConversationAuthor.user ||
      message.author == ConversationAuthor.assistant;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bodyLoaded = message.isBodyLoaded;
    final collapsedToolOutput =
        bodyLoaded && message.hasToolOutput && !expanded;
    final collapsedLongMessage =
        bodyLoaded && !message.hasToolOutput && message.isLong && !expanded;
    final body = collapsedToolOutput || collapsedLongMessage
        ? message.preview
        : message.body;
    final semanticsBody = bodyLoaded ? body : 'Message body not loaded yet.';
    final isUser = message.author == ConversationAuthor.user;
    final background = isUser
        ? Color.alphaBlend(
            scheme.primary.withValues(alpha: 0.07),
            scheme.surface,
          )
        : scheme.surface;
    final borderColor = selected
        ? scheme.primary
        : _isChatAuthor
        ? scheme.outlineVariant
        : scheme.outlineVariant.withValues(alpha: 0.6);
    final meta = [
      '#${message.number}',
      message.createdAtUtc.shortTime,
      if (message.tokenCount != null) message.tokenLabel,
      if (message.hasError) 'error',
    ].join(' · ');
    final bodyStyle = _isChatAuthor
        ? theme.textTheme.bodyMedium
        : theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
            fontFamily: message.author == ConversationAuthor.tool
                ? 'Consolas'
                : null,
          );
    return Semantics(
      key: Key('message-card-semantics-${message.number}'),
      container: true,
      focusable: true,
      readOnly: true,
      label: _messageSemanticsLabel(
        message,
        collapsedToolOutput
            ? 'Tool output collapsed, ${message.lineCount} lines.'
            : semanticsBody,
      ),
      explicitChildNodes: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        child: GestureDetector(
          behavior: HitTestBehavior.deferToChild,
          excludeFromSemantics: true,
          onTap: onSelect,
          child: DecoratedBox(
            key: Key('message-card-${message.number}'),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: borderColor, width: selected ? 2 : 1),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 8, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _MessageKindIcon(
                        key: Key('message-card-icon-${message.number}'),
                        message: message,
                        selected: selected,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        message.authorLabel,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (bodyLoaded)
                        Semantics(
                          label: 'Copy message ${message.number} as Markdown',
                          button: true,
                          child: ExcludeSemantics(
                            child: TextButton.icon(
                              style: TextButton.styleFrom(
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed: () => _copyMarkdown(context),
                              icon: const AppSvgIcon(AppIcons.copy, size: 14),
                              label: const Text('Copy'),
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
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
                            style: bodyStyle,
                          ),
                        ),
                      ),
                    )
                  else
                    CodexMotion.expandCollapse(
                      policy: motionPolicy,
                      child: Semantics(
                        container: true,
                        label: body,
                        readOnly: true,
                        child: ExcludeSemantics(
                          child: SelectionArea(
                            child: _HighlightedText(
                              text: body,
                              query: findQuery,
                              currentMatchStart: currentMatchStart,
                              currentMatchKey: currentMatchKey,
                              style: bodyStyle,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (bodyLoaded &&
                      (message.isLong || message.hasToolOutput)) ...[
                    const SizedBox(height: 4),
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: onToggleExpanded,
                      icon: AppSvgIcon(
                        expanded ? AppIcons.collapse : AppIcons.expand,
                        size: 14,
                      ),
                      label: Text(
                        expanded
                            ? 'Collapse'
                            : message.hasToolOutput
                            ? 'Expand tool output'
                            : 'Show full message',
                      ),
                    ),
                  ],
                ],
              ),
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

/// Message text with find matches highlighted.
///
/// A zero-size marker keyed by [currentMatchKey] precedes the current match so
/// the list can scroll the match itself into view inside long messages.
class _HighlightedText extends StatelessWidget {
  const _HighlightedText({
    required this.text,
    required this.query,
    required this.currentMatchStart,
    required this.currentMatchKey,
    required this.style,
  });

  final String text;
  final String query;
  final int? currentMatchStart;
  final GlobalKey currentMatchKey;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    if (query.isEmpty) {
      return Text(text, style: style);
    }
    final scheme = Theme.of(context).colorScheme;
    final lower = text.toLowerCase();
    final spans = <InlineSpan>[];
    var cursor = 0;
    var start = lower.indexOf(query);
    if (start < 0) {
      return Text(text, style: style);
    }
    while (start >= 0) {
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start)));
      }
      final isCurrent = start == currentMatchStart;
      if (isCurrent) {
        spans.add(
          WidgetSpan(
            child: SizedBox(key: currentMatchKey, width: 0, height: 0),
          ),
        );
      }
      spans.add(
        TextSpan(
          text: text.substring(start, start + query.length),
          style: TextStyle(
            backgroundColor: isCurrent
                ? scheme.primary
                : scheme.tertiaryContainer,
            color: isCurrent ? scheme.onPrimary : scheme.onTertiaryContainer,
          ),
        ),
      );
      cursor = start + query.length;
      start = lower.indexOf(query, cursor);
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return Text.rich(TextSpan(children: spans), style: style);
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
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: AppSvgIcon(_messageIcon(message.author), size: 13, color: color),
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
