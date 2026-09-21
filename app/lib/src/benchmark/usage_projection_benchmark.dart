import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import '../database/database_connection.dart';
import '../database/database_generation.dart';
import '../database/project_tag_state.dart';
import '../database/session_list_query.dart';
import '../usage/usage_summary.dart';

Future<int> runUsageProjectionBenchmarkCli(
  List<String> arguments, {
  required StringSink output,
  required StringSink errors,
}) async {
  try {
    final options = _Options(arguments);
    if (options.help) {
      output.writeln(
        'Run from app/: dart run bin/usage_projection_benchmark.dart '
        '[--events 4000000] [--contexts 256] [--samples 7] '
        '[--expected-hash SHA256]\n'
        'Uses only deterministic synthetic temporary databases. '
        'Scales: 100000, 1000000, requested events (capped and deduplicated).',
      );
      return 0;
    }
    if (!Platform.isWindows) {
      throw StateError('This benchmark requires Windows-native SQLite.');
    }
    final scales = <Map<String, Object?>>[];
    for (final count in {
      if (options.events > 100000) 100000,
      if (options.events > 1000000) 1000000,
      options.events,
    }) {
      errors.writeln(
        'Synthetic scale: $count events, ${options.contexts} contexts.',
      );
      scales.add(_runScale(count, options));
    }
    if (options.expectedHash != null &&
        scales.last['projectedHash'] != options.expectedHash) {
      throw StateError('Expected output hash mismatch.');
    }
    output.writeln(
      jsonEncode({
        'fixture':
            'deterministic synthetic v1; one session per context; 60 UTC days; '
            '3 models; local/inherited/ambiguous events; no prices',
        'platform': Platform.operatingSystemVersion,
        'dart': Platform.version,
        'execution':
            'Required dart run command uses JIT; not a release-app benchmark.',
        'warmups': 1,
        'percentile': 'nearest-rank p95; median averages middle pair',
        'peakRssBytes': ProcessInfo.maxRss,
        'memoryScope':
            'OS whole-process lifetime high-water RSS, including setup and all scales; not operation-isolated',
        'statementScope':
            'Observed host SQL API executions, including prepared executions; excludes implicit trigger/VM steps. Instrumentation adds overhead.',
        'hashScope':
            'Economic amounts/unknown flags, token/message/session totals, breakdowns, tops, coverage and project/branch accounting. Excludes intentionally changed pricing provenance/updating UI metadata; no historical-money certification.',
        'baselineScope':
            'Retained production legacy branch in current source and additive schema, not an old executable.',
        'sourceHashes': _sourceHashes(),
        'scales': scales,
      }),
    );
    return 0;
  } on FormatException catch (error) {
    errors.writeln('Invalid arguments: ${error.message}');
    return 64;
  } on Object catch (error) {
    errors.writeln('Benchmark failed: $error');
    return 1;
  }
}

class _Options {
  _Options(List<String> arguments) {
    for (var i = 0; i < arguments.length; i++) {
      final key = arguments[i];
      if (key == '--help') {
        help = true;
        continue;
      }
      if (!{
            '--events',
            '--contexts',
            '--samples',
            '--expected-hash',
          }.contains(key) ||
          ++i == arguments.length) {
        throw FormatException('Unknown or incomplete option $key.');
      }
      final value = arguments[i];
      if (key == '--expected-hash') {
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
          throw const FormatException(
            'Expected hash must be lowercase SHA256.',
          );
        }
        expectedHash = value;
        continue;
      }
      final number = int.tryParse(value);
      if (number == null || number <= 0) {
        throw FormatException('$key requires a positive integer.');
      }
      switch (key) {
        case '--events':
          events = number;
        case '--contexts':
          contexts = number;
        case '--samples':
          samples = number;
      }
    }
    if (contexts > events || contexts > 100000 || samples > 1000) {
      throw const FormatException(
        'Contexts must not exceed events or 100000; samples must not exceed 1000.',
      );
    }
  }
  int events = 4000000;
  int contexts = 256;
  int samples = 7;
  bool help = false;
  String? expectedHash;
}

