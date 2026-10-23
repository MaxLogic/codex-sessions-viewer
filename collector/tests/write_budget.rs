mod support;

use std::time::Duration;

use codex_sessions_collector::store::{
    schema::{self, StoreError},
    write_budget::{HoldStats, WriteHoldScope, write_phase},
};
use rusqlite::Connection;

/// Count actual SQLite VM instructions only while a physical transaction is
/// open. Stop a quadratic regression promptly rather than hanging the suite.
fn locked_steps(conn: &Connection) -> std::sync::Arc<std::sync::atomic::AtomicU64> {
    use std::sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    };
    let steps = Arc::new(AtomicU64::new(0));
    let count = steps.clone();
    // The hook is attached to this live connection and removed before it drops.
    let handle = unsafe { conn.handle() } as usize;
    conn.progress_handler(
        1,
        Some(move || {
            if unsafe { rusqlite::ffi::sqlite3_get_autocommit(handle as *mut _) } == 0 {
                count.fetch_add(1, Ordering::Relaxed) > 2_000_000
            } else {
                false
            }
        }),
    )
    .unwrap();
    steps
}

fn padded_status_store(rows: usize) -> Connection {
    let conn = Connection::open_in_memory().unwrap();
    schema::prepare_standalone(&conn, ":memory:").unwrap();
    conn.execute(
        "with recursive n(x) as (values(1) union all select x+1 from n where x < ?1)
        insert into sessions(id,harness,source_type,source_file_path,display_path,platform_path,
            scan_status,source_state,parse_status,created_at_utc,updated_at_utc,last_scanned_utc)
        select 'padding:'||x,'codex','windows','compressed-'||x||'.jsonl.zst',
            'compressed-'||x||'.jsonl.zst','compressed-'||x||'.jsonl.zst',
            'unsupported_format','active','available','now','now','now' from n",
        [rows as i64],
    )
    .unwrap();
    conn
}

fn unsupported_status(path: &str) -> codex_sessions_collector::contract::SourceStatus {
    serde_json::from_value(serde_json::json!({"harness":"codex","path":path,
        "status":"unsupported_format","state":"active"}))
    .unwrap()
}

#[test]
fn status_lock_work_scales_with_changes_and_70k_unchanged_rows_do_not_write() {
    use codex_sessions_collector::store::writer;
    use std::sync::atomic::Ordering;
    let mut measured = Vec::new();
    for rows in [1_000, 70_553] {
        let conn = padded_status_store(rows);
        let mut changed = unsupported_status("compressed-1.jsonl.zst");
        changed.state = "codex_archived".into();
        let steps = locked_steps(&conn);
        writer::apply_source_statuses(&conn, &[changed]).unwrap();
        measured.push(steps.load(Ordering::Relaxed));
        conn.progress_handler(0, None::<fn() -> bool>).unwrap();
        let statuses: Vec<_> = (2..=rows)
            .map(|n| unsupported_status(&format!("compressed-{n}.jsonl.zst")))
            .collect();
        let scope = WriteHoldScope::for_phase("statuses");
        let steps = locked_steps(&conn);
        writer::apply_source_statuses(&conn, &statuses).unwrap();
        conn.progress_handler(0, None::<fn() -> bool>).unwrap();
        assert_eq!(
            scope.report().transactions,
            0,
            "unchanged error statuses must not acquire a write lock"
        );
        assert_eq!(steps.load(Ordering::Relaxed), 0);
    }
    assert!(
        measured[1] * 2 < measured[0] * 3,
        "in-lock VM steps: {measured:?}"
    );
}

