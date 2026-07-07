import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../commands/resume_command_generator.dart';
import '../../config/app_settings.dart';
import '../../usage/usage_summary.dart';
import '../motion.dart';
import '../models/conversation_message_view_model.dart';
import '../models/session_row_view_model.dart';
import '../number_formatting.dart';
import '../widgets/command_preview.dart';
import '../widgets/conversation_view.dart';
import '../widgets/session_detail_pane.dart';
import '../widgets/svg_icon.dart';

export '../models/session_row_view_model.dart';

enum SessionsPlatformFilter { both, windows, wsl }

enum SessionsArchivedFilter { activeOnly, archivedOnly, all }

enum SessionsOriginFilter { all, user, subagent }

enum SessionsTimeFilter {
  today,
  yesterday,
  thisWeek,
  lastWeek,
  thisMonth,
  lastMonth,
  last30Days,
  allTime,
}

const _defaultOriginFilter = SessionsOriginFilter.user;
const _defaultTimeFilter = SessionsTimeFilter.last30Days;

extension _SessionsTimeFilterLabel on SessionsTimeFilter {
  String get label => switch (this) {
    SessionsTimeFilter.today => 'Today',
    SessionsTimeFilter.yesterday => 'Yesterday',
    SessionsTimeFilter.thisWeek => 'This week',
    SessionsTimeFilter.lastWeek => 'Last week',
    SessionsTimeFilter.thisMonth => 'This month',
    SessionsTimeFilter.lastMonth => 'Last month',
    SessionsTimeFilter.last30Days => 'Last 30 days',
    SessionsTimeFilter.allTime => 'All time',
  };
}

enum SessionRowAction {
  openPath,
  copyPath,
  copyPlainResumeCommand,
  copyPlatformResumeCommand,
  openTerminalResume,
  openTerminalFork,
  copyTerminalCommand,
  editTags,
  togglePin,
  toggleArchive,
  updateEvalMetadata,
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
typedef SessionFileWatcher = Stream<Object> Function(String path);
typedef SessionTableStateChanged = void Function(SessionTableSettings);
typedef SessionMarkdownExportCallback =
    Future<void> Function(SessionRowViewModel row, String markdown);
typedef SessionMessagePageLoader =
    Future<List<ConversationMessageViewModel>> Function(
      String sessionId,
      int anchorMessageNumber,
    );

class SessionOpenTarget {
  const SessionOpenTarget({required this.sessionId, this.messageIndex});

  final String sessionId;
  final int? messageIndex;
}

class SessionActionRequest {
  const SessionActionRequest({
    required this.row,
    required this.action,
    this.payload,
    this.evalMetadata,
  });

