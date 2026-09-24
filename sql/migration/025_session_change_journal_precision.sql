-- Repricing rewrites only the cost columns of usage_session_daily. The
-- sessions list reads costs through its pricing revision, not through the
-- change journal, so an update that keeps every token total and grain is not
-- a session change. Journaling it marked every session changed on a reprice.
drop trigger trg_usage_session_daily_change_update;

create trigger trg_usage_session_daily_change_update after update on usage_session_daily
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

-- Session rows show tag names; a renamed tag changes every tagged session.
create trigger trg_tags_change_rename after update of name on tags
when old.name is not new.name
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select st.session_id, (select revision from session_change_state where id = 1), 0
    from session_tags st where st.tag_id = new.id
      and exists (select 1 from sessions where id = st.session_id)
    on conflict(session_id) do update set revision = excluded.revision;
end;

-- A renamed project changes the sessions assigned to it or detected in it,
-- including rows whose name snapshot is refreshed later.
create trigger trg_projects_change_rename after update of name on projects
when old.name is not new.name
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
    select s.id, (select revision from session_change_state where id = 1), 0
    from sessions s where s.project_id = new.id or s.detected_project_id = new.id
    on conflict(session_id) do update set revision = excluded.revision;
end;
