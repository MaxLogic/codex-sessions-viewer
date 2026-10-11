import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/platform/app_locations.dart';
import 'package:codex_sessions_viewer/src/voice_over/process_voice_over.dart';
import 'package:codex_sessions_viewer/src/voice_over/voice_over_service.dart';
import 'package:codex_sessions_viewer/src/voice_over/windows_voice_over.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('macOS uses afplay with the cue path as one literal argument', () async {
    final calls = <(String, List<String>)>[];
    final player = createVoiceOverPlayer(
      platform: AppHostPlatform.macos,
      startProcess: (executable, arguments) async {
        calls.add((executable, arguments));
        return FakePlaybackProcess.completed(0);
      },
    );
    const path = "/tmp/sound dir/O'Brien;\$HOME & cue.wav";

    expect(await player.play(path), isTrue);
    expect(calls, hasLength(1));
    expect(calls.single.$1, 'afplay');
    expect(calls.single.$2, [path]);
  });

  for (final firstResult in [0, 1, null]) {
    test('Linux fallback after paplay result $firstResult', () async {
      final calls = <String>[];
      final player = createVoiceOverPlayer(
        platform: AppHostPlatform.linux,
        startProcess: (command, arguments) async {
          calls.add(command);
          expect(arguments, ['/tmp/cue.wav']);
          if (command == 'paplay') {
            if (firstResult == null) throw ProcessException(command, arguments);
            return FakePlaybackProcess.completed(firstResult);
          }
          return FakePlaybackProcess.completed(0);
        },
      );
      expect(await player.play('/tmp/cue.wav'), isTrue);
      expect(calls, firstResult == 0 ? ['paplay'] : ['paplay', 'aplay']);
    });
  }

  for (final platform in [AppHostPlatform.macos, AppHostPlatform.linux]) {
    for (final unavailable in [false, true]) {
      test(
        '$platform failed/unavailable=$unavailable announces once',
        () async {
          final directory = await Directory.systemTemp.createTemp('cxv153-');
          addTearDown(() => directory.delete(recursive: true));
          final cue = await File(
            p.join(directory.path, 'cue.wav'),
          ).writeAsBytes([0]);
          final announcer = RecordingVoiceOverAnnouncer();
          final service = createVoiceOverService(
            VoiceOverSettings(
              enabled: true,
              preferWav: true,
              fallbackToScreenReader: true,
              events: {
                'copied': VoiceOverEventSettings(text: 'Copied', wav: cue.path),
              },
            ),
            platform: platform,
            announcer: announcer,
            startProcess: (command, arguments) async {
              if (unavailable) throw ProcessException(command, arguments);
              return FakePlaybackProcess.completed(1);
            },
          );

          await service.staticEvent(VoiceOverStaticEvent.copied);
          expect(announcer.messages, ['Copied']);
        },
      );
    }
  }

  test(
    'production service success and missing assets retain fallback rules',
    () async {
      final directory = await Directory.systemTemp.createTemp('cxv153-');
      addTearDown(() => directory.delete(recursive: true));
      final cue = await File(
        p.join(directory.path, 'cue.wav'),
      ).writeAsBytes([0]);
      final announcer = RecordingVoiceOverAnnouncer();
      final calls = <String>[];
      final service = createVoiceOverService(
        VoiceOverSettings(
          enabled: true,
          preferWav: true,
          fallbackToScreenReader: true,
          events: {
            'copied': VoiceOverEventSettings(text: 'Copied', wav: cue.path),
            'parse_error': VoiceOverEventSettings(
              text: 'Parse error',
              wav: p.join(directory.path, 'missing.wav'),
            ),
          },
        ),
        platform: AppHostPlatform.linux,
        announcer: announcer,
        startProcess: (command, arguments) async {
          calls.add(command);
          return FakePlaybackProcess.completed(0);
        },
      );
      await service.staticEvent(VoiceOverStaticEvent.copied);
      expect(announcer.messages, isEmpty);
      await service.staticEvent(VoiceOverStaticEvent.parseError);
      expect(calls, ['paplay']);
      expect(announcer.messages, ['Parse error']);
    },
  );

  test('Windows factory retains native PlaySound player', () {
    final player = createVoiceOverPlayer(
      platform: AppHostPlatform.windows,
      startProcess: (_, _) async => throw StateError('must not launch'),
    );
    expect(player, isA<WindowsWavPlayer>());
  });

  test('unsupported player returns failure for text fallback', () async {
    expect(await const UnsupportedWavPlayer().play('/tmp/cue.wav'), isFalse);
  });

  testWidgets('hung playback is killed and Linux tries the next player', (
    tester,
  ) async {
    final hung = FakePlaybackProcess();
    final calls = <String>[];
    final player = ProcessWavPlayer(
      commands: const ['paplay', 'aplay'],
      startProcess: (command, arguments) async {
        calls.add(command);
        return command == 'paplay' ? hung : FakePlaybackProcess.completed(0);
      },
    );
    final playback = player.play('/tmp/cue.wav');
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    expect(await playback, isTrue);
    expect(hung.killed, isTrue);
    expect(calls, ['paplay', 'aplay']);
  });

  testWidgets(
    'late startup after timeout is reaped without affecting a newer cue',
    (tester) async {
      final late = Completer<Process>();
      final oldProcess = FakePlaybackProcess();
      final currentProcess = FakePlaybackProcess();
      final player = ProcessWavPlayer(
        commands: const ['afplay'],
        startProcess: (command, arguments) {
          if (arguments.single == 'old.wav') return late.future;
          return Future.value(currentProcess);
        },
      );
      final old = player.play('old.wav');
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      expect(await old, isFalse);
      final current = player.play('current.wav');
      await tester.pump();
      late.complete(oldProcess);
      await tester.pump();
      expect(oldProcess.killed, isTrue);
      expect(currentProcess.killed, isFalse);
      currentProcess.completion.complete(0);
      await tester.pump();
      expect(await current, isTrue);
    },
  );

  test(
    'replacement suppresses stale fallback but newest failure is reported',
    () async {
      final late = Completer<Process>();
      final oldProcess = FakePlaybackProcess();
      final currentProcess = FakePlaybackProcess();
      final player = ProcessWavPlayer(
        commands: const ['paplay', 'aplay'],
        startProcess: (command, arguments) {
          if (arguments.single == 'old.wav') return late.future;
          return Future.value(
            command == 'paplay'
                ? currentProcess
                : FakePlaybackProcess.completed(1),
          );
        },
      );
      final old = player.play('old.wav');
      final current = player.play('current.wav');
      late.complete(oldProcess);
      await Future<void>.delayed(Duration.zero);
      expect(oldProcess.killed, isTrue);
      expect(await old, isTrue);
      expect(currentProcess.killed, isFalse);
      currentProcess.completion.complete(1);
      expect(await current, isFalse);
    },
  );

  test('new cue kills an already playing cue', () async {
    final oldProcess = FakePlaybackProcess();
    final ready = Completer<void>();
    final player = ProcessWavPlayer(
      commands: const ['afplay'],
      startProcess: (command, arguments) async {
        if (arguments.single == 'old.wav') {
          ready.complete();
          return oldProcess;
        }
        return FakePlaybackProcess.completed(0);
      },
    );
    final old = player.play('old.wav');
    await ready.future;
    await Future<void>.delayed(Duration.zero);
    expect(await player.play('new.wav'), isTrue);
    expect(oldProcess.killed, isTrue);
    expect(await old, isTrue);
  });

  testWidgets(
    'late timed-out paplay preserves active aplay replacement ownership',
    (tester) async {
      final latePaplay = Completer<Process>();
      final paplayChild = FakePlaybackProcess();
      final aplayChild = FakePlaybackProcess();
      final calls = <String>[];
      final player = ProcessWavPlayer(
        commands: const ['paplay', 'aplay'],
        startProcess: (command, arguments) {
          calls.add('${arguments.single}:$command');
          if (arguments.single == 'old.wav') {
            return command == 'paplay'
                ? latePaplay.future
                : Future.value(aplayChild);
          }
          // The replacement actually fails, so only its text must be spoken.
          return Future.value(FakePlaybackProcess.completed(1));
        },
      );
      final announcer = RecordingVoiceOverAnnouncer();
      final service = VoiceOverService(
        settings: const VoiceOverSettings(
          enabled: true,
          preferWav: true,
          fallbackToScreenReader: true,
          events: {
            'copied': VoiceOverEventSettings(text: 'Copied', wav: 'old.wav'),
            'export_finished': VoiceOverEventSettings(
              text: 'Export finished',
              wav: 'new.wav',
            ),
          },
        ),
        player: player,
        announcer: announcer,
        wavExists: (_) async => true,
      );
      addTearDown(() {
        if (!aplayChild.completion.isCompleted) {
          aplayChild.completion.complete(0);
        }
      });
      final old = service.staticEvent(VoiceOverStaticEvent.copied);
      await tester.pump();
      await tester.pump(const Duration(seconds: 31));
      expect(calls, ['old.wav:paplay', 'old.wav:aplay']);
      expect(aplayChild.killed, isFalse);

      latePaplay.complete(paplayChild);
      await tester.pump();
      expect(paplayChild.killed, isTrue);
      expect(aplayChild.killed, isFalse);

      final replacement = service.staticEvent(
        VoiceOverStaticEvent.exportFinished,
      );
      await tester.pump();
      expect(
        aplayChild.killed,
        isTrue,
        reason: 'The replacement must stop the still-playing fallback child',
      );
      await replacement;
      await old;
      expect(announcer.messages, ['Export finished']);
      expect(calls, [
        'old.wav:paplay',
        'old.wav:aplay',
        'new.wav:paplay',
        'new.wav:aplay',
      ]);
    },
  );
}

class FakePlaybackProcess implements Process {
  FakePlaybackProcess();

  FakePlaybackProcess.completed(int code) {
    completion.complete(code);
  }

  final completion = Completer<int>();
  bool killed = false;

  @override
  Future<int> get exitCode => completion.future;

  @override
  Stream<List<int>> get stdout => Stream.value(utf8.encode('output'));

  @override
  Stream<List<int>> get stderr => Stream.value(utf8.encode('diagnostic'));

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!completion.isCompleted) completion.complete(-1);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
