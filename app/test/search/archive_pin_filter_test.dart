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
    index = SessionSearchIndex(db);
    store = ProjectTagStateStore(db);
  });

  tearDown(() {
    db.close();
  });

  test('pin and archive filters reflect persisted session state', () {
    index.upsert(_document(id: 'active', title: 'Filter target'));
    index.upsert(_document(id: 'archived', title: 'Filter target'));
    index.upsert(_document(id: 'pinned', title: 'Filter target'));

    store.setArchived('archived', true, reason: 'complete');
    store.setPinned('pinned', true);

    expect(
      index.search(const SessionSearchQuery(text: 'target')),
      unorderedEquals(['active', 'pinned']),
    );
    expect(
      index.search(
        const SessionSearchQuery(
          text: 'target',
          archived: ArchivedFilter.archivedOnly,
        ),
      ),
      ['archived'],
    );
    expect(
      index.search(
        const SessionSearchQuery(
          text: 'target',
          pinned: true,
          archived: ArchivedFilter.all,
        ),
      ),
      ['pinned'],
    );
  });
}

SessionSearchDocument _document({required String id, required String title}) =>
    SessionSearchDocument(
      id: id,
      sourceType: SessionSearchSourceType.windows,
      sourceFilePath: '$id.jsonl',
      displayPath: '$id.jsonl',
      platformPath: '$id.jsonl',
      title: title,
    );
