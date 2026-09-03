import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show OpenMode, sqlite3;

import '../path_mapping/path_mapper.dart';
import '../scanner/session_scanner.dart';
import 'database_connection.dart';

const sessionCacheRepairVersion = 3;
const sessionCacheRepairCompletionKey =
    'session_cache_repair.v$sessionCacheRepairVersion.completed';

enum SessionCacheRepairCategory {
  canonical('canonical'),
  relocated('relocated'),
  fallbackDuplicate('fallback_duplicate'),
  legacyNonSessionArtifact('legacy_non_session_artifact'),
  unresolved('unresolved');

  const SessionCacheRepairCategory(this.wireName);

  final String wireName;
}

enum SessionCacheRepairStatus { completed, alreadyCompleted, postponed }

enum SessionCacheRepairPhase {
  auditing,
  creatingBackup,
  verifyingBackup,
  applying,
}

typedef SessionCacheBackupWriter =
    Future<File> Function({
      required Database source,
      required File databaseFile,
      required Directory backupDirectory,
      required String backupName,
    });

typedef SessionCacheBeforeApply = FutureOr<void> Function(Database db);

typedef SessionCachePhysicalPathResolver =
    String Function(String path, FileSystemEntityType expectedType);

class SessionCacheRepairAudit {
  const SessionCacheRepairAudit._({
    required this.auditId,
    required this.categoryCounts,
    required this.deleteEligibleCount,
    required this._entries,
  });

  final String auditId;
  final Map<SessionCacheRepairCategory, int> categoryCounts;
  final int deleteEligibleCount;
  final List<_RepairEntry> _entries;
}

class SessionCacheRepairResult {
  const SessionCacheRepairResult({
    required this.status,
    required this.reasonCode,
    required this.deletedCount,
    required this.audit,
    this.backupFile,
  });

  final SessionCacheRepairStatus status;
  final String reasonCode;
  final int deletedCount;
  final SessionCacheRepairAudit? audit;
  final File? backupFile;
}

class SessionCacheRepair {
  SessionCacheRepair({
    required this.databaseFile,
    Directory? backupDirectory,
    DateTime Function()? clock,
    SessionCacheBackupWriter? backupWriter,
    SessionCachePhysicalPathResolver? physicalPathResolver,
    this.beforeApply,
  }) : backupDirectory =
           backupDirectory ??
           Directory(p.join(databaseFile.parent.path, 'backups')),
       clock = clock ?? _utcNow,
       backupWriter = backupWriter ?? _writeVerifiedBackup,
       physicalPathResolver =
           physicalPathResolver ?? _resolvePhysicalPathStrict;

  final File databaseFile;
  final Directory backupDirectory;
  final DateTime Function() clock;
  final SessionCacheBackupWriter backupWriter;
  final SessionCachePhysicalPathResolver physicalPathResolver;
  final SessionCacheBeforeApply? beforeApply;
  int _auditSequence = 0;

  SessionCacheRepairAudit audit({
    required Database db,
    required List<SessionScanRoot> roots,
    required bool discoveryComplete,
  }) {
    final recordedAt = clock().toUtc();
    final auditId =
        'repair-$sessionCacheRepairVersion-'
        '${recordedAt.microsecondsSinceEpoch}-${++_auditSequence}';
    final entries = _classifyRows(
      db,
      roots,
      discoveryComplete: discoveryComplete,
      physicalPathResolver: physicalPathResolver,
    );
    final counts = {
      for (final category in SessionCacheRepairCategory.values) category: 0,
    };
    db.execute('begin immediate');
    try {
      db.execute('delete from session_cache_repair_manifest');
      final insert = db.prepare('''
        insert into session_cache_repair_manifest (
          audit_id, repair_version, session_rowid, row_fingerprint,
          category, reason_code, delete_eligible, recorded_at_utc
        ) values (?, ?, ?, ?, ?, ?, ?, ?)
        ''');
      try {
        for (final entry in entries) {
          counts[entry.category] = counts[entry.category]! + 1;
          insert.execute([
            auditId,
            sessionCacheRepairVersion,
            entry.rowId,
            entry.fingerprint,
            entry.category.wireName,
            entry.reasonCode,
            entry.deleteEligible ? 1 : 0,
            recordedAt.toIso8601String(),
          ]);
        }
      } finally {
        insert.close();
      }
      db.execute('commit');
    } on Object {
      db.execute('rollback');
      rethrow;
    }
    return SessionCacheRepairAudit._(
      auditId: auditId,
      categoryCounts: Map.unmodifiable(counts),
      deleteEligibleCount: entries
          .where((entry) => entry.deleteEligible)
          .length,
      entries: List.unmodifiable(entries),
    );
  }