#[test]
fn status_full_input_t2_stays_below_reviewed_bound() {
    use codex_sessions_collector::store::{
        write_budget::{WriteBudget, WriteBudgetScope, WriteChunkScope},
        writer,
    };
    use std::{cell::Cell, rc::Rc, sync::atomic::Ordering};
    let _budget = WriteBudgetScope::enter(WriteBudget {
        soft: Duration::ZERO,
        gap: Duration::ZERO,
        ..WriteBudget::default()
    });
    let mut measurements = Vec::new();
    for count in [1000, 70553] {
        let temp = support::TempDir::new("status_t2");
        let path = temp.path().join("db.sqlite");
        let conn = padded_status_store(count);
        conn.execute("vacuum into ?", [path.to_str().unwrap()])
            .unwrap();
        drop(conn);
        let conn = Connection::open(&path).unwrap();
        let viewer = Connection::open(&path).unwrap();
        let injected = Rc::new(Cell::new(false));
        let did = injected.clone();
        let observer = WriteChunkScope::observe(move |p| {
            if p == "statuses" && !did.replace(true) {
                viewer
                    .execute("update sessions set is_pinned=1 where id='padding:1'", [])
                    .unwrap();
            }
        });
        let input: Vec<_> = (1..=count)
            .map(|n| {
                let mut s = unsupported_status(&format!("compressed-{n}.jsonl.zst"));
                if n <= 2 {
                    s.state = "codex_archived".into();
                }
                s
            })
            .collect();
        let steps = locked_steps(&conn);
        let holds = WriteHoldScope::for_phase("statuses");
        writer::apply_source_statuses(&conn, &input).unwrap();
        drop(observer);
        conn.progress_handler(0, None::<fn() -> bool>).unwrap();
        let steps = steps.load(Ordering::Relaxed);
        let transactions = holds.report().transactions;
        assert!(injected.get());
        assert!(steps <= 2967, "steps={steps}");
        assert!(transactions <= 4);
        assert_eq!(
            conn.query_row(
                "select count(*) from sessions where source_state='codex_archived'",
                [],
                |r| r.get::<_, i64>(0)
            )
            .unwrap(),
            2
        );
        eprintln!(
            "T2 rows={count} inputs={} in_lock_steps={steps} transactions={transactions} max_hold_ms={:.3}",
            input.len(),
            holds.report().max_ms
        );
        measurements.push((steps, transactions));
    }
    assert_eq!(measurements[0], measurements[1]);
}

#[test]
fn compressed_noop_preserves_placeholder_metadata_journal_and_hub_queue() {
    use codex_sessions_collector::{
        codex::{
            self,
            parser::{ParserOptions, SourceType},
            scanner::{ScanOptions, session_scan_roots},
        },
        path_mapping::PathMapper,
        store::{OwnerMode, Store},
    };
    let temp = support::TempDir::new("compressed_metadata");
    let home = support::codex_home(&temp, &[]);
    let path = support::day_folder(&home).join("unsupported.jsonl.zst");
    std::fs::write(&path, b"compressed").unwrap();
    let store = Store::open(&temp.path().join("fixture.sqlite"), OwnerMode::Standalone).unwrap();
    let options = ScanOptions {
        roots: session_scan_roots(home.to_str().unwrap(), SourceType::Windows),
        mapper: PathMapper::new(String::new()),
        parser: ParserOptions::default(),
        parser_workers: 1,
        wsl_root_retry_delays: vec![],
        thread_names: Default::default(),
        force: false,
    };
    codex::collect(&store, &options, false).unwrap();
    let metadata: (i64, Option<String>) = store
        .conn
        .query_row(
            "select file_size,modified_utc from sessions where scan_status='unsupported_format'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(
        metadata,
        (0, None),
        "unsupported placeholders retain legacy metadata"
    );
    store.conn.execute("insert into collector_hub_state(id,enabled,hub_url,machine_id) values (1,1,'http://127.0.0.1:1','fixture')",[]).unwrap();
    let tables = [
        "sessions",
        "session_changes",
        "session_change_state",
        "collector_upload_outbox",
        "collector_hub_record_state",
    ];
    let before: Vec<_> = tables
        .iter()
        .map(|table| support::rows(&store.conn, &format!("select * from {table}")))
        .collect();
    // Extension-based status is unchanged even when the compressed file's
    // content revision changes. No persisted revision is needed to know that.
    std::fs::write(&path, b"a different compressed revision").unwrap();
    let holds = WriteHoldScope::start();
    codex::collect(&store, &options, false).unwrap();
    assert_eq!(holds.report().transactions, 0);
    let after: Vec<_> = tables
        .iter()
        .map(|table| support::rows(&store.conn, &format!("select * from {table}")))
        .collect();
    assert_eq!(before, after);
}

