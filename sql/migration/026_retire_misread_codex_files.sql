-- The old Dart scanner also stored other files under a Codex home, such as
-- plugin manifests, package.json files and `.tmp` leftovers, as empty Codex
-- sessions. Codex names every rollout `rollout-*`; the collector never
-- revisits these rows, so they stayed forever. Remove them with everything
-- that refers to them. Only empty `.json` and `.tmp` rows are touched; a
-- `.jsonl` file or a row that holds messages is kept even when its name is
-- unusual.
create temp table retired_codex_rows as
  select rowid as row_id, id from sessions
  where harness = 'codex'
    and coalesce(message_count, 0) = 0
    and not exists (select 1 from messages m where m.session_id = sessions.id)
    and (lower(source_file_path) like '%.json' or lower(source_file_path) like '%.tmp')
    and lower(replace(
      replace(source_file_path, '/', '\'),
      rtrim(replace(source_file_path, '/', '\'), replace(replace(source_file_path, '/', '\'), '\', '')),
      ''
    )) not like 'rollout-%';

delete from usage_event_inputs where session_row_id in (select id from retired_codex_rows);
delete from usage_events where session_row_id in (select id from retired_codex_rows);
delete from tool_calls where session_id in (select id from retired_codex_rows);
delete from session_tags where session_id in (select id from retired_codex_rows);
delete from session_path_keys where session_id in (select id from retired_codex_rows);
delete from session_search where rowid in (select row_id from retired_codex_rows);
delete from sessions where id in (select id from retired_codex_rows);

drop table retired_codex_rows;
