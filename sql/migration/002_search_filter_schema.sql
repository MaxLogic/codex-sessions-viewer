alter table sessions
  add column has_code_blocks integer not null default 0
  check (has_code_blocks in (0, 1));

alter table sessions
  add column has_tool_calls integer not null default 0
  check (has_tool_calls in (0, 1));

alter table sessions
  add column has_errors integer not null default 0
  check (has_errors in (0, 1));

drop table if exists session_search;

create virtual table session_search using fts5(
  title,
  summary,
  user_messages,
  assistant_messages,
  tool_names,
  display_path,
  normalized_path_keys,
  project_name,
  tags,
  tool_output
);

update sessions
set has_code_blocks = case
  when exists (
    select 1
    from messages m
    where m.session_id = sessions.id
      and (
        coalesce(m.content_markdown, '') like '%```%'
        or coalesce(m.content_plain, '') like '%```%'
        or coalesce(m.content_preview, '') like '%```%'
      )
  ) then 1
  else 0
end;

update sessions
set has_tool_calls = case
  when coalesce(tool_call_count, 0) > 0
    or exists (
      select 1
      from messages m
      where m.session_id = sessions.id
        and m.has_tool_calls = 1
    )
    or exists (
      select 1
      from tool_calls tc
      where tc.session_id = sessions.id
    )
  then 1
  else 0
end;

update sessions
set has_errors = case
  when exists (
    select 1
    from messages m
    where m.session_id = sessions.id
      and m.has_error = 1
  )
    or exists (
      select 1
      from tool_calls tc
      where tc.session_id = sessions.id
        and (
          tc.error_message is not null
          or lower(tc.status) in ('error', 'failed')
        )
    )
  then 1
  else 0
end;

insert into session_search (
  rowid,
  title,
  summary,
  user_messages,
  assistant_messages,
  tool_names,
  display_path,
  normalized_path_keys,
  project_name,
  tags,
  tool_output
)
select
  s.rowid,
  coalesce(s.title, ''),
  coalesce(s.summary, ''),
  coalesce((
    select group_concat(
      coalesce(
        nullif(m.content_plain, ''),
        nullif(m.content_preview, ''),
        nullif(m.summary, ''),
        nullif(m.first_line, ''),
        ''
      ),
      char(10)
    )
    from messages m
    where m.session_id = s.id
      and m.author_type = 'user'
  ), ''),
  coalesce((
    select group_concat(
      coalesce(
        nullif(m.content_plain, ''),
        nullif(m.content_preview, ''),
        nullif(m.summary, ''),
        nullif(m.first_line, ''),
        ''
      ),
      char(10)
    )
    from messages m
    where m.session_id = s.id
      and m.author_type = 'assistant'
  ), ''),
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
  ), ''),
  coalesce((
    select group_concat(tc.output_preview, char(10))
    from tool_calls tc
    where tc.session_id = s.id
      and tc.output_preview is not null
  ), '')
from sessions s
left join projects p on p.id = s.project_id;
