alter table sessions add column t3_parent_thread_id text;
alter table sessions add column t3_parent_session_id text;
alter table sessions add column t3_relationship text;

create trigger trg_sessions_t3_change after update of
  t3_parent_thread_id, t3_parent_session_id, t3_relationship on sessions
when old.t3_parent_thread_id is not new.t3_parent_thread_id
  or old.t3_parent_session_id is not new.t3_parent_session_id
  or old.t3_relationship is not new.t3_relationship
begin
  update session_change_state set revision = revision + 1 where id = 1;
  insert into session_changes(session_id, revision, deleted)
  values(new.id, (select revision from session_change_state where id = 1), 0)
  on conflict(session_id) do update set revision = excluded.revision;
end;
