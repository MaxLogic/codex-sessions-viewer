create virtual table if not exists message_search using fts5(
  session_id unindexed,
  message_index unindexed,
  author_type unindexed,
  created_at_utc unindexed,
  content
);

create trigger if not exists trg_sessions_delete_message_search
after delete on sessions
begin
  delete from message_search where session_id = old.id;
end;
