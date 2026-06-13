import 'package:codex_sessions_viewer/src/accessibility/announcement_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'announces required state changes with dynamic text where needed',
    () async {
      final announcer = RecordingScreenReaderAnnouncer();
      final service = AnnouncementService(announcer: announcer);

      await service.scanStarted();
      await service.scanFinished(found: 12, changed: 3, failed: 1);
      await service.refreshStarted();
      await service.refreshFinished(visibleCount: 7);
      await service.filterApplied(visibleCount: 4);
      await service.commandCopied('Plain resume command copied.');
      await service.pathCopied();
      await service.messageCopied();
      await service.parseError(count: 2);
      await service.databaseError('SQLite FTS5 is unavailable.');

      expect(announcer.messages, [
        'Scanning started',
        'Scan finished. 12 sessions found, 3 changed, 1 failed.',
        'Refresh started',
        'Refresh finished. 7 sessions visible.',
        'Filter applied. 4 sessions visible.',
        'Plain resume command copied.',
        'Path copied.',
        'Message copied.',
        '2 sessions could not be parsed.',
        'Database error. SQLite FTS5 is unavailable.',
      ]);
    },
  );
}
