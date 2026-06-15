import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../config/app_settings.dart';
import '../logging/structured_logger.dart';
import '../parser/codex_session_parser.dart';
import '../path_mapping/path_mapper.dart';
import '../pricing/pricing_repository.dart';
import '../scanner/session_scanner.dart';
import '../search/session_search.dart';
import '../usage/usage_summary.dart';
import '../ui/models/conversation_message_view_model.dart';
import '../ui/screens/sessions_screen.dart';

class RuntimeSessionController {
  RuntimeSessionController({
    required this.settingsFile,
    required this.databaseFile,
  });

  final File settingsFile;
  final File databaseFile;

  Future<SessionsRefreshResult> loadCachedRows() async {
    final settings = await SettingsRepository(settingsFile).loadOrCreate();
    final db = sqlite3.open(databaseFile.path);
    try {
      final pricing = PricingRepository(db).loadCached(settings.pricing);
      final rows = _loadRows(db, pricing: pricing);
      return SessionsRefreshResult(
        rows: rows,
        statusMessage: rows.isEmpty
            ? ''
            : 'Loaded ${_plural(rows.length, 'session')} from the previous scan.',
      );
    } finally {
      db.close();
    }
  }

  Future<SessionRowViewModel?> loadSessionDetail(String sessionId) async {
    final settings = await SettingsRepository(settingsFile).loadOrCreate();
    final db = sqlite3.open(databaseFile.path);
    try {
      final pricing = PricingRepository(db).loadCached(settings.pricing);
      final rows = _loadRows(
        db,
        sessionId: sessionId,
        includeMessages: true,
        pricing: pricing,
      );
      if (rows.isEmpty) {
        return null;
      }
      return rows.single;
    } finally {
      db.close();
    }
  }

