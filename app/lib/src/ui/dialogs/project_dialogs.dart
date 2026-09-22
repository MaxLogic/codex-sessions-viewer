import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

/// Picks a folder for a folder rule. Returns null when the user cancels.
Future<String?> showFolderRuleDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  String initialFolder = '',
  String? message,
  Future<String?> Function()? pickDirectory,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _FolderRuleDialog(
      title: title,
      confirmLabel: confirmLabel,
      initialFolder: initialFolder,
      message: message,
      pickDirectory: pickDirectory ?? () => getDirectoryPath(),
    ),
  );
}

class _FolderRuleDialog extends StatefulWidget {
  const _FolderRuleDialog({
    required this.title,
    required this.confirmLabel,
    required this.initialFolder,
    required this.message,
    required this.pickDirectory,
  });

  final String title;
  final String confirmLabel;
  final String initialFolder;
  final String? message;
  final Future<String?> Function() pickDirectory;

  @override
  State<_FolderRuleDialog> createState() => _FolderRuleDialogState();
}

class _FolderRuleDialogState extends State<_FolderRuleDialog> {
  late final _folder = TextEditingController(text: widget.initialFolder);

  @override
  void initState() {
    super.initState();
    _folder.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _folder.dispose();
    super.dispose();
  }

  void _confirm() {
    final folder = _folder.text.trim();
    if (folder.isNotEmpty) {
      Navigator.of(context).pop(folder);
    }
  }

  Future<void> _browse() async {
    final picked = await widget.pickDirectory();
    if (picked != null && mounted) {
      _folder.text = picked;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.message case final message?) ...[
              Text(message),
              const SizedBox(height: 16),
            ],
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _folder,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'Folder',
                      helperText: 'Includes its subfolders.',
                    ),
                    onSubmitted: (_) => _confirm(),
                  ),
                ),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton(
                    onPressed: _browse,
                    child: const Text('Browse…'),
                  ),
                ),
              ],
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
          onPressed: _folder.text.trim().isEmpty ? null : _confirm,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// Picks an existing project or names a new one. Returns null when the user
/// cancels.
Future<String?> showProjectPickerDialog(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required List<String> projectNames,
  String? message,
  String? excludeName,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _ProjectPickerDialog(
      title: title,
      confirmLabel: confirmLabel,
      projectNames: [
        for (final name in projectNames)
          if (name != excludeName) name,
      ],
      message: message,
      excludeName: excludeName,
    ),
  );
}

class _ProjectPickerDialog extends StatefulWidget {
  const _ProjectPickerDialog({
    required this.title,
    required this.confirmLabel,
    required this.projectNames,
    required this.message,
    required this.excludeName,
  });

  final String title;
  final String confirmLabel;
  final List<String> projectNames;
  final String? message;
  final String? excludeName;

  @override
  State<_ProjectPickerDialog> createState() => _ProjectPickerDialogState();
}

class _ProjectPickerDialogState extends State<_ProjectPickerDialog> {
  var _name = '';

  String get _target => _name.trim();

  bool get _isCurrent => _target == widget.excludeName;

  bool get _canConfirm => _target.isNotEmpty && !_isCurrent;

  void _confirm() {
    if (_canConfirm) {
      Navigator.of(context).pop(_target);
    }
  }

  @override
  Widget build(BuildContext context) {
    final helper = _isCurrent
        ? 'That is the current project.'
        : _target.isNotEmpty && !widget.projectNames.contains(_target)
        ? 'Creates a new project named "$_target".'
        : 'Pick a project or type a new name.';
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.message case final message?) ...[
              Text(message),
              const SizedBox(height: 16),
            ],
            Autocomplete<String>(
              optionsBuilder: (value) {
                final query = value.text.trim().toLowerCase();
                return widget.projectNames.where(
                  (name) => name.toLowerCase().contains(query),
                );
              },
              onSelected: (name) => setState(() => _name = name),
              fieldViewBuilder:
                  (context, controller, focusNode, onFieldSubmitted) {
                    return TextField(
                      controller: controller,
                      focusNode: focusNode,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: 'Project',
                        helperText: helper,
                      ),
                      onChanged: (value) => setState(() => _name = value),
                      onSubmitted: (_) {
                        onFieldSubmitted();
                        _confirm();
                      },
                    );
                  },
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
          onPressed: _canConfirm ? _confirm : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
