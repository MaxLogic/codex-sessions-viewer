import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/ui/number_formatting.dart';
import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/screens/sessions_screen.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/session_detail_pane.dart';
import 'package:codex_sessions_viewer/src/usage/session_activity.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/session_stats_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_sessions_screen.dart';

void main() {
  testWidgets('shows required metadata and detail actions', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionDetailPane(row: _detailRow())),
      ),
    );

    await _openDetails(tester);

    for (final text in const [
      'Flutter accessibility spike',
      'Platform: WSL',
      'Project: Codex Viewer',
      'Source file: /home/pawel/.codex/sessions/session.jsonl',
      'Display path: /home/pawel/.codex/sessions/session.jsonl',
      'Working directory: /home/pawel/projects/codex-viewer',
      'Duration: 1h 30m',
      'Total messages: 9',
      'User message count: 3',
      'Assistant message count: 4',
      'Tool call count: 2',
      'Total tokens: 400',
      'Input tokens: 100',
      'Output tokens: 200',
      'Cached input tokens: 50 (12.5%)',
      'User message tokens: 100 (25%)',
      'AI response tokens: 200 (50%)',
      'Tool call tokens: 50 (12.5%)',
      'Estimated cost: \$0.1234',
      'Models used: gpt-5.4, gpt-5.4-mini',
      'Status: Available',
      'Tags: Flutter, accessibility',
      'Pinned: Yes',
      'Archived: Yes',
    ]) {
      expect(find.text(text), findsOneWidget);
    }

    expect(
      find.widgetWithText(FilledButton, 'Resume in terminal'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('Unpin session'), findsOneWidget);
    expect(find.bySemanticsLabel('Unarchive session'), findsOneWidget);
    expect(find.text('More'), findsOneWidget);

    for (final action in const [
      'Copy plain resume command',
      'Copy platform resume command',
      'Copy terminal launch command',
      'Run',
      'Edit and run',
      'Open in terminal and fork',
    ]) {
      expect(find.widgetWithText(OutlinedButton, action), findsOneWidget);
    }

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    for (final action in const [
      'Open containing folder',
      'Export Markdown…',
      'Re-parse this session',
      'Add/remove tags',
    ]) {
      expect(find.textContaining(action), findsOneWidget);
    }
  });

  testWidgets('detail copy actions use injected callbacks', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final copied = <String>[];
    final actions = <SessionDetailAction>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionDetailPane(
            row: _detailRow(),
            onCopyText: (text) async {
              copied.add(text);
            },
            onSessionAction: (action) async {
              actions.add(action);
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy session path'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy plain resume command'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Re-parse this session'));
    await tester.pumpAndSettle();

    expect(copied.first, '/home/pawel/.codex/sessions/session.jsonl');
    expect(copied.last, 'codex resume abc123');
    expect(actions, [SessionDetailAction.reparse]);
    expect(find.text('Copied session path.'), findsOneWidget);
  });

  testWidgets('exports full conversation from paged messages', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var fullLoadCalls = 0;
    final exports = <String>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionDetailPane(
            row: _detailRow(
              messages: [
                ConversationMessageViewModel(
                  id: 'old',
                  number: 1,
                  author: ConversationAuthor.user,
                  createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                  preview: 'Older prompt preview',
                  body: '',
                  tokenCount: 4,
                  isBodyLoaded: false,
                ),
                ConversationMessageViewModel(
                  id: 'new',
                  number: 2,
                  author: ConversationAuthor.assistant,
                  createdAtUtc: DateTime.utc(2026, 6, 12, 9, 1),
                  preview: 'Newest answer preview',
                  body: 'Newest answer body',
                  tokenCount: 8,
                ),
              ],
            ),
            onLoadFullConversationMessages: (_) async {
              fullLoadCalls++;
              return [
                ConversationMessageViewModel(
                  id: 'old',
                  number: 1,
                  author: ConversationAuthor.user,
                  createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                  preview: 'Older prompt preview',
                  body: 'Older prompt body',
                  tokenCount: 4,
                ),
                ConversationMessageViewModel(
                  id: 'new',
                  number: 2,
                  author: ConversationAuthor.assistant,
                  createdAtUtc: DateTime.utc(2026, 6, 12, 9, 1),
                  preview: 'Newest answer preview',
                  body: 'Newest answer body',
                  tokenCount: 8,
                ),
              ];
            },
            onExportMarkdown: (_, markdown) async {
              exports.add(markdown);
            },
          ),
        ),
      ),
    );

    expect(fullLoadCalls, 0);
    expect(find.text('Message body not loaded yet.'), findsOneWidget);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export Markdown…'));
    await tester.pumpAndSettle();

    expect(fullLoadCalls, 1);
    expect(exports.single, contains('Older prompt body'));
    expect(exports.single, contains('Newest answer body'));
    expect(exports.single, isNot(contains('Message body not loaded yet')));
  });

  testWidgets('command preview lives in the Details tab', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionDetailPane(row: _detailRow())),
      ),
    );

    expect(find.text('Plain resume command:'), findsNothing);

    await _openDetails(tester);

    expect(find.text('Plain resume command:'), findsOneWidget);
  });

  testWidgets(
    'conversation shows only prompts and replies and finds text in session',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SessionDetailPane(
              row: _detailRow(
                messages: [
                  _message(1, ConversationAuthor.user, 'Find the flaky test'),
                  _message(2, ConversationAuthor.reasoning, 'Thinking quietly'),
                  _message(3, ConversationAuthor.tool, 'rg flaky', tool: true),
                  _message(
                    4,
                    ConversationAuthor.assistant,
                    'The flaky test is X',
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      expect(find.text('Find the flaky test'), findsWidgets);
      expect(find.text('The flaky test is X'), findsWidgets);
      expect(find.text('Thinking quietly'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('^Message 3 Tool')), findsNothing);

      await tester.enterText(
        find.byKey(const Key('conversation-find-field')),
        'flaky',
      );
      await tester.pumpAndSettle();
      expect(find.text('2 of 2'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('1 of 2'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Show tool calls and reasoning'));
      await tester.pumpAndSettle();
      expect(find.text('Thinking quietly'), findsWidgets);
    },
  );

  testWidgets('stats tab shows time split, tools, and subagents', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1600, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final child = SessionRowViewModel(
      id: 'child-1',
      sessionId: 'child-1',
      threadSource: 'subagent',
      agentNickname: 'Mencius',
      agentRole: 'explorer',
      startedAtUtc: DateTime.utc(2026, 6, 12, 9),
      lastMessageAtUtc: DateTime.utc(2026, 6, 12, 9, 3),
      platform: SessionRowPlatform.wsl,
      project: 'Codex Viewer',
      path: '/home/pawel/.codex/sessions/child.jsonl',
      title: 'Explorer child',
      summary: '',
      messageCount: 4,
      totalTokens: 100,
      model: 'gpt-5.4-mini',
      tags: const [],
      status: 'Available',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionDetailPane(
            row: _detailRow(),
            subagents: [child],
            initialTab: SessionDetailTab.stats,
            loadActivity: (row, subagents) async => SessionActivityBundle(
              main: _activity(
                active: const Duration(minutes: 10),
                tools: const Duration(minutes: 4),
                wait: const Duration(minutes: 1),
              ),
              subagents: {
                'child-1': _activity(
                  active: const Duration(minutes: 3),
                  tools: Duration.zero,
                  wait: Duration.zero,
                ),
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.bySemanticsLabel(
        RegExp(
          'Active time split: Model thinking and writing 5m, 50%; '
          'Running tools 4m, 40%; Waiting on subagents 1m, 10%',
        ),
      ),
      findsOneWidget,
    );
    expect(find.text('shell'), findsOneWidget);
    expect(find.text('Mencius'), findsOneWidget);
    expect(find.text('Preconfigured: explorer'), findsOneWidget);
    expect(find.text('gpt-5.6 · high'), findsOneWidget);
    expect(find.text('100 (20%)'), findsOneWidget);
  });

  testWidgets('conversation and focus reader are alternate tabs', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionDetailPane(
            row: _detailRow().copyWithConversationMessages([
              ConversationMessageViewModel(
                id: 'm1',
                number: 1,
                author: ConversationAuthor.user,
                createdAtUtc: DateTime.utc(2026, 6, 12, 9),
                preview: 'Conversation preview',
                body: 'Conversation body',
                tokenCount: 10,
              ),
            ]),
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.text('Conversation'));
    expect(
      find.bySemanticsLabel('Selected message 1 of 1. User.'),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('message-card-1')),
        matching: find.text('Conversation body'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(Tab, 'Focus reader'));
    await tester.pumpAndSettle();

    expect(find.text('Message 1 of 1'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Selected message 1 of 1. User.'),
      findsOneWidget,
    );
  });

  testWidgets('shows main and subagent usage split', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionDetailPane(
            row: _detailRow().copyWithUsageRollup(
              const SessionUsageRollup(
                mainTokens: 400,
                subagentTokens: 250,
                totalTokens: 650,
                mainEstimatedCostText: '0.1234',
                subagentEstimatedCostText: '0.0706',
                totalEstimatedCostText: '0.194',
                mainCostUnknown: false,
                subagentCostUnknown: false,
                totalCostUnknown: false,
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.text('650 tokens'), findsOneWidget);
    await _openDetails(tester);

    for (final text in const [
      'Usage total: 650 tokens | \$0.194',
      'Usage main: 400 tokens | \$0.1234',
      'Usage subagents: 250 tokens | \$0.0706',
    ]) {
      expect(find.text(text), findsOneWidget);
    }
  });

  testWidgets('formats token breakdown numbers consistently', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionDetailPane(
            row: _detailRow(
              messageCount: 12345,
              userMessageCount: 3456,
              assistantMessageCount: 7890,
              toolCallCount: 999,
              inputTokens: 1234567,
              outputTokens: 2345678,
              cachedInputTokens: 3456789,
              totalTokens: 6000000,
              userMessageTokens: 1000000,
              assistantResponseTokens: 2000000,
              toolCallTokens: 3000000,
            ),
          ),
        ),
      ),
    );

    expect(find.text('${formatCompactInt(12345)} messages'), findsOneWidget);
    expect(find.text('${formatCompactInt(6000000)} tokens'), findsOneWidget);

    await _openDetails(tester);

    for (final text in [
      'Total messages: ${formatGroupedInt(12345)}',
      'User message count: ${formatGroupedInt(3456)}',
      'Assistant message count: ${formatGroupedInt(7890)}',
      'Tool call count: 999',
      'Total tokens: ${formatGroupedInt(6000000)}',
      'Input tokens: ${formatGroupedInt(1234567)}',
      'Output tokens: ${formatGroupedInt(2345678)}',
      'Cached input tokens: ${formatGroupedInt(3456789)} (57.6%)',
      'User message tokens: ${formatGroupedInt(1000000)} (16.7%)',
      'AI response tokens: ${formatGroupedInt(2000000)} (33.3%)',
      'Tool call tokens: ${formatGroupedInt(3000000)} (50%)',
    ]) {
      expect(find.text(text), findsOneWidget);
    }
  });

  testWidgets('hides the title area when the session has no title', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionDetailPane(row: _detailRow(title: '')),
        ),
      ),
    );

    expect(find.text('Selected: '), findsNothing);
    await _openDetails(tester);
    expect(find.text('Platform: WSL'), findsOneWidget);
  });

  testWidgets('loading state is visible and exposed to screen readers', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionDetailPane(row: _detailRow(), isLoadingMessages: true),
        ),
      ),
    );

    expect(find.text('Loading conversation messages'), findsOneWidget);
    expect(find.text('Conversation messages loading'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Loading session conversation messages.'),
      findsOneWidget,
    );
    expect(find.text('No conversation messages'), findsNothing);
  });

  testWidgets('session detail transitions between selected sessions', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: TestSessionsScreen(
          initialRows: [
            _detailRow(
              id: 'row-1',
              sessionId: 'row-1',
              title: 'First detail',
              project: 'First project',
              isArchived: false,
            ),
            _detailRow(
              id: 'row-2',
              sessionId: 'row-2',
              title: 'Second detail',
              project: 'Second project',
              isArchived: false,
            ),
          ],
          settings: AppSettings.defaults().copyWith(
            ui: AppSettings.defaults().ui.copyWithMotion(AppMotionMode.normal),
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel(RegExp('Session First detail')));
    await tester.pumpAndSettle();
    expect(find.text('First detail'), findsWidgets);

    await tester.tap(find.bySemanticsLabel(RegExp('Session Second detail')));
    await tester.pump();

    expect(find.byType(AnimatedSwitcher), findsWidgets);
    expect(find.byType(FadeTransition), findsWidgets);
    expect(find.byType(SlideTransition), findsWidgets);
    expect(
      find.bySemanticsLabel('Selected session First detail'),
      findsNothing,
    );
    expect(find.text('First detail'), findsWidgets);
    expect(find.text('Second detail'), findsWidgets);

    await tester.pumpAndSettle();
    expect(find.text('Second detail'), findsWidgets);
  });

  testWidgets('session detail reduced motion avoids pane movement', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: TestSessionsScreen(
          initialRows: [
            _detailRow(
              id: 'row-1',
              sessionId: 'row-1',
              title: 'First detail',
              project: 'First project',
              isArchived: false,
            ),
            _detailRow(
              id: 'row-2',
              sessionId: 'row-2',
              title: 'Second detail',
              project: 'Second project',
              isArchived: false,
            ),
          ],
          settings: AppSettings.defaults().copyWith(
            ui: AppSettings.defaults().ui.copyWithMotion(AppMotionMode.reduced),
          ),
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel(RegExp('Session First detail')));
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsLabel(RegExp('Session Second detail')));
    await tester.pump();

    expect(
      find.descendant(
        of: find.byType(AnimatedSwitcher),
        matching: find.byType(SlideTransition),
      ),
      findsNothing,
    );
  });
}

