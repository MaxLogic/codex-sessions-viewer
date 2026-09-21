import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'project_tag_state.dart';
import 'maintenance_job.dart';
import 'database_maintenance.dart';

/// Runs only the context portion of a verified, startup-gated migration.
/// True means this portion is validated, NOT that the migration may activate
/// or release writers. False leaves a resumable checkpoint after a stop.
Future<bool> prepareUsagePathContexts(
  DatabaseMaintenanceWorkerContext context,
) async {
  final db = context.database;
  final jobs = context.jobs;
  final lease = context.lease;
  var job = jobs.read(lease.jobId)!;
  final generationId = job.databaseGenerationId;
  final payload = job.payloadJson == null
      ? <String, dynamic>{}
      : jsonDecode(job.payloadJson!) as Map<String, dynamic>;
  if (generationId == null ||
      payload['backup'] is! Map ||
      !{
        'backup_complete',
        'copy_events',
        'resolve_contexts',
        'validate_contexts',
        'contexts_validated',
      }.contains(job.phase) ||
      db.select('select state from database_generations where id = ?', [
            generationId,
          ]).single['state'] !=
          'building') {
    throw StateError(
      'Context migration requires a verified backup and building generation.',
    );
  }
  final migration = UsagePathContextMigration(db);
  void checkpoint(String phase, String message, {void Function()? apply}) {
    job = jobs.read(lease.jobId)!;
    jobs.commitBatch(
      lease: lease,
      phase: phase,
      completedUnits: job.completedUnits,
      totalUnits: job.totalUnits,
      lastProcessedRowId: job.lastProcessedRowId,
      statusMessage: message,
      apply: (_) => apply?.call(),
    );
  }

  void publish(
    String phase,
    String message,
    String unit,
    int completed,
    int? total,
  ) {
    context.publish(
      state: DatabaseMaintenanceState.running,
      phase: phase,
      currentWork: message,
      unitLabel: unit,
      completedUnits: completed,
      totalUnits: total,
    );
  }

  Future<bool> stopped() async {
    // Yield so the isolate can receive stop messages; checkpoint only outside
    // write transactions. The encompassing worker owns disk-headroom checks.
    await Future<void>.delayed(Duration.zero);
    if (context.stopRequested) return true;
    db.select('pragma wal_checkpoint(passive)');
    return false;
  }

  if (await stopped()) return false;
  if (job.phase == 'backup_complete') {
    checkpoint(
      'copy_events',
      'Normalizing legacy project masks.',
      apply: () {
        migration.normalizeLegacyMasks(generationId: generationId);
      },
    );
  }
  job = jobs.read(lease.jobId)!;
  if (job.phase == 'copy_events') {
    final total =
        db.select('select count(*) n from usage_events').single['n'] as int;
    publish(
      'copy_events',
      'Copying usage events and retaining path evidence.',
      'events',
      job.completedUnits,
      total,
    );
    while (migration.copyNextBatch(jobs: jobs, lease: lease) != 0) {
      job = jobs.read(lease.jobId)!;
      publish(
        'copy_events',
        job.statusMessage!,
        'events',
        job.completedUnits,
        total,
      );
      if (await stopped()) return false;
    }
    checkpoint('resolve_contexts', 'Resolving historical project assignments.');
  }
  job = jobs.read(lease.jobId)!;
  if (job.phase == 'resolve_contexts') {
    final contextTotal =
        db.select('select count(*) n from usage_path_contexts').single['n']
            as int;
    final sessionTotal =
        db.select('select count(*) n from sessions').single['n'] as int;
    while (migration.resolveNextContextBatch(jobs: jobs, lease: lease) != 0) {
      job = jobs.read(lease.jobId)!;
      final progress = jsonDecode(job.payloadJson!) as Map;
      final contexts = progress['resolved_context_count'] as int;
      final sessions = progress['preserved_session_count'] as int;
      publish(
        'resolve_contexts',
        '$contexts of $contextTotal contexts resolved; $sessions of $sessionTotal sessions examined.',
        'records',
        contexts + sessions,
        contextTotal + sessionTotal,
      );
      if (await stopped()) return false;
    }
    checkpoint(
      'validate_contexts',
      'Checking shadow event facts and path evidence.',
    );
  }
  if (await stopped()) return false;
  job = jobs.read(lease.jobId)!;
  if (job.phase == 'validate_contexts') {
    publish('validate_contexts', job.statusMessage!, 'events', 0, null);
    // Publish before the potentially long read-only validation. Restart can
    // repeat it without replaying copied rows or changing either active table.
    if (await stopped()) return false;
    final parity = await context.runAtomic(migration.validateShadowParity);
    checkpoint(
      'contexts_validated',
      'Path contexts validated; remaining migration phases required.',
      apply: () {
        final raw =
            db.select(
                  'select validation_report_json from database_generations where id = ?',
                  [generationId],
                ).single['validation_report_json']
                as String?;
        final report = raw == null
            ? <String, dynamic>{}
            : jsonDecode(raw) as Map<String, dynamic>;
        report['context_parity'] = parity;
        db.execute(
          'update database_generations set validation_report_json = ? where id = ?',
          [jsonEncode(report), generationId],
        );
      },
    );
  }
  return true;
}

