import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('session detail edits eval metadata without a rescan', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    var refreshed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionsScreen(
            initialRows: [_row()],
            onRefresh: () async {
              refreshed = true;
              return [_row()];
            },
            onSessionAction: (request) async {
              actions.add(request);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Parser cache').first);
    await tester.pumpAndSettle();

    expect(find.text('Eval status: Not reviewed'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Add to Evals'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Add to Evals'));
    await tester.pumpAndSettle();

    expect(actions.single.action, SessionRowAction.updateEvalMetadata);
    expect(actions.single.evalMetadata?.evalReady, isTrue);
    expect(
      find.widgetWithText(OutlinedButton, 'Remove from Evals'),
      findsOneWidget,
    );
    expect(refreshed, isFalse);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Edit eval details'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.bySemanticsLabel('Eval review status'),
      'correct',
    );
    await tester.enterText(
      find.bySemanticsLabel('Eval notes'),
      'Covers cache invalidation',
    );
    await tester.enterText(
      find.bySemanticsLabel('Eval expected output'),
      'It invalidates cache.',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(actions.last.action, SessionRowAction.updateEvalMetadata);
    expect(actions.last.evalMetadata?.evalReady, isTrue);
    expect(actions.last.evalMetadata?.status, 'correct');
    expect(actions.last.evalMetadata?.notes, 'Covers cache invalidation');
    expect(actions.last.evalMetadata?.expectedOutput, 'It invalidates cache.');
    expect(actions.last.evalMetadata?.reviewedAtUtc, isNotNull);
    expect(find.text('Eval status: Correct'), findsOneWidget);
    expect(find.text('Notes: Covers cache invalidation'), findsOneWidget);
    expect(find.text('Expected output: It invalidates cache.'), findsOneWidget);
    expect(refreshed, isFalse);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Remove from Evals'));
    await tester.pumpAndSettle();

    expect(actions.last.evalMetadata?.evalReady, isFalse);
    expect(actions.last.evalMetadata?.status, isNull);
    expect(find.widgetWithText(OutlinedButton, 'Add to Evals'), findsOneWidget);
    expect(find.text('Eval status: Not reviewed'), findsOneWidget);
    expect(refreshed, isFalse);
  });

  testWidgets('unknown eval status renders as not reviewed', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionsScreen(
            initialRows: [_row(evalReady: true, evalStatus: 'mystery')],
          ),
        ),
      ),
    );

    await tester.tap(find.text('Parser cache').first);
    await tester.pumpAndSettle();

    expect(find.text('Eval status: Not reviewed'), findsOneWidget);
  });
}

SessionRowViewModel _row({bool evalReady = false, String evalStatus = ''}) {
  return SessionRowViewModel(
    id: 'active',
    sessionId: 'abc123',
    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
    lastMessageAtUtc: DateTime.utc(2026, 6, 12, 10),
    platform: SessionRowPlatform.windows,
    project: 'Codex Viewer',
    path: r'F:\projects\MaxLogic\codex-sessions-viewer',
    title: 'Parser cache',
    summary: 'Parser cache',
    messageCount: 7,
    totalTokens: 1200,
    model: 'gpt-5.4',
    tags: const ['parser'],
    status: 'Available',
    evalReady: evalReady,
    evalStatus: evalStatus,
  );
}
