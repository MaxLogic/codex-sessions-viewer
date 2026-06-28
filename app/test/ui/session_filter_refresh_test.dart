import 'dart:async';

import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    expect(find.text('Keep selected'), findsWidgets);

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

  testWidgets('shows and filters named Codex threads', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(
              id: 'named',
              title: 'Named title',
              project: 'codex-sessions-viewer',
              threadName: 'dmk2',
            ),
            _row(id: 'plain', title: 'Plain title', project: 'Other'),
          ],
        ),
      ),
    );

    expect(find.text('[dmk2]'), findsOneWidget);

    await tester.enterText(find.bySemanticsLabel('Session search'), 'dmk2');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Sessions, 1 visible'), findsOneWidget);
    expect(find.text('[dmk2]'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Advanced filters'));
    await tester.pumpAndSettle();
    await tester.enterText(find.bySemanticsLabel('Thread name filter'), 'mk2');
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Sessions, 1 visible'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('Named sessions only filter'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Sessions, 1 visible'), findsOneWidget);

    await tester.tap(find.text('[dmk2]'));
    await tester.pumpAndSettle();
    expect(find.text('dmk2'), findsWidgets);
    expect(find.text('Thread dmk2'), findsOneWidget);
    expect(find.text('Thread name'), findsOneWidget);
  });

  testWidgets(
    'unreachable scan with cached rows keeps recovery actions visible',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SessionsScreen(
            initialRows: [
              _row(id: 'cached', title: 'Cached session', project: 'Viewer'),
            ],
            onRefreshResult: () async {
              return SessionsRefreshResult(
                rows: [
                  _row(
                    id: 'cached',
                    title: 'Cached session',
                    project: 'Viewer',
                  ),
                ],
                statusMessage:
                    r'Scan finished. 1 session visible. Session root is unreachable. Unreachable paths: \\wsl.localhost\Ubuntu\home\pawel\.codex',
              );
            },
          ),
        ),
      );

      await tester.tap(find.widgetWithText(ElevatedButton, 'Refresh'));
      await tester.pumpAndSettle();

      expect(find.text('Cached session'), findsWidgets);
      expect(
        find.textContaining('Session root is unreachable'),
        findsOneWidget,
      );
      expect(find.text('Test WSL path'), findsOneWidget);
      expect(find.text('Open Settings'), findsOneWidget);
      expect(
        find.textContaining(
          r'Configured path: \\wsl.localhost\Ubuntu\home\pawel\.codex',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('groups subagent sessions under user sessions', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(
              id: 'parent',
              sessionId: 'thread-parent',
              title: 'Main user session',
              project: 'Viewer',
            ),
            _row(
              id: 'child',
              sessionId: 'thread-child',
              title: 'Child subagent',
              project: 'Viewer',
              threadSource: 'subagent',
              parentThreadId: 'thread-parent',
              agentNickname: 'Singer',
              estimatedCostText: '0.12',
              costUnknown: false,
            ),
          ],
        ),
      ),
    );

    expect(find.bySemanticsLabel('Sessions, 1 visible'), findsOneWidget);
    expect(find.text('Main user session'), findsWidgets);
    expect(find.textContaining('Child subagent'), findsNothing);
    expect(
      find.bySemanticsLabel('Show 1 subagent for Main user session'),
      findsOneWidget,
    );

    await tester.tap(
      find.bySemanticsLabel('Show 1 subagent for Main user session'),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Sessions, 2 visible'), findsOneWidget);
    expect(
      find.text('Subagent: Singer - Child subagent - \$0.12'),
      findsWidgets,
    );
    expect(
      find.bySemanticsLabel(
        'Session Subagent: Singer, Child subagent under Main user session. Status Available.',
      ),
      findsOneWidget,
    );

    await tester.tap(
      find.text('Subagent: Singer - Child subagent - \$0.12').first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Child subagent'), findsWidgets);
  });

  testWidgets('parent rows show aggregate subagent usage', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(
              id: 'parent',
              sessionId: 'thread-parent',
              title: 'Main user session',
              project: 'Viewer',
              totalTokens: 400,
              estimatedCostText: '0.10',
              costUnknown: false,
            ),
            _row(
              id: 'child',
              sessionId: 'thread-child',
              title: 'Child subagent',
              project: 'Viewer',
              threadSource: 'subagent',
              parentThreadId: 'thread-parent',
              agentNickname: 'Singer',
              totalTokens: 250,
              estimatedCostText: '0.025',
              costUnknown: false,
            ),
          ],
        ),
      ),
    );

    expect(find.bySemanticsLabel('Tokens 650'), findsOneWidget);
    expect(find.text('650'), findsOneWidget);

    await tester.tap(
      find.bySemanticsLabel('Show 1 subagent for Main user session'),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Tokens 650'), findsOneWidget);
    expect(find.bySemanticsLabel('Tokens 250'), findsOneWidget);
    expect(find.text('250'), findsOneWidget);
  });

  testWidgets('parent aggregate tokens drive token sorting', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialTableState: const SessionTableSettings(
            columnWidths: {},
            newestPerProjectOnly: false,
            sorts: [
              SessionTableSortSettings(
                column: 'total_tokens',
                ascending: false,
              ),
            ],
          ),
          initialRows: [
            _row(
              id: 'standalone',
              sessionId: 'thread-standalone',
              title: 'Standalone medium',
              project: 'Viewer',
              totalTokens: 500,
            ),
            _row(
              id: 'parent',
              sessionId: 'thread-parent',
              title: 'Small main big child',
              project: 'Viewer',
              totalTokens: 100,
            ),
            _row(
              id: 'child',
              sessionId: 'thread-child',
              title: 'Big child',
              project: 'Viewer',
              threadSource: 'subagent',
              parentThreadId: 'thread-parent',
              agentNickname: 'Singer',
              totalTokens: 1000,
            ),
          ],
        ),
      ),
    );

    final parentTop = tester.getTopLeft(
      find.text('Small main big child').first,
    );
    final standaloneTop = tester.getTopLeft(
      find.text('Standalone medium').first,
    );
    expect(parentTop.dy, lessThan(standaloneTop.dy));
  });

  testWidgets(
    'newest per project keeps matching subagent parent discoverable',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1800, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: SessionsScreen(
            initialTableState: const SessionTableSettings(
              columnWidths: {},
              newestPerProjectOnly: true,
              sorts: [
                SessionTableSortSettings(
                  column: 'last_message_at',
                  ascending: false,
                ),
              ],
            ),
            initialRows: [
              _row(
                id: 'new-parent',
                sessionId: 'thread-new',
                title: 'Newest same-project parent',
                project: 'Viewer',
                lastMessageAtUtc: DateTime.utc(2026, 6, 12, 12),
              ),
              _row(
                id: 'old-parent',
                sessionId: 'thread-old',
                title: 'Older parent',
                project: 'Viewer',
                lastMessageAtUtc: DateTime.utc(2026, 6, 12, 9),
              ),
              _row(
                id: 'needle-child',
                sessionId: 'thread-child',
                title: 'Needle subagent',
                project: 'Viewer',
                threadSource: 'subagent',
                parentThreadId: 'thread-old',
                agentNickname: 'Singer',
                lastMessageAtUtc: DateTime.utc(2026, 6, 12, 10),
              ),
            ],
          ),
        ),
      );

      await tester.enterText(find.bySemanticsLabel('Session search'), 'Needle');
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Sessions, 2 visible'), findsOneWidget);
      expect(find.text('Older parent'), findsWidgets);
      expect(
        find.text('Subagent: Singer - Needle subagent - Cost unknown'),
        findsWidgets,
      );
      expect(find.text('Newest same-project parent'), findsNothing);
    },
  );

  testWidgets('all origin applies newest per project across orphan subagents', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialTableState: const SessionTableSettings(
            columnWidths: {},
            newestPerProjectOnly: true,
            sorts: [
              SessionTableSortSettings(
                column: 'last_message_at',
                ascending: false,
              ),
            ],
          ),
          initialRows: [
            _row(
              id: 'parent',
              sessionId: 'thread-parent',
              title: 'Older user session',
              project: 'Viewer',
              lastMessageAtUtc: DateTime.utc(2026, 6, 12, 9),
            ),
            _row(
              id: 'orphan',
              sessionId: 'thread-orphan',
              title: 'Newer orphan subagent',
              project: 'Viewer',
              threadSource: 'subagent',
              parentThreadId: 'missing-parent',
              agentNickname: 'Singer',
              lastMessageAtUtc: DateTime.utc(2026, 6, 12, 12),
            ),
          ],
        ),
      ),
    );

    await _setOriginFilter(tester, 'All');

    expect(find.bySemanticsLabel('Sessions, 1 visible'), findsOneWidget);
    expect(
      find.text('Subagent: Singer - Newer orphan subagent - Cost unknown'),
      findsWidgets,
    );
    expect(find.text('Older user session'), findsNothing);
  });

  testWidgets('newest per project applies after archived filters', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialTableState: const SessionTableSettings(
            columnWidths: {},
            newestPerProjectOnly: true,
            sorts: [
              SessionTableSortSettings(
                column: 'last_message_at',
                ascending: false,
              ),
            ],
          ),
          initialRows: [
            _row(
              id: 'active-new',
              sessionId: 'thread-active-new',
              title: 'Active newer session',
              project: 'Viewer',
              lastMessageAtUtc: DateTime.utc(2026, 6, 12, 12),
            ),
            _row(
              id: 'archived-old',
              sessionId: 'thread-archived-old',
              title: 'Archived older session',
              project: 'Viewer',
              isArchived: true,
              lastMessageAtUtc: DateTime.utc(2026, 6, 12, 9),
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.text('Active only').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archived only').last);
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Sessions, 1 visible'), findsOneWidget);
    expect(find.text('Archived older session'), findsWidgets);
    expect(find.text('Active newer session'), findsNothing);
  });

  testWidgets('origin filters keep subagent hierarchy discoverable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(
              id: 'parent',
              sessionId: 'thread-parent',
              title: 'Main user session',
              project: 'Viewer',
            ),
            _row(
              id: 'child',
              sessionId: 'thread-child',
              title: 'Child subagent',
              project: 'Viewer',
              threadSource: 'subagent',
              parentThreadId: 'thread-parent',
              agentNickname: 'Singer',
              estimatedCostText: '0.12',
              costUnknown: false,
            ),
            _row(
              id: 'orphan',
              sessionId: 'thread-orphan',
              title: 'Orphan subagent',
              project: 'Viewer',
              threadSource: 'subagent',
              parentThreadId: 'missing-parent',
              agentNickname: 'Heisenberg',
            ),
          ],
        ),
      ),
    );

    expect(find.bySemanticsLabel('Sessions, 1 visible'), findsOneWidget);
    expect(find.textContaining('Child subagent'), findsNothing);
    expect(find.textContaining('Orphan subagent'), findsNothing);

    await _setOriginFilter(tester, 'All');

    expect(find.bySemanticsLabel('Sessions, 2 visible'), findsOneWidget);
    expect(find.text('Main user session'), findsWidgets);
    expect(
      find.text('Subagent: Heisenberg - Orphan subagent - Cost unknown'),
      findsWidgets,
    );
    expect(find.textContaining('Child subagent'), findsNothing);

    await tester.tap(
      find.bySemanticsLabel('Show 1 subagent for Main user session'),
    );
    await tester.pumpAndSettle();

    expect(find.bySemanticsLabel('Sessions, 3 visible'), findsOneWidget);
    expect(
      find.text('Subagent: Singer - Child subagent - \$0.12'),
      findsWidgets,
    );

    await _setOriginFilter(tester, 'Subagent');

    expect(find.bySemanticsLabel('Sessions, 2 visible'), findsOneWidget);
    expect(
      find.text(
        'Subagent: Singer - Child subagent - \$0.12 (Parent: Main user session)',
      ),
      findsWidgets,
    );
    expect(
      find.text('Subagent: Heisenberg - Orphan subagent - Cost unknown'),
      findsWidgets,
    );
    expect(find.text('Main user session'), findsNothing);
  });

  testWidgets('newly visible rows use bounded motion feedback', (tester) async {
    final refresh = Completer<List<SessionRowViewModel>>();

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(id: 'existing', title: 'Existing row', project: 'Viewer'),
          ],
          onRefresh: () => refresh.future,
          settings: AppSettings.defaults().copyWith(
            ui: AppSettings.defaults().ui.copyWithMotion(AppMotionMode.normal),
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(ElevatedButton, 'Refresh'));
    await tester.pump();

    refresh.complete([
      _row(id: 'existing', title: 'Existing row', project: 'Viewer'),
      _row(id: 'new-row', title: 'New animated row', project: 'Viewer'),
    ]);
    await tester.pump();

    final animatedRow = find.byKey(const Key('session-row-motion-new-row-v1'));
    expect(animatedRow, findsOneWidget);
    expect(
      find.descendant(of: animatedRow, matching: find.byType(SlideTransition)),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('session-row-motion-existing-v1')),
      findsNothing,
    );

    await tester.pumpAndSettle();
    expect(find.text('New animated row'), findsWidgets);
  });

  testWidgets('row motion cap follows visible sorted rows', (tester) async {
    final refresh = Completer<List<SessionRowViewModel>>();

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(id: 'visible', title: 'Visible old', project: 'Viewer'),
          ],
          onRefresh: () => refresh.future,
          settings: AppSettings.defaults().copyWith(
            ui: AppSettings.defaults().ui.copyWithMotion(AppMotionMode.normal),
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(ElevatedButton, 'Refresh'));
    await tester.pump();

    refresh.complete([
      for (var i = 0; i < 45; i++)
        _row(
          id: 'hidden-$i',
          title: 'Hidden changed $i',
          project: 'Hidden',
          isArchived: true,
        ),
      _row(id: 'visible', title: 'Visible changed', project: 'Viewer'),
    ]);
    await tester.pump();

    expect(
      find.byKey(const Key('session-row-motion-visible-v1')),
      findsOneWidget,
    );
  });

  testWidgets('filter changes animate newly visible rows', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(id: 'alpha', title: 'Alpha row', project: 'Viewer'),
            _row(id: 'beta', title: 'Beta row', project: 'Viewer'),
          ],
          settings: AppSettings.defaults().copyWith(
            ui: AppSettings.defaults().ui.copyWithMotion(AppMotionMode.normal),
          ),
        ),
      ),
    );

    await tester.enterText(find.bySemanticsLabel('Session search'), 'Alpha');
    await tester.pumpAndSettle();
    expect(find.text('Beta row'), findsNothing);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
    await tester.pump();

    expect(_rowMotionKeyFor('beta'), findsOneWidget);
  });

  testWidgets('repeated row updates replay motion with a new key', (
    tester,
  ) async {
    final refreshes = <Completer<List<SessionRowViewModel>>>[
      Completer<List<SessionRowViewModel>>(),
      Completer<List<SessionRowViewModel>>(),
    ];
    var refreshIndex = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(id: 'repeat', title: 'Repeat v1', project: 'Viewer'),
          ],
          onRefresh: () => refreshes[refreshIndex++].future,
          settings: AppSettings.defaults().copyWith(
            ui: AppSettings.defaults().ui.copyWithMotion(AppMotionMode.normal),
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(ElevatedButton, 'Refresh'));
    await tester.pump();
    refreshes[0].complete([
      _row(id: 'repeat', title: 'Repeat v2', project: 'Viewer'),
    ]);
    await tester.pump();
    expect(
      find.byKey(const Key('session-row-motion-repeat-v1')),
      findsOneWidget,
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Refresh'));
    await tester.pump();
    refreshes[1].complete([
      _row(id: 'repeat', title: 'Repeat v3', project: 'Viewer'),
    ]);
    await tester.pump();

    expect(
      find.byKey(const Key('session-row-motion-repeat-v2')),
      findsOneWidget,
    );
  });

  testWidgets('reduced row motion keeps non-spatial feedback', (tester) async {
    final refresh = Completer<List<SessionRowViewModel>>();

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(id: 'existing', title: 'Existing row', project: 'Viewer'),
          ],
          onRefresh: () => refresh.future,
          settings: AppSettings.defaults().copyWith(
            ui: AppSettings.defaults().ui.copyWithMotion(AppMotionMode.reduced),
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(ElevatedButton, 'Refresh'));
    await tester.pump();
    refresh.complete([
      _row(id: 'existing', title: 'Existing row', project: 'Viewer'),
      _row(id: 'reduced-new', title: 'Reduced new row', project: 'Viewer'),
    ]);
    await tester.pump();

    final animatedRow = find.byKey(
      const Key('session-row-motion-reduced-new-v1'),
    );
    expect(animatedRow, findsOneWidget);
    expect(
      find.descendant(of: animatedRow, matching: find.byType(SlideTransition)),
      findsNothing,
    );
    expect(
      find.descendant(of: animatedRow, matching: find.byType(FadeTransition)),
      findsOneWidget,
    );
  });

  testWidgets('sort options dialog remains keyboard accessible', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [_row(id: 'sort', title: 'Sort row', project: 'Viewer')],
          settings: AppSettings.defaults().copyWith(
            ui: AppSettings.defaults().ui.copyWithMotion(AppMotionMode.normal),
          ),
        ),
      ),
    );

    final header = find.bySemanticsLabel(
      'Last Message column descending priority 1',
    );
    await tester.tap(header, buttons: kSecondaryButton);
    await tester.pump();

    expect(find.text('Sort options'), findsOneWidget);
    expect(find.byType(FadeTransition), findsWidgets);
    expect(find.byType(ScaleTransition), findsWidgets);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.text('Sort options'), findsNothing);
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

  testWidgets('periodic rescans follow settings without overlapping', (
    tester,
  ) async {
    var refreshCalls = 0;
    final operations = <Completer<SessionsRefreshResult>>[];
    final enabledSettings = AppSettings.defaults().copyWith(
      scanner: const ScannerSettings(
        backgroundRescanEnabled: true,
        backgroundRescanIntervalSeconds: 1,
      ),
    );
    final disabledSettings = AppSettings.defaults().copyWith(
      scanner: const ScannerSettings(
        backgroundRescanEnabled: false,
        backgroundRescanIntervalSeconds: 1,
      ),
    );

    Widget screen(AppSettings settings) => MaterialApp(
      home: SessionsScreen(
        settings: settings,
        onRefreshOperation: (_) {
          refreshCalls++;
          final operation = Completer<SessionsRefreshResult>();
          operations.add(operation);
          return SessionsRefreshOperation(
            result: operation.future,
            cancel: () => operation.future.then<void>((_) {}),
          );
        },
      ),
    );

    await tester.pumpWidget(screen(enabledSettings));
    await tester.pump(const Duration(milliseconds: 999));
    expect(refreshCalls, 0);

    await tester.pump(const Duration(milliseconds: 2));
    expect(refreshCalls, 1);

    await tester.pump(const Duration(seconds: 1));
    expect(refreshCalls, 1);

    operations.single.complete(
      const SessionsRefreshResult(rows: [], statusMessage: 'Scan finished.'),
    );
    await tester.pump();

    await tester.pump(const Duration(seconds: 1));
    expect(refreshCalls, 2);
    operations.last.complete(
      const SessionsRefreshResult(rows: [], statusMessage: 'Scan finished.'),
    );
    await tester.pump();

    await tester.pumpWidget(screen(disabledSettings));
    await tester.pump();
    final callsAfterDisable = refreshCalls;
    await tester.pump(const Duration(seconds: 1));

    expect(refreshCalls, callsAfterDisable);
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
    final tableStates = <SessionTableSettings>[];

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          onTableStateChanged: tableStates.add,
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

    expect(tableStates.last.newestPerProjectOnly, isTrue);
    expect(find.bySemanticsLabel('Sessions, 3 visible'), findsOneWidget);
    expect(find.text('Newest viewer session'), findsWidgets);
    expect(find.text('Tools session'), findsWidgets);
    expect(find.text('Session without project'), findsWidgets);
    expect(find.text('Older viewer session'), findsNothing);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Clear filters'));
    await tester.pumpAndSettle();

    expect(tableStates.last.newestPerProjectOnly, isFalse);
    expect(find.bySemanticsLabel('Sessions, 4 visible'), findsOneWidget);
    expect(find.text('Older viewer session'), findsWidgets);
  });

  testWidgets(
    'restores newest session per project filter from table settings',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          home: SessionsScreen(
            initialTableState: const SessionTableSettings(
              columnWidths: {},
              newestPerProjectOnly: true,
              sorts: [
                SessionTableSortSettings(
                  column: 'last_message_at',
                  ascending: false,
                ),
              ],
            ),
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
            ],
          ),
        ),
      );

      expect(find.bySemanticsLabel('Sessions, 1 visible'), findsOneWidget);
      expect(find.text('Newest viewer session'), findsWidgets);
      expect(find.text('Older viewer session'), findsNothing);
    },
  );

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

  testWidgets('left panel matches the session table width', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(id: 'sized', title: 'Sized panel', project: 'Viewer'),
          ],
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(const Key('sessions-left-panel'))).width,
      1196,
    );
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

  testWidgets('loads newest selected conversation page first', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final load = Completer<SessionRowViewModel?>();

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(id: 'paged', title: 'Paged detail', project: 'Viewer'),
          ],
          onLoadSessionDetail: (_) => load.future,
        ),
      ),
    );

    await tester.tap(find.text('Paged detail').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Paged detail'), findsWidgets);
    expect(find.text('Loading conversation messages'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Loading session conversation messages')),
      findsOneWidget,
    );

    load.complete(
      _row(
        id: 'paged',
        title: 'Paged detail',
        project: 'Viewer',
        messages: [
          ConversationMessageViewModel(
            id: 'old-metadata',
            number: 1,
            author: ConversationAuthor.user,
            createdAtUtc: DateTime.utc(2026, 6, 12, 9),
            preview: 'Older prompt preview',
            body: '',
            tokenCount: 4,
            isBodyLoaded: false,
          ),
          ConversationMessageViewModel(
            id: 'new-loaded',
            number: 2,
            author: ConversationAuthor.assistant,
            createdAtUtc: DateTime.utc(2026, 6, 12, 9, 1),
            preview: 'Newest answer preview',
            body: 'Newest answer body',
            tokenCount: 8,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Newest answer body'), findsOneWidget);
    expect(find.text('Message body not loaded yet.'), findsOneWidget);
    expect(find.text('Loading conversation messages'), findsNothing);
  });

  testWidgets('restores selected session conversation position', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(
              id: 'first',
              title: 'First session',
              project: 'Viewer',
              messages: _messages('first', count: 6),
            ),
            _row(
              id: 'second',
              title: 'Second session',
              project: 'Viewer',
              messages: _messages('second', count: 6),
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.text('First session').first);
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel('#4 Assistant, 4 tokens'));
    await tester.pumpAndSettle();
    expect(find.text('Selected message 4'), findsOneWidget);

    await tester.tap(find.text('Second session').first);
    await tester.pumpAndSettle();
    expect(find.text('Selected message 4'), findsNothing);

    await tester.tap(find.text('First session').first);
    await tester.pumpAndSettle();
    expect(find.text('Selected message 4'), findsOneWidget);
  });

  testWidgets('ignores stale selected conversation loads', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final firstLoad = Completer<SessionRowViewModel?>();
    final secondLoad = Completer<SessionRowViewModel?>();

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(id: 'first', title: 'First session', project: 'Viewer'),
            _row(id: 'second', title: 'Second session', project: 'Viewer'),
          ],
          onLoadSessionDetail: (id) {
            return switch (id) {
              'first' => firstLoad.future,
              'second' => secondLoad.future,
              _ => Future<SessionRowViewModel?>.value(null),
            };
          },
        ),
      ),
    );

    await tester.tap(find.text('First session').first);
    await tester.pump();
    expect(find.text('Loading conversation messages'), findsOneWidget);

    await tester.tap(find.text('Second session').first);
    await tester.pump();

    firstLoad.complete(
      _row(
        id: 'first',
        title: 'First loaded',
        project: 'Viewer',
        messages: [
          ConversationMessageViewModel(
            id: 'first-message',
            number: 1,
            author: ConversationAuthor.user,
            createdAtUtc: DateTime.utc(2026, 6, 12, 9),
            preview: 'Stale body',
            body: 'Stale body',
            tokenCount: 1,
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('Stale body'), findsNothing);
    expect(find.text('Loading conversation messages'), findsOneWidget);

    secondLoad.complete(
      _row(
        id: 'second',
        title: 'Second loaded',
        project: 'Viewer',
        messages: [
          ConversationMessageViewModel(
            id: 'second-message',
            number: 1,
            author: ConversationAuthor.assistant,
            createdAtUtc: DateTime.utc(2026, 6, 12, 9),
            preview: 'Current body',
            body: 'Current body',
            tokenCount: 1,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current body'), findsOneWidget);
    expect(find.text('Stale body'), findsNothing);
    expect(find.text('Loading conversation messages'), findsNothing);
  });

  testWidgets('ignores stale conversation page loads', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final firstLoad = Completer<SessionRowViewModel?>();
    final secondLoad = Completer<SessionRowViewModel?>();

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(id: 'first-page', title: 'First paged', project: 'Viewer'),
            _row(id: 'second-page', title: 'Second paged', project: 'Viewer'),
          ],
          onLoadSessionDetail: (id) {
            return switch (id) {
              'first-page' => firstLoad.future,
              'second-page' => secondLoad.future,
              _ => Future<SessionRowViewModel?>.value(null),
            };
          },
        ),
      ),
    );

    await tester.tap(find.text('First paged').first);
    await tester.pump();
    await tester.tap(find.text('Second paged').first);
    await tester.pump();

    firstLoad.complete(
      _row(
        id: 'first-page',
        title: 'First loaded',
        project: 'Viewer',
        messages: [
          ConversationMessageViewModel(
            id: 'stale-page',
            number: 1,
            author: ConversationAuthor.assistant,
            createdAtUtc: DateTime.utc(2026, 6, 12, 9),
            preview: 'Stale page preview',
            body: 'Stale page body',
            tokenCount: 1,
          ),
        ],
      ),
    );
    await tester.pump();
    expect(find.text('Stale page body'), findsNothing);

    secondLoad.complete(
      _row(
        id: 'second-page',
        title: 'Second loaded',
        project: 'Viewer',
        messages: [
          ConversationMessageViewModel(
            id: 'current-page',
            number: 1,
            author: ConversationAuthor.assistant,
            createdAtUtc: DateTime.utc(2026, 6, 12, 9),
            preview: 'Current page preview',
            body: 'Current page body',
            tokenCount: 1,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current page body'), findsOneWidget);
    expect(find.text('Stale page body'), findsNothing);
  });

  testWidgets('reloads selected conversation when its session file changes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final changes = StreamController<Object>();
    addTearDown(changes.close);
    var reloadCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(
              id: 'live',
              title: 'Live detail',
              project: 'Viewer',
              sourceFilePath: r'F:\codex\sessions\live.jsonl',
            ),
          ],
          watchSessionFile: (path) {
            expect(path, r'F:\codex\sessions\live.jsonl');
            return changes.stream;
          },
          onLoadSessionDetail: (id) async {
            return _row(
              id: id,
              title: 'Live detail',
              project: 'Viewer',
              sourceFilePath: r'F:\codex\sessions\live.jsonl',
              messages: [
                ConversationMessageViewModel(
                  id: 'msg-1',
                  number: 1,
                  author: ConversationAuthor.user,
                  createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                  preview: 'Initial body',
                  body: 'Initial body',
                  tokenCount: 12,
                ),
              ],
            );
          },
          onReloadSessionDetailFromSource: (id) async {
            reloadCalls++;
            return _row(
              id: id,
              title: 'Live detail',
              project: 'Viewer',
              sourceFilePath: r'F:\codex\sessions\live.jsonl',
              messages: [
                ConversationMessageViewModel(
                  id: 'msg-1',
                  number: 1,
                  author: ConversationAuthor.user,
                  createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                  preview: 'Initial body',
                  body: 'Initial body',
                  tokenCount: 12,
                ),
                ConversationMessageViewModel(
                  id: 'msg-2',
                  number: 2,
                  author: ConversationAuthor.assistant,
                  createdAtUtc: DateTime.utc(2026, 6, 12, 9, 1),
                  preview: 'New streamed answer',
                  body: 'New streamed answer',
                  tokenCount: 24,
                ),
              ],
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Live detail').first);
    await tester.pumpAndSettle();
    expect(find.text('Initial body'), findsWidgets);

    changes.add(Object());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(reloadCalls, 1);
    expect(find.text('New streamed answer'), findsWidgets);
  });

  testWidgets('conversation view hides injected environment context messages', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1800, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(
              id: 'context',
              title: 'Context detail',
              project: 'Viewer',
              messages: [
                ConversationMessageViewModel(
                  id: 'msg-1',
                  number: 1,
                  author: ConversationAuthor.user,
                  createdAtUtc: DateTime.utc(2026, 6, 18, 10),
                  preview: '<environment_context>',
                  body: '''
<environment_context>
  <current_date>2026-06-18</current_date>
  <filesystem><workspace_roots><root>F:\\repo</root></workspace_roots></filesystem>
</environment_context>''',
                  tokenCount: 12,
                ),
                ConversationMessageViewModel(
                  id: 'msg-2',
                  number: 2,
                  author: ConversationAuthor.user,
                  createdAtUtc: DateTime.utc(2026, 6, 18, 10, 1),
                  preview: 'Please explain this environment_context tag.',
                  body: 'Please explain this environment_context tag.',
                  tokenCount: 8,
                ),
              ],
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.text('Context detail').first);
    await tester.pumpAndSettle();

    expect(find.textContaining('<environment_context>'), findsNothing);
    expect(
      find.textContaining('Please explain this environment_context tag.'),
      findsWidgets,
    );
  });

  testWidgets('conversation index shows message-kind icons', (tester) async {
    await tester.binding.setSurfaceSize(const Size(2200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: SessionsScreen(
          initialRows: [
            _row(
              id: 'icons',
              title: 'Icon detail',
              project: 'Viewer',
              messages: [
                ConversationMessageViewModel(
                  id: 'msg-1',
                  number: 1,
                  author: ConversationAuthor.user,
                  createdAtUtc: DateTime.utc(2026, 6, 18, 10),
                  preview: 'Prompt',
                  body: 'Prompt',
                  tokenCount: 8,
                ),
                ConversationMessageViewModel(
                  id: 'msg-2',
                  number: 2,
                  author: ConversationAuthor.assistant,
                  createdAtUtc: DateTime.utc(2026, 6, 18, 10, 1),
                  preview: 'Answer',
                  body: 'Answer',
                  tokenCount: 12,
                ),
                ConversationMessageViewModel(
                  id: 'msg-3',
                  number: 3,
                  author: ConversationAuthor.tool,
                  createdAtUtc: DateTime.utc(2026, 6, 18, 10, 2),
                  preview: 'Tool',
                  body: 'Tool',
                  tokenCount: 4,
                ),
              ],
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.text('Icon detail').first);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('message-index-icon-1')), findsOneWidget);
    expect(find.byKey(const Key('message-index-icon-2')), findsOneWidget);
    expect(find.byKey(const Key('message-index-icon-3')), findsOneWidget);
    expect(find.byKey(const Key('message-card-icon-1')), findsOneWidget);
    expect(find.byKey(const Key('message-card-icon-2')), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('#3 Tool, 4 tokens'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('message-card-icon-3')), findsOneWidget);
  });
}

SessionRowViewModel _row({
  required String id,
  required String title,
  required String project,
  String sessionId = '',
  String threadName = '',
  String threadSource = '',
  String parentThreadId = '',
  String agentNickname = '',
  bool isArchived = false,
  String sourceFilePath = '',
  DateTime? lastMessageAtUtc,
  int totalTokens = 900,
  List<ConversationMessageViewModel> messages = const [],
  String? estimatedCostText,
  bool costUnknown = true,
}) {
  return SessionRowViewModel(
    id: id,
    sessionId: sessionId,
    threadName: threadName,
    threadSource: threadSource,
    parentThreadId: parentThreadId,
    agentNickname: agentNickname,
    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
    lastMessageAtUtc: lastMessageAtUtc ?? DateTime.utc(2026, 6, 12, 10),
    platform: SessionRowPlatform.windows,
    project: project,
    path: r'F:\projects\MaxLogic\codex-sessions-viewer',
    title: title,
    summary: title,
    messageCount: 3,
    totalTokens: totalTokens,
    model: 'gpt-5.4',
    estimatedCostText: estimatedCostText,
    costUnknown: costUnknown,
    tags: const ['ui'],
    status: 'Available',
    isArchived: isArchived,
    sourceFilePath: sourceFilePath,
    conversationMessages: messages,
  );
}

List<ConversationMessageViewModel> _messages(
  String prefix, {
  required int count,
}) {
  return [
    for (var i = 1; i <= count; i++)
      ConversationMessageViewModel(
        id: '$prefix-$i',
        number: i,
        author: i.isOdd
            ? ConversationAuthor.user
            : ConversationAuthor.assistant,
        createdAtUtc: DateTime.utc(2026, 6, 12, 9, i),
        preview: '$prefix message $i preview',
        body: '$prefix message $i body',
        tokenCount: i,
      ),
  ];
}

Future<void> _setOriginFilter(WidgetTester tester, String label) async {
  Finder originDropdown() {
    return find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith('origin-filter-');
    });
  }

  if (originDropdown().evaluate().isEmpty) {
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
  }
  await tester.tap(originDropdown());
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Finder _rowMotionKeyFor(String id) {
  return find.byWidgetPredicate((widget) {
    final key = widget.key;
    return key is ValueKey<String> &&
        key.value.startsWith('session-row-motion-$id-v');
  });
}
