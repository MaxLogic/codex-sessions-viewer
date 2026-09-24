import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

/// Writes an evaluation [result] and returns the file written.
///
/// Only a `measured` result replaces [output], through a temporary file and
/// rename, so retained evidence is never truncated or overwritten by an
/// unavailable or failed run. Other results go to `<output>.unavailable.json`.
File writeEvaluationResult(File output, Map<String, dynamic> result) {
  final target = result['status'] == 'measured'
      ? output
      : File('${output.path}.unavailable.json');
  target.parent.createSync(recursive: true);
  final staging = File('${target.path}.tmp');
  staging.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(result)}\n',
    flush: true,
  );
  return staging.renameSync(target.path);
}

typedef Embed = Future<List<List<double>>> Function(List<String> texts);

class EvaluationCancelled implements Exception {}

class EvaluationCancellation {
  bool cancelled = false;
  void check() {
    if (cancelled) throw EvaluationCancelled();
  }
}

class SearchChunk {
  SearchChunk(this.session, this.message, this.offset, this.source, this.text);
  final String session, message, source, text;
  final int offset;
  String get citation => '$session/$message@$offset';
  String get hash => sha256.convert(utf8.encode(text)).toString();
}

/// Chunk each message independently. Appending messages preserves old citations.
/// Tool output is excluded from this experiment to avoid drowning out dialogue.
List<SearchChunk> chunkSessions(List<dynamic> sessions, {int maxChars = 400}) {
  if (maxChars < 1) throw ArgumentError.value(maxChars);
  final result = <SearchChunk>[];
  final citations = <String>{};
  for (final session in sessions.cast<Map<String, dynamic>>()) {
    for (final message
        in (session['messages'] as List).cast<Map<String, dynamic>>()) {
      if (message['role'] == 'tool') continue;
      final text = (message['text'] as String)
          .replaceAll('\r\n', '\n')
          .replaceAll('\r', '\n');
      for (var start = 0; start < text.length; start += maxChars) {
        final part = text.substring(
          start,
          math.min(start + maxChars, text.length),
        );
        if (part.trim().isEmpty) continue;
        final chunk = SearchChunk(
          session['id'] as String,
          message['id'] as String,
          start,
          session['source'] as String,
          part,
        );
        if (!citations.add(chunk.citation)) {
          throw FormatException('Duplicate citation');
        }
        result.add(chunk);
      }
    }
  }
  return result;
}

Set<String> terms(String text) => RegExp(
  r'[a-z0-9]+',
).allMatches(text.toLowerCase()).map((m) => m.group(0)!).toSet();

double cosine(List<double> a, List<double> b) {
  if (a.length != b.length || a.isEmpty) {
    throw ArgumentError('Vector dimension');
  }
  var dot = 0.0, aa = 0.0, bb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    aa += a[i] * a[i];
    bb += b[i] * b[i];
  }
  if (!dot.isFinite || aa == 0 || bb == 0) {
    throw ArgumentError('Invalid vector');
  }
  return dot / math.sqrt(aa * bb);
}

class EvaluationIndex {
  EvaluationIndex(this.db, this.model, this.dimension, this.embed) {
    db.execute(
      'CREATE TABLE IF NOT EXISTS vectors (hash TEXT, model TEXT, dim INTEGER, vector TEXT NOT NULL, PRIMARY KEY(hash, model, dim))',
    );
  }
  final Database db;
  final String model;
  final int dimension;
  final Embed embed;
  int embedded = 0;

  Future<List<List<double>>> vectors(
    List<String> texts,
    EvaluationCancellation cancel,
  ) async {
    cancel.check();
    final found = <String, List<double>>{};
    final missing = <String, String>{};
    for (final text in texts) {
      final hash = sha256.convert(utf8.encode(text)).toString();
      final rows = db.select(
        'SELECT vector FROM vectors WHERE hash=? AND model=? AND dim=?',
        [hash, model, dimension],
      );
      if (rows.isEmpty) {
        missing[hash] = text;
      } else {
        found[hash] = (jsonDecode(rows.first['vector'] as String) as List)
            .cast<num>()
            .map((v) => v.toDouble())
            .toList();
      }
    }
    if (missing.isNotEmpty) {
      final values = await embed(missing.values.toList());
      cancel.check();
      if (values.length != missing.length) {
        throw StateError('Embedding count mismatch');
      }
      for (final vector in values) {
        if (vector.length != dimension ||
            vector.any((v) => !v.isFinite) ||
            vector.every((v) => v == 0)) {
          throw StateError('Embedding dimension or value mismatch');
        }
      }
      db.execute('BEGIN');
      try {
        var i = 0;
        for (final hash in missing.keys) {
          final vector = values[i++];
          db.execute('INSERT OR REPLACE INTO vectors VALUES (?, ?, ?, ?)', [
            hash,
            model,
            dimension,
            jsonEncode(vector),
          ]);
          found[hash] = vector;
        }
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
      embedded += missing.length;
    }
    cancel.check();
    return texts
        .map((s) => found[sha256.convert(utf8.encode(s)).toString()]!)
        .toList();
  }
}

class RankedChunk {
  RankedChunk(this.chunk, this.score);
  final SearchChunk chunk;
  final double score;
}

/// Hybrid reranks lexical candidates, matching the observed SkillSearch pattern.
/// Semantic mode independently considers every eligible chunk.
List<RankedChunk> rank(
  List<SearchChunk> chunks,
  String query,
  String mode, {
  List<List<double>>? vectors,
  List<double>? queryVector,
  String? source,
}) {
  if (!{'lexical', 'hybrid', 'semantic'}.contains(mode)) {
    throw ArgumentError(mode);
  }
  final q = terms(query);
  final lexical = chunks
      .map((c) => terms(c.text).intersection(q).length.toDouble())
      .toList();
  final maxLex = lexical.fold<double>(0, math.max);
  final result = <RankedChunk>[];
  for (var i = 0; i < chunks.length; i++) {
    if (source != null && chunks[i].source != source) continue;
    if (mode != 'semantic' && lexical[i] == 0) continue;
    var score = lexical[i];
    if (mode != 'lexical' && vectors != null && queryVector != null) {
      final semantic = (cosine(vectors[i], queryVector) + 1) / 2;
      score = mode == 'semantic'
          ? semantic
          : 0.35 * lexical[i] / maxLex + 0.65 * semantic;
    } else if (mode == 'semantic') {
      // Explicit lexical fallback if the optional model is unavailable.
      if (lexical[i] == 0) continue;
    }
    result.add(RankedChunk(chunks[i], score));
  }
  result.sort((a, b) {
    final order = b.score.compareTo(a.score);
    return order == 0 ? a.chunk.citation.compareTo(b.chunk.citation) : order;
  });
  // Session retrieval: return the strongest chunk and its stable citation.
  final seen = <String>{};
  return result.where((r) => seen.add(r.chunk.session)).take(10).toList();
}
