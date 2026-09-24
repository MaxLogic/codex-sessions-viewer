-- One durable watermark and one latest revision per session, including tombstones.
-- Readers acknowledge a watermark only with the corresponding snapshot/delta.
-- Collector message/usage replacement updates sessions in the same transaction.
create table session_change_state (
  id integer primary key check (id = 1),
  revision integer not null check (revision >= 0)
);
insert into session_change_state values (1, 0);
create table session_changes (
  session_id text primary key,
  revision integer not null,
  deleted integer not null check (deleted in (0, 1))
) without rowid;
create index idx_session_changes_revision on session_changes(revision);

create trigger trg_sessions_change_insert after insert on sessions

begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    values (new.id, (select revision from session_change_state where id = 1), 0)
    on conflict(session_id) do update set revision = excluded.revision, deleted = excluded.deleted;
end;

create trigger trg_sessions_change_update after update on sessions
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

create trigger trg_sessions_change_delete after delete on sessions

begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    values (old.id, (select revision from session_change_state where id = 1), 1)
    on conflict(session_id) do update set revision = excluded.revision, deleted = excluded.deleted;
end;

create trigger trg_session_tags_change_insert after insert on session_tags
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select new.session_id, revision, 0 from session_change_state where id = 1
      and exists (select 1 from sessions where id = new.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

create trigger trg_session_tags_change_update after update on session_tags
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select new.session_id, revision, 0 from session_change_state where id = 1
      and exists (select 1 from sessions where id = new.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

create trigger trg_session_tags_change_delete after delete on session_tags
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select old.session_id, revision, 0 from session_change_state where id = 1
      and exists (select 1 from sessions where id = old.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

create trigger trg_usage_session_daily_change_insert after insert on usage_session_daily
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select new.session_id, revision, 0 from session_change_state where id = 1
      and exists (select 1 from sessions where id = new.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

create trigger trg_usage_session_daily_change_update after update on usage_session_daily
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select new.session_id, revision, 0 from session_change_state where id = 1
      and exists (select 1 from sessions where id = new.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

create trigger trg_usage_session_daily_change_delete after delete on usage_session_daily
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select old.session_id, revision, 0 from session_change_state where id = 1
      and exists (select 1 from sessions where id = old.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

