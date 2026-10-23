import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ScriptedBridge implements Process {
  ScriptedBridge() {
    stdin = IOSink(_Input(this));
  }
  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final _exit = Completer<int>();
  final received = <Map<String, dynamic>>[];
  void Function(Map<String, dynamic>) onRequest = (_) {};
  bool killed = false;
  void emit(Map<String, Object?> event) =>
      _out.add(utf8.encode('${jsonEncode(event)}\n'));
  @override
  late final IOSink stdin;
  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => _err.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 1;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exit.isCompleted) {
      killed = true;
      unawaited(_out.close());
      unawaited(_err.close());
      _exit.complete(0);
    }
    return true;
  }
}

class _Input implements StreamConsumer<List<int>> {
  _Input(this.bridge);
  final ScriptedBridge bridge;
  String pending = '';
  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      pending += utf8.decode(chunk);
      while (pending.contains('\n')) {
        final end = pending.indexOf('\n');
        final request =
            jsonDecode(pending.substring(0, end)) as Map<String, dynamic>;
        pending = pending.substring(end + 1);
        bridge.received.add(request);
        bridge.onRequest(request);
      }
    }
  }

  @override
  Future<void> close() async => bridge.kill();
}
