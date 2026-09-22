import 'package:flutter/material.dart';

import '../../database/project_tag_state.dart';
import '../models/session_project_change.dart';

enum _MoveScope { session, folder }

/// Asks where a session belongs. Returns null when the user cancels.
Future<SessionProjectChange?> showMoveToProjectDialog(
  BuildContext context, {
  required SessionProjectAssignment assignment,
}) {
  return showDialog<SessionProjectChange>(
    context: context,
    builder: (context) => MoveToProjectDialog(assignment: assignment),
  );
}

class MoveToProjectDialog extends StatefulWidget {
  const MoveToProjectDialog({super.key, required this.assignment});

  final SessionProjectAssignment assignment;

  @override
  State<MoveToProjectDialog> createState() => _MoveToProjectDialogState();
}

class _MoveToProjectDialogState extends State<MoveToProjectDialog> {
  late final TextEditingController _folder;
  var _projectName = '';
  var _scope = _MoveScope.session;

  SessionProjectAssignment get _assignment => widget.assignment;

  @override
  void initState() {
    super.initState();
    _folder = TextEditingController(text: _assignment.workingDirectory ?? '');
    _folder.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  String get _target => _projectName.trim();

  bool get _isNewProject =>
      _target.isNotEmpty && !_assignment.projectNames.contains(_target);

  bool get _canMove =>
      _target.isNotEmpty &&
      (_scope == _MoveScope.session || _folder.text.trim().isNotEmpty);

  void _move() {
    if (!_canMove) {
      return;
    }
    Navigator.of(context).pop(switch (_scope) {
      _MoveScope.session => MoveSessionToProject(_target),
      _MoveScope.folder => MoveFolderToProject(
        folder: _folder.text.trim(),
        projectName: _target,
      ),
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasFolder = (_assignment.workingDirectory ?? '').isNotEmpty;
    return AlertDialog(
      title: const Text('Move to project'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CurrentAssignment(assignment: _assignment),
              const SizedBox(height: 20),
              Autocomplete<String>(
                optionsBuilder: (value) {
                  final query = value.text.trim().toLowerCase();
                  return _assignment.projectNames.where(
                    (name) => name.toLowerCase().contains(query),
                  );
                },
                onSelected: (name) => setState(() => _projectName = name),
                fieldViewBuilder:
                    (context, controller, focusNode, onFieldSubmitted) {
                      return TextField(
                        controller: controller,
                        focusNode: focusNode,
                        autofocus: true,
                        decoration: InputDecoration(
                          labelText: 'Project',
                          helperText: _isNewProject
                              ? 'Creates a new project named "$_target".'
                              : 'Pick a project or type a new name.',
                        ),
                        onChanged: (value) =>
                            setState(() => _projectName = value),
                        onSubmitted: (_) {
                          onFieldSubmitted();
                          _move();
                        },
                      );
                    },
              ),
              const SizedBox(height: 16),
              Text('Move', style: theme.textTheme.titleSmall),
              RadioGroup<_MoveScope>(
                groupValue: _scope,
                onChanged: (scope) => setState(() => _scope = scope!),
                child: Column(
                  children: [
                    const RadioListTile<_MoveScope>(
                      value: _MoveScope.session,
                      contentPadding: EdgeInsets.zero,
                      title: Text('Only this session'),
                    ),
                    RadioListTile<_MoveScope>(
                      value: _MoveScope.folder,
                      enabled: hasFolder,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Every session from a folder'),
                      subtitle: Text(
                        hasFolder
                            ? 'Includes subfolders and future sessions. '
                                  'Use it to merge a worktree into its '
                                  'main project.'
                            : 'This session has no working folder.',
                      ),
                    ),
                  ],
                ),
              ),
              if (_scope == _MoveScope.folder)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: TextField(
                    controller: _folder,
                    decoration: const InputDecoration(
                      labelText: 'Folder',
                      helperText:
                          'Shorten it to include sibling folders, for '
                          'example every worktree.',
                    ),
                    onSubmitted: (_) => _move(),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(
            context,
          ).pop(ManageProjectRules(_assignment.projectName)),
          child: const Text('Manage folder rules…'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canMove ? _move : null,
          child: const Text('Move'),
        ),
      ],
    );
  }
}

/// Says where the session is now and offers the matching undo.
class _CurrentAssignment extends StatelessWidget {
  const _CurrentAssignment({required this.assignment});

  final SessionProjectAssignment assignment;

  @override
  Widget build(BuildContext context) {
    final current = assignment.projectName;
    final rule = assignment.folderRule;
    final detected = assignment.detectedProjectName;
    final String description;
    SessionProjectChange? undo;
    String? undoLabel;
    if (assignment.isManual) {
      description = current == null
          ? 'This session was removed from its project by hand.'
          : 'In "$current", set by hand.';
      undo = const ResetSessionProject();
      undoLabel = rule != null
          ? 'Use the folder rule ("${rule.projectName}")'
          : detected != null
          ? 'Use the detected project ("$detected")'
          : 'Use the detected project';
    } else if (rule != null) {
      description =
          'In "${rule.projectName}" by the folder rule for ${rule.folder}.';
      undo = RemoveFolderRule(rule.folder);
      undoLabel = 'Remove folder rule';
    } else if (current != null) {
      description = 'In "$current", detected from its folder.';
    } else {
      description = 'This session has no project yet.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(description),
        if (undo != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(undo),
              child: Text(undoLabel!),
            ),
          ),
      ],
    );
  }
}
