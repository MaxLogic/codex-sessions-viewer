import 'dart:async';
import 'dart:developer' as developer;

enum ProfilingEventKind { start, finish, instant }

class ProfilingEvent {
  const ProfilingEvent({
    required this.name,
    required this.kind,
    this.arguments = const {},
  });

  final String name;
  final ProfilingEventKind kind;
  final Map<String, Object?> arguments;
}

typedef ProfilingEventSink = void Function(ProfilingEvent event);

class Profiling {
  static ProfilingEventSink? _eventSink;

  static T capture<T>(ProfilingEventSink sink, T Function() action) {
    final previous = _eventSink;
    _eventSink = sink;
    try {
      return action();
    } finally {
      _eventSink = previous;
    }
  }

  static Future<T> captureAsync<T>(
    ProfilingEventSink sink,
    FutureOr<T> Function() action,
  ) async {
    final previous = _eventSink;
    _eventSink = sink;
    try {
      return await Future<T>.sync(action);
    } finally {
      _eventSink = previous;
    }
  }

  static T spanSync<T>(
    String name,
    T Function() action, {
    Map<String, Object?> arguments = const {},
  }) {
    _emit(name, ProfilingEventKind.start, arguments);
    try {
      return developer.Timeline.timeSync(
        name,
        action,
        arguments: _timelineArguments(arguments),
      );
    } finally {
      _emit(name, ProfilingEventKind.finish, arguments);
    }
  }

  static Future<T> spanAsync<T>(
    String name,
    FutureOr<T> Function() action, {
    Map<String, Object?> arguments = const {},
  }) async {
    final task = developer.TimelineTask();
    _emit(name, ProfilingEventKind.start, arguments);
    task.start(name, arguments: _timelineArguments(arguments));
    try {
      return await Future<T>.sync(action);
    } finally {
      task.finish();
      _emit(name, ProfilingEventKind.finish, arguments);
    }
  }

  static void instant(
    String name, {
    Map<String, Object?> arguments = const {},
  }) {
    developer.Timeline.instantSync(
      name,
      arguments: _timelineArguments(arguments),
    );
    _emit(name, ProfilingEventKind.instant, arguments);
  }

  static void _emit(
    String name,
    ProfilingEventKind kind,
    Map<String, Object?> arguments,
  ) {
    _eventSink?.call(
      ProfilingEvent(
        name: name,
        kind: kind,
        arguments: Map.unmodifiable(arguments),
      ),
    );
  }

  static Map<Object?, Object?>? _timelineArguments(
    Map<String, Object?> arguments,
  ) => arguments.isEmpty ? null : arguments;
}
