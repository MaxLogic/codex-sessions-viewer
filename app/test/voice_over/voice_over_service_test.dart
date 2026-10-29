import 'dart:io';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/platform/app_locations.dart';
import 'package:codex_sessions_viewer/src/voice_over/voice_over_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('plays configured static WAV when enabled and available', () async {
    final player = RecordingVoiceOverPlayer(playResult: true);
    final announcer = RecordingVoiceOverAnnouncer();
    final service = VoiceOverService(
      settings: AppSettings.defaults().voiceOver,
      player: player,
      announcer: announcer,
      wavExists: (_) async => true,
    );

    await service.staticEvent(VoiceOverStaticEvent.copied);

    expect(player.played, [_defaultWav('copied')]);
    expect(announcer.messages, isEmpty);
  });

  test('falls back to text when WAV is missing or fails', () async {
    final player = RecordingVoiceOverPlayer(playResult: false);
    final announcer = RecordingVoiceOverAnnouncer();
    final service = VoiceOverService(
      settings: AppSettings.defaults().voiceOver,
      player: player,
      announcer: announcer,
      wavExists: (_) async => true,
    );

    await service.staticEvent(VoiceOverStaticEvent.exportFinished);

    expect(player.played, [_defaultWav('export_finished')]);
    expect(announcer.messages, ['Export finished']);
  });

  test('dynamic announcements never play WAV files', () async {
    final player = RecordingVoiceOverPlayer(playResult: true);
    final announcer = RecordingVoiceOverAnnouncer();
    final service = VoiceOverService(
      settings: AppSettings.defaults().voiceOver,
      player: player,
      announcer: announcer,
      wavExists: (_) async => true,
    );

    await service.dynamicAnnouncement('Refresh finished. 9 sessions visible.');

    expect(player.played, isEmpty);
    expect(announcer.messages, ['Refresh finished. 9 sessions visible.']);
  });
}

/// Windows defaults name the WAV relative to the app folder; other platforms
/// use the bundled assets folder.
String _defaultWav(String event) => p.join(
  Platform.isWindows ? 'assets' : AppLocations.current().assetsDirectory.path,
  'voice',
  '$event.wav',
);
