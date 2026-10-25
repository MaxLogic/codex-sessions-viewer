//! Codex notify and Claude Code hook collection (T-121), through the real
//! executable: hooks queue work, drains ingest it, and scans reconcile.

mod support;
use support::Command;

use std::path::{Path, PathBuf};
use std::process::{Output, Stdio};
use std::time::{Duration, Instant};

use rusqlite::Connection;
use serde_json::{Value, json};

use support::{TempDir, collector, viewer_database};

const CLAUDE_SESSION: &str = "11111111-2222-4333-8444-555555555555";

fn open(path: &Path) -> Connection {
    let conn = Connection::open(path).unwrap();
    conn.busy_timeout(Duration::from_secs(30)).unwrap();
    conn
}

fn count(db: &Path, sql: &str) -> i64 {
    open(db).query_row(sql, [], |row| row.get(0)).unwrap()
}

struct Env {
    temp: TempDir,
    db: PathBuf,
    queue: PathBuf,
    codex_home: PathBuf,
    claude_root: PathBuf,
}

impl Env {
    fn new(label: &str) -> Self {
        let temp = TempDir::new(label);
        let db = viewer_database(&temp);
        let queue = temp.path().join("queue");
        let codex_home = support::codex_home(&temp, &[]);
        let claude_root = temp.path().join("claude-projects");
        copy_tree(Path::new("../samples/claude/projects"), &claude_root);
        Self {
            temp,
            db,
            queue,
            codex_home,
            claude_root,
        }
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = collector();
        command.profile(self.temp.path());
        command
            .args(args)
            .env("CODEX_SESSIONS_COLLECTOR_QUEUE", &self.queue)
            .arg("--db")
            .arg(&self.db)
            .arg("--windows-root")
            .arg(&self.codex_home)
            .args(["--wsl-root", "", "--no-wsl-projects", "--claude-root"])
            .arg(&self.claude_root)
            .arg("--wsl-unc-root")
            .arg(self.temp.path().join("wsl-root"));
        #[cfg(windows)]
        {
            command.creation_flags(0x08000000);
        }
        command
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command(args).output().unwrap()
    }

    fn claude_hook(&self, event: &Value, drain: bool) -> Output {
        let mut args = vec!["claude", "hook"];
        if !drain {
            args.push("--no-drain");
        }
        let child = self
            .command(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn_with_input(&event.to_string())
            .unwrap();
        child.wait_with_output().unwrap()
    }

    fn codex_hook(&self, input: &str, options: &[&str]) -> Output {
        self.command(&["codex", "hook"])
            .args(options)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn_with_input(input)
            .unwrap()
            .wait_with_output()
            .unwrap()
    }

    fn codex_event(&self, id: &str, event: &str) -> Value {
        json!({
            "session_id": id,
            "turn_id": "turn-1",
            "cwd": self.temp.path().to_string_lossy(),
            "transcript_path": self.codex_home.join("transcript.jsonl").to_string_lossy(),
            "hook_event_name": event,
            "stop_hook_active": false,
        })
    }

    fn drain(&self) -> Value {
        let output = self.run(&["drain", "--no-wait"]);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).unwrap()
    }

    fn transcript(&self) -> PathBuf {
        self.claude_root
            .join("F--fixtures-claude-project")
            .join(format!("{CLAUDE_SESSION}.jsonl"))
    }

    fn queued(&self) -> Vec<PathBuf> {
        std::fs::read_dir(&self.queue)
            .map(|entries| {
                entries
                    .filter_map(Result::ok)
                    .map(|entry| entry.path())
                    .filter(|path| path.to_string_lossy().contains(".json"))
                    .collect()
            })
            .unwrap_or_default()
    }

    fn claude_event(&self, event: &str) -> Value {
        json!({
            "session_id": CLAUDE_SESSION,
            "transcript_path": self.transcript().to_string_lossy(),
            "cwd": "C:\\nonexistent\\claude-project",
            "hook_event_name": event,
        })
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let output = self.run(&["resident", "stop"]);
        assert!(
            output.status.success(),
            "test-owned resident did not stop: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), target).unwrap();
        }
    }
}