  Future<SessionsRefreshResult> refreshInBackground({
    SessionsRefreshProgressCallback? onProgress,
  }) async {
    final messages = ReceivePort();
    final errors = ReceivePort();
    final exits = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn<_BackgroundRefreshRequest>(
        _backgroundRefreshEntry,
        _BackgroundRefreshRequest(
          settingsFilePath: settingsFile.path,
          databaseFilePath: databaseFile.path,
          sendPort: messages.sendPort,
        ),
        onError: errors.sendPort,
        onExit: exits.sendPort,
      );

      final result = Completer<SessionsRefreshResult>();
      late StreamSubscription<Object?> messageSubscription;
      late StreamSubscription<Object?> errorSubscription;
      late StreamSubscription<Object?> exitSubscription;

      void finishError(Object error, [StackTrace? stackTrace]) {
        if (!result.isCompleted) {
          result.completeError(error, stackTrace);
        }
      }

      messageSubscription = messages.listen((message) {
        if (message is _BackgroundRefreshProgress) {
          onProgress?.call(message.progress);
          return;
        }
        if (message is _BackgroundRefreshDone) {
          if (!result.isCompleted) {
            result.complete(message.result);
          }
          return;
        }
        if (message is _BackgroundRefreshError) {
          finishError(
            StateError(message.error),
            StackTrace.fromString(message.stackTrace),
          );
        }
      });
      errorSubscription = errors.listen((message) {
        finishError(StateError('Background scan failed. $message'));
      });
      exitSubscription = exits.listen((_) {
        if (!result.isCompleted) {
          finishError(StateError('Background scan exited before completion.'));
        }
      });

      return await result.future.whenComplete(() async {
        await messageSubscription.cancel();
        await errorSubscription.cancel();
        await exitSubscription.cancel();
      });
    } finally {
      messages.close();
      errors.close();
      exits.close();
      isolate?.kill(priority: Isolate.immediate);
    }
  }

  Future<SessionsRefreshResult> refresh({
    SessionsRefreshProgressCallback? onProgress,
  }) async {
    final settings = await SettingsRepository(settingsFile).loadOrCreate();
    final db = sqlite3.open(databaseFile.path);
    final logger = StructuredLogger(db: db, settings: settings.logging);
    final pricing = PricingRepository(db).loadCached(settings.pricing);
    int? scanRunId;
    var latestProgress = ScanProgress(startedAtUtc: DateTime.now().toUtc());
    final pendingParsedSessions = <ScannedSessionFile>[];
    try {
      scanRunId = _startScanRun(db);
      final activeScanRunId = scanRunId;

      void flushParsedSessions(ScanProgress progress) {
        if (pendingParsedSessions.isEmpty) {
          return;
        }
        _persistParsedSessions(db, pendingParsedSessions);
        pendingParsedSessions.clear();
        onProgress?.call(
          SessionsRefreshProgress(
            statusMessage: _progressStatusMessage(progress),
            rows: _loadRows(db, pricing: pricing),
          ),
        );
      }

      final cachedRows = _loadRows(db, pricing: pricing);
      if (onProgress != null && cachedRows.isNotEmpty) {
        onProgress(
          SessionsRefreshProgress(
            rows: cachedRows,
            statusMessage:
                'Loaded ${_plural(cachedRows.length, 'session')} from the previous scan. Scanning started.',
          ),
        );
      }

      await logger.write(
        LogEntryDraft(
          level: LogLevel.info,
          category: LogCategory.scanner,
          message: 'Session scan started.',
          details: {
            'directory_workers': _defaultDirectoryWorkerCount(),
            'parser_workers': _defaultParserWorkerCount(),
            'parser_isolates': true,
          },
        ),
      );
      final mapper = CodexPathMapper(
        wslDistro: settings.wsl.distro,
        wslLinuxHome: settings.wsl.linuxHome,
        wslUncRoot: settings.wsl.linuxRootUnc,
      );
      final parserWorkerCount = _defaultParserWorkerCount();
      final directoryWorkerCount = _defaultDirectoryWorkerCount();
      final scanner = SessionScanner(
        parser: CodexSessionParser(
          maxToolOutputPreviewChars:
              settings.toolOutput.maxToolOutputPreviewChars,
        ),
        pathMapper: mapper,
        maxConcurrentParses: parserWorkerCount,
        maxConcurrentDirectoryScans: directoryWorkerCount,
        onProgress: onProgress == null
            ? null
            : (progress) {
                latestProgress = progress;
                _updateScanRun(db, activeScanRunId, progress);
                onProgress(
                  SessionsRefreshProgress(
                    statusMessage: _progressStatusMessage(progress),
                  ),
                );
              },
        onSessionParsed: onProgress == null
            ? null
            : (session, progress) async {
                pendingParsedSessions.add(session);
                if (pendingParsedSessions.length >= 25) {
                  flushParsedSessions(progress);
                }
              },
      );
      final result = await scanner.scan(
        SessionScanRequest(
          windowsRoot: _sessionScanRoot(settings.paths.windowsCodexPath),
          wslRoot: _sessionScanRoot(settings.paths.wslCodexUncPath),
          cachedSessions: _cachedSessions(db),
        ),
      );
      flushParsedSessions(result.progress);
      _persistScan(
        db,
        result,
        scanRunId: activeScanRunId,
        persistSessions: onProgress == null,
      );
      final rows = _loadRows(db, pricing: pricing);
      await logger.write(
        LogEntryDraft(
          level: LogLevel.info,
          category: LogCategory.scanner,
          message: 'Session scan finished.',
          details: {
            ..._progressLogDetails(result.progress),
            'visible_sessions': rows.length,
            'directory_workers': directoryWorkerCount,
            'parser_workers': parserWorkerCount,
          },
        ),
      );
      return SessionsRefreshResult(
        rows: rows,
        statusMessage: _statusMessage(result, visibleSessionCount: rows.length),
      );
    } on Object catch (error) {
      final progress = latestProgress.finish();
      if (scanRunId != null) {
        _updateScanRun(db, scanRunId, progress);
      }
      await logger.write(
        LogEntryDraft(
          level: LogLevel.error,
          category: LogCategory.scanner,
          message: 'Session scan failed.',
          details: {
            ..._progressLogDetails(progress),
            'error_type': error.runtimeType.toString(),
          },
        ),
      );
      rethrow;
    } finally {
      db.close();
    }
  }
}

