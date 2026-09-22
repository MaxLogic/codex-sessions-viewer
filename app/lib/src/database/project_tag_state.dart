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
    return _inTransaction(() {
      final maskId = upsertProjectMask(
        projectId: projectId,
        pathMask: pathMask,
        priority: priority,
        isActive: isActive,
      );
      _recalculateAfterRuleChange(projectionVersion, pricing);
      return maskId;
    });
  }

  /// What the "Move to project" dialog needs to know about a session.
  SessionProjectAssignment loadSessionProjectAssignment(String sessionId) {
    final session = db
        .select(
          '''
      select s.id,
             display_path,
             working_directory_display,
             working_directory_platform,
             working_directory_unc,
             s.project_name_snapshot,
             s.project_override,
             detected.name as detected_project_name
      from sessions s
      left join projects detected on detected.id = s.detected_project_id
      where s.id = ?
      ''',
          [sessionId],
        )
        .single;
    final match = _bestProjectMatch(
      _projectCandidatePaths(sessionId, session),
      _activeMasks(),
    );
    final workingDirectory =
        (session['working_directory_display'] as String?)?.trim() ?? '';
    return SessionProjectAssignment(
      projectName: session['project_name_snapshot'] as String?,
      isManual: session['project_override'] == 1,
      detectedProjectName: session['detected_project_name'] as String?,
      workingDirectory: workingDirectory.isEmpty ? null : workingDirectory,
      folderRule: match == null
          ? null
          : ProjectFolderRule(
              folder: projectRuleFolder(match.pathMask),
              projectName: match.projectName,
            ),
      projectNames: [
        for (final row in db.select(
          'select name from projects where is_active = 1 '
          'order by name collate nocase',
        ))
          row['name'] as String,
      ],
    );
  }

  /// Moves one session to [projectName], creating the project if needed.
  /// The session keeps this project until it is reset.
  void assignSessionProject(String sessionId, String projectName) {
    _inTransaction(() {
      setSessionProject(sessionId, _ensureProject(projectName));
    });
  }

  /// Returns [sessionId] to automatic assignment: folder rules, then the
  /// project detected from its working directory.
  void resetSessionProject(String sessionId) {
    _inTransaction(() {
      db.execute(
        'update sessions set project_override = 0, updated_at_utc = ? '
        'where id = ?',
        [_utcNow(), sessionId],
      );
      refreshSessionProject(sessionId);
    });
  }

  /// Adds a folder rule: sessions from [folder] and its subfolders belong to
  /// [projectName]. It replaces any rule for the same folder. When
  /// [sessionId] is given, that session drops its manual project so the
  /// rule applies to it too.
  void assignFolderToProject({
    required String folder,
    required String projectName,
    String? sessionId,
    required int projectionVersion,
    UsagePricingCatalog pricing = const UsagePricingCatalog({}),
  }) {
    _inTransaction(() {
      _putFolderRule(folder, _ensureProject(projectName));
      if (sessionId != null) {
        db.execute('update sessions set project_override = 0 where id = ?', [
          sessionId,
        ]);
      }
      _recalculateAfterRuleChange(projectionVersion, pricing);
    });
  }

  /// Removes the folder rule for [folder]; its sessions fall back to their
  /// detected projects.
  void removeFolderRule({
    required String folder,
    required int projectionVersion,
    UsagePricingCatalog pricing = const UsagePricingCatalog({}),
  }) {
    _inTransaction(() {
      _deleteFolderMasks(_trimFolder(folder));
      _recalculateAfterRuleChange(projectionVersion, pricing);
    });
  }

  /// Points the rule for [oldFolder] at [newFolder], keeping its project.
  void changeFolderRule({
    required String oldFolder,
    required String newFolder,
    required String projectName,
    required int projectionVersion,
    UsagePricingCatalog pricing = const UsagePricingCatalog({}),
  }) {
    _inTransaction(() {
      _deleteFolderMasks(_trimFolder(oldFolder));
      _putFolderRule(newFolder, _ensureProject(projectName));
      _recalculateAfterRuleChange(projectionVersion, pricing);
    });
  }

  /// Merges project [sourceProjectId] into [targetName]: every folder its
  /// sessions were detected from and every folder rule of it now point at
  /// the target, and sessions moved to it by hand move too.
  void mergeProject({
    required int sourceProjectId,
    required String targetName,
    required int projectionVersion,
    UsagePricingCatalog pricing = const UsagePricingCatalog({}),
  }) {
    _inTransaction(() {
      final targetId = _ensureProject(targetName);
      if (targetId == sourceProjectId) {
        throw ArgumentError.value(targetName, 'targetName', 'Same project');
      }
      final folders = {
        for (final folder in _detectedFolders(sourceProjectId).keys)
          normalizeProjectPath(folder): folder,
        for (final folder in _ruleFolders(sourceProjectId))
          normalizeProjectPath(folder): folder,
      };
      for (final folder in folders.values) {
        _putFolderRule(folder, targetId);
      }
      for (final row in db.select(
        'select id from sessions where project_id = ? and project_override = 1',
        [sourceProjectId],
      )) {
        setSessionProject(row['id'] as String, targetId);
      }
      _recalculateAfterRuleChange(projectionVersion, pricing);
    });
  }

  /// Returns the sessions of [projectId] that were moved there by hand to
  /// automatic assignment.
  void resetManualSessions({required int projectId}) {
    _inTransaction(() {
      final ids = [
        for (final row in db.select(
          'select id from sessions where project_id = ? and project_override = 1',
          [projectId],
        ))
          row['id'] as String,
      ];
      db.execute(
        'update sessions set project_override = 0, updated_at_utc = ? '
        'where project_id = ? and project_override = 1',
        [_utcNow(), projectId],
      );
      for (var start = 0; start < ids.length; start += 512) {
        refreshSessionProjectsBatch(
          ids.sublist(start, (start + 512).clamp(0, ids.length)),
        );
      }
    });
  }

  /// Every folder rule and manual session project, for undo.
  ProjectRulesSnapshot snapshotProjectRules() {
    return ProjectRulesSnapshot(
      masks: [
        for (final row in db.select('''
          select p.name, m.path_mask, m.priority, m.is_active
          from project_path_masks m
          join projects p on p.id = m.project_id
          order by m.id
          '''))
          (
            projectName: row['name'] as String,
            pathMask: row['path_mask'] as String,
            priority: row['priority'] as int,
            isActive: row['is_active'] == 1,
          ),
      ],
      manualSessions: {
        for (final row in db.select(
          'select id, project_name_snapshot from sessions '
          'where project_override = 1',
        ))
          row['id'] as String: row['project_name_snapshot'] as String?,
      },
    );
  }

  /// Puts folder rules and manual session projects back as [snapshot] had
  /// them.
  void restoreProjectRules(
    ProjectRulesSnapshot snapshot, {
    required int projectionVersion,
    UsagePricingCatalog pricing = const UsagePricingCatalog({}),
  }) {
    _inTransaction(() {
      db.execute('delete from project_path_masks');
      for (final mask in snapshot.masks) {
        upsertProjectMask(
          projectId: _ensureProject(mask.projectName),
          pathMask: mask.pathMask,
          priority: mask.priority,
          isActive: mask.isActive,
        );
      }
      final now = _utcNow();
      for (final row in db.select(
        'select id from sessions where project_override = 1',
      )) {
        final id = row['id'] as String;
        if (!snapshot.manualSessions.containsKey(id)) {
          db.execute(
            'update sessions set project_override = 0, updated_at_utc = ? '
            'where id = ?',
            [now, id],
          );
        }
      }
      for (final entry in snapshot.manualSessions.entries) {
        final name = entry.value;
        setSessionProject(
          entry.key,
          name == null ? null : _ensureProject(name),
        );
      }
      _recalculateAfterRuleChange(projectionVersion, pricing);
    });
  }

  /// Projects that have sessions or folder rules, with their counts.
  List<ProjectSummary> listProjects() {
    final stats = {
      for (final row in db.select('''
        select project_id,
               count(*) as session_count,
               sum(project_override) as manual_count,
               max(coalesce(last_message_at_utc, started_at_utc)) as last_activity
        from sessions
        where project_id is not null
        group by project_id
        '''))
        row['project_id'] as int: row,
    };
    final ruleFolders = <int, Set<String>>{};
    for (final row in db.select(
      'select project_id, path_mask from project_path_masks where is_active = 1',
    )) {
      ruleFolders
          .putIfAbsent(row['project_id'] as int, () => {})
          .add(
            normalizeProjectPath(projectRuleFolder(row['path_mask'] as String)),
          );
    }
    return [
      for (final row in db.select(
        'select id, name from projects where is_active = 1',
      ))
        if (stats.containsKey(row['id']) || ruleFolders.containsKey(row['id']))
          ProjectSummary(
            id: row['id'] as int,
            name: row['name'] as String,
            sessionCount: stats[row['id']]?['session_count'] as int? ?? 0,
            manualSessionCount: stats[row['id']]?['manual_count'] as int? ?? 0,
            folderRuleCount: ruleFolders[row['id']]?.length ?? 0,
            lastActivityUtc: DateTime.tryParse(
              stats[row['id']]?['last_activity'] as String? ?? '',
            )?.toUtc(),
          ),
    ];
  }

  /// The folder rules of [projectId] with how many sessions each places, the
  /// folders its sessions were detected from, and its manual sessions.
  ProjectDetail loadProjectDetail(int projectId) {
    final masks = _activeMasks();
    final ruleMasks = masks.where((mask) => mask.projectId == projectId);
    final rules = <String, _RuleUsageBuilder>{};
    for (final mask in ruleMasks) {
      final folder = projectRuleFolder(mask.pathMask);
      rules
          .putIfAbsent(
            normalizeProjectPath(folder),
            () => _RuleUsageBuilder(folder),
          )
          .masks
          .add(mask);
    }
    if (rules.isNotEmpty) {
      final pathKeys = <String, List<String>>{};
      for (final row in db.select(
        'select session_id, path_key from session_path_keys',
      )) {
        pathKeys
            .putIfAbsent(row['session_id'] as String, () => [])
            .add(normalizeProjectPath(row['path_key'] as String));
      }
      for (final session in db.select('''
        select id, display_path, working_directory_display,
               working_directory_platform, working_directory_unc
        from sessions where project_override = 0
        ''')) {
        final keys = {
          for (final column in [
            'working_directory_display',
            'working_directory_platform',
            'working_directory_unc',
            'display_path',
          ])
            if ((session[column] as String?)?.isNotEmpty ?? false)
              normalizeProjectPath(session[column] as String),
          ...?pathKeys[session['id']],
        }.toList(growable: false);
        final best = _bestProjectMatch(keys, masks);
        if (best == null) {
          continue;
        }
        for (final rule in rules.values) {
          if (rule.masks.contains(best)) {
            rule.sessionCount++;
          } else if (rule.masks.any(
            (mask) => keys.any(mask.matcher.hasMatch),
          )) {
            final winner = ProjectFolderRule(
              folder: projectRuleFolder(best.pathMask),
              projectName: best.projectName,
            );
            rule.overriddenBy[winner] = (rule.overriddenBy[winner] ?? 0) + 1;
          }
        }
      }
    }
    final manual =
        db.select(
              'select count(*) as n from sessions '
              'where project_id = ? and project_override = 1',
              [projectId],
            ).single['n']
            as int;
    final detected = _detectedFolders(projectId);
    return ProjectDetail(
      projectId: projectId,
      rules: [
        for (final rule
            in rules.values.toList()..sort(
              (a, b) =>
                  a.folder.toLowerCase().compareTo(b.folder.toLowerCase()),
            ))
          rule.build(),
      ],
      detectedFolders: [
        for (final entry
            in detected.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
          (folder: entry.key, sessionCount: entry.value),
      ],
      manualSessionCount: manual,
    );
  }

  /// Folders that sessions detected as [projectId] came from, with session
  /// counts. The folder is the project root: the part of the working
  /// directory up to the segment named like the project.
  Map<String, int> _detectedFolders(int projectId) {
    final name =
        db.select('select name from projects where id = ?', [
              projectId,
            ]).single['name']
            as String;
    final byKey = <String, ({String folder, int count})>{};
    for (final row in db.select(
      'select working_directory_display from sessions '
      'where detected_project_id = ?',
      [projectId],
    )) {
      final directory = (row['working_directory_display'] as String?)?.trim();
      if (directory == null || directory.isEmpty) {
        continue;
      }
      final folder = projectRootFolder(directory, name);
      final key = normalizeProjectPath(folder);
      final current = byKey[key];
      byKey[key] = (
        folder: current?.folder ?? folder,
        count: (current?.count ?? 0) + 1,
      );
    }
    return {for (final value in byKey.values) value.folder: value.count};
  }

  List<String> _ruleFolders(int projectId) {
    final byKey = <String, String>{};
    for (final row in db.select(
      'select path_mask from project_path_masks where project_id = ?',
      [projectId],
    )) {
      final folder = projectRuleFolder(row['path_mask'] as String);
      byKey.putIfAbsent(normalizeProjectPath(folder), () => folder);
    }
    return byKey.values.toList(growable: false);
  }

  /// Replaces any rule for [folder] with one that sends it and its
  /// subfolders to [projectId]. The caller owns the transaction.
  void _putFolderRule(String folder, int projectId) {
    final base = _trimFolder(folder);
    if (base.isEmpty) {
      throw ArgumentError.value(folder, 'folder', 'Must not be empty');
    }
    _deleteFolderMasks(base);
    final separator = base.contains(r'\') ? r'\' : '/';
    for (final mask in [base, '$base$separator*']) {
      upsertProjectMask(projectId: projectId, pathMask: mask, priority: 10);
    }
  }

  void _deleteFolderMasks(String base) {
    final normalized = normalizeProjectPath(base);
    db.execute(
      'delete from project_path_masks where normalized_mask in (?, ?, ?)',
      [normalized, '$normalized/*', '$normalized*'],
    );
  }

  int _ensureProject(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Must not be empty');
    }
    final existing = db.select(
      'select id, is_active from projects where name = ?',
      [trimmed],
    );
    if (existing.isNotEmpty) {
      final row = existing.single;
      if (row['is_active'] != 1) {
        db.execute(
          'update projects set is_active = 1, updated_at_utc = ? where id = ?',
          [_utcNow(), row['id']],
        );
      }
      return row['id'] as int;
    }
    return upsertProject(name: trimmed);
  }

  void _recalculateAfterRuleChange(
    int projectionVersion,
    UsagePricingCatalog pricing,
  ) {
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
  }

  T _inTransaction<T>(T Function() work) {
    db.execute('begin immediate');
    try {
      final result = work();
      db.execute('commit');
      return result;
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
    final masks = [
      for (final row in rows)
        _ProjectMask(
          projectId: row['project_id'] as int,
          projectName: row['name'] as String,
          pathMask: row['path_mask'] as String,
          normalizedMask: normalizeProjectPath(row['path_mask'] as String),
        ),
    ];
    // The more specific folder wins: a rule for F:\worktrees\viewer-wt beats
    // one for F:\worktrees. Priority, then age, break ties (stable sort).
    final order = {for (final (index, mask) in masks.indexed) mask: index};
    return masks..sort((a, b) {
      final bySpecificity = b.specificity.compareTo(a.specificity);
      return bySpecificity != 0
          ? bySpecificity
          : order[a]!.compareTo(order[b]!);
    });
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
    required this.pathMask,
    required String normalizedMask,
  }) : matcher = _maskRegex(normalizedMask);

  final int projectId;
  final String projectName;
  final String pathMask;
  final RegExp matcher;

  /// Length of the literal folder before the first wildcard.
  int get specificity {
    final normalized = normalizeProjectPath(pathMask);
    final star = normalized.indexOf('*');
    return star < 0 ? normalized.length : star;
  }
}

