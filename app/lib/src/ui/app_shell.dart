import 'package:flutter/material.dart';

typedef SessionsScreenBuilder =
    Widget Function(BuildContext context, VoidCallback onOpenSettings);

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
  const CodexAppShell({
    super.key,
    this.title = 'Codex Session Viewer',
    required this.sessionsScreenBuilder,
    required this.usageScreen,
    required this.settingsScreen,
    required this.logsScreen,
  });

  final String title;
  final SessionsScreenBuilder sessionsScreenBuilder;
  final Widget usageScreen;
  final Widget settingsScreen;
  final Widget logsScreen;

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
            Expanded(
              child: _SectionContent(
                section: section,
                sessionsScreenBuilder: widget.sessionsScreenBuilder,
                usageScreen: widget.usageScreen,
                settingsScreen: widget.settingsScreen,
                logsScreen: widget.logsScreen,
                onOpenSettings: () {
                  setState(() {
                    _selectedIndex = CodexAppSection.settings.index;
                  });
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionContent extends StatelessWidget {
  const _SectionContent({
    required this.section,
    required this.sessionsScreenBuilder,
    required this.usageScreen,
    required this.settingsScreen,
    required this.logsScreen,
    required this.onOpenSettings,
  });

  final CodexAppSection section;
  final SessionsScreenBuilder sessionsScreenBuilder;
  final Widget usageScreen;
  final Widget settingsScreen;
  final Widget logsScreen;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    if (section == CodexAppSection.sessions) {
      return sessionsScreenBuilder(context, onOpenSettings);
    }
    if (section == CodexAppSection.usage) {
      return usageScreen;
    }
    if (section == CodexAppSection.settings) {
      return settingsScreen;
    }
    if (section == CodexAppSection.logs) {
      return logsScreen;
    }
    throw StateError('Unsupported app section: $section');
  }
}
