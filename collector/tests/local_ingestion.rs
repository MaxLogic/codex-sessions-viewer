//! Local ingestion proof for the Codex collector (T-119).
//!
//! Every test uses isolated temporary folders and databases. Tests that need
//! a viewer database build one from the same SQL files the viewer applies and
//! record the viewer as owner; `app/test/app/collector_ingestion_compat_test.dart`
//! additionally proves the viewer's production reads against databases the
//! collector wrote.
#![recursion_limit = "256"]

mod support;

use std::path::Path;

use codex_sessions_collector::codex::parser::{ParserOptions, Usage, parse_file};
use codex_sessions_collector::contract::{self, Envelope, Record};
use rusqlite::Connection;
use serde_json::{Value, json};

use support::{TempDir, collector, viewer_database};

// ---------------------------------------------------------------------------
// Parser goldens
//
// `samples/collector-parity/expected` holds the collector's normalized parser
// output for every fixture in `samples/collector-parity/sessions`. The goldens
// started as the retired Dart parser's output; the collector owns them now.
// After an intended parser change, regenerate them with
// `CODEX_PARITY_UPDATE=1 cargo test --test local_ingestion parser_output`,
// review the diff, and bump `PARSER_VERSION` when stored rows change.

fn usage_view(usage: &Usage) -> Value {
    json!({
        "input_tokens": usage.input_tokens,
        "cached_input_tokens": usage.cached_input_tokens,
        "cache_write_input_tokens": usage.cache_write_input_tokens,
        "output_tokens": usage.output_tokens,
        "reasoning_output_tokens": usage.reasoning_output_tokens,
        "total_tokens": usage.total_tokens(),
        "is_empty": usage.is_empty(),
    })
}

fn time(value: Option<codex_sessions_collector::dart::DartDateTime>) -> Value {
    value.map_or(Value::Null, |value| Value::String(value.to_iso8601()))
}

/// The normalized view of one parsed file that the goldens record.
fn parity_view(path: &str) -> Value {
    let result = parse_file(path, ParserOptions::default());
    let session = match result {
        Err(error) => {
            let kind = match error.kind {
                codex_sessions_collector::codex::parser::ParseErrorKind::MalformedJson => {
                    "malformedJson"
                }
                codex_sessions_collector::codex::parser::ParseErrorKind::UnsupportedRoot => {
                    "unsupportedRoot"
                }
                codex_sessions_collector::codex::parser::ParseErrorKind::Io => "io",
            };
            return json!({"error": {"kind": kind, "line": error.line}});
        }
        Ok(success) => success.session,
    };
    json!({
        "internal_id": session.internal_id,
        "session_id": session.session_id,
        "thread_name": session.thread_name,
        "thread_source": session.thread_source,
        "parent_thread_id": session.parent_thread_id,
        "forked_from_id": session.forked_from_id,
        "history_base_thread_id": session.history_base_thread_id,
        "history_base_end_ordinal_exclusive": session.history_base_end_ordinal_exclusive,
        "history_base_end_byte_offset": session.history_base_end_byte_offset,
        "subagent_history_start_ordinal": session.subagent_history_start_ordinal,
        "usage_projection_status": session.usage_projection_status,
        "agent_nickname": session.agent_nickname,
        "agent_role": session.agent_role,
        "subagent_depth": session.subagent_depth,
        "source_type": session.source_type.wire_name(),
        "source_path": session.source_path,
        "source_file_unc_path": session.source_file_unc_path,
        "display_path": session.display_path,
        "platform_path": session.platform_path,
        "working_directory_display": session.working_directory_display,
        "working_directory_platform": session.working_directory_platform,
        "working_directory_unc": session.working_directory_unc,
        "title": session.title,
        "summary": session.summary,
        "started_at_utc": time(session.started_at_utc),
        "last_message_at_utc": time(session.last_message_at_utc),
        "model_ids": session.model_ids,
        "usage": usage_view(&session.usage),
        "last_turn_usage": usage_view(&session.last_turn_usage),
        "messages": session.messages.iter().map(|message| json!({
            "index": message.index,
            "author_type": message.author_type.name(),
            "raw_type": message.raw_type,
            "created_at_utc": time(message.created_at_utc),
            "first_line": message.first_line,
            "content_plain": message.content_plain,
            "content_preview": message.content_preview,
            "content_truncated": message.content_truncated,
            "usage": usage_view(&message.usage),
            "model": message.model,
            "has_tool_calls": message.has_tool_calls,
            "has_error": message.has_error,
        })).collect::<Vec<_>>(),
        "tool_calls": session.tool_calls.iter().map(|tool| json!({
            "message_index": tool.message_index,
            "tool_index": tool.tool_index,
            "tool_name": tool.tool_name,
            "status": tool.status,
            "started_at_utc": time(tool.started_at_utc),
            "finished_at_utc": time(tool.finished_at_utc),
            "input_preview": tool.input_preview,
            "output_preview": tool.output_preview,
            "output_truncated": tool.output_truncated,
            "error_message": tool.error_message,
        })).collect::<Vec<_>>(),
        "usage_events": session.usage_events.iter().map(|event| json!({
            "source_record_ordinal": event.source_record_ordinal,
            "rollout_ordinal": event.rollout_ordinal,
            "turn_ordinal": event.turn_ordinal,
            "counter_epoch": event.counter_epoch,
            "occurred_at_utc": time(event.occurred_at_utc),
            "model": event.model,
            "working_directory": event.working_directory,
            "working_directory_unc": event.working_directory_unc,
            "usage": usage_view(&event.usage),
            "derivation": event.derivation,
            "branch_scope": event.branch_scope,
            "cumulative_usage": usage_view(&event.cumulative_usage),
            "event_fingerprint": event.event_fingerprint,
            "provider": event.provider,
            "request_input_tokens": event.request_input_tokens,
            "model_context_window": event.model_context_window,
        })).collect::<Vec<_>>(),
        "warnings": session.warnings.iter().map(|warning| json!({
            "code": warning.code,
            "record_type": warning.record_type,
            "payload_type": warning.payload_type,
            "message": warning.message,
        })).collect::<Vec<_>>(),
    })
}

fn first_difference(path: &str, expected: &Value, actual: &Value) -> Option<String> {
    match (expected, actual) {
        (Value::Object(left), Value::Object(right)) => {
            for (key, value) in left {
                let other = right.get(key).unwrap_or(&Value::Null);
                if let Some(found) = first_difference(&format!("{path}.{key}"), value, other) {
                    return Some(found);
                }
            }
            right
                .keys()
                .find(|key| !left.contains_key(*key))
                .map(|key| format!("{path}.{key}: unexpected key"))
        }
        (Value::Array(left), Value::Array(right)) => {
            for (index, (value, other)) in left.iter().zip(right).enumerate() {
                if let Some(found) = first_difference(&format!("{path}[{index}]"), value, other) {
                    return Some(found);
                }
            }
            (left.len() != right.len())
                .then(|| format!("{path}: length {} != {}", left.len(), right.len()))
        }
        _ => (expected != actual).then(|| format!("{path}: expected {expected}, got {actual}")),
    }
}

#[test]
fn normalized_parser_output_matches_the_goldens() {
    let update = std::env::var("CODEX_PARITY_UPDATE").is_ok_and(|value| value == "1");
    let sessions = Path::new("../samples/collector-parity/sessions");
    let mut names: Vec<String> = std::fs::read_dir(sessions)
        .expect("parity fixtures")
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert!(
        names.len() >= 10,
        "expected the parity fixture set, found {names:?}"
    );
    let mut failures = Vec::new();
    for name in &names {
        // IDs derived from the path depend on this relative form.
        let path = format!("../samples/collector-parity/sessions/{name}");
        let golden_path = format!("../samples/collector-parity/expected/{name}.json");
        let actual = parity_view(&path);
        if update {
            let text = serde_json::to_string_pretty(&actual).unwrap();
            std::fs::write(&golden_path, format!("{text}\n")).unwrap();
            continue;
        }
        let golden: Value = serde_json::from_str(
            &std::fs::read_to_string(&golden_path)
                .unwrap_or_else(|error| panic!("{golden_path}: {error}")),
        )
        .unwrap();
        if let Some(difference) = first_difference(name, &golden, &actual) {
            failures.push(difference);
        }
    }
    assert!(
        failures.is_empty(),
        "parity differences:\n{}",
        failures.join("\n")
    );
}

// ---------------------------------------------------------------------------
// Separate-process ingestion into a viewer database

fn count(conn: &Connection, sql: &str) -> i64 {
    conn.query_row(sql, [], |row| row.get(0)).unwrap()
}

