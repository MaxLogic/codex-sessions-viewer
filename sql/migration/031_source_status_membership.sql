-- CXV-216: resolve status membership by changed source, preserving exact paths.
-- Lead with path so unrelated harness-only predicates retain their own indexes.
-- Cover membership fields so a scan rematching many sources reads these compact
-- indexes rather than the wide sessions table. Rowid is carried by SQLite.
create index idx_sessions_harness_source_path
  on sessions(source_file_path, harness, id, scan_status, source_state, parse_status);
create index idx_sessions_harness_source_unc_path
  on sessions(source_file_unc_path, harness, id, scan_status, source_state, parse_status);