/// Wait for detached drains started by hooks to finish their work.
fn wait_until(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(60);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

// ---------------------------------------------------------------------------
// Claude Code

#[test]
fn a_claude_stop_hook_ingests_the_transcript_and_its_subagents() {
    let env = Env::new("claude-hook");
    let output = env.claude_hook(&env.claude_event("Stop"), true);
    assert!(output.status.success());
    wait_until("the drain", || {
        env.queued().is_empty()
            && count(
                &env.db,
                "select count(*) from sessions where harness = 'claude'",
            ) == 2
    });
    let conn = open(&env.db);
    let (title, messages, tools, input, cached, write, output_tokens): (
        String,
        i64,
        i64,
        i64,
        i64,
        i64,
        i64,
    ) = conn
        .query_row(
            "select title, message_count, tool_call_count, input_tokens, cached_input_tokens,
               (select sum(cache_write_input_tokens) from usage_events where session_row_id = s.id),
               output_tokens
             from sessions s where harness = 'claude' and session_id = ?",
            [CLAUDE_SESSION],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                ))
            },
        )
        .unwrap();
    assert_eq!(title, "Fix flaky claude fixture");
    assert_eq!(messages, 7);
    assert_eq!(tools, 2);
    // One usage event per response, input including cache reads and writes.
    assert_eq!(
        count(
            &env.db,
            "select count(*) from usage_events e join sessions s on s.id = e.session_row_id where s.session_id = '11111111-2222-4333-8444-555555555555'"
        ),
        3
    );
    assert_eq!((input, cached, write, output_tokens), (4018, 3700, 300, 92));
    let units: String = conn
        .query_row(
            "select group_concat(billable_units_json, ';') from usage_event_inputs i join sessions s on s.id = i.session_row_id where s.session_id = ?",
            [CLAUDE_SESSION],
            |row| row.get(0),
        )
        .unwrap();
    assert!(units.contains("cache_write_5m_input_tokens") && units.contains("web_search_requests"));
    let provider: String = conn
        .query_row(
            "select distinct provider from usage_event_inputs",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(provider, "anthropic");
    // The subagent is its own session, linked to its parent.
    let (sub_parent, sub_source): (String, String) = conn
        .query_row(
            "select parent_thread_id, thread_source from sessions where session_id = ?",
            [format!("{CLAUDE_SESSION}:agent-a1b2c3")],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(
        (sub_parent.as_str(), sub_source.as_str()),
        (CLAUDE_SESSION, "subagent")
    );
    // Unmodeled records and usage keys are kept as evidence.
    let extra: String = conn
        .query_row(
            "select extra_json from session_source_extras e join sessions s on s.id = e.session_row_id where s.session_id = ?",
            [CLAUDE_SESSION],
            |row| row.get(0),
        )
        .unwrap();
    let extra: Value = serde_json::from_str(&extra).unwrap();
    assert_eq!(extra["unmodeled_record_types"]["brand-new-record"], 1);
    assert!(
        extra["unmodeled_usage_fields"]
            .as_array()
            .unwrap()
            .iter()
            .any(|v| v == "inference_geo")
    );
    // Messages are searchable, and usage is not priced by the collector.
    assert_eq!(
        count(
            &env.db,
            "select count(*) from message_search where message_search match 'race'"
        ),
        1
    );
    assert_eq!(
        count(
            &env.db,
            "select count(*) from usage_session_daily where cost_status <> 'unknown'"
        ),
        0
    );
}

#[test]
fn absent_usage_stays_unknown_rather_than_zero() {
    let env = Env::new("claude-absent-usage");
    let transcript = env
        .claude_root
        .join("F--fixtures-claude-project")
        .join("parity-rich-001.jsonl");
    let output = env.run(&["claude", "ingest", &transcript.to_string_lossy()]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let (input, total): (Option<i64>, Option<i64>) = open(&env.db)
        .query_row(
            "select input_tokens, total_tokens from sessions where harness = 'claude' and session_id = 'parity-rich-001'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!((input, total), (None, None));
}

#[test]
fn claude_and_codex_sessions_with_the_same_id_do_not_collide() {
    let env = Env::new("identity");
    std::fs::copy(
        "../samples/collector-parity/sessions/rich_session.jsonl",
        support::day_folder(&env.codex_home).join("rich_session.jsonl"),
    )
    .unwrap();
    assert!(env.run(&["codex", "scan"]).status.success());
    let output = env.run(&["claude", "scan"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    // Rescanning either side must not merge or delete the other.
    assert!(env.run(&["codex", "scan", "--force"]).status.success());
    let rows = support::rows(
        &open(&env.db),
        "select id, harness from sessions where session_id = 'parity-rich-001' order by harness",
    );
    assert_eq!(rows.len(), 2, "{rows:?}");
    assert_eq!(rows[0]["harness"], "claude");
    assert_eq!(rows[0]["id"], "claude:session:parity-rich-001");
    assert_eq!(rows[1]["id"], "session:parity-rich-001");
    assert_eq!(
        count(
            &env.db,
            "select count(*) from messages where session_id = 'session:parity-rich-001'"
        ),
        12
    );
}

#[test]
fn duplicate_and_simultaneous_hooks_converge_on_one_copy() {
    let env = Env::new("claude-duplicates");
    for _ in 0..3 {
        assert!(
            env.claude_hook(&env.claude_event("Stop"), false)
                .status
                .success()
        );
    }
    assert!(
        env.claude_hook(&env.claude_event("SessionEnd"), false)
            .status
            .success()
    );
    assert_eq!(env.queued().len(), 4);
    // Several drains race for the same queue.
    let drains: Vec<std::process::Child> = (0..3)
        .map(|_| {
            env.command(&["drain"])
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap()
        })
        .collect();
    // Reap every caller before asserting, including on a contention failure.
    let outputs: Vec<_> = drains
        .into_iter()
        .map(|drain| drain.wait_with_output().unwrap())
        .collect();
    for output in outputs {
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    assert!(env.queued().is_empty());
    assert_eq!(
        count(
            &env.db,
            "select count(*) from sessions where harness = 'claude'"
        ),
        2
    );
    assert_eq!(count(&env.db, "select count(*) from usage_events"), 4);
}

#[test]
fn a_transcript_caught_mid_write_is_retried_until_complete() {
    let env = Env::new("claude-append");
    let path = env.transcript();
    let full = std::fs::read_to_string(&path).unwrap();
    let cut = full.rfind("{\"type\":\"attachment\"").unwrap() + 30;
    std::fs::write(&path, &full[..cut]).unwrap();
    assert!(
        env.claude_hook(&env.claude_event("Stop"), false)
            .status
            .success()
    );
    let report = env.drain();
    assert_eq!(report["retried"], 1);
    // What was complete is already visible, marked to be read again.
    let status = || -> String {
        open(&env.db)
            .query_row(
                "select scan_status from sessions where session_id = ?",
                [CLAUDE_SESSION],
                |row| row.get(0),
            )
            .unwrap()
    };
    assert_eq!(status(), "changed_pending_parse");
    // A drain started by a hook waits for the retry itself: no later hook
    // is needed once the transcript is complete.
    let mut waiting = env.command(&["serve"]).spawn().unwrap();
    std::thread::sleep(Duration::from_millis(300));
    std::fs::write(&path, &full).unwrap();
    wait_until("resident retry", || {
        env.queued().is_empty() && status() == "available"
    });
    assert!(env.run(&["resident", "stop"]).status.success());
    assert!(waiting.wait().unwrap().success());
    assert!(env.queued().is_empty());
    assert_eq!(status(), "available");
}

/// End to end through the executable's default, which has a WSL bridge only
/// on Windows; the mapping itself is unit-tested on every platform in
/// `path_mapping.rs`.
#[cfg(windows)]
#[test]
fn a_hook_from_wsl_reads_the_transcript_through_the_wsl_root() {
    let env = Env::new("claude-wsl");
    let root = env.temp.path().join("wsl-root");
    let folder = root.join("home/dev/.claude/projects/-home-dev-project");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::copy(
        env.transcript(),
        folder.join(format!("{CLAUDE_SESSION}.jsonl")),
    )
    .unwrap();
    let event = json!({
        "session_id": CLAUDE_SESSION,
        "transcript_path": format!("/home/dev/.claude/projects/-home-dev-project/{CLAUDE_SESSION}.jsonl"),
        "cwd": "/home/dev/project",
        "hook_event_name": "Stop",
    });
    assert!(env.claude_hook(&event, false).status.success());
    let root_arg = root.to_string_lossy().into_owned();
    let output = env.run(&["drain", "--no-wait", "--wsl-unc-root", &root_arg]);
    assert!(output.status.success());
    let report: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["completed"], 1, "{report}");
    assert_eq!(
        count(
            &env.db,
            "select count(*) from sessions where session_id = '11111111-2222-4333-8444-555555555555'"
        ),
        1
    );
}

#[test]
fn a_crashed_drain_leaves_work_that_the_next_drain_recovers() {
    let env = Env::new("claude-restart");
    assert!(
        env.claude_hook(&env.claude_event("Stop"), false)
            .status
            .success()
    );
    let entry = env.queued().pop().unwrap();
    let claimed = PathBuf::from(format!("{}.claimed-99999", entry.display()));
    std::fs::rename(&entry, &claimed).unwrap();
    let old = std::time::SystemTime::now() - Duration::from_secs(3600);
    std::fs::File::options()
        .write(true)
        .open(&claimed)
        .unwrap()
        .set_modified(old)
        .unwrap();
    let report = env.drain();
    assert_eq!(report["completed"], 1);
    assert!(env.queued().is_empty());
    assert_eq!(
        count(
            &env.db,
            "select count(*) from sessions where session_id = '11111111-2222-4333-8444-555555555555'"
        ),
        1
    );
}

#[test]
fn a_full_scan_repairs_missed_hooks() {
    let env = Env::new("claude-reconcile");
    let output = env.run(&["claude", "scan", "--json"]);
    assert!(output.status.success());
    let first: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(first["files_parsed"], 3);
    // A later turn arrives without any hook.
    let mut text = std::fs::read_to_string(env.transcript()).unwrap();
    text.push_str(
        &json!({
            "type": "user", "timestamp": "2026-09-20T11:00:00.000Z", "sessionId": CLAUDE_SESSION,
            "uuid": "late", "cwd": "C:\\nonexistent\\claude-project",
            "message": {"role": "user", "content": "one more question about reconciliation"}
        })
        .to_string(),
    );
    text.push('\n');
    std::fs::write(env.transcript(), text).unwrap();
    let output = env.run(&["claude", "scan", "--json"]);
    let second: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(
        second["files_parsed"], 1,
        "only the changed transcript is read again"
    );
    assert_eq!(second["files_skipped"], 2);
    assert_eq!(
        count(
            &env.db,
            "select count(*) from message_search where message_search match 'reconciliation'"
        ),
        1
    );
    // A deleted transcript is marked missing but keeps its history.
    std::fs::remove_file(env.transcript()).unwrap();
    let output = env.run(&["claude", "scan", "--json"]);
    let third: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(third["sessions_missing"], 1);
    assert!(
        count(
            &env.db,
            "select count(*) from messages m join sessions s on s.id = m.session_id where s.session_id = '11111111-2222-4333-8444-555555555555'"
        ) > 0
    );
}

// ---------------------------------------------------------------------------
// Codex notify

fn write_rollout(home: &Path, day: &str, id: &str, text: &str) -> PathBuf {
    let folder = home.join("sessions").join("2026").join("09").join(day);
    std::fs::create_dir_all(&folder).unwrap();
    let path = folder.join(format!("rollout-2026-09-{day}T10-00-00-{id}.jsonl"));
    support::write_generated_session(&path, id, 3);
    let mut content = std::fs::read_to_string(&path).unwrap();
    content.push_str(&json!({"timestamp": "2026-09-01T00:10:00Z", "type": "event_msg", "payload": {"type": "user_message", "message": text}}).to_string());
    content.push('\n');
    std::fs::write(&path, content).unwrap();
    path
}

fn notify_payload(thread: &str) -> String {
    json!({
        "type": "agent-turn-complete",
        "thread-id": thread,
        "turn-id": "1",
        "cwd": "C:\\nonexistent\\generated",
        "input-messages": ["hi"],
        "last-assistant-message": "done"
    })
    .to_string()
}

fn assert_native_success(output: &Output) {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap(),
        json!({})
    );
    assert!(output.stderr.is_empty());
}

fn computer_use_fixture(env: &Env) -> (PathBuf, PathBuf, PathBuf) {
    let source = env.temp.path().join("computer_use_fixture.rs");
    let exe = env.temp.path().join(if cfg!(windows) {
        "codex-computer-use.exe"
    } else {
        "codex-computer-use"
    });
    let sink = env.temp.path().join("helper-payload.json");
    std::fs::write(
        &source,
        r#"
fn main() {
    let mode = std::env::var("CSV_COMPUTER_USE_TEST_MODE").unwrap_or_default();
    if mode == "fail" { std::process::exit(7); }
    if mode == "timeout" { std::thread::sleep(std::time::Duration::from_secs(10)); }
    let args: Vec<String> = std::env::args().collect();
    assert_eq!(args[1], "turn-ended");
    let sink = std::path::PathBuf::from(std::env::var_os("CSV_COMPUTER_USE_TEST_SINK").unwrap());
    std::fs::write(&sink, args.last().unwrap()).unwrap();
    // Length-prefixed UTF-8 preserves every argument, including JSON quotes,
    // whitespace and newlines, without introducing fixture dependencies.
    let mut captured = Vec::new();
    for arg in &args {
        captured.extend_from_slice(&(arg.len() as u64).to_le_bytes());
        captured.extend_from_slice(arg.as_bytes());
    }
    std::fs::write(sink.with_extension("argv"), captured).unwrap();
}
"#,
    )
    .unwrap();
    // Invoke the installed compiler directly, so rustup does not consult a
    // synthetic HOME for its toolchain. The compiler writes only this fixture.
    let rustup = std::env::var_os("RUSTUP_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(
                std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" }).unwrap(),
            )
            .join(".rustup")
        });
    let mut compilers: Vec<PathBuf> = std::fs::read_dir(rustup.join("toolchains"))
        .unwrap()
        .map(Result::unwrap)
        .map(|entry| {
            entry
                .path()
                .join("bin")
                .join(if cfg!(windows) { "rustc.exe" } else { "rustc" })
        })
        .filter(|path| path.is_file())
        .collect();
    compilers.sort();
    let compiler = compilers.first().expect("installed Rust compiler");
    let outside = support::test_root()
        .parent()
        .unwrap()
        .join("unowned-compiler-fixture");
    for (input, output) in [
        (outside.join("computer_use_fixture.rs"), exe.clone()),
        (source.clone(), outside.join(exe.file_name().unwrap())),
    ] {
        let error = support::test_command(compiler)
            .arg(input)
            .arg("-o")
            .arg(output)
            .output()
            .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
    }
    let output = support::test_command(compiler)
        .arg(&source)
        .arg("-o")
        .arg(&exe)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "fixture compiler: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let file = env.temp.path().join("helper-command.json");
    std::fs::write(&file, json!([exe, "turn-ended"]).to_string()).unwrap();
    (file, exe, sink)
}

fn computer_use_hook(env: &Env, file: &Path, sink: &Path, input: &str, mode: &str) -> Output {
    let mut command = collector();
    command.profile(env.temp.path());
    command
        .args(["codex", "computer-use-hook", "--command-file"])
        .arg(file)
        .env("CSV_COMPUTER_USE_TEST_SINK", sink)
        .env("CSV_COMPUTER_USE_TEST_MODE", mode)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn_with_input(input)
        .unwrap()
        .wait_with_output()
        .unwrap()
}

fn captured_computer_use_argv(sink: &Path) -> Vec<String> {
    let bytes = std::fs::read(sink.with_extension("argv")).unwrap();
    let mut remaining = bytes.as_slice();
    let mut args = Vec::new();
    while !remaining.is_empty() {
        let (length, rest) = remaining.split_at(8);
        let length = usize::try_from(u64::from_le_bytes(length.try_into().unwrap())).unwrap();
        let (arg, rest) = rest.split_at(length);
        args.push(std::str::from_utf8(arg).unwrap().to_owned());
        remaining = rest;
    }
    args
}

fn assert_computer_use_argv(actual: &[String], expected: &[String]) {
    assert_eq!(
        actual, expected,
        "helper argv must preserve the complete configured command"
    );
}

#[test]
#[should_panic(expected = "helper argv must preserve the complete configured command")]
fn codex_computer_use_argv_assertion_rejects_dropped_predecessor() {
    let expected = vec![
        "helper".into(),
        "turn-ended".into(),
        "--previous-notify".into(),
        r#"["nested helper","turn-ended"]"#.into(),
        "metadata".into(),
    ];
    let mut dropped = expected.clone();
    dropped.drain(2..4);
    assert_computer_use_argv(&dropped, &expected);
}

#[test]
fn codex_computer_use_adapter_projects_large_input_and_reports_helper_failures() {
    let env = Env::new("computer-use-adapter");
    let (file, exe, sink) = computer_use_fixture(&env);
    for event_name in ["Stop", "Interrupt", "SubagentStop"] {
        let mut event = env.codex_event("parent-session", event_name);
        event["turn_id"] = json!("turn-🦀-\"quoted\"\nline");
        event["agent_id"] = json!("child-session");
        event["stop_hook_active"] = json!(true);
        event["last_assistant_message"] =
            json!("Private response\nZażółć 🦀 \"quotes\"".repeat(5000));
        let input = event.to_string();
        assert!(input.len() > 100_000);
        assert_native_success(&computer_use_hook(&env, &file, &sink, &input, ""));
        let raw = std::fs::read_to_string(&sink).unwrap();
        assert!(raw.len() < 4096);
        assert!(!raw.contains("Private"));
        let payload: Value = serde_json::from_str(&raw).unwrap();
        let session = if event_name == "SubagentStop" {
            "child-session"
        } else {
            "parent-session"
        };
        assert_eq!(
            payload,
            json!({"type":"agent-turn-complete", "thread-id":session,
            "turn-id":event["turn_id"], "cwd":event["cwd"], "hook_event_name":event_name,
            "session_id":session, "turn_id":event["turn_id"]})
        );
    }
    // Nested helper-only commands remain structured argv, without interpreting
    // or rewriting the configured nested JSON.
    // Noncanonical JSON whitespace also detects parse-and-reserialize changes.
    let nested = format!(" [\n  {},\n  \"turn-ended\"\n] ", json!(exe));
    std::fs::write(
        &file,
        json!([exe, "turn-ended", "--previous-notify", nested]).to_string(),
    )
    .unwrap();
    let event = env.codex_event("nested-session", "Stop").to_string();
    assert_native_success(&computer_use_hook(&env, &file, &sink, &event, ""));
    let payload = std::fs::read_to_string(&sink).unwrap();
    let expected = vec![
        exe.to_string_lossy().into_owned(),
        "turn-ended".into(),
        "--previous-notify".into(),
        nested,
        payload,
    ];
    assert_computer_use_argv(&captured_computer_use_argv(&sink), &expected);
    for (mode, expected) in [("fail", "helper failed"), ("timeout", "timed out")] {
        let output = computer_use_hook(&env, &file, &sink, &event, mode);
        assert_eq!(output.status.code(), Some(1));
        assert!(output.stdout.is_empty());
        assert!(String::from_utf8_lossy(&output.stderr).contains(expected));
    }
    std::fs::remove_file(&exe).unwrap();
    let output = computer_use_hook(&env, &file, &sink, &event, "");
    assert_eq!(output.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&output.stderr).contains("could not launch"));
    assert!(env.queued().is_empty(), "adapter must not collect");
}

#[test]
fn codex_computer_use_adapter_rejects_invalid_metadata_and_unknown_chains_before_launch() {
    let env = Env::new("computer-use-invalid");
    let (file, exe, sink) = computer_use_fixture(&env);
    let valid = env.codex_event("session", "Stop");
    let mut inputs = vec!["not JSON".into(), "null".into()];
    for field in ["session_id", "turn_id", "cwd", "hook_event_name"] {
        for value in [Value::Null, json!(""), json!(42)] {
            let mut event = valid.clone();
            event[field] = value;
            inputs.push(event.to_string());
        }
        let mut event = valid.clone();
        event.as_object_mut().unwrap().remove(field);
        inputs.push(event.to_string());
    }
    inputs.push(env.codex_event("parent", "SubagentStop").to_string());
    inputs.push(env.codex_event("parent", "SessionStart").to_string());
    let mut oversized = valid.clone();
    oversized["turn_id"] = json!("🦀".repeat(6000));
    inputs.push(oversized.to_string());
    for input in inputs {
        let output = computer_use_hook(&env, &file, &sink, &input, "");
        assert_eq!(output.status.code(), Some(1));
        assert!(output.stdout.is_empty());
        assert!(!output.stderr.is_empty());
        assert!(!sink.exists());
    }
    let unknown = json!([
        env!("CARGO_BIN_EXE_codex-sessions-collector"),
        "codex",
        "notify"
    ])
    .to_string();
    for argv in [
        json!([]),
        json!(["unknown", "turn-ended"]),
        json!([exe, "turn-ended", "--previous-notify", unknown]),
        json!([exe, "turn-ended", "--unknown"]),
    ] {
        std::fs::write(&file, argv.to_string()).unwrap();
        let output = computer_use_hook(&env, &file, &sink, &valid.to_string(), "");
        assert_eq!(output.status.code(), Some(1));
        assert!(output.stdout.is_empty());
        assert!(!sink.exists());
    }
    assert!(env.queued().is_empty());
}

#[test]
fn codex_computer_use_fixture_guard_rejects_unowned_sinks_and_unknown_modes() {
    let outside = support::test_root()
        .parent()
        .unwrap()
        .join("unowned-helper-sink");
    let result = collector()
        .arg("version")
        .env("CSV_COMPUTER_USE_TEST_SINK", &outside)
        .output();
    assert_eq!(
        result.unwrap_err().kind(),
        std::io::ErrorKind::PermissionDenied
    );
    let result = collector()
        .arg("version")
        .env("CSV_COMPUTER_USE_TEST_MODE", "unlisted")
        .output();
    assert_eq!(
        result.unwrap_err().kind(),
        std::io::ErrorKind::PermissionDenied
    );
    let result = collector()
        .args(["codex", "computer-use-hook", "--command-file"])
        .arg(&outside)
        .output();
    assert_eq!(
        result.unwrap_err().kind(),
        std::io::ErrorKind::PermissionDenied
    );
}

#[test]
fn codex_native_hook_large_stdin_queues_only_metadata_and_ingests_expected_session() {
    let env = Env::new("codex-native-large");
    let target = "01a0aaaa-0000-7000-8000-000000000011";
    let other = "01a0aaaa-0000-7000-8000-000000000012";
    let path = write_rollout(&env.codex_home, "03", target, "native target");
    write_rollout(&env.codex_home, "04", other, "unrelated newer rollout");
    let mut event = env.codex_event(target, "Stop");
    event["transcript_path"] = json!(path);
    event["last_assistant_message"] =
        json!("Private \"quoted\" response\nZażółć 🦀\n".repeat(6000));
    let payload = event.to_string();
    assert!(payload.len() > 100_000);
    assert_native_success(&env.codex_hook(&payload, &["--no-drain"]));
    let entries = env.queued();
    assert_eq!(entries.len(), 1);
    let queued = std::fs::read_to_string(&entries[0]).unwrap();
    assert!(queued.len() < 4096);
    assert!(!queued.contains("Private"));
    let item: Value = serde_json::from_str(&queued).unwrap();
    assert_eq!(item["session_id"], target);
    assert_eq!(item["turn_id"], "turn-1");
    assert_eq!(item["event"], "Stop");
    assert_eq!(item["cwd"], event["cwd"]);
    assert_eq!(item["transcript_path"], event["transcript_path"]);
    assert!(item["database_key"].as_str().is_some());
    let mut legacy = item.clone();
    legacy.as_object_mut().unwrap().remove("turn_id");
    let legacy: codex_sessions_collector::hooks::WorkItem = serde_json::from_value(legacy).unwrap();
    assert_eq!(legacy.turn_id, None);
    assert_eq!(env.drain()["completed"], 1);
    let sessions: Vec<String> = open(&env.db)
        .prepare("select session_id from sessions where harness = 'codex'")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert_eq!(sessions, vec![target]);
}

#[test]
fn codex_native_continued_stop_and_interrupt_are_both_collected() {
    let env = Env::new("codex-native-events");
    let id = "01a0aaaa-0000-7000-8000-000000000013";
    write_rollout(&env.codex_home, "03", id, "continued interrupted thread");
    for name in ["Stop", "Interrupt"] {
        let mut event = env.codex_event(id, name);
        event["stop_hook_active"] = json!(true);
        // Older hook producers need not provide Codex's turn-id extension.
        event.as_object_mut().unwrap().remove("turn_id");
        assert_native_success(&env.codex_hook(&event.to_string(), &["--no-drain"]));
    }
    let events: Vec<Value> = env
        .queued()
        .iter()
        .map(|path| serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap())
        .collect();
    assert_eq!(events.len(), 2);
    assert!(events.iter().any(|item| item["event"] == "Stop"));
    assert!(events.iter().any(|item| item["event"] == "Interrupt"));
    assert_eq!(env.drain()["completed"], 2);
    assert_eq!(
        count(
            &env.db,
            "select count(*) from sessions where harness = 'codex'"
        ),
        1
    );
}

#[test]
fn codex_native_invalid_input_and_options_fail_without_blocking_or_queueing() {
    let env = Env::new("codex-native-invalid");
    let valid = env.codex_event("native-invalid", "Stop");
    let mut inputs = vec!["not json".to_owned(), "[]".to_owned(), "null".to_owned()];
    for key in ["session_id", "cwd", "hook_event_name"] {
        let mut missing = valid.clone();
        missing.as_object_mut().unwrap().remove(key);
        inputs.push(missing.to_string());
        let mut empty = valid.clone();
        empty[key] = json!("  ");
        inputs.push(empty.to_string());
        let mut wrong_type = valid.clone();
        wrong_type[key] = json!(42);
        inputs.push(wrong_type.to_string());
    }
    let mut wrong_event = valid.clone();
    wrong_event["hook_event_name"] = json!("UserPromptSubmit");
    inputs.push(wrong_event.to_string());
    for turn_id in [json!(""), json!(42)] {
        let mut invalid_turn = valid.clone();
        invalid_turn["turn_id"] = turn_id;
        inputs.push(invalid_turn.to_string());
    }
    for input in inputs {
        let output = env.codex_hook(&input, &["--no-drain"]);
        assert_eq!(output.status.code(), Some(1), "{input}");
        assert!(output.stdout.is_empty());
        assert!(!output.stderr.is_empty());
        assert!(env.queued().is_empty());
    }
    for options in [
        vec!["--parser-workers", "invalid"],
        vec!["unexpected-payload"],
    ] {
        let output = env.codex_hook(&valid.to_string(), &options);
        assert_eq!(output.status.code(), Some(1));
        assert!(output.stdout.is_empty());
        assert!(!output.stderr.is_empty());
        assert!(env.queued().is_empty());
    }
}

#[test]
fn codex_native_null_or_missing_transcript_keeps_identity_based_collection_and_retry() {
    let env = Env::new("codex-native-null-transcript");
    let id = "01a0aaaa-0000-7000-8000-000000000015";
    for name in ["Stop", "Interrupt"] {
        let mut event = env.codex_event(id, name);
        if name == "Stop" {
            event["transcript_path"] = Value::Null;
        } else {
            event.as_object_mut().unwrap().remove("transcript_path");
        }
        assert_native_success(&env.codex_hook(&event.to_string(), &["--no-drain"]));
    }
    assert_eq!(
        env.drain()["retried"],
        2,
        "missing rollouts retain normal retry semantics"
    );
    write_rollout(
        &env.codex_home,
        "03",
        id,
        "rollout appears after lifecycle signal",
    );
    // Make the retained retries due without waiting on the backoff clock.
    for path in env.queued() {
        let mut item: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(item["attempts"], 1);
        assert!(item["transcript_path"].is_null());
        item["not_before_utc"] = Value::Null;
        std::fs::write(path, item.to_string()).unwrap();
    }
    assert_eq!(env.drain()["completed"], 2);
    assert_eq!(
        count(
            &env.db,
            "select count(*) from sessions where harness = 'codex'"
        ),
        1
    );
}

#[test]
fn codex_native_input_limit_rejects_even_valid_json_with_excess_whitespace() {
    let env = Env::new("codex-native-limit");
    let mut input = env.codex_event("native-limit", "Stop").to_string();
    input.extend(std::iter::repeat_n(' ', 1024 * 1024 + 1 - input.len()));
    let output = env.codex_hook(&input, &["--no-drain"]);
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("exceeds 1048576 bytes"));
    assert!(env.queued().is_empty());
    input.truncate(1024 * 1024);
    assert_native_success(&env.codex_hook(&input, &["--no-drain"]));
    assert_eq!(env.queued().len(), 1);
}