Future<void> _backgroundRefreshEntry(_BackgroundRefreshRequest request) async {
  try {
    final result =
        await RuntimeSessionController(
          settingsFile: File(request.settingsFilePath),
          databaseFile: File(request.databaseFilePath),
        ).refresh(
          onProgress: (progress) {
            request.sendPort.send(_BackgroundRefreshProgress(progress));
          },
        );
    request.sendPort.send(_BackgroundRefreshDone(result));
  } on Object catch (error, stackTrace) {
    request.sendPort.send(
      _BackgroundRefreshError(error.toString(), stackTrace.toString()),
    );
  }
}

class _BackgroundRefreshRequest {
  const _BackgroundRefreshRequest({
    required this.settingsFilePath,
    required this.databaseFilePath,
    required this.sendPort,
  });

  final String settingsFilePath;
  final String databaseFilePath;
  final SendPort sendPort;
}

class _BackgroundRefreshProgress {
  const _BackgroundRefreshProgress(this.progress);

  final SessionsRefreshProgress progress;
}

class _BackgroundRefreshDone {
  const _BackgroundRefreshDone(this.result);

  final SessionsRefreshResult result;
}

class _BackgroundRefreshError {
  const _BackgroundRefreshError(this.error, this.stackTrace);

  final String error;
  final String stackTrace;
}

void _persistParsedSessions(Database db, List<ScannedSessionFile> sessions) {
  db.execute('begin immediate');
  try {
    final now = DateTime.now().toUtc().toIso8601String();
    for (final session in sessions) {
      _upsertParsedSession(db, session, now);
    }
    db.execute('commit');
  } on Object {
    db.execute('rollback');
    rethrow;
  }
}

int _startScanRun(Database db) {
  db.execute(
    '''
    insert into scan_runs (
      started_at_utc,
      files_found,
      files_skipped,
      files_parsed,
      files_failed,
      sessions_added,
      sessions_changed,
      sessions_missing
    ) values (?, 0, 0, 0, 0, 0, 0, 0)
    ''',
    [DateTime.now().toUtc().toIso8601String()],
  );
  return db.lastInsertRowId;
}

void _updateScanRun(Database db, int scanRunId, ScanProgress progress) {
  db.execute(
    '''
    update scan_runs
    set
      finished_at_utc = ?,
      files_found = ?,
      files_skipped = ?,
      files_parsed = ?,
      files_failed = ?,
      sessions_added = ?,
      sessions_changed = ?,
      sessions_missing = ?
    where id = ?
    ''',
    [
      progress.finishedAtUtc?.toIso8601String(),
      progress.filesFound,
      progress.filesSkipped,
      progress.filesParsed,
      progress.filesFailed,
      progress.sessionsAdded,
      progress.sessionsChanged,
      progress.sessionsMissing,
      scanRunId,
    ],
  );
}

List<CachedSessionSnapshot> _cachedSessions(Database db) {
  final rows = db.select('''
    select
      source_file_path,
      source_file_unc_path,
      scan_status,
      file_size,
      modified_utc,
      content_hash,
      parser_version,
      last_scanned_utc,
      last_parsed_utc
    from sessions
    ''');
  return [
    for (final row in rows)
      CachedSessionSnapshot(
        sourcePath: row['source_file_path'] as String,
        sourceFileUncPath: row['source_file_unc_path'] as String?,
        status: _scanStatus(row['scan_status'] as String?),
        sourceFileSize: row['file_size'] as int?,
        sourceModifiedUtc: _dateTime(row['modified_utc'] as String?),
        sourceContentHash: row['content_hash'] as String?,
        parserVersion: row['parser_version'] as int?,
        lastScannedUtc: _dateTime(row['last_scanned_utc'] as String?),
        lastParsedUtc: _dateTime(row['last_parsed_utc'] as String?),
      ),
  ];
}