Map<String, Object?> _runScale(int count, _Options options) {
  final directory = Directory.systemTemp.createTempSync(
    'usage-projection-benchmark-',
  );
  final file = File('${directory.path}/synthetic.db');
  final db = openFileBackedDatabase(file);
  try {
    _seed(db, count, options.contexts);
    final observer = _ObservedDatabase(db);
    final repository = UsageSummaryRepository(observer);
    final projects = ProjectTagStateStore(observer);
    final request = UsageSummaryRequest(
      period: UsagePeriod.last30Days,
      nowUtc: DateTime.utc(2026, 9, 7, 12),
      projectionVersion: 1,
    );
    void remap(int index) => projects.upsertProjectMaskAndRecalculate(
      projectId: 1,
      pathMask: '*benchmark*',
      isActive: index.isEven,
      projectionVersion: 1,
    );
    final legacyRemap = _measure(observer, options.samples, remap);
    remap(0);
    final enabledAccounting = _hash(_accounting(db));
    remap(1);
    final legacySummary = _measure(
      observer,
      options.samples,
      (_) => repository.summarize(request),
    );
    final legacyHash = _hash(_summaryValue(repository.summarize(request)));
    final legacyAccounting = _accounting(db);
    final legacyPlan = [
      ...repository.explainUsageEventAggregation(request),
      ...repository.explainUsageProjectionCoverage(request),
    ];
    final legacyStorage = _storage(db, file);

    _activate(db, options.contexts);
    final projectedSummary = _measure(
      observer,
      options.samples,
      (_) => repository.summarize(request),
    );
    final projectedHash = _hash(_summaryValue(repository.summarize(request)));
    if (legacyHash != projectedHash ||
        _hash(legacyAccounting) != _hash(_accounting(db))) {
      throw StateError(
        'Legacy/projected output hash mismatch at $count events.',
      );
    }
    final contextRemap = _measure(observer, options.samples, remap);
    remap(0);
    if (_hash(_accounting(db)) != enabledAccounting) {
      throw StateError('Enabled project/branch output hash mismatch.');
    }
    remap(1);
    final projectedAccounting = _accounting(db);
    if (_hash(legacyAccounting) != _hash(projectedAccounting)) {
      throw StateError('Project/branch output hash mismatch after remapping.');
    }
    final projectedPlan = [
      ...repository.explainUsageEventAggregation(request),
      ...repository.explainUsageProjectionCoverage(request),
    ];
    final sessionQuery = sessionListQuery(limit: 100);
    final sessionList = _measure(
      observer,
      options.samples,
      (_) => observer.select(sessionQuery.sql, sessionQuery.parameters),
    );
    if (projectedSummary['rawEventSqlExecutions'] != 0 ||
        contextRemap['rawEventSqlExecutions'] != 0 ||
        projectedPlan.any((line) => line.contains('usage_events'))) {
      throw StateError('Projected production path accessed raw usage events.');
    }
    if (db.select('pragma foreign_key_check').isNotEmpty ||
        db.select('pragma quick_check').single.values.single != 'ok') {
      throw StateError('Synthetic database integrity check failed.');
    }
    final actualEvents = db
        .select('select count(*) from usage_events')
        .single
        .values
        .single;
    if (actualEvents != count) {
      throw StateError('Synthetic event count does not match requested count.');
    }
    return {
      'events': actualEvents,
      'sessions': db
          .select('select count(*) from sessions')
          .single
          .values
          .single,
      'usedContexts': db
          .select('select count(distinct path_context_id) from usage_events')
          .single
          .values
          .single,
      'allocatedContexts': db
          .select('select count(*) from usage_path_contexts')
          .single
          .values
          .single,
      'dailyRows': db
          .select('select count(*) from usage_session_daily')
          .single
          .values
          .single,
      'hashesMatch': true,
      'legacyHash': legacyHash,
      'projectedHash': projectedHash,
      'projectBranchHash': _hash(projectedAccounting),
      'enabledProjectBranchHash': enabledAccounting,
      'legacySummary': legacySummary,
      'projectedSummary': projectedSummary,
      'legacyRemap': legacyRemap,
      'contextRemap': contextRemap,
      'legacyPlan': legacyPlan,
      'projectedPlan': projectedPlan,
      'sessionList': sessionList,
      'sessionListPlan': [
        for (final row in db.select(
          'explain query plan ${sessionQuery.sql}',
          sessionQuery.parameters,
        ))
          row['detail'],
      ],
      'legacyStorage': legacyStorage,
      'projectedStorage': {
        'scope':
            'Transitional post-cutover storage before legacy rollback-table cleanup; not final database footprint.',
        ..._storage(db, file),
      },
      'sqliteVersion': db
          .select('select sqlite_version()')
          .single
          .values
          .single,
      'pragmas': {
        for (final name in [
          'journal_mode',
          'synchronous',
          'cache_size',
          'page_size',
        ])
          name: db.select('pragma $name').single.values.single,
      },
    };
  } finally {
    db.close();
    // Only the exact directory created above is removed; no user path accepted.
    directory.deleteSync(recursive: true);
  }
}

