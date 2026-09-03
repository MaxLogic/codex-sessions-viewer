import 'dart:async';
import 'dart:io';

import 'package:codex_sessions_viewer/src/pricing/pricing_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../tool/branch_usage_audit.dart';

void main() {
  test('audits branch usage lineage projects and current pricing', () async {
    final db = _openFixtureDatabase();
    addTearDown(db.close);

    final report = await auditBranchUsage(
      db,
      currentProjectionVersion: 3,
      publicModels: _publicModels(),
    );

    expect(report.isValid, isTrue);
    expect(report.coverage.availableSessions, 6);
    expect(report.coverage.currentCompleteSessions, 4);
    expect(report.coverage.ambiguousSessions, 1);
    expect(report.coverage.missingParentSessions, 1);
    expect(report.coverage.completeZeroUsageSessions, 1);
    expect(report.duplicateEventViolations, 0);
    expect(report.tokenInvariantViolations, 0);
    expect(report.unmatchedInheritedEventViolations, 0);
    expect(report.lineage.parentForkPairs, 2);
    expect(report.lineage.forkOfForkChains, 1);
    expect(report.lineage.matchedInheritedEvents, 3);
    expect(report.projectTotals.single.totalTokens, 26);
    expect(report.projectTotals.single.estimatedCostText, '0.00033');
    expect(report.projectTotals.single.costUnknown, isFalse);
    expect(report.pricing, hasLength(3));
    expect(report.pricing.every((row) => row.resolutionMatchesPublic), isTrue);
    expect(report.pricing.every((row) => row.cacheMatchesPublic), isTrue);
    final gpt55 = report.pricing.first;
    expect(gpt55.promptPricePerToken, '0.000005');
    expect(gpt55.completionPricePerToken, '0.00003');
    expect(gpt55.cachedFetchedAtUtc, '2026-07-29T00:00:00.000Z');
  });

  test(
    'rejects stale, inherited-only, duplicate, and invalid projections',
    () async {
      final db = _openFixtureDatabase();
      addTearDown(db.close);
      final projectId =
          db.select('select id from projects').single['id'] as int;
      _insertSession(
        db,
        'inherited-only-row',
        'inherited-only',
        forkedFromId: 'parent',
        projectId: projectId,
      );
      _insertEvent(
        db,
        'inherited-only-row',
        1,
        _fingerprint('a'),
        input: 10,
        output: 5,
        scope: 'inherited',
      );
      _insertSession(db, 'stale-row', 'stale', projectId: projectId);
      db.execute(
        "update sessions set parser_version = 2 where id = 'stale-row'",
      );
      _insertEvent(db, 'parent-row', 2, _fingerprint('a'), input: 1, output: 1);
      db.execute('''
      update usage_events
      set cached_input_tokens = 20, total_tokens = 1
      where session_row_id = 'parent-row' and source_record_ordinal = 1
      ''');
      db.execute(
        "update model_pricing_cache set prompt_price_per_token = '1' "
        "where model_id = 'openai/gpt-5.5'",
      );

      final report = await auditBranchUsage(
        db,
        currentProjectionVersion: 3,
        publicModels: _publicModels(),
      );

      expect(report.isValid, isFalse);
      expect(report.coverage.outdatedProjectionSessions, 1);
      expect(report.coverage.inheritedOnlySessions, 1);
      expect(report.duplicateEventViolations, 1);
      expect(report.tokenInvariantViolations, 1);
      expect(report.pricing.first.cacheMatchesPublic, isFalse);
    },
  );

  test('preflight rejects a database before branch-aware migration', () {
    final db = sqlite3.openInMemory();
    addTearDown(db.close);
    db.execute(File('../sql/init/001_initial_schema.sql').readAsStringSync());

    expect(branchUsageAuditPreconditionError(db), 'schema_upgrade_required');
  });

  test('reports but does not reject excluded legacy pending rows', () async {
    final db = _openFixtureDatabase();
    addTearDown(db.close);
    final projectId = db.select('select id from projects').single['id'] as int;
    _insertSession(db, 'legacy-row', 'legacy', projectId: projectId);
    db.execute('''
      update sessions
      set parser_version = 1, usage_projection_status = 'legacy_pending'
      where id = 'legacy-row'
    ''');

    final report = await auditBranchUsage(
      db,
      currentProjectionVersion: 3,
      publicModels: _publicModels(),
    );

    expect(report.coverage.legacyPendingSessions, 1);
    expect(report.isValid, isTrue);
  });

  test('rejects a copied parent event wrongly marked billable', () async {
    final db = _openFixtureDatabase();
    addTearDown(db.close);
    db.execute(
      "update usage_events set branch_scope = 'local' "
      "where session_row_id = 'child-row' and source_record_ordinal = 1",
    );

    final report = await auditBranchUsage(
      db,
      currentProjectionVersion: 3,
      publicModels: _publicModels(),
    );

    expect(report.isValid, isFalse);
    expect(report.lineage.scopeMismatchViolations, 1);
  });

  test('rejects ambiguous parent candidates for reconciled history', () async {
    final db = _openFixtureDatabase();
    addTearDown(db.close);
    final projectId = db.select('select id from projects').single['id'] as int;
    _insertSession(db, 'parent-copy-row', 'parent', projectId: projectId);

    final report = await auditBranchUsage(
      db,
      currentProjectionVersion: 3,
      publicModels: _publicModels(),
    );

    expect(report.isValid, isFalse);
    expect(report.lineage.ambiguousParentViolations, 1);
  });

  test(
    'accepts truthful unknown costs without a complete fork-of-fork chain',
    () async {
      final db = _openFixtureDatabase();
      addTearDown(db.close);
      db.execute(
        "delete from usage_events where session_row_id = 'grandchild-row'",
      );
      db.execute("delete from sessions where id = 'grandchild-row'");
      _insertEvent(
        db,
        'parent-row',
        3,
        _fingerprint('d'),
        input: 1,
        output: 1,
        model: 'gpt-unpriced-historical',
      );

      final report = await auditBranchUsage(
        db,
        currentProjectionVersion: 3,
        publicModels: _publicModels(),
      );

      expect(report.lineage.parentForkPairs, 1);
      expect(report.lineage.forkOfForkChains, 0);
      expect(report.projectTotals.single.costUnknown, isTrue);
      expect(report.isValid, isTrue);
    },
  );

  test('treats source token subsets as cost uncertainty', () async {
    final db = _openFixtureDatabase();
    addTearDown(db.close);
    db.execute(
      '''
      update usage_events
      set cached_input_tokens = input_tokens + 1,
          reasoning_output_tokens = output_tokens + 1
      where event_fingerprint = ?
    ''',
      [_fingerprint('a')],
    );

    final report = await auditBranchUsage(
      db,
      currentProjectionVersion: 3,
      publicModels: _publicModels(),
    );

    expect(report.tokenInvariantViolations, 0);
    expect(report.projectTotals.single.costUnknown, isTrue);
    expect(report.isValid, isTrue);
  });

  test(
    'rejects a raw cache row that shadows canonical OpenRouter pricing',
    () async {
      final db = _openFixtureDatabase();
      addTearDown(db.close);
      db.execute('''
      insert into model_pricing_cache (
        model_id, provider, prompt_price_per_token,
        completion_price_per_token, fetched_at_utc, source
      ) values (
        'gpt-5.5', 'openai', '1', '1',
        '2026-07-29T00:00:00Z', 'override'
      )
      ''');

      final report = await auditBranchUsage(
        db,
        currentProjectionVersion: 3,
        publicModels: _publicModels(),
      );

      expect(report.isValid, isFalse);
      expect(report.pricing.first.resolvedModelId, 'gpt-5.5');
      expect(report.pricing.first.cacheMatchesPublic, isFalse);
    },
  );

  test(
    'rejects an observed GPT-5.6 model absent from public pricing',
    () async {
      final db = _openFixtureDatabase();
      addTearDown(db.close);
      _insertEvent(
        db,
        'parent-row',
        3,
        _fingerprint('d'),
        input: 1,
        output: 1,
        model: 'gpt-5.6-new',
      );

      final report = await auditBranchUsage(
        db,
        currentProjectionVersion: 3,
        publicModels: _publicModels(),
      );

      expect(report.isValid, isFalse);
      expect(report.pricing.map((row) => row.modelId), contains('gpt-5.6-new'));
    },
  );

  test('compares cached pricing as exact valid decimals', () async {
    final db = _openFixtureDatabase();
    addTearDown(db.close);
    db.execute(
      "update model_pricing_cache "
      "set prompt_price_per_token = '0.0000050000000000000000000000001' "
      "where model_id = 'openai/gpt-5.5'",
    );

    final report = await auditBranchUsage(
      db,
      currentProjectionVersion: 3,
      publicModels: _publicModels(),
    );

    expect(report.isValid, isFalse);
    expect(report.pricing.first.cacheMatchesPublic, isFalse);
  });

  test('reports positive token buckets without a usable price', () async {
    final db = _openFixtureDatabase();
    addTearDown(db.close);
    db.execute(
      "update usage_events set cached_input_tokens = 5 "
      "where session_row_id = 'parent-row' and source_record_ordinal = 1",
    );
    db.execute(
      "update model_pricing_cache "
      "set input_cache_read_price_per_token = null "
      "where model_id = 'openai/gpt-5.5'",
    );
    final publicModels = [
      const OpenRouterModelPricing(
        modelId: 'openai/gpt-5.5',
        provider: 'openai',
        promptPricePerToken: '0.000005',
        completionPricePerToken: '0.00003',
      ),
      ..._publicModels().skip(1),
    ];

    final report = await auditBranchUsage(
      db,
      currentProjectionVersion: 3,
      publicModels: publicModels,
    );

    expect(report.isValid, isTrue);
    expect(report.projectTotals.single.costUnknown, isTrue);
  });

  test('bounds the public OpenRouter catalog request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final disconnected = Completer<void>();
    server.listen((request) async {
      final socket = await request.response.detachSocket();
      socket.listen(
        (_) {},
        onDone: disconnected.complete,
        onError: (_) => disconnected.complete(),
      );
    });

    await expectLater(
      fetchPublicOpenRouterModels(
        endpoint: Uri.http('${server.address.host}:${server.port}', '/models'),
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(anything),
    );
    await disconnected.future.timeout(const Duration(seconds: 1));
  });
}

