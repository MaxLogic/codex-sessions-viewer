import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'dart:async';

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

    await _openDetailTab(tester, 'Details');

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

    await _chooseMoreAction(tester, 'Re-parse this session');

    expect(actions.map((action) => action.action), [
      SessionRowAction.openTerminalResume,
      SessionRowAction.openTerminalResume,
      SessionRowAction.openTerminalFork,
      SessionRowAction.reparse,
    ]);
    expect(actions.first.payload, contains('codex resume abc123'));
    expect(actions[1].payload, 'cmd /c echo edited');
    // Both run without a shell: the command text becomes program + args.
    expect(actions.first.launchSpec, isNotNull);
    expect(actions[1].launchSpec?.executable, 'cmd');
    expect(actions[1].launchSpec?.arguments, ['/c', 'echo', 'edited']);
    expect(actions[2].payload, contains('codex fork abc123'));

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(_menuItemEnabled(tester, 'Export Markdown…'), isFalse);
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
    await _openDetailTab(tester, 'Details');

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
    'session detail keeps one primary resume action and commands in Details',
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
        find.widgetWithText(FilledButton, 'Resume in terminal'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Copy resume command'),
        findsOneWidget,
      );
      expect(find.text('Plain resume command:'), findsNothing);

      await _openDetailTab(tester, 'Details');

      expect(
        find.widgetWithText(OutlinedButton, 'Copy plain resume command'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Copy terminal launch command'),
        findsOneWidget,
      );
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

      await _chooseMoreAction(tester, 'Open containing folder');

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

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(_menuItemEnabled(tester, 'Open containing folder'), isFalse);
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
    await _chooseMoreAction(tester, 'Export Markdown…');

    expect(exported.single, contains('# Parser cache'));
    expect(exported.single, contains('## Message 1 - User'));
    expect(exported.single, contains('Hello'));
  });

  testWidgets('shows delayed progress while preparing conversation Markdown', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(2400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final loadGate = Completer<List<ConversationMessageViewModel>>();
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
                    body: '',
                    tokenCount: 3,
                    isBodyLoaded: false,
                  ),
                ],
              ),
            ],
            onLoadAllMessages: (_) => loadGate.future,
            onExportMarkdown: (_, _) async {},
          ),
        ),
      ),
    );
    await tester.tap(find.text('Parser cache').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export Markdown…'));
    await tester.pump(const Duration(milliseconds: 1999));
    expect(find.text('Preparing Markdown'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('Preparing Markdown'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    loadGate.complete([
      ConversationMessageViewModel(
        id: 'm1',
        number: 1,
        author: ConversationAuthor.user,
        createdAtUtc: DateTime.utc(2026, 6, 18, 10),
        preview: 'Hello',
        body: 'Hello',
        tokenCount: 3,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Preparing Markdown'), findsNothing);
  });

  testWidgets('pin and archive show immediately without a rescan', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(2400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [_row(sessionId: 'abc123')],
            onSessionAction: (request) async => actions.add(request),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Parser cache').first);
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsLabel('Pin session'));
    await tester.pumpAndSettle();
    expect(actions.single.action, SessionRowAction.togglePin);
    expect(find.bySemanticsLabel('Unpin session'), findsOneWidget);
    expect(find.text('Session pinned.'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Archive session'));
    await tester.pumpAndSettle();
    expect(actions.last.action, SessionRowAction.toggleArchive);
    expect(
      find.text('Session archived and hidden by the current filter.'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Sessions, 0 visible'), findsOneWidget);
  });

  testWidgets('re-parse reloads only the selected session', (tester) async {
    await tester.binding.setSurfaceSize(const Size(2400, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final actions = <SessionActionRequest>[];
    final reloaded = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TestSessionsScreen(
            initialRows: [_row(sessionId: 'abc123')],
            onSessionAction: (request) async => actions.add(request),
            onReloadSessionDetailFromSource: (id) async {
              reloaded.add(id);
              return _row(sessionId: 'abc123', path: r'F:\projects\renamed');
            },
          ),
        ),
      ),
    );
    await tester.tap(find.text('Parser cache').first);
    await tester.pumpAndSettle();
    reloaded.clear();

    await _chooseMoreAction(tester, 'Re-parse this session');

    expect(reloaded, ['active']);
    expect(actions, isEmpty);
    expect(find.text('Session re-parsed.'), findsOneWidget);
    expect(find.textContaining(r'F:\projects\renamed'), findsWidgets);
  });
}

Future<void> _openDetailTab(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(Tab, label));
  await tester.pumpAndSettle();
}

Future<void> _chooseMoreAction(WidgetTester tester, String label) async {
  await tester.tap(find.text('More'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

bool _menuItemEnabled(WidgetTester tester, String label) {
  final item = tester.widget<PopupMenuItem<String>>(
    find.ancestor(
      of: find.textContaining(label),
      matching: find.byType(PopupMenuItem<String>),
    ),
  );
  return item.enabled;
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
