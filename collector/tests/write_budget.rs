mod support;

use std::time::Duration;

use codex_sessions_collector::store::{
    schema::{self, StoreError},
    write_budget::{HoldStats, WriteHoldScope, write_phase},
};
use rusqlite::Connection;

#[test]
fn rollback_journal_to_wal_has_a_measured_owner() {
    let temp = support::TempDir::new("journal_mode_hold");
    let db = temp.path().join("rollback.sqlite");
    let conn = Connection::open(&db).unwrap();
    conn.execute_batch("create table fixture(id integer)")
        .unwrap();
    assert_eq!(&std::fs::read(&db).unwrap()[18..20], &[1, 1]);
    let holds = WriteHoldScope::for_phase("journal_mode");
    schema::configure(&conn, 100).unwrap();
    assert!(conn.is_autocommit());
    assert_eq!(&std::fs::read(&db).unwrap()[18..20], &[2, 2]);
    assert_eq!(holds.report().transactions, 1);
    assert_eq!(holds.report().max_phase.as_deref(), Some("journal_mode"));
    assert!(holds.report().max_ms > 0.0);
}

#[cfg(debug_assertions)]
#[test]
fn completeness_open_bootstrap_and_migration() {
    use codex_sessions_collector::store::{OwnerMode, Store, write_budget::audit::WriteAudit};
    let temp = support::TempDir::new("audit_bootstrap");
    let old = temp.path().join("old.sqlite");
    support::create_database_at_version(&old, 29);
    let conn = Connection::open(&old).unwrap();
    conn.execute_batch("update database_generations set target_schema_version=16; update database_state set active_usage_generation_id=(select min(id) from database_generations)").unwrap();
    conn.execute(
        "update app_metadata set value='collector' where key='database_owner'",
        [],
    )
    .unwrap();
    let mode: String = conn
        .query_row("pragma journal_mode=delete", [], |row| row.get(0))
        .unwrap();
    assert_eq!(mode, "delete");
    drop(conn);
    let audit = WriteAudit::start();
    let store = Store::open(&old, OwnerMode::Standalone).unwrap();
    assert_eq!(schema::last_applied_version(&store.conn).unwrap(), 30);
    drop(store);
    let fresh = Store::open(&temp.path().join("new.sqlite"), OwnerMode::Standalone).unwrap();
    assert_eq!(schema::last_applied_version(&fresh.conn).unwrap(), 30);
    // Includes writes after Connection moved out of Store::open.
    schema::in_write_transaction(&fresh.conn, || {
        fresh.conn.execute(
            "insert into app_metadata values ('audit-move','v','now')",
            [],
        )?;
        Ok(())
    })
    .unwrap();
    let report = audit.report();
    assert_eq!(report.connections, 2);
    assert!(report.commits > 0);
    audit.assert_complete();
}

#[cfg(debug_assertions)]
#[test]
fn completeness_guard_detects_unowned_commit_and_special_pragma() {
    use codex_sessions_collector::store::write_budget::audit::WriteAudit;
    let temp = support::TempDir::new("audit_negative");
    let conn = Connection::open(temp.path().join("fixture.sqlite")).unwrap();
    conn.execute_batch("create table fixture(id integer)")
        .unwrap();
    let audit = WriteAudit::start();
    audit.attach(&conn).unwrap();
    // Deliberate accounting mutants: the guard must catch both historical
    // defect classes without relying on the phase-specific regression tests.
    conn.execute("insert into fixture values (1)", []).unwrap();
    conn.query_row("pragma journal_mode=wal", [], |row| row.get::<_, String>(0))
        .unwrap();
    let report = audit.report();
    assert!(report.commits > 0);
    assert!(report.unattributed.iter().any(|entry| entry == "commit"));
    assert!(
        report
            .unattributed
            .iter()
            .any(|entry| entry == "pragma journal_mode")
    );
    assert!(std::panic::catch_unwind(|| report.assert_complete()).is_err());
}