#[test]
fn steady_state_full_scan_with_compressed_sources_has_zero_write_transactions() {
    use codex_sessions_collector::{
        codex::{
            self,
            parser::{ParserOptions, SourceType},
            scanner::{ScanOptions, session_scan_roots},
        },
        path_mapping::PathMapper,
        store::{OwnerMode, Store},
    };
    let temp = support::TempDir::new("steady_compressed");
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
    std::fs::write(
        support::day_folder(&home).join("unsupported.jsonl.zst"),
        b"compressed",
    )
    .unwrap();
    let store = Store::open(&temp.path().join("fixture.sqlite"), OwnerMode::Standalone).unwrap();
    let options = ScanOptions {
        roots: session_scan_roots(home.to_str().unwrap(), SourceType::Windows),
        mapper: PathMapper::new(String::new()),
        parser: ParserOptions::default(),
        parser_workers: 1,
        wsl_root_retry_delays: vec![],
        thread_names: Default::default(),
        force: false,
    };
    codex::collect(&store, &options, false).unwrap();
    let holds = WriteHoldScope::start();
    let report = codex::collect(&store, &options, false).unwrap();
    assert_eq!(report.counts.files_parsed, 0);
    assert_eq!(
        holds.report().transactions,
        0,
        "unchanged scan must not churn data_version: {:?}",
        holds.report()
    );
}

#[test]
fn one_session_lock_work_is_independent_of_cached_table_size() {
    use codex_sessions_collector::store::writer;
    use std::sync::atomic::Ordering;
    let mut measured = Vec::new();
    for rows in [1_000, 50_000] {
        let conn = padded_status_store(rows);
        let steps = locked_steps(&conn);
        writer::apply_session_batch(&conn, vec![support::sample_snapshot("changed")]).unwrap();
        measured.push(steps.load(Ordering::Relaxed));
        conn.progress_handler(0, None::<fn() -> bool>).unwrap();
    }
    eprintln!("session in-lock VM steps: {measured:?}");
    assert!(
        measured[1] * 2 < measured[0] * 3,
        "in-lock VM steps: {measured:?}"
    );
}

#[test]
fn chunking_preserves_complete_table_contents_at_session_boundaries() {
    use codex_sessions_collector::{
        codex::{
            self,
            parser::{ParserOptions, SourceType},
            scanner::{ScanOptions, session_scan_roots},
        },
        contract::{Envelope, ProjectHint, ProjectHints, Record, SessionRef, ThreadName},
        path_mapping::PathMapper,
        store::{
            OwnerMode, Store,
            write_budget::{WriteBudget, WriteBudgetScope},
        },
    };
    let temp = support::TempDir::new("chunk_equivalence");
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
    std::fs::write(
        support::day_folder(&home).join("unsupported.jsonl.zst"),
        b"compressed",
    )
    .unwrap();
    let mut outputs = Vec::new();
    for soft in [Duration::ZERO, WriteBudget::default().soft] {
        let db = temp.path().join(format!("{}.sqlite", soft.as_millis()));
        let store = Store::open(&db, OwnerMode::Standalone).unwrap();
        let _budget = WriteBudgetScope::enter(WriteBudget {
            soft,
            gap: Duration::ZERO,
            ..WriteBudget::default()
        });
        let snapshots: Vec<_> = (0..4)
            .map(|n| support::sample_snapshot(&format!("chunk-{n}")))
            .collect();
        let sessions = WriteHoldScope::for_phase("sessions");
        store
            .apply(
                snapshots
                    .iter()
                    .cloned()
                    .map(|snapshot| Envelope::new(Record::SessionSnapshot(Box::new(snapshot))))
                    .collect(),
            )
            .unwrap();
        assert_eq!(
            sessions.report().transactions,
            4,
            "session units stay isolated so a large unit never inherits earlier work"
        );
        let mut records: Vec<_> = snapshots
            .iter()
            .map(|snapshot| {
                Envelope::new(Record::ThreadName(ThreadName {
                    harness: "codex".into(),
                    session_id: snapshot.session.session_id.clone().unwrap(),
                    thread_name: "display name".into(),
                }))
            })
            .collect();
        records.extend((0..3).map(|n| {
            Envelope::new(Record::SourceStatus(unsupported_status(&format!(
                "unsupported-{n}.jsonl.zst"
            ))))
        }));
        records.push(Envelope::new(Record::ProjectHints(ProjectHints {
            harness: "codex".into(),
            sessions: snapshots
                .iter()
                .map(|snapshot| SessionRef {
                    session_id: snapshot.session.session_id.clone(),
                    source_path: snapshot.source.path.clone(),
                })
                .collect(),
            hints: vec![ProjectHint {
                working_directory: "C:\\nonexistent\\synthetic".into(),
                project_name: "Refined".into(),
            }],
        })));
        let statuses = WriteHoldScope::for_phase("statuses");
        store.apply(records).unwrap();
        assert_eq!(
            statuses.report().transactions,
            if soft.is_zero() { 3 } else { 1 }
        );
        // Exercise the real scanner as well as contract writers on identical
        // roots; generated IDs and timestamps are normalized by the shared
        // natural-content snapshot, including FTS and usage projections.
        codex::collect(
            &store,
            &ScanOptions {
                roots: session_scan_roots(home.to_str().unwrap(), SourceType::Windows),
                mapper: PathMapper::new(String::new()),
                parser: ParserOptions::default(),
                parser_workers: 1,
                wsl_root_retry_delays: vec![],
                thread_names: Default::default(),
                force: false,
            },
            false,
        )
        .unwrap();
        drop(store);
        outputs.push(support::content_snapshot(&db));
    }
    assert_eq!(outputs[0], outputs[1]);
}

