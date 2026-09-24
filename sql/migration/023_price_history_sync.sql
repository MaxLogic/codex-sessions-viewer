-- T-128: immutable public price observations. Session data never enters this log.
create table price_observations (
  fingerprint text primary key,
  origin text not null,
  authority text not null check (authority in ('hub', 'local')),
  observed_at_utc text not null,
  provider text not null,
  model_id text not null,
  payload_json text not null check (json_valid(payload_json))
);
create index idx_price_observations_model on price_observations(provider, model_id, observed_at_utc);
create table price_history_revisions (
  revision text primary key,
  observations_json text not null check (json_valid(observations_json)),
  created_at_utc text not null
);
create table price_history_state (
  id integer primary key check (id = 1),
  revision text references price_history_revisions(revision)
);
insert into price_history_state(id) values (1);
create table price_hub_sync_state (
  hub_url text primary key,
  through_rowid integer not null,
  revision text not null
);
create table price_hub_membership (
  hub_url text not null,
  fingerprint text not null references price_observations(fingerprint),
  primary key (hub_url, fingerprint)
);
create table price_history_model_sources (
  revision text not null references price_history_revisions(revision),
  model_id text not null,
  source text not null,
  primary key (revision, model_id)
);
alter table price_catalog_snapshots add column canonical_revision text references price_history_revisions(revision);
create trigger trg_price_observations_immutable_update before update on price_observations
begin select raise(abort, 'price observations are immutable'); end;
create trigger trg_price_observations_immutable_delete before delete on price_observations
begin select raise(abort, 'price observations are immutable'); end;
create trigger trg_price_history_revisions_immutable_update before update on price_history_revisions
begin select raise(abort, 'price history revisions are immutable'); end;
create trigger trg_price_history_revisions_immutable_delete before delete on price_history_revisions
begin select raise(abort, 'price history revisions are immutable'); end;