#[test]
fn writer_versions_refuse_mismatched_or_missing_viewer_metadata_without_writes() {
    for key in [
        "writer_codex_parser_version",
        "writer_usage_cost_projection_version",
    ] {
        for recorded in [Some("999"), None] {
            let temp = TempDir::new("writer-version-refusal");
            let db = viewer_database(&temp);
            let conn = open(&db);
            conn.execute("delete from app_metadata where key = ?", [key])
                .unwrap();
            if let Some(value) = recorded {
                conn.execute(
                    "insert into app_metadata(key,value,updated_at_utc) values (?,?,'now')",
                    [key, value],
                )
                .unwrap();
            }
            let before = support::content_snapshot(&db);
            let input = temp.path().join("record.jsonl");
            std::fs::write(
                &input,
                serde_json::to_string(&Envelope::new(Record::SessionSnapshot(Box::new(
                    support::sample_snapshot("must-not-write"),
                ))))
                .unwrap(),
            )
            .unwrap();
            let output = collector()
                .args(["apply", "--db"])
                .arg(&db)
                .arg("--input")
                .arg(&input)
                .output()
                .unwrap();
            let error = refused(&output);
            assert!(
                error.contains("parser") && error.contains("projection"),
                "{error}"
            );
            assert!(
                error.contains("collector") && error.contains("viewer"),
                "{error}"
            );
            assert!(error.contains(recorded.unwrap_or("missing")), "{error}");
            support::assert_same(&before, &support::content_snapshot(&db));
            assert_eq!(count(&conn, "select count(*) from scan_runs"), 0);
            assert_eq!(count(&conn, "select count(*) from sessions"), 0);
        }
    }
}

#[test]
fn writer_versions_are_rechecked_under_the_write_lock_between_batches() {
    use codex_sessions_collector::store::{OwnerMode, Store, StoreError};
    let temp = TempDir::new("writer-version-mid-scan");
    let db = viewer_database(&temp);
    let store = Store::open(&db, OwnerMode::Viewer).unwrap();
    let conn = open(&db);
    conn.execute("insert into app_metadata(key,value,updated_at_utc) values ('writer_codex_parser_version','999','now') on conflict(key) do update set value=excluded.value", []).unwrap();
    let result = store.apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
        support::sample_snapshot("later"),
    )))]);
    assert!(matches!(result, Err(StoreError::Refused(_))), "{result:?}");
    assert!(
        store.conn.is_autocommit(),
        "failed version guard must roll back"
    );
    assert_eq!(count(&conn, "select count(*) from sessions"), 0);
}

fn open(path: &Path) -> Connection {
    let conn = Connection::open(path).unwrap();
    conn.busy_timeout(std::time::Duration::from_secs(30))
        .unwrap();
    conn.pragma_update(None, "foreign_keys", "on").unwrap();
    conn
}

#[test]
fn separate_process_scan_ingests_codex_history_with_the_viewer_closed() {
    let temp = TempDir::new("scan");
    let home = support::codex_home(
        &temp,
        &[
            "rich_session.jsonl",
            "subagent_session.jsonl",
            "no_session_id.jsonl",
        ],
    );
    std::fs::write(home.join("sessions").join("notes.txt"), "not a session").unwrap();
    let db = viewer_database(&temp);
    let output = collector()
        .args(["codex", "scan", "--json", "--no-wsl-projects", "--db"])
        .arg(&db)
        .args(["--windows-root"])
        .arg(&home)
        .args(["--wsl-root", ""])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["files_parsed"], 3);
    assert_eq!(report["sessions_written"], 3);
    let conn = open(&db);
    assert_eq!(
        count(
            &conn,
            "select count(*) from sessions where parse_status = 'available' and session_id is not null"
        ),
        2
    );
    assert_eq!(
        count(
            &conn,
            "select count(*) from sessions where id like 'source:%'"
        ),
        1
    );
    assert_eq!(
        count(
            &conn,
            "select count(*) from messages where session_id = 'session:parity-rich-001'"
        ),
        13
    );
    assert_eq!(
        count(
            &conn,
            "select count(*) from usage_events where session_row_id = 'session:parity-rich-001'"
        ),
        9
    );
    assert_eq!(
        count(
            &conn,
            "select count(distinct day_utc || '|' || model_key) from usage_session_daily where session_id = 'session:parity-rich-001'"
        ),
        count(
            &conn,
            "select count(*) from usage_cost_dirty_partitions where session_id = 'session:parity-rich-001'"
        )
    );
    assert!(count(&conn, "select count(*) from usage_cost_dirty_partitions") > 0);
    assert_eq!(
        count(
            &conn,
            "select count(*) from usage_session_daily where cost_status <> 'unknown' or estimated_cost_text is not null"
        ),
        0,
        "the collector must not price usage"
    );
    // Full-text search finds collected message and session text.
    assert_eq!(
        count(
            &conn,
            "select count(*) from message_search where message_search match 'parser'"
        ),
        2
    );
    assert_eq!(
        count(
            &conn,
            "select count(*) from session_search where session_search match 'shell'"
        ),
        1
    );
    // Unsupported files leave a hidden status row, like the viewer's scan.
    assert_eq!(
        count(
            &conn,
            "select count(*) from sessions where scan_status = 'unsupported_format'"
        ),
        1
    );
    // Identity: every row belongs to this machine and harness.
    let machine: String = conn
        .query_row(
            "select value from app_metadata where key = 'machine_id'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        count(
            &conn,
            &format!(
                "select count(*) from sessions where machine_id = '{machine}' and harness = 'codex'"
            )
        ),
        count(&conn, "select count(*) from sessions")
    );
}

#[test]
fn repeated_scans_skip_unchanged_files_and_never_duplicate_usage() {
    let temp = TempDir::new("repeat");
    let home = support::codex_home(
        &temp,
        &["rich_session.jsonl", "forked_legacy_session.jsonl"],
    );
    let db = viewer_database(&temp);
    let run = || {
        let output = support::scan(&db, &home, &["--json"]);
        serde_json::from_slice::<Value>(&output.stdout).unwrap()
    };
    let first = run();
    assert_eq!(first["files_parsed"], 2);
    let snapshot = support::usage_snapshot(&db);
    let second = run();
    assert_eq!(second["files_parsed"], 0);
    assert_eq!(second["files_skipped"], 2);
    assert_eq!(support::usage_snapshot(&db), snapshot);
    let forced = support::scan(&db, &home, &["--json", "--force"]);
    assert!(forced.status.success());
    assert_eq!(
        support::usage_snapshot(&db),
        snapshot,
        "a forced reparse replaces, never adds"
    );
}

#[test]
fn appended_rollout_updates_messages_and_usage_in_place() {
    let temp = TempDir::new("append");
    let home = support::codex_home(&temp, &["subagent_session.jsonl"]);
    let db = viewer_database(&temp);
    assert!(support::scan(&db, &home, &[]).status.success());
    let file = support::day_folder(&home).join("subagent_session.jsonl");
    let conn = open(&db);
    let before_messages = count(&conn, "select count(*) from messages");
    let before_events = count(&conn, "select count(*) from usage_events");
    drop(conn);
    let mut text = std::fs::read_to_string(&file).unwrap();
    text.push_str(concat!(
        r#"{"timestamp":"2026-09-02T09:10:00Z","type":"event_msg","payload":{"type":"agent_message","message":"appended answer"},"rollout_ordinal":8}"#,
        "\n",
        r#"{"timestamp":"2026-09-02T09:10:01Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":400,"cached_input_tokens":10,"output_tokens":60,"reasoning_output_tokens":0,"total_tokens":460},"last_token_usage":{"input_tokens":100,"cached_input_tokens":0,"output_tokens":20,"reasoning_output_tokens":0,"total_tokens":120}}},"rollout_ordinal":9}"#,
        "\n"
    ));
    std::fs::write(&file, text).unwrap();
    assert!(support::scan(&db, &home, &[]).status.success());
    let conn = open(&db);
    assert_eq!(
        count(&conn, "select count(*) from messages"),
        before_messages + 1
    );
    assert_eq!(
        count(&conn, "select count(*) from usage_events"),
        before_events + 1
    );
    assert_eq!(
        count(
            &conn,
            "select count(*) from sessions where session_id = 'parity-sub-002'"
        ),
        1
    );
}

