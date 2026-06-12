create table if not exists schema_version (
  version integer primary key,
  filename text not null,
  checksum text not null,
  applied_at_utc text not null,
  success integer not null check (success in (0, 1)),
  error_message text
);

create table if not exists app_metadata (
  key text primary key,
  value text not null,
  updated_at_utc text not null
);

create table if not exists sessions (
  id text primary key,
  session_id text,
  source_type text not null check (source_type in ('windows', 'wsl')),
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
);

create table if not exists messages (
  id integer primary key autoincrement,
  session_id text not null references sessions(id) on delete cascade,
  message_index integer not null,
  author_type text not null,
  created_at_utc text,
  first_line text not null default '',
  summary text,
  content_markdown text,
  content_plain text,
  content_preview text not null default '',
  content_truncated integer not null default 0 check (content_truncated in (0, 1)),
  token_input integer,
  token_output integer,
  token_cached integer,
  token_total integer,
  model text,
  has_tool_calls integer not null default 0 check (has_tool_calls in (0, 1)),
  has_error integer not null default 0 check (has_error in (0, 1)),
  raw_type text,
  created_at_db_utc text not null,
  updated_at_db_utc text not null,
  unique (session_id, message_index)
);

create table if not exists tool_calls (
  id integer primary key autoincrement,
  session_id text not null references sessions(id) on delete cascade,
  message_id integer references messages(id) on delete cascade,
  tool_index integer not null,
  tool_name text not null,
  status text not null,
  started_at_utc text,
  finished_at_utc text,
  input_preview text,
  output_preview text,
  output_truncated integer not null default 0 check (output_truncated in (0, 1)),
  error_message text
);

create table if not exists projects (
  id integer primary key autoincrement,
  name text not null unique,
  description text,
  is_active integer not null default 1 check (is_active in (0, 1)),
  created_at_utc text not null,
  updated_at_utc text not null
);

create table if not exists project_path_masks (
  id integer primary key autoincrement,
  project_id integer not null references projects(id) on delete cascade,
  path_mask text not null,
  priority integer not null default 100,
  is_active integer not null default 1 check (is_active in (0, 1)),
  created_at_utc text not null,
  updated_at_utc text not null
);

create table if not exists tags (
  id integer primary key autoincrement,
  name text not null unique,
  color text,
  created_at_utc text not null,
  updated_at_utc text not null
);

create table if not exists session_tags (
  session_id text not null references sessions(id) on delete cascade,
  tag_id integer not null references tags(id) on delete cascade,
  created_at_utc text not null,
  primary key (session_id, tag_id)
);

create table if not exists session_path_keys (
  session_id text not null references sessions(id) on delete cascade,
  path_key text not null,
  primary key (session_id, path_key)
);

create table if not exists usage_daily (
  day_utc text not null,
  model text,
  project_id integer,
  source_type text,
  is_archived integer not null default 0 check (is_archived in (0, 1)),
  session_count integer not null default 0,
  message_count integer not null default 0,
  input_tokens integer not null default 0,
  output_tokens integer not null default 0,
  cached_input_tokens integer not null default 0,
  total_tokens integer not null default 0,
  estimated_cost_text text,
  primary key (day_utc, model, project_id, source_type, is_archived)
);

create table if not exists scan_runs (
  id integer primary key autoincrement,
  started_at_utc text not null,
  finished_at_utc text,
  files_found integer not null default 0,
  files_skipped integer not null default 0,
  files_parsed integer not null default 0,
  files_failed integer not null default 0,
  sessions_added integer not null default 0,
  sessions_changed integer not null default 0,
  sessions_missing integer not null default 0
);

create table if not exists scan_errors (
  id integer primary key autoincrement,
  scan_run_id integer references scan_runs(id) on delete cascade,
  source_path text not null,
  status text not null,
  message text not null,
  details text,
  created_at_utc text not null
);

create table if not exists model_pricing_cache (
  model_id text primary key,
  model_name text,
  provider text not null,
  prompt_price_per_token text,
  completion_price_per_token text,
  input_cache_read_price_per_token text,
  input_cache_write_price_per_token text,
  internal_reasoning_price_per_token text,
  request_price text,
  raw_pricing_json text,
  fetched_at_utc text not null,
  source text not null check (source in ('openrouter', 'override'))
);

create table if not exists logs (
  id integer primary key autoincrement,
  time_utc text not null,
  level text not null,
  category text not null,
  message text not null,
  details text
);

create virtual table if not exists session_search using fts5(
  title,
  summary,
  user_messages,
  assistant_messages,
  display_path,
  normalized_path_keys,
  project_name,
  tags,
  tool_output,
  content=''
);

create index if not exists idx_sessions_source_type on sessions(source_type);
create index if not exists idx_sessions_parse_status on sessions(parse_status);
create index if not exists idx_sessions_scan_status on sessions(scan_status);
create index if not exists idx_sessions_archived on sessions(is_archived);
create index if not exists idx_messages_session on messages(session_id);
create index if not exists idx_tool_calls_session on tool_calls(session_id);
create index if not exists idx_logs_category_time on logs(category, time_utc);
