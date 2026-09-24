import 'dart:io';

import 'package:codex_sessions_viewer/src/app/runtime_session_controller.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:codex_sessions_viewer/src/search/session_search.dart';
import 'package:codex_sessions_viewer/src/ui/models/session_project_change.dart';
import '../support/session_search_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// A migrated database with a main checkout and a side worktree session.
Future<({Database db, RuntimeSessionController controller})> _fixture() async {
  final temp = await Directory.systemTemp.createTemp('csv_move_project_');
  final databaseFile = File(p.join(temp.path, 'viewer.sqlite'));
  final settingsFile = File(p.join(temp.path, 'settings.toml'));
  await SettingsRepository(settingsFile).save(AppSettings.defaults());
  expect(
    (await DatabaseMigrator(
      sqlRoot: Directory('../sql'),
    ).openAndMigrate(databaseFile)).canStartNormalUi,
    isTrue,
  );
  final db = openFileBackedDatabase(databaseFile);
  final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
  addTearDown(() async {
    await coordinator.idle;
    db.close();
    await temp.delete(recursive: true);
  });
  final store = ProjectTagStateStore(db);
  for (final (id, folder, project) in [
    ('main', r'F:\projects\viewer', 'viewer'),
    ('worktree', r'F:\projects\viewer-wt\app', 'viewer-wt'),
  ]) {
    SessionSearchIndex(db).upsert(
      SessionSearchDocument(
        id: id,
        sourceType: SessionSearchSourceType.windows,
        sourceFilePath: '$id.jsonl',
        displayPath: '$id.jsonl',
        platformPath: '$id.jsonl',
      ),
    );
    final detected = store.upsertProject(name: project);
    db.execute(
      'update sessions set working_directory_display = ?, '
      'detected_project_id = ? where id = ?',
      [folder, detected, id],
    );
    store.refreshSessionProject(id);
  }
  return (
    db: db,
    controller: RuntimeSessionController(
      settingsFile: settingsFile,
      databaseFile: databaseFile,
      writerCoordinator: coordinator,
    ),
  );
}

String? _project(Database db, String id) =>
    db.select('select project_name_snapshot from sessions where id = ?', [
          id,
        ]).single['project_name_snapshot']
        as String?;

void main() {
  test('a worktree folder merges into its main project', () async {
    final (:db, :controller) = await _fixture();

    await controller.changeSessionProject(
      'worktree',
      const MoveFolderToProject(
        folder: r'F:\projects\viewer-wt',
        projectName: 'viewer',
      ),
    );

    expect(_project(db, 'worktree'), 'viewer');
    expect(
      SessionSearchIndex(db).search(
        const SessionSearchQuery(
          projectNames: {'viewer'},
          archived: ArchivedFilter.all,
        ),
      ),
      unorderedEquals(['main', 'worktree']),
    );
    final assignment = await controller.loadSessionProjectAssignment(
      'worktree',
    );
    expect(assignment.folderRule?.folder, r'F:\projects\viewer-wt');

    await controller.changeSessionProject(
      'worktree',
      const RemoveFolderRule(r'F:\projects\viewer-wt'),
    );
    expect(_project(db, 'worktree'), 'viewer-wt');
  });

  test('the Projects screen data merges a project and undoes it', () async {
    final (:db, :controller) = await _fixture();

    final projects = await controller.loadProjects();
    expect(
      projects.map((project) => project.name),
      unorderedEquals(['viewer', 'viewer-wt']),
    );
    final worktree = projects.firstWhere((p) => p.name == 'viewer-wt');
    final detail = await controller.loadProjectDetail(worktree.id);
    expect(detail.detectedFolders, [
      (folder: r'F:\projects\viewer-wt', sessionCount: 1),
    ]);

    final before = await controller.mergeProject(
      sourceProjectId: worktree.id,
      targetName: 'viewer',
    );

    expect(_project(db, 'worktree'), 'viewer');
    final merged = await controller.loadProjects();
    expect(merged.map((project) => project.name), ['viewer']);
    expect(merged.single.folderRuleCount, 1);

    await controller.restore(before);

    expect(_project(db, 'worktree'), 'viewer-wt');
    expect(await controller.loadProjects(), hasLength(2));
  });
}
