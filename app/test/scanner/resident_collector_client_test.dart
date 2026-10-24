import '../support/test_environment.dart';

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:codex_sessions_viewer/src/scanner/resident_collector_client.dart';
import 'package:codex_sessions_viewer/src/scanner/scan_types.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import '../support/scripted_collector_bridge.dart';
import '../support/collector_fixture.dart';

void main() {
  late ScriptedBridge bridge;
  late ResidentCollectorClient client;
  setUp(() {
    bridge = ScriptedBridge();
    client = ResidentCollectorClient(
      databaseFile: File('fixture.sqlite'),
      settingsFile: File('fixture.toml'),
      start: (_, args) async {
        expect(args.take(5), [
          'client',
          '--db',
          p.absolute('fixture.sqlite'),
          '--settings',
          p.absolute('fixture.toml'),
        ]);
        bridge.emit({'event': 'bridge', 'state': 'replaced'});
        bridge.emit({'event': 'bridge', 'state': 'connected'});
        return bridge;
      },
    );
  });
  tearDown(() => client.dispose());

  test('a worker request to a closed app port has a bounded failure', () async {
    final closed = ReceivePort();
    final owner = closed.sendPort;
    closed.close();
    final proxy = ResidentCollectorClient.proxy(
      databaseFile: File('fixture.sqlite'),
      settingsFile: File('fixture.toml'),
      owner: owner,
    );
    try {
      await expectLater(
        proxy
            .ingest(sourcePath: 'fixture.jsonl', harness: 'codex')
            .timeout(const Duration(seconds: 5)),
        throwsA(isA<CollectorDisconnectedException>()),
      );
    } finally {
      await proxy.dispose();
    }
  });

  test(
    'shutdown rejects a worker request arriving after connections stop',
    () async {
      final proxy = ResidentCollectorClient.proxy(
        databaseFile: File('fixture.sqlite'),
        settingsFile: File('fixture.toml'),
        owner: client.requestPort,
      );
      try {
        await client.stop();
        await expectLater(
          proxy
              .ingest(sourcePath: 'fixture.jsonl', harness: 'codex')
              .timeout(const Duration(seconds: 1)),
          throwsA(isA<CollectorDisconnectedException>()),
        );
      } finally {
        await proxy.dispose();
      }
    },
  );

  test(
    'native bridge processes are gone after timeout retry and disposal',
    () async {
      await client.dispose();
      final root = await Directory.systemTemp.createTemp(
        'cxv184-bridge-process-',
      );
      final script = File(p.join(root.path, 'bridge.dart'));
      await script.writeAsString('''
import 'dart:async';
import 'dart:io';
void main(List<String> args) {
  if (args.isNotEmpty) stdout.writeln('{"event":"bridge","state":"connected"}');
  stdin.listen((_) {});
  Timer.periodic(const Duration(seconds: 1), (_) {});
}
''');
      final flutterRoot = Platform.environment['FLUTTER_ROOT'];
      expect(
        flutterRoot,
        isNotNull,
        reason: 'Run using the installed Flutter SDK.',
      );
      final dart = p.join(
        flutterRoot!,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      );
      final processes = <Process>[];
      var firstReaped = false;
      client = ResidentCollectorClient(
        databaseFile: File('fixture.sqlite'),
        settingsFile: File('fixture.toml'),
        start: (_, _) async {
          if (processes.isNotEmpty) expect(firstReaped, isTrue);
          final process = await startTestProcess(dart, [
            script.path,
            if (processes.isNotEmpty) 'ready',
          ]);
          processes.add(process);
          if (processes.length == 1) {
            unawaited(process.exitCode.then((_) => firstReaped = true));
          }
          return process;
        },
      );
      try {
        await expectLater(
          client.connect(),
          throwsA(isA<CollectorDisconnectedException>()),
        );
        expect(firstReaped, isTrue);
        await client.connect();
        await client.dispose().timeout(const Duration(seconds: 5));
        final exits = await Future.wait(
          processes.map((p) => p.exitCode),
        ).timeout(const Duration(seconds: 2));
        expect(processes, hasLength(2));
        // ignore: avoid_print
        print(
          'native_bridge_pids=${processes.map((p) => p.pid).toList()} exit_codes=$exits reaped_before_retry=$firstReaped surviving_bridges=0',
        );
      } finally {
        for (final process in processes) {
          process.kill(ProcessSignal.sigkill);
          await process.exitCode;
        }
        await client.dispose();
        await deleteCollectorFixture(root);
      }
    },
  );

  test(
    'a process returned after startup timeout remains owned and is reaped',
    () async {
      await client.dispose();
      final lateProcess = Completer<Process>();
      client = ResidentCollectorClient(
        databaseFile: File('fixture.sqlite'),
        settingsFile: File('fixture.toml'),
        start: (_, _) => lateProcess.future,
      );
      final result = client.connect().then<Object>(
        (_) => 'connected',
        onError: (Object error) => error,
      );
      // Includes the four-second handshake and bounded cleanup of a late start.
      expect(
        await result.timeout(const Duration(seconds: 7)),
        isA<Exception>(),
      );
      lateProcess.complete(bridge);
      await client.dispose().timeout(const Duration(seconds: 5));
      expect(bridge.killed, isTrue);
      await bridge.exitCode;
    },
  );

  test('timed-out initial bridge is reaped before retry and disposal', () async {
    await client.dispose();
    final old = bridge;
    final fresh = ScriptedBridge();
    var starts = 0;
    client = ResidentCollectorClient(
      databaseFile: File('fixture.sqlite'),
      settingsFile: File('fixture.toml'),
      start: (_, _) async {
        if (starts++ == 0) return old;
        expect(
          old.killed,
          isTrue,
          reason: 'Retry must first retire the failed attempt.',
        );
        await old.exitCode;
        fresh.emit({'event': 'bridge', 'state': 'connected'});
        return fresh;
      },
    );
    try {
      final watch = Stopwatch()..start();
      await expectLater(client.connect(), throwsA(isA<Exception>()));
      expect(watch.elapsed, lessThan(const Duration(seconds: 22)));
      expect(old.killed, isTrue);
      expect(client.statusText, contains('unavailable'));
      await client.connect();
      await client.dispose();
      expect(fresh.killed, isTrue);
      await Future.wait([old.exitCode, fresh.exitCode]);
      // ignore: avoid_print
      print(
        'initial_timeout_ms=${watch.elapsedMilliseconds} starts=$starts all_bridges_reaped=true',
      );
    } finally {
      old.kill();
      fresh.kill();
    }
  });

  test('hung reconnect and cancelled scan finish without disposal', () async {
    await client.connect();
    bridge.emit({'event': 'bridge', 'state': 'reconnecting'});
    await Future<void>.delayed(Duration.zero);
    var connected = false;
    var scanFinished = false;
    final cancellation = ScanCancellationController();
    final scan = client
        .scan(cancellation: cancellation.token, onProgress: (_, _) {})
        .then<void>(
          (_) => scanFinished = true,
          onError: (Object _) => scanFinished = true,
        );
    final connection = client.connect().then<void>(
      (_) => connected = true,
      onError: (Object _) => connected = true,
    );
    cancellation.cancel();
    try {
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(
        connected,
        isTrue,
        reason: 'Reconnect must have its own deadline.',
      );
      expect(scanFinished, isTrue);
      expect(bridge.killed, isTrue);
      // ignore: avoid_print
      print(
        'hung_reconnect_at_6s connection_finished=$connected cancelled_scan_finished=$scanFinished bridge_killed=${bridge.killed}',
      );
    } finally {
      await client.dispose();
      await connection;
      await scan;
    }
  });

  test(
    'cancelled connected scan cannot hold shutdown waiting for done',
    () async {
      final cancellation = ScanCancellationController();
      final requested = Completer<void>();
      bridge.onRequest = (request) {
        if (request['op'] == 'scan') requested.complete();
      };
      final result = client
          .scan(cancellation: cancellation.token, onProgress: (_, _) {})
          .then<Object>((value) => value, onError: (Object error) => error);
      await requested.future;
      cancellation.cancel();
      try {
        final value = await result.timeout(const Duration(seconds: 6));
        expect(value, isA<CollectorDisconnectedException>());
        expect(bridge.killed, isTrue);
      } finally {
        await client.dispose();
      }
    },
  );

  test(
    'scan retries a busy writer without retaining partial attempt counts',
    () async {
      final ids = <String>[];
      bridge.onRequest = (request) {
        if (request['op'] != 'scan') return;
        final id = request['id'] as String;
        ids.add(id);
        if (ids.length == 1) {
          bridge.emit({
            'id': id,
            'event': 'progress',
            'harness': 'codex',
            'counts': {'files_parsed': 1},
            'sessions_written': 1,
          });
          bridge.emit({
            'id': id,
            'event': 'error',
            'code': 'busy',
            'message': 'SQLite error 5 (DatabaseBusy): database is locked',
          });
        } else {
          bridge.emit({
            'id': id,
            'event': 'finished',
            'command': 'codex scan',
            'files_parsed': 2,
            'sessions_written': 2,
            'persistence_flushes': 1,
            'errors': [],
          });
          bridge.emit({'id': id, 'event': 'done', 'cancelled': false});
        }
      };
      final result = await client.scan(
        cancellation: ScanCancellationController().token,
        onProgress: (_, _) {},
      );
      expect(ids, hasLength(2));
      expect(ids.toSet(), hasLength(2));
      expect(result.progress.filesParsed, 2);
      expect(client.persistenceFlushCount, 1);
    },
  );

  for (final code in [
    'busy',
    'refused',
    'bad_request',
    'unsupported_version',
  ]) {
    test('scan bounds $code failures and preserves their diagnostic', () async {
      var attempts = 0;
      bridge.onRequest = (request) {
        if (request['op'] != 'scan') return;
        attempts++;
        bridge.emit({
          'id': request['id'],
          'event': 'error',
          'code': code,
          'message': 'specific failure cause',
        });
      };
      await expectLater(
        client.scan(
          cancellation: ScanCancellationController().token,
          onProgress: (_, _) {},
        ),
        throwsA(
          isA<CollectorRequestException>()
              .having((error) => error.code, 'code', code)
              .having(
                (error) => error.toString(),
                'diagnostic',
                contains('specific failure cause'),
              ),
        ),
      );
      expect(attempts, code == 'busy' ? 3 : 1);
    });
  }

  test(
    'cancellation during busy backoff does not start another scan',
    () async {
      final cancellation = ScanCancellationController();
      var attempts = 0;
      bridge.onRequest = (request) {
        if (request['op'] != 'scan') return;
        attempts++;
        bridge.emit({'id': request['id'], 'event': 'error', 'code': 'busy'});
        Timer(const Duration(milliseconds: 50), cancellation.cancel);
      };
      await expectLater(
        client.scan(cancellation: cancellation.token, onProgress: (_, _) {}),
        throwsA(isA<CollectorRequestException>()),
      );
      expect(attempts, 1);
    },
  );

  test('scan maps per-harness progress and waits for done', () async {
    var completed = false;
    final progress = <int>[];
    bridge.onRequest = (request) {
      expect(
        request['context'],
        containsPair('database', p.absolute('fixture.sqlite')),
      );
      final context = request['context'] as Map<String, dynamic>;
      expect(context['claude_roots'], [p.absolute('Claude-Root')]);
      for (final key in [
        'settings',
        'windows_root',
        'wsl_root',
        'wsl_unc_root',
        't3_state_path',
      ]) {
        final path = context[key] as String?;
        if (path != null) expect(p.isAbsolute(path), isTrue, reason: key);
      }
      final id = request['id'];
      bridge.emit({
        'id': id,
        'event': 'progress',
        'harness': 'codex',
        'counts': {'files_parsed': 2},
        'sessions_written': 2,
      });
      bridge.emit({
        'id': id,
        'event': 'finished',
        'command': 'codex scan',
        'files_parsed': 2,
        'sessions_written': 2,
        'persistence_flushes': 1,
        'errors': [],
      });
      bridge.emit({
        'id': id,
        'event': 'finished',
        'command': 'claude scan',
        'files_parsed': 3,
        'sessions_written': 3,
        'persistence_flushes': 2,
        'errors': [],
      });
      scheduleMicrotask(() {
        expect(completed, isFalse);
        bridge.emit({'id': id, 'event': 'done', 'cancelled': false});
      });
    };
    final result = await client
        .scan(
          cancellation: ScanCancellationController().token,
          onProgress: (value, _) => progress.add(value.filesParsed),
          claudeRoots: ['Claude-Root'],
        )
        .then((value) {
          completed = true;
          return value;
        });
    expect(result.progress.filesParsed, 5);
    expect(result.cancelled, isFalse);
    expect(progress, contains(2));
    expect(client.persistenceFlushCount, 3);
    expect(bridge.received, hasLength(1));
    expect(
      bridge.killed,
      isFalse,
      reason: 'The app owns one long-lived bridge.',
    );
  });

  test('cancel targets the active scan without a writer grant', () async {
    final cancellation = ScanCancellationController();
    String? scanId;
    bridge.onRequest = (request) {
      if (request['op'] == 'scan') {
        scanId = request['id'] as String;
        cancellation.cancel();
      }
      if (request['op'] == 'cancel') {
        expect(request['target'], scanId);
        bridge.emit({'id': scanId, 'event': 'done', 'cancelled': true});
      }
    };
    final result = await client.scan(
      cancellation: cancellation.token,
      onProgress: (_, _) {},
    );
    expect(result.cancelled, isTrue);
  });

  test(
    'ingest passes an absolute typed file and completes on committed finished',
    () async {
      bridge.onRequest = (request) {
        expect(request['op'], 'ingest');
        expect(request['harness'], 'claude');
        expect(request['path'], p.absolute('transcript.jsonl'));
        bridge.emit({'id': request['id'], 'event': 'finished'});
      };
      await client.ingest(sourcePath: 'transcript.jsonl', harness: 'claude');
    },
  );

  test('pause handle releases once and dispose closes the bridge', () async {
    bridge.onRequest = (request) => bridge.emit({
      'id': request['id'],
      'event': request['op'] == 'pause' ? 'paused' : 'resumed',
    });
    final pause = await client.pause();
    expect(
      client.statusText,
      'Session collection is paused during database maintenance.',
    );
    final nested = await client.pause();
    await pause.dispose();
    await pause.dispose();
    expect(bridge.received.map((r) => r['op']), ['pause']);
    expect(
      client.statusText,
      'Session collection is paused during database maintenance.',
    );
    await nested.dispose();
    expect(bridge.received.map((r) => r['op']), ['pause', 'resume']);
    final held = await client.pause();
    await client.dispose();
    await held.dispose();
    expect(bridge.killed, isTrue);
  });

  test('reconnect reacquires maintenance pause before connected', () async {
    bridge.onRequest = (request) => bridge.emit({
      'id': request['id'],
      'event': request['op'] == 'pause' ? 'paused' : 'resumed',
    });
    final previous = await client.pause();
    bridge.emit({'event': 'bridge', 'state': 'reconnecting'});
    await Future<void>.delayed(Duration.zero);
    expect(client.statusText, 'Reconnecting to session collection…');
    final resumedConnection = Completer<void>();
    bridge.onRequest = (request) {
      if (request['op'] == 'pause') {
        expect(client.statusText, 'Reconnecting to session collection…');
        resumedConnection.complete();
      } else {
        bridge.emit({'id': request['id'], 'event': 'resumed'});
      }
    };
    bridge.emit({'event': 'bridge', 'state': 'connected'});
    await Future<void>.delayed(Duration.zero);
    expect(bridge.received.map((r) => r['op']), ['pause', 'pause']);
    await resumedConnection.future;
    bridge.emit({'id': bridge.received.last['id'], 'event': 'paused'});
    await Future<void>.delayed(Duration.zero);
    expect(
      client.statusText,
      'Session collection is paused during database maintenance.',
    );
    await previous.dispose();
    expect(bridge.received.map((r) => r['op']), ['pause', 'pause', 'resume']);
  });

  test(
    'pause acknowledgement is bounded and releases pending ownership',
    () async {
      bridge.onRequest = (_) {};
      await expectLater(
        client.pause().timeout(const Duration(seconds: 5)),
        throwsA(isNot(isA<TimeoutException>())),
      );
      expect(bridge.killed, isTrue);
      expect(client.statusText, contains('unavailable'));
    },
  );

  test(
    'pause deadline includes connecting and closes an unacknowledged handshake',
    () async {
      await client.dispose();
      client = ResidentCollectorClient(
        databaseFile: File('fixture.sqlite'),
        settingsFile: File('fixture.toml'),
        start: (_, _) async => bridge,
      );
      await expectLater(
        client.pause().timeout(const Duration(seconds: 5)),
        throwsA(isA<CollectorDisconnectedException>()),
      );
      expect(bridge.killed, isTrue);
      expect(bridge.received, isEmpty);
    },
  );

  test(
    'failed pause restoration never reports a connected maintenance state',
    () async {
      bridge.onRequest = (request) =>
          bridge.emit({'id': request['id'], 'event': 'paused'});
      final held = await client.pause();
      bridge.emit({'event': 'bridge', 'state': 'reconnecting'});
      await Future<void>.delayed(Duration.zero);
      bridge.onRequest = (_) {};
      final states = <String>[];
      client.addListener(() => states.add(client.statusText));
      bridge.emit({'event': 'bridge', 'state': 'connected'});
      await Future<void>.delayed(const Duration(milliseconds: 4200));
      expect(bridge.received.map((r) => r['op']), ['pause', 'pause']);
      expect(bridge.killed, isTrue);
      expect(
        states,
        isNot(
          contains('Session collection is paused during database maintenance.'),
        ),
      );
      expect(client.statusText, contains('unavailable'));
      await held.dispose();
    },
  );

  test(
    'replaced and reconnecting are observable; disconnect fails inflight',
    () async {
      final states = <String>[];
      client.addListener(() => states.add(client.statusText));
      bridge.onRequest = (request) {
        bridge.emit({'event': 'bridge', 'state': 'replaced'});
        bridge.emit({'event': 'bridge', 'state': 'reconnecting'});
        bridge.emit({
          'id': request['id'],
          'event': 'error',
          'code': 'disconnected',
          'message': 'resident disconnected',
        });
      };
      await expectLater(
        client.ingest(sourcePath: 'a.jsonl', harness: 'codex'),
        throwsA(isA<CollectorDisconnectedException>()),
      );
      expect(states, contains('Reconnecting to session collection…'));
    },
  );

  test('unexpected bridge exit fails pending requests', () async {
    bridge.onRequest = (_) => bridge.kill();
    await expectLater(
      client.ingest(sourcePath: 'a.jsonl', harness: 'codex'),
      throwsA(isA<CollectorDisconnectedException>()),
    );
    expect(
      client.statusText,
      'Session collection is unavailable. Saved sessions are still shown. Select Refresh to try again.',
    );
    final previous = bridge;
    bridge = ScriptedBridge();
    bridge.onRequest = (request) =>
        bridge.emit({'id': request['id'], 'event': 'finished'});
    await client.ingest(sourcePath: 'b.jsonl', harness: 'codex');
    expect(previous.received, hasLength(1));
    expect(bridge.received.single['path'], p.absolute('b.jsonl'));
    expect(client.statusText, isEmpty);
  });
}
