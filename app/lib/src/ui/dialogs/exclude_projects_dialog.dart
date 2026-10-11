import 'package:flutter/material.dart';

/// Changes are returned only on Apply; Cancel preserves the current view.
class ExcludeProjectsDialog extends StatefulWidget {
  const ExcludeProjectsDialog({
    super.key,
    required this.projects,
    required this.excludedProjects,
  });
  final List<String> projects;
  final Set<String> excludedProjects;
  @override
  State<ExcludeProjectsDialog> createState() => _ExcludeProjectsDialogState();
}

class _ExcludeProjectsDialogState extends State<ExcludeProjectsDialog> {
  late final Map<String, String> _names;
  late final Set<String> _selected;
  String _search = '';
  @override
  void initState() {
    super.initState();
    _names = {};
    for (final project in [...widget.excludedProjects, ...widget.projects]) {
      final name = project.trim();
      if (name.isNotEmpty) _names.putIfAbsent(name.toLowerCase(), () => name);
    }
    _selected = widget.excludedProjects
        .map((name) => name.trim().toLowerCase())
        .toSet();
  }

  @override
  Widget build(BuildContext context) {
    final projects = _names.keys.where((key) => key.contains(_search)).toList()
      ..sort();
    return AlertDialog(
      title: const Text('Exclude projects'),
      content: SizedBox(
        width: 440,
        height: (MediaQuery.sizeOf(context).height * 0.5).clamp(180, 420),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Search projects'),
              onChanged: (value) =>
                  setState(() => _search = value.trim().toLowerCase()),
            ),
            const SizedBox(height: 8),
            Text(
              '${_selected.length} projects excluded',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: projects.isEmpty
                  ? Center(
                      child: Text(
                        _names.isEmpty
                            ? 'No projects available.'
                            : 'No projects match your search.',
                      ),
                    )
                  : ListView.builder(
                      itemCount: projects.length,
                      itemBuilder: (context, index) {
                        final key = projects[index];
                        return CheckboxListTile(
                          title: Text(_names[key]!),
                          value: _selected.contains(key),
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: (checked) => setState(() {
                            if (checked == true) {
                              _selected.add(key);
                            } else {
                              _selected.remove(key);
                            }
                          }),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final keys = _selected.toList()..sort();
            Navigator.pop(context, {for (final key in keys) _names[key]!});
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
