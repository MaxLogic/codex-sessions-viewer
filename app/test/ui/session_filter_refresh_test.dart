import 'dart:async';

import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('defaults to active sessions and preserves filters on refresh', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final refresh = Completer<List<SessionRowViewModel>>();
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(id: 'keep', title: 'Keep selected', project: 'Viewer'),
            _row(id: 'other', title: 'Other active', project: 'Viewer'),
            _row(
              id: 'archived',
              title: 'Archived selected',
              project: 'Archive',
              isArchived: true,
            ),
          ],
          onRefresh: () => refresh.future,
        ),
      ),
    );

    expect(find.text('2 sessions visible'), findsOneWidget);
    expect(find.text('Archived selected'), findsNothing);

    await tester.enterText(find.bySemanticsLabel('Session search'), 'Other');
    await tester.pumpAndSettle();
    expect(find.text('1 session visible'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
    await tester.pumpAndSettle();
    expect(find.text('2 sessions visible'), findsOneWidget);

    await tester.enterText(find.bySemanticsLabel('Session search'), 'Keep');
    await tester.pumpAndSettle();
    expect(find.text('1 session visible'), findsOneWidget);

    await tester.tap(find.text('Keep selected'));
    await tester.pumpAndSettle();
    expect(find.text('Selected: Keep selected'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Refresh'));
    await tester.pump();
    expect(find.widgetWithText(ElevatedButton, 'Scanning...'), findsOneWidget);
    expect(find.text('Scanning started'), findsOneWidget);

    refresh.complete([
      _row(id: 'keep', title: 'Keep selected updated', project: 'Viewer'),
      _row(id: 'new', title: 'New active', project: 'Viewer'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Keep'), findsOneWidget);
    expect(find.text('1 session visible'), findsOneWidget);
    expect(find.text('Keep selected updated'), findsWidgets);
    expect(find.text('Selected: Keep selected updated'), findsOneWidget);
    expect(find.text('Scan finished. 2 sessions found.'), findsOneWidget);
  });

  testWidgets('shows refresh progress and adds parsed rows before completion', (
    tester,
  ) async {
    final refresh = Completer<SessionsRefreshResult>();
    SessionsRefreshProgressCallback? progressCallback;
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          onRefreshWithProgress: (onProgress) {
            progressCallback = onProgress;
            return refresh.future;
          },
        ),
      ),
    );

    await tester.tap(find.widgetWithText(ElevatedButton, 'Refresh'));
    await tester.pump();
    expect(find.widgetWithText(ElevatedButton, 'Scanning...'), findsOneWidget);

    progressCallback!(
      SessionsRefreshProgress(
        rows: [
          _row(id: 'parsed', title: 'Parsed while scanning', project: 'Viewer'),
        ],
        statusMessage:
            'Scanning... scanned 3 directories, found 5 JSON files, skipped 0 unchanged files, parsed 1 changed JSON file, found 1 valid session, failed to parse 0 files, estimated progress 20%, ETA calculating.',
      ),
    );
    await tester.pump();

    expect(find.text('Parsed while scanning'), findsWidgets);
    expect(find.text('1 session visible'), findsOneWidget);
    expect(find.textContaining('scanned 3 directories'), findsOneWidget);
    expect(find.textContaining('estimated progress 20%'), findsOneWidget);

    refresh.complete(
      SessionsRefreshResult.scanFinished([
        _row(id: 'parsed', title: 'Parsed while scanning', project: 'Viewer'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ElevatedButton, 'Refresh'), findsOneWidget);
  });

  testWidgets('large session lists are rendered lazily', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            for (var i = 0; i < 5000; i++)
              _row(id: 'row-$i', title: 'Session $i', project: 'Viewer'),
          ],
        ),
      ),
    );

    expect(find.text('5000 sessions visible'), findsOneWidget);
    expect(find.text('Session 0'), findsWidgets);
    expect(find.text('Session 4999'), findsNothing);
  });

  testWidgets('loads selected conversation on demand', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loadCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(id: 'lazy', title: 'Lazy detail', project: 'Viewer'),
          ],
          onLoadSessionDetail: (id) async {
            loadCalls++;
            return _row(
              id: id,
              title: 'Lazy detail',
              project: 'Viewer',
              messages: [
                ConversationMessageViewModel(
                  id: 'msg-1',
                  number: 1,
                  author: ConversationAuthor.user,
                  createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                  preview: 'Prompt preview',
                  body: 'Prompt body loaded lazily',
                  tokenCount: 12,
                ),
              ],
            );
          },
        ),
      ),
    );

    expect(find.text('Prompt body loaded lazily'), findsNothing);

    await tester.tap(find.text('Lazy detail').first);
    await tester.pumpAndSettle();

    expect(loadCalls, 1);
    expect(find.text('Prompt body loaded lazily'), findsWidgets);
  });
}

SessionRowViewModel _row({
  required String id,
  required String title,
  required String project,
  bool isArchived = false,
  List<ConversationMessageViewModel> messages = const [],
}) {
  return SessionRowViewModel(
    id: id,
    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
    lastMessageAtUtc: DateTime.utc(2026, 6, 12, 10),
    platform: SessionRowPlatform.windows,
    project: project,
    path: r'F:\projects\MaxLogic\codex-sessions-viewer',
    title: title,
    summary: 'Session summary',
    messageCount: 3,
    totalTokens: 900,
    model: 'gpt-5.4',
    tags: const ['ui'],
    status: 'Available',
    isArchived: isArchived,
    conversationMessages: messages,
  );
}
