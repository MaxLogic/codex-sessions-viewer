-- A WSL session's automatic project starts as its folder name; the collector
-- refines it to the git root name through wsl.exe. `project_refined = 1` marks
-- a name a resolver really found, so a single-file reingest can keep it without
-- waiting for a cold WSL start. Existing rows start unmarked and are resolved
-- again on their next reingest.
alter table sessions
  add column project_refined integer not null default 0
  check (project_refined in (0, 1));
