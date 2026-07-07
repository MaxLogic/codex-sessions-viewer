import 'package:sqlite3/sqlite3.dart';

class SessionEvalStateStore {
  const SessionEvalStateStore(this.db);

  final Database db;

  void setEvalMetadata(
    String sessionId, {
    required bool evalReady,
    String? status,
    String? notes,
    String? expectedOutput,
    DateTime? reviewedAtUtc,
  }) {
    db.execute(
      '''
      update sessions
      set eval_ready = ?,
          eval_status = ?,
          eval_notes = ?,
          eval_expected_output = ?,
          eval_reviewed_at_utc = ?,
          eval_updated_at_utc = ?
      where id = ?
      ''',
      [
        evalReady ? 1 : 0,
        _blankToNull(status),
        _blankToNull(notes),
        _blankToNull(expectedOutput),
        reviewedAtUtc?.toUtc().toIso8601String(),
        DateTime.now().toUtc().toIso8601String(),
        sessionId,
      ],
    );
  }
}

String? _blankToNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
