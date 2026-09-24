import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/app/hub_data_source.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'hub settings preserve local settings and never serialize credentials',
    () {
      final settings = AppSettings.defaults().copyWith(
        hub: const HubSettings(url: 'https://hub.example', machine: 'laptop'),
      );
      expect(AppSettings.fromTomlMap(settings.toTomlMap()), settings);
      expect(settings.toTomlMap()['hub'], {
        'url': 'https://hub.example',
        'machine': 'laptop',
      });
    },
  );
  test('remote credentials require TLS except loopback', () {
    expect(
      () => HubDataSource(url: 'http://example.com', ownerToken: 'secret'),
      throwsA(isA<HubFailure>()),
    );
    expect(
      () => HubDataSource(
        url: 'https://user:pass@example.com',
        ownerToken: 'secret',
      ),
      throwsA(isA<HubFailure>()),
    );
  });
  test(
    'paged reads send identity and cursor, reject outage without fallback',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = <Map<String, dynamic>>[];
      var fail = false;
      server.listen((request) async {
        expect(request.headers.value('authorization'), 'Bearer owner');
        received.add(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        request.response.statusCode = fail ? 503 : 200;
        request.response.write(
          jsonEncode({
            'contract': 'codex-sessions-viewer.query',
            'version': 1,
            'machine': 'machine-a',
            'results': [],
            'next_cursor': 'next',
          }),
        );
        await request.response.close();
      });
      final source = HubDataSource(
        url: 'http://127.0.0.1:${server.port}',
        ownerToken: 'owner',
      );
      addTearDown(source.close);
      await source.sessions('machine-a', search: 'needle', cursor: 'previous');
      expect(received.single['args'], [
        'search',
        '--query',
        'needle',
        '--limit',
        '50',
        '--cursor',
        'previous',
      ]);
      fail = true;
      await expectLater(
        source.sessions('machine-a'),
        throwsA(isA<HubFailure>()),
      );
    },
  );
}
