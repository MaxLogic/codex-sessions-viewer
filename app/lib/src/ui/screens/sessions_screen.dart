import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../commands/resume_command_generator.dart';
import '../../config/app_settings.dart';
import '../models/session_row_view_model.dart';
import '../widgets/command_preview.dart';
import '../widgets/session_detail_pane.dart';

export '../models/session_row_view_model.dart';

enum SessionsPlatformFilter { both, windows, wsl }

enum SessionsArchivedFilter { activeOnly, archivedOnly, all }

enum SessionRowAction {
  openPath,
  copyPath,
  copyPlainResumeCommand,
  copyPlatformResumeCommand,
  openTerminalResume,
  copyTerminalCommand,
  togglePin,
  toggleArchive,
  reparse,
}

typedef SessionActionCallback = Future<void> Function(SessionActionRequest);

class SessionActionRequest {
  const SessionActionRequest({
    required this.row,
    required this.action,
    this.payload,
  });

  final SessionRowViewModel row;
  final SessionRowAction action;
  final String? payload;
}

class SessionsScreen extends StatefulWidget {
  // ignore: prefer_const_constructors_in_immutables
  SessionsScreen({
    super.key,
    this.initialRows = const [],
    this.onRefresh,
    this.onRefreshResult,
    this.onOpenSettings,
    this.onTestWslPath,
    this.onSessionAction,
    this.settings,
    this.initialStatusMessage = '',
  });

  final List<SessionRowViewModel> initialRows;
  final Future<List<SessionRowViewModel>> Function()? onRefresh;
  final Future<SessionsRefreshResult> Function()? onRefreshResult;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onTestWslPath;
  final SessionActionCallback? onSessionAction;
  final AppSettings? settings;
  final String initialStatusMessage;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  final _searchController = TextEditingController();
  final _pathController = TextEditingController();
  var _platformFilter = SessionsPlatformFilter.both;
  var _archivedFilter = SessionsArchivedFilter.activeOnly;
  var _isScanning = false;
  var _scanAnnouncement = '';
  String? _selectedId;
  late List<SessionRowViewModel> _rows;

  @override
  void initState() {
    super.initState();
    _rows = List.of(widget.initialRows);
    _scanAnnouncement = widget.initialStatusMessage;
    _searchController.addListener(_filtersChanged);
    _pathController.addListener(_filtersChanged);
  }

