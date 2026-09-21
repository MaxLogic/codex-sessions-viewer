import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/pricing/pricing_repository.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final endpoint = Uri.parse('https://openrouter.ai/api/v1/models');
  final request = OpenRouterModelsRequest(
    endpoint: endpoint,
    apiKey: 'fixture-key',
  );

  test(
    'fetches all catalog pages with bounded credential-safe requests',
    () async {
      final wire = _CatalogWire([
        _page('provider/a', total: 2, next: '?cursor=second'),
        _page('provider/b', total: 2),
      ]);
      final result = await HttpOverrides.runZoned(
        () => const OpenRouterHttpClient().fetchModels(request),
        createHttpClient: (_) => wire,
      );
      expect(result.models.map((model) => model.modelId), [
        'provider/a',
        'provider/b',
      ]);
      expect(result.declaredTotalCount, 2);
      expect(result.pageCount, 2);
      expect(result.nextPage, isNull);
      expect(result.payloadSha256, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(wire.connectionTimeout, const Duration(seconds: 10));
      expect(wire.requests.map((item) => item.uri), [
        endpoint,
        endpoint.replace(query: 'cursor=second'),
      ]);
      for (final sent in wire.requests) {
        expect(sent.followRedirects, isFalse);
        expect(sent.headers.values, {
          HttpHeaders.acceptHeader: 'application/json',
          HttpHeaders.authorizationHeader: 'Bearer fixture-key',
        });
      }
      expect(wire.closed, isTrue);
    },
  );

  test(
    'rejects unsafe continuation and inconsistent pages without credential leakage',
    () async {
      for (final pages in [
        [_page('provider/a', next: 'https://example.invalid/api/v1/models')],
        [_page('provider/a', next: 'https://openrouter.ai:8443/api/v1/models')],
        [
          _page(
            'provider/a',
            next: 'https://openrouter.ai/api/v1/models#fragment',
          ),
        ],
        [_page('provider/a', next: 'http://openrouter.ai/api/v1/models')],
        [_page('provider/a', next: '/api/v1/chat/completions')],
        [_page('provider/a', next: endpoint.toString())],
        [
          _page('provider/a', total: 2, next: '?cursor=2'),
          _page('provider/b', total: 3),
        ],
        [_page('provider/a', total: 2)],
        [
          _page('provider/a', total: 2, next: '?cursor=2'),
          _page('provider/a', total: 2),
        ],
      ]) {
        final wire = _CatalogWire(pages);
        await expectLater(
          HttpOverrides.runZoned(
            () => const OpenRouterHttpClient().fetchModels(request),
            createHttpClient: (_) => wire,
          ),
          throwsA(isA<PricingFetchException>()),
        );
        expect(
          wire.requests.every(
            (sent) =>
                sent.uri.scheme == 'https' &&
                sent.uri.host == 'openrouter.ai' &&
                sent.uri.port == 443 &&
                sent.uri.path == '/api/v1/models',
          ),
          isTrue,
        );
        expect(wire.closed, isTrue);
      }
    },
  );

  test(
    'preserves bounded Retry-After metadata without retaining response content',
    () async {
      final now = DateTime.utc(2026, 9, 7, 12);
      for (final (status, header, expected)
          in <(int, List<String>?, Duration?)>[
            (429, ['120'], const Duration(minutes: 2)),
            (503, ['Mon, 07 Sep 2026 14:00:00 GMT'], const Duration(hours: 2)),
            (429, ['0'], Duration.zero),
            (503, ['Mon, 07 Sep 2026 11:00:00 GMT'], Duration.zero),
            (
              429,
              ['999999999999999999999999999999'],
              const Duration(hours: 24),
            ),
            (503, ['Wed, 09 Sep 2026 12:00:00 GMT'], const Duration(hours: 24)),
            (503, null, null),
            (429, ['-1'], null),
            (429, ['1.5'], null),
            (429, ['fixture-key'], null),
            (429, ['120', '240'], null),
          ]) {
        final wire = _CatalogWire(
          ['private response fixture-key'],
          statusCode: status,
          retryAfter: header,
        );
        await expectLater(
          HttpOverrides.runZoned(
            () => OpenRouterHttpClient(clock: () => now).fetchModels(request),
            createHttpClient: (_) => wire,
          ),
          throwsA(
            isA<PricingFetchException>()
                .having((error) => error.statusCode, 'HTTP status', status)
                .having((error) => error.retryAfter, 'retry delay', expected)
                .having(
                  (error) => error.toString(),
                  'safe diagnostic',
                  'OpenRouter returned HTTP $status.',
                ),
          ),
        );
        expect(wire.closed, isTrue);
      }
    },
  );

  test(
    'cancels held catalog responses and prevents later page requests',
    () async {
      for (final holdPage in [1, 2]) {
        final cancelled = Completer<void>();
        final release = Completer<void>();
        final wire = _CatalogWire(
          [
            _page('provider/a', total: 3, next: '?cursor=2'),
            _page('provider/b', total: 3, next: '?cursor=3'),
            _page('provider/c', total: 3),
          ],
          responseGate: release.future,
          holdPage: holdPage,
        );
        final result = HttpOverrides.runZoned(
          () => const OpenRouterHttpClient().fetchModels(
            OpenRouterModelsRequest(
              endpoint: endpoint,
              apiKey: 'fixture-key',
              cancellation: cancelled.future,
            ),
          ),
          createHttpClient: (_) => wire,
        );
        await wire.heldRequestStarted.future;
        cancelled.complete();
        try {
          await expectLater(
            result.timeout(const Duration(seconds: 1)),
            throwsA(
              isA<PricingFetchException>().having(
                (error) => error.message,
                'safe cancellation',
                'OpenRouter catalog request cancelled.',
              ),
            ),
          );
          expect(wire.closed, isTrue);
        } finally {
          release.complete();
          await Future<void>.delayed(Duration.zero);
        }
        expect(wire.requests.length, holdPage);
      }
    },
  );

  test(
    'caps decoded page bytes before parsing and refuses redirects',
    () async {
      for (final wire in [
        _CatalogWire([
          jsonEncode({'data': [], 'padding': 'x' * (5 * 1024 * 1024)}),
        ]),
        _CatalogWire(['private response fixture-key'], statusCode: 302),
      ]) {
        await expectLater(
          HttpOverrides.runZoned(
            () => const OpenRouterHttpClient().fetchModels(request),
            createHttpClient: (_) => wire,
          ),
          throwsA(
            isA<PricingFetchException>().having(
              (error) => error.message,
              'safe diagnostic',
              isNot(contains('fixture-key')),
            ),
          ),
        );
        expect(wire.closed, isTrue);
      }
    },
  );
}

