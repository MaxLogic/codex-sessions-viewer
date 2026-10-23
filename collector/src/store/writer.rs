//! Applies contract records: the only writer of parsed session state. The SQL
//! began as a port of the viewer's retired Dart scan writer, and the daily
//! usage projection matches `UsageSummaryRepository`, which the viewer still
//! uses for its own repricing. Every write runs in a short `BEGIN IMMEDIATE`
//! transaction. A per-call collector lease fences other collectors across
//! chunks; SQLite locks and its busy timeout serialize individual chunks with
//! the viewer.

use std::cmp::Ordering;
use std::collections::{BTreeMap, HashMap, HashSet};

use rusqlite::types::Value;
use rusqlite::{Connection, OptionalExtension, Row, params, params_from_iter};
use sha2::{Digest, Sha256};

use crate::codex::parser::{AuthorType, SourceType, Usage};
use crate::contract::{
    MessageRecord, ProjectHint, ProjectHints, Record, SessionRef, SessionSnapshot, SourceStatus,
    ThreadName, ToolCallRecord, UsageRecord, parse_time,
};
use crate::dart::{DartDateTime, compare_utf16, to_lower, trim};
use crate::hub_client;
use crate::path_mapping::{
    HOST_PATHS_ARE_CASE_SENSITIVE, canonical_scan_path, normalize_identity_path,
    normalize_windows_path,
};

use super::projects::{
    ProjectResolver, refresh_session_project, resolve_usage_path_context, upsert_auto_project,
};
use super::schema::{
    StoreError, StoreResult, begin_write, check_parser_version, finish, parser_version_key,
};

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

fn physical_paths_are_case_sensitive(source_type: SourceType) -> bool {
    matches!(source_type, SourceType::Wsl | SourceType::Linux)
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
            let case_sensitive = physical_paths_are_case_sensitive(left.source_type)
                || physical_paths_are_case_sensitive(right.source_type);
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

/// `_persistParsedSessions`: bounded transactions at session boundaries.
pub fn apply_session_batch(
    conn: &Connection,
    snapshots: Vec<SessionSnapshot>,
) -> StoreResult<usize> {
    apply_session_batch_versioned(conn, snapshots, None)
}

pub(crate) fn apply_session_batch_versioned(
    conn: &Connection,
    snapshots: Vec<SessionSnapshot>,
    version: Option<u32>,
) -> StoreResult<usize> {
    let _phase = super::write_budget::write_phase("sessions");
    let _lease = super::write_lease::WriteLease::acquire(conn)?;
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
    let now = DartDateTime::now().to_iso8601();
    super::write_budget::write_planned(
        conn,
        "sessions",
        // A session's cost is unknown before applying its indexed merges and
        // projections. Isolate it so one large indivisible unit cannot carry
        // earlier units past the soft target (CXV-180 live-copy witness).
        1,
        || {
            let lookup = IdentityLookup::for_batch(conn)?;
            let mut units = Vec::new();
            for (id, snapshot) in &canonical {
                let mut candidates = capture_identity_merge(conn, id, snapshot, lookup)?
                    .map(|merge| merge.alternate_ids)
                    .unwrap_or_default();
                candidates.push(id.clone());
                let shape =
                    crate::timing::enabled().then(|| super::write_budget::SessionWriteShape {
                        messages: snapshot.messages.len(),
                        tool_calls: snapshot.tool_calls.len(),
                        source_bytes: snapshot.source.size,
                        content_bytes: snapshot
                            .messages
                            .iter()
                            .map(|message| message.content_plain.len())
                            .sum(),
                    });
                units.push((id, snapshot, candidates, shape));
            }
            Ok(units)
        },
        |(id, snapshot, candidates, shape)| {
            let start = std::time::Instant::now();
            {
                check_parser_version(conn, &snapshot.harness)?;
                let resolver = ProjectResolver::new(
                    snapshot
                        .project_hints
                        .iter()
                        .map(|hint| (hint.working_directory.clone(), hint.project_name.clone())),
                );
                crate::timing::timed("write: session total", || {
                    upsert_session(
                        conn,
                        id,
                        snapshot,
                        &now,
                        &resolver,
                        IdentityLookup::Planned(&candidates),
                    )
                })?;
            }
            if hub_client::queue_enabled(conn)? {
                enqueue_for_version(
                    conn,
                    Record::SessionSnapshot(Box::new(snapshot.clone())),
                    &now,
                    version,
                )?;
            }
            super::write_budget::record_session_unit(start.elapsed());
            super::write_budget::record_session_shape(shape);
            Ok(())
        },
    )?;
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
                source_type: row
                    .get::<_, Option<String>>(0)?
                    .as_deref()
                    .and_then(SourceType::from_wire)
                    .unwrap_or(SourceType::Windows),
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
        // A new parse of the file the row came from always replaces it: a
        // newer parser may drop trailing records, so the reparse can end
        // earlier than the stored row. The evidence ranking only chooses
        // between different copies of a session.
        Some(existing) if same_source_file(&existing, snapshot) => true,
        Some(existing) => {
            compare_candidates(&Evidence::from_snapshot(snapshot), &existing) != Ordering::Less
        }
    })
}

fn same_source_file(existing: &Evidence, snapshot: &SessionSnapshot) -> bool {
    let snapshot_type = source_type(snapshot);
    if existing.source_type != snapshot_type {
        return false;
    }
    if physical_paths_are_case_sensitive(snapshot_type) {
        existing.source_path == snapshot.source.path
    } else {
        to_lower(&existing.source_path) == to_lower(&snapshot.source.path)
    }
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
    lookup: IdentityLookup<'_>,
) -> StoreResult<()> {
    let session = &snapshot.session;
    let identity_merge = crate::timing::timed("write: identity capture", || {
        capture_identity_merge(conn, id, snapshot, lookup)
    })?;
    if !crate::timing::timed("write: replace decision", || {
        candidate_should_replace(conn, id, snapshot)
    })? {
        if let Some(merge) = identity_merge {
            apply_identity_merge(conn, id, &merge)?;
            let (affected, _) = reconcile_affected_legacy_usage(
                conn,
                &snapshot.harness,
                id,
                session.session_id.as_deref(),
            )?;
            replace_daily_projections(conn, &affected, None)?;
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
    let stored_digest: Option<String> = conn
        .prepare_cached("select content_hash from sessions where id = ?")?
        .query_row([id], |row| row.get(0))
        .optional()?
        .flatten();
    let content = crate::timing::timed("write: content rows", || {
        SessionContent::build(conn, snapshot, now, resolver, source_type)
    })?;
    let has_errors = snapshot.messages.iter().any(|message| message.has_error)
        || snapshot
            .tool_calls
            .iter()
            .any(|tool| tool.error_message.is_some() || tool.status == "error");
    let resolved =
        resolver.resolve_marked(session.working_directory_display.as_deref(), source_type);
    let project_refined = resolved.as_ref().is_some_and(|(_, hinted)| *hinted);
    let auto_project = resolved.map(|(name, _)| name);
    let detected_project_id = match &auto_project {
        Some(name) => Some(upsert_auto_project(conn, name, now)?),
        None => None,
    };
    let (user_tokens, assistant_tokens, tool_tokens) = message_token_buckets(snapshot);
    let usage = Usage::from(session.usage);
    crate::timing::timed("write: search document", || {
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
        )
    })?;
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
           detected_project_id = ?, project_refined = ?, last_scanned_utc = ?, last_parsed_utc = ?,
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
        content.digest.as_str(),
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
        project_refined,
        now,
        now,
        snapshot.harness,
        snapshot.machine_id,
        id,
    ])?;
    // While the stored digest matches, the stored rows already equal this
    // parse's rows, and reading them back to compare is skipped.
    let unchanged =
        identity_merge.is_none() && stored_digest.as_deref() == Some(content.digest.as_str());
    let partitions = if unchanged {
        Some(Vec::new())
    } else {
        crate::timing::timed("write: messages", || {
            replace_messages(conn, id, &content.messages, now)
        })?;
        crate::timing::timed("write: tool calls", || {
            replace_tool_calls(conn, id, snapshot, content.tool_calls)
        })?;
        crate::timing::timed("write: usage events", || {
            sync_usage_events(conn, id, now, &content.usage_events, &content.usage_inputs)
        })?
    };
    // A merged identity may change this session's usage beyond the events
    // that changed here: rebuild all of its days.
    let partitions = partitions.filter(|_| identity_merge.is_none());
    crate::timing::timed("write: source extras", || {
        replace_source_extras(conn, id, snapshot, now)
    })?;
    if let Some(merge) = identity_merge {
        apply_identity_merge(conn, id, &merge)?;
    }
    crate::timing::timed("write: project refresh", || {
        refresh_session_project(conn, id)
    })?;
    let (affected, rescoped) = crate::timing::timed("write: legacy usage", || {
        reconcile_affected_legacy_usage(conn, &snapshot.harness, id, session.session_id.as_deref())
    })?;
    // Rescoped inherited usage changes this session's days beyond the events
    // that changed here: rebuild all of them.
    let partitions = partitions.filter(|_| !rescoped);
    crate::timing::timed("write: daily projections", || {
        replace_daily_projections(
            conn,
            &affected,
            Some(WrittenSession {
                id,
                partitions: partitions.as_deref(),
            }),
        )
    })
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

