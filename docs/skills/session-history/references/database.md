# Current database contract

Verified against product schema migrations through 017. Inspect actual columns
before writing custom SQL; the helper validates the required columns itself.

| Table | Relevant columns / relationship |
| --- | --- |
| sessions | `id` is the database session key; `session_id` is the original Codex ID. Includes title, project_id, project_name_snapshot, source_type (windows/wsl), working_directory_display/platform, source_file_path, scan_status, parse_status, last_parsed_utc. |
| messages | `session_id` references sessions.id; `message_index` orders the parsed conversation; content_plain contains indexed text; author_type distinguishes user/assistant/tool; created_at_utc may be absent. Integer id is a cache row ID. |
| projects | id and current name; prefer current name over sessions.project_name_snapshot. |
| message_search | External-content FTS5 index, joined through message_search.rowid = messages.id. Coverage may be incomplete during backfill. |
| app_metadata | message_search.backfill.* keys report progress; inspect them without advancing the backfill. |

There are no published agent query views yet. Do not invent `session_history`,
`machine_id`, or `harness` columns. Do not equate source_type with harness.
Usage/cost reporting is outside this initial helper: branch-aware usage and
historical pricing require the application's dedicated projections.

For an explicitly requested custom query, open the named database with a native
Windows connection using `mode=ro`; set `PRAGMA query_only=ON` and a bounded busy
timeout. Use parameters and LIMIT. Never use `immutable=1` on an active WAL
database, run repair/FTS rebuild/PRAGMA optimize, change journal mode, or migrate
as part of retrieval. An error from a mismatched schema is not permission to fix it.

Example parameterized SQL (execute through Windows Python sqlite3):

```sql
SELECT s.id AS session_id, m.message_index, m.author_type,
       m.created_at_utc, substr(m.content_plain, 1, 1200) AS excerpt
FROM message_search
JOIN messages m ON m.id = message_search.rowid
JOIN sessions s ON s.id = m.session_id
WHERE message_search MATCH ? AND s.id = ?
ORDER BY m.message_index
LIMIT ?;
```

The helper reports `source_content_truncated` independently from its own excerpt
limit. Paging text cannot recover material the parser did not retain. Do not read
raw session sources automatically to conceal that limitation.
