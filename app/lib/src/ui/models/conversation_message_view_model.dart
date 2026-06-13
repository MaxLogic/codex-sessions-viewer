enum ConversationAuthor { user, assistant, tool }

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
  });

  final String id;
  final int number;
  final ConversationAuthor author;
  final DateTime createdAtUtc;
  final String preview;
  final String body;
  final int tokenCount;
  final bool hasError;
  final bool hasToolOutput;
  final bool isLong;

  String get authorLabel => switch (author) {
    ConversationAuthor.user => 'User',
    ConversationAuthor.assistant => 'Assistant',
    ConversationAuthor.tool => 'Tool',
  };

  int get lineCount => body.isEmpty ? 0 : body.split('\n').length;
}