  Future<SessionCacheRepairResult> run({
    required Database db,
    required List<SessionScanRoot> roots,
    required bool discoveryComplete,
    bool Function()? isCancellationRequested,
    void Function(SessionCacheRepairPhase phase)? onProgress,
  }) async {
    if (_repairCompleted(db)) {
      return const SessionCacheRepairResult(
        status: SessionCacheRepairStatus.alreadyCompleted,
        reasonCode: 'already_completed',
        deletedCount: 0,
        audit: null,
      );
    }
    bool cancelled() => isCancellationRequested?.call() ?? false;

    SessionCacheRepairResult cancellationResult(
      SessionCacheRepairAudit? audit,
    ) {
      return SessionCacheRepairResult(
        status: SessionCacheRepairStatus.postponed,
        reasonCode: 'cancelled',
        deletedCount: 0,
        audit: audit,
      );
    }

    if (cancelled()) {
      return cancellationResult(null);
    }
    onProgress?.call(SessionCacheRepairPhase.auditing);
    if (cancelled()) {
      return cancellationResult(null);
    }
    final hasRecognizedOwners = _hasRecognizedCodexOwners(roots);
    final cleanupDiscoveryComplete = discoveryComplete && hasRecognizedOwners;
    final repairAudit = audit(
      db: db,
      roots: roots,
      discoveryComplete: cleanupDiscoveryComplete,
    );
    if (!cleanupDiscoveryComplete) {
      return SessionCacheRepairResult(
        status: SessionCacheRepairStatus.postponed,
        reasonCode: discoveryComplete
            ? 'no_recognized_codex_owner'
            : 'root_discovery_incomplete',
        deletedCount: 0,
        audit: repairAudit,
      );
    }
    if (repairAudit.deleteEligibleCount == 0) {
      onProgress?.call(SessionCacheRepairPhase.applying);
      if (cancelled()) {
        return cancellationResult(repairAudit);
      }
      var transactionOpen = false;
      try {
        db.execute('begin immediate');
        transactionOpen = true;
        final reclassified = _classifyRows(
          db,
          roots,
          discoveryComplete: true,
          physicalPathResolver: physicalPathResolver,
        );
        if (!_sameAuditSnapshot(repairAudit._entries, reclassified)) {
          throw StateError('Repair predicates changed after the audit.');
        }
        _writeRepairCompletion(db, repairAudit.auditId, clock());
        db.execute('commit');
        transactionOpen = false;
        return SessionCacheRepairResult(
          status: SessionCacheRepairStatus.completed,
          reasonCode: 'no_changes',
          deletedCount: 0,
          audit: repairAudit,
        );
      } on Object {
        if (transactionOpen) {
          db.execute('rollback');
        }
        return SessionCacheRepairResult(
          status: SessionCacheRepairStatus.postponed,
          reasonCode: 'repair_invariant_failed',
          deletedCount: 0,
          audit: repairAudit,
        );
      }
    }
    final dataVersion = _dataVersion(db);
    File? createdBackupFile;
    try {
      onProgress?.call(SessionCacheRepairPhase.creatingBackup);
      if (cancelled()) {
        return cancellationResult(repairAudit);
      }
      final backupFile = await backupWriter(
        source: db,
        databaseFile: databaseFile,
        backupDirectory: backupDirectory,
        backupName: _backupName(repairAudit.auditId),
      );
      createdBackupFile = backupFile;
      if (p.equals(
        p.absolute(backupFile.path),
        p.absolute(databaseFile.path),
      )) {
        throw StateError('Repair backup cannot be the source database.');
      }
      onProgress?.call(SessionCacheRepairPhase.verifyingBackup);
      if (cancelled()) {
        await _discardUncommittedBackup(backupFile);
        return cancellationResult(repairAudit);
      }
      _verifyBackupSnapshot(backupFile, repairAudit);
    } on Object {
      await _discardUncommittedBackup(createdBackupFile);
      return SessionCacheRepairResult(
        status: SessionCacheRepairStatus.postponed,
        reasonCode: 'backup_failed',
        deletedCount: 0,
        audit: repairAudit,
      );
    }
    final backupFile = createdBackupFile;
    if (cancelled()) {
      await _discardUncommittedBackup(backupFile);
      return cancellationResult(repairAudit);
    }

    var transactionOpen = false;
    try {
      onProgress?.call(SessionCacheRepairPhase.applying);
      if (cancelled()) {
        await _discardUncommittedBackup(backupFile);
        return cancellationResult(repairAudit);
      }
      await beforeApply?.call(db);
      if (cancelled()) {
        await _discardUncommittedBackup(backupFile);
        return cancellationResult(repairAudit);
      }
      db.execute('begin immediate');
      transactionOpen = true;
      if (_dataVersion(db) != dataVersion) {
        throw StateError('Database changed after the repair audit.');
      }
      final reclassified = _classifyRows(
        db,
        roots,
        discoveryComplete: true,
        physicalPathResolver: physicalPathResolver,
      );
      if (!_sameAuditSnapshot(repairAudit._entries, reclassified)) {
        throw StateError('Repair predicates changed after the backup.');
      }
      var deletedCount = 0;
      for (final entry in reclassified.where(
        (candidate) => candidate.deleteEligible,
      )) {
        final rows = db.select('select id from sessions where rowid = ?', [
          entry.rowId,
        ]);
        if (rows.length != 1) {
          throw StateError('Repair candidate disappeared before deletion.');
        }
        final id = rows.single['id'] as String;
        db.execute('delete from usage_events where session_row_id = ?', [id]);
        db.execute('delete from tool_calls where session_id = ?', [id]);
        db.execute('delete from messages where session_id = ?', [id]);
        db.execute('delete from session_tags where session_id = ?', [id]);
        db.execute('delete from session_path_keys where session_id = ?', [id]);
        db.execute('delete from session_search where rowid = ?', [entry.rowId]);
        db.execute('delete from sessions where rowid = ?', [entry.rowId]);
        deletedCount++;
      }
      _writeRepairCompletion(db, repairAudit.auditId, clock());
      if (!_databaseIsHealthy(db)) {
        throw StateError('Repair database invariants failed.');
      }
      db.execute('commit');
      transactionOpen = false;
      return SessionCacheRepairResult(
        status: SessionCacheRepairStatus.completed,
        reasonCode: 'completed',
        deletedCount: deletedCount,
        audit: repairAudit,
        backupFile: backupFile,
      );
    } on Object {
      if (transactionOpen) {
        db.execute('rollback');
      }
      await _discardUncommittedBackup(backupFile);
      return SessionCacheRepairResult(
        status: SessionCacheRepairStatus.postponed,
        reasonCode: 'repair_invariant_failed',
        deletedCount: 0,
        audit: repairAudit,
      );
    }
  }