  final SessionRowViewModel row;
  final SessionRowAction action;
  final String? payload;
  final SessionEvalMetadata? evalMetadata;
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
    this.onCopyText,
    this.onExportMarkdown,
    this.onLoadSessionDetail,
    this.onReloadSessionDetailFromSource,
    this.onLoadMessagePage,
    this.watchSessionFile = _watchSessionFile,
    this.settings,
    this.initialTableState,
    this.onTableStateChanged,
    this.initialStatusMessage = '',
    this.autoRefreshToken = 0,
    this.openTarget,
    this.openTargetSerial = 0,
  });

  final List<SessionRowViewModel> initialRows;
  final Future<List<SessionRowViewModel>> Function()? onRefresh;
  final Future<SessionsRefreshResult> Function()? onRefreshResult;
  final SessionsRefreshWithProgress? onRefreshWithProgress;
  final SessionsRefreshOperationFactory? onRefreshOperation;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onTestWslPath;
  final SessionActionCallback? onSessionAction;
  final DetailCopyCallback? onCopyText;
  final SessionMarkdownExportCallback? onExportMarkdown;
  final SessionDetailLoader? onLoadSessionDetail;
  final SessionDetailLoader? onReloadSessionDetailFromSource;
  final SessionMessagePageLoader? onLoadMessagePage;
  final SessionFileWatcher watchSessionFile;
  final AppSettings? settings;
  final SessionTableSettings? initialTableState;
  final SessionTableStateChanged? onTableStateChanged;
  final String initialStatusMessage;
  final int autoRefreshToken;
  final SessionOpenTarget? openTarget;
  final int openTargetSerial;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  static const _detailPaneMinWidth = 360.0;
  static const _minimumTablePaneWidth = 520.0;
  static const _splitDividerWidth = 1.0;

  final _searchController = TextEditingController();
  final _pathController = TextEditingController();
  final _threadNameController = TextEditingController();
  var _platformFilter = SessionsPlatformFilter.both;
  var _archivedFilter = SessionsArchivedFilter.activeOnly;
  var _originFilter = _defaultOriginFilter;
  var _timeFilter = _defaultTimeFilter;
  var _newestPerProjectOnly = false;
  var _namedOnly = false;
  var _isScanning = false;
  var _isCancellingRefresh = false;
  var _scanAnnouncement = '';
  var _hasRefreshOwnedRows = false;
  String? _selectedId;
  String? _loadingDetailId;
  var _rowMotionIds = <String>{};
  var _rowMotionGeneration = 0;
  final _expandedParentIds = <String>{};
  final _conversationPositions = <String, ConversationPositionState>{};
  StreamSubscription<Object>? _selectedFileSubscription;
  Timer? _selectedFileReloadTimer;
  String? _watchedDetailPath;
  var _selectedDetailWatchGeneration = 0;
  var _selectedDetailLoadGeneration = 0;
  late List<SessionRowViewModel> _rows;
  late Map<String, double> _columnWidths;
  late List<SessionTableSortSettings> _sorts;
  late int _handledAutoRefreshToken;
  late int _handledOpenTargetSerial;
  SessionOpenTarget? _pendingOpenTarget;
  int? _pendingOpenTargetSerial;
  Timer? _relativeDateTimer;
  Timer? _backgroundRescanTimer;
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
    _newestPerProjectOnly = tableState.newestPerProjectOnly;
    _scanAnnouncement = widget.initialStatusMessage;
    _handledAutoRefreshToken = widget.autoRefreshToken;
    _handledOpenTargetSerial = -1;
    _searchController.addListener(_filtersChanged);
    _pathController.addListener(_filtersChanged);
    _threadNameController.addListener(_filtersChanged);
    _relativeDateTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
    _configureBackgroundRescanTimer();
    _queueOpenTargetFromWidget();
  }

  @override
  void didUpdateWidget(covariant SessionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_hasRefreshOwnedRows && oldWidget.initialRows != widget.initialRows) {
      _replaceRows(widget.initialRows);
      _retainSelection();
      _tryApplyPendingOpenTarget();
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
    if (widget.openTargetSerial != _handledOpenTargetSerial) {
      _queueOpenTargetFromWidget();
    }
    if (_settingsFor(oldWidget).scanner != _settingsFor(widget).scanner) {
      _configureBackgroundRescanTimer();
    }
  }

  @override
  void dispose() {
    _requestRefreshCancel(updateUi: false);
    _backgroundRescanTimer?.cancel();
    _searchController
      ..removeListener(_filtersChanged)
      ..dispose();
    _pathController
      ..removeListener(_filtersChanged)
      ..dispose();
    _threadNameController
      ..removeListener(_filtersChanged)
      ..dispose();
    _relativeDateTimer?.cancel();
    _stopSelectedSessionFileWatch();
    super.dispose();
  }

  AppSettings _settingsFor(SessionsScreen widget) =>
      widget.settings ?? AppSettings.defaults();

  void _configureBackgroundRescanTimer() {
    _backgroundRescanTimer?.cancel();
    _backgroundRescanTimer = null;
    final scanner = (widget.settings ?? AppSettings.defaults()).scanner;
    if (!scanner.backgroundRescanEnabled ||
        scanner.backgroundRescanIntervalSeconds <= 0) {
      return;
    }
    _backgroundRescanTimer = Timer.periodic(
      Duration(seconds: scanner.backgroundRescanIntervalSeconds),
      (_) {
        if (!mounted || _isScanning) {
          return;
        }
        unawaited(_refresh());
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final visibleDisplayRows = _visibleDisplayRows;
    final visibleRows = [
      for (final displayRow in visibleDisplayRows) displayRow.row,
    ];
    final selectedRow = _selectedRow(visibleRows);
    final hasRowsHiddenByDefaultOrigin =
        visibleDisplayRows.isEmpty && _hasRowsHiddenOnlyByOrigin;
    return Material(
      child: FocusTraversalGroup(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final tablePaneWidth = _tablePaneWidth(constraints.maxWidth);
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  key: const Key('sessions-left-panel'),
                  width: tablePaneWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _FilterBar(
                        searchController: _searchController,
                        pathController: _pathController,
                        threadNameController: _threadNameController,
                        platformFilter: _platformFilter,
                        timeFilter: _timeFilter,
                        archivedFilter: _archivedFilter,
                        originFilter: _originFilter,
                        newestPerProjectOnly: _newestPerProjectOnly,
                        namedOnly: _namedOnly,
                        isScanning: _isScanning,
                        isCancellingRefresh: _isCancellingRefresh,
                        onPlatformChanged: (value) {
                          setState(() {
                            _platformFilter = value;
                            _retainSelection();
                            _markVisibleRowsForMotion();
                          });
                        },
                        onTimeChanged: (value) {
                          setState(() {
                            _timeFilter = value;
                            _retainSelection();
                            _markVisibleRowsForMotion();
                          });
                        },
                        onArchivedChanged: (value) {
                          setState(() {
                            _archivedFilter = value;
                            _retainSelection();
                            _markVisibleRowsForMotion();
                          });
                        },
                        onOriginChanged: (value) {
                          setState(() {
                            _originFilter = value;
                            _retainSelection();
                            _markVisibleRowsForMotion();
                          });
                        },
                        onNewestPerProjectOnlyChanged: (value) {
                          setState(() {
                            _newestPerProjectOnly = value;
                            _retainSelection();
                            _markVisibleRowsForMotion();
                          });
                          _emitTableState();
                        },
                        onNamedOnlyChanged: (value) {
                          setState(() {
                            _namedOnly = value;
                            _retainSelection();
                            _markVisibleRowsForMotion();
                          });
                        },
                        onClearFilters: _clearFilters,
                        onRefresh: _refresh,
                      ),
                      Expanded(
                        child: visibleDisplayRows.isEmpty
                            ? _SessionsEmptyState(
                                hasRows: _rows.isNotEmpty,
                                hasActiveFilters: _hasActiveFilters,
                                statusMessage: _scanAnnouncement,
                                isScanning: _isScanning,
                                visibleCount: visibleDisplayRows.length,
                                unreachablePaths: _unreachablePaths,
                                hasRowsHiddenByDefaultOrigin:
                                    hasRowsHiddenByDefaultOrigin,
                                onClearFilters: _clearFilters,
                                onShowAllOrigins: _showAllOrigins,
                                onOpenSettings: widget.onOpenSettings,
                                onTestWslPath: widget.onTestWslPath ?? _refresh,
                              )
                            : _SessionsTable(
                                rows: visibleDisplayRows,
                                selectedId: _selectedId,
                                onSelect: _select,
                                onToggleSubagents: _toggleSubagents,
                                onAction: _handleSessionAction,
                                settings:
                                    widget.settings ?? AppSettings.defaults(),
                                columnWidths: _columnWidths,
                                sorts: _sorts,
                                onColumnWidthChanged: _setColumnWidth,
                                onSortGesture: _handleSortGesture,
                                onShowSortOptions: _showSortOptions,
                                statusMessage: _scanAnnouncement,
                                isScanning: _isScanning,
                                animatedRowIds: _rowMotionIds,
                                rowMotionGeneration: _rowMotionGeneration,
                                unreachablePaths: _unreachablePaths,
                                onOpenSettings: widget.onOpenSettings,
                                onTestWslPath: widget.onTestWslPath ?? _refresh,
                              ),
                      ),
                    ],
                  ),
                ),
                VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: Theme.of(context).colorScheme.outlineVariant,
                ),
                Expanded(
                  child: _SessionDetailPlaceholder(
                    row: selectedRow,
                    visibleCount: visibleDisplayRows.length,
                    hasRows: _rows.isNotEmpty,
                    hasActiveFilters: _hasActiveFilters,
                    isScanning: _isScanning,
                    settings: widget.settings ?? AppSettings.defaults(),
                    onSessionAction: selectedRow == null
                        ? null
                        : (action) => _handleDetailAction(selectedRow, action),
                    onCopyText: widget.onCopyText,
                    onExportMarkdown: widget.onExportMarkdown,
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
                    initialConversationMessageNumber: selectedRow == null
                        ? null
                        : _conversationPositions[selectedRow.id]?.messageNumber,
                    onConversationPositionChanged: selectedRow == null
                        ? null
                        : (position) {
                            _conversationPositions[selectedRow.id] = position;
                          },
                    onLoadMessagePage:
                        selectedRow == null || widget.onLoadMessagePage == null
                        ? null
                        : (anchor) =>
                              widget.onLoadMessagePage!(selectedRow.id, anchor),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  double _tablePaneWidth(double availableWidth) {
    final tableWidth = _SessionsTable.tableWidthFor(_columnWidths);
    if (!availableWidth.isFinite) {
      return tableWidth;
    }
    final contentWidth = (availableWidth - _splitDividerWidth).clamp(
      0.0,
      availableWidth,
    );
    if (contentWidth <= _minimumTablePaneWidth) {
      return contentWidth;
    }
    final maxLeftWidth = (contentWidth - _detailPaneMinWidth).clamp(
      _minimumTablePaneWidth,
      contentWidth,
    );
    return tableWidth.clamp(_minimumTablePaneWidth, maxLeftWidth).toDouble();
  }

  List<SessionRowViewModel> get _visibleRows => [
    for (final displayRow in _visibleDisplayRows) displayRow.row,
  ];

  List<_SessionDisplayRow> get _visibleDisplayRows {
    final search = _searchController.text.trim().toLowerCase();
    final path = _pathController.text
        .trim()
        .replaceAll(r'\', '/')
        .toLowerCase();
    final threadName = _threadNameController.text.trim().toLowerCase();
    final hierarchy = _buildSessionHierarchy();
    switch (_originFilter) {
      case SessionsOriginFilter.user:
        return _groupedDisplayRows(
          parents: hierarchy.parents,
          childrenByParentId: hierarchy.childrenByParentId,
          parentByChildId: hierarchy.parentByChildId,
          path: path,
          search: search,
          threadName: threadName,
        );
      case SessionsOriginFilter.all:
        return _allOriginDisplayRows(
          hierarchy: hierarchy,
          path: path,
          search: search,
          threadName: threadName,
        );
      case SessionsOriginFilter.subagent:
        final rows = _newestPerProjectOnly
            ? _newestRowsPerProject(
                hierarchy.subagents
                    .where(
                      (row) =>
                          _matchesDisplayFilters(row, path, search, threadName),
                    )
                    .toList(growable: false),
              )
            : hierarchy.subagents
                  .where(
                    (row) =>
                        _matchesDisplayFilters(row, path, search, threadName),
                  )
                  .toList(growable: false);
        return [
          for (final row in _sortedRows(rows))
            _SessionDisplayRow.directSubagent(
              row: row,
              parent: hierarchy.parentByChildId[row.id],
            ),
        ];
    }
  }

  List<_SessionDisplayRow> _groupedDisplayRows({
    required List<SessionRowViewModel> parents,
    required Map<String, List<SessionRowViewModel>> childrenByParentId,
    required Map<String, SessionRowViewModel> parentByChildId,
    required String path,
    required String search,
    required String threadName,
    bool applyNewestPerProject = true,
  }) {
    final groups = <List<_SessionDisplayRow>>[];
    for (final parent in _sortedRows(parents)) {
      final children = _sortedRows(childrenByParentId[parent.id] ?? const []);
      final availableChildren = [
        for (final child in children)
          if (_matchesStructuralFilters(child, path, threadName)) child,
      ];
      final matchingChildren = [
        for (final child in availableChildren)
          if (_matchesSearch(child, search)) child,
      ];
      final parentMatches = _matchesDisplayFilters(
        parent,
        path,
        search,
        threadName,
      );
      if (!parentMatches && matchingChildren.isEmpty) {
        continue;
      }
      final childTriggeredMatch =
          !parentMatches &&
          (search.isNotEmpty || path.isNotEmpty || threadName.isNotEmpty);
      final expanded = _expandedParentIds.contains(parent.id);
      final rolledUpParent = _parentRowWithUsageRollup(parent, children);
      final group = <_SessionDisplayRow>[
        _SessionDisplayRow.parent(
          row: rolledUpParent,
          childCount: availableChildren.length,
          expanded: expanded,
        ),
      ];
      if (expanded || childTriggeredMatch) {
        final displayChildren = search.isEmpty || parentMatches
            ? availableChildren
            : matchingChildren;
        for (final child in displayChildren) {
          group.add(
            _SessionDisplayRow.child(
              row: child,
              parent: parentByChildId[child.id] ?? parent,
            ),
          );
        }
      }
      groups.add(group);
    }
    groups.sort(
      (left, right) =>
          _compareRowsByActiveSorts(left.first.row, right.first.row),
    );
    final reducedGroups =
        applyNewestPerProject &&
            _newestPerProjectOnly &&
            search.isEmpty &&
            path.isEmpty &&
            threadName.isEmpty &&
            !_namedOnly
        ? _newestDisplayGroupsPerProject(groups)
        : groups;
    return [
      for (final group in reducedGroups)
        for (final displayRow in group) displayRow,
    ];
  }

  SessionRowViewModel _parentRowWithUsageRollup(
    SessionRowViewModel parent,
    List<SessionRowViewModel> children,
  ) {
    if (children.isEmpty) {
      return parent.copyWithUsageRollup(null);
    }
    final subagentTokens = children.fold<int>(
      0,
      (total, child) => total + child.totalTokens,
    );
    final mainCostText = _knownCostText(parent);
    final childCostTexts = [
      for (final child in children) _knownCostText(child),
    ];
    final subagentCostText = sumEstimatedCostTexts(childCostTexts);
    final totalCostText = sumEstimatedCostTexts([
      mainCostText,
      ...childCostTexts,
    ]);
    return parent.copyWithUsageRollup(
      SessionUsageRollup(
        mainTokens: parent.totalTokens,
        subagentTokens: subagentTokens,
        totalTokens: parent.totalTokens + subagentTokens,
        mainEstimatedCostText: mainCostText,
        subagentEstimatedCostText: subagentCostText,
        totalEstimatedCostText: totalCostText,
        mainCostUnknown: mainCostText == null,
        subagentCostUnknown: subagentCostText == null,
        totalCostUnknown: totalCostText == null,
      ),
    );
  }

  String? _knownCostText(SessionRowViewModel row) {
    if (row.costUnknown) {
      return null;
    }
    return row.estimatedCostText ?? '0';
  }

  List<_SessionDisplayRow> _allOriginDisplayRows({
    required _SessionHierarchy hierarchy,
    required String path,
    required String search,
    required String threadName,
  }) {
    final groups = _displayRowGroups(
      _groupedDisplayRows(
        parents: hierarchy.parents,
        childrenByParentId: hierarchy.childrenByParentId,
        parentByChildId: hierarchy.parentByChildId,
        path: path,
        search: search,
        threadName: threadName,
        applyNewestPerProject: false,
      ),
    );
    for (final row in hierarchy.orphanSubagents) {
      if (_matchesDisplayFilters(row, path, search, threadName)) {
        groups.add([_SessionDisplayRow.directSubagent(row: row)]);
      }
    }
    groups.sort(
      (left, right) =>
          _compareRowsByActiveSorts(left.first.row, right.first.row),
    );
    final reducedGroups =
        _newestPerProjectOnly &&
            search.isEmpty &&
            path.isEmpty &&
            threadName.isEmpty &&
            !_namedOnly
        ? _newestDisplayGroupsPerProject(groups)
        : groups;
    return [
      for (final group in reducedGroups)
        for (final displayRow in group) displayRow,
    ];
  }

  List<List<_SessionDisplayRow>> _displayRowGroups(
    List<_SessionDisplayRow> rows,
  ) {
    final groups = <List<_SessionDisplayRow>>[];
    for (final row in rows) {
      if (row.row.isSubagentSession &&
          row.parent != null &&
          groups.isNotEmpty) {
        groups.last.add(row);
      } else {
        groups.add([row]);
      }
    }
    return groups;
  }

  List<List<_SessionDisplayRow>> _newestDisplayGroupsPerProject(
    List<List<_SessionDisplayRow>> groups,
  ) {
    final newestByProject = <String, List<_SessionDisplayRow>>{};
    for (final group in groups) {
      final key = _projectGroupKey(group.first.row);
      final current = newestByProject[key];
      if (current == null ||
          _isNewerProjectRow(group.first.row, current.first.row)) {
        newestByProject[key] = group;
      }
    }
    return newestByProject.values.toList(growable: false)..sort(
      (left, right) =>
          _compareRowsByActiveSorts(left.first.row, right.first.row),
    );
  }

  _SessionHierarchy _buildSessionHierarchy() {
    final parentByKey = <String, SessionRowViewModel>{};
    final parents = <SessionRowViewModel>[];
    final subagents = <SessionRowViewModel>[];
    for (final row in _rows) {
      if (row.isSubagentSession) {
        subagents.add(row);
        continue;
      }
      parents.add(row);
      for (final key in _sessionIdentityKeys(row)) {
        parentByKey.putIfAbsent(key, () => row);
      }
    }

    final childrenByParentId = <String, List<SessionRowViewModel>>{};
    final parentByChildId = <String, SessionRowViewModel>{};
    final orphanSubagents = <SessionRowViewModel>[];
    for (final child in subagents) {
      final parent = parentByKey[child.parentThreadId.trim()];
      if (parent == null) {
        orphanSubagents.add(child);
        continue;
      }
      parentByChildId[child.id] = parent;
      childrenByParentId.putIfAbsent(parent.id, () => []).add(child);
    }
    return _SessionHierarchy(
      parents: parents,
      subagents: subagents,
      orphanSubagents: orphanSubagents,
      childrenByParentId: childrenByParentId,
      parentByChildId: parentByChildId,
    );
  }

  Iterable<String> _sessionIdentityKeys(SessionRowViewModel row) sync* {
    final sessionId = row.sessionId.trim();
    if (sessionId.isNotEmpty) {
      yield sessionId;
    }
    yield row.id;
  }

  bool _matchesDisplayFilters(
    SessionRowViewModel row,
    String path,
    String search,
    String threadName,
  ) {
    return _matchesStructuralFilters(row, path, threadName) &&
        _matchesSearch(row, search);
  }

  bool _matchesStructuralFilters(
    SessionRowViewModel row,
    String path,
    String threadName,
  ) {
    return _matchesArchived(row) &&
        _matchesPlatform(row) &&
        _matchesTime(row) &&
        _matchesPath(row, path) &&
        _matchesThreadName(row, threadName) &&
        (!_namedOnly || row.hasThreadName);
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
    sorted.sort(_compareRowsByActiveSorts);
    return sorted;
  }

  int _compareRowsByActiveSorts(
    SessionRowViewModel left,
    SessionRowViewModel right,
  ) {
    for (final sort in _sorts) {
      final result = _compareRows(left, right, sort.column);
      if (result != 0) {
        return sort.ascending ? result : -result;
      }
    }
    return left.id.compareTo(right.id);
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
      'total_tokens' => left.displayTotalTokens.compareTo(
        right.displayTotalTokens,
      ),
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

  bool _matchesTime(SessionRowViewModel row) {
    if (_timeFilter == SessionsTimeFilter.allTime) {
      return true;
    }
    final value = row.lastMessageAtUtc.toLocal();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return switch (_timeFilter) {
      SessionsTimeFilter.today => _isWithinTimeRange(
        value,
        today,
        today.add(const Duration(days: 1)),
      ),
      SessionsTimeFilter.yesterday => _isWithinTimeRange(
        value,
        today.subtract(const Duration(days: 1)),
        today,
      ),
      SessionsTimeFilter.thisWeek => _isWithinTimeRange(
        value,
        _startOfWeek(today),
        _startOfWeek(today).add(const Duration(days: 7)),
      ),
      SessionsTimeFilter.lastWeek => _isWithinTimeRange(
        value,
        _startOfWeek(today).subtract(const Duration(days: 7)),
        _startOfWeek(today),
      ),
      SessionsTimeFilter.thisMonth => _isWithinTimeRange(
        value,
        DateTime(today.year, today.month),
        DateTime(today.year, today.month + 1),
      ),
      SessionsTimeFilter.lastMonth => _isWithinTimeRange(
        value,
        DateTime(today.year, today.month - 1),
        DateTime(today.year, today.month),
      ),
      SessionsTimeFilter.last30Days => !value.isBefore(
        now.subtract(const Duration(days: 30)),
      ),
      SessionsTimeFilter.allTime => true,
    };
  }

  DateTime _startOfWeek(DateTime value) {
    return value.subtract(Duration(days: value.weekday - DateTime.monday));
  }

  bool _isWithinTimeRange(DateTime value, DateTime start, DateTime end) {
    return !value.isBefore(start) && value.isBefore(end);
  }

  bool _matchesPath(SessionRowViewModel row, String path) {
    if (path.isEmpty) {
      return true;
    }
    return row.path.replaceAll(r'\', '/').toLowerCase().contains(path);
  }

  bool _matchesThreadName(SessionRowViewModel row, String threadName) {
    if (threadName.isEmpty) {
      return true;
    }
    return row.threadName.toLowerCase().contains(threadName);
  }

  bool _matchesSearch(SessionRowViewModel row, String search) {
    if (search.isEmpty) {
      return true;
    }
    return [
      row.title,
      row.summary,
      row.project,
      row.threadName,
      row.path,
      row.platformLabel,
      row.originLabel,
      row.model,
      row.status,
      ...row.tags,
    ].any((value) => value.toLowerCase().contains(search));
  }

  bool get _hasActiveFilters {
    return _searchController.text.trim().isNotEmpty ||
        _pathController.text.trim().isNotEmpty ||
        _threadNameController.text.trim().isNotEmpty ||
        _platformFilter != SessionsPlatformFilter.both ||
        _timeFilter != _defaultTimeFilter ||
        _archivedFilter != SessionsArchivedFilter.activeOnly ||
        _originFilter != _defaultOriginFilter ||
        _newestPerProjectOnly ||
        _namedOnly;
  }

  bool get _hasRowsHiddenOnlyByOrigin {
    if (_originFilter != _defaultOriginFilter || _rows.isEmpty) {
      return false;
    }
    final search = _searchController.text.trim().toLowerCase();
    final path = _pathController.text
        .trim()
        .replaceAll(r'\', '/')
        .toLowerCase();
    final threadName = _threadNameController.text.trim().toLowerCase();
    return _rows.any(
      (row) =>
          row.isSubagentSession &&
          _matchesArchived(row) &&
          _matchesPlatform(row) &&
          _matchesTime(row) &&
          _matchesPath(row, path) &&
          _matchesThreadName(row, threadName) &&
          (!_namedOnly || row.hasThreadName) &&
          _matchesSearch(row, search),
    );
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
    _selectedDetailLoadGeneration++;
    setState(() {
      _selectedId = id;
    });
    _watchSelectedSessionFile(_rowById(id));
    unawaited(_loadSelectedDetail(id));
  }

  void _queueOpenTargetFromWidget() {
    final target = widget.openTarget;
    if (target == null) {
      _pendingOpenTarget = null;
      _pendingOpenTargetSerial = null;
      _handledOpenTargetSerial = widget.openTargetSerial;
      return;
    }
    _pendingOpenTarget = target;
    _pendingOpenTargetSerial = widget.openTargetSerial;
    _tryApplyPendingOpenTarget();
  }

  void _tryApplyPendingOpenTarget() {
    final target = _pendingOpenTarget;
    final serial = _pendingOpenTargetSerial;
    if (target == null ||
        serial == null ||
        _rowById(target.sessionId) == null) {
      return;
    }
    _applyOpenTarget(target);
    _pendingOpenTarget = null;
    _pendingOpenTargetSerial = null;
    _handledOpenTargetSerial = serial;
  }

  void _applyOpenTarget(SessionOpenTarget target) {
    _revealOpenTarget(target.sessionId);
    final messageIndex = target.messageIndex;
    if (messageIndex != null) {
      _conversationPositions[target.sessionId] = ConversationPositionState(
        messageNumber: messageIndex,
        wasNearBottom: false,
        messageCount: 0,
      );
    }
    _select(target.sessionId);
  }

  void _revealOpenTarget(String id) {
    if (_rowById(id) == null || _visibleRows.any((row) => row.id == id)) {
      return;
    }
    _searchController.removeListener(_filtersChanged);
    _pathController.removeListener(_filtersChanged);
    _threadNameController.removeListener(_filtersChanged);
    try {
      setState(() {
        _searchController.clear();
        _pathController.clear();
        _threadNameController.clear();
        _platformFilter = SessionsPlatformFilter.both;
        _timeFilter = SessionsTimeFilter.allTime;
        _archivedFilter = SessionsArchivedFilter.all;
        _originFilter = SessionsOriginFilter.all;
        _newestPerProjectOnly = false;
        _namedOnly = false;
        _markVisibleRowsForMotion({id});
      });
    } finally {
      _searchController.addListener(_filtersChanged);
      _pathController.addListener(_filtersChanged);
      _threadNameController.addListener(_filtersChanged);
    }
  }

  void _toggleSubagents(String parentId) {
    setState(() {
      if (!_expandedParentIds.add(parentId)) {
        _expandedParentIds.remove(parentId);
      }
    });
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
    final generation = ++_selectedDetailLoadGeneration;
    try {
      final loaded = await loader(id);
      if (!mounted ||
          loaded == null ||
          generation != _selectedDetailLoadGeneration ||
          _selectedId != id) {
        return;
      }
      setState(() {
        _replaceRow(loaded);
        _retainSelection();
      });
    } finally {
      if (mounted &&
          _loadingDetailId == id &&
          generation == _selectedDetailLoadGeneration) {
        setState(() {
          _loadingDetailId = null;
        });
      }
    }
  }

  Future<void> _reloadSelectedDetailFromSource(
    String id,
    int generation,
  ) async {
    final loader =
        widget.onReloadSessionDetailFromSource ?? widget.onLoadSessionDetail;
    if (loader == null || _loadingDetailId == id) {
      return;
    }
    setState(() {
      _loadingDetailId = id;
    });
    final loadGeneration = ++_selectedDetailLoadGeneration;
    try {
      final loaded = await loader(id);
      if (!mounted ||
          loaded == null ||
          generation != _selectedDetailWatchGeneration ||
          loadGeneration != _selectedDetailLoadGeneration ||
          _selectedId != id) {
        return;
      }
      setState(() {
        _replaceRow(loaded);
        _retainSelection();
      });
    } finally {
      if (mounted &&
          _loadingDetailId == id &&
          loadGeneration == _selectedDetailLoadGeneration) {
        setState(() {
          _loadingDetailId = null;
        });
      }
    }
  }

  void _watchSelectedSessionFile(SessionRowViewModel? row) {
    _selectedDetailWatchGeneration++;
    final path = row?.sourceFilePath.trim() ?? '';
    if (path.isEmpty ||
        widget.onReloadSessionDetailFromSource == null &&
            widget.onLoadSessionDetail == null) {
      _stopSelectedSessionFileWatch(incrementGeneration: false);
      return;
    }
    if (_watchedDetailPath == path) {
      return;
    }
    _stopSelectedSessionFileWatch(incrementGeneration: false);
    _watchedDetailPath = path;
    final generation = _selectedDetailWatchGeneration;
    try {
      _selectedFileSubscription = widget
          .watchSessionFile(path)
          .listen(
            (_) => _scheduleSelectedDetailReload(row!.id, generation),
            onError: (_) {},
          );
    } on Object {
      _watchedDetailPath = null;
    }
  }

  void _scheduleSelectedDetailReload(String id, int generation) {
    _selectedFileReloadTimer?.cancel();
    _selectedFileReloadTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted ||
          generation != _selectedDetailWatchGeneration ||
          _selectedId != id) {
        return;
      }
      unawaited(_reloadSelectedDetailFromSource(id, generation));
    });
  }

  void _stopSelectedSessionFileWatch({bool incrementGeneration = true}) {
    if (incrementGeneration) {
      _selectedDetailWatchGeneration++;
    }
    _selectedFileReloadTimer?.cancel();
    _selectedFileReloadTimer = null;
    unawaited(_selectedFileSubscription?.cancel());
    _selectedFileSubscription = null;
    _watchedDetailPath = null;
  }

  void _filtersChanged() {
    setState(() {
      _retainSelection();
      _markVisibleRowsForMotion();
    });
  }

  void _retainSelection() {
    final selectedId = _selectedId;
    if (selectedId == null) {
      return;
    }
    if (!_visibleRows.any((row) => row.id == selectedId)) {
      _selectedId = null;
      _stopSelectedSessionFileWatch();
    }
  }

  void _clearFilters() {
    _searchController.removeListener(_filtersChanged);
    _pathController.removeListener(_filtersChanged);
    _threadNameController.removeListener(_filtersChanged);
    try {
      setState(() {
        _searchController.clear();
        _pathController.clear();
        _threadNameController.clear();
        _platformFilter = SessionsPlatformFilter.both;
        _timeFilter = _defaultTimeFilter;
        _archivedFilter = SessionsArchivedFilter.activeOnly;
        _originFilter = _defaultOriginFilter;
        _newestPerProjectOnly = false;
        _namedOnly = false;
        _retainSelection();
        _markVisibleRowsForMotion();
      });
      _emitTableState();
    } finally {
      _searchController.addListener(_filtersChanged);
      _pathController.addListener(_filtersChanged);
      _threadNameController.addListener(_filtersChanged);
    }
  }

  void _showAllOrigins() {
    setState(() {
      _originFilter = SessionsOriginFilter.all;
      _retainSelection();
      _markVisibleRowsForMotion();
    });
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
      _tryApplyPendingOpenTarget();
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
    _tryApplyPendingOpenTarget();
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
      if (request.action == SessionRowAction.updateEvalMetadata &&
          request.evalMetadata != null &&
          mounted) {
        _replaceEvalMetadata(request.row, request.evalMetadata!);
      }
      return;
    }
    if (request.action == SessionRowAction.updateEvalMetadata &&
        request.evalMetadata != null) {
      _replaceEvalMetadata(request.row, request.evalMetadata!);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Eval metadata updated.')));
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
    if (action == SessionDetailAction.addToEvals) {
      await _saveEvalMetadata(
        row,
        SessionEvalMetadata(
          evalReady: true,
          status: _blankToNull(row.evalStatus),
          notes: _blankToNull(row.evalNotes),
          expectedOutput: _blankToNull(row.evalExpectedOutput),
          reviewedAtUtc: row.evalReviewedAtUtc,
        ),
      );
      return;
    }
    if (action == SessionDetailAction.removeFromEvals) {
      await _saveEvalMetadata(row, const SessionEvalMetadata(evalReady: false));
      return;
    }
    if (action == SessionDetailAction.editEvalMetadata) {
      await _editEvalMetadata(row);
      return;
    }
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
        payload: row.containingFolderTarget,
      ),
      SessionDetailAction.openTerminalResume => SessionActionRequest(
        row: row,
        action: SessionRowAction.openTerminalResume,
        payload: commandSet.terminalLaunchCommand,
      ),
      SessionDetailAction.openTerminalFork => SessionActionRequest(
        row: row,
        action: SessionRowAction.openTerminalFork,
        payload: commandSet.terminalForkCommand,
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
      SessionDetailAction.editTags => SessionActionRequest(
        row: row,
        action: SessionRowAction.editTags,
      ),
      SessionDetailAction.openTerminalHere ||
      SessionDetailAction.exportMarkdown ||
      SessionDetailAction.assignProject ||
      SessionDetailAction.addToEvals ||
      SessionDetailAction.removeFromEvals ||
      SessionDetailAction.editEvalMetadata => null,
    };
    if (request != null) {
      await _handleSessionAction(request);
    }
  }

  Future<void> _editEvalMetadata(SessionRowViewModel row) async {
    var status = row.evalStatus;
    var notes = row.evalNotes;
    var expectedOutput = row.evalExpectedOutput;
    final metadata = await showDialog<SessionEvalMetadata>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit eval details'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: status,
                onChanged: (value) => status = value,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Eval review status',
                ),
              ),
              TextFormField(
                initialValue: notes,
                onChanged: (value) => notes = value,
                maxLines: 3,
                decoration: const InputDecoration(labelText: 'Eval notes'),
              ),
              TextFormField(
                initialValue: expectedOutput,
                onChanged: (value) => expectedOutput = value,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Eval expected output',
                ),
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
                expectedOutput: _blankToNull(expectedOutput),
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
    await _saveEvalMetadata(row, metadata);
  }

  Future<void> _saveEvalMetadata(
    SessionRowViewModel row,
    SessionEvalMetadata metadata,
  ) async {
    await _handleSessionAction(
      SessionActionRequest(
        row: row,
        action: SessionRowAction.updateEvalMetadata,
        evalMetadata: metadata,
      ),
    );
  }

  void _replaceEvalMetadata(
    SessionRowViewModel row,
    SessionEvalMetadata metadata,
  ) {
    setState(() {
      _replaceRow(row.copyWithEvalMetadata(metadata));
    });
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
    final policy = CodexMotionPolicy.fromContext(
      context,
      mode: (widget.settings ?? AppSettings.defaults()).ui.motion,
    );
    final result = await showGeneralDialog<List<SessionTableSortSettings>>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      transitionDuration: policy.dialogDuration,
      pageBuilder: (context, _, _) => _SortOptionsDialog(sorts: _sorts),
      transitionBuilder: (context, animation, _, child) =>
          CodexMotion.dialogTransition(
            policy: policy,
            animation: animation,
            child: child,
          ),
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
        newestPerProjectOnly: _newestPerProjectOnly,
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
    final previousById = {for (final row in _rows) row.id: row};
    final loadedMessagesById = {
      for (final row in _rows)
        if (row.conversationMessages.isNotEmpty)
          row.id: row.conversationMessages,
    };
    final nextRows = [
      for (final row in rows)
        if (row.conversationMessages.isEmpty &&
            loadedMessagesById.containsKey(row.id))
          row.copyWithConversationMessages(loadedMessagesById[row.id]!)
        else
          row,
    ];
    final changedIds = {
      for (final row in nextRows)
        if (_rowChangedForMotion(previousById[row.id], row)) row.id,
    };
    _rows = nextRows;
    _markVisibleRowsForMotion(changedIds);
  }

  void _markVisibleRowsForMotion([Set<String>? changedIds]) {
    final candidates = changedIds ?? {for (final row in _visibleRows) row.id};
    final visibleIds = <String>{};
    for (final row in _visibleRows) {
      if (candidates.contains(row.id)) {
        visibleIds.add(row.id);
        if (visibleIds.length >= 40) {
          break;
        }
      }
    }
    _rowMotionIds = visibleIds;
    if (visibleIds.isNotEmpty) {
      _rowMotionGeneration++;
    }
  }

  bool _rowChangedForMotion(
    SessionRowViewModel? previous,
    SessionRowViewModel next,
  ) {
    return previous == null ||
        previous.title != next.title ||
        previous.summary != next.summary ||
        previous.project != next.project ||
        previous.path != next.path ||
        previous.status != next.status ||
        previous.lastMessageAtUtc != next.lastMessageAtUtc ||
        previous.messageCount != next.messageCount ||
        previous.totalTokens != next.totalTokens;
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

class _SessionHierarchy {
  const _SessionHierarchy({
    required this.parents,
    required this.subagents,
    required this.orphanSubagents,
    required this.childrenByParentId,
    required this.parentByChildId,
  });

  final List<SessionRowViewModel> parents;
  final List<SessionRowViewModel> subagents;
  final List<SessionRowViewModel> orphanSubagents;
  final Map<String, List<SessionRowViewModel>> childrenByParentId;
  final Map<String, SessionRowViewModel> parentByChildId;
}

class _SessionDisplayRow {
  const _SessionDisplayRow._({
    required this.row,
    required this.depth,
    required this.childCount,
    required this.expanded,
    this.parent,
    this.directSubagent = false,
  });

  factory _SessionDisplayRow.parent({
    required SessionRowViewModel row,
    required int childCount,
    required bool expanded,
  }) {
    return _SessionDisplayRow._(
      row: row,
      depth: 0,
      childCount: childCount,
      expanded: expanded,
    );
  }

  factory _SessionDisplayRow.child({
    required SessionRowViewModel row,
    required SessionRowViewModel parent,
  }) {
    return _SessionDisplayRow._(
      row: row,
      depth: 1,
      childCount: 0,
      expanded: false,
      parent: parent,
    );
  }

  factory _SessionDisplayRow.directSubagent({
    required SessionRowViewModel row,
    SessionRowViewModel? parent,
  }) {
    return _SessionDisplayRow._(
      row: row,
      depth: 0,
      childCount: 0,
      expanded: false,
      parent: parent,
      directSubagent: true,
    );
  }

  final SessionRowViewModel row;
  final int depth;
  final int childCount;
  final bool expanded;
  final SessionRowViewModel? parent;
  final bool directSubagent;

  bool get hasChildren => childCount > 0;

  String get parentLabel {
    final parentRow = parent;
    return parentRow == null ? '' : _rowAccessibleLabel(parentRow);
  }

  String get summaryText {
    if (!row.isSubagentSession) {
      final summary = row.summary.trim();
      if (summary.isEmpty || summary == row.primaryIdentity) {
        return '';
      }
      return row.summary;
    }
    final parentName = parentLabel;
    final parentSuffix = directSubagent && parentName.isNotEmpty
        ? ' (Parent: $parentName)'
        : '';
    return '${row.originLabel} - ${row.summary} - ${row.estimatedCostDisplay}$parentSuffix';
  }

  String get accessibleLabel {
    final label = _rowAccessibleLabel(row);
    if (row.isSubagentSession) {
      final parentName = parentLabel;
      final parentSuffix = parentName.isEmpty ? '' : ' under $parentName';
      return '${row.originLabel}, $label$parentSuffix';
    }
    if (hasChildren) {
      final state = expanded ? 'expanded' : 'collapsed';
      final childLabel = childCount == 1 ? 'session' : 'sessions';
      return '$label, $childCount subagent $childLabel $state';
    }
    return label;
  }
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

bool _isUnreachableStatus(String statusMessage) {
  return statusMessage.toLowerCase().contains('unreachable');
}

class _SessionsEmptyState extends StatelessWidget {
  const _SessionsEmptyState({
    required this.hasRows,
    required this.hasActiveFilters,
    required this.statusMessage,
    required this.isScanning,
    required this.visibleCount,
    required this.unreachablePaths,
    required this.hasRowsHiddenByDefaultOrigin,
    required this.onClearFilters,
    required this.onShowAllOrigins,
    required this.onOpenSettings,
    required this.onTestWslPath,
  });

  final bool hasRows;
  final bool hasActiveFilters;
  final String statusMessage;
  final bool isScanning;
  final int visibleCount;
  final List<String> unreachablePaths;
  final bool hasRowsHiddenByDefaultOrigin;
  final VoidCallback onClearFilters;
  final VoidCallback onShowAllOrigins;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onTestWslPath;

  @override
  Widget build(BuildContext context) {
    final isUnreachable = _isUnreachableStatus(statusMessage);
    final title = isUnreachable
        ? 'Codex session path is currently unreachable.'
        : hasRowsHiddenByDefaultOrigin
        ? 'Only subagent sessions match the current filters.'
        : hasRows && hasActiveFilters
        ? 'No sessions match the current filters.'
        : 'No sessions found.';
    final body = isUnreachable
        ? 'Cached sessions remain visible when available. Check the configured path, then run Refresh.'
        : hasRowsHiddenByDefaultOrigin
        ? 'The default Origin filter shows user sessions. Show all origins to inspect subagent sessions.'
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
                  _UnreachableRecoveryActions(
                    onTestWslPath: onTestWslPath,
                    onOpenSettings: onOpenSettings,
                  ),
                ] else if (hasRowsHiddenByDefaultOrigin) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: onShowAllOrigins,
                    icon: const AppSvgIcon(AppIcons.filter),
                    label: const Text('Show all origins'),
                  ),
                ] else if (hasRows && hasActiveFilters) ...[
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: onClearFilters,
                    icon: const AppSvgIcon(AppIcons.filterClear),
                    label: const Text('Clear filters'),
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: onOpenSettings,
                        icon: const AppSvgIcon(AppIcons.settings),
                        label: const Text('Open Settings'),
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

class _UnreachableRecoveryPanel extends StatelessWidget {
  const _UnreachableRecoveryPanel({
    required this.unreachablePaths,
    required this.onOpenSettings,
    required this.onTestWslPath,
  });

  final List<String> unreachablePaths;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onTestWslPath;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (unreachablePaths.isNotEmpty) ...[
            SelectableText('Configured path: ${unreachablePaths.join('; ')}'),
            const SizedBox(height: 8),
          ],
          _UnreachableRecoveryActions(
            onTestWslPath: onTestWslPath,
            onOpenSettings: onOpenSettings,
          ),
        ],
      ),
    );
  }
}