/// The stored message columns a snapshot sets, in this order.
const MESSAGE_COLUMNS: [&str; 14] = [
    "author_type",
    "created_at_utc",
    "first_line",
    "content_plain",
    "content_preview",
    "content_truncated",
    "token_input",
    "token_output",
    "token_cached",
    "token_total",
    "model",
    "has_tool_calls",
    "has_error",
    "raw_type",
];
const CONTENT_PLAIN: usize = 3;

fn message_values(message: &MessageRecord) -> Vec<Value> {
    let usage = Usage::from(message.usage);
    let flag = |value: bool| Value::Integer(i64::from(value));
    let text = |value: Option<String>| value.map_or(Value::Null, Value::Text);
    let number = |value: Option<i64>| value.map_or(Value::Null, Value::Integer);
    vec![
        Value::Text(message.author().name().to_owned()),
        text(iso_or_null(message.created_at_utc.as_deref())),
        Value::Text(message.first_line.clone()),
        Value::Text(message.content_plain.clone()),
        Value::Text(message.content_preview.clone()),
        flag(message.content_truncated),
        number(usage.input_tokens),
        number(usage.output_tokens),
        number(usage.cached_input_tokens),
        number(usage.total_tokens()),
        text(message.model.clone()),
        flag(message.has_tool_calls),
        flag(message.has_error),
        text(message.raw_type.clone()),
    ]
}

/// A stored row of one session: its per-session key and its columns.
type SessionRow = (i64, Vec<Value>);

/// One table's rows of one session, keyed by a per-session index.
struct SessionRows<'a> {
    table: &'a str,
    session_column: &'a str,
    key: &'a str,
    columns: &'a [&'a str],
    /// The column a search trigger watches (`after update of ...`).
    indexed: Option<usize>,
    /// Stamps written with `now`: on insert, and on update.
    inserted_stamps: &'a [&'a str],
    updated_stamps: &'a [&'a str],
}

/// A row [`sync_session_rows`] deleted, updated or added: its old and new
/// columns.
struct RowChange {
    old: Option<Vec<Value>>,
    new: Option<Vec<Value>>,
}

/// Brings one session's stored rows in line with `rows` (key, values). A
/// row whose columns are unchanged is left alone, and one whose indexed text
/// is unchanged keeps its search entry: rewriting every row of a session
/// that grew by one line rewrote and reindexed its whole history. Returns
/// the changes, or `None`, having written nothing, when a key repeats and
/// rows cannot be matched.
fn sync_session_rows(
    conn: &Connection,
    shape: &SessionRows<'_>,
    session_id: &str,
    now: &str,
    rows: &[(i64, Vec<Value>)],
) -> StoreResult<Option<Vec<RowChange>>> {
    let mut stored: HashMap<i64, Vec<Value>> = HashMap::new();
    {
        let mut select = conn.prepare_cached(&format!(
            "select {}, {} from {} where {} = ?",
            shape.key,
            shape.columns.join(", "),
            shape.table,
            shape.session_column
        ))?;
        let mut cursor = select.query([session_id])?;
        while let Some(row) = cursor.next()? {
            let values = (0..shape.columns.len())
                .map(|column| row.get::<_, Value>(column + 1))
                .collect::<Result<Vec<_>, _>>()?;
            if stored.insert(row.get(0)?, values).is_some() {
                return Ok(None);
            }
        }
    }
    let mut keys = HashSet::new();
    if !rows.iter().all(|(key, _)| keys.insert(*key)) {
        return Ok(None);
    }
    let mut updated = Vec::new();
    let mut added = Vec::new();
    for (key, values) in rows {
        match stored.remove(key) {
            Some(old) if old == *values => {}
            Some(old) => updated.push((*key, old, values)),
            None => added.push((*key, values)),
        }
    }
    let mut changes = Vec::new();
    // Rows the snapshot no longer has go first, so their keys are free
    // before any row is added.
    let mut delete = conn.prepare_cached(&format!(
        "delete from {} where {} = ? and {} = ?",
        shape.table, shape.session_column, shape.key
    ))?;
    for (key, old) in stored {
        delete.execute(params![session_id, key])?;
        changes.push(RowChange {
            old: Some(old),
            new: None,
        });
    }
    // A search trigger fires on any update that names its column, so an
    // unchanged text is left out of the update. A row whose text changed is
    // deleted and inserted again under the same row id instead: the schema's
    // two update triggers run add-then-remove, which would drop the new
    // entry from the index.
    for (key, old, values) in updated {
        if let Some(indexed) = shape.indexed
            && old[indexed] != values[indexed]
        {
            let row_id: i64 = conn
                .prepare_cached(&format!(
                    "select rowid from {} where {} = ? and {} = ?",
                    shape.table, shape.session_column, shape.key
                ))?
                .query_row(params![session_id, key], |row| row.get(0))?;
            delete.execute(params![session_id, key])?;
            let mut parameters = vec![
                Value::Integer(row_id),
                Value::Text(session_id.to_owned()),
                Value::Integer(key),
            ];
            parameters.extend(values.iter().cloned());
            parameters.extend(
                shape
                    .inserted_stamps
                    .iter()
                    .map(|_| Value::Text(now.to_owned())),
            );
            conn.prepare_cached(&format!(
                "insert into {} (rowid, {}, {}, {}{}) values (?, ?, ?, {}{})",
                shape.table,
                shape.session_column,
                shape.key,
                shape.columns.join(", "),
                shape
                    .inserted_stamps
                    .iter()
                    .map(|stamp| format!(", {stamp}"))
                    .collect::<String>(),
                vec!["?"; shape.columns.len()].join(", "),
                ", ?".repeat(shape.inserted_stamps.len()),
            ))?
            .execute(params_from_iter(parameters))?;
            changes.push(RowChange {
                old: Some(old),
                new: Some(values.clone()),
            });
            continue;
        }
        let columns: Vec<usize> = (0..shape.columns.len())
            .filter(|column| Some(*column) != shape.indexed || old[*column] != values[*column])
            .collect();
        let assignments: Vec<String> = columns
            .iter()
            .map(|column| format!("{} = ?", shape.columns[*column]))
            .chain(
                shape
                    .updated_stamps
                    .iter()
                    .map(|stamp| format!("{stamp} = ?")),
            )
            .collect();
        let mut parameters: Vec<Value> = columns
            .iter()
            .map(|column| values[*column].clone())
            .collect();
        parameters.extend(
            shape
                .updated_stamps
                .iter()
                .map(|_| Value::Text(now.to_owned())),
        );
        parameters.push(Value::Text(session_id.to_owned()));
        parameters.push(Value::Integer(key));
        conn.prepare_cached(&format!(
            "update {} set {} where {} = ? and {} = ?",
            shape.table,
            assignments.join(", "),
            shape.session_column,
            shape.key
        ))?
        .execute(params_from_iter(parameters))?;
        changes.push(RowChange {
            old: Some(old),
            new: Some(values.clone()),
        });
    }
    let mut insert = conn.prepare_cached(&format!(
        "insert into {} ({}, {}, {}{}) values (?, ?, {}{})",
        shape.table,
        shape.session_column,
        shape.key,
        shape.columns.join(", "),
        shape
            .inserted_stamps
            .iter()
            .map(|stamp| format!(", {stamp}"))
            .collect::<String>(),
        vec!["?"; shape.columns.len()].join(", "),
        ", ?".repeat(shape.inserted_stamps.len()),
    ))?;
    for (key, values) in added {
        let mut parameters = vec![Value::Text(session_id.to_owned()), Value::Integer(key)];
        parameters.extend(values.iter().cloned());
        parameters.extend(
            shape
                .inserted_stamps
                .iter()
                .map(|_| Value::Text(now.to_owned())),
        );
        insert.execute(params_from_iter(parameters))?;
        changes.push(RowChange {
            old: None,
            new: Some(values.clone()),
        });
    }
    Ok(Some(changes))
}

