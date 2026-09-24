//! Applies contract records with the same SQL the Dart scan writer runs
//! (`_persistParsedSessions` and helpers in `runtime_session_controller.dart`,
//! `SessionSearchIndex.upsert`, and `UsageSummaryRepository`). Every write runs
//! in a short `BEGIN IMMEDIATE` transaction; SQLite's lock and busy timeout
//! serialize the collector with the viewer and with other collectors.

use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet};

use rusqlite::{Connection, OptionalExtension, Row, params, params_from_iter};

use crate::codex::parser::{AuthorType, PARSER_VERSION, SourceType, Usage};
use crate::contract::{
    ProjectHint, SessionRef, SessionSnapshot, SourceStatus, ThreadName, UsageRecord, parse_time,
};
use crate::dart::{DartDateTime, compare_utf16, to_lower, trim};
use crate::path_mapping::{canonical_scan_path, normalize_identity_path, normalize_windows_path};

use super::projects::{
    ProjectResolver, refresh_session_project, resolve_usage_path_context, upsert_auto_project,
};
use super::schema::{StoreError, StoreResult, begin_write, finish};

pub const USAGE_COST_PROJECTION_VERSION: i64 = 1;

/// The `sessions.id` for a harness session. Codex keeps the viewer's
/// historical form; other harnesses are namespaced so IDs cannot collide.
pub fn session_row_id(harness: &str, session_id: Option<&str>, source_path: &str) -> String {
    let stable = session_id.map(trim).unwrap_or("");
    let local = if stable.is_empty() {
        format!("source:{source_path}")
    } else {
        format!("session:{stable}")
    };
    if harness == "codex" {
        local
    } else {
        format!("{harness}:{local}")
    }
}

fn source_type(snapshot: &SessionSnapshot) -> SourceType {
    SourceType::from_wire(&snapshot.source.environment).unwrap_or(SourceType::Windows)
}

fn lifecycle_preference(state: &str) -> i32 {
    match state {
        "active" => 2,
        "codex_archived" => 1,
        _ => 0,
    }
}

fn normalize_state(state: Option<&str>) -> &str {
    match state {
        Some("codex_archived") => "codex_archived",
        Some("missing") => "missing",
        _ => "active",
    }
}

/// `_SessionCandidateEvidence`.
struct Evidence {
    source_path: String,
    source_type: SourceType,
    source_state: String,
    is_valid_parse: bool,
    last_evidence_utc: Option<DartDateTime>,
    modified_utc: Option<DartDateTime>,
    file_size: i64,
}

impl Evidence {
    fn from_snapshot(snapshot: &SessionSnapshot) -> Self {
        Self {
            source_path: snapshot.source.path.clone(),
            source_type: source_type(snapshot),
            source_state: snapshot.source.state.clone(),
            is_valid_parse: true,
            last_evidence_utc: parse_time(snapshot.session.last_message_at_utc.as_deref())
                .or_else(|| parse_time(snapshot.session.started_at_utc.as_deref())),
            modified_utc: DartDateTime::try_parse(&snapshot.source.modified_utc),
            file_size: snapshot.source.size as i64,
        }
    }
}

fn compare_nullable(left: Option<DartDateTime>, right: Option<DartDateTime>) -> Ordering {
    match (left, right) {
        (None, None) => Ordering::Equal,
        (None, Some(_)) => Ordering::Less,
        (Some(_), None) => Ordering::Greater,
        (Some(left), Some(right)) => left.cmp(&right),
    }
}

/// `_compareSessionCandidates`.
fn compare_candidates(left: &Evidence, right: &Evidence) -> Ordering {
    left.is_valid_parse
        .cmp(&right.is_valid_parse)
        .then_with(|| compare_nullable(left.last_evidence_utc, right.last_evidence_utc))
        .then_with(|| compare_nullable(left.modified_utc, right.modified_utc))
        .then_with(|| left.file_size.cmp(&right.file_size))
        .then_with(|| {
            lifecycle_preference(&left.source_state).cmp(&lifecycle_preference(&right.source_state))
        })
        .then_with(|| {
            let case_sensitive =
                left.source_type == SourceType::Wsl || right.source_type == SourceType::Wsl;
            let (left_path, right_path) = if case_sensitive {
                (left.source_path.clone(), right.source_path.clone())
            } else {
                (to_lower(&left.source_path), to_lower(&right.source_path))
            };
            compare_utf16(&right_path, &left_path)
        })
}

/// `_canonicalScannedSessions`: the best snapshot per row ID, sorted by ID.
pub fn canonical_snapshots(snapshots: Vec<SessionSnapshot>) -> Vec<(String, SessionSnapshot)> {
    let mut winners: HashMap<String, SessionSnapshot> = HashMap::new();
    for snapshot in snapshots {
        let id = session_row_id(
            &snapshot.harness,
            snapshot.session.session_id.as_deref(),
            &snapshot.source.path,
        );
        match winners.get(&id) {
            Some(existing)
                if compare_candidates(
                    &Evidence::from_snapshot(&snapshot),
                    &Evidence::from_snapshot(existing),
                ) != Ordering::Greater => {}
            _ => {
                winners.insert(id, snapshot);
            }
        }
    }
    let mut result: Vec<(String, SessionSnapshot)> = winners.into_iter().collect();
    result.sort_by(|left, right| compare_utf16(&left.0, &right.0));
    result
}

