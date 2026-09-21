alter table sessions add column detected_project_id integer
  references projects(id) on delete set null;

-- Capture the existing ordering once. Metadata timestamps must not move a
-- session; source reparses explicitly update the message/start evidence.
alter table sessions add column activity_at_utc text;
update sessions set activity_at_utc =
  coalesce(last_message_at_utc, started_at_utc, updated_at_utc);

create trigger trg_sessions_insert_activity after insert on sessions
begin
  update sessions set activity_at_utc =
    coalesce(new.last_message_at_utc, new.started_at_utc, new.updated_at_utc)
  where id = new.id;
end;

create trigger trg_sessions_update_activity
after update of last_message_at_utc, started_at_utc on sessions
begin
  update sessions set activity_at_utc =
    coalesce(new.last_message_at_utc, new.started_at_utc, new.updated_at_utc)
  where id = new.id and activity_at_utc is not
    coalesce(new.last_message_at_utc, new.started_at_utc, new.updated_at_utc);
end;

create index idx_sessions_available_activity
  on sessions(activity_at_utc desc, id)
  where parse_status = 'available' and scan_status = 'available'
    and session_id is not null and session_id <> '';

-- Includes undated and zero-token local events, which cannot be inferred from
-- dated daily rows. Null means this generation has not projected the session.
alter table sessions add column usage_local_event_count integer
  check (usage_local_event_count is null or usage_local_event_count >= 0);

-- Legacy rows remain null until the bounded migration merges collisions.
alter table project_path_masks add column normalized_mask text;
create unique index idx_project_path_masks_identity
  on project_path_masks(project_id, normalized_mask);

create table database_generations (
  id integer primary key autoincrement,
  source_schema_version integer not null
    check (source_schema_version >= 0),
  target_schema_version integer not null
    check (target_schema_version >= source_schema_version),
  source_fingerprint text,
  state text not null
    check (
      state in (
        'legacy',
        'building',
        'ready',
        'active',
        'cleanup_pending',
        'complete',
        'failed'
      )
    ),
  created_at_utc text not null,
  activated_at_utc text,
  completed_at_utc text,
  validation_report_json text,
  error_message text
);