/// The rows one parse writes to a session's child tables, and their
/// digest. The digest is kept in `sessions.content_hash`: the collector is
/// the only writer of these rows, so while the digest matches, the stored
/// rows equal this parse's rows and need not be read back and compared.
/// On a forced reparse nearly every file is unchanged.
struct SessionContent {
    messages: Vec<(i64, Vec<Value>)>,
    /// Tool call columns with the message index where the message id goes;
    /// [`replace_tool_calls`] fills the id in from the stored messages.
    tool_calls: Vec<(i64, Vec<Value>)>,
    usage_events: Vec<(i64, Vec<Value>)>,
    usage_inputs: Vec<(i64, Vec<Value>)>,
    digest: String,
}

impl SessionContent {
    fn build(
        conn: &Connection,
        snapshot: &SessionSnapshot,
        now: &str,
        resolver: &ProjectResolver,
        source_type: SourceType,
    ) -> StoreResult<Self> {
        let messages: Vec<(i64, Vec<Value>)> = snapshot
            .messages
            .iter()
            .map(|message| (message.index, message_values(message)))
            .collect();
        let tool_calls: Vec<(i64, Vec<Value>)> = snapshot
            .tool_calls
            .iter()
            .map(|tool| (tool.tool_index, tool_call_values(tool)))
            .collect();
        let (usage_events, usage_inputs) =
            usage_event_rows(conn, snapshot, now, resolver, source_type)?;
        let digest = content_digest(&[
            ("messages", &messages[..]),
            ("tool_calls", &tool_calls[..]),
            ("usage_events", &usage_events[..]),
            ("usage_event_inputs", &usage_inputs[..]),
        ]);
        Ok(Self {
            messages,
            tool_calls,
            usage_events,
            usage_inputs,
            digest,
        })
    }
}

/// SHA-256 over the tables' rows: each key and each column with its type.
fn content_digest(tables: &[(&str, &[SessionRow])]) -> String {
    use std::fmt::Write as _;
    let mut hasher = Sha256::new();
    for (table, rows) in tables {
        hasher.update(table.as_bytes());
        hasher.update((rows.len() as u64).to_le_bytes());
        for (key, values) in rows.iter() {
            hasher.update(key.to_le_bytes());
            for value in values {
                match value {
                    Value::Null => hasher.update([0u8]),
                    Value::Integer(number) => {
                        hasher.update([1u8]);
                        hasher.update(number.to_le_bytes());
                    }
                    Value::Real(number) => {
                        hasher.update([2u8]);
                        hasher.update(number.to_bits().to_le_bytes());
                    }
                    Value::Text(text) => {
                        hasher.update([3u8]);
                        hasher.update((text.len() as u64).to_le_bytes());
                        hasher.update(text.as_bytes());
                    }
                    Value::Blob(bytes) => {
                        hasher.update([4u8]);
                        hasher.update((bytes.len() as u64).to_le_bytes());
                        hasher.update(bytes);
                    }
                }
            }
        }
    }
    let mut hex = String::with_capacity(64);
    for byte in hasher.finalize().iter() {
        let _ = write!(hex, "{byte:02x}");
    }
    hex
}

fn replace_messages(
    conn: &Connection,
    id: &str,
    rows: &[(i64, Vec<Value>)],
    now: &str,
) -> StoreResult<()> {
    let shape = SessionRows {
        table: "messages",
        session_column: "session_id",
        key: "message_index",
        columns: &MESSAGE_COLUMNS,
        indexed: Some(CONTENT_PLAIN),
        inserted_stamps: &["created_at_db_utc", "updated_at_db_utc"],
        updated_stamps: &["updated_at_db_utc"],
    };
    if sync_session_rows(conn, &shape, id, now, rows)?.is_none() {
        // Unreachable while `(session_id, message_index)` is unique.
        return Err(StoreError::Refused(
            "a session has two messages with the same index".to_owned(),
        ));
    }
    Ok(())
}

fn replace_source_extras(
    conn: &Connection,
    id: &str,
    snapshot: &SessionSnapshot,
    now: &str,
) -> StoreResult<()> {
    match &snapshot.extra {
        Some(extra) if !extra.is_null() => {
            conn.prepare_cached(
                "insert into session_source_extras (session_row_id, extra_json, updated_at_utc)
                 values (?, ?, ?)
                 on conflict(session_row_id) do update set
                   extra_json = excluded.extra_json, updated_at_utc = excluded.updated_at_utc",
            )?
            .execute(params![id, extra.to_string(), now])?;
        }
        _ => {
            conn.prepare_cached("delete from session_source_extras where session_row_id = ?")?
                .execute([id])?;
        }
    }
    Ok(())
}

/// Stores the calls after `replace_messages`. `message_id` links the last
/// message stored before the call's `message_index` (the message that issued
/// it); it is null when the record has no index or no message precedes it.
/// The stored tool call columns a snapshot sets, in this order.
const TOOL_CALL_COLUMNS: [&str; 9] = [
    "message_id",
    "tool_name",
    "status",
    "started_at_utc",
    "finished_at_utc",
    "input_preview",
    "output_preview",
    "output_truncated",
    "error_message",
];
const OUTPUT_PREVIEW: usize = 6;

/// [`TOOL_CALL_COLUMNS`] values, with the message index standing in for the
/// message id.
fn tool_call_values(tool: &ToolCallRecord) -> Vec<Value> {
    let text =
        |value: Option<&str>| value.map_or(Value::Null, |value| Value::Text(value.to_owned()));
    vec![
        tool.message_index.map_or(Value::Null, Value::Integer),
        Value::Text(tool.tool_name.clone()),
        Value::Text(tool.status.clone()),
        text(iso_or_null(tool.started_at_utc.as_deref()).as_deref()),
        text(iso_or_null(tool.finished_at_utc.as_deref()).as_deref()),
        Value::Text(tool.input_preview.clone()),
        Value::Text(tool.output_preview.clone()),
        Value::Integer(i64::from(tool.output_truncated)),
        text(tool.error_message.as_deref()),
    ]
}

