import 'dart:io';

import 'package:codex_sessions_viewer/src/database/project_tag_state.dart';
import 'package:codex_sessions_viewer/src/search/session_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Database db;
  late SessionSearchIndex index;
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
    index = SessionSearchIndex(db);
    store = ProjectTagStateStore(db);
  });

  tearDown(() {
    db.close();
  });

  test('project filters use recalculated project snapshots', () {
    index.upsert(
      _document(
        id: 'viewer',
        path: r'F:\projects\MaxLogic\codex-sessions-viewer\a.jsonl',
        pathKey: 'f:/projects/maxlogic/codex-sessions-viewer/a.jsonl',
      ),
    );
    index.upsert(
      _document(
        id: 'other',
        path: r'F:\projects\MaxLogic\other\b.jsonl',
        pathKey: 'f:/projects/maxlogic/other/b.jsonl',
      ),
    );

    final projectId = store.upsertProject(name: 'Viewer');
    store.upsertProjectMask(
      projectId: projectId,
      pathMask: 'f:/projects/maxlogic/codex-sessions-viewer/*',
    );
    store.recalculateSessionProjects();

    expect(
      index.search(
        const SessionSearchQuery(
          projectNames: {'Viewer'},
          archived: ArchivedFilter.all,
        ),
      ),
      ['viewer'],
    );
  });
}

SessionSearchDocument _document({
  required String id,
  required String path,
  required String pathKey,
}) => SessionSearchDocument(
  id: id,
  sourceType: SessionSearchSourceType.windows,
  sourceFilePath: path,
  displayPath: path,
  platformPath: path,
  normalizedPathKeys: pathKey,
);
