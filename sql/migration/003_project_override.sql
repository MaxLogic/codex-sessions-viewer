alter table sessions
  add column project_override integer not null default 0
  check (project_override in (0, 1));

update sessions
set project_override = 1
where project_id is not null
   or project_name_snapshot is not null;
