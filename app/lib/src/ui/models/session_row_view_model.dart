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
    this.modelsUsed = const [],
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
  final List<String> modelsUsed;
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

  List<String> get modelsUsedForDetail =>
      modelsUsed.isEmpty ? [model] : modelsUsed;
}
