# Read-only views for direct SQL

Schema 19 publishes views that form a stable query contract; the tables
behind them may change. Prefer the `session_history.py` commands; use these
views only for an explicitly requested custom query.

| View | One row per | Key columns |
| --- | --- | --- |
| `history_sessions` | collected session | `reference`, `machine_id`, `harness`, `session_key`, `session_id`, `project`, `working_directory`, `environment` (windows/wsl/macos/linux), `title`, `thread_name`, `started_at_utc`, `last_message_at_utc`, `activity_at_utc`, `last_parsed_utc`, `message_count`, token totals, `source_state` |
| `history_messages` | parsed message | `reference` (`<session reference>#<message_index>`), `session_reference`, `message_index`, `author_type`, `created_at_utc` (may be null), `content_plain`, `content_truncated`, `message_rowid` |
| `history_tool_calls` | tool call | `session_reference`, `tool_index`, `tool_name`, `status`, `input_preview`, `output_preview`, `error_message` |

References have the form `history://<machine_id>/<harness>/<session_key>`. The
session key is the agent's own session ID, or a database row ID for a source
without one. `harness` names the agent (codex, claude, ...); `environment` is
where it ran. Do not equate the two.

There is no usage view: token usage and costs come from the viewer's
projections, and `session_history.py session` reports a session's own token
counts. Full-text search uses `message_search` joined through
`message_search.rowid = history_messages.message_rowid`.

Open the database with a native Windows connection using `mode=ro`, set
`PRAGMA query_only=ON` and a bounded busy timeout, and use parameters and
LIMIT. Never use `immutable=1` on an active WAL database, run repair, FTS
rebuild, `PRAGMA optimize`, change the journal mode, or migrate as part of
retrieval. An error from a mismatched schema is not permission to fix it.

Example parameterized SQL (execute through Windows Python `sqlite3`):

```sql
SELECT m.reference, m.author_type, m.created_at_utc,
       substr(m.content_plain, 1, 1200) AS excerpt
FROM message_search
JOIN history_messages m ON m.message_rowid = message_search.rowid
WHERE message_search MATCH ? AND m.session_reference = ?
ORDER BY m.message_index
LIMIT ?;
```

`content_truncated` reports what the parser did not retain; paging text cannot
recover it. Do not read raw session sources automatically to conceal that
limitation.