  @override
  void didUpdateWidget(covariant SessionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialRows != widget.initialRows) {
      _rows = List.of(widget.initialRows);
      _retainSelection();
    }
  }

  @override
  void dispose() {
    _searchController
      ..removeListener(_filtersChanged)
      ..dispose();
    _pathController
      ..removeListener(_filtersChanged)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final visibleRows = _visibleRows;
    final selectedRow = _selectedRow(visibleRows);
    return Material(
      child: FocusTraversalGroup(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _FilterBar(
              searchController: _searchController,
              pathController: _pathController,
              platformFilter: _platformFilter,
              archivedFilter: _archivedFilter,
              isScanning: _isScanning,
              onPlatformChanged: (value) {
                setState(() {
                  _platformFilter = value;
                  _retainSelection();
                });
              },
              onArchivedChanged: (value) {
                setState(() {
                  _archivedFilter = value;
                  _retainSelection();
                });
              },
              onClearFilters: _clearFilters,
              onRefresh: _refresh,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Semantics(
                liveRegion: true,
                label: _resultCountText(visibleRows.length),
                child: Text(_resultCountText(visibleRows.length)),
              ),
            ),
            if (_scanAnnouncement.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Semantics(
                  liveRegion: true,
                  child: Text(_scanAnnouncement),
                ),
              ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    flex: 3,
                    child: visibleRows.isEmpty
                        ? _SessionsEmptyState(
                            hasRows: _rows.isNotEmpty,
                            hasActiveFilters: _hasActiveFilters,
                            statusMessage: _scanAnnouncement,
                            unreachablePaths: _unreachablePaths,
                            onClearFilters: _clearFilters,
                            onOpenSettings: widget.onOpenSettings,
                            onTestWslPath: widget.onTestWslPath ?? _refresh,
                          )
                        : _SessionsTable(
                            rows: visibleRows,
                            selectedId: _selectedId,
                            onSelect: _select,
                            onAction: _handleSessionAction,
                            settings: widget.settings ?? AppSettings.defaults(),
                          ),
                  ),
                  VerticalDivider(
                    width: 1,
                    thickness: 1,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  Expanded(
                    flex: 2,
                    child: _SessionDetailPlaceholder(
                      row: selectedRow,
                      settings: widget.settings ?? AppSettings.defaults(),
                      onSessionAction: selectedRow == null
                          ? null
                          : (action) =>
                                _handleDetailAction(selectedRow, action),
                      onRunTerminalCommand: selectedRow == null
                          ? null
                          : (command) => _handleSessionAction(
                              SessionActionRequest(
                                row: selectedRow,
                                action: SessionRowAction.openTerminalResume,
                                payload: command,
                              ),
                            ),
                      onEditTerminalCommand: selectedRow == null
                          ? null
                          : (command) => _handleSessionAction(
                              SessionActionRequest(
                                row: selectedRow,
                                action: SessionRowAction.openTerminalResume,
                                payload: command,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<SessionRowViewModel> get _visibleRows {
    final search = _searchController.text.trim().toLowerCase();
    final path = _pathController.text
        .trim()
        .replaceAll(r'\', '/')
        .toLowerCase();
    return [
      for (final row in _rows)
        if (_matchesArchived(row) &&
            _matchesPlatform(row) &&
            _matchesPath(row, path) &&
            _matchesSearch(row, search))
          row,
    ];
  }

  bool _matchesArchived(SessionRowViewModel row) {
    return switch (_archivedFilter) {
      SessionsArchivedFilter.activeOnly => !row.isArchived,
      SessionsArchivedFilter.archivedOnly => row.isArchived,
      SessionsArchivedFilter.all => true,
    };
  }

  bool _matchesPlatform(SessionRowViewModel row) {
    return switch (_platformFilter) {
      SessionsPlatformFilter.both => true,
      SessionsPlatformFilter.windows =>
        row.platform == SessionRowPlatform.windows,
      SessionsPlatformFilter.wsl => row.platform == SessionRowPlatform.wsl,
    };
  }

  bool _matchesPath(SessionRowViewModel row, String path) {
    if (path.isEmpty) {
      return true;
    }
    return row.path.replaceAll(r'\', '/').toLowerCase().contains(path);
  }

  bool _matchesSearch(SessionRowViewModel row, String search) {
    if (search.isEmpty) {
      return true;
    }
    return [
      row.title,
      row.summary,
      row.project,
      row.path,
      row.platformLabel,
      row.model,
      row.status,
      ...row.tags,
    ].any((value) => value.toLowerCase().contains(search));
  }

  bool get _hasActiveFilters {
    return _searchController.text.trim().isNotEmpty ||
        _pathController.text.trim().isNotEmpty ||
        _platformFilter != SessionsPlatformFilter.both ||
        _archivedFilter != SessionsArchivedFilter.activeOnly;
  }

  List<String> get _unreachablePaths {
    final source = _scanAnnouncement;
    final marker = 'Unreachable paths: ';
    final markerIndex = source.indexOf(marker);
    if (markerIndex < 0) {
      return const [];
    }
    return source
        .substring(markerIndex + marker.length)
        .split(';')
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
  }

  SessionRowViewModel? _selectedRow(List<SessionRowViewModel> visibleRows) {
    final selectedId = _selectedId;
    if (selectedId == null) {
      return null;
    }
    for (final row in visibleRows) {
      if (row.id == selectedId) {
        return row;
      }
    }
    return null;
  }

  void _select(String id) {
    setState(() {
      _selectedId = id;
    });
  }

  void _filtersChanged() {
    setState(_retainSelection);
  }

  void _retainSelection() {
    final selectedId = _selectedId;
    if (selectedId == null) {
      return;
    }
    if (!_visibleRows.any((row) => row.id == selectedId)) {
      _selectedId = null;
    }
  }

  void _clearFilters() {
    _searchController.removeListener(_filtersChanged);
    _pathController.removeListener(_filtersChanged);
    try {
      setState(() {
        _searchController.clear();
        _pathController.clear();
        _platformFilter = SessionsPlatformFilter.both;
        _archivedFilter = SessionsArchivedFilter.activeOnly;
        _retainSelection();
      });
    } finally {
      _searchController.addListener(_filtersChanged);
      _pathController.addListener(_filtersChanged);
    }
  }

  Future<void> _refresh() async {
    if (_isScanning) {
      return;
    }
    setState(() {
      _isScanning = true;
      _scanAnnouncement = 'Scanning started';
    });
    try {
      final refreshResult = await _refreshResult();
      if (!mounted) {
        return;
      }
      setState(() {
        _rows = List.of(refreshResult.rows);
        _scanAnnouncement = refreshResult.statusMessage;
        _retainSelection();
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _scanAnnouncement = 'Refresh failed. $error';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  Future<SessionsRefreshResult> _refreshResult() async {
    final refreshResult = widget.onRefreshResult;
    if (refreshResult != null) {
      return refreshResult();
    }
    final refreshRows = widget.onRefresh;
    if (refreshRows != null) {
      final rows = await refreshRows();
      return SessionsRefreshResult.scanFinished(rows);
    }
    return SessionsRefreshResult.scanFinished(_rows);
  }

  Future<void> _handleSessionAction(SessionActionRequest request) async {
    final callback = widget.onSessionAction;
    if (callback != null) {
      await callback(request);
      return;
    }
    final payload = request.payload;
    final messenger = ScaffoldMessenger.of(context);
    if (payload != null && _isCopyAction(request.action)) {
      await Clipboard.setData(ClipboardData(text: payload));
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(content: Text(_copySuccessMessage(request.action))),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(content: Text('${request.action.label} is not wired yet.')),
    );
  }

  Future<void> _handleDetailAction(
    SessionRowViewModel row,
    SessionDetailAction action,
  ) async {
    final commandSet =
        ResumeCommandGenerator(
          settings: widget.settings ?? AppSettings.defaults(),
        ).build(
          ResumeCommandSession(
            sessionId: row.sessionId,
            sourceType: row.platform == SessionRowPlatform.wsl
                ? ResumeSessionSourceType.wsl
                : ResumeSessionSourceType.windows,
            workingDirectory: row.workingDirectoryForCommands,
          ),
        );
    final request = switch (action) {
      SessionDetailAction.openContainingFolder => SessionActionRequest(
        row: row,
        action: SessionRowAction.openPath,
        payload: row.sourcePathForDisplay,
      ),
      SessionDetailAction.openTerminalResume => SessionActionRequest(
        row: row,
        action: SessionRowAction.openTerminalResume,
        payload: commandSet.terminalLaunchCommand,
      ),
      SessionDetailAction.reparse => SessionActionRequest(
        row: row,
        action: SessionRowAction.reparse,
      ),
      SessionDetailAction.togglePin => SessionActionRequest(
        row: row,
        action: SessionRowAction.togglePin,
      ),
      SessionDetailAction.toggleArchive => SessionActionRequest(
        row: row,
        action: SessionRowAction.toggleArchive,
      ),
      SessionDetailAction.openTerminalHere ||
      SessionDetailAction.exportMarkdown ||
      SessionDetailAction.editTags ||
      SessionDetailAction.assignProject => null,
    };
    if (request != null) {
      await _handleSessionAction(request);
    }
  }

  bool _isCopyAction(SessionRowAction action) {
    return switch (action) {
      SessionRowAction.copyPath ||
      SessionRowAction.copyPlainResumeCommand ||
      SessionRowAction.copyPlatformResumeCommand ||
      SessionRowAction.copyTerminalCommand => true,
      _ => false,
    };
  }

  String _copySuccessMessage(SessionRowAction action) {
    return switch (action) {
      SessionRowAction.copyPath => 'Session path copied.',
      SessionRowAction.copyPlainResumeCommand => 'Plain resume command copied.',
      SessionRowAction.copyPlatformResumeCommand =>
        'Platform resume command copied.',
      SessionRowAction.copyTerminalCommand => 'Terminal launch command copied.',
      _ => 'Copied.',
    };
  }
}

class SessionsRefreshResult {
  const SessionsRefreshResult({
    required this.rows,
    required this.statusMessage,
  });

  factory SessionsRefreshResult.scanFinished(List<SessionRowViewModel> rows) {
    return SessionsRefreshResult(
      rows: rows,
      statusMessage:
          'Scan finished. ${rows.length} ${rows.length == 1 ? 'session' : 'sessions'} found.',
    );
  }

  final List<SessionRowViewModel> rows;
  final String statusMessage;
}

class _SessionsEmptyState extends StatelessWidget {
  const _SessionsEmptyState({
    required this.hasRows,
    required this.hasActiveFilters,
    required this.statusMessage,
    required this.unreachablePaths,
    required this.onClearFilters,
    required this.onOpenSettings,
    required this.onTestWslPath,
  });

  final bool hasRows;
  final bool hasActiveFilters;
  final String statusMessage;
  final List<String> unreachablePaths;
  final VoidCallback onClearFilters;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onTestWslPath;

  @override
  Widget build(BuildContext context) {
    final isUnreachable = statusMessage.toLowerCase().contains('unreachable');
    final title = isUnreachable
        ? 'Codex session path is currently unreachable.'
        : hasRows && hasActiveFilters
        ? 'No sessions match the current filters.'
        : 'No sessions found.';
    final body = isUnreachable
        ? 'Cached sessions remain visible when available. Check the configured path, then run Refresh.'
        : hasRows && hasActiveFilters
        ? 'Try clearing filters or expanding the date range.'
        : 'Check your Windows and WSL Codex paths in Settings, then run Refresh.';
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Session table', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 24),
          Semantics(
            liveRegion: true,
            container: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                Text(body),
                if (isUnreachable && unreachablePaths.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  SelectableText(
                    'Configured path: ${unreachablePaths.join('; ')}',
                  ),
                ],
                if (isUnreachable) ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: onTestWslPath,
                        child: const Text('Test WSL path'),
                      ),
                      OutlinedButton(
                        onPressed: onOpenSettings,
                        child: const Text('Open Settings'),
                      ),
                    ],
                  ),
                ] else if (hasRows && hasActiveFilters) ...[
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: onClearFilters,
                    child: const Text('Clear filters'),
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton(
                        onPressed: onOpenSettings,
                        child: const Text('Open Settings'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.searchController,
    required this.pathController,
    required this.platformFilter,
    required this.archivedFilter,
    required this.isScanning,
    required this.onPlatformChanged,
    required this.onArchivedChanged,
    required this.onClearFilters,
    required this.onRefresh,
  });

  final TextEditingController searchController;
  final TextEditingController pathController;
  final SessionsPlatformFilter platformFilter;
  final SessionsArchivedFilter archivedFilter;
  final bool isScanning;
  final ValueChanged<SessionsPlatformFilter> onPlatformChanged;
  final ValueChanged<SessionsArchivedFilter> onArchivedChanged;
  final VoidCallback onClearFilters;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: 920,
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Semantics(
                        label: 'Session search',
                        textField: true,
                        child: TextField(
                          controller: searchController,
                          decoration: const InputDecoration(
                            labelText: 'Search',
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _FilterSemantics(
                        label: 'Platform filter',
                        child: DropdownButtonFormField<SessionsPlatformFilter>(
                          key: ValueKey(platformFilter),
                          initialValue: platformFilter,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Platform',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: SessionsPlatformFilter.both,
                              child: Text('Both'),
                            ),
                            DropdownMenuItem(
                              value: SessionsPlatformFilter.windows,
                              child: Text('Windows'),
                            ),
                            DropdownMenuItem(
                              value: SessionsPlatformFilter.wsl,
                              child: Text('WSL'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              onPlatformChanged(value);
                            }
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _FilterSemantics(
                        label: 'Time range filter',
                        child: DropdownButtonFormField<String>(
                          initialValue: 'Last 30 days',
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Time',
                            helperText:
                                'Additional time ranges are not available yet.',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'Last 30 days',
                              child: Text('Last 30 days'),
                            ),
                          ],
                          onChanged: null,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: 1240,
                child: Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: Semantics(
                        label: 'Path filter',
                        textField: true,
                        child: TextField(
                          controller: pathController,
                          decoration: const InputDecoration(labelText: 'Path'),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(child: _staticFilter('Project filter', 'Project')),
                    const SizedBox(width: 12),
                    Expanded(child: _staticFilter('Tags filter', 'Tags')),
                    const SizedBox(width: 12),
                    Expanded(child: _staticFilter('Model filter', 'Model')),
                    const SizedBox(width: 12),
                    Expanded(child: _staticFilter('Status filter', 'Status')),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _FilterSemantics(
                        label: 'Archived filter',
                        child: DropdownButtonFormField<SessionsArchivedFilter>(
                          key: ValueKey(archivedFilter),
                          initialValue: archivedFilter,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Archived',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: SessionsArchivedFilter.activeOnly,
                              child: Text('Active only'),
                            ),
                            DropdownMenuItem(
                              value: SessionsArchivedFilter.archivedOnly,
                              child: Text('Archived only'),
                            ),
                            DropdownMenuItem(
                              value: SessionsArchivedFilter.all,
                              child: Text('All'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              onArchivedChanged(value);
                            }
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(
                  onPressed: isScanning ? null : onRefresh,
                  child: Text(isScanning ? 'Scanning...' : 'Refresh'),
                ),
                OutlinedButton(
                  onPressed: onClearFilters,
                  child: const Text('Clear filters'),
                ),
                const Tooltip(
                  message: 'Advanced filters are not available yet.',
                  child: OutlinedButton(
                    onPressed: null,
                    child: Text('Advanced filters'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _staticFilter(String semanticsLabel, String label) {
    return _FilterSemantics(
      label: semanticsLabel,
      child: DropdownButtonFormField<String>(
        initialValue: 'All',
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          helperText: '$label values are not available yet.',
        ),
        items: const [DropdownMenuItem(value: 'All', child: Text('All'))],
        onChanged: null,
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

class _SessionsTable extends StatelessWidget {
  const _SessionsTable({
    required this.rows,
    required this.selectedId,
    required this.onSelect,
    required this.onAction,
    required this.settings,
  });

  final List<SessionRowViewModel> rows;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final SessionActionCallback onAction;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Text(
            'Session table',
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  showCheckboxColumn: false,
                  dataRowMinHeight: 64,
                  dataRowMaxHeight: 80,
                  columns: const [
                    DataColumn(label: Text('Date')),
                    DataColumn(label: Text('Last message')),
                    DataColumn(label: Text('Platform')),
                    DataColumn(label: Text('Project')),
                    DataColumn(label: Text('Path')),
                    DataColumn(label: Text('Title')),
                    DataColumn(label: Text('Summary')),
                    DataColumn(label: Text('Messages')),
                    DataColumn(label: Text('Tokens')),
                    DataColumn(label: Text('Model')),
                    DataColumn(label: Text('Tags')),
                    DataColumn(label: Text('Status')),
                    DataColumn(label: Text('Actions')),
                  ],
                  rows: [
                    for (final row in rows)
                      DataRow(
                        selected: row.id == selectedId,
                        color: WidgetStateProperty.resolveWith(
                          (_) => _rowColor(context, row),
                        ),
                        onSelectChanged: (_) => onSelect(row.id),
                        cells: [
                          _dateCell(row),
                          _cell(
                            row.lastMessageAtUtc.shortDateTime,
                            row,
                            width: 120,
                          ),
                          _cell(row.platformLabel, row, width: 72),
                          _cell(row.project, row, width: 112),
                          _cell(row.path, row, width: 160),
                          _cell(row.title, row, width: 148),
                          _cell(row.summary, row, width: 180),
                          _cell(row.messageCount.toString(), row, width: 70),
                          _cell(row.totalTokens.toString(), row, width: 70),
                          _cell(row.model, row, width: 92),
                          _cell(row.tags.join(', '), row, width: 100),
                          DataCell(
                            _StatusCell(row: row),
                            onTap: () => onSelect(row.id),
                          ),
                          DataCell(
                            _ActionsMenu(
                              row: row,
                              onAction: onAction,
                              settings: settings,
                            ),
                            onTap: () => onSelect(row.id),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  DataCell _cell(
    String text,
    SessionRowViewModel row, {
    required double width,
    String? semanticLabel,
  }) {
    return DataCell(
      semanticLabel == null
          ? SizedBox(
              width: width,
              child: Text(text, overflow: TextOverflow.ellipsis),
            )
          : Semantics(
              label: semanticLabel,
              button: true,
              child: ExcludeSemantics(
                child: SizedBox(
                  width: width,
                  child: Text(text, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
      onTap: () => onSelect(row.id),
    );
  }

  DataCell _dateCell(SessionRowViewModel row) {
    final badges = [
      if (row.isPinned) 'Pinned',
      if (row.isArchived) 'Archived',
      if (row.hasError) row.status,
    ];
    return DataCell(
      Semantics(
        label: 'Select session ${row.title}',
        button: true,
        child: ExcludeSemantics(
          child: SizedBox(
            width: 120,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.startedAtUtc.shortDateTime),
                for (final badge in badges)
                  Text(
                    badge,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
      ),
      onTap: () => onSelect(row.id),
    );
  }

  Color? _rowColor(BuildContext context, SessionRowViewModel row) {
    final scheme = Theme.of(context).colorScheme;
    if (row.hasError) {
      return scheme.errorContainer.withValues(alpha: 0.55);
    }
    if (row.isArchived) {
      return scheme.surfaceContainerHighest.withValues(alpha: 0.65);
    }
    if (row.isPinned) {
      return scheme.primaryContainer.withValues(alpha: 0.45);
    }
    return null;
  }
}

class _StatusCell extends StatelessWidget {
  const _StatusCell({required this.row});

  final SessionRowViewModel row;

  @override
  Widget build(BuildContext context) {
    final labels = <String>[
      if (row.isPinned) 'Pinned',
      if (row.isArchived) 'Archived',
      row.status,
    ];
    return Text(labels.join(' | '));
  }
}

class _ActionsMenu extends StatelessWidget {
  const _ActionsMenu({
    required this.row,
    required this.onAction,
    required this.settings,
  });

  final SessionRowViewModel row;
  final SessionActionCallback onAction;
  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    final commandSet = _commandSet(row);
    return Semantics(
      label: 'Actions for ${row.title}',
      button: true,
      child: PopupMenuButton<SessionRowAction>(
        tooltip: 'More actions',
        onSelected: (action) => onAction(
          SessionActionRequest(
            row: row,
            action: action,
            payload: _payloadFor(row, commandSet, action),
          ),
        ),
        itemBuilder: (context) => [
          _item(SessionRowAction.openPath, 'Open path'),
          _item(SessionRowAction.copyPath, 'Copy path'),
          _item(
            SessionRowAction.copyPlainResumeCommand,
            'Copy plain resume command',
            enabled: commandSet.plainResumeCommand != null,
            disabledReason: commandSet.disabledReason,
          ),
          _item(
            SessionRowAction.copyPlatformResumeCommand,
            'Copy platform resume command',
            enabled: commandSet.platformResumeCommand != null,
            disabledReason: commandSet.disabledReason,
          ),
          _item(
            SessionRowAction.openTerminalResume,
            'Open terminal and resume',
            enabled: commandSet.terminalLaunchCommand != null,
            disabledReason:
                commandSet.terminalDisabledReason ?? commandSet.disabledReason,
          ),
          _item(
            SessionRowAction.copyTerminalCommand,
            'Copy terminal command',
            enabled: commandSet.terminalLaunchCommand != null,
            disabledReason:
                commandSet.terminalDisabledReason ?? commandSet.disabledReason,
          ),
          _item(
            SessionRowAction.togglePin,
            row.isPinned ? 'Unpin session' : 'Pin session',
          ),
          _item(
            SessionRowAction.toggleArchive,
            row.isArchived ? 'Unarchive session' : 'Archive session',
          ),
          _item(SessionRowAction.reparse, 'Re-parse session'),
        ],
      ),
    );
  }

  PopupMenuItem<SessionRowAction> _item(
    SessionRowAction action,
    String label, {
    bool enabled = true,
    String? disabledReason,
  }) {
    return PopupMenuItem<SessionRowAction>(
      value: action,
      enabled: enabled,
      child: enabled || disabledReason == null
          ? Text(label)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                Text(disabledReason, style: const TextStyle(fontSize: 12)),
              ],
            ),
    );
  }

  ResumeCommandSet _commandSet(SessionRowViewModel row) {
    return ResumeCommandGenerator(settings: settings).build(
      ResumeCommandSession(
        sessionId: row.sessionId,
        sourceType: row.platform == SessionRowPlatform.wsl
            ? ResumeSessionSourceType.wsl
            : ResumeSessionSourceType.windows,
        workingDirectory: row.workingDirectoryForCommands,
      ),
    );
  }

  String? _payloadFor(
    SessionRowViewModel row,
    ResumeCommandSet commandSet,
    SessionRowAction action,
  ) {
    return switch (action) {
      SessionRowAction.openPath ||
      SessionRowAction.copyPath => row.sourcePathForDisplay,
      SessionRowAction.copyPlainResumeCommand => commandSet.plainResumeCommand,
      SessionRowAction.copyPlatformResumeCommand =>
        commandSet.platformResumeCommand,
      SessionRowAction.openTerminalResume ||
      SessionRowAction.copyTerminalCommand => commandSet.terminalLaunchCommand,
      SessionRowAction.togglePin ||
      SessionRowAction.toggleArchive ||
      SessionRowAction.reparse => null,
    };
  }
}

extension on SessionRowAction {
  String get label {
    return switch (this) {
      SessionRowAction.openPath => 'Open path',
      SessionRowAction.copyPath => 'Copy path',
      SessionRowAction.copyPlainResumeCommand => 'Copy plain resume command',
      SessionRowAction.copyPlatformResumeCommand =>
        'Copy platform resume command',
      SessionRowAction.openTerminalResume => 'Open terminal and resume',
      SessionRowAction.copyTerminalCommand => 'Copy terminal command',
      SessionRowAction.togglePin => 'Pin or unpin session',
      SessionRowAction.toggleArchive => 'Archive or unarchive session',
      SessionRowAction.reparse => 'Re-parse session',
    };
  }
}

class _SessionDetailPlaceholder extends StatelessWidget {
  const _SessionDetailPlaceholder({
    required this.row,
    required this.settings,
    required this.onSessionAction,
    required this.onRunTerminalCommand,
    required this.onEditTerminalCommand,
  });

  final SessionRowViewModel? row;
  final AppSettings settings;
  final SessionDetailActionCallback? onSessionAction;
  final TerminalCommandCallback? onRunTerminalCommand;
  final TerminalCommandCallback? onEditTerminalCommand;

  @override
  Widget build(BuildContext context) {
    if (row != null) {
      return SessionDetailPane(
        row: row!,
        settings: settings,
        onSessionAction: onSessionAction,
        onRunTerminalCommand: onRunTerminalCommand,
        onEditTerminalCommand: onEditTerminalCommand,
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Session detail', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text('No session selected'),
        ],
      ),
    );
  }
}

String _resultCountText(int count) =>
    '$count ${count == 1 ? 'session' : 'sessions'} visible';

extension on DateTime {
  String get shortDateTime {
    final local = toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