#[test]
fn malformed_and_unreadable_sources_are_recorded_without_stopping_the_scan() {
    let temp = TempDir::new("malformed");
    let home = support::codex_home(
        &temp,
        &[
            "malformed_line.jsonl",
            "invalid_utf8.jsonl",
            "array_record.jsonl",
            "no_session_id.jsonl",
        ],
    );
    let db = viewer_database(&temp);
    let output = support::scan(&db, &home, &["--json"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["files_parsed"], 1);
    assert_eq!(report["files_failed"], 3);
    let statuses: Vec<String> = report["errors"]
        .as_array()
        .unwrap()
        .iter()
        .map(|error| error["status"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(statuses.iter().filter(|s| *s == "parse_error").count(), 2);
    assert_eq!(
        statuses
            .iter()
            .filter(|s| *s == "unsupported_format")
            .count(),
        1
    );
    let conn = open(&db);
    assert_eq!(
        count(
            &conn,
            "select count(*) from sessions where parse_status = 'parse_error'"
        ),
        2
    );
    // A parse failure never removes previously collected content.
    let good = support::day_folder(&home).join("no_session_id.jsonl");
    std::fs::write(&good, "{\"type\": broken\n").unwrap();
    assert!(support::scan(&db, &home, &[]).status.success());
    let conn = open(&db);
    assert_eq!(count(&conn, "select count(*) from messages"), 2);
    assert_eq!(
        count(
            &conn,
            "select count(*) from sessions where parse_status = 'parse_error'"
        ),
        3
    );
}

#[test]
fn deleted_rollouts_become_missing_but_keep_their_history() {
    let temp = TempDir::new("missing");
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
    let db = viewer_database(&temp);
    assert!(support::scan(&db, &home, &[]).status.success());
    std::fs::remove_file(support::day_folder(&home).join("rich_session.jsonl")).unwrap();
    let output = support::scan(&db, &home, &["--json"]);
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["sessions_missing"], 1);
    let conn = open(&db);
    let (scan_status, source_state): (String, String) = conn
        .query_row(
            "select scan_status, source_state from sessions where id = 'session:parity-rich-001'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(
        (scan_status.as_str(), source_state.as_str()),
        ("missing", "missing")
    );
    assert_eq!(count(&conn, "select count(*) from messages"), 13);
}

#[test]
fn a_single_file_ingest_matches_a_scan_of_that_file() {
    let temp = TempDir::new("single");
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
    let scanned = viewer_database(&temp);
    assert!(support::scan(&scanned, &home, &[]).status.success());
    let single_db = temp.path().join("single.sqlite");
    support::create_viewer_database(&single_db);
    let file = support::day_folder(&home).join("rich_session.jsonl");
    let output = collector()
        .args(["codex", "ingest", "--no-wsl-projects", "--db"])
        .arg(&single_db)
        .arg("--windows-root")
        .arg(&home)
        .args(["--wsl-root", ""])
        .arg(&file)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    support::assert_same(
        &support::content_snapshot(&scanned),
        &support::content_snapshot(&single_db),
    );
}

// ---------------------------------------------------------------------------
// Concurrency, interruption, and recovery under SQLite locking

#[test]
fn concurrent_collectors_and_viewer_writes_serialize_through_sqlite() {
    let temp = TempDir::new("concurrent");
    let names: Vec<String> = (0..60).map(|i| format!("generated-{i:03}.jsonl")).collect();
    let home = support::codex_home(&temp, &[]);
    for name in &names {
        support::write_generated_session(&support::day_folder(&home).join(name), name, 40);
    }
    let db = viewer_database(&temp);
    let mut children: Vec<std::process::Child> = (0..3)
        .map(|_| {
            support::scan_command(&db, &home, &["--parser-workers", "2"])
                .spawn()
                .unwrap()
        })
        .collect();
    // A viewer-style mutation keeps committing while the collectors run.
    let conn = open(&db);
    for round in 0..40 {
        conn.execute_batch("begin immediate").unwrap();
        conn.execute(
            "insert into app_metadata (key, value, updated_at_utc) values ('viewer_probe', ?, 'now')
             on conflict(key) do update set value = excluded.value",
            [round.to_string()],
        )
        .unwrap();
        conn.execute_batch("commit").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    for child in &mut children {
        let status = child.wait().unwrap();
        assert!(status.success());
    }
    assert_eq!(
        count(
            &conn,
            "select count(*) from sessions where parse_status = 'available'"
        ),
        60
    );
    assert_eq!(count(&conn, "select count(*) from usage_events"), 60 * 40);
    assert_eq!(
        count(
            &conn,
            "select cast(value as integer) from app_metadata where key = 'viewer_probe'"
        ),
        39
    );
    let check: String = conn
        .query_row("pragma integrity_check", [], |row| row.get(0))
        .unwrap();
    assert_eq!(check, "ok");
}

#[test]
fn an_interrupted_scan_converges_on_the_next_run() {
    let temp = TempDir::new("interrupt");
    let home = support::codex_home(&temp, &[]);
    for i in 0..400 {
        let name = format!("interrupt-{i:03}.jsonl");
        support::write_generated_session(&support::day_folder(&home).join(&name), &name, 30);
    }
    let reference = temp.path().join("reference.sqlite");
    support::create_viewer_database(&reference);
    assert!(support::scan(&reference, &home, &[]).status.success());

    let db = viewer_database(&temp);
    let mut child = support::scan_command(&db, &home, &["--parser-workers", "1"])
        .spawn()
        .unwrap();
    // Kill it only after the first batch committed, so the run is really cut
    // off in the middle.
    let watcher = open(&db);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(60);
    while count(&watcher, "select count(*) from sessions") == 0 {
        assert!(std::time::Instant::now() < deadline, "no batch committed");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    drop(watcher);
    let _ = child.kill();
    let _ = child.wait();
    let conn = open(&db);
    let partial = count(&conn, "select count(*) from sessions");
    assert!(partial > 0);
    let check: String = conn
        .query_row("pragma integrity_check", [], |row| row.get(0))
        .unwrap();
    assert_eq!(check, "ok");
    drop(conn);
    assert!(
        partial < 400,
        "the scan finished before it could be interrupted"
    );
    assert!(support::scan(&db, &home, &[]).status.success());
    support::assert_same(
        &support::content_snapshot(&reference),
        &support::content_snapshot(&db),
    );
}

#[test]
fn a_busy_database_fails_the_batch_cleanly_and_the_rerun_completes() {
    let temp = TempDir::new("busy");
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
    let db = viewer_database(&temp);
    let holder = open(&db);
    holder.execute_batch("begin exclusive").unwrap();
    let output = support::scan_command(&db, &home, &[])
        .env("CODEX_SESSIONS_COLLECTOR_BUSY_TIMEOUT_MS", "200")
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("locked"));
    holder.execute_batch("rollback").unwrap();
    drop(holder);
    assert_eq!(count(&open(&db), "select count(*) from messages"), 0);
    assert!(support::scan(&db, &home, &[]).status.success());
    assert_eq!(count(&open(&db), "select count(*) from messages"), 13);
}

// ---------------------------------------------------------------------------
// Database ownership and schema refusal

fn refused(output: &std::process::Output) -> String {
    assert_eq!(
        output.status.code(),
        Some(3),
        "stdout: {}\nstderr: {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stderr).into_owned()
}

#[test]
fn refuses_databases_it_does_not_own_or_cannot_write_safely() {
    let temp = TempDir::new("refuse");
    let home = support::codex_home(&temp, &["no_session_id.jsonl"]);

    // Missing viewer database: never created by the collector.
    let missing = temp.path().join("absent.sqlite");
    assert!(refused(&support::scan(&missing, &home, &[])).contains("Start the viewer once"));
    assert!(!missing.exists());

    // Older schema: the viewer must upgrade it.
    let older = temp.path().join("older.sqlite");
    support::create_database_at_version(&older, 17);
    assert!(
        refused(&support::scan(&older, &home, &[])).contains("Open the viewer once to upgrade")
    );

    // Newer schema than this collector knows.
    let newer = viewer_database(&temp);
    open(&newer)
        .execute(
            "insert into schema_version (version, filename, checksum, applied_at_utc, success) values (999, '999_future.sql', 'x', 'now', 1)",
            [],
        )
        .unwrap();
    assert!(
        refused(&support::scan(&newer, &home, &[])).contains("newer than this collector supports")
    );

    // A pending viewer usage migration.
    let pending = temp.path().join("pending.sqlite");
    support::create_viewer_database(&pending);
    open(&pending)
        .execute(
            "insert into app_metadata (key, value, updated_at_utc) values ('usage_migration_bootstrap', '{}', 'now')",
            [],
        )
        .unwrap();
    assert!(refused(&support::scan(&pending, &home, &[])).contains("migrating this database"));
    let running = temp.path().join("running.sqlite");
    support::create_viewer_database(&running);
    support::insert_running_usage_migration(&running);
    assert!(refused(&support::scan(&running, &home, &[])).contains("has not finished"));

    // Foreign owners in both directions.
    let viewer_owned = temp.path().join("viewer-owned.sqlite");
    support::create_viewer_database(&viewer_owned);
    let output = collector()
        .args(["codex", "scan", "--no-wsl-projects", "--standalone"])
        .arg(&viewer_owned)
        .arg("--windows-root")
        .arg(&home)
        .args(["--wsl-root", ""])
        .output()
        .unwrap();
    assert!(refused(&output).contains("belongs to the viewer"));
    let collector_owned = temp.path().join("collector-owned.sqlite");
    let output = collector()
        .args(["codex", "scan", "--no-wsl-projects", "--standalone"])
        .arg(&collector_owned)
        .arg("--windows-root")
        .arg(&home)
        .args(["--wsl-root", ""])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        refused(&support::scan(&collector_owned, &home, &[]))
            .contains("owned by a standalone collector")
    );
    // Nothing was written to any refused database.
    for path in [&older, &pending, &running, &viewer_owned] {
        assert_eq!(count(&open(path), "select count(*) from sessions"), 0);
    }
}

#[test]
fn a_standalone_collector_creates_and_then_reuses_its_own_database() {
    let temp = TempDir::new("standalone");
    let home = support::codex_home(
        &temp,
        &["rich_session.jsonl", "forked_legacy_session.jsonl"],
    );
    let db = temp.path().join("nested").join("collector.sqlite");
    for _ in 0..2 {
        let output = collector()
            .args([
                "codex",
                "scan",
                "--json",
                "--no-wsl-projects",
                "--standalone",
            ])
            .arg(&db)
            .arg("--windows-root")
            .arg(&home)
            .args(["--wsl-root", ""])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let report: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(report["owner"], "collector");
    }
    let conn = open(&db);
    let owner: String = conn
        .query_row(
            "select value from app_metadata where key = 'database_owner'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(owner, "collector");
    assert_eq!(
        count(
            &conn,
            "select max(version) from schema_version where success = 1"
        ),
        codex_sessions_collector::store::schema::SUPPORTED_SCHEMA_VERSION
    );
    assert_eq!(
        count(
            &conn,
            "select count(*) from sessions where parse_status = 'available'"
        ),
        2
    );
}

// ---------------------------------------------------------------------------
// Identity migration and the contract

#[test]
fn identity_migration_is_additive_and_preserves_local_annotations() {
    let temp = TempDir::new("identity");
    let db = temp.path().join("v17.sqlite");
    support::create_database_at_version(&db, 17);
    let conn = open(&db);
    conn.execute_batch(
        "insert into projects (name, is_active, created_at_utc, updated_at_utc) values ('Mine', 1, 'now', 'now');
         insert into sessions (id, session_id, source_type, source_file_path, display_path, platform_path,
           scan_status, parse_status, is_pinned, project_override, project_id, project_name_snapshot,
           eval_ready, eval_notes, created_at_utc, updated_at_utc)
         values ('session:old', 'old', 'windows', 'C:\\a.jsonl', 'C:\\a.jsonl', 'C:\\a.jsonl',
           'available', 'available', 1, 1, 1, 'Mine', 1, 'keep me', 'now', 'now');
         insert into tags (name, created_at_utc, updated_at_utc) values ('important', 'now', 'now');
         insert into session_tags (session_id, tag_id, created_at_utc) values ('session:old', 1, 'now');",
    )
    .unwrap();
    let before: Vec<Value> = support::rows(&conn, "select * from sessions");
    let migration = codex_sessions_collector::store::schema::MIGRATIONS
        .iter()
        .find(|migration| migration.version == 18)
        .unwrap();
    conn.execute_batch(migration.sql).unwrap();
    let after: Vec<Value> = support::rows(&conn, "select * from sessions");
    assert_eq!(after.len(), 1);
    let machine: String = conn
        .query_row(
            "select value from app_metadata where key = 'machine_id'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(machine.len(), 32);
    for (key, value) in before[0].as_object().unwrap() {
        assert_eq!(&after[0][key], value, "column {key} changed");
    }
    assert_eq!(after[0]["harness"], "codex");
    assert_eq!(after[0]["machine_id"], machine.as_str());
    assert_eq!(count(&conn, "select count(*) from session_tags"), 1);
    // New rows from any writer get the machine ID without knowing it.
    conn.execute(
        "insert into sessions (id, source_type, source_file_path, display_path, platform_path,
           created_at_utc, updated_at_utc) values ('session:new', 'windows', 'x', 'x', 'x', 'now', 'now')",
        [],
    )
    .unwrap();
    let new_machine: String = conn
        .query_row(
            "select machine_id from sessions where id = 'session:new'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(new_machine, machine);
}

#[test]
fn conditional_usage_fields_round_trip_through_the_contract() {
    let temp = TempDir::new("contract");
    let db = viewer_database(&temp);
    let mut snapshot = support::sample_snapshot("claude-like-1");
    snapshot.harness = "example".to_owned();
    snapshot.usage_events[0].provider = Some("anthropic".to_owned());
    snapshot.usage_events[0].request_input_tokens = Some(180_000);
    snapshot.usage_events[0].model_context_window = Some(200_000);
    snapshot.usage_events[0].billable_units =
        Some(serde_json::from_value(json!({"web_search_requests": 2, "image_inputs": 1})).unwrap());
    snapshot.usage_events[0].usage.cache_write_input_tokens = Some(1200);
    snapshot.usage_events[1].usage = contract::UsageRecord {
        input_tokens: Some(5),
        output_tokens: None,
        ..contract::UsageRecord::default()
    };
    let lines = [
        serde_json::to_string(&Envelope::new(Record::SessionSnapshot(Box::new(
            snapshot.clone(),
        ))))
        .unwrap(),
    ];
    let input = temp.path().join("records.jsonl");
    std::fs::write(&input, lines.join("\n")).unwrap();
    let output = collector()
        .args(["apply", "--json", "--db"])
        .arg(&db)
        .arg("--input")
        .arg(&input)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let conn = open(&db);
    let row: (String, i64, i64, String) = conn
        .query_row(
            "select provider, request_input_tokens, model_context_window, billable_units_json
             from usage_event_inputs where session_row_id = 'example:session:claude-like-1' and source_record_ordinal = 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .unwrap();
    assert_eq!(row.0, "anthropic");
    assert_eq!((row.1, row.2), (180_000, 200_000));
    assert_eq!(
        serde_json::from_str::<Value>(&row.3).unwrap(),
        json!({"web_search_requests": 2, "image_inputs": 1})
    );
    let cache_write: i64 = conn
        .query_row(
            "select cache_write_input_tokens from usage_events where session_row_id = 'example:session:claude-like-1' and source_record_ordinal = 1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(cache_write, 1200);
    // Unknown inputs stay absent instead of becoming zero-valued evidence.
    assert_eq!(
        count(
            &conn,
            "select count(*) from usage_event_inputs where session_row_id = 'example:session:claude-like-1' and source_record_ordinal = 2"
        ),
        0
    );
    let harness: String = conn
        .query_row(
            "select harness from sessions where id = 'example:session:claude-like-1'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(harness, "example");
}

#[test]
fn contract_rejects_unsupported_versions_and_malformed_records_before_writing() {
    let temp = TempDir::new("contract-reject");
    let db = viewer_database(&temp);
    let good = serde_json::to_string(&Envelope::new(Record::SessionSnapshot(Box::new(
        support::sample_snapshot("good"),
    ))))
    .unwrap();
    let cases = [
        good.replace("\"version\":1", "\"version\":2"),
        good.replace("codex-sessions-viewer.ingest", "other.contract"),
        good.replace(
            "\"branch_scope\":\"local\"",
            "\"branch_scope\":\"sideways\"",
        ),
        good.replace("\"kind\":\"session_snapshot\"", "\"kind\":\"mystery\""),
        "{not json".to_owned(),
    ];
    for case in cases {
        let input = temp.path().join("bad.jsonl");
        std::fs::write(&input, format!("{good}\n{case}\n")).unwrap();
        let output = collector()
            .args(["apply", "--db"])
            .arg(&db)
            .arg("--input")
            .arg(&input)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(1), "{case}");
        assert!(String::from_utf8_lossy(&output.stderr).contains("line 2"));
    }
    assert_eq!(count(&open(&db), "select count(*) from sessions"), 0);
    // Unknown fields are tolerated.
    let extended = good.replacen(
        "\"harness\":\"codex\"",
        "\"harness\":\"codex\",\"future_field\":{\"x\":1}",
        1,
    );
    let input = temp.path().join("extended.jsonl");
    std::fs::write(&input, extended).unwrap();
    let output = collector()
        .args(["apply", "--db"])
        .arg(&db)
        .arg("--input")
        .arg(&input)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(count(&open(&db), "select count(*) from sessions"), 1);
}

#[test]
fn parse_emits_contract_records_that_apply_like_a_scan() {
    let temp = TempDir::new("parse-apply");
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
    let scanned = viewer_database(&temp);
    assert!(support::scan(&scanned, &home, &[]).status.success());
    let file = support::day_folder(&home).join("rich_session.jsonl");
    let parsed = collector()
        .args(["codex", "parse", "--windows-root"])
        .arg(&home)
        .args(["--wsl-root", ""])
        .arg(&file)
        .output()
        .unwrap();
    assert!(
        parsed.status.success(),
        "{}",
        String::from_utf8_lossy(&parsed.stderr)
    );
    let applied_db = temp.path().join("applied.sqlite");
    support::create_viewer_database(&applied_db);
    let mut child = collector()
        .args(["apply", "--db"])
        .arg(&applied_db)
        .stdin(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    use std::io::Write as _;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(&parsed.stdout)
        .unwrap();
    assert!(child.wait().unwrap().success());
    // Project names are resolved after the scan; statuses come from scan outcomes.
    let conn = open(&applied_db);
    assert_eq!(count(&conn, "select count(*) from messages"), 13);
    support::assert_same(
        &support::content_snapshot_without_projects(&scanned),
        &support::content_snapshot_without_projects(&applied_db),
    );
}

#[test]
fn the_cli_reports_usage_errors_with_exit_code_two() {
    let output = collector()
        .args(["codex", "scan", "--frobnicate"])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    let output = collector().args(["codex", "ingest"]).output().unwrap();
    assert_eq!(output.status.code(), Some(2));
    let output = collector().arg("version").output().unwrap();
    assert!(output.status.success());
    assert!(String::from_utf8_lossy(&output.stdout).contains(&format!(
        "schema {}",
        codex_sessions_collector::store::schema::SUPPORTED_SCHEMA_VERSION
    )));
}

// ---------------------------------------------------------------------------
// Review follow-ups: ownership re-checks, machine identity, harness scoping

#[test]
fn a_viewer_migration_started_mid_collection_stops_further_writes() {
    use codex_sessions_collector::store::{OwnerMode, Store, StoreError};
    let temp = TempDir::new("mid-migration");
    let db = viewer_database(&temp);
    let store = Store::open(&db, OwnerMode::Viewer).unwrap();
    store
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            support::sample_snapshot("before"),
        )))])
        .unwrap();
    // A newer viewer starts its startup migration between two batches.
    open(&db)
        .execute(
            "insert into app_metadata (key, value, updated_at_utc) values ('usage_migration_bootstrap', '{}', 'now')",
            [],
        )
        .unwrap();
    let result = store.apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
        support::sample_snapshot("after"),
    )))]);
    assert!(matches!(result, Err(StoreError::Refused(_))), "{result:?}");
    let conn = open(&db);
    assert_eq!(
        count(
            &conn,
            "select count(*) from sessions where session_id = 'after'"
        ),
        0
    );
    // A schema change is refused the same way.
    conn.execute_batch(
        "delete from app_metadata where key = 'usage_migration_bootstrap';
         insert into schema_version (version, filename, checksum, applied_at_utc, success)
         values (999, '999_future.sql', 'x', 'now', 1);",
    )
    .unwrap();
    let result = store.apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
        support::sample_snapshot("later"),
    )))]);
    assert!(matches!(result, Err(StoreError::Refused(_))), "{result:?}");
    assert_eq!(
        count(
            &conn,
            "select count(*) from sessions where session_id = 'later'"
        ),
        0
    );
}

