import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../app/runtime_session_controller.dart';
import '../config/app_settings.dart';
import '../database/database_connection.dart';
import '../database/database_migrator.dart';
import '../database/database_maintenance.dart';
import '../database/collector_versions.dart';
import '../scanner/scan_batching.dart';

const scanMemoryBenchmarkFlag = '--benchmark-scan-memory';

class ScanMemoryBenchmarkRequest {
  const ScanMemoryBenchmarkRequest({
    required this.root,
    required this.workDirectory,
    required this.sqlRoot,
    required this.resultFile,
    required this.workers,
    required this.batchSize,
  });

  final Directory root;
  final Directory workDirectory;
  final Directory sqlRoot;
  final File resultFile;
  final int workers;
  final int batchSize;

  static ScanMemoryBenchmarkRequest? tryParse(List<String> arguments) {
    if (!arguments.contains(scanMemoryBenchmarkFlag)) {
      return null;
    }
    final root = _option(arguments, '--root');
    final work = _option(arguments, '--work');
    final sqlRoot = _option(arguments, '--sql-root');
    final result = _option(arguments, '--result');
    final workers = int.tryParse(_option(arguments, '--workers') ?? '');
    final batchSize = int.tryParse(_option(arguments, '--batch-size') ?? '');
    if ([
          root,
          work,
          sqlRoot,
          result,
        ].any((value) => value == null || value.trim().isEmpty) ||
        workers == null ||
        workers <= 0 ||
        batchSize == null ||
        batchSize <= 0) {
      return null;
    }
    return ScanMemoryBenchmarkRequest(
      root: Directory(root!),
      workDirectory: Directory(work!),
      sqlRoot: Directory(sqlRoot!),
      resultFile: File(result!),
      workers: workers,
      batchSize: batchSize,
    );
  }
}

Future<int> runScanMemoryBenchmark(ScanMemoryBenchmarkRequest request) async {
  if (!await request.root.exists() || !await request.sqlRoot.exists()) {
    return 66;
  }
  await request.workDirectory.create(recursive: true);
  final emptyWslRoot = Directory(
    p.join(request.workDirectory.path, 'empty-wsl'),
  );
  await emptyWslRoot.create(recursive: true);
  final settingsFile = File(
    p.join(request.workDirectory.path, 'settings.toml'),
  );
  await SettingsRepository(settingsFile).save(
    AppSettings.defaults().copyWith(
      paths: PathSettings(
        windowsCodexPath: request.root.path,
        wslCodexUncPath: emptyWslRoot.path,
      ),
      logging: LoggingSettings(
        level: 'info',
        logFile: p.join(request.workDirectory.path, 'logs', 'benchmark.log'),
        maxLogFiles: 1,
        maxLogSizeMb: 1,
      ),
    ),
  );

  final databaseFile = File(
    p.join(request.workDirectory.path, 'benchmark.sqlite'),
  );
  final startup = await DatabaseMigrator(
    sqlRoot: request.sqlRoot,
  ).openAndMigrate(databaseFile, deferUsageMigration: true);
  if (!startup.canStartNormalUi) {
    return 70;
  }
  final migration = await startPendingDatabaseMigration(
    databaseFile,
    sqlRoot: request.sqlRoot,
  );
  if (migration != null && !(await migration.result).succeeded) return 70;
  final preflightDb = openFileBackedDatabase(databaseFile);
  try {
    preflightDb.execute(
      '''
      insert into app_metadata (key, value, updated_at_utc)
      values (?, 'benchmark-post-repair-state', ?)
      on conflict(key) do update set
        value = excluded.value,
        updated_at_utc = excluded.updated_at_utc
      ''',
      [
        sessionCacheRepairCompletionKey,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
  } finally {
    preflightDb.close();
  }

  final stopwatch = Stopwatch()..start();
  final batchingPolicy = ScanBatchingPolicy(
    parsedSessionFlushBatchSize: request.batchSize,
    fullRowSnapshotBatchSize: request.batchSize * 2,
  );
  final refresh = await RuntimeSessionController(
    settingsFile: settingsFile,
    databaseFile: databaseFile,
    parserWorkerCountOverride: request.workers,
    scanBatchingPolicy: batchingPolicy,
    // Only the requested corpus is timed.
    claudeProjectRoots: const [],
  ).refresh();
  stopwatch.stop();

  final db = openFileBackedDatabase(databaseFile);
  late final int filesParsed;
  late final int filesSkipped;
  late final int filesFailed;
  try {
    final scanRun = db.select('''
      select files_parsed, files_skipped, files_failed
      from scan_runs
      order by id desc
      limit 1
    ''').single;
    filesParsed = scanRun['files_parsed'] as int;
    filesSkipped = scanRun['files_skipped'] as int;
    filesFailed = scanRun['files_failed'] as int;
  } finally {
    db.close();
  }

  var files = 0;
  var totalBytes = 0;
  await for (final entity in request.root.list(
    recursive: true,
    followLinks: false,
  )) {
    if (entity is! File) {
      continue;
    }
    final lowerPath = entity.path.toLowerCase();
    if (!lowerPath.endsWith('.json') && !lowerPath.endsWith('.jsonl')) {
      continue;
    }
    files++;
    totalBytes += await entity.length();
  }

  final report = <String, Object?>{
    'parser_version': collectorCodexParserVersion,
    'workers': request.workers,
    'batch_size': request.batchSize,
    'batch_source_bytes': batchingPolicy.parsedSessionFlushSourceBytes,
    'cache_repair_precompleted': true,
    'files': files,
    'total_bytes': totalBytes,
    'elapsed_ms': stopwatch.elapsedMilliseconds,
    'files_parsed': filesParsed,
    'files_skipped': filesSkipped,
    'files_failed': filesFailed,
    'persistence_flush_count': refresh.persistenceFlushCount,
    'rows_available': refresh.rows.length,
    'cancelled': refresh.cancelled,
  };
  await request.resultFile.parent.create(recursive: true);
  final temporaryResult = File('${request.resultFile.path}.tmp');
  await temporaryResult.writeAsString('${jsonEncode(report)}\n', flush: true);
  if (await request.resultFile.exists()) {
    await request.resultFile.delete();
  }
  await temporaryResult.rename(request.resultFile.path);
  return filesFailed == 0 && !refresh.cancelled ? 0 : 1;
}

String? _option(List<String> arguments, String name) {
  for (var index = 0; index < arguments.length; index++) {
    final argument = arguments[index];
    if (argument == name && index + 1 < arguments.length) {
      return arguments[index + 1];
    }
    if (argument.startsWith('$name=')) {
      return argument.substring(name.length + 1);
    }
  }
  return null;
}
