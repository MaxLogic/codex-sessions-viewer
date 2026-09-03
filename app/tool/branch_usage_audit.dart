import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_sessions_viewer/src/parser/codex_session_parser.dart';
import 'package:codex_sessions_viewer/src/pricing/pricing_repository.dart';
import 'package:codex_sessions_viewer/src/usage/usage_summary.dart';
import 'package:sqlite3/sqlite3.dart';

const _auditedModels = ['gpt-5.5', 'gpt-5.6-sol', 'gpt-5.6-terra'];

Future<BranchUsageAuditReport> auditBranchUsage(
  Database db, {
  required int currentProjectionVersion,
  required List<OpenRouterModelPricing> publicModels,
}) async {
  db.execute('begin deferred');
  try {
    return await _auditBranchUsageSnapshot(
      db,
      currentProjectionVersion: currentProjectionVersion,
      publicModels: publicModels,
    );
  } finally {
    if (!db.autocommit) {
      db.execute('rollback');
    }
  }
}

Future<BranchUsageAuditReport> _auditBranchUsageSnapshot(
  Database db, {
  required int currentProjectionVersion,
  required List<OpenRouterModelPricing> publicModels,
}) async {
  final coverageRow = db
      .select(
        '''
    select
      count(*) as available_sessions,
      coalesce(sum(case
        when parser_version = ? and usage_projection_status = 'complete'
          then 1 else 0 end), 0) as current_complete_sessions,
      coalesce(sum(case
        when parser_version is not ? and usage_projection_status = 'complete'
          then 1 else 0 end), 0) as outdated_projection_sessions,
      coalesce(sum(case when usage_projection_status = 'legacy_pending'
        then 1 else 0 end), 0) as legacy_pending_sessions,
      coalesce(sum(case when usage_projection_status = 'ambiguous'
        then 1 else 0 end), 0) as ambiguous_sessions,
      coalesce(sum(case when usage_projection_status = 'missing_parent'
        then 1 else 0 end), 0) as missing_parent_sessions,
      coalesce(sum(case
        when parser_version = ? and usage_projection_status = 'complete'
          and not exists (
            select 1 from billable_usage_events e
            where e.session_row_id = sessions.id
          ) then 1 else 0 end), 0) as complete_zero_usage_sessions
      ,coalesce(sum(case
        when parser_version = ? and usage_projection_status = 'complete'
          and exists (
            select 1 from usage_events e
            where e.session_row_id = sessions.id
          )
          and not exists (
            select 1 from billable_usage_events e
            where e.session_row_id = sessions.id
          ) then 1 else 0 end), 0) as inherited_only_sessions
    from sessions
    where parse_status = 'available'
    ''',
        [
          currentProjectionVersion,
          currentProjectionVersion,
          currentProjectionVersion,
          currentProjectionVersion,
        ],
      )
      .single;
  final coverage = BranchUsageCoverage(
    availableSessions: coverageRow['available_sessions'] as int,
    currentCompleteSessions: coverageRow['current_complete_sessions'] as int,
    outdatedProjectionSessions:
        coverageRow['outdated_projection_sessions'] as int,
    legacyPendingSessions: coverageRow['legacy_pending_sessions'] as int,
    ambiguousSessions: coverageRow['ambiguous_sessions'] as int,
    missingParentSessions: coverageRow['missing_parent_sessions'] as int,
    completeZeroUsageSessions:
        coverageRow['complete_zero_usage_sessions'] as int,
    inheritedOnlySessions: coverageRow['inherited_only_sessions'] as int,
  );

  final duplicateEventViolations = _count(db, '''
    select count(*) as count from (
      select session_row_id, event_fingerprint
      from usage_events
      group by session_row_id, event_fingerprint
      having count(*) > 1
    )
    ''');
  final tokenInvariantViolations = _count(db, '''
    select count(*) as count
    from usage_events
    where input_tokens < 0
       or cached_input_tokens < 0
       or cache_write_input_tokens < 0
       or output_tokens < 0
       or reasoning_output_tokens < 0
       or total_tokens < 0
       or total_tokens != input_tokens + output_tokens
    ''');

  const parentId =
      'coalesce(c.forked_from_id, c.parent_thread_id, '
      'c.history_base_thread_id)';
  final lineageRow = db
      .select(
        '''
    select
      count(*) as parent_fork_pairs,
      coalesce(sum(case
        when coalesce(p.forked_from_id, p.parent_thread_id,
          p.history_base_thread_id) is not null then 1 else 0 end), 0)
        as fork_of_fork_chains
    from sessions c
    join sessions p on p.session_id = $parentId
    where c.parse_status = 'available'
      and c.parser_version = ?
      and c.usage_projection_status = 'complete'
      and (select count(*) from sessions candidate
        where candidate.session_id = $parentId) = 1
    ''',
        [currentProjectionVersion],
      )
      .single;
  final inheritedReconciliation = db
      .select(
        '''
    with unique_pairs as (
      select c.id as child_id, p.id as parent_id
      from sessions c
      join sessions p on p.session_id = $parentId
      where c.parse_status = 'available'
        and c.parser_version = ?
        and c.usage_projection_status = 'complete'
        and c.history_base_thread_id is null
        and (select count(*) from sessions candidate
          where candidate.session_id = $parentId) = 1
    ),
    child_events as (
      select pair.child_id, event.event_fingerprint, event.branch_scope,
        row_number() over (
          partition by pair.child_id order by event.source_record_ordinal
        ) as sequence
      from unique_pairs pair
      join usage_events event on event.session_row_id = pair.child_id
    ),
    parent_events as (
      select pair.child_id, event.event_fingerprint,
        row_number() over (
          partition by pair.child_id order by event.source_record_ordinal
        ) as sequence
      from unique_pairs pair
      join usage_events event on event.session_row_id = pair.parent_id
    ),
    bounds as (
      select child.child_id,
        coalesce(
          min(case when parent.event_fingerprint is null
            or parent.event_fingerprint != child.event_fingerprint
            then child.sequence end),
          max(child.sequence) + 1
        ) as first_local_sequence
      from child_events child
      left join parent_events parent
        on parent.child_id = child.child_id
       and parent.sequence = child.sequence
      group by child.child_id
    )
    select
      coalesce(sum(case when child.branch_scope = 'inherited'
        and child.sequence >= bounds.first_local_sequence
        then 1 else 0 end), 0) as unmatched,
      coalesce(sum(case when child.branch_scope = 'inherited'
        and child.sequence < bounds.first_local_sequence
        then 1 else 0 end), 0) as matched
      ,coalesce(sum(case
        when child.sequence < bounds.first_local_sequence
          and child.branch_scope != 'inherited' then 1
        when child.sequence >= bounds.first_local_sequence
          and child.branch_scope != 'local' then 1
        else 0 end), 0) as scope_mismatches
    from child_events child
    join bounds on bounds.child_id = child.child_id
    ''',
        [currentProjectionVersion],
      )
      .single;
  final unmatchedInheritedEventViolations =
      inheritedReconciliation['unmatched'] as int;
  final scopeMismatchViolations =
      inheritedReconciliation['scope_mismatches'] as int;
  final ambiguousParentViolations = _count(
    db,
    '''
    select count(*) as count
    from sessions c
    where c.parse_status = 'available'
      and c.parser_version = ?
      and c.usage_projection_status = 'complete'
      and c.history_base_thread_id is null
      and c.subagent_history_start_ordinal is null
      and $parentId is not null
      and (select count(*) from sessions candidate
        where candidate.session_id = $parentId) != 1
    ''',
    [currentProjectionVersion],
  );
  final lineage = BranchUsageLineage(
    parentForkPairs: lineageRow['parent_fork_pairs'] as int,
    forkOfForkChains: lineageRow['fork_of_fork_chains'] as int,
    matchedInheritedEvents: inheritedReconciliation['matched'] as int,
    scopeMismatchViolations: scopeMismatchViolations,
    ambiguousParentViolations: ambiguousParentViolations,
  );

  final publicById = {for (final model in publicModels) model.modelId: model};
  final catalog = _loadCachedPricingCatalog(db);
  final projectGroups = <String, _ProjectAccumulator>{};
  for (final row in db.select(
    '''
    select
      case when s.project_override = 1 then s.project_id
        else e.project_id end as project_id,
      coalesce(
        case when s.project_override = 1
          then coalesce(p.name, s.project_name_snapshot)
          else p.name end,
        'Unknown'
      ) as project_name,
      e.model,
      sum(e.input_tokens) as input_tokens,
      sum(e.cached_input_tokens) as cached_input_tokens,
      sum(e.cache_write_input_tokens) as cache_write_input_tokens,
      sum(e.output_tokens) as output_tokens,
      sum(e.reasoning_output_tokens) as reasoning_output_tokens,
      sum(case when e.total_tokens = e.input_tokens + e.output_tokens
        then e.total_tokens else e.input_tokens + e.output_tokens end)
        as total_tokens,
      sum(case
        when e.cached_input_tokens + e.cache_write_input_tokens > e.input_tokens
          or e.reasoning_output_tokens > e.output_tokens
        then 1 else 0 end) as invalid_bucket_count
    from billable_usage_events e
    join sessions s on s.id = e.session_row_id
    left join projects p on p.id = case
      when s.project_override = 1 then s.project_id else e.project_id end
    where s.parse_status = 'available'
      and s.parser_version = ?
      and s.usage_projection_status = 'complete'
    group by
      case when s.project_override = 1 then s.project_id
        else e.project_id end,
      project_name,
      e.model
    ''',
    [currentProjectionVersion],
  )) {
    final projectId = row['project_id'] as int?;
    final projectName = row['project_name'] as String;
    final key = '${projectId ?? 'null'}\u0000$projectName';
    final accumulator = projectGroups.putIfAbsent(
      key,
      () => _ProjectAccumulator(projectId, projectName),
    );
    accumulator.totalTokens += row['total_tokens'] as int;
    accumulator.costs.add(
      (row['invalid_bucket_count'] as int) == 0
          ? estimateUsageCost(
              inputTokens: row['input_tokens'] as int,
              outputTokens: row['output_tokens'] as int,
              cachedInputTokens: row['cached_input_tokens'] as int,
              cacheWriteInputTokens: row['cache_write_input_tokens'] as int,
              reasoningOutputTokens: row['reasoning_output_tokens'] as int,
              model: row['model'] as String?,
              pricing: catalog,
            ).estimatedCostText
          : null,
    );
  }
  final projectTotals =
      [
        for (final accumulator in projectGroups.values)
          BranchUsageProjectTotal(
            projectId: accumulator.projectId,
            projectName: accumulator.projectName,
            totalTokens: accumulator.totalTokens,
            estimatedCostText: sumEstimatedCostTexts(accumulator.costs),
            costUnknown: accumulator.costs.any((cost) => cost == null),
          ),
      ]..sort((left, right) {
        final byTokens = right.totalTokens.compareTo(left.totalTokens);
        return byTokens != 0
            ? byTokens
            : left.projectName.compareTo(right.projectName);
      });
  final auditedModelIds = <String>{..._auditedModels};
  for (final row in db.select(
    '''
    select distinct e.model
    from billable_usage_events e
    join sessions s on s.id = e.session_row_id
    where s.parse_status = 'available'
      and s.parser_version = ?
      and s.usage_projection_status = 'complete'
      and (
        lower(e.model) like 'gpt-5.5%'
        or lower(e.model) like 'gpt-5.6%'
        or lower(e.model) like 'openai/gpt-5.5%'
        or lower(e.model) like 'openai/gpt-5.6%'
      )
    ''',
    [currentProjectionVersion],
  )) {
    auditedModelIds.add(row['model'] as String);
  }
  final pricing = <BranchUsagePricingAudit>[];
  for (final rawModelId in auditedModelIds.toList()..sort()) {
    final publicModelId = rawModelId.startsWith('openai/')
        ? rawModelId
        : 'openai/$rawModelId';
    final publicModel = publicById[publicModelId];
    final resolution = catalog.resolve(rawModelId);
    final cached = resolution.pricing;
    pricing.add(
      BranchUsagePricingAudit(
        modelId: rawModelId,
        publicModelId: publicModelId,
        resolvedModelId: resolution.resolvedModelId,
        promptPricePerToken: publicModel?.promptPricePerToken,
        completionPricePerToken: publicModel?.completionPricePerToken,
        inputCacheReadPricePerToken: publicModel?.inputCacheReadPricePerToken,
        inputCacheWritePricePerToken: publicModel?.inputCacheWritePricePerToken,
        internalReasoningPricePerToken:
            publicModel?.internalReasoningPricePerToken,
        cachedFetchedAtUtc: cached?.fetchedAtUtc?.toIso8601String(),
        resolvedSource: cached?.source,
        resolutionMatchesPublic:
            publicModel != null && resolution.resolvedModelId == publicModelId,
        cacheMatchesPublic:
            publicModel != null &&
            cached != null &&
            cached.source == 'openrouter' &&
            _samePrice(
              cached.promptPricePerToken,
              publicModel.promptPricePerToken,
            ) &&
            _samePrice(
              cached.completionPricePerToken,
              publicModel.completionPricePerToken,
            ) &&
            _samePrice(
              cached.cachedInputPricePerToken,
              publicModel.inputCacheReadPricePerToken,
            ) &&
            _samePrice(
              cached.cacheWriteInputPricePerToken,
              publicModel.inputCacheWritePricePerToken,
            ) &&
            _samePrice(
              cached.internalReasoningPricePerToken,
              publicModel.internalReasoningPricePerToken,
            ),
      ),
    );
  }

  final isValid =
      coverage.outdatedProjectionSessions == 0 &&
      duplicateEventViolations == 0 &&
      tokenInvariantViolations == 0 &&
      unmatchedInheritedEventViolations == 0 &&
      scopeMismatchViolations == 0 &&
      ambiguousParentViolations == 0 &&
      lineage.parentForkPairs > 0 &&
      pricing.every(
        (row) => row.resolutionMatchesPublic && row.cacheMatchesPublic,
      );
  return BranchUsageAuditReport(
    isValid: isValid,
    coverage: coverage,
    duplicateEventViolations: duplicateEventViolations,
    tokenInvariantViolations: tokenInvariantViolations,
    unmatchedInheritedEventViolations: unmatchedInheritedEventViolations,
    lineage: lineage,
    projectTotals: projectTotals,
    pricing: pricing,
  );
}