  String _backupName(String auditId) {
    final databaseName = p.basenameWithoutExtension(databaseFile.path);
    return '$databaseName.pre-session-cache-repair-v$sessionCacheRepairVersion.$auditId.sqlite';
  }

  Future<void> _discardUncommittedBackup(File? backupFile) async {
    if (backupFile == null) {
      return;
    }
    final backupPath = p.normalize(p.absolute(backupFile.path));
    final sourcePath = p.normalize(p.absolute(databaseFile.path));
    final expectedDirectory = p.normalize(p.absolute(backupDirectory.path));
    if (p.equals(backupPath, sourcePath) ||
        !p.equals(p.dirname(backupPath), expectedDirectory)) {
      return;
    }
    try {
      if (await backupFile.exists()) {
        await backupFile.delete();
      }
      await _deleteSqliteSidecars(backupFile);
    } on FileSystemException {
      // A failed repair must not be replaced by a cleanup failure. A later
      // attempt uses a unique name and can retry cleanup independently.
    }
  }

  Future<void> restoreVerifiedBackup({
    required File backupFile,
    required File destinationFile,
  }) async {
    if (!await backupFile.exists()) {
      throw StateError('Repair backup does not exist.');
    }
    if (await destinationFile.exists()) {
      throw StateError('Restore destination already exists.');
    }
    await destinationFile.parent.create(recursive: true);
    final partialFile = File('${destinationFile.path}.partial');
    if (await partialFile.exists() ||
        await _hasAnySqliteSidecar(destinationFile)) {
      throw StateError(
        'Restore destination has stale partial or sidecar files.',
      );
    }
    final source = sqlite3.open(backupFile.path, mode: OpenMode.readOnly);
    Database? destination;
    try {
      if (!_databaseIsHealthy(source)) {
        throw StateError('Repair backup failed integrity verification.');
      }
      destination = sqlite3.open(partialFile.path);
      await source.backup(destination, nPage: 256).drain<void>();
      destination.execute('pragma wal_checkpoint(truncate)');
      final journalMode = destination
          .select('pragma journal_mode = delete')
          .single
          .values
          .single;
      if (journalMode.toString().toLowerCase() != 'delete') {
        throw StateError('Restored database could not switch to one file.');
      }
      destination.close();
      destination = null;
      await _deleteSqliteSidecars(partialFile);
      _verifyDatabaseFile(partialFile);
      if (await destinationFile.exists() ||
          await _hasAnySqliteSidecar(destinationFile)) {
        throw StateError('Restore destination changed before publication.');
      }
      await partialFile.rename(destinationFile.path);
    } on Object {
      destination?.close();
      if (await partialFile.exists()) {
        await partialFile.delete();
      }
      await _deleteSqliteSidecars(partialFile);
      rethrow;
    } finally {
      source.close();
    }
  }
}

