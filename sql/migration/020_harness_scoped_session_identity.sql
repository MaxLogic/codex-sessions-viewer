-- Session IDs are unique per harness, not globally: a Codex and a Claude
-- session may carry the same ID without being the same session.
drop index if exists idx_sessions_session_id_unique;

create unique index idx_sessions_harness_session_id_unique
on sessions(harness, session_id)
where session_id is not null and trim(session_id) <> '';

-- Source fields a collector read but the schema does not model, kept as
-- evidence (for example unknown Claude transcript record types or usage
-- keys). One JSON object per session; replaced on every reparse.
create table session_source_extras (
  session_row_id text primary key references sessions(id) on delete cascade,
  extra_json text not null check (json_valid(extra_json)),
  updated_at_utc text not null
) without rowid;
