import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../search/message_search.dart';
import '../models/session_label_formatter.dart';
import '../models/session_row_view_model.dart';
import '../widgets/app_button.dart';

typedef ContextMessageSearchCallback =
    Future<List<MessageSearchResult>> Function(MessageSearchQuery query);
typedef ContextCopyCallback = Future<void> Function(String text);
typedef ContextOpenCallback = Future<void> Function(ContextOpenRequest request);

enum ContextSearchMode { messages, sessions }

class ContextOpenRequest {
  const ContextOpenRequest({required this.sessionId, this.messageIndex});

  final String sessionId;
  final int? messageIndex;
}

class ContextSearchScreen extends StatefulWidget {
  const ContextSearchScreen({
    super.key,
    required this.initialSessionRows,
    required this.onSearchMessages,
    this.statusMessage = '',
    this.onCopyContext,
    this.onOpenResult,
  });

  final List<SessionRowViewModel> initialSessionRows;
  final ContextMessageSearchCallback onSearchMessages;
  final String statusMessage;
  final ContextCopyCallback? onCopyContext;
  final ContextOpenCallback? onOpenResult;

  @override
  State<ContextSearchScreen> createState() => _ContextSearchScreenState();
}

class _ContextSearchScreenState extends State<ContextSearchScreen> {
  final _queryController = TextEditingController();
  final _selectedKeys = <String>{};
  var _mode = ContextSearchMode.messages;
  var _messageResults = <MessageSearchResult>[];
  var _sessionResults = <SessionRowViewModel>[];
  var _isSearching = false;
  var _statusMessage = '';
  var _searchGeneration = 0;
  Timer? _rowsChangedTimer;

  /// Collector commits can replace the session rows several times a second;
  /// only the settled rows re-run an active query.
  static const _rowsChangedDebounce = Duration(milliseconds: 400);

  @override
  void initState() {
    super.initState();
    _statusMessage = widget.statusMessage;
  }

