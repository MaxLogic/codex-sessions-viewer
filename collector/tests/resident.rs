use support::Command;
mod support;

use codex_sessions_collector::resident::{endpoint, instance, protocol};
use serde_json::Value;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

// Hook latency is measured against the real executable and durable queue.
// Competing tests in this binary start dozens of residents and fsync-heavy
// databases. Keep those fixtures parallel, but give the two <1 s measurements
// an exclusive lane. Concurrency within each test is unchanged.
static FIXTURE_LOAD: std::sync::RwLock<()> = std::sync::RwLock::new(());

fn ordinary_fixture_lane() -> impl Drop {
    FIXTURE_LOAD
        .read()
        .unwrap_or_else(|error| error.into_inner())
}

fn latency_fixture_lane() -> impl Drop {
    FIXTURE_LOAD
        .write()
        .unwrap_or_else(|error| error.into_inner())
}

trait Wire: Read + Write + Send {}
impl<T: Read + Write + Send> Wire for T {}

fn next_event(wire: &mut impl BufRead) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut line = Vec::new();
    loop {
        match protocol::read_frame(wire, &mut line, protocol::MAX_EVENT_BYTES) {
            Ok(protocol::Frame::Complete) => return serde_json::from_slice(&line).unwrap(),
            Ok(protocol::Frame::Partial) => (),
            Err(e)
                if matches!(
                    e.kind(),
                    std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                ) => {}
            other => panic!("event stream ended: {:?}", other.err()),
        }
        assert!(Instant::now() < deadline, "event timeout");
    }
}

impl Fixture {
    fn viewer_request(&self, id: &str, op: &str) -> Value {
        serde_json::json!({"v":1,"id":id,"op":op,"harnesses":["codex"],
            "context":{"database":self.db,"settings":null,"windows_root":self.root.join("codex"),
            "wsl_root":null,"wsl_unc_root":null,"claude_roots":[self.root.join("claude")],
            "claude_wsl_roots":[],"wsl_projects":false}})
    }
}

#[test]
fn scan_request_streams_progress_before_finished_and_done() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.rollout("01a0aaaa-0000-7000-8000-000000000201");
    fixture.start("resident");
    fixture.ready();
    let mut wire = fixture.wire();
    protocol::send(wire.get_mut(), &fixture.viewer_request("scan", "scan")).unwrap();
    let first = next_event(&mut wire);
    assert_eq!(first["event"], "progress", "{first}");
    assert!(first["counts"].is_object());
    let mut finished = false;
    loop {
        let event = next_event(&mut wire);
        assert_eq!(event["id"], "scan");
        assert_ne!(event["event"], "error", "{event}");
        if event["event"] == "finished" {
            finished = true;
            assert_eq!(event["files_parsed"], 1);
        }
        if event["event"] == "done" {
            assert!(finished);
            assert_eq!(event["cancelled"], false);
            break;
        }
    }
}

#[test]
fn scan_request_refuses_missing_relative_or_foreign_context() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    for case in ["missing", "relative", "database", "settings"] {
        let mut wire = fixture.wire();
        let mut request = fixture.viewer_request(case, "scan");
        match case {
            "missing" => {
                request.as_object_mut().unwrap().remove("context");
            }
            "relative" => request["context"]["windows_root"] = "relative".into(),
            "database" => {
                request["context"]["database"] =
                    serde_json::json!(fixture.root.join("other.sqlite"))
            }
            "settings" => {
                request["context"]["settings"] = serde_json::json!(fixture.root.join("other.toml"))
            }
            _ => unreachable!(),
        }
        let event = exchange(&mut wire, request);
        assert_eq!(event["event"], "error", "{case}: {event}");
        assert!(
            matches!(event["code"].as_str(), Some("refused" | "bad_request")),
            "{event}"
        );
    }
}

fn await_scanning(fixture: &Fixture) {
    let deadline = Instant::now() + Duration::from_secs(4);
    loop {
        let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
        if status["state"] == "scanning" {
            return;
        }
        assert!(Instant::now() < deadline, "scan did not start: {status}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn scan_request_cancel_detaches_one_coalesced_waiter() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.rollout("01a0aaaa-0000-7000-8000-000000000204");
    fixture.start("resident");
    fixture.ready();
    let mut first = fixture.wire();
    let mut second = fixture.wire();
    let mut control = fixture.wire();
    assert_eq!(
        exchange(
            &mut control,
            serde_json::json!({"v":1,"id":"pause","op":"pause"})
        )["event"],
        "paused"
    );
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(codex_sessions_collector::store::write_lease::lock_path(&fixture.db).unwrap())
        .unwrap();
    lock.try_lock().unwrap();
    protocol::send(first.get_mut(), &fixture.viewer_request("first", "scan")).unwrap();
    protocol::send(second.get_mut(), &fixture.viewer_request("second", "scan")).unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
        if status["work_requests"] == 2 {
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        exchange(
            &mut control,
            serde_json::json!({"v":1,"id":"resume","op":"resume"})
        )["event"],
        "resumed"
    );
    await_scanning(&fixture);
    protocol::send(
        first.get_mut(),
        &serde_json::json!({"v":1,"id":"cancel","op":"cancel","target":"first"}),
    )
    .unwrap();
    // A status reply on this connection is a barrier after cancellation was registered.
    protocol::send(
        first.get_mut(),
        &serde_json::json!({"v":1,"id":"barrier","op":"status"}),
    )
    .unwrap();
    let mut first_done = false;
    loop {
        let event = next_event(&mut first);
        if event["event"] == "done" {
            assert_eq!(event["cancelled"], true);
            first_done = true;
        }
        if event["id"] == "barrier" {
            break;
        }
    }
    drop(lock);
    loop {
        let event = next_event(&mut second);
        assert_ne!(event["event"], "error", "{event}");
        if event["event"] == "done" {
            assert_eq!(event["cancelled"], false);
            break;
        }
    }
    while !first_done {
        let event = next_event(&mut first);
        if event["event"] == "done" {
            assert_eq!(event["cancelled"], true);
            first_done = true;
        }
    }
    let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
    assert_eq!(status["last_scan"]["sequence"], 1);
    fixture.await_ingested("01a0aaaa-0000-7000-8000-000000000204");
}

#[test]
fn scan_request_cancel_on_same_connection_abandons_a_lease_wait() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.rollout("01a0aaaa-0000-7000-8000-000000000202");
    fixture.start("resident");
    fixture.ready();
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(codex_sessions_collector::store::write_lease::lock_path(&fixture.db).unwrap())
        .unwrap();
    lock.try_lock().unwrap();
    let mut wire = fixture.wire();
    protocol::send(wire.get_mut(), &fixture.viewer_request("cancel-me", "scan")).unwrap();
    await_scanning(&fixture);
    protocol::send(
        wire.get_mut(),
        &serde_json::json!({"v":1,"id":"cancel","op":"cancel","target":"cancel-me"}),
    )
    .unwrap();
    loop {
        let event = next_event(&mut wire);
        if event["event"] == "done" {
            assert_eq!(event["cancelled"], true);
            break;
        }
    }
    assert_eq!(
        rusqlite::Connection::open(&fixture.db)
            .unwrap()
            .query_row("select count(*) from sessions", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    drop(lock);
    protocol::send(wire.get_mut(), &fixture.viewer_request("fresh", "scan")).unwrap();
    loop {
        let event = next_event(&mut wire);
        assert_ne!(event["event"], "error", "{event}");
        if event["event"] == "done" {
            assert_eq!(event["cancelled"], false);
            break;
        }
    }
    fixture.await_ingested("01a0aaaa-0000-7000-8000-000000000202");
}

#[test]
fn bridge_pause_abandons_scan_and_resume_starts_no_old_plan() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let sessions = fixture.root.join("codex/sessions");
    std::fs::create_dir_all(&sessions).unwrap();
    for i in 0..64 {
        support::write_generated_session(
            &sessions.join(format!("{i:03}.jsonl")),
            &format!("01a0aaaa-0000-7000-8000-{i:012}"),
            1,
        );
    }
    let child = fixture
        .command()
        .args(["serve", "--db"])
        .arg(&fixture.db)
        .args(["--flush-sessions", "1"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .stdin(Stdio::null())
        .spawn()
        .unwrap();
    fixture.children.push(child);
    fixture.ready();
    let mut wire = fixture.wire();
    protocol::send(
        wire.get_mut(),
        &fixture.viewer_request("interrupted", "scan"),
    )
    .unwrap();
    let connection = rusqlite::Connection::open(&fixture.db).unwrap();
    let count = || {
        connection
            .query_row("select count(*) from sessions", [], |r| r.get::<_, i64>(0))
            .unwrap()
    };
    let deadline = Instant::now() + Duration::from_secs(4);
    while count() == 0 {
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    protocol::send(
        wire.get_mut(),
        &serde_json::json!({"v":1,"id":"pause","op":"pause"}),
    )
    .unwrap();
    let mut cancelled = false;
    loop {
        let event = next_event(&mut wire);
        if event["event"] == "done" {
            assert_eq!(event["cancelled"], true);
            cancelled = true;
        }
        if event["event"] == "paused" {
            assert!(cancelled, "pause acknowledged before scan ended");
            break;
        }
    }
    let at_pause = count();
    assert!(at_pause < 64);
    assert_eq!(
        connection
            .query_row("pragma wal_checkpoint(truncate)", [], |r| r
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert_eq!(
        exchange(
            &mut wire,
            serde_json::json!({"v":1,"id":"resume","op":"resume"})
        )["event"],
        "resumed"
    );
    std::thread::sleep(Duration::from_millis(500));
    assert_eq!(count(), at_pause, "old plan resumed");
    protocol::send(wire.get_mut(), &fixture.viewer_request("new-plan", "scan")).unwrap();
    loop {
        let event = next_event(&mut wire);
        assert_ne!(event["event"], "error", "{event}");
        if event["event"] == "done" {
            assert_eq!(event["cancelled"], false);
            break;
        }
    }
    assert_eq!(count(), 64);
}

#[test]
fn bridge_pause_waits_for_closed_database_and_disconnect_releases() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let mut first = fixture.wire();
    let mut second = fixture.wire();
    assert_eq!(
        exchange(
            &mut first,
            serde_json::json!({"v":1,"id":"p1","op":"pause"})
        )["event"],
        "paused"
    );
    assert_eq!(
        exchange(
            &mut second,
            serde_json::json!({"v":1,"id":"p2","op":"pause"})
        )["event"],
        "paused"
    );
    let connection = rusqlite::Connection::open(&fixture.db).unwrap();
    let result: (i64, i64, i64) = connection
        .query_row("pragma wal_checkpoint(truncate)", [], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        })
        .unwrap();
    assert_eq!(result.0, 0);
    drop(connection);
    #[cfg(windows)]
    {
        // Windows SQLite handles do not share deletion. A successful rename
        // proves the resident closed its connection, beyond transaction quiescence.
        let renamed = fixture.root.join("closed-while-paused.sqlite");
        std::fs::rename(&fixture.db, &renamed).unwrap();
        std::fs::rename(&renamed, &fixture.db).unwrap();
    }
    drop(first);
    let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
    assert_eq!(status["state"], "paused");
    drop(second);
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
        if status["state"] == "ready" {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "disconnect did not resume: {status}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn bridge_pause_survives_cancel_flood() {
    let _fixture_load = ordinary_fixture_lane();
    bridge_pause_survives_flood("cancel", 3000, 0, false);
}

#[test]
fn bridge_pause_survives_large_id_flood() {
    let _fixture_load = ordinary_fixture_lane();
    bridge_pause_survives_flood("status", 20, 60_000, false);
}

#[test]
fn bridge_pause_survives_oversized_frame() {
    let _fixture_load = ordinary_fixture_lane();
    bridge_pause_survives_flood("oversized", 1, 70_000, false);
}

#[test]
fn bridge_resident_pause_survives_direct_control_flood() {
    let _fixture_load = ordinary_fixture_lane();
    for (op, count, padding) in [
        ("cancel", 3000, 0),
        ("status", 20, 60_000),
        ("oversized", 1, 70_000),
    ] {
        bridge_pause_survives_flood(op, count, padding, true);
    }
}

fn bridge_pause_survives_flood(op: &'static str, count: usize, padding: usize, direct: bool) {
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let (mut input, output): (Box<dyn Write + Send>, Box<dyn Read + Send>) = if direct {
        let stream = fixture.native_stream();
        (Box::new(stream.try_clone().unwrap()), Box::new(stream))
    } else {
        let child = fixture
            .command()
            .args(["client", "--db"])
            .arg(&fixture.db)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        fixture.children.push(child);
        let child = fixture.children.last_mut().unwrap();
        (
            Box::new(child.stdin.take().unwrap()),
            Box::new(child.stdout.take().unwrap()),
        )
    };
    let (sender, receiver) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || {
        for line in BufReader::new(output).lines() {
            let Ok(line) = line else { break };
            if sender
                .send(serde_json::from_str::<Value>(&line).unwrap())
                .is_err()
            {
                break;
            }
        }
    });
    let receive = || {
        receiver
            .recv_timeout(Duration::from_secs(15))
            .expect("flood reply timeout")
    };
    if !direct {
        assert_eq!(receive()["state"], "connected");
    }
    protocol::send(
        &mut input,
        &serde_json::json!({"v":1,"id":"pause","op":"pause"}),
    )
    .unwrap();
    assert_eq!(receive()["event"], "paused");
    let writer = std::thread::spawn(move || {
        for index in 0..count {
            let id = format!(
                "flood-{index}-{}",
                "x".repeat(if op == "oversized" { 0 } else { padding })
            );
            protocol::send(
                &mut input,
                &serde_json::json!({"v":1,"id":id,"op":if op == "oversized" { "status" } else { op },"target":"unknown", "extra":"x".repeat(if op == "oversized" { padding } else { 0 })}),
            )
            .unwrap();
        }
        protocol::send(
            &mut input,
            &serde_json::json!({"v":1,"id":"marker","op":"status"}),
        )
        .unwrap();
        input
    });
    let mut answered = std::collections::HashSet::new();
    loop {
        let event = receive();
        assert_ne!(
            event["event"], "bridge",
            "flood disconnected an acknowledged pause: {event}"
        );
        assert_ne!(event["code"], "disconnected", "flood reply disconnected");
        if event["id"] == "marker" {
            assert_eq!(event["state"], "paused", "pause lost during flood: {event}");
            assert_eq!(answered.len(), count, "missing flood replies");
            break;
        }
        let id = event["id"].as_str().unwrap();
        assert!(id.starts_with("flood-") || (op == "oversized" && id.is_empty()));
        assert!(answered.insert(id.to_owned()), "duplicate flood reply");
        assert_eq!(event["code"], "bad_request");
    }
    let mut input = writer.join().unwrap();
    protocol::send(
        &mut input,
        &serde_json::json!({"v":1,"id":"resume","op":"resume"}),
    )
    .unwrap();
    assert_eq!(receive()["event"], "resumed");
    if direct {
        protocol::send(
            &mut input,
            &serde_json::json!({"v":1,"id":"shutdown","op":"shutdown"}),
        )
        .unwrap();
        assert_eq!(receive()["event"], "stopping");
    }
    drop(input);
    let child = fixture.children.last_mut().unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while child.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "bridge survived EOF");
        std::thread::sleep(Duration::from_millis(10));
    }
    reader.join().unwrap();
}

#[test]
fn bridge_controls_remain_admissible_at_work_capacity() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    // Keep work queued after the bridge resumes, so cancellation is deterministic.
    let mut other_pauser = fixture.wire();
    assert_eq!(
        exchange(
            &mut other_pauser,
            serde_json::json!({"v":1,"id":"other-pause","op":"pause"})
        )["event"],
        "paused"
    );
    let child = fixture
        .command()
        .args(["client", "--db"])
        .arg(&fixture.db)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    fixture.children.push(child);
    let child = fixture.children.last_mut().unwrap();
    let mut input = child.stdin.take().unwrap();
    let output = child.stdout.take().unwrap();
    let (sender, receiver) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || {
        for line in BufReader::new(output).lines() {
            let Ok(line) = line else { break };
            let event = serde_json::from_str::<Value>(&line).unwrap();
            if sender.send(event).is_err() {
                break;
            }
        }
    });
    let receive = || receiver.recv_timeout(Duration::from_secs(10)).unwrap();
    assert_eq!(receive()["state"], "connected");
    protocol::send(
        &mut input,
        &serde_json::json!({"v":1,"id":"pause","op":"pause"}),
    )
    .unwrap();
    assert_eq!(receive()["event"], "paused");
    for index in 0..64 {
        protocol::send(
            &mut input,
            &fixture.viewer_request(&format!("scan-{index}"), "scan"),
        )
        .unwrap();
    }
    protocol::send(&mut input, &fixture.viewer_request("overflow", "scan")).unwrap();
    let overflow = receive();
    assert_eq!(overflow["id"], "overflow", "{overflow}");
    assert_eq!(overflow["code"], "refused", "{overflow}");
    protocol::send(
        &mut input,
        &serde_json::json!({"v":1,"id":"resume","op":"resume"}),
    )
    .unwrap();
    let resumed = receive();
    assert_eq!(
        resumed["event"], "resumed",
        "control refused at capacity: {resumed}"
    );
    for op in ["status", "hello"] {
        protocol::send(
            &mut input,
            &serde_json::json!({"v":1,"id":op,"op":op,"client":"viewer"}),
        )
        .unwrap();
        let event = receive();
        assert_eq!(event["event"], op, "{event}");
        assert_eq!(event["state"], "paused", "{event}");
        if op == "status" {
            assert_eq!(event["work_requests"], 64, "{event}");
        }
    }
    protocol::send(
        &mut input,
        &serde_json::json!({"v":1,"id":"cancel","op":"cancel","target":"scan-0"}),
    )
    .unwrap();
    let cancelled = receive();
    assert_eq!(cancelled["id"], "scan-0", "{cancelled}");
    assert_eq!(cancelled["event"], "done", "{cancelled}");
    assert_eq!(cancelled["cancelled"], true, "{cancelled}");
    assert_eq!(
        exchange(
            &mut other_pauser,
            serde_json::json!({"v":1,"id":"other-resume","op":"resume"})
        )["event"],
        "resumed"
    );
    let mut completed = std::collections::HashSet::new();
    while completed.len() < 63 {
        let event = receive();
        assert_ne!(event["event"], "error", "{event}");
        if event["event"] == "done" {
            assert_eq!(event["cancelled"], false, "{event}");
            assert!(completed.insert(event["id"].as_str().unwrap().to_owned()));
        }
    }
    drop(input);
    let child = fixture.children.last_mut().unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        assert!(Instant::now() < deadline, "bridge survived EOF");
        std::thread::sleep(Duration::from_millis(20));
    }
    reader.join().unwrap();
}

