use codex_sessions_collector::{
    claude,
    codex::parser::SourceType,
    path_mapping::PathMapper,
    resume::{ResumePolicy, ResumePolicyScope},
    store::{OwnerMode, Store},
};

#[test]
fn ingest_persists_checkpoint_and_resumes() {
    let dir = super::support::TempDir::new("resume-store");
    let path = dir.path().join("transcript.jsonl");
    let db = dir.path().join("store.sqlite");
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let store = Store::open(&db, OwnerMode::Standalone).unwrap();
    let line = |text: &str| {
        format!(
            "{{\"type\":\"user\",\"sessionId\":\"resume-test\",\"message\":{{\"role\":\"user\",\"content\":\"{text}\"}}}}\n"
        )
    };
    std::fs::write(&path, line("first")).unwrap();
    let ingest = || {
        claude::collect_file(
            &store,
            &path,
            SourceType::Windows,
            &PathMapper::new(""),
            &Default::default(),
        )
        .unwrap()
    };
    assert_eq!(ingest().counts.files_parsed, 1);
    let steps = || {
        store
            .conn
            .query_row("select state from session_parse_checkpoints", [], |r| {
                r.get::<_, Vec<u8>>(0)
            })
            .unwrap()
    };
    assert!(!steps().is_empty());
    std::fs::write(&path, line("first") + &line("second")).unwrap();
    assert_eq!(ingest().counts.files_parsed, 1);
    assert_eq!(
        store
            .conn
            .query_row("select message_count from sessions", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        2
    );
}

#[test]
fn scoped_echo_update_preserves_resolved_tool_and_search() {
    let _budget = fast_writes();
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = super::support::TempDir::new("echo-link");
    let path = dir.path().join("session.jsonl");
    let a = configured(&dir.path().join("a.sqlite"));
    let b = configured(&dir.path().join("b.sqlite"));
    let (prefix, suffix) = super::session_gen::echo_with_resolved_tool();
    std::fs::write(&path, &prefix).unwrap();
    ingest(&a, &path, false, SourceType::Windows);
    let original: i64 = a
        .conn
        .query_row("select message_id from tool_calls", [], |r| r.get(0))
        .unwrap();
    std::fs::write(&path, [prefix, suffix].concat()).unwrap();
    ingest(&a, &path, false, SourceType::Windows);
    ingest(&b, &path, false, SourceType::Windows);
    assert_eq!(
        a.conn
            .query_row("select count(*) from tool_calls", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        1
    );
    assert_eq!(
        a.conn
            .query_row("select message_id from tool_calls", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        original
    );
    assert_eq!(
        a.conn
            .query_row(
                "select count(*) from message_search where message_search match 'echo'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
        1
    );
    compare(
        &a,
        &b,
        "resolved tool survives authoritative echo replacement",
    );
}

#[test]
fn cli_ingest_resumes_unless_explicitly_forced() {
    let dir = super::support::TempDir::new("cli-resume");
    let path = dir.path().join("session.jsonl");
    let db = dir.path().join("store.sqlite");
    let settings = dir.path().join("settings.toml");
    std::fs::write(&settings, "").unwrap();
    let (mut prefix, suffix) = super::session_gen::echo_with_resolved_tool();
    prefix.extend(std::iter::repeat_n(b'\n', 1024 * 1024));
    std::fs::write(&path, &prefix).unwrap();
    let run = |force: bool| {
        let mut command = super::support::collector();
        command
            .args(["codex", "ingest", "--standalone"])
            .arg(&db)
            .arg("--settings")
            .arg(&settings)
            .args(["--no-wsl-projects", "--windows-root"])
            .arg(dir.path())
            .args(["--wsl-root", ""]);
        if force {
            command.arg("--force");
        }
        let result = command.arg(&path).output().unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
    };
    run(false);
    std::fs::write(&path, [prefix, suffix].concat()).unwrap();
    run(false);
    codex_sessions_collector::store::connection::ensure().unwrap();
    let conn = Connection::open(&db).unwrap();
    let steps = || {
        conn.query_row(
            "select steps_since_full from session_parse_checkpoints",
            [],
            |r| r.get::<_, i64>(0),
        )
        .unwrap()
    };
    assert_eq!(
        steps(),
        1,
        "single-file CLI ingest must not force full parsing"
    );
    assert_eq!(
        conn.query_row("select count(*) from tool_calls", [], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        1
    );
    run(true);
    assert_eq!(steps(), 0, "explicit --force starts a fresh full parse");
}

#[test]
fn cli_unchanged_ingest_succeeds_both_harnesses() {
    let dir = super::support::TempDir::new("cli-skip");
    let file = dir.path().join("session.jsonl");
    let settings = dir.path().join("settings.toml");
    std::fs::write(&settings, "").unwrap();
    for claude in [false, true] {
        let harness = if claude { "claude" } else { "codex" };
        let db = dir.path().join(format!("{harness}.sqlite"));
        std::fs::write(&file, tool_source(claude).0).unwrap();
        for expected in [1, 0] {
            let result = super::support::collector()
                .args([harness, "ingest", "--standalone"])
                .arg(&db)
                .arg("--settings")
                .arg(&settings)
                .args(["--json", "--no-wsl-projects"])
                .arg(&file)
                .output()
                .unwrap();
            assert!(
                result.status.success(),
                "{}",
                String::from_utf8_lossy(&result.stderr)
            );
            let report: Value = serde_json::from_slice(&result.stdout).unwrap();
            assert_eq!(report["files_parsed"], expected);
            assert_eq!(report["files_skipped"], 1 - expected);
        }
    }
}

use codex_sessions_collector::codex::scanner::{ScanOptions, ScanRoot};
use codex_sessions_collector::store::writer;
use codex_sessions_collector::{codex, hub_snapshot, resume, store::checkpoints};
use rusqlite::Connection;
use serde_json::{Value, json};
use std::path::Path;
use std::time::{Duration, Instant};

fn fast_writes() -> codex_sessions_collector::store::write_budget::WriteBudgetScope {
    let budget = codex_sessions_collector::store::write_budget::WriteBudget {
        gap: Duration::ZERO,
        ..Default::default()
    };
    codex_sessions_collector::store::write_budget::WriteBudgetScope::enter(budget)
}
fn options(path: &Path, source_type: SourceType) -> ScanOptions {
    ScanOptions {
        roots: vec![ScanRoot {
            path: path.display().to_string(),
            availability_root_path: None,
            source_type,
            source_state: "active",
        }],
        mapper: PathMapper::new(""),
        parser: Default::default(),
        parser_workers: 2,
        wsl_root_retry_delays: vec![],
        thread_names: Default::default(),
        force: false,
    }
}
fn ingest(
    store: &Store,
    path: &Path,
    claude: bool,
    source_type: SourceType,
) -> codex::CollectReport {
    try_ingest(store, path, claude, source_type).unwrap()
}
fn try_ingest(
    store: &Store,
    path: &Path,
    claude: bool,
    source_type: SourceType,
) -> codex_sessions_collector::store::StoreResult<codex::CollectReport> {
    if claude {
        claude::collect_file(
            store,
            path,
            source_type,
            &PathMapper::new(""),
            &Default::default(),
        )
    } else {
        let options = options(path, source_type);
        codex::collect_file_with(store, &options, &options.roots[0], |_| Default::default())
    }
}
fn configured(db: &Path) -> Store {
    let store = Store::open(db, OwnerMode::Standalone).unwrap();
    store
        .conn
        .execute(
            "update app_metadata set value='fixture-machine' where key='machine_id'",
            [],
        )
        .unwrap();
    store.conn.execute("insert into collector_hub_state (id,hub_url,machine_id) values (1,'http://127.0.0.1:1','fixture-machine')", []).unwrap();
    store
}
fn remove(row: &mut Value, columns: &[&str]) {
    for column in columns {
        row.as_object_mut().unwrap().remove(*column);
    }
}
fn table(conn: &Connection, name: &str) -> Vec<Value> {
    let mut result = super::support::rows(conn, &format!("select * from {name}"));
    for row in &mut result {
        match name {
            "sessions" => {
                remove(
                    row,
                    &[
                        "content_hash",
                        "created_at_utc",
                        "updated_at_utc",
                        "last_scanned_utc",
                        "last_parsed_utc",
                    ],
                );
                if row["started_at_utc"].is_null() && row["last_message_at_utc"].is_null() {
                    remove(row, &["activity_at_utc"]);
                }
                for column in ["project_id", "detected_project_id"] {
                    if let Some(id) = row[column].as_i64() {
                        row[column] = json!(
                            conn.query_row("select name from projects where id=?", [id], |r| {
                                r.get::<_, String>(0)
                            })
                            .unwrap()
                        );
                    }
                }
            }
            "messages" => remove(row, &["id", "created_at_db_utc", "updated_at_db_utc"]),
            "tool_calls" => {
                if let Some(id) = row["message_id"].as_i64() {
                    row["message_id"] = json!(
                        conn.query_row(
                            "select message_index from messages where id=?",
                            [id],
                            |r| r.get::<_, i64>(0)
                        )
                        .unwrap()
                    );
                }
                remove(row, &["id"]);
            }
            "usage_session_daily" | "session_source_extras" => remove(row, &["updated_at_utc"]),
            "usage_cost_dirty_partitions" => remove(row, &["created_at_utc", "updated_at_utc"]),
            "projects" => remove(row, &["id", "created_at_utc", "updated_at_utc"]),
            "usage_path_contexts" => remove(row, &["id", "created_at_utc", "updated_at_utc"]),
            _ => {}
        }
        if let Some(id) = row["path_context_id"].as_i64() {
            row["path_context_id"] = json!(super::support::rows(
                conn,
                &format!(
                    "select display_path_key,platform_path_key,unc_path_key from usage_path_contexts where id={id}"
                )
            ));
            for context in row["path_context_id"].as_array_mut().unwrap() {
                if let Some(project) = context["project_id"].as_i64() {
                    context["project_id"] = json!(
                        conn.query_row("select name from projects where id=?", [project], |r| {
                            r.get::<_, String>(0)
                        })
                        .unwrap()
                    );
                }
            }
        }
        if name == "usage_path_contexts" {
            for column in [
                "detected_project_id",
                "mask_project_id",
                "effective_project_id",
            ] {
                if let Some(project) = row[column].as_i64() {
                    row[column] = json!(
                        conn.query_row("select name from projects where id=?", [project], |r| {
                            r.get::<_, String>(0)
                        })
                        .unwrap()
                    );
                }
            }
        }
    }
    result.sort_by_key(Value::to_string);
    result
}
const STORED_TABLES: &[&str] = &[
    "sessions",
    "messages",
    "tool_calls",
    "usage_events",
    "usage_event_inputs",
    "usage_session_daily",
    "usage_cost_dirty_partitions",
    "session_search",
    "session_path_keys",
    "session_source_extras",
    "projects",
    "usage_path_contexts",
];

fn compare_rows(a: &Store, b: &Store, label: &str) {
    for &name in STORED_TABLES {
        let left = table(&a.conn, name);
        let right = table(&b.conn, name);
        if left != right {
            eprintln!("DB mismatch {label}: {name}");
            super::support::assert_same(&json!(left), &json!(right));
        }
    }
    let ids = super::support::rows(&a.conn, "select id from sessions order by id");
    for id in ids {
        let id = id["id"].as_str().unwrap();
        assert_eq!(
            serde_json::to_value(
                hub_snapshot::build(&a.conn, id, hub_snapshot::Children::Include).unwrap()
            )
            .unwrap(),
            serde_json::to_value(
                hub_snapshot::build(&b.conn, id, hub_snapshot::Children::Include).unwrap()
            )
            .unwrap(),
            "{label}: hub rows"
        );
    }
    for store in [a, b] {
        for row in super::support::rows(
            &store.conn,
            "select content_hash from sessions where content_hash is not null",
        ) {
            let hash = row["content_hash"].as_str().unwrap();
            assert!(hash.len() == 64 && hash.bytes().all(|b| b.is_ascii_hexdigit()));
        }
    }
}

fn compare(a: &Store, b: &Store, label: &str) {
    compare_rows(a, b, label);
    let cp = |store: &Store| {
        let mut values = Vec::new();
        let mut stmt=store.conn.prepare("select harness,source_file_path,parser_version,format_version,consumed_bytes,state from session_parse_checkpoints order by harness,source_key").unwrap();
        let records = stmt
            .query_map([], |r| {
                Ok(resume::CheckpointRecord {
                    harness: r.get(0)?,
                    source_path: r.get(1)?,
                    parser_version: r.get(2)?,
                    format_version: r.get(3)?,
                    consumed_bytes: r.get::<_, i64>(4)? as u64,
                    state: r.get(5)?,
                })
            })
            .unwrap();
        for record in records {
            let mut value = serde_json::to_value(record.unwrap().decode().unwrap()).unwrap();
            remove(&mut value, &["windows", "steps_since_full"]);
            values.push(value);
        }
        values
    };
    assert_eq!(cp(a), cp(b), "{label}: checkpoint");
}

#[test]
fn database_seeded_fixture_differential() {
    let _budget = fast_writes();
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let started = Instant::now();
    // Reuse immutable schema setup, never mutable session state. Every case
    // still opens isolated, file-backed WAL databases and the real writer.
    let template_dir = super::support::TempDir::new("db-template");
    let template = template_dir.path().join("empty.sqlite");
    drop(configured(&template));
    let mut steps = 0;
    let mut errors = 0;
    let mut resumed = 0;
    let exhaustive = super::session_gen::exhaustive();
    for (n, input) in super::session_gen::inputs().into_iter().enumerate() {
        if !exhaustive
            && !(input.name.contains("seed-1-")
                || input.name.contains("extreme-values")
                || input.name.contains("rich_session")
                || input.name.contains("malformed_line")
                || input.name.contains("agent-a1b2c3")
                || input
                    .name
                    .contains("11111111-2222-4333-8444-555555555555.jsonl"))
        {
            continue;
        }
        let chains = if exhaustive {
            let mut chains = super::session_gen::chains(&input.bytes, n as u64 + 1);
            chains.truncate(chains.len().saturating_sub(40)); // all boundary chains + 10 seeded chains
            chains
        } else {
            let first = input
                .bytes
                .iter()
                .position(|b| *b == b'\n')
                .map_or(input.bytes.len(), |i| i + 1);
            let mut cuts = vec![
                first.saturating_sub(1),
                first,
                input.bytes.len() / 2,
                input.bytes.len(),
            ];
            cuts.sort_unstable();
            cuts.dedup();
            vec![cuts]
        };
        for (chain_index, chain) in chains.into_iter().enumerate() {
            for source_type in [SourceType::Windows, SourceType::Wsl] {
                let dir = super::support::TempDir::new("db-diff");
                let path = dir.path().join(format!("session.{}", input.extension));
                let open = |name: &str| {
                    let db = dir.path().join(name);
                    std::fs::copy(&template, &db).unwrap();
                    Store::open(&db, OwnerMode::Standalone).unwrap()
                };
                let a = open("a.sqlite");
                let b = open("b.sqlite");
                for &cut in &chain {
                    std::fs::write(&path, &input.bytes[..cut]).unwrap();
                    b.conn
                        .execute("delete from session_parse_checkpoints", [])
                        .unwrap();
                    a.conn
                        .execute("delete from collector_upload_outbox", [])
                        .unwrap();
                    b.conn
                        .execute("delete from collector_upload_outbox", [])
                        .unwrap();
                    let x = try_ingest(&a, &path, input.claude, source_type);
                    let y = try_ingest(&b, &path, input.claude, source_type);
                    let (x, y) = match (x, y) {
                        (Ok(x), Ok(y)) => (x, y),
                        (Err(x), Err(y)) => {
                            assert_eq!(
                                x.to_string(),
                                y.to_string(),
                                "{} cut={cut}: SQL rejection parity",
                                input.name
                            );
                            compare_rows(
                                &a,
                                &b,
                                &format!("{} cut={cut}: rejected ingest", input.name),
                            );
                            errors += 1;
                            steps += 1;
                            continue;
                        }
                        (x, y) => {
                            panic!("{} cut={cut}: ingest result parity {x:?} {y:?}", input.name)
                        }
                    };
                    assert_eq!(
                        x.counts.files_failed, y.counts.files_failed,
                        "{} chain={chain_index} cut={cut}",
                        input.name
                    );
                    steps += 1;
                    if x.counts.files_failed > 0 {
                        // Failed parsing still changes source status and may
                        // retain earlier children. Compare them too; only the
                        // reference's deliberately discarded checkpoint differs.
                        compare_rows(&a, &b, &format!("{} cut={cut}: parse failure", input.name));
                        errors += 1;
                    } else {
                        let references = |store: &Store| {
                            super::support::rows(
                                &store.conn,
                                "select record_key from collector_upload_outbox where record_json = '{\"outbox_ref\":\"session_snapshot\"}' order by record_key",
                            )
                        };
                        assert_eq!(
                            references(&a),
                            references(&b),
                            "{} cut={cut}: session references",
                            input.name
                        );
                        let refs = references(&a);
                        let keys: std::collections::HashSet<_> = refs
                            .iter()
                            .map(|r| r["record_key"].as_str().unwrap())
                            .collect();
                        assert_eq!(keys.len(), refs.len());
                        compare(
                            &a,
                            &b,
                            &format!(
                                "{} {source_type:?} chain={chain_index} cut={cut}",
                                input.name
                            ),
                        );
                        resumed += checkpoints::index(
                            &a.conn,
                            if input.claude { "claude" } else { "codex" },
                        )
                        .unwrap()
                        .values()
                        .filter(|c| c.steps_since_full > 0)
                        .count();
                    }
                }
            }
        }
    }
    assert!(resumed > 0 && errors > 0);
    eprintln!(
        "DB differential exhaustive={exhaustive} seeds=1..{} chains-per-input={} steps={steps} resumed={resumed} errors={errors} elapsed={:?}",
        super::session_gen::seed_count(),
        if exhaustive {
            "all boundaries plus 10 seeded"
        } else {
            "1 bounded chain"
        },
        started.elapsed()
    );
}

#[test]
fn idle_scan_runs_one_full_parse_then_skips_both_harnesses() {
    let _budget = fast_writes();
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    for (claude, partial) in [(false, false), (true, false), (true, true)] {
        let dir = super::support::TempDir::new("settle");
        let source_root = dir.path().join("sessions");
        std::fs::create_dir(&source_root).unwrap();
        let project = source_root.join("project");
        std::fs::create_dir(&project).unwrap();
        let path = project.join("session.jsonl");
        let store = configured(&dir.path().join("a.sqlite"));
        let line = |n| {
            let value = if claude {
                json!({"type":"user","message":{"content":format!("message {n}")}})
            } else {
                json!({"type":"response_item","payload":{"type":"message","role":"user","content":format!("message {n}")}})
            };
            value.to_string() + "\n"
        };
        let scan = || {
            if claude {
                claude::collect(
                    &store,
                    &claude::ClaudeScanOptions {
                        roots: vec![claude::ClaudeRoot {
                            path: source_root.display().to_string(),
                            source_type: SourceType::Windows,
                        }],
                        mapper: PathMapper::new(""),
                        parser: Default::default(),
                        workers: 2,
                        force: false,
                        resolve_wsl_projects: false,
                    },
                )
                .unwrap()
            } else {
                codex::collect(&store, &options(&source_root, SourceType::Windows), false).unwrap()
            }
        };
        std::fs::write(&path, line(1)).unwrap();
        ingest(&store, &path, claude, SourceType::Windows);
        std::fs::write(
            &path,
            line(1) + &line(2) + if partial { "{\"type\":\"user\"" } else { "" },
        )
        .unwrap();
        assert_eq!(scan().counts.files_parsed, 1);
        let harness = if claude { "claude" } else { "codex" };
        assert!(
            checkpoints::index(&store.conn, harness)
                .unwrap()
                .values()
                .any(|c| c.steps_since_full > 0)
        );

        assert_eq!(scan().counts.files_parsed, 1);
        assert!(
            checkpoints::index(&store.conn, harness)
                .unwrap()
                .values()
                .all(|c| c.steps_since_full == 0)
        );
        assert_eq!(scan().counts.files_parsed, 0);
        let b = configured(&dir.path().join("b.sqlite"));
        ingest(&b, &path, claude, SourceType::Windows);
        compare(&store, &b, "idle full convergence");
    }
}

fn checkpoint_rows(store: &Store) -> Vec<Value> {
    super::support::rows(
        &store.conn,
        "select *, hex(state) as state_hex from session_parse_checkpoints order by source_key",
    )
}

#[test]
fn unchanged_subagent_parent_ingest_preserves_checkpoint_until_idle_scan() {
    // CXV-215-P2-01: the reviewer's main + 1 MiB child reproduction, with
    // reopened stores between visits so the obligation must be durable.
    let _budget = fast_writes();
    for (partial, missing_blob) in [(false, false), (true, false), (true, true)] {
        let dir = super::support::TempDir::new("child-idle");
        let root = dir.path().join("sources");
        let project = root.join("project");
        let child_dir = project.join("11111111-2222-4333-8444-555555555555/subagents");
        std::fs::create_dir_all(&child_dir).unwrap();
        let main = project.join("11111111-2222-4333-8444-555555555555.jsonl");
        let child = child_dir.join("agent-a1b2c3.jsonl");
        let db = dir.path().join("store.sqlite");
        let line = |text, agent| {
            let mut value = json!({"type":"user","sessionId":"11111111-2222-4333-8444-555555555555","timestamp":"2026-09-20T10:01:00Z","message":{"role":"user","content":text}});
            if agent {
                value["agentId"] = json!("a1b2c3");
                value["isSidechain"] = json!(true);
            }
            value.to_string() + "\n"
        };
        std::fs::write(&main, line("main", false)).unwrap();
        let prefix = line("first", true) + &"\n".repeat(1024 * 1024);
        std::fs::write(&child, &prefix).unwrap();
        {
            let store = configured(&db);
            assert_eq!(
                ingest(&store, &main, true, SourceType::Windows)
                    .counts
                    .files_parsed,
                2
            );
        }
        std::fs::write(
            &child,
            prefix + &line("second", true) + if partial { "{\"type\":" } else { "" },
        )
        .unwrap();
        let before = {
            let store = Store::open(&db, OwnerMode::Standalone).unwrap();
            ingest(&store, &main, true, SourceType::Windows);
            let rows = checkpoint_rows(&store);
            assert_eq!(rows[0]["steps_since_full"], 1);
            if missing_blob {
                store
                    .conn
                    .execute("update session_parse_checkpoints set state=x''", [])
                    .unwrap();
            }
            checkpoint_rows(&store)
        };
        for _ in 0..2 {
            let store = Store::open(&db, OwnerMode::Standalone).unwrap();
            let changes = store.conn.total_changes();
            let report = ingest(&store, &main, true, SourceType::Windows);
            assert_eq!(
                checkpoint_rows(&store),
                before,
                "unchanged visits must not rewrite receipts"
            );
            assert_eq!(
                (report.counts.files_parsed, report.counts.files_skipped),
                (0, 2),
                "unchanged parent and child must skip"
            );
            assert_eq!(
                store.conn.total_changes(),
                changes,
                "skip must write nothing"
            );
        }
        // A newly changed parent must still visit and skip its unchanged child.
        std::fs::write(&main, line("main", false) + &line("main again", false)).unwrap();
        {
            let store = Store::open(&db, OwnerMode::Standalone).unwrap();
            let report = ingest(&store, &main, true, SourceType::Windows);
            assert_eq!(
                (report.counts.files_parsed, report.counts.files_skipped),
                (1, 1)
            );
            assert_eq!(checkpoint_rows(&store), before);
        }
        let scan_options = claude::ClaudeScanOptions {
            roots: vec![claude::ClaudeRoot {
                path: root.display().to_string(),
                source_type: SourceType::Windows,
            }],
            mapper: PathMapper::new(""),
            parser: Default::default(),
            workers: 1,
            force: false,
            resolve_wsl_projects: false,
        };
        for expected in [1, 0] {
            let store = Store::open(&db, OwnerMode::Standalone).unwrap();
            assert_eq!(
                claude::collect(&store, &scan_options)
                    .unwrap()
                    .counts
                    .files_parsed,
                expected
            );
            assert!(
                checkpoints::index(&store.conn, "claude")
                    .unwrap()
                    .values()
                    .all(|cp| cp.steps_since_full == 0)
            );
        }
        let store = Store::open(&db, OwnerMode::Standalone).unwrap();
        let reference = configured(&dir.path().join("full.sqlite"));
        ingest(&reference, &main, true, SourceType::Windows);
        compare_rows(&store, &reference, "subagent idle full convergence");
        assert_eq!(
            ingest(&store, &main, true, SourceType::Windows)
                .counts
                .files_parsed,
            0
        );
    }
}

#[test]
fn unchanged_direct_ingests_skip_both_harnesses_without_checkpoint_writes() {
    let _budget = fast_writes();
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    for claude in [false, true] {
        let dir = super::support::TempDir::new("direct-skip");
        let file = dir.path().join("session.jsonl");
        let db = dir.path().join("store.sqlite");
        let (prefix, suffix) = tool_source(claude);
        std::fs::write(&file, &prefix).unwrap();
        {
            let store = configured(&db);
            ingest(&store, &file, claude, SourceType::Windows);
        }
        std::fs::write(&file, [prefix, suffix].concat()).unwrap();
        let before = {
            let store = Store::open(&db, OwnerMode::Standalone).unwrap();
            ingest(&store, &file, claude, SourceType::Windows);
            let rows = checkpoint_rows(&store);
            assert_eq!(rows[0]["steps_since_full"], 1);
            rows
        };
        for _ in 0..2 {
            let store = Store::open(&db, OwnerMode::Standalone).unwrap();
            let changes = store.conn.total_changes();
            let report = ingest(&store, &file, claude, SourceType::Windows);
            assert_eq!(
                (report.counts.files_parsed, report.counts.files_skipped),
                (0, 1)
            );
            assert_eq!(checkpoint_rows(&store), before);
            assert_eq!(store.conn.total_changes(), changes);
        }
    }
}

#[test]
fn tail_only_growth_does_not_rewrite_checkpoint_both_harnesses() {
    let _budget = fast_writes();
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    for claude in [false, true] {
        let dir = super::support::TempDir::new("tail-no-step");
        let file = dir.path().join("session.jsonl");
        let store = configured(&dir.path().join("store.sqlite"));
        let (prefix, suffix) = tool_source(claude);
        std::fs::write(&file, &prefix).unwrap();
        ingest(&store, &file, claude, SourceType::Windows);
        let before = checkpoint_rows(&store);
        // A complete JSON value without a newline is parsed for row parity,
        // but it cannot advance the complete-line checkpoint.
        std::fs::write(&file, [prefix.as_slice(), suffix.trim_ascii_end()].concat()).unwrap();
        ingest(&store, &file, claude, SourceType::Windows);
        assert_eq!(
            checkpoint_rows(&store),
            before,
            "tail-only growth must not write a checkpoint"
        );
        let full = configured(&dir.path().join("full.sqlite"));
        ingest(&full, &file, claude, SourceType::Windows);
        compare_rows(&store, &full, "tail-only growth");
        std::fs::write(&file, [prefix, suffix].concat()).unwrap();
        ingest(&store, &file, claude, SourceType::Windows);
        ingest(&full, &file, claude, SourceType::Windows);
        compare_rows(&store, &full, "completed tail");
    }
}

#[test]
fn idle_finality_without_another_blob_does_not_loop_on_partial_tail() {
    let _budget = fast_writes();
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = super::support::TempDir::new("idle-no-state");
    let root = dir.path().join("sources");
    let project = root.join("project");
    std::fs::create_dir_all(&project).unwrap();
    let path = project.join("session.jsonl");
    let store = configured(&dir.path().join("store.sqlite"));
    let prefix = "{\"type\":\"user\",\"message\":{\"content\":\"first\"}}\n";
    std::fs::write(&path, prefix).unwrap();
    ingest(&store, &path, true, SourceType::Windows);
    std::fs::write(
        &path,
        format!(
            "{prefix}{{\"type\":\"user\",\"message\":{{\"content\":\"second\"}}}}\n{{\"type\":"
        ),
    )
    .unwrap();
    ingest(&store, &path, true, SourceType::Windows);
    let scan = || {
        claude::collect(
            &store,
            &claude::ClaudeScanOptions {
                roots: vec![claude::ClaudeRoot {
                    path: root.display().to_string(),
                    source_type: SourceType::Windows,
                }],
                mapper: PathMapper::new(""),
                parser: Default::default(),
                workers: 1,
                force: false,
                resolve_wsl_projects: false,
            },
        )
        .unwrap()
    };
    // Exercise a legitimate full parse with no next blob without allocating
    // enough live parser state to exceed its cap. Disabling checkpoint creation
    // leaves the same writer input (a full result and None) as a capped blob.
    {
        let _no_blob = ResumePolicyScope::enter(ResumePolicy {
            enabled: false,
            ..ResumePolicy::testing()
        });
        assert_eq!(scan().counts.files_parsed, 1);
    }
    assert_eq!(
        scan().counts.files_parsed,
        0,
        "settled incomplete revision must stay quiet without parser state"
    );
    let full = configured(&dir.path().join("full.sqlite"));
    ingest(&full, &path, true, SourceType::Windows);
    for &name in STORED_TABLES {
        assert_eq!(
            table(&store.conn, name),
            table(&full.conn, name),
            "settled no-blob {name}"
        );
    }
}

fn tool_source(claude: bool) -> (Vec<u8>, Vec<u8>) {
    if !claude {
        return super::session_gen::late_codex_tool();
    }
    let prefix=json!({"type":"assistant","sessionId":"generated-claude","message":{"id":"tool-message","content":[{"type":"tool_use","id":"late","name":"exec","input":{}}],"usage":{"input_tokens":2,"output_tokens":1}}}).to_string()+"\n";
    let suffix=json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"late","content":"late answer"}]}}).to_string()+"\n";
    (prefix.into_bytes(), suffix.into_bytes())
}

