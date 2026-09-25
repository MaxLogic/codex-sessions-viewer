-- Migration 012 kept the full-text index in step with in-place text edits
-- through two `after update of` triggers per table: one removing the old
-- entry, one adding the new. SQLite fires triggers in reverse creation
-- order, so the add ran first and the removal then deleted the row's
-- document entry together with every word both texts share. One trigger
-- per column now removes the old entry and then adds the new one.

drop trigger if exists trg_messages_update_message_search_delete;
drop trigger if exists trg_messages_update_message_search_insert;

create trigger trg_messages_update_message_search
after update of content_plain on messages
begin
  insert into message_search (message_search, rowid, content_plain)
  select 'delete', old.id, coalesce(old.content_plain, '')
  where old.id > cast(coalesce((
      select value
      from app_metadata
      where key = 'message_search.backfill.target_message_rowid'
    ), '0') as integer)
    or old.id <= cast(coalesce((
      select value
      from app_metadata
      where key = 'message_search.backfill.last_message_rowid'
    ), '0') as integer);
  insert into message_search (rowid, content_plain)
  select new.id, coalesce(new.content_plain, '')
  where new.id > cast(coalesce((
      select value
      from app_metadata
      where key = 'message_search.backfill.target_message_rowid'
    ), '0') as integer)
    or new.id <= cast(coalesce((
      select value
      from app_metadata
      where key = 'message_search.backfill.last_message_rowid'
    ), '0') as integer);
end;

drop trigger if exists trg_tool_calls_update_output_search_delete;
drop trigger if exists trg_tool_calls_update_output_search_insert;

create trigger trg_tool_calls_update_output_search
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
  insert into tool_output_search (rowid, output_preview)
  values (new.id, coalesce(new.output_preview, ''));
end;
