import 'package:flutter/material.dart';

/// A popup menu caption, such as the harness above a session's actions.
///
/// Unlike a disabled [PopupMenuItem] it is not a menu item: it takes no
/// keyboard focus and screen readers read it as a header, not as an
/// unavailable command.
class MenuHeaderEntry<T> extends PopupMenuEntry<T> {
  const MenuHeaderEntry(this.label, {super.key});

  final String label;

  @override
  double get height => 36;

  @override
  bool represents(T? value) => false;

  @override
  State<MenuHeaderEntry<T>> createState() => _MenuHeaderEntryState<T>();
}

class _MenuHeaderEntryState<T> extends State<MenuHeaderEntry<T>> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Container(
        height: widget.height,
        alignment: AlignmentDirectional.centerStart,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          widget.label,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