#[test]
fn codex_native_queue_failure_is_reported_on_stderr_with_exit_one() {
    let env = Env::new("codex-native-queue-failure");
    std::fs::write(&env.queue, "queue path occupied by a file").unwrap();
    let output = env.codex_hook(&env.codex_event("queue-failure", "Stop").to_string(), &[]);
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("could not queue"));
}

#[test]
fn codex_native_worker_start_failure_reports_error_and_retains_durable_work() {
    let env = Env::new("codex-native-worker-failure");
    // The detached worker requires an appendable error log. A directory here
    // deterministically denies launch after successful queue persistence.
    std::fs::create_dir_all(env.queue.join("errors.log")).unwrap();
    let output = env.codex_hook(
        &env.codex_event("worker-failure", "Interrupt").to_string(),
        &[],
    );
    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(String::from_utf8_lossy(&output.stderr).contains("could not start hook worker"));
    assert_eq!(env.queued().len(), 1);
}

#[test]
fn codex_native_hook_starts_fallback_resident_then_wakes_the_same_resident() {
    let env = Env::new("codex-native-resident");
    let id = "01a0aaaa-0000-7000-8000-000000000014";
    write_rollout(&env.codex_home, "03", id, "fallback thread");
    let event = env.codex_event(id, "Stop");
    assert_native_success(&env.codex_hook(&event.to_string(), &[]));
    wait_until("native fallback collection", || {
        env.queued().is_empty()
            && count(
                &env.db,
                "select count(*) from sessions where harness = 'codex'",
            ) == 1
    });
    let info: Value = serde_json::from_slice(&env.run(&["resident", "status"]).stdout).unwrap();
    // The second hook must work while SQLite is locked; only the resident
    // waits for persistence. It must not start another serving owner.
    let holder = open(&env.db);
    holder.execute_batch("begin exclusive").unwrap();
    let started = Instant::now();
    assert_native_success(&env.codex_hook(&env.codex_event(id, "Interrupt").to_string(), &[]));
    assert!(started.elapsed() < Duration::from_secs(3));
    assert!(!env.queued().is_empty());
    holder.execute_batch("rollback").unwrap();
    drop(holder);
    wait_until("native resident collection", || env.queued().is_empty());
    let after: Value = serde_json::from_slice(&env.run(&["resident", "status"]).stdout).unwrap();
    assert_eq!(info["pid"], after["pid"]);
    assert!(info["pid"].as_u64().is_some());
}

