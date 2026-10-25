mod support;
use codex_sessions_collector::store::{
    OwnerMode, Store,
    write_budget::{WriteBudget, WriteBudgetScope, WriteChunkScope},
    writer,
};
use std::{cell::Cell, rc::Rc, time::Duration};
#[test]
fn l1_between_chunks_refuses_same_and_other_connection_writers() {
    let temp = support::TempDir::new("lease_yield");
    let path = temp.path().join("db.sqlite");
    let store = Rc::new(Store::open(&path, OwnerMode::Standalone).unwrap());
    let other = Store::open(&path, OwnerMode::Standalone).unwrap();
    let same = store.clone();
    let calls = Rc::new(Cell::new(0));
    let did = calls.clone();
    let _budget = WriteBudgetScope::enter(WriteBudget {
        soft: Duration::ZERO,
        gap: Duration::ZERO,
        ..WriteBudget::default()
    });
    let observer = WriteChunkScope::observe(move |phase| {
        if phase == "sessions" {
            for conn in [&same.conn, &other.conn] {
                let result =
                    writer::apply_session_batch(conn, vec![support::sample_snapshot("forbidden")]);
                assert!(result.is_err(), "writer entered between chunks");
                assert_eq!(
                    conn.query_row(
                        "select count(*) from sessions where session_id='forbidden'",
                        [],
                        |r| r.get::<_, i64>(0)
                    )
                    .unwrap(),
                    0
                );
            }
            did.set(did.get() + 1);
        }
    });
    writer::apply_session_batch(
        &store.conn,
        vec![support::sample_snapshot("a"), support::sample_snapshot("b")],
    )
    .unwrap();
    assert_eq!(calls.get(), 2);
    drop(observer);
    let oracle_path = temp.path().join("oracle.sqlite");
    let oracle = Store::open(&oracle_path, OwnerMode::Standalone).unwrap();
    writer::apply_session_batch(
        &oracle.conn,
        vec![support::sample_snapshot("a"), support::sample_snapshot("b")],
    )
    .unwrap();
    assert_eq!(
        support::content_snapshot(Path::new(&store.path)),
        support::content_snapshot(&oracle_path)
    );
    assert_eq!(
        support::rows(
            &store.conn,
            "select session_id,revision,deleted from session_changes order by session_id"
        ),
        support::rows(
            &oracle.conn,
            "select session_id,revision,deleted from session_changes order by session_id"
        )
    );
}

use codex_sessions_collector::{
    contract::{Record, ThreadName},
    hooks,
    store::{
        schema,
        write_budget::WriteHoldScope,
        write_lease::{LeaseWait, WriteLease, is_busy},
    },
};
use std::{
    path::Path,
    process::Stdio,
    sync::{Arc, atomic::AtomicBool, mpsc},
    time::Instant,
};
fn zero_gap() -> WriteBudgetScope {
    WriteBudgetScope::enter(WriteBudget {
        soft: Duration::ZERO,
        gap: Duration::ZERO,
        ..WriteBudget::default()
    })
}

#[test]
fn viewer_grant_request_refuses_an_enclosing_collector_lease() {
    let _budget = zero_gap();
    let temp = support::TempDir::new("nested_grant_order");
    let store = Store::open(&temp.path().join("db.sqlite"), OwnerMode::Standalone).unwrap();
    let _lease = WriteLease::acquire(&store.conn).unwrap();
    let mut requested = false;
    let result = codex_sessions_collector::codex::gated(
        &mut |_| {
            requested = true;
            Ok(true)
        },
        || Ok(()),
    );
    assert!(
        result.is_err(),
        "grant requested under an enclosing collector lease"
    );
    assert!(!requested);
}

