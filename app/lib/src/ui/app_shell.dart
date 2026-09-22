import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_settings.dart';
import 'dialogs/keyboard_shortcuts_dialog.dart';
import 'motion.dart';
import 'widgets/app_button.dart';

typedef SessionsScreenBuilder =
    Widget Function(BuildContext context, VoidCallback onOpenSettings);

enum CodexAppSection {
  sessions('Sessions', Icons.history),
  projects('Projects', Icons.folder_copy_outlined),
  evals('Evals', Icons.fact_check),
  context('Context', Icons.manage_search),
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
    required this.projectsScreen,
    required this.evalsScreen,
    required this.contextScreen,
    required this.usageScreen,
    required this.settingsScreen,
    required this.logsScreen,
    this.requestedSection,
    this.sectionRequestSerial = 0,
    this.motionMode = AppMotionMode.system,
  });

  final String title;
  final SessionsScreenBuilder sessionsScreenBuilder;
  final Widget projectsScreen;
  final Widget evalsScreen;
  final Widget contextScreen;
  final Widget usageScreen;
  final Widget settingsScreen;
  final Widget logsScreen;
  final CodexAppSection? requestedSection;
  final int sectionRequestSerial;
  final AppMotionMode motionMode;

  @override
  State<CodexAppShell> createState() => _CodexAppShellState();
}

class _CodexAppShellState extends State<CodexAppShell> {
  var _selectedIndex = 0;
  var _previousIndex = 0;
  var _handledSectionRequestSerial = 0;
  var _shortcutsOpen = false;

  @override
  void initState() {
    super.initState();
    // A global handler so F1 works even before anything has focus.
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  bool _handleKey(KeyEvent event) {
    if (event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.f1) {
      return false;
    }
    unawaited(_showShortcuts());
    return true;
  }

  Future<void> _showShortcuts() async {
    if (_shortcutsOpen || !mounted) {
      return;
    }
    _shortcutsOpen = true;
    try {
      await showKeyboardShortcutsDialog(context);
    } finally {
      _shortcutsOpen = false;
    }
  }

  @override
  void didUpdateWidget(covariant CodexAppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    final requested = widget.requestedSection;
    if (requested != null &&
        widget.sectionRequestSerial != _handledSectionRequestSerial) {
      _handledSectionRequestSerial = widget.sectionRequestSerial;
      _previousIndex = _selectedIndex;
      _selectedIndex = requested.index;
    }
  }

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
                trailing: Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Tooltip(
                    message: 'Keyboard shortcuts (F1)',
                    child: AppButton.text(
                      onPressed: _showShortcuts,
                      icon: const Icon(Icons.keyboard_outlined),
                      label: const Text('Shortcuts'),
                    ),
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
                      // Let the rail merge its label, focus, and selected state.
                      icon: Icon(item.icon),
                      label: Text(
                        item.label,
                        semanticsLabel: '${item.label} navigation',
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
                projectsScreen: widget.projectsScreen,
                evalsScreen: widget.evalsScreen,
                contextScreen: widget.contextScreen,
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
    required this.projectsScreen,
    required this.evalsScreen,
    required this.contextScreen,
    required this.usageScreen,
    required this.settingsScreen,
    required this.logsScreen,
    required this.motionMode,
    required this.previousIndex,
    required this.onOpenSettings,
  });

  final CodexAppSection section;
  final SessionsScreenBuilder sessionsScreenBuilder;
  final Widget projectsScreen;
  final Widget evalsScreen;
  final Widget contextScreen;
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
    if (section == CodexAppSection.projects) {
      return projectsScreen;
    }
    if (section == CodexAppSection.evals) {
      return evalsScreen;
    }
    if (section == CodexAppSection.context) {
      return contextScreen;
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
