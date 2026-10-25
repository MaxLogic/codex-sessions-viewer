//! `hub backfill`: queue stored sessions whose source files are gone.
//!
//! A hub receives a session only as a snapshot parsed from its source file.
//! A session collected before the machine was paired, whose file has since
//! been deleted, exists only in the local database. Backfill rebuilds its
//! snapshot from the stored rows and queues it with an explicit missing
//! status, so the hub keeps the history and knows that the file is gone.
//!
//! The rebuilt snapshot is the stored state, not the source: per-message
//! reasoning and cache-write tokens, and content the parser never stored, are
//! absent. A hub that already holds a parsed copy of the session keeps that
//! copy, because a missing source ranks below an available one.

use std::path::Path;

use rusqlite::{Connection, OptionalExtension, params};

use crate::contract::{
    MessageRecord, ProjectHint, Record, SessionRecord, SessionSnapshot, Source, SourceStatus,
    ToolCallRecord, UsageEventRecord, UsageRecord,
};
use crate::dart::DartDateTime;
use crate::store::schema::{StoreError, StoreResult, begin_write, finish};
use crate::store::{OwnerMode, Store};

/// Sessions queued per write transaction, so the viewer's writers wait for
/// at most one chunk.
const CHUNK: usize = 32;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BackfillReport {
    pub candidates: usize,
    pub queued: usize,
    pub pending: i64,
}

/// Queues every available-parse session whose source is recorded missing.
/// Refuses when hub delivery is not enabled: nothing would be queued.
pub fn backfill(db_path: &Path, mode: OwnerMode) -> Result<BackfillReport, String> {
    let store = Store::open(db_path, mode).map_err(|error| error.to_string())?;
    run(&store.conn).map_err(|error| error.to_string())
}

