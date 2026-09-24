import '../../usage/usage_summary.dart';
import 'conversation_message_view_model.dart';
import 'session_label_formatter.dart';

enum SessionRowPlatform { windows, wsl }

enum SessionRowSourceState { active, codexArchived, missing }

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
    this.harness = 'codex',
    this.threadName = '',
    this.threadSource = '',
    this.parentThreadId = '',
    this.agentNickname = '',
    this.agentRole = '',
    this.subagentDepth,
    this.sourceFilePath = '',
    this.displayPath = '',
    this.workingDirectory = '',
    this.openablePath = '',
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
    this.costUpdating = false,
    this.costPartialUnsupportedUnits = false,
    this.modelsUsed = const [],
    this.conversationMessages = const [],
    this.usageRollup,
    this.isPinned = false,
    this.isArchived = false,
    this.sourceState = SessionRowSourceState.active,
    this.hasError = false,
    this.evalReady = false,
    this.evalStatus = '',
    this.evalNotes = '',
    this.evalExpectedOutput = '',
    this.evalReviewedAtUtc,
    this.evalUpdatedAtUtc,
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

  /// The agent harness that wrote the session (`codex`, `claude`). Session
  /// IDs are unique only within a harness.
  final String harness;

  String get harnessLabel => SessionLabelFormatter.harness(harness);
  final String threadName;
  final String threadSource;
  final String parentThreadId;
  final String agentNickname;
  final String agentRole;
  final int? subagentDepth;
  final String sourceFilePath;
  final String displayPath;
  final String workingDirectory;
  final String openablePath;
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
  final bool costUpdating;
  final bool costPartialUnsupportedUnits;
  final List<String> modelsUsed;
  final List<ConversationMessageViewModel> conversationMessages;
  final SessionUsageRollup? usageRollup;
  final bool isPinned;
  final bool isArchived;
  final SessionRowSourceState sourceState;
  final bool hasError;
  final bool evalReady;
  final String evalStatus;
  final String evalNotes;
  final String evalExpectedOutput;
  final DateTime? evalReviewedAtUtc;
  final DateTime? evalUpdatedAtUtc;

  String get evalStatusLabel {
    return switch (evalStatus.trim().toLowerCase()) {
      'correct' => 'Correct',
      'incorrect' => 'Incorrect',
      'needs_review' || 'needs review' => 'Needs review',
      'blocked' => 'Blocked',
      'not_reviewed' || 'not reviewed' || '' => 'Not reviewed',
      _ => 'Not reviewed',
    };
  }

  String get platformLabel => SessionLabelFormatter.platform(platform.name);

  /// [id] (a session or parent thread ID) qualified by [harness], so equal
  /// IDs from different harnesses never match; empty for an empty ID.
  String harnessSessionKey(String id) {
    final trimmed = id.trim();
    return trimmed.isEmpty ? '' : '$harness:$trimmed';
  }

  bool get isSubagentSession => threadSource.toLowerCase() == 'subagent';

  bool get hasThreadName => threadName.trim().isNotEmpty;

  String get primaryIdentity {
    final candidates = [
      threadName.trim(),
      title.trim(),
      project.trim(),
      _shortSessionIdentifier(sessionId),
      _shortSessionIdentifier(id),
    ];
    for (final candidate in candidates) {
      if (candidate.isNotEmpty) {
        return candidate;
      }
    }
    return id;
  }

  String get originLabel => SessionLabelFormatter.origin(
    threadSource: threadSource,
    agentNickname: agentNickname,
  );

  String get providerLabel => SessionLabelFormatter.provider(model);

  String get modelLabel => SessionLabelFormatter.model(model);

  String get modelProviderLabel =>
      SessionLabelFormatter.modelWithProvider(model);

  String get sourcePathForDisplay =>
      sourceFilePath.isEmpty ? path : sourceFilePath;

  String get displayPathForDetail => displayPath.isEmpty ? path : displayPath;

  String get workingDirectoryForCommands =>
      workingDirectory.isEmpty ? displayPathForDetail : workingDirectory;

  String get containingFolderTarget {
    final trimmed = openablePath.trim();
    return trimmed.isEmpty ? workingDirectoryForCommands : trimmed;
  }

  bool get canOpenContainingFolder {
    if (platform == SessionRowPlatform.windows) {
      return true;
    }
    return _isWindowsOpenablePath(containingFolderTarget);
  }

  List<String> get modelsUsedForDetail {
    if (modelsUsed.isNotEmpty) {
      return modelsUsed;
    }
    final label = modelLabel;
    return label == SessionLabelFormatter.unknown ? const [] : [label];
  }

  String get estimatedCostDisplay => _costDisplay(
    estimatedCostText,
    costUnknown,
    costUpdating,
    costPartialUnsupportedUnits,
  );

  int get displayTotalTokens => usageRollup?.totalTokens ?? totalTokens;

  String get displayEstimatedCost {
    final rollup = usageRollup;
    if (rollup == null) {
      return estimatedCostDisplay;
    }
    return rollup.totalEstimatedCostDisplay;
  }

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

  SessionRowViewModel copyWithProjectedCost(UsageCostEstimate cost) =>
      _copyWithUsage(usageRollup, cost: cost);

  SessionRowViewModel copyWithConversationMessages(
    List<ConversationMessageViewModel> messages,
  ) {
    return SessionRowViewModel(
      id: id,
      sessionId: sessionId,
      harness: harness,
      threadName: threadName,
      threadSource: threadSource,
      parentThreadId: parentThreadId,
      agentNickname: agentNickname,
      agentRole: agentRole,
      subagentDepth: subagentDepth,
      sourceFilePath: sourceFilePath,
      displayPath: displayPath,
      workingDirectory: workingDirectory,
      openablePath: openablePath,
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
      costUpdating: costUpdating,
      costPartialUnsupportedUnits: costPartialUnsupportedUnits,
      totalTokens: totalTokens,
      model: model,
      modelsUsed: modelsUsed,
      tags: tags,
      status: status,
      conversationMessages: messages,
      usageRollup: usageRollup,
      isPinned: isPinned,
      isArchived: isArchived,
      sourceState: sourceState,
      hasError: hasError,
      evalReady: evalReady,
      evalStatus: evalStatus,
      evalNotes: evalNotes,
      evalExpectedOutput: evalExpectedOutput,
      evalReviewedAtUtc: evalReviewedAtUtc,
      evalUpdatedAtUtc: evalUpdatedAtUtc,
    );
  }

  SessionRowViewModel copyWithFlags({bool? isPinned, bool? isArchived}) {
    return SessionRowViewModel(
      id: id,
      sessionId: sessionId,
      harness: harness,
      threadName: threadName,
      threadSource: threadSource,
      parentThreadId: parentThreadId,
      agentNickname: agentNickname,
      agentRole: agentRole,
      subagentDepth: subagentDepth,
      sourceFilePath: sourceFilePath,
      displayPath: displayPath,
      workingDirectory: workingDirectory,
      openablePath: openablePath,
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
      costUpdating: costUpdating,
      costPartialUnsupportedUnits: costPartialUnsupportedUnits,
      totalTokens: totalTokens,
      model: model,
      modelsUsed: modelsUsed,
      tags: tags,
      status: status,
      conversationMessages: conversationMessages,
      usageRollup: usageRollup,
      isPinned: isPinned ?? this.isPinned,
      isArchived: isArchived ?? this.isArchived,
      sourceState: sourceState,
      hasError: hasError,
      evalReady: evalReady,
      evalStatus: evalStatus,
      evalNotes: evalNotes,
      evalExpectedOutput: evalExpectedOutput,
      evalReviewedAtUtc: evalReviewedAtUtc,
      evalUpdatedAtUtc: evalUpdatedAtUtc,
    );
  }

  SessionRowViewModel copyWithUsageRollup(SessionUsageRollup? rollup) =>
      _copyWithUsage(rollup);

  SessionRowViewModel _copyWithUsage(
    SessionUsageRollup? rollup, {
    UsageCostEstimate? cost,
  }) {
    return SessionRowViewModel(
      id: id,
      sessionId: sessionId,
      harness: harness,
      threadName: threadName,
      threadSource: threadSource,
      parentThreadId: parentThreadId,
      agentNickname: agentNickname,
      agentRole: agentRole,
      subagentDepth: subagentDepth,
      sourceFilePath: sourceFilePath,
      displayPath: displayPath,
      workingDirectory: workingDirectory,
      openablePath: openablePath,
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
      estimatedCostText: cost == null
          ? estimatedCostText
          : cost.estimatedCostText,
      costUnknown: cost?.costUnknown ?? costUnknown,
      costUpdating: cost?.updating ?? costUpdating,
      costPartialUnsupportedUnits:
          cost?.partialUnsupportedUnits ?? costPartialUnsupportedUnits,
      totalTokens: totalTokens,
      model: model,
      modelsUsed: modelsUsed,
      tags: tags,
      status: status,
      conversationMessages: conversationMessages,
      usageRollup: rollup,
      isPinned: isPinned,
      isArchived: isArchived,
      sourceState: sourceState,
      hasError: hasError,
      evalReady: evalReady,
      evalStatus: evalStatus,
      evalNotes: evalNotes,
      evalExpectedOutput: evalExpectedOutput,
      evalReviewedAtUtc: evalReviewedAtUtc,
      evalUpdatedAtUtc: evalUpdatedAtUtc,
    );
  }

  SessionRowViewModel copyWithEvalMetadata(SessionEvalMetadata metadata) {
    return SessionRowViewModel(
      id: id,
      sessionId: sessionId,
      harness: harness,
      threadName: threadName,
      threadSource: threadSource,
      parentThreadId: parentThreadId,
      agentNickname: agentNickname,
      agentRole: agentRole,
      subagentDepth: subagentDepth,
      sourceFilePath: sourceFilePath,
      displayPath: displayPath,
      workingDirectory: workingDirectory,
      openablePath: openablePath,
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
      costUpdating: costUpdating,
      costPartialUnsupportedUnits: costPartialUnsupportedUnits,
      totalTokens: totalTokens,
      model: model,
      modelsUsed: modelsUsed,
      tags: tags,
      status: status,
      conversationMessages: conversationMessages,
      usageRollup: usageRollup,
      isPinned: isPinned,
      isArchived: isArchived,
      sourceState: sourceState,
      hasError: hasError,
      evalReady: metadata.evalReady,
      evalStatus: metadata.status ?? '',
      evalNotes: metadata.notes ?? '',
      evalExpectedOutput: metadata.expectedOutput ?? '',
      evalReviewedAtUtc: metadata.reviewedAtUtc,
      evalUpdatedAtUtc: DateTime.now().toUtc(),
    );
  }
}

