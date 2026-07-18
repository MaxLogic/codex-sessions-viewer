drop trigger if exists trg_sessions_delete_message_search;
drop table if exists message_search;

create virtual table message_search using fts5(
  content_plain,
  content='messages',
  content_rowid='id'
);

insert into app_metadata (key, value, updated_at_utc)
values (
  'message_search.backfill.last_message_rowid',
  '0',
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
)
on conflict(key) do update set
  value = excluded.value,
  updated_at_utc = excluded.updated_at_utc;

insert into app_metadata (key, value, updated_at_utc)
values (
  'message_search.backfill.target_message_rowid',
  coalesce((select cast(max(id) as text) from messages), '0'),
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
)
on conflict(key) do update set
  value = excluded.value,
  updated_at_utc = excluded.updated_at_utc;

insert into app_metadata (key, value, updated_at_utc)
values (
  'message_search.backfill.target_message_count',
  '-1',
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
)
on conflict(key) do update set
  value = excluded.value,
  updated_at_utc = excluded.updated_at_utc;

insert into app_metadata (key, value, updated_at_utc)
values (
  'message_search.backfill.indexed_message_count',
  '0',
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
)
on conflict(key) do update set
  value = excluded.value,
  updated_at_utc = excluded.updated_at_utc;

delete from app_metadata
where key in (
  'message_search.backfill.updated_at_utc',
  'message_search.backfill.completed_at_utc'
);

create trigger trg_messages_insert_message_search
after insert on messages
when new.id > cast(coalesce((
    select value
    from app_metadata
    where key = 'message_search.backfill.target_message_rowid'
  ), '0') as integer)
begin
  insert into message_search (rowid, content_plain)
  values (new.id, coalesce(new.content_plain, ''));
end;

create trigger trg_messages_delete_message_search
after delete on messages
when (
    old.id > cast(coalesce((
      select value
      from app_metadata
      where key = 'message_search.backfill.target_message_rowid'
    ), '0') as integer)
    or old.id <= cast(coalesce((
      select value
      from app_metadata
      where key = 'message_search.backfill.last_message_rowid'
    ), '0') as integer)
  )
begin
  insert into message_search (message_search, rowid, content_plain)
  values ('delete', old.id, coalesce(old.content_plain, ''));
end;

create trigger trg_messages_update_message_search_delete
after update of content_plain on messages
when (
    old.id > cast(coalesce((
      select value
      from app_metadata
      where key = 'message_search.backfill.target_message_rowid'
    ), '0') as integer)
    or old.id <= cast(coalesce((
      select value
      from app_metadata
      where key = 'message_search.backfill.last_message_rowid'
    ), '0') as integer)
  )
begin
  insert into message_search (message_search, rowid, content_plain)
  values ('delete', old.id, coalesce(old.content_plain, ''));
end;

create trigger trg_messages_update_message_search_insert
after update of content_plain on messages
when (
    new.id > cast(coalesce((
      select value
      from app_metadata
      where key = 'message_search.backfill.target_message_rowid'
    ), '0') as integer)
    or new.id <= cast(coalesce((
      select value
      from app_metadata
      where key = 'message_search.backfill.last_message_rowid'
    ), '0') as integer)
  )
begin
  insert into message_search (rowid, content_plain)
  values (new.id, coalesce(new.content_plain, ''));
end;

drop table if exists session_search;

create virtual table session_search using fts5(
  title,
  summary,
  tool_names,
  display_path,
  normalized_path_keys,
  project_name,
  tags
);

insert into session_search (
  rowid,
  title,
  summary,
  tool_names,
  display_path,
  normalized_path_keys,
  project_name,
  tags
)
select
  s.rowid,
  coalesce(s.title, ''),
  coalesce(s.summary, ''),
  coalesce((
    select group_concat(tc.tool_name, ' ')
    from tool_calls tc
    where tc.session_id = s.id
  ), ''),
  coalesce(s.display_path, ''),
  coalesce((
    select group_concat(pk.path_key, ' ')
    from session_path_keys pk
    where pk.session_id = s.id
  ), ''),
  coalesce(s.project_name_snapshot, p.name, ''),
  coalesce((
    select group_concat(t.name, ' ')
    from session_tags st
    join tags t on t.id = st.tag_id
    where st.session_id = s.id
  ), '')
from sessions s
left join projects p on p.id = s.project_id;

drop table if exists tool_output_search;

create virtual table tool_output_search using fts5(
  output_preview,
  content='tool_calls',
  content_rowid='id'
);

insert into app_metadata (key, value, updated_at_utc)
values (
  'tool_output_search.enabled',
  '0',
  strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
)
on conflict(key) do nothing;

create trigger trg_tool_calls_insert_output_search
after insert on tool_calls
when (
  select value
  from app_metadata
  where key = 'tool_output_search.enabled'
) = '1'
begin
  insert into tool_output_search (rowid, output_preview)
  values (new.id, coalesce(new.output_preview, ''));
end;

create trigger trg_tool_calls_delete_output_search
after delete on tool_calls
when (
  select value
  from app_metadata
  where key = 'tool_output_search.enabled'
) = '1'
begin
  insert into tool_output_search (
    tool_output_search,
    rowid,
    output_preview
  ) values ('delete', old.id, coalesce(old.output_preview, ''));
end;

create trigger trg_tool_calls_update_output_search_delete
after update of output_preview on tool_calls
when (
  select value
  from app_metadata
  where key = 'tool_output_search.enabled'
) = '1'
begin
  insert into tool_output_search (
    tool_output_search,
    rowid,
    output_preview
  ) values ('delete', old.id, coalesce(old.output_preview, ''));
end;

create trigger trg_tool_calls_update_output_search_insert
after update of output_preview on tool_calls
when (
  select value
  from app_metadata
  where key = 'tool_output_search.enabled'
) = '1'
begin
  insert into tool_output_search (rowid, output_preview)
  values (new.id, coalesce(new.output_preview, ''));
end;