void _seed(Database db, int count, int contexts) {
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
  const stamp = '2026-09-07T00:00:00.000Z';
  db.execute(
    "insert into projects (id,name,created_at_utc,updated_at_utc) values (1,'Synthetic project',?,?)",
    [stamp, stamp],
  );
  final projects = ProjectTagStateStore(db);
  db.execute('begin immediate');
  for (var i = 0; i < contexts; i++) {
    final path = i == 0 ? '' : 'C:/benchmark/context$i';
    projects.resolveUsagePathContext(displayPath: path);
    db.execute(
      '''insert into sessions (id,session_id,source_type,source_file_path,display_path,
      platform_path,working_directory_display,started_at_utc,created_at_utc,
      updated_at_utc,parser_version,usage_projection_status,title,message_count,
      model_primary,is_archived)
      values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 'complete', ?, ?, ?, ?)''',
      [
        's$i',
        'logical-$i',
        i.isEven ? 'windows' : 'wsl',
        'synthetic-$i.jsonl',
        path,
        path,
        path,
        stamp,
        stamp,
        stamp,
        'Synthetic $i',
        i + 1,
        'model-${i % 3}',
        i % 2,
      ],
    );
  }
  db.execute('commit');
  for (var start = 0; start < count; start += 10000) {
    final end = start + 10000 < count ? start + 10000 : count;
    db.execute('begin immediate');
    db.execute(
      '''
      with recursive seq(i) as (select ? union all select i+1 from seq where i+1 < ?)
      insert into usage_events (session_row_id,source_record_ordinal,epoch,
        occurred_at_utc,model,working_directory_display,input_tokens,cached_input_tokens,
        cache_write_input_tokens,output_tokens,reasoning_output_tokens,total_tokens,
        branch_scope,derivation,event_fingerprint)
      select 's'||(i%?), i, 0,
        strftime('%Y-%m-%dT12:00:00.000Z','2026-09-07','-'||(i%60)||' days'),
        'model-'||(i%3), case when i%?=0 then '' else 'C:/benchmark/context'||(i%?) end,
        1+i%17, min(i%3,1+i%17), 0, 1+i%7, 0, 2+i%17+i%7,
        case when i%11=0 then 'inherited' when i%13=0 then 'ambiguous' else 'local' end,
        'last_token_usage', printf('%064d',i) from seq
    ''',
      [start, end, contexts, contexts, contexts],
    );
    db.execute('commit');
  }
  db.execute('analyze');
}

void _activate(Database db, int contexts) {
  db.execute(
    '''insert into usage_events_next (session_row_id,source_record_ordinal,
    rollout_ordinal,turn_ordinal,epoch,occurred_at_utc,model,path_context_id,
    input_tokens,cached_input_tokens,cache_write_input_tokens,output_tokens,
    reasoning_output_tokens,total_tokens,branch_scope,derivation,event_fingerprint)
    select e.session_row_id,e.source_record_ordinal,e.rollout_ordinal,e.turn_ordinal,
      e.epoch,e.occurred_at_utc,e.model,c.id,e.input_tokens,e.cached_input_tokens,
      e.cache_write_input_tokens,e.output_tokens,e.reasoning_output_tokens,
      e.total_tokens,e.branch_scope,e.derivation,e.event_fingerprint
    from usage_events e join usage_path_contexts c
      on c.display_path_raw=e.working_directory_display
      and c.platform_path_key='' and c.unc_path_key=''
  ''',
  );
  final generations = DatabaseGenerationRepository(db);
  final generation = generations.createBuilding(
    sourceSchemaVersion: 15,
    targetSchemaVersion: 16,
    sourceFingerprint: 'deterministic synthetic benchmark',
  );
  // Fixture construction only: migration safety has separate acceptance proofs.
  generations.markReady(
    generation.id,
    validationReportJson: '{"synthetic_fixture":true}',
  );
  generations.activate(generation.id);
  for (var i = 0; i < contexts; i++) {
    db.execute('begin immediate');
    UsageSummaryRepository(
      db,
    ).replaceDailyProjectionsInCurrentTransaction(['s$i']);
    db.execute('commit');
  }
  db.execute('analyze');
}