#[test]
fn records_from_another_machine_are_refused_instead_of_relabelled() {
    let temp = TempDir::new("foreign-machine");
    let db = viewer_database(&temp);
    let mut snapshot = support::sample_snapshot("foreign");
    snapshot.machine_id = Some("0123456789abcdef0123456789abcdef".to_owned());
    let input = temp.path().join("foreign.jsonl");
    std::fs::write(
        &input,
        serde_json::to_string(&Envelope::new(Record::SessionSnapshot(Box::new(snapshot)))).unwrap(),
    )
    .unwrap();
    let output = collector()
        .args(["apply", "--db"])
        .arg(&db)
        .arg("--input")
        .arg(&input)
        .output()
        .unwrap();
    assert!(refused(&output).contains("another machine"));
    assert_eq!(count(&open(&db), "select count(*) from sessions"), 0);
    // The database's own machine ID is accepted.
    let machine: String = open(&db)
        .query_row(
            "select value from app_metadata where key = 'machine_id'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let mut snapshot = support::sample_snapshot("local");
    snapshot.machine_id = Some(machine);
    std::fs::write(
        &input,
        serde_json::to_string(&Envelope::new(Record::SessionSnapshot(Box::new(snapshot)))).unwrap(),
    )
    .unwrap();
    let output = collector()
        .args(["apply", "--db"])
        .arg(&db)
        .arg("--input")
        .arg(&input)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn source_statuses_only_touch_their_own_harness() {
    let temp = TempDir::new("status-harness");
    let db = viewer_database(&temp);
    let snapshot = support::sample_snapshot("codex-owned");
    let path = snapshot.source.path.clone();
    let status = |harness: &str, path: &str| {
        serde_json::to_string(&Envelope::new(Record::SourceStatus(
            contract::SourceStatus {
                harness: harness.to_owned(),
                path: path.to_owned(),
                status: "parse_error".to_owned(),
                state: "active".to_owned(),
                message: None,
            },
        )))
        .unwrap()
    };
    let lines = [
        serde_json::to_string(&Envelope::new(Record::SessionSnapshot(Box::new(snapshot)))).unwrap(),
        status("example", &path),
        status("example", "C:\\synthetic\\example-only.jsonl"),
    ];
    let input = temp.path().join("statuses.jsonl");
    std::fs::write(&input, lines.join("\n")).unwrap();
    let output = collector()
        .args(["apply", "--db"])
        .arg(&db)
        .arg("--input")
        .arg(&input)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let conn = open(&db);
    let codex_status: (String, String) = conn
        .query_row(
            "select scan_status, parse_status from sessions where id = 'session:codex-owned'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(
        codex_status,
        ("available".to_owned(), "available".to_owned())
    );
    let placeholders = support::rows(
        &conn,
        "select id, harness, parse_status from sessions where id like '%source-status:%' order by id",
    );
    assert_eq!(placeholders.len(), 2);
    for row in &placeholders {
        assert_eq!(row["harness"], "example");
        assert!(
            row["id"]
                .as_str()
                .unwrap()
                .starts_with("example:source-status:")
        );
        assert_eq!(row["parse_status"], "parse_error");
    }
}

// ---------------------------------------------------------------------------
// Writer version agreement per harness

fn snapshot_for(harness: &str, session_id: &str, parser_version: i64) -> contract::SessionSnapshot {
    let mut snapshot = support::sample_snapshot(session_id);
    snapshot.harness = harness.to_owned();
    snapshot.session.parser_version = parser_version;
    snapshot
}

fn apply_snapshot(
    store: &codex_sessions_collector::store::Store,
    snapshot: contract::SessionSnapshot,
) -> Result<(), String> {
    store
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            snapshot,
        )))])
        .map(|_| ())
        .map_err(|error| error.to_string())
}

