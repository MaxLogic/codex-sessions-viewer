String formatGroupedInt(int value) {
  final text = value.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < text.length; i += 1) {
    final remaining = text.length - i;
    buffer.write(text[i]);
    if (remaining > 1 && remaining % 3 == 1) {
      buffer.write(',');
    }
  }
  final formatted = buffer.toString();
  return value < 0 ? '-$formatted' : formatted;
}

String formatCompactInt(int value) {
  final absValue = value.abs();
  if (absValue < 10000) {
    return formatGroupedInt(value);
  }
  if (absValue < 1000000) {
    return _formatScaled(value, 1000, 'K');
  }
  if (absValue < 1000000000) {
    return _formatScaled(value, 1000000, 'M');
  }
  return _formatScaled(value, 1000000000, 'B');
}

String _formatScaled(int value, int scale, String suffix) {
  final scaled = value / scale;
  final precision = scaled.abs() < 100 ? 1 : 0;
  var text = scaled.toStringAsFixed(precision);
  if (text.endsWith('.0')) {
    text = text.substring(0, text.length - 2);
  }
  return '$text$suffix';
}
