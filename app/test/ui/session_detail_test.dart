import 'package:codex_sessions_viewer/src/ui/models/session_row_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/widgets/session_detail_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows required metadata and detail actions', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionDetailPane(row: _detailRow())),
      ),
    );

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

    for (final action in const [
      'Copy session path',
      'Copy working directory',
      'Copy plain resume command',
      'Copy platform resume command',
      'Open containing folder',
      'Open terminal here',
      'Open in terminal and resume',
      'Copy terminal launch command',
      'Export Markdown',
      'Copy conversation Markdown',
      'Re-parse this session',
      'Unpin session',
      'Unarchive session',
      'Add/remove tags',
      'Assign/change project',
    ]) {
      expect(find.widgetWithText(OutlinedButton, action), findsOneWidget);
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

    await tester.tap(find.widgetWithText(OutlinedButton, 'Copy session path'));
    await tester.pumpAndSettle();
    final copyResume = find.widgetWithText(
      OutlinedButton,
      'Copy plain resume command',
    );
    await tester.ensureVisible(copyResume);
    await tester.tap(copyResume);
    await tester.pumpAndSettle();
    final reparse = find.widgetWithText(
      OutlinedButton,
      'Re-parse this session',
    );
    await tester.ensureVisible(reparse);
    await tester.tap(reparse);
    await tester.pumpAndSettle();

    expect(copied.first, '/home/pawel/.codex/sessions/session.jsonl');
    expect(copied.last, 'codex resume abc123');
    expect(actions, [SessionDetailAction.reparse]);
    expect(find.text('Copied session path.'), findsOneWidget);
  });

  testWidgets(
    'keeps command preview collapsed in the selected-session header',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SessionDetailPane(row: _detailRow())),
        ),
      );

      expect(find.text('Commands'), findsOneWidget);
      expect(find.text('Plain resume command:'), findsNothing);

      await tester.tap(find.text('Commands'));
      await tester.pumpAndSettle();

      expect(find.text('Plain resume command:'), findsOneWidget);
    },
  );
}

SessionRowViewModel _detailRow() {
  return SessionRowViewModel(
    id: 'row-1',
    sessionId: 'abc123',
    startedAtUtc: DateTime.utc(2026, 6, 12, 9),
    lastMessageAtUtc: DateTime.utc(2026, 6, 12, 10, 30),
    duration: const Duration(minutes: 90),
    platform: SessionRowPlatform.wsl,
    project: 'Codex Viewer',
    path: '/home/pawel/.codex/sessions/session.jsonl',
    sourceFilePath: '/home/pawel/.codex/sessions/session.jsonl',
    displayPath: '/home/pawel/.codex/sessions/session.jsonl',
    workingDirectory: '/home/pawel/projects/codex-viewer',
    title: 'Flutter accessibility spike',
    summary: 'Session summary',
    messageCount: 9,
    userMessageCount: 3,
    assistantMessageCount: 4,
    toolCallCount: 2,
    inputTokens: 100,
    outputTokens: 200,
    cachedInputTokens: 50,
    totalTokens: 400,
    userMessageTokens: 100,
    assistantResponseTokens: 200,
    toolCallTokens: 50,
    estimatedCostText: '0.1234',
    costUnknown: false,
    model: 'gpt-5.4',
    modelsUsed: const ['gpt-5.4', 'gpt-5.4-mini'],
    tags: const ['Flutter', 'accessibility'],
    status: 'Available',
    isPinned: true,
    isArchived: true,
  );
}