bool _repairCompleted(Database db) => db.select(
  'select 1 from app_metadata where key = ?',
  [sessionCacheRepairCompletionKey],
).isNotEmpty;

void _writeRepairCompletion(Database db, String auditId, DateTime completedAt) {
  db.execute(
    '''
    insert into app_metadata (key, value, updated_at_utc)
    values (?, ?, ?)
    on conflict(key) do update set
      value = excluded.value,
      updated_at_utc = excluded.updated_at_utc
    ''',
    [
      sessionCacheRepairCompletionKey,
      auditId,
      completedAt.toUtc().toIso8601String(),
    ],
  );
}

bool _hasRecognizedCodexOwners(List<SessionScanRoot> roots) {
  if (roots.isEmpty) {
    return false;
  }
  return roots.every((root) {
    final owner = root.availabilityRootPath;
    if (owner == null || owner.trim().isEmpty) {
      return false;
    }
    final leaf = p.basename(root.path).toLowerCase();
    return switch (root.sourceState) {
      SessionSourceState.active => leaf == 'sessions',
      SessionSourceState.codexArchived => leaf == 'archived_sessions',
      SessionSourceState.missing => false,
    };
  });
}

int _dataVersion(Database db) =>
    db.select('pragma data_version').single.values.single as int;

bool _databaseIsHealthy(Database db) {
  final integrity = db.select('pragma integrity_check');
  return integrity.length == 1 &&
      integrity.single.values.single == 'ok' &&
      db.select('pragma foreign_key_check').isEmpty;
}

bool _sameAuditSnapshot(List<_RepairEntry> left, List<_RepairEntry> right) {
  if (left.length != right.length) {
    return false;
  }
  final rightByRowId = {for (final entry in right) entry.rowId: entry};
  for (final entry in left) {
    final other = rightByRowId[entry.rowId];
    if (other == null ||
        other.fingerprint != entry.fingerprint ||
        other.category != entry.category ||
        other.reasonCode != entry.reasonCode ||
        other.deleteEligible != entry.deleteEligible) {
      return false;
    }
  }
  return true;
}

Future<File> _writeVerifiedBackup({
  required Database source,
  required File databaseFile,
  required Directory backupDirectory,
  required String backupName,
}) async {
  if (!await databaseFile.exists()) {
    throw StateError('Repair source database does not exist.');
  }
  await backupDirectory.create(recursive: true);
  final backupFile = File(p.join(backupDirectory.path, backupName));
  final partialFile = File('${backupFile.path}.partial');
  if (await backupFile.exists() || await partialFile.exists()) {
    throw StateError('Repair backup target already exists.');
  }
  Database? destination;
  try {
    destination = sqlite3.open(partialFile.path);
    await source.backup(destination, nPage: 256).drain<void>();
    destination.execute('pragma wal_checkpoint(truncate)');
    final journalMode = destination
        .select('pragma journal_mode = delete')
        .single
        .values
        .single;
    if (journalMode.toString().toLowerCase() != 'delete') {
      throw StateError('Repair backup could not switch to a single file.');
    }
    destination.close();
    destination = null;
    await _deleteSqliteSidecars(partialFile);
    await partialFile.rename(backupFile.path);
  } on Object {
    destination?.close();
    destination = null;
    if (await partialFile.exists()) {
      await partialFile.delete();
    }
    await _deleteSqliteSidecars(partialFile);
    rethrow;
  } finally {
    destination?.close();
  }
  return backupFile;
}