Database _openFixtureDatabase() {
  final db = sqlite3.openInMemory();
  for (final script in const [
    '../sql/init/001_initial_schema.sql',
    '../sql/migration/002_search_filter_schema.sql',
    '../sql/migration/003_project_override.sql',
    '../sql/migration/006_session_origin.sql',
    '../sql/migration/015_branch_aware_usage.sql',
  ]) {
    db.execute(File(script).readAsStringSync());
  }
  final projectId = _insertProject(db, 'Viewer');
  _insertSession(db, 'parent-row', 'parent', projectId: projectId);
  _insertSession(
    db,
    'child-row',
    'child',
    forkedFromId: 'parent',
    projectId: projectId,
  );
  _insertSession(
    db,
    'grandchild-row',
    'grandchild',
    forkedFromId: 'child',
    projectId: projectId,
  );
  _insertSession(db, 'zero-row', 'zero', projectId: projectId);
  _insertSession(
    db,
    'ambiguous-row',
    'ambiguous',
    status: 'ambiguous',
    projectId: projectId,
  );
  _insertSession(
    db,
    'missing-row',
    'missing',
    status: 'missing_parent',
    forkedFromId: 'absent',
    projectId: projectId,
  );
  _insertEvent(db, 'parent-row', 1, _fingerprint('a'), input: 10, output: 5);
  _insertEvent(
    db,
    'child-row',
    1,
    _fingerprint('a'),
    input: 10,
    output: 5,
    scope: 'inherited',
  );
  _insertEvent(db, 'child-row', 2, _fingerprint('b'), input: 5, output: 2);
  _insertEvent(
    db,
    'grandchild-row',
    1,
    _fingerprint('a'),
    input: 10,
    output: 5,
    scope: 'inherited',
  );
  _insertEvent(
    db,
    'grandchild-row',
    2,
    _fingerprint('b'),
    input: 5,
    output: 2,
    scope: 'inherited',
  );
  _insertEvent(db, 'grandchild-row', 3, _fingerprint('c'), input: 3, output: 1);
  _insertCurrentPricing(db);
  return db;
}