#[test]
fn repair_releases_collector_lease_before_waiting_for_viewer_grant() {
    use codex_sessions_collector::{
        codex::{parser::SourceType, scanner::session_scan_roots},
        store::cache_repair,
    };
    let _budget = zero_gap();
    let temp = support::TempDir::new("repair_grant_order");
    let home = temp.path().join(".codex");
    for dir in ["sessions", "archived_sessions", "plugins"] {
        std::fs::create_dir_all(home.join(dir)).unwrap();
    }
    let file = home.join("plugins/file.jsonl");
    std::fs::write(&file, "{}").unwrap();
    let path = temp.path().join("db.sqlite");
    let repair = Store::open(&path, OwnerMode::Standalone).unwrap();
    let reload = Store::open(&path, OwnerMode::Standalone).unwrap();
    repair.conn.execute("insert into sessions(id,source_type,source_file_path,display_path,platform_path,source_state,parser_version,created_at_utc,updated_at_utc) values('source:legacy','windows',?1,?1,?1,'active',1,'fixed','fixed')", [file.to_str().unwrap()]).unwrap();
    let (audit_held, audit_started) = mpsc::channel();
    let (checked, check_done) = mpsc::channel();
    let (released, release_seen) = mpsc::channel();
    let (viewer_slot, slot_seen) = mpsc::channel();
    let (done, completed) = mpsc::channel();
    let peer = std::thread::spawn(move || {
        let _budget = zero_gap();
        audit_started.recv_timeout(Duration::from_secs(5)).unwrap();
        let wait = LeaseWait::enter(Duration::ZERO);
        let excluded = writer::apply_thread_names(&reload.conn, &[]).is_err_and(|e| is_busy(&e));
        drop(wait);
        checked.send(excluded).unwrap();
        release_seen.recv_timeout(Duration::from_secs(5)).unwrap();
        // Viewer runWriter owns its slot until the child ingest writer returns.
        viewer_slot.send(()).unwrap();
        let _wait = LeaseWait::enter(Duration::from_millis(300));
        let result = writer::apply_thread_names(&reload.conn, &[]);
        done.send(()).unwrap();
        result
    });
    let mut first = true;
    let observer = WriteChunkScope::observe(move |phase| {
        if phase == "cache_repair_audit" && first {
            first = false;
            audit_held.send(()).unwrap();
            assert!(
                check_done.recv_timeout(Duration::from_secs(5)).unwrap(),
                "repair audit must exclude another collector (lease-less sensitivity)"
            );
        }
    });
    let mut grants = 0;
    let report = cache_repair::run(
        &repair,
        &session_scan_roots(home.to_str().unwrap(), SourceType::Windows),
        true,
        &Arc::new(AtomicBool::new(false)),
        &mut |acquire| {
            if acquire {
                grants += 1;
                if grants == 2 {
                    completed.recv_timeout(Duration::from_secs(5)).unwrap();
                }
            } else if grants == 1 {
                released.send(()).unwrap();
                slot_seen.recv_timeout(Duration::from_secs(5)).unwrap();
            }
            Ok(true)
        },
    )
    .unwrap();
    drop(observer);
    let reload_result = peer.join().unwrap();
    assert!(
        reload_result.is_ok(),
        "Reload failed while repair waited for viewer grant: {reload_result:?}"
    );
    assert_eq!(grants, 2);
    assert_eq!(report.status, "completed", "{report:?}");
}

#[test]
fn repair_preserves_rows_if_backup_disappears_during_grant_wait() {
    use codex_sessions_collector::{
        codex::{parser::SourceType, scanner::session_scan_roots},
        store::cache_repair,
    };
    let _budget = zero_gap();
    let temp = support::TempDir::new("repair_backup_grant_gap");
    let home = temp.path().join(".codex");
    for dir in ["sessions", "archived_sessions", "plugins"] {
        std::fs::create_dir_all(home.join(dir)).unwrap();
    }
    let file = home.join("plugins/file.jsonl");
    std::fs::write(&file, "{}").unwrap();
    let path = temp.path().join("db.sqlite");
    let store = Store::open(&path, OwnerMode::Standalone).unwrap();
    store.conn.execute("insert into sessions(id,source_type,source_file_path,display_path,platform_path,source_state,parser_version,created_at_utc,updated_at_utc) values('source:legacy','windows',?1,?1,?1,'active',1,'fixed','fixed')", [file.to_str().unwrap()]).unwrap();
    let mut grants = 0;
    let mut removed = 0;
    let report = cache_repair::run(
        &store,
        &session_scan_roots(home.to_str().unwrap(), SourceType::Windows),
        true,
        &Arc::new(AtomicBool::new(false)),
        &mut |acquire| {
            if acquire {
                grants += 1;
                if grants == 2 {
                    // A competing repair may discard an orphan copy while this
                    // call has released its collector lease to wait for the slot.
                    for entry in std::fs::read_dir(cache_repair::backup_directory(&path)).unwrap() {
                        let entry = entry.unwrap();
                        if entry.file_name().to_string_lossy().ends_with(".sqlite") {
                            std::fs::remove_file(entry.path()).unwrap();
                            removed += 1;
                        }
                    }
                }
            }
            Ok(true)
        },
    )
    .unwrap();
    assert_eq!(removed, 1);
    assert_eq!(report.reason_code, "repair_invariant_failed", "{report:?}");
    assert_eq!(report.deleted_rows, 0);
    assert_eq!(
        store
            .conn
            .query_row(
                "select count(*) from sessions where id='source:legacy'",
                [],
                |row| row.get::<_, i64>(0)
            )
            .unwrap(),
        1
    );
}
#[derive(Clone, Copy, Debug)]
enum RepairInterruption {
    CollectorLease,
    GrantRelease,
    ViewerMigration,
}