void _persistScan(
  Database db,
  SessionScanResult result, {
  required int scanRunId,
  required bool persistSessions,
}) {
  db.execute('begin immediate');
  try {
    final now = DateTime.now().toUtc().toIso8601String();
    _updateScanRun(db, scanRunId, result.progress);
    for (final error in result.errors) {
      db.execute(
        '''
        insert into scan_errors (
          scan_run_id,
          source_path,
          status,
          message,
          created_at_utc
        ) values (?, ?, ?, ?, ?)
        ''',
        [
          scanRunId,
          error.sourcePath,
          error.status.wireName,
          error.message,
          now,
        ],
      );
    }
    if (persistSessions) {
      for (final session in result.sessions) {
        _upsertParsedSession(db, session, now);
      }
    }
    for (final status in result.fileStatuses) {
      if (result.sessions.any(
        (session) => session.sourcePath == status.sourcePath,
      )) {
        continue;
      }
      _upsertScanStatusOnly(db, status, now);
    }
    db.execute('commit');
  } on Object {
    db.execute('rollback');
    rethrow;
  }
}

void _upsertParsedSession(
  Database db,
  ScannedSessionFile scannedSession,
  String now,
) {
  final parsed = scannedSession.parsedSession;
  final sourceType = scannedSession.sourceType == SessionSourceType.windows
      ? SessionSearchSourceType.windows
      : SessionSearchSourceType.wsl;
  final stat = File(scannedSession.sourcePath).statSync();
  final hasErrors =
      parsed.messages.any((message) => message.hasError) ||
      parsed.toolCalls.any((tool) => tool.hasError);
  SessionSearchIndex(db).upsert(
    SessionSearchDocument(
      id: parsed.internalId,
      sourceType: sourceType,
      sourceFilePath: scannedSession.sourcePath,
      displayPath: scannedSession.mappedPath.displayPath,
      platformPath: scannedSession.mappedPath.platformPath,
      title: parsed.title ?? '',
      summary: parsed.summary ?? '',
      userMessages: _messagesForAuthor(parsed, CodexMessageAuthorType.user),
      assistantMessages: _messagesForAuthor(
        parsed,
        CodexMessageAuthorType.assistant,
      ),
      toolNames: parsed.toolCalls.map((tool) => tool.toolName).join(' '),
      toolOutput: parsed.toolCalls.map((tool) => tool.outputPreview).join('\n'),
      normalizedPathKeys: scannedSession.mappedPath.normalizedPathKeys.join(
        ' ',
      ),
      startedAtUtc: parsed.startedAtUtc,
      lastMessageAtUtc: parsed.lastMessageAtUtc,
      modelsUsed: parsed.modelIds.toList(growable: false),
      scanStatus: scannedSession.status.wireName,
      parseStatus: 'available',
      hasCodeBlocks: parsed.messages.any(
        (message) => message.contentPlain.contains('```'),
      ),
      hasToolCalls: parsed.toolCalls.isNotEmpty,
      hasErrors: hasErrors,
      totalTokens: parsed.usage.totalTokens,
    ),
  );
  db.execute(
    '''
    update sessions
    set
      session_id = ?,
      source_file_unc_path = ?,
      working_directory_display = ?,
      working_directory_platform = ?,
      working_directory_unc = ?,
      file_size = ?,
      modified_utc = ?,
      content_hash = ?,
      parser_version = ?,
      message_count = ?,
      user_message_count = ?,
      assistant_message_count = ?,
      tool_call_count = ?,
      input_tokens = ?,
      output_tokens = ?,
      cached_input_tokens = ?,
      last_scanned_utc = ?,
      last_parsed_utc = ?
    where id = ?
    ''',
    [
      parsed.sessionId,
      scannedSession.mappedPath.sourceFileUncPath,
      parsed.workingDirectoryDisplay,
      parsed.workingDirectoryPlatform,
      parsed.workingDirectoryUnc,
      stat.size,
      stat.modified.toUtc().toIso8601String(),
      _readHash(scannedSession.sourcePath),
      CodexSessionParser.currentVersion,
      parsed.messages.length,
      parsed.messages
          .where((message) => message.authorType == CodexMessageAuthorType.user)
          .length,
      parsed.messages
          .where(
            (message) => message.authorType == CodexMessageAuthorType.assistant,
          )
          .length,
      parsed.toolCalls.length,
      parsed.usage.inputTokens,
      parsed.usage.outputTokens,
      parsed.usage.cachedInputTokens,
      now,
      now,
      parsed.internalId,
    ],
  );
  _replaceMessages(db, parsed, now);
  _replaceToolCalls(db, parsed);
}

