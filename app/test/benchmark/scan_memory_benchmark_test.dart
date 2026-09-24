import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/benchmark/scan_memory_benchmark.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('parses a valid isolated scan-memory benchmark request', () {
    final request = ScanMemoryBenchmarkRequest.tryParse([
      '--benchmark-scan-memory',
      '--root',
      r'C:\corpus',
      '--work',
      r'C:\scratch',
      '--sql-root',
      r'C:\repo\sql',
      '--result',
      r'C:\scratch\result.json',
      '--workers',
      '4',
      '--batch-size',
      '250',
    ]);

    expect(request, isNotNull);
    expect(request!.workers, 4);
    expect(request.batchSize, 250);
    expect(request.root.path, r'C:\corpus');
  });

  test('rejects incomplete or unsafe scan-memory benchmark requests', () {
    expect(ScanMemoryBenchmarkRequest.tryParse(const []), isNull);
    expect(
      ScanMemoryBenchmarkRequest.tryParse(const [
        '--benchmark-scan-memory',
        '--root',
        r'C:\corpus',
        '--workers',
        '0',
      ]),
      isNull,
    );
  });

  test(
    'runs the actual runtime and writes only aggregate results',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'csv_scan_memory_benchmark_',
      );
      addTearDown(() => temp.delete(recursive: true));
      final corpus = Directory(p.join(temp.path, 'corpus'))..createSync();
      final work = Directory(p.join(temp.path, 'work'));
      final resultFile = File(p.join(temp.path, 'result.json'));
      final source = File(p.join(corpus.path, 'session.jsonl'));
      await source.writeAsString(
        '${jsonEncode({
          'type': 'session_meta',
          'payload': {'id': 'benchmark-session', 'timestamp': '2026-07-27T10:00:00Z', 'cwd': r'C:\project'},
        })}\n'
        '${jsonEncode({
          'type': 'response_item',
          'timestamp': '2026-07-27T10:00:01Z',
          'payload': {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'private marker'},
            ],
          },
        })}\n',
      );

      final request = ScanMemoryBenchmarkRequest(
        root: corpus,
        workDirectory: work,
        sqlRoot: Directory(p.join(Directory.current.parent.path, 'sql')),
        resultFile: resultFile,
        workers: 1,
        batchSize: 1,
      );
      final exitCode = await runScanMemoryBenchmark(request);

      expect(exitCode, 0);
      final result = jsonDecode(await resultFile.readAsString()) as Map;
      expect(result['files'], 1);
      expect(result['files_parsed'], 1);
      expect(result['files_failed'], 0);
      expect(result['persistence_flush_count'], 1);
      expect(result['batch_source_bytes'], 32 * 1024 * 1024);
      expect(result['cache_repair_precompleted'], isTrue);
      final backupDirectory = Directory(p.join(work.path, 'backups'));
      // The production usage migration retains one recovery backup.
      expect(
        await backupDirectory.exists()
            ? await backupDirectory
                  .list()
                  .where((entry) => entry is File)
                  .length
            : 0,
        1,
      );
      final text = await resultFile.readAsString();
      expect(text, isNot(contains('private marker')));
      expect(text, isNot(contains(source.path)));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
