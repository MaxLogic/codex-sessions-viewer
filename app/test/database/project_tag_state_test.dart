import 'dart:io';

import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:codex_sessions_viewer/src/search/session_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late SessionSearchIndex searchIndex;
  late ProjectTagStateStore store;

  setUp(() {
    db = sqlite3.openInMemory();
    db.execute(File('../sql/init/001_initial_schema.sql').readAsStringSync());
    db.execute(
      File('../sql/migration/002_search_filter_schema.sql').readAsStringSync(),
    );
    db.execute(
      File('../sql/migration/003_project_override.sql').readAsStringSync(),
    );
    db.execute(
      File('../sql/migration/009_message_search.sql').readAsStringSync(),
    );
    db.execute(
      File(
        '../sql/migration/012_external_content_search.sql',
      ).readAsStringSync(),
    );
    db.execute(
      File(
        '../sql/migration/016_persisted_usage_pricing_maintenance.sql',
      ).readAsStringSync(),
    );
    searchIndex = SessionSearchIndex(db);
    store = ProjectTagStateStore(db);
  });

  tearDown(() {
    db.close();
  });

  test(
    'later discovery fills an existing context and missing discovery retains it',
    () {
      final id = store.resolveUsagePathContext(displayPath: 'c:/client');
      final project = store.upsertProject(name: 'Discovered');
      expect(
        store.resolveUsagePathContext(
          displayPath: 'c:/client',
          detectedProjectId: project,
        ),
        id,
      );
      expect(
        db.select(
          'select detected_project_id from usage_path_contexts where id = ?',
          [id],
        ).single['detected_project_id'],
        project,
      );
      store.resolveUsagePathContext(displayPath: 'c:/client');
      expect(
        db.select(
          'select effective_project_id from usage_path_contexts where id = ?',
          [id],
        ).single['effective_project_id'],
        project,
      );
    },
  );

  test('legacy fallback provenance survives a mask being added and removed', () {
    final imported = store.upsertProject(name: 'Imported');
    final masked = store.upsertProject(name: 'Masked');
    final contextId = store.resolveUsagePathContext(
      displayPath: 'c:/legacy',
      detectedProjectId: imported,
    );
    db.execute(
      "update usage_path_contexts set resolution_source = 'legacy_import' where id = ?",
      [contextId],
    );
    final maskId = store.upsertProjectMask(projectId: masked, pathMask: 'c:/*');
    store.recalculateSessionProjects();
    expect(
      db.select(
        'select resolution_source from usage_path_contexts where id = ?',
        [contextId],
      ).single['resolution_source'],
      'mask',
    );
    db.execute('delete from project_path_masks where id = ?', [maskId]);

    store.recalculateSessionProjects();

    final context = db.select(
      'select * from usage_path_contexts where id = ?',
      [contextId],
    ).single;
    expect(context['effective_project_id'], imported);
    expect(context['resolution_source'], 'legacy_import');
  });

  test('project deletion recalculates fallback without losing path evidence', () {
    db.execute('pragma foreign_keys = on');
    expect(db.select('pragma foreign_keys').single.values.single, 1);
    final first = store.upsertProject(name: 'First mask');
    final second = store.upsertProject(name: 'Second mask');
    final detected = store.upsertProject(name: 'Detected');
    final manual = store.upsertProject(name: 'Manual');
    for (final id in ['automatic', 'manual']) {
      searchIndex.upsert(_document(id: id, displayPath: 'c:/client/$id.jsonl'));
      db.execute('update sessions set detected_project_id = ? where id = ?', [
        detected,
        id,
      ]);
    }
    store.setSessionProject('manual', manual);
    store.upsertProjectMask(
      projectId: first,
      pathMask: 'c:/client/*',
      priority: 1,
    );
    store.upsertProjectMask(
      projectId: second,
      pathMask: 'c:/client/*',
      priority: 2,
    );
    store.upsertProjectMask(projectId: second, pathMask: 'c:/retained/*');
    final contextId = store.resolveUsagePathContext(
      displayPath: r'C:\Client\Source',
      detectedProjectId: detected,
    );
    expect(
      store.resolveUsagePathContext(displayPath: 'c:/client/source'),
      contextId,
    );
    final retainedMaskContext = store.resolveUsagePathContext(
      displayPath: 'c:/retained/source',
      detectedProjectId: first,
    );
    store.recalculateSessionProjects();
    expect(_sessionProject(db, 'automatic'), 'First mask');
    final rawEvidence = db.select('''
      select * from usage_path_context_aliases
      order by path_context_id, display_path_raw, platform_path_raw, unc_path_raw
    ''');
    final contextCount = db
        .select('select count(*) n from usage_path_contexts')
        .single['n'];

    for (final step in [
      (deleted: first, effective: second, name: 'Second mask', source: 'mask'),
      (
        deleted: second,
        effective: detected,
        name: 'Detected',
        source: 'detected',
      ),
      (deleted: detected, effective: null, name: null, source: 'unassigned'),
    ]) {
      // Deletion has no production UI/API. Exercise the existing SQL and
      // recalculation boundary atomically, not an implicit FK-only remap.
      db.execute('begin immediate');
      try {
        db.execute('delete from projects where id = ?', [step.deleted]);
        store.recalculateSessionProjects();
        db.execute('commit');
      } on Object {
        db.execute('rollback');
        rethrow;
      }
      final context = db.select(
        'select * from usage_path_contexts where id = ?',
        [contextId],
      ).single;
      expect(context['effective_project_id'], step.effective);
      expect(context['resolution_source'], step.source);
      expect(
        context['detected_project_id'],
        step.deleted == detected ? null : detected,
      );
      expect(context['mask_project_id'], step.deleted == first ? second : null);
      expect(context['display_path_raw'], r'C:\Client\Source');
      expect(_sessionProject(db, 'automatic'), step.name);
      final retained = db.select(
        'select * from usage_path_contexts where id = ?',
        [retainedMaskContext],
      ).single;
      expect(retained['detected_project_id'], isNull);
      expect(
        retained['effective_project_id'],
        step.deleted == first ? second : null,
      );
      expect(
        retained['resolution_source'],
        step.deleted == first ? 'mask' : 'unassigned',
      );
      expect(_sessionProject(db, 'manual'), 'Manual');
      expect(
        db
            .select(
              "select project_id, project_override from sessions where id = 'manual'",
            )
            .single,
        {'project_id': manual, 'project_override': 1},
      );
      expect(
        searchIndex.search(
          const SessionSearchQuery(
            projectNames: {'Manual'},
            archived: ArchivedFilter.all,
          ),
        ),
        ['manual'],
      );
      expect(
        db.select('select * from project_path_masks where project_id = ?', [
          step.deleted,
        ]),
        isEmpty,
      );
      expect(
        db.select('select count(*) n from usage_path_contexts').single['n'],
        contextCount,
      );
      expect(
        db.select('''
        select * from usage_path_context_aliases
        order by path_context_id, display_path_raw, platform_path_raw, unc_path_raw
      '''),
        rawEvidence,
      );
      expect(db.select('pragma foreign_key_check'), isEmpty);
    }
  });

  test(
    'mask upsert uses normalized identity and preserves literal glob characters',
    () {
      final project = store.upsertProject(name: 'Literal Client');
      final first = store.upsertProjectMask(
        projectId: project,
        pathMask: r'*C:\Work\\Client[1]\*',
        priority: 20,
      );
      final equivalent = store.upsertProjectMask(
        projectId: project,
        pathMask: '*c:/work/client[1]/*',
        priority: 5,
      );
      expect(equivalent, first);
      expect(
        db
            .select('select normalized_mask from project_path_masks')
            .single['normalized_mask'],
        '*c:/work/client[1]/*',
      );
      final literal = store.resolveUsagePathContext(
        displayPath: r'prefix-C:\Work\Client[1]\src',
      );
      final regexLike = store.resolveUsagePathContext(
        displayPath: r'prefix-C:\Work\Client1\src',
      );
      expect(
        db.select(
          'select mask_project_id from usage_path_contexts where id = ?',
          [literal],
        ).single['mask_project_id'],
        project,
      );
      expect(
        db.select(
          'select mask_project_id from usage_path_contexts where id = ?',
          [regexLike],
        ).single['mask_project_id'],
        isNull,
      );
    },
  );

  test(
    'context identity retains every raw alias tuple after normalization',
    () {
      final project = store.upsertProject(name: 'Client');
      final original = store.resolveUsagePathContext(
        displayPath: r'C:\Work\\Client',
        platformPath: '/home/User/Client',
        uncPath: r'\\wsl.localhost\Ubuntu\home\User\Client',
        detectedProjectId: project,
      );
      final variant = store.resolveUsagePathContext(
        displayPath: 'c:/work/client',
        platformPath: '/home/user/client',
        uncPath: '//wsl.localhost/ubuntu/home/user/client',
        detectedProjectId: project,
      );
      expect(variant, original);
      expect(
        store.resolveUsagePathContext(
          displayPath: 'c:/work/client',
          platformPath: '/home/user/client',
          uncPath: '//wsl.localhost/ubuntu/home/user/client',
          detectedProjectId: project,
        ),
        original,
      );
      expect(
        db
            .select(
              '''
      select display_path_raw, platform_path_raw, unc_path_raw
      from usage_path_context_aliases where path_context_id = ?
      order by display_path_raw
    ''',
              [original],
            )
            .map((row) => row.values.toList()),
        [
          [
            r'C:\Work\\Client',
            '/home/User/Client',
            r'\\wsl.localhost\Ubuntu\home\User\Client',
          ],
          [
            'c:/work/client',
            '/home/user/client',
            '//wsl.localhost/ubuntu/home/user/client',
          ],
        ],
      );
      final context = db.select(
        'select * from usage_path_contexts where id = ?',
        [original],
      ).single;
      expect(context['display_path_raw'], r'C:\Work\\Client');
      expect(context['detected_project_id'], project);
      expect(context['effective_project_id'], project);
      final plan = db.select(
        '''
      explain query plan select id from usage_path_contexts
      where normalization_version = 1 and display_path_key = ?
        and platform_path_key = ? and unc_path_key = ?
    ''',
        [
          'c:/work/client',
          '/home/user/client',
          '/wsl.localhost/ubuntu/home/user/client',
        ],
      );
      expect(
        plan.map((row) => row['detail']).join(' '),
        contains('idx_usage_path_contexts_identity'),
      );
      expect(store.resolveUsagePathContext(), 1);
    },
  );

  test(
    'mask removal restores detected project without replacing manual override',
    () {
      searchIndex.upsert(
        _document(id: 'detected', displayPath: r'C:\work\client\a.jsonl'),
      );
      searchIndex.upsert(
        _document(id: 'manual', displayPath: r'C:\work\client\b.jsonl'),
      );
      final detected = store.upsertProject(name: 'Detected Client');
      final matched = store.upsertProject(name: 'Mask Client');
      final manual = store.upsertProject(name: 'Manual Client');
      db.execute('update sessions set detected_project_id = ?', [detected]);
      store.setSessionProject('manual', manual);
      final mask = store.upsertProjectMask(
        projectId: matched,
        pathMask: r'C:\work\client\*',
      );
      final contextId = store.resolveUsagePathContext(
        displayPath: r'C:\work\client\src',
        detectedProjectId: detected,
      );
      store.recalculateSessionProjects();
      expect(_sessionProject(db, 'detected'), 'Mask Client');
      db.execute('update project_path_masks set is_active = 0 where id = ?', [
        mask,
      ]);

      store.recalculateSessionProjects();

      expect(_sessionProject(db, 'detected'), 'Detected Client');
      expect(_sessionProject(db, 'manual'), 'Manual Client');
      final context = db.select(
        'select * from usage_path_contexts where id = ?',
        [contextId],
      ).single;
      expect(context['mask_project_id'], isNull);
      expect(context['detected_project_id'], detected);
      expect(context['effective_project_id'], detected);
      expect(context['resolution_source'], 'detected');
      expect(context['project_rules_version'], greaterThan(0));
      expect(
        searchIndex.search(
          const SessionSearchQuery(projectNames: {'Detected Client'}),
        ),
        ['detected'],
      );
    },
  );

  test(
    'session remapping preserves aliases and overrides across seek batches',
    () {
      final detected = store.upsertProject(name: 'Detected');
      final masked = store.upsertProject(name: 'Masked');
      final manual = store.upsertProject(name: 'Manual');
      for (var index = 0; index < 520; index++) {
        searchIndex.upsert(
          _document(
            id: 'session-${index.toString().padLeft(4, '0')}',
            displayPath: 'c:/unmatched/$index.jsonl',
            normalizedPathKeys: 'c:/aliases/$index.jsonl',
          ),
        );
      }
      db.execute('update sessions set detected_project_id = ?', [detected]);
      store.setSessionProject('session-0519', manual);
      final mask = store.upsertProjectMask(
        projectId: masked,
        pathMask: 'c:/aliases/*',
      );
      store.recalculateSessionProjects();
      expect(
        searchIndex.search(const SessionSearchQuery(projectNames: {'Masked'})),
        hasLength(519),
      );
      expect(_sessionProject(db, 'session-0519'), 'Manual');
      db.execute('delete from project_path_masks where id = ?', [mask]);
      store.recalculateSessionProjects();
      expect(
        searchIndex.search(
          const SessionSearchQuery(projectNames: {'Detected'}),
        ),
        hasLength(519),
      );
      expect(_sessionProject(db, 'session-0519'), 'Manual');
    },
  );

  test('persists projects and assigns sessions by active mask priority', () {
    searchIndex.upsert(
      _document(
        id: 'viewer',
        displayPath: r'F:\projects\MaxLogic\codex-sessions-viewer\a.jsonl',
        normalizedPathKeys:
            'f:/projects/maxlogic/codex-sessions-viewer/a.jsonl',
      ),
    );
    searchIndex.upsert(
      _document(
        id: 'other',
        displayPath: r'F:\projects\MaxLogic\other\b.jsonl',
        normalizedPathKeys: 'f:/projects/maxlogic/other/b.jsonl',
      ),
    );

    final broad = store.upsertProject(name: 'MaxLogic');
    final specific = store.upsertProject(name: 'Viewer');
    store.upsertProjectMask(
      projectId: broad,
      pathMask: r'F:\projects\MaxLogic\*',
      priority: 50,
    );
    store.upsertProjectMask(
      projectId: specific,
      pathMask: 'f:/projects/maxlogic/codex-sessions-viewer/*',
      priority: 10,
    );

    store.recalculateSessionProjects();

    expect(_sessionProject(db, 'viewer'), 'Viewer');
    expect(_sessionProject(db, 'other'), 'MaxLogic');
    expect(
      searchIndex.search(
        const SessionSearchQuery(
          projectNames: {'Viewer'},
          archived: ArchivedFilter.all,
        ),
      ),
      ['viewer'],
    );
    expect(searchIndex.search(const SessionSearchQuery(text: 'viewer')), [
      'viewer',
    ]);
  });

  test('assigns projects from working directory before session file path', () {
    searchIndex.upsert(
      _document(id: 'working-dir', displayPath: 'session.jsonl'),
    );
    db.execute(
      '''
      update sessions
      set working_directory_display = ?,
          working_directory_platform = ?,
          working_directory_unc = ?
      where id = ?
      ''',
      [
        r'C:\work\client',
        r'C:\work\client',
        r'\\wsl.localhost\Ubuntu\home\pawel\work\client',
        'working-dir',
      ],
    );
    final projectId = store.upsertProject(name: 'Client');
    store.upsertProjectMask(
      projectId: projectId,
      pathMask: r'C:\work\client',
      priority: 1,
    );

    store.recalculateSessionProjects();

    expect(_sessionProject(db, 'working-dir'), 'Client');
  });

  test('ignores inactive projects and masks during recalculation', () {
    searchIndex.upsert(
      _document(
        id: 'session',
        displayPath: r'C:\work\inactive\a.jsonl',
        normalizedPathKeys: 'c:/work/inactive/a.jsonl',
      ),
    );
    final inactiveProject = store.upsertProject(
      name: 'Inactive Project',
      isActive: false,
    );
    final activeProject = store.upsertProject(name: 'Active Project');
    store.upsertProjectMask(
      projectId: inactiveProject,
      pathMask: 'c:/work/inactive/*',
      priority: 1,
    );
    store.upsertProjectMask(
      projectId: activeProject,
      pathMask: 'c:/work/inactive/*',
      priority: 2,
      isActive: false,
    );

    store.recalculateSessionProjects();

    expect(_sessionProject(db, 'session'), isNull);
  });

  test('persists tag assignments and keeps search filters in sync', () {
    searchIndex.upsert(_document(id: 'tagged', title: 'Tag target'));

    store.setSessionTags('tagged', const ['important', 'parser']);

    expect(
      db
          .select(
            'select t.name from session_tags st '
            'join tags t on t.id = st.tag_id '
            'where st.session_id = ? order by t.name',
            ['tagged'],
          )
          .map((row) => row['name']),
      ['important', 'parser'],
    );
    expect(
      searchIndex.search(
        const SessionSearchQuery(
          tags: {'important'},
          archived: ArchivedFilter.all,
        ),
      ),
      ['tagged'],
    );
    expect(searchIndex.search(const SessionSearchQuery(text: 'parser')), [
      'tagged',
    ]);

    store.setSessionTags('tagged', const ['reviewed']);

    expect(
      searchIndex.search(
        const SessionSearchQuery(
          tags: {'important'},
          archived: ArchivedFilter.all,
        ),
      ),
      isEmpty,
    );
    expect(
      searchIndex.search(
        const SessionSearchQuery(
          tags: {'reviewed'},
          archived: ArchivedFilter.all,
        ),
      ),
      ['tagged'],
    );
  });

  test('manual project override survives mask recalculation', () {
    searchIndex.upsert(
      _document(
        id: 'override',
        displayPath: r'C:\work\auto\session.jsonl',
        normalizedPathKeys: 'c:/work/auto/session.jsonl',
      ),
    );
    final automaticProject = store.upsertProject(name: 'Automatic');
    final manualProject = store.upsertProject(name: 'Manual');
    store.upsertProjectMask(
      projectId: automaticProject,
      pathMask: 'c:/work/auto/*',
      priority: 1,
    );

    store.setSessionProject('override', manualProject);
    store.recalculateSessionProjects();

    expect(_sessionProject(db, 'override'), 'Manual');
    expect(
      searchIndex.search(
        const SessionSearchQuery(
          projectNames: {'Manual'},
          archived: ArchivedFilter.all,
        ),
      ),
      ['override'],
    );
  });

  test(
    'rescan upsert preserves user-managed projects tags pin and archive',
    () {
      searchIndex.upsert(
        _document(
          id: 'rescanned',
          title: 'Original title',
          displayPath: r'C:\work\session.jsonl',
          normalizedPathKeys: 'c:/work/session.jsonl',
        ),
      );
      final projectId = store.upsertProject(name: 'Manual');
      store.setSessionProject('rescanned', projectId);
      store.setSessionTags('rescanned', const ['important']);
      store.setPinned('rescanned', true);
      store.setArchived('rescanned', true, reason: 'done');

      searchIndex.upsert(
        _document(
          id: 'rescanned',
          title: 'Updated title',
          displayPath: r'C:\work\session.jsonl',
          normalizedPathKeys: 'c:/work/session.jsonl',
        ),
      );

      final row = db
          .select(
            '''
          select project_name_snapshot, is_pinned, is_archived, archive_reason
          from sessions
          where id = ?
          ''',
            ['rescanned'],
          )
          .single;
      expect(row['project_name_snapshot'], 'Manual');
      expect(row['is_pinned'], 1);
      expect(row['is_archived'], 1);
      expect(row['archive_reason'], 'done');
      expect(
        searchIndex.search(
          const SessionSearchQuery(
            projectNames: {'Manual'},
            tags: {'important'},
            pinned: true,
            archived: ArchivedFilter.archivedOnly,
          ),
        ),
        ['rescanned'],
      );
      expect(
        searchIndex.search(
          const SessionSearchQuery(
            text: 'important',
            archived: ArchivedFilter.archivedOnly,
          ),
        ),
        ['rescanned'],
      );
      expect(
        searchIndex.search(
          const SessionSearchQuery(
            text: 'manual',
            archived: ArchivedFilter.archivedOnly,
          ),
        ),
        ['rescanned'],
      );
    },
  );

  test('persists pin and archive state without changing source paths', () {
    searchIndex.upsert(
      _document(id: 'stateful', displayPath: r'C:\sessions\stateful.jsonl'),
    );

    store.setPinned('stateful', true);
    store.setArchived('stateful', true, reason: 'done');

    final row = db
        .select(
          '''
      select is_pinned,
             is_archived,
             archive_reason,
             archived_at_utc,
             source_file_path,
             display_path,
             platform_path
      from sessions
      where id = ?
      ''',
          ['stateful'],
        )
        .single;
    expect(row['is_pinned'], 1);
    expect(row['is_archived'], 1);
    expect(row['archive_reason'], 'done');
    expect(row['archived_at_utc'], isNotNull);
    expect(row['source_file_path'], r'C:\sessions\stateful.jsonl');
    expect(row['display_path'], r'C:\sessions\stateful.jsonl');
    expect(row['platform_path'], r'C:\sessions\stateful.jsonl');
    expect(
      searchIndex.search(
        const SessionSearchQuery(
          pinned: true,
          archived: ArchivedFilter.archivedOnly,
        ),
      ),
      ['stateful'],
    );

    store.setArchived('stateful', false);

    expect(
      db.select(
        'select is_archived, archive_reason, archived_at_utc '
        'from sessions where id = ?',
        ['stateful'],
      ).single,
      containsPair('is_archived', 0),
    );
  });

  group('moving sessions between projects', () {
    late int mainProject;

    void addSession(String id, String workingDirectory, int? detected) {
      searchIndex.upsert(_document(id: id, displayPath: '$id.jsonl'));
      db.execute(
        'update sessions set working_directory_display = ?, '
        'detected_project_id = ?, project_id = ? where id = ?',
        [workingDirectory, detected, detected, id],
      );
      store.refreshSessionProject(id);
    }

    setUp(() {
      // A migrated database: usage follows path contexts, not usage_events.
      db.execute('update database_generations set target_schema_version = 16');
      mainProject = store.upsertProject(name: 'viewer');
      final worktree = store.upsertProject(name: 'viewer-wt');
      addSession('main', r'F:\projects\viewer', mainProject);
      addSession('wt-root', r'F:\projects\viewer-wt', worktree);
      addSession('wt-sub', r'F:\projects\viewer-wt\app', worktree);
      addSession('wt-sibling', r'F:\projects\viewer-wt2', worktree);
    });

    test('a folder rule merges a worktree and its subfolders', () {
      store.assignFolderToProject(
        folder: r'F:\projects\viewer-wt\',
        projectName: 'viewer',
        projectionVersion: 1,
      );

      expect(_sessionProject(db, 'wt-root'), 'viewer');
      expect(_sessionProject(db, 'wt-sub'), 'viewer');
      expect(_sessionProject(db, 'wt-sibling'), 'viewer-wt');
      final assignment = store.loadSessionProjectAssignment('wt-sub');
      expect(assignment.folderRule?.folder, r'F:\projects\viewer-wt');
      expect(assignment.folderRule?.projectName, 'viewer');
      expect(assignment.isManual, isFalse);
      expect(assignment.detectedProjectName, 'viewer-wt');
    });

    test('a new folder rule replaces the old rule for that folder', () {
      store.assignFolderToProject(
        folder: r'F:\projects\viewer-wt',
        projectName: 'viewer',
        projectionVersion: 1,
      );
      store.assignFolderToProject(
        folder: 'f:/projects/viewer-wt',
        projectName: 'Other',
        projectionVersion: 1,
      );

      expect(_sessionProject(db, 'wt-sub'), 'Other');
      expect(
        db.select('select count(*) as n from project_path_masks').single['n'],
        2,
      );
    });

    test('removing the folder rule restores detected projects', () {
      store.assignFolderToProject(
        folder: r'F:\projects\viewer-wt',
        projectName: 'viewer',
        projectionVersion: 1,
      );
      store.removeFolderRule(
        folder: r'F:\projects\viewer-wt',
        projectionVersion: 1,
      );

      expect(_sessionProject(db, 'wt-root'), 'viewer-wt');
      expect(_sessionProject(db, 'wt-sub'), 'viewer-wt');
      expect(store.loadSessionProjectAssignment('wt-root').folderRule, isNull);
    });

    test('one session can move to a new project and back', () {
      store.assignSessionProject('wt-root', '  Side quest ');

      expect(_sessionProject(db, 'wt-root'), 'Side quest');
      expect(_sessionProject(db, 'wt-sub'), 'viewer-wt');
      final assignment = store.loadSessionProjectAssignment('wt-root');
      expect(assignment.isManual, isTrue);
      expect(assignment.projectNames, ['Side quest', 'viewer', 'viewer-wt']);

      store.resetSessionProject('wt-root');

      expect(_sessionProject(db, 'wt-root'), 'viewer-wt');
      expect(store.loadSessionProjectAssignment('wt-root').isManual, isFalse);
    });

    test('a folder rule from a manual session makes it follow the rule', () {
      store.assignSessionProject('wt-root', 'Side quest');
      store.assignFolderToProject(
        folder: r'F:\projects\viewer-wt',
        projectName: 'viewer',
        sessionId: 'wt-root',
        projectionVersion: 1,
      );

      expect(_sessionProject(db, 'wt-root'), 'viewer');
      expect(store.loadSessionProjectAssignment('wt-root').isManual, isFalse);
    });

    test('the more specific folder rule wins over an older broad one', () {
      store.assignFolderToProject(
        folder: r'F:\projects',
        projectName: 'Everything',
        projectionVersion: 1,
      );
      store.assignFolderToProject(
        folder: r'F:\projects\viewer-wt',
        projectName: 'viewer',
        projectionVersion: 1,
      );

      expect(_sessionProject(db, 'wt-sub'), 'viewer');
      expect(_sessionProject(db, 'main'), 'Everything');
      final everything = store.listProjects().firstWhere(
        (project) => project.name == 'Everything',
      );
      final rule = store.loadProjectDetail(everything.id).rules.single;
      expect(rule.folder, r'F:\projects');
      expect(rule.sessionCount, 2);
      expect(rule.overriddenBy, {
        const ProjectFolderRule(
          folder: r'F:\projects\viewer-wt',
          projectName: 'viewer',
        ): 2,
      });
    });

    test('lists projects with sessions or rules and their counts', () {
      db.execute(
        "update sessions set last_message_at_utc = '2026-09-20T10:00:00Z' "
        "where id = 'wt-sub'",
      );
      store.upsertProject(name: 'Empty');
      store.assignSessionProject('wt-root', 'viewer');
      store.assignFolderToProject(
        folder: r'D:\elsewhere',
        projectName: 'Rules only',
        projectionVersion: 1,
      );

      final projects = {
        for (final project in store.listProjects()) project.name: project,
      };

      expect(
        projects.keys,
        unorderedEquals(['viewer', 'viewer-wt', 'Rules only']),
      );
      expect(projects['viewer']!.sessionCount, 2);
      expect(projects['viewer']!.manualSessionCount, 1);
      expect(projects['viewer-wt']!.sessionCount, 2);
      expect(
        projects['viewer-wt']!.lastActivityUtc,
        DateTime.utc(2026, 9, 20, 10),
      );
      expect(projects['Rules only']!.folderRuleCount, 1);
      expect(projects['Rules only']!.sessionCount, 0);
    });

    test('project detail lists the folders it was detected from', () {
      final worktree = store.listProjects().firstWhere(
        (project) => project.name == 'viewer-wt',
      );

      final detail = store.loadProjectDetail(worktree.id);

      expect(detail.rules, isEmpty);
      expect(detail.detectedFolders, [
        (folder: r'F:\projects\viewer-wt', sessionCount: 2),
        (folder: r'F:\projects\viewer-wt2', sessionCount: 1),
      ]);
    });

    test('merging a project moves its folders and manual sessions', () {
      final worktree = store.listProjects().firstWhere(
        (project) => project.name == 'viewer-wt',
      );
      store.assignSessionProject('main', 'viewer-wt');
      final before = store.snapshotProjectRules();

      store.mergeProject(
        sourceProjectId: worktree.id,
        targetName: 'viewer',
        projectionVersion: 1,
      );

      for (final id in ['main', 'wt-root', 'wt-sub', 'wt-sibling']) {
        expect(_sessionProject(db, id), 'viewer', reason: id);
      }
      expect(store.listProjects().map((project) => project.name), ['viewer']);
      final viewer = store.listProjects().single;
      expect(
        store.loadProjectDetail(viewer.id).rules.map((rule) => rule.folder),
        [r'F:\projects\viewer-wt', r'F:\projects\viewer-wt2'],
      );

      store.restoreProjectRules(before, projectionVersion: 1);

      expect(_sessionProject(db, 'main'), 'viewer-wt');
      expect(_sessionProject(db, 'wt-sub'), 'viewer-wt');
      expect(
        db.select('select count(*) as n from project_path_masks').single['n'],
        0,
      );
    });

    test('merging into the same project is refused', () {
      final viewer = store.listProjects().firstWhere(
        (project) => project.name == 'viewer',
      );
      expect(
        () => store.mergeProject(
          sourceProjectId: viewer.id,
          targetName: 'viewer',
          projectionVersion: 1,
        ),
        throwsArgumentError,
      );
    });

    test('changing and resetting keep sessions consistent', () {
      store.assignFolderToProject(
        folder: r'F:\projects\viewer-wt',
        projectName: 'viewer',
        projectionVersion: 1,
      );
      store.changeFolderRule(
        oldFolder: r'F:\projects\viewer-wt',
        newFolder: r'F:\projects\viewer-wt2',
        projectName: 'viewer',
        projectionVersion: 1,
      );
      expect(_sessionProject(db, 'wt-sub'), 'viewer-wt');
      expect(_sessionProject(db, 'wt-sibling'), 'viewer');

      store.assignSessionProject('wt-root', 'viewer');
      store.assignSessionProject('wt-sub', 'viewer');
      final viewer = store.listProjects().firstWhere(
        (project) => project.name == 'viewer',
      );
      store.resetManualSessions(projectId: viewer.id);

      expect(_sessionProject(db, 'wt-root'), 'viewer-wt');
      expect(_sessionProject(db, 'wt-sub'), 'viewer-wt');
      expect(store.loadProjectDetail(viewer.id).manualSessionCount, 0);
    });

    test('project roots come from the segment named like the project', () {
      expect(
        projectRootFolder(r'F:\projects\viewer-wt\app\src', 'viewer-wt'),
        r'F:\projects\viewer-wt',
      );
      expect(
        projectRootFolder('/home/me/Viewer/app', 'viewer'),
        '/home/me/Viewer',
      );
      expect(projectRootFolder(r'F:\other\', 'viewer'), r'F:\other');
    });

    test('rule folders drop the trailing wildcard and separator', () {
      expect(projectRuleFolder(r'F:\work\wt\*'), r'F:\work\wt');
      expect(projectRuleFolder('/home/me/wt/*'), '/home/me/wt');
      expect(projectRuleFolder('/home/me/wt'), '/home/me/wt');
      expect(projectRuleFolder(r'C:\*'), r'C:\');
    });
  });
}

String? _sessionProject(Database db, String sessionId) {
  final row = db.select(
    'select project_name_snapshot from sessions where id = ?',
    [sessionId],
  ).single;
  return row['project_name_snapshot'] as String?;
}

SessionSearchDocument _document({
  required String id,
  String title = '',
  String displayPath = '',
  String normalizedPathKeys = '',
}) => SessionSearchDocument(
  id: id,
  sourceType: SessionSearchSourceType.windows,
  sourceFilePath: displayPath.isEmpty ? '$id.jsonl' : displayPath,
  displayPath: displayPath.isEmpty ? '$id.jsonl' : displayPath,
  platformPath: displayPath.isEmpty ? '$id.jsonl' : displayPath,
  title: title,
  normalizedPathKeys: normalizedPathKeys,
);