void _replaceMessages(Database db, CodexParsedSession parsed, String now) {
  db.execute('delete from messages where session_id = ?', [parsed.internalId]);
  for (final message in parsed.messages) {
    db.execute(
      '''
      insert into messages (
        session_id,
        message_index,
        author_type,
        created_at_utc,
        first_line,
        content_plain,
        content_preview,
        content_truncated,
        token_input,
        token_output,
        token_cached,
        token_total,
        model,
        has_tool_calls,
        has_error,
        raw_type,
        created_at_db_utc,
        updated_at_db_utc
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        parsed.internalId,
        message.index,
        message.authorType.name,
        message.createdAtUtc?.toIso8601String(),
        message.firstLine,
        message.contentPlain,
        message.contentPreview,
        message.contentTruncated ? 1 : 0,
        message.usage.inputTokens,
        message.usage.outputTokens,
        message.usage.cachedInputTokens,
        message.usage.totalTokens,
        message.model,
        message.hasToolCalls ? 1 : 0,
        message.hasError ? 1 : 0,
        message.rawType,
        now,
        now,
      ],
    );
  }
}

void _replaceToolCalls(Database db, CodexParsedSession parsed) {
  db.execute('delete from tool_calls where session_id = ?', [
    parsed.internalId,
  ]);
  for (final tool in parsed.toolCalls) {
    db.execute(
      '''
      insert into tool_calls (
        session_id,
        tool_index,
        tool_name,
        status,
        started_at_utc,
        finished_at_utc,
        input_preview,
        output_preview,
        output_truncated,
        error_message
      ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        parsed.internalId,
        tool.toolIndex,
        tool.toolName,
        tool.status,
        tool.startedAtUtc?.toIso8601String(),
        tool.finishedAtUtc?.toIso8601String(),
        tool.inputPreview,
        tool.outputPreview,
        tool.outputTruncated ? 1 : 0,
        tool.errorMessage,
      ],
    );
  }
}

void _upsertScanStatusOnly(Database db, ScannedFileStatus status, String now) {
  final existingSessionIds = db.select(
    '''
    select id
    from sessions
    where source_file_path = ?
       or source_file_unc_path = ?
    ''',
    [status.sourcePath, status.sourcePath],
  );
  if (existingSessionIds.isNotEmpty) {
    for (final row in existingSessionIds) {
      db.execute(
        '''
        update sessions
        set
          scan_status = ?,
          parse_status = case
            when ? = 'parse_error' then 'parse_error'
            else parse_status
          end,
          updated_at_utc = ?,
          last_scanned_utc = ?
        where id = ?
        ''',
        [
          status.status.wireName,
          status.status.wireName,
          now,
          now,
          row['id'] as String,
        ],
      );
    }
    return;
  }
  db.execute(
    '''
    insert into sessions (
      id,
      source_type,
      source_file_path,
      display_path,
      platform_path,
      scan_status,
      parse_status,
      created_at_utc,
      updated_at_utc,
      last_scanned_utc
    ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    on conflict(id) do update set
      scan_status = excluded.scan_status,
      updated_at_utc = excluded.updated_at_utc,
      last_scanned_utc = excluded.last_scanned_utc
    ''',
    [
      _sourceStatusId(status.sourcePath),
      _sourceTypeLabel(status.sourcePath),
      status.sourcePath,
      status.sourcePath,
      status.sourcePath,
      status.status.wireName,
      status.status == SessionFileStatus.parseError
          ? 'parse_error'
          : 'available',
      now,
      now,
      now,
    ],
  );
}