#[test]
fn codex_notify_ingests_the_named_thread_not_the_newest_file() {
    let env = Env::new("codex-notify");
    let target = "01a0aaaa-0000-7000-8000-000000000001";
    let newer = "01a0bbbb-0000-7000-8000-000000000002";
    write_rollout(&env.codex_home, "03", target, "the targeted older thread");
    std::thread::sleep(Duration::from_millis(50));
    write_rollout(&env.codex_home, "04", newer, "a newer unrelated thread");
    let output = env.run(&["codex", "notify", "--no-drain", &notify_payload(target)]);
    assert!(output.status.success());
    let report = env.drain();
    assert_eq!(report["completed"], 1);
    assert_eq!(
        count(
            &env.db,
            &format!("select count(*) from sessions where session_id = '{target}'")
        ),
        1
    );
    assert_eq!(
        count(
            &env.db,
            &format!("select count(*) from sessions where session_id = '{newer}'")
        ),
        0
    );
}

#[test]
fn codex_notify_keeps_the_previous_notify_command_running() {
    let env = Env::new("codex-chain");
    let thread = "01a0cccc-0000-7000-8000-000000000003";
    write_rollout(&env.codex_home, "05", thread, "chained notify thread");
    // The previous notify here is another queueing notify, so its run is
    // visible as a second queue entry carrying the same payload.
    let previous = json!([
        env!("CARGO_BIN_EXE_codex-sessions-collector"),
        "codex",
        "notify",
        "--no-drain",
        "--db",
        env.db.to_string_lossy()
    ])
    .to_string();
    let output = env.run(&[
        "codex",
        "notify",
        "--no-drain",
        "--previous-notify",
        &previous,
        &notify_payload(thread),
    ]);
    assert!(output.status.success());
    wait_until("the previous notify command", || env.queued().len() == 2);
    for entry in env.queued() {
        let item: Value = serde_json::from_str(&std::fs::read_to_string(entry).unwrap()).unwrap();
        assert_eq!(item["session_id"], thread);
    }
    // A broken previous command never stops collection.
    let output = env.run(&[
        "codex",
        "notify",
        "--no-drain",
        "--previous-notify",
        &json!([env.temp.path().join("missing-notify.exe")]).to_string(),
        &notify_payload(thread),
    ]);
    assert!(output.status.success());
    assert_eq!(env.queued().len(), 3);
    let report = env.drain();
    assert_eq!(report["completed"], 3);
    assert_eq!(
        count(
            &env.db,
            &format!("select count(*) from sessions where session_id = '{thread}'")
        ),
        1
    );
    assert_eq!(
        count(&env.db, "select count(*) from usage_events"),
        3,
        "duplicates never add usage"
    );
}

