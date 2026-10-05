import 'dart:io';

import 'package:intl/intl.dart';

String formatGroupedInt(int value, {String? locale}) {
  return NumberFormat.decimalPattern(
    resolveNumberLocale(locale ?? Platform.localeName),
  ).format(value);
}

String formatCompactInt(int value, {String? locale}) {
  final absValue = value.abs();
  if (absValue < 1000) {
    return formatGroupedInt(value, locale: locale);
  }
  if (absValue < 1000000) {
    return _formatScaled(value, 1000, 'K', locale);
  }
  if (absValue < 1000000000) {
    return _formatScaled(value, 1000000, 'M', locale);
  }
  return _formatScaled(value, 1000000000, 'B', locale);
}

String _formatScaled(int value, int scale, String suffix, String? locale) {
  final scaled = value / scale;
  final precision = scaled.abs() < 100 ? 1 : 0;
  var text = NumberFormat(
    precision == 0 ? '0' : '0.#',
    resolveNumberLocale(locale ?? Platform.localeName),
  ).format(scaled);
  if (text.endsWith('.0') || text.endsWith(',0')) {
    text = text.substring(0, text.length - 2);
  }
  return '$text$suffix';
}

/// Resolves desktop/POSIX locale names against intl's number-format data.
/// Blank host locales retain a supported [Intl.systemLocale]; unsupported
/// inputs use the deterministic en_US fallback. [systemLocale] is injectable
/// so callers can verify fallback handling without mutating global locale state.
String resolveNumberLocale(String locale, {String? systemLocale}) {
  final candidate = locale.trim().isEmpty
      ? (systemLocale ?? Intl.systemLocale).trim()
      : locale.trim();
  // POSIX encoding and modifier suffixes are not part of intl locale names.
  final name = candidate.split(RegExp(r'[.@]')).first;
  return Intl.verifiedLocale(
    name,
    NumberFormat.localeExists,
    onFailure: (_) => 'en_US',
  )!;
}