fn run(conn: &Connection) -> StoreResult<BackfillReport> {
    if !crate::hub_client::queue_enabled(conn)? {
        return Err(StoreError::Refused(
            "hub delivery is not enabled; run hub enable first".to_owned(),
        ));
    }
    let ids: Vec<String> = conn
        .prepare(
            "select id from sessions
             where scan_status = 'missing' and parse_status = 'available'
               and message_count > 0
             order by coalesce(last_message_at_utc, started_at_utc), id",
        )?
        .query_map([], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    let mut report = BackfillReport {
        candidates: ids.len(),
        ..BackfillReport::default()
    };
    for chunk in ids.chunks(CHUNK) {
        let _lease = crate::store::write_lease::WriteLease::acquire(conn)?;
        let _phase = crate::store::write_budget::write_phase("hub");
        begin_write(conn)?;
        let result = (|| -> StoreResult<usize> {
            let now = DartDateTime::now().to_iso8601();
            let mut queued = 0;
            for id in chunk {
                // Revalidated under the lock: a scan may have found the file.
                let Some((snapshot, status)) = rebuild(conn, id)? else {
                    continue;
                };
                crate::hub_client::enqueue(
                    conn,
                    Record::SessionSnapshot(Box::new(snapshot)),
                    &now,
                )?;
                crate::hub_client::enqueue(conn, Record::SourceStatus(status), &now)?;
                queued += 1;
            }
            Ok(queued)
        })();
        report.queued += finish(conn, result)?;
    }
    report.pending = crate::hub_client::pending(conn)?;
    Ok(report)
}

struct Row {
    session_id: Option<String>,
    harness: String,
    source_type: String,
    source_file_path: String,
    source_file_unc_path: Option<String>,
    display_path: String,
    platform_path: String,
    file_size: Option<i64>,
    modified_utc: Option<String>,
    source_state: String,
}

/// The stored session as a snapshot and its missing status, or `None` when
/// the session no longer qualifies.
pub(crate) fn rebuild(
    conn: &Connection,
    id: &str,
) -> StoreResult<Option<(SessionSnapshot, SourceStatus)>> {
    let found = conn
        .prepare_cached(
            "select session_id, harness, source_type, source_file_path, source_file_unc_path,
                    display_path, platform_path, file_size, modified_utc,
                    coalesce(source_state, 'missing'),
                    thread_name, thread_source, parent_thread_id, forked_from_id,
                    history_base_thread_id, history_base_end_ordinal,
                    history_base_end_byte_offset, subagent_history_start_ordinal,
                    coalesce(usage_projection_status, 'complete'), agent_nickname, agent_role,
                    subagent_depth, working_directory_display, working_directory_platform,
                    working_directory_unc, title, summary, started_at_utc, last_message_at_utc,
                    models_used, input_tokens, output_tokens, cached_input_tokens, total_tokens,
                    coalesce(parser_version, 0), detected_project_id
             from sessions
             where id = ? and scan_status = 'missing' and parse_status = 'available'",
        )?
        .query_row([id], |row| {
            let source = Row {
                session_id: row.get(0)?,
                harness: row
                    .get::<_, Option<String>>(1)?
                    .unwrap_or_else(|| "codex".to_owned()),
                source_type: row
                    .get::<_, Option<String>>(2)?
                    .unwrap_or_else(|| "windows".to_owned()),
                source_file_path: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
                source_file_unc_path: row.get(4)?,
                display_path: row.get::<_, Option<String>>(5)?.unwrap_or_default(),
                platform_path: row.get::<_, Option<String>>(6)?.unwrap_or_default(),
                file_size: row.get(7)?,
                modified_utc: row.get(8)?,
                source_state: row.get(9)?,
            };
            let session = SessionRecord {
                session_id: source.session_id.clone(),
                thread_name: row.get(10)?,
                thread_source: row.get(11)?,
                parent_thread_id: row.get(12)?,
                forked_from_id: row.get(13)?,
                history_base_thread_id: row.get(14)?,
                history_base_end_ordinal_exclusive: row.get(15)?,
                history_base_end_byte_offset: row.get(16)?,
                subagent_history_start_ordinal: row.get(17)?,
                usage_projection_status: row.get(18)?,
                agent_nickname: row.get(19)?,
                agent_role: row.get(20)?,
                subagent_depth: row.get(21)?,
                working_directory_display: row.get(22)?,
                working_directory_platform: row.get(23)?,
                working_directory_unc: row.get(24)?,
                title: row.get(25)?,
                summary: row.get(26)?,
                started_at_utc: row.get(27)?,
                last_message_at_utc: row.get(28)?,
                models: decode_membership(row.get::<_, Option<String>>(29)?.as_deref()),
                usage: UsageRecord {
                    input_tokens: row.get(30)?,
                    output_tokens: row.get(31)?,
                    cached_input_tokens: row.get(32)?,
                    total_tokens: row.get(33)?,
                    ..UsageRecord::default()
                },
                parser_version: row.get(34)?,
            };
            Ok((source, session, row.get::<_, Option<i64>>(35)?))
        })
        .optional()?;
    let Some((source, session, project_id)) = found else {
        return Ok(None);
    };
    if source.source_file_path.is_empty() {
        return Ok(None);
    }
    let messages = messages(conn, id)?;
    if messages.is_empty() {
        return Ok(None);
    }
    let project_hints = match (&session.working_directory_display, project_id) {
        (Some(directory), Some(project)) => conn
            .prepare_cached("select name from projects where id = ?")?
            .query_row([project], |row| row.get::<_, String>(0))
            .optional()?
            .map(|name| ProjectHint {
                working_directory: directory.clone(),
                project_name: name,
            })
            .into_iter()
            .collect(),
        _ => Vec::new(),
    };
    let extra = conn
        .prepare_cached("select extra_json from session_source_extras where session_row_id = ?")?
        .query_row([id], |row| row.get::<_, String>(0))
        .optional()?
        .and_then(|text| serde_json::from_str(&text).ok());
    let normalized_path_keys = conn
        .prepare_cached(
            "select path_key from session_path_keys where session_id = ? order by path_key",
        )?
        .query_map([id], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    let state = match source.source_state.as_str() {
        state @ ("active" | "codex_archived" | "missing") => state.to_owned(),
        _ => "missing".to_owned(),
    };
    let status = SourceStatus {
        harness: source.harness.clone(),
        path: source.source_file_path.clone(),
        environment: Some(source.source_type.clone()),
        status: "missing".to_owned(),
        state: state.clone(),
        message: Some(
            "Source file was removed; history rebuilt from the collecting database.".to_owned(),
        ),
    };
    let snapshot = SessionSnapshot {
        harness: source.harness,
        machine_id: None,
        source: Source {
            path: source.source_file_path.clone(),
            environment: source.source_type,
            state,
            status: "available".to_owned(),
            size: source.file_size.unwrap_or(0).max(0) as u64,
            modified_utc: source
                .modified_utc
                .filter(|value| DartDateTime::try_parse(value).is_some())
                .or_else(|| session.last_message_at_utc.clone())
                .or_else(|| session.started_at_utc.clone())
                .unwrap_or_else(|| "1970-01-01T00:00:00.000Z".to_owned()),
            display_path: source.display_path,
            mapped_source_file_path: source.source_file_path,
            unc_path: source.source_file_unc_path,
            platform_path: source.platform_path,
            normalized_path_keys,
        },
        tool_calls: tool_calls(conn, id)?,
        usage_events: usage_events(conn, id)?,
        session,
        messages,
        project_hints,
        extra,
    };
    Ok(Some((snapshot, status)))
}

fn decode_membership(value: Option<&str>) -> Vec<String> {
    value
        .unwrap_or("")
        .split('|')
        .filter(|item| !item.is_empty())
        .map(str::to_owned)
        .collect()
}

fn messages(conn: &Connection, id: &str) -> StoreResult<Vec<MessageRecord>> {
    let mut statement = conn.prepare_cached(
        "select message_index, author_type, raw_type, created_at_utc, first_line, content_plain,
                content_preview, content_truncated, token_input, token_output, token_cached,
                token_total, model, has_tool_calls, has_error
         from messages where session_id = ? order by message_index",
    )?;
    let rows = statement.query_map([id], |row| {
        Ok(MessageRecord {
            index: row.get(0)?,
            author_type: row.get(1)?,
            raw_type: row.get(2)?,
            created_at_utc: row.get(3)?,
            first_line: row.get::<_, Option<String>>(4)?.unwrap_or_default(),
            content_plain: row.get::<_, Option<String>>(5)?.unwrap_or_default(),
            content_preview: row.get::<_, Option<String>>(6)?.unwrap_or_default(),
            content_truncated: row.get::<_, Option<bool>>(7)?.unwrap_or(false),
            usage: UsageRecord {
                input_tokens: row.get(8)?,
                output_tokens: row.get(9)?,
                cached_input_tokens: row.get(10)?,
                total_tokens: row.get(11)?,
                ..UsageRecord::default()
            },
            model: row.get(12)?,
            has_tool_calls: row.get::<_, Option<bool>>(13)?.unwrap_or(false),
            has_error: row.get::<_, Option<bool>>(14)?.unwrap_or(false),
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// `message_index` is the linked message's index plus one: the writer links
/// a call to the last message before that index, which is the same message.
fn tool_calls(conn: &Connection, id: &str) -> StoreResult<Vec<ToolCallRecord>> {
    let mut statement = conn.prepare_cached(
        "select t.tool_index, m.message_index, t.tool_name, t.status, t.started_at_utc,
                t.finished_at_utc, t.input_preview, t.output_preview, t.output_truncated,
                t.error_message
         from tool_calls t left join messages m on m.id = t.message_id
         where t.session_id = ? order by t.tool_index, t.id",
    )?;
    let rows = statement.query_map([id], |row| {
        Ok(ToolCallRecord {
            tool_index: row.get(0)?,
            message_index: row.get::<_, Option<i64>>(1)?.map(|index| index + 1),
            tool_name: row.get::<_, Option<String>>(2)?.unwrap_or_default(),
            status: row.get::<_, Option<String>>(3)?.unwrap_or_default(),
            started_at_utc: row.get(4)?,
            finished_at_utc: row.get(5)?,
            input_preview: row.get::<_, Option<String>>(6)?.unwrap_or_default(),
            output_preview: row.get::<_, Option<String>>(7)?.unwrap_or_default(),
            output_truncated: row.get::<_, Option<bool>>(8)?.unwrap_or(false),
            error_message: row.get(9)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

fn usage_events(conn: &Connection, id: &str) -> StoreResult<Vec<UsageEventRecord>> {
    let mut statement = conn.prepare_cached(
        "select e.source_record_ordinal, e.rollout_ordinal, e.turn_ordinal, e.epoch,
                e.occurred_at_utc, e.model, c.display_path_raw, c.unc_path_raw,
                e.input_tokens, e.cached_input_tokens, e.cache_write_input_tokens,
                e.output_tokens, e.reasoning_output_tokens, e.total_tokens,
                i.provider, i.request_input_tokens, i.model_context_window,
                i.billable_units_json, e.derivation, e.branch_scope, e.event_fingerprint
         from usage_events e
         left join usage_path_contexts c on c.id = e.path_context_id
         left join usage_event_inputs i
           on i.session_row_id = e.session_row_id
          and i.source_record_ordinal = e.source_record_ordinal
         where e.session_row_id = ? order by e.source_record_ordinal",
    )?;
    let rows = statement.query_map(params![id], |row| {
        Ok(UsageEventRecord {
            source_record_ordinal: row.get(0)?,
            rollout_ordinal: row.get(1)?,
            turn_ordinal: row.get(2)?,
            counter_epoch: row.get::<_, Option<i64>>(3)?.unwrap_or(0),
            occurred_at_utc: row.get(4)?,
            model: row.get(5)?,
            working_directory: row.get(6)?,
            working_directory_unc: row.get(7)?,
            usage: UsageRecord {
                input_tokens: row.get(8)?,
                cached_input_tokens: row.get(9)?,
                cache_write_input_tokens: row.get(10)?,
                output_tokens: row.get(11)?,
                reasoning_output_tokens: row.get(12)?,
                total_tokens: row.get(13)?,
            },
            provider: row.get(14)?,
            request_input_tokens: row.get(15)?,
            model_context_window: row.get(16)?,
            billable_units: row
                .get::<_, Option<String>>(17)?
                .and_then(|text| serde_json::from_str(&text).ok()),
            derivation: row.get(18)?,
            branch_scope: row.get(19)?,
            event_fingerprint: row.get(20)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}