int _count(Database db, String sql, [List<Object?> parameters = const []]) =>
    db.select(sql, parameters).single['count'] as int;

bool _samePrice(Object? cached, String? current) {
  if (cached == null || current == null) {
    return cached == null && current == null;
  }
  final cachedDecimal = _exactNonNegativeDecimal(cached.toString());
  final currentDecimal = _exactNonNegativeDecimal(current);
  return cachedDecimal != null &&
      currentDecimal != null &&
      cachedDecimal == currentDecimal;
}

({BigInt units, int scale})? _exactNonNegativeDecimal(String value) {
  final match = RegExp(r'^\+?(\d+)(?:\.(\d*))?$').firstMatch(value.trim());
  if (match == null) {
    return null;
  }
  final fractional = match.group(2) ?? '';
  if (fractional.length > 18) {
    return null;
  }
  var units = BigInt.parse('${match.group(1)}$fractional');
  var scale = fractional.length;
  while (scale > 0 && units % BigInt.from(10) == BigInt.zero) {
    units ~/= BigInt.from(10);
    scale--;
  }
  return (units: units, scale: scale);
}

UsagePricingCatalog _loadCachedPricingCatalog(Database db) {
  final models = <String, UsageModelPricing>{};
  for (final row in db.select('''
    select model_id, prompt_price_per_token, completion_price_per_token,
      input_cache_read_price_per_token, input_cache_write_price_per_token,
      internal_reasoning_price_per_token, source, fetched_at_utc
    from model_pricing_cache
    order by case source when 'openrouter' then 0 else 1 end, model_id
    ''')) {
    models.putIfAbsent(
      row['model_id'] as String,
      () => UsageModelPricing(
        promptPricePerToken: row['prompt_price_per_token'] as String?,
        completionPricePerToken: row['completion_price_per_token'] as String?,
        cachedInputPricePerToken:
            row['input_cache_read_price_per_token'] as String?,
        cacheWriteInputPricePerToken:
            row['input_cache_write_price_per_token'] as String?,
        internalReasoningPricePerToken:
            row['internal_reasoning_price_per_token'] as String?,
        source: row['source'] as String?,
        fetchedAtUtc: DateTime.tryParse(
          row['fetched_at_utc'] as String? ?? '',
        )?.toUtc(),
      ),
    );
  }
  return UsagePricingCatalog(Map.unmodifiable(models));
}

