alter table messages add column token_cache_write integer;
alter table messages add column token_reasoning integer;
alter table sessions add column cache_write_input_tokens integer;
alter table sessions add column reasoning_output_tokens integer;
alter table sessions add column project_hints_json text;
