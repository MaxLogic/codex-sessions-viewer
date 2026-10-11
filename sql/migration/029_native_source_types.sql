-- CXV-150: widen the source-type check without losing dependent rows.

-- Both migrators must turn foreign_keys OFF before their transaction and

-- validate foreign_key_check before recording success/commit.

-- Drop dependent objects before replacing sessions so ALTER TABLE can reparse.

drop view history_tool_calls;

drop view history_sessions;

drop view history_messages;

drop trigger trg_projects_change_rename;

drop trigger trg_session_tags_change_delete;

drop trigger trg_session_tags_change_insert;

drop trigger trg_session_tags_change_update;

drop trigger trg_sessions_change_delete;

drop trigger trg_sessions_change_insert;

drop trigger trg_sessions_change_update;

drop trigger trg_sessions_insert_activity;

drop trigger trg_sessions_insert_machine_id;

drop trigger trg_sessions_update_activity;

drop trigger trg_tags_change_rename;

drop trigger trg_usage_session_daily_change_delete;

drop trigger trg_usage_session_daily_change_insert;

drop trigger trg_usage_session_daily_change_update;

create table sessions_next (
  id text primary key,
  session_id text,
  source_type text not null check (source_type in ('windows', 'wsl', 'macos', 'linux')),
  source_file_path text not null,
  source_file_unc_path text,
  display_path text not null,
  platform_path text not null,
  working_directory_display text,
  working_directory_platform text,
  working_directory_unc text,
  file_size integer not null default 0,
  modified_utc text,
  content_hash text,
  parser_version integer not null default 1,
  parse_status text not null default 'available',
  parse_error text,
  scan_status text not null default 'available',
  started_at_utc text,
  last_message_at_utc text,
  title text,
  summary text,
  message_count integer not null default 0,
  user_message_count integer not null default 0,
  assistant_message_count integer not null default 0,
  tool_call_count integer not null default 0,
  input_tokens integer,
  output_tokens integer,
  cached_input_tokens integer,
  total_tokens integer,
  model_primary text,
  models_used text,
  project_id integer,
  project_name_snapshot text,
  is_pinned integer not null default 0 check (is_pinned in (0, 1)),
  is_archived integer not null default 0 check (is_archived in (0, 1)),
  archived_at_utc text,
  archive_reason text,
  created_at_utc text not null,
  updated_at_utc text not null,
  last_scanned_utc text,
  last_parsed_utc text
, has_code_blocks integer not null default 0
  check (has_code_blocks in (0, 1)), has_tool_calls integer not null default 0
  check (has_tool_calls in (0, 1)), has_errors integer not null default 0
  check (has_errors in (0, 1)), project_override integer not null default 0
  check (project_override in (0, 1)), user_message_tokens integer not null default 0, assistant_response_tokens integer not null default 0, tool_call_tokens integer not null default 0, thread_source text, parent_thread_id text, agent_nickname text, agent_role text, subagent_depth integer, thread_name text, eval_ready integer not null default 0, eval_status text, eval_notes text, eval_expected_output text, eval_reviewed_at_utc text, eval_updated_at_utc text, source_state text not null default 'active'
  check (source_state in ('active', 'codex_archived', 'missing')), forked_from_id text, history_base_thread_id text, history_base_end_ordinal integer
  check (history_base_end_ordinal is null or history_base_end_ordinal >= 0), history_base_end_byte_offset integer
  check (history_base_end_byte_offset is null or history_base_end_byte_offset >= 0), subagent_history_start_ordinal integer
  check (
    subagent_history_start_ordinal is null or
    subagent_history_start_ordinal >= 0
  ), usage_projection_status text not null
  default 'legacy_pending'
  check (
    usage_projection_status in (
      'complete',
      'legacy_pending',
      'missing_parent',
      'ambiguous'
    )
  ), detected_project_id integer
  references projects(id) on delete set null, activity_at_utc text, usage_local_event_count integer
  check (usage_local_event_count is null or usage_local_event_count >= 0), harness text not null default 'codex', machine_id text, project_refined integer not null default 0
  check (project_refined in (0, 1)));

