import 'dart:io';

import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/session_cache_repair.dart';
import 'package:codex_sessions_viewer/src/parser/codex_session_parser.dart';
import 'package:codex_sessions_viewer/src/path_mapping/path_mapper.dart';
import 'package:codex_sessions_viewer/src/scanner/session_scanner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('persists the five content-safe repair audit categories', () async {
    final fixture = await _RepairFixture.create();
    addTearDown(fixture.dispose);

    final activeFile = await fixture.file('sessions/canonical.jsonl');
    final archivedFile = await fixture.file(
      'archived_sessions/relocated.jsonl',
    );
    final pluginFile = await fixture.file('plugins/cache/artifact.json');

    final canonicalRowId = fixture.insertSession(
      id: 'session:canonical',
      sessionId: 'canonical',
      sourcePath: activeFile.path,
      sourceState: 'active',
      parserVersion: 2,
    );
    final relocatedRowId = fixture.insertSession(
      id: 'session:relocated',
      sessionId: 'relocated',
      sourcePath: archivedFile.path,
      sourceState: 'codex_archived',
      parserVersion: 2,
    );
    final fallbackRowId = fixture.insertSession(
      id: 'source:${activeFile.path}',
      sourcePath: activeFile.path,
      parserVersion: 1,
    );
    final protectedFallbackRowId = fixture.insertSession(
      id: 'source-status:${activeFile.path}',
      sourcePath: activeFile.path,
      parserVersion: 1,
      isPinned: true,
    );
    final legacyRowId = fixture.insertSession(
      id: 'source:${pluginFile.path}',
      sourcePath: pluginFile.path,
      parserVersion: 1,
    );
    final unresolvedRowId = fixture.insertSession(
      id: 'source:${pluginFile.path}.protected',
      sourcePath: pluginFile.path,
      parserVersion: 1,
      isPinned: true,
    );

    final audit = SessionCacheRepair(
      databaseFile: fixture.databaseFile,
      clock: () => DateTime.utc(2026, 7, 27, 16),
    ).audit(db: fixture.db, roots: fixture.roots, discoveryComplete: true);

    expect(audit.categoryCounts, {
      SessionCacheRepairCategory.canonical: 1,
      SessionCacheRepairCategory.relocated: 1,
      SessionCacheRepairCategory.fallbackDuplicate: 2,
      SessionCacheRepairCategory.legacyNonSessionArtifact: 1,
      SessionCacheRepairCategory.unresolved: 1,
    });
    expect(
      {
        for (final row in fixture.db.select(
          '''
          select session_rowid, category, reason_code, delete_eligible
          from session_cache_repair_manifest
          where audit_id = ?
          order by session_rowid
          ''',
          [audit.auditId],
        ))
          row['session_rowid']: (
            category: row['category'],
            reason: row['reason_code'],
            deleteEligible: row['delete_eligible'],
          ),
      },
      {
        canonicalRowId: (
          category: 'canonical',
          reason: 'stable_active_session',
          deleteEligible: 0,
        ),
        relocatedRowId: (
          category: 'relocated',
          reason: 'stable_archived_session',
          deleteEligible: 0,
        ),
        fallbackRowId: (
          category: 'fallback_duplicate',
          reason: 'canonical_path_match_empty_legacy',
          deleteEligible: 1,
        ),
        protectedFallbackRowId: (
          category: 'fallback_duplicate',
          reason: 'canonical_path_match_requires_reconciliation',
          deleteEligible: 0,
        ),
        legacyRowId: (
          category: 'legacy_non_session_artifact',
          reason: 'allowlisted_non_session_namespace',
          deleteEligible: 1,
        ),
        unresolvedRowId: (
          category: 'unresolved',
          reason: 'protected_viewer_metadata',
          deleteEligible: 0,
        ),
      },
    );

    final columns = fixture.db
        .select("pragma table_info('session_cache_repair_manifest')")
        .map((row) => row['name'])
        .toSet();
    expect(
      columns,
      isNot(
        containsAll(<String>{
          'session_id',
          'source_file_path',
          'title',
          'summary',
          'content',
        }),
      ),
    );
    final persistedText = fixture.db
        .select(
          'select group_concat(row_fingerprint || category || reason_code) '
          'as value from session_cache_repair_manifest where audit_id = ?',
          [audit.auditId],
        )
        .single['value']
        .toString();
    expect(persistedText, isNot(contains(fixture.root.path)));
    expect(persistedText, isNot(contains('session:canonical')));
  });

  test(
    'consolidates only empty legacy fallbacks with an exact canonical path',
    () async {
      final fixture = await _RepairFixture.create();
      addTearDown(fixture.dispose);

      final activeFile = await fixture.file('sessions/canonical.jsonl');
      fixture.insertSession(
        id: 'session:canonical',
        sessionId: 'canonical',
        sourcePath: activeFile.path,
        sourceState: 'active',
        parserVersion: 2,
      );
      fixture.insertSession(
        id: 'source:${activeFile.path}',
        sourcePath: activeFile.path,
        parserVersion: 1,
      );
      fixture.insertSession(
        id: 'source-status:${activeFile.path}',
        sourcePath: activeFile.path,
        parserVersion: 1,
        isPinned: true,
      );

      final result = await SessionCacheRepair(
        databaseFile: fixture.databaseFile,
      ).run(db: fixture.db, roots: fixture.roots, discoveryComplete: true);

      expect(result.status, SessionCacheRepairStatus.completed);
      expect(result.deletedCount, 1);
      expect(
        fixture.db
            .select('select id from sessions order by id')
            .map((row) => row['id']),
        containsAll(<String>[
          'session:canonical',
          'source-status:${activeFile.path}',
        ]),
      );
      expect(
        fixture.db.select('select id from sessions where id = ?', [
          'source:${activeFile.path}',
        ]),
        isEmpty,
      );
      expect(await activeFile.exists(), isTrue);
    },
  );

  test(
    'fallback cleanup requires matching source type and traversal-free aliases',
    () async {
      final fixture = await _RepairFixture.create();
      addTearDown(fixture.dispose);

      final activeFile = await fixture.file('sessions/canonical.jsonl');
      final normalizedPath = activeFile.path.toLowerCase();
      fixture.insertSession(
        id: 'session:canonical',
        sessionId: 'canonical',
        sourcePath: normalizedPath,
        sourceState: 'active',
        parserVersion: 2,
      );
      final crossSourceRowId = fixture.insertSession(
        id: 'source:cross-source',
        sourcePath: normalizedPath,
        parserVersion: 1,
      );
      fixture.db.execute(
        "update sessions set source_type = 'wsl' where rowid = ?",
        [crossSourceRowId],
      );
      final traversalRowId = fixture.insertSession(
        id: 'source:traversal',
        sourcePath: p.join(
          p.dirname(activeFile.path),
          'child',
          '..',
          p.basename(activeFile.path),
        ),
        parserVersion: 1,
      );

      final audit = SessionCacheRepair(
        databaseFile: fixture.databaseFile,
      ).audit(db: fixture.db, roots: fixture.roots, discoveryComplete: true);
      final rows = {
        for (final row in fixture.db.select(
          '''
          select session_rowid, reason_code, delete_eligible
          from session_cache_repair_manifest
          where audit_id = ? and session_rowid in (?, ?)
          ''',
          [audit.auditId, crossSourceRowId, traversalRowId],
        ))
          row['session_rowid']: (
            reason: row['reason_code'],
            deleteEligible: row['delete_eligible'],
          ),
      };

      expect(rows[crossSourceRowId]!.deleteEligible, 0);
      expect(rows[traversalRowId], (
        reason: 'path_traversal_ambiguous',
        deleteEligible: 0,
      ));
    },
  );

  test('protects legacy fallbacks that own usage events', () async {
    final fixture = await _RepairFixture.create();
    addTearDown(fixture.dispose);

    final activeFile = await fixture.file('sessions/usage-owner.jsonl');
    fixture.insertSession(
      id: 'session:usage-owner',
      sessionId: 'usage-owner',
      sourcePath: activeFile.path,
      parserVersion: CodexSessionParser.currentVersion,
    );
    final fallbackId = 'source:${activeFile.path}';
    fixture.insertSession(
      id: fallbackId,
      sourcePath: activeFile.path,
      parserVersion: 1,
    );
    fixture.insertUsageEvent(fallbackId);

    final result = await SessionCacheRepair(
      databaseFile: fixture.databaseFile,
    ).run(db: fixture.db, roots: fixture.roots, discoveryComplete: true);

    expect(result.status, SessionCacheRepairStatus.completed);
    expect(result.deletedCount, 0);
    expect(
      fixture.db.select('select id from sessions where id = ?', [fallbackId]),
      hasLength(1),
    );
    expect(
      fixture.db
          .select(
            '''
            select reason_code
            from session_cache_repair_manifest
            where session_rowid = (
              select rowid from sessions where id = ?
            )
            ''',
            [fallbackId],
          )
          .single['reason_code'],
      'canonical_path_match_requires_reconciliation',
    );
  });

  test('deletes only rows satisfying every legacy allowlist predicate', () async {
    final fixture = await _RepairFixture.create();
    addTearDown(fixture.dispose);

    final sourceFiles = <File>[];
    Future<File> source(String name, {String namespace = 'plugins'}) async {
      final file = await fixture.file('$namespace/$name.json');
      sourceFiles.add(file);
      return file;
    }

    final eligible = await source('eligible');
    fixture.insertSession(
      id: 'source:eligible',
      sourcePath: eligible.path,
      parserVersion: 1,
    );

    final currentParser = await source('current-parser');
    fixture.insertSession(
      id: 'source:current-parser',
      sourcePath: currentParser.path,
      parserVersion: 2,
    );
    final stable = await source('stable');
    fixture.insertSession(
      id: 'session:stable-outside',
      sessionId: 'stable-outside',
      sourcePath: stable.path,
      parserVersion: 1,
    );
    final ownsMessage = await source('owns-message');
    fixture.insertSession(
      id: 'source:owns-message',
      sourcePath: ownsMessage.path,
      parserVersion: 1,
    );
    fixture.insertMessage('source:owns-message');
    final ownsTool = await source('owns-tool');
    fixture.insertSession(
      id: 'source:owns-tool',
      sourcePath: ownsTool.path,
      parserVersion: 1,
    );
    fixture.db.execute('''
      insert into tool_calls (session_id, tool_index, tool_name, status)
      values ('source:owns-tool', 0, 'guard', 'completed')
      ''');

    final protectedColumns = <String, Object?>{
      'is_pinned': 1,
      'is_archived': 1,
      'project_override': 1,
      'eval_ready': 1,
      'archived_at_utc': '2026-07-27T10:00:00Z',
      'archive_reason': 'guard',
      'eval_status': 'guard',
      'eval_notes': 'guard',
      'eval_expected_output': 'guard',
      'eval_reviewed_at_utc': '2026-07-27T10:00:00Z',
      'eval_updated_at_utc': '2026-07-27T10:00:00Z',
    };
    for (final entry in protectedColumns.entries) {
      final name = entry.key.replaceAll('_', '-');
      final file = await source(name);
      final id = 'source:$name';
      fixture.insertSession(id: id, sourcePath: file.path, parserVersion: 1);
      fixture.db.execute('update sessions set ${entry.key} = ? where id = ?', [
        entry.value,
        id,
      ]);
    }
    final tagged = await source('tagged');
    fixture.insertSession(
      id: 'source:tagged',
      sourcePath: tagged.path,
      parserVersion: 1,
    );
    fixture.db.execute('''
      insert into tags (id, name, created_at_utc, updated_at_utc)
      values (1, 'guard', '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z')
      ''');
    fixture.db.execute('''
      insert into session_tags (session_id, tag_id, created_at_utc)
      values ('source:tagged', 1, '2026-07-27T09:00:00Z')
      ''');

    fixture.insertSession(
      id: 'source:missing',
      sourcePath: p.join(fixture.root.path, 'plugins', 'missing.json'),
      parserVersion: 1,
    );
    final unknown = await source('unknown', namespace: 'misc');
    fixture.insertSession(
      id: 'source:unknown',
      sourcePath: unknown.path,
      parserVersion: 1,
    );
    final sessionFallback = await source('fallback', namespace: 'sessions');
    fixture.insertSession(
      id: 'source:session-fallback',
      sourcePath: sessionFallback.path,
      parserVersion: 1,
    );
    final nestedSession = await source('nested', namespace: 'plugins/sessions');
    fixture.insertSession(
      id: 'source:nested-session',
      sourcePath: nestedSession.path,
      parserVersion: 1,
    );

    final beforeCount =
        fixture.db
                .select('select count(*) as count from sessions')
                .single['count']
            as int;
    final result = await SessionCacheRepair(
      databaseFile: fixture.databaseFile,
      clock: () => DateTime.utc(2026, 7, 27, 17),
    ).run(db: fixture.db, roots: fixture.roots, discoveryComplete: true);

    expect(result.status, SessionCacheRepairStatus.completed);
    expect(result.deletedCount, 1);
    expect(result.backupFile, isNotNull);
    expect(await result.backupFile!.exists(), isTrue);
    expect(
      fixture.db
          .select(
            "select count(*) as count from sessions where id = 'source:eligible'",
          )
          .single['count'],
      0,
    );
    expect(
      fixture.db
          .select('select count(*) as count from sessions')
          .single['count'],
      beforeCount - 1,
    );
    expect(
      fixture.db
          .select(
            "select value from app_metadata where key = '$sessionCacheRepairCompletionKey'",
          )
          .single['value'],
      isNotEmpty,
    );
    expect(fixture.db.select('pragma foreign_key_check'), isEmpty);
    expect(
      fixture.db.select('pragma integrity_check').single.values.single,
      'ok',
    );
    for (final file in sourceFiles) {
      expect(await file.exists(), isTrue, reason: file.path);
    }
  });

  test('restores pre-repair backup with clean integrity', () async {
    final fixture = await _RepairFixture.create();
    addTearDown(fixture.dispose);

    final source = await fixture.file('plugins/restore-proof.json');
    fixture.insertSession(
      id: 'source:restore-proof',
      sourcePath: source.path,
      parserVersion: 1,
    );
    final repair = SessionCacheRepair(
      databaseFile: fixture.databaseFile,
      clock: () => DateTime.utc(2026, 7, 27, 18),
    );
    final result = await repair.run(
      db: fixture.db,
      roots: fixture.roots,
      discoveryComplete: true,
    );
    expect(result.status, SessionCacheRepairStatus.completed);

    final restoredFile = File(p.join(fixture.root.path, 'restored.sqlite'));
    final stalePartial = File('${restoredFile.path}.partial');
    await stalePartial.writeAsString('stale restore');
    await expectLater(
      repair.restoreVerifiedBackup(
        backupFile: result.backupFile!,
        destinationFile: restoredFile,
      ),
      throwsStateError,
    );
    expect(await restoredFile.exists(), isFalse);
    expect(await stalePartial.exists(), isTrue);
    await stalePartial.delete();
    await repair.restoreVerifiedBackup(
      backupFile: result.backupFile!,
      destinationFile: restoredFile,
    );
    expect(await stalePartial.exists(), isFalse);

    final restored = openFileBackedDatabase(restoredFile);
    addTearDown(restored.close);
    expect(
      restored
          .select(
            "select count(*) as count from sessions where id = 'source:restore-proof'",
          )
          .single['count'],
      1,
    );
    expect(
      restored
          .select(
            "select count(*) as count from app_metadata where key = '$sessionCacheRepairCompletionKey'",
          )
          .single['count'],
      0,
    );
    expect(
      restored.select('pragma integrity_check').single.values.single,
      'ok',
    );
    expect(restored.select('pragma foreign_key_check'), isEmpty);
  });

  test(
    'postpones on incomplete roots or backup failure without deletion',
    () async {
      final fixture = await _RepairFixture.create();
      addTearDown(fixture.dispose);
      final source = await fixture.file('plugins/postponed.json');
      fixture.insertSession(
        id: 'source:postponed',
        sourcePath: source.path,
        parserVersion: 1,
      );

      final repair = SessionCacheRepair(
        databaseFile: fixture.databaseFile,
        clock: () => DateTime.utc(2026, 7, 27, 19),
        backupWriter:
            ({
              required source,
              required databaseFile,
              required backupDirectory,
              required backupName,
            }) async => throw StateError('injected backup failure'),
      );
      final unreachable = await repair.run(
        db: fixture.db,
        roots: fixture.roots,
        discoveryComplete: false,
      );
      expect(unreachable.status, SessionCacheRepairStatus.postponed);
      expect(unreachable.reasonCode, 'root_discovery_incomplete');
      expect(unreachable.backupFile, isNull);
      expect(
        fixture.db
            .select(
              'select distinct category from session_cache_repair_manifest',
            )
            .single['category'],
        'unresolved',
      );

      final backupFailed = await repair.run(
        db: fixture.db,
        roots: fixture.roots,
        discoveryComplete: true,
      );
      expect(backupFailed.status, SessionCacheRepairStatus.postponed);
      expect(backupFailed.reasonCode, 'backup_failed');
      expect(
        fixture.db
            .select(
              "select count(*) as count from sessions where id = 'source:postponed'",
            )
            .single['count'],
        1,
      );
      expect(
        fixture.db
            .select(
              "select count(*) as count from app_metadata where key = '$sessionCacheRepairCompletionKey'",
            )
            .single['count'],
        0,
      );
      expect(
        fixture.db
            .select(
              'select count(*) as count from session_cache_repair_manifest',
            )
            .single['count'],
        1,
        reason: 'only the latest incomplete audit should remain',
      );
    },
  );

  test('cancellation after backup prevents repair mutation', () async {
    final fixture = await _RepairFixture.create();
    addTearDown(fixture.dispose);
    final source = await fixture.file('plugins/cancelled.json');
    fixture.insertSession(
      id: 'source:cancelled',
      sourcePath: source.path,
      parserVersion: 1,
    );
    var cancelled = false;
    var beforeApplyCalled = false;

    final result =
        await SessionCacheRepair(
          databaseFile: fixture.databaseFile,
          clock: () => DateTime.utc(2026, 7, 28, 3),
          beforeApply: (_) => beforeApplyCalled = true,
        ).run(
          db: fixture.db,
          roots: fixture.roots,
          discoveryComplete: true,
          isCancellationRequested: () => cancelled,
          onProgress: (phase) {
            if (phase == SessionCacheRepairPhase.verifyingBackup) {
              cancelled = true;
            }
          },
        );

    expect(result.status, SessionCacheRepairStatus.postponed);
    expect(result.reasonCode, 'cancelled');
    expect(beforeApplyCalled, isFalse);
    expect(
      fixture.db
          .select(
            "select count(*) as count from sessions where id = 'source:cancelled'",
          )
          .single['count'],
      1,
    );
    expect(
      fixture.db
          .select(
            "select count(*) as count from app_metadata where key = '$sessionCacheRepairCompletionKey'",
          )
          .single['count'],
      0,
    );
  });

  test('no-op repair completes without creating a backup', () async {
    final fixture = await _RepairFixture.create();
    addTearDown(fixture.dispose);
    final source = await fixture.file('sessions/canonical-no-op.jsonl');
    fixture.insertSession(
      id: 'session:canonical-no-op',
      sessionId: 'canonical-no-op',
      sourcePath: source.path,
      parserVersion: 2,
    );
    var backupCalls = 0;

    final result = await SessionCacheRepair(
      databaseFile: fixture.databaseFile,
      clock: () => DateTime.utc(2026, 7, 28, 4),
      backupWriter:
          ({
            required source,
            required databaseFile,
            required backupDirectory,
            required backupName,
          }) async {
            backupCalls++;
            throw StateError('No-op repair must not create a backup.');
          },
    ).run(db: fixture.db, roots: fixture.roots, discoveryComplete: true);

    expect(result.status, SessionCacheRepairStatus.completed);
    expect(result.reasonCode, 'no_changes');
    expect(result.deletedCount, 0);
    expect(result.backupFile, isNull);
    expect(backupCalls, 0);
    expect(
      fixture.db
          .select(
            "select count(*) as count from app_metadata where key = '$sessionCacheRepairCompletionKey'",
          )
          .single['count'],
      1,
    );
  });

  test('postponed repair removes its uncommitted backup', () async {
    final fixture = await _RepairFixture.create();
    addTearDown(fixture.dispose);
    final source = await fixture.file('plugins/drifted-backup.json');
    fixture.insertSession(
      id: 'source:drifted-backup',
      sourcePath: source.path,
      parserVersion: 1,
    );

    final result = await SessionCacheRepair(
      databaseFile: fixture.databaseFile,
      clock: () => DateTime.utc(2026, 7, 28, 5),
      beforeApply: (db) {
        db.execute(
          "update sessions set is_pinned = 1 where id = 'source:drifted-backup'",
        );
      },
    ).run(db: fixture.db, roots: fixture.roots, discoveryComplete: true);

    expect(result.status, SessionCacheRepairStatus.postponed);
    expect(result.reasonCode, 'repair_invariant_failed');
    expect(result.backupFile, isNull);
    expect(await fixture.backupFileCount(), 0);
  });

  test(
    'predicate drift and injected deletion failure cannot partially repair',
    () async {
      final driftFixture = await _RepairFixture.create();
      addTearDown(driftFixture.dispose);
      final driftSource = await driftFixture.file('plugins/drift.json');
      driftFixture.insertSession(
        id: 'source:drift',
        sourcePath: driftSource.path,
        parserVersion: 1,
      );
      final drifted =
          await SessionCacheRepair(
            databaseFile: driftFixture.databaseFile,
            clock: () => DateTime.utc(2026, 7, 27, 20),
            beforeApply: (db) {
              db.execute(
                "update sessions set is_pinned = 1 where id = 'source:drift'",
              );
            },
          ).run(
            db: driftFixture.db,
            roots: driftFixture.roots,
            discoveryComplete: true,
          );
      expect(drifted.status, SessionCacheRepairStatus.postponed);
      expect(drifted.reasonCode, 'repair_invariant_failed');
      expect(
        driftFixture.db
            .select("select is_pinned from sessions where id = 'source:drift'")
            .single['is_pinned'],
        1,
      );

      final rollbackFixture = await _RepairFixture.create();
      addTearDown(rollbackFixture.dispose);
      final rollbackSource = await rollbackFixture.file(
        'plugins/rollback.json',
      );
      rollbackFixture.insertSession(
        id: 'source:rollback',
        sourcePath: rollbackSource.path,
        parserVersion: 1,
      );
      rollbackFixture.db.execute('''
      create trigger fail_cache_repair
      before delete on sessions
      when old.id = 'source:rollback'
      begin
        select raise(abort, 'injected repair failure');
      end
      ''');
      final rolledBack =
          await SessionCacheRepair(
            databaseFile: rollbackFixture.databaseFile,
            clock: () => DateTime.utc(2026, 7, 27, 21),
          ).run(
            db: rollbackFixture.db,
            roots: rollbackFixture.roots,
            discoveryComplete: true,
          );
      expect(rolledBack.status, SessionCacheRepairStatus.postponed);
      expect(rolledBack.reasonCode, 'repair_invariant_failed');
      expect(
        rollbackFixture.db
            .select(
              "select count(*) as count from sessions where id = 'source:rollback'",
            )
            .single['count'],
        1,
      );
      expect(
        rollbackFixture.db
            .select(
              "select count(*) as count from app_metadata where key = '$sessionCacheRepairCompletionKey'",
            )
            .single['count'],
        0,
      );
      expect(rollbackFixture.db.select('pragma foreign_key_check'), isEmpty);
    },
  );

  test('completion marker makes repair idempotent', () async {
    final fixture = await _RepairFixture.create();
    addTearDown(fixture.dispose);
    final source = await fixture.file('plugins/idempotent.json');
    fixture.insertSession(
      id: 'source:idempotent',
      sourcePath: source.path,
      parserVersion: 1,
    );
    final repair = SessionCacheRepair(
      databaseFile: fixture.databaseFile,
      clock: () => DateTime.utc(2026, 7, 27, 22),
    );
    final first = await repair.run(
      db: fixture.db,
      roots: fixture.roots,
      discoveryComplete: true,
    );
    final manifestCount = fixture.db
        .select('select count(*) as count from session_cache_repair_manifest')
        .single['count'];
    final backupCount = await fixture.backupFileCount();

    final second = await repair.run(
      db: fixture.db,
      roots: fixture.roots,
      discoveryComplete: true,
    );

    expect(first.status, SessionCacheRepairStatus.completed);
    expect(second.status, SessionCacheRepairStatus.alreadyCompleted);
    expect(second.audit, isNull);
    expect(
      fixture.db
          .select('select count(*) as count from session_cache_repair_manifest')
          .single['count'],
      manifestCount,
    );
    expect(await fixture.backupFileCount(), backupCount);
  });

  test(
    'allowlists only verified Codex non-session namespaces and root files',
    () async {
      final fixture = await _RepairFixture.create();
      addTearDown(fixture.dispose);

      const namespaces = [
        '.tmp',
        'plugins',
        '.sandbox',
        'cache',
        '.sandbox-secrets',
        'computer-use',
      ];
      const rootFiles = [
        '.codex-global-state.json',
        'auth.json',
        'external_agent_session_imports.json',
        'history.jsonl',
        'internal_storage.json',
        'models_cache.json',
        'session_index.jsonl',
      ];
      for (final namespace in namespaces) {
        final file = await fixture.file('$namespace/artifact.json');
        fixture.insertSession(
          id: 'source:namespace:$namespace',
          sourcePath: file.path,
          parserVersion: 1,
        );
      }
      for (final name in rootFiles) {
        final file = await fixture.file(name);
        fixture.insertSession(
          id: 'source:root:$name',
          sourcePath: file.path,
          parserVersion: 1,
        );
      }
      final speculative = await fixture.file('skills/keep.json');
      fixture.insertSession(
        id: 'source:speculative',
        sourcePath: speculative.path,
        parserVersion: 1,
      );

      final result = await SessionCacheRepair(
        databaseFile: fixture.databaseFile,
        clock: () => DateTime.utc(2026, 7, 27, 23),
      ).run(db: fixture.db, roots: fixture.roots, discoveryComplete: true);

      expect(result.status, SessionCacheRepairStatus.completed);
      expect(result.deletedCount, namespaces.length + rootFiles.length);
      expect(
        fixture.db
            .select(
              "select count(*) as count from sessions where id = 'source:speculative'",
            )
            .single['count'],
        1,
      );
    },
  );

  test(
    'rejects ambiguous versions identities traversal and session aliases',
    () async {
      final fixture = await _RepairFixture.create();
      addTearDown(fixture.dispose);

      final eligible = await fixture.file('plugins/unicode-zażółć.json');
      fixture.insertSession(
        id: 'source:unicode-zażółć',
        sourcePath: eligible.path,
        parserVersion: 1,
      );
      for (final version in [0, -1, 2]) {
        final file = await fixture.file('plugins/version-$version.json');
        fixture.insertSession(
          id: 'source:version-$version',
          sourcePath: file.path,
          parserVersion: version,
        );
      }
      final invalidIdentity = await fixture.file('plugins/invalid-id.json');
      fixture.insertSession(
        id: 'legacy:invalid-id',
        sourcePath: invalidIdentity.path,
        parserVersion: 1,
      );
      final traversalTarget = await fixture.file('plugins/traversal.json');
      fixture.insertSession(
        id: 'source:traversal',
        sourcePath: p.join(
          fixture.root.path,
          'plugins',
          '..',
          'plugins',
          p.basename(traversalTarget.path),
        ),
        parserVersion: 1,
      );
      final aliased = await fixture.file('plugins/aliased.json');
      fixture.insertSession(
        id: 'source:aliased',
        sourcePath: aliased.path,
        parserVersion: 1,
      );
      fixture.db.execute('update sessions set display_path = ? where id = ?', [
        p.join(fixture.root.path, 'plugins', 'sessions', 'ambiguous.json'),
        'source:aliased',
      ]);
      final mixedAllowed = await fixture.file('plugins/mixed.json');
      final mixedUnknown = await fixture.file('misc/mixed.json');
      fixture.insertSession(
        id: 'source:mixed-existing-aliases',
        sourcePath: mixedAllowed.path,
        parserVersion: 1,
      );
      fixture.db.execute('update sessions set display_path = ? where id = ?', [
        mixedUnknown.path,
        'source:mixed-existing-aliases',
      ]);
      final missingAliasSource = await fixture.file(
        'plugins/missing-alias-source.json',
      );
      fixture.insertSession(
        id: 'source:missing-existing-alias',
        sourcePath: missingAliasSource.path,
        parserVersion: 1,
      );
      fixture.db.execute('update sessions set display_path = ? where id = ?', [
        p.join(fixture.root.path, 'plugins', 'missing-alias.json'),
        'source:missing-existing-alias',
      ]);
      final relativeAliasSource = await fixture.file(
        'plugins/relative-alias-source.json',
      );
      fixture.insertSession(
        id: 'source:relative-alias',
        sourcePath: relativeAliasSource.path,
        parserVersion: 1,
      );
      fixture.db.execute('update sessions set display_path = ? where id = ?', [
        p.join('plugins', 'relative-alias-source.json'),
        'source:relative-alias',
      ]);
      final siblingRoot = Directory('${fixture.root.path}-other');
      addTearDown(() async {
        if (await siblingRoot.exists()) {
          await siblingRoot.delete(recursive: true);
        }
      });
      final siblingFile = File(
        p.join(siblingRoot.path, 'plugins', 'sibling.json'),
      );
      await siblingFile.parent.create(recursive: true);
      await siblingFile.writeAsString('{}');
      fixture.insertSession(
        id: 'source:sibling-owner',
        sourcePath: siblingFile.path,
        parserVersion: 1,
      );

      final result = await SessionCacheRepair(
        databaseFile: fixture.databaseFile,
        clock: () => DateTime.utc(2026, 7, 28),
      ).run(db: fixture.db, roots: fixture.roots, discoveryComplete: true);

      expect(result.status, SessionCacheRepairStatus.completed);
      expect(result.deletedCount, 1);
      expect(
        fixture.db
            .select('select id from sessions order by id')
            .map((row) => row['id']),
        containsAll([
          'legacy:invalid-id',
          'source:version-0',
          'source:version--1',
          'source:version-2',
          'source:traversal',
          'source:aliased',
          'source:mixed-existing-aliases',
          'source:missing-existing-alias',
          'source:relative-alias',
          'source:sibling-owner',
        ]),
      );
    },
  );

  test(
    'rejects a lexically contained alias resolved outside its owner',
    () async {
      final fixture = await _RepairFixture.create();
      addTearDown(fixture.dispose);
      final lexicalSource = await fixture.file(
        'plugins/junction/artifact.json',
      );
      final outsideRoot = Directory('${fixture.root.path}-outside');
      final physicalSource = File(p.join(outsideRoot.path, 'artifact.json'));
      await physicalSource.parent.create(recursive: true);
      await physicalSource.writeAsString('{}');
      addTearDown(() async {
        if (await outsideRoot.exists()) {
          await outsideRoot.delete(recursive: true);
        }
      });
      fixture.insertSession(
        id: 'source:parent-junction',
        sourcePath: lexicalSource.path,
        parserVersion: 1,
      );

      final result = await SessionCacheRepair(
        databaseFile: fixture.databaseFile,
        clock: () => DateTime.utc(2026, 7, 28, 1),
        physicalPathResolver: (path, type) {
          if (p.equals(path, lexicalSource.path)) {
            return physicalSource.path;
          }
          return type == FileSystemEntityType.directory
              ? Directory(path).resolveSymbolicLinksSync()
              : File(path).resolveSymbolicLinksSync();
        },
      ).run(db: fixture.db, roots: fixture.roots, discoveryComplete: true);

      expect(result.status, SessionCacheRepairStatus.completed);
      expect(result.deletedCount, 0);
      expect(
        fixture.db
            .select(
              "select count(*) as count from sessions where id = 'source:parent-junction'",
            )
            .single['count'],
        1,
      );
    },
  );

  test('rejects unproven WSL POSIX and UNC alias agreement', () async {
    final fixture = await _RepairFixture.create();
    addTearDown(fixture.dispose);
    final uncSource = await fixture.file('plugins/wsl-alias.json');
    fixture.insertSession(
      id: 'source:wsl-alias',
      sourcePath: uncSource.path,
      parserVersion: 1,
    );
    fixture.db.execute(
      '''
      update sessions
      set source_type = 'wsl',
          source_file_unc_path = ?,
          display_path = '/home/pawel/.codex/plugins/other.json',
          platform_path = '/home/pawel/.codex/plugins/other.json'
      where id = 'source:wsl-alias'
      ''',
      [uncSource.path],
    );
    final wslRoots = [
      for (final root in fixture.roots)
        SessionScanRoot(
          path: root.path,
          availabilityRootPath: root.availabilityRootPath,
          sourceType: SessionSourceType.wsl,
          sourceState: root.sourceState,
        ),
    ];

    final result = await SessionCacheRepair(
      databaseFile: fixture.databaseFile,
      clock: () => DateTime.utc(2026, 7, 28, 2),
    ).run(db: fixture.db, roots: wslRoots, discoveryComplete: true);

    expect(result.status, SessionCacheRepairStatus.completed);
    expect(result.deletedCount, 0);
    expect(
      fixture.db
          .select(
            "select count(*) as count from sessions where id = 'source:wsl-alias'",
          )
          .single['count'],
      1,
    );
  });
}

