import 'dart:io';

import 'package:codex_sessions_viewer/src/ui/number_formatting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

void main() {
  test('groups integers with the system locale', () {
    final locale = Platform.localeName.replaceAll('_', '-');

    expect(
      formatGroupedInt(1234567),
      NumberFormat.decimalPattern(locale).format(1234567),
    );
  });

  test('compacts large count labels with K and M suffixes', () {
    expect(formatCompactInt(999), formatGroupedInt(999));
    expect(formatCompactInt(1200), endsWith('K'));
    expect(formatCompactInt(1200000), endsWith('M'));
  });
}