#[test]
fn bridge_stalled_stdout_does_not_delay_stdin_eof() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let mut child = fixture
        .command()
        .args(["client", "--db"])
        .arg(&fixture.db)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    fixture.children.push(child);
    assert_eq!(next_event(&mut output)["state"], "connected");
    protocol::send(
        &mut input,
        &serde_json::json!({"v":1,"id":"pause","op":"pause"}),
    )
    .unwrap();
    assert_eq!(next_event(&mut output)["event"], "paused");
    // Rust's child pipe is larger than Python's 4 KiB reviewer pipe.
    for index in 0..300 {
        protocol::send(
            &mut input,
            &serde_json::json!({"v":1,"id":format!("status-{index}"),"op":"status"}),
        )
        .unwrap();
    }
    std::thread::sleep(Duration::from_millis(500));
    drop(input);
    let deadline = Instant::now() + Duration::from_secs(3);
    while fixture
        .children
        .last_mut()
        .unwrap()
        .try_wait()
        .unwrap()
        .is_none()
    {
        assert!(
            Instant::now() < deadline,
            "stalled stdout prevented EOF teardown"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    loop {
        let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
        if status["state"] == "ready" {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "EOF did not release pause: {status}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn bridge_resident_disconnect_releases_pause_with_full_output_queue() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let mut stream = BufReader::new(fixture.native_stream());
    protocol::send(
        stream.get_mut(),
        &serde_json::json!({"v":1,"id":"pause","op":"pause"}),
    )
    .unwrap();
    assert_eq!(next_event(&mut stream)["event"], "paused");
    for index in 0..300 {
        protocol::send(
            stream.get_mut(),
            &serde_json::json!({"v":1,"id":format!("status-{index}"),"op":"status"}),
        )
        .unwrap();
    }
    std::thread::sleep(Duration::from_millis(500));
    drop(stream);
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let status = fixture.cli("status");
        assert!(status.status.success(), "other client's status was blocked");
        let status: Value = serde_json::from_slice(&status.stdout).unwrap();
        if status["state"] == "ready" {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "full queue hid disconnect: {status}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn bridge_resident_stalled_refusals_isolate_other_clients() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let mut stalled = BufReader::new(fixture.native_stream());
    protocol::send(
        stalled.get_mut(),
        &serde_json::json!({"v":1,"id":"pause","op":"pause"}),
    )
    .unwrap();
    assert_eq!(next_event(&mut stalled)["event"], "paused");
    for index in 0..64 {
        protocol::send(
            stalled.get_mut(),
            &fixture.viewer_request(&format!("queued-{index}"), "scan"),
        )
        .unwrap();
    }
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
        if status["work_requests"] == 64 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "work queue did not fill: {status}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let template = fixture.viewer_request("flood", "scan");
    let (release, hold) = std::sync::mpsc::channel();
    let writer = std::thread::spawn(move || {
        let mut stream = stalled.into_inner();
        for index in 0..300 {
            let mut request = template.clone();
            request["id"] = format!("refused-{index}-{}", "x".repeat(230)).into();
            if protocol::send(&mut stream, &request).is_err() {
                break;
            }
        }
        let _ = hold.recv();
    });
    std::thread::sleep(Duration::from_secs(1));
    let started = Instant::now();
    let control = |action| {
        let phase = Instant::now();
        let output = fixture
            .command()
            .env("CODEX_SESSIONS_COLLECTOR_TIMINGS", "1")
            .args(["resident", action, "--db"])
            .arg(&fixture.db)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap()
            .wait_with_output()
            .unwrap();
        eprintln!(
            "independent control {action}_ms={:.3}",
            phase.elapsed().as_secs_f64() * 1000.0
        );
        output
    };
    let status = control("status");
    let shutdown = control("stop");
    eprintln!(
        "independent controls completed_ms={:.3}",
        started.elapsed().as_secs_f64() * 1000.0
    );
    // Stop the fixture before joining the producer, including on a regression.
    for child in &mut fixture.children {
        if child.try_wait().unwrap().is_none() {
            child.kill().unwrap();
        }
        child.wait().unwrap();
    }
    let _ = release.send(());
    writer.join().unwrap();
    eprintln!(
        "independent controls plus cleanup_ms={:.3}",
        started.elapsed().as_secs_f64() * 1000.0
    );
    assert!(
        status.status.success(),
        "independent status blocked: {}",
        String::from_utf8_lossy(&status.stderr)
    );
    assert!(
        shutdown.status.success(),
        "independent shutdown blocked: {}",
        String::from_utf8_lossy(&shutdown.stderr)
    );
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "independent controls were delayed"
    );
}

#[test]
fn bridge_starts_absent_resident_relays_and_exits_on_stdin_eof() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    std::fs::create_dir_all(fixture.root.join("Caller-Root")).unwrap();
    support::write_generated_session(
        &fixture.root.join("Caller-Root/one.jsonl"),
        "01a0aaaa-0000-7000-8000-000000000203",
        1,
    );
    let child = fixture
        .command()
        .current_dir(&fixture.root)
        .args([
            "client",
            "--db",
            "viewer.sqlite",
            "--windows-root",
            "Caller-Root",
            "--no-wsl-projects",
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    fixture.children.push(child);
    let child = fixture.children.last_mut().unwrap();
    let mut input = child.stdin.take().unwrap();
    let output = child.stdout.take().unwrap();
    let (sender, receiver) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || {
        for line in BufReader::new(output).lines() {
            if sender
                .send(serde_json::from_str::<Value>(&line.unwrap()).unwrap())
                .is_err()
            {
                break;
            }
        }
    });
    protocol::send(
        &mut input,
        &serde_json::json!({"v":1,"id":"status","op":"status"}),
    )
    .unwrap();
    let mut connected = false;
    loop {
        let event = receiver
            .recv_timeout(Duration::from_secs(10))
            .expect("bridge did not relay status");
        if event["event"] == "bridge" && event["state"] == "connected" {
            connected = true;
        }
        if event["id"] == "status" {
            assert_eq!(event["event"], "status");
            assert!(connected);
            break;
        }
    }
    protocol::send(
        &mut input,
        &serde_json::json!({"v":1,"id":"scan","op":"scan","harnesses":["codex"]}),
    )
    .unwrap();
    let mut finished = false;
    loop {
        let event = receiver.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_ne!(event["event"], "error", "{event}");
        if event["event"] == "finished" {
            assert_eq!(event["files_parsed"], 1);
            finished = true;
        }
        if event["event"] == "done" {
            assert!(finished);
            break;
        }
    }
    let stored_path: String = rusqlite::Connection::open(&fixture.db)
        .unwrap()
        .query_row("select source_file_path from sessions", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(
        stored_path,
        fixture
            .root
            .join("Caller-Root")
            .join("one.jsonl")
            .to_string_lossy()
    );
    support::write_generated_session(
        &fixture.root.join("Caller-Root/Reload.Two.jsonl"),
        "01a0aaaa-0000-7000-8000-000000000299",
        1,
    );
    protocol::send(
        &mut input,
        &serde_json::json!({"v":1,"id":"reload","op":"ingest","harness":"codex","path":"Caller-Root/Reload.Two.jsonl"}),
    )
    .unwrap();
    let event = receiver.recv_timeout(Duration::from_secs(10)).unwrap();
    assert_eq!(event["id"], "reload", "{event}");
    assert_eq!(event["event"], "finished", "{event}");
    assert_eq!(event["sessions_written"], 1, "{event}");
    let reloaded_path: String = rusqlite::Connection::open(&fixture.db)
        .unwrap()
        .query_row(
            "select source_file_path from sessions where session_id=?",
            ["01a0aaaa-0000-7000-8000-000000000299"],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(
        reloaded_path,
        fixture
            .root
            .join("Caller-Root")
            .join("Reload.Two.jsonl")
            .to_string_lossy()
    );
    protocol::send(
        &mut input,
        &serde_json::json!({"v":1,"id":"pause","op":"pause"}),
    )
    .unwrap();
    let event = receiver.recv_timeout(Duration::from_secs(3)).unwrap();
    assert_eq!(event["event"], "paused", "{event}");
    drop(input);
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        assert!(Instant::now() < deadline, "bridge survived EOF");
        std::thread::sleep(Duration::from_millis(20));
    }
    reader.join().unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
        if status["state"] == "ready" {
            break;
        }
        assert!(Instant::now() < deadline, "bridge EOF left resident paused");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn bridge_reports_inflight_disconnect_and_reconnects_without_replaying() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.rollout("01a0aaaa-0000-7000-8000-000000000205");
    fixture.start("resident");
    fixture.ready();
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(codex_sessions_collector::store::write_lease::lock_path(&fixture.db).unwrap())
        .unwrap();
    lock.try_lock().unwrap();
    let mut bridge = fixture
        .command()
        .args(["client", "--db"])
        .arg(&fixture.db)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut input = bridge.stdin.take().unwrap();
    let output = bridge.stdout.take().unwrap();
    fixture.children.push(bridge);
    let (sender, receiver) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || {
        for line in BufReader::new(output).lines() {
            if sender
                .send(serde_json::from_str::<Value>(&line.unwrap()).unwrap())
                .is_err()
            {
                break;
            }
        }
    });
    protocol::send(
        &mut input,
        &serde_json::json!({"v":1,"id":"interrupted","op":"scan","harnesses":["codex"]}),
    )
    .unwrap();
    await_scanning(&fixture);
    fixture.children[0].kill().unwrap();
    fixture.children[0].wait().unwrap();
    let mut disconnected = false;
    let mut reconnecting = false;
    loop {
        let event = receiver.recv_timeout(Duration::from_secs(10)).unwrap();
        if event["id"] == "interrupted" && event["code"] == "disconnected" {
            disconnected = true;
        }
        if event["event"] == "bridge" && event["state"] == "reconnecting" {
            reconnecting = true;
        }
        if reconnecting && event["event"] == "bridge" && event["state"] == "connected" {
            assert!(disconnected);
            break;
        }
    }
    drop(lock);
    protocol::send(
        &mut input,
        &serde_json::json!({"v":1,"id":"fresh","op":"scan","harnesses":["codex"]}),
    )
    .unwrap();
    loop {
        let event = receiver.recv_timeout(Duration::from_secs(10)).unwrap();
        assert_ne!(event["id"], "interrupted", "disconnected scan replayed");
        assert_ne!(event["event"], "error", "{event}");
        if event["id"] == "fresh" && event["event"] == "done" {
            assert_eq!(event["cancelled"], false);
            break;
        }
    }
    drop(input);
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if let Some(status) = fixture.children[1].try_wait().unwrap() {
            assert!(status.success());
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(10));
    }
    reader.join().unwrap();
}

#[cfg(windows)]
#[test]
fn bridge_replaces_only_a_positively_incompatible_resident() {
    let _fixture_load = ordinary_fixture_lane();
    for scenario in [
        "disconnect",
        "malformed",
        "build",
        "version",
        "viewer-protocol",
        "lost-shutdown-reply",
    ] {
        eprintln!("bridge compatibility scenario={scenario}");
        let incompatible = matches!(
            scenario,
            "build" | "version" | "viewer-protocol" | "lost-shutdown-reply"
        );
        let fixture = Fixture::new();
        let key = instance::database_key(&fixture.db).unwrap();
        let lock = instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .unwrap();
        let mut listener = endpoint::Listener::bind(&key).unwrap();
        let fake = std::thread::spawn(move || {
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut accept = || {
                loop {
                    match listener.accept() {
                        Ok(stream) => return stream,
                        Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {
                            assert!(Instant::now() < deadline)
                        }
                        Err(e) => panic!("fake accept: {e}"),
                    }
                }
            };
            let mut wire = BufReader::new(accept());
            let request = next_event(&mut wire);
            assert_eq!(request["op"], "hello");
            if scenario == "malformed" {
                protocol::send(wire.get_mut(), &serde_json::json!({"v":1,"id":"bridge-hello","event":"hello","database_key":key})).unwrap();
                let mut byte = [0];
                assert_eq!(
                    wire.read(&mut byte).unwrap(),
                    0,
                    "malformed hello triggered another request"
                );
            }
            if incompatible {
                if scenario == "version" {
                    protocol::send(wire.get_mut(), &serde_json::json!({"v":2,"id":"bridge-hello","event":"error","code":"unsupported_version"})).unwrap();
                    drop(wire);
                    wire = BufReader::new(accept());
                } else {
                    let mut hello = serde_json::json!({"v":1,"id":"bridge-hello","event":"hello",
                        "database_key":key,"protocol":1,"collector_version":"older-build","schema":30,"contract":2,
                        "parsers":{"codex":1,"claude":1},"state":"ready"});
                    if scenario == "viewer-protocol" {
                        hello["collector_version"] = env!("CARGO_PKG_VERSION").into();
                        hello["schema"] =
                            codex_sessions_collector::store::schema::SUPPORTED_SCHEMA_VERSION
                                .into();
                        hello["contract"] =
                            codex_sessions_collector::contract::CONTRACT_VERSION.into();
                        hello["parsers"]["codex"] =
                            codex_sessions_collector::codex::parser::PARSER_VERSION.into();
                        hello["parsers"]["claude"] =
                            codex_sessions_collector::claude::parser::CLAUDE_PARSER_VERSION.into();
                    }
                    protocol::send(wire.get_mut(), &hello).unwrap();
                }
                let shutdown = next_event(&mut wire);
                assert_eq!(shutdown["op"], "shutdown");
                if scenario != "lost-shutdown-reply" {
                    protocol::send(
                        wire.get_mut(),
                        &protocol::event("bridge-replace", "stopping"),
                    )
                    .unwrap();
                }
            }
            // false simulates a transient disconnect during hello, with no identity reply.
            drop(wire);
            drop(listener);
            drop(lock);
        });
        let mut bridge = fixture
            .command()
            .args(["client", "--db"])
            .arg(&fixture.db)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let input = bridge.stdin.take().unwrap();
        let mut events = Vec::new();
        // Keep the viewer connected until the outcome is observed. EOF asks
        // the bridge to cancel output, so it cannot be a readiness barrier.
        for line in BufReader::new(bridge.stdout.take().unwrap()).lines() {
            let event: Value = serde_json::from_str(&line.unwrap()).unwrap();
            let terminal = matches!(event["state"].as_str(), Some("connected" | "failed"));
            events.push(event);
            if terminal {
                break;
            }
        }
        drop(input);
        let output = bridge.wait_with_output().unwrap();
        fake.join().unwrap();
        if incompatible {
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(
                events
                    .iter()
                    .any(|e| e["event"] == "bridge" && e["state"] == "replaced"),
                "{events:?}"
            );
            assert!(
                events
                    .iter()
                    .any(|e| e["event"] == "bridge" && e["state"] == "connected")
            );
        } else {
            assert!(!output.status.success());
            assert!(
                events
                    .iter()
                    .any(|e| e["event"] == "bridge" && e["state"] == "failed")
            );
            assert!(
                !events
                    .iter()
                    .any(|e| matches!(e["state"].as_str(), Some("replaced" | "starting")))
            );
            assert!(
                instance::InstanceLock::try_acquire(&fixture.db)
                    .unwrap()
                    .is_some()
            );
        }
    }
}

#[cfg(windows)]
#[test]
fn worker_identity_rejects_a_stale_process_from_before_the_hook() {
    let _fixture_load = ordinary_fixture_lane();
    use std::os::windows::io::AsRawHandle;
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let (older, _) = process_times(fixture.children[0].as_raw_handle());
    let mut hook = fixture.command().arg("version").spawn().unwrap();
    let identity = HookIdentity::capture(&hook);
    assert!(hook.wait().unwrap().success());
    let (start, end) = process_times(identity.handle.as_raw_handle());
    assert!(older < start);
    assert!(end >= start);
    assert!(
        !identity.owns_creation(older),
        "a stale parent-PID match must not be owned"
    );
    assert!(identity.owns_creation(start));
    assert!(
        !identity.owns_creation(end + 1),
        "a reused child PID must not be owned"
    );
}

#[test]
fn replacement_started_after_its_shared_deadline_does_not_become_a_resident() {
    let _fixture_load = ordinary_fixture_lane();
    let fixture = Fixture::new();
    let mut child = fixture
        .command()
        .args(["serve-replacement", "--db"])
        .arg(&fixture.db)
        .args(["--replacement-deadline-ms", "0"])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let until = Instant::now() + Duration::from_secs(2);
    while child.try_wait().unwrap().is_none() {
        if Instant::now() >= until {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("expired replacement remained running");
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    let output = child.wait_with_output().unwrap();
    assert_eq!(
        output.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stderr)
            .contains("resident did not release its instance lock")
    );
    assert!(!fixture.cli("status").status.success());
    assert!(
        instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .is_some()
    );
}

#[cfg(windows)]
#[test]
fn bridge_replacement_allows_a_slow_shutdown() {
    let _fixture_load = ordinary_fixture_lane();
    slow_bridge_replacement(6500, false);
}

#[cfg(windows)]
#[test]
fn bridge_replacement_allows_shutdown_near_its_deadline() {
    let _fixture_load = ordinary_fixture_lane();
    slow_bridge_replacement(9500, false);
}

#[cfg(windows)]
#[test]
fn bridge_replacement_survives_the_viewer_connection_deadline() {
    let _fixture_load = ordinary_fixture_lane();
    slow_bridge_replacement(6500, true);
}

#[cfg(windows)]
#[test]
fn bridge_replacement_stops_at_the_shutdown_deadline_without_an_orphan() {
    let _fixture_load = ordinary_fixture_lane();
    slow_bridge_replacement(10500, false);
}

#[cfg(windows)]
fn slow_bridge_replacement(delay_ms: u64, abandon: bool) {
    let mut fixture = Fixture::new();
    let key = instance::database_key(&fixture.db).unwrap();
    let lock = instance::InstanceLock::try_acquire(&fixture.db)
        .unwrap()
        .unwrap();
    let mut listener = endpoint::Listener::bind(&key).unwrap();
    let (shutdown_sent, shutdown_received) = std::sync::mpsc::channel();
    let fake = std::thread::spawn(move || {
        let until = Instant::now() + Duration::from_secs(5);
        let stream = loop {
            match listener.accept() {
                Ok(stream) => break stream,
                Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {
                    assert!(Instant::now() < until)
                }
                Err(e) => panic!("fake accept: {e}"),
            }
        };
        let mut wire = BufReader::new(stream);
        assert_eq!(next_event(&mut wire)["op"], "hello");
        protocol::send(
            wire.get_mut(),
            &serde_json::json!({"v":1,"id":"bridge-hello","event":"hello",
            "database_key":key,"protocol":1,"viewer_protocol":1,"collector_version":"older-build",
            "schema":30,"contract":2,"parsers":{"codex":1,"claude":1},"state":"ready"}),
        )
        .unwrap();
        assert_eq!(next_event(&mut wire)["op"], "shutdown");
        shutdown_sent.send(()).unwrap();
        drop(wire); // Deliberately lose the shutdown reply.
        drop(listener);
        std::thread::sleep(Duration::from_millis(delay_ms));
        drop(lock);
    });
    let start = Instant::now();
    let mut bridge = fixture
        .command()
        .args(["client", "--db"])
        .arg(&fixture.db)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let input = bridge.stdin.take().unwrap();
    let stdout = bridge.stdout.take().unwrap();
    let (sent, received) = std::sync::mpsc::channel();
    let output = std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines() {
            let event: Value = serde_json::from_str(&line.unwrap()).unwrap();
            if sent.send(event).is_err() {
                break;
            }
        }
    });
    shutdown_received
        .recv_timeout(Duration::from_secs(5))
        .unwrap();
    let workers = DetachedWorkers::for_hook(&HookIdentity::capture(&bridge));
    if abandon {
        std::thread::sleep(
            (start + Duration::from_secs(4)).saturating_duration_since(Instant::now()),
        );
        bridge.kill().unwrap();
        bridge.wait().unwrap();
        drop(input);
        output.join().unwrap();
        fixture.children.push(bridge);
        fake.join().unwrap();
        // A new viewer attempt must find a serving successor, even though no
        // viewer/bridge survived to launch it after the old lock was released.
        let until = Instant::now() + Duration::from_secs(4);
        loop {
            let status = fixture.cli("status");
            if status.status.success() {
                break;
            }
            assert!(
                Instant::now() < until,
                "replacement died with the viewer attempt"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
        let reconnect = fixture
            .command()
            .args(["client", "--db"])
            .arg(&fixture.db)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert!(reconnect.status.success());
        assert!(String::from_utf8_lossy(&reconnect.stdout).contains("\"state\":\"connected\""));
    } else {
        let mut replaced = false;
        loop {
            let event = received
                .recv_timeout(Duration::from_secs(16).saturating_sub(start.elapsed()))
                .unwrap();
            if delay_ms > 10000 {
                assert_ne!(event["state"], "replaced");
                assert_ne!(event["state"], "connected");
                if event["state"] == "failed" {
                    assert!(
                        start.elapsed() < Duration::from_secs(11),
                        "shutdown exceeded its bound"
                    );
                    break;
                }
                continue;
            }
            assert_ne!(event["state"], "failed", "{event}");
            if event["state"] == "replaced" {
                assert!(
                    fixture.cli("status").status.success(),
                    "replaced was emitted before successor served"
                );
                replaced = true;
            }
            if event["state"] == "connected" {
                assert!(replaced);
                break;
            }
        }
        drop(input);
        fixture.children.push(bridge);
        if delay_ms > 10000 {
            let until = Instant::now() + Duration::from_secs(3);
            while fixture.children[0].try_wait().unwrap().is_none() {
                assert!(Instant::now() < until);
                std::thread::sleep(Duration::from_millis(10));
            }
        } else {
            fixture.wait_all(Duration::from_secs(3));
        }
        output.join().unwrap();
        fake.join().unwrap();
    }
    assert!(
        start.elapsed() < Duration::from_secs(16),
        "replacement exceeded its total bound"
    );
    if delay_ms > 10000 {
        assert!(
            !fixture.cli("status").status.success(),
            "late successor escaped the shutdown deadline"
        );
    }
    assert!(fixture.cli("stop").status.success());
    drop(workers); // Retained native handles prove the detached process exited.
    assert!(
        instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .is_some()
    );
    // Fixture teardown stops and reaps the detached successor before deleting
    // its database; a surviving process/handle makes teardown fail.
}

#[cfg(windows)]
#[test]
fn database_identity_survives_creation_through_a_junction() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let junction = Junction::new(fixture.root.join("alias"), &fixture.root);
    fixture.db = fixture.root.join("missing/nested/new.sqlite");
    let alias = junction.0.join("missing/nested/new.sqlite");
    let spellings = [
        fixture.db.clone(),
        alias.clone(),
        PathBuf::from(alias.to_string_lossy().to_uppercase()),
        PathBuf::from(format!(
            r"\\?\{}",
            alias.to_string_lossy().replace('/', "\\")
        )),
        PathBuf::from(alias.to_string_lossy().replace('\\', "/")),
    ];
    let before: Vec<_> = spellings
        .iter()
        .map(|p| {
            (
                instance::database_key(p).unwrap(),
                instance::lock_path(p).unwrap(),
                codex_sessions_collector::store::write_lease::lock_path(p).unwrap(),
            )
        })
        .collect();
    let relative_key = |fixture: &Fixture| {
        let output = fixture
            .command()
            .current_dir(&fixture.root)
            .args([
                "resident",
                "info",
                "--db",
                "alias/missing/nested/new.sqlite",
            ])
            .output()
            .unwrap();
        assert!(output.status.success());
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["database_key"].clone()
    };
    let relative_before = relative_key(&fixture);
    let id = "01a0aaaa-0000-7000-8000-000000000195";
    fixture.rollout(id);
    let output = fixture
        .command()
        .args(["codex", "notify", "--no-drain", "--db"])
        .arg(&alias)
        .arg(serde_json::json!({"type":"agent-turn-complete","thread-id":id}).to_string())
        .output()
        .unwrap();
    assert!(output.status.success());
    std::fs::create_dir_all(fixture.db.parent().unwrap()).unwrap();
    support::create_viewer_database(&fixture.db);
    let expected = instance::database_key(&fixture.db).unwrap();
    for (path, before) in spellings.iter().zip(before) {
        assert_eq!(before.0, expected, "key changed on creation: {path:?}");
        assert_eq!(before.1, instance::lock_path(path).unwrap());
        assert_eq!(
            before.2,
            codex_sessions_collector::store::write_lease::lock_path(path).unwrap()
        );
    }
    assert_eq!(relative_before, relative_key(&fixture));
    assert_eq!(relative_before, expected);
    fixture.start("resident");
    fixture.ready();
    fixture.await_ingested(id);
}

#[test]
fn alternate_queue_detached_drain_keeps_caller_context_and_retries() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let id = "01a0aaaa-0000-7000-8000-000000000196";
    let queue = fixture.root.join("alternate-queue");
    std::fs::create_dir_all(fixture.root.join("caller-root/sessions")).unwrap();
    std::fs::write(
        fixture.root.join("caller.toml"),
        "[scanner]\nbackground_rescan_enabled=false\n",
    )
    .unwrap();
    let start = Instant::now();
    let mut command = fixture.command();
    command
        .current_dir(&fixture.root)
        .env("CODEX_SESSIONS_COLLECTOR_QUEUE", "alternate-queue")
        .args([
            "codex",
            "notify",
            "--db",
            "viewer.sqlite",
            "--settings",
            "caller.toml",
            "--windows-root",
            "caller-root",
            "--no-wsl-projects",
        ])
        .arg(serde_json::json!({"type":"agent-turn-complete","thread-id":id}).to_string());
    let hook = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let hook_identity = HookIdentity::capture(&hook);
    let output = hook.wait_with_output().unwrap();
    assert!(output.status.success());
    eprintln!(
        "alternate queue hook returned_ms={:.3}",
        start.elapsed().as_secs_f64() * 1000.0
    );
    let _workers = DetachedWorkers::for_hook(&hook_identity);
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if std::fs::read_dir(&queue)
            .unwrap()
            .flatten()
            .filter_map(|e| std::fs::read(e.path()).ok())
            .filter_map(|b| serde_json::from_slice::<Value>(&b).ok())
            .any(|v| v["attempts"].as_u64().is_some_and(|n| n >= 1))
        {
            break;
        }
        assert!(Instant::now() < deadline, "missing first retry state");
        std::thread::sleep(Duration::from_millis(20));
    }
    support::write_generated_session(
        &fixture
            .root
            .join(format!("caller-root/sessions/rollout-late-{id}.jsonl")),
        id,
        1,
    );
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let count: i64 = rusqlite::Connection::open(&fixture.db)
            .unwrap()
            .query_row(
                "select count(*) from sessions where session_id=?",
                [id],
                |r| r.get(0),
            )
            .unwrap();
        let empty = !std::fs::read_dir(&queue)
            .unwrap()
            .flatten()
            .any(|e| e.file_name().to_string_lossy().contains(".json"));
        if count == 1 && empty {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "detached caller-context retry failed: count={count}, empty={empty}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    let registry = PathBuf::from(format!(
        "{}.collector.queues",
        instance::identity_path(&fixture.db).unwrap().display()
    ));
    assert!(!registry.exists(), "hook created a queue registry");
}