  @override
  void didUpdateWidget(covariant ContextSearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialSessionRows != widget.initialSessionRows &&
        _queryController.text.trim().isNotEmpty) {
      _rowsChangedTimer?.cancel();
      _rowsChangedTimer = Timer(_rowsChangedDebounce, () {
        if (mounted && _queryController.text.trim().isNotEmpty) {
          _search(preserveSelection: true);
        }
      });
    }
    if (oldWidget.statusMessage != widget.statusMessage) {
      _statusMessage = widget.statusMessage;
    }
  }

  @override
  void dispose() {
    _rowsChangedTimer?.cancel();
    _queryController.dispose();
    super.dispose();
  }

  int get _resultCount => switch (_mode) {
    ContextSearchMode.messages => _messageResults.length,
    ContextSearchMode.sessions => _sessionResults.length,
  };

  @override
  Widget build(BuildContext context) {
    return Material(
      child: Semantics(
        label: 'Context content',
        container: true,
        explicitChildNodes: true,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Heading(resultCount: _resultCount),
              const SizedBox(height: 12),
              _buildSearchBar(),
              if (_statusMessage.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  label: _statusMessage,
                  child: ExcludeSemantics(child: Text(_statusMessage)),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(child: _buildResults()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    final hasSelected = _selectedKeys.isNotEmpty;
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Semantics(
          label: 'Context search mode',
          container: true,
          child: SegmentedButton<ContextSearchMode>(
            segments: const [
              ButtonSegment(
                value: ContextSearchMode.messages,
                icon: Icon(Icons.chat_bubble_outline),
                label: Text('Messages'),
              ),
              ButtonSegment(
                value: ContextSearchMode.sessions,
                icon: Icon(Icons.history),
                label: Text('Sessions'),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (selection) {
              setState(() {
                _mode = selection.single;
                _selectedKeys.clear();
              });
            },
          ),
        ),
        SizedBox(
          width: 340,
          child: Semantics(
            label: 'Context query',
            textField: true,
            child: TextField(
              controller: _queryController,
              decoration: const InputDecoration(
                labelText: 'Search',
                isDense: true,
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
            ),
          ),
        ),
        // Stays enabled while searching so keyboard focus is not dropped; a
        // new search supersedes the running one.
        Semantics(
          label: 'Search context',
          button: true,
          enabled: true,
          excludeSemantics: true,
          onTap: _search,
          child: AppButton.filled(
            onPressed: _search,
            icon: const Icon(Icons.search),
            label: Text(_isSearching ? 'Searching' : 'Search'),
          ),
        ),
        Semantics(
          label: 'Copy selected context results',
          button: true,
          enabled: hasSelected,
          excludeSemantics: true,
          onTap: hasSelected ? _copySelected : null,
          child: AppButton.outlined(
            onPressed: hasSelected ? _copySelected : null,
            icon: const Icon(Icons.copy),
            label: const Text('Copy selected'),
          ),
        ),
      ],
    );
  }

  Widget _buildResults() {
    if (_resultCount == 0) {
      return const Center(child: Text('No context results'));
    }
    return Semantics(
      label: 'Context results',
      container: true,
      explicitChildNodes: true,
      child: ListView.builder(
        itemCount: _resultCount,
        itemExtent: 116,
        itemBuilder: (context, index) => switch (_mode) {
          ContextSearchMode.messages => _MessageContextRow(
            result: _messageResults[index],
            selected: _selectedKeys.contains(
              _messageKey(_messageResults[index]),
            ),
            onSelected: (selected) =>
                _setSelected(_messageKey(_messageResults[index]), selected),
            onOpen: () => _openMessageResult(_messageResults[index]),
          ),
          ContextSearchMode.sessions => _SessionContextRow(
            row: _sessionResults[index],
            selected: _selectedKeys.contains(
              _sessionKey(_sessionResults[index]),
            ),
            onSelected: (selected) =>
                _setSelected(_sessionKey(_sessionResults[index]), selected),
            onOpen: () => _openSessionResult(_sessionResults[index]),
          ),
        },
      ),
    );
  }

  Future<void> _search({bool preserveSelection = false}) async {
    final text = _queryController.text.trim();
    final generation = ++_searchGeneration;
    setState(() {
      _isSearching = true;
      if (!preserveSelection) _selectedKeys.clear();
      _statusMessage = '';
    });
    try {
      if (_mode == ContextSearchMode.messages) {
        final results = text.isEmpty
            ? const <MessageSearchResult>[]
            : await widget.onSearchMessages(
                MessageSearchQuery(text: text, limit: 100),
              );
        if (!mounted || generation != _searchGeneration) {
          return;
        }
        setState(() {
          _messageResults = results;
        });
      } else {
        final results = _searchSessions(text);
        if (!mounted || generation != _searchGeneration) {
          return;
        }
        setState(() {
          _sessionResults = results;
        });
      }
    } on Object catch (error) {
      if (!mounted || generation != _searchGeneration) {
        return;
      }
      setState(() {
        _statusMessage = 'Context search failed. $error';
      });
    } finally {
      if (mounted && generation == _searchGeneration) {
        setState(() {
          _isSearching = false;
        });
      }
    }
  }

  List<SessionRowViewModel> _searchSessions(String text) {
    final tokens = text
        .toLowerCase()
        .split(RegExp(r'[^a-z0-9_]+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty) {
      return const [];
    }
    return [
      for (final row in widget.initialSessionRows)
        if (tokens.every((token) => _sessionText(row).contains(token))) row,
    ];
  }

  String _sessionText(SessionRowViewModel row) {
    return [
      row.primaryIdentity,
      row.summary,
      row.project,
      row.platformLabel,
      row.harnessLabel,
      row.modelProviderLabel,
      row.path,
      ...row.tags,
    ].join(' ').toLowerCase();
  }

  void _setSelected(String key, bool selected) {
    setState(() {
      if (selected) {
        _selectedKeys.add(key);
      } else {
        _selectedKeys.remove(key);
      }
    });
  }

  Future<void> _copySelected() async {
    final selectedText = switch (_mode) {
      ContextSearchMode.messages => [
        for (final result in _messageResults)
          if (_selectedKeys.contains(_messageKey(result)))
            _messageCopyText(result),
      ],
      ContextSearchMode.sessions => [
        for (final row in _sessionResults)
          if (_selectedKeys.contains(_sessionKey(row))) _sessionCopyText(row),
      ],
    };
    final text = selectedText.join('\n\n');
    final callback = widget.onCopyContext;
    if (callback == null) {
      await Clipboard.setData(ClipboardData(text: text));
    } else {
      await callback(text);
    }
    if (!mounted) {
      return;
    }
    final count = selectedText.length;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Copied $count context ${count == 1 ? 'result' : 'results'}.',
        ),
      ),
    );
  }

  Future<void> _openMessageResult(MessageSearchResult result) async {
    await widget.onOpenResult?.call(
      ContextOpenRequest(
        sessionId: result.sessionId,
        messageIndex: result.messageIndex,
      ),
    );
  }

  Future<void> _openSessionResult(SessionRowViewModel row) async {
    await widget.onOpenResult?.call(ContextOpenRequest(sessionId: row.id));
  }
}

class _MessageContextRow extends StatelessWidget {
  const _MessageContextRow({
    required this.result,
    required this.selected,
    required this.onSelected,
    required this.onOpen,
  });

  final MessageSearchResult result;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final label = _messageResultLabel(result);
    return _ResultSurface(
      selected: selected,
      semanticsLabel:
          '$label. ${result.authorLabel}. ${result.projectName}. ${result.sourceLabel}. ${result.harnessLabel}.',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ResultCheckbox(
            label: 'Select context result $label',
            selected: selected,
            onSelected: onSelected,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  result.sessionIdentity,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _ChipText(result.authorLabel),
                    _ChipText(result.projectName),
                    _ChipText(result.sourceLabel),
                    _ChipText(result.harnessLabel),
                    _ChipText(_timestampUtc(result.timestampUtc)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  _plainSnippet(result.snippet),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _OpenButton(label: 'Open context result $label', onOpen: onOpen),
        ],
      ),
    );
  }
}

class _SessionContextRow extends StatelessWidget {
  const _SessionContextRow({
    required this.row,
    required this.selected,
    required this.onSelected,
    required this.onOpen,
  });

  final SessionRowViewModel row;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final label = row.primaryIdentity;
    return _ResultSurface(
      selected: selected,
      semanticsLabel:
          '$label. ${row.project}. ${row.platformLabel}. ${row.harnessLabel}.',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _ResultCheckbox(
            label: 'Select context result $label',
            selected: selected,
            onSelected: onSelected,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _ChipText(row.project),
                    _ChipText(row.platformLabel),
                    _ChipText(row.harnessLabel),
                    if (row.providerLabel != SessionLabelFormatter.unknown)
                      _ChipText(row.providerLabel),
                    _ChipText(row.modelLabel),
                    _ChipText(_shortDate(row.lastMessageAtUtc)),
                  ],
                ),
                const SizedBox(height: 4),
                Text(row.summary, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          const SizedBox(width: 8),
          _OpenButton(label: 'Open context result $label', onOpen: onOpen),
        ],
      ),
    );
  }
}