Future<void> _deleteSqliteSidecars(File database) async {
  for (final suffix in ['-wal', '-shm', '-journal']) {
    final sidecar = File('${database.path}$suffix');
    if (await sidecar.exists()) {
      await sidecar.delete();
    }
  }
}

Future<bool> _hasAnySqliteSidecar(File database) async {
  for (final suffix in ['-wal', '-shm', '-journal']) {
    if (await File('${database.path}$suffix').exists()) {
      return true;
    }
  }
  return false;
}

void _verifyDatabaseFile(File file) {
  final verification = sqlite3.open(file.path, mode: OpenMode.readOnly);
  try {
    if (!_databaseIsHealthy(verification)) {
      throw StateError('Repair backup did not pass SQLite integrity checks.');
    }
  } finally {
    verification.close();
  }
}

void _verifyBackupSnapshot(File file, SessionCacheRepairAudit repairAudit) {
  final verification = sqlite3.open(file.path, mode: OpenMode.readOnly);
  try {
    if (!_databaseIsHealthy(verification)) {
      throw StateError('Repair backup did not pass SQLite integrity checks.');
    }
    final schemaVersion = verification
        .select(
          'select coalesce(max(version), 0) as version from schema_version',
        )
        .single['version'];
    if (schemaVersion != 15) {
      throw StateError(
        'Repair backup schema version is not the expected version.',
      );
    }
    final rows = verification.select(
      '''
      select session_rowid, row_fingerprint, category, reason_code,
             delete_eligible
      from session_cache_repair_manifest
      where audit_id = ?
      order by session_rowid
      ''',
      [repairAudit.auditId],
    );
    if (rows.length != repairAudit._entries.length) {
      throw StateError(
        'Repair backup manifest count does not match the audit.',
      );
    }
    final entriesByRowId = {
      for (final entry in repairAudit._entries) entry.rowId: entry,
    };
    for (final row in rows) {
      final entry = entriesByRowId[row['session_rowid'] as int];
      if (entry == null ||
          row['row_fingerprint'] != entry.fingerprint ||
          row['category'] != entry.category.wireName ||
          row['reason_code'] != entry.reasonCode ||
          row['delete_eligible'] != (entry.deleteEligible ? 1 : 0)) {
        throw StateError('Repair backup manifest does not match the audit.');
      }
    }
  } finally {
    verification.close();
  }
}

List<_RepairEntry> _classifyRows(
  Database db,
  List<SessionScanRoot> roots, {
  required bool discoveryComplete,
  required SessionCachePhysicalPathResolver physicalPathResolver,
}) {
  final rows = db.select('''
    select
      s.rowid as session_rowid,
      s.*,
      (select count(*) from messages m where m.session_id = s.id)
        as owned_message_count,
      (select count(*) from tool_calls tc where tc.session_id = s.id)
        as owned_tool_count,
      (select count(*) from usage_events ue where ue.session_row_id = s.id)
        as owned_usage_count,
      (select count(*) from session_tags st where st.session_id = s.id)
        as owned_tag_count
    from sessions s
    order by s.rowid
    ''');
  final canonicalPaths = <(SessionSourceType, String)>{};
  for (final row in rows) {
    if (_stableSessionId(row).isEmpty) {
      continue;
    }
    final sourceType = _sourceType(row);
    final paths = _rowPaths(row);
    if (!_isWithinAnySessionRoot(paths, roots, sourceType)) {
      continue;
    }
    for (final path in paths) {
      canonicalPaths.add((sourceType, _pathKey(path, sourceType)));
    }
  }

  return [
    for (final row in rows)
      _classifyRow(
        row,
        roots,
        canonicalPaths,
        discoveryComplete: discoveryComplete,
        physicalPathResolver: physicalPathResolver,
      ),
  ];
}