/// `_persistParsedSessions`: one transaction for a batch of snapshots.
pub fn apply_session_batch(
    conn: &Connection,
    snapshots: Vec<SessionSnapshot>,
) -> StoreResult<usize> {
    let own_machine: Option<String> = conn
        .query_row(
            "select value from app_metadata where key = 'machine_id'",
            [],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(foreign) = snapshots.iter().find_map(|snapshot| {
        snapshot
            .machine_id
            .as_ref()
            .filter(|machine| Some(*machine) != own_machine.as_ref())
    }) {
        // Local session IDs are not namespaced by machine, so accepting the
        // record would relabel another machine's history as this one's.
        return Err(StoreError::Refused(format!(
            "The records come from another machine ({foreign}); this database only stores its own machine's sessions."
        )));
    }
    let canonical = canonical_snapshots(snapshots);
    let count = canonical.len();
    begin_write(conn)?;
    let result = (|| -> StoreResult<()> {
        let now = DartDateTime::now().to_iso8601();
        for (id, snapshot) in &canonical {
            let resolver = ProjectResolver::new(
                snapshot
                    .project_hints
                    .iter()
                    .map(|hint| (hint.working_directory.clone(), hint.project_name.clone())),
            );
            upsert_session(conn, id, snapshot, &now, &resolver)?;
        }
        Ok(())
    })();
    finish(conn, result)?;
    Ok(count)
}

fn iso_or_null(value: Option<&str>) -> Option<String> {
    parse_time(value).map(DartDateTime::to_iso8601)
}

fn clean_display_title(value: Option<&str>) -> String {
    let Some(value) = value else {
        return String::new();
    };
    let trimmed = trim(value);
    if trimmed.is_empty() || to_lower(trimmed).starts_with("# agents.md") {
        return String::new();
    }
    trimmed.to_owned()
}

fn clean_display_summary(value: Option<&str>) -> String {
    let Some(value) = value else {
        return String::new();
    };
    let trimmed = trim(value);
    if trimmed.is_empty() || to_lower(trimmed) == "auto" {
        return String::new();
    }
    trimmed.to_owned()
}

fn candidate_should_replace(
    conn: &Connection,
    id: &str,
    snapshot: &SessionSnapshot,
) -> StoreResult<bool> {
    let existing = conn
        .prepare_cached(
            "select source_type, source_file_path, source_state, parse_status,
                    coalesce(last_message_at_utc, started_at_utc) as last_evidence_utc,
                    modified_utc, file_size
             from sessions where id = ?",
        )?
        .query_row([id], |row| {
            Ok(Evidence {
                source_type: if row.get::<_, Option<String>>(0)?.as_deref() == Some("wsl") {
                    SourceType::Wsl
                } else {
                    SourceType::Windows
                },
                source_path: row.get(1)?,
                source_state: normalize_state(row.get::<_, Option<String>>(2)?.as_deref())
                    .to_owned(),
                is_valid_parse: row.get::<_, Option<String>>(3)?.as_deref() == Some("available"),
                last_evidence_utc: parse_time(row.get::<_, Option<String>>(4)?.as_deref()),
                modified_utc: parse_time(row.get::<_, Option<String>>(5)?.as_deref()),
                file_size: row.get::<_, Option<i64>>(6)?.unwrap_or(0),
            })
        })
        .optional()?;
    Ok(match existing {
        None => true,
        Some(existing) => {
            compare_candidates(&Evidence::from_snapshot(snapshot), &existing) != Ordering::Less
        }
    })
}

fn message_token_buckets(snapshot: &SessionSnapshot) -> (i64, i64, i64) {
    let (mut user, mut assistant, mut tool) = (0i64, 0i64, 0i64);
    for message in &snapshot.messages {
        let total = Usage::from(message.usage).total_tokens().unwrap_or(0);
        match message.author() {
            AuthorType::User => user = user.wrapping_add(total),
            AuthorType::Assistant => assistant = assistant.wrapping_add(total),
            AuthorType::Tool => tool = tool.wrapping_add(total),
            _ => {}
        }
    }
    if user.wrapping_add(assistant).wrapping_add(tool) == 0 {
        let usage = snapshot.session.usage;
        return (
            usage.input_tokens.unwrap_or(0),
            usage.output_tokens.unwrap_or(0),
            0,
        );
    }
    (user, assistant, tool)
}

fn encode_membership(values: &[String]) -> String {
    if values.is_empty() {
        String::new()
    } else {
        format!("|{}|", values.join("|"))
    }
}

/// `_upsertParsedSession`.
fn upsert_session(
    conn: &Connection,
    id: &str,
    snapshot: &SessionSnapshot,
    now: &str,
    resolver: &ProjectResolver,
) -> StoreResult<()> {
    let session = &snapshot.session;
    let identity_merge = capture_identity_merge(conn, id, snapshot)?;
    if !candidate_should_replace(conn, id, snapshot)? {
        if let Some(merge) = identity_merge {
            apply_identity_merge(conn, id, &merge)?;
            let affected =
                reconcile_affected_legacy_usage(conn, id, session.session_id.as_deref())?;
            replace_daily_projections(conn, &affected)?;
        }
        return Ok(());
    }
    let resolved_thread_name = session
        .thread_name
        .as_deref()
        .map(trim)
        .unwrap_or("")
        .to_owned();
    let source_type = source_type(snapshot);
    let has_errors = snapshot.messages.iter().any(|message| message.has_error)
        || snapshot
            .tool_calls
            .iter()
            .any(|tool| tool.error_message.is_some() || tool.status == "error");
    let auto_project = resolver.resolve(session.working_directory_display.as_deref(), source_type);
    let detected_project_id = match &auto_project {
        Some(name) => Some(upsert_auto_project(conn, name, now)?),
        None => None,
    };
    let (user_tokens, assistant_tokens, tool_tokens) = message_token_buckets(snapshot);
    let usage = Usage::from(session.usage);
    upsert_search_document(
        conn,
        &SearchDocument {
            id,
            source_type: source_type.wire_name(),
            source_file_path: &snapshot.source.path,
            display_path: &snapshot.source.display_path,
            platform_path: &snapshot.source.platform_path,
            title: clean_display_title(session.title.as_deref()),
            summary: clean_display_summary(session.summary.as_deref()),
            thread_name: &resolved_thread_name,
            tool_names: snapshot
                .tool_calls
                .iter()
                .map(|tool| tool.tool_name.as_str())
                .collect::<Vec<_>>()
                .join(" "),
            normalized_path_keys: snapshot.source.normalized_path_keys.join(" "),
            started_at_utc: iso_or_null(session.started_at_utc.as_deref()),
            last_message_at_utc: iso_or_null(session.last_message_at_utc.as_deref()),
            models_used: &session.models,
            scan_status: &snapshot.source.status,
            has_code_blocks: snapshot
                .messages
                .iter()
                .any(|message| message.content_plain.contains("```")),
            has_tool_calls: !snapshot.tool_calls.is_empty(),
            has_errors,
            total_tokens: usage.total_tokens(),
            project_name: auto_project.as_deref().unwrap_or(""),
        },
    )?;
    let modified_utc = DartDateTime::try_parse(&snapshot.source.modified_utc)
        .map(DartDateTime::to_iso8601)
        .unwrap_or_else(|| snapshot.source.modified_utc.clone());
    let user_message_count = snapshot
        .messages
        .iter()
        .filter(|message| message.author() == AuthorType::User)
        .count() as i64;
    let assistant_message_count = snapshot
        .messages
        .iter()
        .filter(|message| message.author() == AuthorType::Assistant)
        .count() as i64;
    conn.prepare_cached(
        "update sessions set
           session_id = ?, thread_name = ?, thread_source = ?, parent_thread_id = ?,
           forked_from_id = ?, history_base_thread_id = ?, history_base_end_ordinal = ?,
           history_base_end_byte_offset = ?, subagent_history_start_ordinal = ?,
           usage_projection_status = ?, agent_nickname = ?, agent_role = ?, subagent_depth = ?,
           source_file_unc_path = ?, source_state = ?, working_directory_display = ?,
           working_directory_platform = ?, working_directory_unc = ?, file_size = ?,
           modified_utc = ?, content_hash = ?, parser_version = ?, message_count = ?,
           user_message_count = ?, assistant_message_count = ?, tool_call_count = ?,
           input_tokens = ?, output_tokens = ?, cached_input_tokens = ?,
           user_message_tokens = ?, assistant_response_tokens = ?, tool_call_tokens = ?,
           detected_project_id = ?, last_scanned_utc = ?, last_parsed_utc = ?,
           harness = ?, machine_id = coalesce(?, machine_id)
         where id = ?",
    )?
    .execute(params![
        session.session_id,
        resolved_thread_name,
        session.thread_source,
        session.parent_thread_id,
        session.forked_from_id,
        session.history_base_thread_id,
        session.history_base_end_ordinal_exclusive,
        session.history_base_end_byte_offset,
        session.subagent_history_start_ordinal,
        session.usage_projection_status,
        session.agent_nickname,
        session.agent_role,
        session.subagent_depth,
        snapshot.source.unc_path,
        snapshot.source.state,
        session.working_directory_display,
        session.working_directory_platform,
        session.working_directory_unc,
        snapshot.source.size as i64,
        modified_utc,
        Option::<String>::None,
        session.parser_version,
        snapshot.messages.len() as i64,
        user_message_count,
        assistant_message_count,
        snapshot.tool_calls.len() as i64,
        usage.input_tokens,
        usage.output_tokens,
        usage.cached_input_tokens,
        user_tokens,
        assistant_tokens,
        tool_tokens,
        detected_project_id,
        now,
        now,
        snapshot.harness,
        snapshot.machine_id,
        id,
    ])?;
    replace_messages(conn, id, snapshot, now)?;
    replace_tool_calls(conn, id, snapshot)?;
    replace_usage_events(conn, id, snapshot, now, resolver, source_type)?;
    if let Some(merge) = identity_merge {
        apply_identity_merge(conn, id, &merge)?;
    }
    refresh_session_project(conn, id)?;
    let affected = reconcile_affected_legacy_usage(conn, id, session.session_id.as_deref())?;
    replace_daily_projections(conn, &affected)
}

struct SearchDocument<'a> {
    id: &'a str,
    source_type: &'a str,
    source_file_path: &'a str,
    display_path: &'a str,
    platform_path: &'a str,
    title: String,
    summary: String,
    thread_name: &'a str,
    tool_names: String,
    normalized_path_keys: String,
    started_at_utc: Option<String>,
    last_message_at_utc: Option<String>,
    models_used: &'a [String],
    scan_status: &'a str,
    has_code_blocks: bool,
    has_tool_calls: bool,
    has_errors: bool,
    total_tokens: Option<i64>,
    project_name: &'a str,
}