fn committed_repair_survives(interruption: RepairInterruption) {
    use codex_sessions_collector::{
        codex::{parser::SourceType, scanner::session_scan_roots},
        store::cache_repair,
    };
    let _budget = zero_gap();
    let _wait = LeaseWait::enter(Duration::from_millis(300));
    // Both the destructive delete and a no-changes audit commit completion.
    for deletes in [true, false] {
        let temp = support::TempDir::new("repair_postcommit");
        let home = temp.path().join(".codex");
        for dir in ["sessions", "archived_sessions", "plugins"] {
            std::fs::create_dir_all(home.join(dir)).unwrap();
        }
        let file = home.join("plugins/file.jsonl");
        std::fs::write(&file, "{}").unwrap();
        let path = temp.path().join("db.sqlite");
        let store = Store::open(&path, OwnerMode::Standalone).unwrap();
        let peer = Store::open(&path, OwnerMode::Standalone).unwrap();
        if deletes {
            store.conn.execute("insert into sessions(id,source_type,source_file_path,display_path,platform_path,source_state,parser_version,created_at_utc,updated_at_utc) values('source:legacy','windows',?1,?1,?1,'active',1,'fixed','fixed')", [file.to_str().unwrap()]).unwrap();
        }
        let backups = || -> Vec<std::path::PathBuf> {
            std::fs::read_dir(cache_repair::backup_directory(&path))
                .into_iter()
                .flatten()
                .map(Result::unwrap)
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "sqlite"))
                .collect()
        };
        let mut grants = 0;
        let mut blocker = None;
        let mut backup_before = 0;
        let result = cache_repair::run(
            &store,
            &session_scan_roots(home.to_str().unwrap(), SourceType::Windows),
            true,
            &Arc::new(AtomicBool::new(false)),
            &mut |acquire| {
                if acquire {
                    grants += 1;
                } else if grants == if deletes { 2 } else { 1 } {
                    // This is after the final COMMIT, before returning its result.
                    backup_before = backups().len();
                    match interruption {
                        RepairInterruption::CollectorLease => {
                            blocker = Some(WriteLease::acquire(&peer.conn)?);
                        }
                        RepairInterruption::GrantRelease => {
                            return Err(schema::StoreError::Refused("release failed".into()));
                        }
                        RepairInterruption::ViewerMigration => {
                            peer.conn.execute("insert into app_metadata values('usage_migration_bootstrap','viewer','fixed')", [])?;
                        }
                    }
                }
                Ok(true)
            },
        );
        drop(blocker);
        let remaining: i64 = store
            .conn
            .query_row(
                "select count(*) from sessions where id='source:legacy'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let completed: i64 = store
            .conn
            .query_row(
                "select count(*) from app_metadata where key=?",
                [cache_repair::COMPLETION_KEY],
                |r| r.get(0),
            )
            .unwrap();
        println!(
            "{interruption:?} deletes={deletes}: result={result:?}; rows={remaining}; completed={completed}; backups_before={backup_before}; backups_after={}",
            backups().len()
        );
        assert_eq!(remaining, 0);
        assert_eq!(completed, 1);
        assert_eq!(backup_before, usize::from(deletes));
        assert_eq!(
            backups().len(),
            backup_before,
            "committed repair must retain its recovery copy"
        );
        let report =
            result.expect("post-COMMIT interruption must not replace the committed outcome");
        assert_eq!(report.status, "completed");
        assert_eq!(report.deleted_rows, usize::from(deletes));
        assert_eq!(report.backup_file.is_some(), deletes);
        if deletes {
            let recovery = rusqlite::Connection::open_with_flags(
                &backups()[0],
                rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
            )
            .unwrap();
            assert_eq!(
                recovery
                    .query_row("pragma integrity_check", [], |r| r.get::<_, String>(0))
                    .unwrap(),
                "ok"
            );
            assert_eq!(
                recovery
                    .query_row(
                        "select count(*) from sessions where id='source:legacy'",
                        [],
                        |r| r.get::<_, i64>(0)
                    )
                    .unwrap(),
                1
            );
        }
        if matches!(interruption, RepairInterruption::ViewerMigration) {
            let _lease = WriteLease::acquire(&store.conn).unwrap();
            let error = schema::begin_write(&store.conn).unwrap_err();
            assert!(error.to_string().contains("migrating"), "{error}");
        }
        peer.conn
            .execute(
                "delete from app_metadata where key='usage_migration_bootstrap'",
                [],
            )
            .unwrap();
        let again = cache_repair::run(
            &store,
            &session_scan_roots(home.to_str().unwrap(), SourceType::Windows),
            true,
            &Arc::new(AtomicBool::new(false)),
            &mut |_| panic!("completed repair must not request another grant"),
        )
        .unwrap();
        assert_eq!(again.status, "already_completed");
        assert_eq!(backups().len(), backup_before);
    }
}