/// A harness may kill its whole process group once a hook returns. Detached
/// work (the drain, a chained notify) must run in its own group and survive.
#[test]
#[cfg(unix)]
fn detached_work_outlives_the_hook_process_group_on_unix() {
    let env = Env::new("detached-group");
    let marker = env.temp.path().join("survived");
    let script = format!("sleep 1; echo alive > '{}'", marker.display());
    let previous = json!(["/bin/sh", "-c", script, "sh"]).to_string();
    let mut hook = env.command(&[
        "codex",
        "notify",
        "--no-drain",
        "--previous-notify",
        &previous,
        &notify_payload("01a0cccc-0000-7000-8000-000000000009"),
    ]);
    // The hook leads a fresh group (numbered after its pid), as a
    // harness-started hook would; the harness then kills that group.
    let child = hook
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let group = format!("-{}", child.id());
    assert!(child.wait_with_output().unwrap().status.success());
    // With the detached work in its own group the hook's group is already
    // empty, so `kill` may report that nothing matched.
    let _ = support::test_command("kill")
        .args(["-KILL", "--", &group])
        .stderr(Stdio::null())
        .status();
    wait_until("the detached command", || marker.is_file());
}

#[test]
fn hooks_return_promptly_while_the_database_is_locked() {
    let env = Env::new("hook-latency");
    let thread = "01a0dddd-0000-7000-8000-000000000004";
    write_rollout(&env.codex_home, "06", thread, "locked database thread");
    let holder = open(&env.db);
    holder.execute_batch("begin exclusive").unwrap();
    let started = Instant::now();
    assert!(
        env.run(&["codex", "notify", &notify_payload(thread)])
            .status
            .success()
    );
    assert!(
        env.claude_hook(&env.claude_event("Stop"), true)
            .status
            .success()
    );
    assert!(
        started.elapsed() < Duration::from_secs(5),
        "hooks took {:?}",
        started.elapsed()
    );
    holder.execute_batch("rollback").unwrap();
    drop(holder);
    wait_until("the queued work", || {
        env.queued().is_empty()
            && count(
                &env.db,
                &format!("select count(*) from sessions where session_id = '{thread}'"),
            ) == 1
            && count(
                &env.db,
                "select count(*) from sessions where harness = 'claude'",
            ) == 2
    });
}

#[test]
fn hook_problems_are_logged_without_failing_the_harness() {
    let env = Env::new("hook-errors");
    let output = env.run(&["codex", "notify", "--no-drain", "not json"]);
    assert!(output.status.success());
    let output = env.claude_hook(&json!({"hook_event_name": "Stop"}), false);
    assert!(output.status.success());
    let log = std::fs::read_to_string(env.queue.join("errors.log")).unwrap();
    assert!(log.contains("no transcript_path"));
    // An unknown thread is retried, then left for the next full scan.
    let report = env.drain();
    assert_eq!(report["retried"], 1);
    let _ = &env.temp;
}