/// `SessionSearchIndex.upsert`.
fn upsert_search_document(conn: &Connection, document: &SearchDocument<'_>) -> StoreResult<()> {
    let now = DartDateTime::now().to_iso8601();
    let existing_project: Option<Option<String>> = conn
        .prepare_cached("select project_name_snapshot from sessions where id = ?")?
        .query_row([document.id], |row| row.get(0))
        .optional()?;
    let existing_tags: Option<Vec<String>> = match existing_project {
        None => None,
        Some(_) => {
            let mut statement = conn.prepare_cached(
                "select t.name from session_tags st join tags t on t.id = st.tag_id
                 where st.session_id = ? order by t.name",
            )?;
            let names = statement
                .query_map([document.id], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;
            Some(names)
        }
    };
    conn.prepare_cached(
        "insert into sessions (
           id, source_type, source_file_path, display_path, platform_path, scan_status,
           parse_status, started_at_utc, last_message_at_utc, title, summary, thread_name,
           has_code_blocks, has_tool_calls, has_errors, total_tokens, model_primary,
           models_used, project_name_snapshot, is_pinned, is_archived, created_at_utc,
           updated_at_utc
         ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
         on conflict(id) do update set
           source_type = excluded.source_type,
           source_file_path = excluded.source_file_path,
           display_path = excluded.display_path,
           platform_path = excluded.platform_path,
           scan_status = excluded.scan_status,
           parse_status = excluded.parse_status,
           started_at_utc = excluded.started_at_utc,
           last_message_at_utc = excluded.last_message_at_utc,
           title = excluded.title,
           summary = excluded.summary,
           thread_name = excluded.thread_name,
           has_code_blocks = excluded.has_code_blocks,
           has_tool_calls = excluded.has_tool_calls,
           has_errors = excluded.has_errors,
           total_tokens = excluded.total_tokens,
           model_primary = excluded.model_primary,
           models_used = excluded.models_used,
           updated_at_utc = excluded.updated_at_utc",
    )?
    .execute(params![
        document.id,
        document.source_type,
        document.source_file_path,
        document.display_path,
        document.platform_path,
        document.scan_status,
        "available",
        document.started_at_utc,
        document.last_message_at_utc,
        document.title,
        document.summary,
        (!document.thread_name.is_empty()).then_some(document.thread_name),
        document.has_code_blocks,
        document.has_tool_calls,
        document.has_errors,
        document.total_tokens,
        document.models_used.first(),
        encode_membership(document.models_used),
        (!document.project_name.is_empty()).then_some(document.project_name),
        false,
        false,
        now,
        now,
    ])?;
    conn.prepare_cached("delete from session_path_keys where session_id = ?")?
        .execute([document.id])?;
    for path_key in document.normalized_path_keys.split(' ') {
        // Dart trims with String.trim; keys never contain spaces themselves.
        let key = trim(path_key);
        if key.is_empty() {
            continue;
        }
        conn.prepare_cached(
            "insert or ignore into session_path_keys (session_id, path_key) values (?, ?)",
        )?
        .execute(params![document.id, key])?;
    }
    let rowid: i64 = conn
        .prepare_cached("select rowid from sessions where id = ?")?
        .query_row([document.id], |row| row.get(0))?;
    let fts_project = match &existing_project {
        Some(project) => project.clone().unwrap_or_default(),
        None => document.project_name.to_owned(),
    };
    let fts_tags = existing_tags.clone().unwrap_or_default().join(" ");
    conn.prepare_cached("delete from session_search where rowid = ?")?
        .execute([rowid])?;
    conn.prepare_cached(
        "insert into session_search (rowid, title, summary, tool_names, display_path,
           normalized_path_keys, project_name, tags) values (?, ?, ?, ?, ?, ?, ?, ?)",
    )?
    .execute(params![
        rowid,
        document.title,
        document.summary,
        document.tool_names,
        document.display_path,
        document.normalized_path_keys,
        fts_project,
        fts_tags,
    ])?;
    if existing_project.is_none() {
        conn.prepare_cached("delete from session_tags where session_id = ?")?
            .execute([document.id])?;
    }
    Ok(())
}

fn replace_messages(
    conn: &Connection,
    id: &str,
    snapshot: &SessionSnapshot,
    now: &str,
) -> StoreResult<()> {
    conn.prepare_cached("delete from messages where session_id = ?")?
        .execute([id])?;
    let mut insert = conn.prepare_cached(
        "insert into messages (
           session_id, message_index, author_type, created_at_utc, first_line, content_plain,
           content_preview, content_truncated, token_input, token_output, token_cached,
           token_total, model, has_tool_calls, has_error, raw_type, created_at_db_utc,
           updated_at_db_utc
         ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )?;
    for message in &snapshot.messages {
        let usage = Usage::from(message.usage);
        insert.execute(params![
            id,
            message.index,
            message.author().name(),
            iso_or_null(message.created_at_utc.as_deref()),
            message.first_line,
            message.content_plain,
            message.content_preview,
            message.content_truncated,
            usage.input_tokens,
            usage.output_tokens,
            usage.cached_input_tokens,
            usage.total_tokens(),
            message.model,
            message.has_tool_calls,
            message.has_error,
            message.raw_type,
            now,
            now,
        ])?;
    }
    Ok(())
}

fn replace_tool_calls(conn: &Connection, id: &str, snapshot: &SessionSnapshot) -> StoreResult<()> {
    conn.prepare_cached("delete from tool_calls where session_id = ?")?
        .execute([id])?;
    let mut insert = conn.prepare_cached(
        "insert into tool_calls (
           session_id, tool_index, tool_name, status, started_at_utc, finished_at_utc,
           input_preview, output_preview, output_truncated, error_message
         ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    )?;
    for tool in &snapshot.tool_calls {
        insert.execute(params![
            id,
            tool.tool_index,
            tool.tool_name,
            tool.status,
            iso_or_null(tool.started_at_utc.as_deref()),
            iso_or_null(tool.finished_at_utc.as_deref()),
            tool.input_preview,
            tool.output_preview,
            tool.output_truncated,
            tool.error_message,
        ])?;
    }
    Ok(())
}

fn usage_bucket(record: &UsageRecord) -> [i64; 6] {
    let usage = Usage::from(*record);
    [
        usage.input_tokens.unwrap_or(0),
        usage.cached_input_tokens.unwrap_or(0),
        usage.cache_write_input_tokens.unwrap_or(0),
        usage.output_tokens.unwrap_or(0),
        usage.reasoning_output_tokens.unwrap_or(0),
        usage.total_tokens().unwrap_or(0),
    ]
}

