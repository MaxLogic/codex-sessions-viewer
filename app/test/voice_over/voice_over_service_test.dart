import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/voice_over/voice_over_service.dart';
import 'package:flutter_test/flutter_test.dart';

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

    expect(player.played, [r'assets\voice\copied.wav']);
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

    expect(player.played, [r'assets\voice\export_finished.wav']);
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
