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
        mapper: PathMapper {
            wsl_unc_root: String::new(),
        },
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
fn gui_grants_each_write_and_can_cancel_before_discovery() {
    use std::io::{BufRead, BufReader, Write};
    use std::process::Stdio;
    let temp = TempDir::new("writer_leases");
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
    let db = viewer_database(&temp);
    let mut child = collector()
        .args([
            "codex",
            "scan",
            "--coordinate-writes",
            "--no-wsl-projects",
            "--db",
        ])
        .arg(&db)
        .arg("--windows-root")
        .arg(home)
        .args(["--wsl-root", ""])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let output = BufReader::new(child.stdout.take().unwrap());
    let mut leased = false;
    let mut grants = 0;
    let mut terminal = None;
    for line in output.lines() {
        let event: serde_json::Value = serde_json::from_str(&line.unwrap()).unwrap();
        match event["event"].as_str().unwrap() {
            "write_requested" => {
                assert!(!leased);
                leased = true;
                if grants == 0 {
                    writeln!(input, "cancel").unwrap();
                }
                writeln!(input, "grant").unwrap();
                input.flush().unwrap();
                grants += 1;
            }
            "write_released" => {
                assert!(leased);
                leased = false;
            }
            "finished" => terminal = Some(event),
            "progress" => {}
            other => panic!("Unexpected event {other}"),
        }
    }
    assert!(child.wait().unwrap().success());
    assert!(!leased);
    assert!(grants >= 1);
    let terminal = terminal.unwrap();
    assert_eq!(terminal["cancelled"], true);
    assert_eq!(terminal["sessions_written"], 0);
    let conn = rusqlite::Connection::open(&db).unwrap();
    let count: i64 = conn
        .query_row("select count(*) from sessions", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 0);
}
