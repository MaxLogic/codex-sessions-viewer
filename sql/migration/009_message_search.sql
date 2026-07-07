create virtual table if not exists message_search using fts5(
  session_id unindexed,
  message_index unindexed,
  author_type unindexed,
  created_at_utc unindexed,
  content
);

delete from message_search;

insert into message_search (
  session_id,
  message_index,
  author_type,
  created_at_utc,
  content
)
select
  m.session_id,
  m.message_index,
  m.author_type,
  m.created_at_utc,
  coalesce(
    nullif(m.content_plain, ''),
    nullif(m.content_preview, ''),
    nullif(m.first_line, ''),
    ''
  )
from messages m
where trim(coalesce(
  nullif(m.content_plain, ''),
  nullif(m.content_preview, ''),
  nullif(m.first_line, ''),
  ''
)) <> '';

create trigger if not exists trg_sessions_delete_message_search
after delete on sessions
begin
  delete from message_search where session_id = old.id;
end;
