abstract interface class ScreenReaderAnnouncer {
  Future<void> announce(String message);
}

class RecordingScreenReaderAnnouncer implements ScreenReaderAnnouncer {
  final messages = <String>[];

  @override
  Future<void> announce(String message) async {
    messages.add(message);
  }
}

class AnnouncementService {
  const AnnouncementService({required this.announcer});

  final ScreenReaderAnnouncer announcer;

  Future<void> scanStarted() => announcer.announce('Scanning started');

  Future<void> scanFinished({
    required int found,
    required int changed,
    required int failed,
  }) => announcer.announce(
    'Scan finished. $found sessions found, $changed changed, $failed failed.',
  );

  Future<void> refreshStarted() => announcer.announce('Refresh started');

  Future<void> refreshFinished({required int visibleCount}) =>
      announcer.announce('Refresh finished. $visibleCount sessions visible.');

  Future<void> filterApplied({required int visibleCount}) =>
      announcer.announce('Filter applied. $visibleCount sessions visible.');

  Future<void> commandCopied(String message) => announcer.announce(message);

  Future<void> pathCopied() => announcer.announce('Path copied.');

  Future<void> messageCopied() => announcer.announce('Message copied.');

  Future<void> parseError({required int count}) =>
      announcer.announce('$count sessions could not be parsed.');

  Future<void> databaseError(String summary) =>
      announcer.announce('Database error. $summary');
}
