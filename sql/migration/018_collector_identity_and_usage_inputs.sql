-- Machine and harness identity for collected sessions, plus the usage inputs
-- conditional pricing needs.
-- Every database gets one persistent machine ID. Existing rows are this
-- machine's Codex history; the viewer's scan and the collector keep inserting
-- through the column defaults and the trigger, so neither writer has to know
-- the ID. The database owner decides who migrates it: the viewer unless a
-- standalone collector created the database and recorded itself.
insert or ignore into app_metadata (key, value, updated_at_utc)
values (
  'machine_id',
  lower(hex(randomblob(16))),
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

insert or ignore into app_metadata (key, value, updated_at_utc)
values ('database_owner', 'viewer', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));

alter table sessions add column harness text not null default 'codex';
alter table sessions add column machine_id text;

update sessions
set machine_id = (select value from app_metadata where key = 'machine_id')
where machine_id is null;

create trigger trg_sessions_insert_machine_id
after insert on sessions
when new.machine_id is null
begin
  update sessions
  set machine_id = (select value from app_metadata where key = 'machine_id')
  where rowid = new.rowid;
end;

create index idx_sessions_machine_harness_session
  on sessions(machine_id, harness, session_id);

-- Conditional-pricing inputs, one row per usage event that reported any.
-- A separate table because the viewer swaps usage_events storage between
-- generations by renaming tables. Null means the source did not report the
-- value; it is never a guessed zero. request_input_tokens is the prompt size
-- of one model request, known only when the event is that request's own usage.
-- billable_units_json holds non-token units as a JSON object.
create table usage_event_inputs (
  session_row_id text not null references sessions(id) on delete cascade,
  source_record_ordinal integer not null check (source_record_ordinal >= 0),
  provider text,
  request_input_tokens integer
    check (request_input_tokens is null or request_input_tokens >= 0),
  model_context_window integer
    check (model_context_window is null or model_context_window >= 0),
  billable_units_json text
    check (billable_units_json is null or json_valid(billable_units_json)),
  primary key (session_row_id, source_record_ordinal)
) without rowid;
