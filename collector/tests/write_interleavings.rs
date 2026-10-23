//! Viewer-only interleavings under the collector lease (design 16).
//! Raw SQL models Dart writes; each target must equal edit-then-base or
//! base-then-edit at its own unit boundary. Sequential goldens in
//! write_side_effects pin exact base queues/journals independently.
mod support;
use codex_sessions_collector::store::write_budget::{
    WriteBudget, WriteBudgetScope, WriteChunkScope,
};
use codex_sessions_collector::{
    codex::{parser::SourceType, scanner::session_scan_roots},
    contract::{Envelope, ProjectHint, Record, SessionRef, SourceStatus, ThreadName},
    hub_client,
    store::{OwnerMode, Store, StoreResult, cache_repair, writer},
    t3,
};
use rusqlite::Connection;
use serde_json::{Value, json};
use std::{cell::Cell, path::Path, rc::Rc, time::Duration};
fn name(id: &str, value: &str) -> ThreadName {
    ThreadName {
        harness: "codex".into(),
        session_id: id.into(),
        thread_name: value.into(),
    }
}
#[test]
fn hub_receive_keeps_snapshots_and_receipt_in_one_outer_transaction() {
    let temp = support::TempDir::new("hub_receive_parent");
    let store = Store::open(&temp.path().join("receiver.sqlite"), OwnerMode::Standalone).unwrap();
    codex_sessions_collector::store::schema::in_write_transaction(&store.conn, || {
        store.apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(support::sample_snapshot("a"))))])?;
        store.conn.execute("insert into app_metadata(key,value,updated_at_utc) values('test.received.sequence','1','fixed')", [])?;
        Ok(())
    }).unwrap();
    assert_eq!(
        store
            .conn
            .query_row(
                "select count(*) from sessions where session_id='a'",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
        1
    );
    assert_eq!(
        store
            .conn
            .query_row(
                "select value from app_metadata where key='test.received.sequence'",
                [],
                |row| row.get::<_, String>(0)
            )
            .unwrap(),
        "1"
    );
}

const IDS: [&str; 4] = ["a", "b", "c", "skipped"];

fn hints() -> Vec<ProjectHint> {
    vec![ProjectHint {
        working_directory: "C:/work/repo".into(),
        project_name: "Resolved".into(),
    }]
}
fn refs() -> Vec<SessionRef> {
    IDS.iter()
        .map(|id| SessionRef {
            session_id: Some((*id).into()),
            source_path: format!("C:/synthetic/{id}.jsonl"),
        })
        .collect()
}
fn statuses() -> Vec<SourceStatus> {
    IDS.iter().map(|id| serde_json::from_value(json!({"harness":"codex","path":format!("C:\\synthetic\\{id}.jsonl"),"status":"missing","state":"active"})).unwrap()).collect()
}
fn names() -> Vec<ThreadName> {
    std::iter::once(name("a", "A"))
        .chain(IDS.iter().map(|id| name(id, "B")))
        .collect()
}
fn snapshots() -> Vec<codex_sessions_collector::contract::SessionSnapshot> {
    IDS.iter()
        .map(|id| {
            let mut snapshot = support::sample_snapshot(id);
            snapshot.session.working_directory_display = Some("C:/work/repo".into());
            snapshot.session.title = Some(format!("updated {id}"));
            snapshot.session.working_directory_platform = Some("C:/work/repo".into());
            snapshot
        })
        .collect()
}
fn seed_phase(store: &Store, phase: &str) {
    store
        .conn
        .execute(
            "update app_metadata set value='fixture' where key='machine_id'",
            [],
        )
        .unwrap();
    for id in IDS {
        let mut snapshot = support::sample_snapshot(id);
        snapshot.session.working_directory_display = Some("C:/work/repo".into());
        snapshot.session.working_directory_platform = Some("C:/work/repo".into());
        writer::apply_session_batch(&store.conn, vec![snapshot]).unwrap();
    }
    let conn = &store.conn;
    match phase {
        "statuses" => {
            conn.execute(
                "update sessions set scan_status='missing' where session_id='skipped'",
                [],
            )
            .unwrap();
        }
        "thread_names" => {
            conn.execute("update sessions set thread_name=case when session_id='skipped' then 'B' else 'A' end", []).unwrap();
        }
        "project_hints" | "project_backfill" => {
            writer::apply_project_hints(conn, "codex", &refs(), &hints()).unwrap();
            conn.execute("update sessions set detected_project_id=null,project_id=null,project_name_snapshot=null where session_id<>'skipped'", []).unwrap();
        }
        "metadata_placeholders" => {
            conn.execute("update sessions set title='# AGENTS.md old',summary='auto' where session_id<>'skipped'", []).unwrap();
        }
        "t3_lineage" => {
            conn.execute("update sessions set t3_parent_thread_id='old',t3_parent_session_id=null,t3_relationship='fork' where session_id<>'skipped'", []).unwrap();
            conn.execute("update sessions set t3_parent_thread_id='app-a',t3_parent_session_id='session:a',t3_relationship='fork' where session_id='skipped'", []).unwrap();
        }
        "cache_repair_audit" | "sessions" => {}
        _ => panic!("unknown phase"),
    }
    conn.execute("insert into collector_hub_state(id,enabled,hub_url,machine_id) values(1,1,'http://127.0.0.1:1','fixture')", []).unwrap();
    if phase == "thread_names" {
        hub_client::enqueue(conn, Record::ThreadName(name("a", "A")), "fixed").unwrap();
        hub_client::enqueue(conn, Record::ThreadName(name("skipped", "B")), "fixed").unwrap();
    }
}

