-- Replacing a session deletes its old messages. SQLite checks this child key
-- for every deleted message, including when all tool calls have a null key.
-- The partial index avoids scanning unrelated tool calls and stores only links.
create index idx_tool_calls_message on tool_calls(message_id)
  where message_id is not null;
