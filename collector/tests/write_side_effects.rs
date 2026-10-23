//! CXV-180: hub-enabled equivalence against e81ecf9, not another candidate budget.
//! The golden was captured by running these fixtures against that base library.
//! Only wall-clock timestamps are normalized; queue IDs, payloads, hashes and
//! journal revisions are retained. No network connection is made.
mod support;

use codex_sessions_collector::{
    codex::{parser::SourceType, scanner::session_scan_roots},
    contract::{Envelope, ProjectHint, SessionRef, SourceStatus, ThreadName},
    store::{OwnerMode, Store, cache_repair, writer},
    t3,
};
use rusqlite::{Connection, params};
use serde_json::{Value, json};

fn enable_hub(conn: &Connection) {
    conn.execute("insert into collector_hub_state(id,enabled,hub_url,machine_id) values(1,1,'http://127.0.0.1:1','fixture')", []).unwrap();
}

fn seed(conn: &Connection, id: &str) {
    let mut snapshot = support::sample_snapshot(id);
    snapshot.session.working_directory_display = Some("C:/work/repo".into());
    snapshot.session.working_directory_platform = Some("C:/work/repo".into());
    writer::apply_session_batch(conn, vec![snapshot]).unwrap();
}

fn effects(conn: &Connection) -> Value {
    let tables: Vec<String> = conn.prepare("select name from sqlite_schema where type='table' and (name like 'collector_%' or name in ('session_changes','session_change_state')) order by name").unwrap()
        .query_map([], |r| r.get(0)).unwrap().collect::<Result<_,_>>().unwrap();
    let mut result = serde_json::Map::new();
    for table in tables {
        let mut rows = support::rows(conn, &format!("select * from {table} order by 1"));
        for row in &mut rows {
            for (column, value) in row.as_object_mut().unwrap() {
                if column.ends_with("_at_utc") && !value.is_null() {
                    *value = json!("<clock>");
                }
            }
        }
        result.insert(table, json!(rows));
    }
    result.insert(
        "queue_sequences".into(),
        json!(support::rows(
            conn,
            "select * from sqlite_sequence where name like 'collector_%' order by name"
        )),
    );
    result.insert("sessions".into(), json!(support::rows(conn, "select id,scan_status,source_state,parse_status,thread_name,title,summary,detected_project_id,project_refined,project_id,project_override,project_name_snapshot,t3_parent_thread_id,t3_parent_session_id,t3_relationship from sessions order by id")));
    Value::Object(result)
}

fn status(path: &str, value: &str) -> SourceStatus {
    serde_json::from_value(json!({"harness":"codex","path":path,"status":value,"state":"active"}))
        .unwrap()
}

fn thread(id: &str, name: &str) -> ThreadName {
    serde_json::from_value(json!({"harness":"codex","session_id":id,"thread_name":name})).unwrap()
}

fn references(id: &str) -> Vec<SessionRef> {
    vec![SessionRef {
        session_id: Some(id.into()),
        source_path: format!("C:/peer/{id}.jsonl"),
    }]
}

fn hints() -> Vec<ProjectHint> {
    vec![
        ProjectHint {
            working_directory: "C:/work/repo".into(),
            project_name: "Resolved".into(),
        },
        ProjectHint {
            working_directory: "C:/unused".into(),
            project_name: "Unused".into(),
        },
    ]
}

