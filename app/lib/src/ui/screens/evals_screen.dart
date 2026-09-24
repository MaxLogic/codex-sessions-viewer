import 'package:flutter/material.dart';

import '../../export/eval_dataset_exporter.dart';
import '../models/session_label_formatter.dart';
import '../models/session_row_view_model.dart';

typedef EvalMetadataUpdateCallback =
    Future<void> Function(
      SessionRowViewModel row,
      SessionEvalMetadata metadata,
    );
typedef EvalsExportCallback =
    Future<EvalsScreenExportResult> Function(EvalsScreenExportRequest request);

enum EvalsScreenExportScope { selected, filtered }

class EvalsScreenExportRequest {
  const EvalsScreenExportRequest({
    required this.scope,
    required this.rows,
    required this.format,
    required this.turnMode,
    required this.options,
  });

  final EvalsScreenExportScope scope;
  final List<SessionRowViewModel> rows;
  final EvalDatasetFormat format;
  final EvalTurnMode turnMode;
  final EvalDatasetExportOptions options;
}

class EvalsScreenExportResult {
  const EvalsScreenExportResult.completed({
    required this.exportedCount,
    this.skippedCount = 0,
  }) : cancelled = false;

  const EvalsScreenExportResult.cancelled()
    : cancelled = true,
      exportedCount = 0,
      skippedCount = 0;

  final bool cancelled;
  final int exportedCount;
  final int skippedCount;
}

enum _EvalStatusFilter {
  all('All statuses', ''),
  notReviewed('Not reviewed', 'not_reviewed'),
  needsReview('Needs review', 'needs_review'),
  correct('Correct', 'correct'),
  incorrect('Incorrect', 'incorrect'),
  blocked('Blocked', 'blocked');

  const _EvalStatusFilter(this.label, this.value);

  final String label;
  final String value;
}

enum _EvalSourceFilter {
  all('All sources'),
  windows('Windows'),
  wsl('WSL');

  const _EvalSourceFilter(this.label);

  final String label;
}

class EvalsScreen extends StatefulWidget {
  const EvalsScreen({
    super.key,
    required this.initialRows,
    this.statusMessage = '',
    this.onUpdateEvalMetadata,
    this.onExport,
  });

  final List<SessionRowViewModel> initialRows;
  final String statusMessage;
  final EvalMetadataUpdateCallback? onUpdateEvalMetadata;
  final EvalsExportCallback? onExport;

  @override
  State<EvalsScreen> createState() => _EvalsScreenState();
}

class _EvalsScreenState extends State<EvalsScreen> {
  late List<SessionRowViewModel> _rows;
  final _textController = TextEditingController();
  final _tagController = TextEditingController();
  final _projectController = TextEditingController();
  final _modelController = TextEditingController();
  final _selectedIds = <String>{};
  var _statusFilter = _EvalStatusFilter.all;
  var _sourceFilter = _EvalSourceFilter.all;
  var _format = EvalDatasetFormat.deepEvalJson;
  var _turnMode = EvalTurnMode.fullConversation;
  var _anonymizePaths = true;
  var _filterResetGeneration = 0;

  @override
  void initState() {
    super.initState();
    _rows = widget.initialRows;
  }