#[cfg(debug_assertions)]
#[test]
fn completeness_guard_rejects_missing_completion_after_already_wal_configure() {
    use codex_sessions_collector::store::{OwnerMode, Store, write_budget::audit::WriteAudit};
    let temp = support::TempDir::new("audit_replaced_completion");
    let store = Store::open(&temp.path().join("fixture.sqlite"), OwnerMode::Standalone).unwrap();
    let audit = WriteAudit::start();
    audit.attach(&store.conn).unwrap();
    let holds = WriteHoldScope::start();
    schema::begin_write(&store.conn).unwrap();
    store
        .conn
        .execute(
            "insert into app_metadata values ('missing-original-completion','v','now')",
            [],
        )
        .unwrap();
    store.conn.execute_batch("commit").unwrap(); // deliberately omit finish
    assert_eq!(audit.report().commits, 1);
    assert_eq!(holds.report().transactions, 0);
    // This no-op WAL configuration used to replace the unfinished owner and
    // let its unrelated sample erase the original commit's pending receipt.
    schema::configure(&store.conn, 100).unwrap();
    assert_eq!(audit.report().commits, 1);
    assert_eq!(holds.report().transactions, 1);
    assert_eq!(holds.report().max_phase.as_deref(), Some("journal_mode"));
    assert!(
        std::panic::catch_unwind(|| audit.report().assert_complete()).is_err(),
        "the journal_mode sample must not cover the original write commit"
    );
}

#[cfg(debug_assertions)]
#[test]
fn completeness_guard_detects_missing_completion() {
    use codex_sessions_collector::store::{OwnerMode, Store, write_budget::audit::WriteAudit};
    let temp = support::TempDir::new("audit_completion");
    let audit = WriteAudit::start();
    let store = Store::open(&temp.path().join("fixture.sqlite"), OwnerMode::Standalone).unwrap();
    schema::begin_write(&store.conn).unwrap();
    store
        .conn
        .execute(
            "insert into app_metadata values ('missing-completion','v','now')",
            [],
        )
        .unwrap();
    store.conn.execute_batch("commit").unwrap(); // deliberately omit finish/record
    assert!(std::panic::catch_unwind(|| audit.report().assert_complete()).is_err());
    // Clean the deliberately incomplete owner through the production finish path.
    assert!(schema::finish(&store.conn, Ok(())).is_err());
    audit.assert_complete();
}

#[cfg(debug_assertions)]
#[test]
fn completeness_codex_claude_and_price_history() {
    use codex_sessions_collector::{
        claude::{self, ClaudeRoot, ClaudeScanOptions},
        codex::{
            self,
            parser::{ParserOptions, SourceType},
            scanner::{ScanOptions, session_scan_roots},
        },
        path_mapping::PathMapper,
        price_history,
        store::{OwnerMode, Store, write_budget::audit::WriteAudit},
    };
    let temp = support::TempDir::new("audit_scans");
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
    let claude_root = temp.path().join("claude");
    std::fs::create_dir_all(claude_root.join("project")).unwrap();
    std::fs::write(claude_root.join("project/audit.jsonl"), serde_json::json!({
        "type":"user", "sessionId":"audit-claude", "uuid":"audit-message", "timestamp":"2026-01-01T00:00:00Z",
        "message":{"role":"user","content":"audit fixture"}
    }).to_string()+"\n").unwrap();
    let audit = WriteAudit::start();
    let store = Store::open(&temp.path().join("fixture.sqlite"), OwnerMode::Standalone).unwrap();
    let codex = codex::collect(
        &store,
        &ScanOptions {
            roots: session_scan_roots(home.to_str().unwrap(), SourceType::Windows),
            mapper: PathMapper::new(String::new()),
            parser: ParserOptions::default(),
            parser_workers: 1,
            wsl_root_retry_delays: vec![],
            thread_names: Default::default(),
            force: true,
        },
        false,
    )
    .unwrap();
    assert!(codex.applied.sessions > 0);
    audit.assert_complete();
    let before = audit.report().commits;
    let claude = claude::collect(
        &store,
        &ClaudeScanOptions {
            roots: vec![ClaudeRoot {
                path: claude_root.to_string_lossy().into_owned(),
                source_type: SourceType::Windows,
            }],
            mapper: PathMapper::new(String::new()),
            parser: Default::default(),
            workers: 1,
            force: true,
            resolve_wsl_projects: false,
        },
    )
    .unwrap();
    assert!(claude.applied.sessions > 0);
    assert!(audit.report().commits > before);
    audit.assert_complete();
    let before = audit.report().commits;
    let history = price_history::synchronize(temp.path(), "machine-a", serde_json::json!({
        "protocol":1, "observations":[{
            "origin":"machine-a", "authority":"local", "observed_at_utc":"2026-01-01T00:00:00.000000Z",
            "provider":"provider", "model_id":"provider/model", "model":{"id":"provider/model","pricing":{"prompt":"0.1"}}
        }]
    })).unwrap();
    assert_eq!(history["observations"].as_array().unwrap().len(), 1);
    assert!(audit.report().commits > before);
    audit.assert_complete();
}

