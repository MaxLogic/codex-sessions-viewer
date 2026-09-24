-- T-138: bounded hub delivery and compact hub price history.
-- Unsent records for one source key coalesce; the newest state replaces older
-- unsent state. Keyless records (project hints) are always appended.
alter table collector_upload_outbox add column record_key text;
create unique index idx_collector_upload_outbox_record_key
  on collector_upload_outbox(record_key) where record_key is not null;

-- The last queued state per source key. Unchanged scan statuses and thread
-- names are not queued again. Cleared by `hub disable` and `hub resync`.
create table collector_hub_record_state (
  record_key text primary key,
  record_hash text not null
);

-- A batch is persisted before it is sent so that a lost acknowledgment is
-- retried with the same sequence and batch ID.
alter table collector_hub_state add column inflight_batch_id text;
alter table collector_hub_state add column inflight_last_id integer;

-- Records the hub permanently rejected. They no longer block the queue.
create table collector_upload_dead_letters (
  id integer primary key autoincrement,
  outbox_id integer not null,
  record_key text,
  record_json text not null,
  created_at_utc text not null,
  failed_at_utc text not null,
  http_status integer,
  error text not null
);

-- A complete hub catalog fetch that finds a model's price unchanged confirms
-- the latest observation instead of storing another copy. change_seq orders
-- confirmation updates for incremental download.
create table price_observation_confirmations (
  fingerprint text primary key references price_observations(fingerprint),
  confirmed_at_utc text not null,
  change_seq integer not null unique
);
alter table price_hub_sync_state add column confirmation_seq integer not null default 0;