fn t3_fixture(path: &std::path::Path) {
    let db = Connection::open(path).unwrap();
    db.execute_batch("create table orchestration_v2_projection_threads(payload_json text);create table orchestration_v2_projection_provider_threads(payload_json text)").unwrap();
    for id in IDS {
        db.execute("insert into orchestration_v2_projection_threads values(?)", [json!({"id":format!("app-{id}"),"lineage":{"parentThreadId":if id=="a" {None} else {Some("app-a")},"relationshipToParent":"fork"}}).to_string()]).unwrap();
        db.execute("insert into orchestration_v2_projection_provider_threads values(?)", [json!({"driver":"codex","appThreadId":format!("app-{id}"),"nativeThreadRef":{"driver":"codex","nativeId":id,"strength":"strong"}}).to_string()]).unwrap();
    }
}

fn run_phase(store: &Store, phase: &str, root: &std::path::Path) -> StoreResult<()> {
    match phase {
        "sessions" => {
            writer::apply_session_batch(&store.conn, snapshots())?;
        }
        "statuses" => writer::apply_source_statuses(&store.conn, &statuses())?,
        "thread_names" => {
            writer::apply_thread_names(&store.conn, &names())?;
        }
        "project_hints" => {
            writer::apply_project_hints(&store.conn, "codex", &refs(), &hints())?;
        }
        "project_backfill" => {
            writer::apply_project_backfill(&store.conn, &hints())?;
        }
        "metadata_placeholders" => {
            writer::clean_session_metadata_placeholders(&store.conn)?;
        }
        "t3_lineage" => {
            t3::import(&store.conn, &root.join("t3.sqlite"), "windows")
                .map_err(codex_sessions_collector::store::StoreError::Refused)?;
        }
        "cache_repair_audit" => {
            let report = cache_repair::run(
                store,
                &session_scan_roots(root.join(".codex").to_str().unwrap(), SourceType::Windows),
                true,
                &std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false)),
                &mut |_| Ok(true),
            )?;
            assert_eq!(report.status, "completed", "{report:?}");
        }
        _ => unreachable!(),
    }
    Ok(())
}

const PHASES: [&str; 8] = [
    "sessions",
    "statuses",
    "thread_names",
    "project_hints",
    "project_backfill",
    "metadata_placeholders",
    "t3_lineage",
    "cache_repair_audit",
];
fn budget() -> WriteBudgetScope {
    WriteBudgetScope::enter(WriteBudget {
        soft: Duration::ZERO,
        gap: Duration::ZERO,
        ..WriteBudget::default()
    })
}

