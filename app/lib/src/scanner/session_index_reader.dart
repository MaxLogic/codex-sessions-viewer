import 'dart:convert';
import 'dart:io';

class CodexThreadNameEntry {
  const CodexThreadNameEntry({
    required this.id,
    required this.threadName,
    this.updatedAtUtc,
  });

  final String id;
  final String threadName;
  final DateTime? updatedAtUtc;
}

class CodexSessionIndexResult {
  const CodexSessionIndexResult({
    required this.entriesById,
    required this.rowsRead,
    required this.parseFailures,
    required this.readFailed,
  });

  final Map<String, CodexThreadNameEntry> entriesById;
  final int rowsRead;
  final int parseFailures;
  final bool readFailed;
}

class CodexSessionIndexReader {
  const CodexSessionIndexReader();

  Future<CodexSessionIndexResult> read(File file) async {
    if (!await file.exists()) {
      return const CodexSessionIndexResult(
        entriesById: {},
        rowsRead: 0,
        parseFailures: 0,
        readFailed: false,
      );
    }

    final entries = <String, CodexThreadNameEntry>{};
    var rowsRead = 0;
    var parseFailures = 0;
    try {
      final lines = file
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) {
          continue;
        }
        rowsRead++;
        try {
          final value = jsonDecode(trimmed);
          if (value is! Map<String, Object?>) {
            parseFailures++;
            continue;
          }
          final id = (value['id'] as String?)?.trim() ?? '';
          final threadName = (value['thread_name'] as String?)?.trim() ?? '';
          if (id.isEmpty || threadName.isEmpty) {
            continue;
          }
          final updatedAt = DateTime.tryParse(
            (value['updated_at'] as String?)?.trim() ?? '',
          )?.toUtc();
          final candidate = CodexThreadNameEntry(
            id: id,
            threadName: threadName,
            updatedAtUtc: updatedAt,
          );
          final previous = entries[id];
          if (previous == null ||
              _isNewer(candidate.updatedAtUtc, previous.updatedAtUtc)) {
            entries[id] = candidate;
          }
        } on FormatException {
          parseFailures++;
        } on TypeError {
          parseFailures++;
        }
      }
    } on IOException {
      return CodexSessionIndexResult(
        entriesById: entries,
        rowsRead: rowsRead,
        parseFailures: parseFailures,
        readFailed: true,
      );
    }

    return CodexSessionIndexResult(
      entriesById: entries,
      rowsRead: rowsRead,
      parseFailures: parseFailures,
      readFailed: false,
    );
  }

  bool _isNewer(DateTime? candidate, DateTime? previous) {
    if (candidate == null) {
      return previous == null;
    }
    if (previous == null) {
      return true;
    }
    return candidate.isAfter(previous);
  }
}