insert into sessions_next (rowid, id, session_id, source_type, source_file_path, source_file_unc_path, display_path, platform_path, working_directory_display, working_directory_platform, working_directory_unc, file_size, modified_utc, content_hash, parser_version, parse_status, parse_error, scan_status, started_at_utc, last_message_at_utc, title, summary, message_count, user_message_count, assistant_message_count, tool_call_count, input_tokens, output_tokens, cached_input_tokens, total_tokens, model_primary, models_used, project_id, project_name_snapshot, is_pinned, is_archived, archived_at_utc, archive_reason, created_at_utc, updated_at_utc, last_scanned_utc, last_parsed_utc, has_code_blocks, has_tool_calls, has_errors, project_override, user_message_tokens, assistant_response_tokens, tool_call_tokens, thread_source, parent_thread_id, agent_nickname, agent_role, subagent_depth, thread_name, eval_ready, eval_status, eval_notes, eval_expected_output, eval_reviewed_at_utc, eval_updated_at_utc, source_state, forked_from_id, history_base_thread_id, history_base_end_ordinal, history_base_end_byte_offset, subagent_history_start_ordinal, usage_projection_status, detected_project_id, activity_at_utc, usage_local_event_count, harness, machine_id, project_refined)
select rowid, id, session_id, source_type, source_file_path, source_file_unc_path, display_path, platform_path, working_directory_display, working_directory_platform, working_directory_unc, file_size, modified_utc, content_hash, parser_version, parse_status, parse_error, scan_status, started_at_utc, last_message_at_utc, title, summary, message_count, user_message_count, assistant_message_count, tool_call_count, input_tokens, output_tokens, cached_input_tokens, total_tokens, model_primary, models_used, project_id, project_name_snapshot, is_pinned, is_archived, archived_at_utc, archive_reason, created_at_utc, updated_at_utc, last_scanned_utc, last_parsed_utc, has_code_blocks, has_tool_calls, has_errors, project_override, user_message_tokens, assistant_response_tokens, tool_call_tokens, thread_source, parent_thread_id, agent_nickname, agent_role, subagent_depth, thread_name, eval_ready, eval_status, eval_notes, eval_expected_output, eval_reviewed_at_utc, eval_updated_at_utc, source_state, forked_from_id, history_base_thread_id, history_base_end_ordinal, history_base_end_byte_offset, subagent_history_start_ordinal, usage_projection_status, detected_project_id, activity_at_utc, usage_local_event_count, harness, machine_id, project_refined from sessions;

create temp table cxv29_copy_guard (delta integer check (delta = 0));

insert into cxv29_copy_guard values ((select count(*) from sessions) - (select count(*) from sessions_next));

drop table cxv29_copy_guard;

drop table sessions;

alter table sessions_next rename to sessions;

CREATE INDEX idx_sessions_archived on sessions(is_archived);

CREATE INDEX idx_sessions_available_activity
  on sessions(activity_at_utc desc, id)
  where parse_status = 'available' and scan_status = 'available'
    and session_id is not null and session_id <> '';

CREATE INDEX idx_sessions_eval_ready on sessions(eval_ready);

CREATE INDEX idx_sessions_eval_status on sessions(eval_status);

CREATE INDEX idx_sessions_forked_from_id
  on sessions(forked_from_id)
  where forked_from_id is not null;

CREATE UNIQUE INDEX idx_sessions_harness_session_id_unique
on sessions(harness, session_id)
where session_id is not null and trim(session_id) <> '';

CREATE INDEX idx_sessions_machine_harness_session
  on sessions(machine_id, harness, session_id);

CREATE INDEX idx_sessions_parent_thread_id
  on sessions(parent_thread_id)
  where parent_thread_id is not null;