_RepairEntry _classifyRow(
  Row row,
  List<SessionScanRoot> roots,
  Set<(SessionSourceType, String)> canonicalPaths, {
  required bool discoveryComplete,
  required SessionCachePhysicalPathResolver physicalPathResolver,
}) {
  final rowId = row['session_rowid'] as int;
  final id = row['id'] as String;
  final sourceType = _sourceType(row);
  final paths = _rowPaths(row);
  final fingerprint = sha256
      .convert(
        utf8.encode(
          jsonEncode([
            rowId,
            id,
            row['session_id'],
            row['source_type'],
            ...paths,
            row['parser_version'],
            row['is_pinned'],
            row['is_archived'],
            row['project_override'],
            row['archived_at_utc'],
            row['archive_reason'],
            row['eval_ready'],
            row['eval_status'],
            row['eval_notes'],
            row['eval_expected_output'],
            row['eval_reviewed_at_utc'],
            row['eval_updated_at_utc'],
            row['owned_message_count'],
            row['owned_tool_count'],
            row['owned_usage_count'],
            row['owned_tag_count'],
          ]),
        ),
      )
      .toString();
  final stableId = _stableSessionId(row);

  _RepairEntry entry(
    SessionCacheRepairCategory category,
    String reason, {
    bool deleteEligible = false,
  }) => _RepairEntry(
    rowId: rowId,
    fingerprint: fingerprint,
    category: category,
    reasonCode: reason,
    deleteEligible: deleteEligible,
  );

  if (!discoveryComplete) {
    return entry(
      SessionCacheRepairCategory.unresolved,
      'root_discovery_incomplete',
    );
  }
  if (stableId.isNotEmpty) {
    if (_isWithinSourceRoot(
      paths,
      roots,
      sourceType,
      SessionSourceState.active,
    )) {
      return entry(
        SessionCacheRepairCategory.canonical,
        'stable_active_session',
      );
    }
    if (_isWithinSourceRoot(
      paths,
      roots,
      sourceType,
      SessionSourceState.codexArchived,
    )) {
      return entry(
        SessionCacheRepairCategory.relocated,
        'stable_archived_session',
      );
    }
    return entry(
      SessionCacheRepairCategory.unresolved,
      'stable_identity_outside_session_roots',
    );
  }
  if (paths.any(_hasTraversalSegment)) {
    return entry(
      SessionCacheRepairCategory.unresolved,
      'path_traversal_ambiguous',
    );
  }
  if (paths.any(
    (path) => canonicalPaths.contains((sourceType, _pathKey(path, sourceType))),
  )) {
    final isEmptyLegacyFallback =
        (id.startsWith('source:') || id.startsWith('source-status:')) &&
        (row['parser_version'] as int) == 1 &&
        !_hasProtectedMetadata(row) &&
        (row['owned_message_count'] as int) == 0 &&
        (row['owned_tool_count'] as int) == 0 &&
        (row['owned_usage_count'] as int) == 0;
    return entry(
      SessionCacheRepairCategory.fallbackDuplicate,
      isEmptyLegacyFallback
          ? 'canonical_path_match_empty_legacy'
          : 'canonical_path_match_requires_reconciliation',
      deleteEligible: isEmptyLegacyFallback,
    );
  }
  if (!id.startsWith('source:') && !id.startsWith('source-status:')) {
    return entry(
      SessionCacheRepairCategory.unresolved,
      'non_fallback_identity',
    );
  }
  if (_containsSessionNamespace(paths, sourceType)) {
    return entry(
      SessionCacheRepairCategory.unresolved,
      'session_namespace_path',
    );
  }
  if (_hasProtectedMetadata(row)) {
    return entry(
      SessionCacheRepairCategory.unresolved,
      'protected_viewer_metadata',
    );
  }
  if ((row['owned_message_count'] as int) != 0) {
    return entry(SessionCacheRepairCategory.unresolved, 'owns_messages');
  }
  if ((row['owned_tool_count'] as int) != 0) {
    return entry(SessionCacheRepairCategory.unresolved, 'owns_tools');
  }
  if ((row['owned_usage_count'] as int) != 0) {
    return entry(SessionCacheRepairCategory.unresolved, 'owns_usage_events');
  }
  if ((row['parser_version'] as int) != 1) {
    return entry(
      SessionCacheRepairCategory.unresolved,
      'current_parser_version',
    );
  }
  if (_isWithinAnySessionRoot(paths, roots, sourceType)) {
    return entry(
      SessionCacheRepairCategory.unresolved,
      'fallback_in_session_root',
    );
  }
  final resolvedAliases = _resolveFileAliases(
    paths,
    sourceType,
    physicalPathResolver,
  );
  if (resolvedAliases == null) {
    return entry(
      SessionCacheRepairCategory.unresolved,
      'source_alias_resolution_ambiguous',
    );
  }
  final namespaces = {
    _knownNonSessionNamespace(
      resolvedAliases.physicalPath,
      roots,
      sourceType,
      physicalPathResolver,
    ),
  };
  if (namespaces.contains(null) || namespaces.length != 1) {
    return entry(
      SessionCacheRepairCategory.unresolved,
      'source_namespace_not_allowlisted',
    );
  }
  return entry(
    SessionCacheRepairCategory.legacyNonSessionArtifact,
    'allowlisted_non_session_namespace',
    deleteEligible: true,
  );
}