fn capture(phase: &str) -> Value {
    let temp = support::TempDir::new(&format!("side_effects_{phase}"));
    let store = Store::open(&temp.path().join("fixture.sqlite"), OwnerMode::Standalone).unwrap();
    seed(&store.conn, "local");
    let mut stages = Vec::new();
    match phase {
        "sessions" => {
            enable_hub(&store.conn);
            let input = vec![support::sample_snapshot("a"), support::sample_snapshot("b")];
            writer::apply_session_batch(&store.conn, input.clone()).unwrap();
            stages.push(effects(&store.conn));
            writer::apply_session_batch(&store.conn, input.clone()).unwrap();
            stages.push(effects(&store.conn));
            let mut changed = input;
            changed[0].session.title = Some("Changed title".into());
            writer::apply_session_batch(&store.conn, changed).unwrap();
            stages.push(effects(&store.conn));
        }
        "statuses" => {
            enable_hub(&store.conn);
            // Local priority differs from original delivery order, and keys repeat.
            let input = vec![
                status("C:\\synthetic\\local.jsonl", "parse_error"),
                status("C:\\synthetic\\local.jsonl", "available"),
                status("C:/unknown.zst", "unsupported_format"),
            ];
            writer::apply_source_statuses(&store.conn, &input).unwrap();
            stages.push(effects(&store.conn));
            writer::apply_source_statuses(&store.conn, &input).unwrap();
            stages.push(effects(&store.conn));
        }
        "project_hints" => {
            enable_hub(&store.conn);
            let mut refs = references("local");
            refs.extend(references("missing-locally"));
            refs.extend(references("local")); // Exact refs, order, duplicates matter.
            for _ in 0..2 {
                writer::apply_project_hints(&store.conn, "codex", &refs, &hints()).unwrap();
                stages.push(effects(&store.conn));
            }
            writer::apply_project_hints(&store.conn, "codex", &references("absent"), &[]).unwrap();
            stages.push(effects(&store.conn));
            writer::apply_project_hints(&store.conn, "codex", &[], &hints()).unwrap();
            stages.push(effects(&store.conn));
        }
        "thread_names" => {
            enable_hub(&store.conn);
            let initial = vec![thread("local", "Original"), thread("absent", "Original")];
            writer::apply_thread_names(&store.conn, &initial).unwrap();
            stages.push(effects(&store.conn));
            let input = vec![
                thread("local", "Changed"),
                thread("local", "Original"),
                thread("absent", "Changed"),
                thread("absent", "Original"),
                thread("local", " Original "),
                thread("local", " "),
            ];
            for _ in 0..2 {
                writer::apply_thread_names(&store.conn, &input).unwrap();
                stages.push(effects(&store.conn));
            }
        }
        "backfill" => {
            store
                .conn
                .execute(
                    "update sessions set detected_project_id=null,project_name_snapshot=null",
                    [],
                )
                .unwrap();
            enable_hub(&store.conn);
            for _ in 0..2 {
                writer::apply_project_backfill(&store.conn, &hints()).unwrap();
                stages.push(effects(&store.conn));
            }
        }
        "placeholders" => {
            store
                .conn
                .execute(
                    "update sessions set title='# AGENTS.md old',summary='auto'",
                    [],
                )
                .unwrap();
            enable_hub(&store.conn);
            for _ in 0..2 {
                writer::clean_session_metadata_placeholders(&store.conn).unwrap();
                stages.push(effects(&store.conn));
            }
        }
        "cache_repair" => {
            let home = temp.path().join(".codex");
            std::fs::create_dir_all(home.join("sessions")).unwrap();
            std::fs::create_dir_all(home.join("archived_sessions")).unwrap();
            std::fs::create_dir_all(home.join("plugins")).unwrap();
            let path = home.join("plugins/file.jsonl");
            std::fs::write(&path, "{}").unwrap();
            let path = path.to_str().unwrap();
            store.conn.execute("insert into sessions(id,source_type,source_file_path,display_path,platform_path,source_state,parser_version,created_at_utc,updated_at_utc) values('source:legacy','windows',?1,?1,?1,'active',1,'fixed','fixed')", [path]).unwrap();
            enable_hub(&store.conn);
            for _ in 0..2 {
                let report = cache_repair::run(
                    &store,
                    &session_scan_roots(home.to_str().unwrap(), SourceType::Windows),
                    true,
                    &std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
                    &mut |_| Ok(true),
                )
                .unwrap();
                assert!(
                    matches!(report.status, "completed" | "already_completed"),
                    "{report:?}"
                );
                stages.push(effects(&store.conn));
            }
            assert_eq!(
                store
                    .conn
                    .query_row(
                        "select count(*) from sessions where id='source:legacy'",
                        [],
                        |r| r.get::<_, i64>(0)
                    )
                    .unwrap(),
                0
            );
        }
        "t3" => {
            seed(&store.conn, "child");
            let path = temp.path().join("t3.sqlite");
            let db = Connection::open(&path).unwrap();
            db.execute_batch("create table orchestration_v2_projection_threads(payload_json text);create table orchestration_v2_projection_provider_threads(payload_json text)").unwrap();
            for (id, parent) in [("local", None), ("child", Some("app-local"))] {
                db.execute("insert into orchestration_v2_projection_threads values(?)", [json!({"id":format!("app-{id}"),"lineage":{"parentThreadId":parent,"relationshipToParent":"fork","rootThreadId":"app-local"}}).to_string()]).unwrap();
                db.execute("insert into orchestration_v2_projection_provider_threads values(?)", [json!({"driver":"codex","appThreadId":format!("app-{id}"),"nativeThreadRef":{"driver":"codex","nativeId":id,"strength":"strong"}}).to_string()]).unwrap();
            }
            enable_hub(&store.conn);
            for _ in 0..2 {
                t3::import(&store.conn, &path, "windows").unwrap();
                stages.push(effects(&store.conn));
            }
            db.execute("delete from orchestration_v2_projection_threads", [])
                .unwrap();
            t3::import(&store.conn, &path, "windows").unwrap();
            stages.push(effects(&store.conn));
        }
        _ => panic!("unknown phase"),
    }
    json!(stages)
}

