import 'conversation_message_view_model.dart';

enum SessionRowPlatform { windows, wsl }

class SessionRowViewModel {
  const SessionRowViewModel({
    required this.id,
    required this.startedAtUtc,
    required this.lastMessageAtUtc,
    required this.platform,
    required this.project,
    required this.path,
    required this.title,
    required this.summary,
    required this.messageCount,
    required this.totalTokens,
    required this.model,
    required this.tags,
    required this.status,
    this.sessionId = '',
    this.sourceFilePath = '',
    this.displayPath = '',
    this.workingDirectory = '',
    this.duration,
    this.userMessageCount = 0,
    this.assistantMessageCount = 0,
    this.toolCallCount = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedInputTokens = 0,
    this.userMessageTokens = 0,
    this.assistantResponseTokens = 0,
    this.toolCallTokens = 0,
    this.estimatedCostText,
    this.costUnknown = true,
    this.modelsUsed = const [],
    this.conversationMessages = const [],
    this.isPinned = false,
    this.isArchived = false,
    this.hasError = false,
  });

  final String id;
  final DateTime startedAtUtc;
  final DateTime lastMessageAtUtc;
  final SessionRowPlatform platform;
  final String project;
  final String path;
  final String title;
  final String summary;
  final int messageCount;
  final int totalTokens;
  final String model;
  final List<String> tags;
  final String status;
  final String sessionId;
  final String sourceFilePath;
  final String displayPath;
  final String workingDirectory;
  final Duration? duration;
  final int userMessageCount;
  final int assistantMessageCount;
  final int toolCallCount;
  final int inputTokens;
  final int outputTokens;
  final int cachedInputTokens;
  final int userMessageTokens;
  final int assistantResponseTokens;
  final int toolCallTokens;
  final String? estimatedCostText;
  final bool costUnknown;
  final List<String> modelsUsed;
  final List<ConversationMessageViewModel> conversationMessages;
  final bool isPinned;
  final bool isArchived;
  final bool hasError;

  String get platformLabel => switch (platform) {
    SessionRowPlatform.windows => 'Windows',
    SessionRowPlatform.wsl => 'WSL',
  };

  String get sourcePathForDisplay =>
      sourceFilePath.isEmpty ? path : sourceFilePath;

  String get displayPathForDetail => displayPath.isEmpty ? path : displayPath;

  String get workingDirectoryForCommands =>
      workingDirectory.isEmpty ? displayPathForDetail : workingDirectory;

  List<String> get modelsUsedForDetail {
    if (modelsUsed.isNotEmpty) {
      return modelsUsed;
    }
    final trimmed = model.trim();
    return trimmed.isEmpty ? const [] : [trimmed];
  }

  String get estimatedCostDisplay =>
      costUnknown ? 'Cost unknown' : '\$${estimatedCostText ?? '0'}';

  int get tokenBreakdownTotal {
    if (totalTokens > 0) {
      return totalTokens;
    }
    return userMessageTokens + assistantResponseTokens + toolCallTokens;
  }

  String tokenShareText(int tokens) {
    final total = tokenBreakdownTotal;
    if (total <= 0 || tokens <= 0) {
      return '0%';
    }
    final rounded = double.parse((tokens * 100 / total).toStringAsFixed(1));
    if (rounded == rounded.roundToDouble()) {
      return '${rounded.toStringAsFixed(0)}%';
    }
    return '${rounded.toStringAsFixed(1)}%';
  }

  SessionRowViewModel copyWithConversationMessages(
    List<ConversationMessageViewModel> messages,
  ) {
    return SessionRowViewModel(
      id: id,
      sessionId: sessionId,
      sourceFilePath: sourceFilePath,
      displayPath: displayPath,
      workingDirectory: workingDirectory,
      startedAtUtc: startedAtUtc,
      lastMessageAtUtc: lastMessageAtUtc,
      duration: duration,
      platform: platform,
      project: project,
      path: path,
      title: title,
      summary: summary,
      messageCount: messageCount,
      userMessageCount: userMessageCount,
      assistantMessageCount: assistantMessageCount,
      toolCallCount: toolCallCount,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cachedInputTokens: cachedInputTokens,
      userMessageTokens: userMessageTokens,
      assistantResponseTokens: assistantResponseTokens,
      toolCallTokens: toolCallTokens,
      estimatedCostText: estimatedCostText,
      costUnknown: costUnknown,
      totalTokens: totalTokens,
      model: model,
      modelsUsed: modelsUsed,
      tags: tags,
      status: status,
      conversationMessages: messages,
      isPinned: isPinned,
      isArchived: isArchived,
      hasError: hasError,
    );
  }
}
