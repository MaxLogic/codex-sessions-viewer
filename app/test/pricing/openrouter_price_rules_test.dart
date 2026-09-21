import 'dart:convert';

import 'package:codex_sessions_viewer/src/pricing/openrouter_price_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes catalog rules without losing provider order or rates', () {
    final raw = [
      {
        'min_prompt_tokens': 272000,
        'prompt': '0.0000002200',
        'completion': '0.000000660',
        'input_cache_read': '0.000000007',
        'input_cache_write': '0.0000000833333333333333',
        'audio': '0.10',
        'audio_output': '0.040',
        'image_output': '0.050',
        'input_audio_cache': '0.020',
        'input_cache_write_1h': '0.030',
      },
      {
        'utc_days': ['monday', 'wednesday', 'friday'],
        'utc_start': 1000,
        'utc_end': 0,
        'prompt': '0',
      },
    ];

    final rules = parseOpenRouterPriceRules(raw);

    expect(rules.map((rule) => rule.providerOrder), [0, 1]);
    expect(rules.first.minPromptTokens, 272000);
    expect(rules.first.utcWeekdays, isNull);
    expect(rules.first.utcStartMinute, isNull);
    expect(rules.first.utcEndMinute, isNull);
    expect(rules.first.rateOverrides, {
      'prompt': '0.00000022',
      'completion': '0.00000066',
      'input_cache_read': '0.000000007',
      'input_cache_write': '0.0000000833333333333333',
      'audio': '0.1',
      'audio_output': '0.04',
      'image_output': '0.05',
      'input_audio_cache': '0.02',
      'input_cache_write_1h': '0.03',
    });
    expect(rules.last.utcStartMinute, 600);
    expect(rules.last.utcEndMinute, 0);
    expect(rules.last.utcWeekdays, {1, 3, 5});
    expect(jsonDecode(rules.first.rawRuleJson), raw.first);
    expect(jsonDecode(rules.last.rawRuleJson), raw.last);
    expect(parseOpenRouterPriceRules(null), isEmpty);
    expect(parseOpenRouterPriceRules([]), isEmpty);
    expect(() => rules.clear(), throwsUnsupportedError);
    expect(() => rules.first.rateOverrides.clear(), throwsUnsupportedError);
    expect(() => rules.last.utcWeekdays!.clear(), throwsUnsupportedError);
  });

  test('rejects unsupported or malformed rules without partial acceptance', () {
    final valid = {'min_prompt_tokens': 10, 'prompt': '0.1'};
    for (final invalid in <Object?>[
      {'max_prompt_tokens': 100, 'prompt': '0.1'},
      {
        'conditions': {'region': 'eu'},
        'prompt': '0.1',
      },
      {'unrecognized_rate': '0.1', 'prompt': '0.1'},
      {'utc_start': 100, 'prompt': '0.1'},
      {'utc_end': 400, 'prompt': '0.1'},
      {'utc_start': 0, 'utc_end': 0, 'prompt': '0.1'},
      {'utc_start': 1260, 'utc_end': 1600, 'prompt': '0.1'},
      {'utc_start': -100, 'utc_end': 1600, 'prompt': '0.1'},
      {'utc_start': 100, 'utc_end': 2400, 'prompt': '0.1'},
      {'utc_start': '1000', 'utc_end': 0, 'prompt': '0.1'},
      {'min_prompt_tokens': -1, 'prompt': '0.1'},
      {'min_prompt_tokens': 1.5, 'prompt': '0.1'},
      {'min_prompt_tokens': null, 'prompt': '0.1'},
      {'min_prompt_tokens': 10},
      {'utc_days': [], 'prompt': '0.1'},
      {
        'utc_days': ['Monday'],
        'prompt': '0.1',
      },
      {
        'utc_days': ['monday', 2],
        'prompt': '0.1',
      },
      {'prompt': '-0.1'},
      {'prompt': 0.1},
      {'prompt': '1e-7'},
      {'prompt': null},
      null,
      'not an object',
    ]) {
      expect(
        () => parseOpenRouterPriceRules([valid, invalid]),
        throwsFormatException,
        reason: 'Must reject the whole rule list for $invalid',
      );
    }
    expect(() => parseOpenRouterPriceRules({}), throwsFormatException);
  });

  test('matches prompt threshold strictly using each event token count', () {
    final rules = parseOpenRouterPriceRules([
      {'min_prompt_tokens': 272000, 'prompt': '0.2'},
      {'prompt': '0.1'},
    ]);
    final time = DateTime.utc(2026, 9, 7, 12);
    expect(
      rules.first.matches(promptTokens: 271999, occurredAtUtc: time),
      isFalse,
    );
    expect(
      rules.first.matches(promptTokens: 272000, occurredAtUtc: time),
      isFalse,
    );
    expect(
      rules.first.matches(promptTokens: 272001, occurredAtUtc: time),
      isTrue,
    );
    expect(rules.last.matches(promptTokens: 0, occurredAtUtc: time), isTrue);
    expect(rules.last.matches(promptTokens: -1, occurredAtUtc: time), isFalse);
  });

  test('matches UTC weekdays and half-open recurring windows per event', () {
    final rules = parseOpenRouterPriceRules([
      {
        'min_prompt_tokens': 9,
        'utc_days': ['monday', 'tuesday', 'wednesday', 'thursday', 'friday'],
        'utc_start': 1000,
        'utc_end': 0,
        'prompt': '0.1',
      },
      {'utc_start': 100, 'utc_end': 400, 'prompt': '0.2'},
      {
        'utc_days': ['monday'],
        'utc_start': 2230,
        'utc_end': 400,
        'prompt': '0.3',
      },
      {
        'utc_days': ['monday'],
        'prompt': '0.4',
      },
    ]);
    for (final (ruleIndex, timestamp, tokens, expected) in [
      (0, '2026-09-07T09:59:59.999999Z', 10, false),
      (0, '2026-09-07T10:00:00Z', 10, true),
      (0, '2026-09-07T10:00:00Z', 9, false),
      (0, '2026-09-11T23:59:59.999999Z', 10, true),
      (0, '2026-09-12T10:00:00Z', 10, false),
      (0, '2026-09-08T00:00:00Z', 10, false),
      (0, '2026-09-07T12:00:00+02:00', 10, true),
      (0, '2026-09-12T00:30:00+02:00', 10, true),
      (1, '2026-09-07T00:59:59.999999Z', 0, false),
      (1, '2026-09-07T01:00:00Z', 0, true),
      (1, '2026-09-07T03:59:59.999999Z', 0, true),
      (1, '2026-09-07T04:00:00Z', 0, false),
      (2, '2026-09-07T22:29:59.999999Z', 0, false),
      (2, '2026-09-07T22:30:00Z', 0, true),
      (2, '2026-09-07T02:00:00Z', 0, true),
      (2, '2026-09-08T02:00:00Z', 0, false),
      (2, '2026-09-07T04:00:00Z', 0, false),
      (3, '2026-09-07T00:00:00Z', 0, true),
      (3, '2026-09-08T00:00:00Z', 0, false),
    ]) {
      expect(
        rules[ruleIndex].matches(
          promptTokens: tokens,
          occurredAtUtc: DateTime.parse(timestamp),
        ),
        expected,
        reason: 'Rule $ruleIndex at $timestamp with $tokens prompt tokens',
      );
    }
    // Matching rules remain in provider order for per-key overlay by callers.
    expect(
      rules
          .where(
            (rule) => rule.matches(
              promptTokens: 10,
              occurredAtUtc: DateTime.utc(2026, 9, 7, 23),
            ),
          )
          .first
          .providerOrder,
      0,
    );
  });
}