/// Shadow-copy phases run only while normal application writers are gated.
/// The caller owns the maintenance transaction and its durable checkpoint.
class UsagePathContextMigration {
  const UsagePathContextMigration(this.db);

  final Database db;

  /// Exact fact equality implies per-session and per-branch token parity too.
  /// This intentionally scans the source once during migration, never on reads.
  Map<String, Object?> validateShadowParity() {
    final sourceCount = db
        .select('select count(*) n from usage_events')
        .single['n'];
    final targetCount = db
        .select('select count(*) n from usage_events_next')
        .single['n'];
    if (sourceCount != targetCount) {
      throw StateError('Shadow event count differs from the source.');
    }
    final comparisons = [
      for (final column in [..._leadingFactColumns, ..._trailingFactColumns])
        'source.$column is not target.$column',
    ].join(' or ');
    final mismatch = db.select('''
      select 1 from usage_events source left join usage_events_next target
        on target.session_row_id = source.session_row_id
        and target.source_record_ordinal = source.source_record_ordinal
      where target.session_row_id is null or $comparisons
        or not exists (
          select 1 from usage_path_context_aliases alias
          where alias.path_context_id = target.path_context_id
            and alias.display_path_raw = coalesce(source.working_directory_display, '')
            and alias.platform_path_raw = coalesce(source.working_directory_platform, '')
            and alias.unc_path_raw = coalesce(source.working_directory_unc, '')
        )
      limit 1
    ''');
    if (mismatch.isNotEmpty) {
      throw StateError(
        'Shadow event facts or raw path evidence differ from the source.',
      );
    }
    if (db
        .select('select * from pragma_foreign_key_check limit 1')
        .isNotEmpty) {
      throw StateError('Foreign-key integrity failed before usage cutover.');
    }
    final totals = db.select('''
      select count(*) event_count,
        coalesce(sum(input_tokens), 0) input_tokens,
        coalesce(sum(cached_input_tokens), 0) cached_input_tokens,
        coalesce(sum(cache_write_input_tokens), 0) cache_write_input_tokens,
        coalesce(sum(output_tokens), 0) output_tokens,
        coalesce(sum(reasoning_output_tokens), 0) reasoning_output_tokens,
        coalesce(sum(total_tokens), 0) total_tokens,
        coalesce(sum(branch_scope = 'local'), 0) local_events,
        coalesce(sum(branch_scope = 'inherited'), 0) inherited_events,
        coalesce(sum(branch_scope = 'ambiguous'), 0) ambiguous_events
      from usage_events_next
    ''').single;
    return Map<String, Object?>.from(totals);
  }

