//! Fixtures and helpers shared by the collector integration tests.
#![allow(dead_code)]

use std::path::{Path, PathBuf};
use std::process::Output;
mod test_environment;
use std::sync::atomic::{AtomicUsize, Ordering};
#[allow(unused_imports)]
pub use test_environment::{
    TestCommand as Command, command_with_inherited_profile, own_endpoint, temp_dir, test_command,
    test_root,
};

use codex_sessions_collector::contract::{
    MessageRecord, SessionRecord, SessionSnapshot, Source, ToolCallRecord, UsageEventRecord,
    UsageRecord,
};
use codex_sessions_collector::dart::sha256_hex;
use codex_sessions_collector::store::schema::{self, MIGRATIONS};
use rusqlite::Connection;
use rusqlite::types::ValueRef;
use serde_json::{Map, Value, json};

static NEXT: AtomicUsize = AtomicUsize::new(0);

/// A folder removed when dropped.
pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new(label: &str) -> Self {
        // Leave room for Windows SQLite backup names under the shared sandbox.
        let short_label: String = label.chars().take(12).collect();
        let path = temp_dir().join(format!(
            "{}-{short_label}",
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub fn collector() -> Command {
    test_command(env!("CARGO_BIN_EXE_codex-sessions-collector"))
}

/// Opens like the viewer does: WAL journal, foreign keys, 30 s busy wait.
fn open(path: &Path) -> Connection {
    let conn = Connection::open(path).unwrap();
    conn.busy_timeout(std::time::Duration::from_secs(30))
        .unwrap();
    conn.pragma_update(None, "foreign_keys", "on").unwrap();
    let mode: String = conn
        .query_row("pragma journal_mode = wal", [], |row| row.get(0))
        .unwrap();
    assert_eq!(mode, "wal");
    conn
}

/// A database with the viewer's schema, owned by the viewer.
pub fn create_viewer_database(path: &Path) {
    let conn = open(path);
    schema::prepare_standalone(&conn, &path.display().to_string()).unwrap();
    conn.execute(
        "update app_metadata set value = 'viewer' where key = 'database_owner'",
        [],
    )
    .unwrap();
}

pub fn viewer_database(temp: &TempDir) -> PathBuf {
    let path = temp.path().join(format!(
        "viewer-{}.sqlite",
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    create_viewer_database(&path);
    path
}

pub fn viewer_reference_schema(temp: &TempDir) -> PathBuf {
    viewer_database(temp)
}

/// Apply migrations 1..=`version` the way the viewer's migrator records them.
pub fn create_database_at_version(path: &Path, version: i64) {
    let conn = open(path);
    conn.execute_batch(
        "create table if not exists schema_version (
            version integer primary key, filename text not null, checksum text not null,
            applied_at_utc text not null, success integer not null check (success in (0, 1)),
            error_message text)",
    )
    .unwrap();
    for migration in MIGRATIONS.iter().filter(|m| m.version <= version) {
        conn.execute_batch("begin immediate; pragma defer_foreign_keys = on;")
            .unwrap();
        conn.execute_batch(migration.sql).unwrap();
        conn.execute(
            "insert into schema_version (version, filename, checksum, applied_at_utc, success)
             values (?, ?, ?, 'now', 1)",
            rusqlite::params![
                migration.version,
                migration.filename,
                sha256_hex(migration.sql.as_bytes())
            ],
        )
        .unwrap();
        conn.execute_batch("commit").unwrap();
    }
}

pub fn insert_running_usage_migration(path: &Path) {
    open(path)
        .execute(
            "insert into maintenance_jobs (job_type, state, phase, run_token, lease_expires_at_utc,
               updated_at_utc, created_at_utc)
             values ('usage_projection_migration', 'running', 'copy_usage', 'token', 'later', 'now', 'now')",
            [],
        )
        .unwrap();
}

/// A Codex home with `sessions/2026/09/01` holding the named parity fixtures.
pub fn codex_home(temp: &TempDir, fixtures: &[&str]) -> PathBuf {
    let home = temp.path().join("codex-home");
    let day = day_folder(&home);
    std::fs::create_dir_all(&day).unwrap();
    std::fs::create_dir_all(home.join("archived_sessions")).unwrap();
    for name in fixtures {
        std::fs::copy(
            Path::new("../samples/collector-parity/sessions").join(name),
            day.join(name),
        )
        .unwrap();
    }
    home
}

pub fn day_folder(home: &Path) -> PathBuf {
    home.join("sessions").join("2026").join("09").join("01")
}

pub fn scan_command(db: &Path, home: &Path, extra: &[&str]) -> Command {
    let mut command = collector();
    command
        .args(["codex", "scan", "--no-wsl-projects", "--db"])
        .arg(db)
        .arg("--windows-root")
        .arg(home)
        .args(["--wsl-root", ""])
        .args(extra);
    command
}

pub fn scan(db: &Path, home: &Path, extra: &[&str]) -> Output {
    scan_command(db, home, extra).output().unwrap()
}

/// A Codex rollout with `events` token counts and a message per event.
pub fn write_generated_session(path: &Path, session_id: &str, events: usize) {
    let mut text = format!(
        "{{\"timestamp\":\"2026-09-01T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{{\"id\":\"{session_id}\",\"cwd\":\"C:\\\\nonexistent\\\\generated\",\"model_provider\":\"openai\"}}}}\n\
         {{\"timestamp\":\"2026-09-01T00:00:00Z\",\"type\":\"turn_context\",\"payload\":{{\"model\":\"gpt-5.5\"}}}}\n"
    );
    for event in 1..=events {
        let total = event * 100;
        text.push_str(&format!(
            "{{\"timestamp\":\"2026-09-01T00:{:02}:{:02}Z\",\"type\":\"event_msg\",\"payload\":{{\"type\":\"agent_message\",\"message\":\"answer {event} for {session_id}\"}}}}\n",
            event / 60,
            event % 60
        ));
        text.push_str(&format!(
            "{{\"timestamp\":\"2026-09-01T00:{:02}:{:02}Z\",\"type\":\"event_msg\",\"payload\":{{\"type\":\"token_count\",\"info\":{{\"total_token_usage\":{{\"input_tokens\":{total},\"cached_input_tokens\":0,\"output_tokens\":{event},\"reasoning_output_tokens\":0,\"total_tokens\":{}}},\"last_token_usage\":{{\"input_tokens\":100,\"cached_input_tokens\":0,\"output_tokens\":1,\"reasoning_output_tokens\":0,\"total_tokens\":101}}}}}}}}\n",
            event / 60,
            event % 60,
            total + event
        ));
    }
    std::fs::write(path, text).unwrap();
}

pub fn rows(conn: &Connection, sql: &str) -> Vec<Value> {
    let mut statement = conn.prepare(sql).unwrap();
    let names: Vec<String> = statement
        .column_names()
        .iter()
        .map(|name| name.to_string())
        .collect();
    let mut rows = statement.query([]).unwrap();
    let mut result = Vec::new();
    while let Some(row) = rows.next().unwrap() {
        let mut map = Map::new();
        for (index, name) in names.iter().enumerate() {
            let value = match row.get_ref(index).unwrap() {
                ValueRef::Null => Value::Null,
                ValueRef::Integer(value) => json!(value),
                ValueRef::Real(value) => json!(value),
                ValueRef::Text(value) => json!(String::from_utf8_lossy(value)),
                ValueRef::Blob(value) => json!(format!("blob:{}", value.len())),
            };
            map.insert(name.clone(), value);
        }
        result.push(Value::Object(map));
    }
    result
}

pub fn usage_snapshot(db: &Path) -> Vec<Value> {
    rows(
        &open(db),
        "select session_row_id, source_record_ordinal, input_tokens, cached_input_tokens,
           output_tokens, total_tokens, branch_scope, derivation, event_fingerprint
         from usage_events order by session_row_id, source_record_ordinal",
    )
}

const SESSION_TIMESTAMPS: &str = "created_at_utc, updated_at_utc, last_scanned_utc, last_parsed_utc, activity_at_utc, machine_id";

fn without(row: &Value, keys: &str) -> Value {
    let mut row = row.clone();
    for key in keys.split(',') {
        row.as_object_mut().unwrap().remove(key.trim());
    }
    row
}

/// Stored content that must not depend on when or in which order it was
/// written: timestamps and autoincrement IDs are replaced by natural keys.
pub fn content_snapshot(db: &Path) -> Value {
    content(db, true)
}

pub fn content_snapshot_without_projects(db: &Path) -> Value {
    content(db, false)
}

fn content(db: &Path, include_projects: bool) -> Value {
    let conn = open(db);
    let mut project_columns = "project_id, detected_project_id".to_owned();
    if !include_projects {
        project_columns.push_str(", project_name_snapshot, scan_status");
    }
    let sessions: Vec<Value> = rows(
        &conn,
        "select s.*, p.name as project_name, d.name as detected_project_name
         from sessions s left join projects p on p.id = s.project_id
         left join projects d on d.id = s.detected_project_id order by s.id",
    )
    .iter()
    .map(|row| without(&without(row, SESSION_TIMESTAMPS), &project_columns))
    .map(|row| {
        if include_projects {
            row
        } else {
            without(&row, "project_name, detected_project_name")
        }
    })
    .collect();
    let messages: Vec<Value> = rows(
        &conn,
        "select * from messages order by session_id, message_index",
    )
    .iter()
    .map(|row| without(row, "id, created_at_db_utc, updated_at_db_utc"))
    .collect();
    let tools: Vec<Value> = rows(
        &conn,
        "select * from tool_calls order by session_id, tool_index",
    )
    .iter()
    .map(|row| without(row, "id"))
    .collect();
    let events = rows(
        &conn,
        "select e.*, c.display_path_key, c.platform_path_key, c.unc_path_key
         from usage_events e join usage_path_contexts c on c.id = e.path_context_id
         order by e.session_row_id, e.source_record_ordinal",
    )
    .iter()
    .map(|row| without(row, "path_context_id"))
    .collect::<Vec<_>>();
    let inputs = rows(
        &conn,
        "select * from usage_event_inputs order by session_row_id, source_record_ordinal",
    );
    let daily = rows(
        &conn,
        "select d.session_id, d.day_utc, d.model_key, c.display_path_key, d.branch_scope,
           d.input_tokens, d.cached_input_tokens, d.cache_write_input_tokens, d.output_tokens,
           d.reasoning_output_tokens, d.total_tokens, d.estimated_cost_text, d.cost_status
         from usage_session_daily d join usage_path_contexts c on c.id = d.path_context_id
         order by d.session_id, d.day_utc, d.model_key, c.display_path_key, d.branch_scope",
    );
    let dirty = rows(
        &conn,
        "select session_id, day_utc, model_key, reason, target_cost_projection_version
         from usage_cost_dirty_partitions order by session_id, day_utc, model_key",
    );
    let path_keys = rows(
        &conn,
        "select * from session_path_keys order by session_id, path_key",
    );
    let search = rows(
        &conn,
        "select s.id, f.title, f.summary, f.tool_names, f.display_path, f.normalized_path_keys,
           f.project_name, f.tags
         from session_search f join sessions s on s.rowid = f.rowid order by s.id",
    );
    let message_search = rows(
        &conn,
        "select session_id, message_index from messages
         where rowid in (select rowid from message_search where message_search match 'the OR parser OR tool')
         order by session_id, message_index",
    );
    let contexts = rows(
        &conn,
        "select c.display_path_raw, c.platform_path_raw, c.unc_path_raw, c.resolution_source,
           d.name as detected, e.name as effective
         from usage_path_contexts c left join projects d on d.id = c.detected_project_id
         left join projects e on e.id = c.effective_project_id
         order by c.display_path_raw, c.platform_path_raw, c.unc_path_raw",
    );
    let mut value = json!({
        "sessions": sessions,
        "messages": messages,
        "tool_calls": tools,
        "usage_events": events,
        "usage_event_inputs": inputs,
        "usage_session_daily": daily,
        "usage_cost_dirty_partitions": dirty,
        "session_path_keys": path_keys,
        "session_search": search,
        "message_search": message_search,
    });
    if include_projects {
        value["usage_path_contexts"] = json!(contexts);
        value["projects"] = json!(rows(
            &conn,
            "select name, description, is_active from projects order by name"
        ));
    }
    value
}

pub fn schema_objects(db: &Path) -> Vec<Value> {
    rows(
        &open(db),
        "select type, name, tbl_name from sqlite_schema
         where name not like 'sqlite_%' order by type, name",
    )
}

/// A contract snapshot for a synthetic session with two usage events.
pub fn sample_snapshot(session_id: &str) -> SessionSnapshot {
    SessionSnapshot {
        harness: "codex".to_owned(),
        machine_id: None,
        source: Source {
            path: format!("C:\\synthetic\\{session_id}.jsonl"),
            environment: "windows".to_owned(),
            state: "active".to_owned(),
            status: "available".to_owned(),
            size: 100,
            modified_utc: "2026-09-10T10:00:00.000Z".to_owned(),
            display_path: format!("C:\\synthetic\\{session_id}.jsonl"),
            mapped_source_file_path: format!("C:\\synthetic\\{session_id}.jsonl"),
            unc_path: None,
            platform_path: format!("C:\\synthetic\\{session_id}.jsonl"),
            normalized_path_keys: vec![format!("c:/synthetic/{session_id}.jsonl")],
        },
        session: SessionRecord {
            session_id: Some(session_id.to_owned()),
            usage_projection_status: "complete".to_owned(),
            working_directory_display: Some("C:\\nonexistent\\synthetic".to_owned()),
            working_directory_platform: Some("C:\\nonexistent\\synthetic".to_owned()),
            title: Some("Synthetic".to_owned()),
            started_at_utc: Some("2026-09-10T10:00:00Z".to_owned()),
            last_message_at_utc: Some("2026-09-10T10:05:00Z".to_owned()),
            models: vec!["model-a".to_owned()],
            usage: UsageRecord {
                input_tokens: Some(300),
                output_tokens: Some(30),
                ..UsageRecord::default()
            },
            parser_version: 4,
            ..SessionRecord::default()
        },
        messages: vec![MessageRecord {
            index: 0,
            author_type: "user".to_owned(),
            raw_type: Some("user_message".to_owned()),
            created_at_utc: Some("2026-09-10T10:00:01Z".to_owned()),
            first_line: "hello".to_owned(),
            content_plain: "hello".to_owned(),
            content_preview: "hello".to_owned(),
            content_truncated: false,
            usage: UsageRecord::default(),
            model: None,
            has_tool_calls: false,
            has_error: false,
        }],
        tool_calls: vec![ToolCallRecord {
            tool_index: 0,
            message_index: Some(1),
            tool_name: "shell".to_owned(),
            status: "finished".to_owned(),
            started_at_utc: None,
            finished_at_utc: None,
            input_preview: String::new(),
            output_preview: "ok".to_owned(),
            output_truncated: false,
            error_message: None,
        }],
        usage_events: (1..=2)
            .map(|ordinal| UsageEventRecord {
                source_record_ordinal: ordinal,
                rollout_ordinal: None,
                turn_ordinal: Some(0),
                counter_epoch: 0,
                occurred_at_utc: Some(format!("2026-09-10T10:0{ordinal}:00Z")),
                model: Some("model-a".to_owned()),
                provider: None,
                working_directory: Some("C:\\nonexistent\\synthetic".to_owned()),
                working_directory_unc: None,
                usage: UsageRecord {
                    input_tokens: Some(150),
                    output_tokens: Some(15),
                    ..UsageRecord::default()
                },
                request_input_tokens: None,
                model_context_window: None,
                billable_units: None,
                derivation: "last_token_usage".to_owned(),
                branch_scope: "local".to_owned(),
                event_fingerprint: sha256_hex(format!("{session_id}-{ordinal}").as_bytes()),
            })
            .collect(),
        project_hints: Vec::new(),
        extra: None,
    }
}

fn differences(path: &str, expected: &Value, actual: &Value, found: &mut Vec<String>) {
    if found.len() >= 12 {
        return;
    }
    match (expected, actual) {
        (Value::Object(left), Value::Object(right)) => {
            for (key, value) in left {
                differences(
                    &format!("{path}.{key}"),
                    value,
                    right.get(key).unwrap_or(&Value::Null),
                    found,
                );
            }
            for key in right.keys().filter(|key| !left.contains_key(*key)) {
                found.push(format!("{path}.{key}: only in actual"));
            }
        }
        (Value::Array(left), Value::Array(right)) => {
            for (index, (value, other)) in left.iter().zip(right).enumerate() {
                differences(&format!("{path}[{index}]"), value, other, found);
            }
            if left.len() != right.len() {
                found.push(format!("{path}: length {} != {}", left.len(), right.len()));
            }
        }
        _ if expected != actual => found.push(format!("{path}: {expected} != {actual}")),
        _ => {}
    }
}

/// Assert equal JSON, reporting the first differing paths instead of both values.
pub fn assert_same(expected: &Value, actual: &Value) {
    let mut found = Vec::new();
    differences("$", expected, actual, &mut found);
    assert!(
        found.is_empty(),
        "content differs:
{}",
        found.join(
            "
"
        )
    );
}

pub fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), target).unwrap();
        }
    }
}

/// A Claude projects folder holding the sample transcripts.
pub fn claude_root(temp: &TempDir) -> PathBuf {
    let root = temp.path().join("claude-projects");
    copy_tree(Path::new("../samples/claude/projects"), &root);
    root
}

/// Lines a coordinated scan wrote to stdout, read with a deadline so a
/// collector that stops responding fails the test instead of hanging it.
pub struct EventStream {
    receiver: std::sync::mpsc::Receiver<String>,
}

impl EventStream {
    pub fn new(stdout: std::process::ChildStdout) -> Self {
        use std::io::BufRead;
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for line in std::io::BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        Self { receiver }
    }

    /// The next event, or `None` at end of output.
    pub fn next(&self, child: &mut std::process::Child) -> Option<Value> {
        match self
            .receiver
            .recv_timeout(std::time::Duration::from_secs(30))
        {
            Ok(line) => Some(serde_json::from_str(&line).unwrap()),
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => None,
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                let _ = child.kill();
                panic!("the collector stopped responding");
            }
        }
    }
}
