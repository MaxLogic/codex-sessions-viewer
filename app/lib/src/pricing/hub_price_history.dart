import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

/// Wire v1 uses sorted JSON object keys, decimal strings, and microsecond UTC.
/// Fingerprints include origin: identical observations from distinct machines
/// remain separate evidence. Retries of one observation are idempotent.
String canonicalPriceJson(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

String priceFingerprint(Object? value) =>
    sha256.convert(utf8.encode(canonicalPriceJson(value))).toString();

String priceObservationTimestamp(DateTime value) {
  final text = value.toUtc().toIso8601String();
  return text.length == 24 ? '${text.substring(0, 23)}000Z' : text;
}

class PriceObservation {
  PriceObservation({
    required this.origin,
    required this.authority,
    required DateTime observedAtUtc,
    required this.provider,
    required this.modelId,
    required this.model,
  }) : observedAtUtc = observedAtUtc.toUtc() {
    if (origin.isEmpty ||
        !['hub', 'local'].contains(authority) ||
        provider.isEmpty ||
        modelId.isEmpty ||
        model['id'] != modelId ||
        model['pricing'] is! Map) {
      throw const FormatException('Invalid price observation.');
    }
    void validateRates(Map rates) {
      for (final entry in rates.entries) {
        if ([
          'min_prompt_tokens',
          'utc_start',
          'utc_end',
          'utc_days',
        ].contains(entry.key)) {
          continue;
        }
        if (entry.key == 'overrides') {
          if (entry.value is! List) {
            throw const FormatException('Invalid price rules.');
          }
          for (final rule in entry.value as List) {
            if (rule is! Map) {
              throw const FormatException('Invalid price rule.');
            }
            validateRates(rule);
          }
        } else if (entry.value != null &&
            entry.value != '-1' &&
            (entry.value is! String ||
                !RegExp(r'^\d+(\.\d+)?$').hasMatch(entry.value as String))) {
          throw const FormatException(
            'Prices must be nonnegative decimal strings.',
          );
        }
      }
    }

    validateRates(model['pricing'] as Map);
    void validateNumbers(Object? value) {
      if (value is double) {
        throw const FormatException(
          'Noninteger metadata must be retained as raw JSON text.',
        );
      }
      if (value is Map) {
        for (final item in value.values) {
          validateNumbers(item);
        }
      }
      if (value is List) {
        for (final item in value) {
          validateNumbers(item);
        }
      }
    }

    validateNumbers(model);
  }

  factory PriceObservation.fromJson(Map<String, dynamic> json) {
    final at = DateTime.parse(json['observed_at_utc'] as String);
    if (!at.isUtc) throw const FormatException('Observation must use UTC.');
    return PriceObservation(
      origin: json['origin'] as String,
      authority: json['authority'] as String,
      observedAtUtc: at,
      provider: json['provider'] as String,
      modelId: json['model_id'] as String,
      model: (json['model'] as Map).cast<String, dynamic>(),
    );
  }

  final String origin;
  final String authority;
  final DateTime observedAtUtc;
  final String provider;
  final String modelId;
  final Map<String, dynamic> model;
  Map<String, Object?> toJson() => {
    'origin': origin,
    'authority': authority,
    'observed_at_utc': priceObservationTimestamp(observedAtUtc),
    'provider': provider,
    'model_id': modelId,
    'model': model,
  };
  String get fingerprint => priceFingerprint(toJson());
  int get slot => observedAtUtc.millisecondsSinceEpoch ~/ 21600000;
}

class CanonicalPriceHistory {
  CanonicalPriceHistory(Iterable<PriceObservation> input)
    : observations = {for (final item in input) item.fingerprint: item} {
    final ids = observations.keys.toList()..sort();
    revision = priceFingerprint(ids);
    final slots = <String, PriceObservation>{};
    for (final id in ids) {
      final item = observations[id]!;
      final key = canonicalPriceJson([
        item.provider,
        item.modelId,
        priceObservationTimestamp(item.observedAtUtc),
      ]);
      final prior = slots[key];
      if (prior == null || _compare(item, prior) > 0) slots[key] = item;
    }
    winners = slots.values.toList()
      ..sort((a, b) {
        final model = a.modelId.compareTo(b.modelId);
        if (model != 0) return model;
        return a.observedAtUtc.compareTo(b.observedAtUtc);
      });
  }
  final Map<String, PriceObservation> observations;
  late final String revision;
  late final List<PriceObservation> winners;

  static int _compare(PriceObservation a, PriceObservation b) {
    final authority = (a.authority == 'hub' ? 1 : 0).compareTo(
      b.authority == 'hub' ? 1 : 0,
    );
    if (authority != 0) return authority;
    final time = a.observedAtUtc.compareTo(b.observedAtUtc);
    return time != 0 ? time : a.fingerprint.compareTo(b.fingerprint);
  }

  Map<String, Object?> toJson() => {
    'protocol': 1,
    'revision': revision,
    'observations': [
      for (final id in observations.keys.toList()..sort())
        observations[id]!.toJson(),
    ],
  };
}

class PriceObservationStore {
  const PriceObservationStore(this.db);
  final Database db;
  bool get available => db
      .select("select 1 from sqlite_schema where name = 'price_observations'")
      .isNotEmpty;

  List<PriceObservation> read() => db
      .select(
        'select payload_json from price_observations order by fingerprint',
      )
      .map(
        (row) => PriceObservation.fromJson(
          jsonDecode(row['payload_json'] as String) as Map<String, dynamic>,
        ),
      )
      .toList();

  void insert(PriceObservation observation) => db.execute(
    '''insert or ignore into price_observations
      (fingerprint, origin, authority, observed_at_utc, provider, model_id, payload_json)
      values (?, ?, ?, ?, ?, ?, ?)''',
    [
      observation.fingerprint,
      observation.origin,
      observation.authority,
      priceObservationTimestamp(observation.observedAtUtc),
      observation.provider,
      observation.modelId,
      canonicalPriceJson(observation.toJson()),
    ],
  );
}

class HubPriceSyncResult {
  const HubPriceSyncResult(this.observations, this.through, this.revision);
  final List<PriceObservation> observations;
  final int through;
  final String revision;
}

/// Bounded pages use a stable server rowid watermark. A retained membership
/// snapshot validates deltas independently of the viewer's local-only evidence.
class HubPriceHistoryClient {
  Future<List<PriceObservation>> synchronize({
    required Uri endpoint,
    required String token,
    required List<PriceObservation> observations,
    Future<void>? cancellation,
  }) async => (await synchronizeIncremental(
    endpoint: endpoint,
    token: token,
    observations: observations,
    cancellation: cancellation,
  )).observations;

  Future<HubPriceSyncResult> synchronizeIncremental({
    required Uri endpoint,
    required String token,
    required List<PriceObservation> observations,
    List<PriceObservation> known = const [],
    int after = 0,
    Future<void>? cancellation,
  }) async {
    final loopback = ['localhost', '127.0.0.1', '::1'].contains(endpoint.host);
    if (endpoint.userInfo.isNotEmpty ||
        (endpoint.scheme != 'https' &&
            !(endpoint.scheme == 'http' && loopback))) {
      throw const FormatException(
        'Price hub requires HTTPS or loopback without URL credentials.',
      );
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    var active = true;
    unawaited(
      cancellation?.then((_) {
        if (active) client.close(force: true);
      }),
    );
    Future<Map<String, dynamic>> send(Map<String, Object?> body) async {
      final deadline = Timer(
        const Duration(seconds: 45),
        () => client.close(force: true),
      );
      try {
        final request = await client.postUrl(
          endpoint.resolve('/v1/prices/sync'),
        );
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode({'protocol': 1, ...body}));
        final response = await request.close();
        if (response.statusCode != 200) {
          throw const HttpException('Price hub request failed.');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          bytes.addAll(chunk);
          if (bytes.length > 8 * 1024 * 1024) {
            throw const FormatException('Price history page exceeds 8 MiB.');
          }
        }
        final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        if (decoded['protocol'] != 1) {
          throw const FormatException('Price protocol mismatch.');
        }
        return decoded;
      } finally {
        deadline.cancel();
      }
    }

    Future<void> upload(Iterable<PriceObservation> input) async {
      var batch = <Object?>[];
      var bytes = 0;
      for (final item in input) {
        if (item.authority != 'local') continue;
        final size = utf8.encode(jsonEncode(item.toJson())).length;
        if (size > 1024 * 1024) {
          throw const FormatException('Price observation exceeds 1 MiB.');
        }
        if (batch.isNotEmpty &&
            (batch.length == 512 || bytes + size > 4 * 1024 * 1024)) {
          await send({'download': false, 'observations': batch});
          batch = [];
          bytes = 0;
        }
        batch.add(item.toJson());
        bytes += size;
      }
      if (batch.isNotEmpty) {
        await send({'download': false, 'observations': batch});
      }
    }

    Future<HubPriceSyncResult> download(
      List<PriceObservation> previous,
      int cursor,
    ) async {
      final collected = <String, PriceObservation>{
        for (final item in previous) item.fingerprint: item,
      };
      int? through;
      String? revision;
      while (true) {
        final body = await send({
          'download': true,
          'observations': <Object?>[],
          'after': cursor,
          'through': ?through,
        });
        if (revision != null && revision != body['revision']) {
          throw const FormatException('Price snapshot changed during paging.');
        }
        revision = body['revision'] as String;
        for (final item in body['observations'] as List) {
          final observation = PriceObservation.fromJson(
            (item as Map).cast<String, dynamic>(),
          );
          collected[observation.fingerprint] = observation;
        }
        // Small legacy v1 responses remain interoperable.
        if (!body.containsKey('complete')) {
          through = 0;
        } else {
          final next = body['after'] as int;
          final upper = body['through'] as int;
          if (through != null && through != upper ||
              next < cursor ||
              next > upper ||
              (body['complete'] != true && next == cursor)) {
            throw const FormatException('Invalid price history cursor.');
          }
          through = upper;
          cursor = next;
          if (body['complete'] != true) continue;
        }
        final history = CanonicalPriceHistory(collected.values);
        if (history.revision != revision) {
          throw const FormatException('Price revision fingerprint mismatch.');
        }
        return HubPriceSyncResult(
          history.observations.values.toList(),
          through,
          revision,
        );
      }
    }

    try {
      final knownIds = known.map((item) => item.fingerprint).toSet();
      await upload(
        observations.where((item) => !knownIds.contains(item.fingerprint)),
      );
      try {
        return await download(known, after);
      } on Object {
        if (after == 0 && known.isEmpty) rethrow;
        // A restored/replaced hub can have a different rowid history. Restore
        // this machine's evidence, then verify one complete fresh snapshot.
        await upload(observations);
        return await download(const [], 0);
      }
    } finally {
      active = false;
      client.close(force: true);
    }
  }
}