Future<void> _openDetails(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1400, 2600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(Tab, 'Details'));
  await tester.pumpAndSettle();
}

ConversationMessageViewModel _message(
  int number,
  ConversationAuthor author,
  String body, {
  bool tool = false,
}) {
  return ConversationMessageViewModel(
    id: 'm$number',
    number: number,
    author: author,
    createdAtUtc: DateTime.utc(2026, 6, 12, 9, number),
    preview: body,
    body: body,
    tokenCount: 5,
    hasToolOutput: tool,
  );
}

SessionActivityStats _activity({
  required Duration active,
  required Duration tools,
  required Duration wait,
}) {
  final start = DateTime.utc(2026, 6, 12, 9);
  return SessionActivityStats(
    firstEventAtUtc: start,
    lastEventAtUtc: start.add(active),
    turnCount: 2,
    activeTime: active,
    toolTime: tools,
    agentWaitTime: wait,
    tools: [
      SessionToolUsage(
        name: 'shell',
        callCount: 3,
        failedCount: 1,
        totalTime: tools,
        isAgentCoordination: false,
      ),
    ],
    models: const [
      SessionModelUsage(
        model: 'gpt-5.6',
        reasoningEffort: 'high',
        turnCount: 2,
      ),
    ],
    spawnedAgents: const [],
    reasoningOutputTokens: 10,
  );
}