  /// Visits at most 512 contexts and 512 sessions, with independent cursors.
  /// Returns the number visited, or zero only when both sources are exhausted.
  int resolveNextContextBatch({
    required MaintenanceJobRepository jobs,
    required MaintenanceJobLease lease,
  }) {
    final job = jobs.read(lease.jobId)!;
    final generationId = job.databaseGenerationId;
    if (generationId == null ||
        !{'copy_events', 'resolve_contexts'}.contains(job.phase) ||
        db.select('select 1 from usage_events where rowid > ? limit 1', [
          job.lastProcessedRowId,
        ]).isNotEmpty) {
      throw StateError('Context resolution requires a completed event copy.');
    }
    final payload = job.payloadJson == null
        ? <String, dynamic>{}
        : jsonDecode(job.payloadJson!) as Map<String, dynamic>;
    final cursor = payload['context_resolution_cursor'] as int? ?? 0;
    final contexts = db.select(
      '''
      select id, mask_project_id from usage_path_contexts where id > ? order by id limit 512
    ''',
      [cursor],
    );
    final sessionCursor = payload['session_fallback_cursor'] as String?;
    final sessions = db.select(
      '''
      select id from sessions
      ${sessionCursor == null ? '' : 'where id > ?'}
      order by id limit 512
    ''',
      [?sessionCursor],
    );
    if (contexts.isEmpty && sessions.isEmpty) return 0;
    if (contexts.isNotEmpty) {
      payload['context_resolution_cursor'] = contexts.last['id'];
    }
    if (sessions.isNotEmpty) {
      payload['session_fallback_cursor'] = sessions.last['id'];
    }
    payload['resolved_context_count'] =
        (payload['resolved_context_count'] as int? ?? 0) + contexts.length;
    payload['preserved_session_count'] =
        (payload['preserved_session_count'] as int? ?? 0) + sessions.length;
    jobs.commitBatch(
      lease: lease,
      phase: 'resolve_contexts',
      completedUnits: job.completedUnits,
      totalUnits: null,
      lastProcessedRowId: job.lastProcessedRowId,
      statusMessage:
          'Preserving historical session and path-context project assignments.',
      payloadJson: jsonEncode(payload),
      apply: (_) {
        // Old automatic assignments are the only available session fallback.
        // Never reinterpret a manual override as detection or replace a newer
        // discovery. Legacy session project IDs can outlive their project row.
        for (final session in sessions) {
          db.execute(
            '''
            update sessions set detected_project_id = project_id
            where id = ? and project_override = 0 and detected_project_id is null
              and exists (select 1 from projects where id = sessions.project_id)
          ''',
            [session['id']],
          );
        }
        ProjectTagStateStore(db).refreshSessionProjectsBatch(
          sessions.map((session) => session['id'] as String).toList(),
        );
        final rawReport =
            db
                    .select(
                      'select validation_report_json from database_generations where id = ?',
                      [generationId],
                    )
                    .single
                    .values
                    .single
                as String?;
        final report = rawReport == null
            ? <String, dynamic>{}
            : jsonDecode(rawReport) as Map<String, dynamic>;
        final conflicts = report['project_conflicts'] as List? ?? <Object?>[];
        for (final context in contexts) {
          final candidates = db.select(
            '''
            select historical_project_id, event_count from usage_context_project_candidates
            where generation_id = ? and path_context_id = ?
            order by latest_event_epoch_us desc, latest_source_rowid desc
          ''',
            [generationId, context['id']],
          );
          final fallback = candidates.isEmpty
              ? null
              : candidates.first['historical_project_id'];
          final effective = context['mask_project_id'] ?? fallback;
          db.execute(
            '''
            update usage_path_contexts set detected_project_id = ?,
              detected_project_source = 'legacy_import', effective_project_id = ?,
              resolution_source = ?, updated_at_utc = ? where id = ?
          ''',
            [
              fallback,
              effective,
              context['mask_project_id'] != null
                  ? 'mask'
                  : fallback != null
                  ? 'legacy_import'
                  : 'unassigned',
              DateTime.now().toUtc().toIso8601String(),
              context['id'],
            ],
          );
          if (candidates.length > 1) {
            conflicts.add({
              'context_id': context['id'],
              'candidate_count': candidates.length,
              'attributed_event_count': candidates.fold<int>(
                0,
                (sum, row) => sum + (row['event_count'] as int),
              ),
              'chosen_fallback_project_id': fallback,
              'mask_project_id_at_migration': context['mask_project_id'],
              'effective_project_id_at_migration': effective,
            });
          }
        }
        report['project_conflicts'] = conflicts;
        report['project_candidate_audit_table'] =
            'usage_context_project_candidates';
        report['project_candidate_ordering'] =
            'UTC microseconds descending, undated last, source rowid descending';
        db.execute(
          'update database_generations set validation_report_json = ? where id = ?',
          [jsonEncode(report), generationId],
        );
      },
    );
    return contexts.length + sessions.length;
  }

