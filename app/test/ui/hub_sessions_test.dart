import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/app/hub_data_source.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/ui/screens/hub_sessions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/hub_fixture.dart';

void main() {
  testWidgets(
    'production GUI reads actual Rust hub uploads and preserves owner annotations',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1300, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      late HubFixture hub;
      late HubDataSource source;
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          hub = await HubFixture.start();
          await hub.ingest(['alpha', 'beta']);
          source = HubDataSource(
            url: hub.url,
            ownerToken: HubFixture.ownerToken,
          );
        }, _RealHttp()),
      );
      addTearDown(() async {
        source.close();
        await hub.close();
      });
      Future<void> settleNetwork() async {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        });
        await tester.pump();
      }

      Future<void> waitForText(String value) async {
        // Wall-clock wait for the real hub process; generous so a loaded
        // full-suite run does not flake.
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (find.text(value).evaluate().isEmpty) {
          if (DateTime.now().isAfter(deadline)) {
            final visible = find
                .byType(Text)
                .evaluate()
                .map((element) => (element.widget as Text).data)
                .whereType<String>()
                .where((text) => text.trim().isNotEmpty)
                .take(40)
                .join(' | ');
            fail(
              'Timed out waiting for hub UI text: $value. Visible: $visible',
            );
          }
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)),
          );
          await tester.pump();
        }
      }

      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SessionSourcePane(
                local: const Text('Offline local history'),
                settings: AppSettings.defaults().copyWith(
                  hub: HubSettings(url: hub.url),
                ),
                settingsFile: File('${hub.root.path}/settings.toml'),
                databaseFile: File('${hub.root.path}/absent-local.sqlite'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Hub'));
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Owner token (kept in memory)'),
        HubFixture.ownerToken,
      );
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(
          () => tester.tap(find.text('Connect to hub')),
          _RealHttp(),
        ),
      );
      await waitForText('Session alpha');
      expect(find.text('Session alpha'), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.text('Session alpha')));
      await waitForText('Prompt alpha');
      expect(find.text('Prompt alpha'), findsOneWidget);
      await tester.tap(find.text('This machine'));
      await tester.pump();
      expect(find.text('Offline local history'), findsOneWidget);
      await tester.tap(find.text('Hub'));
      await tester.pump();
      expect(find.text('Prompt alpha'), findsOneWidget);
      expect(find.text('Connect to hub'), findsNothing);
      await tester.runAsync(() async {
        final saved = await File(
          '${hub.root.path}/settings.toml',
        ).readAsString();
        expect(saved, contains(hub.url));
        expect(saved, contains('gui-machine'));
        expect(saved, isNot(contains(HubFixture.ownerToken)));
      });
      await tester.enterText(
        find.widgetWithText(TextField, 'Hub notes (owned by hub)'),
        'Preserved owner note',
      );
      await tester.runAsync(
        () => tester.tap(find.text('Save hub annotations')),
      );
      await settleNetwork();
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await hub.ingest(['alpha', 'gamma']);
          final annotation = await source.annotations(
            'gui-machine',
            'history://gui-machine/codex/alpha',
          );
          expect(annotation['notes'], 'Preserved owner note');
          final search = await source.sessions('gui-machine', search: 'Prompt');
          expect((search['results'] as List).length, 3);
          expect((await source.usage('gui-machine'))['days'], isA<List>());
        }, _RealHttp()),
      );
      // The refresh button is disabled while the annotation save is still
      // running; under full-suite load that can outlast settleNetwork, and a
      // tap on a disabled button is silently dropped.
      final refresh = find.widgetWithText(TextButton, 'Search / refresh hub');
      final idleBy = DateTime.now().add(const Duration(seconds: 30));
      while (tester.widget<TextButton>(refresh).onPressed == null) {
        if (DateTime.now().isAfter(idleBy)) fail('Hub stayed busy.');
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.runAsync(
        () => tester.tap(find.text('Search / refresh hub')),
      );
      await waitForText('Session gamma');
      expect(find.text('Session gamma'), findsOneWidget);
      expect(find.text('Prompt alpha'), findsOneWidget);
      await tester.runAsync(
        () => HttpOverrides.runWithHttpOverrides(() async {
          await hub.ingest(['long'], content: '${'x' * 4000}remaining message');
          final first = await source.message(
            'gui-machine',
            'history://gui-machine/codex/long',
            0,
            0,
          );
          expect(first['result']['next_text_offset'], 4000);
          final rest = await source.message(
            'gui-machine',
            'history://gui-machine/codex/long',
            0,
            4000,
          );
          expect(rest['result']['excerpt'], 'remaining message');
          expect(rest['result']['excerpt_truncated'], isFalse);
        }, _RealHttp()),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('a row tap during a poll never overlaps hub requests', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1300, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final source = _GatedSource();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HubSessionsScreen(
            settings: AppSettings.defaults(),
            settingsFile: File('unused.toml'),
            databaseFile: File('unused.sqlite'),
            source: source,
            pollInterval: const Duration(seconds: 1),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Gated session'), findsOneWidget);
    // The tap handler of the rendered, enabled row.
    final staleTap = tester.widget<ListTile>(find.byType(ListTile)).onTap!;
    source.listGate = Completer<void>();
    await tester.pump(const Duration(seconds: 1));
    expect(source.inFlight, 1, reason: 'the poll is holding a list request');
    staleTap();
    await tester.pump();
    expect(source.maxInFlight, 1);
    source.listGate!.complete();
    source.listGate = null;
    await tester.pump();
    await tester.pump();
    expect(source.maxInFlight, 1);
    // After the poll, selecting works and still never overlaps a poll.
    await tester.tap(find.text('Gated session'));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(source.requests, contains('session'));
    expect(source.maxInFlight, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('This machine works without any hub connection', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionSourcePane(
            local: const Text('Local history works'),
            settingsFile: File('unused.toml'),
            databaseFile: File('unused.sqlite'),
            settings: AppSettings.defaults(),
          ),
        ),
      ),
    );
    expect(find.text('Local history works'), findsOneWidget);
    expect(find.text('Hub URL'), findsNothing);
    await tester.tap(find.text('Hub'));
    await tester.pump();
    expect(find.text('Hub URL'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Owner token (kept in memory)'),
      'memory-only-token',
    );
    await tester.tap(find.text('This machine'));
    await tester.pump();
    expect(find.text('Local history works'), findsOneWidget);
    await tester.tap(find.text('Hub'));
    await tester.pump();
    expect(
      tester
          .widget<TextField>(
            find.widgetWithText(TextField, 'Owner token (kept in memory)'),
          )
          .controller!
          .text,
      'memory-only-token',
    );
  });

  testWidgets(
    'hub pages, detail, annotation save, outage and reconnect retain source identity',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1300, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final semantics = tester.ensureSemantics();
      late HttpServer server;
      late HubDataSource source;
      var fail = false;
      var ingested = false;
      final requests = <Map<String, dynamic>>[];
      await tester.runAsync(() async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          final body = request.method == 'POST'
              ? jsonDecode(await utf8.decoder.bind(request).join())
                    as Map<String, dynamic>
              : <String, dynamic>{};
          requests.add({'path': request.uri.path, ...body});
          final args = (body['args'] as List?)?.cast<String>() ?? [];
          Object response = {'protocol': 1};
          if (fail) {
            request.response.statusCode = 503;
          } else if (request.uri.path == '/v1/machines') {
            response = {
              'protocol': 1,
              'machines': ['foreign'],
            };
          } else if (request.uri.path.startsWith('/v1/annotations')) {
            response = {
              'protocol': 1,
              'machine': 'foreign',
              'reference': 'history://foreign/codex/a',
              'revision': 1,
              'title': '',
              'notes': '',
            };
          } else if (request.uri.path == '/v1/query') {
            final session = {
              'reference': 'history://foreign/codex/a',
              'machine_id': 'foreign',
              'session_key': 'a',
              'title': 'Remote session',
              'harness': 'codex',
              'environment': 'windows',
            };
            response = {
              'contract': 'codex-sessions-viewer.query',
              'version': 1,
              'machine': 'foreign',
              if (args.first == 'session')
                'session': session
              else if (args.first == 'messages') ...{
                'results': [
                  {'author_type': 'user', 'excerpt': 'Remote prompt'},
                ],
                'next_after_index': null,
              } else ...{
                'results': [
                  if (ingested)
                    {
                      ...session,
                      'reference': 'history://foreign/codex/new',
                      'title': 'New ingest',
                    },
                  session,
                ],
                'next_cursor': args.contains('--cursor') ? null : 'page2',
              },
            };
          }
          request.response.write(jsonEncode(response));
          await request.response.close();
        });
        source = HttpOverrides.runWithHttpOverrides(
          () => HubDataSource(
            url: 'http://127.0.0.1:${server.port}',
            ownerToken: 'owner',
          ),
          _RealHttp(),
        );
      });
      addTearDown(() async {
        source.close();
        await server.close(force: true);
      });
      Future<void> settleNetwork() async {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        });
        await tester.pump();
      }

      await tester.runAsync(
        () => tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: HubSessionsScreen(
                source: source,
                settings: AppSettings.defaults(),
                settingsFile: File('unused.toml'),
                databaseFile: File('missing-hub-test.sqlite'),
                pollInterval: const Duration(seconds: 1),
              ),
            ),
          ),
        ),
      );
      await settleNetwork();
      expect(
        find.text('Remote session'),
        findsOneWidget,
        reason:
            '${requests.toString()} ${tester.widgetList<Text>(find.byType(Text)).map((e) => e.data).toList()}',
      );
      await tester.runAsync(() => tester.tap(find.text('Next page')));
      await settleNetwork();
      expect(
        requests.any((r) => (r['args'] as List?)?.contains('page2') ?? false),
        isTrue,
      );
      await tester.runAsync(() => tester.tap(find.text('Remote session')));
      await settleNetwork();
      expect(find.text('Remote prompt'), findsOneWidget);
      expect(
        find.text('This machine has no local session database.'),
        findsOneWidget,
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Hub notes (owned by hub)'),
        'Owner note',
      );
      await tester.runAsync(
        () => tester.tap(find.text('Save hub annotations')),
      );
      await settleNetwork();
      expect(requests.last['notes'], 'Owner note');
      expect(requests.last['path'], '/v1/annotations/edit');
      fail = true;
      await tester.runAsync(
        () => tester.tap(find.text('Search / refresh hub')),
      );
      await settleNetwork();
      expect(find.textContaining('HTTP 503'), findsOneWidget);
      expect(find.text('Remote session'), findsOneWidget);
      fail = false;
      ingested = true;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1100)),
      );
      await settleNetwork();
      expect(find.text('New ingest'), findsOneWidget);
      expect(find.text('Remote prompt'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _RealHttp extends HttpOverrides {}

/// Counts concurrent hub requests; a list request can be held open.
class _GatedSource extends HubDataSource {
  _GatedSource() : super(url: 'http://127.0.0.1:9', ownerToken: 'test-token');
  var inFlight = 0;
  var maxInFlight = 0;
  final requests = <String>[];
  Completer<void>? listGate;

  Future<T> _track<T>(String name, Future<T> Function() body) async {
    requests.add(name);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      return await body();
    } finally {
      inFlight--;
    }
  }

  @override
  Future<List<String>> machines() => _track('machines', () async => ['m']);

  @override
  Future<Map<String, dynamic>> query(String machine, List<String> args) =>
      _track(args.first, () async {
        const session = {
          'reference': 'history://m/codex/a',
          'title': 'Gated session',
          'harness': 'codex',
          'environment': 'windows',
        };
        if (args.first == 'sessions') {
          final gate = listGate;
          if (gate != null) await gate.future;
          return {
            'results': [session],
            'next_cursor': null,
          };
        }
        if (args.first == 'session') return {'session': session};
        return {'results': <Object?>[], 'next_after_index': null};
      });

  @override
  Future<Map<String, dynamic>> annotations(String machine, String reference) =>
      _track(
        'annotations',
        () async => {'revision': 0, 'title': '', 'notes': ''},
      );
}