class BranchUsageAuditReport {
  const BranchUsageAuditReport({
    required this.isValid,
    required this.coverage,
    required this.duplicateEventViolations,
    required this.tokenInvariantViolations,
    required this.unmatchedInheritedEventViolations,
    required this.lineage,
    required this.projectTotals,
    required this.pricing,
  });

  final bool isValid;
  final BranchUsageCoverage coverage;
  final int duplicateEventViolations;
  final int tokenInvariantViolations;
  final int unmatchedInheritedEventViolations;
  final BranchUsageLineage lineage;
  final List<BranchUsageProjectTotal> projectTotals;
  final List<BranchUsagePricingAudit> pricing;

  Map<String, Object?> toJson() => {
    'valid': isValid,
    'coverage': coverage.toJson(),
    'duplicate_event_violations': duplicateEventViolations,
    'token_invariant_violations': tokenInvariantViolations,
    'unmatched_inherited_event_violations': unmatchedInheritedEventViolations,
    'lineage': lineage.toJson(),
    'project_totals': [for (final row in projectTotals) row.toJson()],
    'pricing': [for (final row in pricing) row.toJson()],
  };
}

class BranchUsageCoverage {
  const BranchUsageCoverage({
    required this.availableSessions,
    required this.currentCompleteSessions,
    required this.outdatedProjectionSessions,
    required this.legacyPendingSessions,
    required this.ambiguousSessions,
    required this.missingParentSessions,
    required this.completeZeroUsageSessions,
    required this.inheritedOnlySessions,
  });