fn set_metadata(conn: &Connection, key: &str, value: Option<&str>) {
    conn.execute("delete from app_metadata where key = ?", [key])
        .unwrap();
    if let Some(value) = value {
        conn.execute(
            "insert into app_metadata(key,value,updated_at_utc) values (?,?,'now')",
            [key, value],
        )
        .unwrap();
    }
}

#[test]
fn each_harness_is_gated_only_by_its_own_parser_version() {
    use codex_sessions_collector::claude::parser::CLAUDE_PARSER_VERSION;
    use codex_sessions_collector::codex::parser::PARSER_VERSION;
    use codex_sessions_collector::store::{OwnerMode, Store};
    let temp = TempDir::new("writer-version-harness");
    let db = viewer_database(&temp);
    let conn = open(&db);
    let store = Store::open(&db, OwnerMode::Viewer).unwrap();

    // A viewer from another Codex parser release refuses Codex rows only.
    set_metadata(&conn, "writer_codex_parser_version", Some("999"));
    let refused =
        apply_snapshot(&store, snapshot_for("codex", "codex-a", PARSER_VERSION)).unwrap_err();
    assert!(
        refused.contains("codex") && refused.contains("999"),
        "{refused}"
    );
    apply_snapshot(
        &store,
        snapshot_for("claude", "claude-a", CLAUDE_PARSER_VERSION),
    )
    .unwrap();
    apply_snapshot(&store, snapshot_for("example", "example-a", 7)).unwrap();

    // A viewer that does not know the Claude parser refuses Claude rows only.
    set_metadata(
        &conn,
        "writer_codex_parser_version",
        Some(&PARSER_VERSION.to_string()),
    );
    set_metadata(&conn, "writer_claude_parser_version", None);
    let refused = apply_snapshot(
        &store,
        snapshot_for("claude", "claude-b", CLAUDE_PARSER_VERSION),
    )
    .unwrap_err();
    assert!(
        refused.contains("claude") && refused.contains("missing"),
        "{refused}"
    );
    apply_snapshot(&store, snapshot_for("codex", "codex-b", PARSER_VERSION)).unwrap();

    // Every harness's usage becomes cost rows: the cost version gates all.
    set_metadata(
        &conn,
        "writer_claude_parser_version",
        Some(&CLAUDE_PARSER_VERSION.to_string()),
    );
    set_metadata(&conn, "writer_usage_cost_projection_version", Some("999"));
    for (harness, version) in [
        ("codex", PARSER_VERSION),
        ("claude", CLAUDE_PARSER_VERSION),
        ("example", 7),
    ] {
        let refused = apply_snapshot(
            &store,
            snapshot_for(harness, &format!("{harness}-c"), version),
        )
        .unwrap_err();
        assert!(
            refused.contains("projection") && refused.contains("999"),
            "{refused}"
        );
    }
    assert_eq!(
        count(
            &conn,
            "select count(*) from sessions where session_id in ('codex-a','claude-b','codex-c','claude-c','example-c')"
        ),
        0
    );
    assert_eq!(count(&conn, "select count(*) from sessions"), 3);
}

