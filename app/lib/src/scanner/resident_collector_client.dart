import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../config/app_settings.dart';
import 'collector_process.dart';
import 'scan_types.dart';

class CollectorDisconnectedException implements Exception {
  const CollectorDisconnectedException([
    this.reason = 'Collector disconnected.',
  ]);
  final String reason;
  @override
  String toString() => reason;
}

class CollectorRequestException implements Exception {
  const CollectorRequestException(this.code);
  final String code;
}

class CollectorPauseUnavailableException implements Exception {
  const CollectorPauseUnavailableException();
  static const message =
      'Database maintenance could not start because session collection could not pause. Try again in a moment.';
  @override
  String toString() => message;
}

String collectionRefreshError(Object error) => switch (error) {
  CollectorUnavailableException() =>
    CollectorUnavailableException.recoveryMessage,
  CollectorDisconnectedException() =>
    'Refresh stopped because session collection restarted. Select Refresh to try again.',
  CollectorRequestException(
    code: 'busy' || 'refused' || 'queue_full' || 'unavailable',
  ) =>
    'Session collection is busy. Try Refresh again in a moment.',
  _ => 'Refresh could not finish. Select Refresh to try again.',
};

/// Connection-owned pause; release is idempotent, including after shutdown.
class CollectorPauseHandle {
  CollectorPauseHandle(this._release, {this.lost});
  final Future<void> Function() _release;

  /// Completes when exclusion is lost, even if a later connection restores it.
  final Future<void>? lost;
  Future<void>? _released;
  Future<void> dispose() => _released ??= _release();
}

typedef CollectorPauser = Future<CollectorPauseHandle> Function();

/// Bounds injected pausers too, releasing a handle that arrives after expiry.
Future<CollectorPauseHandle> acquireCollectorPause(
  CollectorPauser pauser,
) async {
  var expired = false;
  try {
    return await pauser()
        .then((handle) async {
          if (expired) await handle.dispose();
          return handle;
        })
        .timeout(const Duration(seconds: 4));
  } on Object {
    expired = true;
    rethrow;
  }
}

/// One app-owned bridge. Rust owns endpoint identity and reconnection. Worker
/// isolates forward typed requests to this same connection through requestPort.
class ResidentCollectorClient extends ChangeNotifier {
  ResidentCollectorClient({
    required this.databaseFile,
    required this.settingsFile,
    String? executable,
    CollectorProcessStarter? start,
    this.claudeRoots = const [],
  }) : executable = executable ?? CollectorProcess.defaultExecutable(),
       _start = start ?? startCollectorProcess,
       _owner = null;
  ResidentCollectorClient.proxy({
    required this.databaseFile,
    required this.settingsFile,
    required SendPort this._owner,
  }) : executable = '',
       _start = startCollectorProcess,
       claudeRoots = const [];
  final List<String> claudeRoots;
  final File databaseFile;
  final File settingsFile;
  final String executable;
  final CollectorProcessStarter _start;
  final SendPort? _owner;
  Process? _process;
  Future<void>? _opening;
  Future<void>? _restoring;
  int _residentEpoch = 0;
  Completer<void>? _connected;
  static const _connectionTimeout = Duration(seconds: 4);
  static const _ioTimeout = Duration(seconds: 2);
  final _bridges = <Process>{};
  final _launches = <Future<void>>{};
  final _retirements = <Process, Future<void>>{};
  final _pipes = <Process, List<StreamSubscription<dynamic>>>{};
  final _cancelTimers = <String, Timer>{};
  Timer? _connectionTimer;
  bool _installationUnavailable = false;
  final _operations = <String, String>{};
  final _pending = <String, StreamController<Map<String, dynamic>>>{};
  Future<void> _writes = Future.value();
  ReceivePort? _forwarding;
  var _disposed = false;
  var _stopping = false;
  var _serial = 0;
  var _pauseCount = 0;
  var _pauseEpoch = 0;
  var _connectionEpoch = 0;
  bool _pauseAcknowledged = false;
  Completer<void>? _pauseLost;
  Timer? _startingTimer;
  bool _slowStart = false;
  bool _reconnecting = false;
  int reconnectionAnnouncement = 0;
  Future<void> _pauseTail = Future.value();
  String _state = '';
  int persistenceFlushCount = 0;
  Map<String, dynamic>? cacheRepair;
  String get statusText => _pauseCount > 0 && _pauseAcknowledged
      ? 'Session collection is paused during database maintenance.'
      : switch (_state) {
          'starting' when _slowStart => 'Starting session collection…',
          'replaced' || 'reconnecting' => 'Reconnecting to session collection…',
          'failed' when _installationUnavailable =>
            CollectorUnavailableException.recoveryMessage,
          'failed' =>
            'Session collection is unavailable. Saved sessions are still shown. Select Refresh to try again.',
          _ => '',
        };
  void _setState(String state) {
    if (const {'replaced', 'reconnecting', 'failed'}.contains(state)) {
      _residentEpoch++;
      _restoring = null;
      _pauseAcknowledged = false;
      if (!(_pauseLost?.isCompleted ?? true)) _pauseLost!.complete();
      if (state != 'failed' && _state.isNotEmpty && _state != 'starting') {
        _reconnecting = true;
      }
      if (state != 'failed' && (_connected?.isCompleted ?? false)) {
        _connected = Completer<void>();
        _armConnectionDeadline();
        unawaited(
          _connected!.future.then<void>((_) {}, onError: (Object _) {}),
        );
      }
    }
    if (_state == state) return;
    if (state == 'connected' && _reconnecting) {
      reconnectionAnnouncement++;
      _reconnecting = false;
    }
    _state = state;
    if (!_disposed && !_stopping) notifyListeners();
  }

