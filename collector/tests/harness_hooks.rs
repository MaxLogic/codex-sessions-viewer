//! Codex notify and Claude Code hook collection (T-121), through the real
//! executable: hooks queue work, drains ingest it, and scans reconcile.

mod support;

use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
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
        command
            .args(args)
            .env("CODEX_SESSIONS_COLLECTOR_QUEUE", &self.queue)
            .arg("--db")
            .arg(&self.db)
            .arg("--windows-root")
            .arg(&self.codex_home)
            .args(["--wsl-root", "", "--no-wsl-projects", "--claude-root"])
            .arg(&self.claude_root);
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
        let mut child = self
            .command(&args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        use std::io::Write as _;
        child
            .stdin
            .take()
            .unwrap()
            .write_all(event.to_string().as_bytes())
            .unwrap();
        child.wait_with_output().unwrap()
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
    let mut drains: Vec<std::process::Child> = (0..3)
        .map(|_| env.command(&["drain"]).spawn().unwrap())
        .collect();
    for drain in &mut drains {
        assert!(drain.wait().unwrap().success());
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
    let mut waiting = env.command(&["drain"]).spawn().unwrap();
    std::thread::sleep(Duration::from_millis(300));
    std::fs::write(&path, &full).unwrap();
    assert!(waiting.wait().unwrap().success());
    assert!(env.queued().is_empty());
    assert_eq!(status(), "available");
}

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
        "--no-drain"
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
        "[\"C:\\\\missing\\\\notify.exe\"]",
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
    use std::os::unix::process::CommandExt;
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
    let _ = Command::new("kill")
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
