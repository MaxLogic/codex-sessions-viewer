import 'test_environment.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

class HubFixture {
  HubFixture._(this.root, this.executable);
  final Directory root;
  final String executable;

  /// Chosen by the hub itself on first start (port 0), so parallel tests
  /// cannot race for the same free port; restarts reuse it.
  int port = 0;
  Process? _process;
  int _sequence = 0;
  static const ownerToken = 'gui-owner-token-1234567890123456789';
  static const machineToken = 'gui-machine-token-12345678901234567';
  String get url => 'http://127.0.0.1:$port';

  static Future<HubFixture> start() async {
    final root = await Directory.systemTemp.createTemp('csv-hub-gui-');
    final collector = Platform.environment['CODEX_SESSIONS_COLLECTOR_EXE'];
    final executable =
        Platform.environment['CODEX_SESSIONS_HUB_EXE'] ??
        (collector == null
            ? p.absolute('../collector/target/debug/codex-sessions-hub.exe')
            : p.join(p.dirname(collector), 'codex-sessions-hub.exe'));
    if (!File(executable).existsSync()) {
      await root.delete();
      throw StateError(
        'Build codex-sessions-hub, or set CODEX_SESSIONS_HUB_EXE to the exact candidate.',
      );
    }
    await File(p.join(root.path, 'hub.json')).writeAsString(
      jsonEncode({
        'owner_token': ownerToken,
        'machines': {'gui-machine': machineToken},
      }),
    );
    final fixture = HubFixture._(root, executable);
    try {
      await fixture.restart();
      return fixture;
    } catch (_) {
      await fixture.close();
      rethrow;
    }
  }

  Future<void> restart() async {
    _process = await startTestProcess(executable, [
      '127.0.0.1:$port',
      p.join(root.path, 'data'),
      p.join(root.path, 'hub.json'),
    ]);
    final errors = StringBuffer();
    _process!.stderr.transform(utf8.decoder).listen(errors.write);
    final bound = Completer<int>();
    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final match = RegExp(
            r'listening on http://[^:]+:(\d+)',
          ).firstMatch(line);
          if (match != null && !bound.isCompleted) {
            bound.complete(int.parse(match.group(1)!));
          }
        });
    var exited = false;
    unawaited(_process!.exitCode.then((_) => exited = true));
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    port = await bound.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => throw StateError('Hub failed to start: $errors'),
    );
    TestEnvironment.current.ownEndpoint(Uri.parse(url));
    while (true) {
      try {
        await request('/v1/health');
        return;
      } catch (_) {
        if (exited || DateTime.now().isAfter(deadline)) {
          throw StateError('Hub failed to start: $errors');
        }
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }
  }

  Future<Map<String, dynamic>> request(
    String route, {
    Object? body,
    String token = ownerToken,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 1);
    try {
      final request = await client.openUrl(
        body == null ? 'GET' : 'POST',
        Uri.parse('$url$route'),
      );
      request.headers.set('Authorization', 'Bearer $token');
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await utf8.decoder.bind(response).join();
      if (response.statusCode != 200) {
        throw StateError('Hub HTTP ${response.statusCode}: $text');
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> ingest(List<String> ids, {String? content}) async {
    _sequence++;
    await request(
      '/v1/ingest',
      token: machineToken,
      body: {
        'protocol': 1,
        'sequence': _sequence,
        'batch_id': 'batch-$_sequence',
        'records': [
          for (final id in ids)
            {
              'contract': 'codex-sessions-viewer.ingest',
              'version': 1,
              'kind': 'session_snapshot',
              'record': {
                'harness': 'codex',
                'source': {
                  'path': 'C:\\fixture\\$id.jsonl',
                  'environment': 'windows',
                  'state': 'active',
                  'status': 'available',
                  'size': 100,
                  'modified_utc': '2026-09-24T00:00:00Z',
                  'display_path': 'C:\\fixture\\$id.jsonl',
                  'mapped_source_file_path': 'C:\\fixture\\$id.jsonl',
                  'platform_path': 'C:\\fixture\\$id.jsonl',
                },
                'session': {
                  'session_id': id,
                  'usage_projection_status': 'complete',
                  'title': 'Session $id',
                  'started_at_utc': '2026-09-24T00:00:00Z',
                  'parser_version': 4,
                },
                'messages': [
                  {
                    'index': 0,
                    'author_type': 'user',
                    'first_line': 'Prompt $id',
                    'content_plain': content ?? 'Prompt $id',
                    'content_preview': content ?? 'Prompt $id',
                    'content_truncated': false,
                  },
                ],
              },
            },
        ],
      },
    );
  }

  Future<void> stop() async {
    _process?.kill();
    await _process?.exitCode;
    _process = null;
  }

  Future<void> close() async {
    await stop();
    if (root.existsSync()) await root.delete(recursive: true);
  }
}
