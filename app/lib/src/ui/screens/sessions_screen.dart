import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

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
typedef SessionsRefreshProgressCallback =
    void Function(SessionsRefreshProgress progress);
typedef SessionsRefreshWithProgress =
    Future<SessionsRefreshResult> Function(
      SessionsRefreshProgressCallback onProgress,
    );
typedef SessionsRefreshOperationFactory =
    SessionsRefreshOperation Function(SessionsRefreshProgressCallback);
typedef SessionDetailLoader =
    Future<SessionRowViewModel?> Function(String sessionId);
typedef SessionTableStateChanged = void Function(SessionTableSettings);

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
    this.onRefreshWithProgress,
    this.onRefreshOperation,
    this.onOpenSettings,
    this.onTestWslPath,
    this.onSessionAction,
    this.onLoadSessionDetail,
    this.settings,
    this.initialTableState,
    this.onTableStateChanged,
    this.initialStatusMessage = '',
    this.autoRefreshToken = 0,
  });

  final List<SessionRowViewModel> initialRows;
  final Future<List<SessionRowViewModel>> Function()? onRefresh;
  final Future<SessionsRefreshResult> Function()? onRefreshResult;
  final SessionsRefreshWithProgress? onRefreshWithProgress;
  final SessionsRefreshOperationFactory? onRefreshOperation;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onTestWslPath;
  final SessionActionCallback? onSessionAction;
  final SessionDetailLoader? onLoadSessionDetail;
  final AppSettings? settings;
  final SessionTableSettings? initialTableState;
  final SessionTableStateChanged? onTableStateChanged;
  final String initialStatusMessage;
  final int autoRefreshToken;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  final _searchController = TextEditingController();
  final _pathController = TextEditingController();
  var _platformFilter = SessionsPlatformFilter.both;
  var _archivedFilter = SessionsArchivedFilter.activeOnly;
  var _newestPerProjectOnly = false;
  var _isScanning = false;
  var _isCancellingRefresh = false;
  var _scanAnnouncement = '';
  var _hasRefreshOwnedRows = false;
  String? _selectedId;
  String? _loadingDetailId;
  late List<SessionRowViewModel> _rows;
  late Map<String, double> _columnWidths;
  late List<SessionTableSortSettings> _sorts;
  late int _handledAutoRefreshToken;
  Timer? _relativeDateTimer;
  SessionsRefreshOperation? _activeRefreshOperation;

  @override
  void initState() {
    super.initState();
    _rows = List.of(widget.initialRows);
    final tableState =
        widget.initialTableState ??
        (widget.settings ?? AppSettings.defaults()).ui.sessionTable;
    _columnWidths = Map.of(tableState.columnWidths);
    _sorts = _normalizedSorts(tableState.sorts);
    _scanAnnouncement = widget.initialStatusMessage;
    _handledAutoRefreshToken = widget.autoRefreshToken;
    _searchController.addListener(_filtersChanged);
    _pathController.addListener(_filtersChanged);
    _relativeDateTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(covariant SessionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_hasRefreshOwnedRows && oldWidget.initialRows != widget.initialRows) {
      _replaceRows(widget.initialRows);
      _retainSelection();
    }
    if (!_isScanning &&
        oldWidget.initialStatusMessage != widget.initialStatusMessage) {
      _scanAnnouncement = widget.initialStatusMessage;
    }
    if (widget.autoRefreshToken != _handledAutoRefreshToken) {
      _handledAutoRefreshToken = widget.autoRefreshToken;
      if (widget.autoRefreshToken > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_isScanning) {
            unawaited(_refresh());
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _requestRefreshCancel(updateUi: false);
    _searchController
      ..removeListener(_filtersChanged)
      ..dispose();
    _pathController
      ..removeListener(_filtersChanged)
      ..dispose();
    _relativeDateTimer?.cancel();
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
              newestPerProjectOnly: _newestPerProjectOnly,
              isScanning: _isScanning,
              isCancellingRefresh: _isCancellingRefresh,
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
              onNewestPerProjectOnlyChanged: (value) {
                setState(() {
                  _newestPerProjectOnly = value;
                  _retainSelection();
                });
              },
              onClearFilters: _clearFilters,
              onRefresh: _refresh,
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
                            isScanning: _isScanning,
                            visibleCount: visibleRows.length,
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
                            columnWidths: _columnWidths,
                            sorts: _sorts,
                            onColumnWidthChanged: _setColumnWidth,
                            onSortGesture: _handleSortGesture,
                            onShowSortOptions: _showSortOptions,
                            statusMessage: _scanAnnouncement,
                            isScanning: _isScanning,
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
                      isLoadingMessages:
                          selectedRow != null &&
                          _loadingDetailId == selectedRow.id,
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
    final filtered = [
      for (final row in _rows)
        if (_matchesArchived(row) &&
            _matchesPlatform(row) &&
            _matchesPath(row, path) &&
            _matchesSearch(row, search))
          row,
    ];
    final reduced = _newestPerProjectOnly
        ? _newestRowsPerProject(filtered)
        : filtered;
    return _sortedRows(reduced);
  }

  List<SessionRowViewModel> _newestRowsPerProject(
    List<SessionRowViewModel> rows,
  ) {
    final newestByProject = <String, SessionRowViewModel>{};
    for (final row in rows) {
      final key = _projectGroupKey(row);
      final current = newestByProject[key];
      if (current == null || _isNewerProjectRow(row, current)) {
        newestByProject[key] = row;
      }
    }
    return newestByProject.values.toList(growable: false);
  }

  String _projectGroupKey(SessionRowViewModel row) {
    final project = row.project.trim().toLowerCase();
    if (project.isNotEmpty) {
      return project;
    }
    return 'session:${row.id}';
  }

  bool _isNewerProjectRow(
    SessionRowViewModel candidate,
    SessionRowViewModel current,
  ) {
    final timestampOrder = candidate.lastMessageAtUtc.compareTo(
      current.lastMessageAtUtc,
    );
    if (timestampOrder != 0) {
      return timestampOrder > 0;
    }
    return candidate.id.compareTo(current.id) < 0;
  }

  List<SessionRowViewModel> _sortedRows(List<SessionRowViewModel> rows) {
    final sorted = List<SessionRowViewModel>.of(rows);
    sorted.sort((left, right) {
      for (final sort in _sorts) {
        final result = _compareRows(left, right, sort.column);
        if (result != 0) {
          return sort.ascending ? result : -result;
        }
      }
      return left.id.compareTo(right.id);
    });
    return sorted;
  }

  int _compareRows(
    SessionRowViewModel left,
    SessionRowViewModel right,
    String column,
  ) {
    return switch (column) {
      'last_message_at' => left.lastMessageAtUtc.compareTo(
        right.lastMessageAtUtc,
      ),
      'project' => _compareText(left.project, right.project),
      'path' => _compareText(left.path, right.path),
      'summary' => _compareText(left.summary, right.summary),
      'message_count' => left.messageCount.compareTo(right.messageCount),
      'total_tokens' => left.totalTokens.compareTo(right.totalTokens),
      'model' => _compareText(left.model, right.model),
      'tags' => _compareText(left.tags.join(', '), right.tags.join(', ')),
      'status' => _compareText(left.status, right.status),
      _ => 0,
    };
  }

  int _compareText(String left, String right) =>
      left.toLowerCase().compareTo(right.toLowerCase());

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
        _archivedFilter != SessionsArchivedFilter.activeOnly ||
        _newestPerProjectOnly;
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
    unawaited(_loadSelectedDetail(id));
  }

  Future<void> _loadSelectedDetail(String id) async {
    final loader = widget.onLoadSessionDetail;
    if (loader == null || _loadingDetailId == id) {
      return;
    }
    final row = _rowById(id);
    if (row == null ||
        row.messageCount == 0 ||
        row.conversationMessages.isNotEmpty) {
      return;
    }
    setState(() {
      _loadingDetailId = id;
    });
    try {
      final loaded = await loader(id);
      if (!mounted || loaded == null) {
        return;
      }
      setState(() {
        _replaceRow(loaded);
        _retainSelection();
      });
    } finally {
      if (mounted && _loadingDetailId == id) {
        setState(() {
          _loadingDetailId = null;
        });
      }
    }
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
        _newestPerProjectOnly = false;
        _retainSelection();
      });
    } finally {
      _searchController.addListener(_filtersChanged);
      _pathController.addListener(_filtersChanged);
    }
  }

  Future<void> _refresh() async {
    if (_isScanning) {
      _requestRefreshCancel();
      return;
    }
    setState(() {
      _isScanning = true;
      _isCancellingRefresh = false;
      _hasRefreshOwnedRows = true;
      _scanAnnouncement = 'Scanning started';
    });
    SessionsRefreshOperation? operation;
    try {
      operation = _refreshOperation(_handleRefreshProgress);
      _activeRefreshOperation = operation;
      final refreshResult = await operation.result;
      if (!mounted) {
        return;
      }
      setState(() {
        _hasRefreshOwnedRows = true;
        _replaceRows(refreshResult.rows);
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
      if (operation != null && identical(_activeRefreshOperation, operation)) {
        _activeRefreshOperation = null;
      }
      if (mounted) {
        setState(() {
          _isScanning = false;
          _isCancellingRefresh = false;
        });
      }
    }
  }

  void _requestRefreshCancel({bool updateUi = true}) {
    final operation = _activeRefreshOperation;
    if (operation == null || _isCancellingRefresh) {
      return;
    }
    if (updateUi && mounted) {
      setState(() {
        _isCancellingRefresh = true;
        _scanAnnouncement = 'Cancelling scan...';
      });
    } else {
      _isCancellingRefresh = true;
      _scanAnnouncement = 'Cancelling scan...';
    }
    unawaited(operation.cancel().catchError((Object _) {}));
  }

  void _handleRefreshProgress(SessionsRefreshProgress progress) {
    if (!mounted) {
      return;
    }
    setState(() {
      final rows = progress.rows;
      if (rows != null) {
        _hasRefreshOwnedRows = true;
        _replaceRows(rows);
      }
      _scanAnnouncement = progress.statusMessage;
      _retainSelection();
    });
  }

  SessionsRefreshOperation _refreshOperation(
    SessionsRefreshProgressCallback onProgress,
  ) {
    final refreshOperation = widget.onRefreshOperation;
    if (refreshOperation != null) {
      return refreshOperation(onProgress);
    }
    return SessionsRefreshOperation.fromFuture(_refreshResult(onProgress));
  }

  Future<SessionsRefreshResult> _refreshResult(
    SessionsRefreshProgressCallback onProgress,
  ) async {
    final refreshWithProgress = widget.onRefreshWithProgress;
    if (refreshWithProgress != null) {
      return refreshWithProgress(onProgress);
    }
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

  void _setColumnWidth(String column, double width) {
    setState(() {
      _columnWidths[column] = width.clamp(64, 520).toDouble();
    });
    _emitTableState();
  }

  void _handleSortGesture(String column, _SortGesture gesture) {
    if (column == 'actions') {
      return;
    }
    setState(() {
      _sorts = _nextSorts(column, gesture);
    });
    _emitTableState();
  }

  List<SessionTableSortSettings> _nextSorts(
    String column,
    _SortGesture gesture,
  ) {
    final existingIndex = _sorts.indexWhere((sort) => sort.column == column);
    if (gesture == _SortGesture.remove) {
      if (existingIndex < 0) {
        return _sorts;
      }
      final next = List<SessionTableSortSettings>.of(_sorts)
        ..removeAt(existingIndex);
      return next.isEmpty ? _defaultSorts : next;
    }
    if (gesture == _SortGesture.add) {
      if (existingIndex >= 0) {
        final next = List<SessionTableSortSettings>.of(_sorts);
        final existing = next[existingIndex];
        next[existingIndex] = SessionTableSortSettings(
          column: column,
          ascending: !existing.ascending,
        );
        return next;
      }
      return [
        ..._sorts,
        SessionTableSortSettings(column: column, ascending: true),
      ];
    }
    if (existingIndex == 0 && _sorts.length == 1) {
      return [
        SessionTableSortSettings(
          column: column,
          ascending: !_sorts.first.ascending,
        ),
      ];
    }
    return [SessionTableSortSettings(column: column, ascending: true)];
  }

  Future<void> _showSortOptions(BuildContext context) async {
    final result = await showDialog<List<SessionTableSortSettings>>(
      context: context,
      builder: (context) => _SortOptionsDialog(sorts: _sorts),
    );
    if (result == null) {
      return;
    }
    setState(() {
      _sorts = _normalizedSorts(result);
    });
    _emitTableState();
  }

  void _emitTableState() {
    widget.onTableStateChanged?.call(
      SessionTableSettings(
        columnWidths: Map.unmodifiable(_columnWidths),
        sorts: List.unmodifiable(_sorts),
      ),
    );
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

  SessionRowViewModel? _rowById(String id) {
    for (final row in _rows) {
      if (row.id == id) {
        return row;
      }
    }
    return null;
  }

  void _replaceRow(SessionRowViewModel replacement) {
    final index = _rows.indexWhere((row) => row.id == replacement.id);
    if (index < 0) {
      return;
    }
    _rows[index] = replacement;
  }

  void _replaceRows(List<SessionRowViewModel> rows) {
    final loadedMessagesById = {
      for (final row in _rows)
        if (row.conversationMessages.isNotEmpty)
          row.id: row.conversationMessages,
    };
    _rows = [
      for (final row in rows)
        if (row.conversationMessages.isEmpty &&
            loadedMessagesById.containsKey(row.id))
          row.copyWithConversationMessages(loadedMessagesById[row.id]!)
        else
          row,
    ];
  }
}

class SessionsRefreshResult {
  const SessionsRefreshResult({
    required this.rows,
    required this.statusMessage,
    this.cancelled = false,
    this.persistenceFlushCount = 0,
    this.fullRowSnapshotCount = 0,
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
  final bool cancelled;
  final int persistenceFlushCount;
  final int fullRowSnapshotCount;
}

class SessionsRefreshOperation {
  const SessionsRefreshOperation({required this.result, required this.cancel});

  factory SessionsRefreshOperation.fromFuture(
    Future<SessionsRefreshResult> result,
  ) {
    return SessionsRefreshOperation(
      result: result,
      cancel: () => result.then<void>((_) {}, onError: (_) {}),
    );
  }

  final Future<SessionsRefreshResult> result;
  final Future<void> Function() cancel;
}

class SessionsRefreshProgress {
  const SessionsRefreshProgress({required this.statusMessage, this.rows});

  final List<SessionRowViewModel>? rows;
  final String statusMessage;
}

class _SessionsEmptyState extends StatelessWidget {
  const _SessionsEmptyState({
    required this.hasRows,
    required this.hasActiveFilters,
    required this.statusMessage,
    required this.isScanning,
    required this.visibleCount,
    required this.unreachablePaths,
    required this.onClearFilters,
    required this.onOpenSettings,
    required this.onTestWslPath,
  });

  final bool hasRows;
  final bool hasActiveFilters;
  final String statusMessage;
  final bool isScanning;
  final int visibleCount;
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
          _SessionsHeading(visibleCount: visibleCount),
          if (statusMessage.isNotEmpty) ...[
            const SizedBox(height: 8),
            _StatusLine(message: statusMessage, isScanning: isScanning),
          ],
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
    required this.newestPerProjectOnly,
    required this.isScanning,
    required this.isCancellingRefresh,
    required this.onPlatformChanged,
    required this.onArchivedChanged,
    required this.onNewestPerProjectOnlyChanged,
    required this.onClearFilters,
    required this.onRefresh,
  });

  final TextEditingController searchController;
  final TextEditingController pathController;
  final SessionsPlatformFilter platformFilter;
  final SessionsArchivedFilter archivedFilter;
  final bool newestPerProjectOnly;
  final bool isScanning;
  final bool isCancellingRefresh;
  final ValueChanged<SessionsPlatformFilter> onPlatformChanged;
  final ValueChanged<SessionsArchivedFilter> onArchivedChanged;
  final ValueChanged<bool> onNewestPerProjectOnlyChanged;
  final VoidCallback onClearFilters;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final refreshLabel = isCancellingRefresh
        ? 'Cancelling scan...'
        : isScanning
        ? 'Cancel scan'
        : 'Refresh';
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
                  onPressed: isCancellingRefresh ? null : onRefresh,
                  child: Text(refreshLabel),
                ),
                OutlinedButton(
                  onPressed: onClearFilters,
                  child: const Text('Clear filters'),
                ),
                _NewestPerProjectFilter(
                  value: newestPerProjectOnly,
                  onChanged: onNewestPerProjectOnlyChanged,
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

class _NewestPerProjectFilter extends StatelessWidget {
  const _NewestPerProjectFilter({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Newest session per project filter',
      toggled: value,
      container: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => onChanged(!value),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: value,
                semanticLabel: 'Newest session per project filter',
                onChanged: (checked) => onChanged(checked ?? false),
              ),
              const Text('Newest per project'),
              const SizedBox(width: 8),
            ],
          ),
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

class _SessionsHeading extends StatelessWidget {
  const _SessionsHeading({required this.visibleCount});

  final int visibleCount;

  @override
  Widget build(BuildContext context) {
    final countStyle = Theme.of(context).textTheme.bodySmall;
    return Semantics(
      header: true,
      label: 'Sessions, $visibleCount visible',
      child: ExcludeSemantics(
        child: Row(
          children: [
            Text('Sessions', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(width: 6),
            Text('($visibleCount)', style: countStyle),
          ],
        ),
      ),
    );
  }
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.message, required this.isScanning});

  final String message;
  final bool isScanning;

  @override
  Widget build(BuildContext context) {
    final lowerMessage = message.toLowerCase();
    final isLoadingPrevious =
        lowerMessage.startsWith('loading previous sessions') ||
        (lowerMessage.startsWith('loaded ') &&
            lowerMessage.contains('from the previous scan'));
    final showSpinner = isScanning || isLoadingPrevious;
    final isFinished = lowerMessage.startsWith('scan finished');
    final isError =
        lowerMessage.contains('failed') || lowerMessage.contains('unreachable');
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      label: message,
      child: Row(
        children: [
          SizedBox.square(
            dimension: 16,
            child: showSpinner
                ? const CircularProgressIndicator(strokeWidth: 2)
                : Icon(
                    isFinished
                        ? Icons.check_circle_outline
                        : isError
                        ? Icons.error_outline
                        : Icons.info_outline,
                    size: 16,
                    color: isFinished
                        ? scheme.primary
                        : isError
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(message, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

class _SessionColumn {
  const _SessionColumn({
    required this.key,
    required this.label,
    required this.defaultWidth,
  });

  final String key;
  final String label;
  final double defaultWidth;
}

enum _SortGesture { replace, add, remove }

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({
    required this.column,
    required this.width,
    required this.style,
    required this.sort,
    required this.sortPriority,
    required this.onResize,
    required this.onSortGesture,
    required this.onShowSortOptions,
  });

  final _SessionColumn column;
  final double width;
  final TextStyle? style;
  final SessionTableSortSettings? sort;
  final int? sortPriority;
  final ValueChanged<double> onResize;
  final void Function(String column, _SortGesture gesture) onSortGesture;
  final Future<void> Function(BuildContext context) onShowSortOptions;

  @override
  Widget build(BuildContext context) {
    final sort = this.sort;
    final priority = sortPriority;
    final sortLabel = sort == null
        ? ''
        : ' ${sort.ascending ? 'ascending' : 'descending'}'
              '${priority == null ? '' : ' priority $priority'}';
    return SizedBox(
      width: width,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              label: '${column.label} column$sortLabel',
              button: column.key != 'actions',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: column.key == 'actions' ? null : _handleTap,
                onSecondaryTapDown: (_) => onShowSortOptions(context),
                child: ExcludeSemantics(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            column.label,
                            overflow: TextOverflow.ellipsis,
                            style: style,
                          ),
                        ),
                        if (sort != null)
                          _SortIndicator(
                            ascending: sort.ascending,
                            priority: priority,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragUpdate: (details) =>
                  onResize(width + details.delta.dx),
              child: const SizedBox(width: 8, height: double.infinity),
            ),
          ),
        ],
      ),
    );
  }

  void _handleTap() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    if (pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight)) {
      onSortGesture(column.key, _SortGesture.remove);
      return;
    }
    if (pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight)) {
      onSortGesture(column.key, _SortGesture.add);
      return;
    }
    onSortGesture(column.key, _SortGesture.replace);
  }
}

class _SortIndicator extends StatelessWidget {
  const _SortIndicator({required this.ascending, required this.priority});

  final bool ascending;
  final int? priority;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.primary;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _SvgIcon(
            ascending
                ? 'assets/icons/sort_ascending.svg'
                : 'assets/icons/sort_descending.svg',
            size: 16,
            color: color,
          ),
          if (priority != null) ...[
            const SizedBox(width: 4),
            Container(
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: color.withValues(alpha: 0.34)),
              ),
              child: Text(
                priority.toString(),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SvgIcon extends StatelessWidget {
  const _SvgIcon(this.assetName, {required this.size, required this.color});

  final String assetName;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
    assetName,
    width: size,
    height: size,
    colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
  );
}

class _SessionsTable extends StatelessWidget {
  const _SessionsTable({
    required this.rows,
    required this.selectedId,
    required this.onSelect,
    required this.onAction,
    required this.settings,
    required this.columnWidths,
    required this.sorts,
    required this.onColumnWidthChanged,
    required this.onSortGesture,
    required this.onShowSortOptions,
    required this.statusMessage,
    required this.isScanning,
  });

  final List<SessionRowViewModel> rows;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final SessionActionCallback onAction;
  final AppSettings settings;
  final Map<String, double> columnWidths;
  final List<SessionTableSortSettings> sorts;
  final void Function(String column, double width) onColumnWidthChanged;
  final void Function(String column, _SortGesture gesture) onSortGesture;
  final Future<void> Function(BuildContext context) onShowSortOptions;
  final String statusMessage;
  final bool isScanning;

  static const _rowHeight = 80.0;
  static const _columns = <_SessionColumn>[
    _SessionColumn(
      key: 'last_message_at',
      label: 'Last Message Date',
      defaultWidth: 180,
    ),
    _SessionColumn(key: 'actions', label: 'Actions', defaultWidth: 66),
    _SessionColumn(key: 'project', label: 'Project', defaultWidth: 112),
    _SessionColumn(key: 'path', label: 'Path', defaultWidth: 280),
    _SessionColumn(key: 'summary', label: 'Summary', defaultWidth: 220),
    _SessionColumn(key: 'message_count', label: 'Messages', defaultWidth: 82),
    _SessionColumn(key: 'total_tokens', label: 'Tokens', defaultWidth: 78),
    _SessionColumn(key: 'model', label: 'Model', defaultWidth: 110),
    _SessionColumn(key: 'tags', label: 'Tags', defaultWidth: 110),
    _SessionColumn(key: 'status', label: 'Status', defaultWidth: 130),
  ];

  double get _tableWidth => _columns.fold<double>(
    0,
    (total, column) => total + _widthFor(column.key),
  );

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: _SessionsHeading(visibleCount: rows.length),
        ),
        if (statusMessage.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _StatusLine(message: statusMessage, isScanning: isScanning),
          ),
        Expanded(
          child: Scrollbar(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: _tableWidth,
                child: Column(
                  children: [
                    _header(context),
                    Expanded(
                      child: ListView.builder(
                        itemExtent: _rowHeight,
                        itemCount: rows.length,
                        itemBuilder: (context, index) =>
                            _sessionRow(context, rows[index]),
                      ),
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

  Widget _header(BuildContext context) {
    final style = Theme.of(context).textTheme.labelMedium;
    return Container(
      height: 40,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Theme.of(context).colorScheme.outline),
        ),
      ),
      child: Row(
        children: [
          for (final column in _columns)
            _HeaderCell(
              column: column,
              width: _widthFor(column.key),
              style: style,
              sort: _sortFor(column.key),
              sortPriority: _sortPriority(column.key),
              onResize: (width) => onColumnWidthChanged(column.key, width),
              onSortGesture: onSortGesture,
              onShowSortOptions: onShowSortOptions,
            ),
        ],
      ),
    );
  }

  Widget _sessionRow(BuildContext context, SessionRowViewModel row) {
    final selected = row.id == selectedId;
    final color = _rowColor(context, row, selected: selected);
    return InkWell(
      excludeFromSemantics: true,
      onTap: () => onSelect(row.id),
      child: Container(
        height: _rowHeight,
        color: color,
        child: Row(
          children: [
            _dateCell(row),
            SizedBox(
              width: _widthFor('actions'),
              child: _ActionsMenu(
                row: row,
                onAction: onAction,
                settings: settings,
              ),
            ),
            _cell('Project', row.project, width: _widthFor('project')),
            _PathCell(
              row: row,
              width: _widthFor('path'),
              onCopy: () => onAction(
                SessionActionRequest(
                  row: row,
                  action: SessionRowAction.copyPath,
                  payload: row.path,
                ),
              ),
            ),
            _cell('Summary', row.summary, width: _widthFor('summary')),
            _cell(
              'Messages',
              row.messageCount.toString(),
              width: _widthFor('message_count'),
            ),
            _cell(
              'Tokens',
              row.totalTokens.toString(),
              width: _widthFor('total_tokens'),
            ),
            _cell('Model', row.model, width: _widthFor('model')),
            _cell('Tags', row.tags.join(', '), width: _widthFor('tags')),
            SizedBox(
              width: _widthFor('status'),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Semantics(
                  label: 'Status ${_statusText(row)}',
                  container: true,
                  child: ExcludeSemantics(child: _StatusCell(row: row)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(String label, String text, {required double width}) => SizedBox(
    width: width,
    child: Semantics(
      label: '$label ${text.isEmpty ? 'empty' : text}',
      container: true,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(text, overflow: TextOverflow.ellipsis),
        ),
      ),
    ),
  );

  Widget _dateCell(SessionRowViewModel row) {
    final display = row.lastMessageAtUtc.relativeDisplay();
    return Semantics(
      label: 'Last Message Date $display',
      container: true,
      child: ExcludeSemantics(
        child: SizedBox(
          width: _widthFor('last_message_at'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(display, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    );
  }

  double _widthFor(String key) =>
      columnWidths[key] ??
      _columns.firstWhere((column) => column.key == key).defaultWidth;

  SessionTableSortSettings? _sortFor(String key) {
    for (final sort in sorts) {
      if (sort.column == key) {
        return sort;
      }
    }
    return null;
  }

  int? _sortPriority(String key) {
    final index = sorts.indexWhere((sort) => sort.column == key);
    return index < 0 ? null : index + 1;
  }

  String _statusText(SessionRowViewModel row) {
    final labels = <String>[
      if (row.isPinned) 'Pinned',
      if (row.isArchived) 'Archived',
      row.status,
    ];
    return labels.join(' | ');
  }

  Color? _rowColor(
    BuildContext context,
    SessionRowViewModel row, {
    required bool selected,
  }) {
    final scheme = Theme.of(context).colorScheme;
    if (selected) {
      return scheme.primaryContainer.withValues(alpha: 0.7);
    }
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

class _PathCell extends StatelessWidget {
  const _PathCell({
    required this.row,
    required this.width,
    required this.onCopy,
  });

  final SessionRowViewModel row;
  final double width;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final rowLabel = _rowAccessibleLabel(row);
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                label: '${row.platformLabel} path ${row.path}',
                container: true,
                child: ExcludeSemantics(
                  child: Row(
                    children: [
                      _PlatformGlyph(platform: row.platform),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(row.path, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Semantics(
              label: 'Copy path for $rowLabel',
              button: true,
              child: IconButton(
                tooltip: 'Copy path',
                icon: const Icon(Icons.copy, size: 16),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                onPressed: onCopy,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlatformGlyph extends StatelessWidget {
  const _PlatformGlyph({required this.platform});

  final SessionRowPlatform platform;

  @override
  Widget build(BuildContext context) {
    final color = IconTheme.of(context).color ?? Colors.black87;
    return SizedBox.square(
      dimension: 16,
      child: switch (platform) {
        SessionRowPlatform.windows => _SvgIcon(
          'assets/icons/platform_windows.svg',
          size: 16,
          color: color,
        ),
        SessionRowPlatform.wsl => _SvgIcon(
          'assets/icons/platform_wsl.svg',
          size: 16,
          color: color,
        ),
      },
    );
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
    final rowLabel = _rowAccessibleLabel(row);
    return Semantics(
      label: 'Actions for $rowLabel',
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
      SessionRowAction.openPath || SessionRowAction.copyPath => row.path,
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
    required this.isLoadingMessages,
  });

  final SessionRowViewModel? row;
  final AppSettings settings;
  final SessionDetailActionCallback? onSessionAction;
  final TerminalCommandCallback? onRunTerminalCommand;
  final TerminalCommandCallback? onEditTerminalCommand;
  final bool isLoadingMessages;

  @override
  Widget build(BuildContext context) {
    if (row != null) {
      return SessionDetailPane(
        row: row!,
        settings: settings,
        onSessionAction: onSessionAction,
        onRunTerminalCommand: onRunTerminalCommand,
        onEditTerminalCommand: onEditTerminalCommand,
        isLoadingMessages: isLoadingMessages,
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

class _SortOptionsDialog extends StatefulWidget {
  const _SortOptionsDialog({required this.sorts});

  final List<SessionTableSortSettings> sorts;

  @override
  State<_SortOptionsDialog> createState() => _SortOptionsDialogState();
}

class _SortOptionsDialogState extends State<_SortOptionsDialog> {
  late List<SessionTableSortSettings> _sorts;

  @override
  void initState() {
    super.initState();
    _sorts = List.of(widget.sorts);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sort options'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _sorts.length; i++)
              ListTile(
                title: Text(_columnLabel(_sorts[i].column)),
                subtitle: Text('Priority ${i + 1}'),
                trailing: SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Asc')),
                    ButtonSegment(value: false, label: Text('Desc')),
                  ],
                  selected: {_sorts[i].ascending},
                  onSelectionChanged: (selection) {
                    setState(() {
                      _sorts[i] = SessionTableSortSettings(
                        column: _sorts[i].column,
                        ascending: selection.single,
                      );
                    });
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(_defaultSorts),
          child: const Text('Default'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_defaultSorts),
          child: const Text('Clear'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_sorts),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

extension on DateTime {
  String get shortDateTime {
    final local = toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  String relativeDisplay() {
    final now = DateTime.now().toUtc();
    final elapsed = now.difference(toUtc());
    final absolute = '($shortDateTime)';
    if (elapsed.inMinutes < 1) {
      return 'just now';
    }
    if (elapsed.inHours < 1) {
      return '${elapsed.inMinutes}m ago';
    }
    if (elapsed.inDays < 1) {
      final minutes = elapsed.inMinutes % 60;
      return minutes == 0
          ? '${elapsed.inHours}h ago'
          : '${elapsed.inHours}h ${minutes}m ago';
    }
    if (elapsed.inDays < 7) {
      return '${elapsed.inDays} ${elapsed.inDays == 1 ? 'day' : 'days'} ago $absolute';
    }
    return shortDateTime;
  }
}

String _rowAccessibleLabel(SessionRowViewModel row) {
  final title = row.title.trim();
  if (title.isNotEmpty) {
    return title;
  }
  final sessionId = row.sessionId.trim();
  if (sessionId.isNotEmpty) {
    return sessionId;
  }
  return row.id;
}

const _defaultSorts = [
  SessionTableSortSettings(column: 'last_message_at', ascending: false),
];

List<SessionTableSortSettings> _normalizedSorts(
  List<SessionTableSortSettings> sorts,
) {
  final validColumns = {
    'last_message_at',
    'project',
    'path',
    'summary',
    'message_count',
    'total_tokens',
    'model',
    'tags',
    'status',
  };
  final normalized = <SessionTableSortSettings>[];
  for (final sort in sorts) {
    if (validColumns.contains(sort.column) &&
        !normalized.any((existing) => existing.column == sort.column)) {
      normalized.add(sort);
    }
  }
  return normalized.isEmpty ? List.of(_defaultSorts) : normalized;
}

String _columnLabel(String key) {
  return switch (key) {
    'last_message_at' => 'Last Message Date',
    'project' => 'Project',
    'path' => 'Path',
    'summary' => 'Summary',
    'message_count' => 'Messages',
    'total_tokens' => 'Tokens',
    'model' => 'Model',
    'tags' => 'Tags',
    'status' => 'Status',
    _ => key,
  };
}