#[test]
fn chunk_gap_admits_a_waiting_viewer_between_consecutive_transactions() {
    use codex_sessions_collector::store::{
        OwnerMode, Store,
        write_budget::{WriteBudget, write_chunked},
    };
    use std::sync::mpsc;
    let temp = support::TempDir::new("chunk_gap");
    let path = temp.path().join("fixture.sqlite");
    let store = Store::open(&path, OwnerMode::Standalone).unwrap();
    let (ready_tx, ready_rx) = mpsc::channel();
    let (start_tx, start_rx) = mpsc::channel();
    let probe = std::thread::spawn(move || {
        let conn = Connection::open(path).unwrap();
        conn.busy_timeout(Duration::from_secs(5)).unwrap();
        ready_tx.send(()).unwrap();
        start_rx.recv().unwrap();
        let mut max = Duration::ZERO;
        let mut success = 0;
        for _ in 0..8 {
            let start = std::time::Instant::now();
            conn.execute_batch("begin immediate; rollback").unwrap();
            max = max.max(start.elapsed());
            success += 1;
            std::thread::sleep(Duration::from_millis(50));
        }
        (success, max)
    });
    ready_rx.recv().unwrap();
    let last = std::cell::Cell::new(None);
    let mut gaps = Vec::new();
    let _lease =
        codex_sessions_collector::store::write_lease::WriteLease::acquire(&store.conn).unwrap();
    write_chunked(
        &store.conn,
        "gap_proof",
        WriteBudget {
            soft: Duration::ZERO,
            ..WriteBudget::default()
        },
        usize::MAX,
        0..4,
        || {
            if let Some(last) = last.get() {
                gaps.push(std::time::Instant::now().duration_since(last));
            }
            Ok(())
        },
        |_, index| {
            store.conn.execute(
                "insert into app_metadata values (?,'v','now')",
                [format!("gap-{index}")],
            )?;
            if index == 0 {
                start_tx.send(()).unwrap();
            }
            std::thread::sleep(Duration::from_millis(65));
            last.set(Some(std::time::Instant::now()));
            Ok(())
        },
    )
    .unwrap();
    let (success, max) = probe.join().unwrap();
    assert_eq!(success, 8);
    assert_eq!(gaps.len(), 3, "all four chunks must run independently");
    assert!(max < Duration::from_millis(1250), "viewer wait {max:?}");
    assert!(
        gaps.iter().all(|gap| *gap >= Duration::from_millis(150)),
        "gaps: {gaps:?}"
    );
}

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
    let _lease =
        codex_sessions_collector::store::write_lease::WriteLease::acquire(&store.conn).unwrap();
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
    let _lease =
        codex_sessions_collector::store::write_lease::WriteLease::acquire(&store.conn).unwrap();
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
    let _lease = codex_sessions_collector::store::write_lease::WriteLease::acquire(&conn).unwrap();
    schema::begin_write(&conn).unwrap();
    std::thread::sleep(Duration::from_millis(20));
    assert!(schema::finish::<()>(&conn, Err(StoreError::Refused("test".into()))).is_err());
    drop(phase);
    let stats = scope.report();
    assert_eq!(stats.transactions, 2); // savepoints do not release the write lock
    assert!(stats.max_ms >= 20.0);
    assert_eq!(stats.max_phase.as_deref(), Some("failed"));
    let next = WriteHoldScope::start();
    let _lease = codex_sessions_collector::store::write_lease::WriteLease::acquire(&conn).unwrap();
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
    let _lease = codex_sessions_collector::store::write_lease::WriteLease::acquire(&conn).unwrap();
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
    let _lease = codex_sessions_collector::store::write_lease::WriteLease::acquire(&conn).unwrap();
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
    let _lease =
        codex_sessions_collector::store::write_lease::WriteLease::acquire(&blocked).unwrap();
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
