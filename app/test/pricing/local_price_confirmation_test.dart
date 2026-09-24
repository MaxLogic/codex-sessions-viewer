import 'package:codex_sessions_viewer/src/pricing/hub_price_history.dart';
import 'package:codex_sessions_viewer/src/pricing/pricing_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

import 'hub_price_history_test.dart' show cost, fixture, observation;

/// One complete local catalog fetch at [hour] (hours after 2026-09-01 UTC).
/// A null [rate] means the model is absent from the complete catalog.
void fetch(Database db, int hour, String? rate) {
  final at = DateTime.utc(2026, 9, 1, hour);
  PricingRepository(db).applyCatalog(
    OpenRouterModelsResponse([
      if (rate != null)
        OpenRouterModelPricing.fromJson(observation(hour, rate).model),
    ], declaredTotalCount: rate == null ? 0 : 1),
    startedAtUtc: at,
    observedAtUtc: at,
  );
}

List<PriceObservation> local(Database db) =>
    PriceObservationStore(db).read().where((o) => o.origin == 'local').toList()
      ..sort((a, b) => a.observedAtUtc.compareTo(b.observedAtUtc));

DateTime? confirmedAt(Database db, PriceObservation item) =>
    PriceObservationStore(db).readConfirmations()[item.fingerprint];

void main() {
  test('unchanged contiguous fetches confirm the observation', () {
    final db = fixture();
    addTearDown(db.close);
    for (final hour in [0, 6, 12, 18]) {
      fetch(db, hour, '0.1');
    }
    final stored = local(db);
    expect(stored, hasLength(1));
    expect(stored.single.observedAtUtc, DateTime.utc(2026, 9, 1));
    expect(confirmedAt(db, stored.single), DateTime.utc(2026, 9, 1, 18));
    // The legacy period table keeps one open period as well.
    expect(
      db.select('select count(*) n from model_price_periods').single['n'],
      1,
    );
  });

  test('a changed price stores one new observation', () {
    final db = fixture();
    addTearDown(db.close);
    fetch(db, 0, '0.1');
    fetch(db, 6, '0.2');
    fetch(db, 12, '0.2');
    final stored = local(db);
    expect(stored.map((o) => o.model['pricing']['prompt']), ['0.1', '0.2']);
    expect(confirmedAt(db, stored.last), DateTime.utc(2026, 9, 1, 12));
  });

  test('a missed fetch slot starts a new observation', () {
    final db = fixture();
    addTearDown(db.close);
    fetch(db, 0, '0.1');
    fetch(db, 6, '0.1');
    // The 12:00 slot was missed.
    fetch(db, 18, '0.1');
    fetch(db, 24, '0.1');
    final stored = local(db);
    expect(stored.map((o) => o.observedAtUtc.hour), [0, 18]);
    expect(confirmedAt(db, stored.first), DateTime.utc(2026, 9, 1, 6));
    expect(confirmedAt(db, stored.last), DateTime.utc(2026, 9, 2));
  });

  test('a removed model tombstone is confirmed, not duplicated', () {
    final db = fixture();
    addTearDown(db.close);
    fetch(db, 0, '0.1');
    for (final hour in [6, 12, 18]) {
      fetch(db, hour, null);
    }
    final tombstones = local(
      db,
    ).where((o) => o.model['removed'] == true).toList();
    expect(tombstones, hasLength(1));
    expect(tombstones.single.observedAtUtc, DateTime.utc(2026, 9, 1, 6));
    expect(confirmedAt(db, tombstones.single), DateTime.utc(2026, 9, 1, 18));
  });

  test('compacted history reprices exactly as the uncompacted history', () {
    // Schema 23 has no confirmation table, so every fetch stores a new
    // observation there: the previous behavior.
    final compacted = fixture();
    addTearDown(compacted.close);
    final uncompacted = fixture(maxVersion: 23);
    addTearDown(uncompacted.close);
    final hub = observation(27, '0.9', authority: 'hub', origin: 'hub');
    final script = <(int, String?)>[
      (0, '0.1'),
      (6, '0.1'),
      (12, '0.1'),
      (18, '0.2'),
      (24, '0.2'),
      // A hub observation with another price arrives at 27:00.
      (30, '0.2'),
      (36, '0.2'),
      // 42:00 and 48:00 are missed.
      (54, '0.2'),
      (60, null),
      (66, null),
      (72, '0.1'),
      (78, '0.1'),
    ];
    for (final db in [compacted, uncompacted]) {
      for (final (hour, rate) in script) {
        if (hour == 30) PricingRepository(db).mergePriceObservations([hub]);
        fetch(db, hour, rate);
      }
    }
    // Every fetch but the second absent one (no second tombstone).
    expect(local(uncompacted), hasLength(script.length - 1));
    // 00:00, 18:00, 30:00 (after the hub's other price), 54:00 (after the
    // gap), the 60:00 tombstone and 72:00.
    expect(local(compacted).map((o) => o.observedAtUtc.hour), [
      0,
      18,
      6,
      6,
      12,
      0,
    ]);
    // The script covers each price, the hub's price and the withdrawal.
    expect({
      for (var hour = 0; hour <= 84; hour++)
        cost(uncompacted, hour).estimatedCostText,
    }, hasLength(4));
    for (var hour = 0; hour <= 84; hour++) {
      final expected = cost(uncompacted, hour);
      final actual = cost(compacted, hour);
      expect(
        (actual.estimatedCostText, actual.costStatus),
        (expected.estimatedCostText, expected.costStatus),
        reason: 'hour $hour',
      );
    }
  });
}