#[test]
fn repair_committed_outcome_survives_postcommit_collector_contention() {
    committed_repair_survives(RepairInterruption::CollectorLease);
}

#[test]
fn repair_committed_outcome_survives_postcommit_grant_release_error() {
    committed_repair_survives(RepairInterruption::GrantRelease);
}

#[test]
fn repair_committed_outcome_survives_postcommit_viewer_migration() {
    committed_repair_survives(RepairInterruption::ViewerMigration);
}

fn revision(conn: &rusqlite::Connection) -> i64 {
    conn.query_row(
        "select revision from session_change_state where id=1",
        [],
        |r| r.get(0),
    )
    .unwrap()
}
#[test]
fn l2_other_thread_waits_for_the_whole_call_and_journal_order() {
    let _budget = zero_gap();
    let temp = support::TempDir::new("lease_threads");
    let path = temp.path().join("db.sqlite");
    let store = Store::open(&path, OwnerMode::Standalone).unwrap();
    let other = Store::open(&path, OwnerMode::Standalone).unwrap();
    let (parked, ready) = mpsc::channel();
    let (resume, go) = mpsc::channel();
    let (waiting, started) = mpsc::channel();
    let a = std::thread::spawn(move || {
        let _budget = zero_gap();
        let mut first = true;
        let _yielding = WriteChunkScope::observe(move |_| {
            if first {
                first = false;
                parked.send(()).unwrap();
                go.recv_timeout(Duration::from_secs(5)).unwrap();
            }
        });
        writer::apply_session_batch(
            &store.conn,
            vec![support::sample_snapshot("a"), support::sample_snapshot("b")],
        )
        .unwrap();
        revision(&store.conn)
    });
    ready.recv_timeout(Duration::from_secs(5)).unwrap();
    let b = std::thread::spawn(move || {
        let _budget = zero_gap();
        let _wait = LeaseWait::enter(Duration::ZERO);
        let error = writer::apply_thread_names(&other.conn, &[]).unwrap_err();
        assert!(is_busy(&error));
        waiting.send(()).unwrap();
        let _wait = LeaseWait::enter(Duration::from_secs(5));
        writer::apply_session_batch(&other.conn, vec![support::sample_snapshot("c")]).unwrap();
        revision(&other.conn)
    });
    started.recv_timeout(Duration::from_secs(5)).unwrap();
    resume.send(()).unwrap();
    assert!(a.join().unwrap() < b.join().unwrap());
}
#[test]
fn lease_child_helper() {
    if let Some(path) = std::env::var_os("CSV_TEST_LEASE_CHILD") {
        let _budget = zero_gap();
        let store = Store::open(Path::new(&path), OwnerMode::Standalone).unwrap();
        let _lease = WriteLease::acquire(&store.conn).unwrap();
        std::fs::write(Path::new(&path).with_extension("ready"), b"ready").unwrap();
        std::thread::sleep(Duration::from_secs(15));
    }
}
#[test]
fn l3_process_death_releases_the_lease_without_unlinking() {
    let _budget = zero_gap();
    let temp = support::TempDir::new("lease_process");
    let path = temp.path().join("db.sqlite");
    let store = Store::open(&path, OwnerMode::Standalone).unwrap();
    let mut command = support::test_command(std::env::current_exe().unwrap());
    command
        .args(["--exact", "lease_child_helper", "--nocapture"])
        .env("CSV_TEST_LEASE_CHILD", &path)
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        command.creation_flags(0x08000000);
    }
    let mut child = command.spawn().unwrap();
    let deadline = Instant::now() + Duration::from_secs(8);
    while !path.with_extension("ready").exists() {
        if Instant::now() > deadline {
            let _ = child.kill();
            panic!("child did not acquire");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let _wait = LeaseWait::enter(Duration::ZERO);
    assert!(is_busy(&WriteLease::acquire(&store.conn).err().unwrap()));
    child.kill().unwrap();
    child.wait().unwrap();
    let start = Instant::now();
    let _wait = LeaseWait::enter(Duration::from_secs(1));
    let _lease = WriteLease::acquire(&store.conn).unwrap();
    assert!(start.elapsed() < Duration::from_secs(1));
    assert!(
        codex_sessions_collector::store::write_lease::lock_path(&path)
            .unwrap()
            .exists()
    );
}
#[test]
fn l4_begin_write_requires_lease_and_memory_reentrancy_is_per_connection() {
    let _budget = zero_gap();
    let temp = support::TempDir::new("lease_backstop");
    let store = Store::open(&temp.path().join("db.sqlite"), OwnerMode::Standalone).unwrap();
    let holds = WriteHoldScope::start();
    assert!(matches!(
        schema::begin_write(&store.conn),
        Err(codex_sessions_collector::store::StoreError::Refused(_))
    ));
    assert_eq!(holds.report().transactions, 0);
    let lease = WriteLease::acquire(&store.conn).unwrap();
    let nested = WriteLease::acquire(&store.conn).unwrap();
    drop(lease);
    schema::begin_write(&store.conn).unwrap();
    schema::finish(&store.conn, Ok(())).unwrap();
    drop(nested);
    let memory = rusqlite::Connection::open_in_memory().unwrap();
    let temporary = rusqlite::Connection::open("").unwrap();
    let _a = WriteLease::acquire(&memory).unwrap();
    let _b = WriteLease::acquire(&temporary).unwrap();
}
#[test]
fn l5_drain_lease_timeout_releases_claim_without_attempting() {
    let _budget = zero_gap();
    let temp = support::TempDir::new("lease_drain");
    let path = temp.path().join("db.sqlite");
    let store = Store::open(&path, OwnerMode::Standalone).unwrap();
    let other = Store::open(&path, OwnerMode::Standalone).unwrap();
    let queue = temp.path().join("queue");
    std::fs::create_dir(&queue).unwrap();
    let item = hooks::WorkItem {
        database_key: None,
        harness: "codex".into(),
        event: "turn".into(),
        session_id: Some("a".into()),
        turn_id: None,
        transcript_path: None,
        cwd: None,
        received_utc: "fixed".into(),
        attempts: 2,
        not_before_utc: None,
        last_error: Some("old".into()),
    };
    let bytes = serde_json::to_vec(&item).unwrap();
    std::fs::write(queue.join("entry.json"), &bytes).unwrap();
    let claim = hooks::claim_due(&queue).pop().unwrap();
    let _lease = WriteLease::acquire(&other.conn).unwrap();
    let start = Instant::now();
    assert!(
        hooks::lease_claim(&store.conn, &claim, Duration::from_millis(50))
            .unwrap()
            .is_none()
    );
    assert!(start.elapsed() < Duration::from_secs(1));
    assert!(!claim.path.exists());
    assert_eq!(std::fs::read(queue.join("entry.json")).unwrap(), bytes);
    assert_eq!(hooks::claim_due(&queue)[0].item, item);
}
#[test]
fn l6_public_writers_busy_without_changes() {
    use codex_sessions_collector::{
        claude,
        codex::{self, parser::SourceType, scanner::session_scan_roots},
        hub_client,
        path_mapping::PathMapper,
        store::cache_repair,
        t3,
    };
    let _budget = zero_gap();
    let temp = support::TempDir::new("lease_inventory");
    let path = temp.path().join("db.sqlite");
    let store = Store::open(&path, OwnerMode::Standalone).unwrap();
    let holder = Store::open(&path, OwnerMode::Standalone).unwrap();
    let _lease = WriteLease::acquire(&holder.conn).unwrap();
    let _wait = LeaseWait::enter(Duration::ZERO);
    let before = all_rows(&store.conn);
    macro_rules! busy {
        ($value:expr) => {
            assert!(is_busy(&$value.unwrap_err()));
        };
    }
    busy!(writer::apply_session_batch(&store.conn, vec![]));
    busy!(writer::apply_source_statuses(&store.conn, &[]));
    busy!(writer::apply_thread_names(&store.conn, &[]));
    busy!(writer::apply_project_hints(&store.conn, "codex", &[], &[]));
    busy!(writer::apply_project_backfill(&store.conn, &[]));
    busy!(writer::clean_session_metadata_placeholders(&store.conn));
    busy!(writer::record_complete_codex_scan(&store.conn));
    busy!(store.apply(vec![]));
    busy!(schema::in_write_transaction(&store.conn, || Ok(())));
    busy!(
        codex_sessions_collector::store::write_budget::execute_write(
            &store.conn,
            "lease_inventory",
            "insert into app_metadata values('forbidden','x','fixed')",
            []
        )
    );

    busy!(hub_client::enqueue(
        &store.conn,
        Record::ThreadName(ThreadName {
            harness: "codex".into(),
            session_id: "a".into(),
            thread_name: "n".into()
        }),
        "fixed"
    ));
    busy!(cache_repair::run(
        &store,
        &[],
        true,
        &Arc::new(AtomicBool::new(false)),
        &mut |_| Ok(true)
    ));
    assert!(
        t3::import(&store.conn, &temp.path().join("missing"), "windows")
            .unwrap_err()
            .contains("another collector")
    );
    assert!(
        hub_client::enable_for_collection(&path, OwnerMode::Standalone, "http://127.0.0.1:1")
            .unwrap_err()
            .contains("another collector")
    );
    assert!(
        hub_client::disable(&path, OwnerMode::Standalone)
            .unwrap_err()
            .contains("another collector")
    );
    assert!(
        hub_client::resync(&path, OwnerMode::Standalone, "http://127.0.0.1:1", "token")
            .unwrap_err()
            .contains("another collector")
    );
    assert!(
        hub_client::sync(&path, OwnerMode::Standalone, "http://127.0.0.1:1", "token")
            .unwrap_err()
            .contains("another collector")
    );
    busy!(codex::collect_file(
        &store,
        &scan_options(vec![]),
        &session_scan_roots("missing", SourceType::Windows)[0],
        false
    ));
    busy!(claude::collect_file(
        &store,
        Path::new("missing"),
        SourceType::Windows,
        &PathMapper::new(String::new()),
        &Default::default()
    ));
    assert_eq!(all_rows(&store.conn), before);
}

fn scan_options(
    roots: Vec<codex_sessions_collector::codex::scanner::ScanRoot>,
) -> codex_sessions_collector::codex::scanner::ScanOptions {
    codex_sessions_collector::codex::scanner::ScanOptions {
        roots,
        mapper: codex_sessions_collector::path_mapping::PathMapper::new(String::new()),
        parser: Default::default(),
        parser_workers: 1,
        wsl_root_retry_delays: vec![],
        thread_names: Default::default(),
        force: true,
    }
}
#[test]
fn l6_waiter_gets_a_turn_between_repeated_long_calls() {
    let temp = support::TempDir::new("lease_fairness");
    let path = temp.path().join("db.sqlite");
    let a = Store::open(&path, OwnerMode::Standalone).unwrap();
    let b = Store::open(&path, OwnerMode::Standalone).unwrap();
    let (park, parked) = mpsc::channel();
    let (start, started) = mpsc::channel();
    let a = std::thread::spawn(move || {
        let _budget = WriteBudgetScope::enter(WriteBudget {
            soft: Duration::ZERO,
            ..WriteBudget::default()
        });
        let mut first = true;
        let _observer = WriteChunkScope::observe(move |_| {
            if first {
                first = false;
                park.send(()).unwrap();
                started.recv_timeout(Duration::from_secs(5)).unwrap();
            }
            std::thread::sleep(Duration::from_millis(50));
        });
        writer::apply_session_batch(
            &a.conn,
            vec![support::sample_snapshot("a"), support::sample_snapshot("b")],
        )
        .unwrap();
        let revision = revision(&a.conn);
        writer::apply_session_batch(&a.conn, vec![support::sample_snapshot("a2")]).unwrap();
        (revision, revision_fn(&a.conn))
    });
    parked.recv_timeout(Duration::from_secs(5)).unwrap();
    start.send(()).unwrap();
    let begin = Instant::now();
    let _wait = LeaseWait::enter(Duration::from_secs(5));
    writer::apply_session_batch(&b.conn, vec![support::sample_snapshot("waiter")]).unwrap();
    let middle = revision(&b.conn);
    let (first, last) = a.join().unwrap();
    assert!(
        first < middle && middle < last,
        "first={first},waiter={middle},last={last}"
    );
    assert!(begin.elapsed() < Duration::from_secs(3));
}
fn revision_fn(conn: &rusqlite::Connection) -> i64 {
    revision(conn)
}
#[test]
fn l_scan_drain_can_commit_between_two_flush_batches() {
    use codex_sessions_collector::codex::{
        self, CollectionBatching, parser::SourceType, scanner::session_scan_roots,
    };
    let _budget = zero_gap();
    let temp = support::TempDir::new("lease_scan_flush");
    let home = support::codex_home(&temp, &["rich_session.jsonl", "event_stream_session.jsonl"]);
    let path = temp.path().join("db.sqlite");
    let scan = Store::open(&path, OwnerMode::Standalone).unwrap();
    let drain = Store::open(&path, OwnerMode::Standalone).unwrap();
    let queue = temp.path().join("queue");
    std::fs::create_dir(&queue).unwrap();
    std::fs::write(
        queue.join("item.json"),
        r#"{"harness":"codex","event":"turn","session_id":"drain","received_utc":"fixed"}"#,
    )
    .unwrap();
    let claim = hooks::claim_due(&queue).pop().unwrap();
    let mut committed = false;
    let mut scanned_before = 0;
    let mut scanned_after = 0;
    let options = scan_options(session_scan_roots(
        home.to_str().unwrap(),
        SourceType::Windows,
    ));
    let report = codex::collect_coordinated(
        &scan,
        &options,
        false,
        &Arc::new(AtomicBool::new(false)),
        |_, _| {},
        |acquire| {
            if !acquire && !committed {
                let count: i64 = drain.conn.query_row(
                    "select count(*) from sessions where id<>'session:drain'",
                    [],
                    |r| r.get(0),
                )?;
                if count > 0 {
                    let _lease = hooks::lease_claim(&drain.conn, &claim, Duration::ZERO)?
                        .expect("scan must release its flush lease");
                    writer::apply_session_batch(
                        &drain.conn,
                        vec![support::sample_snapshot("drain")],
                    )?;
                    hooks::complete(&claim);
                    scanned_before = count;
                    committed = true;
                }
            } else if !acquire && committed {
                scanned_after = drain.conn.query_row(
                    "select count(*) from sessions where id<>'session:drain'",
                    [],
                    |r| r.get(0),
                )?;
            }
            Ok(true)
        },
        CollectionBatching {
            sessions: 1,
            source_bytes: u64::MAX,
        },
    )
    .unwrap();
    assert!(committed);
    assert!(report.counts.persistence_flushes >= 2, "{report:?}");
    assert!(scanned_after > scanned_before);
    assert!(!claim.path.exists());
    assert!(hooks::claim_due(&queue).is_empty());
}

fn all_rows(conn: &rusqlite::Connection) -> serde_json::Value {
    let tables: Vec<String> = conn
        .prepare("select name from sqlite_schema where type='table' order by name")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let mut result = serde_json::Map::new();
    for table in tables {
        let mut rows = support::rows(conn, &format!("select * from \"{table}\""));
        rows.sort_by_key(serde_json::Value::to_string);
        result.insert(table, serde_json::json!(rows));
    }
    serde_json::Value::Object(result)
}