  SendPort get requestPort {
    if (_disposed || _stopping) throw const CollectorDisconnectedException();
    _forwarding ??= ReceivePort()
      ..listen((dynamic message) async {
        final request = Map<String, dynamic>.from(message[0] as Map);
        final reply = message[1] as SendPort?;
        reply?.send({'event': 'accepted'});
        try {
          if (reply == null) {
            await _send(request);
          } else {
            await for (final event in _request(request)) {
              reply.send(event);
            }
          }
        } on Object catch (error) {
          reply?.send({
            'event': 'error',
            'code': error is CollectorUnavailableException
                ? 'installation_unavailable'
                : 'disconnected',
            'message': error.toString(),
          });
        }
      });
    return _forwarding!.sendPort;
  }

  String _id() =>
      '${Isolate.current.hashCode}-${DateTime.now().microsecondsSinceEpoch}-${_serial++}';
  Future<void> connect() async {
    if (_disposed || _stopping) throw const CollectorDisconnectedException();
    final opening = _opening ??= _open();
    try {
      await opening;
      await _connected?.future;
    } on Object {
      if (identical(_opening, opening)) _opening = null;
      // A retry must never overwrite an unreaped, failed attempt.
      await _finishPreviousAttempts();
      rethrow;
    }
  }

  void _armConnectionDeadline() {
    _connectionTimer?.cancel();
    final epoch = _connectionEpoch;
    _connectionTimer = Timer(_connectionTimeout, () {
      if (epoch == _connectionEpoch && !(_connected?.isCompleted ?? true)) {
        _disconnect('Session collection connection timed out.');
      }
    });
  }

