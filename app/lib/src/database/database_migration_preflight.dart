import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show SqliteException, OpenMode, sqlite3;

import 'database_backup.dart';
import 'database_connection.dart';
import 'disk_space_probe.dart';
import 'maintenance_job.dart';

export 'disk_space_probe.dart' show DiskVolumeSpace;

const _minimumRecoveryReserveBytes = 64 * 1024 * 1024;

final class MigrationSpaceRequirement {
  const MigrationSpaceRequirement({
    required this.volumeKey,
    required this.availableBytes,
    required this.requiredBytes,
    this.allocations = const {},
  });

  final String volumeKey;
  final int availableBytes;
  final int requiredBytes;
  final Map<String, int> allocations;
}

final class DatabaseMigrationPreflightResult {
  const DatabaseMigrationPreflightResult({
    required this.backup,
    required this.spaceRequirements,
  });

  final VerifiedSqliteBackup backup;
  final List<MigrationSpaceRequirement> spaceRequirements;
}

final class InsufficientMigrationSpaceException implements Exception {
  const InsufficientMigrationSpaceException(this.requirement);

  final MigrationSpaceRequirement requirement;

  @override
  String toString() =>
      'Insufficient free space on ${requirement.volumeKey}: '
      '${requirement.availableBytes} bytes available, '
      '${requirement.requiredBytes} bytes required.';
}

typedef MigrationDiskSpaceProbe =
    Future<DiskVolumeSpace> Function(Directory directory);

final class DatabaseMigrationPreflight {
  DatabaseMigrationPreflight({
    SqliteBackupService? backupService,
    MigrationDiskSpaceProbe? diskSpaceProbe,
  }) : _backupService = backupService ?? SqliteBackupService(),
       _diskSpaceProbe = diskSpaceProbe ?? _probePlatformDiskSpace;

  final SqliteBackupService _backupService;
  final MigrationDiskSpaceProbe _diskSpaceProbe;

  /// Checks additional free space, not the size of already allocated files.
  /// The caller must verify its recovery receipt before setting
  /// [backupAlreadyPresent]; merely finding a file is insufficient.
  Future<List<MigrationSpaceRequirement>> checkSpace({
    required Database database,
    required File databaseFile,
    required Directory backupDirectory,
    required Directory temporaryDirectory,
    bool backupAlreadyPresent = false,
  }) async {
    final allocations = _estimateAllocations(database);
    final requested = [
      (
        databaseFile.parent,
        {
          'shadow_tables': allocations['shadow_tables']!,
          'final_indexes': allocations['final_indexes']!,
          'wal': allocations['wal']!,
        },
      ),
      (
        backupDirectory,
        {
          'verified_backup': backupAlreadyPresent
              ? 0
              : allocations['verified_backup']!,
        },
      ),
      (
        temporaryDirectory,
        {'temporary_index_build': allocations['temporary_index_build']!},
      ),
    ];
    final byVolume = <String, MigrationSpaceRequirement>{};
    for (final request in requested) {
      final space = await _diskSpaceProbe(request.$1);
      final existing = byVolume[space.volumeKey];
      final volumeAllocations = {...?existing?.allocations, ...request.$2};
      final allocatedBytes = volumeAllocations.values.fold<int>(
        0,
        (total, bytes) => total + bytes,
      );
      byVolume[space.volumeKey] = MigrationSpaceRequirement(
        volumeKey: space.volumeKey,
        availableBytes: existing == null
            ? space.availableBytes
            : math.min(existing.availableBytes, space.availableBytes),
        requiredBytes: (allocatedBytes * 6 + 4) ~/ 5,
        allocations: Map.unmodifiable(volumeAllocations),
      );
    }
    for (final requirement in byVolume.values) {
      if (requirement.availableBytes < requirement.requiredBytes) {
        throw InsufficientMigrationSpaceException(requirement);
      }
    }
    return List.unmodifiable(byVolume.values);
  }

