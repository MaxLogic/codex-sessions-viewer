alter table sessions
  add column user_message_tokens integer not null default 0;

alter table sessions
  add column assistant_response_tokens integer not null default 0;

alter table sessions
  add column tool_call_tokens integer not null default 0;

update sessions
set user_message_tokens = coalesce((
  select sum(coalesce(m.token_total, 0))
  from messages m
  where m.session_id = sessions.id
    and m.author_type = 'user'
), 0);

update sessions
set assistant_response_tokens = coalesce((
  select sum(coalesce(m.token_total, 0))
  from messages m
  where m.session_id = sessions.id
    and m.author_type = 'assistant'
), 0);

update sessions
set tool_call_tokens = coalesce((
  select sum(coalesce(m.token_total, 0))
  from messages m
  where m.session_id = sessions.id
    and m.author_type = 'tool'
), 0);

update sessions
set
  user_message_tokens = coalesce(input_tokens, 0),
  assistant_response_tokens = coalesce(output_tokens, 0)
where user_message_tokens + assistant_response_tokens + tool_call_tokens = 0;