class SessionEvalMetadata {
  const SessionEvalMetadata({
    required this.evalReady,
    this.status,
    this.notes,
    this.expectedOutput,
    this.reviewedAtUtc,
  });

  final bool evalReady;
  final String? status;
  final String? notes;
  final String? expectedOutput;
  final DateTime? reviewedAtUtc;
}

class SessionUsageRollup {
  const SessionUsageRollup({
    required this.mainTokens,
    required this.subagentTokens,
    required this.totalTokens,
    required this.mainEstimatedCostText,
    required this.subagentEstimatedCostText,
    required this.totalEstimatedCostText,
    required this.mainCostUnknown,
    required this.subagentCostUnknown,
    required this.totalCostUnknown,
    this.mainCostUpdating = false,
    this.subagentCostUpdating = false,
    this.totalCostUpdating = false,
    this.mainCostPartialUnsupportedUnits = false,
    this.subagentCostPartialUnsupportedUnits = false,
    this.totalCostPartialUnsupportedUnits = false,
  });

  final int mainTokens;
  final int subagentTokens;
  final int totalTokens;
  final String? mainEstimatedCostText;
  final String? subagentEstimatedCostText;
  final String? totalEstimatedCostText;
  final bool mainCostUnknown;
  final bool subagentCostUnknown;
  final bool totalCostUnknown;
  final bool mainCostUpdating;
  final bool subagentCostUpdating;
  final bool totalCostUpdating;
  final bool mainCostPartialUnsupportedUnits;
  final bool subagentCostPartialUnsupportedUnits;
  final bool totalCostPartialUnsupportedUnits;

