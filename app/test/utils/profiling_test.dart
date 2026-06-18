import 'package:codex_sessions_viewer/src/utils/profiling.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('profiling helper records sync and async span boundaries', () async {
    final events = <ProfilingEvent>[];

    final syncValue = Profiling.capture(events.add, () {
      return Profiling.spanSync('test.sync', () => 42);
    });
    final asyncValue = await Profiling.captureAsync(events.add, () async {
      return Profiling.spanAsync('test.async', () async => 'done');
    });

    expect(syncValue, 42);
    expect(asyncValue, 'done');
    expect(events.map((event) => '${event.name}:${event.kind.name}'), [
      'test.sync:start',
      'test.sync:finish',
      'test.async:start',
      'test.async:finish',
    ]);
  });

  test('profiling helper reports finish when a span throws', () {
    final events = <ProfilingEvent>[];

    expect(
      () => Profiling.capture(events.add, () {
        return Profiling.spanSync('test.throw', () {
          throw StateError('boom');
        });
      }),
      throwsStateError,
    );

    expect(events.map((event) => '${event.name}:${event.kind.name}'), [
      'test.throw:start',
      'test.throw:finish',
    ]);
  });

  test('profiling helper reports finish when an async span throws', () async {
    final events = <ProfilingEvent>[];

    await expectLater(
      Profiling.captureAsync(events.add, () {
        return Profiling.spanAsync('test.async_throw', () async {
          throw StateError('async boom');
        });
      }),
      throwsStateError,
    );

    expect(events.map((event) => '${event.name}:${event.kind.name}'), [
      'test.async_throw:start',
      'test.async_throw:finish',
    ]);
  });
}
