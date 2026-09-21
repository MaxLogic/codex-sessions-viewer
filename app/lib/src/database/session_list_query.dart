/// The cached Sessions query shared by runtime and query-plan benchmarks.
({String sql, List<Object?> parameters}) sessionListQuery({
  String? sessionId,
  int? limit,
  int offset = 0,
}) {
  final filters = [
    "s.parse_status = 'available'",
    "s.scan_status = 'available'",
    's.session_id is not null',
    "s.session_id <> ''",
    if (sessionId != null) 's.id = ?',
  ];
  final limitClause = limit == null ? '' : 'limit ? offset ?';
  // Skewed status statistics can otherwise choose a filter index plus a sort.
  // Point reads must remain free to use the primary key.
  final indexClause = sessionId == null
      ? ' indexed by idx_sessions_available_activity'
      : '';
  final args = <Object?>[?sessionId];
  if (limit != null) {
    args
      ..add(limit)
      ..add(offset);
  }
  return (
    sql:
        '''
    select
      s.id,
      s.session_id,
      s.thread_name,
      s.thread_source,
      s.parent_thread_id,
      s.agent_nickname,
      s.agent_role,
      s.subagent_depth,
      s.source_type,
      s.source_state,
      s.source_file_path,
      s.source_file_unc_path,
      s.display_path,
      s.platform_path,
      s.working_directory_display,
      s.working_directory_unc,
      s.started_at_utc,
      s.last_message_at_utc,
      nullif(trim(s.title), '') as row_title,
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
      s.user_message_tokens,
      s.assistant_response_tokens,
      s.tool_call_tokens,
      s.model_primary,
      s.models_used,
      s.project_name_snapshot,
      s.scan_status,
      s.parse_status,
      s.is_pinned,
      s.is_archived,
      s.has_errors,
      s.eval_ready,
      s.eval_status,
      s.eval_notes,
      s.eval_expected_output,
      s.eval_reviewed_at_utc,
      s.eval_updated_at_utc
    from sessions s$indexClause
    where ${filters.join(' and ')}
    order by s.activity_at_utc desc,
             s.id asc
    $limitClause
    ''',
    parameters: args,
  );
}
