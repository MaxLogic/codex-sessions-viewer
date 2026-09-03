import 'package:sqlite3/sqlite3.dart';

import '../usage/usage_summary.dart';

class ProjectTagStateStore {
  const ProjectTagStateStore(this.db);

  final Database db;

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
    final existing = db.select(
      'select id from project_path_masks where project_id = ? and path_mask = ?',
      [projectId, pathMask],
    );
    if (existing.isEmpty) {
      db.execute(
        '''
        insert into project_path_masks (
          project_id,
          path_mask,
          priority,
          is_active,
          created_at_utc,
          updated_at_utc
        ) values (?, ?, ?, ?, ?, ?)
        ''',
        [projectId, pathMask, priority, isActive ? 1 : 0, now, now],
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
      _recalculateUsageEventProjects();
      UsageSummaryRepository(db).rebuildDailyUsageInCurrentTransaction(
        projectionVersion: projectionVersion,
        pricing: pricing,
      );
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
    final sessions = db.select('''
      select id,
             display_path,
             working_directory_display,
             working_directory_platform,
             working_directory_unc
      from sessions
      where project_override = 0
      order by id
      ''');
    final now = _utcNow();
    for (final session in sessions) {
      final sessionId = session['id'] as String;
      final keys = _projectCandidatePaths(sessionId, session);
      final match = _bestProjectMatch(keys, masks);
      db.execute(
        '''
        update sessions
        set project_id = ?,
            project_name_snapshot = ?,
            updated_at_utc = ?
        where id = ?
        ''',
        [match?.projectId, match?.projectName, now, sessionId],
      );
      _updateSearchProject(sessionId, match?.projectName ?? '');
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
              paths.add(_normalizePath(value));
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
          normalizedMask: _normalizePath(row['path_mask'] as String),
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
        paths.add(_normalizePath(value));
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
      _normalizePath(row['path_key'] as String),
  ];

  _ProjectMask? _bestProjectMatch(
    List<String> pathKeys,
    List<_ProjectMask> masks,
  ) {
    for (final mask in masks) {
      final regex = _maskRegex(mask.normalizedMask);
      for (final pathKey in pathKeys) {
        if (regex.hasMatch(pathKey)) {
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
  const _ProjectMask({
    required this.projectId,
    required this.projectName,
    required this.normalizedMask,
  });

  final int projectId;
  final String projectName;
  final String normalizedMask;
}

String _utcNow() => DateTime.now().toUtc().toIso8601String();

String _normalizePath(String path) =>
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
