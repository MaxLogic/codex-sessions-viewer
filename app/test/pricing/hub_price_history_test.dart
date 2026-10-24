import '../support/test_environment.dart';

import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/database/application_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_connection.dart';
import 'package:codex_sessions_viewer/src/database/database_maintenance.dart';
import 'package:codex_sessions_viewer/src/database/database_migrator.dart';
import 'package:codex_sessions_viewer/src/database/maintenance_job.dart';
import 'package:codex_sessions_viewer/src/pricing/hub_price_history.dart';
import 'package:codex_sessions_viewer/src/pricing/pricing_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

Database fixture({int maxVersion = 999}) {
  final db = sqlite3.openInMemory();
  final files =
      [
        ...Directory('../sql/init').listSync().whereType<File>(),
        ...Directory('../sql/migration').listSync().whereType<File>(),
      ].where((file) => file.path.endsWith('.sql')).toList()..sort(
        (a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last),
      );
  for (final file in files) {
    if (int.parse(file.uri.pathSegments.last.split('_').first) > maxVersion) {
      continue;
    }
    db.execute(file.readAsStringSync());
  }
  return db;
}

PriceObservation observation(
  int hour,
  String rate, {
  String authority = 'local',
  String origin = 'machine-a',
  List<Map<String, Object?>> rules = const [],
}) => PriceObservation(
  origin: origin,
  authority: authority,
  observedAtUtc: DateTime.utc(2026, 9, 1, hour),
  provider: 'provider',
  modelId: 'provider/model',
  model: {
    'id': 'provider/model',
    'pricing': {
      'prompt': rate,
      'completion': '0.2',
      'input_cache_read': '0.01',
      'input_cache_write': '0.0000000833333333333333',
      'internal_reasoning': '0.3',
      if (rules.isNotEmpty) 'overrides': rules,
    },
  },
);

HistoricalUsageCost cost(Database db, int hour, {PricingSettings? settings}) =>
    PricingRepository(db).resolveHistoricalUsageCost(
      settings: settings ?? AppSettings.defaults().pricing,
      occurredAtUtc: DateTime.utc(2026, 9, 1, hour),
      model: 'provider/model',
      inputTokens: 10,
      cachedInputTokens: 2,
      cacheWriteInputTokens: 3,
      outputTokens: 4,
      reasoningOutputTokens: 1,
    );

