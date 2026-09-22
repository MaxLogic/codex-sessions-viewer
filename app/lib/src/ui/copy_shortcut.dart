import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Whether Ctrl+C belongs to the focused text: a text field or selectable
/// text. Inside a selection area it does only when [textSelected], or when
/// the caller cannot tell ([textSelected] null).
bool focusedTextOwnsCopy({bool? textSelected}) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) {
    return false;
  }
  if (context.widget is EditableText ||
      context.findAncestorWidgetOfExactType<EditableText>() != null) {
    return true;
  }
  if (context.findAncestorStateOfType<SelectableRegionState>() != null) {
    return textSelected ?? true;
  }
  return false;
}

/// Calls [onCopy] for Ctrl+C pressed while focus is inside [child].
/// [onCopy] returns false to leave the key to the default copy handling.
class CopyShortcut extends StatelessWidget {
  const CopyShortcut({
    super.key,
    required this.onCopy,
    this.focusNode,
    this.autofocus = false,
    required this.child,
  });

  final bool Function() onCopy;
  final FocusNode? focusNode;
  final bool autofocus;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: focusNode,
      autofocus: autofocus,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        final keyboard = HardwareKeyboard.instance;
        if (event is! KeyDownEvent ||
            event.logicalKey != LogicalKeyboardKey.keyC ||
            !keyboard.isControlPressed ||
            keyboard.isShiftPressed ||
            keyboard.isAltPressed ||
            keyboard.isMetaPressed) {
          return KeyEventResult.ignored;
        }
        return onCopy() ? KeyEventResult.handled : KeyEventResult.ignored;
      },
      child: child,
    );
  }
}
