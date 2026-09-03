import 'package:codex_sessions_viewer/src/config/app_settings.dart';
import 'package:codex_sessions_viewer/src/export/session_list_exporter.dart';
import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/models/session_row_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports every supplied session as a compact Markdown overview', () {
    final exporter = SessionListExporter(settings: AppSettings.defaults());

    final markdown = exporter.exportMarkdown([
      _row(
        id: 'newer',
        sessionId: 'session-2',
        threadName: 'Clipboard reliability',
        workingDirectory: r'F:\projects\MaxLogic\codex-sessions-viewer',
        lastMessageAtUtc: DateTime.utc(2026, 8, 6, 11, 2),
      ),
      _row(
        id: 'older',
        sessionId: 'session-1',
        title: 'Parser work',
        workingDirectory: '/home/pawel/projects/DelphiAiKit',
        platform: SessionRowPlatform.wsl,
        startedAtUtc: DateTime.utc(2026, 8, 5, 8),
        lastMessageAtUtc: DateTime.utc(2026, 8, 5, 8, 30),
      ),
    ]);

    expect(markdown, startsWith('# Sessions (2)\n\n'));
    expect(
      markdown,
      contains('## Clipboard reliability — codex-sessions-viewer\n\n'),
    );
    expect(
      markdown,
      contains(
        '`F:\\projects\\MaxLogic\\codex-sessions-viewer`\n\n'
        '```powershell\n'
        'codex resume session-2\n'
        '```',
      ),
    );
    expect(
      markdown,
      contains(
        '**Started:** 2026-08-06 09:14 UTC · '
        '**Last:** 2026-08-06 11:02 UTC · '
        '**Duration:** 1h 48m · '
        '**Messages:** 87 · '
        '**Tokens:** 123,456 · '
        '**Cost:** \$1.24 · '
        '**Model:** GPT 5.6 · '
        '**Platform:** Windows',
      ),
    );
    expect(markdown, contains('\n\n---\n\n## Parser work — DelphiAiKit'));
    expect(
      markdown,
      contains(
        'wsl.exe -d Ubuntu --cd /home/pawel/projects/DelphiAiKit '
        "bash -lc \"'codex' 'resume' 'session-1'\"",
      ),
    );
  });

  test('exports supplied sessions as Excel-friendly CSV rows', () {
    final exporter = SessionListExporter(settings: AppSettings.defaults());

    final csv = exporter.exportCsv([
      _row(
        id: 'wsl-row',
        sessionId: 'session-1',
        threadName: 'Parser, "review"',
        title: 'Parser work',
        workingDirectory: '/home/pawel/projects/DelphiAiKit',
        platform: SessionRowPlatform.wsl,
      ),
    ]);

    expect(
      csv,
      startsWith(
        '\ufeffname,thread_name,title,project,working_directory,'
        'resume_command,started_utc,last_message_utc,duration_minutes,'
        'message_count,total_tokens,estimated_cost,model,platform,tags,'
        'status,session_id\r\n',
      ),
    );
    expect(csv, contains('"Parser, ""review"" — DelphiAiKit"'));
    expect(csv, contains('"Parser, ""review"""'));
    expect(
      csv,
      contains(
        '"wsl.exe -d Ubuntu --cd /home/pawel/projects/DelphiAiKit '
        'bash -lc ""\'codex\' \'resume\' \'session-1\'"""',
      ),
    );
    expect(
      csv,
      endsWith(
        ',87,123456,1.24,gpt-5.6,WSL,accessibility,'
        'Available,session-1\r\n',
      ),
    );
  });

  test('includes requested first and last messages in Markdown', () {
    final exporter = SessionListExporter(settings: AppSettings.defaults());
    final row = _row(
      id: 'messages',
      sessionId: 'session-messages',
      workingDirectory: r'F:\projects\MaxLogic\codex-sessions-viewer',
      conversationMessages: [
        _message(1, ConversationAuthor.user, 'First prompt.'),
        _message(2, ConversationAuthor.tool, 'Intermediate tool output.'),
        _message(3, ConversationAuthor.assistant, 'Last response.'),
      ],
    );

    final markdown = exporter.exportMarkdown(
      [row],
      includeFirstMessage: true,
      includeLastMessage: true,
    );

    expect(markdown, contains('### First message (User)\n\nFirst prompt.'));
    expect(
      markdown,
      contains('### Last message (Assistant)\n\nLast response.'),
    );
    expect(markdown, isNot(contains('Intermediate tool output.')));

    final firstOnly = exporter.exportMarkdown([row], includeFirstMessage: true);
    expect(firstOnly, contains('### First message (User)'));
    expect(firstOnly, isNot(contains('### Last message')));
  });
}

SessionRowViewModel _row({
  required String id,
  required String sessionId,
  String threadName = '',
  String title = '',
  required String workingDirectory,
  SessionRowPlatform platform = SessionRowPlatform.windows,
  DateTime? startedAtUtc,
  DateTime? lastMessageAtUtc,
  List<ConversationMessageViewModel> conversationMessages = const [],
}) {
  return SessionRowViewModel(
    id: id,
    sessionId: sessionId,
    threadName: threadName,
    startedAtUtc: startedAtUtc ?? DateTime.utc(2026, 8, 6, 9, 14),
    lastMessageAtUtc: lastMessageAtUtc ?? DateTime.utc(2026, 8, 6, 11, 2),
    duration: const Duration(hours: 1, minutes: 48),
    platform: platform,
    project: 'Codex Viewer',
    path: workingDirectory,
    workingDirectory: workingDirectory,
    title: title,
    summary: 'Session summary',
    messageCount: 87,
    totalTokens: 123456,
    estimatedCostText: '1.24',
    costUnknown: false,
    model: 'gpt-5.6',
    tags: const ['accessibility'],
    status: 'Available',
    conversationMessages: conversationMessages,
  );
}

ConversationMessageViewModel _message(
  int number,
  ConversationAuthor author,
  String body,
) {
  return ConversationMessageViewModel(
    id: 'message-$number',
    number: number,
    author: author,
    createdAtUtc: DateTime.utc(2026, 8, 6, 10, number),
    preview: body,
    body: body,
    tokenCount: null,
  );
}
