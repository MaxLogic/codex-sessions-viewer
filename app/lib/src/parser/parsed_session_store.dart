import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'codex_session_parser.dart';

class ParsedSessionStore {
  const ParsedSessionStore();

  void recordParseFailure(Database db, CodexParseError error) {
    final now = DateTime.now().toUtc().toIso8601String();
    final id = _stableSourceId(error.sourcePath);
    db.execute(
      '''
      insert into sessions (
        id,
        source_type,
        source_file_path,
        display_path,
        platform_path,
        parse_status,
        parse_error,
        created_at_utc,
        updated_at_utc,
        last_parsed_utc
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      on conflict(id) do update set
        parse_status = excluded.parse_status,
        parse_error = excluded.parse_error,
        updated_at_utc = excluded.updated_at_utc,
        last_parsed_utc = excluded.last_parsed_utc
      ''',
      [
        id,
        _sourceTypeLabel(error.sourcePath),
        error.sourcePath,
        error.sourcePath,
        error.sourcePath,
        'parse_error',
        jsonEncode({
          'kind': error.kind.name,
          'message': error.message,
          'offset': error.offset,
          'line': error.line,
          'column': error.column,
        }),
        now,
        now,
        now,
      ],
    );
  }
}

String _stableSourceId(String sourcePath) {
  return sha256.convert(utf8.encode(sourcePath)).toString();
}

String _sourceTypeLabel(String sourcePath) {
  if (sourcePath.startsWith(r'\\wsl') || sourcePath.contains('/home/')) {
    return 'wsl';
  }
  return 'windows';
}
