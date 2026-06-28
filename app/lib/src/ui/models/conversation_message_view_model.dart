enum ConversationAuthor { user, assistant, tool, reasoning, system }

class ConversationMessageViewModel {
  const ConversationMessageViewModel({
    required this.id,
    required this.number,
    required this.author,
    required this.createdAtUtc,
    required this.preview,
    required this.body,
    required this.tokenCount,
    this.hasError = false,
    this.hasToolOutput = false,
    this.isLong = false,
    this.isBodyLoaded = true,
  });

  final String id;
  final int number;
  final ConversationAuthor author;
  final DateTime createdAtUtc;
  final String preview;
  final String body;
  final int? tokenCount;
  final bool hasError;
  final bool hasToolOutput;
  final bool isLong;
  final bool isBodyLoaded;

  String get authorLabel => switch (author) {
    ConversationAuthor.user => 'User',
    ConversationAuthor.assistant => 'Assistant',
    ConversationAuthor.tool => 'Tool',
    ConversationAuthor.reasoning => 'Reasoning',
    ConversationAuthor.system => 'System',
  };

  String get tokenLabel {
    final count = tokenCount;
    return count == null ? 'tokens unknown' : '$count tokens';
  }

  int get lineCount => body.isEmpty ? 0 : body.split('\n').length;
}
