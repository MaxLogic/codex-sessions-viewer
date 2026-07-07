import 'package:codex_sessions_viewer/src/export/eval_dataset_exporter.dart';
import 'package:codex_sessions_viewer/src/ui/models/session_row_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/screens/evals_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'reviews eval-ready sessions and exports selected or filtered rows',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final updates = <SessionEvalMetadata>[];
      final exports = <EvalsScreenExportRequest>[];
      await tester.pumpWidget(
        MaterialApp(
          home: EvalsScreen(
            initialRows: [
              _row(
                id: 'parser',
                title: 'Parser regression',
                status: 'needs_review',
                tags: const ['parser', 'jsonl'],
                notes: 'Check malformed JSONL.',
                expectedOutput: 'Graceful parse error.',
              ),
              _row(
                id: 'cache',
                title: 'Cache answer',
                status: 'correct',
                project: 'Runtime',
                platform: SessionRowPlatform.wsl,
                model: 'gpt-5-mini',
                tags: const ['cache'],
              ),
              _row(id: 'unmarked', title: 'Unmarked session', evalReady: false),
            ],
            onUpdateEvalMetadata: (row, metadata) async {
              updates.add(metadata);
            },
            onExport: (request) async {
              exports.add(request);
              return EvalsScreenExportResult.completed(
                exportedCount: request.rows.length,
              );
            },
          ),
        ),
      );

      expect(find.bySemanticsLabel('Evals, 2 visible'), findsOneWidget);
      expect(find.text('Parser regression'), findsOneWidget);
      expect(find.text('Cache answer'), findsOneWidget);
      expect(find.text('Unmarked session'), findsNothing);
      expect(find.byType(ListView), findsOneWidget);

      for (final label in [
        'Evals text filter',
        'Eval status filter',
        'Eval tags filter',
        'Eval source filter',
        'Eval project filter',
        'Eval model provider filter',
        'Eval export format',
        'Eval turn mode',
        'Anonymize paths in eval export',
      ]) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }

      await tester.tap(find.bySemanticsLabel('Eval status filter'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Correct').last);
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Evals, 1 visible'), findsOneWidget);
      expect(find.text('Cache answer'), findsOneWidget);
      expect(find.text('Parser regression'), findsNothing);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.bySemanticsLabel('Evals text filter'),
        'parser',
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Evals, 1 visible'), findsOneWidget);
      expect(find.text('Parser regression'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Select eval Parser regression'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.bySemanticsLabel('Edit review for Parser regression'),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.bySemanticsLabel('Eval review status'),
        'incorrect',
      );
      await tester.enterText(
        find.bySemanticsLabel('Eval notes'),
        'Mismatch against expected parse error.',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(updates.single.status, 'incorrect');
      expect(updates.single.notes, 'Mismatch against expected parse error.');
      expect(find.text('Incorrect'), findsOneWidget);
      expect(find.text('Notes'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Export selected eval sessions'));
      await tester.pumpAndSettle();
      expect(exports.single.scope, EvalsScreenExportScope.selected);
      expect(exports.single.rows.single.id, 'parser');
      expect(exports.single.format, EvalDatasetFormat.deepEvalJson);
      expect(exports.single.turnMode, EvalTurnMode.fullConversation);
      expect(exports.single.options.anonymizePaths, isTrue);

      await tester.tap(
        find.bySemanticsLabel('Export all filtered eval sessions'),
      );
      await tester.pumpAndSettle();
      expect(exports.last.scope, EvalsScreenExportScope.filtered);
      expect(exports.last.rows.map((row) => row.id), ['parser']);
    },
  );

  testWidgets('empty state points users back to Sessions marking', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: EvalsScreen(initialRows: [])),
    );

    expect(find.text('No eval-ready sessions yet'), findsOneWidget);
    expect(
      find.text('Mark sessions from Sessions view to review them here.'),
      findsOneWidget,
    );
  });

  testWidgets('export feedback distinguishes cancellation and skipped rows', (
    tester,
  ) async {
    final results = [
      const EvalsScreenExportResult.cancelled(),
      const EvalsScreenExportResult.completed(
        exportedCount: 0,
        skippedCount: 1,
      ),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EvalsScreen(
            initialRows: [_row(id: 'parser', title: 'Parser regression')],
            onExport: (request) async => results.removeAt(0),
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Select eval Parser regression'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Export selected eval sessions'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Prepared'), findsNothing);
    expect(find.textContaining('Exported'), findsNothing);

    await tester.tap(find.bySemanticsLabel('Export selected eval sessions'));
    await tester.pumpAndSettle();

    expect(find.text('Exported 0 eval sessions. 1 skipped.'), findsOneWidget);
  });
}

SessionRowViewModel _row({
  required String id,
  required String title,
  String status = 'not_reviewed',
  String project = 'Codex Viewer',
  SessionRowPlatform platform = SessionRowPlatform.windows,
  String model = 'gpt-5',
  List<String> tags = const [],
  String notes = '',
  String expectedOutput = '',
  bool evalReady = true,
}) {
  return SessionRowViewModel(
    id: id,
    sessionId: id,
    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
    lastMessageAtUtc: DateTime.utc(2026, 6, 12, 9, 5),
    title: title,
    summary: '$title summary',
    project: project,
    path: r'F:\projects\MaxLogic\codex-sessions-viewer',
    platform: platform,
    messageCount: 4,
    totalTokens: 1200,
    model: model,
    tags: tags,
    status: 'Parsed',
    evalReady: evalReady,
    evalStatus: status,
    evalNotes: notes,
    evalExpectedOutput: expectedOutput,
  );
}