// CXV-215-P2-02: the review's unchanged source / preview 50 -> 5 probe,
// extended to every parser option, both checkpoint states and child dispatch.
fn ingest_options(
    store: &Store,
    path: &Path,
    is_claude: bool,
    preview: usize,
    message: usize,
) -> codex::CollectReport {
    if is_claude {
        claude::collect_file(
            store,
            path,
            SourceType::Windows,
            &PathMapper::new(""),
            &claude::parser::ClaudeOptions {
                max_tool_output_preview_chars: preview,
                max_message_content_chars: message,
            },
        )
        .unwrap()
    } else {
        let mut opts = options(path, SourceType::Windows);
        opts.parser.max_tool_output_preview_chars = preview;
        opts.parser.max_message_content_chars = message;
        codex::collect_file_with(store, &opts, &opts.roots[0], |_| Default::default()).unwrap()
    }
}

fn options_source(is_claude: bool) -> Vec<u8> {
    let (prefix, suffix) = tool_source(is_claude);
    let text = if is_claude {
        json!({"type":"user","message":{"content":"a message whose limit also affects parsing"}})
    } else {
        json!({"type":"response_item","payload":{"type":"message","role":"user","content":"a message whose limit also affects parsing"}})
    };
    let mut bytes = String::from_utf8([prefix, suffix].concat())
        .unwrap()
        .replace("late answer", "abcdefghijklmnopqrstuvwxyz")
        .into_bytes();
    bytes.extend_from_slice(format!("{text}\n").as_bytes());
    bytes
}