int _insertProject(Database db, String name) {
  db.execute(
    '''
    insert into projects (name, created_at_utc, updated_at_utc)
    values (?, '2026-07-29T00:00:00Z', '2026-07-29T00:00:00Z')
    ''',
    [name],
  );
  return db.lastInsertRowId;
}

void _insertSession(
  Database db,
  String rowId,
  String sessionId, {
  String status = 'complete',
  String? forkedFromId,
  required int projectId,
}) {
  db.execute(
    '''
    insert into sessions (
      id, session_id, source_type, source_file_path, display_path,
      platform_path, parser_version, parse_status, scan_status,
      started_at_utc, project_id, created_at_utc, updated_at_utc,
      usage_projection_status, forked_from_id
    ) values (
      ?, ?, 'windows', ?, ?, ?, 3, 'available', 'available',
      '2026-07-29T00:00:00Z', ?, '2026-07-29T00:00:00Z',
      '2026-07-29T00:00:00Z', ?, ?
    )
    ''',
    [
      rowId,
      sessionId,
      '$rowId.jsonl',
      '$rowId.jsonl',
      '$rowId.jsonl',
      projectId,
      status,
      forkedFromId,
    ],
  );
}

void _insertEvent(
  Database db,
  String sessionRowId,
  int ordinal,
  String fingerprint, {
  required int input,
  required int output,
  String scope = 'local',
  String model = 'gpt-5.5',
}) {
  db.execute(
    '''
    insert into usage_events (
      session_row_id, source_record_ordinal, epoch, occurred_at_utc, model,
      project_id, input_tokens, cached_input_tokens,
      cache_write_input_tokens, output_tokens, reasoning_output_tokens,
      total_tokens, branch_scope, derivation, event_fingerprint
    ) values (
      ?, ?, 0, '2026-07-29T00:00:00Z', ?, 1,
      ?, 0, 0, ?, 0, ?, ?, 'last_token_usage', ?
    )
    ''',
    [
      sessionRowId,
      ordinal,
      model,
      input,
      output,
      input + output,
      scope,
      fingerprint,
    ],
  );
}