List<SessionRowViewModel> _loadRows(
  Database db, {
  bool includeMessages = false,
  String? sessionId,
  UsagePricingCatalog pricing = const UsagePricingCatalog({}),
}) {
  final filters = [
    "s.parse_status = 'available'",
    "s.scan_status = 'available'",
    "coalesce(s.session_id, '') <> ''",
    if (sessionId != null) 's.id = ?',
  ];
  final rows = db.select(
    '''
    select
      s.id,
      s.session_id,
      s.source_type,
      s.source_file_path,
      s.display_path,
      s.platform_path,
      s.working_directory_display,
      s.started_at_utc,
      s.last_message_at_utc,
      s.title,
      s.summary,
      s.message_count,
      s.user_message_count,
      s.assistant_message_count,
      s.tool_call_count,
      s.input_tokens,
      s.output_tokens,
      s.cached_input_tokens,
      s.total_tokens,
      coalesce((
        select sum(coalesce(m.token_total, 0))
        from messages m
        where m.session_id = s.id
          and m.author_type = 'user'
      ), 0) as user_message_tokens,
      coalesce((
        select sum(coalesce(m.token_total, 0))
        from messages m
        where m.session_id = s.id
          and m.author_type = 'assistant'
      ), 0) as assistant_response_tokens,
      coalesce((
        select sum(coalesce(m.token_total, 0))
        from messages m
        where m.session_id = s.id
          and m.author_type = 'tool'
      ), 0) as tool_call_tokens,
      s.model_primary,
      s.models_used,
      s.project_name_snapshot,
      s.scan_status,
      s.parse_status,
      s.is_pinned,
      s.is_archived,
      s.has_errors
    from sessions s
    where ${filters.join(' and ')}
    order by coalesce(s.last_message_at_utc, s.started_at_utc, s.updated_at_utc) desc,
             s.id asc
    ''',
    [?sessionId],
  );
  return [
    for (final row in rows)
      _loadRow(db, row, includeMessages: includeMessages, pricing: pricing),
  ];
}

SessionRowViewModel _loadRow(
  Database db,
  Row row, {
  required bool includeMessages,
  required UsagePricingCatalog pricing,
}) {
  final inputTokens = row['input_tokens'] as int? ?? 0;
  final outputTokens = row['output_tokens'] as int? ?? 0;
  final cachedInputTokens = row['cached_input_tokens'] as int? ?? 0;
  final storedUserMessageTokens = row['user_message_tokens'] as int? ?? 0;
  final storedAssistantResponseTokens =
      row['assistant_response_tokens'] as int? ?? 0;
  final storedToolCallTokens = row['tool_call_tokens'] as int? ?? 0;
  final hasMessageTokenBreakdown =
      storedUserMessageTokens +
          storedAssistantResponseTokens +
          storedToolCallTokens >
      0;
  final model = row['model_primary'] as String? ?? '';
  final estimate = estimateUsageCost(
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cachedInputTokens: cachedInputTokens,
    model: model.isEmpty ? null : model,
    pricing: pricing,
  );
  return SessionRowViewModel(
    id: row['id'] as String,
    sessionId: row['session_id'] as String? ?? '',
    sourceFilePath: row['source_file_path'] as String? ?? '',
    displayPath: row['display_path'] as String? ?? '',
    workingDirectory: row['working_directory_display'] as String? ?? '',
    startedAtUtc:
        _dateTime(row['started_at_utc'] as String?) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    lastMessageAtUtc:
        _dateTime(row['last_message_at_utc'] as String?) ??
        DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    platform: (row['source_type'] as String?) == 'wsl'
        ? SessionRowPlatform.wsl
        : SessionRowPlatform.windows,
    project: row['project_name_snapshot'] as String? ?? 'Unassigned',
    path:
        row['display_path'] as String? ??
        row['source_file_path'] as String? ??
        '',
    title: row['title'] as String? ?? 'Untitled session',
    summary: row['summary'] as String? ?? '',
    messageCount: row['message_count'] as int? ?? 0,
    userMessageCount: row['user_message_count'] as int? ?? 0,
    assistantMessageCount: row['assistant_message_count'] as int? ?? 0,
    toolCallCount: row['tool_call_count'] as int? ?? 0,
    inputTokens: inputTokens,
    outputTokens: outputTokens,
    cachedInputTokens: cachedInputTokens,
    userMessageTokens: hasMessageTokenBreakdown
        ? storedUserMessageTokens
        : inputTokens,
    assistantResponseTokens: hasMessageTokenBreakdown
        ? storedAssistantResponseTokens
        : outputTokens,
    toolCallTokens: storedToolCallTokens,
    totalTokens: row['total_tokens'] as int? ?? 0,
    estimatedCostText: estimate.estimatedCostText,
    costUnknown: estimate.costUnknown,
    model: model,
    modelsUsed: _decodeMembership(row['models_used'] as String?),
    tags: _loadTags(db, row['id'] as String),
    status: _rowStatus(row),
    isPinned: (row['is_pinned'] as int? ?? 0) == 1,
    isArchived: (row['is_archived'] as int? ?? 0) == 1,
    hasError: (row['has_errors'] as int? ?? 0) == 1,
    conversationMessages: includeMessages
        ? _loadMessages(db, row['id'] as String)
        : const [],
  );
}

