import 'package:flutter/material.dart';

import '../../logging/structured_logger.dart';

typedef LogEntryAction = Future<void> Function(LogEntry entry);
typedef LogsAction = Future<void> Function();

class LogsScreen extends StatefulWidget {
  const LogsScreen({
    super.key,
    this.entries = const [],
    this.onCopySelected,
    this.onOpenLogFile,
    this.onOpenLogsFolder,
    this.onClearOldLogs,
  });

  final List<LogEntry> entries;
  final LogEntryAction? onCopySelected;
  final LogsAction? onOpenLogFile;
  final LogsAction? onOpenLogsFolder;
  final LogsAction? onClearOldLogs;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  var _errorsOnly = false;
  final _categories = <LogCategory>{};
  LogEntry? _selected;

  List<LogEntry> get _visibleEntries {
    return widget.entries
        .where((entry) {
          if (_errorsOnly && entry.level != LogLevel.error) {
            return false;
          }
          if (_categories.isNotEmpty && !_categories.contains(entry.category)) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  Future<void> _copySelected() async {
    final selected = _selected;
    if (selected != null) {
      await widget.onCopySelected?.call(selected);
    }
  }

  Future<void> _confirmClearOldLogs() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Semantics(
        label: 'Confirm clearing old logs',
        explicitChildNodes: true,
        child: AlertDialog(
          title: const Text('Clear old logs?'),
          content: const Text(
            'Old log entries will be cleared from the configured log store.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Clear logs'),
            ),
          ],
        ),
      ),
    );
    if (confirmed ?? false) {
      await widget.onClearOldLogs?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final visible = _visibleEntries;
    return Material(
      color: scheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Logs', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            _Filters(
              errorsOnly: _errorsOnly,
              selectedCategories: _categories,
              onErrorsOnlyChanged: (value) {
                setState(() {
                  _errorsOnly = value;
                });
              },
              onCategoryChanged: (category, selected) {
                setState(() {
                  if (selected) {
                    _categories.add(category);
                  } else {
                    _categories.remove(category);
                  }
                });
              },
            ),
            const SizedBox(height: 12),
            Text('Log table', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Expanded(
              flex: 3,
              child: Semantics(
                label: 'Logs table',
                container: true,
                child: ClipRect(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: SingleChildScrollView(
                      child: DataTable(
                        columnSpacing: 24,
                        showCheckboxColumn: false,
                        columns: const [
                          DataColumn(label: Text('Time')),
                          DataColumn(label: Text('Level')),
                          DataColumn(label: Text('Category')),
                          DataColumn(label: Text('Message')),
                          DataColumn(label: Text('Details')),
                        ],
                        rows: [
                          for (final entry in visible)
                            DataRow(
                              selected: _selected?.id == entry.id,
                              onSelectChanged: (_) {
                                setState(() {
                                  _selected = entry;
                                });
                              },
                              cells: [
                                _cell(entry, _formatTime(entry.timeUtc)),
                                _cell(entry, entry.level.name),
                                _cell(entry, entry.category.displayLabel),
                                _messageCell(entry),
                                _cell(
                                  entry,
                                  entry.details == null ? 'No' : 'Yes',
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _DetailsPane(entry: _selected),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _selected == null ? null : _copySelected,
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy selected'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.onOpenLogFile,
                  icon: const Icon(Icons.description),
                  label: const Text('Open log file'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.onOpenLogsFolder,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Open logs folder'),
                ),
                FilledButton.icon(
                  onPressed: _confirmClearOldLogs,
                  icon: const Icon(Icons.delete_sweep),
                  label: const Text('Clear old logs'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  DataCell _cell(LogEntry entry, String text) {
    return DataCell(
      Text(text),
      onTap: () {
        setState(() {
          _selected = entry;
        });
      },
    );
  }

  DataCell _messageCell(LogEntry entry) {
    return DataCell(
      TextButton(
        onPressed: () {
          setState(() {
            _selected = entry;
          });
        },
        child: Text(entry.message),
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.errorsOnly,
    required this.selectedCategories,
    required this.onErrorsOnlyChanged,
    required this.onCategoryChanged,
  });

  final bool errorsOnly;
  final Set<LogCategory> selectedCategories;
  final ValueChanged<bool> onErrorsOnlyChanged;
  final void Function(LogCategory category, bool selected) onCategoryChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: const Text('Errors only'),
              selected: errorsOnly,
              onSelected: onErrorsOnlyChanged,
            ),
          ),
          for (final category in LogCategory.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(category.displayLabel),
                selected: selectedCategories.contains(category),
                onSelected: (selected) => onCategoryChanged(category, selected),
              ),
            ),
        ],
      ),
    );
  }
}

class _DetailsPane extends StatelessWidget {
  const _DetailsPane({required this.entry});

  final LogEntry? entry;

  @override
  Widget build(BuildContext context) {
    final details = entry?.details ?? 'No details selected.';
    return Semantics(
      label: 'Selected log details',
      container: true,
      explicitChildNodes: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SizedBox(
          width: double.infinity,
          height: 136,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ExcludeSemantics(
                  child: Text(
                    'Selected log details',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: SingleChildScrollView(child: SelectableText(details)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _formatTime(DateTime value) {
  final utc = value.toUtc();
  String two(int part) => part.toString().padLeft(2, '0');
  return '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}';
}

extension on LogCategory {
  String get displayLabel {
    return switch (this) {
      LogCategory.scanner => 'Scanner',
      LogCategory.parser => 'Parser',
      LogCategory.database => 'Database',
      LogCategory.migration => 'Migration',
      LogCategory.search => 'Search',
      LogCategory.commands => 'Commands',
      LogCategory.pricing => 'Pricing',
      LogCategory.export => 'Export',
      LogCategory.accessibility => 'Accessibility',
      LogCategory.voiceOver => 'Voice-over',
      LogCategory.ui => 'UI',
    };
  }
}