#[test]
fn backfill_pending_override_has_no_project_side_effect() {
    let _budget = budget();
    fn setup(path: &Path) -> Store {
        let store = Store::open(path, OwnerMode::Standalone).unwrap();
        store.conn.execute_batch("insert into projects(id,name,is_active,created_at_utc,updated_at_utc) values(1,'Old',1,'fixed','fixed'),(2,'Manual',1,'fixed','fixed')").unwrap();
        for id in ["a", "b"] {
            store.conn.execute("insert into sessions(id,session_id,source_type,source_file_path,display_path,platform_path,working_directory_display,parse_status,scan_status,created_at_utc,updated_at_utc,harness,detected_project_id,project_id,project_name_snapshot,project_override) values(?1,?1,'windows',?1,?1,?1,?2,'available','available','fixed','fixed','codex',1,1,null,0)", rusqlite::params![id,format!("C:/work/{id}")]).unwrap();
        }
        store.conn.execute("insert into collector_hub_state(id,enabled,hub_url,machine_id) values(1,1,'http://127.0.0.1:1','fixture')", []).unwrap();
        store
    }
    for target in ["a", "b"] {
        let temp = support::TempDir::new("backfill_override_effects");
        let actual = setup(&temp.path().join("actual.sqlite"));
        let expected = setup(&temp.path().join("expected.sqlite"));
        let hints: Vec<_> = ["a", "b"]
            .iter()
            .map(|id| ProjectHint {
                working_directory: format!("C:/work/{id}"),
                project_name: format!("New-{id}"),
            })
            .collect();
        let sql = "update sessions set project_override=1,project_id=2,project_name_snapshot='Manual' where id=?";
        // a already committed at the boundary, b is pending. An override of b
        // removes it from the base candidate set before ANY project side effect.
        if target == "b" {
            expected.conn.execute(sql, [target]).unwrap();
        }
        writer::apply_project_backfill(&expected.conn, &hints).unwrap();
        if target == "a" {
            expected.conn.execute(sql, [target]).unwrap();
        }
        let peer = Connection::open(&actual.path).unwrap();
        let mut first = true;
        let observer = WriteChunkScope::observe(move |phase| {
            if phase == "project_backfill" && first {
                first = false;
                peer.execute(sql, [target]).unwrap();
            }
        });
        let watermark = revision(&actual.conn);
        writer::apply_project_backfill(&actual.conn, &hints).unwrap();
        drop(observer);
        assert_eq!(
            state(&actual),
            state(&expected),
            "backfill override target={target}"
        );
        assert_eq!(delivery(&actual.conn), delivery(&expected.conn));
        let final_revision: i64 = actual
            .conn
            .query_row(
                "select revision from session_changes where session_id=?",
                [target],
                |r| r.get(0),
            )
            .unwrap();
        assert!(final_revision > watermark);
    }
}