List<String> _loadTags(Database db, String sessionId) {
  final rows = db.select(
    '''
    select t.name
    from session_tags st
    join tags t on t.id = st.tag_id
    where st.session_id = ?
    order by t.name
    ''',
    [sessionId],
  );
  return [for (final row in rows) row['name'] as String];
}

List<ConversationMessageViewModel> _loadMessages(
  Database db,
  String sessionId,
) {
  final rows = db.select(
    '''
    select
      message_index,
      author_type,
      created_at_utc,
      content_preview,
      content_plain,
      token_total,
      model,
      has_error,
      has_tool_calls
    from messages
    where session_id = ?
    order by message_index
    ''',
    [sessionId],
  );
  return [
    for (final row in rows)
      ConversationMessageViewModel(
        id: '$sessionId:${row['message_index']}',
        number: row['message_index'] as int,
        author: _messageAuthor(row['author_type'] as String?),
        createdAtUtc:
            _dateTime(row['created_at_utc'] as String?) ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        preview: row['content_preview'] as String? ?? '',
        body:
            row['content_plain'] as String? ??
            row['content_preview'] as String? ??
            '',
        tokenCount: row['token_total'] as int? ?? 0,
        hasError: (row['has_error'] as int? ?? 0) == 1,
        hasToolOutput: (row['has_tool_calls'] as int? ?? 0) == 1,
      ),
  ];
}

String _messagesForAuthor(
  CodexParsedSession session,
  CodexMessageAuthorType author,
) => session.messages
    .where((message) => message.authorType == author)
    .map((message) => message.contentPlain)
    .join('\n');

String _statusMessage(
  SessionScanResult result, {
  required int visibleSessionCount,
}) {
  final visible = _plural(visibleSessionCount, 'session');
  final parsed = _plural(result.progress.filesParsed, 'new or changed session');
  if (result.errors.any(
    (error) => error.status == SessionFileStatus.pathUnreachable,
  )) {
    final paths = result.errors
        .where((error) => error.status == SessionFileStatus.pathUnreachable)
        .map((error) => error.sourcePath)
        .join('; ');
    return 'Scan finished. $visible visible. $parsed parsed. '
        'Session root is unreachable. Unreachable paths: $paths';
  }
  if (result.progress.filesFound == 0 && visibleSessionCount == 0) {
    return 'Scan finished. No supported files found.';
  }
  return 'Scan finished. $visible visible. $parsed parsed.';
}

String _progressStatusMessage(ScanProgress progress) {
  final directories = _plural(progress.directoriesScanned, 'directory');
  final found = _plural(progress.filesFound, 'JSON file');
  final skipped = _plural(progress.filesSkipped, 'unchanged file');
  final parsed = _plural(progress.filesParsed, 'changed JSON file');
  final sessions = _plural(progress.filesParsed, 'valid session');
  final failed = _plural(progress.filesFailed, 'file');
  final percent = _estimatedProgressPercent(progress);
  return 'Scanning... scanned $directories, found $found, skipped $skipped, parsed $parsed, '
      'found $sessions, failed to parse $failed, estimated progress $percent%, '
      'ETA ${_estimatedEta(progress)}.';
}

