alter table sessions add column eval_ready integer not null default 0;
alter table sessions add column eval_status text;
alter table sessions add column eval_notes text;
alter table sessions add column eval_expected_output text;
alter table sessions add column eval_reviewed_at_utc text;
alter table sessions add column eval_updated_at_utc text;

create index if not exists idx_sessions_eval_ready on sessions(eval_ready);
create index if not exists idx_sessions_eval_status on sessions(eval_status);
