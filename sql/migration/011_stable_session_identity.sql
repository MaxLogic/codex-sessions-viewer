create temp table temp_session_dedupe as
select
  id,
  rowid as session_rowid,
  case
    when trim(coalesce(session_id, '')) <> '' then 'session:' || trim(session_id)
    else 'source:' || trim(coalesce(nullif(source_file_path, ''), source_file_unc_path, display_path, platform_path))
  end as stable_id,
  first_value(id) over (
    partition by case
      when trim(coalesce(session_id, '')) <> '' then 'session:' || trim(session_id)
      else 'source:' || trim(coalesce(nullif(source_file_path, ''), source_file_unc_path, display_path, platform_path))
    end
    order by coalesce(file_size, 0) desc,
             coalesce(last_message_at_utc, modified_utc, updated_at_utc, created_at_utc, '') desc,
             coalesce(message_count, 0) desc,
             id desc
  ) as keep_id,
  row_number() over (
    partition by case
      when trim(coalesce(session_id, '')) <> '' then 'session:' || trim(session_id)
      else 'source:' || trim(coalesce(nullif(source_file_path, ''), source_file_unc_path, display_path, platform_path))
    end
    order by coalesce(file_size, 0) desc,
             coalesce(last_message_at_utc, modified_utc, updated_at_utc, created_at_utc, '') desc,
             coalesce(message_count, 0) desc,
             id desc
  ) as rank
from sessions
where trim(coalesce(session_id, '')) <> ''
   or trim(coalesce(source_file_path, source_file_unc_path, display_path, platform_path, '')) <> '';

create temp table temp_session_metadata as
select
  d.keep_id,
  max(s.is_pinned) as is_pinned,
  max(s.is_archived) as is_archived,
  max(s.project_override) as project_override,
  max(s.eval_ready) as eval_ready,
  coalesce(
    max(case when s.project_override = 1 then s.project_id end),
    max(case when d.id = d.keep_id then s.project_id end)
  ) as project_id,
  coalesce(
    max(case when s.project_override = 1 then s.project_name_snapshot end),
    max(case when d.id = d.keep_id then s.project_name_snapshot end)
  ) as project_name_snapshot,
  coalesce(
    max(case when s.is_archived = 1 then s.archived_at_utc end),
    max(case when d.id = d.keep_id then s.archived_at_utc end)
  ) as archived_at_utc,
  coalesce(
    max(case when s.is_archived = 1 then s.archive_reason end),
    max(case when d.id = d.keep_id then s.archive_reason end)
  ) as archive_reason,
  coalesce(
    max(case when s.eval_ready = 1 then s.eval_status end),
    max(case when d.id = d.keep_id then s.eval_status end)
  ) as eval_status,
  coalesce(
    max(case when s.eval_ready = 1 then s.eval_notes end),
    max(case when d.id = d.keep_id then s.eval_notes end)
  ) as eval_notes,
  coalesce(
    max(case when s.eval_ready = 1 then s.eval_expected_output end),
    max(case when d.id = d.keep_id then s.eval_expected_output end)
  ) as eval_expected_output,
  coalesce(
    max(case when s.eval_ready = 1 then s.eval_reviewed_at_utc end),
    max(case when d.id = d.keep_id then s.eval_reviewed_at_utc end)
  ) as eval_reviewed_at_utc,
  coalesce(
    max(case when s.eval_ready = 1 then s.eval_updated_at_utc end),
    max(case when d.id = d.keep_id then s.eval_updated_at_utc end)
  ) as eval_updated_at_utc
from temp_session_dedupe d
join sessions s on s.id = d.id
group by d.keep_id;

