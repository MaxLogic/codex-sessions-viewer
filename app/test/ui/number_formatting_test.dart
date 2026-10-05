import 'dart:io';

import 'package:codex_sessions_viewer/src/ui/number_formatting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

void main() {
  test('default entry points resolve the host locale', () {
    expect(
      formatGroupedInt(1234567),
      formatGroupedInt(1234567, locale: Platform.localeName),
    );
    expect(
      formatCompactInt(1200),
      formatCompactInt(1200, locale: Platform.localeName),
    );
  });

  for (final locale in [
    'C',
    'POSIX',
    'C.UTF-8',
    'C@euro',
    'POSIX.UTF-8@modifier',
    'unknown_LOCALE',
    'unknown.UTF-8@modifier',
  ]) {
    test('$locale falls back for grouped and compact counts', () {
      expect(formatGroupedInt(1234567, locale: locale), '1,234,567');
      expect(formatGroupedInt(-1234567, locale: locale), '-1,234,567');
      expect(formatCompactInt(1200, locale: locale), '1.2K');
      expect(formatCompactInt(-1200, locale: locale), '-1.2K');
    });
  }

  for (final fallback in ['', 'C', 'C.UTF-8', 'POSIX', 'unknown_LOCALE']) {
    test('blank locale with unsupported system locale "$fallback" is safe', () {
      final resolved = resolveNumberLocale('   ', systemLocale: fallback);
      expect(resolved, 'en_US');
      expect(formatGroupedInt(1234567, locale: resolved), '1,234,567');
      expect(formatCompactInt(1200, locale: resolved), '1.2K');
    });
  }

  test('blank locale preserves supported system locale', () {
    final polish = resolveNumberLocale(
      '',
      systemLocale: 'pl_PL.UTF-8@modifier',
    );
    expect(formatGroupedInt(1234567, locale: polish), '1\u00a0234\u00a0567');
    expect(formatCompactInt(1200, locale: polish), '1,2K');
    expect(resolveNumberLocale('', systemLocale: 'en_US'), 'en_US');
  });

  for (final entry in {
    'en_US': '1,234,567',
    'en-US': '1,234,567',
    'en_US.UTF-8': '1,234,567',
    'pl_PL': '1\u00a0234\u00a0567',
    'pl-PL': '1\u00a0234\u00a0567',
    ' pl_PL.UTF-8@modifier ': '1\u00a0234\u00a0567',
  }.entries) {
    test('${entry.key} preserves supported separators and signs', () {
      expect(formatGroupedInt(1234567, locale: entry.key), entry.value);
      expect(formatGroupedInt(-1234567, locale: entry.key), '-${entry.value}');
      expect(formatGroupedInt(0, locale: entry.key), '0');
      final decimal = entry.key.contains('pl') ? ',' : '.';
      expect(formatCompactInt(1200, locale: entry.key), '1${decimal}2K');
      expect(formatCompactInt(-1200, locale: entry.key), '-1${decimal}2K');
    });
  }

  for (final locale in ['C.UTF-8', 'en_US', 'pl_PL']) {
    test('$locale retains compact boundaries and precision', () {
      final expected = {
        0: '0',
        999: '999',
        1000: '1K',
        99999: '100K',
        100000: '100K',
        999999: '1000K',
        1000000: '1M',
        12000000: '12M',
        999999999: '1000M',
        1000000000: '1B',
      };
      for (final entry in expected.entries) {
        expect(formatCompactInt(entry.key, locale: locale), entry.value);
        expect(
          formatCompactInt(-entry.key, locale: locale),
          entry.key == 0 ? '0' : '-${entry.value}',
        );
      }
    });
  }

  test('resolving and formatting leaves Intl defaults unchanged', () {
    final system = Intl.systemLocale;
    final defaultLocale = Intl.defaultLocale;
    formatGroupedInt(1234567, locale: 'C.UTF-8');
    formatCompactInt(1200, locale: 'POSIX');
    resolveNumberLocale('', systemLocale: 'unknown_LOCALE');
    expect(Intl.systemLocale, system);
    expect(Intl.defaultLocale, defaultLocale);
  });
}
