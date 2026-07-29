create table session_cache_repair_manifest (
  audit_id text not null,
  repair_version integer not null,
  session_rowid integer not null,
  row_fingerprint text not null,
  category text not null check (
    category in (
      'canonical',
      'relocated',
      'fallback_duplicate',
      'legacy_non_session_artifact',
      'unresolved'
    )
  ),
  reason_code text not null,
  delete_eligible integer not null check (delete_eligible in (0, 1)),
  recorded_at_utc text not null,
  primary key (audit_id, session_rowid)
);

create index idx_session_cache_repair_manifest_category
  on session_cache_repair_manifest(audit_id, category, delete_eligible);
