import 'dart:io';

import 'package:intl/intl.dart';

String formatGroupedInt(int value) {
  return NumberFormat.decimalPattern(_systemLocaleName()).format(value);
}

String formatCompactInt(int value) {
  final absValue = value.abs();
  if (absValue < 1000) {
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
  var text = NumberFormat(
    precision == 0 ? '0' : '0.#',
    _systemLocaleName(),
  ).format(scaled);
  if (text.endsWith('.0') || text.endsWith(',0')) {
    text = text.substring(0, text.length - 2);
  }
  return '$text$suffix';
}

String _systemLocaleName() {
  final locale = Platform.localeName;
  if (locale.trim().isEmpty) {
    return Intl.systemLocale;
  }
  return locale.replaceAll('_', '-');
}