Map<String, Object?> _measure(
  _ObservedDatabase db,
  int samples,
  void Function(int) action,
) {
  action(0); // Warm-up intentionally excluded, including prepared/JIT setup.
  final times = <double>[];
  final counts = <int>[];
  final preparedCounts = <int>[];
  var longestWriter = 0.0;
  var rawEvents = 0;
  final queries = <String>{};
  for (var i = 0; i < samples; i++) {
    db.resetMeasurement();
    final watch = Stopwatch()..start();
    action(i + 1);
    watch.stop();
    times.add(watch.elapsedMicroseconds / 1000);
    counts.add(db.executions);
    preparedCounts.add(db.preparedExecutions);
    rawEvents += db.rawExecutions;
    if (db.longestWriterMs > longestWriter) longestWriter = db.longestWriterMs;
    queries.addAll(db.queries);
  }
  final sorted = [...times]..sort();
  return {
    'samplesMs': times,
    'statementCounts': counts,
    'preparedStatementCounts': preparedCounts,
    'medianMs': samples.isOdd
        ? sorted[samples ~/ 2]
        : (sorted[samples ~/ 2 - 1] + sorted[samples ~/ 2]) / 2,
    'p95Ms': sorted[(samples * 0.95).ceil() - 1],
    'longestWriterTransactionMs': longestWriter,
    'rawEventSqlExecutions': rawEvents,
    'sql': queries.toList(),
  };
}

List<Object?> _accounting(Database db) => [
  for (final row in db.select(
    '''select project_id,branch_scope,count(*),sum(input_tokens+output_tokens)
    from ${DatabaseGenerationRepository(db).activeGeneration().targetSchemaVersion >= 16 ? '(select e.*,c.effective_project_id project_id from usage_events e join usage_path_contexts c on c.id=e.path_context_id)' : 'usage_events'}
    group by project_id,branch_scope order by project_id,branch_scope''',
  ))
    row.values.toList(),
];

Map<String, Object?> _storage(Database db, File file) {
  db.select('pragma wal_checkpoint(truncate)');
  return {
    'databaseBytes': file.lengthSync(),
    'retainsLegacyRollbackTable': db
        .select("select 1 from sqlite_schema where name='usage_events_legacy'")
        .isNotEmpty,
    'objects': [
      for (final row in db.select(
        '''select name,sum(pgsize) bytes,count(*) pages
      from dbstat group by name order by name''',
      ))
        Map<String, Object?>.from(row),
    ],
    'schemaSha256': _hash([
      for (final row in db.select(
        "select type,name,tbl_name,sql from sqlite_schema where sql is not null order by type,name",
      ))
        Map<String, Object?>.from(row),
    ]),
    'indexes': [
      for (final row in db.select(
        "select name,tbl_name,sql from sqlite_schema where type='index' order by name",
      ))
        Map<String, Object?>.from(row),
    ],
  };
}

Object _summaryValue(UsageSummary s) {
  List<Object?> breakdown(List<UsageBreakdownRow> rows) => [
    for (final r in rows)
      [
        r.key,
        r.sessionCount,
        r.messageCount,
        r.inputTokens,
        r.outputTokens,
        r.cachedInputTokens,
        r.totalTokens,
        r.estimatedCostText,
        r.costUnknown,
      ],
  ];
  List<Object?> top(List<UsageTopSession> rows) => [
    for (final r in rows)
      [
        r.sessionId,
        r.title,
        r.messageCount,
        r.totalTokens,
        r.originLabel,
        r.estimatedCostText,
        r.costUnknown,
      ],
  ];
  final c = s.projectionCoverage;
  return [
    s.period.startUtc.toIso8601String(),
    s.period.endExclusiveUtc.toIso8601String(),
    s.totalSessions,
    s.totalMessages,
    s.inputTokens,
    s.outputTokens,
    s.cachedInputTokens,
    s.totalTokens,
    s.estimatedCostText,
    s.costUnknown,
    s.mostUsedModel,
    s.mostActiveProject,
    s.mostActivePlatform,
    [
      c.projectionVersion,
      c.availableSessions,
      c.currentCompleteSessions,
      c.outdatedProjectionSessions,
      c.legacyPendingSessions,
      c.ambiguousSessions,
      c.missingParentSessions,
      c.completeZeroUsageSessions,
    ],
    for (final rows in [
      s.byDay,
      s.byWeek,
      s.byMonth,
      s.byModel,
      s.byProject,
      s.byPlatform,
      s.byOrigin,
      s.byArchiveState,
    ])
      breakdown(rows),
    top(s.topSessionsByTokens),
    top(s.topSessionsByMessageCount),
    top(s.topSessionsByEstimatedCost),
  ];
}

