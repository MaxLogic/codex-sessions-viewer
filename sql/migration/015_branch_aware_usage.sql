alter table sessions add column forked_from_id text;
alter table sessions add column history_base_thread_id text;
alter table sessions add column history_base_end_ordinal integer
  check (history_base_end_ordinal is null or history_base_end_ordinal >= 0);
alter table sessions add column history_base_end_byte_offset integer
  check (history_base_end_byte_offset is null or history_base_end_byte_offset >= 0);
alter table sessions add column subagent_history_start_ordinal integer
  check (
    subagent_history_start_ordinal is null or
    subagent_history_start_ordinal >= 0
  );
alter table sessions add column usage_projection_status text not null
  default 'legacy_pending'
  check (
    usage_projection_status in (
      'complete',
      'legacy_pending',
      'missing_parent',
      'ambiguous'
    )
  );

create table usage_events (
  session_row_id text not null
    references sessions(id) on delete cascade,
  source_record_ordinal integer not null
    check (source_record_ordinal >= 0),
  rollout_ordinal integer
    check (rollout_ordinal is null or rollout_ordinal >= 0),
  turn_ordinal integer
    check (turn_ordinal is null or turn_ordinal >= 0),
  epoch integer not null
    check (epoch >= 0),
  occurred_at_utc text,
  model text,
  working_directory_display text,
  working_directory_platform text,
  working_directory_unc text,
  project_id integer references projects(id) on delete set null,
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
  event_fingerprint text not null
    check (length(event_fingerprint) = 64),
  primary key (session_row_id, source_record_ordinal)
);

create index idx_sessions_forked_from_id
  on sessions(forked_from_id)
  where forked_from_id is not null;

create index idx_sessions_parent_thread_id
  on sessions(parent_thread_id)
  where parent_thread_id is not null;

create index idx_usage_events_time_project
  on usage_events(occurred_at_utc, project_id);

create index idx_usage_events_model_time
  on usage_events(model, occurred_at_utc);

create view billable_usage_events as
select *
from usage_events
where branch_scope = 'local';