int _estimatedProgressPercent(ScanProgress progress) {
  if (progress.finishedAtUtc != null) {
    return 100;
  }
  final processed =
      progress.filesParsed + progress.filesSkipped + progress.filesFailed;
  final totalKnown = [
    progress.filesFound,
    processed,
  ].reduce((left, right) => left > right ? left : right);
  if (totalKnown == 0) {
    return 0;
  }
  return ((processed / totalKnown) * 100).clamp(0, 99).round();
}

String _sessionScanRoot(String rootPath) {
  final sessions = Directory(p.join(rootPath, 'sessions'));
  if (sessions.existsSync()) {
    return sessions.path;
  }
  return rootPath;
}

Map<String, Object?> _progressLogDetails(ScanProgress progress) => {
  'directories_scanned': progress.directoriesScanned,
  'files_found': progress.filesFound,
  'files_skipped': progress.filesSkipped,
  'files_parsed': progress.filesParsed,
  'files_failed': progress.filesFailed,
  'sessions_added': progress.sessionsAdded,
  'sessions_changed': progress.sessionsChanged,
  'sessions_missing': progress.sessionsMissing,
  'finished': progress.finishedAtUtc != null,
};

int _defaultParserWorkerCount() {
  final processors = Platform.numberOfProcessors;
  if (processors <= 2) {
    return 1;
  }
  return math.min(8, processors - 1);
}

int _defaultDirectoryWorkerCount() {
  final processors = Platform.numberOfProcessors;
  return math.min(8, math.max(2, processors ~/ 2));
}

String _estimatedEta(ScanProgress progress) {
  final percent = _estimatedProgressPercent(progress);
  if (percent >= 100) {
    return '0s';
  }
  if (percent <= 0) {
    return 'calculating';
  }
  final elapsed = DateTime.now().toUtc().difference(progress.startedAtUtc);
  final remainingSeconds = (elapsed.inSeconds * (100 - percent) / percent)
      .round();
  if (remainingSeconds <= 0) {
    return 'calculating';
  }
  if (remainingSeconds < 60) {
    return '${remainingSeconds}s';
  }
  final minutes = remainingSeconds ~/ 60;
  final seconds = remainingSeconds % 60;
  return '${minutes}m ${seconds}s';
}

String _plural(int count, String label) =>
    '$count $label${count == 1 ? '' : 's'}';

SessionFileStatus _scanStatus(String? value) {
  for (final status in SessionFileStatus.values) {
    if (status.wireName == value) {
      return status;
    }
  }
  return SessionFileStatus.available;
}

DateTime? _dateTime(String? value) =>
    value == null ? null : DateTime.tryParse(value)?.toUtc();

String _readHash(String path) {
  return sha256.convert(File(path).readAsBytesSync()).toString();
}

String _sourceStatusId(String sourcePath) =>
    'source-status:${p.normalize(sourcePath).toLowerCase()}';

String _sourceTypeLabel(String sourcePath) {
  if (sourcePath.startsWith(r'\\wsl') || sourcePath.contains('/home/')) {
    return 'wsl';
  }
  return 'windows';
}

List<String> _decodeMembership(String? encoded) {
  if (encoded == null || encoded.isEmpty) {
    return const [];
  }
  return encoded
      .split('|')
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
}

String _rowStatus(Row row) {
  final scanStatus = row['scan_status'] as String? ?? 'available';
  final parseStatus = row['parse_status'] as String? ?? 'available';
  if (parseStatus != 'available') {
    return parseStatus;
  }
  return scanStatus;
}

ConversationAuthor _messageAuthor(String? value) {
  return switch (value) {
    'user' => ConversationAuthor.user,
    'assistant' => ConversationAuthor.assistant,
    _ => ConversationAuthor.tool,
  };
}
