-- Read-only views for querying collected history directly with SQL.
-- Their names and columns are a documented contract (see
-- docs/skills/session-history/references/database.md); the tables behind
-- them may change. Views over plain tables cannot be written through.
--
-- A session reference is
--   history://<machine_id>/<harness>/<session key>
-- where the session key is the harness's own session ID, or the database row
-- ID for a source that has none. A message reference appends
-- #<message_index>. References identify the currently parsed revision.
--
-- There is deliberately no usage view: the viewer swaps usage_events storage
-- by renaming tables, and ALTER TABLE RENAME rewrites and re-validates every
-- view, so a view over usage storage could break that migration. Query usage
-- through the viewer or the collector's query commands.

create view history_sessions as
select
  s.id as row_id,
  coalesce(s.machine_id, '') as machine_id,
  s.harness,
  coalesce(nullif(trim(s.session_id), ''), s.id) as session_key,
  'history://' || coalesce(s.machine_id, '') || '/' || s.harness || '/'
    || coalesce(nullif(trim(s.session_id), ''), s.id) as reference,
  s.session_id,
  s.source_type as environment,
  coalesce(p.name, s.project_name_snapshot) as project,
  s.working_directory_display as working_directory,
  s.working_directory_platform,
  s.source_file_path,
  s.source_state,
  s.scan_status,
  s.title,
  s.summary,
  s.thread_name,
  s.thread_source,
  s.parent_thread_id,
  s.forked_from_id,
  s.started_at_utc,
  s.last_message_at_utc,
  coalesce(s.last_message_at_utc, s.started_at_utc) as activity_at_utc,
  s.last_parsed_utc,
  s.message_count,
  s.user_message_count,
  s.assistant_message_count,
  s.tool_call_count,
  s.input_tokens,
  s.output_tokens,
  s.cached_input_tokens,
  s.total_tokens,
  s.model_primary,
  s.models_used,
  s.is_archived,
  s.is_pinned
from sessions s
left join projects p on p.id = s.project_id
where s.parse_status = 'available'
  and s.id not like '%source-status:%';

create view history_messages as
select
  m.id as message_rowid,
  h.row_id as session_row_id,
  h.machine_id,
  h.harness,
  h.session_key,
  h.reference as session_reference,
  h.reference || '#' || m.message_index as reference,
  m.message_index,
  m.author_type,
  m.raw_type,
  m.created_at_utc,
  m.content_plain,
  m.content_truncated,
  m.token_input,
  m.token_output,
  m.token_cached,
  m.token_total,
  m.model,
  m.has_tool_calls,
  m.has_error
from messages m
join history_sessions h on h.row_id = m.session_id;

create view history_tool_calls as
select
  h.row_id as session_row_id,
  h.machine_id,
  h.harness,
  h.session_key,
  h.reference as session_reference,
  t.tool_index,
  t.tool_name,
  t.status,
  t.started_at_utc,
  t.finished_at_utc,
  t.input_preview,
  t.output_preview,
  t.output_truncated,
  t.error_message
from tool_calls t
join history_sessions h on h.row_id = t.session_id;