class _RepairFixture {
  _RepairFixture({
    required this.root,
    required this.databaseFile,
    required this.db,
  });

  static Future<_RepairFixture> create() async {
    final root = await Directory.systemTemp.createTemp('csv_cache_repair_');
    final databaseFile = File(p.join(root.path, 'viewer.sqlite'));
    final startup = await DatabaseMigrator(
      sqlRoot: Directory(p.normalize(p.join('..', 'sql'))),
    ).openAndMigrate(databaseFile);
    expect(startup.canStartNormalUi, isTrue);
    return _RepairFixture(
      root: root,
      databaseFile: databaseFile,
      db: openFileBackedDatabase(databaseFile),
    );
  }

  final Directory root;
  final File databaseFile;
  final Database db;

  List<SessionScanRoot> get roots => [
    SessionScanRoot(
      path: p.join(root.path, 'sessions'),
      availabilityRootPath: root.path,
      sourceType: SessionSourceType.windows,
      sourceState: SessionSourceState.active,
    ),
    SessionScanRoot(
      path: p.join(root.path, 'archived_sessions'),
      availabilityRootPath: root.path,
      sourceType: SessionSourceType.windows,
      sourceState: SessionSourceState.codexArchived,
    ),
  ];

  Future<File> file(String relativePath) async {
    final result = File(p.joinAll([root.path, ...relativePath.split('/')]));
    await result.parent.create(recursive: true);
    await result.writeAsString('{}');
    return result;
  }

