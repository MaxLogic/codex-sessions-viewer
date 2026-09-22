import 'package:flutter/material.dart';

import '../../logging/structured_logger.dart';
import '../widgets/svg_icon.dart';
import '../widgets/app_button.dart';

typedef LogEntryAction = Future<void> Function(LogEntry entry);
typedef LogsAction = Future<void> Function();

class LogsScreen extends StatefulWidget {
  // ignore: prefer_const_constructors_in_immutables
  LogsScreen({
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
            AppButton.filled(
              onPressed: () => Navigator.of(context).pop(true),
              icon: const AppSvgIcon(AppIcons.deleteSweep),
              label: const Text('Clear logs'),
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
              child: _LogsTable(
                entries: visible,
                selected: _selected,
                onSelected: (entry) {
                  setState(() {
                    _selected = entry;
                  });
                },
              ),
            ),
            const SizedBox(height: 12),
            _DetailsPane(entry: _selected),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                AppButton.outlined(
                  onPressed: _selected == null ? null : _copySelected,
                  icon: const AppSvgIcon(AppIcons.copy),
                  label: const Text('Copy selected'),
                ),
                AppButton.outlined(
                  onPressed: widget.onOpenLogFile,
                  icon: const AppSvgIcon(AppIcons.file),
                  label: const Text('Open log file'),
                ),
                AppButton.outlined(
                  onPressed: widget.onOpenLogsFolder,
                  icon: const AppSvgIcon(AppIcons.folderOpen),
                  label: const Text('Open logs folder'),
                ),
                AppButton.filled(
                  onPressed: _confirmClearOldLogs,
                  icon: const AppSvgIcon(AppIcons.deleteSweep),
                  label: const Text('Clear old logs'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LogsTable extends StatelessWidget {
  const _LogsTable({
    required this.entries,
    required this.selected,
    required this.onSelected,
  });

  static const _rowHeight = 44.0;
  static const _columns = <({String label, double width})>[
    (label: 'Time', width: 96),
    (label: 'Level', width: 96),
    (label: 'Category', width: 136),
    (label: 'Message', width: 420),
    (label: 'Details', width: 96),
  ];

  final List<LogEntry> entries;
  final LogEntry? selected;
  final ValueChanged<LogEntry> onSelected;

  @override
  Widget build(BuildContext context) {
    final width = _columns.fold<double>(
      0,
      (total, column) => total + column.width,
    );
    return Semantics(
      label: 'Logs table',
      container: true,
      child: ClipRect(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: width,
            child: Column(
              children: [
                const _LogsHeader(columns: _columns),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemExtent: _rowHeight,
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entry = entries[index];
                      return _LogsRow(
                        entry: entry,
                        columns: _columns,
                        selected: selected?.id == entry.id,
                        onSelected: onSelected,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LogsHeader extends StatelessWidget {
  const _LogsHeader({required this.columns});

  final List<({String label, double width})> columns;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.labelLarge;
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          for (final column in columns)
            SizedBox(
              width: column.width,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(column.label, style: style),
              ),
            ),
        ],
      ),
    );
  }
}

class _LogsRow extends StatelessWidget {
  const _LogsRow({
    required this.entry,
    required this.columns,
    required this.selected,
    required this.onSelected,
  });

  final LogEntry entry;
  final List<({String label, double width})> columns;
  final bool selected;
  final ValueChanged<LogEntry> onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = selected ? scheme.secondaryContainer : null;
    return Material(
      color: background,
      child: InkWell(
        onTap: () => onSelected(entry),
        child: Row(
          children: [
            _LogCell(width: columns[0].width, text: _formatTime(entry.timeUtc)),
            _LogCell(width: columns[1].width, text: entry.level.name),
            _LogCell(
              width: columns[2].width,
              text: entry.category.displayLabel,
            ),
            SizedBox(
              width: columns[3].width,
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () => onSelected(entry),
                  child: Text(
                    entry.message,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ),
            ),
            _LogCell(
              width: columns[4].width,
              text: entry.details == null ? 'No' : 'Yes',
            ),
          ],
        ),
      ),
    );
  }
}

class _LogCell extends StatelessWidget {
  const _LogCell({required this.width, required this.text});

  final double width;
  final String text;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(text, overflow: TextOverflow.ellipsis, maxLines: 1),
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