  Future<void> _open() async {
    await _finishPreviousAttempts();
    if (_disposed || _stopping) throw const CollectorDisconnectedException();
    final connectionEpoch = _connectionEpoch;
    _installationUnavailable = false;
    _setState(_state == 'failed' ? 'reconnecting' : 'starting');
    _slowStart = false;
    _startingTimer?.cancel();
    final startingTimer = _startingTimer = Timer(
      const Duration(seconds: 1),
      () {
        if (_state == 'starting' && !_disposed && !_stopping) {
          _slowStart = true;
          notifyListeners();
        }
      },
    );
    final connected = _connected = Completer<void>();
    unawaited(connected.future.then<void>((_) {}, onError: (Object _) {}));
    _armConnectionDeadline();
    // Process.start itself can be late. Keep the attempt owned after timeout,
    // and retire its eventual process rather than attaching it to a retry.
    final launch = () async {
      try {
        final process = await _start(executable, [
          'client',
          '--db',
          databaseFile.absolute.path,
          '--settings',
          settingsFile.absolute.path,
          for (final root in claudeRoots.isEmpty ? [''] : claudeRoots) ...[
            '--claude-root',
            root.isEmpty ? '' : p.absolute(root),
          ],
        ]);
        _bridges.add(process);
        unawaited(
          process.stdin.done.then<void>((_) {}, onError: (Object _) {}),
        );
        if (_disposed || _stopping || connectionEpoch != _connectionEpoch) {
          await _retire(process);
          return;
        }
        _process = process;
        _pipes[process] = [
          process.stderr.listen((_) {}, onError: (Object _) {}),
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (line) {
                  if (identical(_process, process)) _event(line);
                },
                onError: (Object error) =>
                    _disconnect(error.toString(), source: process),
                onDone: () => _disconnect(
                  'Session collection connection closed.',
                  source: process,
                ),
              ),
        ];
        unawaited(
          process.exitCode.then((_) {
            _disconnect(
              'Session collection connection exited.',
              source: process,
            );
          }),
        );
      } on Object catch (error) {
        if (!_disposed && !_stopping && connectionEpoch == _connectionEpoch) {
          _installationUnavailable =
              error is ProcessException ||
              error is CollectorUnavailableException;
          _disconnect(
            'Session collection could not start.',
            error: error is ProcessException
                ? CollectorUnavailableException(executable, error.message)
                : error,
          );
        }
      }
    }();
    _launches.add(launch);
    unawaited(launch.whenComplete(() => _launches.remove(launch)));
    try {
      await connected.future;
    } finally {
      startingTimer.cancel();
    }
  }

  Future<void> _retire(Process process) => _retirements[process] ??= () async {
    process.kill(ProcessSignal.sigkill);
    try {
      await process.exitCode.timeout(_ioTimeout);
      final pipes = _pipes.remove(process) ?? [];
      await Future.wait(pipes.map((pipe) => pipe.cancel())).timeout(_ioTimeout);
      _bridges.remove(process);
      unawaited(
        process.stdin.close().then<void>((_) {}, onError: (Object _) {}),
      );
    } finally {
      _retirements.remove(process);
    }
  }();

  Future<void> _finishPreviousAttempts() async {
    // If a starter has not returned a process handle yet, refuse a retry after
    // this bound; the late-result handler above still owns its cleanup.
    await Future.wait(_launches.toList()).timeout(_ioTimeout);
    await Future.wait(
      _bridges
          .where((process) => !identical(process, _process))
          .map(_retire)
          .toList(),
    ).timeout(const Duration(seconds: 4));
  }

  void _event(String line) {
    try {
      final event = jsonDecode(line) as Map<String, dynamic>;
      if (event['event'] == 'bridge') {
        final state = event['state'] as String;
        if (state == 'connected') {
          final restoring = _restoring ??= _connectionReady();
          unawaited(
            restoring.whenComplete(() {
              if (identical(_restoring, restoring)) _restoring = null;
            }),
          );
        } else if (state == 'starting' && _state == 'starting') {
          // The initial handshake remains silent unless it takes over a second.
        } else {
          _setState(state);
        }
        if (state == 'failed') _disconnect('Collector unavailable.');
        return;
      }
      final controller = _pending[event['id']];
      if (controller == null) return;
      controller.add(event);
      if (_terminal(event, op: _operations[event['id']])) {
        _pending.remove(event['id']);
        _cancelTimers.remove(event['id'])?.cancel();
        unawaited(controller.close());
      }
    } on Object catch (error) {
      _disconnect('Invalid collector response: $error');
    }
  }

  Future<void> _connectionReady() async {
    final residentEpoch = _residentEpoch;
    try {
      if (_pauseCount > 0 && !_pauseAcknowledged) {
        await _control(
          'pause',
          ready: false,
        ).timeout(const Duration(seconds: 4));
        if (_disposed || _stopping || residentEpoch != _residentEpoch) {
          throw const CollectorDisconnectedException();
        }
        if (_pauseCount == 0) {
          await _control(
            'resume',
            ready: false,
          ).timeout(const Duration(seconds: 4));
        } else {
          _pauseAcknowledged = true;
          _pauseLost = Completer<void>();
        }
      }
      if (_disposed || _stopping || residentEpoch != _residentEpoch) {
        throw const CollectorDisconnectedException();
      }
      _connectionTimer?.cancel();
      _setState('connected');
      if (!(_connected?.isCompleted ?? true)) _connected!.complete();
    } on Object {
      if (residentEpoch == _residentEpoch) {
        _disconnect('Maintenance pause could not be restored.');
      }
    }
  }

  static bool _terminal(Map<String, dynamic> event, {String? op}) =>
      (op == 'ingest' && event['event'] == 'finished') ||
      const {'done', 'error', 'paused', 'resumed'}.contains(event['event']);
  void _disconnect(String reason, {Process? source, Object? error}) {
    if (source != null && !identical(_process, source)) return;
    final process = _process;
    _process = null;
    _connectionEpoch++;
    _connectionTimer?.cancel();
    _startingTimer?.cancel();
    if (process != null) {
      unawaited(_retire(process).then<void>((_) {}, onError: (Object _) {}));
    }
    _setState('failed');
    final failure = error ?? CollectorDisconnectedException(reason);
    if (!(_connected?.isCompleted ?? true)) _connected!.completeError(failure);
    for (final controller in _pending.values) {
      controller.add({
        'event': 'error',
        'code': 'disconnected',
        'message': reason,
      });
      unawaited(controller.close());
    }
    _pending.clear();
    for (final timer in _cancelTimers.values) {
      timer.cancel();
    }
    _cancelTimers.clear();
    _opening = null;
  }

  Future<void> _send(Map<String, dynamic> request, {bool ready = true}) async {
    if (_disposed || _stopping) throw const CollectorDisconnectedException();
    if (_owner case final owner?) {
      owner.send([request, null]);
      return;
    }
    if (request['op'] == 'cancel') {
      final target = request['target'] as String;
      _cancelTimers.putIfAbsent(
        target,
        () => Timer(_connectionTimeout, () {
          if (_pending.containsKey(target)) {
            _disconnect('Session collection did not finish cancellation.');
          }
        }),
      );
    }
    if (ready) await connect();
    final process = _process;
    if (process == null || _disposed || _stopping) {
      throw const CollectorDisconnectedException();
    }
    await (_writes = _writes.catchError((Object _) {}).then((_) async {
      if (!identical(process, _process) || _disposed || _stopping) {
        throw const CollectorDisconnectedException();
      }
      try {
        process.stdin.writeln(jsonEncode(request));
        await process.stdin.flush().timeout(_ioTimeout);
      } on Object {
        _disconnect(
          'Session collection input stopped responding.',
          source: process,
        );
        rethrow;
      }
    }));
  }

  Stream<Map<String, dynamic>> _request(
    Map<String, dynamic> request, {
    bool ready = true,
  }) async* {
    if (_disposed || _stopping) throw const CollectorDisconnectedException();
    if (_owner case final owner?) {
      final reply = ReceivePort();
      final messages = StreamIterator<dynamic>(reply);
      try {
        owner.send([request, reply.sendPort]);
        // Bound admission to the app-owned connection even if its port closed
        // before this worker's request arrived. Scan execution can remain long.
        var available = await messages.moveNext().timeout(_connectionTimeout);
        while (available) {
          final event = Map<String, dynamic>.from(messages.current as Map);
          if (event['event'] != 'accepted') {
            yield event;
            if (_terminal(event, op: request['op'] as String)) break;
          }
          available = await messages.moveNext();
        }
      } on TimeoutException {
        throw const CollectorDisconnectedException();
      } finally {
        reply.close();
        await messages.cancel();
      }
      return;
    }
    if (_pending.length >= 128) {
      throw StateError('Collector request queue full.');
    }
    final events = StreamController<Map<String, dynamic>>();
    final id = request['id'] as String;
    _pending[id] = events;
    _operations[id] = request['op'] as String;
    try {
      await _send(request, ready: ready);
      yield* events.stream;
    } finally {
      _pending.remove(id);
      _operations.remove(id);
      _cancelTimers.remove(id)?.cancel();
      unawaited(events.close());
    }
  }

  Map<String, dynamic> _command(String op) => {'v': 1, 'id': _id(), 'op': op};
  static String? _path(String value) =>
      value.isEmpty ? null : p.absolute(value);
  Future<Map<String, dynamic>> _context(
    List<String> claudeRoots,
    bool wslProjects,
  ) async {
    final settings = settingsFile.existsSync()
        ? await SettingsRepository(settingsFile).loadOrCreate()
        : AppSettings.defaults();
    return {
      'database': databaseFile.absolute.path,
      'settings': settingsFile.absolute.path,
      'windows_root': _path(settings.paths.windowsCodexPath),
      'wsl_root': _path(settings.paths.wslCodexUncPath),
      'wsl_unc_root': _path(settings.wsl.linuxRootUnc),
      'claude_roots': claudeRoots.map((r) => p.absolute(r)).toList(),
      'claude_wsl_roots': <String>[],
      'wsl_projects': wslProjects,
      't3_state_path': _path(settings.paths.t3StatePath),
    };
  }

  static void _check(Map<String, dynamic> event) {
    if (event['event'] == 'error') {
      if (event['code'] == 'installation_unavailable') {
        throw const CollectorUnavailableException(
          '',
          'Session collection could not start.',
        );
      }
      if (event['code'] == 'disconnected') {
        throw CollectorDisconnectedException(
          event['message'] as String? ?? 'Collector disconnected.',
        );
      }
      throw CollectorRequestException(event['code'] as String? ?? 'unknown');
    }
  }

  Future<SessionScanResult> scan({
    required ScanCancellationToken cancellation,
    required void Function(ScanProgress, int) onProgress,
    List<String> claudeRoots = const [],
    bool resolveWslProjects = true,
    int? parserWorkers,
  }) async {
    final request = _command('scan')
      ..addAll({
        'harnesses': ['codex', if (claudeRoots.isNotEmpty) 'claude'],
        'context': await _context(claudeRoots, resolveWslProjects),
        'parser_workers': ?parserWorkers,
      });
    final reports = <String, Map<String, dynamic>>{};
    final counts = <String, Map<String, dynamic>>{};
    final written = <String, int>{};
    final started = DateTime.now().toUtc();
    var cancelled = false;
    var cancelSent = false;
    persistenceFlushCount = 0;
    cacheRepair = null;
    final poll = Timer.periodic(const Duration(milliseconds: 25), (_) {
      if (!cancelSent && cancellation.isCancellationRequested) {
        cancelSent = true;
        unawaited(
          _send(
            _command('cancel')..['target'] = request['id'],
          ).catchError((Object _) {}),
        );
      }
    });
    ScanProgress progress() => ScanProgress(startedAtUtc: started)
      ..directoriesScanned = _sum(counts.values, 'directories_scanned')
      ..filesFound = _sum(counts.values, 'files_found')
      ..filesSkipped = _sum(counts.values, 'files_skipped')
      ..filesParsed = _sum(counts.values, 'files_parsed')
      ..filesFailed = _sum(counts.values, 'files_failed')
      ..sessionsMissing = _sum(counts.values, 'sessions_missing');
    try {
      await for (final event in _request(request)) {
        _check(event);
        final harness =
            event['harness'] as String? ??
            (event['command'] as String? ?? 'codex').split(' ').first;
        if (event['event'] == 'progress' || event['event'] == 'finished') {
          counts[harness] = event['event'] == 'progress'
              ? event['counts'] as Map<String, dynamic>
              : event;
          written[harness] = event['sessions_written'] as int? ?? 0;
          if (event['event'] == 'finished') reports[harness] = event;
          onProgress(progress(), written.values.fold(0, (a, b) => a + b));
        }
        if (event['event'] == 'done') cancelled = event['cancelled'] == true;
      }
    } finally {
      poll.cancel();
    }
    persistenceFlushCount = _sum(reports.values, 'persistence_flushes');
    cacheRepair = reports['codex']?['cache_repair'] as Map<String, dynamic>?;
    final errors = [
      for (final report in reports.values)
        for (final dynamic entry in report['errors'] as List? ?? const [])
          ScanFileError(
            sourcePath: entry['path'] as String,
            status: SessionFileStatus.values.firstWhere(
              (s) => s.wireName == entry['status'],
              orElse: () => SessionFileStatus.parseError,
            ),
            message: entry['message'] as String? ?? '',
          ),
    ];
    final finished = progress()..finish(cancelled: cancelled);
    onProgress(finished, written.values.fold(0, (a, b) => a + b));
    return SessionScanResult(
      progress: finished,
      cancelled: cancelled,
      allConfiguredRootsReachable: !errors.any(
        (e) => e.status == SessionFileStatus.pathUnreachable,
      ),
      errors: errors,
    );
  }

  static int _sum(Iterable<Map<String, dynamic>> reports, String key) =>
      reports.fold(0, (sum, r) => sum + (r[key] as int? ?? 0));
  Future<void> ingest({
    required String sourcePath,
    required String harness,
    List<String> claudeRoots = const [],
  }) async {
    if (!const {'codex', 'claude'}.contains(harness)) {
      throw UnsupportedError('No collector for harness $harness.');
    }
    final request = _command('ingest')
      ..addAll({
        'harness': harness,
        'path': p.absolute(sourcePath),
        'context': await _context(claudeRoots, true),
      });
    await for (final event in _request(request)) {
      _check(event);
    }
  }

  Future<void> _control(String op, {bool ready = true}) async {
    await for (final event in _request(_command(op), ready: ready)) {
      _check(event);
    }
  }

  Future<T> _serializePause<T>(Future<T> Function() work) {
    final result = _pauseTail.then((_) => work());
    _pauseTail = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<CollectorPauseHandle> pause() {
    final epoch = _pauseEpoch;
    return _serializePause(() async {
      if (_disposed || _stopping || epoch != _pauseEpoch) {
        throw const CollectorDisconnectedException();
      }
      if (_owner == null) await connect();
      if (_disposed || _stopping || epoch != _pauseEpoch) {
        throw const CollectorDisconnectedException();
      }
      if (_pauseCount == 0) {
        await _control('pause');
        _pauseLost = Completer<void>();
        _pauseAcknowledged = true;
      }
      if (_disposed || _stopping || epoch != _pauseEpoch) {
        throw const CollectorDisconnectedException();
      }
      _pauseCount++;
      if (!_disposed && !_stopping) notifyListeners();
      return CollectorPauseHandle(
        () => _serializePause(() async {
          if (_disposed || _stopping || epoch != _pauseEpoch) return;
          if (--_pauseCount == 0) {
            if (_pauseAcknowledged) {
              try {
                await _control('resume').timeout(const Duration(seconds: 4));
              } on Object {
                _disconnect('Maintenance pause release failed.');
              }
            }
            _pauseAcknowledged = false;
          }
          if (!_disposed && !_stopping) notifyListeners();
        }),
        lost: _pauseLost!.future,
      );
    }).timeout(
      const Duration(seconds: 4),
      onTimeout: () {
        // Closing the connection releases even a pause acknowledged after our deadline.
        _pauseEpoch++;
        _pauseCount = 0;
        _disconnect('Maintenance pause timed out.');
        throw const CollectorDisconnectedException(
          'Maintenance pause timed out.',
        );
      },
    );
  }

  Future<void>? _closing;

  /// Fail and retire connections before joining app workers. Keep the forwarding
  /// port available to reject requests already in flight from those isolates.
  Future<void> stop() {
    if (_closing != null) return _closing!;
    _stopping = true;
    return _closing = _close();
  }

  @override
  Future<void> dispose() {
    if (!_disposed) {
      _disposed = true;
      super.dispose();
      _forwarding?.close();
    }
    return stop();
  }

  Future<void> _close() async {
    _startingTimer?.cancel();
    _disconnect('Session collection client closed.');
    try {
      await _finishPreviousAttempts();
    } on TimeoutException {
      // An OS starter can return after shutdown. Its retained callback kills
      // and reaps that process; exit never waits indefinitely for that handle.
      for (final process in _bridges.toList()) {
        process.kill(ProcessSignal.sigkill);
      }
    }
  }
}
