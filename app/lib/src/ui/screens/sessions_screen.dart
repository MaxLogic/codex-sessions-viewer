import 'dart:async';
import 'dart:isolate';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../commands/resume_command_generator.dart';
import '../../commands/windows_command_line.dart';
import '../../config/app_settings.dart';
import '../../export/session_list_exporter.dart';
import '../dialogs/delayed_export_progress.dart';
import '../dialogs/exclude_projects_dialog.dart';
import '../../voice_over/voice_over_service.dart';
import '../copy_shortcut.dart';
import '../../usage/usage_summary.dart';
import '../motion.dart';
import '../models/conversation_message_view_model.dart';
import '../models/session_label_formatter.dart';
import '../models/session_row_view_model.dart';
import '../number_formatting.dart';
import '../widgets/command_preview.dart';
import '../widgets/conversation_view.dart';
import '../widgets/session_detail_pane.dart';
import '../widgets/session_project_limit.dart';
import '../widgets/svg_icon.dart';
import '../widgets/app_button.dart';
import '../widgets/menu_header_entry.dart';

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
  moveToProject,
  openInProjects,
  togglePin,
  toggleArchive,
  updateEvalMetadata,
  reparse,
}

enum _SessionListAction { copyMarkdown, copyExtendedMarkdown, saveCsv }

class _SessionListMarkdownOptions {
  const _SessionListMarkdownOptions({
    required this.includeFirstMessage,
    required this.includeLastMessage,
  });

  final bool includeFirstMessage;
  final bool includeLastMessage;
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
typedef SessionListCsvExportCallback = Future<void> Function(String csv);
typedef SessionListExportMessageLoader =
    Future<Map<String, List<ConversationMessageViewModel>>> Function(
      List<String> sessionIds, {
      required bool includeFirstMessage,
      required bool includeLastMessage,
    });
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
    this.launchSpec,
    this.evalMetadata,
  });

  final SessionRowViewModel row;
  final SessionRowAction action;
  final String? payload;
  final TerminalLaunchSpec? launchSpec;
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
    this.onSaveSessionListCsv,
    this.onLoadSessionListExportMessages,
    this.onLoadSessionDetail,
    this.onReloadSessionDetailFromSource,
    this.onLoadMessagePage,
    this.onLoadAllMessages,
    this.onVoiceEvent,
    this.watchSessionFile = _watchSessionFile,
    this.settings,
    this.initialTableState,
    this.onTableStateChanged,
    this.initialStatusMessage = '',
    this.autoRefreshToken = 0,
    this.pricingRevision = 0,
    this.externalRevision = 0,
    this.pricingUpdating = false,
    this.onLoadPersistedCosts,
    this.openTarget,
    this.openTargetSerial = 0,
    this.projectFilterRequest,
    this.projectFilterSerial = 0,
    this.now = DateTime.now,
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
  final SessionListCsvExportCallback? onSaveSessionListCsv;
  final SessionListExportMessageLoader? onLoadSessionListExportMessages;
  final SessionDetailLoader? onLoadSessionDetail;
  final SessionDetailLoader? onReloadSessionDetailFromSource;
  final SessionMessagePageLoader? onLoadMessagePage;
  final Future<List<ConversationMessageViewModel>> Function(String sessionId)?
  onLoadAllMessages;

  /// Plays a voice-over event (scan started or finished, parse errors) for
  /// scans the user started.
  final void Function(VoiceOverStaticEvent event)? onVoiceEvent;
  final SessionFileWatcher watchSessionFile;
  final AppSettings? settings;
  final SessionTableSettings? initialTableState;
  final SessionTableStateChanged? onTableStateChanged;
  final String initialStatusMessage;
  final int autoRefreshToken;
  final int pricingRevision;
  final int externalRevision;
  final bool pricingUpdating;
  final Future<Map<String, UsageCostEstimate>?> Function(Iterable<String>)?
  onLoadPersistedCosts;
  final SessionOpenTarget? openTarget;
  final int openTargetSerial;

  /// Shows only this project, replacing the current filters. It applies on
  /// the first build and whenever [projectFilterSerial] changes.
  final String? projectFilterRequest;
  final int projectFilterSerial;
  final DateTime Function() now;

  @override
  State<SessionsScreen> createState() => _SessionsScreenState();
}

class _SessionsScreenState extends State<SessionsScreen> {
  static const _detailPaneMinWidth = 360.0;
  static const _minimumTablePaneWidth = 520.0;
  static const _splitDividerWidth = 9.0;
  static const _filterDebounceDuration = Duration(milliseconds: 220);
  static const _tableStateEmitDebounce = Duration(milliseconds: 500);
  static const _synchronousTextFilterRowLimit = 200;

  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode(debugLabel: 'Session search');
  final _screenFocusNode = FocusNode(debugLabel: 'Sessions screen');
  final _filterAreaFocusNode = FocusNode(
    debugLabel: 'Session filters',
    skipTraversal: true,
  );
  final _pathController = TextEditingController();
  final _threadNameController = TextEditingController();
  final _filterScrollController = ScrollController();
  var _platformFilter = SessionsPlatformFilter.both;
  var _archivedFilter = SessionsArchivedFilter.activeOnly;
  var _originFilter = _defaultOriginFilter;
  String? _harnessFilter;
  var _timeFilter = _defaultTimeFilter;
  ({int start, int? end})? _timeWindowCache;
  SessionsTimeFilter? _timeWindowCacheFilter;
  var _timeWindowCacheMinute = -1;

  // Derived views of _rows are rebuilt only when their inputs change. Scan
  // progress rebuilds the screen often, and recomputing them for thousands of
  // rows on every frame blocked the UI.
  var _expansionRevision = 0;
  List<Object?>? _displayRowsInputs;
  List<_SessionDisplayRow>? _displayRowsCache;
  List<Object?>? _hierarchyInputs;
  _SessionHierarchy? _hierarchyCache;
  List<SessionRowViewModel>? _facetRows;
  List<String> _projectOptionsCache = const [];
  List<String> _modelOptionsCache = const [];
  List<String> _tagOptionsCache = const [];
  int? _maxSessionsPerProject;
  Set<String> _excludedProjects = const {};
  Set<String> _excludedProjectKeys = const {};
  var _namedOnly = false;
  String? _projectFilter;
  var _handledProjectFilterSerial = 0;
  String? _modelFilter;
  String? _tagFilter;
  var _isScanning = false;
  var _isCancellingRefresh = false;
  var _scanAnnouncement = '';
  var _hasRefreshOwnedRows = false;

  /// The external revision current when this screen's refresh last replaced
  /// the rows; parent rows apply again only after a newer revision.
  var _refreshOwnedExternalRevision = 0;
  String? _selectedId;
  var _detailTab = SessionDetailTab.conversation;

  /// Saved share of the available width, or null for the default split.
  double? _tablePaneFraction;
  String? _loadingDetailId;
  String? _pendingExternalDetailId;
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
  var _pricingLoadGeneration = 0;
  var _pricingCostsPending = false;
  var _pricingInvalidated = false;
  late Map<String, double> _columnWidths;
  late List<SessionTableSortSettings> _sorts;
  late int _handledAutoRefreshToken;
  late int _handledOpenTargetSerial;
  SessionOpenTarget? _pendingOpenTarget;
  int? _pendingOpenTargetSerial;
  Timer? _relativeDateTimer;
  Timer? _backgroundRescanTimer;
  Timer? _filterDebounceTimer;
  Timer? _tableStateEmitTimer;
  SessionsRefreshOperation? _activeRefreshOperation;
  var _textFilterGeneration = 0;
  var _appliedSearch = '';
  var _appliedPath = '';
  var _appliedThreadName = '';
  Set<String>? _matchingSearchRowIds;
  Set<String>? _matchingPathRowIds;
  Set<String>? _matchingThreadNameRowIds;

  @override
  void initState() {
    super.initState();
    _rows = _dedupeSessionSnapshots(widget.initialRows);
    final tableState =
        widget.initialTableState ??
        (widget.settings ?? AppSettings.defaults()).ui.sessionTable;
    _columnWidths = Map.of(tableState.columnWidths);
    _sorts = _normalizedSorts(tableState.sorts);
    _tablePaneFraction = tableState.paneFraction;
    _maxSessionsPerProject = tableState.maxSessionsPerProject;
    _setExcludedProjects(tableState.excludedProjects);
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
    _handledProjectFilterSerial = widget.projectFilterSerial;
    if (widget.projectFilterRequest case final project?) {
      _applyProjectFilter(project, notify: false);
    }
    if (widget.pricingRevision > 0) {
      _pricingInvalidated = true;
      _queuePersistedCostRefresh();
    }
  }