fn replace_tool_calls(
    conn: &Connection,
    id: &str,
    snapshot: &SessionSnapshot,
    mut rows: Vec<(i64, Vec<Value>)>,
) -> StoreResult<()> {
    // Each call links to the last stored message before its index; the
    // messages are already in place.
    let messages: Vec<(i64, i64)> = conn
        .prepare_cached(
            "select message_index, id from messages where session_id = ? order by message_index",
        )?
        .query_map([id], |row| Ok((row.get(0)?, row.get(1)?)))?
        .collect::<Result<_, _>>()?;
    for (tool, (_, values)) in snapshot.tool_calls.iter().zip(rows.iter_mut()) {
        // Without an index the old `message_index < null` matched nothing.
        values[0] = tool
            .message_index
            .and_then(|limit| {
                messages
                    .partition_point(|(index, _)| *index < limit)
                    .checked_sub(1)
            })
            .map_or(Value::Null, |position| Value::Integer(messages[position].1));
    }
    let shape = SessionRows {
        table: "tool_calls",
        session_column: "session_id",
        key: "tool_index",
        columns: &TOOL_CALL_COLUMNS,
        indexed: Some(OUTPUT_PREVIEW),
        inserted_stamps: &[],
        updated_stamps: &[],
    };
    if sync_session_rows(conn, &shape, id, "", &rows)?.is_some() {
        return Ok(());
    }
    // Repeated tool indexes cannot be matched row by row: replace them all.
    conn.prepare_cached("delete from tool_calls where session_id = ?")?
        .execute([id])?;
    let mut insert = conn.prepare_cached(&format!(
        "insert into tool_calls (session_id, tool_index, {}) values (?, ?, {})",
        TOOL_CALL_COLUMNS.join(", "),
        vec!["?"; TOOL_CALL_COLUMNS.len()].join(", ")
    ))?;
    for (key, values) in rows {
        let mut parameters = vec![Value::Text(id.to_owned()), Value::Integer(key)];
        parameters.extend(values);
        insert.execute(params_from_iter(parameters))?;
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
/// The stored usage event columns a snapshot sets, in this order.
const USAGE_EVENT_COLUMNS: [&str; 15] = [
    "rollout_ordinal",
    "turn_ordinal",
    "epoch",
    "occurred_at_utc",
    "model",
    "path_context_id",
    "input_tokens",
    "cached_input_tokens",
    "cache_write_input_tokens",
    "output_tokens",
    "reasoning_output_tokens",
    "total_tokens",
    "branch_scope",
    "derivation",
    "event_fingerprint",
];
const OCCURRED_AT: usize = 3;
const MODEL: usize = 4;

const USAGE_INPUT_COLUMNS: [&str; 4] = [
    "provider",
    "request_input_tokens",
    "model_context_window",
    "billable_units_json",
];

/// Daily partitions (`day_utc`, `model_key`) whose usage events changed;
/// `None` when a changed event's day cannot be read the way SQLite's
/// `strftime('%Y-%m-%d', ...)` would, so every partition is rebuilt.
type ChangedPartitions = Option<Vec<DailyPartition>>;

/// A daily usage partition: `day_utc` and `model_key`.
type DailyPartition = (String, String);

/// The session a batch just wrote, and the partitions whose events changed
/// when they are known.
#[derive(Clone, Copy)]
struct WrittenSession<'a> {
    id: &'a str,
    partitions: Option<&'a [DailyPartition]>,
}

/// `strftime('%Y-%m-%d', value)` for the stored ISO-8601 UTC times. `Err`
/// for any other shape.
fn usage_day(value: &Value) -> Result<Option<String>, ()> {
    match value {
        Value::Null => Ok(None),
        Value::Text(text) => {
            let bytes = text.as_bytes();
            let shaped = bytes.len() > 10
                && bytes[..4].iter().all(u8::is_ascii_digit)
                && bytes[4] == b'-'
                && bytes[5..7].iter().all(u8::is_ascii_digit)
                && bytes[7] == b'-'
                && bytes[8..10].iter().all(u8::is_ascii_digit)
                && bytes[10] == b'T'
                && text.ends_with('Z');
            if shaped {
                Ok(Some(text[..10].to_owned()))
            } else {
                Err(())
            }
        }
        _ => Err(()),
    }
}

/// The `usage_events` and `usage_event_inputs` rows of a snapshot.
fn usage_event_rows(
    conn: &Connection,
    snapshot: &SessionSnapshot,
    now: &str,
    resolver: &ProjectResolver,
    source_type: SourceType,
) -> StoreResult<(Vec<SessionRow>, Vec<SessionRow>)> {
    let mut project_ids: HashMap<String, i64> = HashMap::new();
    let mut context_ids: HashMap<(Option<String>, Option<String>), i64> = HashMap::new();
    let text =
        |value: Option<&str>| value.map_or(Value::Null, |value| Value::Text(value.to_owned()));
    let number = |value: Option<i64>| value.map_or(Value::Null, Value::Integer);
    let mut events: Vec<(i64, Vec<Value>)> = Vec::with_capacity(snapshot.usage_events.len());
    let mut inputs: Vec<(i64, Vec<Value>)> = Vec::new();
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
        let mut values = vec![
            number(event.rollout_ordinal),
            number(event.turn_ordinal),
            Value::Integer(event.counter_epoch),
            text(iso_or_null(event.occurred_at_utc.as_deref()).as_deref()),
            text(event.model.as_deref()),
            Value::Integer(context_id),
        ];
        values.extend(buckets.iter().map(|bucket| Value::Integer(*bucket)));
        values.push(Value::Text(event.branch_scope.clone()));
        values.push(Value::Text(event.derivation.clone()));
        values.push(Value::Text(event.event_fingerprint.clone()));
        events.push((event.source_record_ordinal, values));
        let units = event
            .billable_units
            .as_ref()
            .map(|units| serde_json::Value::Object(units.clone()).to_string());
        if event.provider.is_some()
            || event.request_input_tokens.is_some()
            || event.model_context_window.is_some()
            || units.is_some()
        {
            inputs.push((
                event.source_record_ordinal,
                vec![
                    text(event.provider.as_deref()),
                    number(event.request_input_tokens),
                    number(event.model_context_window),
                    text(units.as_deref()),
                ],
            ));
        }
    }
    Ok((events, inputs))
}

fn sync_usage_events(
    conn: &Connection,
    id: &str,
    now: &str,
    events: &[(i64, Vec<Value>)],
    inputs: &[(i64, Vec<Value>)],
) -> StoreResult<ChangedPartitions> {
    let event_shape = SessionRows {
        table: "usage_events",
        session_column: "session_row_id",
        key: "source_record_ordinal",
        columns: &USAGE_EVENT_COLUMNS,
        indexed: None,
        inserted_stamps: &[],
        updated_stamps: &[],
    };
    let input_shape = SessionRows {
        table: "usage_event_inputs",
        session_column: "session_row_id",
        key: "source_record_ordinal",
        columns: &USAGE_INPUT_COLUMNS,
        indexed: None,
        inserted_stamps: &[],
        updated_stamps: &[],
    };
    // Both tables are keyed by (session, ordinal), so keys never repeat.
    let changes = sync_session_rows(conn, &event_shape, id, now, events)?.unwrap_or_default();
    sync_session_rows(conn, &input_shape, id, now, inputs)?;
    let mut partitions: Vec<DailyPartition> = Vec::new();
    for values in changes
        .iter()
        .flat_map(|change| change.old.iter().chain(change.new.iter()))
    {
        let Ok(day) = usage_day(&values[OCCURRED_AT]) else {
            return Ok(None);
        };
        let Some(day) = day else { continue };
        let model = match &values[MODEL] {
            Value::Text(model) => model.clone(),
            _ => String::new(),
        };
        if !partitions.contains(&(day.clone(), model.clone())) {
            partitions.push((day, model));
        }
    }
    Ok(Some(partitions))
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
/// How [`capture_identity_merge`] finds a session's other rows.
#[derive(Clone, Copy)]
enum IdentityLookup<'a> {
    /// Every stored session ID is trimmed, so an exact match through the
    /// `(harness, session_id)` index finds the same rows as `trim(...)`.
    Indexed,
    /// Some stored ID has surrounding spaces: compare every row.
    Scan,
    Planned(&'a [String]),
}

impl IdentityLookup<'_> {
    fn for_batch(conn: &Connection) -> StoreResult<Self> {
        let untrimmed: bool = conn
            .prepare_cached(
                "select exists(select 1 from sessions
                 where session_id <> trim(session_id) or session_id = ''
                   or (session_id is not null and trim(session_id) = ''))",
            )?
            .query_row([], |row| row.get(0))?;
        Ok(if untrimmed { Self::Scan } else { Self::Indexed })
    }
}

