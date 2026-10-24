import 'package:codex_sessions_viewer/src/platform/app_environment.dart';
import 'dart:async';
import 'dart:io';

import 'voice_over_service.dart';

typedef VoiceOverProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// Plays one cue at a time using a native audio command. A new cue replaces the
/// old one, matching Windows PlaySound's behavior. Commands run without a shell.
class ProcessWavPlayer implements VoiceOverPlayer {
  ProcessWavPlayer({
    required List<String> commands,
    VoiceOverProcessStarter? startProcess,
    this.playbackTimeout = const Duration(seconds: 30),
  }) : _commands = List.unmodifiable(commands),
       _startProcess = startProcess ?? _start;

  final List<String> _commands;
  final VoiceOverProcessStarter _startProcess;
  final Duration playbackTimeout;
  _Playback? _active;

  static Future<Process> _start(String command, List<String> arguments) =>
      AppEnvironment.start(command, arguments, runInShell: false);

  @override
  Future<bool> play(String wavPath) async {
    final previous = _active;
    if (previous != null) {
      previous.superseded = true;
      previous.process?.kill(ProcessSignal.sigkill);
    }
    final playback = _Playback();
    _active = playback;
    try {
      for (final command in _commands) {
        if (playback.superseded) return true;
        if (await _attempt(command, wavPath, playback)) return true;
      }
      // Replaced cues must not announce stale text over their replacement.
      return playback.superseded;
    } finally {
      if (identical(_active, playback)) _active = null;
    }
  }

  Future<bool> _attempt(
    String command,
    String wavPath,
    _Playback playback,
  ) async {
    Process? process;
    var expired = false;
    try {
      final started = _startProcess(command, [wavPath]).then((child) {
        // Process.start cannot be cancelled. Reap a child arriving after its
        // request timed out or was replaced, and still drain both pipes.
        if (expired || playback.superseded) child.kill(ProcessSignal.sigkill);
        return child;
      });
      final completed = started.then((child) async {
        process = child;
        // A late expired attempt must not steal ownership from a live fallback
        // or a replacing cue. It still owns its local cleanup and pipe drains.
        if (!expired && !playback.superseded) playback.process = child;
        final results = await Future.wait<Object?>([
          child.exitCode,
          child.stdout.drain<void>(),
          child.stderr.drain<void>(),
        ]);
        return results.first == 0;
      });
      return await completed.timeout(playbackTimeout);
    } on ProcessException {
      return false;
    } on TimeoutException {
      expired = true;
      process?.kill(ProcessSignal.sigkill);
      return false;
    } on IOException {
      process?.kill(ProcessSignal.sigkill);
      return false;
    } finally {
      if (identical(playback.process, process)) playback.process = null;
    }
  }
}

class _Playback {
  Process? process;
  bool superseded = false;
}

/// A false result makes VoiceOverService use its configured text fallback.
class UnsupportedWavPlayer implements VoiceOverPlayer {
  const UnsupportedWavPlayer();

  @override
  Future<bool> play(String wavPath) async => false;
}
