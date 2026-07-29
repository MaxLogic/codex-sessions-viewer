alter table sessions
  add column source_state text not null default 'active'
  check (source_state in ('active', 'codex_archived', 'missing'));

update sessions
set source_state = case
  when scan_status = 'missing' then 'missing'
  when replace(lower(coalesce(source_file_path, '')), '\', '/')
         like '%/archived_sessions/%'
    or replace(lower(coalesce(source_file_unc_path, '')), '\', '/')
         like '%/archived_sessions/%'
    or replace(lower(coalesce(display_path, '')), '\', '/')
         like '%/archived_sessions/%'
    or replace(lower(coalesce(platform_path, '')), '\', '/')
         like '%/archived_sessions/%'
    then 'codex_archived'
  else 'active'
end;

create index if not exists idx_sessions_source_state
  on sessions(source_state);
