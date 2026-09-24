import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'database_connection.dart';

export '../config/app_settings.dart' show defaultBackupRetentionDays;

final class PrunedBackup {
  const PrunedBackup({required this.path, required this.bytes});

  final String path;
  final int bytes;
}

final class BackupRetentionResult {
  const BackupRetentionResult({required this.deleted, required this.failed});

  final List<PrunedBackup> deleted;

  /// Files that could not be deleted, such as a backup still open elsewhere.
  /// They are retried on the next run.
  final List<String> failed;
}

/// Deletes the viewer's own database backups once they are older than the
/// retention period.
///
/// Only files in the `backups` folder beside the database whose whole name
/// matches a viewer backup are considered: `usage-pre16-<32 hex>.sqlite`
/// (startup usage migration) and the legacy session cache repair copies
/// `<stem>.pre-session-cache-repair-v1|v2.repair-<v>-<micros>-<n>.sqlite`.
/// The collector prunes its own v3 repair copies. SQLite side files
/// (`-wal`, `-shm`, `-journal`) go with their backup.
///
/// A usage backup is kept whatever its age while its migration is
/// unfinished: its recovery receipt still exists, or its latest job has not
/// succeeded. Legacy v1/v2 repairs no longer run, so none can be resumed.
final class ViewerBackupRetention {
  ViewerBackupRetention({
    required this.databaseFile,
    required this.retention,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  final File databaseFile;
  final Duration retention;
  final DateTime Function() clock;

  static const _sideSuffixes = ['-wal', '-shm', '-journal'];
  static final _usage = RegExp(r'^usage-pre16-[0-9a-f]{32}\.sqlite$');

  Directory get backupDirectory =>
      Directory(p.join(databaseFile.parent.path, 'backups'));

  BackupRetentionResult prune(Database db) {
    final deleted = <PrunedBackup>[];
    final failed = <String>[];
    final directory = backupDirectory;
    if (!directory.existsSync()) {
      return BackupRetentionResult(deleted: deleted, failed: failed);
    }
    final usage = _usageMigration(db);
    final legacy = RegExp(
      '^${RegExp.escape(p.basenameWithoutExtension(databaseFile.path))}'
      r'\.pre-session-cache-repair-v([12])\.repair-\1-(\d+)-\d+\.sqlite$',
    );
    // Backup name -> (backup file, side files).
    final groups = <String, (File?, List<File>)>{};
    for (final entity in directory.listSync(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final suffix = _sideSuffixes.where(name.endsWith).firstOrNull;
      if (suffix == null) {
        final group = groups[name];
        groups[name] = (entity, group?.$2 ?? []);
      } else {
        final base = name.substring(0, name.length - suffix.length);
        final group = groups[base] ??= (null, []);
        group.$2.add(entity);
      }
    }
    final now = clock().toUtc();
    for (final MapEntry(key: name, value: (backup, sides)) in groups.entries) {
      DateTime? created;
      if (_usage.hasMatch(name)) {
        if (usage.unfinished) continue;
        created = usage.createdByName[name] ?? _modified(backup, sides);
      } else if (legacy.firstMatch(name) case final match?) {
        created = DateTime.fromMicrosecondsSinceEpoch(
          int.parse(match.group(2)!),
          isUtc: true,
        );
      }
      if (created == null || now.difference(created) < retention) continue;
      // Side files belong to the backup; keep them while it stays.
      if (backup != null && !_delete(backup, deleted, failed)) continue;
      for (final side in sides) {
        _delete(side, deleted, failed);
      }
    }
    return BackupRetentionResult(deleted: deleted, failed: failed);
  }

  static DateTime? _modified(File? backup, List<File> sides) {
    for (final file in [?backup, ...sides]) {
      try {
        return file.lastModifiedSync().toUtc();
      } on FileSystemException {
        continue;
      }
    }
    return null;
  }

  static bool _delete(
    File file,
    List<PrunedBackup> deleted,
    List<String> failed,
  ) {
    try {
      final bytes = file.lengthSync();
      file.deleteSync();
      deleted.add(PrunedBackup(path: file.path, bytes: bytes));
      return true;
    } on FileSystemException {
      failed.add(file.path);
      return false;
    }
  }
}

/// Whether the startup usage migration still needs its backup, and when the
/// completed migration recorded each backup.
({bool unfinished, Map<String, DateTime> createdByName}) _usageMigration(
  Database db,
) {
  try {
    if (db
        .select(
          "select 1 from app_metadata where key='usage_migration_bootstrap'",
        )
        .isNotEmpty) {
      return (unfinished: true, createdByName: const {});
    }
    final rows = db.select('''
      select state, created_at_utc, payload_json from maintenance_jobs
      where job_type='usage_projection_migration' order by id desc limit 1
    ''');
    if (rows.isEmpty) return (unfinished: false, createdByName: const {});
    final job = rows.single;
    if (job['state'] != 'succeeded') {
      return (unfinished: true, createdByName: const {});
    }
    final created = <String, DateTime>{};
    final payload = jsonDecode(job['payload_json'] as String? ?? 'null');
    if (payload case {'backup': {'path': final String path}}) {
      created[p.basename(path)] = DateTime.parse(
        job['created_at_utc'] as String,
      ).toUtc();
    }
    return (unfinished: false, createdByName: created);
  } on Object {
    // An unreadable receipt or job keeps every usage backup.
    return (unfinished: true, createdByName: const {});
  }
}
