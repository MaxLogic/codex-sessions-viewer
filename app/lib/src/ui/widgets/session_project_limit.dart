import 'package:flutter/material.dart';

/// Keeps draft input separate from the last valid, applied limit.
class SessionProjectLimit extends StatefulWidget {
  const SessionProjectLimit({
    super.key,
    required this.limit,
    required this.onChanged,
  });
  final int? limit;
  final ValueChanged<int?> onChanged;
  @override
  State<SessionProjectLimit> createState() => _SessionProjectLimitState();
}

class _SessionProjectLimitState extends State<SessionProjectLimit> {
  late final TextEditingController _controller;
  final _focusNode = FocusNode();
  late int _lastValid;
  String? _error;
  @override
  void initState() {
    super.initState();
    _lastValid = widget.limit ?? 1;
    _controller = TextEditingController(text: '$_lastValid');
    _focusNode.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(SessionProjectLimit oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.limit != widget.limit) {
      _lastValid = widget.limit ?? 1;
      _controller.text = '$_lastValid';
      _error = null;
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_focusChanged);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _focusChanged() {
    if (!_focusNode.hasFocus && widget.limit != null) _commit();
  }

  void _commit() {
    final value = int.tryParse(_controller.text.trim());
    if (value == null || value <= 0) {
      setState(() => _error = 'Enter a positive whole number.');
      return;
    }
    setState(() {
      _lastValid = value;
      _error = null;
    });
    if (value != widget.limit) widget.onChanged(value);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 290,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: const Text('Limit sessions per project'),
          value: widget.limit != null,
          onChanged: (checked) =>
              widget.onChanged(checked == true ? _lastValid : null),
        ),
        TextField(
          controller: _controller,
          focusNode: _focusNode,
          enabled: widget.limit != null,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _commit(),
          decoration: InputDecoration(
            isDense: true,
            labelText: 'Maximum sessions',
            helperText: 'Keeps the most recently active matching sessions.',
            helperMaxLines: 2,
            errorText: _error,
            errorMaxLines: 2,
          ),
        ),
      ],
    ),
  );
}