#[test]
fn hold_stats_distribution_and_max_phase() {
    let mut stats = HoldStats::default();
    for ms in 1..=100 {
        stats.record(Duration::from_millis(ms), "sessions");
    }
    stats.record(Duration::from_millis(900), "statuses");
    let report = stats.report();
    assert_eq!(report.transactions, 101);
    assert_eq!(report.max_ms, 900.0);
    assert_eq!(report.p99_ms, 100.0); // nearest rank ceil(.99 * 101) = 100
    assert_eq!(report.max_phase.as_deref(), Some("statuses"));
}

#[test]
fn hold_stats_empty_and_submillisecond() {
    let mut stats = HoldStats::default();
    let report = stats.report();
    assert_eq!(report.transactions, 0);
    assert_eq!(report.max_ms, 0.0);
    assert_eq!(report.p99_ms, 0.0);
    assert_eq!(report.max_phase, None);
    stats.record(Duration::from_micros(125), "tiny");
    assert_eq!(stats.report().max_ms, 0.125);
    assert!(stats.report().p99_ms >= 0.125);
    assert!(stats.report().p99_ms <= 1.0);
}

#[test]
fn hold_stats_commit_rollback_nested_and_scope_restoration() {
    let conn = Connection::open_in_memory().unwrap();
    schema::prepare_standalone(&conn, ":memory:").unwrap();
    let scope = WriteHoldScope::start();
    let phase = write_phase("outer");
    schema::in_write_transaction(&conn, || {
        let _inner = write_phase("nested");
        schema::begin_write(&conn)?;
        schema::finish(&conn, Ok(()))
    })
    .unwrap();
    drop(phase);
    let phase = write_phase("failed");
    schema::begin_write(&conn).unwrap();
    std::thread::sleep(Duration::from_millis(20));
    assert!(schema::finish::<()>(&conn, Err(StoreError::Refused("test".into()))).is_err());
    drop(phase);
    let stats = scope.report();
    assert_eq!(stats.transactions, 2); // savepoints do not release the write lock
    assert!(stats.max_ms >= 20.0);
    assert_eq!(stats.max_phase.as_deref(), Some("failed"));
    let next = WriteHoldScope::start();
    schema::begin_write(&conn).unwrap();
    schema::finish(&conn, Ok(())).unwrap();
    assert_eq!(next.report().transactions, 1);
    assert_eq!(next.report().max_phase.as_deref(), Some("unlabelled"));
}

