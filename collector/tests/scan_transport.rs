mod support;
use codex_sessions_collector::{
    codex::{
        self,
        parser::{ParserOptions, SourceType},
        scanner::{ScanOptions, session_scan_roots},
    },
    path_mapping::PathMapper,
    store::{OwnerMode, Store},
};
use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};
use support::{TempDir, collector, viewer_database};

#[test]
fn cancellation_flushes_completed_sessions_without_marking_missing_sources() {
    let temp = TempDir::new("cancel_transport");
    let home = support::codex_home(
        &temp,
        &[
            "rich_session.jsonl",
            "subagent_session.jsonl",
            "no_session_id.jsonl",
        ],
    );
    let db = viewer_database(&temp);
    let store = Store::open(&db, OwnerMode::Viewer).unwrap();
    let options = ScanOptions {
        roots: session_scan_roots(home.to_str().unwrap(), SourceType::Windows),
        mapper: PathMapper::new(String::new()),
        parser: ParserOptions::default(),
        parser_workers: 1,
        wsl_root_retry_delays: vec![],
        thread_names: HashMap::new(),
        force: true,
    };
    let baseline = codex::collect(&store, &options, false).unwrap();
    assert_eq!(baseline.applied.sessions, 3);
    std::fs::remove_file(support::day_folder(&home).join("no_session_id.jsonl")).unwrap();
    let cancel = Arc::new(AtomicBool::new(false));
    let report = codex::collect_controlled(&store, &options, false, &cancel, |counts, _| {
        if counts.files_parsed >= 1 {
            cancel.store(true, Ordering::Relaxed);
        }
    })
    .unwrap();
    assert!(report.counts.cancelled);
    assert!(report.applied.sessions >= 1);
    assert_eq!(report.applied.sessions as u64, report.counts.files_parsed);
    assert_eq!(report.counts.sessions_missing, 0);
    let missing: i64 = store
        .conn
        .query_row(
            "select count(*) from sessions where scan_status='missing'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(missing, 0);
}

#[test]
fn cli_streams_progress_and_terminal_summary() {
    let temp = TempDir::new("progress_transport");
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
    let db = viewer_database(&temp);
    let result = collector()
        .args([
            "codex",
            "scan",
            "--progress-json",
            "--no-wsl-projects",
            "--db",
        ])
        .arg(db)
        .arg("--windows-root")
        .arg(home)
        .args(["--wsl-root", ""])
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let events: Vec<serde_json::Value> = String::from_utf8(result.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(events.first().unwrap()["event"], "progress");
    assert_eq!(events.last().unwrap()["event"], "finished");
    assert_eq!(events.last().unwrap()["sessions_written"], 1);
    assert_eq!(events.last().unwrap()["cancelled"], false);
}
#[test]
fn progress_events_are_throttled_but_every_commit_is_reported() {
    let temp = TempDir::new("progress_throttle");
    let home = support::codex_home(&temp, &[]);
    for day in 1..=60 {
        let folder = home
            .join("sessions")
            .join("2026")
            .join("08")
            .join(format!("{day:02}"));
        std::fs::create_dir_all(&folder).unwrap();
        for index in 0..4 {
            support::write_generated_session(
                &folder.join(format!("rollout-{day}-{index}.jsonl")),
                &format!("throttle-{day}-{index}"),
                1,
            );
        }
    }
    let db = viewer_database(&temp);
    let started = std::time::Instant::now();
    let result = collector()
        .args([
            "codex",
            "scan",
            "--progress-json",
            "--no-wsl-projects",
            "--flush-sessions",
            "100",
            "--db",
        ])
        .arg(&db)
        .arg("--windows-root")
        .arg(&home)
        .args(["--wsl-root", ""])
        .output()
        .unwrap();
    let elapsed = started.elapsed();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let events: Vec<serde_json::Value> = String::from_utf8(result.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let progress: Vec<&serde_json::Value> = events
        .iter()
        .filter(|event| event["event"] == "progress")
        .collect();
    let terminal = events.last().unwrap();
    assert_eq!(terminal["event"], "finished");
    assert_eq!(terminal["sessions_written"], 240);
    let directories = terminal["directories_scanned"].as_u64().unwrap();
    assert!(directories >= 60);
    // One event per 100 ms, plus the first one and one per commit.
    let allowed = 1 + elapsed.as_millis() as usize / 100 + 3;
    assert!(
        progress.len() <= allowed,
        "{} progress events in {elapsed:?} for {directories} directories and 240 files",
        progress.len()
    );
    let mut committed: Vec<u64> = progress
        .iter()
        .map(|event| event["sessions_written"].as_u64().unwrap())
        .collect();
    committed.dedup();
    assert!(
        committed.contains(&100) && committed.contains(&200),
        "every commit is reported: {committed:?}"
    );
}

#[test]
fn claude_scan_reports_progress_without_viewer_leases() {
    let temp = TempDir::new("claude_progress");
    let root = support::claude_root(&temp);
    let db = viewer_database(&temp);
    let result = collector()
        .args([
            "claude",
            "scan",
            "--progress-json",
            "--no-wsl-projects",
            "--db",
        ])
        .arg(&db)
        .arg("--claude-root")
        .arg(root)
        .output()
        .unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    let events: Vec<serde_json::Value> = String::from_utf8(result.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert!(events.iter().any(|event| event["event"] == "progress"));
    assert!(
        events
            .iter()
            .all(|event| event["event"] == "progress" || event["event"] == "finished")
    );
    assert_eq!(events.last().unwrap()["sessions_written"], 3);
    assert_eq!(events.last().unwrap()["cancelled"], false);
}