CREATE INDEX idx_sessions_parse_status on sessions(parse_status);

CREATE INDEX idx_sessions_scan_status on sessions(scan_status);

CREATE INDEX idx_sessions_session_id on sessions(session_id);

CREATE INDEX idx_sessions_source_type on sessions(source_type);

CREATE TRIGGER trg_projects_change_rename after update of name on projects
when old.name is not new.name
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select s.id, (select revision from session_change_state where id = 1), 0
    from sessions s where s.project_id = new.id or s.detected_project_id = new.id
    on conflict(session_id) do update set revision = excluded.revision;
end;

CREATE TRIGGER trg_session_tags_change_delete after delete on session_tags
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select old.session_id, revision, 0 from session_change_state where id = 1
      and exists (select 1 from sessions where id = old.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

CREATE TRIGGER trg_session_tags_change_insert after insert on session_tags
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select new.session_id, revision, 0 from session_change_state where id = 1
      and exists (select 1 from sessions where id = new.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

CREATE TRIGGER trg_session_tags_change_update after update on session_tags
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select new.session_id, revision, 0 from session_change_state where id = 1
      and exists (select 1 from sessions where id = new.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

CREATE TRIGGER trg_sessions_change_delete after delete on sessions

begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    values (old.id, (select revision from session_change_state where id = 1), 1)
    on conflict(session_id) do update set revision = excluded.revision, deleted = excluded.deleted;
end;

CREATE TRIGGER trg_sessions_change_insert after insert on sessions

begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    values (new.id, (select revision from session_change_state where id = 1), 0)
    on conflict(session_id) do update set revision = excluded.revision, deleted = excluded.deleted;
end;

CREATE TRIGGER trg_sessions_change_update after update on sessions
when old.id is not new.id
  or old.session_id is not new.session_id
  or old.source_type is not new.source_type
  or old.source_file_path is not new.source_file_path
  or old.source_file_unc_path is not new.source_file_unc_path
  or old.display_path is not new.display_path
  or old.platform_path is not new.platform_path
  or old.working_directory_display is not new.working_directory_display
  or old.working_directory_platform is not new.working_directory_platform
  or old.working_directory_unc is not new.working_directory_unc
  or old.file_size is not new.file_size
  or old.modified_utc is not new.modified_utc
  or old.content_hash is not new.content_hash
  or old.parser_version is not new.parser_version
  or old.parse_status is not new.parse_status
  or old.parse_error is not new.parse_error
  or old.scan_status is not new.scan_status
  or old.started_at_utc is not new.started_at_utc
  or old.last_message_at_utc is not new.last_message_at_utc
  or old.title is not new.title
  or old.summary is not new.summary
  or old.message_count is not new.message_count
  or old.user_message_count is not new.user_message_count
  or old.assistant_message_count is not new.assistant_message_count
  or old.tool_call_count is not new.tool_call_count
  or old.input_tokens is not new.input_tokens
  or old.output_tokens is not new.output_tokens
  or old.cached_input_tokens is not new.cached_input_tokens
  or old.total_tokens is not new.total_tokens
  or old.model_primary is not new.model_primary
  or old.models_used is not new.models_used
  or old.project_id is not new.project_id
  or old.project_name_snapshot is not new.project_name_snapshot
  or old.is_pinned is not new.is_pinned
  or old.is_archived is not new.is_archived
  or old.archived_at_utc is not new.archived_at_utc
  or old.archive_reason is not new.archive_reason
  or old.last_parsed_utc is not new.last_parsed_utc
  or old.has_code_blocks is not new.has_code_blocks
  or old.has_tool_calls is not new.has_tool_calls
  or old.has_errors is not new.has_errors
  or old.project_override is not new.project_override
  or old.user_message_tokens is not new.user_message_tokens
  or old.assistant_response_tokens is not new.assistant_response_tokens
  or old.tool_call_tokens is not new.tool_call_tokens
  or old.thread_source is not new.thread_source
  or old.parent_thread_id is not new.parent_thread_id
  or old.agent_nickname is not new.agent_nickname
  or old.agent_role is not new.agent_role
  or old.subagent_depth is not new.subagent_depth
  or old.thread_name is not new.thread_name
  or old.eval_ready is not new.eval_ready
  or old.eval_status is not new.eval_status
  or old.eval_notes is not new.eval_notes
  or old.eval_expected_output is not new.eval_expected_output
  or old.eval_reviewed_at_utc is not new.eval_reviewed_at_utc
  or old.eval_updated_at_utc is not new.eval_updated_at_utc
  or old.source_state is not new.source_state
  or old.forked_from_id is not new.forked_from_id
  or old.history_base_thread_id is not new.history_base_thread_id
  or old.history_base_end_ordinal is not new.history_base_end_ordinal
  or old.history_base_end_byte_offset is not new.history_base_end_byte_offset
  or old.subagent_history_start_ordinal is not new.subagent_history_start_ordinal
  or old.usage_projection_status is not new.usage_projection_status
  or old.detected_project_id is not new.detected_project_id
  or old.activity_at_utc is not new.activity_at_utc
  or old.usage_local_event_count is not new.usage_local_event_count
  or old.harness is not new.harness
  or old.machine_id is not new.machine_id
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    values (new.id, (select revision from session_change_state where id = 1), 0)
    on conflict(session_id) do update set revision = excluded.revision, deleted = excluded.deleted;
end;

CREATE TRIGGER trg_sessions_insert_activity after insert on sessions
begin
  update sessions set activity_at_utc =
    coalesce(new.last_message_at_utc, new.started_at_utc, new.updated_at_utc)
  where id = new.id;
end;

CREATE TRIGGER trg_sessions_insert_machine_id
after insert on sessions
when new.machine_id is null
begin
  update sessions
  set machine_id = (select value from app_metadata where key = 'machine_id')
  where rowid = new.rowid;
end;

CREATE TRIGGER trg_sessions_update_activity
after update of last_message_at_utc, started_at_utc on sessions
begin
  update sessions set activity_at_utc =
    coalesce(new.last_message_at_utc, new.started_at_utc, new.updated_at_utc)
  where id = new.id and activity_at_utc is not
    coalesce(new.last_message_at_utc, new.started_at_utc, new.updated_at_utc);
end;

CREATE TRIGGER trg_tags_change_rename after update of name on tags
when old.name is not new.name
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select st.session_id, (select revision from session_change_state where id = 1), 0
    from session_tags st where st.tag_id = new.id
      and exists (select 1 from sessions where id = st.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

CREATE TRIGGER trg_usage_session_daily_change_delete after delete on usage_session_daily
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select old.session_id, revision, 0 from session_change_state where id = 1
      and exists (select 1 from sessions where id = old.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

CREATE TRIGGER trg_usage_session_daily_change_insert after insert on usage_session_daily
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select new.session_id, revision, 0 from session_change_state where id = 1
      and exists (select 1 from sessions where id = new.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

CREATE TRIGGER trg_usage_session_daily_change_update after update on usage_session_daily
when old.session_id is not new.session_id
  or old.day_utc is not new.day_utc
  or old.model_key is not new.model_key
  or old.path_context_id is not new.path_context_id
  or old.branch_scope is not new.branch_scope
  or old.input_tokens is not new.input_tokens
  or old.cached_input_tokens is not new.cached_input_tokens
  or old.cache_write_input_tokens is not new.cache_write_input_tokens
  or old.output_tokens is not new.output_tokens
  or old.reasoning_output_tokens is not new.reasoning_output_tokens
  or old.total_tokens is not new.total_tokens
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select new.session_id, revision, 0 from session_change_state where id = 1
      and exists (select 1 from sessions where id = new.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

CREATE VIEW history_sessions as
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

CREATE VIEW history_messages as
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

CREATE VIEW history_tool_calls as
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