fn assert_base_effects(phase: &str) {
    use codex_sessions_collector::store::write_budget::{WriteBudget, WriteBudgetScope};
    use std::time::Duration;
    let golden: Value = if phase == "sessions" {
        serde_json::from_str(include_str!("fixtures/write_sessions_base.json")).unwrap()
    } else {
        serde_json::from_str(include_str!("fixtures/write_side_effects_base.json")).unwrap()
    };
    for soft in [Duration::ZERO, Duration::from_millis(250)] {
        let _budget = WriteBudgetScope::enter(WriteBudget {
            soft,
            hard: Duration::from_secs(1),
            gap: Duration::ZERO,
        });
        let actual = capture(phase);
        assert_eq!(
            actual, golden[phase],
            "base side effects: {phase}, soft={soft:?}"
        );
    }
}

macro_rules! base_effects_test {
    ($name:ident, $phase:literal) => {
        #[test]
        fn $name() {
            assert_base_effects($phase);
        }
    };
}
base_effects_test!(statuses_match_base_side_effects, "statuses");
base_effects_test!(sessions_match_base_side_effects, "sessions");
base_effects_test!(project_hints_match_base_side_effects, "project_hints");
base_effects_test!(thread_names_match_base_side_effects, "thread_names");
base_effects_test!(backfill_matches_base_side_effects, "backfill");
base_effects_test!(placeholders_match_base_side_effects, "placeholders");
base_effects_test!(cache_repair_matches_base_side_effects, "cache_repair");
base_effects_test!(t3_matches_base_side_effects, "t3");

#[test]
fn project_hints_reach_peer_when_local_session_is_absent_or_unchanged() {
    for absent in [true, false] {
        let temp = support::TempDir::new("hint_peer");
        let sender =
            Store::open(&temp.path().join("sender.sqlite"), OwnerMode::Standalone).unwrap();
        let peer = Store::open(&temp.path().join("peer.sqlite"), OwnerMode::Standalone).unwrap();
        seed(&peer.conn, "peer");
        if !absent {
            seed(&sender.conn, "peer");
            writer::apply_project_hints(&sender.conn, "codex", &references("peer"), &hints())
                .unwrap();
        }
        enable_hub(&sender.conn);
        assert_eq!(
            writer::apply_project_hints(&sender.conn, "codex", &references("peer"), &hints())
                .unwrap(),
            0
        );
        let records: Vec<Envelope> = sender
            .conn
            .prepare("select record_json from collector_upload_outbox order by id")
            .unwrap()
            .query_map([], |r| {
                Ok(serde_json::from_str(&r.get::<_, String>(0)?).unwrap())
            })
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(records.len(), 1, "absent={absent}");
        peer.apply(records).unwrap();
        assert_eq!(peer.conn.query_row("select p.name from sessions s join projects p on p.id=s.detected_project_id where s.session_id=?", params!["peer"], |r|r.get::<_,String>(0)).unwrap(), "Resolved");
    }
}

