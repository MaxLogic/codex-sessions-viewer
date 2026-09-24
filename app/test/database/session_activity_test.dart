import 'dart:io';

import 'package:codex_sessions_viewer/src/database/session_list_query.dart';
import 'package:codex_sessions_viewer/src/search/session_search.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  test('retained filter indexes preserve actual ordered session search', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final scripts =
        [
          ...Directory('../sql/init').listSync().whereType<File>(),
          ...Directory('../sql/migration').listSync().whereType<File>(),
        ].where((file) => file.path.endsWith('.sql')).toList()..sort(
          (a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
        );
    for (final script in scripts) {
      db.execute(script.readAsStringSync());
    }
    db.execute('''
      with recursive n(i) as (select 1 union all select i+1 from n where i<10000)
      insert into sessions(id,session_id,source_type,source_file_path,display_path,
        platform_path,parse_status,scan_status,started_at_utc,created_at_utc,
        updated_at_utc,title,is_archived,eval_ready,eval_status)
      select printf('s%06d',i),printf('s%06d',i),
        case when i%100=0 then 'wsl' else 'windows' end,
        'synthetic/'||i,'synthetic','synthetic',
        case when i%100=0 then 'parse_error' else 'available' end,
        case when i%100=1 then 'missing' else 'available' end,
        printf('2026-09-%02dT00:00:00Z',i%7+1),'2026-09-01','2026-09-01',
        'Synthetic session',i%100=0,i%100=0,
        case when i%100=0 then 'correct' else 'needs_review' end from n;
      insert into session_search(rowid,title,summary,tool_names,display_path,
        normalized_path_keys,project_name,tags)
      select rowid,title,'','','synthetic','synthetic','','' from sessions;
      analyze;
    ''');
    final observed = _SearchSqlCapture(db);
    final search = SessionSearchIndex(observed);
    const scenarios = <String, List<SessionSearchQuery>>{
      'idx_sessions_source_type': [
        SessionSearchQuery(
          sourceTypes: {SessionSearchSourceType.wsl},
          archived: ArchivedFilter.all,
        ),
        SessionSearchQuery(
          sourceTypes: {SessionSearchSourceType.windows},
          archived: ArchivedFilter.all,
        ),
      ],
      'idx_sessions_parse_status': [
        SessionSearchQuery(
          statuses: {'parse_error'},
          archived: ArchivedFilter.all,
        ),
        SessionSearchQuery(
          statuses: {'available'},
          archived: ArchivedFilter.all,
        ),
      ],
      'idx_sessions_scan_status': [
        SessionSearchQuery(statuses: {'missing'}, archived: ArchivedFilter.all),
        SessionSearchQuery(
          statuses: {'available'},
          archived: ArchivedFilter.all,
        ),
      ],
      'idx_sessions_archived': [
        SessionSearchQuery(archived: ArchivedFilter.archivedOnly),
        SessionSearchQuery(archived: ArchivedFilter.activeOnly),
      ],
      'idx_sessions_eval_ready': [
        SessionSearchQuery(evalReady: true, archived: ArchivedFilter.all),
        SessionSearchQuery(evalReady: false, archived: ArchivedFilter.all),
      ],
      'idx_sessions_eval_status': [
        SessionSearchQuery(
          evalStatuses: {'correct'},
          archived: ArchivedFilter.all,
        ),
        SessionSearchQuery(
          evalStatuses: {'needs_review'},
          archived: ArchivedFilter.all,
        ),
      ],
    };
    for (final entry in scenarios.entries) {
      final name = entry.key;
      final ddl =
          db.select('select sql from sqlite_schema where name=?', [
                name,
              ]).single['sql']
              as String;
      final bytes = db
          .select('select sum(pgsize) from dbstat where name=?', [name])
          .single
          .values
          .single;
      final expected = [for (final query in entry.value) search.search(query)];
      expect(expected.first, hasLength(100));
      final measurements = <Object?>[];
      for (final present in [true, false]) {
        if (!present) {
          db.execute('drop index $name');
          db.execute('analyze');
        }
        for (var scenario = 0; scenario < entry.value.length; scenario++) {
          final query = entry.value[scenario];
          expect(search.search(query), expected[scenario]); // excluded warm-up
          final sql = observed.sql!;
          final parameters = observed.parameters;
          expect(sql, contains('join session_search f on f.rowid = s.rowid'));
          expect(sql, contains('order by s.activity_at_utc desc'));
          final plan = db
              .select('explain query plan $sql', parameters)
              .map((row) => row['detail'])
              .toList();
          final samples = <int>[];
          for (var sample = 0; sample < 3; sample++) {
            final watch = Stopwatch()..start();
            final actual = search.search(query);
            watch.stop();
            samples.add(watch.elapsedMicroseconds);
            expect(actual, expected[scenario]);
          }
          measurements.add({
            'present': present,
            'selectivity': scenario == 0 ? 'rare' : 'common',
            'rows': expected[scenario].length,
            'us': samples,
            'plan': plan,
            'parameters': parameters,
          });
        }
      }
      db.execute(ddl);
      db.execute('analyze');
      // ignore: avoid_print
      print(
        'Actual SessionSearchIndex.search A/B: $name bytes=$bytes; '
        '10000 synthetic rows,1% rare per field,full FTS join+activity order; '
        'Flutter-test JIT;1warmup+3samples; timings supporting only; '
        'no VM-step API available in installed Dart sqlite3. $measurements',
      );
    }
  });

  test('stored activity preserves order and ignores metadata-only edits', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    final scripts =
        [
          ...Directory('../sql/init').listSync().whereType<File>(),
          ...Directory('../sql/migration').listSync().whereType<File>(),
        ].where((file) => file.path.endsWith('.sql')).toList()..sort(
          (a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
        );
    for (final file in scripts) {
      // This isolated ordering fixture omits the usage-generation schema.
      // Later migrations install triggers that require those usage tables;
      // 024 extends the price tables that 023 creates.
      if (file.uri.pathSegments.last.startsWith('016_') ||
          file.uri.pathSegments.last.startsWith('021_') ||
          file.uri.pathSegments.last.startsWith('023_') ||
          file.uri.pathSegments.last.startsWith('024_') ||
          file.uri.pathSegments.last.startsWith('025_')) {
        continue;
      }
      db.execute(file.readAsStringSync());
    }
    db.execute('''
      with recursive n(i) as (select 1 union all select i+1 from n where i<10000)
      insert into sessions(id,session_id,source_type,source_file_path,display_path,
        platform_path,parse_status,scan_status,started_at_utc,last_message_at_utc,
        created_at_utc,updated_at_utc)
      select printf('s%06d',i),printf('s%06d',i),'windows',printf('fixture/%d',i),
        'fixture','fixture','available','available',
        case when i%3<>0 then printf('2026-08-%02dT12:00:00Z',i%28+1) end,
        case when i%3=1 then printf('2026-09-%02dT12:00:00Z',i%6+1) end,
        '2026-08-01T00:00:00Z','2026-08-01T00:00:00Z' from n;
    ''');
    final query = sessionListQuery(limit: 512);
    final legacySql = query.sql
        .replaceAll(' indexed by idx_sessions_available_activity', '')
        .replaceAll(
          's.activity_at_utc',
          'coalesce(s.last_message_at_utc, s.started_at_utc, s.updated_at_utc)',
        );
    final beforePlan = db
        .select('explain query plan $legacySql', query.parameters)
        .map((row) => row['detail'])
        .toList();
    final before = db
        .select(legacySql, query.parameters)
        .map((row) => row['id'])
        .toList();
    final samples = <int>[];
    for (var sample = 0; sample < 7; sample++) {
      final watch = Stopwatch()..start();
      final rows = db.select(legacySql, query.parameters);
      watch.stop();
      samples.add(watch.elapsedMicroseconds);
      expect(rows.length, 512);
    }
    // Retain the measured old ordering as the reference, not another new query.
    // ignore: avoid_print
    print(
      'Session ordering baseline: rows=10000 limit=512 us=$samples plan=$beforePlan',
    );
    final migrationWatch = Stopwatch()..start();
    db.execute(
      scripts
          .singleWhere((file) => file.uri.pathSegments.last.startsWith('016_'))
          .readAsStringSync(),
    );
    migrationWatch.stop();
    expect(
      db.select('pragma table_info(sessions)').map((row) => row['name']),
      contains('activity_at_utc'),
    );
    expect(
      db.select(
        'select 1 from sessions where activity_at_utc is not coalesce(last_message_at_utc,started_at_utc,updated_at_utc) limit 1',
      ),
      isEmpty,
    );
    expect(
      db.select(query.sql, query.parameters).map((row) => row['id']).toList(),
      before,
    );

    final original = db
        .select("select activity_at_utc from sessions where id='s000003'")
        .single['activity_at_utc'];
    db.execute(
      "update sessions set is_pinned=1,updated_at_utc='2099-01-01T00:00:00Z' where id='s000003'",
    );
    expect(
      db
          .select("select activity_at_utc from sessions where id='s000003'")
          .single['activity_at_utc'],
      original,
    );
    expect(
      db.select(query.sql, query.parameters).map((row) => row['id']).toList(),
      before,
      reason: 'metadata edits must not change visible session ordering',
    );
    db.execute('analyze');
    final plan = db
        .select('explain query plan ${query.sql}', query.parameters)
        .map((row) => row['detail'] as String)
        .toList();
    expect(plan.join(' '), contains('idx_sessions_available_activity'));
    expect(plan.join(' '), isNot(contains('TEMP B-TREE')));
    final indexedSamples = <int>[];
    for (var sample = 0; sample < 7; sample++) {
      final watch = Stopwatch()..start();
      final rows = db.select(query.sql, query.parameters);
      watch.stop();
      indexedSamples.add(watch.elapsedMicroseconds);
      expect(rows.map((row) => row['id']).toList(), before);
    }
    final indexBytes = db
        .select(
          "select sum(pgsize) n from dbstat where name='idx_sessions_available_activity'",
        )
        .single['n'];
    // ignore: avoid_print
    print(
      'Session ordering indexed: rows=10000 limit=512 us=$indexedSamples index_bytes=$indexBytes migration_us=${migrationWatch.elapsedMicroseconds} plan=$plan',
    );

    // STAT1 averages two status values even when almost every row is available.
    // This mirrors the real database distribution missed by the uniform case.
    db.execute('''
      update sessions set scan_status='changed_pending_parse'
        where id in ('s000001','s000002');
      update sessions set session_id=null where id='s000004';
      update sessions set session_id='' where id='s000005';
      analyze;
    ''');
    for (final shape in [
      (limit: 512, offset: 0),
      (limit: 512, offset: 5000),
      (limit: null, offset: 0),
    ]) {
      final list = sessionListQuery(limit: shape.limit, offset: shape.offset);
      final unhinted = list.sql.replaceAll(
        ' indexed by idx_sessions_available_activity',
        '',
      );
      final expectedIds = db
          .select(unhinted, list.parameters)
          .map((row) => row['id'])
          .toList();
      final actualIds = db
          .select(list.sql, list.parameters)
          .map((row) => row['id'])
          .toList();
      expect(actualIds, expectedIds);
      expect(
        actualIds,
        isNot(anyElement(isIn(['s000001', 's000002', 's000004', 's000005']))),
      );
      expect(actualIds.length, shape.limit ?? 9996);
      final skewedPlan = db
          .select('explain query plan ${list.sql}', list.parameters)
          .map((row) => row['detail'])
          .join(' ');
      expect(skewedPlan, contains('idx_sessions_available_activity'));
      expect(skewedPlan, isNot(contains('TEMP B-TREE')));
    }
    final detail = sessionListQuery(sessionId: 's000003');
    final detailPlan = db
        .select('explain query plan ${detail.sql}', detail.parameters)
        .map((row) => row['detail'])
        .join(' ');
    expect(detailPlan, contains('sqlite_autoindex_sessions_1 (id=?)'));
    expect(db.select(detail.sql, detail.parameters).single['id'], 's000003');
    db.execute(
      "update sessions set parse_status='parse_error' where id='s000003'",
    );
    expect(db.select(detail.sql, detail.parameters), isEmpty);
    db.execute(
      "update sessions set parse_status='available' where id='s000003'",
    );
    db.execute(
      "update sessions set last_message_at_utc='2026-09-07T00:00:00Z',updated_at_utc='2026-09-08T00:00:00Z' where id='s000003'",
    );
    expect(
      db
          .select("select activity_at_utc from sessions where id='s000003'")
          .single['activity_at_utc'],
      '2026-09-07T00:00:00Z',
    );
    db.execute(
      "update sessions set last_message_at_utc=null,started_at_utc=null,updated_at_utc='2026-09-08T00:00:00Z' where id='s000003'",
    );
    expect(
      db
          .select("select activity_at_utc from sessions where id='s000003'")
          .single['activity_at_utc'],
      '2026-09-08T00:00:00Z',
    );
  });
}

// Captures the real search boundary, rather than reconstructing its predicates.
// Other APIs fail closed so changed search behavior cannot escape observation.
class _SearchSqlCapture implements Database {
  _SearchSqlCapture(this.inner);
  final Database inner;
  String? sql;
  List<Object?> parameters = const [];
  @override
  ResultSet select(String statement, [List<Object?> arguments = const []]) {
    if (statement.contains('join session_search f on f.rowid = s.rowid')) {
      sql = statement;
      parameters = List<Object?>.of(arguments);
    }
    return inner.select(statement, arguments);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected search database API: ${invocation.memberName}',
  );
}
