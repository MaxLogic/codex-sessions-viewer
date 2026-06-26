alter table sessions add column thread_name text;

create index if not exists idx_sessions_thread_name on sessions(thread_name);