#[test]
fn alternate_queue_detached_drain_recovers_from_database_unavailability() {
    let _fixture_load = latency_fixture_lane();
    for unavailable in ["migration", "locked"] {
        eprintln!("detached drain database recovery: {unavailable}");
        let mut fixture = Fixture::new();
        fixture.start("resident");
        fixture.ready();
        let id = "01a0aaaa-0000-7000-8000-000000000197";
        let queue = fixture.root.join("alternate-queue");
        let root = fixture.root.join("caller-root");
        std::fs::create_dir_all(root.join("sessions")).unwrap();
        support::write_generated_session(&root.join(format!("sessions/rollout-{id}.jsonl")), id, 1);
        let connection = rusqlite::Connection::open(&fixture.db).unwrap();
        match unavailable {
            "migration" => connection
                .execute_batch(
                    "insert into app_metadata values ('usage_migration_bootstrap', '{}', 'now')",
                )
                .unwrap(),
            "locked" => connection.execute_batch("begin immediate").unwrap(),
            _ => unreachable!(),
        }
        let started = Instant::now();
        let hook = fixture
            .command()
            .current_dir(&fixture.root)
            .env("CODEX_SESSIONS_COLLECTOR_QUEUE", "alternate-queue")
            .env("CODEX_SESSIONS_COLLECTOR_TIMINGS", "1")
            .env("CODEX_SESSIONS_COLLECTOR_BUSY_TIMEOUT_MS", "50")
            .args([
                "codex",
                "notify",
                "--db",
                "viewer.sqlite",
                "--windows-root",
                "caller-root",
                "--no-wsl-projects",
            ])
            .arg(serde_json::json!({"type":"agent-turn-complete","thread-id":id}).to_string())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let hook_identity = HookIdentity::capture(&hook);
        let output = hook.wait_with_output().unwrap();
        let hook_elapsed = started.elapsed();
        eprintln!(
            "database recovery {unavailable} hook phases:\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
        let _workers = DetachedWorkers::for_hook(&hook_identity);
        assert!(output.status.success());
        eprintln!(
            "database recovery {unavailable} hook_returned_ms={:.3}",
            hook_elapsed.as_secs_f64() * 1000.0
        );
        assert!(
            hook_elapsed < Duration::from_secs(1),
            "hook waited for database recovery"
        );
        // Keep the refusal in place across several retry polls. Attempts are a
        // file retry budget, never a database availability budget.
        let held_until = Instant::now() + Duration::from_secs(3);
        while Instant::now() < held_until {
            assert_queue_attempts(&queue, 0);
            std::thread::sleep(Duration::from_millis(25));
        }
        match unavailable {
            "migration" => connection
                .execute_batch("delete from app_metadata where key='usage_migration_bootstrap'")
                .unwrap(),
            "locked" => connection.execute_batch("commit").unwrap(),
            _ => unreachable!(),
        }
        wait_for_queue_ingest(&fixture, &queue, id);
        let errors = std::fs::read_to_string(queue.join("errors.log")).unwrap();
        assert!(
            errors.contains("drain waiting for database"),
            "missing {unavailable} diagnostic: {errors}"
        );
    }
}

#[test]
fn direct_drain_newer_schema_exits_promptly() {
    let _fixture_load = ordinary_fixture_lane();
    drain_newer_schema_is_permanent(false, false);
}

#[test]
fn direct_drain_newer_schema_after_claim_exits_promptly() {
    let _fixture_load = ordinary_fixture_lane();
    drain_newer_schema_is_permanent(true, false);
}

#[test]
fn alternate_queue_detached_drain_newer_schema_logs_refusal() {
    let _fixture_load = ordinary_fixture_lane();
    drain_newer_schema_is_permanent(true, true);
}

fn drain_newer_schema_is_permanent(after_claim: bool, detached: bool) {
    let mut fixture = Fixture::new();
    let id = "01a0aaaa-0000-7000-8000-000000000199";
    fixture.rollout(id);
    if detached {
        fixture.start("resident");
        fixture.ready();
    }
    let queue = fixture.root.join("permanent-queue");
    let lease = if after_claim {
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(codex_sessions_collector::store::write_lease::lock_path(&fixture.db).unwrap())
            .unwrap();
        file.lock().unwrap();
        Some(file)
    } else {
        None
    };
    let future_schema = || {
        rusqlite::Connection::open(&fixture.db)
            .unwrap()
            .execute_batch(
                "insert into schema_version values (999, '999_future.sql', 'x', 'now', 1, null)",
            )
            .unwrap();
    };
    if !after_claim {
        future_schema();
    }
    let mut hook = fixture.command();
    hook.env("CODEX_SESSIONS_COLLECTOR_QUEUE", &queue)
        .args(["codex", "notify", "--db"])
        .arg(&fixture.db);
    if !detached {
        hook.arg("--no-drain");
    }
    let hook = hook
        .arg(serde_json::json!({"type":"agent-turn-complete","thread-id":id}).to_string())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let hook_identity = HookIdentity::capture(&hook);
    assert!(hook.wait_with_output().unwrap().status.success());
    let _workers = detached.then(|| DetachedWorkers::for_hook(&hook_identity));
    let direct = if !detached {
        let child = fixture
            .command()
            .env("CODEX_SESSIONS_COLLECTOR_QUEUE", &queue)
            .args(["drain", "--db"])
            .arg(&fixture.db)
            .stdout(Stdio::null())
            .stderr(std::fs::File::create(fixture.root.join("drain.stderr")).unwrap())
            .spawn()
            .unwrap();
        fixture.children.push(child);
        Some(fixture.children.len() - 1)
    } else {
        None
    };
    if after_claim {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !std::fs::read_dir(&queue)
            .unwrap()
            .flatten()
            .any(|e| e.file_name().to_string_lossy().contains(".claimed-"))
        {
            assert!(
                Instant::now() < deadline,
                "drain did not reach the held write lease"
            );
            std::thread::sleep(Duration::from_millis(10));
        }
        future_schema();
    }
    let started = Instant::now();
    drop(lease);
    let deadline = started + Duration::from_secs(3);
    loop {
        if let Some(index) = direct {
            if let Some(status) = fixture.children[index].try_wait().unwrap() {
                assert_eq!(status.code(), Some(3));
                break;
            }
        } else if std::fs::read_to_string(queue.join("errors.log"))
            .unwrap_or_default()
            .contains("drain stopped:")
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "permanently newer schema kept drain waiting"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    let errors = std::fs::read_to_string(queue.join("errors.log")).unwrap();
    assert!(errors.contains("schema version 999"), "{errors}");
    assert!(
        !errors.contains("waiting for database"),
        "incompatible schema marked transient: {errors}"
    );
    assert_queue_attempts(&queue, 0);
    assert!(
        !std::fs::read_dir(&queue)
            .unwrap()
            .flatten()
            .any(|e| e.file_name().to_string_lossy().contains(".claimed-")),
        "permanent refusal retained a claim"
    );
    eprintln!(
        "newer_schema after_claim={after_claim} detached={detached} refused_ms={:.3}",
        started.elapsed().as_secs_f64() * 1000.0
    );
}

#[test]
fn direct_drain_recovers_when_migration_starts_after_claim() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let id = "01a0aaaa-0000-7000-8000-000000000198";
    fixture.rollout(id);
    assert!(fixture.hook(id, true).status.success());
    let queue = fixture.root.join("queue");
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(codex_sessions_collector::store::write_lease::lock_path(&fixture.db).unwrap())
        .unwrap();
    lock.lock().unwrap();
    let child = fixture
        .command()
        .args(["drain", "--db"])
        .arg(&fixture.db)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    fixture.children.push(child);
    let deadline = Instant::now() + Duration::from_secs(10);
    while !std::fs::read_dir(&queue)
        .unwrap()
        .flatten()
        .any(|e| e.file_name().to_string_lossy().contains(".claim"))
    {
        assert!(Instant::now() < deadline, "drain never claimed entry");
        std::thread::sleep(Duration::from_millis(20));
    }
    let connection = rusqlite::Connection::open(&fixture.db).unwrap();
    connection
        .execute_batch("insert into app_metadata values ('usage_migration_bootstrap', '{}', 'now')")
        .unwrap();
    drop(lock);
    let held_until = Instant::now() + Duration::from_secs(3);
    while Instant::now() < held_until {
        assert_queue_attempts(&queue, 0);
        assert!(
            fixture.children[0].try_wait().unwrap().is_none(),
            "drain exited during migration"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    connection
        .execute_batch("delete from app_metadata where key='usage_migration_bootstrap'")
        .unwrap();
    wait_for_queue_ingest(&fixture, &queue, id);
    fixture.wait_all(Duration::from_secs(10));
}

#[test]
fn alternate_queue_detached_drain_logs_permanent_refusal() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let queue = fixture.root.join("alternate-queue");
    let hook = fixture
        .command()
        .env("CODEX_SESSIONS_COLLECTOR_QUEUE", &queue)
        .args(["codex", "notify", "--standalone"])
        .arg(&fixture.db)
        .arg(serde_json::json!({"type":"agent-turn-complete","thread-id":"permanent"}).to_string())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let hook_identity = HookIdentity::capture(&hook);
    let output = hook.wait_with_output().unwrap();
    let _workers = DetachedWorkers::for_hook(&hook_identity);
    assert!(output.status.success());
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if std::fs::read_to_string(queue.join("errors.log"))
            .unwrap_or_default()
            .contains("belongs to the viewer")
        {
            break;
        }
        assert!(Instant::now() < deadline, "detached stderr was discarded");
        std::thread::sleep(Duration::from_millis(25));
    }
    assert_queue_attempts(&queue, 0);
}

fn assert_queue_attempts(queue: &Path, expected: u64) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        // Claim/release is an atomic rename, but read_dir followed by read is
        // not a snapshot. Retry the observation if its listed name moved.
        let entries: Vec<Value> = std::fs::read_dir(queue)
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().contains(".json"))
            .filter_map(|e| std::fs::read(e.path()).ok())
            .map(|bytes| serde_json::from_slice(&bytes).unwrap())
            .collect();
        if !entries.is_empty() {
            for entry in entries {
                assert_eq!(
                    entry["attempts"], expected,
                    "database wait consumed a file attempt"
                );
            }
            return;
        }
        assert!(
            Instant::now() < deadline,
            "durable entry vanished while database unavailable"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn wait_for_queue_ingest(fixture: &Fixture, queue: &Path, id: &str) {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let count: i64 = rusqlite::Connection::open(&fixture.db)
            .unwrap()
            .query_row(
                "select count(*) from sessions where session_id=?",
                [id],
                |r| r.get(0),
            )
            .unwrap();
        let empty = !std::fs::read_dir(queue)
            .unwrap()
            .flatten()
            .any(|e| e.file_name().to_string_lossy().contains(".json"));
        if count == 1 && empty {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "database recovery did not ingest: count={count}, queue_empty={empty}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

// Hold the original process object across wait_with_output: a numeric parent
// PID alone can match an old orphan or a process that reused the hook PID.
struct HookIdentity {
    pid: u32,
    #[cfg(windows)]
    handle: std::os::windows::io::OwnedHandle,
}
impl HookIdentity {
    fn capture(child: &Child) -> Self {
        #[cfg(windows)]
        use std::os::windows::io::AsHandle;
        Self {
            pid: child.id(),
            #[cfg(windows)]
            handle: child.as_handle().try_clone_to_owned().unwrap(),
        }
    }
    #[cfg(windows)]
    fn owns_creation(&self, created: u64) -> bool {
        use std::os::windows::io::AsRawHandle;
        let (start, end) = process_times(self.handle.as_raw_handle());
        created >= start && (end == 0 || created <= end)
    }
}
#[cfg(windows)]
fn process_times(handle: windows_sys::Win32::Foundation::HANDLE) -> (u64, u64) {
    use windows_sys::Win32::{Foundation::FILETIME, System::Threading::GetProcessTimes};
    let zero = FILETIME {
        dwLowDateTime: 0,
        dwHighDateTime: 0,
    };
    let (mut start, mut end, mut kernel, mut user) = (zero, zero, zero, zero);
    // SAFETY: retained process handle and four writable FILETIME values.
    assert_ne!(
        unsafe { GetProcessTimes(handle, &mut start, &mut end, &mut kernel, &mut user) },
        0
    );
    let ticks = |t: FILETIME| ((t.dwHighDateTime as u64) << 32) | t.dwLowDateTime as u64;
    (ticks(start), ticks(end))
}

// Detached processes are observed with wait-only handles. Numeric PIDs from
// IPC or a census never confer termination rights, even after parent checks.
struct DetachedWorkers {
    #[cfg(windows)]
    handles: Vec<std::os::windows::io::OwnedHandle>,
}
impl DetachedWorkers {
    fn for_resident(fixture: &Fixture) -> Self {
        let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
        Self::for_pid(status["pid"].as_u64().unwrap() as u32)
    }
    fn for_pid(pid: u32) -> Self {
        #[cfg(windows)]
        {
            use std::os::windows::io::FromRawHandle;
            use windows_sys::Win32::System::Threading::*;
            // SAFETY: a stale/reused PID is harmless here: the handle has only
            // query/synchronization rights and is never used for termination.
            let handle = unsafe {
                OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                    0,
                    pid,
                )
            };
            Self {
                handles: if handle.is_null() {
                    Vec::new()
                } else {
                    vec![unsafe { std::os::windows::io::OwnedHandle::from_raw_handle(handle) }]
                },
            }
        }
        #[cfg(not(windows))]
        {
            let _ = pid;
            Self {}
        }
    }
    fn for_hook(hook: &HookIdentity) -> Self {
        let pid = hook.pid;
        #[cfg(windows)]
        {
            use std::os::windows::io::FromRawHandle;
            use windows_sys::Win32::System::Threading::*;
            let census_started = Instant::now();
            let output = support::test_command("powershell.exe")
                .args(["-NoProfile", "-NonInteractive", "-Command", &format!(
                    "Get-CimInstance Win32_Process -Filter 'ParentProcessId={pid}' | Select-Object -ExpandProperty ProcessId")])
                .creation_flags(0x08000000).output().unwrap();
            eprintln!(
                "worker census_ms={:.3}",
                census_started.elapsed().as_secs_f64() * 1000.0
            );
            assert!(output.status.success());
            let handles = String::from_utf8(output.stdout)
                .unwrap()
                .split_whitespace()
                .map(|p| p.parse::<u32>().unwrap())
                .filter_map(|pid| {
                    // SAFETY: numeric child PID, valid access flags; an exited
                    // child can disappear before OpenProcess and is ignored.
                    let handle = unsafe {
                        OpenProcess(
                            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
                            0,
                            pid,
                        )
                    };
                    if handle.is_null() {
                        None
                    } else {
                        // SAFETY: OpenProcess returned a new owned handle.
                        let owned = unsafe { std::os::windows::io::OwnedHandle::from_raw_handle(handle) };
                        let (created, _) = process_times(handle);
                        if !hook.owns_creation(created) {
                            eprintln!("worker census rejected stale parent PID: parent={} candidate={} created={created}", hook.pid, pid);
                            return None;
                        }
                        eprintln!("worker census retained parent={} child={} created={created}", hook.pid, pid);
                        Some(owned)
                    }
                })
                .collect();
            Self { handles }
        }
        #[cfg(not(windows))]
        {
            let _ = pid;
            Self {}
        }
    }
}
impl Drop for DetachedWorkers {
    fn drop(&mut self) {
        #[cfg(windows)]
        {
            use std::os::windows::io::AsRawHandle;
            use windows_sys::Win32::{Foundation::WAIT_OBJECT_0, System::Threading::*};
            for handle in &self.handles {
                // SAFETY: owned process handle stays valid throughout wait,
                // and wait. Status/census PIDs never grant termination authority:
                // they may have been reused before OpenProcess. Only directly
                // spawned Child objects elsewhere in this fixture can be killed.
                let finished = unsafe {
                    let result = WaitForSingleObject(handle.as_raw_handle(), 30_000);
                    result == WAIT_OBJECT_0
                };
                if !std::thread::panicking() {
                    assert!(finished, "detached hook worker leaked");
                }
            }
        }
    }
}

#[cfg(windows)]
#[test]
fn status_pid_handles_cannot_terminate_a_reused_process() {
    let _fixture_load = ordinary_fixture_lane();
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::System::Threading::TerminateProcess;
    // This process belongs to another fixture. Simulate stale IPC returning
    // its PID: even a successfully opened handle must have no kill authority.
    let mut other = Fixture::new();
    other.start("resident");
    other.ready();
    let observed = DetachedWorkers::for_pid(other.children[0].id());
    assert_eq!(observed.handles.len(), 1);
    // SAFETY: the target is our retained spawned fixture, not an actual user
    // process. A permissive regression would terminate only this owned child.
    let result = unsafe { TerminateProcess(observed.handles[0].as_raw_handle(), 1) };
    assert_eq!(result, 0, "status PID must not confer termination rights");
    assert!(other.children[0].try_wait().unwrap().is_none());
    assert!(other.cli("stop").status.success());
    other.children[0].wait().unwrap();
}

fn resident_queue_delayed_recovery(restart: bool, legacy_stale_claim: bool) {
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let queue = fixture.root.join("queue");
    let transcript = fixture.root.join("late.jsonl");
    let event = fixture.root.join("event.json");
    std::fs::write(
        &event,
        serde_json::json!({"hook_event_name":"Stop","transcript_path":transcript}).to_string(),
    )
    .unwrap();
    let output = fixture
        .command()
        .env("CODEX_SESSIONS_COLLECTOR_QUEUE", &queue)
        .args(["claude", "hook", "--db"])
        .arg(&fixture.db)
        .stdin(Stdio::from(std::fs::File::open(event).unwrap()))
        .output()
        .unwrap();
    assert!(output.status.success());
    let entry = {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let entry = std::fs::read_dir(&queue)
                .unwrap()
                .flatten()
                .map(|e| e.path())
                .find(|p| {
                    p.extension().is_some_and(|e| e == "json")
                        && std::fs::read(p)
                            .ok()
                            .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
                            .is_some_and(|v| v["attempts"] == 1)
                });
            if let Some(entry) = entry {
                break entry;
            }
            assert!(Instant::now() < deadline, "first retry never scheduled");
            std::thread::sleep(Duration::from_millis(20));
        }
    };
    if restart {
        if legacy_stale_claim {
            fixture.children[0].kill().unwrap();
            fixture.children[0].wait().unwrap();
            fixture.children.clear();
        } else {
            assert!(fixture.cli("stop").status.success());
            fixture.wait_all(Duration::from_secs(30));
        }
    }
    if legacy_stale_claim {
        let mut item: Value = serde_json::from_slice(&std::fs::read(&entry).unwrap()).unwrap();
        item.as_object_mut().unwrap().remove("database_key");
        std::fs::write(&entry, serde_json::to_vec(&item).unwrap()).unwrap();
        let claim = PathBuf::from(format!("{}.claimed-99999999", entry.display()));
        std::fs::rename(&entry, &claim).unwrap();
        std::fs::File::options()
            .write(true)
            .open(&claim)
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(601))
            .unwrap();
    }
    std::fs::copy("../samples/claude/projects/F--fixtures-claude-project/11111111-2222-4333-8444-555555555555.jsonl", &transcript).unwrap();
    if restart {
        fixture.start("resident");
        fixture.ready();
    }
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let count: i64 = rusqlite::Connection::open(&fixture.db)
            .unwrap()
            .query_row(
                "select count(*) from sessions where harness='claude'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        let empty = !std::fs::read_dir(&queue)
            .unwrap()
            .flatten()
            .any(|e| e.file_name().to_string_lossy().contains(".json"));
        if count == 1 && empty {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "resident queue has no retry owner: count={count}, empty={empty}, restart={restart}, legacy={legacy_stale_claim}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn resident_queue_retries_without_another_hook() {
    let _fixture_load = ordinary_fixture_lane();
    resident_queue_delayed_recovery(false, false);
}
#[test]
fn resident_queue_retries_after_resident_restart() {
    let _fixture_load = ordinary_fixture_lane();
    resident_queue_delayed_recovery(true, false);
}
#[test]
fn resident_queue_legacy_stale_claim_recovers_after_restart() {
    let _fixture_load = ordinary_fixture_lane();
    resident_queue_delayed_recovery(true, true);
}

#[test]
fn shared_queue_new_database_starts_its_own_retry_owner() {
    let _fixture_load = ordinary_fixture_lane();
    let mut first = Fixture::new();
    first.start("resident");
    first.ready();
    let other = Fixture::new();
    let queue = first.root.join("queue");
    let transcript = other.root.join("late.jsonl");
    let input = other.root.join("hook.json");
    std::fs::write(
        &input,
        serde_json::json!({"hook_event_name":"Stop","transcript_path":transcript}).to_string(),
    )
    .unwrap();
    assert!(
        other
            .command()
            .env("CODEX_SESSIONS_COLLECTOR_QUEUE", &queue)
            .args(["claude", "hook", "--db"])
            .arg(&other.db)
            .stdin(Stdio::from(std::fs::File::open(input).unwrap()))
            .output()
            .unwrap()
            .status
            .success()
    );
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if std::fs::read_dir(&queue)
            .unwrap()
            .flatten()
            .filter_map(|e| std::fs::read(e.path()).ok())
            .filter_map(|b| serde_json::from_slice::<Value>(&b).ok())
            .any(|v| v["attempts"] == 1)
        {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "new identity did not start a retrying resident"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let worker = DetachedWorkers::for_resident(&other);
    std::fs::copy("../samples/claude/projects/F--fixtures-claude-project/11111111-2222-4333-8444-555555555555.jsonl", transcript).unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let count: i64 = rusqlite::Connection::open(&other.db)
            .unwrap()
            .query_row(
                "select count(*) from sessions where harness='claude'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        if count == 1 {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "new identity retry stranded without another hook"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(
        rusqlite::Connection::open(&first.db)
            .unwrap()
            .query_row("select count(*) from sessions", [], |r| r.get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert!(other.cli("stop").status.success());
    drop(worker);
}

#[cfg(windows)]
struct Junction(PathBuf);
#[cfg(windows)]
impl Junction {
    fn new(path: PathBuf, target: &Path) -> Self {
        let mut command = support::test_command("cmd");

        command.creation_flags(0x08000000);
        let output = command
            .args(["/c", "mklink", "/J"])
            .arg(&path)
            .arg(target)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        Self(path)
    }
}
#[cfg(windows)]
impl Drop for Junction {
    fn drop(&mut self) {
        // Remove only the link, before Fixture's recursive cleanup.
        std::fs::remove_dir(&self.0).unwrap();
    }
}

#[test]
fn database_identity_aliases_share_every_derived_name() {
    let _fixture_load = ordinary_fixture_lane();
    let fixture = Fixture::new();
    let mut aliases = vec![
        fixture.db.clone(),
        fixture.db.parent().unwrap().join(".").join("viewer.sqlite"),
    ];
    let cwd = std::env::current_dir().unwrap();
    let mut ancestor = cwd.as_path();
    let mut relative = PathBuf::new();
    while fixture.db.strip_prefix(ancestor).is_err() {
        let Some(parent) = ancestor.parent() else {
            break;
        };
        ancestor = parent;
        relative.push("..");
    }
    if let Ok(suffix) = fixture.db.strip_prefix(ancestor) {
        relative.push(suffix);
        assert!(relative.is_relative());
        aliases.push(relative);
    }
    // Also exercise relative lookup when OS temp is on another drive.
    let output = fixture
        .command()
        .current_dir(&fixture.root)
        .args(["resident", "info", "--db", "viewer.sqlite"])
        .output()
        .unwrap();
    assert!(output.status.success());
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["database_key"],
        instance::database_key(&fixture.db).unwrap()
    );
    #[cfg(windows)]
    let _junction = {
        aliases.push(std::fs::canonicalize(&fixture.db).unwrap());
        aliases.push(PathBuf::from(fixture.db.to_string_lossy().to_uppercase()));
        aliases.push(PathBuf::from(
            fixture.db.to_string_lossy().replace('\\', "/"),
        ));
        let junction = Junction::new(fixture.root.join("alias"), &fixture.root);
        aliases.push(junction.0.join("viewer.sqlite"));
        junction
    };
    for alias in aliases {
        assert_eq!(
            instance::database_key(&alias).unwrap(),
            instance::database_key(&fixture.db).unwrap(),
            "key: {alias:?}"
        );
        assert_eq!(
            instance::lock_path(&alias).unwrap(),
            instance::lock_path(&fixture.db).unwrap(),
            "instance lock: {alias:?}"
        );
        assert_eq!(
            codex_sessions_collector::store::write_lease::lock_path(&alias).unwrap(),
            codex_sessions_collector::store::write_lease::lock_path(&fixture.db).unwrap(),
            "write lease: {alias:?}"
        );
        let _owner = instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .unwrap();
        assert!(
            instance::InstanceLock::try_acquire(&alias)
                .unwrap()
                .is_none()
        );
    }
}

#[test]
fn hook_with_another_queue_is_processed_without_stranding() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let id = "01a0aaaa-0000-7000-8000-000000000193";
    fixture.rollout(id);
    fixture.start("resident");
    fixture.ready();
    let queue = fixture.root.join("caller-queue");
    let output = fixture
        .command()
        .env("CODEX_SESSIONS_COLLECTOR_QUEUE", &queue)
        .args(["codex", "notify", "--db"])
        .arg(&fixture.db)
        .arg(serde_json::json!({"type":"agent-turn-complete","thread-id":id}).to_string())
        .output()
        .unwrap();
    assert!(output.status.success());
    fixture.await_ingested(id);
    assert_eq!(
        serde_json::from_slice::<Value>(&fixture.cli("status").stdout).unwrap()["pid"],
        fixture.children[0].id()
    );
    let deadline = Instant::now() + Duration::from_secs(3);
    while std::fs::read_dir(&queue).unwrap().flatten().any(|e| {
        e.path()
            .extension()
            .is_some_and(|e| e == "json" || e == "processing")
    }) {
        assert!(Instant::now() < deadline, "caller queue entry stranded");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[cfg(windows)]
#[test]
fn hook_database_aliases_are_drained_by_the_one_resident() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let id = "01a0aaaa-0000-7000-8000-000000000194";
    fixture.rollout(id);
    fixture.start("resident");
    fixture.ready();
    let junction = Junction::new(fixture.root.join("alias"), &fixture.root);
    for alias in [
        std::fs::canonicalize(&fixture.db).unwrap(),
        junction.0.join("viewer.sqlite"),
    ] {
        let status = fixture
            .command()
            .args(["resident", "status", "--db"])
            .arg(&alias)
            .output()
            .unwrap();
        assert!(status.status.success());
        assert_eq!(
            serde_json::from_slice::<Value>(&status.stdout).unwrap()["pid"],
            fixture.children[0].id()
        );
        let output = fixture
            .command()
            .args(["codex", "notify", "--no-drain", "--db"])
            .arg(alias)
            .arg(serde_json::json!({"type":"agent-turn-complete","thread-id":id}).to_string())
            .output()
            .unwrap();
        assert!(output.status.success());
        let entry = fixture.entries().pop().unwrap();
        let reply = exchange(
            &mut fixture.wire(),
            serde_json::json!({"v":1,"id":"alias","op":"notify","entry":entry.file_name().unwrap().to_str().unwrap()}),
        );
        assert_eq!(reply["state"], "accepted");
        fixture.await_ingested(id);
        assert_eq!(
            serde_json::from_slice::<Value>(&fixture.cli("status").stdout).unwrap()["pid"],
            fixture.children[0].id()
        );
    }
}

#[test]
fn cli_scan_and_drain_run_directly_and_wait_for_the_lease() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let id = "01a0aaaa-0000-7000-8000-000000000195";
    fixture.rollout(id);
    fixture.start("resident");
    fixture.ready();
    for action in ["scan", "drain"] {
        let lock = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .open(codex_sessions_collector::store::write_lease::lock_path(&fixture.db).unwrap())
            .unwrap();
        lock.try_lock().unwrap();
        let queue = fixture.root.join("direct-queue");
        if action == "drain" {
            let output = fixture
                .command()
                .env("CODEX_SESSIONS_COLLECTOR_QUEUE", &queue)
                .args(["codex", "notify", "--no-drain", "--db"])
                .arg(&fixture.db)
                .arg(serde_json::json!({"type":"agent-turn-complete","thread-id":id}).to_string())
                .output()
                .unwrap();
            assert!(output.status.success());
        }
        let mut command = fixture.command();
        command.env("CODEX_SESSIONS_COLLECTOR_QUEUE", &queue);
        if action == "scan" {
            command.arg("codex");
        }
        let child = command
            .arg(action)
            .args(["--json", "--force", "--no-wsl-projects", "--db"])
            .arg(&fixture.db)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        fixture.children.push(child);
        std::thread::sleep(Duration::from_millis(350));
        assert!(
            fixture
                .children
                .last_mut()
                .unwrap()
                .try_wait()
                .unwrap()
                .is_none(),
            "CLI did not wait for write lease"
        );
        let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
        assert_eq!(status["state"], "ready", "CLI executed in the resident");
        assert!(status["last_scan"].is_null());
        assert_eq!(status["work_requests"], 0);
        drop(lock);
        let deadline = Instant::now() + Duration::from_secs(12);
        loop {
            if let Some(status) = fixture.children.last_mut().unwrap().try_wait().unwrap() {
                assert!(status.success());
                break;
            }
            assert!(Instant::now() < deadline, "CLI did not finish");
            std::thread::sleep(Duration::from_millis(20));
        }
        if action == "drain" {
            assert!(
                !std::fs::read_dir(queue)
                    .unwrap()
                    .flatten()
                    .any(|e| e.path().extension().is_some_and(|e| e == "json"))
            );
        }
    }
    fixture.await_ingested(id);
}

struct Fixture {
    root: PathBuf,
    db: PathBuf,
    children: Vec<Child>,
}
impl Fixture {
    fn new() -> Self {
        use std::sync::atomic::{AtomicU64, Ordering};
        static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);
        let parent = support::temp_dir();
        let root = parent.join(format!(
            "resident-{}-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos(),
            NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&root).unwrap();
        let db = root.join("viewer.sqlite");
        support::create_viewer_database(&db);
        Self {
            root,
            db,
            children: Vec::new(),
        }
    }
    fn command(&self) -> Command {
        let mut command = support::collector();
        command.profile(&self.root);
        command.env("CODEX_SESSIONS_COLLECTOR_QUEUE", self.root.join("queue"));
        #[cfg(windows)]
        {
            command.creation_flags(0x08000000);
        }
        command
    }
    fn start(&mut self, lifetime: &str) {
        let child = self
            .command()
            .args(["serve", "--db"])
            .arg(&self.db)
            .args(["--lifetime", lifetime])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        self.children.push(child);
    }
    fn cli(&self, action: &str) -> std::process::Output {
        self.command()
            .args(["resident", action, "--db"])
            .arg(&self.db)
            .output()
            .unwrap()
    }
    fn ready(&mut self) -> Value {
        let deadline = Instant::now() + Duration::from_secs(4);
        loop {
            let output = self.cli("status");
            if output.status.success() {
                let value: Value = serde_json::from_slice(&output.stdout).unwrap();
                if value["state"] != "starting" {
                    return value;
                }
            }
            assert!(
                self.children
                    .iter_mut()
                    .any(|c| c.try_wait().unwrap().is_none()),
                "serve exited before readiness: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(
                Instant::now() < deadline,
                "resident did not become reachable"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    fn wire(&self) -> BufReader<Box<dyn Wire>> {
        BufReader::new(Box::new(self.native_stream()))
    }
    fn native_stream(&self) -> endpoint::Stream {
        #[cfg(windows)]
        let stream = endpoint::connect(
            &instance::database_key(&self.db).unwrap(),
            Duration::from_secs(2),
        )
        .unwrap();
        #[cfg(unix)]
        let stream = {
            let info: Value = serde_json::from_slice(&self.cli("info").stdout).unwrap();
            let stream =
                std::os::unix::net::UnixStream::connect(info["endpoint"].as_str().unwrap())
                    .unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            stream
                .set_write_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            stream
        };
        stream
    }
    fn wait_all(&mut self, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        for child in &mut self.children {
            loop {
                if let Some(status) = child.try_wait().unwrap() {
                    assert!(status.success(), "child {} exited {status}", child.id());
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "child {} did not exit",
                    child.id()
                );
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
}
fn exchange(wire: &mut BufReader<Box<dyn Wire>>, value: Value) -> Value {
    protocol::send(wire.get_mut(), &value).unwrap();
    let mut line = String::new();
    wire.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

impl Fixture {
    fn rollout(&self, id: &str) {
        let dir = self.root.join("codex").join("sessions");
        std::fs::create_dir_all(&dir).unwrap();
        support::write_generated_session(&dir.join(format!("rollout-{id}.jsonl")), id, 3);
    }
    fn hook(&self, id: &str, enqueue_only: bool) -> std::process::Output {
        let mut command = self.command();
        command.args(["codex", "notify", "--db"]).arg(&self.db);
        if enqueue_only {
            command.arg("--no-drain");
        }
        command.arg(serde_json::json!({"type":"agent-turn-complete","thread-id":id}).to_string());
        command.output().unwrap()
    }
    fn entries(&self) -> Vec<PathBuf> {
        std::fs::read_dir(self.root.join("queue"))
            .into_iter()
            .flatten()
            .map(Result::unwrap)
            .map(|entry| entry.path())
            .filter(|path| path.extension().is_some_and(|ext| ext == "json"))
            .collect()
    }
    fn await_ingested(&self, id: &str) {
        let deadline = Instant::now() + Duration::from_secs(12);
        loop {
            let conn = rusqlite::Connection::open(&self.db).unwrap();
            let count: i64 = conn
                .query_row(
                    "select count(*) from sessions where session_id = ?",
                    [id],
                    |row| row.get(0),
                )
                .unwrap();
            if count == 1 && self.entries().is_empty() {
                return;
            }
            assert!(Instant::now() < deadline, "hook not ingested: {id}");
            std::thread::sleep(Duration::from_millis(25));
        }
    }
}

#[test]
fn hook_ack_is_validated_and_durable_across_kill_before_claim() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let id = "01a0aaaa-0000-7000-8000-000000000182";
    fixture.rollout(id);
    fixture.start("viewer");
    fixture.ready();
    assert!(fixture.hook(id, true).status.success());
    let entry = fixture.entries().pop().unwrap();
    let bytes = std::fs::read(&entry).unwrap();
    let item: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(
        item["database_key"],
        instance::database_key(&fixture.db).unwrap()
    );
    let reply = exchange(
        &mut fixture.wire(),
        serde_json::json!({"v":1,"id":"hook","op":"notify","entry":entry.file_name().unwrap().to_str().unwrap()}),
    );
    assert_eq!(reply["event"], "ack");
    assert_eq!(reply["state"], "accepted");
    fixture.children[0].kill().unwrap();
    fixture.children[0].wait().unwrap();
    // Debounce keeps this entry unclaimed until after the acknowledgement.
    assert_eq!(std::fs::read(&entry).unwrap(), bytes);
    fixture.children.clear();
    fixture.start("resident");
    fixture.ready();
    fixture.await_ingested(id);
}

#[test]
fn hook_handoff_returns_under_one_second_and_busy_never_counts_as_attempt() {
    let _fixture_load = latency_fixture_lane();
    let mut fixture = Fixture::new();
    let id = "01a0aaaa-0000-7000-8000-000000000183";
    fixture.rollout(id);
    fixture.start("resident");
    fixture.ready();
    let conn = rusqlite::Connection::open(&fixture.db).unwrap();
    conn.execute_batch("begin immediate").unwrap();
    let start = Instant::now();
    let output = fixture.hook(id, false);
    let elapsed = start.elapsed();
    eprintln!(
        "T5 hook handoff latency_ms={:.3}",
        elapsed.as_secs_f64() * 1000.0
    );
    assert!(output.status.success());
    assert!(elapsed < Duration::from_secs(1), "{elapsed:?}");
    std::thread::sleep(Duration::from_secs(3));
    let entries = fixture.entries();
    assert_eq!(entries.len(), 1, "busy work must remain unclaimed");
    let item: Value = serde_json::from_slice(&std::fs::read(&entries[0]).unwrap()).unwrap();
    assert_eq!(item["attempts"], 0);
    conn.execute_batch("rollback").unwrap();
    fixture.await_ingested(id);
}

#[test]
fn hook_queue_partition_and_notify_path_validation() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    assert!(fixture.hook("other", true).status.success());
    let entry = fixture.entries().pop().unwrap();
    let mut item: Value = serde_json::from_slice(&std::fs::read(&entry).unwrap()).unwrap();
    item["database_key"] = serde_json::json!("another-database");
    let bytes = serde_json::to_vec(&item).unwrap();
    std::fs::write(&entry, &bytes).unwrap();
    fixture.start("resident");
    fixture.ready();
    for name in [
        "../outside.json",
        "C:\\outside.json",
        entry.file_name().unwrap().to_str().unwrap(),
    ] {
        let reply = exchange(
            &mut fixture.wire(),
            serde_json::json!({"v":1,"id":"bad","op":"notify","entry":name}),
        );
        assert_eq!(reply["event"], "ack");
        assert_eq!(reply["state"], "rejected");
    }
    assert_eq!(std::fs::read(&entry).unwrap(), bytes);
}

#[test]
fn hook_enqueue_only_starts_nothing_and_absent_resident_is_started() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let id = "01a0aaaa-0000-7000-8000-000000000184";
    fixture.rollout(id);
    assert!(fixture.hook(id, true).status.success());
    assert!(
        instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .is_some()
    );
    let output = fixture.hook(id, false);
    assert!(output.status.success());
    let deadline = Instant::now() + Duration::from_secs(6);
    while !fixture.cli("status").status.success() {
        assert!(
            Instant::now() < deadline,
            "hook fallback did not start resident"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    let worker = DetachedWorkers::for_resident(&fixture);
    fixture.await_ingested(id);
    assert!(fixture.cli("stop").status.success());
    drop(worker);
    fixture.wait_all(Duration::from_secs(5));
}

#[test]
fn hook_recovery_sweep_drains_legacy_but_leaves_foreign_partition() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let id = "01a0aaaa-0000-7000-8000-000000000185";
    fixture.rollout(id);
    fixture.start("resident");
    fixture.ready();
    assert!(fixture.hook(id, true).status.success());
    let entry = fixture.entries().pop().unwrap();
    let mut item: Value = serde_json::from_slice(&std::fs::read(&entry).unwrap()).unwrap();
    item.as_object_mut().unwrap().remove("database_key");
    std::fs::write(&entry, serde_json::to_vec(&item).unwrap()).unwrap();
    item["database_key"] = serde_json::json!("foreign");
    let foreign = fixture.root.join("queue").join("foreign.json");
    let bytes = serde_json::to_vec(&item).unwrap();
    std::fs::write(&foreign, &bytes).unwrap();
    let deadline = Instant::now() + Duration::from_secs(33);
    while entry.exists() {
        assert!(
            Instant::now() < deadline,
            "lost wakeup not recovered by sweep"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(std::fs::read(&foreign).unwrap(), bytes);
    let conn = rusqlite::Connection::open(&fixture.db).unwrap();
    assert_eq!(
        conn.query_row(
            "select count(*) from sessions where session_id = ?",
            [id],
            |r| r.get::<_, i64>(0)
        )
        .unwrap(),
        1
    );
}

#[test]
fn cli_scan_and_ingest_run_alongside_the_resident() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let id = "01a0aaaa-0000-7000-8000-000000000186";
    fixture.rollout(id);
    fixture.start("resident");
    fixture.ready();
    let output = fixture
        .command()
        .args(["codex", "scan", "--json", "--no-wsl-projects", "--db"])
        .arg(&fixture.db)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["files_parsed"], 1);
    let output = fixture
        .command()
        .args(["codex", "ingest", "--json", "--no-wsl-projects", "--db"])
        .arg(&fixture.db)
        .arg(
            fixture
                .root
                .join("codex")
                .join("sessions")
                .join(format!("rollout-{id}.jsonl")),
        )
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["files_parsed"],
        1
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&fixture.cli("status").stdout).unwrap()["pid"],
        fixture.children[0].id()
    );
}

#[test]
fn hook_notify_preempts_a_long_periodic_scan_between_writer_calls() {
    let _fixture_load = ordinary_fixture_lane();
    preempts_periodic_scan(false);
}

#[test]
fn scan_request_ingest_preempts_periodic_scan() {
    let _fixture_load = ordinary_fixture_lane();
    preempts_periodic_scan(true);
}

fn preempts_periodic_scan(viewer_ingest: bool) {
    let mut fixture = Fixture::new();
    // Forty-eight real public writer calls create a bounded long scan using
    // the production 150 ms write gap, without a test-only scheduler delay.
    let sessions = fixture.root.join("codex/sessions");
    std::fs::create_dir_all(&sessions).unwrap();
    for index in 0..48 {
        support::write_generated_session(
            &sessions.join(format!("{index:03}.jsonl")),
            &format!("01a0aaaa-0000-7000-8000-{index:012}"),
            1,
        );
    }
    let transcript = fixture.root.join("hook-only.jsonl");
    std::fs::copy(
        "../samples/claude/projects/F--fixtures-claude-project/11111111-2222-4333-8444-555555555555.jsonl",
        &transcript,
    ).unwrap();
    let settings = fixture.root.join("settings.toml");
    std::fs::write(
        &settings,
        "[scanner]\nbackground_rescan_enabled = true\nbackground_rescan_interval_seconds = 300\n",
    )
    .unwrap();
    let child = fixture
        .command()
        .args(["serve", "--db"])
        .arg(&fixture.db)
        .arg("--settings")
        .arg(&settings)
        .args([
            "--flush-sessions",
            "1",
            "--parser-workers",
            "1",
            "--no-wsl-projects",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    fixture.children.push(child);
    fixture.ready();
    let conn = rusqlite::Connection::open(&fixture.db).unwrap();
    conn.busy_timeout(Duration::from_secs(1)).unwrap();
    let count = |harness: &str| {
        conn.query_row(
            "select count(*) from sessions where harness = ? and session_id is not null",
            [harness],
            |row| row.get::<_, i64>(0),
        )
        .unwrap()
    };
    let deadline = Instant::now() + Duration::from_secs(35);
    while count("codex") == 0 {
        assert!(Instant::now() < deadline, "periodic scan never started");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(count("codex") < 48);
    let input = fixture.root.join("hook.json");
    std::fs::write(
        &input,
        serde_json::json!({"hook_event_name":"Stop","transcript_path":transcript}).to_string(),
    )
    .unwrap();
    let started = Instant::now();
    let mut viewer = None;
    if viewer_ingest {
        let mut wire = fixture.wire();
        let mut request = fixture.viewer_request("priority", "ingest");
        request["context"]["settings"] = serde_json::json!(settings);
        request["harness"] = "claude".into();
        request["path"] = serde_json::json!(transcript);
        protocol::send(wire.get_mut(), &request).unwrap();
        viewer = Some(wire);
    } else {
        let output = fixture
            .command()
            .args(["claude", "hook", "--db"])
            .arg(&fixture.db)
            .stdin(Stdio::from(std::fs::File::open(input).unwrap()))
            .output()
            .unwrap();
        assert!(output.status.success());
    }
    let handoff = started.elapsed();
    assert!(
        handoff < Duration::from_secs(1),
        "hook handoff took {handoff:?}"
    );
    while count("claude") == 0 {
        assert!(
            started.elapsed() < Duration::from_secs(3),
            "hook starved behind periodic scan"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    if let Some(mut wire) = viewer {
        let reply = next_event(&mut wire);
        assert_eq!(reply["event"], "finished", "{reply}");
        assert_eq!(reply["files_parsed"], 1);
    }
    let latency = started.elapsed();
    assert!(
        latency < Duration::from_secs(3),
        "hook ingestion took {latency:?}"
    );
    assert!(
        count("codex") < 48,
        "hook was processed after the scan's session batches"
    );
    let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
    assert_eq!(status["state"], "scanning");
    assert!(
        status["last_scan"].is_null(),
        "periodic scan already finished"
    );
    eprintln!(
        "hook during periodic scan handoff_ms={:.3} ingestion_ms={:.3}",
        handoff.as_secs_f64() * 1000.0,
        latency.as_secs_f64() * 1000.0
    );
    let deadline = Instant::now() + Duration::from_secs(20);
    while serde_json::from_slice::<Value>(&fixture.cli("status").stdout).unwrap()["last_scan"]
        .is_null()
    {
        assert!(
            Instant::now() < deadline,
            "periodic scan did not finish after hook preemption"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    assert_eq!(count("codex"), 48);
    assert!(fixture.entries().is_empty());
}

#[test]
fn resident_recovery_periodic_rescan_uses_settings_fixed_delay() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let settings = fixture.root.join("settings.toml");
    std::fs::write(
        &settings,
        "[scanner]\nbackground_rescan_enabled = true\nbackground_rescan_interval_seconds = 1\n",
    )
    .unwrap();
    let id = "01a0aaaa-0000-7000-8000-000000000187";
    fixture.rollout(id);
    let child = fixture
        .command()
        .args(["serve", "--db"])
        .arg(&fixture.db)
        .arg("--settings")
        .arg(settings)
        .args(["--no-wsl-projects"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    fixture.children.push(child);
    fixture.ready();
    let count = |id: &str| -> i64 {
        rusqlite::Connection::open(&fixture.db)
            .unwrap()
            .query_row(
                "select count(*) from sessions where session_id = ?",
                [id],
                |row| row.get(0),
            )
            .unwrap()
    };
    let deadline = Instant::now() + Duration::from_secs(34);
    while count(id) == 0 {
        assert!(Instant::now() < deadline, "initial periodic scan absent");
        std::thread::sleep(Duration::from_millis(50));
    }
    let later = "01a0aaaa-0000-7000-8000-000000000188";
    fixture.rollout(later);
    let deadline = Instant::now() + Duration::from_secs(5);
    while count(later) == 0 {
        assert!(
            Instant::now() < deadline,
            "settings interval did not schedule follow-up"
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn resident_shutdown_interrupts_a_scan_waiting_for_the_collector_lease() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.rollout("01a0aaaa-0000-7000-8000-000000000189");
    fixture.start("resident");
    fixture.ready();
    let lock_path = codex_sessions_collector::store::write_lease::lock_path(&fixture.db).unwrap();
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(lock_path)
        .unwrap();
    lock.try_lock().unwrap();
    let mut wire = fixture.wire();
    protocol::send(
        wire.get_mut(),
        &fixture.viewer_request("shutdown-scan", "scan"),
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if serde_json::from_slice::<Value>(&fixture.cli("status").stdout).unwrap()["state"]
            == "scanning"
        {
            break;
        }
        assert!(Instant::now() < deadline, "scan did not start");
        std::thread::sleep(Duration::from_millis(20));
    }
    let start = Instant::now();
    assert!(
        fixture.cli("stop").status.success(),
        "lease waiter prevented shutdown"
    );
    assert!(start.elapsed() < Duration::from_secs(5));
    drop(lock);
}

#[test]
fn scan_request_coalesces_waiters_into_one_followup_scan() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.rollout("01a0aaaa-0000-7000-8000-000000000190");
    fixture.start("resident");
    fixture.ready();
    let lock = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(codex_sessions_collector::store::write_lease::lock_path(&fixture.db).unwrap())
        .unwrap();
    lock.try_lock().unwrap();
    let mut wires = [fixture.wire(), fixture.wire(), fixture.wire()];
    protocol::send(wires[0].get_mut(), &fixture.viewer_request("first", "scan")).unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if serde_json::from_slice::<Value>(&fixture.cli("status").stdout).unwrap()["state"]
            == "scanning"
        {
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(20));
    }
    for (index, wire) in wires.iter_mut().enumerate().skip(1) {
        let mut request = fixture.viewer_request(&format!("follow-{index}"), "scan");
        request["force"] = true.into();
        protocol::send(wire.get_mut(), &request).unwrap();
    }
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if serde_json::from_slice::<Value>(&fixture.cli("status").stdout).unwrap()["work_requests"]
            == 2
        {
            break;
        }
        assert!(Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(20));
    }
    drop(lock);
    for wire in &mut wires {
        let deadline = Instant::now() + Duration::from_secs(8);
        let mut line = Vec::new();
        loop {
            match protocol::read_frame(wire, &mut line, protocol::MAX_EVENT_BYTES) {
                Ok(protocol::Frame::Complete) => {
                    let event: Value = serde_json::from_slice(&line).unwrap();
                    line.clear();
                    assert_ne!(event["event"], "error", "{event}");
                    if event["event"] == "done" {
                        break;
                    }
                }
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                    ) => {}
                Ok(protocol::Frame::Partial) => (),
                other => panic!("scan response: {:?}", other.err()),
            }
            assert!(Instant::now() < deadline);
        }
    }
    let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
    assert_eq!(
        status["last_scan"]["sequence"], 2,
        "waiters require one follow-up scan"
    );
}
impl Drop for Fixture {
    fn drop(&mut self) {
        // A detached resident can own this fixture as its current directory.
        // Retain a process handle before shutdown and wait for process exit,
        // not merely instance-lock release, before removing the fixture.
        let resident = serde_json::from_slice::<Value>(&self.cli("status").stdout)
            .ok()
            .and_then(|v| v["pid"].as_u64())
            .map(|pid| DetachedWorkers::for_pid(pid as u32));
        // Includes residents started by this fixture's hook fallback.
        let _ = self.cli("stop");
        for child in &mut self.children {
            if child.try_wait().unwrap().is_none() {
                child.kill().unwrap();
            }
            child.wait().unwrap();
        }
        drop(resident);
        // Only this test's freshly allocated root; never follow reparse points.
        fn no_links(path: &Path) -> bool {
            std::fs::read_dir(path).unwrap().all(|entry| {
                let entry = entry.unwrap();
                let metadata = std::fs::symlink_metadata(entry.path()).unwrap();
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if metadata.file_attributes() & 0x400 != 0 {
                        return false;
                    }
                }
                !metadata.file_type().is_symlink()
                    && (!metadata.is_dir() || no_links(&entry.path()))
            })
        }
        assert!(no_links(&self.root));
        if std::thread::panicking() {
            eprintln!("failed fixture retained at {}", self.root.display());
            return;
        }
        if let Err(error) = std::fs::remove_dir_all(&self.root) {
            eprintln!("fixture cleanup left {}: {error}", self.root.display());
            assert!(std::thread::panicking(), "fixture cleanup failed");
        }
    }
}

#[test]
fn protocol_connect_close_preserves_endpoint_and_resident() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let key = instance::database_key(&fixture.db).unwrap();
    for _ in 0..16 {
        // A newly created instance permits connect before ConnectNamedPipe;
        // a reset instance requires accept to be posted before reconnect.
        let mut listener = endpoint::Listener::bind(&key).unwrap();
        // Close before accept starts: on Windows this deterministically puts
        // the pending instance into ERROR_NO_DATA, rather than racing accept.
        drop(endpoint::connect(&key, Duration::from_secs(2)).unwrap());
        match listener.accept() {
            Ok(stream) => drop(stream),
            Err(error) => assert!(matches!(
                error.kind(),
                std::io::ErrorKind::ConnectionAborted | std::io::ErrorKind::BrokenPipe
            )),
        }
        assert!(
            endpoint::Listener::bind(&key).is_err(),
            "a disconnected client must not release first-instance ownership"
        );
    }
    fixture.start("resident");
    let pid = fixture.ready()["pid"].clone();
    for n in 0..16 {
        drop(fixture.wire());
        let reply = exchange(
            &mut fixture.wire(),
            serde_json::json!({"v":1,"id":format!("after-close-{n}"),"op":"hello","client":"cli"}),
        );
        assert_eq!(reply["event"], "hello");
        assert_eq!(reply["pid"], pid);
    }
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
}

#[test]
fn single_instance_eight_concurrent_starters() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let start = Instant::now();
    for _ in 0..8 {
        fixture.start("resident");
    }
    let status = fixture.ready();
    let deadline = start + Duration::from_secs(6);
    loop {
        let mut alive = Vec::new();
        for child in &mut fixture.children {
            match child.try_wait().unwrap() {
                Some(status) => assert!(status.success(), "loser exited {status}"),
                None => alive.push(child.id()),
            }
        }
        if alive.len() == 1 {
            assert_eq!(status["pid"].as_u64().unwrap(), u64::from(alive[0]));
            break;
        }
        assert!(
            Instant::now() < deadline,
            "{} starters still running",
            alive.len()
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(fixture.db.with_extension("sqlite.collector.lock"))
        .unwrap();
    assert!(matches!(
        lock.try_lock(),
        Err(std::fs::TryLockError::WouldBlock)
    ));
    for n in 0..8 {
        let hello = exchange(
            &mut fixture.wire(),
            serde_json::json!({"v":1,"id":format!("hello-{n}"),"op":"hello","client":"cli"}),
        );
        assert_eq!(hello["pid"], status["pid"]);
    }
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
    lock.try_lock().unwrap();
}

#[cfg(windows)]
#[test]
fn single_instance_database_key_uses_absolute_case_normalization() {
    let _fixture_load = ordinary_fixture_lane();
    // Independently computed with .NET SHA256 over UTF-8 c:\viewer\db.sqlite.
    assert_eq!(
        instance::database_key(Path::new("C:/Viewer/DB.sqlite")).unwrap(),
        "3696a1c048ed0f03"
    );
    assert_eq!(
        instance::database_key(Path::new("c:\\viewer\\db.sqlite")).unwrap(),
        "3696a1c048ed0f03"
    );
    let relative = Path::new(".").join("resident-identity-uncreated.sqlite");
    let absolute = std::env::current_dir()
        .unwrap()
        .join("resident-identity-uncreated.sqlite");
    assert_eq!(
        instance::database_key(&relative).unwrap(),
        instance::database_key(&absolute).unwrap()
    );
}

#[test]
fn bridge_protocol_wire_version_and_validation() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.start("viewer");
    fixture.ready();
    let mut wire = fixture.wire();
    let hello = exchange(
        &mut wire,
        serde_json::json!({"v":1,"id":"h","op":"hello","client":"viewer","future_field":true}),
    );
    assert_eq!(hello["event"], "hello");
    assert_eq!(hello["id"], "h");
    assert_eq!(hello["protocol"], 1);
    assert_eq!(hello["schema"], 30);
    assert_eq!(hello["contract"], 2);
    assert!(hello["parsers"]["codex"].as_i64().unwrap() > 0);
    assert!(hello["parsers"]["claude"].as_i64().unwrap() > 0);
    assert_eq!(hello["collector_version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(hello["lifetime"], "viewer");
    let unknown = exchange(
        &mut wire,
        serde_json::json!({"v":1,"id":"u","op":"not_an_operation"}),
    );
    assert_eq!(unknown["code"], "bad_request");
    let upgraded = exchange(
        &mut wire,
        serde_json::json!({"v":1,"id":"h2","op":"hello","client":"launcher","lifetime":"resident"}),
    );
    assert_eq!(upgraded["lifetime"], "resident");
    let v2 = exchange(
        &mut wire,
        serde_json::json!({"v":2,"id":"v2","op":"status"}),
    );
    assert_eq!(v2["v"], 1);
    assert_eq!(v2["id"], "v2");
    assert_eq!(v2["code"], "unsupported_version");
    let mut byte = [0];
    assert_eq!(
        wire.read(&mut byte).unwrap(),
        0,
        "unsupported version closes connection"
    );
    drop(wire);
    let mut oversized = fixture.wire();
    oversized
        .get_mut()
        .write_all(&vec![b' '; protocol::MAX_REQUEST_BYTES + 1])
        .unwrap();
    let mut line = String::new();
    oversized.read_line(&mut line).unwrap();
    let error: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(error["code"], "bad_request");
    drop(oversized);
    let mut invalid = fixture.wire();
    invalid.get_mut().write_all(b"{bad json}\n").unwrap();
    let mut line = String::new();
    invalid.read_line(&mut line).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&line).unwrap()["code"],
        "bad_request"
    );
    drop(invalid);
    let idle = fixture.wire();
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
    drop(idle);
}

#[test]
fn single_instance_hard_kill_releases_lock_and_restarts() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let first = fixture.children[0].id();
    fixture.children[0].kill().unwrap();
    fixture.children[0].wait().unwrap();
    fixture.start("resident");
    assert_ne!(fixture.ready()["pid"], u64::from(first));
    assert!(fixture.cli("stop").status.success());
    let child = fixture.children.last_mut().unwrap();
    assert!(child.wait().unwrap().success());
}

#[test]
fn single_instance_waits_for_lock_when_no_endpoint_is_available() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let lock = instance::InstanceLock::try_acquire(&fixture.db)
        .unwrap()
        .unwrap();
    fixture.start("resident");
    std::thread::sleep(Duration::from_millis(5200));
    assert!(
        fixture.children[0].try_wait().unwrap().is_none(),
        "starter must wait beyond the 5 s hello window"
    );
    drop(lock);
    assert_eq!(fixture.ready()["state"], "ready");
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
}

#[test]
fn protocol_missing_database_waits_without_creating_it() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    std::fs::remove_file(&fixture.db).unwrap();
    fixture.start("resident");
    assert_eq!(fixture.ready()["state"], "waiting_for_database");
    assert!(!fixture.db.exists());
    support::create_viewer_database(&fixture.db);
    let deadline = Instant::now() + Duration::from_secs(32);
    loop {
        let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
        if status["state"] == "ready" {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "missing database was not retried"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
}

#[test]
fn protocol_viewer_idle_exit_after_last_viewer_disconnects() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.start("viewer");
    fixture.ready();
    let mut viewer = fixture.wire();
    assert_eq!(
        exchange(
            &mut viewer,
            serde_json::json!({"v":1,"id":"viewer","op":"hello","client":"viewer"})
        )["lifetime"],
        "viewer"
    );
    // A live viewer must suppress idle exit even beyond the startup idle window.
    std::thread::sleep(Duration::from_secs(31));
    assert!(fixture.children[0].try_wait().unwrap().is_none());
    drop(viewer);
    let disconnected = Instant::now();
    std::thread::sleep(Duration::from_secs(29));
    assert!(
        fixture.children[0].try_wait().unwrap().is_none(),
        "exited before the 30 s disconnect grace"
    );
    fixture.wait_all(Duration::from_secs(4));
    assert!(disconnected.elapsed() >= Duration::from_secs(30));
    assert!(
        instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .is_some()
    );
}

#[test]
fn protocol_pending_migration_recovers_without_writing() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    support::insert_running_usage_migration(&fixture.db);
    fixture.start("resident");
    assert_eq!(fixture.ready()["state"], "waiting_for_database");
    let connection = rusqlite::Connection::open(&fixture.db).unwrap();
    connection
        .execute("update maintenance_jobs set state='succeeded'", [])
        .unwrap();
    drop(connection);
    let deadline = Instant::now() + Duration::from_secs(12);
    loop {
        let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
        if status["state"] == "ready" {
            // Opening the worker records WAL configuration as a schema hold in S2b.
            // No collection has run before the delayed initial scan.
            assert_eq!(
                rusqlite::Connection::open(&fixture.db)
                    .unwrap()
                    .query_row("select count(*) from sessions", [], |row| row
                        .get::<_, i64>(0))
                    .unwrap(),
                0
            );
            break;
        }
        assert!(Instant::now() < deadline, "migration was not retried");
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
}

#[test]
fn protocol_saturated_clients_do_not_break_accept_or_shutdown() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let mut clients = Vec::new();
    for _ in 0..12 {
        clients.push(fixture.wire());
    }
    // New connections beyond capacity are closed. Release all test-owned clients;
    // a control client must then be admitted and shutdown must still join everyone.
    drop(clients);
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if fixture.cli("stop").status.success() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "accept loop failed under saturation"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    fixture.wait_all(Duration::from_secs(5));
}

#[test]
fn protocol_shutdown_interrupts_a_continuously_partial_request() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let mut wire = fixture.wire();
    wire.get_mut().write_all(b" ").unwrap();
    let writer = std::thread::spawn(move || {
        let until = Instant::now() + Duration::from_secs(7);
        while Instant::now() < until {
            if wire.get_mut().write_all(b" ").is_err() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    });
    let start = Instant::now();
    let stop = fixture.cli("stop");
    let elapsed = start.elapsed();
    writer.join().unwrap();
    assert!(stop.status.success());
    fixture.wait_all(Duration::from_secs(1));
    assert!(
        elapsed < Duration::from_secs(5),
        "shutdown took {elapsed:?} while a partial request kept arriving"
    );
}

#[test]
fn protocol_running_resident_newer_schema_exits_three() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let stderr = fixture.root.join("resident.stderr");
    let child = fixture
        .command()
        .args(["serve", "--db"])
        .arg(&fixture.db)
        .args(["--lifetime", "resident"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(std::fs::File::create(&stderr).unwrap())
        .spawn()
        .unwrap();
    fixture.children.push(child);
    fixture.ready();
    let id = "01a0aaaa-0000-7000-8000-000000000200";
    fixture.rollout(id);
    rusqlite::Connection::open(&fixture.db)
        .unwrap()
        .execute_batch(
            "insert into schema_version values (999, '999_future.sql', 'x', 'now', 1, null)",
        )
        .unwrap();
    assert!(fixture.hook(id, true).status.success());
    let mut wire = fixture.wire();
    let reply = exchange(
        &mut wire,
        serde_json::json!({
            "v":1, "id":"future-schema", "op":"notify", "database_key":instance::database_key(&fixture.db).unwrap(),
            "queue":instance::identity_path(&fixture.root.join("queue")).unwrap(), "entry":fixture.entries()[0].file_name().unwrap().to_string_lossy()
        }),
    );
    drop(wire);
    assert_eq!(reply["state"], "accepted", "{reply}");
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if let Some(status) = fixture.children[0].try_wait().unwrap() {
            assert_eq!(status.code(), Some(3));
            break;
        }
        assert!(Instant::now() < deadline, "outdated resident stayed alive");
        std::thread::sleep(Duration::from_millis(10));
    }
    let diagnostic = std::fs::read_to_string(stderr).unwrap();
    assert!(diagnostic.contains("schema version 999"), "{diagnostic}");
    assert_queue_attempts(&fixture.root.join("queue"), 0);
    assert!(
        instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .is_some()
    );
}

#[test]
fn protocol_newer_schema_exits_three() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let conn = rusqlite::Connection::open(&fixture.db).unwrap();
    conn.execute(
        "insert into schema_version values (31, 'future.sql','future','now',1,null)",
        [],
    )
    .unwrap();
    drop(conn);
    fixture.start("resident");
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = fixture.children[0].try_wait().unwrap() {
            assert_eq!(status.code(), Some(3));
            break;
        }
        assert!(Instant::now() < deadline, "outdated resident stayed alive");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .is_some()
    );
}

#[cfg(windows)]
#[test]
fn protocol_windows_first_instance_security_and_handle_cleanup() {
    let _fixture_load = ordinary_fixture_lane();
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::{
        Foundation::*,
        Security::{Authorization::*, *},
        Storage::FileSystem::*,
        System::Threading::*,
    };
    if std::env::var_os("CXV_HANDLE_CHECK_CHILD").is_none() {
        let output = support::test_command(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "protocol_windows_first_instance_security_and_handle_cleanup",
                "--nocapture",
            ])
            .env("CXV_HANDLE_CHECK_CHILD", "1")
            .creation_flags(0x08000000)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "isolated handle check: {} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }
    let fixture = Fixture::new();
    let key = instance::database_key(&fixture.db).unwrap();
    // Obtain the account SID independently from the actual process token.
    // SAFETY: token and variable-sized TOKEN_USER stay owned through SID conversion.
    let account_sid = unsafe {
        let mut raw = std::ptr::null_mut();
        assert_ne!(
            OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut raw),
            0
        );
        let token = <std::os::windows::io::OwnedHandle as std::os::windows::io::FromRawHandle>::from_raw_handle(raw);
        let mut size = 0;
        GetTokenInformation(
            token.as_raw_handle(),
            TokenUser,
            std::ptr::null_mut(),
            0,
            &mut size,
        );
        assert!(size > 0);
        let mut buffer = vec![0usize; (size as usize).div_ceil(size_of::<usize>())];
        assert_ne!(
            GetTokenInformation(
                token.as_raw_handle(),
                TokenUser,
                buffer.as_mut_ptr().cast(),
                size,
                &mut size
            ),
            0
        );
        let user = &*buffer.as_ptr().cast::<TOKEN_USER>();
        let mut text = std::ptr::null_mut();
        assert_ne!(ConvertSidToStringSidW(user.User.Sid, &mut text), 0);
        let mut length = 0;
        while *text.add(length) != 0 {
            length += 1;
        }
        let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, length));
        LocalFree(text.cast());
        sid
    };
    // Inspect the actual kernel object's descriptor, rather than its input SDDL.
    let mut before = 0;
    // SAFETY: process pseudohandle is valid and before is writable.
    assert_ne!(
        unsafe { GetProcessHandleCount(GetCurrentProcess(), &mut before) },
        0
    );
    for iteration in 0..33 {
        let _lock = instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .unwrap();
        let listener = endpoint::Listener::bind(&key).unwrap();
        assert!(
            endpoint::Listener::bind(&key).is_err(),
            "first-instance guard must reject a second server"
        );
        let name: Vec<u16> = endpoint::endpoint_name(&key)
            .unwrap()
            .encode_utf16()
            .chain(Some(0))
            .collect();
        // Open with READ_CONTROL so GetSecurityInfo examines the live pipe.
        // SAFETY: valid NUL-terminated name, returned owned handle closed below.
        let raw = unsafe {
            CreateFileW(
                name.as_ptr(),
                READ_CONTROL,
                0,
                std::ptr::null(),
                OPEN_EXISTING,
                0,
                std::ptr::null_mut(),
            )
        };
        assert_ne!(raw, INVALID_HANDLE_VALUE);
        // SAFETY: raw is newly owned, and remains valid until File drop.
        let file =
            unsafe { <std::fs::File as std::os::windows::io::FromRawHandle>::from_raw_handle(raw) };
        let mut descriptor = std::ptr::null_mut();
        // SAFETY: all optional outputs null except descriptor, allocated by this API.
        let result = unsafe {
            GetSecurityInfo(
                file.as_raw_handle(),
                SE_KERNEL_OBJECT,
                DACL_SECURITY_INFORMATION,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut descriptor,
            )
        };
        assert_eq!(result, 0);
        let mut text = std::ptr::null_mut();
        // SAFETY: descriptor is valid until LocalFree; text is an out pointer.
        assert_ne!(
            unsafe {
                ConvertSecurityDescriptorToStringSecurityDescriptorW(
                    descriptor,
                    SDDL_REVISION_1,
                    DACL_SECURITY_INFORMATION,
                    &mut text,
                    std::ptr::null_mut(),
                )
            },
            0
        );
        let mut len = 0;
        // SAFETY: the API returns a NUL-terminated UTF-16 string.
        let sddl = unsafe {
            while *text.add(len) != 0 {
                len += 1;
            }
            String::from_utf16_lossy(std::slice::from_raw_parts(text, len))
        };
        // SAFETY: free exactly the allocations returned by the security APIs.
        unsafe {
            LocalFree(text.cast());
            LocalFree(descriptor);
        }
        assert!(sddl.starts_with("D:P"), "DACL must be protected: {sddl}");
        assert_eq!(
            sddl.matches("(A;").count(),
            2,
            "only user and SYSTEM grants: {sddl}"
        );
        assert!(sddl.contains(";;;SY)"));
        assert!(
            sddl.contains(&format!(";;;{account_sid})")),
            "current account SID: {sddl}"
        );
        assert!(!sddl.contains(";;;WD)") && !sddl.contains(";;;AU)"));
        drop(file);
        drop(listener);
        drop(_lock);
        if iteration == 0 {
            // Security APIs load Windows DLLs on first use. Measure after that
            // initialization, in this isolated process with no sibling test activity.
            // SAFETY: process pseudohandle is valid and before is writable.
            assert_ne!(
                unsafe { GetProcessHandleCount(GetCurrentProcess(), &mut before) },
                0
            );
        }
    }
    let mut after = 0;
    // SAFETY: process pseudohandle is valid and after is writable.
    assert_ne!(
        unsafe { GetProcessHandleCount(GetCurrentProcess(), &mut after) },
        0
    );
    assert_eq!(after, before, "32 bind/security/drop cycles leaked handles");
}

#[test]
fn protocol_cli_info_status_shutdown() {
    let _fixture_load = ordinary_fixture_lane();
    let mut fixture = Fixture::new();
    let info = fixture.cli("info");
    assert!(
        info.status.success(),
        "resident info failed: {}",
        String::from_utf8_lossy(&info.stderr)
    );
    let info: Value = serde_json::from_slice(&info.stdout).unwrap();
    assert_eq!(info["database_key"].as_str().unwrap().len(), 16);
    assert!(!info["endpoint"].as_str().unwrap().is_empty());
    fixture.start("resident");
    let status = fixture.ready();
    assert_eq!(status["v"], 1);
    assert_eq!(status["event"], "status");
    assert_eq!(status["state"], "ready");
    assert_eq!(status["queue"]["pending"], 0);
    // Opening the worker records WAL configuration as a schema hold in S2b.
    // No collection has run before the delayed initial scan.
    assert_eq!(
        rusqlite::Connection::open(&fixture.db)
            .unwrap()
            .query_row("select count(*) from sessions", [], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
    assert!(!fixture.cli("status").status.success());
    assert!(fixture.cli("stop").status.success(), "stop is idempotent");
}

// Windows named pipes can disconnect before the shutdown acknowledgement is
// consumed. The instance lock, not delivery of that last frame, proves stop.
#[cfg(windows)]
fn shutdown_peer(fixture: &Fixture, read_shutdown: bool) -> std::thread::JoinHandle<()> {
    let lock = instance::InstanceLock::try_acquire(&fixture.db)
        .unwrap()
        .unwrap();
    let key = instance::database_key(&fixture.db).unwrap();
    let mut listener = endpoint::Listener::bind(&key).unwrap();
    std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let stream = loop {
            match listener.accept() {
                Ok(stream) => break stream,
                Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {
                    assert!(Instant::now() < deadline);
                }
                Err(e) => panic!("shutdown peer accept: {e}"),
            }
        };
        let mut wire = BufReader::new(stream);
        if read_shutdown {
            let shutdown = next_event(&mut wire);
            assert_eq!(shutdown["op"], "shutdown");
        }
        // Deliberately send no reply, as if the process exited at this boundary.
        drop(wire);
        drop(listener);
        drop(lock);
    })
}

#[cfg(windows)]
#[test]
fn resident_stop_succeeds_after_shutdown_reply_is_lost() {
    let _fixture_load = ordinary_fixture_lane();
    let fixture = Fixture::new();
    let peer = shutdown_peer(&fixture, true);
    let result = fixture.cli("stop");
    peer.join().unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(
        instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .is_some()
    );
    assert!(
        fixture.cli("stop").status.success(),
        "already stopped is success"
    );
}

#[cfg(windows)]
#[test]
fn resident_stop_succeeds_if_peer_exits_before_shutdown_write() {
    let _fixture_load = ordinary_fixture_lane();
    let fixture = Fixture::new();
    let peer = shutdown_peer(&fixture, false);
    let result = fixture.cli("stop");
    peer.join().unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(
        instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .is_some()
    );
}

#[cfg(windows)]
#[test]
fn resident_stop_times_out_if_disconnected_instance_stays_locked() {
    let _fixture_load = ordinary_fixture_lane();
    let fixture = Fixture::new();
    let lock = instance::InstanceLock::try_acquire(&fixture.db)
        .unwrap()
        .unwrap();
    let key = instance::database_key(&fixture.db).unwrap();
    let mut listener = endpoint::Listener::bind(&key).unwrap();
    let peer = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let stream = loop {
            match listener.accept() {
                Ok(stream) => break stream,
                Err(e) if e.kind() == std::io::ErrorKind::TimedOut => {
                    assert!(Instant::now() < deadline)
                }
                Err(e) => panic!("shutdown peer accept: {e}"),
            }
        };
        let mut wire = BufReader::new(stream);
        assert_eq!(next_event(&mut wire)["op"], "shutdown");
        drop(wire);
        drop(listener);
    });
    let started = Instant::now();
    let result = fixture.cli("stop");
    peer.join().unwrap();
    drop(lock);
    assert!(
        !result.status.success(),
        "a live instance must not be reported stopped"
    );
    assert!(
        String::from_utf8_lossy(&result.stderr)
            .contains("resident did not release its instance lock"),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
    assert!(started.elapsed() >= Duration::from_secs(9));
    assert!(started.elapsed() < Duration::from_secs(13));
}
