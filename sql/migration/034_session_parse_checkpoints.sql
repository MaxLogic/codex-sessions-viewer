-- Collector-owned parser state. Never uploaded to the hub.
-- Null means the writer did not have a local parser-options identity.
alter table sessions add column parse_options_hash text;
create table session_parse_checkpoints (
  id integer primary key,
  harness text not null,
  source_key text not null,
  source_file_path text not null,
  session_row_id text not null references sessions(id) on delete cascade,
  parser_version integer not null,
  format_version integer not null,
  consumed_bytes integer not null,
  content_hash text not null,
  parse_options_hash text,
  state blob not null,
  steps_since_full integer not null,
  updated_at_utc text not null,
  unique(harness, source_key)
);
create index idx_session_parse_checkpoints_session on session_parse_checkpoints(session_row_id);

-- Scope predicates must not fetch old tool previews just to inspect their key.
create index idx_tool_calls_session_tool_index on tool_calls(session_id, tool_index);
