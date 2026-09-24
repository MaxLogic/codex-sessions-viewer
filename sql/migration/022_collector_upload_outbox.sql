-- Optional hub delivery is enabled explicitly in collector_hub_state. Every
-- queued envelope is committed with its local projection, then removed only
-- after an authenticated hub acknowledgment.
create table collector_hub_state (
  id integer primary key check (id = 1),
  hub_url text not null,
  machine_id text not null,
  last_sequence integer not null default 0 check (last_sequence >= 0),
  enabled integer not null default 1 check (enabled in (0, 1))
);

create table collector_upload_outbox (
  id integer primary key autoincrement,
  record_json text not null check (json_valid(record_json)),
  created_at_utc text not null
);