/// `_replaceUsageEvents` for a context-based (schema 16+) database.
fn replace_usage_events(
    conn: &Connection,
    id: &str,
    snapshot: &SessionSnapshot,
    now: &str,
    resolver: &ProjectResolver,
    source_type: SourceType,
) -> StoreResult<()> {
    conn.prepare_cached("delete from usage_events where session_row_id = ?")?
        .execute([id])?;
    conn.prepare_cached("delete from usage_event_inputs where session_row_id = ?")?
        .execute([id])?;
    if snapshot.usage_events.is_empty() {
        return Ok(());
    }
    let mut project_ids: HashMap<String, i64> = HashMap::new();
    let mut context_ids: HashMap<(Option<String>, Option<String>), i64> = HashMap::new();
    for event in &snapshot.usage_events {
        let project_id = match resolver.resolve(event.working_directory.as_deref(), source_type) {
            Some(name) => match project_ids.get(&name) {
                Some(id) => Some(*id),
                None => {
                    let project = upsert_auto_project(conn, &name, now)?;
                    project_ids.insert(name, project);
                    Some(project)
                }
            },
            None => None,
        };
        let key = (
            event.working_directory.clone(),
            event.working_directory_unc.clone(),
        );
        let context_id = match context_ids.get(&key) {
            Some(context) => *context,
            None => {
                let context = resolve_usage_path_context(
                    conn,
                    event.working_directory.as_deref(),
                    event.working_directory.as_deref(),
                    event.working_directory_unc.as_deref(),
                    project_id,
                )?;
                context_ids.insert(key, context);
                context
            }
        };
        let buckets = usage_bucket(&event.usage);
        let units = event
            .billable_units
            .as_ref()
            .map(|units| serde_json::Value::Object(units.clone()).to_string());
        conn.prepare_cached(
            "insert into usage_events (
               session_row_id, source_record_ordinal, rollout_ordinal, turn_ordinal, epoch,
               occurred_at_utc, model, path_context_id, input_tokens, cached_input_tokens,
               cache_write_input_tokens, output_tokens, reasoning_output_tokens, total_tokens,
               branch_scope, derivation, event_fingerprint
             ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )?
        .execute(params![
            id,
            event.source_record_ordinal,
            event.rollout_ordinal,
            event.turn_ordinal,
            event.counter_epoch,
            iso_or_null(event.occurred_at_utc.as_deref()),
            event.model,
            context_id,
            buckets[0],
            buckets[1],
            buckets[2],
            buckets[3],
            buckets[4],
            buckets[5],
            event.branch_scope,
            event.derivation,
            event.event_fingerprint,
        ])?;
        if event.provider.is_some()
            || event.request_input_tokens.is_some()
            || event.model_context_window.is_some()
            || units.is_some()
        {
            conn.prepare_cached(
                "insert into usage_event_inputs (
                   session_row_id, source_record_ordinal, provider, request_input_tokens,
                   model_context_window, billable_units_json
                 ) values (?, ?, ?, ?, ?, ?)",
            )?
            .execute(params![
                id,
                event.source_record_ordinal,
                event.provider,
                event.request_input_tokens,
                event.model_context_window,
                units,
            ])?;
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Identity merge

struct MetadataSnapshot {
    row_id: i64,
    id: String,
    is_pinned: bool,
    project_override: bool,
    project_id: Option<i64>,
    project_name: Option<String>,
    updated_at_value: Option<String>,
    is_archived: bool,
    archived_at_value: Option<String>,
    archive_reason: Option<String>,
    eval_ready: bool,
    eval_status: Option<String>,
    eval_notes: Option<String>,
    eval_expected_output: Option<String>,
    eval_reviewed_at_value: Option<String>,
    eval_updated_at_value: Option<String>,
}

impl MetadataSnapshot {
    fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        let flag = |name: &str| -> rusqlite::Result<bool> {
            Ok(row.get::<_, Option<i64>>(name)?.unwrap_or(0) == 1)
        };
        Ok(Self {
            row_id: row.get("session_rowid")?,
            id: row.get("id")?,
            is_pinned: flag("is_pinned")?,
            project_override: flag("project_override")?,
            project_id: row.get("project_id")?,
            project_name: row.get("project_name_snapshot")?,
            updated_at_value: row.get("updated_at_utc")?,
            is_archived: flag("is_archived")?,
            archived_at_value: row.get("archived_at_utc")?,
            archive_reason: row.get("archive_reason")?,
            eval_ready: flag("eval_ready")?,
            eval_status: row.get("eval_status")?,
            eval_notes: row.get("eval_notes")?,
            eval_expected_output: row.get("eval_expected_output")?,
            eval_reviewed_at_value: row.get("eval_reviewed_at_utc")?,
            eval_updated_at_value: row.get("eval_updated_at_utc")?,
        })
    }
}

struct IdentityMerge {
    alternate_ids: Vec<String>,
    alternate_row_ids: Vec<i64>,
    is_pinned: bool,
    project: usize,
    archive: usize,
    evaluation: usize,
    snapshots: Vec<MetadataSnapshot>,
    tag_created_at_by_id: BTreeMap<i64, String>,
    path_aliases: Vec<String>,
}

fn identity_preference(id: &str) -> i32 {
    if id.starts_with("source:") {
        2
    } else if id.starts_with("source-status:") {
        1
    } else {
        0
    }
}

fn compare_metadata_tie_break(left: &MetadataSnapshot, right: &MetadataSnapshot) -> Ordering {
    identity_preference(&left.id)
        .cmp(&identity_preference(&right.id))
        .then_with(|| compare_utf16(&right.id, &left.id))
        .then_with(|| right.row_id.cmp(&left.row_id))
}

fn latest_metadata(
    snapshots: &[MetadataSnapshot],
    canonical: Option<usize>,
    timestamp: impl Fn(&MetadataSnapshot) -> Option<DartDateTime>,
) -> usize {
    let mut winner = canonical.unwrap_or(0);
    for (index, snapshot) in snapshots.iter().enumerate() {
        if index == winner {
            continue;
        }
        let compared = compare_nullable(timestamp(snapshot), timestamp(&snapshots[winner]));
        if compared == Ordering::Greater
            || (canonical.is_none()
                && compared == Ordering::Equal
                && compare_metadata_tie_break(snapshot, &snapshots[winner]) == Ordering::Greater)
        {
            winner = index;
        }
    }
    winner
}

/// `_captureIdentityMergeState`.
fn capture_identity_merge(
    conn: &Connection,
    canonical_id: &str,
    snapshot: &SessionSnapshot,
) -> StoreResult<Option<IdentityMerge>> {
    let stable = snapshot
        .session
        .session_id
        .as_deref()
        .map(trim)
        .unwrap_or("");
    if stable.is_empty() {
        return Ok(None);
    }
    let case_sensitive = source_type(snapshot) == SourceType::Wsl;
    let source = &snapshot.source;
    let mut raw_keys: Vec<&str> = vec![
        &source.path,
        &source.mapped_source_file_path,
        &source.display_path,
        &source.platform_path,
    ];
    if !case_sensitive {
        raw_keys.extend(source.normalized_path_keys.iter().map(String::as_str));
    }
    if let Some(unc) = &source.unc_path {
        raw_keys.push(unc);
    }
    let mut path_keys: Vec<String> = Vec::new();
    let mut seen: HashSet<&str> = HashSet::new();
    for key in raw_keys {
        if !seen.insert(key) {
            continue;
        }
        let normalized = normalize_identity_path(key, case_sensitive);
        if !normalized.is_empty() {
            path_keys.push(normalized);
        }
    }
    let placeholders = vec!["?"; path_keys.len()].join(", ");
    let column = |name: &str| {
        if case_sensitive {
            format!("replace(coalesce({name}, ''), '\\', '/')")
        } else {
            format!("replace(lower(coalesce({name}, '')), '\\', '/')")
        }
    };
    let id_suffix = |offset: usize| {
        if case_sensitive {
            format!("replace(substr(id, {offset}), '\\', '/')")
        } else {
            format!("replace(lower(substr(id, {offset})), '\\', '/')")
        }
    };
    let sql = format!(
        "select rowid as session_rowid, * from sessions
         where id = ?
            or (id <> ? and (
              trim(coalesce(session_id, '')) = ?
              or (trim(coalesce(session_id, '')) = '' and source_type = ? and (
                {} in ({placeholders})
                or {} in ({placeholders})
                or {} in ({placeholders})
                or {} in ({placeholders})
                or (id like 'source:%' and source_type = 'windows' and {} in ({placeholders}))
                or (id like 'source-status:%' and source_type = 'windows' and {} in ({placeholders}))
              ))
            ))",
        column("source_file_path"),
        column("source_file_unc_path"),
        column("display_path"),
        column("platform_path"),
        id_suffix(8),
        id_suffix(15),
    );
    let mut values: Vec<rusqlite::types::Value> = vec![
        canonical_id.to_owned().into(),
        canonical_id.to_owned().into(),
        stable.to_owned().into(),
        source.environment.clone().into(),
    ];
    for _ in 0..6 {
        values.extend(path_keys.iter().cloned().map(rusqlite::types::Value::from));
    }
    let mut statement = conn.prepare(&sql)?;
    let snapshots: Vec<MetadataSnapshot> = statement
        .query_map(params_from_iter(values), |row| {
            MetadataSnapshot::from_row(row)
        })?
        .collect::<Result<_, _>>()?;
    let alternates: Vec<&MetadataSnapshot> =
        snapshots.iter().filter(|s| s.id != canonical_id).collect();
    if alternates.is_empty() {
        return Ok(None);
    }
    let alternate_ids: Vec<String> = alternates.iter().map(|s| s.id.clone()).collect();
    let alternate_row_ids: Vec<i64> = alternates.iter().map(|s| s.row_id).collect();
    let canonical = snapshots.iter().position(|s| s.id == canonical_id);
    let project = latest_metadata(&snapshots, canonical, |s| {
        parse_time(s.updated_at_value.as_deref())
    });
    let archive = latest_metadata(&snapshots, canonical, |s| {
        parse_time(s.archived_at_value.as_deref())
    });
    let evaluation = latest_metadata(&snapshots, canonical, |s| {
        parse_time(s.eval_updated_at_value.as_deref())
    });
    let owner_ids: Vec<String> = snapshots.iter().map(|s| s.id.clone()).collect();
    let owner_placeholders = vec!["?"; owner_ids.len()].join(", ");
    let mut tag_created_at_by_id: BTreeMap<i64, String> = BTreeMap::new();
    let mut tag_statement = conn.prepare(&format!(
        "select tag_id, created_at_utc from session_tags where session_id in ({owner_placeholders})"
    ))?;
    let tags = tag_statement.query_map(params_from_iter(owner_ids.iter()), |row| {
        Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
    })?;
    for tag in tags {
        let (tag_id, created_at) = tag?;
        let keep = match tag_created_at_by_id.get(&tag_id) {
            Some(existing) => compare_utf16(&created_at, existing) == Ordering::Less,
            None => true,
        };
        if keep {
            tag_created_at_by_id.insert(tag_id, created_at);
        }
    }
    let mut alias_statement = conn.prepare(&format!(
        "select path_key from session_path_keys where session_id in ({owner_placeholders})"
    ))?;
    let mut path_aliases: Vec<String> = Vec::new();
    for alias in alias_statement.query_map(params_from_iter(owner_ids.iter()), |row| {
        row.get::<_, String>(0)
    })? {
        let alias = alias?;
        if !path_aliases.contains(&alias) {
            path_aliases.push(alias);
        }
    }
    let is_pinned = snapshots.iter().any(|s| s.is_pinned);
    Ok(Some(IdentityMerge {
        alternate_ids,
        alternate_row_ids,
        is_pinned,
        project,
        archive,
        evaluation,
        snapshots,
        tag_created_at_by_id,
        path_aliases,
    }))
}

/// `_applyIdentityMerge`.
fn apply_identity_merge(
    conn: &Connection,
    canonical_id: &str,
    merge: &IdentityMerge,
) -> StoreResult<()> {
    let project = &merge.snapshots[merge.project];
    let archive = &merge.snapshots[merge.archive];
    let evaluation = &merge.snapshots[merge.evaluation];
    conn.execute(
        "update sessions
         set is_pinned = ?, project_override = ?, project_id = ?, project_name_snapshot = ?,
             is_archived = ?, archived_at_utc = ?, archive_reason = ?, eval_ready = ?,
             eval_status = ?, eval_notes = ?, eval_expected_output = ?,
             eval_reviewed_at_utc = ?, eval_updated_at_utc = ?,
             updated_at_utc = case when julianday(?) > julianday(updated_at_utc) then ? else updated_at_utc end
         where id = ?",
        params![
            merge.is_pinned,
            project.project_override,
            project.project_id,
            project.project_name,
            archive.is_archived,
            archive.archived_at_value,
            archive.archive_reason,
            evaluation.eval_ready,
            evaluation.eval_status,
            evaluation.eval_notes,
            evaluation.eval_expected_output,
            evaluation.eval_reviewed_at_value,
            evaluation.eval_updated_at_value,
            project.updated_at_value,
            project.updated_at_value,
            canonical_id,
        ],
    )?;
    for alternate in &merge.alternate_ids {
        conn.execute(
            "delete from usage_events where session_row_id = ?",
            [alternate],
        )?;
        conn.execute(
            "delete from usage_event_inputs where session_row_id = ?",
            [alternate],
        )?;
        conn.execute("delete from tool_calls where session_id = ?", [alternate])?;
        conn.execute("delete from messages where session_id = ?", [alternate])?;
        conn.execute("delete from session_tags where session_id = ?", [alternate])?;
        conn.execute(
            "delete from session_path_keys where session_id = ?",
            [alternate],
        )?;
    }
    for row_id in &merge.alternate_row_ids {
        conn.execute("delete from session_search where rowid = ?", [row_id])?;
    }
    for alternate in &merge.alternate_ids {
        conn.execute("delete from sessions where id = ?", [alternate])?;
    }
    for (tag_id, created_at) in &merge.tag_created_at_by_id {
        conn.execute(
            "insert or ignore into session_tags (session_id, tag_id, created_at_utc) values (?, ?, ?)",
            params![canonical_id, tag_id, created_at],
        )?;
    }
    for alias in &merge.path_aliases {
        conn.execute(
            "insert or ignore into session_path_keys (session_id, path_key) values (?, ?)",
            params![canonical_id, alias],
        )?;
    }
    refresh_session_search_row(conn, canonical_id)?;
    let violations: i64 =
        conn.query_row("select count(*) from pragma_foreign_key_check", [], |row| {
            row.get(0)
        })?;
    if violations > 0 {
        return Err(super::schema::StoreError::Refused(
            "Session identity reconciliation left foreign-key violations.".to_owned(),
        ));
    }
    Ok(())
}

fn refresh_session_search_row(conn: &Connection, session_id: &str) -> StoreResult<()> {
    let row = conn
        .query_row(
            "select s.rowid,
               coalesce(s.title, ''), coalesce(s.summary, ''),
               coalesce((select group_concat(tc.tool_name, ' ') from tool_calls tc where tc.session_id = s.id), ''),
               coalesce(s.display_path, ''),
               coalesce((select group_concat(pk.path_key, ' ') from session_path_keys pk where pk.session_id = s.id), ''),
               coalesce(s.project_name_snapshot, p.name, ''),
               coalesce((select group_concat(t.name, ' ') from session_tags st join tags t on t.id = st.tag_id where st.session_id = s.id), '')
             from sessions s left join projects p on p.id = s.project_id
             where s.id = ?",
            [session_id],
            |row| {
                Ok((
                    row.get::<_, i64>(0)?,
                    [
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, String>(6)?,
                        row.get::<_, String>(7)?,
                    ],
                ))
            },
        )
        .optional()?;
    let Some((rowid, values)) = row else {
        return Ok(());
    };
    conn.execute("delete from session_search where rowid = ?", [rowid])?;
    conn.execute(
        "insert into session_search (rowid, title, summary, tool_names, display_path,
           normalized_path_keys, project_name, tags) values (?, ?, ?, ?, ?, ?, ?, ?)",
        params![
            rowid, values[0], values[1], values[2], values[3], values[4], values[5], values[6]
        ],
    )?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Legacy fork/subagent usage reconciliation

struct LegacyUsageSession {
    row_id: String,
    parent_logical_id: String,
    parser_version: i64,
    projection_status: String,
    has_aggregate_usage: bool,
}

const LEGACY_COLUMNS: &str = "id, session_id, forked_from_id, parent_thread_id, parser_version,
    usage_projection_status, input_tokens, output_tokens, cached_input_tokens, total_tokens";

const LEGACY_PREDICATE: &str = "history_base_thread_id is null
    and subagent_history_start_ordinal is null
    and ((forked_from_id is not null and forked_from_id <> '')
      or (parent_thread_id is not null and parent_thread_id <> ''))";

impl LegacyUsageSession {
    fn from_row(row: &Row<'_>) -> rusqlite::Result<Self> {
        let forked: Option<String> = row.get("forked_from_id")?;
        let parent: Option<String> = row.get("parent_thread_id")?;
        let forked = forked.as_deref().map(trim).unwrap_or("").to_owned();
        let parent = parent.as_deref().map(trim).unwrap_or("").to_owned();
        let positive = |name: &str| -> rusqlite::Result<bool> {
            Ok(row.get::<_, Option<i64>>(name)?.unwrap_or(0) > 0)
        };
        Ok(Self {
            row_id: row.get("id")?,
            parent_logical_id: if forked.is_empty() { parent } else { forked },
            parser_version: row.get("parser_version")?,
            projection_status: row.get("usage_projection_status")?,
            has_aggregate_usage: positive("input_tokens")?
                || positive("output_tokens")?
                || positive("cached_input_tokens")?
                || positive("total_tokens")?,
        })
    }
}

fn set_projection_status(conn: &Connection, row_id: &str, status: &str) -> StoreResult<()> {
    conn.prepare_cached("update sessions set usage_projection_status = ? where id = ?")?
        .execute(params![status, row_id])?;
    Ok(())
}

fn mark_unresolved(conn: &Connection, row_id: &str, status: &str) -> StoreResult<()> {
    conn.prepare_cached(
        "update usage_events set branch_scope = 'ambiguous' where session_row_id = ?",
    )?
    .execute([row_id])?;
    set_projection_status(conn, row_id, status)
}

/// `_reconcileAffectedLegacyUsage`. Returns the session IDs whose daily
/// projections must be rebuilt, in the order the Dart set yields them.
fn reconcile_affected_legacy_usage(
    conn: &Connection,
    replaced_row_id: &str,
    replaced_logical_id: Option<&str>,
) -> StoreResult<Vec<String>> {
    let mut affected: Vec<LegacyUsageSession> = Vec::new();
    let mut affected_index: HashMap<String, usize> = HashMap::new();
    let mut add =
        |session: LegacyUsageSession, affected: &mut Vec<LegacyUsageSession>| match affected_index
            .get(&session.row_id)
        {
            Some(index) => affected[*index] = session,
            None => {
                affected_index.insert(session.row_id.clone(), affected.len());
                affected.push(session);
            }
        };
    {
        let mut statement = conn.prepare_cached(&format!(
            "select {LEGACY_COLUMNS} from sessions where id = ? and {LEGACY_PREDICATE}"
        ))?;
        let rows = statement.query_map([replaced_row_id], LegacyUsageSession::from_row)?;
        for row in rows {
            add(row?, &mut affected);
        }
    }
    let logical = replaced_logical_id.map(trim).unwrap_or("");
    let mut pending: Vec<String> = if logical.is_empty() {
        Vec::new()
    } else {
        vec![logical.to_owned()]
    };
    let mut visited: HashSet<String> = HashSet::new();
    while let Some(parent_id) = pending.pop() {
        if !visited.insert(parent_id.clone()) {
            continue;
        }
        let mut statement = conn.prepare_cached(&format!(
            "select {LEGACY_COLUMNS}, ({LEGACY_PREDICATE}) as needs_reconciliation
             from sessions
             where (forked_from_id = ? or ((forked_from_id is null or forked_from_id = '') and parent_thread_id = ?))"
        ))?;
        let rows = statement.query_map(params![parent_id, parent_id], |row| {
            let needs: i64 = row.get("needs_reconciliation")?;
            let session_id: Option<String> = row.get("session_id")?;
            Ok((needs == 1, session_id, LegacyUsageSession::from_row(row)?))
        })?;
        for row in rows {
            let (needs, session_id, session) = row?;
            if needs {
                add(session, &mut affected);
            }
            let descendant = session_id.as_deref().map(trim).unwrap_or("").to_owned();
            if !descendant.is_empty() && !visited.contains(&descendant) {
                pending.push(descendant);
            }
        }
    }

    let mut parent_cache: HashMap<String, Vec<LegacyUsageSession>> = HashMap::new();
    let mut fingerprint_cache: HashMap<String, Vec<String>> = HashMap::new();
    let parents_for = |conn: &Connection,
                       cache: &mut HashMap<String, Vec<LegacyUsageSession>>,
                       parent: &str|
     -> StoreResult<Vec<(String, i64, String, bool)>> {
        if !cache.contains_key(parent) {
            let mut statement = conn.prepare_cached(&format!(
                "select {LEGACY_COLUMNS} from sessions where session_id = ? order by id"
            ))?;
            let rows = statement
                .query_map([parent], LegacyUsageSession::from_row)?
                .collect::<Result<Vec<_>, _>>()?;
            cache.insert(parent.to_owned(), rows);
        }
        Ok(cache[parent]
            .iter()
            .map(|p| {
                (
                    p.row_id.clone(),
                    p.parser_version,
                    p.projection_status.clone(),
                    p.has_aggregate_usage,
                )
            })
            .collect())
    };
    let fingerprints_for = |conn: &Connection,
                            cache: &mut HashMap<String, Vec<String>>,
                            row_id: &str|
     -> StoreResult<Vec<String>> {
        if !cache.contains_key(row_id) {
            let mut statement = conn.prepare_cached(
                "select event_fingerprint from usage_events where session_row_id = ? order by source_record_ordinal",
            )?;
            let rows = statement
                .query_map([row_id], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;
            cache.insert(row_id.to_owned(), rows);
        }
        Ok(cache[row_id].clone())
    };
    let parent_logical_of = |conn: &Connection,
                             cache: &mut HashMap<String, Vec<LegacyUsageSession>>,
                             parent: &str|
     -> StoreResult<Option<(String, String)>> {
        let parents = parents_for(conn, cache, parent)?;
        if parents.len() != 1 {
            return Ok(None);
        }
        let row = &cache[parent][0];
        Ok(Some((parents[0].0.clone(), row.parent_logical_id.clone())))
    };

    for child in &affected {
        if child.parser_version != PARSER_VERSION {
            mark_unresolved(conn, &child.row_id, "legacy_pending")?;
            continue;
        }
        // hasCycle
        let mut cycle = false;
        {
            let mut seen: HashSet<String> = HashSet::from([child.row_id.clone()]);
            let mut current_parent = child.parent_logical_id.clone();
            while !current_parent.is_empty() {
                let Some((parent_row, grand_parent)) =
                    parent_logical_of(conn, &mut parent_cache, &current_parent)?
                else {
                    break;
                };
                if !seen.insert(parent_row) {
                    cycle = true;
                    break;
                }
                current_parent = grand_parent;
            }
        }
        if cycle {
            mark_unresolved(conn, &child.row_id, "ambiguous")?;
            continue;
        }
        let child_fingerprints = fingerprints_for(conn, &mut fingerprint_cache, &child.row_id)?;
        if child_fingerprints.is_empty() {
            if !child.has_aggregate_usage {
                set_projection_status(conn, &child.row_id, "complete")?;
            } else {
                mark_unresolved(conn, &child.row_id, "ambiguous")?;
            }
            continue;
        }
        let parents = parents_for(conn, &mut parent_cache, &child.parent_logical_id)?;
        if parents.is_empty() {
            mark_unresolved(conn, &child.row_id, "missing_parent")?;
            continue;
        }
        if parents.len() != 1 {
            mark_unresolved(conn, &child.row_id, "ambiguous")?;
            continue;
        }
        let (parent_row, parent_version, parent_status, parent_aggregate) = parents[0].clone();
        if parent_version != PARSER_VERSION {
            mark_unresolved(conn, &child.row_id, "legacy_pending")?;
            continue;
        }
        let parent_fingerprints = fingerprints_for(conn, &mut fingerprint_cache, &parent_row)?;
        if parent_fingerprints.is_empty() && (parent_status != "complete" || parent_aggregate) {
            mark_unresolved(conn, &child.row_id, "ambiguous")?;
            continue;
        }
        let prefix = parent_fingerprints
            .iter()
            .zip(&child_fingerprints)
            .take_while(|(left, right)| left == right)
            .count();
        if !parent_fingerprints.is_empty() && prefix == 0 {
            mark_unresolved(conn, &child.row_id, "ambiguous")?;
            continue;
        }
        if prefix == 0 {
            conn.prepare_cached(
                "update usage_events set branch_scope = 'local' where session_row_id = ?",
            )?
            .execute([&child.row_id])?;
        } else {
            let inherited_end: i64 = conn
                .prepare_cached(
                    "select source_record_ordinal from usage_events where session_row_id = ?
                     order by source_record_ordinal limit 1 offset ?",
                )?
                .query_row(params![child.row_id, prefix as i64 - 1], |row| row.get(0))?;
            conn.prepare_cached(
                "update usage_events set branch_scope = case
                   when source_record_ordinal <= ? then 'inherited' else 'local' end
                 where session_row_id = ?",
            )?
            .execute(params![inherited_end, child.row_id])?;
        }
        set_projection_status(conn, &child.row_id, "complete")?;
    }
    let mut result = vec![replaced_row_id.to_owned()];
    for session in affected {
        if !result.contains(&session.row_id) {
            result.push(session.row_id);
        }
    }
    Ok(result)
}

/// `UsageSummaryRepository.replaceDailyProjectionsInCurrentTransaction` for
/// the active (schema 16+) generation. New rows start with unknown cost; the
/// viewer's pricing maintenance fills in prices from the dirty partitions.
fn replace_daily_projections(conn: &Connection, session_ids: &[String]) -> StoreResult<()> {
    let now = DartDateTime::now().to_iso8601();
    for id in session_ids {
        conn.prepare_cached("delete from usage_session_daily where session_id = ?")?
            .execute([id])?;
        conn.prepare_cached(
            "insert into usage_session_daily (
               session_id, day_utc, model_key, path_context_id, branch_scope,
               input_tokens, cached_input_tokens, cache_write_input_tokens,
               output_tokens, reasoning_output_tokens, total_tokens, estimated_cost_text,
               cost_status, pricing_resolution_method, cost_projection_version, updated_at_utc)
             select session_row_id, strftime('%Y-%m-%d', occurred_at_utc),
               coalesce(model, ''), path_context_id, branch_scope,
               sum(input_tokens), sum(cached_input_tokens), sum(cache_write_input_tokens),
               sum(output_tokens), sum(reasoning_output_tokens), sum(input_tokens + output_tokens),
               null, 'unknown', 'pending_history', 1, ?
             from usage_events where session_row_id = ?
               and strftime('%Y-%m-%d', occurred_at_utc) is not null
             group by session_row_id, strftime('%Y-%m-%d', occurred_at_utc),
               coalesce(model, ''), path_context_id, branch_scope",
        )?
        .execute(params![now, id])?;
        conn.prepare_cached(
            "update sessions set usage_local_event_count = (
               select count(*) from usage_events where session_row_id = ? and branch_scope = 'local'
             ) where id = ?",
        )?
        .execute(params![id, id])?;
        conn.prepare_cached(
            "delete from usage_cost_dirty_partitions where session_id = ?
               and not exists (select 1 from usage_session_daily daily
                 where daily.session_id = usage_cost_dirty_partitions.session_id
                   and daily.day_utc = usage_cost_dirty_partitions.day_utc
                   and daily.model_key = usage_cost_dirty_partitions.model_key)",
        )?
        .execute([id])?;
        conn.prepare_cached(
            "insert into usage_cost_dirty_partitions (session_id, day_utc, model_key, reason,
               target_cost_projection_version, created_at_utc, updated_at_utc)
             select distinct session_id, day_utc, model_key, 'usage_ingestion', ?, ?, ?
             from usage_session_daily where session_id = ?
             on conflict(session_id, day_utc, model_key) do update set
               target_cost_projection_version = max(usage_cost_dirty_partitions.target_cost_projection_version,
                 excluded.target_cost_projection_version),
               updated_at_utc = excluded.updated_at_utc",
        )?
        .execute(params![USAGE_COST_PROJECTION_VERSION, now, now, id])?;
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Scan outcomes, thread names, and resolved projects

fn status_index(status: &str) -> i32 {
    match status {
        "available" => 0,
        "missing" => 1,
        "path_unreachable" => 2,
        "parse_error" => 3,
        "permission_denied" => 4,
        "unsupported_format" => 5,
        _ => 6,
    }
}

/// `'source-status:${p.normalize(sourcePath).toLowerCase()}'`.
pub fn source_status_id(source_path: &str) -> String {
    format!(
        "source-status:{}",
        to_lower(&normalize_windows_path(source_path))
    )
}

/// Placeholder row for a source that produced no session. Codex keeps the
/// viewer's form; other harnesses are namespaced like their session rows.
fn placeholder_id(harness: &str, source_path: &str) -> String {
    let id = source_status_id(source_path);
    if harness == "codex" {
        id
    } else {
        format!("{harness}:{id}")
    }
}

fn source_type_label(source_path: &str) -> &'static str {
    if source_path.starts_with("\\\\wsl") || source_path.contains("/home/") {
        "wsl"
    } else {
        "windows"
    }
}

