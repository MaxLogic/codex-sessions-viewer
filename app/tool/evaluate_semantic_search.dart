import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'semantic_search_evaluation.dart';

Future<void> main(List<String> args) async {
  String option(String key) {
    final i = args.indexOf(key);
    if (i < 0 || i + 1 == args.length) throw ArgumentError('Required: $key');
    return args[i + 1];
  }

  final manifestFile = File(option('--manifest'));
  final output = File(option('--out'));
  final manifestBytes = manifestFile.readAsBytesSync();
  final manifest =
      jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
  final model = manifest['model'] as String;
  final revision = manifest['revision'] as String;
  final queries = (manifest['queries'] as List).cast<Map<String, dynamic>>();
  final chunks = chunkSessions(manifest['sessions'] as List);
  final result = <String, dynamic>{
    'status': 'unavailable',
    'corpus_sha256': sha256.convert(manifestBytes).toString(),
    'model': model,
    'revision': revision,
    'dimension': manifest['dimension'],
    'chunk_max_chars': 400,
    'tool_output': 'excluded',
    'sessions': (manifest['sessions'] as List).length,
    'chunks': chunks.length,
    'queries': queries.length,
    'device': 'cpu',
    'hybrid_weights': {'lexical': 0.35, 'semantic': 0.65},
    'notes':
        'Synthetic labeled corpus; screening experiment, not production certification.',
  };
  final temp = Directory.systemTemp.createTempSync('semantic-eval-');
  final dbFile = File('${temp.path}/vectors.sqlite');
  final db = sqlite3.open(dbFile.path);
  final cancel = EvaluationCancellation();
  try {
    final total = Stopwatch()..start();
    final worker = await Process.start(
      'python',
      [File.fromUri(Platform.script.resolve('local_embedding_worker.py')).path],
      environment: {
        'HF_HUB_OFFLINE': '1',
        'TRANSFORMERS_OFFLINE': '1',
        'HF_HUB_DISABLE_TELEMETRY': '1',
      },
    );
    final stdoutFuture = worker.stdout.transform(utf8.decoder).join();
    final stderrFuture = worker.stderr.transform(utf8.decoder).join();
    worker.stdin.write(
      jsonEncode({
        'model': model,
        'revision': revision,
        'corpus_count': chunks.length,
        'texts': [
          ...chunks.map((c) => c.text),
          ...queries.map((q) => q['text']),
        ],
      }),
    );
    await worker.stdin.close();
    final workerExit = await worker.exitCode.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        worker.kill();
        throw StateError('Embedding worker timed out');
      },
    );
    final workerOutput = await stdoutFuture;
    final workerErrors = await stderrFuture;
    if (workerExit != 0) {
      throw StateError(
        'Offline embedding worker exit $workerExit: $workerErrors',
      );
    }
    final evidence = jsonDecode(workerOutput) as Map<String, dynamic>;
    final allVectors = (evidence['vectors'] as List)
        .map((v) => (v as List).cast<num>().map((n) => n.toDouble()).toList())
        .toList();
    if (allVectors.length != chunks.length + queries.length) {
      throw StateError('Incomplete embedding evidence');
    }
    final byText = <String, List<double>>{};
    final texts = [
      ...chunks.map((c) => c.text),
      ...queries.map((q) => q['text'] as String),
    ];
    for (var i = 0; i < texts.length; i++) {
      byText[texts[i]] = allVectors[i];
    }
    final index = EvaluationIndex(
      db,
      '$model@$revision',
      manifest['dimension'] as int,
      (values) async => values.map((s) => byText[s]!).toList(),
    );
    final cacheTimer = Stopwatch()..start();
    final vectors = await index.vectors(
      chunks.map((c) => c.text).toList(),
      cancel,
    );
    result['corpus_cache_write_ms'] = cacheTimer.elapsedMicroseconds / 1000;
    result['index_bytes_without_queries'] = dbFile.lengthSync();
    final queryVectors = await index.vectors(
      queries.map((q) => q['text'] as String).toList(),
      cancel,
    );
    result['cold_embedding_and_cache_ms'] = total.elapsedMicroseconds / 1000;
    result['worker'] = {...evidence}..remove('vectors');
    result['index_bytes'] = dbFile.lengthSync();
    result['parent_peak_rss_bytes'] = ProcessInfo.maxRss;
    result['embedded_unique_texts'] = index.embedded;
    await index.vectors(texts, cancel);
    result['warm_reembedding_count'] =
        index.embedded - (result['embedded_unique_texts'] as int);
    final modes = <String, dynamic>{};
    for (final mode in ['lexical', 'hybrid', 'semantic']) {
      final rows = <Map<String, dynamic>>[];
      for (var i = 0; i < queries.length; i++) {
        final query = queries[i];
        final timer = Stopwatch()..start();
        final hits = rank(
          chunks,
          query['text'] as String,
          mode,
          vectors: vectors,
          queryVector: queryVectors[i],
          source: query['source'] as String?,
        );
        final relevant = (query['relevant'] as List).cast<String>().toSet();
        if (relevant.isEmpty) throw FormatException('Missing relevance labels');
        final retrieved = hits.map((r) => r.chunk.session).toList();
        final first = retrieved.indexWhere(relevant.contains);
        rows.add({
          'id': query['id'],
          'ranking_ms': timer.elapsedMicroseconds / 1000,
          'query_encode_ms': mode == 'lexical'
              ? 0
              : (evidence['query_encode_ms'] as List)[i],
          'recall_at_10':
              retrieved.toSet().intersection(relevant).length / relevant.length,
          'reciprocal_rank': first < 0 ? 0.0 : 1 / (first + 1),
          'hits': hits
              .map((r) => {'citation': r.chunk.citation, 'score': r.score})
              .toList(),
        });
      }
      double mean(String key) =>
          rows.fold<double>(0, (s, row) => s + (row[key] as num)) / rows.length;
      modes[mode] = {
        'recall_at_10': mean('recall_at_10'),
        'mrr_at_10': mean('reciprocal_rank'),
        'mean_ranking_ms': mean('ranking_ms'),
        'mean_query_encode_ms': mean('query_encode_ms'),
        'results': rows,
      };
    }
    result['modes'] = modes;
    result['status'] = 'measured';
  } catch (error) {
    result['error'] = error.toString();
    exitCode = 2;
  } finally {
    db.close();
    temp.deleteSync(recursive: true);
    final written = writeEvaluationResult(output, result);
    stdout.writeln('Semantic evaluation: ${result['status']}; ${written.path}');
  }
}