String _hash(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
Map<String, String> _sourceHashes() => {
  for (final name in [
    'lib/src/usage/usage_summary.dart',
    'lib/src/database/project_tag_state.dart',
    'lib/src/database/database_generation.dart',
    'lib/src/benchmark/usage_projection_benchmark.dart',
    'lib/src/database/session_list_query.dart',
  ])
    name: sha256.convert(File(name).readAsBytesSync()).toString(),
};

// Harness-only transparent observation. Unsupported APIs fail rather than being
// silently omitted from measurements; no production database abstraction added.
class _ObservedDatabase implements Database {
  _ObservedDatabase(this.inner);
  final Database inner;
  int executions = 0, rawExecutions = 0, preparedExecutions = 0;
  double longestWriterMs = 0;
  Stopwatch? writer;
  final queries = <String>{};
  void resetMeasurement() {
    executions = 0;
    rawExecutions = 0;
    preparedExecutions = 0;
    longestWriterMs = 0;
    queries.clear();
  }

  void record(String sql, {bool prepared = false}) {
    executions++;
    if (prepared) preparedExecutions++;
    queries.add(sql);
    if (sql.contains('usage_events')) rawExecutions++;
  }

  @override
  bool get autocommit => inner.autocommit;
  @override
  int get lastInsertRowId => inner.lastInsertRowId;
  @override
  int get updatedRows => inner.updatedRows;
  @override
  ResultSet select(String sql, [List<Object?> parameters = const []]) {
    record(sql);
    return inner.select(sql, parameters);
  }

  @override
  void execute(String sql, [List<Object?> parameters = const []]) {
    // Current production calls contain one statement. Fail closed if this changes.
    if (sql.trim().replaceFirst(RegExp(r';$'), '').contains(';')) {
      throw StateError('Observer requires single SQL statements.');
    }
    record(sql);
    final normalized = sql.trim().toLowerCase();
    if (normalized.startsWith('begin')) writer = Stopwatch()..start();
    inner.execute(sql, parameters);
    if (normalized == 'commit' || normalized == 'rollback') {
      final elapsed = (writer?.elapsedMicroseconds ?? 0) / 1000;
      if (elapsed > longestWriterMs) longestWriterMs = elapsed;
      writer = null;
    }
  }

  @override
  PreparedStatement prepare(
    String sql, {
    bool persistent = false,
    bool vtab = true,
    bool checkNoTail = false,
  }) => _ObservedStatement(
    inner.prepare(
      sql,
      persistent: persistent,
      vtab: vtab,
      checkNoTail: checkNoTail,
    ),
    this,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unobserved database API: ${invocation.memberName}',
  );
}

class _ObservedStatement implements PreparedStatement {
  _ObservedStatement(this.inner, this.owner);
  final PreparedStatement inner;
  final _ObservedDatabase owner;
  @override
  String get sql => inner.sql;
  @override
  void execute([List<Object?> parameters = const []]) {
    owner.record(sql, prepared: true);
    inner.execute(parameters);
  }

  @override
  void executeWith(StatementParameters parameters) {
    owner.record(sql, prepared: true);
    inner.executeWith(parameters);
  }

  @override
  ResultSet select([List<Object?> parameters = const []]) {
    owner.record(sql, prepared: true);
    return inner.select(parameters);
  }

  @override
  ResultSet selectWith(StatementParameters parameters) {
    owner.record(sql, prepared: true);
    return inner.selectWith(parameters);
  }

  @override
  IteratingCursor iterateWith(StatementParameters parameters) {
    owner.record(sql, prepared: true);
    return inner.iterateWith(parameters);
  }

  @override
  void close() => inner.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unobserved statement API: ${invocation.memberName}',
  );
}
