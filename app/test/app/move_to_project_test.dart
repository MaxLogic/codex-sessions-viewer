import 'dart:io';

import 'package:codex_sessions_viewer/src/app/runtime_session_controller.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:codex_sessions_viewer/src/search/session_search.dart';
import 'package:codex_sessions_viewer/src/ui/models/session_project_change.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test(
    'a worktree merges into its main project on a migrated database',
    () async {
      final temp = await Directory.systemTemp.createTemp('csv_move_project_');
      addTearDown(() => temp.delete(recursive: true));
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
      addTearDown(db.close);
      final store = ProjectTagStateStore(db);
      for (final (id, folder) in [
        ('main', r'F:\projects\viewer'),
        ('worktree', r'F:\projects\viewer-wt\app'),
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
        final detected = store.upsertProject(name: p.windows.basename(folder));
        db.execute(
          'update sessions set working_directory_display = ?, '
          'detected_project_id = ? where id = ?',
          [folder, detected, id],
        );
        store.refreshSessionProject(id);
      }
      final coordinator = DatabaseMaintenanceCoordinator(databaseFile);
      final controller = RuntimeSessionController(
        settingsFile: settingsFile,
        databaseFile: databaseFile,
        writerCoordinator: coordinator,
      );

      await controller.changeSessionProject(
        'worktree',
        const MoveFolderToProject(
          folder: r'F:\projects\viewer-wt',
          projectName: 'viewer',
        ),
      );

      String? project(String id) =>
          db.select('select project_name_snapshot from sessions where id = ?', [
                id,
              ]).single['project_name_snapshot']
              as String?;
      expect(project('worktree'), 'viewer');
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
      expect(project('worktree'), 'app');
      await coordinator.idle;
    },
  );
}