  @override
  void didUpdateWidget(covariant EvalsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.initialRows, widget.initialRows)) {
      _rows = widget.initialRows;
      final rowIds = _rows.map((row) => row.id).toSet();
      _selectedIds.removeWhere((id) => !rowIds.contains(id));
    }
  }

  @override
  void dispose() {
    _textController.dispose();
    _tagController.dispose();
    _projectController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  List<SessionRowViewModel> get _visibleRows {
    final text = _textController.text.trim().toLowerCase();
    final tag = _tagController.text.trim().toLowerCase();
    final project = _projectController.text.trim().toLowerCase();
    final model = _modelController.text.trim().toLowerCase();
    return [
      for (final row in _rows)
        if (row.evalReady &&
            _matchesText(row, text) &&
            _matchesStatus(row) &&
            _matchesTag(row, tag) &&
            _matchesSource(row) &&
            _contains(row.project, project) &&
            _matchesModel(row, model))
          row,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final visibleRows = _visibleRows;
    return Material(
      child: Semantics(
        label: 'Evals content',
        container: true,
        explicitChildNodes: true,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Heading(visibleCount: visibleRows.length),
              const SizedBox(height: 12),
              _buildFilters(),
              const SizedBox(height: 12),
              _buildExportBar(visibleRows),
              if (widget.statusMessage.trim().isNotEmpty) ...[
                const SizedBox(height: 8),
                Semantics(
                  liveRegion: true,
                  label: widget.statusMessage,
                  child: ExcludeSemantics(child: Text(widget.statusMessage)),
                ),
              ],
              const SizedBox(height: 12),
              Expanded(
                child: visibleRows.isEmpty
                    ? const _EmptyState()
                    : Semantics(
                        label: 'Evals list',
                        container: true,
                        child: ListView.builder(
                          itemCount: visibleRows.length,
                          itemExtent: 112,
                          itemBuilder: (context, index) => _EvalRow(
                            row: visibleRows[index],
                            selected: _selectedIds.contains(
                              visibleRows[index].id,
                            ),
                            onSelected: (selected) {
                              setState(() {
                                if (selected) {
                                  _selectedIds.add(visibleRows[index].id);
                                } else {
                                  _selectedIds.remove(visibleRows[index].id);
                                }
                              });
                            },
                            onEdit: () => _editRow(visibleRows[index]),
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilters() {
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 240,
          child: Semantics(
            label: 'Evals text filter',
            textField: true,
            child: TextField(
              controller: _textController,
              decoration: const InputDecoration(
                labelText: 'Search',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
        SizedBox(
          width: 160,
          child: _FilterSemantics(
            label: 'Eval status filter',
            child: DropdownButtonFormField<_EvalStatusFilter>(
              key: ValueKey('status-filter-$_filterResetGeneration'),
              initialValue: _statusFilter,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Status',
                isDense: true,
              ),
              items: [
                for (final value in _EvalStatusFilter.values)
                  DropdownMenuItem(value: value, child: Text(value.label)),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _statusFilter = value);
                }
              },
            ),
          ),
        ),
        _textFilter('Eval tags filter', 'Tags', _tagController),
        SizedBox(
          width: 140,
          child: _FilterSemantics(
            label: 'Eval source filter',
            child: DropdownButtonFormField<_EvalSourceFilter>(
              key: ValueKey('source-filter-$_filterResetGeneration'),
              initialValue: _sourceFilter,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Source',
                isDense: true,
              ),
              items: [
                for (final value in _EvalSourceFilter.values)
                  DropdownMenuItem(value: value, child: Text(value.label)),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _sourceFilter = value);
                }
              },
            ),
          ),
        ),
        _textFilter('Eval project filter', 'Project', _projectController),
        _textFilter('Eval model provider filter', 'Model', _modelController),
        OutlinedButton(
          onPressed: _clearFilters,
          child: const Text('Clear filters'),
        ),
      ],
    );
  }

  Widget _textFilter(
    String semanticsLabel,
    String label,
    TextEditingController controller,
  ) {
    return SizedBox(
      width: 160,
      child: Semantics(
        label: semanticsLabel,
        textField: true,
        child: TextField(
          controller: controller,
          decoration: InputDecoration(labelText: label, isDense: true),
          onChanged: (_) => setState(() {}),
        ),
      ),
    );
  }

  Widget _buildExportBar(List<SessionRowViewModel> visibleRows) {
    final selectedRows = [
      for (final row in visibleRows)
        if (_selectedIds.contains(row.id)) row,
    ];
    final hasSelected = selectedRows.isNotEmpty;
    final hasFiltered = visibleRows.isNotEmpty;
    return Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        SizedBox(
          width: 190,
          child: _FilterSemantics(
            label: 'Eval export format',
            child: DropdownButtonFormField<EvalDatasetFormat>(
              initialValue: _format,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Format',
                isDense: true,
              ),
              items: [
                for (final value in EvalDatasetFormat.values)
                  DropdownMenuItem(
                    value: value,
                    child: Text(_formatLabel(value)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _format = value);
                }
              },
            ),
          ),
        ),
        SizedBox(
          width: 210,
          child: _FilterSemantics(
            label: 'Eval turn mode',
            child: DropdownButtonFormField<EvalTurnMode>(
              initialValue: _turnMode,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Turn mode',
                isDense: true,
              ),
              items: [
                for (final value in EvalTurnMode.values)
                  DropdownMenuItem(
                    value: value,
                    child: Text(_turnModeLabel(value)),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _turnMode = value);
                }
              },
            ),
          ),
        ),
        Semantics(
          label: 'Anonymize paths in eval export',
          toggled: _anonymizePaths,
          excludeSemantics: true,
          onTap: () => setState(() => _anonymizePaths = !_anonymizePaths),
          child: CheckboxMenuButton(
            value: _anonymizePaths,
            onChanged: (value) =>
                setState(() => _anonymizePaths = value ?? true),
            child: const Text('Anonymize paths'),
          ),
        ),
        Semantics(
          label: 'Export selected eval sessions',
          button: true,
          enabled: hasSelected,
          excludeSemantics: true,
          onTap: hasSelected
              ? () => _export(EvalsScreenExportScope.selected, selectedRows)
              : null,
          child: FilledButton(
            onPressed: hasSelected
                ? () => _export(EvalsScreenExportScope.selected, selectedRows)
                : null,
            child: const Text('Export selected'),
          ),
        ),
        Semantics(
          label: 'Export all filtered eval sessions',
          button: true,
          enabled: hasFiltered,
          excludeSemantics: true,
          onTap: hasFiltered
              ? () => _export(EvalsScreenExportScope.filtered, visibleRows)
              : null,
          child: OutlinedButton(
            onPressed: hasFiltered
                ? () => _export(EvalsScreenExportScope.filtered, visibleRows)
                : null,
            child: const Text('Export filtered'),
          ),
        ),
      ],
    );
  }

  void _clearFilters() {
    _textController.clear();
    _tagController.clear();
    _projectController.clear();
    _modelController.clear();
    setState(() {
      _statusFilter = _EvalStatusFilter.all;
      _sourceFilter = _EvalSourceFilter.all;
      _filterResetGeneration++;
    });
  }

  Future<void> _editRow(SessionRowViewModel row) async {
    var status = row.evalStatus;
    var notes = row.evalNotes;
    final metadata = await showDialog<SessionEvalMetadata>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Edit review for ${row.primaryIdentity}'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: status,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Eval review status',
                ),
                onChanged: (value) => status = value,
              ),
              TextFormField(
                initialValue: notes,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Eval notes'),
                onChanged: (value) => notes = value,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              SessionEvalMetadata(
                evalReady: true,
                status: _blankToNull(status),
                notes: _blankToNull(notes),
                expectedOutput: _blankToNull(row.evalExpectedOutput),
                reviewedAtUtc: DateTime.now().toUtc(),
              ),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (metadata == null) {
      return;
    }
    await widget.onUpdateEvalMetadata?.call(row, metadata);
    if (!mounted) {
      return;
    }
    setState(() {
      _replaceRow(row.copyWithEvalMetadata(metadata));
    });
  }

  Future<void> _export(
    EvalsScreenExportScope scope,
    List<SessionRowViewModel> rows,
  ) async {
    final result =
        await widget.onExport?.call(
          EvalsScreenExportRequest(
            scope: scope,
            rows: List.unmodifiable(rows),
            format: _format,
            turnMode: _turnMode,
            options: EvalDatasetExportOptions(anonymizePaths: _anonymizePaths),
          ),
        ) ??
        EvalsScreenExportResult.completed(exportedCount: rows.length);
    if (!mounted) {
      return;
    }
    if (result.cancelled) {
      return;
    }
    if (Scaffold.maybeOf(context) != null) {
      final skipped = result.skippedCount;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            skipped > 0
                ? 'Exported ${result.exportedCount} eval sessions. $skipped skipped.'
                : 'Exported ${result.exportedCount} eval sessions.',
          ),
        ),
      );
    }
  }

  void _replaceRow(SessionRowViewModel replacement) {
    final index = _rows.indexWhere((row) => row.id == replacement.id);
    if (index == -1) {
      return;
    }
    _rows = [..._rows.take(index), replacement, ..._rows.skip(index + 1)];
  }

  bool _matchesStatus(SessionRowViewModel row) {
    if (_statusFilter == _EvalStatusFilter.all) {
      return true;
    }
    final value = row.evalStatus.trim().toLowerCase();
    if (_statusFilter == _EvalStatusFilter.notReviewed) {
      return value.isEmpty ||
          value == 'not_reviewed' ||
          value == 'not reviewed' ||
          row.evalStatusLabel == 'Not reviewed';
    }
    return value == _statusFilter.value ||
        row.evalStatusLabel.toLowerCase() == _statusFilter.label.toLowerCase();
  }

  bool _matchesSource(SessionRowViewModel row) {
    return switch (_sourceFilter) {
      _EvalSourceFilter.all => true,
      _EvalSourceFilter.windows => row.platform == SessionRowPlatform.windows,
      _EvalSourceFilter.wsl => row.platform == SessionRowPlatform.wsl,
    };
  }

  static bool _matchesText(SessionRowViewModel row, String value) {
    if (value.isEmpty) {
      return true;
    }
    return [
      row.primaryIdentity,
      row.summary,
      row.project,
      row.platformLabel,
      row.modelProviderLabel,
      row.evalStatusLabel,
      row.evalNotes,
      row.evalExpectedOutput,
      ...row.tags,
    ].any((field) => _contains(field, value));
  }

  static bool _matchesTag(SessionRowViewModel row, String value) {
    if (value.isEmpty) {
      return true;
    }
    return row.tags.any((tag) => _contains(tag, value));
  }

  static bool _matchesModel(SessionRowViewModel row, String value) {
    if (value.isEmpty) {
      return true;
    }
    return [
      row.modelProviderLabel,
      row.modelLabel,
      row.providerLabel,
      row.model,
    ].any((field) => _contains(field, value));
  }
}