  /// Returns zero once the source is exhausted. Never activates the shadow.
  int copyNextBatch({
    required MaintenanceJobRepository jobs,
    required MaintenanceJobLease lease,
  }) {
    final job = jobs.read(lease.jobId)!;
    final generationId = job.databaseGenerationId;
    if (generationId == null || job.phase != 'copy_events') {
      throw StateError('Event copying requires its generation and copy phase.');
    }
    final rows = db.select(
      '''
      select e.rowid as source_rowid, e.*, p.name as project_name_snapshot
      from usage_events e left join projects p on p.id = e.project_id
      where e.rowid > ? order by e.rowid limit 512
    ''',
      [job.lastProcessedRowId],
    );
    if (rows.isEmpty) return 0;
    jobs.commitBatch(
      lease: lease,
      phase: 'copy_events',
      completedUnits: job.completedUnits + rows.length,
      totalUnits: job.totalUnits,
      lastProcessedRowId: rows.last['source_rowid'] as int,
      statusMessage: 'Copying usage events and retaining path evidence.',
      apply: (_) {
        final store = ProjectTagStateStore(db);
        final contexts = <(String?, String?, String?), int>{};
        final insert = db.prepare('''
          insert into usage_events_next (
            session_row_id, source_record_ordinal, rollout_ordinal, turn_ordinal,
            epoch, occurred_at_utc, model, path_context_id, input_tokens,
            cached_input_tokens, cache_write_input_tokens, output_tokens,
            reasoning_output_tokens, total_tokens, branch_scope, derivation, event_fingerprint
          ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''');
        final candidate = db.prepare('''
          insert into usage_context_project_candidates (
            generation_id, path_context_id, historical_project_id, project_name_snapshot,
            event_count, malformed_timestamp_count, latest_event_epoch_us, latest_event_time_raw,
            latest_source_rowid, latest_session_id_snapshot, latest_source_record_ordinal
          ) values (?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?)
          on conflict(generation_id, path_context_id, historical_project_id) do update set
            event_count = event_count + 1,
            malformed_timestamp_count = malformed_timestamp_count + excluded.malformed_timestamp_count
        ''');
        final newest = db.prepare('''
          update usage_context_project_candidates set latest_event_epoch_us = ?,
            latest_event_time_raw = ?, latest_source_rowid = ?,
            latest_session_id_snapshot = ?, latest_source_record_ordinal = ?
          where generation_id = ? and path_context_id = ? and historical_project_id = ?
            and ((? is not null and latest_event_epoch_us is null)
              or ? > latest_event_epoch_us
              or (? is latest_event_epoch_us and ? > latest_source_rowid))
        ''');
        try {
          for (final row in rows) {
            final paths = (
              row['working_directory_display'] as String?,
              row['working_directory_platform'] as String?,
              row['working_directory_unc'] as String?,
            );
            final contextId = contexts.putIfAbsent(
              paths,
              () => store.resolveUsagePathContext(
                displayPath: paths.$1,
                platformPath: paths.$2,
                uncPath: paths.$3,
              ),
            );
            insert.execute([
              for (final column in _leadingFactColumns) row[column],
              contextId,
              for (final column in _trailingFactColumns) row[column],
            ]);
            if (row['project_id'] == null) continue;
            final rawTime = row['occurred_at_utc'] as String?;
            final time = rawTime == null
                ? null
                : DateTime.tryParse(rawTime)?.toUtc().microsecondsSinceEpoch;
            final identity = [generationId, contextId, row['project_id']];
            candidate.execute([
              ...identity,
              row['project_name_snapshot'],
              rawTime != null && time == null ? 1 : 0,
              time,
              rawTime,
              row['source_rowid'],
              row['session_row_id'],
              row['source_record_ordinal'],
            ]);
            newest.execute([
              time,
              rawTime,
              row['source_rowid'],
              row['session_row_id'],
              row['source_record_ordinal'],
              ...identity,
              time,
              time,
              time,
              row['source_rowid'],
            ]);
          }
        } finally {
          insert.close();
          candidate.close();
          newest.close();
        }
      },
    );
    return rows.length;
  }

