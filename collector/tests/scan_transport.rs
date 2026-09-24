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

fn coordinated(args: &[&str], db: &std::path::Path) -> std::process::Child {
    use std::process::Stdio;
    collector()
        .args(args)
        .args(["--coordinate-writes", "--no-wsl-projects", "--db"])
        .arg(db)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

#[test]
fn cancel_while_waiting_for_a_lease_withdraws_it_and_asks_for_no_more() {
    use std::io::Write;
    let temp = TempDir::new("cancel_waiting_lease");
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
    let db = viewer_database(&temp);
    let mut child = coordinated(
        &[
            "codex",
            "scan",
            "--windows-root",
            home.to_str().unwrap(),
            "--wsl-root",
            "",
        ],
        &db,
    );
    let mut input = child.stdin.take().unwrap();
    let events = support::EventStream::new(child.stdout.take().unwrap());
    let mut requested = 0;
    let mut after_request = Vec::new();
    let mut terminal = None;
    while let Some(event) = events.next(&mut child) {
        let name = event["event"].as_str().unwrap().to_owned();
        if requested > 0 && name != "progress" {
            after_request.push(name.clone());
        }
        match name.as_str() {
            "write_requested" => {
                requested += 1;
                // The GUI never grants: its writer queue is busy, then the
                // user cancels. The collector must not wait forever.
                writeln!(input, "cancel").unwrap();
                input.flush().unwrap();
            }
            "finished" => terminal = Some(event),
            _ => {}
        }
    }
    assert!(child.wait().unwrap().success());
    assert_eq!(requested, 1, "no lease may be requested after a cancel");
    assert_eq!(after_request, ["write_released", "finished"]);
    let terminal = terminal.unwrap();
    assert_eq!(terminal["cancelled"], true);
    assert_eq!(terminal["sessions_written"], 0);
}

#[test]
fn a_cancel_after_parsing_skips_the_remaining_batches() {
    use std::io::Write;
    let temp = TempDir::new("cancel_remaining_batches");
    let home = support::codex_home(
        &temp,
        &[
            "rich_session.jsonl",
            "subagent_session.jsonl",
            "no_session_id.jsonl",
        ],
    );
    let db = viewer_database(&temp);
    let mut child = coordinated(
        &[
            "codex",
            "scan",
            "--flush-sessions",
            "1",
            "--windows-root",
            home.to_str().unwrap(),
            "--wsl-root",
            "",
        ],
        &db,
    );
    let mut input = child.stdin.take().unwrap();
    let events = support::EventStream::new(child.stdout.take().unwrap());
    let mut requested = 0;
    let mut terminal = None;
    while let Some(event) = events.next(&mut child) {
        match event["event"].as_str().unwrap() {
            "write_requested" => {
                requested += 1;
                // Grant the placeholder cleanup and the first session batch,
                // then cancel instead of granting the next request.
                if requested <= 2 {
                    writeln!(input, "grant").unwrap();
                } else {
                    writeln!(input, "cancel").unwrap();
                }
                input.flush().unwrap();
            }
            "finished" => terminal = Some(event),
            _ => {}
        }
    }
    assert!(child.wait().unwrap().success());
    assert_eq!(requested, 3, "statuses, hints and names are skipped");
    let terminal = terminal.unwrap();
    assert_eq!(terminal["cancelled"], true);
    assert_eq!(terminal["sessions_written"], 1);
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
fn claude_scan_uses_the_same_leases_progress_and_cancellation() {
    use std::io::Write;
    let temp = TempDir::new("claude_coordinated");
    let root = support::claude_root(&temp);
    let db = viewer_database(&temp);
    let mut child = coordinated(
        &["claude", "scan", "--claude-root", root.to_str().unwrap()],
        &db,
    );
    let mut input = child.stdin.take().unwrap();
    let events = support::EventStream::new(child.stdout.take().unwrap());
    let (mut leased, mut grants, mut progress) = (false, 0, 0);
    let mut terminal = None;
    while let Some(event) = events.next(&mut child) {
        match event["event"].as_str().unwrap() {
            "write_requested" => {
                assert!(!leased);
                leased = true;
                grants += 1;
                writeln!(input, "grant").unwrap();
                input.flush().unwrap();
            }
            "write_released" => {
                assert!(leased);
                leased = false;
            }
            "progress" => progress += 1,
            "finished" => terminal = Some(event),
            other => panic!("unexpected event {other}"),
        }
    }
    assert!(child.wait().unwrap().success());
    assert!(!leased && grants >= 2 && progress >= 1);
    let terminal = terminal.unwrap();
    assert_eq!(terminal["cancelled"], false);
    assert_eq!(terminal["sessions_written"], 3);
    let conn = rusqlite::Connection::open(&db).unwrap();
    let claude: i64 = conn
        .query_row(
            "select count(*) from sessions where harness = 'claude'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(claude, 3);

    // A cancel before the first grant writes nothing.
    let db = viewer_database(&temp);
    let mut child = coordinated(
        &["claude", "scan", "--claude-root", root.to_str().unwrap()],
        &db,
    );
    let mut input = child.stdin.take().unwrap();
    let events = support::EventStream::new(child.stdout.take().unwrap());
    let mut requested = 0;
    let mut terminal = None;
    while let Some(event) = events.next(&mut child) {
        match event["event"].as_str().unwrap() {
            "write_requested" => {
                requested += 1;
                writeln!(input, "cancel").unwrap();
                input.flush().unwrap();
            }
            "finished" => terminal = Some(event),
            _ => {}
        }
    }
    assert!(child.wait().unwrap().success());
    assert_eq!(requested, 1);
    assert_eq!(terminal.unwrap()["cancelled"], true);
    let conn = rusqlite::Connection::open(&db).unwrap();
    let count: i64 = conn
        .query_row("select count(*) from sessions", [], |row| row.get(0))
        .unwrap();
    assert_eq!(count, 0);
}