  int insertSession({
    required String id,
    String? sessionId,
    required String sourcePath,
    String sourceState = 'active',
    required int parserVersion,
    bool isPinned = false,
  }) {
    db.execute(
      '''
      insert into sessions (
        id, session_id, source_type, source_file_path, display_path,
        platform_path, source_state, parser_version, is_pinned,
        created_at_utc, updated_at_utc
      ) values (?, ?, 'windows', ?, ?, ?, ?, ?, ?,
        '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z')
      ''',
      [
        id,
        sessionId,
        sourcePath,
        sourcePath,
        sourcePath,
        sourceState,
        parserVersion,
        isPinned ? 1 : 0,
      ],
    );
    return db.lastInsertRowId;
  }

  void insertMessage(String sessionId) {
    db.execute(
      '''
      insert into messages (
        session_id, message_index, author_type, content_preview,
        created_at_db_utc, updated_at_db_utc
      ) values (?, 0, 'user', '',
        '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z')
      ''',
      [sessionId],
    );
  }

  void insertUsageEvent(String sessionId) {
    db.execute(
      '''
      insert into usage_events (
        session_row_id, source_record_ordinal, epoch, input_tokens,
        cached_input_tokens, cache_write_input_tokens, output_tokens,
        reasoning_output_tokens, total_tokens, branch_scope, derivation,
        event_fingerprint
      ) values (?, 1, 0, 1, 0, 0, 1, 0, 2, 'local',
        'cumulative_delta', ?)
      ''',
      [sessionId, 'a' * 64],
    );
  }

  Future<void> dispose() async {
    db.close();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
  }

  Future<int> backupFileCount() async {
    final directory = Directory(p.join(databaseFile.parent.path, 'backups'));
    if (!await directory.exists()) {
      return 0;
    }
    return directory.list().where((entity) => entity is File).length;
  }
}
