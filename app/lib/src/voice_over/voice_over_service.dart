import '../config/app_settings.dart';

enum VoiceOverStaticEvent {
  scanStarted('scan_started'),
  scanFinished('scan_finished'),
  copied('copied'),
  exportFinished('export_finished'),
  parseError('parse_error'),
  databaseError('database_error');

  const VoiceOverStaticEvent(this.settingsKey);

  final String settingsKey;
}

abstract interface class VoiceOverPlayer {
  Future<bool> play(String wavPath);
}

abstract interface class VoiceOverAnnouncer {
  Future<void> announce(String message);
}

class RecordingVoiceOverPlayer implements VoiceOverPlayer {
  RecordingVoiceOverPlayer({required this.playResult});

  final bool playResult;
  final played = <String>[];

  @override
  Future<bool> play(String wavPath) async {
    played.add(wavPath);
    return playResult;
  }
}

class RecordingVoiceOverAnnouncer implements VoiceOverAnnouncer {
  final messages = <String>[];

  @override
  Future<void> announce(String message) async {
    messages.add(message);
  }
}

class VoiceOverService {
  const VoiceOverService({
    required this.settings,
    required this.player,
    required this.announcer,
    required this.wavExists,
  });

  final VoiceOverSettings settings;
  final VoiceOverPlayer player;
  final VoiceOverAnnouncer announcer;
  final Future<bool> Function(String wavPath) wavExists;

  Future<void> staticEvent(VoiceOverStaticEvent event) async {
    final eventSettings = settings.events[event.settingsKey];
    final text = eventSettings?.text ?? event.settingsKey;
    final wav = eventSettings?.wav ?? '';
    if (settings.enabled && settings.preferWav && wav.isNotEmpty) {
      final exists = await wavExists(wav);
      if (exists && await player.play(wav)) {
        return;
      }
    }
    if (settings.fallbackToScreenReader) {
      await announcer.announce(text);
    }
  }

  Future<void> dynamicAnnouncement(String message) async {
    await announcer.announce(message);
  }
}