void main() {
  test(
    'unchanged observations retain provenance without copying prior periods',
    () {
      final db = fixture();
      addTearDown(db.close);
      final repo = PricingRepository(db);
      repo.mergePriceObservations([observation(0, '0.1')]);
      final snapshots = db
          .select('select count(*) n from price_catalog_snapshots')
          .single['n'];
      final first = cost(db, 1);
      repo.mergePriceObservations([
        for (var hour = 1; hour <= 24; hour++) observation(hour, '0.1'),
      ]);
      expect(
        db.select('select count(*) n from price_observations').single['n'],
        25,
      );
      expect(
        db.select('select count(*) n from price_catalog_snapshots').single['n'],
        snapshots,
      );
      expect(cost(db, 1).providerPricePeriodId, first.providerPricePeriodId);
      expect(
        db
                .select(
                  'select max(length(observations_json)) n from price_history_revisions',
                )
                .single['n']
            as int,
        lessThan(100),
      );
    },
  );
  test(
    'bounded pages, persisted deltas and hub reset preserve acknowledged state',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final stored = <String, PriceObservation>{};
      final uploadSizes = <int>[];
      final downloaded = <int>[];
      server.listen((request) async {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        final incoming = body['observations'] as List;
        if (body['download'] == false) {
          uploadSizes.add(incoming.length);
          for (final value in incoming) {
            final item = PriceObservation.fromJson(
              (value as Map).cast<String, dynamic>(),
            );
            stored[item.fingerprint] = item;
          }
          request.response.write(
            jsonEncode({'protocol': 1, 'accepted': incoming.length}),
          );
        } else {
          final after = body['after'] as int;
          final through = body['through'] as int? ?? stored.length;
          if (after > stored.length || through > stored.length) {
            request.response.statusCode = 409;
          } else {
            final snapshot = stored.values.take(through).toList();
            final page = snapshot.skip(after).take(512).toList();
            downloaded.add(page.length);
            request.response.write(
              jsonEncode({
                'protocol': 1,
                'revision': CanonicalPriceHistory(snapshot).revision,
                'observations': page.map((item) => item.toJson()).toList(),
                'after': after + page.length,
                'through': through,
                'complete': after + page.length == through,
              }),
            );
          }
        }
        await request.response.close();
      });
      final base = observation(0, '0.1');
      final local = [
        for (var i = 0; i < 520; i++)
          PriceObservation(
            origin: 'machine-a',
            authority: 'local',
            observedAtUtc: base.observedAtUtc.add(Duration(seconds: i)),
            provider: base.provider,
            modelId: base.modelId,
            model: base.model,
          ),
      ];
      final client = HubPriceHistoryClient();
      final uri = Uri.parse('http://127.0.0.1:${server.port}');
      final first = await client.synchronizeIncremental(
        endpoint: uri,
        token: 'fixture',
        observations: local,
      );
      expect(uploadSizes, [512, 8]);
      expect(downloaded, [512, 8]);
      final db = fixture();
      addTearDown(db.close);
      final repo = PricingRepository(db);
      repo.mergePriceObservations(
        first.observations,
        hubUrl: uri.toString(),
        through: first.through,
        hubRevision: first.revision,
      );
      final persisted = repo.hubSyncSnapshot(uri.toString());
      expect(persisted.revision, first.revision);
      expect(persisted.through, 520);
      final hub = observation(6, '0.2', authority: 'hub', origin: 'hub');
      stored[hub.fingerprint] = hub;
      final next = await client.synchronizeIncremental(
        endpoint: uri,
        token: 'fixture',
        observations: local,
        known: persisted.observations,
        after: persisted.through,
      );
      expect(uploadSizes, [512, 8]);
      expect(downloaded.last, 1);
      expect(next.through, 521);
      db.execute(
        "create trigger fail_ack before update on price_hub_sync_state begin select raise(abort,'injected ack failure'); end",
      );
      expect(
        () => repo.mergePriceObservations(
          next.observations,
          hubUrl: uri.toString(),
          through: next.through,
          hubRevision: next.revision,
        ),
        throwsA(isA<SqliteException>()),
      );
      expect(repo.hubSyncSnapshot(uri.toString()).through, 520);
      expect(
        db.select('select 1 from price_observations where fingerprint=?', [
          hub.fingerprint,
        ]),
        isEmpty,
      );
      stored.clear();
      final reset = await client.synchronizeIncremental(
        endpoint: uri,
        token: 'fixture',
        observations: local,
        known: next.observations,
        after: next.through,
      );
      expect(reset.through, 520);
      expect(reset.revision, first.revision);
      expect(uploadSizes, [512, 8, 512, 8]);
    },
  );
  test(
    'native Rust hub and Dart client reproduce shared exact-decimal fixture',
    () async {
      final executable = File(
        Platform.environment['CODEX_SESSIONS_HUB_EXE'] ??
            '../collector/target/debug/codex-sessions-hub.exe',
      );
      expect(
        executable.existsSync(),
        isTrue,
        reason: 'Build the schema23 Rust hub or set CODEX_SESSIONS_HUB_EXE.',
      );
      final temp = Directory.systemTemp.createTempSync('hub_price_interop_');
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final config = File('${temp.path}/hub.json')
        ..writeAsStringSync(
          jsonEncode({
            'owner_token': 'owner-token-fixture-1234567890',
            'machines': {'machine-a': 'machine-token-fixture-1234567890'},
          }),
        );
      final process = await startTestProcess(executable.absolute.path, [
        '127.0.0.1:$port',
        '${temp.path}/data',
        config.path,
      ]);
      final errors = process.stderr.transform(utf8.decoder).join();
      try {
        final ready = await process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 20));
        expect(ready, contains('hub listening'));
        final sample =
            jsonDecode(
                  File('../samples/pricing/hub-parity.json').readAsStringSync(),
                )
                as Map<String, dynamic>;
        final input = PriceObservation.fromJson(
          sample['observation'] as Map<String, dynamic>,
        );
        final response = await HubPriceHistoryClient().synchronize(
          endpoint: Uri.parse('http://127.0.0.1:$port'),
          token: 'machine-token-fixture-1234567890',
          observations: [input],
        );
        expect(
          CanonicalPriceHistory(response).revision,
          sample['expected_revision'],
        );
        final db = fixture();
        try {
          PricingRepository(db).mergePriceObservations(response);
          expect(cost(db, 1).estimatedCostText, sample['expected_cost']);
        } finally {
          db.close();
        }
      } finally {
        process.kill();
        await process.exitCode.timeout(const Duration(seconds: 10));
        final stderr = await errors;
        temp.deleteSync(recursive: true);
        expect(stderr, isEmpty);
      }
    },
  );
  test(
    'legacy history backfill preserves gaps, withdrawals and original evidence',
    () {
      final db = fixture(maxVersion: 22);
      addTearDown(db.close);
      final repo = PricingRepository(db);
      for (final hour in [0, 6]) {
        repo.applyCatalog(
          OpenRouterModelsResponse([
            OpenRouterModelPricing.fromJson(
              observation(hour, hour == 0 ? '0.1' : '0.2').model,
            ),
          ]),
          startedAtUtc: DateTime.utc(2026, 9, 1, hour),
          observedAtUtc: DateTime.utc(2026, 9, 1, hour),
        );
      }
      repo.applyCatalog(
        OpenRouterModelsResponse([], declaredTotalCount: 0),
        startedAtUtc: DateTime.utc(2026, 9, 1, 12),
        observedAtUtc: DateTime.utc(2026, 9, 1, 12),
      );
      db.execute(
        File('../sql/migration/023_price_history_sync.sql').readAsStringSync(),
      );
      final export = repo.localPriceObservationsForHub('machine-a');
      expect(export, hasLength(3));
      expect(export.every((item) => item.origin == 'machine-a'), isTrue);
      expect(
        export.where((item) => item.model['removed'] == true),
        hasLength(1),
      );
      repo.mergePriceObservations([
        observation(0, '0.9', authority: 'hub', origin: 'hub'),
      ]);
      expect(cost(db, 7).estimatedCostText, '1.9200002499999999999999');
      expect(cost(db, 13).costStatus, 'unknown');
      expect(
        PriceObservationStore(
          db,
        ).read().where((item) => item.origin == 'legacy-local'),
        hasLength(3),
      );
    },
  );
  test(
    'production maintenance prefers fresh hub and falls back while disconnected',
    () async {
      final temp = Directory.systemTemp.createTempSync('hub_prices_');
      final file = File('${temp.path}/viewer.sqlite');
      expect(
        (await DatabaseMigrator(
          sqlRoot: Directory('../sql'),
        ).openAndMigrate(file)).canStartNormalUi,
        isTrue,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var connected = true;
      final history = CanonicalPriceHistory([
        observation(6, '0.4', authority: 'hub', origin: 'hub'),
      ]);
      server.listen((request) async {
        await request.drain<void>();
        if (!connected) {
          request.response.statusCode = 503;
        } else {
          request.response.write(jsonEncode(history.toJson()));
        }
        await request.response.close();
      });
      final fallback = _FallbackCatalog();
      final maintenance = ApplicationMaintenance(
        databaseFile: file,
        coordinator: DatabaseMaintenanceCoordinator(file),
        client: fallback,
        clock: () => DateTime.utc(2026, 9, 1, 7),
        hubMachineToken: () => 'fixture-token',
      );
      final machine = _machineId(file);
      try {
        await maintenance.configure(
          AppSettings.fromTomlMap({
            'hub': {'url': 'http://127.0.0.1:${server.port}'},
            'maintenance': {'database_optimize_enabled': false},
          }),
        );
        expect(await maintenance.refreshPrices(), isTrue);
        expect(fallback.calls, 0);
        final db = openFileBackedDatabase(file);
        try {
          expect(cost(db, 7).estimatedCostText, '2.9200002499999999999999');
        } finally {
          db.close();
        }
        connected = false;
        expect(await maintenance.refreshPrices(), isTrue);
        expect(fallback.calls, 1);
        final reopened = openFileBackedDatabase(file);
        try {
          // Local evidence carries this database's machine identity.
          expect(
            PriceObservationStore(reopened).read().map((o) => o.origin),
            containsAll(['hub', machine]),
          );
          expect(
            MaintenanceJobRepository(
              reopened,
            ).readSchedule('openrouter_price_refresh')!.lastWarning,
            contains('HTTP 503'),
          );
        } finally {
          reopened.close();
        }
      } finally {
        await maintenance.stop();
        maintenance.dispose();
        await server.close(force: true);
        temp.deleteSync(recursive: true);
      }
    },
  );

  test(
    'hub price sync keeps the URL path prefix and reports rejection in Settings',
    () async {
      final temp = Directory.systemTemp.createTempSync('hub_prices_prefix_');
      final file = File('${temp.path}/viewer.sqlite');
      expect(
        (await DatabaseMigrator(
          sqlRoot: Directory('../sql'),
        ).openAndMigrate(file)).canStartNormalUi,
        isTrue,
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        await request.drain<void>();
        request.response.statusCode = 401;
        request.response.write(
          jsonEncode({'error': 'invalid machine credential'}),
        );
        await request.response.close();
      });
      String? token = 'secret-machine-token';
      final fallback = _FallbackCatalog();
      final maintenance = ApplicationMaintenance(
        databaseFile: file,
        coordinator: DatabaseMaintenanceCoordinator(file),
        client: fallback,
        clock: () => DateTime.utc(2026, 9, 1, 7),
        hubMachineToken: () => token,
      );
      String? warning() {
        final db = openFileBackedDatabase(file);
        try {
          return MaintenanceJobRepository(
            db,
          ).readSchedule('openrouter_price_refresh')!.lastWarning;
        } finally {
          db.close();
        }
      }

      try {
        await maintenance.configure(
          AppSettings.fromTomlMap({
            'hub': {'url': 'http://127.0.0.1:${server.port}/team-hub/'},
            'maintenance': {'database_optimize_enabled': false},
          }),
        );
        // The local fallback still observes prices; the hub failure is kept.
        expect(await maintenance.refreshPrices(), isTrue);
        expect(fallback.calls, 1);
        expect(paths, ['/team-hub/v1/prices/sync']);
        expect(warning(), contains('HTTP 401'));
        expect(warning(), contains('CODEX_SESSIONS_HUB_MACHINE_TOKEN'));
        expect(warning(), isNot(contains('secret-machine-token')));
        expect(maintenance.hubPriceSyncError, warning());
        // Without a machine token nothing is sent, and Settings says why.
        token = null;
        expect(await maintenance.refreshPrices(), isTrue);
        expect(paths, hasLength(1));
        expect(warning(), contains('set CODEX_SESSIONS_HUB_MACHINE_TOKEN'));
      } finally {
        await maintenance.stop();
        maintenance.dispose();
        await server.close(force: true);
        temp.deleteSync(recursive: true);
      }
    },
  );

  test('hub evidence wins across its confirmed coverage in Dart', () {
    final hub = observation(0, '0.4', authority: 'hub', origin: 'hub');
    final inside = observation(3, '0.9');
    final after = observation(9, '0.8');
    final confirmations = {hub.fingerprint: DateTime.utc(2026, 9, 1, 6)};
    final history = CanonicalPriceHistory([
      hub,
      inside,
      after,
    ], confirmations: confirmations);
    expect(history.winners.map((o) => o.model['pricing']['prompt']), [
      '0.4',
      '0.8',
    ]);
    // Confirmations change the winners, not the verified observation set.
    expect(
      history.revision,
      CanonicalPriceHistory([hub, inside, after]).revision,
    );
    expect(history.materializedRevision, isNot(history.revision));
    expect(CanonicalPriceHistory([hub, inside, after]).winners, hasLength(3));

    final db = fixture();
    addTearDown(db.close);
    final expected = fixture();
    addTearDown(expected.close);
    PricingRepository(expected).mergePriceObservations([hub]);
    final repo = PricingRepository(db);
    repo.mergePriceObservations([hub, inside]);
    expect(
      cost(db, 4).estimatedCostText,
      isNot(cost(expected, 4).estimatedCostText),
    );
    repo.mergePriceObservations(
      [hub],
      hubUrl: 'https://hub.example.test',
      through: 1,
      hubRevision: CanonicalPriceHistory([hub]).revision,
      confirmations: confirmations,
      confirmationSeq: 1,
    );
    expect(cost(db, 4).estimatedCostText, cost(expected, 4).estimatedCostText);
    expect(repo.hubSyncSnapshot('https://hub.example.test').confirmationSeq, 1);
  });

  test('a hub coverage gap keeps local evidence, as in the Rust hub', () {
    // The hub confirmed its 00:00 price through 06:00, missed the 12:00
    // fetch, and stored the unchanged price again at 18:00 (the rule of
    // price_history::fetch_once). Local evidence from the gap remains; the
    // same winners come from Rust `History::winners`.
    final first = observation(0, '0.4', authority: 'hub', origin: 'hub');
    final gap = observation(12, '0.9');
    final restarted = observation(18, '0.4', authority: 'hub', origin: 'hub');
    final inside = observation(20, '0.7');
    final history = CanonicalPriceHistory(
      [first, gap, restarted, inside],
      confirmations: {
        first.fingerprint: DateTime.utc(2026, 9, 1, 6),
        restarted.fingerprint: DateTime.utc(2026, 9, 1, 23),
      },
    );
    expect(history.winners.map((o) => o.model['pricing']['prompt']), [
      '0.4',
      '0.9',
      '0.4',
    ]);
  });

  test('plain HTTP is allowed only to a literal loopback address', () async {
    for (final url in [
      'http://localhost:9/',
      'http://example.test/',
      'http://127.0.0.2:9/',
    ]) {
      await expectLater(
        HubPriceHistoryClient().synchronizeIncremental(
          endpoint: Uri.parse(url),
          token: 'synthetic-token',
          observations: const [],
        ),
        throwsA(isA<FormatException>()),
        reason: url,
      );
    }
  });

  test(
    'client downloads confirmations with their own bounded cursor',
    () async {
      final hub = observation(0, '0.4', authority: 'hub', origin: 'hub');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        final body =
            jsonDecode(await utf8.decoder.bind(request).join())
                as Map<String, dynamic>;
        requests.add(body);
        final after = body['confirmations_after'] as int;
        request.response.write(
          jsonEncode({
            'protocol': 1,
            'revision': CanonicalPriceHistory([hub]).revision,
            'observations': [if (body['after'] == 0) hub.toJson()],
            'after': 1,
            'through': 1,
            // Two confirmation pages after the observations are complete.
            'confirmations': [
              if (after == 0)
                {
                  'fingerprint': hub.fingerprint,
                  'confirmed_at_utc': '2026-09-01T06:00:00.000000Z',
                }
              else
                {
                  'fingerprint': hub.fingerprint,
                  'confirmed_at_utc': '2026-09-01T12:00:00.000000Z',
                },
            ],
            'confirmations_after': after + 1,
            'confirmations_through': 2,
            'complete': after + 1 == 2,
          }),
        );
        await request.response.close();
      });
      final result = await HubPriceHistoryClient().synchronizeIncremental(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        token: 'fixture',
        observations: const [],
      );
      expect(requests.map((r) => r['confirmations_after']), [0, 1]);
      expect(requests.last['confirmations_through'], 2);
      expect(result.confirmationSeq, 2);
      expect(
        result.confirmations[hub.fingerprint],
        DateTime.utc(2026, 9, 1, 12),
      );
    },
  );

  test(
    'different instants in one fetch slot retain older evidence and microseconds',
    () {
      final first = observation(0, '0.1');
      final second = observation(1, '0.2', authority: 'hub', origin: 'hub');
      final history = CanonicalPriceHistory([second, first]);
      expect(history.winners, hasLength(2));
      final precise = PriceObservation(
        origin: 'local',
        authority: 'local',
        observedAtUtc: DateTime.parse('2026-09-01T00:00:00.000001Z'),
        provider: first.provider,
        modelId: first.modelId,
        model: first.model,
      );
      expect(
        precise.toJson()['observed_at_utc'],
        '2026-09-01T00:00:00.000001Z',
      );
      expect(CanonicalPriceHistory([first, precise]).winners, hasLength(2));
    },
  );
  test('shared Rust wire fixture retains fingerprint and exact Dart cost', () {
    final sample =
        jsonDecode(
              File('../samples/pricing/hub-parity.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final observed = PriceObservation.fromJson(
      sample['observation'] as Map<String, dynamic>,
    );
    expect(observed.fingerprint, sample['expected_fingerprint']);
    expect(
      CanonicalPriceHistory([observed]).revision,
      sample['expected_revision'],
    );
    final db = fixture();
    addTearDown(db.close);
    PricingRepository(db).mergePriceObservations([observed]);
    final usage = sample['usage'] as Map<String, dynamic>;
    final result = PricingRepository(db).resolveHistoricalUsageCost(
      settings: AppSettings.defaults().pricing,
      occurredAtUtc: DateTime.parse(usage['occurred_at_utc'] as String),
      model: observed.modelId,
      inputTokens: usage['input_tokens'] as int,
      cachedInputTokens: usage['cached_input_tokens'] as int,
      cacheWriteInputTokens: usage['cache_write_input_tokens'] as int,
      outputTokens: usage['output_tokens'] as int,
      reasoningOutputTokens: usage['reasoning_output_tokens'] as int,
    );
    expect(result.estimatedCostText, sample['expected_cost']);
  });

  test(
    'reconciliation invalidates only events within changed price intervals',
    () {
      final db = fixture();
      addTearDown(db.close);
      final repo = PricingRepository(db);
      repo.mergePriceObservations([
        observation(0, '0.1'),
        observation(6, '0.2'),
        observation(12, '0.3'),
      ]);
      for (final (id, at, model) in [
        ('before', '2026-09-01T05:59:59.999999Z', 'provider/model'),
        ('inside', '2026-09-01T07:00:00.000000Z', 'provider/model'),
        ('after', '2026-09-01T12:00:00.000000Z', 'provider/model'),
        ('other', '2026-09-01T07:00:00.000000Z', 'other/model'),
      ]) {
        db.execute(
          '''insert into sessions(id, source_type, source_file_path,
        display_path, platform_path, created_at_utc, updated_at_utc)
        values (?, 'windows', ?, 'fixture', 'fixture', ?, ?)''',
          [id, id, at, at],
        );
        db.execute(
          '''insert into usage_events(session_row_id, source_record_ordinal,
        epoch, occurred_at_utc, model, input_tokens, cached_input_tokens,
        cache_write_input_tokens, output_tokens, reasoning_output_tokens, total_tokens,
        branch_scope, derivation, event_fingerprint)
        values (?, 1, 0, ?, ?, 1, 0, 0, 0, 0, 1, 'local', 'last_token_usage', ?)''',
          [id, at, model, '0' * 64],
        );
        db.execute(
          '''insert into usage_session_daily(session_id, day_utc, model_key,
        path_context_id, branch_scope, input_tokens, cached_input_tokens,
        cache_write_input_tokens, output_tokens, reasoning_output_tokens, total_tokens,
        cost_status, pricing_resolution_method, cost_projection_version, updated_at_utc)
        values (?, '2026-09-01', ?, 1, 'local', 1, 0, 0, 0, 0, 1, 'unknown', 'pending_history', 1, ?)''',
          [id, model, at],
        );
      }
      final before = db
          .select('select * from usage_events')
          .map(Map<String, Object?>.from)
          .toList();
      repo.mergePriceObservations([
        observation(6, '0.9', authority: 'hub', origin: 'hub'),
      ]);
      expect(
        db
            .select('select session_id from usage_cost_dirty_partitions')
            .map((r) => r['session_id']),
        ['inside'],
      );
      expect(
        db
            .select('select * from usage_events')
            .map(Map<String, Object?>.from)
            .toList(),
        before,
      );
      expect(
        () => db.execute("update price_observations set origin = 'mutated'"),
        throwsA(isA<SqliteException>()),
      );
    },
  );
  test(
    'opposite arrival orders, retries and hub conflicts converge without losing gaps',
    () {
      final first = fixture();
      final second = fixture();
      addTearDown(first.close);
      addTearDown(second.close);
      final localOld = observation(0, '0.1');
      final gap = observation(6, '0.2');
      final conflict = observation(12, '9');
      final hub = observation(13, '0.3', authority: 'hub', origin: 'hub');
      final evidence = [localOld, gap, conflict, hub];
      final a = PricingRepository(first);
      final b = PricingRepository(second);
      for (final item in evidence) {
        a.mergePriceObservations([item]);
      }
      for (final item in evidence.reversed) {
        b.mergePriceObservations([item]);
      }
      expect(
        a.mergePriceObservations(evidence),
        b.mergePriceObservations(evidence),
      );
      expect(
        first.select('select count(*) n from price_observations').single['n'],
        4,
      );
      expect(
        cost(first, 1).estimatedCostText,
        cost(second, 1).estimatedCostText,
      );
      expect(cost(first, 7).estimatedCostText, '1.9200002499999999999999');
      expect(cost(first, 14).estimatedCostText, '2.4200002499999999999999');
      expect(
        cost(first, 14).estimatedCostText,
        cost(second, 14).estimatedCostText,
      );
      final count = first
          .select('select count(*) n from model_price_periods')
          .single['n'];
      a.mergePriceObservations(evidence);
      expect(
        first.select('select count(*) n from model_price_periods').single['n'],
        count,
      );
      expect(
        first.select(
          '''select 1 from model_price_periods a join model_price_periods b
      on a.source=b.source and a.model_id=b.model_id and a.id < b.id
      where a.valid_from_utc < coalesce(b.valid_to_utc, '9999')
        and b.valid_from_utc < coalesce(a.valid_to_utc, '9999')''',
        ),
        isEmpty,
      );
    },
  );

  test(
    'conditional rules retain exact decimal buckets and immutable revision provenance',
    () {
      final db = fixture();
      addTearDown(db.close);
      final repo = PricingRepository(db);
      repo.mergePriceObservations([
        observation(
          0,
          '0.1',
          rules: [
            {'min_prompt_tokens': 9, 'prompt': '0.4'},
          ],
        ),
      ]);
      final before = cost(db, 1);
      expect(before.estimatedCostText, '2.9200002499999999999999');
      expect(before.providerRuleIds, hasLength(1));
      final snapshot = db.select(
        'select canonical_revision from price_catalog_snapshots where id = ?',
        [before.catalogSnapshotId],
      ).single;
      expect(snapshot['canonical_revision'], isNotNull);
      repo.mergePriceObservations([
        observation(0, '0.5', authority: 'hub', origin: 'hub'),
      ]);
      expect(
        db.select(
          'select canonical_revision from price_catalog_snapshots where id = ?',
          [before.catalogSnapshotId],
        ).single,
        snapshot,
      );
      expect(cost(db, 1).estimatedCostText, '3.4200002499999999999999');
      expect(db.select('select * from usage_events'), isEmpty);
    },
  );

  test(
    'standalone observations and explicit override-only policy remain usable',
    () {
      final db = fixture();
      addTearDown(db.close);
      final repo = PricingRepository(db);
      repo.applyCatalog(
        OpenRouterModelsResponse([
          OpenRouterModelPricing.fromJson(observation(0, '0.1').model),
        ]),
        startedAtUtc: DateTime.utc(2026, 9, 1),
        observedAtUtc: DateTime.utc(2026, 9, 1),
      );
      expect(cost(db, 1).estimatedCostText, '1.4200002499999999999999');
      final defaults = AppSettings.defaults().pricing;
      final settings = PricingSettings(
        provider: defaults.provider,
        useExternalPricing: false,
        fallbackToOverrides: true,
        openRouter: defaults.openRouter,
        overrides: {
          'provider/model': const PricingOverrideSettings(
            prompt: '0',
            completion: '0',
            inputCacheRead: '0',
            inputCacheWrite: '0',
            internalReasoning: '0',
          ),
        },
      );
      repo.synchronizeSettings(settings, nowUtc: DateTime.utc(2026, 9, 1));
      repo.mergePriceObservations([
        observation(0, '99', authority: 'hub', origin: 'hub'),
      ]);
      expect(cost(db, 1, settings: settings).estimatedCostText, '0');
      expect(cost(db, 1, settings: settings).localOverridePeriodId, isNotNull);
    },
  );

  test('invalid evidence rolls back and unknown dimensions remain unknown', () {
    final db = fixture();
    addTearDown(db.close);
    final repo = PricingRepository(db);
    final unknown = PriceObservation(
      origin: 'hub',
      authority: 'hub',
      observedAtUtc: DateTime.utc(2026, 9, 1),
      provider: 'provider',
      modelId: 'provider/model',
      model: {
        'id': 'provider/model',
        'pricing': {'completion': '1'},
      },
    );
    repo.mergePriceObservations([unknown]);
    expect(cost(db, 1).costStatus, 'unknown');
    final revision = db
        .select('select revision from price_history_state')
        .single['revision'];
    expect(
      () => repo.mergePriceObservations([observation(6, '-2')]),
      throwsA(anything),
    );
    expect(
      db.select('select revision from price_history_state').single['revision'],
      revision,
    );
    expect(
      db.select('select count(*) n from price_observations').single['n'],
      1,
    );
  });

  test(
    'wire response validates canonical revision and preserves rules',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final expected = CanonicalPriceHistory([
        observation(
          0,
          '0.1',
          rules: [
            {'min_prompt_tokens': 100, 'prompt': '0.2'},
          ],
        ),
      ]);
      server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer test-token');
        expect(request.uri.path, '/v1/prices/sync');
        await request.drain<void>();
        request.response.write(jsonEncode(expected.toJson()));
        await request.response.close();
      });
      final result = await HubPriceHistoryClient().synchronize(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}'),
        token: 'test-token',
        observations: [],
      );
      expect(
        result.single.fingerprint,
        expected.observations.values.single.fingerprint,
      );
    },
  );
}

String _machineId(File file) {
  final db = openFileBackedDatabase(file);
  try {
    return db
            .select("select value from app_metadata where key = 'machine_id'")
            .single['value']
        as String;
  } finally {
    db.close();
  }
}

class _FallbackCatalog implements OpenRouterModelsClient {
  var calls = 0;
  @override
  Future<OpenRouterModelsResponse> fetchModels(
    OpenRouterModelsRequest request,
  ) async {
    calls++;
    return OpenRouterModelsResponse([
      OpenRouterModelPricing.fromJson(observation(7, '0.5').model),
    ]);
  }
}