insert into database_generations (
  source_schema_version,
  target_schema_version,
  source_fingerprint,
  state,
  created_at_utc
) values (
  15,
  15,
  null,
  'legacy',
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

create table database_state (
  id integer primary key check (id = 1),
  active_usage_generation_id integer not null
    references database_generations(id),
  last_optimized_schema_version integer not null default 0
    check (last_optimized_schema_version >= 0),
  project_rules_version integer not null default 0
    check (project_rules_version >= 0),
  pricing_settings_revision integer not null default 0
    check (pricing_settings_revision >= 0),
  pricing_policy_json text check (pricing_policy_json is null or json_valid(pricing_policy_json)),
  normal_writes_resumed_at_utc text,
  updated_at_utc text not null
);

insert into database_state (
  id,
  active_usage_generation_id,
  last_optimized_schema_version,
  updated_at_utc
) values (
  1,
  last_insert_rowid(),
  0,
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

create table maintenance_jobs (
  id integer primary key autoincrement,
  job_type text not null check (length(trim(job_type)) > 0),
  database_generation_id integer references database_generations(id),
  state text not null
    check (
      state in (
        'pending',
        'running',
        'interrupted',
        'succeeded',
        'failed'
      )
    ),
  phase text not null check (length(trim(phase)) > 0),
  completed_units integer not null default 0
    check (completed_units >= 0),
  total_units integer check (total_units is null or total_units >= 0),
  last_processed_rowid integer not null default 0
    check (last_processed_rowid >= 0),
  status_message text,
  run_token text,
  owner_process_id integer
    check (owner_process_id is null or owner_process_id > 0),
  heartbeat_at_utc text,
  lease_expires_at_utc text,
  attempt_count integer not null default 0
    check (attempt_count >= 0),
  started_at_utc text,
  updated_at_utc text not null,
  finished_at_utc text,
  error_message text,
  payload_json text,
  created_at_utc text not null,
  check (total_units is null or completed_units <= total_units),
  check (
    state <> 'running' or
    (run_token is not null and lease_expires_at_utc is not null)
  )
);

create unique index idx_maintenance_jobs_active_type
  on maintenance_jobs(job_type)
  where state in ('pending', 'running');

-- Lease recovery reads running jobs in ID order. Heartbeats and checkpoints
-- update timestamps, not this narrow key.
create index idx_maintenance_jobs_running
  on maintenance_jobs(id) where state = 'running';

create table maintenance_schedules (
  job_type text primary key,
  enabled integer not null default 1 check (enabled in (0, 1)),
  interval_seconds integer not null check (interval_seconds > 0),
  last_attempt_at_utc text,
  last_success_at_utc text,
  next_due_at_utc text,
  retry_count integer not null default 0 check (retry_count >= 0),
  last_error text,
  updated_at_utc text not null
);

create table usage_path_contexts (
  id integer primary key autoincrement,
  display_path_raw text not null,
  platform_path_raw text not null,
  unc_path_raw text not null,
  display_path_key text not null,
  platform_path_key text not null,
  unc_path_key text not null,
  normalization_version integer not null
    check (normalization_version > 0),
  detected_project_id integer
    references projects(id) on delete set null,
  detected_project_source text not null default 'detected'
    check (detected_project_source in ('detected', 'legacy_import')),
  mask_project_id integer
    references projects(id) on delete set null,
  effective_project_id integer
    references projects(id) on delete set null,
  resolution_source text not null
    check (
      resolution_source in (
        'mask',
        'detected',
        'legacy_import',
        'unassigned'
      )
    ),
  project_rules_version integer not null
    check (project_rules_version >= 0),
  created_at_utc text not null,
  updated_at_utc text not null
);

create unique index idx_usage_path_contexts_identity
  on usage_path_contexts(
    normalization_version,
    display_path_key,
    platform_path_key,
    unc_path_key
  );

-- Distinct original spellings can share one normalized identity. Retain each
-- raw tuple once so normalization never discards source path evidence.
create table usage_path_context_aliases (
  path_context_id integer not null references usage_path_contexts(id),
  display_path_raw text not null,
  platform_path_raw text not null,
  unc_path_raw text not null,
  primary key (path_context_id, display_path_raw, platform_path_raw, unc_path_raw)
) without rowid;

insert into usage_path_contexts (
  display_path_raw,
  platform_path_raw,
  unc_path_raw,
  display_path_key,
  platform_path_key,
  unc_path_key,
  normalization_version,
  resolution_source,
  project_rules_version,
  created_at_utc,
  updated_at_utc
) values (
  '',
  '',
  '',
  '',
  '',
  '',
  1,
  'unassigned',
  0,
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

create table usage_events_next (
  session_row_id text not null
    references sessions(id) on delete cascade,
  source_record_ordinal integer not null
    check (source_record_ordinal >= 0),
  rollout_ordinal integer
    check (rollout_ordinal is null or rollout_ordinal >= 0),
  turn_ordinal integer
    check (turn_ordinal is null or turn_ordinal >= 0),
  epoch integer not null check (epoch >= 0),
  occurred_at_utc text,
  model text,
  path_context_id integer not null
    references usage_path_contexts(id),
  input_tokens integer not null check (input_tokens >= 0),
  cached_input_tokens integer not null check (cached_input_tokens >= 0),
  cache_write_input_tokens integer not null
    check (cache_write_input_tokens >= 0),
  output_tokens integer not null check (output_tokens >= 0),
  reasoning_output_tokens integer not null
    check (reasoning_output_tokens >= 0),
  total_tokens integer not null check (total_tokens >= 0),
  branch_scope text not null
    check (branch_scope in ('local', 'inherited', 'ambiguous')),
  derivation text not null
    check (
      derivation in (
        'last_token_usage',
        'cumulative_delta',
        'counter_reset'
      )
    ),
  event_fingerprint text not null check (length(event_fingerprint) = 64),
  primary key (session_row_id, source_record_ordinal)
);

-- Historical IDs/names are evidence, not mutable project foreign keys.
-- Unattributed events have no candidate; every actual SQLite project ID is valid.
create table usage_context_project_candidates (
  generation_id integer not null references database_generations(id),
  path_context_id integer not null references usage_path_contexts(id),
  historical_project_id integer not null,
  project_name_snapshot text,
  event_count integer not null check (event_count > 0),
  malformed_timestamp_count integer not null check (malformed_timestamp_count >= 0),
  latest_event_epoch_us integer,
  latest_event_time_raw text,
  latest_source_rowid integer not null,
  latest_session_id_snapshot text not null,
  latest_source_record_ordinal integer not null,
  primary key (generation_id, path_context_id, historical_project_id)
) without rowid;

create table price_catalog_snapshots (
  id integer primary key autoincrement,
  source text not null,
  started_at_utc text not null,
  finished_at_utc text not null,
  status text not null
    check (status in ('succeeded', 'failed')),
  http_status integer
    check (http_status is null or http_status between 100 and 599),
  model_count integer not null default 0 check (model_count >= 0),
  declared_total_count integer
    check (declared_total_count is null or declared_total_count >= 0),
  page_count integer not null default 0 check (page_count >= 0),
  completeness_status text not null
    check (
      completeness_status in (
        'complete_for_removals',
        'complete_for_updates',
        'failed'
      )
    ),
  catalog_generation integer
    check (catalog_generation is null or catalog_generation > 0),
  payload_sha256 text,
  error_message text,
  check (
    declared_total_count is null or model_count is null or
    model_count <= declared_total_count
  ),
  check (
    (status = 'failed' and completeness_status = 'failed') or
    (
      status = 'succeeded' and
      completeness_status in ('complete_for_removals', 'complete_for_updates')
    )
  )
);

create table model_price_periods (
  id integer primary key autoincrement,
  source text not null,
  model_id text not null,
  canonical_slug text,
  model_name text,
  provider text not null,
  prompt_price_per_token text,
  completion_price_per_token text,
  input_cache_read_price_per_token text,
  input_cache_write_price_per_token text,
  internal_reasoning_price_per_token text,
  request_price text,
  image_price text,
  web_search_price text,
  additional_prices_json text not null default '{}' check (json_valid(additional_prices_json)),
  pricing_fingerprint text not null,
  raw_pricing_json text not null,
  valid_from_utc text not null,
  valid_to_utc text,
  first_snapshot_id integer not null
    references price_catalog_snapshots(id),
  last_seen_snapshot_id integer not null
    references price_catalog_snapshots(id),
  check (valid_to_utc is null or valid_to_utc > valid_from_utc)
);

create unique index idx_model_price_period_current
  on model_price_periods(source, model_id)
  where valid_to_utc is null;

create unique index idx_model_price_period_start
  on model_price_periods(source, model_id, valid_from_utc);

create trigger trg_model_price_period_no_overlap_insert
before insert on model_price_periods
when exists (
  select 1
  from model_price_periods existing
  where existing.source = new.source
    and existing.model_id = new.model_id
    and existing.valid_from_utc < coalesce(new.valid_to_utc, '9999-12-31T23:59:59.999999Z')
    and new.valid_from_utc < coalesce(existing.valid_to_utc, '9999-12-31T23:59:59.999999Z')
)
begin
  select raise(abort, 'model price periods must not overlap');
end;

create trigger trg_model_price_period_no_overlap_update
before update of source, model_id, valid_from_utc, valid_to_utc
on model_price_periods
when exists (
  select 1
  from model_price_periods existing
  where existing.id <> old.id
    and existing.source = new.source
    and existing.model_id = new.model_id
    and existing.valid_from_utc < coalesce(new.valid_to_utc, '9999-12-31T23:59:59.999999Z')
    and new.valid_from_utc < coalesce(existing.valid_to_utc, '9999-12-31T23:59:59.999999Z')
)
begin
  select raise(abort, 'model price periods must not overlap');
end;

create table provider_price_rules (
  id integer primary key autoincrement,
  price_period_id integer not null
    references model_price_periods(id) on delete cascade,
  provider_order integer not null check (provider_order >= 0),
  prompt_tokens_min integer
    check (prompt_tokens_min is null or prompt_tokens_min >= 0),
  -- Provider windows recur within each UTC day; an end before the start
  -- wraps midnight. They are not absolute price-period timestamps.
  utc_start_minute integer check (utc_start_minute between 0 and 1439),
  utc_end_minute integer check (utc_end_minute between 0 and 1439),
  utc_weekdays text,
  prompt_price_per_token text,
  completion_price_per_token text,
  input_cache_read_price_per_token text,
  input_cache_write_price_per_token text,
  internal_reasoning_price_per_token text,
  request_price text,
  image_price text,
  web_search_price text,
  additional_prices_json text not null default '{}' check (json_valid(additional_prices_json)),
  pricing_fingerprint text not null,
  raw_rule_json text not null,
  check (
    (utc_start_minute is null and utc_end_minute is null) or
    (utc_start_minute is not null and utc_end_minute is not null and
      utc_start_minute <> utc_end_minute)
  )
);

create unique index idx_provider_price_rules_period_order
  on provider_price_rules(price_period_id, provider_order);

create trigger trg_provider_price_rules_immutable
before update on provider_price_rules
begin
  select raise(abort, 'provider price rules are immutable');
end;

create table local_price_override_periods (
  id integer primary key autoincrement,
  model_id text not null,
  prompt_price_per_token text,
  completion_price_per_token text,
  input_cache_read_price_per_token text,
  input_cache_write_price_per_token text,
  internal_reasoning_price_per_token text,
  request_price text,
  image_price text,
  web_search_price text,
  settings_fingerprint text not null,
  valid_from_utc text not null,
  valid_to_utc text,
  first_settings_revision integer not null
    check (first_settings_revision >= 0),
  last_seen_settings_revision integer not null
    check (last_seen_settings_revision >= first_settings_revision),
  check (valid_to_utc is null or valid_to_utc > valid_from_utc)
);

create unique index idx_local_price_override_current
  on local_price_override_periods(model_id)
  where valid_to_utc is null;

create unique index idx_local_price_override_start
  on local_price_override_periods(model_id, valid_from_utc);

create trigger trg_local_price_override_no_overlap_insert
before insert on local_price_override_periods
when exists (
  select 1
  from local_price_override_periods existing
  where existing.model_id = new.model_id
    and existing.valid_from_utc < coalesce(new.valid_to_utc, '9999-12-31T23:59:59.999999Z')
    and new.valid_from_utc < coalesce(existing.valid_to_utc, '9999-12-31T23:59:59.999999Z')
)
begin
  select raise(abort, 'local price override periods must not overlap');
end;

create trigger trg_local_price_override_no_overlap_update
before update of model_id, valid_from_utc, valid_to_utc
on local_price_override_periods
when exists (
  select 1
  from local_price_override_periods existing
  where existing.id <> old.id
    and existing.model_id = new.model_id
    and existing.valid_from_utc < coalesce(new.valid_to_utc, '9999-12-31T23:59:59.999999Z')
    and new.valid_from_utc < coalesce(existing.valid_to_utc, '9999-12-31T23:59:59.999999Z')
)
begin
  select raise(abort, 'local price override periods must not overlap');
end;

create table usage_session_daily (
  id integer primary key autoincrement,
  session_id text not null references sessions(id) on delete cascade,
  day_utc text not null check (length(day_utc) = 10),
  model_key text not null,
  path_context_id integer not null references usage_path_contexts(id),
  branch_scope text not null
    check (branch_scope in ('local', 'inherited', 'ambiguous')),
  input_tokens integer not null check (input_tokens >= 0),
  cached_input_tokens integer not null check (cached_input_tokens >= 0),
  cache_write_input_tokens integer not null
    check (cache_write_input_tokens >= 0),
  output_tokens integer not null check (output_tokens >= 0),
  reasoning_output_tokens integer not null
    check (reasoning_output_tokens >= 0),
  total_tokens integer not null check (total_tokens >= 0),
  estimated_cost_text text,
  cost_status text not null
    check (
      cost_status in (
        'complete',
        'partial_unsupported_units',
        'unknown'
      )
    ),
  provider_price_period_id integer references model_price_periods(id),
  -- Canonical IDs of all matching rules in provider order, including overwritten
  -- fields. Replaying these overlays reconstructs the exact historical basis.
  provider_rule_ids_json text not null default '[]'
    check (json_valid(provider_rule_ids_json) and json_type(provider_rule_ids_json) = 'array'),
  local_override_period_id integer references local_price_override_periods(id),
  pricing_resolution_method text not null
    check (length(pricing_resolution_method) > 0),
  pricing_catalog_snapshot_id integer references price_catalog_snapshots(id),
  cost_projection_version integer not null
    check (cost_projection_version > 0),
  updated_at_utc text not null,
  check (provider_rule_ids_json = '[]' or provider_price_period_id is not null),
  check (
    provider_price_period_id is null or local_override_period_id is null
  ),
  check (
    (provider_price_period_id is null and pricing_catalog_snapshot_id is null) or
    (provider_price_period_id is not null and pricing_catalog_snapshot_id is not null)
  ),
  check (
    (
      cost_status = 'unknown' and
      estimated_cost_text is null
    ) or
    (
      cost_status in ('complete', 'partial_unsupported_units') and
      estimated_cost_text is not null and
      (
        provider_price_period_id is not null or
        local_override_period_id is not null
      )
    )
  )
);

create trigger trg_usage_session_daily_rule_period_insert
before insert on usage_session_daily
when new.provider_rule_ids_json <> (
  select json_group_array(id) from (
    select rule.id from provider_price_rules rule
    where rule.price_period_id = new.provider_price_period_id
      and rule.id in (select value from json_each(new.provider_rule_ids_json)
        where type = 'integer' and value > 0)
    order by rule.provider_order
  )
)
begin
  select raise(abort, 'provider rule basis must contain ordered unique IDs from its price period');
end;

create trigger trg_usage_session_daily_rule_period_update
before update of provider_price_period_id, provider_rule_ids_json
on usage_session_daily
when new.provider_rule_ids_json <> (
  select json_group_array(id) from (
    select rule.id from provider_price_rules rule
    where rule.price_period_id = new.provider_price_period_id
      and rule.id in (select value from json_each(new.provider_rule_ids_json)
        where type = 'integer' and value > 0)
    order by rule.provider_order
  )
)
begin
  select raise(abort, 'provider rule basis must contain ordered unique IDs from its price period');
end;

-- Historical rule deletion is not a normal writer path. This guard deliberately
-- scans the compact daily projection rather than adding another lookup index.
create trigger trg_provider_price_rules_referenced_delete
before delete on provider_price_rules
when exists (
  select 1 from usage_session_daily daily, json_each(daily.provider_rule_ids_json) basis
  where basis.value = old.id
)
begin
  select raise(abort, 'referenced provider price rules cannot be deleted');
end;

create unique index idx_usage_session_daily_basis
  on usage_session_daily(
    session_id,
    day_utc,
    model_key,
    path_context_id,
    branch_scope,
    ifnull(provider_price_period_id, 0),
    provider_rule_ids_json,
    ifnull(local_override_period_id, 0),
    pricing_resolution_method,
    cost_projection_version
  );

create index idx_usage_session_daily_billable_day
  on usage_session_daily(day_utc)
  where branch_scope = 'local';

-- A changed catalog model invalidates only observed and later daily partitions.
-- Measured against actual catalog application; avoids one full daily scan/model.
create index idx_usage_session_daily_model_day
  on usage_session_daily(model_key, day_utc);

create table usage_cost_dirty_partitions (
  session_id text not null references sessions(id) on delete cascade,
  day_utc text not null check (length(day_utc) = 10),
  model_key text not null,
  reason text not null,
  target_cost_projection_version integer not null
    check (target_cost_projection_version > 0),
  created_at_utc text not null,
  updated_at_utc text not null,
  primary key (session_id, day_utc, model_key)
);

create index idx_usage_cost_dirty_worker
  on usage_cost_dirty_partitions(model_key, day_utc, session_id);

drop index if exists idx_usage_events_model_time;
-- Snapshot status is read by primary key. Repair replay uses its audit/session
-- primary key; message reads use the existing unique session/message index.
drop index if exists idx_session_cache_repair_manifest_category;
drop index if exists idx_messages_session;
-- These columns are selected, but have no indexable production filter. Thread
-- name search uses substring LIKE, which this plain B-tree cannot accelerate.
drop index if exists idx_sessions_thread_source;
drop index if exists idx_sessions_source_state;
drop index if exists idx_sessions_thread_name;