class _ResultSurface extends StatelessWidget {
  const _ResultSurface({
    required this.selected,
    required this.semanticsLabel,
    required this.child,
  });

  final bool selected;
  final String semanticsLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      selected: selected,
      container: true,
      explicitChildNodes: true,
      child: Material(
        color: selected
            ? Theme.of(
                context,
              ).colorScheme.secondaryContainer.withValues(alpha: 0.45)
            : Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: child,
        ),
      ),
    );
  }
}

class _ResultCheckbox extends StatelessWidget {
  const _ResultCheckbox({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final ValueChanged<bool> onSelected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      checked: selected,
      onTap: () => onSelected(!selected),
      child: ExcludeSemantics(
        child: Checkbox(
          value: selected,
          onChanged: (value) => onSelected(value ?? false),
        ),
      ),
    );
  }
}

class _OpenButton extends StatelessWidget {
  const _OpenButton({required this.label, required this.onOpen});

  final String label;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      onTap: onOpen,
      child: ExcludeSemantics(
        child: AppButton.outlined(
          onPressed: onOpen,
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open'),
        ),
      ),
    );
  }
}

class _ChipText extends StatelessWidget {
  const _ChipText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final value = text.trim().isEmpty ? 'Unknown' : text;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(value, style: Theme.of(context).textTheme.labelSmall),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.resultCount});

  final int resultCount;

  @override
  Widget build(BuildContext context) {
    final suffix = resultCount == 1 ? 'result' : 'results';
    return Semantics(
      header: true,
      label: 'Context Search, $resultCount $suffix',
      child: ExcludeSemantics(
        child: Row(
          children: [
            Text('Context', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(width: 12),
            Text('$resultCount $suffix'),
          ],
        ),
      ),
    );
  }
}

String _messageKey(MessageSearchResult result) =>
    '${result.sessionId}:${result.messageIndex}';

String _sessionKey(SessionRowViewModel row) => row.id;

String _messageResultLabel(MessageSearchResult result) =>
    '${result.sessionIdentity} message ${result.messageIndex}';

String _messageCopyText(MessageSearchResult result) {
  return [
    result.sessionIdentity,
    '${result.authorLabel} | ${result.projectName} | ${result.sourceLabel} | ${result.harnessLabel} | ${_timestampUtc(result.timestampUtc)}',
    _plainSnippet(result.snippet),
  ].join('\n');
}

String _sessionCopyText(SessionRowViewModel row) {
  return [
    row.primaryIdentity,
    '${row.project} | ${row.platformLabel} | ${row.harnessLabel} | ${_shortDate(row.lastMessageAtUtc)}',
    row.summary,
  ].join('\n');
}

String _plainSnippet(String value) {
  return value
      .replaceAll('<mark>', '')
      .replaceAll('</mark>', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _shortDate(DateTime? value) {
  if (value == null) {
    return 'Unknown';
  }
  final utc = value.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}

String _timestampUtc(DateTime? value) {
  if (value == null) {
    return 'Unknown';
  }
  final utc = value.toUtc();
  return '${_shortDate(utc)} '
      '${utc.hour.toString().padLeft(2, '0')}:'
      '${utc.minute.toString().padLeft(2, '0')} UTC';
}

extension on MessageSearchResult {
  String get harnessLabel => SessionLabelFormatter.harness(harness);
  String get authorLabel {
    final trimmed = author.trim();
    if (trimmed.isEmpty) {
      return 'Unknown';
    }
    return '${trimmed[0].toUpperCase()}${trimmed.substring(1)}';
  }

  String get sourceLabel {
    return SessionLabelFormatter.sourceType(sourceType);
  }
}