  String get mainEstimatedCostDisplay => _costDisplay(
    mainEstimatedCostText,
    mainCostUnknown,
    mainCostUpdating,
    mainCostPartialUnsupportedUnits,
  );

  String get subagentEstimatedCostDisplay => _costDisplay(
    subagentEstimatedCostText,
    subagentCostUnknown,
    subagentCostUpdating,
    subagentCostPartialUnsupportedUnits,
  );

  String get totalEstimatedCostDisplay => _costDisplay(
    totalEstimatedCostText,
    totalCostUnknown,
    totalCostUpdating,
    totalCostPartialUnsupportedUnits,
  );
}

String _costDisplay(String? amount, bool unknown, bool updating, bool partial) {
  if (updating) return 'Pricing update in progress';
  if (unknown) return 'Cost unknown';
  return '\$${amount ?? '0'}${partial ? ' (partial)' : ''}';
}

bool _isWindowsOpenablePath(String path) {
  final trimmed = path.trim();
  if (trimmed.startsWith(r'\\')) {
    return true;
  }
  return RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(trimmed);
}

String _shortSessionIdentifier(String value) {
  final trimmed = value.trim();
  if (trimmed.length <= 12) {
    return trimmed;
  }
  return '${trimmed.substring(0, 8)}...';
}
