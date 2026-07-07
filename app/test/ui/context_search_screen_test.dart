import 'package:codex_sessions_viewer/src/search/message_search.dart';
import 'package:codex_sessions_viewer/src/ui/models/session_row_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/screens/context_search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('searches messages and copies or opens selected context', (
    tester,
  ) async {
    final copied = <String>[];
    final opened = <ContextOpenRequest>[];
    final searchedQueries = <String>[];

    await tester.binding.setSurfaceSize(const Size(1200, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContextSearchScreen(
            initialSessionRows: [
              _row(id: 'parser', title: 'Parser regression'),
              _row(id: 'usage', title: 'Usage notes', project: 'Usage'),
            ],
            onSearchMessages: (query) async {
              searchedQueries.add(query.text);
              return [
                MessageSearchResult(
                  sessionId: 'parser',
                  messageIndex: 2,
                  author: 'assistant',
                  snippet:
                      'The <mark>cache</mark> needle is in this assistant reply.',
                  sessionIdentity: 'Parser regression',
                  sessionTitle: 'Parser regression',
                  projectName: 'Codex Viewer',
                  sourceType: 'wsl',
                  timestampUtc: DateTime.utc(2026, 7, 7, 10, 5),
                ),
              ];
            },
            onCopyContext: (text) async {
              copied.add(text);
            },
            onOpenResult: (request) async {
              opened.add(request);
            },
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Context Search, 0 results'), findsOneWidget);
    expect(find.bySemanticsLabel('Context search mode'), findsOneWidget);
    expect(find.bySemanticsLabel('Context query'), findsOneWidget);
    expect(find.bySemanticsLabel('Search context'), findsOneWidget);
    expect(find.byType(ListView), findsNothing);

    await tester.enterText(find.bySemanticsLabel('Context query'), 'cache');
    await tester.tap(find.bySemanticsLabel('Search context'));
    await tester.pumpAndSettle();

    expect(searchedQueries, ['cache']);
    expect(find.bySemanticsLabel('Context Search, 1 result'), findsOneWidget);
    expect(find.byType(ListView), findsOneWidget);
    expect(find.text('Parser regression'), findsWidgets);
    expect(find.text('Assistant'), findsOneWidget);
    expect(find.text('Codex Viewer'), findsOneWidget);
    expect(find.text('WSL'), findsOneWidget);
    expect(find.text('2026-07-07 10:05 UTC'), findsOneWidget);

    await tester.tap(
      find.bySemanticsLabel(
        'Select context result Parser regression message 2',
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Copy selected context results'));
    await tester.pumpAndSettle();

    expect(copied.single, contains('Parser regression'));
    expect(copied.single, contains('cache needle'));
    expect(copied.single, contains('2026-07-07 10:05 UTC'));
    expect(find.text('Copied 1 context result.'), findsOneWidget);

    await tester.tap(
      find.bySemanticsLabel('Open context result Parser regression message 2'),
    );
    await tester.pumpAndSettle();

    expect(opened.single.sessionId, 'parser');
    expect(opened.single.messageIndex, 2);
  });

  testWidgets('searches sessions and opens a session result', (tester) async {
    final opened = <ContextOpenRequest>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContextSearchScreen(
            initialSessionRows: [
              _row(id: 'parser', title: 'Parser regression'),
              _row(id: 'usage', title: 'Usage notes', project: 'Usage'),
            ],
            onSearchMessages: (_) async => const [],
            onOpenResult: (request) async {
              opened.add(request);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Sessions'));
    await tester.pumpAndSettle();
    await tester.enterText(find.bySemanticsLabel('Context query'), 'parser');
    await tester.tap(find.bySemanticsLabel('Search context'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Context Search, 1 result'), findsOneWidget);
    expect(find.text('Parser regression'), findsOneWidget);
    expect(find.text('Usage notes'), findsNothing);

    await tester.tap(
      find.bySemanticsLabel('Open context result Parser regression'),
    );
    await tester.pumpAndSettle();

    expect(opened.single.sessionId, 'parser');
    expect(opened.single.messageIndex, isNull);
  });
}

SessionRowViewModel _row({
  required String id,
  required String title,
  String project = 'Codex Viewer',
  SessionRowPlatform platform = SessionRowPlatform.windows,
}) {
  return SessionRowViewModel(
    id: id,
    sessionId: id,
    startedAtUtc: DateTime.utc(2026, 7, 7, 9),
    lastMessageAtUtc: DateTime.utc(2026, 7, 7, 10),
    title: title,
    summary: '$title summary with context',
    project: project,
    path: r'F:\projects\MaxLogic\codex-sessions-viewer',
    platform: platform,
    messageCount: 4,
    totalTokens: 1200,
    model: 'gpt-5',
    tags: const ['context'],
    status: 'Parsed',
  );
}
