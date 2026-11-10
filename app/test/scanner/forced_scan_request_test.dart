import 'dart:io';

import 'package:codex_sessions_viewer/src/scanner/resident_collector_client.dart';
import 'package:codex_sessions_viewer/src/scanner/scan_types.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_collector_bridge.dart';

void main() {
  for (final force in [false, true]) {
    test('resident scan transmits force=$force on every busy retry', () async {
      final bridge = ScriptedBridge();
      final client = ResidentCollectorClient(
        databaseFile: File('fixture.sqlite'),
        settingsFile: File('fixture.toml'),
        start: (_, _) async {
          bridge.emit({'event': 'bridge', 'state': 'connected'});
          return bridge;
        },
      );
      addTearDown(client.dispose);
      var attempts = 0;
      final receivedForces = <Object?>[];
      bridge.onRequest = (request) {
        if (request['op'] != 'scan') return;
        receivedForces.add(request['force']);
        attempts++;
        if (attempts == 1) {
          bridge.emit({
            'id': request['id'],
            'event': 'error',
            'code': 'busy',
            'message': 'fixture writer busy',
          });
        } else {
          bridge.emit({
            'id': request['id'],
            'event': 'finished',
            'command': 'codex scan',
            'files_parsed': 1,
            'errors': [],
          });
          bridge.emit({
            'id': request['id'],
            'event': 'done',
            'cancelled': false,
          });
        }
      };
      final result = await client.scan(
        force: force,
        cancellation: ScanCancellationController().token,
        onProgress: (_, _) {},
      );
      expect(attempts, 2);
      expect(receivedForces, [force, force]);
      expect(result.progress.filesParsed, 1);
    });
  }
}
