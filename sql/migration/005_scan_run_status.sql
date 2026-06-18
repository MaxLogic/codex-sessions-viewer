alter table scan_runs
add column status text not null default 'succeeded'
check (status in ('running', 'succeeded', 'cancelled', 'failed'));
