import 'package:flutter/material.dart';

import '../config/app_settings.dart';
import 'motion.dart';

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
    this.motionMode = AppMotionMode.system,
  });

  final String title;
  final SessionsScreenBuilder sessionsScreenBuilder;
  final Widget usageScreen;
  final Widget settingsScreen;
  final Widget logsScreen;
  final AppMotionMode motionMode;

  @override
  State<CodexAppShell> createState() => _CodexAppShellState();
}

class _CodexAppShellState extends State<CodexAppShell> {
  var _selectedIndex = 0;
  var _previousIndex = 0;

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
                    _previousIndex = _selectedIndex;
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
                motionMode: widget.motionMode,
                previousIndex: _previousIndex,
                onOpenSettings: () {
                  setState(() {
                    _previousIndex = _selectedIndex;
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
    required this.motionMode,
    required this.previousIndex,
    required this.onOpenSettings,
  });

  final CodexAppSection section;
  final SessionsScreenBuilder sessionsScreenBuilder;
  final Widget usageScreen;
  final Widget settingsScreen;
  final Widget logsScreen;
  final AppMotionMode motionMode;
  final int previousIndex;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final policy = CodexMotionPolicy.fromContext(context, mode: motionMode);
    final direction = section.index >= previousIndex
        ? AxisDirection.left
        : AxisDirection.right;
    return AnimatedSwitcher(
      duration: policy.pageDuration,
      reverseDuration: policy.pageDuration,
      switchInCurve: policy.standardCurve,
      switchOutCurve: policy.emphasizedCurve,
      transitionBuilder: (child, animation) => CodexMotion.pageFadeSlide(
        policy: policy,
        animation: animation,
        direction: direction,
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
        key: ValueKey(section),
        child: _buildSection(context),
      ),
    );
  }

  Widget _buildSection(BuildContext context) {
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