  @override
  void didUpdateWidget(covariant SessionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pricingRevision != widget.pricingRevision ||
        oldWidget.pricingUpdating != widget.pricingUpdating) {
      _pricingInvalidated = true;
      _queuePersistedCostRefresh();
    }
    // After this screen's own refresh, parent rows are stale snapshots until
    // a newer external (collector) revision arrives. External rows are loaded
    // asynchronously, so they can arrive in a later update than the revision.
    final acceptsParentRows =
        !_hasRefreshOwnedRows ||
        widget.externalRevision > _refreshOwnedExternalRevision;
    if (acceptsParentRows && oldWidget.initialRows != widget.initialRows) {
      final previouslySelectedId = _selectedId;
      final previousSelected = previouslySelectedId == null
          ? null
          : _rows.where((row) => row.id == previouslySelectedId).firstOrNull;
      _replaceRows(widget.initialRows, external: widget.externalRevision > 0);
      _retainSelection();
      _tryApplyPendingOpenTarget();
      final nextSelected = previouslySelectedId == null
          ? null
          : _rows.where((row) => row.id == previouslySelectedId).firstOrNull;
      if (widget.externalRevision > 0 &&
          previousSelected != null &&
          nextSelected != null &&
          _selectedId == previouslySelectedId &&
          _sessionContentChanged(previousSelected, nextSelected)) {
        unawaited(_loadSelectedDetail(_selectedId!, force: true));
      }
    }
    if (!_isScanning &&
        oldWidget.initialStatusMessage != widget.initialStatusMessage) {
      _scanAnnouncement = widget.initialStatusMessage;
    }
    if (widget.projectFilterSerial != _handledProjectFilterSerial) {
      _handledProjectFilterSerial = widget.projectFilterSerial;
      if (widget.projectFilterRequest case final project?) {
        _applyProjectFilter(project, notify: true);
      }
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
    if (_tableStateEmitTimer?.isActive ?? false) {
      _emitTableState();
    }
    _requestRefreshCancel(updateUi: false);
    _backgroundRescanTimer?.cancel();
    _filterDebounceTimer?.cancel();
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
    _searchFocusNode.dispose();
    _screenFocusNode.dispose();
    _filterAreaFocusNode.dispose();
    _filterScrollController.dispose();
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
    final selectedHierarchy = selectedRow == null
        ? null
        : _buildSessionHierarchy();
    final selectedSubagents = selectedRow == null
        ? const <SessionRowViewModel>[]
        : selectedHierarchy!.childrenByParentId[selectedRow.id] ??
              const <SessionRowViewModel>[];
    final selectedParent = selectedRow == null
        ? null
        : selectedHierarchy!.parentByChildId[selectedRow.id];
    final hasRowsHiddenByDefaultOrigin =
        visibleDisplayRows.isEmpty && _hasRowsHiddenOnlyByOrigin;
    return Material(
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyF, control: true): () {
            _searchFocusNode.requestFocus();
            _searchController.selection = TextSelection(
              baseOffset: 0,
              extentOffset: _searchController.text.length,
            );
          },
          const SingleActivator(LogicalKeyboardKey.f5): () {
            if (!_isScanning) {
              unawaited(_refresh(userInitiated: true));
            }
          },
          const SingleActivator(LogicalKeyboardKey.keyL, control: true): () {
            _filterAreaFocusNode
              ..requestFocus()
              ..nextFocus();
          },
          const SingleActivator(LogicalKeyboardKey.keyE, control: true): () =>
              unawaited(_exportSelectedSession()),
        },
        // Holds focus at startup so Ctrl+F and F5 work before anything else
        // is focused; Ctrl+C here copies the selected session's path.
        child: CopyShortcut(
          focusNode: _screenFocusNode,
          autofocus: true,
          onCopy: _copySelectedSessionPath,
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
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: constraints.maxHeight * 0.55,
                            ),
                            child: Scrollbar(
                              controller: _filterScrollController,
                              thumbVisibility: true,
                              child: SingleChildScrollView(
                                controller: _filterScrollController,
                                child: _FilterBar(
                                  searchController: _searchController,
                                  searchFocusNode: _searchFocusNode,
                                  filterAreaFocusNode: _filterAreaFocusNode,
                                  pathController: _pathController,
                                  threadNameController: _threadNameController,
                                  platformFilter: _platformFilter,

                                  timeFilter: _timeFilter,
                                  archivedFilter: _archivedFilter,
                                  originFilter: _originFilter,
                                  harnessFilter: _harnessFilter,
                                  onHarnessChanged: (value) => _updateFilter(
                                    () => _harnessFilter = value,
                                  ),
                                  maxSessionsPerProject: _maxSessionsPerProject,
                                  excludedProjects: _excludedProjects,
                                  namedOnly: _namedOnly,
                                  projectFilter: _projectFilter,
                                  modelFilter: _modelFilter,
                                  tagFilter: _tagFilter,
                                  projectOptions: _facets.projects,
                                  modelOptions: _facets.models,
                                  tagOptions: _facets.tags,
                                  visibleCount: visibleDisplayRows
                                      .where(
                                        (displayRow) => displayRow.depth == 0,
                                      )
                                      .length,
                                  totalCount: _originScopedRowCount,
                                  onProjectChanged: (value) => _updateFilter(
                                    () => _projectFilter = value,
                                  ),
                                  onModelChanged: (value) =>
                                      _updateFilter(() => _modelFilter = value),
                                  onTagChanged: (value) =>
                                      _updateFilter(() => _tagFilter = value),
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
                                  onMaxSessionsPerProjectChanged: (value) {
                                    setState(() {
                                      _maxSessionsPerProject = value;
                                      _retainSelection();
                                      _markVisibleRowsForMotion();
                                    });
                                    _emitTableState();
                                  },
                                  onExcludedProjectsChanged: (projects) {
                                    _updateFilter(
                                      () => _setExcludedProjects(projects),
                                    );
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
                                  onRefresh: () =>
                                      unawaited(_refresh(userInitiated: true)),
                                ),
                              ),
                            ),
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
                                    onTestWslPath:
                                        widget.onTestWslPath ?? _refresh,
                                  )
                                : _SessionsTable(
                                    rows: visibleDisplayRows,
                                    selectedId: _selectedId,
                                    onSelect: _selectFromList,
                                    onToggleSubagents: _toggleSubagents,
                                    onAction: _handleSessionAction,
                                    settings:
                                        widget.settings ??
                                        AppSettings.defaults(),
                                    columnWidths: _columnWidths,
                                    sorts: _sorts,
                                    onColumnWidthChanged: _setColumnWidth,
                                    onSortGesture: _handleSortGesture,
                                    onShowSortOptions: _showSortOptions,
                                    onListAction: _handleListAction,
                                    canSaveCsv:
                                        widget.onSaveSessionListCsv != null,
                                    statusMessage: _scanAnnouncement,
                                    isScanning: _isScanning,
                                    animatedRowIds: _rowMotionIds,
                                    rowMotionGeneration: _rowMotionGeneration,
                                    unreachablePaths: _unreachablePaths,
                                    onOpenSettings: widget.onOpenSettings,
                                    onTestWslPath:
                                        widget.onTestWslPath ?? _refresh,
                                    now: widget.now,
                                  ),
                          ),
                        ],
                      ),
                    ),
                    _SplitHandle(
                      onDrag: (delta) => setState(() {
                        final width = _clampTablePaneWidth(
                          tablePaneWidth + delta,
                          constraints.maxWidth,
                        );
                        _tablePaneFraction =
                            width / (constraints.maxWidth - _splitDividerWidth);
                      }),
                      onDragEnd: _emitTableState,
                      onNudgeEnd: _scheduleTableStateEmit,
                      tablePercent: constraints.maxWidth <= 0
                          ? 0
                          : (tablePaneWidth * 100 / constraints.maxWidth)
                                .round(),
                      onReset: () {
                        setState(() => _tablePaneFraction = null);
                        _emitTableState();
                      },
                    ),
                    Expanded(
                      child: _SessionDetailPlaceholder(
                        row: selectedRow,
                        subagents: selectedSubagents,
                        parentRow: selectedParent,
                        onOpenSession: _openSession,
                        detailTab: _detailTab,
                        onDetailTabChanged: (tab) => _detailTab = tab,
                        onLoadFullConversationMessages:
                            widget.onLoadAllMessages == null
                            ? null
                            : (row) => widget.onLoadAllMessages!(row.id),
                        visibleCount: visibleDisplayRows.length,
                        hasRows: _rows.isNotEmpty,
                        hasActiveFilters: _hasActiveFilters,
                        isScanning: _isScanning,
                        settings: widget.settings ?? AppSettings.defaults(),
                        onSessionAction: selectedRow == null
                            ? null
                            : (action) =>
                                  _handleDetailAction(selectedRow, action),
                        onCopyText: widget.onCopyText,
                        onExportMarkdown: widget.onExportMarkdown,
                        onRunTerminalCommand: selectedRow == null
                            ? null
                            : (command) =>
                                  _runTerminalCommand(selectedRow, command),
                        onEditTerminalCommand: selectedRow == null
                            ? null
                            : (command) =>
                                  _runTerminalCommand(selectedRow, command),
                        isLoadingMessages:
                            selectedRow != null &&
                            _loadingDetailId == selectedRow.id,
                        initialConversationMessageNumber: selectedRow == null
                            ? null
                            : _conversationPositions[selectedRow.id]
                                  ?.messageNumber,
                        onConversationPositionChanged: selectedRow == null
                            ? null
                            : (position) {
                                _conversationPositions[selectedRow.id] =
                                    position;
                              },
                        onLoadMessagePage:
                            selectedRow == null ||
                                widget.onLoadMessagePage == null
                            ? null
                            : (anchor) => widget.onLoadMessagePage!(
                                selectedRow.id,
                                anchor,
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  double _tablePaneWidth(double availableWidth) {
    final tableWidth = _SessionsTable.tableWidthFor(_columnWidths);
    if (!availableWidth.isFinite) {
      return tableWidth;
    }
    final fraction = _tablePaneFraction;
    if (fraction != null) {
      return _clampTablePaneWidth(
        fraction * (availableWidth - _splitDividerWidth),
        availableWidth,
      );
    }
    // By default the detail pane gets at least 45% of the width, so the
    // conversation and stats stay readable next to a wide table.
    final defaultMax = availableWidth * 0.55;
    if (tableWidth > defaultMax) {
      return _clampTablePaneWidth(defaultMax, availableWidth);
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

  double _clampTablePaneWidth(double width, double availableWidth) {
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
    return width.clamp(_minimumTablePaneWidth, maxLeftWidth).toDouble();
  }

  List<SessionRowViewModel> get _visibleRows => [
    for (final displayRow in _visibleDisplayRows) displayRow.row,
  ];

  List<_SessionDisplayRow> get _visibleDisplayRows {
    final inputs = <Object?>[
      _rows,
      _platformFilter,
      _harnessFilter,
      _archivedFilter,
      _originFilter,
      _timeFilter,
      if (_timeFilter != SessionsTimeFilter.allTime)
        widget.now().microsecondsSinceEpoch ~/ Duration.microsecondsPerMinute,
      _maxSessionsPerProject,
      _excludedProjects,
      _namedOnly,
      _projectFilter,
      _modelFilter,
      _tagFilter,
      _appliedSearch,
      _appliedPath,
      _appliedThreadName,
      _matchingSearchRowIds,
      _matchingPathRowIds,
      _matchingThreadNameRowIds,
      _sorts,
      _expansionRevision,
      widget.pricingUpdating,
      _pricingCostsPending,
    ];
    final cached = _displayRowsCache;
    if (cached != null && _sameInputs(_displayRowsInputs, inputs)) {
      return cached;
    }
    final rows = _computeVisibleDisplayRows();
    _displayRowsInputs = inputs;
    _displayRowsCache = rows;
    return rows;
  }

  static bool _sameInputs(List<Object?>? previous, List<Object?> next) {
    if (previous == null || previous.length != next.length) {
      return false;
    }
    for (var i = 0; i < next.length; i++) {
      final a = previous[i];
      final b = next[i];
      if (identical(a, b)) {
        continue;
      }
      // Collections are compared by identity: they are replaced, never
      // mutated, when their content changes.
      if (a is Iterable || b is Iterable || a is Map || b is Map || a != b) {
        return false;
      }
    }
    return true;
  }

  List<_SessionDisplayRow> _computeVisibleDisplayRows() {
    final search = _appliedSearch;
    final path = _appliedPath;
    final threadName = _appliedThreadName;
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
        final rows = _maxSessionsPerProject != null
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
      if (_isProjectExcluded(parent)) continue;
      final childRows = childrenByParentId[parent.id];
      final children = childRows == null
          ? const <SessionRowViewModel>[]
          : _sortedRows(childRows);
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
        applyNewestPerProject && _maxSessionsPerProject != null
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
      // Most sessions have no subagents; avoid copying every row.
      return parent.usageRollup == null
          ? parent
          : parent.copyWithUsageRollup(null);
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
    final subagentCostUpdating = children.any((child) => child.costUpdating);
    final subagentCostPartial = children.any(
      (child) => child.costPartialUnsupportedUnits,
    );
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
        mainCostUpdating: parent.costUpdating,
        subagentCostUpdating: subagentCostUpdating,
        totalCostUpdating: parent.costUpdating || subagentCostUpdating,
        mainCostPartialUnsupportedUnits: parent.costPartialUnsupportedUnits,
        subagentCostPartialUnsupportedUnits: subagentCostPartial,
        totalCostPartialUnsupportedUnits:
            parent.costPartialUnsupportedUnits || subagentCostPartial,
      ),
    );
  }

  String? _knownCostText(SessionRowViewModel row) {
    if (row.costUnknown || row.costUpdating) {
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
    final reducedGroups = _maxSessionsPerProject != null
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
    return _latestRowsPerProject(groups, (group) => group.first.row)..sort(
      (left, right) =>
          _compareRowsByActiveSorts(left.first.row, right.first.row),
    );
  }

  _SessionHierarchy _buildSessionHierarchy() {
    final inputs = <Object?>[
      _rows,
      widget.pricingUpdating,
      _pricingCostsPending,
    ];
    final cached = _hierarchyCache;
    if (cached != null && _sameInputs(_hierarchyInputs, inputs)) {
      return cached;
    }
    final hierarchy = _computeSessionHierarchy();
    _hierarchyInputs = inputs;
    _hierarchyCache = hierarchy;
    return hierarchy;
  }

  _SessionHierarchy _computeSessionHierarchy() {
    final parentByKey = <String, SessionRowViewModel>{};
    final parents = <SessionRowViewModel>[];
    final subagents = <SessionRowViewModel>[];
    for (final sourceRow in _rows) {
      final row = _pricingOverlay(sourceRow);
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
      final parent =
          parentByKey[child.harnessSessionKey(child.parentThreadId)] ??
          parentByKey[child.parentThreadId.trim()];
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
    final sessionId = row.harnessSessionKey(row.sessionId);
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
        (!_namedOnly || row.hasThreadName) &&
        _matchesFacets(row);
  }

  bool _matchesFacets(SessionRowViewModel row) {
    if (_isProjectExcluded(row)) return false;
    final parent = _buildSessionHierarchy().parentByChildId[row.id];
    if (parent != null && _isProjectExcluded(parent)) return false;
    if (_harnessFilter != null && row.harness != _harnessFilter) return false;
    final project = _projectFilter;
    if (project != null && row.project.trim() != project) {
      return false;
    }
    final model = _modelFilter;
    if (model != null && row.modelLabel != model) {
      return false;
    }
    final tag = _tagFilter;
    if (tag != null && !row.tags.contains(tag)) {
      return false;
    }
    return true;
  }

  ({List<String> projects, List<String> models, List<String> tags})
  get _facets {
    if (!identical(_facetRows, _rows)) {
      _facetRows = _rows;
      _projectOptionsCache = _facetOptions((row) => [row.project]);
      _modelOptionsCache = _facetOptions((row) => [row.modelLabel]);
      _tagOptionsCache = _facetOptions((row) => row.tags);
    }
    return (
      projects: _projectOptionsCache,
      models: _modelOptionsCache,
      tags: _tagOptionsCache,
    );
  }

  /// Distinct values for a facet filter, most frequent first.
  List<String> _facetOptions(
    Iterable<String> Function(SessionRowViewModel) of,
  ) {
    final counts = <String, int>{};
    for (final row in _rows) {
      if (row.isSubagentSession) {
        continue;
      }
      for (final value in of(row)) {
        final trimmed = value.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        counts[trimmed] = (counts[trimmed] ?? 0) + 1;
      }
    }
    final values = counts.keys.toList()
      ..sort((a, b) {
        final byCount = counts[b]!.compareTo(counts[a]!);
        return byCount != 0
            ? byCount
            : a.toLowerCase().compareTo(b.toLowerCase());
      });
    return values;
  }

  List<SessionRowViewModel> _newestRowsPerProject(
    List<SessionRowViewModel> rows,
  ) {
    return _latestRowsPerProject(rows, (row) => row);
  }

  List<T> _latestRowsPerProject<T>(
    List<T> items,
    SessionRowViewModel Function(T) rowOf,
  ) {
    final limit = _maxSessionsPerProject;
    if (limit == null) return items;
    final byProject = <String, List<T>>{};
    for (final item in items) {
      (byProject[_projectGroupKey(rowOf(item))] ??= []).add(item);
    }
    return [
      for (final group in byProject.values)
        ...((group..sort((left, right) {
              final a = rowOf(left);
              final b = rowOf(right);
              final byActivity = b.lastMessageAtUtc.compareTo(
                a.lastMessageAtUtc,
              );
              return byActivity != 0 ? byActivity : a.id.compareTo(b.id);
            }))
            .take(limit)),
    ];
  }

  void _setExcludedProjects(Iterable<String> projects) {
    final names = <String, String>{};
    for (final project in projects) {
      final name = project.trim();
      if (name.isNotEmpty) names.putIfAbsent(name.toLowerCase(), () => name);
    }
    _excludedProjects = Set.unmodifiable(names.values);
    _excludedProjectKeys = Set.unmodifiable(names.keys);
  }

  bool _isProjectExcluded(SessionRowViewModel row) =>
      _excludedProjectKeys.contains(row.project.trim().toLowerCase());

  String _projectGroupKey(SessionRowViewModel row) {
    final project = row.project.trim().toLowerCase();
    if (project.isNotEmpty) {
      return 'project:$project';
    }
    return 'session:${row.id}';
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
    final window = _timeWindow();
    final value = row.lastMessageAtUtc.microsecondsSinceEpoch;
    return value >= window.start && (window.end == null || value < window.end!);
  }

  /// The active time filter as epoch-microsecond bounds.
  ///
  /// Converting each row to local time costs a time zone lookup per call,
  /// which made filtering thousands of rows block the UI for hundreds of
  /// milliseconds on every scan progress update. The local calendar bounds
  /// are computed once per filter and minute instead.
  ({int start, int? end}) _timeWindow() {
    final now = widget.now();
    final minute = now.microsecondsSinceEpoch ~/ Duration.microsecondsPerMinute;
    final cached = _timeWindowCache;
    if (cached != null &&
        _timeWindowCacheFilter == _timeFilter &&
        _timeWindowCacheMinute == minute) {
      return cached;
    }
    final localNow = now.toLocal();
    final today = DateTime(localNow.year, localNow.month, localNow.day);
    int micros(DateTime value) => value.microsecondsSinceEpoch;
    final window = switch (_timeFilter) {
      SessionsTimeFilter.today => (
        start: micros(today),
        end: micros(today.add(const Duration(days: 1))),
      ),
      SessionsTimeFilter.yesterday => (
        start: micros(today.subtract(const Duration(days: 1))),
        end: micros(today),
      ),
      SessionsTimeFilter.thisWeek => (
        start: micros(_startOfWeek(today)),
        end: micros(_startOfWeek(today).add(const Duration(days: 7))),
      ),
      SessionsTimeFilter.lastWeek => (
        start: micros(_startOfWeek(today).subtract(const Duration(days: 7))),
        end: micros(_startOfWeek(today)),
      ),
      SessionsTimeFilter.thisMonth => (
        start: micros(DateTime(today.year, today.month)),
        end: micros(DateTime(today.year, today.month + 1)),
      ),
      SessionsTimeFilter.lastMonth => (
        start: micros(DateTime(today.year, today.month - 1)),
        end: micros(DateTime(today.year, today.month)),
      ),
      SessionsTimeFilter.last30Days => (
        start: micros(localNow.subtract(const Duration(days: 30))),
        end: null,
      ),
      SessionsTimeFilter.allTime => (start: 0, end: null),
    };
    _timeWindowCache = window;
    _timeWindowCacheFilter = _timeFilter;
    _timeWindowCacheMinute = minute;
    return window;
  }

  DateTime _startOfWeek(DateTime value) {
    return value.subtract(Duration(days: value.weekday - DateTime.monday));
  }

  bool _matchesPath(SessionRowViewModel row, String path) {
    if (path.isEmpty) {
      return true;
    }
    return _matchingPathRowIds?.contains(row.id) ?? false;
  }

  bool _matchesThreadName(SessionRowViewModel row, String threadName) {
    if (threadName.isEmpty) {
      return true;
    }
    return _matchingThreadNameRowIds?.contains(row.id) ?? false;
  }

  bool _matchesSearch(SessionRowViewModel row, String search) {
    if (search.isEmpty) {
      return true;
    }
    return _matchingSearchRowIds?.contains(row.id) ?? false;
  }

  bool get _hasActiveFilters {
    return _searchController.text.trim().isNotEmpty ||
        _pathController.text.trim().isNotEmpty ||
        _threadNameController.text.trim().isNotEmpty ||
        _platformFilter != SessionsPlatformFilter.both ||
        _harnessFilter != null ||
        _timeFilter != _defaultTimeFilter ||
        _archivedFilter != SessionsArchivedFilter.activeOnly ||
        _originFilter != _defaultOriginFilter ||
        _maxSessionsPerProject != null ||
        _excludedProjects.isNotEmpty ||
        _namedOnly ||
        _projectFilter != null ||
        _modelFilter != null ||
        _tagFilter != null;
  }

  bool get _hasRowsHiddenOnlyByOrigin {
    if (_originFilter != _defaultOriginFilter || _rows.isEmpty) {
      return false;
    }
    final search = _appliedSearch;
    final path = _appliedPath;
    final threadName = _appliedThreadName;
    return _rows.any(
      (row) =>
          row.isSubagentSession &&
          _matchesArchived(row) &&
          _matchesPlatform(row) &&
          _matchesTime(row) &&
          _matchesPath(row, path) &&
          _matchesThreadName(row, threadName) &&
          (!_namedOnly || row.hasThreadName) &&
          _matchesFacets(row) &&
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

  /// Selects a session from a click: focus returns to the screen, so Ctrl+C
  /// copies this session's path.
  void _selectFromList(String id) {
    _screenFocusNode.requestFocus();
    _select(id);
  }

  /// Ctrl+C with nothing more specific focused.
  bool _copySelectedSessionPath() {
    if (focusedTextOwnsCopy()) {
      return false;
    }
    final row = _selectedRow(_visibleRows);
    if (row == null || row.path.isEmpty) {
      return false;
    }
    unawaited(
      _handleSessionAction(
        SessionActionRequest(
          row: row,
          action: SessionRowAction.copyPath,
          payload: row.path,
        ),
      ).then((_) {
        if (!mounted || widget.onSessionAction == null) {
          return;
        }
        ScaffoldMessenger.maybeOf(context)
          ?..removeCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('Copied session path.')));
      }),
    );
    return true;
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
        _applyClearedTextFilters();
        _platformFilter = SessionsPlatformFilter.both;
        _harnessFilter = null;
        _timeFilter = SessionsTimeFilter.allTime;
        _archivedFilter = SessionsArchivedFilter.all;
        _originFilter = SessionsOriginFilter.all;
        _maxSessionsPerProject = null;
        _setExcludedProjects(const []);
        _namedOnly = false;
        _projectFilter = null;
        _modelFilter = null;
        _tagFilter = null;
        _markVisibleRowsForMotion({id});
      });
    } finally {
      _searchController.addListener(_filtersChanged);
      _pathController.addListener(_filtersChanged);
      _threadNameController.addListener(_filtersChanged);
    }
  }

  /// Selects a session from a link inside the detail pane, expanding its
  /// parent group or relaxing filters so the row is visible in the table.
  void _openSession(String id) {
    final hierarchy = _buildSessionHierarchy();
    final parent = hierarchy.parentByChildId[id];
    if (parent != null) {
      setState(() {
        _expandedParentIds.add(parent.id);
        _expansionRevision++;
      });
    }
    _revealOpenTarget(id);
    _select(id);
  }

  void _toggleSubagents(String parentId) {
    setState(() {
      if (!_expandedParentIds.add(parentId)) {
        _expandedParentIds.remove(parentId);
      }
      _expansionRevision++;
    });
  }

  Future<void> _loadSelectedDetail(String id, {bool force = false}) async {
    final loader = widget.onLoadSessionDetail;
    if (loader == null) return;
    if (_loadingDetailId == id) {
      if (force) _pendingExternalDetailId = id;
      return;
    }
    final row = _rowById(id);
    if (row == null ||
        row.messageCount == 0 ||
        (!force && row.conversationMessages.isNotEmpty)) {
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
        if (_pendingExternalDetailId == id && _selectedId == id) {
          _pendingExternalDetailId = null;
          unawaited(_loadSelectedDetail(id, force: true));
        }
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
    // Source-file reparsing is the Codex parser path. Other harnesses refresh
    // through collector commits and the external-ingestion snapshot watcher.
    if (row?.harness != 'codex' ||
        path.isEmpty ||
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
    _scheduleTextFilter();
  }

  void _scheduleTextFilter({Duration? delay}) {
    _filterDebounceTimer?.cancel();
    _filterDebounceTimer = Timer(
      delay ?? _filterDebounceDuration,
      _applyTextFiltersInBackground,
    );
  }

  Future<void> _applyTextFiltersInBackground() async {
    final search = _normalizeSearchText(_searchController.text);
    final path = _normalizePathText(_pathController.text);
    final threadName = _normalizeSearchText(_threadNameController.text);
    if (search == _appliedSearch &&
        path == _appliedPath &&
        threadName == _appliedThreadName) {
      return;
    }

    final generation = ++_textFilterGeneration;
    final request = _SessionTextFilterRequest(
      search: search,
      path: path,
      threadName: threadName,
      rows: [for (final row in _rows) _SessionTextFilterRowData.from(row)],
    );
    final result = request.rows.length <= _synchronousTextFilterRowLimit
        ? _matchSessionTextFilters(request)
        : await _runSessionTextFilterOnWorker(request);
    if (!mounted || generation != _textFilterGeneration) {
      return;
    }
    setState(() {
      _appliedSearch = search;
      _appliedPath = path;
      _appliedThreadName = threadName;
      _matchingSearchRowIds = search.isEmpty ? null : result.searchIds;
      _matchingPathRowIds = path.isEmpty ? null : result.pathIds;
      _matchingThreadNameRowIds = threadName.isEmpty
          ? null
          : result.threadNameIds;
      _retainSelection();
      _markVisibleRowsForMotion();
    });
  }

  void _applyClearedTextFilters() {
    _filterDebounceTimer?.cancel();
    _textFilterGeneration++;
    _appliedSearch = '';
    _appliedPath = '';
    _appliedThreadName = '';
    _matchingSearchRowIds = null;
    _matchingPathRowIds = null;
    _matchingThreadNameRowIds = null;
  }

  String _normalizeSearchText(String value) => value.trim().toLowerCase();

  String _normalizePathText(String value) =>
      value.trim().replaceAll(r'\', '/').toLowerCase();

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
        _applyClearedTextFilters();
        _platformFilter = SessionsPlatformFilter.both;
        _harnessFilter = null;
        _timeFilter = _defaultTimeFilter;
        _archivedFilter = SessionsArchivedFilter.activeOnly;
        _originFilter = _defaultOriginFilter;
        _maxSessionsPerProject = null;
        _setExcludedProjects(const []);
        _namedOnly = false;
        _projectFilter = null;
        _modelFilter = null;
        _tagFilter = null;
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

  /// Rows the current Show mode can display at the top level, before any
  /// other filter. Grouped subagents are not counted as separate sessions.
  int get _originScopedRowCount {
    return switch (_originFilter) {
      SessionsOriginFilter.user =>
        _rows.where((row) => !row.isSubagentSession).length,
      SessionsOriginFilter.subagent =>
        _rows.where((row) => row.isSubagentSession).length,
      SessionsOriginFilter.all => _rows.length,
    };
  }

  /// Replaces the filters with "this project only", so a project opened
  /// from the Projects screen shows all of its sessions.
  void _applyProjectFilter(String project, {required bool notify}) {
    void apply() {
      _searchController.clear();
      _pathController.clear();
      _threadNameController.clear();
      _applyClearedTextFilters();
      _platformFilter = SessionsPlatformFilter.both;
      _harnessFilter = null;
      _timeFilter = SessionsTimeFilter.allTime;
      _archivedFilter = SessionsArchivedFilter.all;
      _originFilter = SessionsOriginFilter.all;
      _maxSessionsPerProject = null;
      _setExcludedProjects(const []);
      _namedOnly = false;
      _projectFilter = project;
      _modelFilter = null;
      _tagFilter = null;
    }

    if (!notify) {
      apply();
      return;
    }
    _searchController.removeListener(_filtersChanged);
    _pathController.removeListener(_filtersChanged);
    _threadNameController.removeListener(_filtersChanged);
    try {
      setState(() {
        apply();
        _retainSelection();
        _markVisibleRowsForMotion();
      });
    } finally {
      _searchController.addListener(_filtersChanged);
      _pathController.addListener(_filtersChanged);
      _threadNameController.addListener(_filtersChanged);
    }
  }

  void _updateFilter(VoidCallback change) {
    setState(() {
      change();
      _retainSelection();
      _markVisibleRowsForMotion();
    });
  }

  void _showAllOrigins() {
    setState(() {
      _originFilter = SessionsOriginFilter.all;
      _retainSelection();
      _markVisibleRowsForMotion();
    });
  }

  /// Starts a scan; [userInitiated] scans (Refresh button, F5) also play
  /// voice-over events, background rescans stay quiet.
  Future<void> _refresh({bool userInitiated = false}) async {
    if (_isScanning) {
      _requestRefreshCancel();
      return;
    }
    if (userInitiated) {
      widget.onVoiceEvent?.call(VoiceOverStaticEvent.scanStarted);
    }
    setState(() {
      _isScanning = true;
      _isCancellingRefresh = false;
      _takeRowOwnership();
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
        _takeRowOwnership();
        _replaceRows(refreshResult.rows);
        _scanAnnouncement = refreshResult.statusMessage;
        _retainSelection();
      });
      _tryApplyPendingOpenTarget();
      if (userInitiated) {
        widget.onVoiceEvent?.call(
          refreshResult.statusMessage.contains('could not be parsed')
              ? VoiceOverStaticEvent.parseError
              : VoiceOverStaticEvent.scanFinished,
        );
      }
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
        _takeRowOwnership();
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

  /// Exports the selected session as Markdown (Ctrl+E).
  Future<void> _exportSelectedSession() async {
    final row = _selectedRow(_visibleRows);
    final export = widget.onExportMarkdown;
    if (row == null || export == null) {
      ScaffoldMessenger.maybeOf(context)
        ?..removeCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Select a session to export.')),
        );
      return;
    }
    final markdown = await runWithDelayedExportProgress(
      context,
      label: 'Preparing Markdown',
      operation: () async {
        final loadAll = widget.onLoadAllMessages;
        final messages =
            loadAll != null &&
                row.conversationMessages.any((message) => !message.isBodyLoaded)
            ? await loadAll(row.id)
            : row.conversationMessages;
        return sessionConversationMarkdown(row, messages);
      },
    );
    await export(row, markdown);
  }

  /// Runs a terminal command shown in the detail pane, possibly edited by
  /// the user. It is split into a program and arguments and started without
  /// a shell, like the generated resume commands.
  Future<void> _runTerminalCommand(SessionRowViewModel row, String command) {
    return _handleSessionAction(
      SessionActionRequest(
        row: row,
        action: SessionRowAction.openTerminalResume,
        payload: command,
        launchSpec: parseWindowsCommandLine(command),
      ),
    );
  }

  Future<void> _handleSessionAction(SessionActionRequest request) async {
    if (request.action == SessionRowAction.reparse &&
        widget.onReloadSessionDetailFromSource != null) {
      await _reparseSession(request.row);
      return;
    }
    final callback = widget.onSessionAction;
    if (callback != null) {
      await callback(request);
      if (!mounted) {
        return;
      }
      if (request.action == SessionRowAction.updateEvalMetadata &&
          request.evalMetadata != null) {
        _replaceEvalMetadata(request.row, request.evalMetadata!);
      }
      if (request.action == SessionRowAction.togglePin ||
          request.action == SessionRowAction.toggleArchive) {
        _applyFlagChange(request);
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

  Future<void> _handleListAction(_SessionListAction action) async {
    final rows = _visibleRows;
    if (rows.isEmpty) {
      return;
    }
    final exporter = SessionListExporter(
      settings: widget.settings ?? AppSettings.defaults(),
    );
    switch (action) {
      case _SessionListAction.copyMarkdown:
        await runWithDelayedExportProgress(
          context,
          label: 'Copying Markdown',
          operation: () async {
            final markdown = await formatSessionListMarkdown(
              exporter.settings,
              rows,
            );
            final copy = widget.onCopyText;
            if (copy == null) {
              await Clipboard.setData(ClipboardData(text: markdown));
            } else {
              await copy(markdown);
            }
          },
        );
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Copied ${rows.length} visible '
                '${rows.length == 1 ? 'session' : 'sessions'} as Markdown.',
              ),
            ),
          );
        }
        return;
      case _SessionListAction.copyExtendedMarkdown:
        final options = await _showExtendedMarkdownOptions();
        if (options == null || !mounted) {
          return;
        }
        try {
          await runWithDelayedExportProgress(
            context,
            label: 'Copying extended Markdown',
            operation: () async {
              final exportRows = await _loadExtendedMarkdownRows(rows, options);
              final markdown = await formatSessionListMarkdown(
                exporter.settings,
                exportRows,
                includeFirstMessage: options.includeFirstMessage,
                includeLastMessage: options.includeLastMessage,
              );
              final copy = widget.onCopyText;
              if (copy == null) {
                await Clipboard.setData(ClipboardData(text: markdown));
              } else {
                await copy(markdown);
              }
            },
          );
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Copied ${rows.length} visible '
                  '${rows.length == 1 ? 'session' : 'sessions'} '
                  'as extended Markdown.',
                ),
              ),
            );
          }
        } on Object catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Could not copy extended Markdown. $error'),
              ),
            );
          }
        }
        return;
      case _SessionListAction.saveCsv:
        final save = widget.onSaveSessionListCsv;
        if (save != null) {
          await save(exporter.exportCsv(rows));
        }
        return;
    }
  }

  Future<_SessionListMarkdownOptions?> _showExtendedMarkdownOptions() async {
    var includeFirstMessage = true;
    var includeLastMessage = true;
    return showDialog<_SessionListMarkdownOptions>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Copy extended Markdown'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Choose which message content to include for each visible '
                'session.',
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Include first message'),
                value: includeFirstMessage,
                onChanged: (value) {
                  setDialogState(() {
                    includeFirstMessage = value ?? false;
                  });
                },
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Include last message'),
                value: includeLastMessage,
                onChanged: (value) {
                  setDialogState(() {
                    includeLastMessage = value ?? false;
                  });
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                _SessionListMarkdownOptions(
                  includeFirstMessage: includeFirstMessage,
                  includeLastMessage: includeLastMessage,
                ),
              ),
              child: const Text('Copy'),
            ),
          ],
        ),
      ),
    );
  }

  Future<List<SessionRowViewModel>> _loadExtendedMarkdownRows(
    List<SessionRowViewModel> rows,
    _SessionListMarkdownOptions options,
  ) async {
    if (!options.includeFirstMessage && !options.includeLastMessage) {
      return rows;
    }
    final endpointLoader = widget.onLoadSessionListExportMessages;
    if (endpointLoader == null) return rows;
    final endpoints = await endpointLoader(
      [for (final row in rows) row.id],
      includeFirstMessage: options.includeFirstMessage,
      includeLastMessage: options.includeLastMessage,
    );
    return [
      for (final row in rows)
        row.copyWithConversationMessages(endpoints[row.id] ?? const []),
    ];
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
            harness: row.harness,
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
        launchSpec: commandSet.terminalLaunchSpec,
      ),
      SessionDetailAction.openTerminalFork => SessionActionRequest(
        row: row,
        action: SessionRowAction.openTerminalFork,
        payload: commandSet.terminalForkCommand,
        launchSpec: commandSet.terminalForkLaunchSpec,
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
      SessionDetailAction.moveToProject => SessionActionRequest(
        row: row,
        action: SessionRowAction.moveToProject,
      ),
      SessionDetailAction.openInProjects => SessionActionRequest(
        row: row,
        action: SessionRowAction.openInProjects,
      ),
      SessionDetailAction.exportMarkdown ||
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
                reviewedAtUtc: widget.now().toUtc(),
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
    // Drags and arrow keys resize many times a second; save once they settle.
    _scheduleTableStateEmit();
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

  /// Saves the table layout after a burst of resize steps settles, so arrow
  /// keys and drags do not write settings on every step.
  void _scheduleTableStateEmit() {
    _tableStateEmitTimer?.cancel();
    _tableStateEmitTimer = Timer(_tableStateEmitDebounce, _emitTableState);
  }

  void _emitTableState() {
    _tableStateEmitTimer?.cancel();
    _tableStateEmitTimer = null;
    widget.onTableStateChanged?.call(
      SessionTableSettings(
        columnWidths: Map.unmodifiable(_columnWidths),
        sorts: List.unmodifiable(_sorts),
        maxSessionsPerProject: _maxSessionsPerProject,
        excludedProjects: List.unmodifiable(_excludedProjects),
        paneFraction: _tablePaneFraction,
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

  SessionRowViewModel _pricingOverlay(SessionRowViewModel row) =>
      widget.pricingUpdating || _pricingCostsPending
      ? row.copyWithProjectedCost(
          const UsageCostEstimate(
            estimatedCostText: null,
            costUnknown: true,
            updating: true,
          ),
        )
      : row;

  void _queuePersistedCostRefresh() {
    final generation = ++_pricingLoadGeneration;
    if (widget.pricingUpdating) {
      _pricingCostsPending = false;
      return;
    }
    final loader = widget.onLoadPersistedCosts;
    if (loader == null) {
      if (_pricingInvalidated) {
        _rows = [
          for (final row in _rows)
            row.copyWithProjectedCost(
              const UsageCostEstimate(
                estimatedCostText: null,
                costUnknown: true,
              ),
            ),
        ];
      }
      _pricingCostsPending = false;
      return;
    }
    _pricingCostsPending = true;
    scheduleMicrotask(() async {
      if (!mounted || generation != _pricingLoadGeneration) return;
      Map<String, UsageCostEstimate>? costs;
      try {
        costs = await loader([for (final row in _rows) row.id]);
      } on Object {
        // A failed cost lookup must not restore previously invalidated amounts.
      }
      if (!mounted ||
          generation != _pricingLoadGeneration ||
          widget.pricingUpdating) {
        return;
      }
      setState(() {
        if (costs != null || _pricingInvalidated) {
          const unknown = UsageCostEstimate(
            estimatedCostText: null,
            costUnknown: true,
          );
          _rows = [
            for (final row in _rows)
              row.copyWithProjectedCost(costs?[row.id] ?? unknown),
          ];
        }
        _pricingCostsPending = false;
      });
    });
  }

  SessionRowViewModel? _rowById(String id) {
    for (final row in _rows) {
      if (row.id == id) {
        return _pricingOverlay(row);
      }
    }
    return null;
  }

  /// Parses the session file again and replaces the row and its messages.
  Future<void> _reparseSession(SessionRowViewModel row) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      const SnackBar(content: Text('Re-parsing session...')),
    );
    SessionRowViewModel? reloaded;
    try {
      reloaded = await widget.onReloadSessionDetailFromSource!(row.id);
    } on Object catch (error) {
      messenger
        ?..removeCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Re-parse failed. $error')));
      return;
    }
    if (!mounted) {
      return;
    }
    if (reloaded == null) {
      messenger
        ?..removeCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text(
              'Re-parse failed: the session file is missing or unreadable.',
            ),
          ),
        );
      return;
    }
    setState(() {
      _replaceRow(reloaded!);
      _retainSelection();
    });
    messenger
      ?..removeCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Session re-parsed.')));
  }

  /// Shows a pin or archive change right away instead of after the next
  /// rescan, and says so when the current filter hides the session.
  void _applyFlagChange(SessionActionRequest request) {
    final current = _rowById(request.row.id) ?? request.row;
    final pinning = request.action == SessionRowAction.togglePin;
    final updated = pinning
        ? current.copyWithFlags(isPinned: !request.row.isPinned)
        : current.copyWithFlags(isArchived: !request.row.isArchived);
    setState(() {
      _replaceRow(updated);
      _retainSelection();
    });
    final hidden = !_visibleRows.any((row) => row.id == updated.id);
    final message = pinning
        ? (updated.isPinned ? 'Session pinned.' : 'Session unpinned.')
        : updated.isArchived
        ? (hidden
              ? 'Session archived and hidden by the current filter.'
              : 'Session archived.')
        : (hidden
              ? 'Session unarchived and hidden by the current filter.'
              : 'Session unarchived.');
    ScaffoldMessenger.maybeOf(context)
      ?..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _replaceRow(SessionRowViewModel replacement) {
    final index = _rows.indexWhere((row) => row.id == replacement.id);
    if (index < 0) {
      return;
    }
    _rows = [..._rows]..[index] = replacement;
    if (widget.onLoadPersistedCosts != null &&
        (_pricingInvalidated || _pricingCostsPending)) {
      _queuePersistedCostRefresh();
    }
  }

  void _replaceRows(List<SessionRowViewModel> rows, {bool external = false}) {
    final previousById = {for (final row in _rows) row.id: row};
    final loadedMessagesById = {
      for (final row in _rows)
        if (row.conversationMessages.isNotEmpty)
          row.id: row.conversationMessages,
    };
    final nextRows = _dedupeSessionSnapshots([
      for (final row in rows)
        if (row.conversationMessages.isEmpty &&
            row.messageCount > 0 &&
            (!external || row.id == _selectedId) &&
            loadedMessagesById.containsKey(row.id))
          row.copyWithConversationMessages(loadedMessagesById[row.id]!)
        else
          row,
    ]);
    final changedIds = {
      for (final row in nextRows)
        if (_rowChangedForMotion(previousById[row.id], row)) row.id,
    };
    _rows = nextRows;
    if (_pricingCostsPending) _queuePersistedCostRefresh();
    _textFilterGeneration++;
    if (_appliedSearch.isNotEmpty ||
        _appliedPath.isNotEmpty ||
        _appliedThreadName.isNotEmpty ||
        _searchController.text.trim().isNotEmpty ||
        _pathController.text.trim().isNotEmpty ||
        _threadNameController.text.trim().isNotEmpty) {
      _appliedSearch = '';
      _appliedPath = '';
      _appliedThreadName = '';
      _matchingSearchRowIds = null;
      _matchingPathRowIds = null;
      _matchingThreadNameRowIds = null;
      _scheduleTextFilter(delay: Duration.zero);
    }
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

  List<SessionRowViewModel> _dedupeSessionSnapshots(
    List<SessionRowViewModel> rows,
  ) {
    final result = <SessionRowViewModel>[];
    final indexBySessionId = <String, int>{};
    for (final row in rows) {
      final sessionId = row.harnessSessionKey(row.sessionId);
      if (sessionId.isEmpty) {
        result.add(row);
        continue;
      }
      final existingIndex = indexBySessionId[sessionId];
      if (existingIndex == null) {
        indexBySessionId[sessionId] = result.length;
        result.add(row);
      } else if (_isNewerSnapshot(row, result[existingIndex])) {
        result[existingIndex] = row;
      }
    }
    return result;
  }

  bool _isNewerSnapshot(
    SessionRowViewModel candidate,
    SessionRowViewModel current,
  ) {
    final timestampOrder = candidate.lastMessageAtUtc.compareTo(
      current.lastMessageAtUtc,
    );
    if (timestampOrder != 0) {
      return timestampOrder > 0;
    }
    final messageOrder = candidate.messageCount.compareTo(current.messageCount);
    if (messageOrder != 0) {
      return messageOrder > 0;
    }
    return candidate.id.compareTo(current.id) > 0;
  }

  void _takeRowOwnership() {
    _hasRefreshOwnedRows = true;
    _refreshOwnedExternalRevision = widget.externalRevision;
  }

  /// Whether a new snapshot of the same session changes what its detail pane
  /// shows. Collector commits replace every row object, so identity is not a
  /// revision.
  bool _sessionContentChanged(
    SessionRowViewModel previous,
    SessionRowViewModel next,
  ) {
    return previous.lastMessageAtUtc != next.lastMessageAtUtc ||
        previous.messageCount != next.messageCount ||
        previous.totalTokens != next.totalTokens ||
        previous.userMessageCount != next.userMessageCount ||
        previous.assistantMessageCount != next.assistantMessageCount ||
        previous.toolCallCount != next.toolCallCount ||
        previous.sourceFilePath != next.sourceFilePath ||
        previous.sourceState != next.sourceState ||
        previous.hasError != next.hasError ||
        previous.status != next.status;
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
        previous.sourceState != next.sourceState ||
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
    this.journalRevision,
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

  /// The session change journal revision the rows were read at, so later
  /// external changes load as a delta instead of a second full snapshot.
  final int? journalRevision;
}

class _SessionTextFilterRequest {
  const _SessionTextFilterRequest({
    required this.search,
    required this.path,
    required this.threadName,
    required this.rows,
  });

  final String search;
  final String path;
  final String threadName;
  final List<_SessionTextFilterRowData> rows;
}

class _SessionTextFilterRowData {
  const _SessionTextFilterRowData({
    required this.id,
    required this.idKey,
    required this.idNamespaceLength,
    required this.path,
    required this.threadName,
    required this.searchFields,
  });

  factory _SessionTextFilterRowData.from(SessionRowViewModel row) {
    final idKey = row.id.toLowerCase();
    return _SessionTextFilterRowData(
      id: row.id,
      idKey: idKey,
      idNamespaceLength: _internalIdNamespace.matchAsPrefix(idKey)?.end ?? 0,
      path: row.path.replaceAll(r'\', '/').toLowerCase(),
      threadName: row.threadName.toLowerCase(),
      searchFields: [
        row.sessionId,
        row.title,
        row.summary,
        row.project,
        row.threadName,
        row.path,
        row.platformLabel,
        row.originLabel,
        row.modelProviderLabel,
        row.status,
        ...row.tags,
      ].map((value) => value.toLowerCase()).toList(growable: false),
    );
  }

  final String id;

  /// Lower-case internal ID such as `session:<id>` or `claude:session:<id>`.
  final String idKey;

  /// Length of the `session:` / `claude:session:` namespace in [idKey].
  final int idNamespaceLength;
  final String path;
  final String threadName;
  final List<String> searchFields;

  /// Internal IDs match by prefix, and only once the query reaches past the
  /// namespace, so words such as "session" or "claude" do not match every
  /// row. The ID without its namespace also matches by prefix.
  bool matchesInternalId(String search) =>
      (search.length > idNamespaceLength && idKey.startsWith(search)) ||
      (idNamespaceLength > 0 && idKey.startsWith(search, idNamespaceLength));
}

/// The namespace that prefixes internal session IDs.
final _internalIdNamespace = RegExp(r'(?:[a-z0-9_-]+:)?session:');

class _SessionTextFilterResult {
  const _SessionTextFilterResult({
    required this.searchIds,
    required this.pathIds,
    required this.threadNameIds,
  });

  final Set<String> searchIds;
  final Set<String> pathIds;
  final Set<String> threadNameIds;
}

_SessionTextFilterResult _matchSessionTextFilters(
  _SessionTextFilterRequest request,
) {
  final searchIds = <String>{};
  final pathIds = <String>{};
  final threadNameIds = <String>{};
  for (final row in request.rows) {
    if (request.search.isNotEmpty &&
        (row.matchesInternalId(request.search) ||
            row.searchFields.any((value) => value.contains(request.search)))) {
      searchIds.add(row.id);
    }
    if (request.path.isNotEmpty && row.path.contains(request.path)) {
      pathIds.add(row.id);
    }
    if (request.threadName.isNotEmpty &&
        row.threadName.contains(request.threadName)) {
      threadNameIds.add(row.id);
    }
  }
  return _SessionTextFilterResult(
    searchIds: searchIds,
    pathIds: pathIds,
    threadNameIds: threadNameIds,
  );
}

Future<_SessionTextFilterResult> _runSessionTextFilterOnWorker(
  _SessionTextFilterRequest request,
) {
  return Isolate.run(() => _matchSessionTextFilters(request));
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
                  AppButton.outlined(
                    onPressed: onShowAllOrigins,
                    icon: const AppSvgIcon(AppIcons.filter),
                    label: const Text('Show all origins'),
                  ),
                ] else if (hasRows && hasActiveFilters) ...[
                  const SizedBox(height: 12),
                  AppButton.outlined(
                    onPressed: onClearFilters,
                    icon: const AppSvgIcon(AppIcons.filterClear),
                    label: const Text('Clear filters'),
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      AppButton.outlined(
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
        AppButton.outlined(
          onPressed: onTestWslPath,
          icon: const AppSvgIcon(AppIcons.terminal),
          label: const Text('Retry scan'),
        ),
        AppButton.outlined(
          onPressed: onOpenSettings,
          icon: const AppSvgIcon(AppIcons.settings),
          label: const Text('Open Settings'),
        ),
      ],
    );
  }
}

/// Filters above the session table.
///
/// Row 1 holds the controls used on almost every visit: search, time range,
/// refresh. Row 2 holds facet filters as compact menu buttons that show their
/// current value. Active non-default filters are repeated as removable chips so
/// the user can always see why sessions are hidden.
class _FilterBar extends StatefulWidget {
  const _FilterBar({
    required this.searchController,
    required this.searchFocusNode,
    required this.filterAreaFocusNode,
    required this.pathController,
    required this.threadNameController,
    required this.platformFilter,
    required this.timeFilter,
    required this.archivedFilter,
    required this.originFilter,
    required this.harnessFilter,
    required this.onHarnessChanged,
    required this.maxSessionsPerProject,
    required this.excludedProjects,
    required this.onExcludedProjectsChanged,
    required this.namedOnly,
    required this.projectFilter,
    required this.modelFilter,
    required this.tagFilter,
    required this.projectOptions,
    required this.modelOptions,
    required this.tagOptions,
    required this.visibleCount,
    required this.totalCount,
    required this.isScanning,
    required this.isCancellingRefresh,
    required this.onPlatformChanged,
    required this.onTimeChanged,
    required this.onArchivedChanged,
    required this.onOriginChanged,
    required this.onMaxSessionsPerProjectChanged,
    required this.onNamedOnlyChanged,
    required this.onProjectChanged,
    required this.onModelChanged,
    required this.onTagChanged,
    required this.onClearFilters,
    required this.onRefresh,
  });

  final TextEditingController searchController;
  final FocusNode searchFocusNode;
  final FocusNode filterAreaFocusNode;
  final TextEditingController pathController;
  final TextEditingController threadNameController;
  final SessionsPlatformFilter platformFilter;
  final SessionsTimeFilter timeFilter;
  final SessionsArchivedFilter archivedFilter;
  final SessionsOriginFilter originFilter;
  final String? harnessFilter;
  final ValueChanged<String?> onHarnessChanged;
  final int? maxSessionsPerProject;
  final Set<String> excludedProjects;
  final ValueChanged<Set<String>> onExcludedProjectsChanged;
  final bool namedOnly;
  final String? projectFilter;
  final String? modelFilter;
  final String? tagFilter;
  final List<String> projectOptions;
  final List<String> modelOptions;
  final List<String> tagOptions;
  final int visibleCount;
  final int totalCount;
  final bool isScanning;
  final bool isCancellingRefresh;
  final ValueChanged<SessionsPlatformFilter> onPlatformChanged;
  final ValueChanged<SessionsTimeFilter> onTimeChanged;
  final ValueChanged<SessionsArchivedFilter> onArchivedChanged;
  final ValueChanged<SessionsOriginFilter> onOriginChanged;
  final ValueChanged<int?> onMaxSessionsPerProjectChanged;
  final ValueChanged<bool> onNamedOnlyChanged;
  final ValueChanged<String?> onProjectChanged;
  final ValueChanged<String?> onModelChanged;
  final ValueChanged<String?> onTagChanged;
  final VoidCallback onClearFilters;
  final VoidCallback onRefresh;

  @override
  State<_FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<_FilterBar> {
  late bool _showMore;
  final _excludeProjectsFocusNode = FocusNode(debugLabel: 'Exclude projects');

  Future<void> _editExcludedProjects() async {
    final projects = await showDialog<Set<String>>(
      context: context,
      builder: (context) => ExcludeProjectsDialog(
        projects: widget.projectOptions,
        excludedProjects: widget.excludedProjects,
      ),
    );
    if (!mounted) return;
    if (projects != null) widget.onExcludedProjectsChanged(projects);
    _excludeProjectsFocusNode.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    _showMore =
        widget.pathController.text.isNotEmpty ||
        widget.threadNameController.text.isNotEmpty ||
        widget.maxSessionsPerProject != null ||
        widget.excludedProjects.isNotEmpty;
    widget.searchController.addListener(_textChanged);
    widget.pathController.addListener(_textChanged);
    widget.threadNameController.addListener(_textChanged);
  }

  @override
  void dispose() {
    _excludeProjectsFocusNode.dispose();
    widget.searchController.removeListener(_textChanged);
    widget.pathController.removeListener(_textChanged);
    widget.threadNameController.removeListener(_textChanged);
    super.dispose();
  }

  void _textChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    final theme = Theme.of(context);
    final refreshLabel = widget.isCancellingRefresh
        ? 'Cancelling scan...'
        : widget.isScanning
        ? 'Cancel scan'
        : 'Refresh';
    final activeChips = _activeFilterChips();
    final hiddenActiveCount = [
      widget.archivedFilter != SessionsArchivedFilter.activeOnly,
      widget.namedOnly,
      widget.maxSessionsPerProject != null,
      widget.excludedProjects.isNotEmpty,
      widget.pathController.text.trim().isNotEmpty,
      widget.threadNameController.text.trim().isNotEmpty,
    ].where((active) => active).length;
    final showMore = _showMore || hiddenActiveCount > 0;
    final summary =
        '${widget.visibleCount} of ${widget.totalCount} sessions shown. '
        'Filters: ${activeChips.map((chip) => chip.label).join(', ')}.';

    final search = Semantics(
      label: 'Session search',
      textField: true,
      child: TextField(
        controller: widget.searchController,
        focusNode: widget.searchFocusNode,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search titles, messages, paths, tags (Ctrl+F)',
          border: const OutlineInputBorder(),
          prefixIcon: const Icon(Icons.search, size: 18),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 34,
            minHeight: 34,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 10,
          ),
          suffixIcon: widget.searchController.text.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear search',
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.searchController.clear,
                  icon: const Icon(Icons.close, size: 16),
                ),
        ),
      ),
    );
    final time = _FilterMenuButton<SessionsTimeFilter>(
      semanticsLabel: 'Time range filter',
      key: ValueKey('time-filter-${widget.timeFilter.name}'),
      label: 'Time',
      value: widget.timeFilter,
      isActive: widget.timeFilter != _defaultTimeFilter,
      options: [
        for (final value in SessionsTimeFilter.values) (value, value.label),
      ],
      onSelected: widget.onTimeChanged,
    );
    final refresh = AppButton.elevated(
      onPressed: widget.isCancellingRefresh ? null : widget.onRefresh,
      icon: AppSvgIcon(widget.isScanning ? AppIcons.cancel : AppIcons.refresh),
      label: Text(refreshLabel),
    );
    final facets = Wrap(
      spacing: 6,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _FilterMenuButton<String?>(
          semanticsLabel: 'Project filter',
          label: 'Project',
          value: widget.projectFilter,
          isActive: widget.projectFilter != null,
          options: [
            (null, 'All projects'),
            for (final project in widget.projectOptions) (project, project),
          ],
          onSelected: widget.onProjectChanged,
        ),
        _FilterMenuButton<String?>(
          semanticsLabel: 'Model filter',
          label: 'Model',
          value: widget.modelFilter,
          isActive: widget.modelFilter != null,
          options: [
            (null, 'All models'),
            for (final model in widget.modelOptions) (model, model),
          ],
          onSelected: widget.onModelChanged,
        ),
        if (widget.tagOptions.isNotEmpty || widget.tagFilter != null)
          _FilterMenuButton<String?>(
            semanticsLabel: 'Tag filter',
            label: 'Tag',
            value: widget.tagFilter,
            isActive: widget.tagFilter != null,
            options: [
              (null, 'All tags'),
              for (final tag in widget.tagOptions) (tag, tag),
            ],
            onSelected: widget.onTagChanged,
          ),
        _FilterMenuButton<String>(
          semanticsLabel: 'Harness filter',
          label: 'Harness',
          value: widget.harnessFilter ?? '',
          isActive: widget.harnessFilter != null,
          options: [
            ('', 'All harnesses'),
            for (final harness in const ['codex', 'claude'])
              (harness, SessionLabelFormatter.harness(harness)),
          ],
          onSelected: (value) =>
              widget.onHarnessChanged(value.isEmpty ? null : value),
        ),
        _FilterMenuButton<SessionsPlatformFilter>(
          semanticsLabel: 'Platform filter',
          key: ValueKey(widget.platformFilter),
          label: 'Platform',
          value: widget.platformFilter,
          isActive: widget.platformFilter != SessionsPlatformFilter.both,
          options: [
            for (final value in SessionsPlatformFilter.values)
              (value, value.label),
          ],
          onSelected: widget.onPlatformChanged,
        ),
        _FilterMenuButton<SessionsOriginFilter>(
          semanticsLabel: 'Origin filter',
          key: ValueKey('origin-filter-${widget.originFilter.name}'),
          label: 'Show',
          value: widget.originFilter,
          isActive: widget.originFilter != _defaultOriginFilter,
          tooltip:
              'Main sessions group their subagents under an expandable row.',
          options: [
            for (final value in SessionsOriginFilter.values)
              (value, value.label),
          ],
          onSelected: widget.onOriginChanged,
        ),
        Semantics(
          button: true,
          expanded: showMore,
          label: hiddenActiveCount == 0
              ? 'More filters'
              : 'More filters, $hiddenActiveCount active',
          onTap: () => setState(() => _showMore = !showMore),
          child: ExcludeSemantics(
            child: AppButton.text(
              onPressed: () => setState(() => _showMore = !showMore),
              icon: Icon(
                showMore ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
              label: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('More filters'),
                  if (hiddenActiveCount > 0) ...[
                    const SizedBox(width: 6),
                    _CountBadge(count: hiddenActiveCount),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
    final moreFilters = Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _FilterMenuButton<SessionsArchivedFilter>(
                semanticsLabel: 'Viewer archive filter',
                key: ValueKey(widget.archivedFilter),
                label: 'Archived in viewer',
                value: widget.archivedFilter,
                isActive:
                    widget.archivedFilter != SessionsArchivedFilter.activeOnly,
                tooltip:
                    'Sessions you archived in this viewer. Codex files are not changed.',
                options: [
                  for (final value in SessionsArchivedFilter.values)
                    (value, value.label),
                ],
                onSelected: widget.onArchivedChanged,
              ),
              _ToggleFilterChip(
                semanticsLabel: 'Named sessions only filter',
                label: 'Named only',
                tooltip: 'Only sessions that have a thread name',
                value: widget.namedOnly,
                onChanged: widget.onNamedOnlyChanged,
              ),
              SessionProjectLimit(
                limit: widget.maxSessionsPerProject,
                onChanged: widget.onMaxSessionsPerProjectChanged,
              ),
              AppButton.outlined(
                focusNode: _excludeProjectsFocusNode,
                onPressed: _editExcludedProjects,
                icon: const Icon(Icons.filter_alt_off, size: 18),
                label: const Text('Exclude projects...'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: Semantics(
                  label: 'Path filter',
                  textField: true,
                  child: TextField(
                    controller: widget.pathController,
                    decoration: const InputDecoration(
                      labelText: 'Path contains',
                      hintText: r'e.g. F:\projects\my-app',
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: Semantics(
                  label: 'Thread name filter',
                  textField: true,
                  child: TextField(
                    controller: widget.threadNameController,
                    decoration: const InputDecoration(
                      labelText: 'Thread name contains',
                      isDense: true,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
    final activeSummary = Semantics(
      container: true,
      liveRegion: true,
      label: summary,
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ExcludeSemantics(
            child: Text(
              '${formatGroupedInt(widget.visibleCount)} of '
              '${formatGroupedInt(widget.totalCount)} shown',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final chip in activeChips)
            InputChip(
              label: Text(chip.label),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              labelStyle: theme.textTheme.bodySmall,
              onDeleted: chip.onRemove,
              deleteButtonTooltipMessage: 'Remove filter ${chip.label}',
            ),
          AppButton.outlined(
            onPressed: widget.onClearFilters,
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            icon: const AppSvgIcon(AppIcons.filterClear),
            label: const Text('Clear filters'),
          ),
        ],
      ),
    );

    return Semantics(
      container: true,
      explicitChildNodes: true,
      child: Material(
        color: theme.colorScheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < 620;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(child: search),
                      if (!narrow) ...[const SizedBox(width: 8), time],
                      const SizedBox(width: 8),
                      refresh,
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Ctrl+L focuses this node, then moves to its first filter.
                  Focus(
                    focusNode: widget.filterAreaFocusNode,
                    child: narrow
                        ? Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [time, ...facets.children],
                          )
                        : facets,
                  ),
                  if (showMore) moreFilters,
                  if (activeChips.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    activeSummary,
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  List<_ActiveFilterChip> _activeFilterChips() {
    final widget = this.widget;
    final search = widget.searchController.text.trim();
    final path = widget.pathController.text.trim();
    final threadName = widget.threadNameController.text.trim();
    return [
      if (search.isNotEmpty)
        _ActiveFilterChip('Search: $search', widget.searchController.clear),
      if (widget.timeFilter != _defaultTimeFilter)
        _ActiveFilterChip(
          'Time: ${widget.timeFilter.label}',
          () => widget.onTimeChanged(_defaultTimeFilter),
        ),
      if (widget.projectFilter != null)
        _ActiveFilterChip(
          'Project: ${widget.projectFilter}',
          () => widget.onProjectChanged(null),
        ),
      if (widget.modelFilter != null)
        _ActiveFilterChip(
          'Model: ${widget.modelFilter}',
          () => widget.onModelChanged(null),
        ),
      if (widget.tagFilter != null)
        _ActiveFilterChip(
          'Tag: ${widget.tagFilter}',
          () => widget.onTagChanged(null),
        ),
      if (widget.platformFilter != SessionsPlatformFilter.both)
        _ActiveFilterChip(
          widget.platformFilter.label,
          () => widget.onPlatformChanged(SessionsPlatformFilter.both),
        ),
      if (widget.harnessFilter case final harness?)
        _ActiveFilterChip(
          SessionLabelFormatter.harness(harness),
          () => widget.onHarnessChanged(null),
        ),
      if (widget.originFilter != _defaultOriginFilter)
        _ActiveFilterChip(
          widget.originFilter.label,
          () => widget.onOriginChanged(_defaultOriginFilter),
        ),
      if (widget.archivedFilter != SessionsArchivedFilter.activeOnly)
        _ActiveFilterChip(
          'Archived: ${widget.archivedFilter.label}',
          () => widget.onArchivedChanged(SessionsArchivedFilter.activeOnly),
        ),
      if (widget.namedOnly)
        _ActiveFilterChip('Named only', () => widget.onNamedOnlyChanged(false)),
      if (widget.maxSessionsPerProject case final limit?)
        _ActiveFilterChip(
          'Latest $limit per project',
          () => widget.onMaxSessionsPerProjectChanged(null),
        ),
      for (final project in widget.excludedProjects)
        _ActiveFilterChip('Excluded: $project', () {
          widget.onExcludedProjectsChanged(
            {...widget.excludedProjects}..remove(project),
          );
          _excludeProjectsFocusNode.requestFocus();
        }),
      if (path.isNotEmpty)
        _ActiveFilterChip('Path: $path', widget.pathController.clear),
      if (threadName.isNotEmpty)
        _ActiveFilterChip(
          'Thread: $threadName',
          widget.threadNameController.clear,
        ),
    ];
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$count',
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }
}

class _ActiveFilterChip {
  const _ActiveFilterChip(this.label, this.onRemove);

  final String label;
  final VoidCallback onRemove;
}

extension on SessionsPlatformFilter {
  String get label => switch (this) {
    SessionsPlatformFilter.both => 'Windows and WSL',
    SessionsPlatformFilter.windows => 'Windows only',
    SessionsPlatformFilter.wsl => 'WSL only',
  };
}

extension on SessionsOriginFilter {
  String get label => switch (this) {
    SessionsOriginFilter.user => 'Main sessions',
    SessionsOriginFilter.all => 'All sessions',
    SessionsOriginFilter.subagent => 'Subagents only',
  };
}

extension on SessionsArchivedFilter {
  String get label => switch (this) {
    SessionsArchivedFilter.activeOnly => 'Hidden',
    SessionsArchivedFilter.archivedOnly => 'Archived only',
    SessionsArchivedFilter.all => 'Shown',
  };
}

/// A compact dropdown that shows its label and current value, and highlights
/// itself when set to a non-default value.
class _FilterMenuButton<T> extends StatefulWidget {
  const _FilterMenuButton({
    super.key,
    required this.semanticsLabel,
    required this.label,
    required this.value,
    required this.options,
    required this.onSelected,
    required this.isActive,
    this.tooltip,
  });

  final String semanticsLabel;
  final String label;
  final T value;
  final List<(T, String)> options;
  final ValueChanged<T> onSelected;
  final bool isActive;
  final String? tooltip;

  @override
  State<_FilterMenuButton<T>> createState() => _FilterMenuButtonState<T>();
}

class _FilterMenuButtonState<T> extends State<_FilterMenuButton<T>> {
  // Items carry the option value itself (wrapped so a null "All" value is a
  // real selection). The menu can stay open while rows change the options,
  // so an index into the current options could pick the wrong filter.
  final _menuKey = GlobalKey<PopupMenuButtonState<(T,)>>();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    var valueLabel = '${widget.value}';
    for (final option in widget.options) {
      if (option.$1 == widget.value) {
        valueLabel = option.$2;
        break;
      }
    }
    return Semantics(
      label: widget.semanticsLabel,
      value: valueLabel,
      button: true,
      container: true,
      excludeSemantics: true,
      onTap: () => _menuKey.currentState?.showButtonMenu(),
      child: PopupMenuButton<(T,)>(
        key: _menuKey,
        tooltip: widget.tooltip ?? '${widget.label}: $valueLabel',
        initialValue: (widget.value,),
        onSelected: (choice) => widget.onSelected(choice.$1),
        constraints: const BoxConstraints(maxHeight: 420, minWidth: 180),
        itemBuilder: (context) => [
          for (final option in widget.options)
            CheckedPopupMenuItem<(T,)>(
              value: (option.$1,),
              checked: option.$1 == widget.value,
              child: Text(option.$2),
            ),
        ],
        child: Container(
          constraints: const BoxConstraints(minHeight: 32),
          padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
          decoration: BoxDecoration(
            color: widget.isActive ? scheme.secondaryContainer : null,
            border: Border.all(
              color: widget.isActive ? scheme.secondary : scheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${widget.label}: ',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: widget.isActive
                      ? scheme.onSecondaryContainer
                      : scheme.onSurfaceVariant,
                ),
              ),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    valueLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: widget.isActive ? FontWeight.w600 : null,
                      color: widget.isActive
                          ? scheme.onSecondaryContainer
                          : null,
                    ),
                  ),
                ),
              ),
              Icon(
                Icons.arrow_drop_down,
                size: 18,
                color: widget.isActive
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToggleFilterChip extends StatelessWidget {
  const _ToggleFilterChip({
    required this.semanticsLabel,
    required this.label,
    required this.tooltip,
    required this.value,
    required this.onChanged,
  });

  final String semanticsLabel;
  final String label;
  final String tooltip;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: semanticsLabel,
      toggled: value,
      container: true,
      excludeSemantics: true,
      onTap: () => onChanged(!value),
      child: FilterChip(
        label: Text(label),
        tooltip: tooltip,
        selected: value,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        labelStyle: Theme.of(context).textTheme.bodySmall,
        onSelected: onChanged,
      ),
    );
  }
}

class _SessionsHeading extends StatefulWidget {
  const _SessionsHeading({
    required this.visibleCount,
    this.onAction,
    this.canSaveCsv = false,
  });

  final int visibleCount;
  final ValueChanged<_SessionListAction>? onAction;
  final bool canSaveCsv;

  @override
  State<_SessionsHeading> createState() => _SessionsHeadingState();
}

class _SessionsHeadingState extends State<_SessionsHeading> {
  // Held in State: a key created in build would replace the menu button, and
  // its keyboard focus, on every rebuild.
  final _actionsMenuKey = GlobalKey<PopupMenuButtonState<_SessionListAction>>();

  @override
  Widget build(BuildContext context) {
    final visibleCount = widget.visibleCount;
    final onAction = widget.onAction;
    final canSaveCsv = widget.canSaveCsv;
    final countStyle = Theme.of(context).textTheme.bodySmall;
    final actionsMenuKey = _actionsMenuKey;
    return Row(
      children: [
        Semantics(
          header: true,
          container: true,
          label: 'Sessions, $visibleCount visible',
          child: ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Sessions', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(width: 6),
                Text('($visibleCount)', style: countStyle),
              ],
            ),
          ),
        ),
        if (onAction != null) ...[
          const SizedBox(width: 4),
          Semantics(
            label: 'Session list actions',
            button: true,
            container: true,
            excludeSemantics: true,
            onTap: () => actionsMenuKey.currentState?.showButtonMenu(),
            child: PopupMenuButton<_SessionListAction>(
              key: actionsMenuKey,
              tooltip: 'Session list actions',
              onSelected: onAction,
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: _SessionListAction.copyMarkdown,
                  child: Text('Copy visible list as Markdown'),
                ),
                const PopupMenuItem(
                  value: _SessionListAction.copyExtendedMarkdown,
                  child: Text('Copy visible list as extended Markdown…'),
                ),
                PopupMenuItem(
                  value: _SessionListAction.saveCsv,
                  enabled: canSaveCsv,
                  child: const Text('Save visible list as CSV…'),
                ),
              ],
              icon: const Icon(Icons.more_horiz),
            ),
          ),
        ],
      ],
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
              onTap: column.key == 'actions' ? null : _handleTap,
              excludeSemantics: true,
              child: InkWell(
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
          _ColumnResizeHandle(
            label: column.label,
            width: width,
            defaultWidth: column.defaultWidth,
            onResize: onResize,
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

class _ColumnResizeHandle extends StatefulWidget {
  const _ColumnResizeHandle({
    required this.label,
    required this.width,
    required this.defaultWidth,
    required this.onResize,
  });

  final String label;
  final double width;
  final double defaultWidth;
  final ValueChanged<double> onResize;

  @override
  State<_ColumnResizeHandle> createState() => _ColumnResizeHandleState();
}

class _ColumnResizeHandleState extends State<_ColumnResizeHandle> {
  var _focused = false;

  void _resize(double delta) => widget.onResize(widget.width + delta);

  @override
  Widget build(BuildContext context) {
    final focusColor = Theme.of(context).focusColor;
    return Semantics(
      label: 'Resize ${widget.label} column',
      value: '${widget.width.round()} pixels',
      increasedValue: 'Wider ${widget.label} column',
      decreasedValue: 'Narrower ${widget.label} column',
      focusable: true,
      button: true,
      onIncrease: () => _resize(16),
      onDecrease: () => _resize(-16),
      onTap: () => widget.onResize(widget.defaultWidth),
      child: ExcludeSemantics(
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                _resize(-16),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                _resize(16),
            const SingleActivator(LogicalKeyboardKey.enter): () =>
                widget.onResize(widget.defaultWidth),
            const SingleActivator(LogicalKeyboardKey.space): () =>
                widget.onResize(widget.defaultWidth),
          },
          child: Focus(
            onFocusChange: (focused) => setState(() => _focused = focused),
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeLeftRight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) => _resize(details.delta.dx),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: _focused ? focusColor : Colors.transparent,
                  ),
                  child: const SizedBox(width: 8, height: double.infinity),
                ),
              ),
            ),
          ),
        ),
      ),
    );
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
    required this.onListAction,
    required this.canSaveCsv,
    required this.statusMessage,
    required this.isScanning,
    required this.animatedRowIds,
    required this.rowMotionGeneration,
    required this.unreachablePaths,
    required this.onOpenSettings,
    required this.onTestWslPath,
    required this.now,
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
  final ValueChanged<_SessionListAction> onListAction;
  final bool canSaveCsv;
  final String statusMessage;
  final bool isScanning;
  final Set<String> animatedRowIds;
  final int rowMotionGeneration;
  final List<String> unreachablePaths;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onTestWslPath;
  final DateTime Function() now;

  static double _rowHeightFor(BuildContext context) =>
      48.0 *
      (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(
        1.0,
        double.infinity,
      );
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
          child: _SessionsHeading(
            visibleCount: rows.length,
            onAction: onListAction,
            canSaveCsv: canSaveCsv,
          ),
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
                        itemExtent: _rowHeightFor(context),
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
      // A selectable row, not a button: a button role would hide the nested
      // row controls from screen readers. Tab and Enter still select it.
      selected: selected,
      container: true,
      onTap: () => onSelect(row.id),
      child: InkWell(
        excludeFromSemantics: true,
        onTap: () => onSelect(row.id),
        child: Container(
          height: _rowHeightFor(context),
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
              _cell('Model', row.modelLabel, width: _widthFor('model')),
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
      semanticsText: display,
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
                excludeSemantics: true,
                onTap: () => onToggleSubagents(row.id),
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
                value: 'Harness ${row.harnessLabel}',
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
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                identity,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                row.harnessLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ),
                          ],
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
    final display = row.lastMessageAtUtc.relativeDisplay(now().toUtc());
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
    final isCodexArchived =
        row.sourceState == SessionRowSourceState.codexArchived;
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.only(left: 8, right: 4),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                label:
                    '${row.platformLabel} path ${row.path}'
                    '${isCodexArchived ? ', Codex source archived' : ''}',
                container: true,
                child: ExcludeSemantics(
                  child: Row(
                    children: [
                      _PlatformGlyph(platform: row.platform),
                      const SizedBox(width: 8),
                      if (isCodexArchived) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.secondaryContainer,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'Codex archived',
                            style: Theme.of(context).textTheme.labelSmall,
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
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
              excludeSemantics: true,
              onTap: onCopy,
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
            onTap: onAddTag,
            child: ExcludeSemantics(
              child: IconButton(
                tooltip: 'Add tag to $rowLabel',
                icon: const Icon(Icons.add, size: 18),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints.tightFor(
                  width: 30,
                  height: 30,
                ),
                onPressed: onAddTag,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionsMenu extends StatefulWidget {
  const _ActionsMenu({
    required this.row,
    required this.onAction,
    required this.settings,
  });

  final SessionRowViewModel row;
  final SessionActionCallback onAction;
  final AppSettings settings;

  @override
  State<_ActionsMenu> createState() => _ActionsMenuState();
}

class _ActionsMenuState extends State<_ActionsMenu> {
  // Held in State so collector commits that rebuild the row keep the menu
  // button, and its keyboard focus.
  final _actionsMenuKey = GlobalKey<PopupMenuButtonState<SessionRowAction>>();

  SessionRowViewModel get row => widget.row;
  SessionActionCallback get onAction => widget.onAction;
  AppSettings get settings => widget.settings;

  @override
  Widget build(BuildContext context) {
    final commandSet = _commandSet(row);
    final rowLabel = _rowAccessibleLabel(row);
    final actionsMenuKey = _actionsMenuKey;
    final resumeReason =
        commandSet.terminalDisabledReason ??
        commandSet.disabledReason ??
        'Resume command unavailable.';
    final openTerminalResume = commandSet.terminalLaunchCommand == null
        ? null
        : () => onAction(
            SessionActionRequest(
              row: row,
              action: SessionRowAction.openTerminalResume,
              payload: commandSet.terminalLaunchCommand,
              launchSpec: commandSet.terminalLaunchSpec,
            ),
          );
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Semantics(
          label: commandSet.terminalLaunchCommand == null
              ? 'Open terminal and resume unavailable for $rowLabel: $resumeReason'
              : 'Open terminal and resume for $rowLabel',
          button: true,
          enabled: openTerminalResume != null,
          onTap: openTerminalResume,
          child: ExcludeSemantics(
            child: IconButton(
              tooltip: commandSet.terminalLaunchCommand == null
                  ? 'Resume unavailable: $resumeReason'
                  : 'Open terminal and resume for $rowLabel',
              icon: const AppSvgIcon(AppIcons.terminal),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              onPressed: openTerminalResume,
            ),
          ),
        ),
        Semantics(
          label: 'More actions for $rowLabel',
          button: true,
          excludeSemantics: true,
          onTap: () => actionsMenuKey.currentState?.showButtonMenu(),
          child: PopupMenuButton<SessionRowAction>(
            key: actionsMenuKey,
            tooltip: 'More actions',
            onSelected: (action) => onAction(
              SessionActionRequest(
                row: row,
                action: action,
                payload: _payloadFor(row, commandSet, action),
                launchSpec: _launchSpecFor(commandSet, action),
              ),
            ),
            itemBuilder: (context) => [
              MenuHeaderEntry<SessionRowAction>(row.harnessLabel),
              if (_canOpenContainingFolder(row))
                _item(
                  SessionRowAction.openPath,
                  'Open containing folder',
                  iconAsset: AppIcons.folderOpen,
                ),
              _item(
                SessionRowAction.openTerminalResume,
                commandSet.terminalLaunchCommand == null
                    ? 'Resume unavailable'
                    : 'Open terminal and resume',
                iconAsset: AppIcons.terminal,
                enabled: commandSet.terminalLaunchCommand != null,
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
              if (row.harness == 'codex')
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
                SessionRowAction.moveToProject,
                'Move to project…',
                iconAsset: AppIcons.folderOpen,
              ),
              _item(
                SessionRowAction.openInProjects,
                'Open project in Projects',
                enabled: row.project.isNotEmpty,
                disabledReason: 'This session has no project.',
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
              if (row.harness == 'codex')
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
              AppSvgIcon(iconAsset, size: 18),
              const SizedBox(width: 8),
              Flexible(child: Text(label)),
            ],
          );
    return PopupMenuItem<SessionRowAction>(
      value: action,
      enabled: enabled,
      height: enabled || disabledReason == null ? 36 : 52,
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
        harness: row.harness,
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
      SessionRowAction.editTags ||
      SessionRowAction.moveToProject ||
      SessionRowAction.openInProjects => null,
      SessionRowAction.togglePin ||
      SessionRowAction.toggleArchive ||
      SessionRowAction.updateEvalMetadata ||
      SessionRowAction.reparse => null,
    };
  }

  TerminalLaunchSpec? _launchSpecFor(
    ResumeCommandSet commandSet,
    SessionRowAction action,
  ) {
    return switch (action) {
      SessionRowAction.openTerminalResume => commandSet.terminalLaunchSpec,
      SessionRowAction.openTerminalFork => commandSet.terminalForkLaunchSpec,
      _ => null,
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
      SessionRowAction.moveToProject => 'Move to project',
      SessionRowAction.openInProjects => 'Open project in Projects',
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

/// Draggable divider between the session table and the detail pane.
/// Double-click restores the default split.
class _SplitHandle extends StatefulWidget {
  const _SplitHandle({
    required this.onDrag,
    required this.onDragEnd,
    required this.onNudgeEnd,
    required this.tablePercent,
    required this.onReset,
  });

  /// The session table's share of the width, announced as the value.
  final int tablePercent;

  final ValueChanged<double> onDrag;
  final VoidCallback onDragEnd;

  /// Called after each keyboard or accessibility nudge; the owner saves the
  /// layout once the nudges settle.
  final VoidCallback onNudgeEnd;
  final VoidCallback onReset;

  @override
  State<_SplitHandle> createState() => _SplitHandleState();
}

class _SplitHandleState extends State<_SplitHandle> {
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final focusColor = scheme.primary;
    void nudge(double delta) {
      widget.onDrag(delta);
      widget.onNudgeEnd();
    }

    return Semantics(
      label: 'Resize session table and detail panes',
      value: 'Session table ${widget.tablePercent} percent',
      hint: 'Use Left and Right Arrow to resize. Press Enter to reset.',
      increasedValue: 'Wider session table',
      decreasedValue: 'Narrower session table',
      focusable: true,
      button: true,
      onIncrease: () => nudge(24),
      onDecrease: () => nudge(-24),
      onTap: widget.onReset,
      child: ExcludeSemantics(
        child: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                nudge(-24),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                nudge(24),
            const SingleActivator(LogicalKeyboardKey.enter): widget.onReset,
            const SingleActivator(LogicalKeyboardKey.space): widget.onReset,
          },
          child: Focus(
            onFocusChange: (focused) => setState(() => _focused = focused),
            child: MouseRegion(
              cursor: SystemMouseCursors.resizeColumn,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) =>
                    widget.onDrag(details.delta.dx),
                onHorizontalDragEnd: (_) => widget.onDragEnd(),
                onDoubleTap: widget.onReset,
                child: DecoratedBox(
                  key: const Key('sessions-pane-splitter'),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    border: _focused
                        ? Border.all(color: focusColor, width: 2)
                        : Border(
                            left: BorderSide(color: scheme.outlineVariant),
                            right: BorderSide(color: scheme.outline),
                          ),
                  ),
                  child: SizedBox(
                    width: _SessionsScreenState._splitDividerWidth,
                    child: Center(
                      child: Container(
                        width: 1,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SessionDetailPlaceholder extends StatelessWidget {
  const _SessionDetailPlaceholder({
    required this.row,
    required this.subagents,
    required this.parentRow,
    required this.onOpenSession,
    required this.detailTab,
    required this.onDetailTabChanged,
    required this.onLoadFullConversationMessages,
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
  final List<SessionRowViewModel> subagents;
  final SessionRowViewModel? parentRow;
  final ValueChanged<String> onOpenSession;
  final SessionDetailTab detailTab;
  final ValueChanged<SessionDetailTab> onDetailTabChanged;
  final FullConversationMessagesLoader? onLoadFullConversationMessages;
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
        fit: StackFit.expand,
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
        subagents: subagents,
        parentRow: parentRow,
        onOpenSession: onOpenSession,
        initialTab: detailTab,
        onTabChanged: onDetailTabChanged,
        onLoadFullConversationMessages: onLoadFullConversationMessages,
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
        AppButton.text(
          onPressed: () => Navigator.of(context).pop(_defaultSorts),
          icon: const AppSvgIcon(AppIcons.refresh),
          label: const Text('Default'),
        ),
        AppButton.text(
          onPressed: () => Navigator.of(context).pop(_defaultSorts),
          icon: const AppSvgIcon(AppIcons.filterClear),
          label: const Text('Clear'),
        ),
        AppButton.text(
          onPressed: () => Navigator.of(context).pop(),
          icon: const AppSvgIcon(AppIcons.cancel),
          label: const Text('Cancel'),
        ),
        AppButton.filled(
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

  String relativeDisplay(DateTime nowUtc) {
    final elapsed = nowUtc.difference(toUtc());
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
    if (row.isArchived) 'Viewer archived',
    if (row.sourceState == SessionRowSourceState.codexArchived)
      'Codex source archived',
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