  final int availableSessions;
  final int currentCompleteSessions;
  final int outdatedProjectionSessions;
  final int legacyPendingSessions;
  final int ambiguousSessions;
  final int missingParentSessions;
  final int completeZeroUsageSessions;
  final int inheritedOnlySessions;

  Map<String, int> toJson() => {
    'available_sessions': availableSessions,
    'current_complete_sessions': currentCompleteSessions,
    'outdated_projection_sessions': outdatedProjectionSessions,
    'legacy_pending_sessions': legacyPendingSessions,
    'ambiguous_sessions': ambiguousSessions,
    'missing_parent_sessions': missingParentSessions,
    'complete_zero_usage_sessions': completeZeroUsageSessions,
    'inherited_only_sessions': inheritedOnlySessions,
  };
}

class BranchUsageLineage {
  const BranchUsageLineage({
    required this.parentForkPairs,
    required this.forkOfForkChains,
    required this.matchedInheritedEvents,
    required this.scopeMismatchViolations,
    required this.ambiguousParentViolations,
  });

  final int parentForkPairs;
  final int forkOfForkChains;
  final int matchedInheritedEvents;
  final int scopeMismatchViolations;
  final int ambiguousParentViolations;

  Map<String, int> toJson() => {
    'parent_fork_pairs': parentForkPairs,
    'fork_of_fork_chains': forkOfForkChains,
    'matched_inherited_events': matchedInheritedEvents,
    'scope_mismatch_violations': scopeMismatchViolations,
    'ambiguous_parent_violations': ambiguousParentViolations,
  };
}