/// `_upsertScanStatusesOnly`, in its own transaction.
pub fn apply_source_statuses(conn: &Connection, statuses: &[SourceStatus]) -> StoreResult<()> {
    if statuses.is_empty() {
        return Ok(());
    }
    let mut ordered: Vec<&SourceStatus> = statuses.iter().collect();
    ordered.sort_by(|left, right| {
        compare_utf16(
            &canonical_scan_path(&left.path),
            &canonical_scan_path(&right.path),
        )
        .then_with(|| status_index(&left.status).cmp(&status_index(&right.status)))
    });
    begin_write(conn)?;
    let result = (|| -> StoreResult<()> {
        let now = DartDateTime::now().to_iso8601();
        conn.execute_batch(
            "drop table if exists temp_scan_statuses;
             create temp table temp_scan_statuses (
               harness text not null, source_path text not null, status text not null,
               source_state text not null, primary key (harness, source_path)
             );",
        )?;
        {
            let mut insert = conn.prepare(
                "insert or replace into temp_scan_statuses (harness, source_path, status, source_state)
                 values (?, ?, ?, ?)",
            )?;
            for status in &ordered {
                insert.execute(params![
                    status.harness,
                    status.path,
                    status.status,
                    status.state
                ])?;
            }
        }
        conn.execute(
            "update sessions set
               scan_status = (select t.status from temp_scan_statuses t
                 where t.harness = sessions.harness and (t.source_path = sessions.source_file_path or t.source_path = sessions.source_file_unc_path) limit 1),
               source_state = (select t.source_state from temp_scan_statuses t
                 where t.harness = sessions.harness and (t.source_path = sessions.source_file_path or t.source_path = sessions.source_file_unc_path) limit 1),
               parse_status = case when (select t.status from temp_scan_statuses t
                 where t.harness = sessions.harness and (t.source_path = sessions.source_file_path or t.source_path = sessions.source_file_unc_path) limit 1)
                 = 'parse_error' then 'parse_error' else parse_status end,
               updated_at_utc = case when (select t.status from temp_scan_statuses t
                 where t.harness = sessions.harness and (t.source_path = sessions.source_file_path or t.source_path = sessions.source_file_unc_path) limit 1)
                 = 'available' then updated_at_utc else ? end,
               last_scanned_utc = case when (select t.status from temp_scan_statuses t
                 where t.harness = sessions.harness and (t.source_path = sessions.source_file_path or t.source_path = sessions.source_file_unc_path) limit 1)
                 = 'available' then last_scanned_utc else ? end
             where exists (select 1 from temp_scan_statuses t
               where t.harness = sessions.harness and (t.source_path = sessions.source_file_path or t.source_path = sessions.source_file_unc_path))",
            params![now, now],
        )?;
        let missing: Vec<(String, String, String, String)> = {
            let mut statement = conn.prepare(
                "select t.harness, t.source_path, t.status, t.source_state from temp_scan_statuses t
                 where t.status not in ('available', 'missing', 'path_unreachable')
                   and not exists (select 1 from sessions s where s.harness = t.harness
                     and (s.source_file_path = t.source_path or s.source_file_unc_path = t.source_path))",
            )?;
            statement
                .query_map([], |row| {
                    Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
                })?
                .collect::<Result<_, _>>()?
        };
        {
            let mut insert = conn.prepare(
                "insert into sessions (id, source_type, source_file_path, display_path, platform_path,
                   scan_status, source_state, parse_status, created_at_utc, updated_at_utc,
                   last_scanned_utc, harness)
                 values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                 on conflict(id) do update set
                   scan_status = excluded.scan_status, source_state = excluded.source_state,
                   updated_at_utc = excluded.updated_at_utc, last_scanned_utc = excluded.last_scanned_utc",
            )?;
            for (harness, path, status, state) in &missing {
                insert.execute(params![
                    placeholder_id(harness, path),
                    source_type_label(path),
                    path,
                    path,
                    path,
                    status,
                    state,
                    if status == "parse_error" {
                        "parse_error"
                    } else {
                        "available"
                    },
                    now,
                    now,
                    now,
                    harness,
                ])?;
            }
        }
        conn.execute_batch("delete from temp_scan_statuses")?;
        Ok(())
    })();
    finish(conn, result)
}