bool _hasProtectedMetadata(Row row) {
  bool enabled(String column) => (row[column] as int? ?? 0) == 1;
  bool populated(String column) =>
      (row[column] as String?)?.trim().isNotEmpty ?? false;
  return enabled('is_pinned') ||
      enabled('is_archived') ||
      enabled('project_override') ||
      enabled('eval_ready') ||
      populated('archived_at_utc') ||
      populated('archive_reason') ||
      populated('eval_status') ||
      populated('eval_notes') ||
      populated('eval_expected_output') ||
      populated('eval_reviewed_at_utc') ||
      populated('eval_updated_at_utc') ||
      (row['owned_tag_count'] as int) != 0;
}

String _stableSessionId(Row row) => (row['session_id'] as String? ?? '').trim();

SessionSourceType _sourceType(Row row) => row['source_type'] == 'wsl'
    ? SessionSourceType.wsl
    : SessionSourceType.windows;

List<String> _rowPaths(Row row) => <String>{
  for (final column in [
    'source_file_path',
    'source_file_unc_path',
    'display_path',
    'platform_path',
  ])
    if ((row[column] as String?)?.trim().isNotEmpty ?? false)
      (row[column] as String).trim(),
}.toList(growable: false);

String _pathKey(String path, SessionSourceType sourceType) {
  final raw = path.trim().replaceAll(r'\', '/');
  final absolute = raw.startsWith('/');
  final segments = <String>[];
  for (final segment in raw.split('/')) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    if (segment == '..') {
      if (segments.isNotEmpty && segments.last != '..') {
        segments.removeLast();
      } else {
        segments.add(segment);
      }
      continue;
    }
    segments.add(segment);
  }
  final normalized = '${absolute ? '/' : ''}${segments.join('/')}';
  return sourceType == SessionSourceType.windows
      ? normalized.toLowerCase()
      : normalized;
}

bool _isWithinSourceRoot(
  List<String> paths,
  List<SessionScanRoot> roots,
  SessionSourceType sourceType,
  SessionSourceState state,
) => roots
    .where((root) => root.sourceType == sourceType && root.sourceState == state)
    .any((root) => paths.any((path) => _isWithin(path, root.path, sourceType)));

bool _isWithinAnySessionRoot(
  List<String> paths,
  List<SessionScanRoot> roots,
  SessionSourceType sourceType,
) => roots
    .where((root) => root.sourceType == sourceType)
    .any((root) => paths.any((path) => _isWithin(path, root.path, sourceType)));

bool _isWithin(String path, String directory, SessionSourceType sourceType) {
  final pathKey = _pathKey(path, sourceType);
  final directoryKey = _pathKey(
    directory,
    sourceType,
  ).replaceFirst(RegExp(r'/+$'), '');
  return pathKey == directoryKey || pathKey.startsWith('$directoryKey/');
}

_ResolvedFileAliases? _resolveFileAliases(
  List<String> paths,
  SessionSourceType sourceType,
  SessionCachePhysicalPathResolver physicalPathResolver,
) {
  if (paths.isEmpty || paths.any((path) => !p.windows.isAbsolute(path))) {
    return null;
  }
  final hostPaths = paths.toSet();
  final physicalPaths = <String>[];
  final physicalKeys = <String>{};
  for (final path in hostPaths) {
    if (_hasTraversalSegment(path)) {
      return null;
    }
    try {
      final resolved = physicalPathResolver(path, FileSystemEntityType.file);
      physicalPaths.add(resolved);
      physicalKeys.add(_pathKey(resolved, sourceType));
    } on FileSystemException {
      return null;
    } on StateError {
      return null;
    }
  }
  if (physicalKeys.length != 1) {
    return null;
  }
  return _ResolvedFileAliases(physicalPath: physicalPaths.first);
}

