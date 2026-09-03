import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_sessions_screen.dart';

void main() {
  testWidgets('row action menu invokes callbacks with generated payloads', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [_row(sessionId: 'abc123')],
            onSessionAction: (request) async {
              actions.add(request);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Copy path for Parser cache'));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('More actions for Parser cache'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy plain resume command'));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('More actions for Parser cache'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open terminal and fork'));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('More actions for Parser cache'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Re-parse session'));
    await tester.pumpAndSettle();

    expect(actions.map((action) => action.action), [
      SessionRowAction.copyPath,
      SessionRowAction.copyPlainResumeCommand,
      SessionRowAction.openTerminalFork,
      SessionRowAction.reparse,
    ]);
    expect(actions[0].payload, r'F:\projects\MaxLogic\codex-sessions-viewer');
    expect(actions[1].payload, 'codex resume abc123');
    expect(actions[2].payload, contains('codex fork abc123'));
  });

  testWidgets('shows resume in both primary row actions and the more menu', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [_row(sessionId: 'abc123')],
            onSessionAction: (request) async {
              actions.add(request);
            },
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel('Copy path for Parser cache'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Open terminal and resume for Parser cache'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('More actions for Parser cache'),
      findsOneWidget,
    );

    await tester.tap(
      find.bySemanticsLabel('Open terminal and resume for Parser cache'),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('More actions for Parser cache'));
    await tester.pumpAndSettle();

    expect(find.text('Copy path'), findsNothing);
    expect(find.text('Open terminal and resume'), findsOneWidget);
    expect(find.text('Copy plain resume command'), findsOneWidget);
    expect(find.text('Open terminal and fork'), findsOneWidget);

    await tester.tap(find.text('Open terminal and resume'));
    await tester.pumpAndSettle();

    expect(actions.map((action) => action.action), [
      SessionRowAction.openTerminalResume,
      SessionRowAction.openTerminalResume,
    ]);
    expect(
      actions.every(
        (action) => action.payload!.contains('codex resume abc123'),
      ),
      isTrue,
    );
    expect(
      actions.every(
        (action) =>
            action.launchSpec?.executable ==
            r'C:\Program Files\Alacritty\alacritty.exe',
      ),
      isTrue,
    );
  });

  testWidgets('row action menu uses compact desktop item height', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(initialRows: [_row(sessionId: 'abc123')]),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('More actions for Parser cache'));
    await tester.pumpAndSettle();

    final items = tester
        .widgetList<PopupMenuItem<SessionRowAction>>(
          find.byType(PopupMenuItem<SessionRowAction>),
        )
        .toList();
    expect(items, isNotEmpty);
    expect(items.every((item) => item.height == 36), isTrue);
  });

  testWidgets('session table labels containing-folder action accurately', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(initialRows: [_row(sessionId: 'abc123')]),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('More actions for Parser cache'));
    await tester.pumpAndSettle();

    expect(find.text('Open containing folder'), findsOneWidget);
    expect(find.text('Open path'), findsNothing);
  });

  testWidgets('hides containing-folder action for unresolved WSL paths', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [
              _row(
                sessionId: 'abc123',
                platform: SessionRowPlatform.wsl,
                path: '/mnt/f/projects/oec/te5/maxtdb',
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.byType(PopupMenuButton<SessionRowAction>));
    await tester.pumpAndSettle();

    expect(find.text('Open containing folder'), findsNothing);
    expect(find.text('Copy path'), findsNothing);
    expect(find.bySemanticsLabel('Copy path for Parser cache'), findsOneWidget);
  });

  testWidgets('resolved WSL paths expose containing-folder actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [
              _row(
                sessionId: 'abc123',
                platform: SessionRowPlatform.wsl,
                path: '/home/pawel/project',
                openablePath: r'\\wsl.localhost\Ubuntu\home\pawel\project',
              ),
            ],
            onSessionAction: (request) async {
              actions.add(request);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.byType(PopupMenuButton<SessionRowAction>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open containing folder'));
    await tester.pumpAndSettle();

    expect(actions.single.action, SessionRowAction.openPath);
    expect(
      actions.single.payload,
      r'\\wsl.localhost\Ubuntu\home\pawel\project',
    );
  });

  testWidgets('copy path keeps the visible WSL path', (tester) async {
    await tester.binding.setSurfaceSize(const Size(5000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [
              _row(
                sessionId: 'abc123',
                platform: SessionRowPlatform.wsl,
                path: '/home/pawel/project',
                openablePath: r'\\wsl.localhost\Ubuntu\home\pawel\project',
              ),
            ],
            onSessionAction: (request) async {
              actions.add(request);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Copy path for Parser cache'));
    await tester.pumpAndSettle();

    expect(actions.single.action, SessionRowAction.copyPath);
    expect(actions.single.payload, '/home/pawel/project');
  });

  testWidgets('path cell copy button copies the visible path', (tester) async {
    await tester.binding.setSurfaceSize(const Size(5000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [_row(sessionId: 'abc123')],
            onSessionAction: (request) async {
              actions.add(request);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Copy path for Parser cache'));
    await tester.pumpAndSettle();

    expect(actions.single.action, SessionRowAction.copyPath);
    expect(
      actions.single.payload,
      r'F:\projects\MaxLogic\codex-sessions-viewer',
    );
  });

  testWidgets('resume actions are disabled when session id is unavailable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: TestSessionsScreen(
          initialRows: [_row(sessionId: '')],
          onSessionAction: (request) async {
            actions.add(request);
          },
        ),
      ),
    );

    await tester.tap(find.byType(PopupMenuButton<SessionRowAction>));
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<PopupMenuItem<SessionRowAction>>(
            find.widgetWithText(
              PopupMenuItem<SessionRowAction>,
              'Copy plain resume command',
            ),
          )
          .enabled,
      isFalse,
    );
    expect(find.textContaining('Resume unavailable'), findsWidgets);
    expect(actions, isEmpty);
  });

  testWidgets('row command payloads use injected settings', (tester) async {
    await tester.binding.setSurfaceSize(const Size(5000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: TestSessionsScreen(
          settings: AppSettings.defaults().copyWith(
            wsl: const WslSettings(
              distro: 'Debian',
              linuxHome: '/home/pawel',
              linuxRootUnc: r'\\wsl.localhost\Debian\home\pawel\',
            ),
          ),
          initialRows: [
            _row(sessionId: 'abc123', platform: SessionRowPlatform.wsl),
          ],
          onSessionAction: (request) async {
            actions.add(request);
          },
        ),
      ),
    );

    await tester.tap(find.byType(PopupMenuButton<SessionRowAction>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy platform resume command'));
    await tester.pumpAndSettle();

    expect(actions.single.action, SessionRowAction.copyPlatformResumeCommand);
    expect(actions.single.payload, contains('Debian'));
  });

  testWidgets('selected detail command preview routes run actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [_row(sessionId: 'abc123')],
            onSessionAction: (request) async {
              actions.add(request);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Parser cache').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Commands'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Run'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Edit and run'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'cmd /c echo edited');
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await tester.pumpAndSettle();

    final fork = find.widgetWithText(
      OutlinedButton,
      'Open in terminal and fork',
    );
    await tester.ensureVisible(fork);
    await tester.tap(fork);
    await tester.pumpAndSettle();

    final reparse = find.widgetWithText(
      OutlinedButton,
      'Re-parse this session',
    );
    await tester.ensureVisible(reparse);
    await tester.tap(reparse);
    await tester.pumpAndSettle();

    expect(actions.map((action) => action.action), [
      SessionRowAction.openTerminalResume,
      SessionRowAction.openTerminalResume,
      SessionRowAction.openTerminalFork,
      SessionRowAction.reparse,
    ]);
    expect(actions.first.payload, contains('codex resume abc123'));
    expect(actions[1].payload, 'cmd /c echo edited');
    expect(actions[2].payload, contains('codex fork abc123'));

    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Export Markdown'),
          )
          .enabled,
      isFalse,
    );
  });

  testWidgets('session detail hides duplicate resume command actions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(initialRows: [_row(sessionId: 'abc123')]),
        ),
      ),
    );

    await tester.tap(find.text('Parser cache').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Commands'));
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(OutlinedButton, 'Copy plain resume command'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(OutlinedButton, 'Copy platform resume command'),
      findsNothing,
    );
  });

  testWidgets(
    'session detail command actions live in collapsible commands panel',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(5000, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TestSessionsScreen(initialRows: [_row(sessionId: 'abc123')]),
          ),
        ),
      );

      await tester.tap(find.text('Parser cache').first);
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(OutlinedButton, 'Copy plain resume command'),
        findsNothing,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Open in terminal and resume'),
        findsNothing,
      );
      expect(find.text('Plain resume command:'), findsNothing);

      await tester.tap(find.text('Commands'));
      await tester.pumpAndSettle();

      expect(
        find.widgetWithText(OutlinedButton, 'Copy plain resume command'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Open in terminal and resume'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Copy terminal launch command'),
        findsOneWidget,
      );
      expect(find.text('Plain resume command:'), findsNothing);
      await tester.tap(find.text('Show command preview'));
      await tester.pumpAndSettle();
      expect(find.text('Plain resume command:'), findsOneWidget);
    },
  );

  testWidgets(
    'session detail containing-folder action opens working directory',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(5000, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final actions = <SessionActionRequest>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TestSessionsScreen(
              initialRows: [
                _row(
                  sessionId: 'abc123',
                  sourceFilePath:
                      r'F:\Users\pawel\.codex\sessions\2026\06\session.jsonl',
                  path: r'F:\projects\MaxLogic\codex-sessions-viewer',
                  workingDirectory:
                      r'F:\projects\MaxLogic\codex-sessions-viewer',
                  openablePath: r'F:\projects\MaxLogic\codex-sessions-viewer',
                ),
              ],
              onSessionAction: (request) async {
                actions.add(request);
              },
            ),
          ),
        ),
      );

      await tester.tap(find.text('Parser cache').first);
      await tester.pumpAndSettle();

      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Open containing folder'),
      );
      await tester.pumpAndSettle();

      expect(actions.single.action, SessionRowAction.openPath);
      expect(
        actions.single.payload,
        r'F:\projects\MaxLogic\codex-sessions-viewer',
      );
    },
  );

  testWidgets('session detail disables containing-folder for unresolved WSL', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [
              _row(
                sessionId: 'abc123',
                platform: SessionRowPlatform.wsl,
                path: '/mnt/f/projects/oec/te5/maxtdb',
                workingDirectory: '/mnt/f/projects/oec/te5/maxtdb',
                openablePath: '/mnt/f/projects/oec/te5/maxtdb',
              ),
            ],
            onSessionAction: (request) async {
              actions.add(request);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Parser cache').first);
    await tester.pumpAndSettle();

    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Open containing folder'),
    );
    expect(button.enabled, isFalse);
    expect(actions, isEmpty);
  });

  testWidgets('copies conversation markdown from session details', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final copied = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [
              _row(
                sessionId: 'abc123',
                messages: [
                  ConversationMessageViewModel(
                    id: 'm1',
                    number: 1,
                    author: ConversationAuthor.user,
                    createdAtUtc: DateTime.utc(2026, 6, 18, 10),
                    preview: 'Hello',
                    body: 'Hello',
                    tokenCount: 3,
                  ),
                ],
              ),
            ],
            onCopyText: (text) async {
              copied.add(text);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Parser cache').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy conversation Markdown'));
    await tester.pumpAndSettle();

    expect(copied.single, contains('# Parser cache'));
    expect(copied.single, contains('## Message 1 - User'));
    expect(copied.single, contains('Hello'));
  });

  testWidgets('exports conversation markdown from session details', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(5000, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final exported = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [
              _row(
                sessionId: 'abc123',
                messages: [
                  ConversationMessageViewModel(
                    id: 'm1',
                    number: 1,
                    author: ConversationAuthor.user,
                    createdAtUtc: DateTime.utc(2026, 6, 18, 10),
                    preview: 'Hello',
                    body: 'Hello',
                    tokenCount: 3,
                  ),
                ],
              ),
            ],
            onExportMarkdown: (row, markdown) async {
              exported.add(markdown);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Parser cache').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(OutlinedButton, 'Export Markdown'));
    await tester.pumpAndSettle();

    expect(exported.single, contains('# Parser cache'));
    expect(exported.single, contains('## Message 1 - User'));
    expect(exported.single, contains('Hello'));
  });
}

SessionRowViewModel _row({
  required String sessionId,
  SessionRowPlatform platform = SessionRowPlatform.windows,
  String path = r'F:\projects\MaxLogic\codex-sessions-viewer',
  String sourceFilePath = '',
  String? displayPath,
  String? workingDirectory,
  String? openablePath,
  List<ConversationMessageViewModel> messages = const [],
}) {
  return SessionRowViewModel(
    id: 'active',
    sessionId: sessionId,
    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
    lastMessageAtUtc: DateTime.utc(2026, 6, 12, 10),
    platform: platform,
    project: 'Codex Viewer',
    path: path,
    sourceFilePath: sourceFilePath,
    displayPath: displayPath ?? path,
    workingDirectory: workingDirectory ?? path,
    openablePath: openablePath ?? path,
    title: 'Parser cache',
    summary: 'Parser cache',
    messageCount: 7,
    totalTokens: 1200,
    model: 'gpt-5.4',
    tags: const ['parser'],
    status: 'Available',
    conversationMessages: messages,
  );
}
