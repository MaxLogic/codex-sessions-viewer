import 'package:flutter/material.dart';

import 'screens/sessions_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/usage_screen.dart';

enum CodexAppSection {
  sessions('Sessions', Icons.history),
  usage('Usage', Icons.query_stats),
  settings('Settings', Icons.settings),
  logs('Logs', Icons.list_alt);

  const CodexAppSection(this.label, this.icon);

  final String label;
  final IconData icon;
}

class CodexAppShell extends StatefulWidget {
  const CodexAppShell({super.key, this.title = 'Codex Session Viewer'});

  final String title;

  @override
  State<CodexAppShell> createState() => _CodexAppShellState();
}

class _CodexAppShellState extends State<CodexAppShell> {
  var _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final section = CodexAppSection.values[_selectedIndex];
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            FocusTraversalGroup(
              child: NavigationRail(
                selectedIndex: _selectedIndex,
                labelType: NavigationRailLabelType.all,
                minWidth: 116,
                leading: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
                  child: Text(
                    widget.title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                onDestinationSelected: (index) {
                  setState(() {
                    _selectedIndex = index;
                  });
                },
                destinations: [
                  for (final item in CodexAppSection.values)
                    NavigationRailDestination(
                      icon: Semantics(
                        button: true,
                        label: '${item.label} navigation',
                        child: Icon(item.icon),
                      ),
                      selectedIcon: Semantics(
                        button: true,
                        label: '${item.label} navigation',
                        selected: true,
                        child: Icon(item.icon),
                      ),
                      label: Semantics(
                        button: true,
                        label: '${item.label} navigation',
                        child: Text(item.label),
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
            Expanded(child: _SectionContent(section: section)),
          ],
        ),
      ),
    );
  }
}

class _SectionContent extends StatelessWidget {
  const _SectionContent({required this.section});

  final CodexAppSection section;

  @override
  Widget build(BuildContext context) {
    if (section == CodexAppSection.sessions) {
      return const SessionsScreen();
    }
    if (section == CodexAppSection.usage) {
      return const UsageScreen();
    }
    if (section == CodexAppSection.settings) {
      return const SettingsScreen();
    }
    final scheme = Theme.of(context).colorScheme;
    return FocusTraversalGroup(
      child: Container(
        color: scheme.surface,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(section.label, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outline),
                ),
                child: SizedBox.expand(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(_placeholderText(section)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _placeholderText(CodexAppSection section) {
  return switch (section) {
    CodexAppSection.sessions => 'Session table',
    CodexAppSection.usage => 'Usage summary',
    CodexAppSection.settings => 'Settings form',
    CodexAppSection.logs => 'Log table',
  };
}