fn capture_identity_merge(
    conn: &Connection,
    canonical_id: &str,
    snapshot: &SessionSnapshot,
    lookup: IdentityLookup<'_>,
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
    // Logical lookup/search policy does not establish physical-file equivalence
    // for a NULL-ID fallback. Folded search keys are not alias evidence.
    let case_sensitive = physical_paths_are_case_sensitive(source_type(snapshot));
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
    let path_match = format!(
        "{} in ({placeholders})
                or {} in ({placeholders})
                or {} in ({placeholders})
                or {} in ({placeholders})
                or (id like 'source:%' and source_type = 'windows' and {} in ({placeholders}))
                or (id like 'source-status:%' and source_type = 'windows' and {} in ({placeholders}))",
        column("source_file_path"),
        column("source_file_unc_path"),
        column("display_path"),
        column("platform_path"),
        id_suffix(8),
        id_suffix(15),
    );
    // Both forms select the same rows. The scan form wraps `session_id` in
    // `trim(...)`, which no index covers, so it reads every session; with
    // trimmed IDs each branch uses the key, the `(harness, session_id)`
    // index, or the few rows without a session ID.
    let sql = match lookup {
        IdentityLookup::Planned(_) => "select rowid as session_rowid, * from sessions where id in (select value from json_each(?1))".to_owned(),
        IdentityLookup::Scan => format!(
            "select rowid as session_rowid, * from sessions
         where id = ?1
            or (id <> ?2 and harness = ?3 and (
              trim(coalesce(session_id, '')) = ?4
              or (trim(coalesce(session_id, '')) = '' and source_type = ?5 and (
                {path_match}
              ))
            ))"
        ),
        IdentityLookup::Indexed => format!(
            "select rowid as session_rowid, * from sessions where id = ?1
         union
         select rowid as session_rowid, * from sessions
         where harness = ?3 and session_id = ?4 and id <> ?2
         union
         select rowid as session_rowid, * from sessions
         where session_id is null and id <> ?2 and harness = ?3 and source_type = ?5 and (
                {path_match}
              )"
        ),
    };
    let mut values: Vec<rusqlite::types::Value> = vec![
        canonical_id.to_owned().into(),
        canonical_id.to_owned().into(),
        snapshot.harness.clone().into(),
        stable.to_owned().into(),
        source.environment.clone().into(),
    ];
    for _ in 0..6 {
        values.extend(path_keys.iter().cloned().map(rusqlite::types::Value::from));
    }
    if let IdentityLookup::Planned(ids) = lookup {
        values = vec![
            serde_json::to_string(ids)
                .expect("identity IDs serialize")
                .into(),
        ];
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

/// Returns how many events changed scope.
fn mark_unresolved(conn: &Connection, row_id: &str, status: &str) -> StoreResult<usize> {
    let changed = conn
        .prepare_cached(
            "update usage_events set branch_scope = 'ambiguous'
             where session_row_id = ? and branch_scope <> 'ambiguous'",
        )?
        .execute([row_id])?;
    set_projection_status(conn, row_id, status)?;
    Ok(changed)
}

/// `_reconcileAffectedLegacyUsage`. Returns the session IDs whose daily
/// projections must be rebuilt (the replaced session, then the children
/// whose event scopes changed) and whether the replaced session's own
/// scopes changed.
fn reconcile_affected_legacy_usage(
    conn: &Connection,
    harness: &str,
    replaced_row_id: &str,
    replaced_logical_id: Option<&str>,
) -> StoreResult<(Vec<String>, bool)> {
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
             where harness = ? and (forked_from_id = ? or ((forked_from_id is null or forked_from_id = '') and parent_thread_id = ?))"
        ))?;
        let rows = statement.query_map(params![harness, parent_id, parent_id], |row| {
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
    let parents_for = |conn: &Connection,
                       cache: &mut HashMap<String, Vec<LegacyUsageSession>>,
                       parent: &str|
     -> StoreResult<Vec<(String, i64, String, bool)>> {
        if !cache.contains_key(parent) {
            let mut statement = conn.prepare_cached(&format!(
                "select {LEGACY_COLUMNS} from sessions where session_id = ? and harness = ? order by id"
            ))?;
            let rows = statement
                .query_map([parent, harness], LegacyUsageSession::from_row)?
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

    let mut rescoped: HashSet<String> = HashSet::new();
    for child in &affected {
        if !is_current_parser(harness, child.parser_version) {
            if mark_unresolved(conn, &child.row_id, "legacy_pending")? > 0 {
                rescoped.insert(child.row_id.clone());
            }
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
            if mark_unresolved(conn, &child.row_id, "ambiguous")? > 0 {
                rescoped.insert(child.row_id.clone());
            }
            continue;
        }
        let child_has_usage: bool = conn
            .prepare_cached("select exists(select 1 from usage_events where session_row_id = ?)")?
            .query_row([&child.row_id], |row| row.get(0))?;
        if !child_has_usage {
            if !child.has_aggregate_usage {
                set_projection_status(conn, &child.row_id, "complete")?;
            } else {
                if mark_unresolved(conn, &child.row_id, "ambiguous")? > 0 {
                    rescoped.insert(child.row_id.clone());
                }
            }
            continue;
        }
        let parents = parents_for(conn, &mut parent_cache, &child.parent_logical_id)?;
        if parents.is_empty() {
            if mark_unresolved(conn, &child.row_id, "missing_parent")? > 0 {
                rescoped.insert(child.row_id.clone());
            }
            continue;
        }
        if parents.len() != 1 {
            if mark_unresolved(conn, &child.row_id, "ambiguous")? > 0 {
                rescoped.insert(child.row_id.clone());
            }
            continue;
        }
        let (parent_row, parent_version, parent_status, parent_aggregate) = parents[0].clone();
        if !is_current_parser(harness, parent_version) {
            if mark_unresolved(conn, &child.row_id, "legacy_pending")? > 0 {
                rescoped.insert(child.row_id.clone());
            }
            continue;
        }
        let (parent_has_usage, prefix) = shared_usage_prefix(conn, &parent_row, &child.row_id)?;
        if !parent_has_usage && (parent_status != "complete" || parent_aggregate) {
            if mark_unresolved(conn, &child.row_id, "ambiguous")? > 0 {
                rescoped.insert(child.row_id.clone());
            }
            continue;
        }
        if parent_has_usage && prefix == 0 {
            if mark_unresolved(conn, &child.row_id, "ambiguous")? > 0 {
                rescoped.insert(child.row_id.clone());
            }
            continue;
        }
        // Only rows whose scope differs are written, so a child whose usage
        // is already scoped costs a read of its fingerprints, not a rewrite
        // of its events and a rebuild of its days.
        let changed = if prefix == 0 {
            conn.prepare_cached(
                "update usage_events set branch_scope = 'local'
                 where session_row_id = ? and branch_scope <> 'local'",
            )?
            .execute([&child.row_id])?
        } else {
            let inherited_end: i64 = conn
                .prepare_cached(
                    "select source_record_ordinal from usage_events where session_row_id = ?
                     order by source_record_ordinal limit 1 offset ?",
                )?
                .query_row(params![child.row_id, prefix as i64 - 1], |row| row.get(0))?;
            conn.prepare_cached(
                "update usage_events set branch_scope = case
                   when source_record_ordinal <= ?1 then 'inherited' else 'local' end
                 where session_row_id = ?2 and branch_scope is not (case
                   when source_record_ordinal <= ?1 then 'inherited' else 'local' end)",
            )?
            .execute(params![inherited_end, child.row_id])?
        };
        if changed > 0 {
            rescoped.insert(child.row_id.clone());
        }
        set_projection_status(conn, &child.row_id, "complete")?;
    }
    let mut result = vec![replaced_row_id.to_owned()];
    for session in affected {
        if rescoped.contains(&session.row_id) && !result.contains(&session.row_id) {
            result.push(session.row_id);
        }
    }
    Ok((result, rescoped.contains(replaced_row_id)))
}

/// Whether session `parent_row` has usage events, and how many of its first
/// event fingerprints equal the first of `child_row`'s. Both histories are
/// read side by side only up to the first difference: a parent's history is
/// usually far longer than what a child shares with it.
fn shared_usage_prefix(
    conn: &Connection,
    parent_row: &str,
    child_row: &str,
) -> StoreResult<(bool, usize)> {
    let mut parent_statement = conn.prepare_cached(
        "select event_fingerprint from usage_events as parent_events
         where session_row_id = ? order by source_record_ordinal",
    )?;
    let mut child_statement = conn.prepare_cached(
        "select event_fingerprint from usage_events as child_events
         where session_row_id = ? order by source_record_ordinal",
    )?;
    let mut parent_events = parent_statement.query([parent_row])?;
    let mut child_events = child_statement.query([child_row])?;
    let mut parent_has_usage = false;
    let mut prefix = 0;
    while let Some(parent) = parent_events.next()? {
        parent_has_usage = true;
        let Some(child) = child_events.next()? else {
            break;
        };
        if parent.get_ref(0)? != child.get_ref(0)? {
            break;
        }
        prefix += 1;
    }
    Ok((parent_has_usage, prefix))
}

/// Whether `version` is this collector's parser version for `harness`.
/// Harnesses the viewer does not version are always current.
fn is_current_parser(harness: &str, version: i64) -> bool {
    parser_version_key(harness).is_none_or(|(_, current)| current == version)
}

/// `UsageSummaryRepository.replaceDailyProjectionsInCurrentTransaction` for
/// the active (schema 16+) generation. New rows start with unknown cost; the
/// viewer's pricing maintenance fills in prices from the dirty partitions.
/// Rebuilds the daily usage rows of `session_ids` and marks them for
/// repricing. For `written` (a session and the partitions whose events
/// changed, when known) only those partitions are rebuilt: the others keep
/// their priced rows instead of all waiting for repricing again.
fn replace_daily_projections(
    conn: &Connection,
    session_ids: &[String],
    written: Option<WrittenSession<'_>>,
) -> StoreResult<()> {
    let now = DartDateTime::now().to_iso8601();
    for id in session_ids {
        if let Some(WrittenSession {
            id: written_id,
            partitions: Some(partitions),
        }) = written
            && written_id == id
        {
            replace_daily_partitions(conn, id, partitions, &now)?;
            continue;
        }
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
               null, 'unknown', 'pending_history', ?, ?
             from usage_events where session_row_id = ?
               and strftime('%Y-%m-%d', occurred_at_utc) is not null
             group by session_row_id, strftime('%Y-%m-%d', occurred_at_utc),
               coalesce(model, ''), path_context_id, branch_scope",
        )?
        .execute(params![USAGE_COST_PROJECTION_VERSION, now, id])?;
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

fn replace_daily_partitions(
    conn: &Connection,
    id: &str,
    partitions: &[DailyPartition],
    now: &str,
) -> StoreResult<()> {
    if !partitions.is_empty() {
        let keys = serde_json::to_string(partitions).expect("partition keys serialize");
        let chosen = "exists (select 1 from json_each(?2) j
            where json_extract(j.value, '$[0]') = day_utc
              and json_extract(j.value, '$[1]') = model_key)";
        conn.prepare_cached(&format!(
            "delete from usage_session_daily where session_id = ?1 and {chosen}"
        ))?
        .execute(params![id, keys])?;
        conn.prepare_cached(&format!(
            "insert into usage_session_daily (
               session_id, day_utc, model_key, path_context_id, branch_scope,
               input_tokens, cached_input_tokens, cache_write_input_tokens,
               output_tokens, reasoning_output_tokens, total_tokens, estimated_cost_text,
               cost_status, pricing_resolution_method, cost_projection_version, updated_at_utc)
             select * from (
               select session_row_id, strftime('%Y-%m-%d', occurred_at_utc) as day_utc,
                 coalesce(model, '') as model_key, path_context_id, branch_scope,
                 sum(input_tokens), sum(cached_input_tokens), sum(cache_write_input_tokens),
                 sum(output_tokens), sum(reasoning_output_tokens), sum(input_tokens + output_tokens),
                 null, 'unknown', 'pending_history', ?3, ?4
               from usage_events where session_row_id = ?1
                 and strftime('%Y-%m-%d', occurred_at_utc) is not null
               group by session_row_id, strftime('%Y-%m-%d', occurred_at_utc),
                 coalesce(model, ''), path_context_id, branch_scope
             ) where {chosen}"
        ))?
        .execute(params![id, keys, USAGE_COST_PROJECTION_VERSION, now])?;
        conn.prepare_cached(&format!(
            "insert into usage_cost_dirty_partitions (session_id, day_utc, model_key, reason,
               target_cost_projection_version, created_at_utc, updated_at_utc)
             select distinct session_id, day_utc, model_key, 'usage_ingestion', ?3, ?4, ?4
             from usage_session_daily where session_id = ?1 and {chosen}
             on conflict(session_id, day_utc, model_key) do update set
               target_cost_projection_version = max(usage_cost_dirty_partitions.target_cost_projection_version,
                 excluded.target_cost_projection_version),
               updated_at_utc = excluded.updated_at_utc"
        ))?
        .execute(params![id, keys, USAGE_COST_PROJECTION_VERSION, now])?;
    }
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
    Ok(())
}

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

/// `'source-status:${p.normalize(sourcePath).toLowerCase()}'`, keeping the
/// case where the host's paths are case-sensitive: there, case-variant paths
/// are different files. Windows ids stay lower-case, as existing rows have them.
pub fn source_status_id(source_path: &str) -> String {
    let normalized = normalize_windows_path(source_path);
    if HOST_PATHS_ARE_CASE_SENSITIVE {
        format!("source-status:{normalized}")
    } else {
        format!("source-status:{}", to_lower(&normalized))
    }
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
    apply_source_statuses_versioned(conn, statuses, None)
}

pub(crate) fn apply_source_statuses_versioned(
    conn: &Connection,
    statuses: &[SourceStatus],
    version: Option<u32>,
) -> StoreResult<()> {
    let _phase = super::write_budget::write_phase("statuses");
    let _lease = super::write_lease::WriteLease::acquire(conn)?;
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
    // Last status for each exact (harness,path), matching temp-table replacement.
    let mut unique = BTreeMap::new();
    for (index, status) in ordered.into_iter().enumerate() {
        unique.insert(
            (status.harness.clone(), status.path.clone()),
            (index, status),
        );
    }
    let now = DartDateTime::now().to_iso8601();
    super::write_budget::write_planned(
        conn,
        "statuses",
        500,
        || {
            // One membership map over both physical path columns. Never run the
            // correlated anti-join under BEGIN IMMEDIATE (CXV-180).
            type Stored = (i64, String, Option<String>, Option<String>, Option<String>);
            let mut members: HashMap<(String, String), Vec<Stored>> = HashMap::new();
            let mut statement = conn.prepare("select id,harness,source_file_path,source_file_unc_path,scan_status,source_state,parse_status,rowid from sessions order by rowid")?;
            let mut rows = statement.query([])?;
            while let Some(row) = rows.next()? {
                let harness: String = row.get(1)?;
                let stored = (
                    row.get(7)?,
                    row.get(0)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                );
                for path in [row.get::<_, Option<String>>(2)?, row.get(3)?]
                    .into_iter()
                    .flatten()
                    .collect::<HashSet<_>>()
                {
                    members
                        .entry((harness.clone(), path))
                        .or_default()
                        .push(stored.clone());
                }
            }
            let mut changes = BTreeMap::new();
            let mut placeholders = Vec::new();
            for (key, (index, status)) in &unique {
                match members.get(key) {
                    Some(rows) => {
                        for (rowid, id, scan, state, parse) in rows {
                            if scan.as_deref() != Some(&status.status)
                                || state.as_deref() != Some(&status.state)
                                || (status.status == "parse_error"
                                    && parse.as_deref() != Some("parse_error"))
                            {
                                changes.insert(
                                    *rowid,
                                    (id.clone(), (*status).clone(), Some(false), None),
                                );
                            }
                        }
                    }
                    None if !matches!(
                        status.status.as_str(),
                        "available" | "missing" | "path_unreachable"
                    ) =>
                    {
                        let id = placeholder_id(&status.harness, &status.path);
                        placeholders.push((*index, (id, (*status).clone(), Some(true), None)));
                    }
                    None => {}
                }
            }
            let mut units: Vec<_> = changes.into_values().collect();
            // Base UPDATE FROM applies existing rows in table/rowid order.
            // Its later temp-table scan inserts missing placeholders in last
            // INSERT OR REPLACE order, which need not be ID or harness order.
            // Rowids order the plan only; writes still use stable primary IDs.
            placeholders.sort_by_key(|(index, _)| *index);
            units.extend(placeholders.into_iter().map(|(_, unit)| unit));
            // Local status priority and hub delivery order are different base
            // contracts. Deliver original inputs, independently of local work.
            if hub_client::queue_enabled(conn)? {
                let pending: Vec<_> = statuses.iter().collect();
                let records: Vec<_> = pending
                    .iter()
                    .map(|status| Record::SourceStatus((*status).clone()))
                    .collect();
                let delivery = hub_client::plan_delivery(conn, &records, version)?;
                for (status, deliver) in pending.into_iter().zip(delivery) {
                    if deliver {
                        units.push((String::new(), status.clone(), None, Some(true)));
                    }
                }
            }
            Ok(units)
        },
        |(id, status, placeholder, delivery)| {
            if placeholder == Some(true) {
                conn.prepare_cached("insert into sessions (id,source_type,source_file_path,display_path,platform_path,
                scan_status,source_state,parse_status,created_at_utc,updated_at_utc,last_scanned_utc,harness)
                values (?1,?2,?3,?3,?3,?4,?5,?6,?7,?7,?7,?8)
                on conflict(id) do update set scan_status=excluded.scan_status,source_state=excluded.source_state,
                    updated_at_utc=excluded.updated_at_utc,last_scanned_utc=excluded.last_scanned_utc
                where sessions.scan_status is not excluded.scan_status or sessions.source_state is not excluded.source_state")?
                .execute(params![id,status.environment.as_deref().unwrap_or_else(|| source_type_label(&status.path)),status.path,
                    status.status,status.state,if status.status == "parse_error" {"parse_error"} else {"available"},now,status.harness])?;
            } else if placeholder == Some(false) {
                conn.prepare_cached(
                    "update sessions set scan_status=?1,source_state=?2,
                parse_status=case when ?1='parse_error' then 'parse_error' else parse_status end,
                updated_at_utc=case when ?1='available' then updated_at_utc else ?3 end,
                last_scanned_utc=case when ?1='available' then last_scanned_utc else ?3 end
                where id=?4 and harness=?5 and (source_file_path=?6 or source_file_unc_path=?6)
                    and (scan_status is not ?1 or source_state is not ?2
                    or (?1='parse_error' and parse_status is not 'parse_error'))",
                )?
                .execute(params![
                    status.status,
                    status.state,
                    now,
                    id,
                    status.harness,
                    status.path
                ])?;
            }
            if delivery.is_some() {
                enqueue_for_version(conn, Record::SourceStatus(status), &now, version)?;
            }
            Ok(())
        },
    )
}

/// `_applySessionIndexThreadNames`.
pub fn apply_thread_names(conn: &Connection, names: &[ThreadName]) -> StoreResult<usize> {
    apply_thread_names_versioned(conn, names, None)
}

pub(crate) fn apply_thread_names_versioned(
    conn: &Connection,
    names: &[ThreadName],
    version: Option<u32>,
) -> StoreResult<usize> {
    let _phase = super::write_budget::write_phase("thread_names");
    let _lease = super::write_lease::WriteLease::acquire(conn)?;
    if names.is_empty() {
        return Ok(0);
    }
    let now = DartDateTime::now().to_iso8601();
    let changed = std::cell::RefCell::new(HashSet::new());
    super::write_budget::write_planned(
        conn,
        "thread_names",
        500,
        || {
            let pending: Vec<_> = names
                .iter()
                .filter(|entry| !trim(&entry.thread_name).is_empty())
                .collect();
            let records: Vec<_> = pending
                .iter()
                .map(|entry| Record::ThreadName((*entry).clone()))
                .collect();
            let delivery = hub_client::plan_delivery(conn, &records, version)?;
            let mut predicted = HashMap::new();
            let mut units = Vec::new();
            for (entry, deliver) in pending.into_iter().zip(delivery) {
                let name = trim(&entry.thread_name);
                let rows: Vec<(String, Option<String>)> = conn.prepare_cached("select id,thread_name from sessions where session_id=? and harness=? order by rowid")?
                    .query_map(params![entry.session_id,entry.harness], |row| Ok((row.get(0)?, row.get(1)?)))?.collect::<Result<_,_>>()?;
                for (id, current) in rows {
                    let previous = predicted.entry(id.clone()).or_insert(current);
                    if previous.as_deref().unwrap_or("") != name {
                        *previous = Some(name.to_owned());
                        units.push((Some(id), entry.clone()));
                    }
                }
                if deliver {
                    units.push((None, entry.clone()));
                }
            }
            Ok(units)
        },
        |(id, entry)| {
            if let Some(id) = id {
                let count = conn.prepare_cached("update sessions set thread_name=?1 where id=?2 and harness=?3 and session_id=?4 and coalesce(thread_name,'')<>?1")?
                    .execute(params![trim(&entry.thread_name),id,entry.harness,entry.session_id])?;
                if count > 0 {
                    changed.borrow_mut().insert(id);
                }
            } else {
                enqueue_for_version(conn, Record::ThreadName(entry), &now, version)?;
            }
            Ok(())
        },
    )?;
    Ok(changed.into_inner().len())
}

/// The project name a resolver already found for a stored WSL session whose
/// working directory is still `working_directory`, so a reingest can keep it
/// without asking WSL again. `None` for a folder-name fallback (`project_refined
/// = 0`), which must be resolved again.
pub fn stored_refined_project(
    conn: &Connection,
    session: &SessionRef,
    harness: &str,
    working_directory: &str,
) -> StoreResult<Option<String>> {
    let id = session_row_id(harness, session.session_id.as_deref(), &session.source_path);
    Ok(conn
        .prepare_cached(
            "select p.name from sessions s join projects p on p.id = s.detected_project_id
             where s.id = ? and s.source_type = 'wsl' and s.project_refined = 1
               and s.working_directory_display = ?",
        )?
        .query_row(params![id, working_directory], |row| {
            row.get::<_, String>(0)
        })
        .optional()?
        .filter(|name| !trim(name).is_empty()))
}

/// `_applyResolvedProjectsForParsedCandidates`: re-resolve the detected
/// project of the listed sessions with names found on the source machine.
pub fn apply_project_hints(
    conn: &Connection,
    harness: &str,
    sessions: &[SessionRef],
    hints: &[ProjectHint],
) -> StoreResult<usize> {
    apply_project_hints_versioned(conn, harness, sessions, hints, None)
}

pub(crate) fn apply_project_hints_versioned(
    conn: &Connection,
    harness: &str,
    sessions: &[SessionRef],
    hints: &[ProjectHint],
    version: Option<u32>,
) -> StoreResult<usize> {
    let _phase = super::write_budget::write_phase("project_hints");
    let _lease = super::write_lease::WriteLease::acquire(conn)?;
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
    let now = DartDateTime::now().to_iso8601();
    let mut changed = 0;
    super::write_budget::write_planned(
        conn,
        "project_hints",
        250,
        || {
            let mut rows = Vec::new();
            // Base discovers rows via IN lookups in each 500-reference group,
            // rather than applying them in reference input order (F7 audit).
            // Keep that query order while retaining the original hub packet.
            let mut ordered_ids = Vec::new();
            for chunk in ids.chunks(500) {
                let placeholders = vec!["?"; chunk.len()].join(", ");
                ordered_ids.extend(conn.prepare(&format!(
                    "select id, working_directory_display, source_type from sessions where id in ({placeholders})"
                ))?.query_map(params_from_iter(chunk.iter()), |row| row.get::<_,String>(0))?
                    .collect::<Result<Vec<_>,_>>()?);
            }
            for id in &ordered_ids {
                type CurrentProject = (
                    Option<String>,
                    String,
                    Option<String>,
                    bool,
                    bool,
                    Option<String>,
                );
                let current: Option<CurrentProject> = conn.prepare_cached(
                "select s.working_directory_display,s.source_type,p.name,s.project_refined,coalesce(s.project_override,0),s.project_name_snapshot from sessions s
                 left join projects p on p.id=s.detected_project_id where s.id=?")?
                .query_row([id], |row| Ok((row.get(0)?,row.get(1)?,row.get(2)?,row.get(3)?,row.get(4)?,row.get(5)?))).optional()?;
                let Some((directory, environment, current, refined, manual, displayed)) = current
                else {
                    continue;
                };
                let source_type =
                    SourceType::from_wire(&environment).unwrap_or(SourceType::Windows);
                if let Some((name, new_refined)) =
                    resolver.resolve_marked(directory.as_deref(), source_type)
                {
                    let name = trim(&name).to_owned();
                    if !name.is_empty()
                        && (current.as_deref() != Some(&name)
                            || refined != new_refined
                            || (!manual && displayed.as_deref() != Some(&name)))
                    {
                        rows.push(Some((
                            id.clone(),
                            directory,
                            environment,
                            name,
                            new_refined,
                        )));
                    }
                }
            }
            if hub_client::queue_enabled(conn)? {
                // Preserve the original whole packet, including absent refs,
                // duplicates, unresolved hints and their order (CXV-180 F1).
                // Delivery is its own bounded unit, even with no local changes.
                rows.push(None);
            }
            Ok(rows)
        },
        |unit| {
            let Some((id, directory, environment, name, refined)) = unit else {
                enqueue_for_version(
                    conn,
                    Record::ProjectHints(ProjectHints {
                        harness: harness.to_owned(),
                        sessions: sessions.to_vec(),
                        hints: hints.to_vec(),
                    }),
                    &now,
                    version,
                )?;
                return Ok(());
            };
            // A hint planned solely for an automatic display refresh may have
            // become a no-op after a viewer override. Check before even the
            // project upsert (which also changes its clock/sequence).
            let eligible: bool = conn.prepare_cached("select exists(select 1 from sessions s
                left join projects p on p.id=s.detected_project_id
                where s.id=?1 and s.working_directory_display is ?2 and s.source_type=?3
                    and (p.name collate binary is not ?4 or coalesce(s.project_refined,0)<>?5
                        or (coalesce(s.project_override,0)=0 and s.project_name_snapshot collate binary is not ?4)))")?
                .query_row(params![id,directory,environment,name,refined], |row| row.get(0))?;
            if !eligible {
                return Ok(());
            }
            let project_id = upsert_auto_project(conn, &name, &now)?;
            let count = conn.prepare_cached("update sessions set detected_project_id=?1,project_refined=?2,updated_at_utc=?3
            where id=?4 and working_directory_display is ?5 and source_type=?6
                and (detected_project_id is not ?1 or project_refined is not ?2 or (coalesce(project_override,0)=0 and project_name_snapshot is not ?7))")?
            .execute(params![project_id,refined,now,id,directory,environment,name])?;
            if count > 0 {
                refresh_session_project(conn, &id)?;
                changed += 1;
            }
            Ok(())
        },
    )?;
    Ok(changed)
}

/// A stored session without an automatic project.
pub struct ProjectBackfillCandidate {
    pub id: String,
    pub working_directory: String,
    pub source_type: SourceType,
}

const PROJECT_BACKFILL_CANDIDATES: &str = "select id, working_directory_display, source_type
     from sessions
     where (detected_project_id is null
         or (coalesce(project_override, 0) = 0 and coalesce(trim(project_name_snapshot), '') = ''))
       and coalesce(trim(working_directory_display), '') <> ''
       and parse_status = 'available' and scan_status = 'available'
     order by id";

/// Sessions of any harness that `apply_project_backfill` would assign.
pub fn project_backfill_candidates(
    conn: &Connection,
) -> StoreResult<Vec<ProjectBackfillCandidate>> {
    let mut statement = conn.prepare(PROJECT_BACKFILL_CANDIDATES)?;
    let rows = statement
        .query_map([], |row| {
            Ok(ProjectBackfillCandidate {
                id: row.get(0)?,
                working_directory: row.get::<_, Option<String>>(1)?.unwrap_or_default(),
                source_type: row
                    .get::<_, Option<String>>(2)?
                    .as_deref()
                    .and_then(SourceType::from_wire)
                    .unwrap_or(SourceType::Windows),
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}

/// `_backfillAutomaticProjects`: assign an automatic project to every
/// candidate, preferring names resolved on this machine. Candidate predicates
/// are checked again by indexed ID under the write lock.
pub fn apply_project_backfill(conn: &Connection, hints: &[ProjectHint]) -> StoreResult<usize> {
    let _phase = super::write_budget::write_phase("project_backfill");
    let _lease = super::write_lease::WriteLease::acquire(conn)?;
    let resolver = ProjectResolver::new(
        hints
            .iter()
            .map(|hint| (hint.working_directory.clone(), hint.project_name.clone())),
    );
    let now = DartDateTime::now().to_iso8601();
    let mut updated = 0;
    super::write_budget::write_planned(
        conn,
        "project_backfill",
        250,
        || {
            let mut units = Vec::new();
            for candidate in project_backfill_candidates(conn)? {
                if let Some((name, refined)) = resolver
                    .resolve_marked(Some(&candidate.working_directory), candidate.source_type)
                {
                    let name = trim(&name).to_owned();
                    if !name.is_empty() {
                        units.push((candidate, name, refined));
                    }
                }
            }
            Ok(units)
        },
        |(candidate, name, refined)| {
            // The viewer may have removed a pending row from candidacy. Guard
            // every effect, including creating/updating the project (F8).
            let eligible: bool = conn.prepare_cached("select exists(select 1 from sessions
                where id=?1 and working_directory_display=?2 and source_type=?3
                    and (detected_project_id is null or (coalesce(project_override,0)=0 and coalesce(trim(project_name_snapshot),'')=''))
                    and parse_status='available' and scan_status='available')")?
                .query_row(params![candidate.id,candidate.working_directory,candidate.source_type.wire_name()], |row| row.get(0))?;
            if !eligible {
                return Ok(());
            }
            let project = upsert_auto_project(conn, &name, &now)?;
            let count = conn.prepare_cached("update sessions set detected_project_id=?1,project_refined=?2,updated_at_utc=?3
            where id=?4 and working_directory_display=?5 and source_type=?6
                and (detected_project_id is null or (coalesce(project_override,0)=0 and coalesce(trim(project_name_snapshot),'')=''))
                and parse_status='available' and scan_status='available'")?
            .execute(params![project,refined,now,candidate.id,candidate.working_directory,candidate.source_type.wire_name()])?;
            if count > 0 {
                refresh_session_project(conn, &candidate.id)?;
                updated += 1;
            }
            Ok(())
        },
    )?;
    Ok(updated)
}

/// Sessions whose title or summary is a placeholder older viewers stored.
pub fn session_metadata_placeholder_count(conn: &Connection) -> StoreResult<i64> {
    Ok(conn.query_row(
        "select count(*) from sessions
         where lower(trim(coalesce(title, ''))) like '# agents.md%'
            or lower(trim(coalesce(summary, ''))) = 'auto'",
        [],
        |row| row.get(0),
    )?)
}

/// `_cleanSessionMetadataPlaceholders`.
pub fn clean_session_metadata_placeholders(conn: &Connection) -> StoreResult<()> {
    let _phase = super::write_budget::write_phase("metadata_placeholders");
    let _lease = super::write_lease::WriteLease::acquire(conn)?;
    super::write_budget::write_planned(
        conn,
        "metadata_placeholders",
        500,
        || {
            Ok(conn.prepare("select id from sessions where lower(trim(coalesce(title,''))) like '# agents.md%' or lower(trim(coalesce(summary,'')))='auto'")?
            .query_map([],|row|row.get::<_,String>(0))?.collect::<Result<_,_>>()?)
        },
        |id| {
            let row: Option<(i64,bool,bool)> = conn.prepare_cached("select rowid,lower(trim(coalesce(title,''))) like '# agents.md%',lower(trim(coalesce(summary,'')))='auto' from sessions where id=?")?
            .query_row([&id], |row|Ok((row.get(0)?,row.get(1)?,row.get(2)?))).optional()?;
            if let Some((rowid, bad_title, bad_summary)) = row
                && (bad_title || bad_summary)
            {
                conn.prepare_cached("update sessions set title=case when ?1 then null else title end,summary=case when ?2 then null else summary end where id=?3")?
                    .execute(params![bad_title,bad_summary,id])?;
                conn.prepare_cached("update session_search set title=case when ?1 then '' else title end,summary=case when ?2 then '' else summary end where rowid=?3")?
                    .execute(params![bad_title,bad_summary,rowid])?;
            }
            Ok(())
        },
    )
}

/// Cached invalidation metadata for the scanner's skip decisions.
#[derive(Clone, Debug)]
pub struct CachedSource {
    pub source_path: String,
    pub unc_path: Option<String>,
    pub source_type: SourceType,
    pub scan_status: String,
    pub source_state: String,
    pub file_size: Option<i64>,
    pub modified_utc: Option<DartDateTime>,
    pub parser_version: Option<i64>,
}

/// Written after a scan that listed every configured root and was not
/// cancelled: every reachable session file has been parsed with this parser
/// version, so a row still on an older one is outside the scanned roots or
/// unreadable, and the viewer need not wait for it.
pub const COMPLETE_CODEX_SCAN_KEY: &str = "codex_scan.completed_parser_version";

pub fn record_complete_codex_scan(conn: &Connection) -> StoreResult<()> {
    let _phase = super::write_budget::write_phase("scan_complete");
    let _lease = super::write_lease::WriteLease::acquire(conn)?;
    if super::schema::metadata(conn, COMPLETE_CODEX_SCAN_KEY)?.as_deref()
        == Some(crate::codex::parser::PARSER_VERSION.to_string().as_str())
    {
        return Ok(());
    }
    begin_write(conn)?;
    let result = (|| {
        conn.execute(
        "insert into app_metadata (key, value, updated_at_utc) values (?, ?, ?)
         on conflict(key) do update set value = excluded.value, updated_at_utc = excluded.updated_at_utc
         where value is not excluded.value",
        params![
            COMPLETE_CODEX_SCAN_KEY,
            crate::codex::parser::PARSER_VERSION.to_string(),
            DartDateTime::now().to_iso8601()
        ],
    )?;
        Ok(())
    })();
    finish(conn, result)
}

/// `_cachedSessions`, limited to one harness.
pub fn cached_sources(conn: &Connection, harness: &str) -> StoreResult<Vec<CachedSource>> {
    let mut statement = conn.prepare(
        "select source_file_path, source_file_unc_path, scan_status, file_size, modified_utc, parser_version, source_type, source_state
         from sessions where harness = ?",
    )?;
    let rows = statement
        .query_map([harness], |row| {
            Ok(CachedSource {
                source_path: row.get(0)?,
                unc_path: row.get(1)?,
                source_type: row
                    .get::<_, Option<String>>(6)?
                    .as_deref()
                    .and_then(SourceType::from_wire)
                    .unwrap_or(SourceType::Windows),
                scan_status: row
                    .get::<_, Option<String>>(2)?
                    .unwrap_or_else(|| "available".to_owned()),
                file_size: row.get(3)?,
                modified_utc: parse_time(row.get::<_, Option<String>>(4)?.as_deref()),
                parser_version: row.get(5)?,
                source_state: row.get(7)?,
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}

fn enqueue_for_version(
    conn: &Connection,
    record: Record,
    now: &str,
    version: Option<u32>,
) -> StoreResult<()> {
    match version {
        Some(version) => hub_client::enqueue_versioned(conn, record, now, version),
        None => hub_client::enqueue(conn, record, now),
    }
}