/// `_applySessionIndexThreadNames`.
pub fn apply_thread_names(conn: &Connection, names: &[ThreadName]) -> StoreResult<usize> {
    if names.is_empty() {
        return Ok(0);
    }
    begin_write(conn)?;
    let result = (|| -> StoreResult<usize> {
        let mut changed: HashSet<String> = HashSet::new();
        for entry in names {
            let thread_name = trim(&entry.thread_name);
            if thread_name.is_empty() {
                continue;
            }
            let rows: Vec<(i64, String, Option<String>)> = {
                let mut statement = conn.prepare_cached(
                    "select rowid, id, thread_name from sessions where session_id = ? and harness = ?",
                )?;
                statement
                    .query_map(params![entry.session_id, entry.harness], |row| {
                        Ok((row.get(0)?, row.get(1)?, row.get(2)?))
                    })?
                    .collect::<Result<_, _>>()?
            };
            for (rowid, id, current) in rows {
                if current.as_deref().unwrap_or("") == thread_name {
                    continue;
                }
                conn.prepare_cached("update sessions set thread_name = ? where rowid = ?")?
                    .execute(params![thread_name, rowid])?;
                changed.insert(id);
            }
        }
        Ok(changed.len())
    })();
    finish(conn, result)
}

/// `_applyResolvedProjectsForParsedCandidates`: re-resolve the detected
/// project of the listed sessions with names found on the source machine.
pub fn apply_project_hints(
    conn: &Connection,
    harness: &str,
    sessions: &[SessionRef],
    hints: &[ProjectHint],
) -> StoreResult<usize> {
    let resolver = ProjectResolver::new(
        hints
            .iter()
            .map(|hint| (hint.working_directory.clone(), hint.project_name.clone())),
    );
    let mut ids: Vec<String> = Vec::new();
    for session in sessions {
        let id = session_row_id(harness, session.session_id.as_deref(), &session.source_path);
        if !ids.contains(&id) {
            ids.push(id);
        }
    }
    if ids.is_empty() {
        return Ok(0);
    }
    // Read and write under one write lock so the rows cannot change between.
    begin_write(conn)?;
    let result = (|| -> StoreResult<usize> {
        let mut rows: Vec<(String, String)> = Vec::new();
        for chunk in ids.chunks(500) {
            let placeholders = vec!["?"; chunk.len()].join(", ");
            let mut statement = conn.prepare(&format!(
                "select id, working_directory_display, source_type from sessions where id in ({placeholders})"
            ))?;
            let found = statement.query_map(params_from_iter(chunk.iter()), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            })?;
            for row in found {
                let (id, working_directory, source_type) = row?;
                let source_type = if source_type.as_deref() == Some("wsl") {
                    SourceType::Wsl
                } else {
                    SourceType::Windows
                };
                if let Some(name) = resolver.resolve(working_directory.as_deref(), source_type) {
                    let name = trim(&name).to_owned();
                    if !name.is_empty() {
                        rows.push((id, name));
                    }
                }
            }
        }
        let now = DartDateTime::now().to_iso8601();
        for (id, name) in &rows {
            let project_id = upsert_auto_project(conn, name, &now)?;
            conn.prepare_cached(
                "update sessions set detected_project_id = ?, updated_at_utc = ? where id = ?",
            )?
            .execute(params![project_id, now, id])?;
            refresh_session_project(conn, id)?;
        }
        Ok(rows.len())
    })();
    finish(conn, result)
}

