alter table sessions add column thread_source text;
alter table sessions add column parent_thread_id text;
alter table sessions add column agent_nickname text;
alter table sessions add column agent_role text;
alter table sessions add column subagent_depth integer;

create index if not exists idx_sessions_thread_source on sessions(thread_source);
