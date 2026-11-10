import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:toml/toml.dart';

import 'package:sqlite3/sqlite3.dart';

import 'app_settings.dart';

/// User-settable inputs to collector CheckpointOptions::digest.
/// Add future inputs here so capture, comparison and notice labels stay together.
final _parseSettings = <String, int Function(AppSettings)>{
  'tool_output.max_tool_output_preview_chars': (settings) =>
      settings.toolOutput.maxToolOutputPreviewChars,
};

const _parseSettingLabels = {
  'tool_output.max_tool_output_preview_chars': 'Tool output preview length',
};

class ParsedWithSettings {
  ParsedWithSettings(Map<String, int> values)
    : values = Map.unmodifiable(values);

  factory ParsedWithSettings.capture(AppSettings settings) =>
      ParsedWithSettings({
        for (final entry in _parseSettings.entries)
          entry.key: entry.value(settings),
      });

  final Map<String, int> values;

  List<String> changesFrom(ParsedWithSettings previous) => [
    for (final key in _parseSettings.keys)
      if (values[key] != previous.values[key])
        '${_parseSettingLabels[key] ?? key} ($key): changed from ${previous.values[key] ?? 'not recorded'} to ${values[key]} characters.',
  ];
}

/// Conservative provenance check for the collector's independent file read.
/// Values come from the exact bytes hashed here, never a separate settings load.
class ParseSettingsSnapshot {
  ParseSettingsSnapshot(
    this.values,
    this.hash,
    this.size,
    this.modified,
    this.stable,
  );

  final ParsedWithSettings values;
  final Digest hash;
  final int size;
  final DateTime modified;
  final bool stable;

  static Future<ParseSettingsSnapshot> capture(File file) async {
    final before = await file.stat();
    final bytes = await file.readAsBytes();
    final after = await file.stat();
    return ParseSettingsSnapshot(
      ParsedWithSettings.capture(
        AppSettings.fromTomlMap(TomlDocument.parse(utf8.decode(bytes)).toMap()),
      ),
      sha256.convert(bytes),
      after.size,
      after.modified,
      before.size == after.size &&
          before.modified == after.modified &&
          bytes.length == after.size,
    );
  }

  Future<bool> isUnchanged(File file) async {
    if (!stable) return false;
    try {
      final before = await file.stat();
      final bytes = await file.readAsBytes();
      final after = await file.stat();
      return before.size == after.size &&
          before.modified == after.modified &&
          bytes.length == after.size &&
          sha256.convert(bytes) == hash &&
          after.size == size &&
          after.modified == modified;
    } on FileSystemException {
      return false;
    }
  }
}

class ParsedWithSettingsStore {
  ParsedWithSettingsStore(this.db);

  static const metadataKey = 'history_parsed_with_settings_v1';
  final Database db;

  ParsedWithSettings loadOrInitialize(ParsedWithSettings current) {
    final rows = db.select('select value from app_metadata where key = ?', [
      metadataKey,
    ]);
    if (rows.isEmpty) {
      record(current);
      return current;
    }
    final decoded = jsonDecode(rows.single['value'] as String);
    if (decoded is! Map<String, dynamic> ||
        decoded.values.any((value) => value is! int)) {
      throw const FormatException('Invalid parsed-with settings metadata.');
    }
    return ParsedWithSettings(decoded.cast<String, int>());
  }

  void record(ParsedWithSettings settings) {
    db.execute(
      '''insert into app_metadata(key, value, updated_at_utc) values (?, ?, ?)
         on conflict(key) do update set value = excluded.value,
           updated_at_utc = excluded.updated_at_utc''',
      [
        metadataKey,
        jsonEncode(settings.values),
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  }
}
