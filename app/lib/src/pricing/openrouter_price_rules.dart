import 'dart:convert';

import '../usage/usage_summary.dart' show sumEstimatedCostTexts;

/// Normalized catalog evidence. Prices stay decimal text, never doubles.
class OpenRouterPriceRule {
  const OpenRouterPriceRule({
    required this.providerOrder,
    required this.minPromptTokens,
    required this.utcStartMinute,
    required this.utcEndMinute,
    required this.utcWeekdays,
    required this.rateOverrides,
    required this.rawRuleJson,
  });

  final int providerOrder;
  final int? minPromptTokens;
  final int? utcStartMinute;
  final int? utcEndMinute;
  final Set<int>? utcWeekdays;
  final Map<String, String> rateOverrides;
  final String rawRuleJson;

  /// Conditions apply to one event, not a daily aggregate. The caller first
  /// selects the historical price period covering that event's timestamp.
  bool matches({required int promptTokens, required DateTime occurredAtUtc}) {
    if (promptTokens < 0 ||
        (minPromptTokens != null && promptTokens <= minPromptTokens!)) {
      return false;
    }
    final utc = occurredAtUtc.toUtc();
    if (utcWeekdays != null && !utcWeekdays!.contains(utc.weekday)) {
      return false;
    }
    final start = utcStartMinute;
    final end = utcEndMinute;
    if (start == null || end == null) return true;
    final minute = utc.hour * 60 + utc.minute;
    // Provider recurring-window semantics: weekdays refer to the event's UTC
    // day, even for overnight windows. End 0000 is exclusive midnight.
    return start < end
        ? minute >= start && minute < end
        : minute >= start || minute < end;
  }
}

List<OpenRouterPriceRule> parseOpenRouterPriceRules(Object? overrides) {
  if (overrides == null) return const [];
  if (overrides is! List) {
    throw const FormatException('OpenRouter pricing overrides must be a list.');
  }
  final rules = <OpenRouterPriceRule>[];
  for (final raw in overrides) {
    if (raw is! Map) {
      throw const FormatException('OpenRouter pricing rule must be an object.');
    }
    if (raw.keys.any(
      (key) => !_rateKeys.contains(key) && !_conditionKeys.contains(key),
    )) {
      throw const FormatException(
        'OpenRouter pricing rule has unsupported fields.',
      );
    }
    final rates = <String, String>{};
    for (final key in _rateKeys) {
      if (!raw.containsKey(key)) continue;
      final value = raw[key];
      final normalized = value is String
          ? sumEstimatedCostTexts([value])
          : null;
      if (normalized == null || normalized.startsWith('-')) {
        throw const FormatException('OpenRouter rule rate is invalid.');
      }
      rates[key] = normalized;
    }
    if (rates.isEmpty) {
      throw const FormatException('OpenRouter pricing rule has no rates.');
    }
    int? minimum;
    if (raw.containsKey('min_prompt_tokens')) {
      final value = raw['min_prompt_tokens'];
      if (value is! int || value < 0) {
        throw const FormatException('OpenRouter prompt threshold is invalid.');
      }
      minimum = value;
    }
    Set<int>? weekdays;
    if (raw.containsKey('utc_days')) {
      final value = raw['utc_days'];
      if (value is! List || value.isEmpty) {
        throw const FormatException('OpenRouter UTC weekdays are invalid.');
      }
      weekdays = <int>{};
      for (final day in value) {
        final index = _weekdays.indexOf(day is String ? day : '');
        if (index < 0) {
          throw const FormatException('OpenRouter UTC weekday is invalid.');
        }
        weekdays.add(index + 1);
      }
    }
    final start = raw.containsKey('utc_start')
        ? _minute(raw['utc_start'])
        : null;
    final end = raw.containsKey('utc_end') ? _minute(raw['utc_end']) : null;
    if ((start == null) != (end == null) || (start != null && start == end)) {
      throw const FormatException(
        'OpenRouter UTC window is incomplete or ambiguous.',
      );
    }
    rules.add(
      OpenRouterPriceRule(
        providerOrder: rules.length,
        minPromptTokens: minimum,
        utcStartMinute: start,
        utcEndMinute: end,
        utcWeekdays: weekdays == null ? null : Set.unmodifiable(weekdays),
        rateOverrides: Map.unmodifiable(rates),
        rawRuleJson: jsonEncode(raw),
      ),
    );
  }
  return List.unmodifiable(rules);
}

int _minute(Object? value) {
  // The provider uses HHMM clock numbers. Retain the raw JSON as evidence.
  if (value is! int || value < 0 || value > 2359 || value % 100 > 59) {
    throw const FormatException('OpenRouter UTC time must be an HHMM integer.');
  }
  return value ~/ 100 * 60 + value % 100;
}

const _rateKeys = {
  'prompt',
  'completion',
  'input_cache_read',
  'input_cache_write',
  'internal_reasoning',
  'request',
  'image',
  'web_search',
  'audio',
  'audio_output',
  'image_output',
  'input_audio_cache',
  'input_cache_write_1h',
};

const _conditionKeys = {
  'min_prompt_tokens',
  'utc_start',
  'utc_end',
  'utc_days',
};

const _weekdays = [
  'monday',
  'tuesday',
  'wednesday',
  'thursday',
  'friday',
  'saturday',
  'sunday',
];
