import 'package:flutter/material.dart';

/// The "Show icons" and "Show text on buttons" settings, provided above the
/// app so every [AppButton] follows them.
class ButtonAppearance extends InheritedWidget {
  const ButtonAppearance({
    super.key,
    required this.showIcons,
    required this.showText,
    required super.child,
  });

  final bool showIcons;
  final bool showText;

  static const _defaults = (showIcons: true, showText: true);

  static ({bool showIcons, bool showText}) of(BuildContext context) {
    final appearance = context
        .dependOnInheritedWidgetOfExactType<ButtonAppearance>();
    if (appearance == null) {
      return _defaults;
    }
    // A button always keeps something visible.
    if (!appearance.showIcons && !appearance.showText) {
      return (showIcons: false, showText: true);
    }
    return (showIcons: appearance.showIcons, showText: appearance.showText);
  }

  @override
  bool updateShouldNotify(ButtonAppearance oldWidget) =>
      showIcons != oldWidget.showIcons || showText != oldWidget.showText;
}

enum _AppButtonKind { outlined, text, filled, elevated }

/// An icon-and-label button that honors [ButtonAppearance]. Without text it
/// becomes an icon button whose label is its tooltip and accessible name.
class AppButton extends StatelessWidget {
  const AppButton.outlined({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.style,
    this.autofocus = false,
    this.focusNode,
  }) : _kind = _AppButtonKind.outlined;

  const AppButton.text({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.style,
    this.autofocus = false,
    this.focusNode,
  }) : _kind = _AppButtonKind.text;

  const AppButton.filled({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.style,
    this.autofocus = false,
    this.focusNode,
  }) : _kind = _AppButtonKind.filled;

  const AppButton.elevated({
    super.key,
    required this.onPressed,
    required this.icon,
    required this.label,
    this.style,
    this.autofocus = false,
    this.focusNode,
  }) : _kind = _AppButtonKind.elevated;

  final VoidCallback? onPressed;
  final Widget icon;
  final Widget label;
  final ButtonStyle? style;
  final bool autofocus;
  final FocusNode? focusNode;
  final _AppButtonKind _kind;

  @override
  Widget build(BuildContext context) {
    final appearance = ButtonAppearance.of(context);
    if (appearance.showIcons && appearance.showText) {
      return switch (_kind) {
        _AppButtonKind.outlined => OutlinedButton.icon(
          onPressed: onPressed,
          style: style,
          autofocus: autofocus,
          focusNode: focusNode,
          icon: icon,
          label: label,
        ),
        _AppButtonKind.text => TextButton.icon(
          onPressed: onPressed,
          style: style,
          autofocus: autofocus,
          focusNode: focusNode,
          icon: icon,
          label: label,
        ),
        _AppButtonKind.filled => FilledButton.icon(
          onPressed: onPressed,
          style: style,
          autofocus: autofocus,
          focusNode: focusNode,
          icon: icon,
          label: label,
        ),
        _AppButtonKind.elevated => ElevatedButton.icon(
          onPressed: onPressed,
          style: style,
          autofocus: autofocus,
          focusNode: focusNode,
          icon: icon,
          label: label,
        ),
      };
    }
    if (!appearance.showIcons) {
      return _plain(label);
    }
    final text = _labelText(label);
    if (text == null) {
      // Without a plain text label there is nothing to name the icon with.
      return _plain(label);
    }
    // The label merges into the button's own semantics node, so the button
    // keeps its focus and tap actions; the tooltip is visual only.
    return Tooltip(
      message: text,
      excludeFromSemantics: true,
      child: _plain(Semantics(label: text, child: icon)),
    );
  }

  Widget _plain(Widget child) {
    return switch (_kind) {
      _AppButtonKind.outlined => OutlinedButton(
        onPressed: onPressed,
        style: style,
        autofocus: autofocus,
        focusNode: focusNode,
        child: child,
      ),
      _AppButtonKind.text => TextButton(
        onPressed: onPressed,
        style: style,
        autofocus: autofocus,
        focusNode: focusNode,
        child: child,
      ),
      _AppButtonKind.filled => FilledButton(
        onPressed: onPressed,
        style: style,
        autofocus: autofocus,
        focusNode: focusNode,
        child: child,
      ),
      _AppButtonKind.elevated => ElevatedButton(
        onPressed: onPressed,
        style: style,
        autofocus: autofocus,
        focusNode: focusNode,
        child: child,
      ),
    };
  }

  static String? _labelText(Widget label) {
    if (label is Text) {
      return label.data ?? label.textSpan?.toPlainText();
    }
    return null;
  }
}
