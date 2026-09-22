import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../database/project_tag_state.dart';
import '../dialogs/project_dialogs.dart';
import '../models/projects_repository.dart';
import '../widgets/app_button.dart';

enum ProjectSortKey { name, lastActivity }

/// Sort, search, and selection of the Projects screen, kept by the app so
/// they survive switching screens.
class ProjectsViewState {
  ProjectSortKey sortKey = ProjectSortKey.lastActivity;
  bool descending = true;
  String query = '';
  int? selectedProjectId;
}

class ProjectsScreen extends StatefulWidget {
  const ProjectsScreen({
    super.key,
    required this.repository,
    required this.viewState,
    this.openProjectName,
    this.openProjectSerial = 0,
    this.onProjectsChanged,
    this.pickDirectory,
    this.now = DateTime.now,
  });

  final ProjectsRepository repository;
  final ProjectsViewState viewState;

  /// Selects this project when [openProjectSerial] changes.
  final String? openProjectName;
  final int openProjectSerial;

  /// Called after folder rules or project assignments change.
  final VoidCallback? onProjectsChanged;
  final Future<String?> Function()? pickDirectory;
  final DateTime Function() now;

  @override
  State<ProjectsScreen> createState() => _ProjectsScreenState();
}

class _ProjectsScreenState extends State<ProjectsScreen> {
  final _searchFocusNode = FocusNode(debugLabel: 'Project search');
  late final _searchController = TextEditingController(
    text: widget.viewState.query,
  );
  List<ProjectSummary>? _projects;
  Object? _loadError;
  ProjectDetail? _detail;
  var _detailGeneration = 0;
  var _busy = false;
  String? _pendingOpenName;

  ProjectsViewState get _view => widget.viewState;

