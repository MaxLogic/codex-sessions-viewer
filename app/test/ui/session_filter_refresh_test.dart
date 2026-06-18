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

    expect(find.bySemanticsLabel('Sessions, 2 visible'), findsOneWidget);
    expect(find.text('Archived selected'), findsNothing);

    await tester.enterText(find.bySemanticsLabel('Session search'), 'Other');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Sessions, 1 visible'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Sessions, 2 visible'), findsOneWidget);

    await tester.enterText(find.bySemanticsLabel('Session search'), 'Keep');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Sessions, 1 visible'), findsOneWidget);

    await tester.tap(find.text('Keep selected'));
    await tester.pumpAndSettle();
    expect(find.text('Selected: Keep selected'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Refresh'));
    await tester.pump();
    expect(find.widgetWithText(ElevatedButton, 'Cancel scan'), findsOneWidget);
    expect(find.text('Scanning started'), findsOneWidget);

    refresh.complete([
      _row(id: 'keep', title: 'Keep selected updated', project: 'Viewer'),
      _row(id: 'new', title: 'New active', project: 'Viewer'),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('Keep'), findsOneWidget);
    expect(find.bySemanticsLabel('Sessions, 1 visible'), findsOneWidget);
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
    expect(find.widgetWithText(ElevatedButton, 'Cancel scan'), findsOneWidget);

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
    expect(find.bySemanticsLabel('Sessions, 1 visible'), findsOneWidget);
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

  testWidgets(
    'refresh button cancels active scan without clearing cached rows',
    (tester) async {
      final refresh = Completer<SessionsRefreshResult>();
      var refreshCalls = 0;
      var cancelCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: SessionsScreen(
            initialRows: [
              _row(id: 'cached', title: 'Cached row', project: 'Viewer'),
            ],
            onRefreshOperation: (_) {
              refreshCalls++;
              return SessionsRefreshOperation(
                result: refresh.future,
                cancel: () {
                  cancelCalls++;
                  return refresh.future.then<void>((_) {});
                },
              );
            },
          ),
        ),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Refresh'));
      await tester.pump();

      expect(refreshCalls, 1);
      expect(find.text('Cached row'), findsWidgets);
      expect(
        find.widgetWithText(ElevatedButton, 'Cancel scan'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Cancel scan'));
      await tester.pump();

      expect(cancelCalls, 1);
      expect(refreshCalls, 1);
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'Cancelling scan...'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('Cached row'), findsWidgets);

      refresh.complete(
        SessionsRefreshResult(
          rows: [_row(id: 'cached', title: 'Cached row', project: 'Viewer')],
          statusMessage: 'Scan cancelled. 1 session visible.',
          cancelled: true,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ElevatedButton, 'Refresh'), findsOneWidget);
      expect(find.text('Scan cancelled. 1 session visible.'), findsOneWidget);
      expect(find.text('Cached row'), findsWidgets);
    },
  );

  testWidgets('dispose requests cancellation of an active scan', (
    tester,
  ) async {
    final refresh = Completer<SessionsRefreshResult>();
    var cancelCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          onRefreshOperation: (_) => SessionsRefreshOperation(
            result: refresh.future,
            cancel: () {
              cancelCalls++;
              return refresh.future.then<void>((_) {});
            },
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(ElevatedButton, 'Refresh'));
    await tester.pump();
    expect(find.widgetWithText(ElevatedButton, 'Cancel scan'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();

    expect(cancelCalls, 1);
    refresh.complete(
      const SessionsRefreshResult(
        rows: [],
        statusMessage: 'Scan cancelled.',
        cancelled: true,
      ),
    );
  });

  testWidgets('starts refresh when auto refresh token changes', (tester) async {
    var refreshCalls = 0;
    final refresh = Completer<SessionsRefreshResult>();

    Widget screen(int token) => MaterialApp(
      home: SessionsScreen(
        initialRows: [
          _row(id: 'cached', title: 'Cached row', project: 'Viewer'),
        ],
        autoRefreshToken: token,
        onRefreshWithProgress: (_) {
          refreshCalls++;
          return refresh.future;
        },
      ),
    );

    await tester.pumpWidget(screen(0));
    expect(refreshCalls, 0);

    await tester.pumpWidget(screen(1));
    await tester.pump();
    await tester.pump();

    expect(refreshCalls, 1);
    expect(find.widgetWithText(ElevatedButton, 'Cancel scan'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    refresh.complete(
      SessionsRefreshResult.scanFinished([
        _row(id: 'fresh', title: 'Fresh row', project: 'Viewer'),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('Fresh row'), findsWidgets);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });

  testWidgets('can show only the newest session per project', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(
              id: 'viewer-old',
              title: 'Older viewer session',
              project: 'Viewer',
              lastMessageAtUtc: DateTime.utc(2026, 6, 12, 9),
            ),
            _row(
              id: 'viewer-new',
              title: 'Newest viewer session',
              project: 'Viewer',
              lastMessageAtUtc: DateTime.utc(2026, 6, 12, 11),
            ),
            _row(
              id: 'tools-new',
              title: 'Tools session',
              project: 'Tools',
              lastMessageAtUtc: DateTime.utc(2026, 6, 12, 10),
            ),
            _row(
              id: 'blank-project',
              title: 'Session without project',
              project: '',
              lastMessageAtUtc: DateTime.utc(2026, 6, 12, 8),
            ),
          ],
        ),
      ),
    );

    expect(find.bySemanticsLabel('Sessions, 4 visible'), findsOneWidget);
    expect(find.text('Older viewer session'), findsWidgets);

    await tester.tap(
      find.bySemanticsLabel('Newest session per project filter'),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Sessions, 3 visible'), findsOneWidget);
    expect(find.text('Newest viewer session'), findsWidgets);
    expect(find.text('Tools session'), findsWidgets);
    expect(find.text('Session without project'), findsWidgets);
    expect(find.text('Older viewer session'), findsNothing);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Sessions, 4 visible'), findsOneWidget);
    expect(find.text('Older viewer session'), findsWidgets);
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

    expect(find.bySemanticsLabel('Sessions, 5000 visible'), findsOneWidget);
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
  DateTime? lastMessageAtUtc,
  List<ConversationMessageViewModel> messages = const [],
}) {
  return SessionRowViewModel(
    id: id,
    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
    lastMessageAtUtc: lastMessageAtUtc ?? DateTime.utc(2026, 6, 12, 10),
    platform: SessionRowPlatform.windows,
    project: project,
    path: r'F:\projects\MaxLogic\codex-sessions-viewer',
    title: title,
    summary: title,
    messageCount: 3,
    totalTokens: 900,
    model: 'gpt-5.4',
    tags: const ['ui'],
    status: 'Available',
    isArchived: isArchived,
    conversationMessages: messages,
  );
}