/// `_cleanSessionMetadataPlaceholders`.
pub fn clean_session_metadata_placeholders(conn: &Connection) -> StoreResult<()> {
    let pending: i64 = conn.query_row(
        "select count(*) from sessions
         where lower(trim(coalesce(title, ''))) like '# agents.md%'
            or lower(trim(coalesce(summary, ''))) = 'auto'",
        [],
        |row| row.get(0),
    )?;
    if pending == 0 {
        return Ok(());
    }
    // Select the rows again under the write lock: rowids read earlier could
    // belong to other sessions by now.
    begin_write(conn)?;
    let result = (|| -> StoreResult<()> {
        let rows: Vec<(i64, bool, bool)> = {
            let mut statement = conn.prepare(
                "select rowid,
                   lower(trim(coalesce(title, ''))) like '# agents.md%',
                   lower(trim(coalesce(summary, ''))) = 'auto'
                 from sessions
                 where lower(trim(coalesce(title, ''))) like '# agents.md%'
                    or lower(trim(coalesce(summary, ''))) = 'auto'",
            )?;
            statement
                .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
                .collect::<Result<_, _>>()?
        };
        for (rowid, bad_title, bad_summary) in &rows {
            conn.execute(
                "update sessions set title = case when ? then null else title end,
                   summary = case when ? then null else summary end where rowid = ?",
                params![bad_title, bad_summary, rowid],
            )?;
            conn.execute(
                "update session_search set title = case when ? then '' else title end,
                   summary = case when ? then '' else summary end where rowid = ?",
                params![bad_title, bad_summary, rowid],
            )?;
        }
        Ok(())
    })();
    finish(conn, result)
}

/// Cached invalidation metadata for the scanner's skip decisions.
#[derive(Clone, Debug)]
pub struct CachedSource {
    pub source_path: String,
    pub unc_path: Option<String>,
    pub scan_status: String,
    pub file_size: Option<i64>,
    pub modified_utc: Option<DartDateTime>,
    pub parser_version: Option<i64>,
}

/// `_cachedSessions`, limited to one harness.
pub fn cached_sources(conn: &Connection, harness: &str) -> StoreResult<Vec<CachedSource>> {
    let mut statement = conn.prepare(
        "select source_file_path, source_file_unc_path, scan_status, file_size, modified_utc, parser_version
         from sessions where harness = ?",
    )?;
    let rows = statement
        .query_map([harness], |row| {
            Ok(CachedSource {
                source_path: row.get(0)?,
                unc_path: row.get(1)?,
                scan_status: row
                    .get::<_, Option<String>>(2)?
                    .unwrap_or_else(|| "available".to_owned()),
                file_size: row.get(3)?,
                modified_utc: parse_time(row.get::<_, Option<String>>(4)?.as_deref()),
                parser_version: row.get(5)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}
