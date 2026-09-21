import 'package:sqlite3/sqlite3.dart';

import '../usage/usage_summary.dart';
import 'database_generation.dart';

class ProjectTagStateStore {
  const ProjectTagStateStore(this.db);

  final Database db;

  /// Called inside the event/session write transaction. Raw aliases remain
  /// evidence; only the identity keys are normalized.
  int resolveUsagePathContext({
    String? displayPath,
    String? platformPath,
    String? uncPath,
    int? detectedProjectId,
  }) {
    final rawPaths = [displayPath ?? '', platformPath ?? '', uncPath ?? ''];
    final keys = rawPaths.map(normalizeProjectPath).toList(growable: false);
    final existing = db.select('''
      select id, detected_project_id, detected_project_source from usage_path_contexts
      where normalization_version = 1
        and display_path_key = ? and platform_path_key = ? and unc_path_key = ?
    ''', keys);
    if (existing.isNotEmpty) {
      final id = existing.single['id'] as int;
      if (detectedProjectId != null &&
          (existing.single['detected_project_id'] != detectedProjectId ||
              existing.single['detected_project_source'] != 'detected')) {
        db.execute(
          '''
          update usage_path_contexts set detected_project_id = ?,
            detected_project_source = 'detected',
            effective_project_id = coalesce(mask_project_id, ?),
            resolution_source = case when mask_project_id is null then 'detected' else 'mask' end,
            updated_at_utc = ? where id = ?
        ''',
          [detectedProjectId, detectedProjectId, _utcNow(), id],
        );
      }
      _retainContextAliases(id, rawPaths);
      return id;
    }

    final match = _bestProjectMatch(
      keys.where((key) => key.isNotEmpty).toList(growable: false),
      _activeMasks(),
    );
    final now = _utcNow();
    db.execute(
      '''
      insert into usage_path_contexts (
        display_path_raw, platform_path_raw, unc_path_raw,
        display_path_key, platform_path_key, unc_path_key, normalization_version,
        detected_project_id, mask_project_id, effective_project_id,
        resolution_source, project_rules_version, created_at_utc, updated_at_utc
      ) values (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?,
        (select project_rules_version from database_state where id = 1), ?, ?)
    ''',
      [
        ...rawPaths,
        ...keys,
        detectedProjectId,
        match?.projectId,
        match?.projectId ?? detectedProjectId,
        match != null
            ? 'mask'
            : detectedProjectId != null
            ? 'detected'
            : 'unassigned',
        now,
        now,
      ],
    );
    final id = db.lastInsertRowId;
    _retainContextAliases(id, rawPaths);
    return id;
  }

  void _retainContextAliases(int contextId, List<String> rawPaths) {
    db.execute(
      '''
      insert or ignore into usage_path_context_aliases (
        path_context_id, display_path_raw, platform_path_raw, unc_path_raw
      ) values (?, ?, ?, ?)
    ''',
      [contextId, ...rawPaths],
    );
  }

  int upsertProject({
    required String name,
    String? description,
    bool isActive = true,
  }) {
    final now = _utcNow();
    db.execute(
      '''
      insert into projects (name, description, is_active, created_at_utc, updated_at_utc)
      values (?, ?, ?, ?, ?)
      on conflict(name) do update set
        description = excluded.description,
        is_active = excluded.is_active,
        updated_at_utc = excluded.updated_at_utc
      ''',
      [name, description, isActive ? 1 : 0, now, now],
    );
    return db.select('select id from projects where name = ?', [
          name,
        ]).single['id']
        as int;
  }