class BranchUsageProjectTotal {
  const BranchUsageProjectTotal({
    required this.projectId,
    required this.projectName,
    required this.totalTokens,
    required this.estimatedCostText,
    required this.costUnknown,
  });

  final int? projectId;
  final String projectName;
  final int totalTokens;
  final String? estimatedCostText;
  final bool costUnknown;

  Map<String, Object?> toJson() => {
    'project_id': projectId,
    'project_name': projectName,
    'total_tokens': totalTokens,
    'estimated_cost_usd': estimatedCostText,
    'cost_unknown': costUnknown,
  };
}

class _ProjectAccumulator {
  _ProjectAccumulator(this.projectId, this.projectName);

  final int? projectId;
  final String projectName;
  int totalTokens = 0;
  final List<String?> costs = [];
}

class BranchUsagePricingAudit {
  const BranchUsagePricingAudit({
    required this.modelId,
    required this.publicModelId,
    required this.resolvedModelId,
    required this.promptPricePerToken,
    required this.completionPricePerToken,
    required this.inputCacheReadPricePerToken,
    required this.inputCacheWritePricePerToken,
    required this.internalReasoningPricePerToken,
    required this.cachedFetchedAtUtc,
    required this.resolvedSource,
    required this.resolutionMatchesPublic,
    required this.cacheMatchesPublic,
  });