SessionRowViewModel _detailRow({
  String id = 'row-1',
  String sessionId = 'abc123',
  String title = 'Flutter accessibility spike',
  String project = 'Codex Viewer',
  bool isArchived = true,
  List<ConversationMessageViewModel> messages = const [],
  int messageCount = 9,
  int userMessageCount = 3,
  int assistantMessageCount = 4,
  int toolCallCount = 2,
  int inputTokens = 100,
  int outputTokens = 200,
  int cachedInputTokens = 50,
  int totalTokens = 400,
  int userMessageTokens = 100,
  int assistantResponseTokens = 200,
  int toolCallTokens = 50,
}) {
  return SessionRowViewModel(
    id: id,
    sessionId: sessionId,
    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
    lastMessageAtUtc: DateTime.utc(2026, 6, 12, 10, 30),
    duration: const Duration(minutes: 90),
    platform: SessionRowPlatform.wsl,
    project: project,
    path: '/home/pawel/.codex/sessions/session.jsonl',
    sourceFilePath: '/home/pawel/.codex/sessions/session.jsonl',
    displayPath: '/home/pawel/.codex/sessions/session.jsonl',
    workingDirectory: '/home/pawel/projects/codex-viewer',
    title: title,
    summary: 'Session summary',
    messageCount: messageCount,
    userMessageCount: userMessageCount,
    assistantMessageCount: assistantMessageCount,
    toolCallCount: toolCallCount,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cachedInputTokens: cachedInputTokens,
    totalTokens: totalTokens,
    userMessageTokens: userMessageTokens,
    assistantResponseTokens: assistantResponseTokens,
    toolCallTokens: toolCallTokens,
    estimatedCostText: '0.1234',
    costUnknown: false,
    model: 'gpt-5.4',
    modelsUsed: const ['gpt-5.4', 'gpt-5.4-mini'],
    tags: const ['Flutter', 'accessibility'],
    status: 'Available',
    isPinned: true,
    isArchived: isArchived,
    conversationMessages: messages,
  );
}