  void normalizeLegacyMasks({required int generationId}) {
    if (db.autocommit) {
      throw StateError(
        'Mask normalization requires a maintenance transaction.',
      );
    }
    final reportRow = db.select(
      'select validation_report_json from database_generations where id = ?',
      [generationId],
    ).single;
    final rawReport = reportRow['validation_report_json'] as String?;
    final report = rawReport == null
        ? <String, dynamic>{}
        : jsonDecode(rawReport) as Map<String, dynamic>;
    final merges = (report['mask_merges'] as List?) ?? <Object?>[];
    final groups = <(int, String), List<Map<String, Object?>>>{};
    for (final row in db.select(
      'select * from project_path_masks order by id',
    )) {
      final key = (
        row['project_id'] as int,
        normalizeProjectPath(row['path_mask'] as String),
      );
      groups.putIfAbsent(key, () => []).add(Map<String, Object?>.from(row));
    }
    for (final entry in groups.entries) {
      final originals = entry.value;
      final retained = originals.first;
      var priority = retained['priority'] as int;
      var active = retained['is_active'] as int;
      for (final duplicate in originals.skip(1)) {
        final candidatePriority = duplicate['priority'] as int;
        if (candidatePriority < priority) priority = candidatePriority;
        if (duplicate['is_active'] == 1) active = 1;
        db.execute('delete from project_path_masks where id = ?', [
          duplicate['id'],
        ]);
      }
      if (originals.length > 1) {
        merges.add({
          'retained_id': retained['id'],
          'normalized_mask': entry.key.$2,
          'originals': originals,
        });
      }
      db.execute(
        '''
        update project_path_masks set normalized_mask = ?, priority = ?, is_active = ?
        where id = ?
      ''',
        [entry.key.$2, priority, active, retained['id']],
      );
    }
    report['mask_merges'] = merges;
    db.execute(
      '''
      update database_generations set validation_report_json = ? where id = ?
    ''',
      [jsonEncode(report), generationId],
    );
  }
}

const _leadingFactColumns = [
  'session_row_id',
  'source_record_ordinal',
  'rollout_ordinal',
  'turn_ordinal',
  'epoch',
  'occurred_at_utc',
  'model',
];
const _trailingFactColumns = [
  'input_tokens',
  'cached_input_tokens',
  'cache_write_input_tokens',
  'output_tokens',
  'reasoning_output_tokens',
  'total_tokens',
  'branch_scope',
  'derivation',
  'event_fingerprint',
];