  Future<DatabaseMigrationPreflightResult> run({
    required Database database,
    required MaintenanceJobRepository jobs,
    required MaintenanceJobLease lease,
    required File databaseFile,
    required Directory backupDirectory,
    required Directory temporaryDirectory,
    void Function(double fraction)? onBackupProgress,
  }) async {
    _verifySource(database);
    final startingJob = jobs.read(lease.jobId)!;
    final startingPayload = _readPayload(startingJob.payloadJson);
    final recordedBackup = _readBackupEvidence(startingJob.payloadJson);
    var intent = _readBackupIntent(startingPayload);
    final backupFile = File(
      recordedBackup?['path'] as String? ??
          intent?['path'] as String? ??
          p.join(
            backupDirectory.path,
            'usage-projection-job-${lease.jobId}.sqlite',
          ),
    );
    final VerifiedSqliteBackup backup;
    final List<MigrationSpaceRequirement> spaceRequirements;
    Object? heartbeatError;
    final heartbeatInterval = Duration(
      milliseconds: (lease.leaseDuration.inMilliseconds ~/ 3).clamp(
        1000,
        10000,
      ),
    );
    final heartbeat = Timer.periodic(heartbeatInterval, (_) {
      try {
        jobs.renew(lease);
      } on Object catch (error) {
        heartbeatError = error;
      }
    });
    try {
      VerifiedSqliteBackup? existingBackup;
      if (recordedBackup != null) {
        existingBackup = await _backupService.inspect(backupFile);
        if (existingBackup.lengthBytes != recordedBackup['length_bytes'] ||
            existingBackup.sha256 != recordedBackup['sha256']) {
          throw StateError(
            'Recorded migration backup no longer matches its verified evidence.',
          );
        }
      } else if (await backupFile.exists()) {
        _verifyOrphanBackupIdentity(backupFile, intent ?? const {});
        existingBackup = await _backupService.inspect(backupFile);
      }
      spaceRequirements = await checkSpace(
        database: database,
        databaseFile: databaseFile,
        backupDirectory: backupFile.parent,
        temporaryDirectory: temporaryDirectory,
        backupAlreadyPresent: existingBackup != null,
      );
      if (recordedBackup == null && intent == null) {
        final random = math.Random.secure();
        intent = {
          'identity': List.generate(
            16,
            (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join(),
          'job_id': lease.jobId,
          'job_type': startingJob.jobType,
          'path': backupFile.absolute.path,
        };
        startingPayload['backup_intent'] = intent;
        jobs.commitBatch(
          lease: lease,
          phase: startingJob.phase,
          completedUnits: startingJob.completedUnits,
          totalUnits: startingJob.totalUnits,
          lastProcessedRowId: startingJob.lastProcessedRowId,
          statusMessage: 'Preparing verified migration backup.',
          payloadJson: jsonEncode(startingPayload),
          apply: (_) {},
        );
      }
      if (existingBackup != null) {
        backup = existingBackup;
      } else {
        await _discardAbandonedPartialBackup(backupFile);
        backup = await _backupService.create(
          source: database,
          databaseFile: databaseFile,
          backupDirectory: backupFile.parent,
          backupName: p.basename(backupFile.path),
          onProgress: (fraction) {
            jobs.renew(lease);
            onBackupProgress?.call(fraction);
          },
        );
      }
    } finally {
      heartbeat.cancel();
    }
    if (heartbeatError case final error?) {
      Error.throwWithStackTrace(error, StackTrace.current);
    }
    final job = jobs.read(lease.jobId)!;
    final payload = _mergeBackupEvidence(job.payloadJson, backup);
    jobs.commitBatch(
      lease: lease,
      phase: recordedBackup == null ? 'backup_complete' : job.phase,
      completedUnits: job.completedUnits,
      totalUnits: job.totalUnits,
      lastProcessedRowId: job.lastProcessedRowId,
      statusMessage: 'Verified migration backup created.',
      payloadJson: payload,
      apply: (_) {},
    );
    return DatabaseMigrationPreflightResult(
      backup: backup,
      spaceRequirements: spaceRequirements,
    );
  }
}

Map<String, Object?> _readPayload(String? payloadJson) {
  if (payloadJson == null || payloadJson.trim().isEmpty) return {};
  final payload = jsonDecode(payloadJson);
  if (payload is! Map<String, Object?>) {
    throw StateError('Maintenance job payload must be a JSON object.');
  }
  return payload;
}

Map<String, Object?>? _readBackupIntent(Map<String, Object?> payload) {
  if (!payload.containsKey('backup_intent')) return null;
  final intent = payload['backup_intent'];
  if (intent is! Map<String, Object?> ||
      intent['identity'] is! String ||
      !RegExp(r'^[0-9a-f]{32}$').hasMatch(intent['identity'] as String) ||
      intent['job_id'] is! int ||
      intent['job_type'] is! String ||
      intent['path'] is! String ||
      !p.isAbsolute(intent['path'] as String)) {
    throw StateError('Recorded migration backup intent is incomplete.');
  }
  return intent;
}

void _verifyOrphanBackupIdentity(File backup, Map<String, Object?> intent) {
  final verification = sqlite3.open(backup.path, mode: OpenMode.readOnly);
  try {
    final rows = verification.select(
      'select payload_json from maintenance_jobs where id = ? and job_type = ?',
      [intent['job_id'], intent['job_type']],
    );
    if (rows.length == 1) {
      final embedded = _readBackupIntent(
        _readPayload(rows.single['payload_json'] as String?),
      );
      if (embedded?['identity'] == intent['identity'] &&
          embedded?['path'] == intent['path']) {
        return;
      }
    }
  } on SqliteException {
    // A valid but unrelated SQLite file need not contain maintenance metadata.
  } finally {
    verification.close();
  }
  throw StateError(
    'Existing backup cannot be identified as this migration recovery source. '
    'Move ${backup.path} to a separate safe location, then retry. Do not delete it.',
  );
}

Map<String, Object?>? _readBackupEvidence(String? payloadJson) {
  if (payloadJson == null || payloadJson.trim().isEmpty) return null;
  final payload = jsonDecode(payloadJson);
  if (payload is! Map<String, Object?>) {
    throw StateError('Maintenance job payload must be a JSON object.');
  }
  if (!payload.containsKey('backup')) return null;
  final backup = payload['backup'];
  if (backup is! Map<String, Object?> ||
      backup['path'] is! String ||
      !p.isAbsolute(backup['path'] as String) ||
      backup['length_bytes'] is! int ||
      (backup['length_bytes'] as int) <= 0 ||
      backup['sha256'] is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(backup['sha256'] as String)) {
    throw StateError('Recorded migration backup evidence is incomplete.');
  }
  return backup;
}

Future<void> _discardAbandonedPartialBackup(File backupFile) async {
  final partial = File('${backupFile.path}.partial');
  for (final path in [
    partial.path,
    '${partial.path}-wal',
    '${partial.path}-shm',
    '${partial.path}-journal',
  ]) {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }
}

void _verifySource(Database database) {
  final quickCheck = database.select('pragma quick_check');
  if (quickCheck.length != 1 || quickCheck.single.values.single != 'ok') {
    throw StateError('Source database failed SQLite quick_check.');
  }
  if (database.select('pragma foreign_key_check').isNotEmpty) {
    throw StateError('Source database failed foreign-key verification.');
  }
}

Map<String, int> _estimateAllocations(Database database) {
  final pageSize =
      database.select('pragma page_size').single.values.single as int;
  final pageCount =
      database.select('pragma page_count').single.values.single as int;
  // The backup API copies the logical database, including pages still in WAL,
  // but does not duplicate historical WAL frames or shared-memory bookkeeping.
  final sourceBytes = pageSize * pageCount;
  var tableBytes = sourceBytes;
  var indexBytes = sourceBytes;
  var largestIndexBytes = sourceBytes;
  var allocatedShadowBytes = 0;
  var allocatedContextBytes = 0;
  var allocatedDailyBytes = 0;
  var allocatedIndexBytes = 0;
  try {
    final tables = database
        .select("select name from sqlite_schema where type = 'table'")
        .map((row) => row['name'] as String)
        .toSet();
    // After cutover the retained legacy table remains the estimate's baseline,
    // not free space. Its indexes must never count as allocated target indexes.
    final sourceTable = tables.contains('usage_events_legacy')
        ? 'usage_events_legacy'
        : 'usage_events';
    final targetTable = tables.contains('usage_events_next')
        ? 'usage_events_next'
        : sourceTable == 'usage_events_legacy'
        ? 'usage_events'
        : null;
    const contextTables = {
      'usage_path_contexts',
      'usage_path_context_aliases',
      'usage_context_project_candidates',
    };
    const dailyTables = {'usage_session_daily', 'usage_cost_dirty_partitions'};
    final targetTables = {?targetTable, ...contextTables, ...dailyTables};
    final measuredTables = [sourceTable, ...targetTables];
    final placeholders = List.filled(measuredTables.length, '?').join(',');
    final sizes = database.select('''
      select s.name, s.type, s.tbl_name, sum(d.pgsize) as bytes
      from sqlite_schema s join dbstat d on d.name = s.name
      where s.type in ('table', 'index')
        and s.tbl_name in ($placeholders)
      group by s.name, s.type, s.tbl_name
    ''', measuredTables);
    if (sizes.any((row) => row['name'] == sourceTable)) {
      tableBytes =
          sizes.singleWhere((row) => row['name'] == sourceTable)['bytes']
              as int;
      indexBytes = 0;
      largestIndexBytes = pageSize;
      for (final row in sizes) {
        final bytes = row['bytes'] as int;
        final table = row['tbl_name'] as String;
        if (row['type'] == 'index') {
          if (table == sourceTable) {
            indexBytes += bytes;
          } else {
            allocatedIndexBytes += bytes;
          }
          largestIndexBytes = math.max(largestIndexBytes, bytes);
        } else if (table == targetTable) {
          allocatedShadowBytes += bytes;
        } else if (contextTables.contains(table)) {
          allocatedContextBytes += bytes;
        } else if (dailyTables.contains(table)) {
          allocatedDailyBytes += bytes;
        }
      }
    }
  } on SqliteException {
    // ponytail: SQLite builds without dbstat use whole-database bounds. Do not
    // scan every event or add a database dependency just to refine headroom.
  }
  // Do not assume context deduplication or daily aggregation will save space:
  // reserve one source-table equivalent each for shadow events, raw contexts,
  // and daily rows. Their new indexes receive three further equivalents in
  // addition to the measured event indexes. Deduct only measured target pages
  // already allocated, capped per table class so one oversized target cannot
  // consume another's reserve. Never credit retired tables or freelist pages.
  largestIndexBytes = math.max(largestIndexBytes, tableBytes);
  return {
    'verified_backup': sourceBytes,
    'shadow_tables':
        math.max<int>(0, tableBytes - allocatedShadowBytes) +
        math.max<int>(0, tableBytes - allocatedContextBytes) +
        math.max<int>(0, tableBytes - allocatedDailyBytes),
    'final_indexes': math.max(
      0,
      indexBytes + tableBytes * 3 - allocatedIndexBytes,
    ),
    'temporary_index_build': largestIndexBytes * 2,
    // An atomic index build can hold all its frames until commit. Reserve two
    // index equivalents for frames/page overhead, with 64 MiB for small DBs.
    // The worker must checkpoint between indexes and bounded copy batches.
    'wal': math.max(_minimumRecoveryReserveBytes, largestIndexBytes * 2),
  };
}

String _mergeBackupEvidence(String? payloadJson, VerifiedSqliteBackup backup) {
  final payload = <String, Object?>{};
  if (payloadJson != null && payloadJson.trim().isNotEmpty) {
    final decoded = jsonDecode(payloadJson);
    if (decoded is! Map<String, Object?>) {
      throw StateError('Maintenance job payload must be a JSON object.');
    }
    payload.addAll(decoded);
  }
  payload['backup'] = {
    'path': backup.file.path,
    'length_bytes': backup.lengthBytes,
    'sha256': backup.sha256,
    'sqlite_version': backup.sqliteVersion,
    'restore':
        'Close the application and restore this verified file to a new path before replacing the original database.',
  };
  return jsonEncode(payload);
}

/// Each phase boundary re-probes every target directory: free space can
/// shrink between phases, and a Win32 probe costs microseconds.
Future<DiskVolumeSpace> _probePlatformDiskSpace(Directory directory) async =>
    DiskSpaceProbe.forCurrentPlatform().probe(directory);
