import 'dart:convert';
import 'dart:io';

class SessionFormatAnalyzer {
  Future<SessionFormatSummary> analyzeRoot(Directory root) async {
    final summary = SessionFormatSummary();
    if (!await root.exists()) {
      return summary;
    }

    final files = <File>[];
    await for (final entity in root.list(recursive: true)) {
      if (entity is! File) {
        continue;
      }
      if (entity.path.endsWith('.json') || entity.path.endsWith('.jsonl')) {
        files.add(entity);
      }
    }
    files.sort((left, right) => left.path.compareTo(right.path));

    for (final file in files) {
      await _analyzeFile(file, summary);
    }
    return summary;
  }

  Future<void> _analyzeFile(File file, SessionFormatSummary summary) async {
    summary.filesScanned++;
    final isJsonl = file.path.endsWith('.jsonl');
    try {
      final text = await file.readAsString();
      if (isJsonl) {
        _analyzeJsonl(text, summary);
      } else {
        _analyzeJsonObject(text, summary);
      }
    } on FormatException {
      summary.filesMalformed++;
    } on Object {
      summary.filesUnreadable++;
    }
  }

  void _analyzeJsonObject(String text, SessionFormatSummary summary) {
    final decoded = jsonDecode(text);
    if (decoded is! Map) {
      summary.filesMalformed++;
      return;
    }
    final map = decoded.cast<String, Object?>();
    summary.recordTypes.add('json_object_session');
    summary.topLevelKeys.addAll(map.keys);
    _collectUsageKeys('json_object.usage', map['usage'], summary);
    final messages = map['messages'];
    if (messages is List) {
      for (final message in messages) {
        if (message is! Map) {
          continue;
        }
        final messageMap = message.cast<String, Object?>();
        final messageType = _string(messageMap['type']);
        if (messageType != null) {
          summary.jsonObjectMessageTypes.add(messageType);
        }
        summary.messageKeys.addAll(messageMap.keys);
        _collectUsageKeys(
          'json_object.messages.usage',
          messageMap['usage'],
          summary,
        );
      }
    }
  }

  void _analyzeJsonl(String text, SessionFormatSummary summary) {
    final lines = const LineSplitter().convert(text);
    var fileHadMalformedLine = false;
    for (final line in lines) {
      if (line.trim().isEmpty) {
        continue;
      }
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) {
          summary.malformedLines++;
          fileHadMalformedLine = true;
          continue;
        }
        _analyzeJsonlRecord(decoded.cast<String, Object?>(), summary);
      } on FormatException {
        summary.malformedLines++;
        fileHadMalformedLine = true;
      }
    }
    if (fileHadMalformedLine) {
      summary.filesMalformed++;
    }
  }

  void _analyzeJsonlRecord(
    Map<String, Object?> record,
    SessionFormatSummary summary,
  ) {
    summary.topLevelKeys.addAll(record.keys);
    final recordType = _string(record['type']) ?? 'unknown';
    summary.recordTypes.add(recordType);
    final payload = _map(record['payload']);
    if (payload.isEmpty) {
      return;
    }
    summary.payloadKeys.addAll(payload.keys);
    final payloadType = _string(payload['type']);
    if (recordType == 'response_item') {
      summary.responseItemTypes.add(payloadType ?? 'unknown');
      if (payloadType == 'message') {
        summary.messageKeys.addAll(payload.keys);
      }
      if (payloadType == 'function_call') {
        summary.functionCallKeys.addAll(payload.keys);
      }
      if (payloadType == 'function_call_output') {
        summary.functionCallOutputKeys.addAll(payload.keys);
      }
    } else if (recordType == 'event_msg') {
      summary.eventMessageTypes.add(payloadType ?? 'unknown');
      if (payloadType == 'token_count') {
        final info = _map(payload['info']);
        _collectUsageKeys(
          'event_msg.token_count.info.total_token_usage',
          info['total_token_usage'],
          summary,
        );
        _collectUsageKeys(
          'event_msg.token_count.info.last_token_usage',
          info['last_token_usage'],
          summary,
        );
      }
    }
    _collectUsageKeys(
      '$recordType.$payloadType.usage',
      payload['usage'],
      summary,
    );
  }

  void _collectUsageKeys(
    String shapeName,
    Object? value,
    SessionFormatSummary summary,
  ) {
    final usage = _map(value);
    if (usage.isEmpty) {
      return;
    }
    summary.tokenUsageKeys.addAll(usage.keys);
    summary.tokenUsageShapes.add(shapeName, usage.keys);
  }
}

class SessionFormatSummary {
  int filesScanned = 0;
  int filesMalformed = 0;
  int filesUnreadable = 0;
  int malformedLines = 0;

  final topLevelKeys = CountBag();
  final recordTypes = CountBag();
  final payloadKeys = CountBag();
  final responseItemTypes = CountBag();
  final eventMessageTypes = CountBag();
  final jsonObjectMessageTypes = CountBag();
  final messageKeys = CountBag();
  final functionCallKeys = CountBag();
  final functionCallOutputKeys = CountBag();
  final tokenUsageKeys = CountBag();
  final tokenUsageShapes = ShapeBag();

  Map<String, Object?> toContentSafeJson() {
    return {
      'files_scanned': filesScanned,
      'malformed_files': filesMalformed,
      'unreadable_files': filesUnreadable,
      'malformed_lines': malformedLines,
      'top_level_keys': topLevelKeys.toJson(),
      'record_types': recordTypes.toJson(),
      'payload_keys': payloadKeys.toJson(),
      'response_item_types': responseItemTypes.toJson(),
      'event_message_types': eventMessageTypes.toJson(),
      'json_object_message_types': jsonObjectMessageTypes.toJson(),
      'message_keys': messageKeys.toJson(),
      'function_call_keys': functionCallKeys.toJson(),
      'function_call_output_keys': functionCallOutputKeys.toJson(),
      'token_usage_keys': tokenUsageKeys.toJson(),
      'token_usage_shapes': tokenUsageShapes.toJson(),
    };
  }

  String renderContentSafeReport() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(toContentSafeJson());
  }
}

class CountBag {
  final Map<String, int> _counts = <String, int>{};

  void add(String key) {
    _counts.update(key, (value) => value + 1, ifAbsent: () => 1);
  }

  void addAll(Iterable<String> keys) {
    for (final key in keys) {
      add(key);
    }
  }

  int countFor(String key) => _counts[key] ?? 0;

  Map<String, int> toJson() {
    final entries = _counts.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return {for (final entry in entries) entry.key: entry.value};
  }
}

class ShapeBag {
  final Map<String, CountBag> _shapes = <String, CountBag>{};

  void add(String shapeName, Iterable<String> keys) {
    final bag = _shapes.putIfAbsent(shapeName, CountBag.new);
    bag.addAll(keys);
  }

  Map<String, Map<String, int>> toJson() {
    final entries = _shapes.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return {for (final entry in entries) entry.key: entry.value.toJson()};
  }
}

Map<String, Object?> _map(Object? value) =>
    value is Map ? value.cast<String, Object?>() : <String, Object?>{};

String? _string(Object? value) => value is String ? value : null;