class _EvalRow extends StatelessWidget {
  const _EvalRow({
    required this.row,
    required this.selected,
    required this.onSelected,
    required this.onEdit,
  });

  final SessionRowViewModel row;
  final bool selected;
  final ValueChanged<bool> onSelected;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label:
          'Eval ${row.primaryIdentity}. Status ${row.evalStatusLabel}. ${row.project}.',
      selected: selected,
      container: true,
      explicitChildNodes: true,
      child: Material(
        color: selected
            ? theme.colorScheme.secondaryContainer.withValues(alpha: 0.45)
            : Colors.transparent,
        child: InkWell(
          onTap: () => onSelected(!selected),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  label: 'Select eval ${row.primaryIdentity}',
                  checked: selected,
                  onTap: () => onSelected(!selected),
                  child: ExcludeSemantics(
                    child: Checkbox(
                      value: selected,
                      onChanged: (value) => onSelected(value ?? false),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.primaryIdentity,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 30,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              _ChipText(row.evalStatusLabel),
                              _ChipText(row.project),
                              _ChipText(row.platformLabel),
                              if (row.providerLabel !=
                                  SessionLabelFormatter.unknown)
                                _ChipText(row.providerLabel),
                              _ChipText(row.modelLabel),
                              _ChipText(_shortDate(row.lastMessageAtUtc)),
                              if (row.evalNotes.trim().isNotEmpty)
                                const _ChipText('Notes'),
                              if (row.evalExpectedOutput.trim().isNotEmpty)
                                const _ChipText('Expected output'),
                              for (final tag in row.tags) _ChipText('#$tag'),
                            ],
                          ),
                        ),
                      ),
                      if (row.evalNotes.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          row.evalNotes,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Semantics(
                  label: 'Edit review for ${row.primaryIdentity}',
                  button: true,
                  onTap: onEdit,
                  child: ExcludeSemantics(
                    child: OutlinedButton(
                      onPressed: onEdit,
                      child: const Text('Review'),
                    ),
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

class _ChipText extends StatelessWidget {
  const _ChipText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          child: Text(text, style: Theme.of(context).textTheme.labelSmall),
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading({required this.visibleCount});

  final int visibleCount;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      label: 'Evals, $visibleCount visible',
      child: ExcludeSemantics(
        child: Row(
          children: [
            Text('Evals', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(width: 12),
            Text('$visibleCount visible'),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('No eval-ready sessions yet'),
            SizedBox(height: 6),
            Text('Mark sessions from Sessions view to review them here.'),
          ],
        ),
      ),
    );
  }
}

class _FilterSemantics extends StatelessWidget {
  const _FilterSemantics({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      container: true,
      explicitChildNodes: true,
      child: child,
    );
  }
}

String _formatLabel(EvalDatasetFormat format) {
  return switch (format) {
    EvalDatasetFormat.deepEvalJson => 'DeepEval JSON',
    EvalDatasetFormat.openAiJsonl => 'OpenAI JSONL',
    EvalDatasetFormat.promptfooJsonl => 'Promptfoo JSONL',
    EvalDatasetFormat.markdownFiles => 'Markdown',
    EvalDatasetFormat.plainTextFiles => 'Plain text',
  };
}

String _turnModeLabel(EvalTurnMode mode) {
  return switch (mode) {
    EvalTurnMode.fullConversation => 'Full conversation',
    EvalTurnMode.perUserAssistantTurn => 'Per turn',
    EvalTurnMode.finalAssistantAnswer => 'Final answer',
  };
}

String _shortDate(DateTime value) {
  final utc = value.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}

bool _contains(String field, String value) {
  return value.isEmpty || field.toLowerCase().contains(value);
}

String? _blankToNull(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