update sessions
set
  is_pinned = (select is_pinned from temp_session_metadata m where m.keep_id = sessions.id),
  is_archived = (select is_archived from temp_session_metadata m where m.keep_id = sessions.id),
  project_override = (select project_override from temp_session_metadata m where m.keep_id = sessions.id),
  project_id = (select project_id from temp_session_metadata m where m.keep_id = sessions.id),
  project_name_snapshot = (select project_name_snapshot from temp_session_metadata m where m.keep_id = sessions.id),
  archived_at_utc = (select archived_at_utc from temp_session_metadata m where m.keep_id = sessions.id),
  archive_reason = (select archive_reason from temp_session_metadata m where m.keep_id = sessions.id),
  eval_ready = (select eval_ready from temp_session_metadata m where m.keep_id = sessions.id),
  eval_status = (select eval_status from temp_session_metadata m where m.keep_id = sessions.id),
  eval_notes = (select eval_notes from temp_session_metadata m where m.keep_id = sessions.id),
  eval_expected_output = (select eval_expected_output from temp_session_metadata m where m.keep_id = sessions.id),
  eval_reviewed_at_utc = (select eval_reviewed_at_utc from temp_session_metadata m where m.keep_id = sessions.id),
  eval_updated_at_utc = (select eval_updated_at_utc from temp_session_metadata m where m.keep_id = sessions.id)
where id in (select keep_id from temp_session_dedupe);

insert or ignore into session_tags (session_id, tag_id, created_at_utc)
select d.keep_id, st.tag_id, st.created_at_utc
from temp_session_dedupe d
join session_tags st on st.session_id = d.id
where d.id <> d.keep_id;

insert or ignore into session_path_keys (session_id, path_key)
select d.keep_id, spk.path_key
from temp_session_dedupe d
join session_path_keys spk on spk.session_id = d.id
where d.id <> d.keep_id;

delete from message_search
where session_id in (
  select id from temp_session_dedupe where id <> keep_id
);

delete from session_search
where rowid in (
  select session_rowid from temp_session_dedupe where id <> keep_id
);

delete from messages
where session_id in (
  select id from temp_session_dedupe where id <> keep_id
);

delete from tool_calls
where session_id in (
  select id from temp_session_dedupe where id <> keep_id
);

delete from session_tags
where session_id in (
  select id from temp_session_dedupe where id <> keep_id
);

delete from session_path_keys
where session_id in (
  select id from temp_session_dedupe where id <> keep_id
);

delete from sessions
where id in (
  select id from temp_session_dedupe where id <> keep_id
);

update messages
set session_id = (
  select stable_id from temp_session_dedupe d where d.keep_id = messages.session_id limit 1
)
where session_id in (select keep_id from temp_session_dedupe)
  and session_id <> (
    select stable_id from temp_session_dedupe d where d.keep_id = messages.session_id limit 1
  );

update tool_calls
set session_id = (
  select stable_id from temp_session_dedupe d where d.keep_id = tool_calls.session_id limit 1
)
where session_id in (select keep_id from temp_session_dedupe)
  and session_id <> (
    select stable_id from temp_session_dedupe d where d.keep_id = tool_calls.session_id limit 1
  );

update message_search
set session_id = (
  select stable_id from temp_session_dedupe d where d.keep_id = message_search.session_id limit 1
)
where session_id in (select keep_id from temp_session_dedupe)
  and session_id <> (
    select stable_id from temp_session_dedupe d where d.keep_id = message_search.session_id limit 1
  );

update session_tags
set session_id = (
  select stable_id from temp_session_dedupe d where d.keep_id = session_tags.session_id limit 1
)
where session_id in (select keep_id from temp_session_dedupe)
  and session_id <> (
    select stable_id from temp_session_dedupe d where d.keep_id = session_tags.session_id limit 1
  );

update session_path_keys
set session_id = (
  select stable_id from temp_session_dedupe d where d.keep_id = session_path_keys.session_id limit 1
)
where session_id in (select keep_id from temp_session_dedupe)
  and session_id <> (
    select stable_id from temp_session_dedupe d where d.keep_id = session_path_keys.session_id limit 1
  );

update sessions
set id = (
  select stable_id from temp_session_dedupe d where d.keep_id = sessions.id limit 1
)
where id in (select keep_id from temp_session_dedupe)
  and id <> (
    select stable_id from temp_session_dedupe d where d.keep_id = sessions.id limit 1
  );

create unique index if not exists idx_sessions_session_id_unique
on sessions(session_id)
where session_id is not null and trim(session_id) <> '';

drop table temp_session_metadata;
drop table temp_session_dedupe;