#[test]
fn claude_subagent_usage_is_reconciled_against_the_claude_parser_version() {
    use codex_sessions_collector::claude::parser::CLAUDE_PARSER_VERSION;
    use codex_sessions_collector::store::{OwnerMode, Store};
    let temp = TempDir::new("claude-legacy-reconcile");
    let db = viewer_database(&temp);
    let store = Store::open(&db, OwnerMode::Viewer).unwrap();
    let parent = snapshot_for("claude", "claude-parent", CLAUDE_PARSER_VERSION);
    let mut child = snapshot_for("claude", "claude-child", CLAUDE_PARSER_VERSION);
    child.source.path = "C:\\synthetic\\claude-child.jsonl".to_owned();
    child.session.parent_thread_id = Some("claude-parent".to_owned());
    // The child's first event repeats the parent's history.
    child.usage_events[0].event_fingerprint = parent.usage_events[0].event_fingerprint.clone();
    apply_snapshot(&store, parent).unwrap();
    apply_snapshot(&store, child).unwrap();
    let conn = open(&db);
    let status: String = conn
        .query_row(
            "select usage_projection_status from sessions where id = 'claude:session:claude-child'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(status, "complete", "not legacy_pending");
    let scopes = support::rows(
        &conn,
        "select branch_scope from usage_events where session_row_id = 'claude:session:claude-child' order by source_record_ordinal",
    );
    assert_eq!(
        scopes,
        [
            json!({"branch_scope": "inherited"}),
            json!({"branch_scope": "local"})
        ]
    );
}

// ---------------------------------------------------------------------------
// The session change journal

fn revision(conn: &Connection) -> i64 {
    count(
        conn,
        "select revision from session_change_state where id = 1",
    )
}

#[test]
fn repricing_does_not_journal_sessions_but_token_changes_and_renames_do() {
    use codex_sessions_collector::store::{OwnerMode, Store};
    let temp = TempDir::new("journal-precision");
    let db = viewer_database(&temp);
    let store = Store::open(&db, OwnerMode::Viewer).unwrap();
    apply_snapshot(&store, support::sample_snapshot("journal")).unwrap();
    let conn = open(&db);
    let journaled = |conn: &Connection| {
        count(
            conn,
            "select revision from session_changes where session_id = 'session:journal'",
        )
    };
    let start = revision(&conn);
    assert!(count(&conn, "select count(*) from usage_session_daily") > 0);
    conn.execute(
        "update usage_session_daily set cost_projection_version = cost_projection_version + 1,
           updated_at_utc = 'later'",
        [],
    )
    .unwrap();
    assert_eq!(revision(&conn), start, "a reprice is not a session change");

    conn.execute(
        "update usage_session_daily set input_tokens = input_tokens + 1, total_tokens = total_tokens + 1",
        [],
    )
    .unwrap();
    assert!(revision(&conn) > start);
    assert_eq!(journaled(&conn), revision(&conn));

    conn.execute(
        "insert into tags (name, created_at_utc, updated_at_utc) values ('old tag', 'now', 'now')",
        [],
    )
    .unwrap();
    conn.execute(
        "insert into session_tags (session_id, tag_id, created_at_utc)
         select 'session:journal', id, 'now' from tags where name = 'old tag'",
        [],
    )
    .unwrap();
    let before_rename = revision(&conn);
    conn.execute(
        "update tags set name = 'new tag' where name = 'old tag'",
        [],
    )
    .unwrap();
    assert!(revision(&conn) > before_rename);
    assert_eq!(journaled(&conn), revision(&conn));
    let before_color = revision(&conn);
    conn.execute("update tags set color = 'red'", []).unwrap();
    assert_eq!(revision(&conn), before_color);

    let project: i64 = conn
        .query_row(
            "select coalesce(project_id, detected_project_id) from sessions where id = 'session:journal'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let before_project = revision(&conn);
    conn.execute(
        "update projects set name = 'renamed project' where id = ?",
        [project],
    )
    .unwrap();
    assert!(revision(&conn) > before_project);
    assert_eq!(journaled(&conn), revision(&conn));
}

// ---------------------------------------------------------------------------
// Session cache repair and project backfill, owned by the collector

struct RepairFixture {
    temp: TempDir,
    home: std::path::PathBuf,
    db: std::path::PathBuf,
}

impl RepairFixture {
    fn new(label: &str) -> Self {
        let temp = TempDir::new(label);
        let home = temp.path().join(".codex");
        std::fs::create_dir_all(home.join("sessions")).unwrap();
        std::fs::create_dir_all(home.join("archived_sessions")).unwrap();
        let db = viewer_database(&temp);
        Self { temp, home, db }
    }

    fn file(&self, relative: &str) -> String {
        let path = self.home.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "{}").unwrap();
        path.to_string_lossy().into_owned()
    }

    fn insert(&self, id: &str, session_id: Option<&str>, path: &str, parser_version: i64) -> i64 {
        let conn = open(&self.db);
        conn.execute(
            "insert into sessions (id, session_id, source_type, source_file_path, display_path,
               platform_path, source_state, parser_version, created_at_utc, updated_at_utc)
             values (?, ?, 'windows', ?, ?, ?, 'active', ?, '2026-07-27T09:00:00Z', '2026-07-27T09:00:00Z')",
            rusqlite::params![id, session_id, path, path, path, parser_version],
        )
        .unwrap();
        conn.last_insert_rowid()
    }

    fn roots(&self) -> Vec<codex_sessions_collector::codex::scanner::ScanRoot> {
        codex_sessions_collector::codex::scanner::session_scan_roots(
            self.home.to_str().unwrap(),
            codex_sessions_collector::codex::parser::SourceType::Windows,
        )
    }

    fn repair(
        &self,
        discovery_complete: bool,
        cancelled: bool,
    ) -> codex_sessions_collector::store::cache_repair::RepairReport {
        use codex_sessions_collector::store::{OwnerMode, Store, cache_repair};
        let store = Store::open(&self.db, OwnerMode::Viewer).unwrap();
        cache_repair::run(
            &store,
            &self.roots(),
            discovery_complete,
            &std::sync::Arc::new(std::sync::atomic::AtomicBool::new(cancelled)),
            &mut |_| Ok(true),
        )
        .unwrap()
    }

    fn ids(&self) -> Vec<String> {
        let conn = open(&self.db);
        let mut statement = conn.prepare("select id from sessions order by id").unwrap();
        statement
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    fn backups(&self) -> Vec<std::path::PathBuf> {
        std::fs::read_dir(self.temp.path().join("backups"))
            .map(|entries| entries.map(|entry| entry.unwrap().path()).collect())
            .unwrap_or_default()
    }

    fn completed(&self) -> bool {
        count(
            &open(&self.db),
            "select count(*) from app_metadata where key = 'session_cache_repair.v3.completed'",
        ) == 1
    }
}

#[test]
fn cache_repair_audits_categories_and_deletes_only_allowlisted_legacy_rows() {
    let fixture = RepairFixture::new("repair-categories");
    let active = fixture.file("sessions/canonical.jsonl");
    let archived = fixture.file("archived_sessions/relocated.jsonl");
    let plugin = fixture.file("plugins/cache/artifact.json");
    let canonical = fixture.insert("session:canonical", Some("canonical"), &active, 2);
    let relocated = fixture.insert("session:relocated", Some("relocated"), &archived, 2);
    let fallback = fixture.insert(&format!("source:{active}"), None, &active, 1);
    let protected_fallback = fixture.insert(&format!("source-status:{active}"), None, &active, 1);
    let legacy = fixture.insert(&format!("source:{plugin}"), None, &plugin, 1);
    let unresolved = fixture.insert(&format!("source:{plugin}.protected"), None, &plugin, 1);
    let conn = open(&fixture.db);
    conn.execute(
        "update sessions set is_pinned = 1 where rowid in (?, ?)",
        [protected_fallback, unresolved],
    )
    .unwrap();

    let report = fixture.repair(true, false);
    assert_eq!(report.status, "completed");
    assert_eq!(report.reason_code, "completed");
    assert_eq!(report.deleted_rows, 2);
    assert_eq!(
        serde_json::to_value(&report.categories).unwrap(),
        json!({"canonical": 1, "relocated": 1, "fallback_duplicate": 2,
               "legacy_non_session_artifact": 1, "unresolved": 1})
    );
    let manifest = support::rows(
        &conn,
        "select session_rowid, category, reason_code, delete_eligible
         from session_cache_repair_manifest order by session_rowid",
    );
    assert_eq!(
        manifest,
        [
            json!({"session_rowid": canonical, "category": "canonical", "reason_code": "stable_active_session", "delete_eligible": 0}),
            json!({"session_rowid": relocated, "category": "relocated", "reason_code": "stable_archived_session", "delete_eligible": 0}),
            json!({"session_rowid": fallback, "category": "fallback_duplicate", "reason_code": "canonical_path_match_empty_legacy", "delete_eligible": 1}),
            json!({"session_rowid": protected_fallback, "category": "fallback_duplicate", "reason_code": "canonical_path_match_requires_reconciliation", "delete_eligible": 0}),
            json!({"session_rowid": legacy, "category": "legacy_non_session_artifact", "reason_code": "allowlisted_non_session_namespace", "delete_eligible": 1}),
            json!({"session_rowid": unresolved, "category": "unresolved", "reason_code": "protected_viewer_metadata", "delete_eligible": 0}),
        ]
    );
    // The manifest holds no paths or session content.
    let text: String = conn
        .query_row(
            "select group_concat(row_fingerprint || category || reason_code) from session_cache_repair_manifest",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(!text.contains(fixture.home.to_str().unwrap()) && !text.contains("canonical.jsonl"));

    let ids = fixture.ids();
    assert!(!ids.contains(&format!("source:{active}")));
    assert!(!ids.contains(&format!("source:{plugin}")));
    assert_eq!(ids.len(), 4);
    assert!(fixture.completed());
    // A verified backup holds the deleted rows.
    let backups = fixture.backups();
    assert_eq!(backups.len(), 1);
    assert_eq!(
        backups[0].file_name().unwrap().to_string_lossy(),
        report.backup_file.clone().unwrap()
    );
    assert_eq!(
        count(&open(&backups[0]), "select count(*) from sessions"),
        6
    );
    // Deleted rows leave tombstones for viewers following the journal.
    assert_eq!(
        count(
            &conn,
            "select count(*) from session_changes where deleted = 1"
        ),
        2
    );
    assert_eq!(fixture.repair(true, false).status, "already_completed");
}

#[test]
fn cache_repair_waits_for_complete_discovery_and_never_mutates_when_cancelled() {
    let fixture = RepairFixture::new("repair-gates");
    let plugin = fixture.file("plugins/legacy.json");
    fixture.insert(&format!("source:{plugin}"), None, &plugin, 1);

    let report = fixture.repair(false, false);
    assert_eq!(
        (report.status, report.reason_code),
        ("postponed", "root_discovery_incomplete")
    );
    let report = fixture.repair(true, true);
    assert_eq!(
        (report.status, report.reason_code),
        ("postponed", "cancelled")
    );
    assert_eq!(fixture.ids().len(), 1);
    assert!(!fixture.completed());
    assert!(fixture.backups().is_empty());

    let report = fixture.repair(true, false);
    assert_eq!((report.status, report.deleted_rows), ("completed", 1));
    assert!(fixture.ids().is_empty());
}

#[test]
fn cache_repair_protects_rows_owning_content_and_completes_without_a_backup() {
    let fixture = RepairFixture::new("repair-protects");
    let plugin = fixture.file("plugins/owned.json");
    let id = format!("source:{plugin}");
    fixture.insert(&id, None, &plugin, 1);
    open(&fixture.db)
        .execute(
            "insert into messages (session_id, message_index, author_type, content_preview,
               created_at_db_utc, updated_at_db_utc)
             values (?, 0, 'user', '', 'now', 'now')",
            [&id],
        )
        .unwrap();
    let report = fixture.repair(true, false);
    assert_eq!(
        (report.status, report.reason_code, report.deleted_rows),
        ("completed", "no_changes", 0)
    );
    assert_eq!(fixture.ids(), [id]);
    assert!(fixture.backups().is_empty());
    assert_eq!(
        count(
            &open(&fixture.db),
            "select count(*) from session_cache_repair_manifest where reason_code = 'owns_messages'"
        ),
        1
    );
}

#[test]
fn scans_run_the_cache_repair_after_complete_discovery_and_report_it() {
    let fixture = RepairFixture::new("repair-scan");
    let plugin = fixture.file("plugins/legacy.json");
    fixture.insert(&format!("source:{plugin}"), None, &plugin, 1);
    let malformed = fixture.home.join("sessions").join("gate.jsonl");
    std::fs::write(&malformed, "{ malformed").unwrap();
    let scan = |fixture: &RepairFixture| -> Value {
        let output = support::scan(&fixture.db, &fixture.home, &["--json"]);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).unwrap()
    };
    // A file that fails to parse under a reachable root does not make
    // discovery incomplete. A failing repair is postponed; the scan still succeeds.
    open(&fixture.db)
        .execute_batch(
            "create trigger fail_repair before insert on session_cache_repair_manifest
             begin select raise(abort, 'injected audit failure'); end;",
        )
        .unwrap();
    let report = scan(&fixture);
    assert_eq!(report["cache_repair"]["status"], "postponed");
    assert_eq!(
        report["cache_repair"]["reason_code"],
        "unexpected_repair_error"
    );

    open(&fixture.db)
        .execute_batch("drop trigger fail_repair")
        .unwrap();
    let report = scan(&fixture);
    assert_eq!(report["cache_repair"]["status"], "completed");
    assert_eq!(report["cache_repair"]["deleted_rows"], 1);
    assert!(fixture.completed());
    let report = scan(&fixture);
    assert_eq!(report["cache_repair"]["status"], "already_completed");
    assert!(malformed.exists());
}

