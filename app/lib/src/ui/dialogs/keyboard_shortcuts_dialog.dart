import 'package:flutter/material.dart';

/// One keyboard shortcut and what it does.
class KeyboardShortcut {
  const KeyboardShortcut(this.keys, this.action);

  /// Key combinations, for example `['Ctrl', 'F']`; alternatives are
  /// separate entries in [KeyboardShortcutGroup.shortcuts].
  final List<String> keys;
  final String action;

  String get keysLabel => keys.join('+');
}

class KeyboardShortcutGroup {
  const KeyboardShortcutGroup(this.title, this.shortcuts, {this.note});

  final String title;
  final List<KeyboardShortcut> shortcuts;
  final String? note;
}

/// Every shortcut the app handles, grouped by where it applies. Keep this list
/// in sync with the key bindings in the screens.
const keyboardShortcutGroups = [
  KeyboardShortcutGroup('Anywhere', [
    KeyboardShortcut(['F1'], 'Show this list of keyboard shortcuts'),
    KeyboardShortcut(['Tab'], 'Move to the next control'),
    KeyboardShortcut(['Shift', 'Tab'], 'Move to the previous control'),
    KeyboardShortcut(['Enter'], 'Activate the focused button or row'),
    KeyboardShortcut(['Escape'], 'Close a menu or dialog'),
  ]),
  KeyboardShortcutGroup('Sessions', [
    KeyboardShortcut(['Ctrl', 'F'], 'Search sessions'),
    KeyboardShortcut(['Ctrl', 'L'], 'Go to the session filters'),
    KeyboardShortcut(['Ctrl', 'E'], 'Export the selected session as Markdown'),
    KeyboardShortcut(['Ctrl', 'C'], "Copy the selected session's path"),
    KeyboardShortcut(['F5'], 'Refresh sessions from disk'),
    KeyboardShortcut(['Click column'], 'Sort by that column'),
    KeyboardShortcut(['Shift', 'Click column'], 'Add a secondary sort'),
    KeyboardShortcut([
      'Ctrl',
      'Click column',
    ], 'Remove that column from sorting'),
  ]),
  KeyboardShortcutGroup('Projects', [
    KeyboardShortcut(['Ctrl', 'F'], 'Search projects'),
    KeyboardShortcut([
      'Ctrl',
      'N',
    ], 'Add a folder rule to the selected project'),
    KeyboardShortcut(['Delete'], 'Remove the focused folder rule'),
  ], note: 'Every change shows Undo for a few seconds.'),
  KeyboardShortcutGroup(
    'Conversation',
    [
      KeyboardShortcut(['Ctrl', 'F'], 'Find in the conversation'),
      KeyboardShortcut([
        'Ctrl',
        'C',
      ], 'Copy the selected message as Markdown, or the selected text'),
      KeyboardShortcut(['Enter'], 'Next match (in the find box)'),
      KeyboardShortcut(['Shift', 'Enter'], 'Previous match (in the find box)'),
      KeyboardShortcut(['F3'], 'Next match'),
      KeyboardShortcut(['Shift', 'F3'], 'Previous match'),
      KeyboardShortcut(['Escape'], 'Clear the find box, then leave it'),
    ],
    note:
        'Ctrl+F and Ctrl+C act on the conversation when focus is inside it. '
        'In a command preview, Ctrl+C copies the whole command.',
  ),
  KeyboardShortcutGroup('Focus reader', [
    KeyboardShortcut(['N'], 'Next message'),
    KeyboardShortcut(['P'], 'Previous message'),
    KeyboardShortcut(['U'], 'Next user message'),
    KeyboardShortcut(['Shift', 'U'], 'Previous user message'),
    KeyboardShortcut(['A'], 'Next assistant message'),
    KeyboardShortcut(['Shift', 'A'], 'Previous assistant message'),
    KeyboardShortcut(['T'], 'Next tool message'),
    KeyboardShortcut(['Shift', 'T'], 'Previous tool message'),
    KeyboardShortcut(['E'], 'Next tool call or error'),
    KeyboardShortcut(['Shift', 'E'], 'Previous tool call or error'),
    KeyboardShortcut(['X'], 'Expand or collapse tool output'),
    KeyboardShortcut(['M'], 'Copy the message as Markdown'),
    KeyboardShortcut(['C'], 'Copy the message text'),
  ], note: 'These keys work while the focus reader has focus.'),
];

Future<void> showKeyboardShortcutsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const KeyboardShortcutsDialog(),
  );
}

class KeyboardShortcutsDialog extends StatelessWidget {
  const KeyboardShortcutsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Keyboard shortcuts'),
      content: SizedBox(
        width: 560,
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: keyboardShortcutGroups.length,
          itemBuilder: (context, index) {
            final group = keyboardShortcutGroups[index];
            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Semantics(
                    header: true,
                    child: Text(group.title, style: theme.textTheme.titleSmall),
                  ),
                  if (group.note case final note?)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        note,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(height: 6),
                  for (final shortcut in group.shortcuts)
                    _ShortcutRow(shortcut: shortcut),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        FilledButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.shortcut});

  final KeyboardShortcut shortcut;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '${shortcut.keysLabel}: ${shortcut.action}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 190,
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final key in shortcut.keys) _KeyCap(label: key),
                  ],
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    shortcut.action,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelMedium?.copyWith(fontFamily: 'Consolas'),
      ),
    );
  }
}