String _resolvePhysicalPathStrict(
  String path,
  FileSystemEntityType expectedType,
) {
  final lexicalType = FileSystemEntity.typeSync(path, followLinks: false);
  if (expectedType == FileSystemEntityType.file &&
      lexicalType != FileSystemEntityType.file) {
    throw FileSystemException('Expected a regular file.', path);
  }
  if (expectedType == FileSystemEntityType.directory &&
      lexicalType != FileSystemEntityType.directory &&
      lexicalType != FileSystemEntityType.link) {
    throw FileSystemException('Expected a directory.', path);
  }
  final resolved = expectedType == FileSystemEntityType.directory
      ? Directory(path).resolveSymbolicLinksSync()
      : File(path).resolveSymbolicLinksSync();
  if (FileSystemEntity.typeSync(resolved, followLinks: false) != expectedType) {
    throw FileSystemException('Resolved entity has an unexpected type.', path);
  }
  return resolved;
}

bool _hasTraversalSegment(String path) => path
    .replaceAll(r'\', '/')
    .split('/')
    .any((segment) => segment == '.' || segment == '..');

bool _containsSessionNamespace(
  List<String> paths,
  SessionSourceType sourceType,
) {
  for (final path in paths) {
    final segments = path
        .replaceAll(r'\', '/')
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .map(
          (segment) => sourceType == SessionSourceType.windows
              ? segment.toLowerCase()
              : segment,
        );
    if (segments.contains('sessions') ||
        segments.contains('archived_sessions')) {
      return true;
    }
  }
  return false;
}

const _knownNonSessionNamespaces = {
  '.tmp',
  '.sandbox',
  '.sandbox-secrets',
  'plugins',
  'cache',
  'computer-use',
};

const _knownNonSessionRootFiles = {
  '.codex-global-state.json',
  'auth.json',
  'external_agent_session_imports.json',
  'history.jsonl',
  'internal_storage.json',
  'models_cache.json',
  'session_index.jsonl',
};

String? _knownNonSessionNamespace(
  String sourcePath,
  List<SessionScanRoot> roots,
  SessionSourceType sourceType,
  SessionCachePhysicalPathResolver physicalPathResolver,
) {
  for (final root in roots.where((root) => root.sourceType == sourceType)) {
    final owner = root.availabilityRootPath;
    if (owner == null || owner.trim().isEmpty) {
      continue;
    }
    String physicalOwner;
    try {
      physicalOwner = physicalPathResolver(
        owner,
        FileSystemEntityType.directory,
      );
    } on FileSystemException {
      continue;
    } on StateError {
      continue;
    }
    final pathKey = _pathKey(sourcePath, sourceType);
    final ownerKey = _pathKey(
      physicalOwner,
      sourceType,
    ).replaceFirst(RegExp(r'/+$'), '');
    if (!pathKey.startsWith('$ownerKey/')) {
      continue;
    }
    final relativeSegments = pathKey
        .substring(ownerKey.length + 1)
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (relativeSegments.isEmpty ||
        relativeSegments.contains('sessions') ||
        relativeSegments.contains('archived_sessions')) {
      continue;
    }
    if (relativeSegments.length == 1 &&
        _knownNonSessionRootFiles.contains(relativeSegments.single)) {
      return '<root-file>';
    }
    final namespace = relativeSegments.first;
    if (_knownNonSessionNamespaces.contains(namespace)) {
      return namespace;
    }
  }
  return null;
}

class _ResolvedFileAliases {
  const _ResolvedFileAliases({required this.physicalPath});

  final String physicalPath;
}

class _RepairEntry {
  const _RepairEntry({
    required this.rowId,
    required this.fingerprint,
    required this.category,
    required this.reasonCode,
    required this.deleteEligible,
  });

  final int rowId;
  final String fingerprint;
  final SessionCacheRepairCategory category;
  final String reasonCode;
  final bool deleteEligible;
}

DateTime _utcNow() => DateTime.now().toUtc();
