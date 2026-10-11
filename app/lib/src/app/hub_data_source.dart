import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Owner-authenticated remote reads. This client never opens the local database.
class HubDataSource {
  HubDataSource({required String url, required String ownerToken})
    : base = Uri.parse(url),
      _token = ownerToken {
    if (base.userInfo.isNotEmpty ||
        base.query.isNotEmpty ||
        base.fragment.isNotEmpty ||
        !(base.scheme == 'https' ||
            (base.scheme == 'http' &&
                const ['localhost', '127.0.0.1', '::1'].contains(base.host)))) {
      throw const HubFailure(
        'Use HTTPS, or HTTP on this machine’s loopback address.',
      );
    }
    if (_token.isEmpty) throw const HubFailure('An owner token is required.');
  }

  final Uri base;
  final String _token;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  void close() => _client.close(force: true);

  Future<Map<String, dynamic>> _request(String path, [Object? body]) async {
    HttpClientRequest? pending;
    var expired = false;
    try {
      return await (() async {
        final uri = base.replace(
          path: '${base.path.replaceFirst(RegExp(r'/$'), '')}$path',
        );
        final request = await _client.openUrl(
          body == null ? 'GET' : 'POST',
          uri,
        );
        pending = request;
        if (expired) {
          request.abort();
          throw const HubFailure('The hub request timed out.');
        }
        // Never forward an owner credential through an HTTP redirect.
        request.followRedirects = false;
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
        if (body != null) {
          request.headers.contentType = ContentType.json;
          request.write(jsonEncode(body));
        }
        final response = await request.close();
        final chunks = <int>[];
        await for (final chunk in response) {
          chunks.addAll(chunk);
          if (chunks.length > 8 * 1024 * 1024) {
            throw const HubFailure('The hub response is too large.');
          }
        }
        if (response.statusCode != 200) {
          throw HubFailure(switch (response.statusCode) {
            401 || 403 => 'The hub rejected the owner token.',
            409 => 'The hub data changed. Reload before saving again.',
            _ => 'The hub request failed (HTTP ${response.statusCode}).',
          });
        }
        final value = jsonDecode(utf8.decode(chunks));
        if (value is! Map<String, dynamic>) {
          throw const HubFailure('The hub returned an invalid response.');
        }
        return value;
      })().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          expired = true;
          pending?.abort();
          throw const HubFailure('The hub request timed out.');
        },
      );
    } on HubFailure {
      rethrow;
    } catch (_) {
      // Do not surface token-bearing request diagnostics or remote response text.
      throw const HubFailure(
        'The hub is unavailable. Your local history is still available under This machine.',
      );
    }
  }

  Future<List<String>> machines() async {
    final value = await _request('/v1/machines');
    if (value['protocol'] != 1 || value['machines'] is! List) {
      throw const HubFailure('Unsupported hub protocol.');
    }
    return (value['machines'] as List).cast<String>();
  }

  Future<Map<String, dynamic>> query(String machine, List<String> args) async {
    final value = await _request('/v1/query', {
      'protocol': 1,
      'machine': machine,
      'args': args,
    });
    if (value['contract'] != 'codex-sessions-viewer.query' ||
        value['version'] != 2 ||
        value['machine'] != machine) {
      throw const HubFailure('Unsupported hub query response.');
    }
    return value;
  }

  Future<Map<String, dynamic>> sessions(
    String machine, {
    String search = '',
    String? cursor,
  }) => query(machine, [
    search.isEmpty ? 'sessions' : 'search',
    if (search.isNotEmpty) ...['--query', search],
    '--limit',
    '50',
    if (cursor != null) ...['--cursor', cursor],
  ]);

  Future<Map<String, dynamic>> detail(String machine, String reference) =>
      query(machine, ['session', '--session', reference]);

  Future<Map<String, dynamic>> message(
    String machine,
    String reference,
    int index,
    int offset,
  ) => query(machine, [
    'message',
    '--session',
    reference,
    '--index',
    '$index',
    '--text-offset',
    '$offset',
    '--chars',
    '4000',
  ]);

  Future<Map<String, dynamic>> messages(
    String machine,
    String reference, {
    int? after,
  }) => query(machine, [
    'messages',
    '--session',
    reference,
    '--include-tools',
    '--limit',
    '50',
    '--chars',
    '4000',
    if (after != null) ...['--after-index', '$after'],
  ]);

  Future<Map<String, dynamic>> usage(String machine) async {
    final result = await _request('/v1/usage', {
      'protocol': 1,
      'machine': machine,
      'limit': 30,
    });
    if (result['protocol'] != 1 || result['machine'] != machine) {
      throw const HubFailure('Unsupported hub usage response.');
    }
    return result;
  }

  Future<Map<String, dynamic>> annotations(String machine, String reference) =>
      _request('/v1/annotations', {
        'protocol': 1,
        'machine': machine,
        'reference': reference,
      });

  Future<Map<String, dynamic>> editAnnotations(
    String machine,
    String reference, {
    required int revision,
    required String title,
    required String notes,
  }) => _request('/v1/annotations/edit', {
    'protocol': 1,
    'machine': machine,
    'reference': reference,
    'expected_revision': revision,
    'title': title,
    'notes': notes,
  });
}

class HubFailure implements Exception {
  const HubFailure(this.message);
  final String message;
  @override
  String toString() => message;
}