#[test]
fn options_change_checkpoint_resume_both_harnesses() {
    // Characterization: both parser entry points already reject option skew,
    // independently of the store's unchanged-file skip.
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    for is_claude in [false, true] {
        let dir = super::support::TempDir::new("options-resume");
        let path = dir.path().join("session.jsonl");
        let name = path.to_str().unwrap();
        std::fs::write(&path, options_source(is_claude)).unwrap();
        let parse = |preview, message, resume| {
            if is_claude {
                let parsed = claude::parser::parse_transcript_with(
                    name,
                    &claude::parser::ClaudeOptions {
                        max_tool_output_preview_chars: preview,
                        max_message_content_chars: message,
                    },
                    resume,
                )
                .unwrap();
                (
                    parsed.outcome,
                    parsed.scope,
                    claude::snapshot(
                        name,
                        SourceType::Windows,
                        &PathMapper::new(""),
                        parsed.success,
                    ),
                    parsed.checkpoint,
                )
            } else {
                let mut opts = options(&path, SourceType::Windows);
                opts.parser.max_tool_output_preview_chars = preview;
                opts.parser.max_message_content_chars = message;
                let parsed = codex::parser::parse_file_with(name, opts.parser, resume).unwrap();
                (
                    parsed.outcome,
                    parsed.scope,
                    codex::snapshot_for(&opts, &opts.roots[0], &parsed.success),
                    parsed.checkpoint,
                )
            }
        };
        let saved = parse(50, 1000, resume::Resume::Fresh(ResumePolicy::testing()))
            .3
            .unwrap();
        use std::io::Write;
        std::fs::OpenOptions::new()
            .append(true)
            .open(&path)
            .unwrap()
            .write_all(b"{}\n")
            .unwrap();
        for (preview, message) in [(5, 1000), (50, 5)] {
            let loaded = resume::LoadedCheckpoint::new(saved.decode().unwrap(), "row", "hash");
            let resumed = parse(preview, message, resume::Resume::From(loaded));
            let full = parse(preview, message, resume::Resume::Disabled);
            assert_eq!(
                resumed.0,
                resume::ResumeOutcome::Abandoned(resume::AbandonReason::Mismatch)
            );
            assert!(resumed.1.is_none());
            assert_eq!(
                resumed.2, full.2,
                "options mismatch must restart from byte zero"
            );
            assert_eq!(resumed.3.unwrap().decode().unwrap().steps_since_full, 0);
        }
    }
}