/// A folder rule as the user sees it: sessions from [folder] and its
/// subfolders belong to [projectName].
class ProjectFolderRule {
  const ProjectFolderRule({required this.folder, required this.projectName});

  final String folder;
  final String projectName;

  @override
  bool operator ==(Object other) =>
      other is ProjectFolderRule &&
      normalizeProjectPath(other.folder) == normalizeProjectPath(folder) &&
      other.projectName == projectName;

  @override
  int get hashCode => Object.hash(normalizeProjectPath(folder), projectName);
}

/// A project in the Projects list.
class ProjectSummary {
  const ProjectSummary({
    required this.id,
    required this.name,
    required this.sessionCount,
    required this.manualSessionCount,
    required this.folderRuleCount,
    required this.lastActivityUtc,
  });

  final int id;
  final String name;
  final int sessionCount;

  /// Sessions moved to this project by hand.
  final int manualSessionCount;
  final int folderRuleCount;
  final DateTime? lastActivityUtc;
}

/// A folder rule of a project and what it currently does.
class ProjectRuleUsage {
  const ProjectRuleUsage({
    required this.folder,
    required this.sessionCount,
    required this.overriddenBy,
  });

  final String folder;

  /// Sessions this rule places in its project.
  final int sessionCount;

  /// More specific rules that take sessions from this folder, with how many.
  final Map<ProjectFolderRule, int> overriddenBy;
}

