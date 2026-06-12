# Codex Session Format Analysis

Generated from a content-safe local scan of the local Codex sessions directory
on 2026-06-12. To reproduce, pass your own local root:

```powershell
cd app
dart run bin/analyze_session_format.dart --root <codex-sessions-root> --no-content
```

The analyzer reports only schema keys and counts. It does not print prompt,
message, tool output, path, token value, or raw session content.

## Local Scan Summary

- Files scanned: 4,732
- Malformed files: 0
- Unreadable files: 0
- Malformed JSONL lines: 0
- Total records counted: 1,770,668

All observed local session files are JSONL records with the same top-level keys:

- `timestamp`
- `type`
- `payload`

## Top-Level Record Types

- `event_msg`: 1,180,902
- `response_item`: 560,304
- `turn_context`: 19,804
- `session_meta`: 5,187
- `compacted`: 4,471

## Response Item Types

- `function_call`: 159,871
- `function_call_output`: 159,830
- `message`: 95,933
- `reasoning`: 96,095
- `custom_tool_call`: 20,591
- `custom_tool_call_output`: 20,591
- `web_search_call`: 6,915
- `tool_search_call`: 141
- `tool_search_output`: 141
- `ghost_snapshot`: 196

Parser implication: tool parsing must not assume only `function_call` and
`function_call_output`. Custom tools and tool-search records are real local
formats. Unknown response item types should be preserved as warnings/previews,
not fatal parse errors.

## Event Message Types

- `token_count`: 619,043
- `agent_message`: 312,123
- `thread_goal_updated`: 89,767
- `patch_apply_end`: 91,677
- `exec_command_end`: 21,615
- `task_started`: 11,360
- `user_message`: 10,694
- `task_complete`: 10,694
- `agent_reasoning`: 6,442
- `context_compacted`: 4,471
- Collaboration events also appear: `collab_agent_spawn_end`,
  `collab_agent_interaction_end`, `collab_close_end`, `collab_resume_end`,
  and `collab_waiting_end`.
- Error/abort events also appear: `error`, `turn_aborted`.

Parser implication: user-visible messages can come from both
`response_item`/`message` and `event_msg` records. `event_msg` should feed
diagnostics, parse warnings, scan logs, and possibly timeline metadata.

## Important Payload Keys

High-volume payload keys include:

- message/content: `message`, `content`, `role`, `phase`, `summary`
- tool calls: `call_id`, `name`, `arguments`, `output`, `status`,
  `stdout`, `stderr`, `exit_code`, `duration`, `duration_ms`
- session context: `cwd`, `model`, `approval_policy`, `sandbox_policy`,
  `permission_profile`, `workspace_roots`, `current_date`, `timezone`
- usage/rate limiting: `info`, `rate_limits`, `model_context_window`
- multi-agent/goals: `goal`, `threadId`, `turnId`, `turn_id`,
  `agent_statuses`, `sender_thread_id`, `receiver_thread_id`

Parser implication: T-005 should focus on stable session/message/tool/usage
metadata first and emit structured warnings for non-core payload shapes.

## Token Usage Keys

Observed token usage keys:

- `input_tokens`
- `cached_input_tokens`
- `output_tokens`
- `reasoning_output_tokens`
- `total_tokens`

Parser implication: usage should support nullable/partial fields and preserve
`reasoning_output_tokens` separately or explicitly account for it in future
usage aggregation. Do not assume total tokens is absent or derivable only from
input/output/cache fields.

Observed usage shapes included:

- token-count event totals: `event_msg.token_count.info.total_token_usage`
- token-count event last usage: `event_msg.token_count.info.last_token_usage`

Fixture coverage also keeps legacy JSON-object usage shapes separate from JSONL
response item shapes so parser work does not blur older fixtures with current
Codex JSONL records.

## Recommended Parser Direction

- Treat JSONL as the primary Codex session format.
- Parse line by line and tolerate unknown record or payload types.
- Capture structured parse warnings for unknown formats so the app can surface
  "new format observed" diagnostics.
- Match tool call records by `call_id` where available.
- Support at least `function_call`, `function_call_output`,
  `custom_tool_call`, `custom_tool_call_output`, `tool_search_call`,
  `tool_search_output`, and `web_search_call` as non-fatal records.
- Keep raw session content out of SQLite. Store only parsed metadata, previews,
  counters, statuses, and structured error/warning details.

## Recommended Scanner Direction

- Use cache invalidation before parsing: size, modified UTC, content hash, and
  parser version should skip unchanged files.
- Parse changed files concurrently with a bounded worker pool or Dart isolates.
- Aggregate results deterministically so UI counts and logs are stable.