#[test]
fn project_hint_invalidated_by_override_has_no_project_side_effect() {
    let _budget = budget();
    fn setup(path: &Path) -> Store {
        let store = Store::open(path, OwnerMode::Standalone).unwrap();
        for id in ["a", "b"] {
            let mut snapshot = support::sample_snapshot(id);
            snapshot.session.working_directory_display = Some("C:/work/repo".into());
            writer::apply_session_batch(&store.conn, vec![snapshot]).unwrap();
        }
        writer::apply_project_hints(&store.conn, "codex", &refs(), &hints()).unwrap();
        store
            .conn
            .execute("update sessions set project_name_snapshot=null", [])
            .unwrap();
        store.conn.execute("insert into projects(id,name,is_active,created_at_utc,updated_at_utc) values(100,'Manual',1,'fixed','fixed')", []).unwrap();
        store.conn.execute("insert into collector_hub_state(id,enabled,hub_url,machine_id) values(1,1,'http://127.0.0.1:1','fixture')", []).unwrap();
        store
    }
    fn edit(conn: &Connection) {
        conn.execute_batch("begin immediate;
            update sessions set project_override=1,project_id=100,project_name_snapshot='Manual' where id='session:b';
            update projects set is_active=0,updated_at_utc='viewer-clock' where name='Resolved';
            update session_search set project_name='Manual' where rowid=(select rowid from sessions where id='session:b');
            commit;").unwrap();
    }
    let temp = support::TempDir::new("hint_override_effects");
    let actual = setup(&temp.path().join("actual.sqlite"));
    let expected = setup(&temp.path().join("expected.sqlite"));
    writer::apply_project_hints(&expected.conn, "codex", &refs(), &hints()).unwrap();
    edit(&expected.conn);
    let peer = Connection::open(&actual.path).unwrap();
    let mut first = true;
    let observer = WriteChunkScope::observe(move |phase| {
        if phase == "project_hints" && first {
            first = false;
            edit(&peer);
        }
    });
    writer::apply_project_hints(&actual.conn, "codex", &refs(), &hints()).unwrap();
    drop(observer);
    assert_eq!(
        state(&actual),
        state(&expected),
        "an invalidated hint must have no local effects, including project reactivation"
    );
    assert_eq!(delivery(&actual.conn), delivery(&expected.conn));
    assert_eq!(
        actual
            .conn
            .query_row(
                "select updated_at_utc from projects where name='Resolved'",
                [],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
        "viewer-clock",
        "an invalidated hint must not overwrite the viewer's project clock"
    );
}
fn fixture(root: &Path, phase: &str, edit: &str, target: &str) -> Store {
    std::fs::create_dir_all(root.join(".codex/sessions")).unwrap();
    std::fs::create_dir_all(root.join(".codex/archived_sessions")).unwrap();
    t3_fixture(&root.join("t3.sqlite"));
    let store = Store::open(&root.join("db.sqlite"), OwnerMode::Standalone).unwrap();
    seed_phase(&store, phase);
    store.conn.execute("insert into projects(id,name,is_active,created_at_utc,updated_at_utc) values(100,'Manual',1,'fixed','fixed')",[]).unwrap();
    if edit == "override_clear" {
        viewer_edit(&store.conn, "override_set", target);
    }
    store
}
// All edits use SQL on the viewer connection, never collector APIs. The FTS
// project/tag updates mirror the viewer's explicit denormalized updates.
fn viewer_edit(conn: &Connection, edit: &str, target: &str) {
    let id = format!("session:{target}");
    conn.execute_batch("begin immediate").unwrap();
    match edit {
        "override_set" => {
            conn.execute("update sessions set project_override=1,project_id=100,project_name_snapshot='Manual' where id=?",[&id]).unwrap();
        }
        "override_clear" => {
            conn.execute("update sessions set project_override=0,project_id=detected_project_id,project_name_snapshot=(select name from projects where id=sessions.detected_project_id) where id=?",[&id]).unwrap();
        }
        "rename_deactivate" => {
            conn.execute("update projects set name='Viewer renamed',is_active=0 where id=(select detected_project_id from sessions where id='session:skipped')",[]).unwrap();
            conn.execute("update sessions set project_name_snapshot=(select name from projects where id=sessions.project_id) where project_id=(select id from projects where name='Viewer renamed')",[]).unwrap();
        }
        "mask" => {
            conn.execute("insert into project_path_masks(project_id,path_mask,priority,is_active,created_at_utc,updated_at_utc) values(100,'C:/work/*',1,1,'fixed','fixed')",[]).unwrap();
            conn.execute("update sessions set project_id=100,project_name_snapshot='Manual' where coalesce(project_override,0)=0 and working_directory_display like 'C:/work/%'",[]).unwrap();
        }
        "pin_archive" => {
            conn.execute("update sessions set is_pinned=1,is_archived=1,archived_at_utc='2026-01-02T00:00:00Z',archive_reason='viewer' where id=?",[&id]).unwrap();
        }
        "eval" => {
            conn.execute("update sessions set eval_ready=1,eval_status='ready',eval_notes='viewer notes',eval_expected_output='answer',eval_reviewed_at_utc='2026-01-02T00:00:00Z',eval_updated_at_utc='2026-01-02T00:00:00Z' where id=?",[&id]).unwrap();
        }
        "tags" => {
            conn.execute("insert into tags(id,name,created_at_utc,updated_at_utc) values(100,'viewer tag','fixed','fixed')",[]).unwrap();
            conn.execute(
                "insert into session_tags(session_id,tag_id,created_at_utc) values(?,100,'fixed')",
                [&id],
            )
            .unwrap();
        }
        "vacuum" => {}
        "marker" => {
            conn.execute("insert into app_metadata(key,value,updated_at_utc) values('usage_migration_bootstrap','viewer','fixed')",[]).unwrap();
        }
        _ => panic!("unknown edit {edit}"),
    }
    conn.execute("update session_search set project_name=coalesce((select project_name_snapshot from sessions where rowid=session_search.rowid),'')",[]).unwrap();
    conn.execute("update session_search set tags=coalesce((select group_concat(t.name,' ') from session_tags st join tags t on t.id=st.tag_id join sessions s on s.id=st.session_id where s.rowid=session_search.rowid),'')",[]).unwrap();
    conn.execute_batch("commit").unwrap();
    if edit == "vacuum" {
        conn.execute_batch("vacuum").unwrap();
    }
}
fn state(store: &Store) -> Value {
    let mut value = support::content_snapshot(Path::new(&store.path));
    value["tags"] = json!(support::rows(&store.conn, "select * from tags order by id"));
    value["session_tags"] = json!(support::rows(
        &store.conn,
        "select * from session_tags order by session_id,tag_id"
    ));
    value["masks"] = json!(support::rows(
        &store.conn,
        "select * from project_path_masks order by id"
    ));
    value
}
fn delivery(conn: &Connection) -> Value {
    let mut result = serde_json::Map::new();
    for table in [
        "collector_upload_outbox",
        "collector_hub_record_state",
        "collector_hub_state",
        "collector_upload_dead_letters",
        "sqlite_sequence",
    ] {
        let mut rows = support::rows(conn, &format!("select * from {table} order by 1"));
        for row in &mut rows {
            if let Some(map) = row.as_object_mut() {
                map.remove("created_at_utc");
            }
        }
        // Project/tag/mask creation may advance their unrelated sequences;
        // preserve the exact queue sequences and all hub state.
        if table == "sqlite_sequence" {
            rows.retain(|r| r["name"].as_str().unwrap().starts_with("collector_"));
        }
        result.insert(table.into(), json!(rows));
    }
    Value::Object(result)
}
fn revision(conn: &Connection) -> i64 {
    conn.query_row(
        "select revision from session_change_state where id=1",
        [],
        |r| r.get(0),
    )
    .unwrap()
}
fn serial_references(phase: &str, edit: &str, target: &str) -> (Value, Value, Value, usize) {
    let before = support::TempDir::new("viewer_before");
    let a = fixture(before.path(), phase, edit, target);
    viewer_edit(&a.conn, edit, target);
    run_phase(&a, phase, before.path()).unwrap();
    let after = support::TempDir::new("viewer_after");
    let b = fixture(after.path(), phase, edit, target);
    let count = Rc::new(Cell::new(0));
    let seen = count.clone();
    let selected = phase.to_owned();
    let observer = WriteChunkScope::observe(move |p| {
        if p == selected {
            seen.set(seen.get() + 1)
        }
    });
    run_phase(&b, phase, after.path()).unwrap();
    drop(observer);
    viewer_edit(&b.conn, edit, target);
    assert_eq!(
        delivery(&a.conn),
        delivery(&b.conn),
        "viewer edits must not alter hub packets: {phase}/{edit}"
    );
    (state(&a), state(&b), delivery(&b.conn), count.get())
}
// Each session-indexed row is composed from the independently executed serial
// orders. Global viewer edits (mask/project changes) can affect several rows,
// whose units can fall on opposite sides of the same boundary. All remaining
// content and exact delivery state must come from one of those serial orders.
fn assert_serial_rows(actual: &Value, before: &Value, after: &Value, context: &str) {
    for (table, rows) in actual.as_object().unwrap() {
        if rows == &before[table] || rows == &after[table] {
            continue;
        }
        let rows = rows.as_array().unwrap();
        let a = before[table].as_array().unwrap();
        let b = after[table].as_array().unwrap();
        assert_eq!(rows.len(), a.len(), "length {context}/{table}");
        assert_eq!(rows.len(), b.len(), "length {context}/{table}");
        for (i, row) in rows.iter().enumerate() {
            assert!(
                row == &a[i] || row == &b[i],
                "nonserial {context}/{table}/{i}: actual={row}, before={}, after={}",
                a[i],
                b[i]
            );
        }
    }
}
fn every_viewer_boundary(phase: &str) {
    let _budget = budget();
    let edits: Vec<_> = if ["sessions", "project_hints", "project_backfill"].contains(&phase) {
        if phase == "sessions" {
            vec![
                "override_set",
                "override_clear",
                "rename_deactivate",
                "mask",
                "pin_archive",
                "eval",
                "tags",
                "vacuum",
            ]
        } else {
            vec![
                "override_set",
                "override_clear",
                "rename_deactivate",
                "mask",
                "vacuum",
            ]
        }
    } else if ["metadata_placeholders", "cache_repair_audit"].contains(&phase) {
        vec!["pin_archive", "eval", "tags", "vacuum"]
    } else {
        vec!["vacuum"]
    };
    let mut trials = 0;
    for edit in edits {
        for target in ["a", "c"] {
            let (before, after, packets, count) = serial_references(phase, edit, target);
            for boundary in 1..count {
                let temp = support::TempDir::new("viewer_trial");
                let store = fixture(temp.path(), phase, edit, target);
                let initial = state(&store);
                let target_rowid: i64 = store
                    .conn
                    .query_row(
                        "select rowid from sessions where session_id=?",
                        [target],
                        |r| r.get(0),
                    )
                    .unwrap();
                let touched = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
                let updated = touched.clone();
                store
                    .conn
                    .update_hook(Some(
                        move |_: rusqlite::hooks::Action, _: &str, table: &str, row: i64| {
                            if table == "sessions" && row == target_rowid {
                                updated.store(true, std::sync::atomic::Ordering::Relaxed);
                            }
                        },
                    ))
                    .unwrap();
                let applied = Rc::new(Cell::new(false));
                let committed = applied.clone();
                let watermark = revision(&store.conn);
                let viewer = Connection::open(&store.path).unwrap();
                viewer.busy_timeout(Duration::from_secs(1)).unwrap();
                let n = Rc::new(Cell::new(0));
                let seen = n.clone();
                let phase_name = phase.to_owned();
                let edit_name = edit.to_owned();
                let id = target.to_owned();
                let last = Rc::new(Cell::new(watermark));
                let check = last.clone();
                let observer = WriteChunkScope::observe(move |p| {
                    if p == phase_name {
                        let current = revision(&viewer);
                        assert!(current >= check.get());
                        check.set(current);
                        seen.set(seen.get() + 1);
                        if seen.get() == boundary {
                            committed.set(touched.load(std::sync::atomic::Ordering::Relaxed));
                            viewer_edit(&viewer, &edit_name, &id);
                        }
                    }
                });
                run_phase(&store, phase, temp.path()).unwrap();
                drop(observer);
                assert!(n.get() >= boundary);
                let actual = state(&store);
                let context = format!("{phase}/{edit}/{target}/boundary{boundary}");
                assert_serial_rows(&actual, &before, &after, &context);
                let expected = if applied.get() { &after } else { &before };
                let target_id = format!("session:{target}");
                let target_row = |value: &Value| {
                    value["sessions"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .find(|r| r["id"] == target_id)
                        .unwrap()
                        .clone()
                };
                assert_eq!(
                    target_row(&actual),
                    target_row(expected),
                    "target unit direction {context}"
                );
                store
                    .conn
                    .update_hook(None::<fn(rusqlite::hooks::Action, &str, &str, i64)>)
                    .unwrap();
                assert_eq!(delivery(&store.conn), packets, "delivery {context}");
                for (old, new) in initial["sessions"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .zip(actual["sessions"].as_array().unwrap())
                {
                    if old != new {
                        let id = new["id"].as_str().unwrap();
                        let rev: i64 = store
                            .conn
                            .query_row(
                                "select revision from session_changes where session_id=?",
                                [id],
                                |r| r.get(0),
                            )
                            .unwrap();
                        assert!(rev > watermark, "consumer missed {context}/{id}");
                    }
                }
                trials += 1;
            }
        }
    }
    eprintln!("viewer_matrix phase={phase} trials={trials}");
    assert!(trials > 0);
}
macro_rules! viewer_matrix {
    ($test:ident,$phase:literal) => {
        #[test]
        fn $test() {
            every_viewer_boundary($phase);
        }
    };
}
viewer_matrix!(sessions_viewer_edits, "sessions");
viewer_matrix!(statuses_viewer_edits, "statuses");
viewer_matrix!(thread_names_viewer_edits, "thread_names");
viewer_matrix!(hints_viewer_edits, "project_hints");
viewer_matrix!(backfill_viewer_edits, "project_backfill");
viewer_matrix!(placeholders_viewer_edits, "metadata_placeholders");
viewer_matrix!(t3_viewer_edits, "t3_lineage");
viewer_matrix!(cache_viewer_edits, "cache_repair_audit");
#[test]
fn migration_marker_stops_each_phase_at_the_next_chunk_and_rerun_converges() {
    let _budget = budget();
    for phase in PHASES {
        let reference = support::TempDir::new("viewer_marker_reference");
        let oracle = fixture(reference.path(), phase, "marker", "a");
        let count = Rc::new(Cell::new(0));
        let seen = count.clone();
        let observer = WriteChunkScope::observe(move |p| {
            if p == phase {
                seen.set(seen.get() + 1)
            }
        });
        run_phase(&oracle, phase, reference.path()).unwrap();
        drop(observer);
        for boundary in 1..count.get() {
            let temp = support::TempDir::new("viewer_marker");
            let store = fixture(temp.path(), phase, "marker", "a");
            let viewer = Connection::open(&store.path).unwrap();
            let injected = Rc::new(Cell::new(0));
            let seen = injected.clone();
            let observer = WriteChunkScope::observe(move |p| {
                if p == phase {
                    seen.set(seen.get() + 1);
                    if seen.get() == boundary {
                        viewer_edit(&viewer, "marker", "a");
                    }
                }
            });
            let error = run_phase(&store, phase, temp.path()).unwrap_err();
            drop(observer);
            assert!(
                matches!(
                    error,
                    codex_sessions_collector::store::StoreError::Unavailable(_)
                        | codex_sessions_collector::store::StoreError::Refused(_)
                ),
                "{phase}: {error:?}"
            );
            // The legacy T3 adapter returns a string refusal; the store APIs
            // preserve the typed transient fence. Both must name migration.
            assert!(error.to_string().contains("migrating"), "{phase}: {error}");
            assert_eq!(
                injected.get(),
                boundary,
                "phase continued past marker: {phase}"
            );
            store
                .conn
                .execute(
                    "delete from app_metadata where key='usage_migration_bootstrap'",
                    [],
                )
                .unwrap();
            run_phase(&store, phase, temp.path()).unwrap();
            assert_eq!(
                state(&store),
                state(&oracle),
                "marker rerun: {phase}/{boundary}"
            );
            assert_eq!(
                final_packets(&store.conn),
                final_packets(&oracle.conn),
                "marker final packets {phase}/{boundary}"
            );
        }
        eprintln!("marker_matrix phase={phase} trials={}", count.get() - 1);
    }
}

// An interrupted call already exposed committed chunks; replay can allocate
// newer queue IDs or duplicate unkeyed hints. Require the same final keyed
// values/hash state, rather than pretending its partial commits rolled back.
fn final_packets(conn: &Connection) -> Value {
    let mut packets = support::rows(
        conn,
        "select record_json from collector_upload_outbox order by record_json",
    );
    packets.dedup();
    json!({"packets":packets,"hashes":support::rows(conn,"select * from collector_hub_record_state order by record_key")})
}
