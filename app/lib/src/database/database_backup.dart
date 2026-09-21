import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' show OpenMode, sqlite3;

import 'database_connection.dart';

typedef SqliteBackupStreamFactory =
    Stream<double> Function({
      required Database source,
      required Database destination,
      required int pagesPerStep,
    });

typedef SqliteBeforePublish = FutureOr<void> Function(File finalFile);

final class VerifiedSqliteBackup {
  const VerifiedSqliteBackup({
    required this.file,
    required this.lengthBytes,
    required this.sha256,
    required this.sqliteVersion,
  });

  final File file;
  final int lengthBytes;
  final String sha256;
  final String sqliteVersion;
}

final class SqliteBackupService {
  SqliteBackupService({
    SqliteBackupStreamFactory? backupStreamFactory,
    this._beforePublish,
    this.pagesPerStep = 256,
  }) : _backupStreamFactory = backupStreamFactory ?? _backup;

  final SqliteBackupStreamFactory _backupStreamFactory;
  final SqliteBeforePublish? _beforePublish;
  final int pagesPerStep;

  Future<VerifiedSqliteBackup> create({
    required Database source,
    required File databaseFile,
    required Directory backupDirectory,
    required String backupName,
    void Function(double fraction)? onProgress,
  }) async {
    if (pagesPerStep <= 0) {
      throw StateError('Backup page batch size must be greater than zero.');
    }
    if (!await databaseFile.exists()) {
      throw StateError('Backup source database does not exist.');
    }
    await backupDirectory.create(recursive: true);
    final backupFile = File(p.join(backupDirectory.path, backupName));
    final partialFile = File('${backupFile.path}.partial');
    _validateTarget(databaseFile, backupFile);
    if (await backupFile.exists() ||
        await partialFile.exists() ||
        await _hasAnySqliteSidecar(backupFile)) {
      throw StateError('Backup target already exists.');
    }

    Database? destination;
    try {
      onProgress?.call(0);
      destination = sqlite3.open(partialFile.path);
      var lastProgress = 0.0;
      await for (final progress in _backupStreamFactory(
        source: source,
        destination: destination,
        pagesPerStep: pagesPerStep,
      )) {
        final bounded = progress.clamp(lastProgress, 1.0).toDouble();
        lastProgress = bounded;
        onProgress?.call(bounded);
      }
      destination.execute('pragma wal_checkpoint(truncate)');
      final journalMode = destination
          .select('pragma journal_mode = delete')
          .single
          .values
          .single
          .toString()
          .toLowerCase();
      if (journalMode != 'delete') {
        throw StateError('Backup could not switch to a single file.');
      }
      destination.close();
      destination = null;
      await _deleteSqliteSidecars(partialFile);
      _verifyDatabaseFile(partialFile);
      await _beforePublish?.call(backupFile);
      if (await backupFile.exists() || await _hasAnySqliteSidecar(backupFile)) {
        throw StateError(
          'Backup target appeared while the backup was running.',
        );
      }
      await partialFile.rename(backupFile.path);
      onProgress?.call(1);
      final digest = await sha256.bind(backupFile.openRead()).first;
      return VerifiedSqliteBackup(
        file: backupFile,
        lengthBytes: await backupFile.length(),
        sha256: digest.toString(),
        sqliteVersion: source
            .select('select sqlite_version()')
            .single
            .values
            .single
            .toString(),
      );
    } on Object {
      destination?.close();
      if (await partialFile.exists()) {
        await partialFile.delete();
      }
      await _deleteSqliteSidecars(partialFile);
      rethrow;
    } finally {
      destination?.close();
    }
  }

  Future<VerifiedSqliteBackup> inspect(File backup) async {
    if (!await backup.exists()) {
      throw StateError('Backup does not exist.');
    }
    final verification = sqlite3.open(backup.path, mode: OpenMode.readOnly);
    try {
      _verifyDatabase(verification);
      final digest = await sha256.bind(backup.openRead()).first;
      return VerifiedSqliteBackup(
        file: backup,
        lengthBytes: await backup.length(),
        sha256: digest.toString(),
        sqliteVersion: verification
            .select('select sqlite_version()')
            .single
            .values
            .single
            .toString(),
      );
    } finally {
      verification.close();
    }
  }

  Future<void> restore({
    required File backup,
    required File destinationFile,
  }) async {
    if (!await backup.exists()) {
      throw StateError('Backup does not exist.');
    }
    if (await destinationFile.exists()) {
      throw StateError('Restore destination already exists.');
    }
    await destinationFile.parent.create(recursive: true);
    final partialFile = File('${destinationFile.path}.partial');
    if (await partialFile.exists() ||
        await _hasAnySqliteSidecar(destinationFile)) {
      throw StateError('Restore destination has stale temporary files.');
    }
    final source = sqlite3.open(backup.path, mode: OpenMode.readOnly);
    Database? destination;
    try {
      _verifyDatabase(source);
      destination = sqlite3.open(partialFile.path);
      await source.backup(destination, nPage: pagesPerStep).drain<void>();
      destination.execute('pragma wal_checkpoint(truncate)');
      final journalMode = destination
          .select('pragma journal_mode = delete')
          .single
          .values
          .single
          .toString()
          .toLowerCase();
      if (journalMode != 'delete') {
        throw StateError('Restored database could not switch to one file.');
      }
      destination.close();
      destination = null;
      await _deleteSqliteSidecars(partialFile);
      _verifyDatabaseFile(partialFile);
      await _beforePublish?.call(destinationFile);
      if (await destinationFile.exists() ||
          await _hasAnySqliteSidecar(destinationFile)) {
        throw StateError(
          'Restore destination appeared while the restore was running.',
        );
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
      destination?.close();
      source.close();
    }
  }
}

Stream<double> _backup({
  required Database source,
  required Database destination,
  required int pagesPerStep,
}) => source.backup(destination, nPage: pagesPerStep);

void _validateTarget(File source, File target) {
  if (p.equals(p.absolute(source.path), p.absolute(target.path))) {
    throw StateError('Backup target cannot be the source database.');
  }
}

void _verifyDatabaseFile(File file) {
  final verification = sqlite3.open(file.path, mode: OpenMode.readOnly);
  try {
    _verifyDatabase(verification);
  } finally {
    verification.close();
  }
}

void _verifyDatabase(Database database) {
  final integrity = database.select('pragma integrity_check');
  if (integrity.length != 1 || integrity.single.values.single != 'ok') {
    throw StateError('Backup failed SQLite integrity verification.');
  }
  if (database.select('pragma foreign_key_check').isNotEmpty) {
    throw StateError('Backup failed foreign-key verification.');
  }
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