#[test]
fn scans_postpone_the_cache_repair_while_a_codex_home_is_unreachable() {
    let fixture = RepairFixture::new("repair-unreachable");
    let plugin = fixture.file("plugins/legacy.json");
    fixture.insert(&format!("source:{plugin}"), None, &plugin, 1);
    let moved = fixture.temp.path().join("moved-home");
    std::fs::rename(&fixture.home, &moved).unwrap();
    let output = support::scan(&fixture.db, &fixture.home, &["--json"]);
    assert!(output.status.success());
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        report["cache_repair"]["reason_code"],
        "root_discovery_incomplete"
    );
    assert_eq!(fixture.ids().len(), 1);
}

impl RepairFixture {
    fn audit_id(&self) -> Option<String> {
        open(&self.db)
            .query_row(
                "select min(audit_id) from session_cache_repair_manifest",
                [],
                |row| row.get(0),
            )
            .unwrap()
    }

    /// Age the retry marker past the backoff, as if a day had passed.
    fn age_attempt(&self) {
        let changed = open(&self.db)
            .execute(
                "update app_metadata
                 set value = json_set(value, '$.attempted_at_utc', '2000-01-01T00:00:00.000Z')
                 where key = 'session_cache_repair.v3.attempt'",
                [],
            )
            .unwrap();
        assert_eq!(changed, 1, "a retry marker must exist");
    }

    /// Replace the backup folder with a file so every backup fails.
    fn block_backups(&self, blocked: bool) {
        let path = self.temp.path().join("backups");
        if blocked {
            let _ = std::fs::remove_dir_all(&path);
            std::fs::write(&path, "not a folder").unwrap();
        } else {
            let _ = std::fs::remove_file(&path);
        }
    }
}

#[test]
fn a_failed_repair_backs_off_until_the_inputs_change_or_a_day_passes() {
    let fixture = RepairFixture::new("repair-backoff");
    let plugin = fixture.file("plugins/legacy.json");
    fixture.insert(&format!("source:{plugin}"), None, &plugin, 1);
    fixture.block_backups(true);

    let report = fixture.repair(true, false);
    assert_eq!(
        (report.status, report.reason_code),
        ("postponed", "backup_failed")
    );
    let audit = fixture.audit_id().unwrap();
    // The next refresh repeats neither the audit nor the backup.
    let report = fixture.repair(true, false);
    assert_eq!(
        (report.status, report.reason_code),
        ("postponed", "backoff")
    );

    // After the backoff the repair runs again, but an unchanged audit is not
    // rewritten.
    fixture.age_attempt();
    let report = fixture.repair(true, false);
    assert_eq!(report.reason_code, "backup_failed");
    assert_eq!(fixture.audit_id().unwrap(), audit);

    // Changed inputs retry at once.
    let other = fixture.file("plugins/other.json");
    fixture.insert(&format!("source:{other}"), None, &other, 1);
    fixture.block_backups(false);
    let report = fixture.repair(true, false);
    assert_eq!((report.status, report.deleted_rows), ("completed", 2));
    assert_eq!(
        count(
            &open(&fixture.db),
            "select count(*) from app_metadata where key = 'session_cache_repair.v3.attempt'"
        ),
        0
    );
}

#[test]
fn a_repair_killed_during_its_backup_deletes_the_orphan_and_retries_after_the_backoff() {
    let fixture = RepairFixture::new("repair-killed");
    let plugin = fixture.file("plugins/legacy.json");
    fixture.insert(&format!("source:{plugin}"), None, &plugin, 1);
    // The first attempt records its marker; the process then "dies" and leaves
    // a partial backup behind.
    fixture.block_backups(true);
    fixture.repair(true, false);
    fixture.block_backups(false);
    let backups = fixture.temp.path().join("backups");
    std::fs::create_dir_all(&backups).unwrap();
    let stem = fixture
        .db
        .file_stem()
        .unwrap()
        .to_string_lossy()
        .into_owned();
    let orphan = backups.join(format!(
        "{stem}.pre-session-cache-repair-v3.repair-3-1-1.sqlite"
    ));
    std::fs::write(&orphan, "partial").unwrap();
    std::fs::write(backups.join("unrelated.sqlite"), "keep").unwrap();

    let report = fixture.repair(true, false);
    assert_eq!(
        (report.status, report.reason_code),
        ("postponed", "backoff")
    );
    assert!(!orphan.exists(), "the orphaned backup is deleted");
    assert!(backups.join("unrelated.sqlite").exists());

    fixture.age_attempt();
    let report = fixture.repair(true, false);
    assert_eq!((report.status, report.deleted_rows), ("completed", 1));
    let names: Vec<String> = fixture
        .backups()
        .iter()
        .map(|path| path.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names.len(), 2);
    assert!(names.contains(&report.backup_file.clone().unwrap()));
    // The completed repair's backup is kept on later runs.
    assert_eq!(fixture.repair(true, false).status, "already_completed");
    assert_eq!(fixture.backups().len(), 2);
}