  @override
  void initState() {
    super.initState();
    _pendingOpenName = widget.openProjectName;
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(covariant ProjectsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.openProjectSerial != oldWidget.openProjectSerial) {
      _pendingOpenName = widget.openProjectName;
      _applyPendingOpen();
    }
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _reload({String? selectName}) async {
    try {
      final projects = await widget.repository.loadProjects();
      if (!mounted) {
        return;
      }
      setState(() {
        _projects = projects;
        _loadError = null;
        if (selectName != null) {
          _pendingOpenName = selectName;
        }
        if (!projects.any((p) => p.id == _view.selectedProjectId)) {
          _view.selectedProjectId = null;
          _detail = null;
        }
      });
      _applyPendingOpen();
      await _loadDetail();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _loadError = error);
      }
    }
  }

  void _applyPendingOpen() {
    final name = _pendingOpenName;
    final projects = _projects;
    if (name == null || projects == null) {
      return;
    }
    _pendingOpenName = null;
    for (final project in projects) {
      if (project.name == name) {
        _select(project.id);
        return;
      }
    }
  }

  void _select(int id) {
    if (_view.selectedProjectId == id && _detail?.projectId == id) {
      return;
    }
    setState(() {
      _view.selectedProjectId = id;
      _detail = null;
    });
    unawaited(_loadDetail());
  }

  Future<void> _loadDetail() async {
    final id = _view.selectedProjectId;
    final generation = ++_detailGeneration;
    if (id == null) {
      return;
    }
    try {
      final detail = await widget.repository.loadProjectDetail(id);
      if (mounted && generation == _detailGeneration) {
        setState(() => _detail = detail);
      }
    } on Object catch (error) {
      if (mounted && generation == _detailGeneration) {
        _showMessage('Could not load the project. $error');
      }
    }
  }

  ProjectSummary? get _selected {
    final id = _view.selectedProjectId;
    for (final project in _projects ?? const <ProjectSummary>[]) {
      if (project.id == id) {
        return project;
      }
    }
    return null;
  }

  List<ProjectSummary> get _visibleProjects {
    final query = _view.query.trim().toLowerCase();
    final projects = [
      for (final project in _projects ?? const <ProjectSummary>[])
        if (query.isEmpty || project.name.toLowerCase().contains(query))
          project,
    ];
    int compare(ProjectSummary a, ProjectSummary b) {
      final byKey = switch (_view.sortKey) {
        ProjectSortKey.name => a.name.toLowerCase().compareTo(
          b.name.toLowerCase(),
        ),
        ProjectSortKey.lastActivity =>
          (a.lastActivityUtc ?? DateTime.utc(0)).compareTo(
            b.lastActivityUtc ?? DateTime.utc(0),
          ),
      };
      return _view.descending ? -byKey : byKey;
    }

    return projects..sort(compare);
  }

  List<String> get _projectNames => [
    for (final project in _projects ?? const <ProjectSummary>[]) project.name,
  ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

  void _showMessage(String message, {ProjectRulesSnapshot? undo}) {
    ScaffoldMessenger.maybeOf(context)
      ?..removeCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 8),
          action: undo == null
              ? null
              : SnackBarAction(label: 'Undo', onPressed: () => _undo(undo)),
        ),
      );
  }

  /// Runs an edit, refreshes, and offers Undo.
  Future<void> _edit(
    Future<ProjectRulesSnapshot> Function() run,
    String message, {
    String? selectName,
  }) async {
    if (_busy) {
      return;
    }
    setState(() => _busy = true);
    try {
      final before = await run();
      widget.onProjectsChanged?.call();
      await _reload(selectName: selectName);
      _showMessage(message, undo: before);
    } on Object catch (error) {
      _showMessage('Could not change the project. $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _undo(ProjectRulesSnapshot snapshot) async {
    setState(() => _busy = true);
    try {
      await widget.repository.restore(snapshot);
      widget.onProjectsChanged?.call();
      await _reload();
      _showMessage('Change undone.');
    } on Object catch (error) {
      _showMessage('Could not undo the change. $error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _addRule() async {
    final project = _selected;
    if (project == null || _busy) {
      return;
    }
    final folder = await showFolderRuleDialog(
      context,
      title: 'Add folder rule',
      confirmLabel: 'Add rule',
      message:
          'Sessions from this folder and its subfolders will belong to '
          '"${project.name}".',
      pickDirectory: widget.pickDirectory,
    );
    if (folder == null) {
      return;
    }
    await _edit(
      () => widget.repository.addFolderRule(
        folder: folder,
        projectName: project.name,
      ),
      'Sessions from $folder now belong to "${project.name}".',
    );
  }

  Future<void> _changeRuleFolder(ProjectRuleUsage rule) async {
    final project = _selected;
    if (project == null || _busy) {
      return;
    }
    final folder = await showFolderRuleDialog(
      context,
      title: 'Change folder',
      confirmLabel: 'Save',
      initialFolder: rule.folder,
      pickDirectory: widget.pickDirectory,
    );
    if (folder == null || folder == rule.folder) {
      return;
    }
    await _edit(
      () => widget.repository.changeFolderRule(
        oldFolder: rule.folder,
        newFolder: folder,
        projectName: project.name,
      ),
      'The rule now covers $folder.',
    );
  }

  Future<void> _moveFolder(String folder, {required bool isRule}) async {
    final project = _selected;
    if (project == null || _busy) {
      return;
    }
    final target = await showProjectPickerDialog(
      context,
      title: isRule ? 'Move rule to project' : 'Merge folder into project',
      confirmLabel: isRule ? 'Move' : 'Merge',
      message:
          'Sessions from $folder and its subfolders, now and in the future, '
          'will belong to the project you pick.',
      projectNames: _projectNames,
      excludeName: project.name,
    );
    if (target == null) {
      return;
    }
    await _edit(
      () => isRule
          ? widget.repository.moveFolderRule(
              folder: folder,
              projectName: target,
            )
          : widget.repository.addFolderRule(
              folder: folder,
              projectName: target,
            ),
      'Sessions from $folder now belong to "$target".',
    );
  }

  Future<void> _removeRule(ProjectRuleUsage rule) async {
    if (_busy) {
      return;
    }
    await _edit(
      () => widget.repository.removeFolderRule(rule.folder),
      'Removed the folder rule for ${rule.folder}.',
    );
  }

  Future<void> _mergeProject() async {
    final project = _selected;
    final detail = _detail;
    if (project == null || detail == null || _busy) {
      return;
    }
    final parts = [
      if (detail.detectedFolders.isNotEmpty)
        _count(detail.detectedFolders.length, 'detected folder'),
      if (detail.rules.isNotEmpty) _count(detail.rules.length, 'folder rule'),
      if (detail.manualSessionCount > 0)
        _count(
          detail.manualSessionCount,
          'session moved by hand',
          plural: 'sessions moved by hand',
        ),
    ];
    final target = await showProjectPickerDialog(
      context,
      title: 'Merge "${project.name}" into…',
      confirmLabel: 'Merge',
      message: parts.isEmpty
          ? 'Everything in "${project.name}" will belong to the project you '
                'pick.'
          : 'Its ${_joinList(parts)} will point at the project you pick, '
                'and future sessions from those folders follow.',
      projectNames: _projectNames,
      excludeName: project.name,
    );
    if (target == null) {
      return;
    }
    await _edit(
      () => widget.repository.mergeProject(
        sourceProjectId: project.id,
        targetName: target,
      ),
      'Merged "${project.name}" into "$target".',
      selectName: target,
    );
  }

  Future<void> _resetManual() async {
    final project = _selected;
    final detail = _detail;
    if (project == null || detail == null || _busy) {
      return;
    }
    await _edit(
      () => widget.repository.resetManualSessions(project.id),
      '${_count(detail.manualSessionCount, 'session')} follow their folders '
      'again.',
    );
  }

  void _toggleDirection() {
    setState(() => _view.descending = !_view.descending);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final projects = _projects;
    final visible = _visibleProjects;
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
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
              unawaited(_addRule()),
        },
        child: Focus(
          autofocus: true,
          skipTraversal: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Row(
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        'Projects',
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    const SizedBox(width: 12),
                    if (projects != null)
                      Text(
                        visible.length == projects.length
                            ? _count(projects.length, 'project')
                            : '${visible.length} of ${projects.length} shown',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 280,
                      child: TextField(
                        controller: _searchController,
                        focusNode: _searchFocusNode,
                        decoration: const InputDecoration(
                          labelText: 'Search projects (Ctrl+F)',
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                        ),
                        onChanged: (value) =>
                            setState(() => _view.query = value),
                      ),
                    ),
                    SegmentedButton<ProjectSortKey>(
                      segments: const [
                        ButtonSegment(
                          value: ProjectSortKey.name,
                          label: Text('Name'),
                        ),
                        ButtonSegment(
                          value: ProjectSortKey.lastActivity,
                          label: Text('Last activity'),
                        ),
                      ],
                      selected: {_view.sortKey},
                      showSelectedIcon: false,
                      // Each key starts in its natural order: A to Z,
                      // newest first.
                      onSelectionChanged: (selection) => setState(() {
                        _view.sortKey = selection.single;
                        _view.descending =
                            selection.single == ProjectSortKey.lastActivity;
                      }),
                    ),
                    Tooltip(
                      message: 'Reverse the order',
                      child: AppButton.outlined(
                        onPressed: _toggleDirection,
                        icon: Icon(
                          _view.descending
                              ? Icons.arrow_downward
                              : Icons.arrow_upward,
                        ),
                        label: Text(_directionLabel),
                      ),
                    ),
                  ],
                ),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              Divider(height: 1, color: theme.colorScheme.outlineVariant),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final listWidth = (constraints.maxWidth * 0.36).clamp(
                      280.0,
                      440.0,
                    );
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          width: listWidth,
                          child: _buildList(context, visible),
                        ),
                        VerticalDivider(
                          width: 1,
                          color: theme.colorScheme.outlineVariant,
                        ),
                        Expanded(child: _buildDetail(context)),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _directionLabel => switch ((_view.sortKey, _view.descending)) {
    (ProjectSortKey.name, false) => 'A to Z',
    (ProjectSortKey.name, true) => 'Z to A',
    (ProjectSortKey.lastActivity, true) => 'Newest first',
    (ProjectSortKey.lastActivity, false) => 'Oldest first',
  };

  Widget _buildList(BuildContext context, List<ProjectSummary> visible) {
    if (_loadError != null) {
      return _Message(
        text: 'Could not load projects. $_loadError',
        action: AppButton.outlined(
          onPressed: _reload,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      );
    }
    if (_projects == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (visible.isEmpty) {
      return _Message(
        text: _projects!.isEmpty
            ? 'No projects yet. Projects appear after a scan finds sessions.'
            : 'No project matches "${_view.query.trim()}".',
      );
    }
    final now = widget.now().toUtc();
    return Semantics(
      label: 'Projects list',
      container: true,
      child: ListView.builder(
        itemCount: visible.length,
        itemBuilder: (context, index) {
          final project = visible[index];
          final details = [
            _count(project.sessionCount, 'session'),
            if (project.folderRuleCount > 0)
              _count(project.folderRuleCount, 'folder rule'),
            if (project.manualSessionCount > 0)
              '${project.manualSessionCount} set by hand',
          ].join(' · ');
          final activity = _activityLabel(project.lastActivityUtc, now);
          return ListTile(
            key: ValueKey('project-${project.id}'),
            selected: project.id == _view.selectedProjectId,
            selectedTileColor: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.08),
            title: Text(project.name, overflow: TextOverflow.ellipsis),
            subtitle: Text(details),
            trailing: Text(
              activity,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            onTap: () => _select(project.id),
          );
        },
      ),
    );
  }

  Widget _buildDetail(BuildContext context) {
    final project = _selected;
    if (project == null) {
      return const _Message(
        text:
            'Select a project to see its folder rules and where its '
            'sessions come from.',
      );
    }
    final detail = _detail;
    if (detail == null || detail.projectId != project.id) {
      return const Center(child: CircularProgressIndicator());
    }
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(project.name, style: theme.textTheme.titleLarge),
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    _count(project.sessionCount, 'session'),
                    'last active '
                        '${_activityLabel(project.lastActivityUtc, widget.now().toUtc())}',
                  ].join(' · '),
                  style: muted,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    AppButton.filled(
                      onPressed: _busy ? null : _addRule,
                      icon: const Icon(Icons.create_new_folder_outlined),
                      label: const Text('Add folder rule… (Ctrl+N)'),
                    ),
                    AppButton.outlined(
                      onPressed: _busy ? null : _mergeProject,
                      icon: const Icon(Icons.merge),
                      label: const Text('Merge into…'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                _SectionHeader(
                  title: 'Folder rules',
                  description:
                      'Sessions from these folders and their subfolders '
                      'belong to this project. The most specific folder wins.',
                ),
              ],
            ),
          ),
        ),
        if (detail.rules.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Text(
                'No folder rules. Sessions land here by the folder they '
                'were detected from.',
                style: muted,
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: detail.rules.length,
            itemBuilder: (context, index) {
              final rule = detail.rules[index];
              return _RuleTile(
                rule: rule,
                enabled: !_busy,
                onChangeFolder: () => _changeRuleFolder(rule),
                onMove: () => _moveFolder(rule.folder, isRule: true),
                onRemove: () => _removeRule(rule),
              );
            },
          ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
          sliver: SliverToBoxAdapter(
            child: _SectionHeader(
              title: 'Detected from',
              description:
                  'Folders whose sessions were placed in this project '
                  'automatically. Merge one to send its sessions elsewhere.',
            ),
          ),
        ),
        if (detail.detectedFolders.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Text(
                'No sessions were detected in this project.',
                style: muted,
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: detail.detectedFolders.length,
            itemBuilder: (context, index) {
              final folder = detail.detectedFolders[index];
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder.folder),
                subtitle: Text(_count(folder.sessionCount, 'session')),
                trailing: AppButton.text(
                  onPressed: _busy
                      ? null
                      : () => _moveFolder(folder.folder, isRule: false),
                  icon: const Icon(Icons.merge),
                  label: const Text('Merge into…'),
                ),
              );
            },
          ),
        if (detail.manualSessionCount > 0)
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 0),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SectionHeader(
                    title: 'Set by hand',
                    description:
                        '${_count(detail.manualSessionCount, 'session')} '
                        '${detail.manualSessionCount == 1 ? 'was' : 'were'} '
                        'moved here by hand and ignore folder rules.',
                  ),
                  const SizedBox(height: 8),
                  AppButton.outlined(
                    onPressed: _busy ? null : _resetManual,
                    icon: const Icon(Icons.undo),
                    label: const Text('Reset all to automatic'),
                  ),
                ],
              ),
            ),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, required this.description});

  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Text(title, style: theme.textTheme.titleMedium),
        ),
        const SizedBox(height: 2),
        Text(
          description,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

enum _RuleAction { changeFolder, move, remove }

class _RuleTile extends StatelessWidget {
  const _RuleTile({
    required this.rule,
    required this.enabled,
    required this.onChangeFolder,
    required this.onMove,
    required this.onRemove,
  });

  final ProjectRuleUsage rule;
  final bool enabled;
  final VoidCallback onChangeFolder;
  final VoidCallback onMove;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warnings = [
      for (final entry in rule.overriddenBy.entries)
        '${_count(entry.value, 'session')} from here go to '
            '"${entry.key.projectName}" by the more specific rule for '
            '${entry.key.folder}.',
    ];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.delete): () {
          if (enabled) {
            onRemove();
          }
        },
      },
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 20),
        leading: const Icon(Icons.rule_folder_outlined),
        title: Text(rule.folder),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              rule.sessionCount == 0
                  ? 'Places no sessions yet'
                  : 'Places ${_count(rule.sessionCount, 'session')}',
            ),
            for (final warning in warnings)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: theme.colorScheme.tertiary,
                    ),
                    const SizedBox(width: 4),
                    Expanded(child: Text(warning)),
                  ],
                ),
              ),
          ],
        ),
        onTap: enabled ? onChangeFolder : null,
        trailing: PopupMenuButton<_RuleAction>(
          tooltip: 'Actions for the rule for ${rule.folder}',
          enabled: enabled,
          onSelected: (action) => switch (action) {
            _RuleAction.changeFolder => onChangeFolder(),
            _RuleAction.move => onMove(),
            _RuleAction.remove => onRemove(),
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: _RuleAction.changeFolder,
              child: Text('Change folder…'),
            ),
            PopupMenuItem(
              value: _RuleAction.move,
              child: Text('Move to project…'),
            ),
            PopupMenuItem(
              value: _RuleAction.remove,
              child: Text('Remove rule (Delete)'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.text, this.action});

  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(text, textAlign: TextAlign.center),
            if (action case final action?) ...[
              const SizedBox(height: 12),
              action,
            ],
          ],
        ),
      ),
    );
  }
}

String _count(int count, String singular, {String? plural}) =>
    '$count ${count == 1 ? singular : plural ?? '${singular}s'}';

String _joinList(List<String> parts) {
  if (parts.length < 2) {
    return parts.join();
  }
  return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
}

String _activityLabel(DateTime? utc, DateTime nowUtc) {
  if (utc == null) {
    return 'never';
  }
  final elapsed = nowUtc.difference(utc);
  if (elapsed.inMinutes < 1) {
    return 'just now';
  }
  if (elapsed.inHours < 1) {
    return '${elapsed.inMinutes}m ago';
  }
  if (elapsed.inDays < 1) {
    return '${elapsed.inHours}h ago';
  }
  if (elapsed.inDays < 7) {
    return '${_count(elapsed.inDays, 'day')} ago';
  }
  final local = utc.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}