  int upsertProjectMask({
    required int projectId,
    required String pathMask,
    int priority = 100,
    bool isActive = true,
  }) {
    final now = _utcNow();
    final normalizedMask = normalizeProjectPath(pathMask);
    final existing = db.select(
      'select id from project_path_masks where project_id = ? and normalized_mask = ?',
      [projectId, normalizedMask],
    );
    if (existing.isEmpty) {
      db.execute(
        '''
        insert into project_path_masks (
          project_id,
          path_mask,
          normalized_mask,
          priority,
          is_active,
          created_at_utc,
          updated_at_utc
        ) values (?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          projectId,
          pathMask,
          normalizedMask,
          priority,
          isActive ? 1 : 0,
          now,
          now,
        ],
      );
      return db.lastInsertRowId;
    }
    final id = existing.single['id'] as int;
    db.execute(
      '''
      update project_path_masks
      set priority = ?,
          is_active = ?,
          updated_at_utc = ?
      where id = ?
      ''',
      [priority, isActive ? 1 : 0, now, id],
    );
    return id;
  }

  int upsertProjectMaskAndRecalculate({
    required int projectId,
    required String pathMask,
    int priority = 100,
    bool isActive = true,
    required int projectionVersion,
    UsagePricingCatalog pricing = const UsagePricingCatalog({}),
  }) {
    db.execute('begin immediate');
    try {
      final maskId = upsertProjectMask(
        projectId: projectId,
        pathMask: pathMask,
        priority: priority,
        isActive: isActive,
      );
      recalculateSessionProjects();
      if (DatabaseGenerationRepository(
            db,
          ).activeGeneration().targetSchemaVersion <
          16) {
        _recalculateUsageEventProjects();
        UsageSummaryRepository(db).rebuildDailyUsageInCurrentTransaction(
          projectionVersion: projectionVersion,
          pricing: pricing,
        );
      }
      db.execute('commit');
      return maskId;
    } on Object {
      try {
        db.execute('rollback');
      } on Object {
        // Preserve the original failure if SQLite already rolled back.
      }
      rethrow;
    }
  }

  void recalculateSessionProjects() {
    final masks = _activeMasks();
    db.execute(
      'update database_state set project_rules_version = project_rules_version + 1 where id = 1',
    );
    _recalculateUsagePathContexts(masks);
    _refreshSessionProjects(masks);
  }

  /// Reapply assignment after discovery or metadata changes, without changing
  /// project rules or remapping unrelated contexts. The caller owns the write
  /// transaction, including the detected_project_id update.
  void refreshSessionProject(String sessionId) {
    _refreshSessionProjects(_activeMasks(), sessionId: sessionId);
  }

  /// Remap one migration checkpoint without loading masks for every session.
  /// The caller commits these assignments together with its session cursor.
  void refreshSessionProjectsBatch(List<String> sessionIds) {
    if (sessionIds.length > 512) {
      throw ArgumentError.value(sessionIds.length, 'sessionIds', 'Maximum 512');
    }
    if (sessionIds.isEmpty) return;
    _refreshSessionProjects(_activeMasks(), sessionIds: sessionIds);
  }

  void _refreshSessionProjects(
    List<_ProjectMask> masks, {
    String? sessionId,
    List<String>? sessionIds,
  }) {
    String? lastSessionId;
    final now = _utcNow();
    while (true) {
      final sessions = db.select(
        '''
      select s.id,
             display_path,
             working_directory_display,
             working_directory_platform,
             working_directory_unc,
             s.detected_project_id,
             detected.name as detected_project_name
      from sessions s
      left join projects detected on detected.id = s.detected_project_id
      where s.project_override = 0
        ${sessionId == null ? '' : 'and s.id = ?'}
        ${sessionIds == null ? '' : 'and s.id in (${List.filled(sessionIds.length, '?').join(',')})'}
        ${lastSessionId == null ? '' : 'and s.id > ?'}
      order by s.id limit 512
      ''',
        [?sessionId, ...?sessionIds, ?lastSessionId],
      );
      if (sessions.isEmpty) return;
      for (final session in sessions) {
        final currentId = session['id'] as String;
        final keys = _projectCandidatePaths(currentId, session);
        final match = _bestProjectMatch(keys, masks);
        final projectId = match?.projectId ?? session['detected_project_id'];
        final projectName =
            match?.projectName ?? session['detected_project_name'] as String?;
        db.execute(
          '''
        update sessions
        set project_id = ?,
            project_name_snapshot = ?,
            updated_at_utc = ?
        where id = ?
        ''',
          [projectId, projectName, now, currentId],
        );
        _updateSearchProject(currentId, projectName ?? '');
      }
      if (sessionId != null || sessionIds != null) return;
      lastSessionId = sessions.last['id'] as String;
    }
  }

  void _recalculateUsagePathContexts(List<_ProjectMask> masks) {
    final version = db
        .select('select project_rules_version from database_state where id = 1')
        .single['project_rules_version'];
    final now = _utcNow();
    var lastId = 0;
    while (true) {
      final contexts = db.select(
        '''
        select id, display_path_key, platform_path_key, unc_path_key,
          detected_project_id, detected_project_source, resolution_source
        from usage_path_contexts where id > ? order by id limit 512
      ''',
        [lastId],
      );
      if (contexts.isEmpty) break;
      for (final context in contexts) {
        final keys = [
          context['display_path_key'] as String,
          context['platform_path_key'] as String,
          context['unc_path_key'] as String,
        ].where((key) => key.isNotEmpty).toList(growable: false);
        final match = _bestProjectMatch(keys, masks);
        final detectedId = context['detected_project_id'];
        final detectedSource = context['resolution_source'] == 'legacy_import'
            ? 'legacy_import'
            : context['detected_project_source'] as String;
        final source = match != null
            ? 'mask'
            : detectedId == null
            ? 'unassigned'
            : detectedSource;
        db.execute(
          '''
          update usage_path_contexts set mask_project_id = ?, effective_project_id = ?,
            resolution_source = ?, detected_project_source = ?,
            project_rules_version = ?, updated_at_utc = ?
          where id = ?
        ''',
          [
            match?.projectId,
            match?.projectId ?? detectedId,
            source,
            detectedSource,
            version,
            now,
            context['id'],
          ],
        );
      }
      lastId = contexts.last['id'] as int;
    }
  }

  void _recalculateUsageEventProjects() {
    final masks = _activeMasks();
    final update = db.prepare('''
      update usage_events
      set project_id = ?
      where session_row_id = ? and source_record_ordinal = ?
      ''');
    try {
      int? lastRowId;
      while (true) {
        final events = db.select(
          '''
          select
            rowid as usage_event_rowid,
            session_row_id,
            source_record_ordinal,
            project_id,
            working_directory_display,
            working_directory_platform,
            working_directory_unc
          from usage_events
          ${lastRowId == null ? '' : 'where rowid > ?'}
          order by rowid
          limit 512
          ''',
          [?lastRowId],
        );
        if (events.isEmpty) {
          break;
        }
        for (final event in events) {
          final paths = <String>{};
          for (final column in [
            'working_directory_display',
            'working_directory_platform',
            'working_directory_unc',
          ]) {
            final value = event[column] as String?;
            if (value != null && value.isNotEmpty) {
              paths.add(normalizeProjectPath(value));
            }
          }
          final projectId = _bestProjectMatch(
            paths.toList(growable: false),
            masks,
          )?.projectId;
          if (projectId == event['project_id']) {
            continue;
          }
          update.execute([
            projectId,
            event['session_row_id'],
            event['source_record_ordinal'],
          ]);
        }
        lastRowId = events.last['usage_event_rowid'] as int;
      }
    } finally {
      update.close();
    }
  }

  void setSessionProject(String sessionId, int? projectId) {
    final now = _utcNow();
    final projectName = projectId == null
        ? null
        : db.select('select name from projects where id = ?', [
                projectId,
              ]).single['name']
              as String;
    db.execute(
      '''
      update sessions
      set project_id = ?,
          project_name_snapshot = ?,
          project_override = 1,
          updated_at_utc = ?
      where id = ?
      ''',
      [projectId, projectName, now, sessionId],
    );
    _updateSearchProject(sessionId, projectName ?? '');
  }

  void setSessionTags(String sessionId, List<String> tags) {
    final now = _utcNow();
    final normalizedTags = {
      for (final tag in tags.map((tag) => tag.trim()))
        if (tag.isNotEmpty) tag,
    }.toList()..sort();

    db.execute('delete from session_tags where session_id = ?', [sessionId]);
    for (final tag in normalizedTags) {
      db.execute(
        '''
        insert into tags (name, created_at_utc, updated_at_utc)
        values (?, ?, ?)
        on conflict(name) do update set updated_at_utc = excluded.updated_at_utc
        ''',
        [tag, now, now],
      );
      final tagId =
          db.select('select id from tags where name = ?', [tag]).single['id']
              as int;
      db.execute(
        '''
        insert into session_tags (session_id, tag_id, created_at_utc)
        values (?, ?, ?)
        ''',
        [sessionId, tagId, now],
      );
    }
    db.execute('update sessions set updated_at_utc = ? where id = ?', [
      now,
      sessionId,
    ]);
    _updateSearchTags(sessionId, normalizedTags.join(' '));
  }

  void setPinned(String sessionId, bool isPinned) {
    db.execute(
      'update sessions set is_pinned = ?, updated_at_utc = ? where id = ?',
      [isPinned ? 1 : 0, _utcNow(), sessionId],
    );
  }

  void setArchived(String sessionId, bool isArchived, {String? reason}) {
    final now = _utcNow();
    db.execute(
      '''
      update sessions
      set is_archived = ?,
          archived_at_utc = ?,
          archive_reason = ?,
          updated_at_utc = ?
      where id = ?
      ''',
      [
        isArchived ? 1 : 0,
        isArchived ? now : null,
        isArchived ? reason : null,
        now,
        sessionId,
      ],
    );
  }

  List<_ProjectMask> _activeMasks() {
    final rows = db.select('''
      select ppm.project_id, p.name, ppm.path_mask, ppm.priority
      from project_path_masks ppm
      join projects p on p.id = ppm.project_id
      where ppm.is_active = 1 and p.is_active = 1
      order by ppm.priority asc, ppm.id asc
      ''');
    return [
      for (final row in rows)
        _ProjectMask(
          projectId: row['project_id'] as int,
          projectName: row['name'] as String,
          normalizedMask: normalizeProjectPath(row['path_mask'] as String),
        ),
    ];
  }

  List<String> _projectCandidatePaths(String sessionId, Row session) {
    final paths = <String>[];
    for (final column in [
      'working_directory_display',
      'working_directory_platform',
      'working_directory_unc',
      'display_path',
    ]) {
      final value = session[column] as String?;
      if (value != null && value.isNotEmpty) {
        paths.add(normalizeProjectPath(value));
      }
    }
    paths.addAll(_pathKeysFor(sessionId));
    return paths.toSet().toList();
  }

  List<String> _pathKeysFor(String sessionId) => [
    for (final row in db.select(
      'select path_key from session_path_keys where session_id = ?',
      [sessionId],
    ))
      normalizeProjectPath(row['path_key'] as String),
  ];

  _ProjectMask? _bestProjectMatch(
    List<String> pathKeys,
    List<_ProjectMask> masks,
  ) {
    for (final mask in masks) {
      for (final pathKey in pathKeys) {
        if (mask.matcher.hasMatch(pathKey)) {
          return mask;
        }
      }
    }
    return null;
  }

  void _updateSearchProject(String sessionId, String projectName) {
    final rowid = _sessionRowid(sessionId);
    if (rowid == null) {
      return;
    }
    db.execute('update session_search set project_name = ? where rowid = ?', [
      projectName,
      rowid,
    ]);
  }

  void _updateSearchTags(String sessionId, String tags) {
    final rowid = _sessionRowid(sessionId);
    if (rowid == null) {
      return;
    }
    db.execute('update session_search set tags = ? where rowid = ?', [
      tags,
      rowid,
    ]);
  }

  int? _sessionRowid(String sessionId) {
    final rows = db.select('select rowid from sessions where id = ?', [
      sessionId,
    ]);
    if (rows.isEmpty) {
      return null;
    }
    return rows.single['rowid'] as int;
  }
}

class _ProjectMask {
  _ProjectMask({
    required this.projectId,
    required this.projectName,
    required String normalizedMask,
  }) : matcher = _maskRegex(normalizedMask);

  final int projectId;
  final String projectName;
  final RegExp matcher;
}

String _utcNow() => DateTime.now().toUtc().toIso8601String();

String normalizeProjectPath(String path) =>
    path.replaceAll(r'\', '/').replaceAll(RegExp('/+'), '/').toLowerCase();

RegExp _maskRegex(String mask) {
  final buffer = StringBuffer('^');
  for (final codePoint in mask.runes) {
    final char = String.fromCharCode(codePoint);
    if (char == '*') {
      buffer.write('.*');
    } else {
      buffer.write(RegExp.escape(char));
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString());
}