fn direct_options_case(child: bool) {
    let _budget = fast_writes();
    for is_claude in [false, true] {
        for checkpoint in [false, true] {
            let _policy = ResumePolicyScope::enter(ResumePolicy {
                enabled: checkpoint,
                min_bytes: 0,
            });
            let dir = super::support::TempDir::new("options-direct");
            let parent = dir.path().join("parent.jsonl");
            let path = if child {
                dir.path()
                    .join("parent")
                    .join("subagents")
                    .join("agent-test.jsonl")
            } else {
                parent.clone()
            };
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            let mut bytes = options_source(is_claude);
            if child && !is_claude {
                bytes = String::from_utf8(bytes).unwrap().replace("\"cwd\":", "\"subagent_history_start_ordinal\":0,\"source\":{\"subagent\":{\"thread_spawn\":{\"parent_thread_id\":\"parent\"}}},\"cwd\":").into_bytes();
            }
            std::fs::write(&path, bytes).unwrap();
            if child && is_claude {
                std::fs::write(&parent, "{\"type\":\"user\",\"sessionId\":\"parent\",\"message\":{\"content\":\"parent\"}}\n").unwrap();
            }
            let dispatch = if child && is_claude { &parent } else { &path };
            let db = dir.path().join("a.sqlite");
            let store = configured(&db);
            ingest_options(&store, dispatch, is_claude, 50, 1000);
            assert_eq!(
                !checkpoint_rows(&store).is_empty(),
                checkpoint,
                "claude={is_claude} child={child}"
            );
            assert_eq!(
                store
                    .conn
                    .query_row("select output_preview from tool_calls", [], |r| r
                        .get::<_, String>(0))
                    .unwrap(),
                "abcdefghijklmnopqrstuvwxyz"
            );
            drop(store);
            // Reopen: identity must be durable, not a process-local settings cache.
            let store = Store::open(&db, OwnerMode::Standalone).unwrap();
            let before = store.conn.total_changes();
            let receipts = checkpoint_rows(&store);
            assert_eq!(
                ingest_options(&store, dispatch, is_claude, 50, 1000)
                    .counts
                    .files_parsed,
                0
            );
            assert_eq!(store.conn.total_changes(), before);
            assert_eq!(checkpoint_rows(&store), receipts);
            for (preview, message) in [(5, 1000), (5, 5)] {
                let full = configured(&dir.path().join(format!("full-{preview}-{message}.sqlite")));
                ingest_options(&full, dispatch, is_claude, preview, message);
                let report = ingest_options(&store, dispatch, is_claude, preview, message);
                assert!(
                    report.counts.files_parsed > 0,
                    "options mismatch must parse: claude={is_claude} checkpoint={checkpoint} child={child}"
                );
                compare_rows(&store, &full, "options fresh reference");
                assert_eq!(
                    store
                        .conn
                        .query_row("select output_preview from tool_calls", [], |r| r
                            .get::<_, String>(0))
                        .unwrap(),
                    "abcde"
                );
                let before = store.conn.total_changes();
                assert_eq!(
                    ingest_options(&store, dispatch, is_claude, preview, message)
                        .counts
                        .files_parsed,
                    0
                );
                assert_eq!(store.conn.total_changes(), before);
            }
            if child {
                // The direct child route shares the same identity rule.
                assert_eq!(
                    ingest_options(&store, &path, is_claude, 50, 1000)
                        .counts
                        .files_parsed,
                    1
                );
                let full = configured(&dir.path().join("full-child.sqlite"));
                ingest_options(&full, dispatch, is_claude, 5, 5);
                ingest_options(&full, &path, is_claude, 50, 1000);
                compare_rows(&store, &full, "direct child options reference");
            }
        }
    }
}