  final String modelId;
  final String publicModelId;
  final String? resolvedModelId;
  final String? promptPricePerToken;
  final String? completionPricePerToken;
  final String? inputCacheReadPricePerToken;
  final String? inputCacheWritePricePerToken;
  final String? internalReasoningPricePerToken;
  final String? cachedFetchedAtUtc;
  final String? resolvedSource;
  final bool resolutionMatchesPublic;
  final bool cacheMatchesPublic;

  Map<String, Object?> toJson() => {
    'model_id': modelId,
    'public_model_id': publicModelId,
    'resolved_model_id': resolvedModelId,
    'prompt_price_per_token': promptPricePerToken,
    'completion_price_per_token': completionPricePerToken,
    'input_cache_read_price_per_token': inputCacheReadPricePerToken,
    'input_cache_write_price_per_token': inputCacheWritePricePerToken,
    'internal_reasoning_price_per_token': internalReasoningPricePerToken,
    'cached_fetched_at_utc': cachedFetchedAtUtc,
    'resolved_source': resolvedSource,
    'resolution_matches_public': resolutionMatchesPublic,
    'cache_matches_public': cacheMatchesPublic,
  };
}

String? branchUsageAuditPreconditionError(Database db) {
  final schemaTable = db.select(
    "select 1 from sqlite_master where type = 'table' "
    "and name = 'schema_version'",
  );
  if (schemaTable.isEmpty) {
    return 'schema_upgrade_required';
  }
  final version =
      db
              .select(
                'select coalesce(max(version), 0) as version '
                'from schema_version where success = 1',
              )
              .single['version']
          as int;
  if (version < 15) {
    return 'schema_upgrade_required';
  }
  final objects = {
    for (final row in db.select(
      "select name from sqlite_master where name in "
      "('usage_events', 'billable_usage_events')",
    ))
      row['name'] as String,
  };
  return objects.containsAll({'usage_events', 'billable_usage_events'})
      ? null
      : 'branch_usage_schema_missing';
}

class _AuditPreconditionException implements Exception {
  const _AuditPreconditionException(this.code);

  final String code;
}

Future<List<OpenRouterModelPricing>> fetchPublicOpenRouterModels({
  Uri? endpoint,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  final deadline = Timer(timeout, () => client.close(force: true));
  try {
    final request = await client.getUrl(
      endpoint ?? Uri.parse('https://openrouter.ai/api/v1/models'),
    );
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw PricingFetchException(
        'OpenRouter returned HTTP ${response.statusCode}.',
      );
    }
    return OpenRouterModelsResponse.fromJsonText(text).models;
  } finally {
    deadline.cancel();
    client.close(force: true);
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 2 || args[0] != '--database') {
    stderr.writeln('Usage: branch_usage_audit --database <path>');
    exitCode = 64;
    return;
  }
  final databaseFile = File(args[1]);
  if (!databaseFile.existsSync()) {
    stderr.writeln(jsonEncode({'valid': false, 'error': 'database_not_found'}));
    exitCode = 1;
    return;
  }

  Database? db;
  try {
    db = sqlite3.open(databaseFile.path, mode: OpenMode.readOnly);
    db.execute('pragma busy_timeout = 10000');
    db.execute('pragma query_only = on');
    final preconditionError = branchUsageAuditPreconditionError(db);
    if (preconditionError != null) {
      throw _AuditPreconditionException(preconditionError);
    }
    final publicModels = await fetchPublicOpenRouterModels();
    final report = await auditBranchUsage(
      db,
      currentProjectionVersion: CodexSessionParser.currentVersion,
      publicModels: publicModels,
    );
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    if (!report.isValid) {
      exitCode = 1;
    }
  } on Object catch (error) {
    final code = error is _AuditPreconditionException
        ? error.code
        : 'audit_failed';
    stderr.writeln(jsonEncode({'valid': false, 'error': code}));
    exitCode = 1;
  } finally {
    db?.close();
  }
}