String _page(String id, {int? total, String? next}) => jsonEncode({
  'data': [
    {
      'id': id,
      'pricing': {'prompt': '0.000001'},
    },
  ],
  'total_count': ?total,
  'links': {'next': next},
});

// Fake only the HTTP boundary; the real parser and catalog accumulator run.
class _CatalogWire implements HttpClient {
  _CatalogWire(
    this.pages, {
    this.statusCode = 200,
    this.retryAfter,
    this.responseGate,
    this.holdPage = 1,
  });
  final List<String> pages;
  final int statusCode;
  final List<String>? retryAfter;
  final Future<void>? responseGate;
  final int holdPage;
  final heldRequestStarted = Completer<void>();
  final requests = <_CatalogRequest>[];
  bool closed = false;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    if (requests.length >= pages.length) throw StateError('Unexpected request');
    final request = _CatalogRequest(
      url,
      pages[requests.length],
      statusCode,
      retryAfter,
      requests.length + 1 == holdPage ? responseGate : null,
    );
    requests.add(request);
    if (responseGate != null && requests.length == holdPage) {
      heldRequestStarted.complete();
    }
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CatalogRequest implements HttpClientRequest {
  _CatalogRequest(
    this.uri,
    this.body,
    this.statusCode,
    this.retryAfter,
    this.responseGate,
  );
  @override
  final Uri uri;
  final String body;
  final int statusCode;
  final List<String>? retryAfter;
  final Future<void>? responseGate;
  @override
  final _CatalogHeaders headers = _CatalogHeaders();
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async {
    await responseGate;
    return _CatalogResponse(body, statusCode, retryAfter);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CatalogHeaders implements HttpHeaders {
  final values = <String, Object>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name] = value;
  }

  @override
  List<String>? operator [](String name) {
    final value = values[name];
    return value is List<String> ? value : null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CatalogResponse extends Stream<List<int>> implements HttpClientResponse {
  _CatalogResponse(this.body, this.statusCode, List<String>? retryAfter) {
    if (retryAfter != null) {
      headers.values[HttpHeaders.retryAfterHeader] = retryAfter;
    }
  }
  final String body;
  @override
  final _CatalogHeaders headers = _CatalogHeaders();
  @override
  final int statusCode;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
