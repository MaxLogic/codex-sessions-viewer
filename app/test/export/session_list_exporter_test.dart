import 'package:codex_sessions_viewer/src/export/session_list_exporter.dart';
import 'package:codex_sessions_viewer/src/ui/models/conversation_message_view_model.dart';
import 'package:codex_sessions_viewer/src/ui/models/session_row_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import '../support/fixture_settings.dart';

void main() {
  test('exports meaningful Claude first instructions', () {
    final exporter = SessionListExporter(settings: fixtureDefaultSettings());
    final messages = [
      _message(
        0,
        ConversationAuthor.user,
        '<local-command-caveat>local only</local-command-caveat>',
      ),
      _message(
        1,
        ConversationAuthor.user,
        '<command-name>/model</command-name>\n<command-message>model</command-message>\n<command-args></command-args>',
      ),
      _message(
        2,
        ConversationAuthor.user,
        '<local-command-stdout>Opus</local-command-stdout>',
      ),
      _message(
        3,
        ConversationAuthor.user,
        '<command-name>/goal</command-name>\n<command-message>goal</command-message>\n<command-args>continue resolving open tasks in appropriate slices.</command-args>',
      ),
      _message(4, ConversationAuthor.assistant, 'Real answer.'),
      _message(
        5,
        ConversationAuthor.reasoning,
        'Reasoning content is encrypted and cannot be displayed.',
      ),
      _message(6, ConversationAuthor.tool, 'Tool output'),
      _message(7, ConversationAuthor.system, 'System event'),
      _message(8, ConversationAuthor.user, 'Next question'),
    ];
    String export(List<ConversationMessageViewModel> messages) =>
        exporter.exportMarkdown(
          [
            _row(
              id: 'one',
              sessionId: 'one',
              workingDirectory: 'project',
              conversationMessages: messages,
            ),
          ],
          includeFirstMessage: true,
          includeLastMessage: true,
        );
    final result = export(messages.reversed.toList());
    expect(
      result,
      contains(
        '### First message \u{1F464}\n\ncontinue resolving open tasks in appropriate slices.',
      ),
    );
    expect(result, contains('### Last message \u{1F916}\n\nReal answer.'));
    expect(result, isNot(contains('<command-name>')));
    expect(
      export(messages.take(3).toList()),
      isNot(contains('### First message')),
    );
    expect(
      export(messages.take(3).toList()),
      isNot(contains('### Last message')),
    );
    expect(
      export([
        _message(
          0,
          ConversationAuthor.user,
          'Explain <command-name>/model</command-name> please.',
        ),
      ]),
      contains('Explain <command-name>/model</command-name> please.'),
    );
    expect(
      export([
        _message(
          0,
          ConversationAuthor.user,
          '/model is a command I need help with',
        ),
      ]),
      contains('/model is a command I need help with'),
    );
  });
  test('stats abbreviate large counts and express long durations in days', () {
    final exporter = SessionListExporter(settings: fixtureDefaultSettings());
    for (final entry in [
      (100000, '100k'),
      (10000000, '10M'),
      (484213148, '484M'),
      (1000000000, '1B'),
      (1000000000000, '1T'),
    ]) {
      final output = exporter.exportMarkdown([
        _row(
          id: 'one',
          sessionId: 'one',
          workingDirectory: 'project',
          totalTokens: entry.$1,
          duration: const Duration(hours: 254, minutes: 44),
        ),
      ]);
      expect(output, contains('Tokens: ${entry.$2},'));
      expect(output, contains('Duration: 10d 14h 44m'));
      expect(output, isNot(contains('UTC')));
    }
  });

  for (final platform in [SessionRowPlatform.macos, SessionRowPlatform.linux]) {
    test(
      'native ${platform.name} export guards Markdown CSV and isolate formatting',
      () async {
        final settings = fixtureDefaultSettings();
        final exporter = SessionListExporter(settings: settings);
        final row = _row(
          id: 'native-row',
          sessionId: 'native-session',
          workingDirectory: '/home/native/project',
          platform: platform,
        );
        final outputs = [
          exporter.exportMarkdown([row]),
          exporter.exportCsv([row]),
          await formatSessionListMarkdown(settings, List.filled(100, row)),
        ];
        for (final output in outputs) {
          expect(
            output,
            contains('Resume is unavailable for this source platform.'),
          );
          expect(output, isNot(contains('codex resume native-session')));
          expect(output, isNot(contains('wsl.exe')));
          expect(output, isNot(contains('```powershell')));
        }
      },
    );
  }

  test('exports every supplied session as a compact Markdown overview', () {
    final exporter = SessionListExporter(settings: fixtureDefaultSettings());

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
    expect(markdown, contains('**Stats**\n\n'));
    expect(markdown, contains('Tokens: 123k, in: 0 (0 cached, 0%), out: 0'));
    expect(markdown, contains('Cost: \$1.24 (estimate)'));
    expect(markdown, contains('\n\n---\n\n## Parser work — DelphiAiKit'));
    expect(
      markdown,
      contains(
        'wsl.exe -d Ubuntu --cd /home/pawel/projects/DelphiAiKit '
        "bash -lc \"'codex' 'resume' 'session-1'\"\n"
        '```\n\n```bash\ncodex resume session-1\n```',
      ),
    );
  });

  test('exports supplied sessions as Excel-friendly CSV rows', () {
    final exporter = SessionListExporter(settings: fixtureDefaultSettings());

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
        'status,session_id,harness\r\n',
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
        'Available,session-1,Codex\r\n',
      ),
    );
  });

  test('includes requested first and last messages in Markdown', () {
    final exporter = SessionListExporter(settings: fixtureDefaultSettings());
    final row = _row(
      id: 'messages',
      sessionId: 'session-messages',
      workingDirectory: r'F:\projects\MaxLogic\codex-sessions-viewer',
      conversationMessages: [
        _message(
          1,
          ConversationAuthor.user,
          ' \r\nFirst prompt.\r\n\r\n \t\r\n  Indented line.\r\n ',
        ),
        _message(2, ConversationAuthor.tool, 'Intermediate tool output.'),
        _message(
          3,
          ConversationAuthor.assistant,
          '\nLast response.\n\t \n\nDone.\n',
        ),
      ],
    );

    final markdown = exporter.exportMarkdown(
      [row],
      includeFirstMessage: true,
      includeLastMessage: true,
    );

    expect(
      markdown,
      contains('### First message 👤\n\nFirst prompt.\n  Indented line.'),
    );
    expect(markdown, contains('### Last message 🤖\n\nLast response.\nDone.'));
    expect(markdown, isNot(contains('Intermediate tool output.')));

    final firstOnly = exporter.exportMarkdown([row], includeFirstMessage: true);
    expect(firstOnly, contains('### First message 👤'));
    expect(firstOnly, isNot(contains('### Last message')));
  });
  test('skips lifecycle noise and unwraps completion text', () {
    final exporter = SessionListExporter(settings: fixtureDefaultSettings());
    final row = _row(
      id: 'events',
      sessionId: 'events',
      workingDirectory: r'F:\projects',
      conversationMessages: [
        _message(
          1,
          ConversationAuthor.tool,
          '{"type":"task_started","turn_id":"private-turn","started_at":123}',
        ),
        _message(2, ConversationAuthor.user, 'Please prepare the release.'),
        _message(
          3,
          ConversationAuthor.tool,
          '{"type":"task_complete","turn_id":"private-turn",'
          '"last_agent_message":"**Release ready.**","duration_ms":456}',
        ),
        _message(
          4,
          ConversationAuthor.tool,
          '{"type":"token_count","info":{}}',
        ),
      ],
    );
    final markdown = exporter.exportMarkdown(
      [row],
      includeFirstMessage: true,
      includeLastMessage: true,
    );
    expect(
      markdown,
      contains('### First message 👤\n\nPlease prepare the release.'),
    );
    expect(markdown, contains('### Last message 🤖\n\n**Release ready.**'));
    for (final noise in [
      'task_started',
      'task_complete',
      'turn_id',
      'last_agent_message',
      'duration_ms',
      'token_count',
      '(Tool)',
    ]) {
      expect(markdown, isNot(contains(noise)));
    }
    expect(
      markdown,
      endsWith(
        '**Legend:** 👤 User · 🤖 Assistant · ⚙ Tool · 💭 Reasoning · ℹ System',
      ),
    );
    expect(exporter.exportMarkdown([row]), isNot(contains('Legend')));
  });
  test('first message is the earliest user prompt, or absent without one', () {
    final exporter = SessionListExporter(settings: fixtureDefaultSettings());
    final preamble = [
      _message(1, ConversationAuthor.system, 'System instructions.'),
      _message(2, ConversationAuthor.assistant, 'Assistant introduction.'),
      _message(3, ConversationAuthor.reasoning, 'Internal reasoning.'),
      _message(4, ConversationAuthor.tool, 'Tool output.'),
    ];
    for (final hasUser in [true, false]) {
      final row = _row(
        id: 'prompt',
        sessionId: 'prompt',
        workingDirectory: r'F:\projects',
        conversationMessages: [
          if (hasUser) _message(8, ConversationAuthor.user, 'Later prompt.'),
          ...preamble,
          if (hasUser) _message(5, ConversationAuthor.user, 'Original prompt.'),
        ],
      );
      final markdown = exporter.exportMarkdown([
        row,
      ], includeFirstMessage: true);
      if (hasUser) {
        expect(markdown, contains('### First message 👤\n\nOriginal prompt.'));
        expect(markdown, isNot(contains('Later prompt.')));
      } else {
        expect(markdown, isNot(contains('### First message')));
      }
      for (final message in preamble) {
        expect(markdown, isNot(contains(message.body)));
      }
    }
  });

  test('large list formatting on a worker preserves exact Markdown', () async {
    final settings = fixtureDefaultSettings();
    final rows = [
      for (var index = 0; index < 100; index++)
        _row(
          id: 'row-$index',
          sessionId: 'session-$index',
          workingDirectory: r'F:\projects',
        ),
    ];
    final expected = SessionListExporter(
      settings: settings,
    ).exportMarkdown(rows);
    expect(await formatSessionListMarkdown(settings, rows), expected);
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
  int totalTokens = 123456,
  Duration duration = const Duration(hours: 1, minutes: 48),
  List<ConversationMessageViewModel> conversationMessages = const [],
}) {
  return SessionRowViewModel(
    id: id,
    sessionId: sessionId,
    threadName: threadName,
    startedAtUtc: startedAtUtc ?? DateTime.utc(2026, 8, 6, 9, 14),
    lastMessageAtUtc: lastMessageAtUtc ?? DateTime.utc(2026, 8, 6, 11, 2),
    duration: duration,
    platform: platform,
    project: 'Codex Viewer',
    path: workingDirectory,
    workingDirectory: workingDirectory,
    title: title,
    summary: 'Session summary',
    messageCount: 87,
    totalTokens: totalTokens,
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