#[test]
fn options_change_direct_parent_both_harnesses() {
    direct_options_case(false);
}
#[test]
fn options_change_direct_subagent_both_harnesses() {
    direct_options_case(true);
}

#[test]
fn options_change_resume_and_scan_both_harnesses() {
    let _budget = fast_writes();
    for is_claude in [false, true] {
        for checkpoint in [false, true] {
            let _policy = ResumePolicyScope::enter(ResumePolicy {
                enabled: checkpoint,
                min_bytes: 0,
            });
            let dir = super::support::TempDir::new("options-scan");
            let root = dir.path().join("sources");
            let file = root.join("project").join("session.jsonl");
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            let mut bytes = options_source(is_claude);
            std::fs::write(&file, &bytes).unwrap();
            let store = configured(&dir.path().join("a.sqlite"));
            ingest_options(&store, &file, is_claude, 50, 1000);
            let scan = || {
                if is_claude {
                    claude::collect(
                        &store,
                        &claude::ClaudeScanOptions {
                            roots: vec![claude::ClaudeRoot {
                                path: root.display().to_string(),
                                source_type: SourceType::Windows,
                            }],
                            mapper: PathMapper::new(""),
                            parser: claude::parser::ClaudeOptions {
                                max_tool_output_preview_chars: 5,
                                max_message_content_chars: 1000,
                            },
                            workers: 1,
                            force: false,
                            resolve_wsl_projects: false,
                        },
                    )
                    .unwrap()
                } else {
                    let mut opts = options(&root, SourceType::Windows);
                    opts.parser.max_tool_output_preview_chars = 5;
                    opts.parser.max_message_content_chars = 1000;
                    codex::collect(&store, &opts, false).unwrap()
                }
            };
            let report = scan();
            assert_eq!(report.counts.files_parsed, u64::from(checkpoint));
            if checkpoint {
                let full = configured(&dir.path().join("scan-full.sqlite"));
                ingest_options(&full, &file, is_claude, 5, 1000);
                compare_rows(
                    &store,
                    &full,
                    &format!("checkpoint options scan claude={is_claude}"),
                );
            } else {
                assert_eq!(
                    store
                        .conn
                        .query_row("select output_preview from tool_calls", [], |r| r
                            .get::<_, String>(0))
                        .unwrap(),
                    "abcdefghijklmnopqrstuvwxyz",
                    "legacy unchanged scan must retain its existing limitation"
                );
            }
            // Different options on a growing file must restart, never resume.
            ingest_options(&store, &file, is_claude, 50, 1000);
            bytes.extend_from_slice(b"\n");
            std::fs::write(&file, &bytes).unwrap();
            ingest_options(&store, &file, is_claude, 5, 1000);
            let full = configured(&dir.path().join("grown-full.sqlite"));
            ingest_options(&full, &file, is_claude, 5, 1000);
            compare_rows(&store, &full, "resume different options full reference");
            assert!(
                checkpoints::index(&store.conn, if is_claude { "claude" } else { "codex" })
                    .unwrap()
                    .values()
                    .all(|c| c.steps_since_full == 0)
            );
        }
    }
}