// Deliberately oppose lexical ID order and table insertion order. The older
// fixtures had only one changed status/cleanup row and could not see F7.
fn capture_order_effects(phase: &str) -> Value {
    let temp = support::TempDir::new("base_effect_order");
    let store = Store::open(&temp.path().join("fixture.sqlite"), OwnerMode::Standalone).unwrap();
    for id in ["z", "a", "y", "b", "x", "c"] {
        if phase == "project_hints" {
            seed(&store.conn, id);
            continue;
        }
        store.conn.execute("insert into sessions(id,session_id,source_type,source_file_path,display_path,platform_path,parse_status,scan_status,created_at_utc,updated_at_utc,harness,t3_parent_thread_id,t3_relationship) values(?1,?1,'windows',?1,?1,?1,'available','available','fixed','fixed','codex','old','fork')", [id]).unwrap();
    }
    enable_hub(&store.conn);
    match phase {
        "project_hints" => {
            let refs: Vec<_> = ["z", "a", "y", "b", "x", "c"]
                .iter()
                .flat_map(|id| references(id))
                .collect();
            writer::apply_project_hints(&store.conn, "codex", &refs, &hints()).unwrap();
        }
        "statuses" => {
            let input = vec![
                status("b", "missing"),
                status("z", "missing"),
                status("c", "missing"),
                status("y", "missing"),
                status("a", "missing"),
                status("x", "missing"),
                status("C:/z-unknown.zst", "unsupported_format"),
                status("C:/a-unknown.zst", "unsupported_format"),
            ];
            writer::apply_source_statuses(&store.conn, &input).unwrap();
        }
        "t3" => {
            let path = temp.path().join("t3.sqlite");
            let db = Connection::open(&path).unwrap();
            db.execute_batch("create table orchestration_v2_projection_threads(payload_json text);create table orchestration_v2_projection_provider_threads(payload_json text)").unwrap();
            t3::import(&store.conn, &path, "windows").unwrap();
        }
        _ => unreachable!(),
    }
    let mut value = effects(&store.conn);
    value["journal_order"] = json!(support::rows(
        &store.conn,
        "select session_id,revision,deleted from session_changes order by revision"
    ));
    value["packet_order"] = json!(support::rows(
        &store.conn,
        "select id,record_json from collector_upload_outbox order by id"
    ));
    value
}

#[test]
fn statuses_preserve_base_journal_and_packet_order() {
    assert_base_order("statuses");
}

#[test]
fn t3_cleanup_preserves_base_journal_and_packet_order() {
    assert_base_order("t3");
}

#[test]
fn project_hints_preserve_base_journal_and_packet_order() {
    assert_base_order("project_hints");
}

fn assert_base_order(phase: &str) {
    use codex_sessions_collector::store::write_budget::{WriteBudget, WriteBudgetScope};
    use std::time::Duration;
    let golden: Value =
        serde_json::from_str(include_str!("fixtures/write_order_base.json")).unwrap();
    for soft in [Duration::from_millis(250), Duration::ZERO] {
        let _budget = WriteBudgetScope::enter(WriteBudget {
            soft,
            gap: Duration::ZERO,
            ..WriteBudget::default()
        });
        assert_eq!(
            capture_order_effects(phase),
            golden[phase],
            "base journal/packet order: {phase}, soft={soft:?}"
        );
    }
}