#[test]
fn hold_stats_refusal_and_panic_rollback_are_measured() {
    let conn = Connection::open_in_memory().unwrap();
    schema::prepare_standalone(&conn, ":memory:").unwrap();
    let scope = WriteHoldScope::start();
    let _phase = write_phase("panic");
    let panic = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let _ = schema::in_write_transaction(&conn, || -> schema::StoreResult<()> {
            panic!("synthetic");
        });
    }));
    assert!(panic.is_err());
    assert!(conn.is_autocommit());
    conn.execute(
        "update schema_version set version = 999 where version = 30",
        [],
    )
    .unwrap();
    assert!(schema::begin_write(&conn).is_err());
    assert!(conn.is_autocommit());
    assert_eq!(scope.report().transactions, 2);
}

#[test]
fn hold_stats_commit_failure_records_rollback() {
    let conn = Connection::open_in_memory().unwrap();
    schema::prepare_standalone(&conn, ":memory:").unwrap();
    // A commit hook rejection exercises the real failed-COMMIT cleanup path.
    conn.commit_hook(Some(|| true)).unwrap();
    let scope = WriteHoldScope::start();
    let _phase = write_phase("commit_failure");
    schema::begin_write(&conn).unwrap();
    conn.execute(
        "insert into app_metadata values ('hold_test','v','now')",
        [],
    )
    .unwrap();
    assert!(schema::finish(&conn, Ok(())).is_err());
    assert!(conn.is_autocommit());
    assert_eq!(scope.report().transactions, 1);
    assert_eq!(scope.report().max_phase.as_deref(), Some("commit_failure"));
    assert_eq!(
        conn.query_row(
            "select count(*) from app_metadata where key='hold_test'",
            [],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        0
    );
}

#[test]
fn hold_stats_waiting_for_begin_is_not_a_hold() {
    let temp = support::TempDir::new("hold_stats_busy");
    let db = support::viewer_database(&temp);
    let blocked = Connection::open(&db).unwrap();
    blocked.busy_timeout(Duration::from_millis(30)).unwrap();
    let owner = Connection::open(&db).unwrap();
    owner.execute_batch("begin immediate").unwrap();
    let scope = WriteHoldScope::start();
    assert!(schema::begin_write(&blocked).is_err());
    assert_eq!(scope.report().transactions, 0);
    owner.execute_batch("rollback").unwrap();
    schema::begin_write(&blocked).unwrap();
    schema::finish(&blocked, Ok(())).unwrap();
    assert_eq!(scope.report().transactions, 1);
}

#[test]
fn hold_stats_scan_reports_json_and_text() {
    let temp = support::TempDir::new("hold_stats_reports");
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
    let db = support::viewer_database(&temp);
    let result = support::scan(&db, &home, &["--json"]);
    assert!(result.status.success(), "{:?}", result);
    let report: serde_json::Value = serde_json::from_slice(&result.stdout).unwrap();
    assert!(report["write_hold"]["transactions"].as_u64().unwrap() > 0);
    assert!(report["write_hold"]["max_ms"].as_f64().unwrap() > 0.0);
    assert!(report["write_hold"]["p99_ms"].as_f64().unwrap() > 0.0);
    assert!(report["write_hold"]["max_phase"].as_str().is_some());
    let result = support::scan(&db, &home, &[]);
    assert!(result.status.success());
    assert!(
        String::from_utf8(result.stdout)
            .unwrap()
            .contains("write_hold:")
    );
    let root = temp.path().join("claude");
    std::fs::create_dir(&root).unwrap();
    for json in [true, false] {
        let mut command = support::collector();
        command
            .args(["claude", "scan", "--no-wsl-projects", "--db"])
            .arg(&db)
            .arg("--claude-root")
            .arg(&root);
        if json {
            command.arg("--json");
        }
        let result = command.output().unwrap();
        assert!(result.status.success(), "{:?}", result);
        if json {
            let report: serde_json::Value = serde_json::from_slice(&result.stdout).unwrap();
            assert!(report["write_hold"]["transactions"].is_u64());
            assert!(report["write_hold"]["max_ms"].is_number());
            assert!(report["write_hold"]["p99_ms"].is_number());
            assert!(report["write_hold"].get("max_phase").is_some());
        } else {
            assert!(
                String::from_utf8(result.stdout)
                    .unwrap()
                    .contains("write_hold:")
            );
        }
    }
}

#[test]
fn autocommit_statements_are_measured_without_counting_outer_writes_twice() {
    use codex_sessions_collector::store::write_budget::execute_write;
    let conn = Connection::open_in_memory().unwrap();
    schema::prepare_standalone(&conn, ":memory:").unwrap();
    let statements = WriteHoldScope::for_phase("single_statement");
    execute_write(
        &conn,
        "single_statement",
        "create table hold_single(id integer primary key)",
        [],
    )
    .unwrap();
    execute_write(
        &conn,
        "single_statement",
        "insert into hold_single values (?)",
        [1],
    )
    .unwrap();
    execute_write(
        &conn,
        "single_statement",
        "update hold_single set id = ?",
        [2],
    )
    .unwrap();
    execute_write(
        &conn,
        "single_statement",
        "delete from hold_single where id = ?",
        [2],
    )
    .unwrap();
    assert_eq!(statements.report().transactions, 4);
    assert_eq!(
        statements.report().max_phase.as_deref(),
        Some("single_statement")
    );
    assert!(
        execute_write(
            &conn,
            "single_statement",
            "insert into hold_single values (null),(1),(1)",
            []
        )
        .is_err()
    );
    assert!(conn.is_autocommit());
    assert_eq!(statements.report().transactions, 5);
    assert_eq!(
        conn.query_row("select count(*) from hold_single", [], |row| row
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
    let outer = WriteHoldScope::for_phase("outer_statement");
    let _phase = write_phase("outer_statement");
    schema::in_write_transaction(&conn, || {
        execute_write(
            &conn,
            "single_statement",
            "insert into hold_single values (3)",
            [],
        )?;
        Ok(())
    })
    .unwrap();
    assert_eq!(outer.report().transactions, 1);
    assert_eq!(statements.report().transactions, 5);
}

#[test]
fn hub_bootstrap_identity_and_each_ddl_statement_have_write_holds() {
    use codex_sessions_collector::{hub_annotations, hub_server::HubConfig};
    let temp = support::TempDir::new("hub_bootstrap_holds");
    let config: HubConfig = serde_json::from_value(serde_json::json!({
        "owner_token":"fixture-owner", "machines":{"machine-a":"fixture-token"}
    }))
    .unwrap();
    let identity = WriteHoldScope::for_phase("hub_identity");
    let schema = WriteHoldScope::for_phase("hub_schema");
    #[cfg(debug_assertions)]
    let audit = codex_sessions_collector::store::write_budget::audit::WriteAudit::start();
    let result = hub_annotations::read(
        temp.path(),
        &config,
        serde_json::json!({
            "protocol":1, "machine":"machine-a", "reference":"history://machine-a/absent"
        }),
    );
    assert_eq!(result.unwrap_err().0, 404);
    assert_eq!(identity.report().transactions, 1);
    assert_eq!(identity.report().max_phase.as_deref(), Some("hub_identity"));
    // The two DDL statements keep their original independent commit boundaries.
    assert_eq!(schema.report().transactions, 2);
    assert_eq!(schema.report().max_phase.as_deref(), Some("hub_schema"));
    #[cfg(debug_assertions)]
    audit.assert_complete();
    let conn = Connection::open(temp.path().join("machine-a.sqlite")).unwrap();
    assert_eq!(
        conn.query_row(
            "select value from app_metadata where key='machine_id'",
            [],
            |row| row.get::<_, String>(0)
        )
        .unwrap(),
        "machine-a"
    );
}
