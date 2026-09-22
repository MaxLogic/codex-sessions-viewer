import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter/semantics.dart';

import '../accessibility/announcement_service.dart';
import '../config/app_settings.dart';
import 'voice_over_service.dart';

// PlaySound flags from mmsystem.h.
const _sndAsync = 0x0001;
const _sndNoDefault = 0x0002;
const _sndFilename = 0x00020000;

typedef _PlaySoundNative =
    Int32 Function(Pointer<Utf16> sound, IntPtr module, Uint32 flags);
typedef _PlaySoundDart =
    int Function(Pointer<Utf16> sound, int module, int flags);

/// Plays a WAV file asynchronously with the Windows `PlaySound` API, so a
/// sound never blocks the UI thread.
class WindowsWavPlayer implements VoiceOverPlayer {
  WindowsWavPlayer();

  _PlaySoundDart? _playSound;

  _PlaySoundDart? _load() {
    if (!Platform.isWindows) {
      return null;
    }
    return _playSound ??= DynamicLibrary.open(
      'winmm.dll',
    ).lookupFunction<_PlaySoundNative, _PlaySoundDart>('PlaySoundW');
  }

  @override
  Future<bool> play(String wavPath) async {
    final playSound = _load();
    if (playSound == null) {
      return false;
    }
    final path = File(wavPath).absolute.path.toNativeUtf16();
    try {
      return playSound(path, 0, _sndFilename | _sndAsync | _sndNoDefault) != 0;
    } finally {
      malloc.free(path);
    }
  }
}

/// Speaks a message through the active screen reader.
class SemanticsAnnouncer implements VoiceOverAnnouncer, ScreenReaderAnnouncer {
  const SemanticsAnnouncer();

  @override
  Future<void> announce(String message) async {
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) {
      return;
    }
    await SemanticsService.sendAnnouncement(
      views.first,
      message,
      TextDirection.ltr,
    );
  }
}

/// Builds the production voice-over service for the given settings. WAV
/// paths are relative to the executable directory, which is the working
/// directory of the packaged app.
VoiceOverService createVoiceOverService(
  VoiceOverSettings settings, {
  VoiceOverPlayer? player,
  VoiceOverAnnouncer? announcer,
}) {
  return VoiceOverService(
    settings: settings,
    player: player ?? WindowsWavPlayer(),
    announcer: announcer ?? const SemanticsAnnouncer(),
    wavExists: (path) => File(path).exists(),
  );
}