void _insertCurrentPricing(Database db) {
  for (final model in _publicModels()) {
    db.execute(
      '''
      insert into model_pricing_cache (
        model_id, provider, prompt_price_per_token,
        completion_price_per_token, input_cache_read_price_per_token,
        input_cache_write_price_per_token, fetched_at_utc, source
      ) values (?, 'openai', ?, ?, ?, ?, '2026-07-29T00:00:00Z', 'openrouter')
      ''',
      [
        model.modelId,
        model.promptPricePerToken,
        model.completionPricePerToken,
        model.inputCacheReadPricePerToken,
        model.inputCacheWritePricePerToken,
      ],
    );
  }
}

List<OpenRouterModelPricing> _publicModels() => const [
  OpenRouterModelPricing(
    modelId: 'openai/gpt-5.5',
    provider: 'openai',
    promptPricePerToken: '0.000005',
    completionPricePerToken: '0.00003',
    inputCacheReadPricePerToken: '0.0000005',
  ),
  OpenRouterModelPricing(
    modelId: 'openai/gpt-5.6-sol',
    provider: 'openai',
    promptPricePerToken: '0.000005',
    completionPricePerToken: '0.00003',
    inputCacheReadPricePerToken: '0.0000005',
    inputCacheWritePricePerToken: '0.00000625',
  ),
  OpenRouterModelPricing(
    modelId: 'openai/gpt-5.6-terra',
    provider: 'openai',
    promptPricePerToken: '0.00000125',
    completionPricePerToken: '0.0000075',
    inputCacheReadPricePerToken: '0.000000125',
    inputCacheWritePricePerToken: '0.0000015625',
  ),
];

String _fingerprint(String value) => value.padRight(64, value);
