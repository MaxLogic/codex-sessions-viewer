import 'dart:io';

import 'package:codex_sessions_viewer/src/database/collector_versions.dart';
import 'package:codex_sessions_viewer/src/database/writer_version_agreement.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

/// The Rust constant [name] in [file], read from the collector sources the
/// release builds, so a version bump on either side fails here first.
String _rustConstant(String file, String name) {
  final source = File('../collector/src/$file').readAsStringSync();
  final match = RegExp(
    'pub const $name: [^=]+= "?([^";]+)"?;',
  ).firstMatch(source);
  expect(match, isNotNull, reason: '$name is not defined in $file');
  return match!.group(1)!;
}

void main() {
  test('viewer constants equal the collector constants they mirror', () {
    expect(
      collectorCodexParserVersion.toString(),
      _rustConstant('codex/parser.rs', 'PARSER_VERSION'),
    );
    expect(
      collectorClaudeParserVersion.toString(),
      _rustConstant('claude/parser.rs', 'CLAUDE_PARSER_VERSION'),
    );
    expect(
      usageCostProjectionVersion.toString(),
      _rustConstant('store/writer.rs', 'USAGE_COST_PROJECTION_VERSION'),
    );
    expect(
      sessionCacheRepairCompletionKey,
      _rustConstant('store/cache_repair.rs', 'COMPLETION_KEY'),
    );
    expect(viewerWriterVersions.keys, {
      _rustConstant('store/schema.rs', 'PARSER_VERSION_KEY'),
      _rustConstant('store/schema.rs', 'CLAUDE_PARSER_VERSION_KEY'),
      _rustConstant('store/schema.rs', 'COST_VERSION_KEY'),
    });
  });

  test('cost projection rows are written with the shared version', () {
    // Literal versions in either writer would silently drift from the
    // constant the agreement test covers.
    final dart = File('lib/src/usage/usage_summary.dart').readAsStringSync();
    final rust = File('../collector/src/store/writer.rs').readAsStringSync();
    for (final source in [dart, rust]) {
      expect(source, isNot(contains("'pending_history', 1,")));
    }
  });

  test('the viewer records every writer version for collectors', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(
      'create table app_metadata (key text primary key, value text, updated_at_utc text)',
    );
    recordViewerWriterVersions(db);
    expect(
      {
        for (final row in db.select('select key, value from app_metadata'))
          row['key']: row['value'],
      },
      {
        'writer_codex_parser_version': '$collectorCodexParserVersion',
        'writer_claude_parser_version': '$collectorClaudeParserVersion',
        'writer_usage_cost_projection_version': '$usageCostProjectionVersion',
      },
    );
  });
}