class _UnreachableRecoveryActions extends StatelessWidget {
  const _UnreachableRecoveryActions({
    required this.onTestWslPath,
    required this.onOpenSettings,
  });

  final VoidCallback? onTestWslPath;
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          onPressed: onTestWslPath,
          icon: const AppSvgIcon(AppIcons.terminal),
          label: const Text('Test WSL path'),
        ),
        OutlinedButton.icon(
          onPressed: onOpenSettings,
          icon: const AppSvgIcon(AppIcons.settings),
          label: const Text('Open Settings'),
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.searchController,
    required this.pathController,
    required this.threadNameController,
    required this.platformFilter,
    required this.timeFilter,
    required this.archivedFilter,
    required this.originFilter,
    required this.newestPerProjectOnly,
    required this.namedOnly,
    required this.isScanning,
    required this.isCancellingRefresh,
    required this.onPlatformChanged,
    required this.onTimeChanged,
    required this.onArchivedChanged,
    required this.onOriginChanged,
    required this.onNewestPerProjectOnlyChanged,
    required this.onNamedOnlyChanged,
    required this.onClearFilters,
    required this.onRefresh,
  });

  final TextEditingController searchController;
  final TextEditingController pathController;
  final TextEditingController threadNameController;
  final SessionsPlatformFilter platformFilter;
  final SessionsTimeFilter timeFilter;
  final SessionsArchivedFilter archivedFilter;
  final SessionsOriginFilter originFilter;
  final bool newestPerProjectOnly;
  final bool namedOnly;
  final bool isScanning;
  final bool isCancellingRefresh;
  final ValueChanged<SessionsPlatformFilter> onPlatformChanged;
  final ValueChanged<SessionsTimeFilter> onTimeChanged;
  final ValueChanged<SessionsArchivedFilter> onArchivedChanged;
  final ValueChanged<SessionsOriginFilter> onOriginChanged;
  final ValueChanged<bool> onNewestPerProjectOnlyChanged;
  final ValueChanged<bool> onNamedOnlyChanged;
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
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  width: 280,
                  child: Semantics(
                    label: 'Session search',
                    textField: true,
                    child: TextField(
                      controller: searchController,
                      decoration: const InputDecoration(
                        labelText: 'Search',
                        isDense: true,
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 140,
                  child: _FilterSemantics(
                    label: 'Platform filter',
                    child: DropdownButtonFormField<SessionsPlatformFilter>(
                      key: ValueKey(platformFilter),
                      initialValue: platformFilter,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Platform',
                        isDense: true,
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
                SizedBox(
                  width: 140,
                  child: _FilterSemantics(
                    label: 'Time range filter',
                    child: DropdownButtonFormField<SessionsTimeFilter>(
                      key: ValueKey('time-filter-${timeFilter.name}'),
                      initialValue: timeFilter,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Time',
                        isDense: true,
                      ),
                      items: [
                        for (final value in SessionsTimeFilter.values)
                          DropdownMenuItem(
                            value: value,
                            child: Text(value.label),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          onTimeChanged(value);
                        }
                      },
                    ),
                  ),
                ),
                SizedBox(
                  width: 150,
                  child: _FilterSemantics(
                    label: 'Archived filter',
                    child: DropdownButtonFormField<SessionsArchivedFilter>(
                      key: ValueKey(archivedFilter),
                      initialValue: archivedFilter,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Archived',
                        isDense: true,
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
                _NewestPerProjectFilter(
                  value: newestPerProjectOnly,
                  onChanged: onNewestPerProjectOnlyChanged,
                ),
                _NamedOnlyFilter(
                  value: namedOnly,
                  onChanged: onNamedOnlyChanged,
                ),
                ElevatedButton.icon(
                  onPressed: isCancellingRefresh ? null : onRefresh,
                  icon: AppSvgIcon(
                    isScanning ? AppIcons.cancel : AppIcons.refresh,
                  ),
                  label: Text(refreshLabel),
                ),
                OutlinedButton.icon(
                  onPressed: onClearFilters,
                  icon: const AppSvgIcon(AppIcons.filterClear),
                  label: const Text('Clear filters'),
                ),
              ],
            ),
            Theme(
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
                visualDensity: VisualDensity.compact,
              ),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(top: 4, bottom: 2),
                title: const Text('Advanced filters'),
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 940),
                      child: Row(
                        children: [
                          Expanded(
                            flex: 2,
                            child: Semantics(
                              label: 'Path filter',
                              textField: true,
                              child: TextField(
                                controller: pathController,
                                decoration: const InputDecoration(
                                  labelText: 'Path',
                                  isDense: true,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Semantics(
                              label: 'Thread name filter',
                              textField: true,
                              child: TextField(
                                controller: threadNameController,
                                decoration: const InputDecoration(
                                  labelText: 'Thread name',
                                  isDense: true,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _staticFilter('Project filter', 'Project'),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: _staticFilter('Tags filter', 'Tags')),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _staticFilter('Model filter', 'Model'),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _FilterSemantics(
                              label: 'Origin filter',
                              child:
                                  DropdownButtonFormField<SessionsOriginFilter>(
                                    key: ValueKey(
                                      'origin-filter-${originFilter.name}',
                                    ),
                                    initialValue: originFilter,
                                    isExpanded: true,
                                    decoration: const InputDecoration(
                                      labelText: 'Origin',
                                      isDense: true,
                                    ),
                                    items: const [
                                      DropdownMenuItem(
                                        value: SessionsOriginFilter.all,
                                        child: Text('All'),
                                      ),
                                      DropdownMenuItem(
                                        value: SessionsOriginFilter.user,
                                        child: Text('User'),
                                      ),
                                      DropdownMenuItem(
                                        value: SessionsOriginFilter.subagent,
                                        child: Text('Subagent'),
                                      ),
                                    ],
                                    onChanged: (value) {
                                      if (value != null) {
                                        onOriginChanged(value);
                                      }
                                    },
                                  ),
                            ),
                          ),
                        ],
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

  Widget _staticFilter(String semanticsLabel, String label) {
    return _FilterSemantics(
      label: semanticsLabel,
      child: DropdownButtonFormField<String>(
        initialValue: 'All',
        isExpanded: true,
        decoration: InputDecoration(labelText: label, isDense: true),
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
          constraints: const BoxConstraints(minHeight: 36, maxWidth: 190),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: value,
                visualDensity: VisualDensity.compact,
                semanticLabel: 'Newest session per project filter',
                onChanged: (checked) => onChanged(checked ?? false),
              ),
              const Flexible(
                child: Text(
                  'Newest per project',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }
}

class _NamedOnlyFilter extends StatelessWidget {
  const _NamedOnlyFilter({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Named sessions only filter',
      button: true,
      toggled: value,
      child: IconButton(
        tooltip: 'Named sessions only',
        isSelected: value,
        onPressed: () => onChanged(!value),
        style: IconButton.styleFrom(
          backgroundColor: value ? colorScheme.secondaryContainer : null,
          foregroundColor: value ? colorScheme.onSecondaryContainer : null,
          minimumSize: const Size.square(36),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
        ),
        icon: const AppSvgIcon(AppIcons.filter),
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
    final displayMessage = _scanStatusDisplayMessage(message);
    final lowerMessage = displayMessage.toLowerCase();
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
      label: displayMessage,
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
          Expanded(
            child: Text(displayMessage, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}

String _scanStatusDisplayMessage(String message) {
  final lowerMessage = message.toLowerCase();
  if (!lowerMessage.startsWith('scan finished') &&
      !lowerMessage.startsWith('scan cancelled')) {
    return message;
  }
  return message.replaceAllMapped(
    RegExp(r'\b(\d+) (session|sessions) visible\b'),
    (match) => '${match[1]} ${match[2]} available',
  );
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
  Widget build(BuildContext context) =>
      AppSvgIcon(assetName, size: size, color: color);
}

class _SessionsTable extends StatelessWidget {
  const _SessionsTable({
    required this.rows,
    required this.selectedId,
    required this.onSelect,
    required this.onToggleSubagents,
    required this.onAction,
    required this.settings,
    required this.columnWidths,
    required this.sorts,
    required this.onColumnWidthChanged,
    required this.onSortGesture,
    required this.onShowSortOptions,
    required this.statusMessage,
    required this.isScanning,
    required this.animatedRowIds,
    required this.rowMotionGeneration,
    required this.unreachablePaths,
    required this.onOpenSettings,
    required this.onTestWslPath,
  });

  final List<_SessionDisplayRow> rows;
  final String? selectedId;
  final ValueChanged<String> onSelect;
  final ValueChanged<String> onToggleSubagents;
  final SessionActionCallback onAction;
  final AppSettings settings;
  final Map<String, double> columnWidths;
  final List<SessionTableSortSettings> sorts;
  final void Function(String column, double width) onColumnWidthChanged;
  final void Function(String column, _SortGesture gesture) onSortGesture;
  final Future<void> Function(BuildContext context) onShowSortOptions;
  final String statusMessage;
  final bool isScanning;
  final Set<String> animatedRowIds;
  final int rowMotionGeneration;
  final List<String> unreachablePaths;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onTestWslPath;

  static const _rowHeight = 48.0;
  static const _columns = <_SessionColumn>[
    _SessionColumn(
      key: 'last_message_at',
      label: 'Last Message',
      defaultWidth: 132,
    ),
    _SessionColumn(key: 'actions', label: 'Actions', defaultWidth: 96),
    _SessionColumn(key: 'project', label: 'Project', defaultWidth: 112),
    _SessionColumn(key: 'path', label: 'Path', defaultWidth: 280),
    _SessionColumn(key: 'summary', label: 'Summary', defaultWidth: 220),
    _SessionColumn(key: 'message_count', label: 'Messages', defaultWidth: 82),
    _SessionColumn(key: 'total_tokens', label: 'Tokens', defaultWidth: 78),
    _SessionColumn(key: 'model', label: 'Model', defaultWidth: 110),
    _SessionColumn(key: 'tags', label: 'Tags', defaultWidth: 130),
  ];

  static double tableWidthFor(Map<String, double> columnWidths) {
    return _columns.fold<double>(
      0,
      (total, column) =>
          total + (columnWidths[column.key] ?? column.defaultWidth),
    );
  }

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
        if (_isUnreachableStatus(statusMessage))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _UnreachableRecoveryPanel(
              unreachablePaths: unreachablePaths,
              onOpenSettings: onOpenSettings,
              onTestWslPath: onTestWslPath,
            ),
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
      height: 32,
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

  Widget _sessionRow(BuildContext context, _SessionDisplayRow displayRow) {
    final row = displayRow.row;
    final selected = row.id == selectedId;
    final color = _rowColor(context, row, selected: selected);
    final child = Semantics(
      label: 'Session ${displayRow.accessibleLabel}. Status ${_rowState(row)}.',
      selected: selected,
      container: true,
      child: InkWell(
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
              _projectCell(context, displayRow, width: _widthFor('project')),
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
              _summaryCell(displayRow.summaryText, width: _widthFor('summary')),
              _countCell(
                'Messages',
                row.messageCount,
                width: _widthFor('message_count'),
              ),
              _countCell(
                'Tokens',
                row.displayTotalTokens,
                width: _widthFor('total_tokens'),
              ),
              _cell('Model', row.model, width: _widthFor('model')),
              _TagsCell(
                row: row,
                width: _widthFor('tags'),
                onAddTag: () => onAction(
                  SessionActionRequest(
                    row: row,
                    action: SessionRowAction.editTags,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!animatedRowIds.contains(row.id)) {
      return child;
    }
    final policy = CodexMotionPolicy.fromContext(
      context,
      mode: settings.ui.motion,
    );
    return TweenAnimationBuilder<double>(
      key: Key('session-row-motion-${row.id}-v$rowMotionGeneration'),
      tween: Tween(begin: 0, end: 1),
      duration: policy.isReduced
          ? CodexMotionDurations.fast
          : policy.rowUpdateDuration,
      curve: policy.standardCurve,
      builder: (context, value, child) => CodexMotion.rowUpdateTransition(
        policy: policy,
        animation: AlwaysStoppedAnimation(value),
        child: child!,
      ),
      child: child,
    );
  }

  Widget _cell(
    String label,
    String text, {
    required double width,
    String? semanticsText,
    String? tooltip,
  }) => SizedBox(
    width: width,
    child: Semantics(
      label: '$label ${semanticsText ?? (text.isEmpty ? 'empty' : text)}',
      container: true,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Tooltip(
            message: tooltip ?? text,
            waitDuration: const Duration(milliseconds: 600),
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      ),
    ),
  );

  Widget _countCell(String label, int value, {required double width}) {
    final display = formatCompactInt(value);
    final exact = formatGroupedInt(value);
    return _cell(
      label,
      display,
      width: width,
      semanticsText: exact,
      tooltip: exact,
    );
  }

  Widget _summaryCell(String text, {required double width}) {
    if (text.trim().isEmpty) {
      return SizedBox(width: width);
    }
    return _cell('Summary', text, width: width);
  }

  Widget _projectCell(
    BuildContext context,
    _SessionDisplayRow displayRow, {
    required double width,
  }) {
    final row = displayRow.row;
    final identity = row.primaryIdentity;
    final project = row.project.trim();
    final showProject = project.isNotEmpty && project != identity;
    final subagentLabel = displayRow.childCount == 1
        ? '1 subagent'
        : '${displayRow.childCount} subagents';
    final label = displayRow.hasChildren
        ? '${displayRow.expanded ? 'Hide' : 'Show'} $subagentLabel for ${_rowAccessibleLabel(row)}'
        : '';
    return SizedBox(
      width: width,
      child: Padding(
        padding: EdgeInsets.only(left: 4 + (displayRow.depth * 18), right: 6),
        child: Row(
          children: [
            if (displayRow.hasChildren)
              Semantics(
                label: label,
                button: true,
                child: IconButton(
                  key: Key('subagent-toggle-${row.id}'),
                  tooltip: label,
                  onPressed: () => onToggleSubagents(row.id),
                  icon: AppSvgIcon(
                    displayRow.expanded ? AppIcons.collapse : AppIcons.expand,
                  ),
                ),
              )
            else if (displayRow.depth > 0)
              const SizedBox(width: 28)
            else
              const SizedBox(width: 4),
            Expanded(
              child: Semantics(
                label:
                    'Session identity $identity'
                    '${showProject ? ', project $project' : ''}',
                container: true,
                child: ExcludeSemantics(
                  child: Tooltip(
                    message: showProject
                        ? '$identity\nProject: $project'
                        : identity,
                    waitDuration: const Duration(milliseconds: 600),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          identity,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (showProject)
                          Text(
                            project,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dateCell(SessionRowViewModel row) {
    final display = row.lastMessageAtUtc.relativeDisplay();
    return Semantics(
      label: 'Last Message Date $display',
      container: true,
      child: ExcludeSemantics(
        child: SizedBox(
          width: _widthFor('last_message_at'),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Tooltip(
              message: row.lastMessageAtUtc.shortDateTime,
              waitDuration: const Duration(milliseconds: 600),
              child: Text(
                display,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
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
                icon: const AppSvgIcon(AppIcons.copy),
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

class _TagsCell extends StatelessWidget {
  const _TagsCell({
    required this.row,
    required this.width,
    required this.onAddTag,
  });

  final SessionRowViewModel row;
  final double width;
  final VoidCallback onAddTag;

  @override
  Widget build(BuildContext context) {
    final text = row.tags.join(', ');
    final rowLabel = _rowAccessibleLabel(row);
    return SizedBox(
      width: width,
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              label: 'Tags ${text.isEmpty ? 'empty' : text}',
              container: true,
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Tooltip(
                    message: text,
                    waitDuration: const Duration(milliseconds: 600),
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Semantics(
            label: 'Add tag to $rowLabel',
            button: true,
            child: IconButton(
              tooltip: 'Add tag',
              icon: const Icon(Icons.add, size: 18),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 30, height: 30),
              onPressed: onAddTag,
            ),
          ),
        ],
      ),
    );
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
    final resumeReason =
        commandSet.terminalDisabledReason ??
        commandSet.disabledReason ??
        'Resume command unavailable.';
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Semantics(
          label: commandSet.terminalLaunchCommand == null
              ? 'Open terminal and resume unavailable for $rowLabel: $resumeReason'
              : 'Open terminal and resume for $rowLabel',
          button: true,
          child: IconButton(
            tooltip: commandSet.terminalLaunchCommand == null
                ? 'Resume unavailable: $resumeReason'
                : 'Open terminal and resume',
            icon: const AppSvgIcon(AppIcons.terminal),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 32, height: 32),
            onPressed: commandSet.terminalLaunchCommand == null
                ? null
                : () => onAction(
                    SessionActionRequest(
                      row: row,
                      action: SessionRowAction.openTerminalResume,
                      payload: commandSet.terminalLaunchCommand,
                    ),
                  ),
          ),
        ),
        Semantics(
          label: 'More actions for $rowLabel',
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
              if (_canOpenContainingFolder(row))
                _item(
                  SessionRowAction.openPath,
                  'Open containing folder',
                  iconAsset: AppIcons.folderOpen,
                ),
              if (commandSet.terminalLaunchCommand == null)
                _item(
                  SessionRowAction.openTerminalResume,
                  'Resume unavailable',
                  iconAsset: AppIcons.terminal,
                  enabled: false,
                  disabledReason: resumeReason,
                ),
              _item(
                SessionRowAction.copyPlainResumeCommand,
                'Copy plain resume command',
                iconAsset: AppIcons.copy,
                enabled: commandSet.plainResumeCommand != null,
                disabledReason: commandSet.disabledReason,
              ),
              _item(
                SessionRowAction.copyPlatformResumeCommand,
                'Copy platform resume command',
                iconAsset: AppIcons.copy,
                enabled: commandSet.platformResumeCommand != null,
                disabledReason: commandSet.disabledReason,
              ),
              _item(
                SessionRowAction.openTerminalFork,
                'Open terminal and fork',
                iconAsset: AppIcons.fork,
                enabled: commandSet.terminalForkCommand != null,
                disabledReason:
                    commandSet.terminalDisabledReason ??
                    commandSet.disabledReason,
              ),
              _item(
                SessionRowAction.copyTerminalCommand,
                'Copy terminal command',
                iconAsset: AppIcons.copy,
                enabled: commandSet.terminalLaunchCommand != null,
                disabledReason:
                    commandSet.terminalDisabledReason ??
                    commandSet.disabledReason,
              ),
              _item(
                SessionRowAction.editTags,
                'Add/remove tags',
                iconAsset: AppIcons.tag,
              ),
              _item(
                SessionRowAction.togglePin,
                row.isPinned ? 'Unpin session' : 'Pin session',
                iconAsset: AppIcons.pin,
              ),
              _item(
                SessionRowAction.toggleArchive,
                row.isArchived ? 'Unarchive session' : 'Archive session',
                iconAsset: AppIcons.archive,
              ),
              _item(
                SessionRowAction.reparse,
                'Re-parse session',
                iconAsset: AppIcons.reparse,
              ),
            ],
          ),
        ),
      ],
    );
  }

  PopupMenuItem<SessionRowAction> _item(
    SessionRowAction action,
    String label, {
    bool enabled = true,
    String? disabledReason,
    String? iconAsset,
  }) {
    final labelWidget = iconAsset == null
        ? Text(label)
        : Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AppSvgIcon(iconAsset),
              const SizedBox(width: 10),
              Flexible(child: Text(label)),
            ],
          );
    return PopupMenuItem<SessionRowAction>(
      value: action,
      enabled: enabled,
      child: enabled || disabledReason == null
          ? labelWidget
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                labelWidget,
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
      SessionRowAction.openPath => row.containingFolderTarget,
      SessionRowAction.copyPath => row.path,
      SessionRowAction.copyPlainResumeCommand => commandSet.plainResumeCommand,
      SessionRowAction.copyPlatformResumeCommand =>
        commandSet.platformResumeCommand,
      SessionRowAction.openTerminalResume => commandSet.terminalLaunchCommand,
      SessionRowAction.openTerminalFork => commandSet.terminalForkCommand,
      SessionRowAction.copyTerminalCommand => commandSet.terminalLaunchCommand,
      SessionRowAction.editTags => null,
      SessionRowAction.togglePin ||
      SessionRowAction.toggleArchive ||
      SessionRowAction.updateEvalMetadata ||
      SessionRowAction.reparse => null,
    };
  }

  bool _canOpenContainingFolder(SessionRowViewModel row) =>
      row.canOpenContainingFolder;
}

extension on SessionRowAction {
  String get label {
    return switch (this) {
      SessionRowAction.openPath => 'Open containing folder',
      SessionRowAction.copyPath => 'Copy path',
      SessionRowAction.copyPlainResumeCommand => 'Copy plain resume command',
      SessionRowAction.copyPlatformResumeCommand =>
        'Copy platform resume command',
      SessionRowAction.openTerminalResume => 'Open terminal and resume',
      SessionRowAction.openTerminalFork => 'Open terminal and fork',
      SessionRowAction.copyTerminalCommand => 'Copy terminal command',
      SessionRowAction.editTags => 'Add or remove tags',
      SessionRowAction.togglePin => 'Pin or unpin session',
      SessionRowAction.toggleArchive => 'Archive or unarchive session',
      SessionRowAction.updateEvalMetadata => 'Update eval metadata',
      SessionRowAction.reparse => 'Re-parse session',
    };
  }
}

String? _blankToNull(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

class _SessionDetailPlaceholder extends StatelessWidget {
  const _SessionDetailPlaceholder({
    required this.row,
    required this.visibleCount,
    required this.hasRows,
    required this.hasActiveFilters,
    required this.isScanning,
    required this.settings,
    required this.onSessionAction,
    required this.onCopyText,
    required this.onExportMarkdown,
    required this.onRunTerminalCommand,
    required this.onEditTerminalCommand,
    required this.isLoadingMessages,
    required this.initialConversationMessageNumber,
    required this.onConversationPositionChanged,
    required this.onLoadMessagePage,
  });

  final SessionRowViewModel? row;
  final int visibleCount;
  final bool hasRows;
  final bool hasActiveFilters;
  final bool isScanning;
  final AppSettings settings;
  final SessionDetailActionCallback? onSessionAction;
  final DetailCopyCallback? onCopyText;
  final SessionMarkdownExportCallback? onExportMarkdown;
  final TerminalCommandCallback? onRunTerminalCommand;
  final TerminalCommandCallback? onEditTerminalCommand;
  final bool isLoadingMessages;
  final int? initialConversationMessageNumber;
  final ConversationPositionChanged? onConversationPositionChanged;
  final ConversationMessagePageLoader? onLoadMessagePage;

  @override
  Widget build(BuildContext context) {
    final policy = CodexMotionPolicy.fromContext(
      context,
      mode: settings.ui.motion,
    );
    final detailKey = row == null
        ? 'empty'
        : '${row!.id}:${isLoadingMessages ? 'loading' : 'loaded'}';
    return AnimatedSwitcher(
      duration: policy.paneDuration,
      reverseDuration: policy.paneDuration,
      switchInCurve: policy.standardCurve,
      switchOutCurve: policy.emphasizedCurve,
      transitionBuilder: (child, animation) => CodexMotion.paneFadeSlide(
        policy: policy,
        animation: animation,
        child: child,
      ),
      layoutBuilder: (currentChild, previousChildren) => Stack(
        alignment: Alignment.topLeft,
        children: [
          for (final child in previousChildren)
            IgnorePointer(
              child: ExcludeFocus(child: ExcludeSemantics(child: child)),
            ),
          ?currentChild,
        ],
      ),
      child: KeyedSubtree(
        key: ValueKey(detailKey),
        child: _buildDetail(context),
      ),
    );
  }

  Widget _buildDetail(BuildContext context) {
    if (row != null) {
      return SessionDetailPane(
        row: row!,
        settings: settings,
        onCopyText: onCopyText,
        onSessionAction: onSessionAction,
        onExportMarkdown: onExportMarkdown,
        onRunTerminalCommand: onRunTerminalCommand,
        onEditTerminalCommand: onEditTerminalCommand,
        isLoadingMessages: isLoadingMessages,
        initialConversationMessageNumber: initialConversationMessageNumber,
        onConversationPositionChanged: onConversationPositionChanged,
        onLoadMessagePage: onLoadMessagePage,
      );
    }
    final guidance = _emptyGuidance();
    final visibleText = visibleCount == 1
        ? '1 session visible.'
        : '$visibleCount sessions visible.';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              'Session detail',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 12),
          Text(guidance),
          if (visibleCount > 0) ...[
            const SizedBox(height: 8),
            Text(visibleText),
          ],
        ],
      ),
    );
  }

  String _emptyGuidance() {
    if (visibleCount > 0) {
      return 'Select a session from the table to view details.';
    }
    if (isScanning) {
      return 'Refresh is running. Select a session when results appear.';
    }
    if (hasActiveFilters) {
      return 'No sessions match the current filters. Clear filters or adjust search.';
    }
    if (hasRows) {
      return 'No sessions are visible in the current view. Clear filters or refresh sessions.';
    }
    return 'Refresh sessions to load local Codex session data.';
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
        TextButton.icon(
          onPressed: () => Navigator.of(context).pop(_defaultSorts),
          icon: const AppSvgIcon(AppIcons.refresh),
          label: const Text('Default'),
        ),
        TextButton.icon(
          onPressed: () => Navigator.of(context).pop(_defaultSorts),
          icon: const AppSvgIcon(AppIcons.filterClear),
          label: const Text('Clear'),
        ),
        TextButton.icon(
          onPressed: () => Navigator.of(context).pop(),
          icon: const AppSvgIcon(AppIcons.cancel),
          label: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).pop(_sorts),
          icon: const AppSvgIcon(AppIcons.check),
          label: const Text('Apply'),
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
  return row.primaryIdentity;
}

String _rowState(SessionRowViewModel row) {
  return [
    if (row.isPinned) 'Pinned',
    if (row.isArchived) 'Archived',
    row.status,
  ].join(', ');
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

Stream<FileSystemEvent> _watchSessionFile(String path) {
  return File(
    path,
  ).watch(events: FileSystemEvent.modify | FileSystemEvent.create);
}