class ProjectDetail {
  const ProjectDetail({
    required this.projectId,
    required this.rules,
    required this.detectedFolders,
    required this.manualSessionCount,
  });

  final int projectId;
  final List<ProjectRuleUsage> rules;

  /// Folders this project was detected from, most sessions first.
  final List<({String folder, int sessionCount})> detectedFolders;
  final int manualSessionCount;
}

/// Folder rules and manual session projects at one moment, for undo.
class ProjectRulesSnapshot {
  const ProjectRulesSnapshot({
    required this.masks,
    required this.manualSessions,
  });

  final List<
    ({String projectName, String pathMask, int priority, bool isActive})
  >
  masks;

  /// Session id to its manually set project name (null: no project).
  final Map<String, String?> manualSessions;
}

class _RuleUsageBuilder {
  _RuleUsageBuilder(this.folder);

  final String folder;
  final masks = <_ProjectMask>[];
  var sessionCount = 0;
  final overriddenBy = <ProjectFolderRule, int>{};

  ProjectRuleUsage build() => ProjectRuleUsage(
    folder: folder,
    sessionCount: sessionCount,
    overriddenBy: overriddenBy,
  );
}

/// The project root inside [workingDirectory]: the path up to the last
/// segment named [projectName], or the whole directory when none is.
String projectRootFolder(String workingDirectory, String projectName) {
  final separator = workingDirectory.contains(r'\') ? r'\' : '/';
  final segments = workingDirectory.split(RegExp(r'[\\/]'));
  final wanted = projectName.toLowerCase();
  for (var index = segments.length - 1; index >= 0; index--) {
    if (segments[index].toLowerCase() == wanted) {
      return segments.sublist(0, index + 1).join(separator);
    }
  }
  return _trimFolder(workingDirectory);
}

class SessionProjectAssignment {
  const SessionProjectAssignment({
    required this.projectName,
    required this.isManual,
    required this.detectedProjectName,
    required this.workingDirectory,
    required this.folderRule,
    required this.projectNames,
  });

  final String? projectName;

  /// The project was set by hand for this session.
  final bool isManual;
  final String? detectedProjectName;
  final String? workingDirectory;

  /// The folder rule matching this session; it applies unless [isManual].
  final ProjectFolderRule? folderRule;

  /// Active project names, sorted.
  final List<String> projectNames;
}

/// The folder a path mask covers, without a trailing `*` or separator.
String projectRuleFolder(String pathMask) {
  var folder = pathMask.trim();
  if (folder.endsWith('*')) {
    folder = folder.substring(0, folder.length - 1);
  }
  return _trimFolder(folder);
}

String _trimFolder(String folder) {
  var trimmed = folder.trim();
  while (trimmed.length > 1 &&
      (trimmed.endsWith('/') || trimmed.endsWith(r'\')) &&
      !RegExp(r'^[A-Za-z]:[\\/]$').hasMatch(trimmed)) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  return trimmed;
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