#[test]
fn an_unrelated_foreign_key_violation_does_not_block_the_repair() {
    let fixture = RepairFixture::new("repair-unrelated-fk");
    let plugin = fixture.file("plugins/legacy.json");
    fixture.insert(&format!("source:{plugin}"), None, &plugin, 1);
    let conn = open(&fixture.db);
    conn.execute_batch(
        "pragma foreign_keys = off;
         insert into messages (session_id, message_index, author_type, content_preview,
           created_at_db_utc, updated_at_db_utc)
         values ('session:gone', 0, 'user', '', 'now', 'now');
         pragma foreign_keys = on;",
    )
    .unwrap();
    let report = fixture.repair(true, false);
    assert_eq!(
        (report.status, report.reason_code, report.deleted_rows),
        ("completed", "completed", 1)
    );
}

#[test]
fn cache_repair_leaves_claude_rows_with_source_ids_alone() {
    let fixture = RepairFixture::new("repair-claude");
    let plugin = fixture.file("plugins/legacy.json");
    let codex = format!("source:{plugin}");
    let claude = format!("source:{plugin}.claude");
    fixture.insert(&codex, None, &plugin, 1);
    fixture.insert(&claude, None, &plugin, 1);
    open(&fixture.db)
        .execute(
            "update sessions set harness = 'claude' where id = ?",
            [&claude],
        )
        .unwrap();
    let report = fixture.repair(true, false);
    assert_eq!((report.status, report.deleted_rows), ("completed", 1));
    assert_eq!(fixture.ids(), [claude]);
}

/// A scan through the library, counting the writer leases it asks for and
/// noting whether a repair backup existed when each lease was granted.
fn coordinated_scan(db: &Path, home: &Path) -> (usize, Vec<bool>) {
    use codex_sessions_collector::codex::scanner::{ScanOptions, session_scan_roots};
    use codex_sessions_collector::codex::{self, CollectionBatching, parser::SourceType};
    use codex_sessions_collector::path_mapping::PathMapper;
    use codex_sessions_collector::store::{OwnerMode, Store};
    let store = Store::open(db, OwnerMode::Viewer).unwrap();
    let options = ScanOptions {
        roots: session_scan_roots(home.to_str().unwrap(), SourceType::Windows),
        mapper: PathMapper {
            wsl_unc_root: String::new(),
        },
        parser: ParserOptions::default(),
        parser_workers: 1,
        wsl_root_retry_delays: vec![],
        thread_names: std::collections::HashMap::new(),
        force: false,
    };
    let backups = db.parent().unwrap().join("backups");
    let mut leases = 0;
    let mut backup_seen = Vec::new();
    codex::collect_coordinated(
        &store,
        &options,
        false,
        &std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
        |_, _| {},
        |acquire| {
            if acquire {
                leases += 1;
                backup_seen.push(
                    std::fs::read_dir(&backups).is_ok_and(|mut entries| entries.next().is_some()),
                );
            }
            Ok(true)
        },
        CollectionBatching::default(),
    )
    .unwrap();
    (leases, backup_seen)
}

#[test]
fn scans_ask_for_a_placeholder_cleanup_lease_only_when_there_is_something_to_clean() {
    let temp = TempDir::new("placeholder-lease");
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
    let db = viewer_database(&temp);
    coordinated_scan(&db, &home);
    let (clean, _) = coordinated_scan(&db, &home);
    open(&db)
        .execute_batch("update sessions set summary = 'auto'")
        .unwrap();
    let (dirty, _) = coordinated_scan(&db, &home);
    assert_eq!(dirty, clean + 1);
}

#[test]
fn the_repair_backup_is_taken_between_writer_leases() {
    let fixture = RepairFixture::new("repair-lease");
    let plugin = fixture.file("plugins/legacy.json");
    fixture.insert(&format!("source:{plugin}"), None, &plugin, 1);
    let (_, backup_seen) = coordinated_scan(&fixture.db, &fixture.home);
    assert!(fixture.completed());
    // The last lease deletes the rows; the backup already existed when it was
    // granted, and no earlier lease saw it.
    assert_eq!(backup_seen.last(), Some(&true));
    let seen = backup_seen.iter().filter(|seen| **seen).count();
    assert_eq!(seen, 1, "{backup_seen:?}");
}

/// `tool_calls.message_id` of every stored call, as the `message_index` of
/// the message it links (the message that preceded the call).
fn tool_call_origins(conn: &Connection, session: &str) -> Vec<Option<i64>> {
    let mut statement = conn
        .prepare(
            "select m.message_index from tool_calls tc
             left join messages m on m.id = tc.message_id
             where tc.session_id = ? order by tc.tool_index",
        )
        .unwrap();
    statement
        .query_map([session], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

#[test]
fn stored_codex_tool_calls_link_the_message_that_preceded_them() {
    for fixture in ["rich_session.jsonl", "legacy_session.json"] {
        let temp = TempDir::new("codex-tool-links");
        let home = support::codex_home(&temp, &[fixture]);
        let db = viewer_database(&temp);
        let output = support::scan(&db, &home, &[]);
        assert!(output.status.success());
        let parsed = parse_file(
            support::day_folder(&home).join(fixture).to_str().unwrap(),
            ParserOptions::default(),
        )
        .unwrap()
        .session;
        assert!(!parsed.tool_calls.is_empty(), "{fixture}");
        // The parser's `message_index` is the index of the next message after
        // the call; the stored link is the last message before it.
        let expected: Vec<Option<i64>> = parsed
            .tool_calls
            .iter()
            .map(|tool| {
                parsed
                    .messages
                    .iter()
                    .map(|message| message.index)
                    .filter(|index| *index < tool.message_index)
                    .max()
            })
            .collect();
        assert!(expected.iter().any(Option::is_some), "{fixture}");
        let conn = open(&db);
        let session: String = conn
            .query_row("select id from sessions", [], |row| row.get(0))
            .unwrap();
        assert_eq!(tool_call_origins(&conn, &session), expected, "{fixture}");
    }
}

#[test]
fn stored_claude_tool_calls_link_the_message_that_issued_them() {
    use codex_sessions_collector::codex::parser::SourceType;
    use codex_sessions_collector::path_mapping::PathMapper;
    use codex_sessions_collector::store::{OwnerMode, Store};
    let temp = TempDir::new("claude-tool-links");
    let db = viewer_database(&temp);
    let transcript = temp.path().join("c-1.jsonl");
    let lines = [
        json!({"type": "user", "sessionId": "c-1", "timestamp": "2026-09-24T10:00:00Z",
               "message": {"role": "user", "content": "list files"}}),
        json!({"type": "assistant", "sessionId": "c-1", "timestamp": "2026-09-24T10:00:01Z",
               "message": {"model": "claude-x", "content": [
                   {"type": "text", "text": "Listing."},
                   {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"command": "ls"}}]}}),
        json!({"type": "user", "sessionId": "c-1", "timestamp": "2026-09-24T10:00:01Z",
               "message": {"role": "user", "content": [
                   {"type": "tool_result", "tool_use_id": "t1", "content": "a.txt"}]}}),
        json!({"type": "assistant", "sessionId": "c-1", "timestamp": "2026-09-24T10:00:02Z",
               "message": {"model": "claude-x", "content": [{"type": "text", "text": "Done."}]}}),
    ];
    let text: String = lines.iter().map(|line| format!("{line}\n")).collect();
    std::fs::write(&transcript, text).unwrap();
    let store = Store::open(&db, OwnerMode::Viewer).unwrap();
    codex_sessions_collector::claude::collect_file(
        &store,
        &transcript,
        SourceType::Windows,
        &PathMapper {
            wsl_unc_root: String::new(),
        },
        &codex_sessions_collector::claude::parser::ClaudeOptions::default(),
    )
    .unwrap();
    let conn = open(&db);
    let session: String = conn
        .query_row("select id from sessions", [], |row| row.get(0))
        .unwrap();
    // Messages: 0 "list files", 1 "Listing." (issued the call), 2 "Done.".
    assert_eq!(tool_call_origins(&conn, &session), [Some(1)]);
}

#[test]
fn scans_backfill_projects_and_clean_placeholders_the_viewer_no_longer_writes() {
    let temp = TempDir::new("backfill");
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
    let db = viewer_database(&temp);
    let output = support::scan(&db, &home, &[]);
    assert!(output.status.success());
    let conn = open(&db);
    let project: String = conn
        .query_row("select project_name_snapshot from sessions", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert!(!project.is_empty());
    conn.execute_batch(
        "update sessions set detected_project_id = null, project_id = null,
           project_name_snapshot = null, project_override = 0,
           title = '# AGENTS.md instructions', summary = 'auto';
         update session_search set project_name = '', title = '# AGENTS.md instructions', summary = 'auto';",
    )
    .unwrap();
    // The file is unchanged, so only the scan's maintenance touches the row.
    let output = support::scan(&db, &home, &[]);
    assert!(output.status.success());
    let row = support::rows(
        &conn,
        "select s.title, s.summary, s.project_name_snapshot, s.project_override,
           s.detected_project_id is not null as detected, f.project_name, f.title as search_title
         from sessions s join session_search f on f.rowid = s.rowid",
    );
    assert_eq!(
        row,
        [
            json!({"title": null, "summary": null, "project_name_snapshot": project,
                "project_override": 0, "detected": 1, "project_name": project, "search_title": ""})
        ]
    );
}