#[test]
fn delta_write_lock_does_not_scan_unrelated_sessions() {
    use rusqlite::ffi;
    use std::ffi::{CStr, c_void};
    unsafe extern "C" fn profile(
        _: u32,
        context: *mut c_void,
        stmt: *mut c_void,
        _: *mut c_void,
    ) -> i32 {
        let stmt = stmt.cast::<ffi::sqlite3_stmt>();
        // SAFETY: SQLite supplies live statement/context pointers synchronously;
        // the counter remains allocated until tracing is disabled below.
        unsafe {
            let sql = CStr::from_ptr(ffi::sqlite3_sql(stmt)).to_string_lossy();
            let scans = ffi::sqlite3_stmt_status(stmt, ffi::SQLITE_STMTSTATUS_FULLSCAN_STEP, 1);
            if ffi::sqlite3_get_autocommit(ffi::sqlite3_db_handle(stmt)) == 0
                && sql.trim_start().starts_with("select")
                && sql.contains("from sessions")
            {
                *context.cast::<i64>() += i64::from(scans);
            }
        }
        0
    }
    let _budget = fast_writes();
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    for claude in [false, true] {
        let dir = super::support::TempDir::new("delta-scan-bound");
        let path = dir.path().join("session.jsonl");
        let store = configured(&dir.path().join("db.sqlite"));
        let (prefix, suffix) = tool_source(claude);
        std::fs::write(&path, &prefix).unwrap();
        ingest(&store, &path, claude, SourceType::Windows);
        store.conn.execute_batch("with recursive n(i) as (values(1) union all select i+1 from n where i<2000)
            insert into sessions(id,session_id,harness,source_file_path,source_type,display_path,platform_path,created_at_utc,updated_at_utc)
            select 'unrelated:'||i,'unrelated-'||i,'codex','other-'||i,'windows','other','other','now','now' from n").unwrap();
        std::fs::write(&path, [prefix, suffix].concat()).unwrap();
        let mut scans = Box::new(0_i64);
        // SAFETY: the connection and boxed counter outlive synchronous tracing.
        unsafe {
            ffi::sqlite3_trace_v2(
                store.conn.handle(),
                ffi::SQLITE_TRACE_PROFILE,
                Some(profile),
                (&mut *scans as *mut i64).cast(),
            );
        }
        ingest(&store, &path, claude, SourceType::Windows);
        // SAFETY: disable the callback before reading/dropping its context.
        unsafe {
            ffi::sqlite3_trace_v2(store.conn.handle(), 0, None, std::ptr::null_mut());
        }
        assert!(*scans < 1000, "{claude}: in-lock fullscan steps={scans}");
        let steps: i64 = store
            .conn
            .query_row(
                "select steps_since_full from session_parse_checkpoints",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(steps, 1, "the bounded path must actually resume");
    }
}

#[test]
fn delta_batch_revision_fence_accepts_own_units_across_chunks() {
    use codex_sessions_collector::store::write_budget::{WriteBudget, WriteBudgetScope};
    let _budget = WriteBudgetScope::enter(WriteBudget {
        gap: Duration::ZERO,
        soft: Duration::ZERO,
        ..Default::default()
    });
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = super::support::TempDir::new("delta-batch-fence");
    let store = configured(&dir.path().join("a.sqlite"));
    let full = configured(&dir.path().join("b.sqlite"));
    let mut deltas = Vec::new();
    for i in 0..2 {
        let path = dir.path().join(format!("session-{i}.jsonl"));
        let prefix = format!(
            "{}\n{}\n",
            json!({"type":"session_meta","payload":{"id":format!("batch-{i}")}}),
            json!({"type":"event_msg","payload":{"type":"user_message","message":"first"}})
        );
        std::fs::write(&path, &prefix).unwrap();
        ingest(&store, &path, false, SourceType::Windows);
        let loaded = checkpoints::load(
            &store.conn,
            "codex",
            path.to_str().unwrap(),
            ResumePolicy::testing(),
        )
        .unwrap()
        .unwrap();
        let receipt = resume::ResumeReceipt::from(&loaded);
        let suffix = format!(
            "{}\n",
            json!({"type":"event_msg","payload":{"type":"agent_message","message":"second"}})
        );
        std::fs::write(&path, prefix + &suffix).unwrap();
        let parsed = codex::parser::parse_file_with(
            path.to_str().unwrap(),
            Default::default(),
            resume::Resume::From(loaded),
        )
        .unwrap();
        let options = options(&path, SourceType::Windows);
        deltas.push(resume::SessionDelta::new(
            codex::snapshot_for(&options, &options.roots[0], &parsed.success),
            parsed.scope.unwrap(),
            parsed.checkpoint,
            &receipt,
        ));
        ingest(&full, &path, false, SourceType::Windows);
    }
    assert_eq!(
        writer::apply_session_deltas(&store.conn, deltas).unwrap(),
        [writer::DeltaOutcome::Applied; 2]
    );
    compare(
        &store,
        &full,
        "own writes across admitted chunks preserve the plan fence",
    );
}

#[test]
fn appended_bytes_and_late_tool_results_use_scoped_writer() {
    let _budget = fast_writes();
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    for claude in [false, true] {
        let dir = super::support::TempDir::new("db-tool");
        let path = dir.path().join("session.jsonl");
        let mut a = configured(&dir.path().join("a.sqlite"));
        let b = configured(&dir.path().join("b.sqlite"));
        let (mut prefix, suffix) = tool_source(claude);
        prefix.extend(std::iter::repeat_n(b'\n', 1024 * 1024));
        std::fs::write(&path, &prefix).unwrap();
        ingest(&a, &path, claude, SourceType::Windows);
        prefix.extend(&suffix);
        std::fs::write(&path, &prefix).unwrap();
        let reads = resume::ReadCounterScope::enter();
        ingest(&a, &path, claude, SourceType::Windows);
        assert!(
            reads.bytes() <= suffix.len() as u64 + 144 * 1024,
            "suffix read bound"
        );
        drop(reads);
        assert!(
            checkpoints::index(&a.conn, if claude { "claude" } else { "codex" })
                .unwrap()
                .values()
                .any(|c| c.steps_since_full == 1)
        );
        ingest(&b, &path, claude, SourceType::Windows);
        compare(&a, &b, "late tool delta");
        assert_eq!(
            a.conn
                .query_row("select output_preview from tool_calls", [], |r| r
                    .get::<_, String>(0))
                .unwrap(),
            "late answer"
        );
        // A forced full parse normalizes its digest without changing child rows.
        let writes = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let observed = writes.clone();
        a.conn
            .update_hook(Some(
                move |_: rusqlite::hooks::Action, _: &str, table: &str, _: i64| {
                    if [
                        "messages",
                        "tool_calls",
                        "usage_events",
                        "usage_event_inputs",
                    ]
                    .contains(&table)
                    {
                        observed.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                    }
                },
            ))
            .unwrap();
        a.conn
            .execute("delete from session_parse_checkpoints", [])
            .unwrap();
        ingest(&a, &path, claude, SourceType::Windows);
        a.conn
            .update_hook(None::<fn(rusqlite::hooks::Action, &str, &str, i64)>)
            .unwrap();
        assert_eq!(
            writes.load(std::sync::atomic::Ordering::Relaxed),
            0,
            "full convergence must not rewrite equal children"
        );
    }
}

#[test]
fn stale_preconditions_leave_every_row_untouched() {
    let _budget = fast_writes();
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    for claude in [false, true] {
        for cause in [
            "hash",
            "checkpoint",
            "invalidate",
            "identity",
            "source",
            "parser",
            "duplicate",
            "stored-duplicate",
            "plan-lock",
            "plan-identity",
            "external-identity",
        ] {
            let dir = super::support::TempDir::new("cas");
            let path = dir.path().join("session.jsonl");
            let a = configured(&dir.path().join("a.sqlite"));
            let (mut bytes, suffix) = tool_source(claude);
            std::fs::write(&path, &bytes).unwrap();
            ingest(&a, &path, claude, SourceType::Windows);
            let loaded = checkpoints::load(
                &a.conn,
                if claude { "claude" } else { "codex" },
                path.to_str().unwrap(),
                ResumePolicy::testing(),
            )
            .unwrap()
            .unwrap();
            let receipt = resume::ResumeReceipt::from(&loaded);
            bytes.extend(suffix);
            std::fs::write(&path, &bytes).unwrap();
            let mut delta = if claude {
                let parsed = claude::parser::parse_transcript_with(
                    path.to_str().unwrap(),
                    &Default::default(),
                    resume::Resume::From(loaded),
                )
                .unwrap();
                resume::SessionDelta::new(
                    claude::snapshot(
                        path.to_str().unwrap(),
                        SourceType::Windows,
                        &PathMapper::new(""),
                        parsed.success,
                    ),
                    parsed.scope.unwrap(),
                    parsed.checkpoint,
                    &receipt,
                )
            } else {
                let parsed = codex::parser::parse_file_with(
                    path.to_str().unwrap(),
                    Default::default(),
                    resume::Resume::From(loaded),
                )
                .unwrap();
                let options = options(&path, SourceType::Windows);
                resume::SessionDelta::new(
                    codex::snapshot_for(&options, &options.roots[0], &parsed.success),
                    parsed.scope.unwrap(),
                    parsed.checkpoint,
                    &receipt,
                )
            };
            match cause {
                "hash" => {
                    a.conn
                        .execute("update sessions set content_hash='different'", [])
                        .unwrap();
                }
                "checkpoint" => {
                    a.conn
                        .execute("delete from session_parse_checkpoints", [])
                        .unwrap();
                }
                "invalidate" => {
                    checkpoints::invalidate_for_session(&a.conn, &delta.row_id).unwrap();
                }
                "identity" => {
                    a.conn.execute("insert into sessions(id,harness,source_file_path,source_type,display_path,platform_path,created_at_utc,updated_at_utc) values('source-status:alternate',?,?,'windows','fixture','fixture','now','now')",rusqlite::params![delta.snapshot.harness,delta.snapshot.source.path]).unwrap();
                }
                "source" => {
                    a.conn
                        .execute("update sessions set source_file_path='different.jsonl'", [])
                        .unwrap();
                }
                "parser" => {
                    a.conn
                        .execute("update sessions set parser_version=-1", [])
                        .unwrap();
                }
                "duplicate" => {
                    delta
                        .snapshot
                        .tool_calls
                        .push(delta.snapshot.tool_calls[0].clone());
                }
                "stored-duplicate" => {
                    a.conn.execute("insert into tool_calls(session_id,tool_index,tool_name,status) select session_id,tool_index,tool_name,status from tool_calls",[]).unwrap();
                }
                _ => {}
            }
            let db = a.conn.path().unwrap().to_owned();
            let alternate_harness = delta.snapshot.harness.clone();
            let alternate_source = delta.snapshot.source.path.clone();
            let hook_writes = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
            let observed_hook_writes = hook_writes.clone();
            let hook = writer::SessionPreparationScope::enter(None, move |conn| {
                let before = conn.total_changes();
                if cause == "plan-lock" {
                    conn.execute("delete from session_parse_checkpoints", [])
                        .unwrap();
                }
                if matches!(cause, "plan-identity" | "external-identity") {
                    let external;
                    let conn = if cause == "external-identity" {
                        codex_sessions_collector::store::connection::ensure().unwrap();
                        external = Connection::open(&db).unwrap();
                        &external
                    } else {
                        conn
                    };
                    conn.execute("insert into sessions(id,harness,session_id,source_file_path,source_type,display_path,platform_path,created_at_utc,updated_at_utc) values('source-status:alternate',?,null,?,'windows','fixture','fixture','now','now')",rusqlite::params![alternate_harness,alternate_source]).unwrap();
                }
                observed_hook_writes.store(
                    conn.total_changes() - before,
                    std::sync::atomic::Ordering::Relaxed,
                );
            });
            let before = a.conn.total_changes();
            assert_eq!(
                writer::apply_session_deltas(&a.conn, vec![delta]).unwrap(),
                [writer::DeltaOutcome::Stale],
                "{claude} {cause}"
            );
            let hook_changes = hook_writes.load(std::sync::atomic::Ordering::Relaxed);
            assert_eq!(
                a.conn.total_changes() - before,
                hook_changes,
                "{claude} {cause}: stale writes"
            );
            drop(hook);
            let b = configured(&dir.path().join("b.sqlite"));
            // Remove the synthetic identity fixture before the actual retry.
            if matches!(cause, "identity" | "plan-identity" | "external-identity") {
                a.conn
                    .execute(
                        "delete from sessions where id='source-status:alternate'",
                        [],
                    )
                    .unwrap();
            }
            ingest(&a, &path, claude, SourceType::Windows);
            ingest(&b, &path, claude, SourceType::Windows);
            compare(&a, &b, "CAS retry full parity");
        }
    }
}

#[test]
fn scan_blob_budget_and_cache_delete_are_bounded() {
    let _budget = fast_writes();
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = super::support::TempDir::new("blob-budget");
    let path = dir.path().join("session.jsonl");
    let store = configured(&dir.path().join("a.sqlite"));
    let (bytes, _) = tool_source(false);
    std::fs::write(&path, bytes).unwrap();
    ingest(&store, &path, false, SourceType::Windows);
    let mut remaining = 1;
    assert!(
        checkpoints::load_bounded(
            &store.conn,
            "codex",
            path.to_str().unwrap(),
            ResumePolicy::testing(),
            &mut remaining
        )
        .unwrap()
        .is_none()
    );
    assert_eq!(remaining, 1);
    remaining = resume::MAX_DECODED_BYTES;
    assert!(
        checkpoints::load_bounded(
            &store.conn,
            "codex",
            path.to_str().unwrap(),
            ResumePolicy::testing(),
            &mut remaining
        )
        .unwrap()
        .is_some()
    );
    assert!(remaining < resume::MAX_DECODED_BYTES);
    store.conn.execute("delete from sessions", []).unwrap();
    assert!(checkpoints::index(&store.conn, "codex").unwrap().is_empty());
}

#[test]
fn missing_next_blob_keeps_the_one_time_idle_reparse_obligation() {
    let _budget = fast_writes();
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    for claude in [false, true] {
        let dir = super::support::TempDir::new("idle-no-blob");
        let root = dir.path().join("sources");
        let project = root.join("project");
        std::fs::create_dir_all(&project).unwrap();
        let path = project.join("session.jsonl");
        let store = configured(&dir.path().join("a.sqlite"));
        let (mut bytes, suffix) = tool_source(claude);
        std::fs::write(&path, &bytes).unwrap();
        ingest(&store, &path, claude, SourceType::Windows);
        bytes.extend(suffix);
        std::fs::write(&path, &bytes).unwrap();
        let harness = if claude { "claude" } else { "codex" };
        let loaded = checkpoints::load(
            &store.conn,
            harness,
            path.to_str().unwrap(),
            ResumePolicy::testing(),
        )
        .unwrap()
        .unwrap();
        let receipt = resume::ResumeReceipt::from(&loaded);
        let mut delta = if claude {
            let parsed = claude::parser::parse_transcript_with(
                path.to_str().unwrap(),
                &Default::default(),
                resume::Resume::From(loaded),
            )
            .unwrap();
            resume::SessionDelta::new(
                claude::snapshot(
                    path.to_str().unwrap(),
                    SourceType::Windows,
                    &PathMapper::new(""),
                    parsed.success,
                ),
                parsed.scope.unwrap(),
                parsed.checkpoint,
                &receipt,
            )
        } else {
            let parsed = codex::parser::parse_file_with(
                path.to_str().unwrap(),
                Default::default(),
                resume::Resume::From(loaded),
            )
            .unwrap();
            let options = options(&path, SourceType::Windows);
            resume::SessionDelta::new(
                codex::snapshot_for(&options, &options.roots[0], &parsed.success),
                parsed.scope.unwrap(),
                parsed.checkpoint,
                &receipt,
            )
        };
        // The parser legitimately returns None when its next blob exceeds a cap.
        // Exercise that writer contract without manufacturing a huge allocation.
        delta.checkpoint = None;
        assert_eq!(
            writer::apply_session_deltas(&store.conn, vec![delta]).unwrap(),
            [writer::DeltaOutcome::Applied]
        );
        assert!(
            checkpoints::load(
                &store.conn,
                harness,
                path.to_str().unwrap(),
                ResumePolicy::testing()
            )
            .unwrap()
            .is_none()
        );
        assert!(
            checkpoints::index(&store.conn, harness)
                .unwrap()
                .values()
                .any(|c| c.steps_since_full > 0)
        );
        let scan = || {
            if claude {
                claude::collect(
                    &store,
                    &claude::ClaudeScanOptions {
                        roots: vec![claude::ClaudeRoot {
                            path: root.display().to_string(),
                            source_type: SourceType::Windows,
                        }],
                        mapper: PathMapper::new(""),
                        parser: Default::default(),
                        workers: 2,
                        force: false,
                        resolve_wsl_projects: false,
                    },
                )
                .unwrap()
            } else {
                codex::collect(&store, &options(&root, SourceType::Windows), false).unwrap()
            }
        };
        assert_eq!(scan().counts.files_parsed, 1);
        assert_eq!(scan().counts.files_parsed, 0);
        let full = configured(&dir.path().join("full.sqlite"));
        ingest(&full, &path, claude, SourceType::Windows);
        compare(&store, &full, "missing blob final full parse");
    }
}

#[test]
fn shrink_rewrite_and_checkpoint_skew_restart_full_ingest() {
    let _budget = fast_writes();
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    for claude in [false, true] {
        for cause in ["shrink", "rewrite", "version", "format", "options", "blob"] {
            let dir = super::support::TempDir::new("db-fallback");
            let path = dir.path().join("session.jsonl");
            let a = configured(&dir.path().join("a.sqlite"));
            let b = configured(&dir.path().join("b.sqlite"));
            let (mut bytes, suffix) = tool_source(claude);
            bytes.extend(std::iter::repeat_n(b'\n', 2048));
            std::fs::write(&path, &bytes).unwrap();
            ingest(&a, &path, claude, SourceType::Windows);
            match cause {
                "shrink" => bytes = tool_source(claude).0,
                "rewrite" => {
                    bytes = String::from_utf8(bytes)
                        .unwrap()
                        .replace("exec", "edit")
                        .into_bytes();
                    bytes.extend(&suffix);
                }
                "version" => {
                    a.conn
                        .execute("update session_parse_checkpoints set parser_version=-1", [])
                        .unwrap();
                    bytes.extend(&suffix);
                }
                "format" => {
                    a.conn
                        .execute("update session_parse_checkpoints set format_version=-1", [])
                        .unwrap();
                    bytes.extend(&suffix);
                }
                "blob" => {
                    a.conn
                        .execute("update session_parse_checkpoints set state=x'00'", [])
                        .unwrap();
                    bytes.extend(&suffix);
                }
                "options" => {
                    let loaded = checkpoints::load(
                        &a.conn,
                        if claude { "claude" } else { "codex" },
                        path.to_str().unwrap(),
                        ResumePolicy::testing(),
                    )
                    .unwrap()
                    .unwrap();
                    let mut cp = *loaded.checkpoint;
                    cp.options.max_message_content_chars += 1;
                    let record = cp.encode().unwrap();
                    a.conn
                        .execute(
                            "update session_parse_checkpoints set state=?",
                            [record.state],
                        )
                        .unwrap();
                    bytes.extend(&suffix);
                }
                _ => unreachable!(),
            }
            std::fs::write(&path, &bytes).unwrap();
            let reads = resume::ReadCounterScope::enter();
            ingest(&a, &path, claude, SourceType::Windows);
            assert!(
                reads.bytes() >= bytes.len() as u64,
                "{claude} {cause} must read the full source"
            );
            drop(reads);
            ingest(&b, &path, claude, SourceType::Windows);
            compare(&a, &b, cause);
            assert!(
                checkpoints::index(&a.conn, if claude { "claude" } else { "codex" })
                    .unwrap()
                    .values()
                    .all(|cp| cp.steps_since_full == 0)
            );
        }
    }
}
