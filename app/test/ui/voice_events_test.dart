import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/voice_over/voice_over_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<List<VoiceOverStaticEvent>> run(
    WidgetTester tester, {
    required String finishedMessage,
    required Future<void> Function() trigger,
    int autoRefreshToken = 0,
  }) async {
    final events = <VoiceOverStaticEvent>[];
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionsScreen(
            autoRefreshToken: autoRefreshToken,
            onRefreshResult: () async => SessionsRefreshResult(
              rows: const [],
              statusMessage: finishedMessage,
            ),
            onVoiceEvent: events.add,
          ),
        ),
      ),
    );
    await trigger();
    await tester.pumpAndSettle();
    return events;
  }

  testWidgets('a refresh the user starts plays start and finish', (
    tester,
  ) async {
    final events = await run(
      tester,
      finishedMessage: 'Scan finished. 0 sessions available.',
      trigger: () => tester.tap(find.text('Refresh')),
    );
    expect(events, [
      VoiceOverStaticEvent.scanStarted,
      VoiceOverStaticEvent.scanFinished,
    ]);
  });

  testWidgets('F5 reports parse errors instead of a plain finish', (
    tester,
  ) async {
    final events = await run(
      tester,
      finishedMessage: 'Scan finished. 2 files could not be parsed.',
      trigger: () async {
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.f5);
      },
    );
    expect(events, [
      VoiceOverStaticEvent.scanStarted,
      VoiceOverStaticEvent.parseError,
    ]);
  });

  testWidgets('automatic refreshes stay quiet', (tester) async {
    final events = await run(
      tester,
      finishedMessage: 'Scan finished.',
      autoRefreshToken: 1,
      trigger: () async {
        await tester.pump();
      },
    );
    expect(events, isEmpty);
  });
}
