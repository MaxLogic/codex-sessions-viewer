mod support;

use serde_json::Value;
use support::{TempDir, collector};

struct Fixture {
    temp: TempDir,
    root: std::path::PathBuf,
    config: std::path::PathBuf,
    db: std::path::PathBuf,
    queue: std::path::PathBuf,
    harness: &'static str,
}

impl Fixture {
    fn new(harness: &'static str) -> Self {
        let temp = TempDir::new("diagnostics");
        let root = temp.path().join("sessions");
        std::fs::create_dir(&root).unwrap();
        let config = temp.path().join("harness.config");
        let queue = temp.path().join("queue");
        let db = support::viewer_database(&temp);
        Self {
            temp,
            root,
            config,
            db,
            queue,
            harness,
        }
    }
    fn command(&self, action: &str) -> std::process::Command {
        let mut cmd = collector();
        cmd.args([self.harness, action, "--json", "--root"])
            .arg(&self.root)
            .arg("--config")
            .arg(&self.config)
            .arg("--db")
            .arg(&self.db)
            .env("CODEX_SESSIONS_COLLECTOR_QUEUE", &self.queue)
            .env_remove("CODEX_SESSIONS_HUB_MACHINE_TOKEN");
        cmd
    }
    fn setup(&self) {
        let out = self.command("setup").arg("--apply").output().unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stdout)
        );
    }
    fn run(&self, action: &str, args: &[&str], expected: i32) -> Value {
        let out = self.command(action).args(args).output().unwrap();
        assert_eq!(
            out.status.code(),
            Some(expected),
            "{} {}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice(&out.stdout).unwrap()
    }
}

#[test]
fn fresh_setup_and_offline_synthetic_ingestion_are_independent_of_live_history() {
    for harness in ["codex", "claude"] {
        let f = Fixture::new(harness);
        assert!(!f.config.exists());
        let preview = f.run("setup", &[], 0);
        assert_eq!(preview["applied"], false);
        assert!(!f.config.exists());
        f.setup();
        let report = f.run("verify", &["--local-proof"], 0);
        assert_eq!(report["configuration"]["hook_registered"], true);
        assert_eq!(report["local_ingestion_proof"]["state"], "passed");
        assert_eq!(report["hub"]["state"], "offline");
        let conn = rusqlite::Connection::open(&f.db).unwrap();
        assert_eq!(
            conn.query_row::<i64, _, _>("select count(*) from sessions", [], |r| r.get(0))
                .unwrap(),
            0
        );
        assert!(!f.queue.exists());
    }
}

#[test]
fn status_reports_last_collection_pending_work_and_uploads_without_draining() {
    let f = Fixture::new("codex");
    f.setup();
    let store = codex_sessions_collector::store::Store::open(
        &f.db,
        codex_sessions_collector::store::OwnerMode::Viewer,
    )
    .unwrap();
    store
        .apply(vec![codex_sessions_collector::contract::Envelope::new(
            codex_sessions_collector::contract::Record::SessionSnapshot(Box::new(
                support::sample_snapshot("diagnostic-test"),
            )),
        )])
        .unwrap();
    store.conn.execute("insert into collector_upload_outbox(record_json,created_at_utc) values ('{}','2026-01-01')", []).unwrap();
    std::fs::create_dir(&f.queue).unwrap();
    std::fs::write(f.queue.join("pending.json"), r#"{"harness":"codex"}"#).unwrap();
    std::fs::write(
        f.queue.join("active.json.claimed-99999"),
        r#"{"harness":"codex"}"#,
    )
    .unwrap();
    let report = f.run("status", &[], 0);
    assert!(report["database"]["last_collection_utc"].is_string());
    assert_eq!(report["database"]["pending_uploads"], 1);
    assert_eq!(report["queue"]["pending"], 1);
    assert_eq!(report["queue"]["claimed"], 1);
    assert!(f.queue.join("pending.json").exists());
}

#[test]
fn absent_or_unreadable_root_and_invalid_config_are_actionable_and_secret_safe() {
    let f = Fixture::new("claude");
    std::fs::remove_dir(&f.root).unwrap();
    let report = f.run("verify", &[], 1);
    assert_eq!(report["detected"], false);
    assert!(
        report["roots"][0]["error"]
            .as_str()
            .unwrap()
            .contains("--root")
    );
    f.run("setup", &["--apply"], 1);
    assert!(!f.config.exists());
    // A regular file deterministically exercises the unreadable-as-directory
    // error on Windows, even when the suite runs with administrator rights.
    std::fs::write(&f.root, "not a directory").unwrap();
    assert_eq!(f.run("status", &[], 1)["roots"][0]["readable"], false);
    std::fs::write(&f.config, "{ private-test-secret malformed").unwrap();
    let output = f.command("setup").output().unwrap();
    assert_eq!(output.status.code(), Some(1));
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("invalid Claude JSON"));
    assert!(!text.contains("private-test-secret"));
    let output = collector()
        .args(["codex", "verify", "--bogus-secret-value", "--json"])
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert!(!String::from_utf8_lossy(&output.stdout).contains("bogus-secret-value"));
}

#[test]
fn explicit_hub_verification_authenticates_without_uploads_and_preserves_local_status() {
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};
    let f = Fixture::new("codex");
    f.setup();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    drop(listener);
    let config = f.temp.path().join("hub.json");
    let data = f.temp.path().join("hub-data");
    const TOKEN: &str = "synthetic-private-machine-token-123456789";
    std::fs::write(&config, serde_json::json!({"owner_token":"synthetic-owner-token-123456789","machines":{"test-machine":TOKEN}}).to_string()).unwrap();
    struct Server(std::process::Child);
    impl Drop for Server {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let mut server = Server(
        Command::new(env!("CARGO_BIN_EXE_codex-sessions-hub"))
            .arg(address.to_string())
            .arg(&data)
            .arg(&config)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let url = format!("http://{address}");
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if ureq::get(format!("{url}/v1/health")).call().is_ok() {
            break;
        }
        assert!(server.0.try_wait().unwrap().is_none(), "hub exited");
        assert!(Instant::now() < deadline, "hub startup timed out");
        std::thread::sleep(Duration::from_millis(20));
    }
    // Configured URL alone never sends a request or requires credentials.
    assert_eq!(
        f.run("verify", &["--hub-url", &url], 0)["hub"]["state"],
        "not_checked"
    );
    for (token, expected) in [("rejected-private-token", 1), (TOKEN, 0)] {
        let out = f
            .command("verify")
            .args(["--check-hub", "--hub-url", &url])
            .env("CODEX_SESSIONS_HUB_MACHINE_TOKEN", token)
            .output()
            .unwrap();
        assert_eq!(
            out.status.code(),
            Some(expected),
            "{}",
            String::from_utf8_lossy(&out.stdout)
        );
        let text = String::from_utf8(out.stdout).unwrap();
        assert!(!text.contains(token));
        let report: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(report["local_ok"], true);
        if expected == 0 {
            assert_eq!(report["hub"]["uploaded_records"], 0);
        } else {
            assert!(
                report["hub"]["error"]
                    .as_str()
                    .unwrap()
                    .contains("rejected")
            );
        }
    }
    let hub_db = rusqlite::Connection::open(data.join("test-machine.sqlite")).unwrap();
    assert_eq!(
        hub_db
            .query_row::<i64, _, _>("select count(*) from sessions", [], |r| r.get(0))
            .unwrap(),
        0,
        "verify must not upload history"
    );
    drop(hub_db);
    drop(server);
    let report = f
        .command("verify")
        .args(["--check-hub", "--hub-url", &url])
        .env("CODEX_SESSIONS_HUB_MACHINE_TOKEN", TOKEN)
        .output()
        .unwrap();
    assert_eq!(report.status.code(), Some(1));
    let report: Value = serde_json::from_slice(&report.stdout).unwrap();
    assert_eq!(report["local_ok"], true);
    assert_eq!(report["hub"]["state"], "failed");
}

#[test]
fn text_diagnostics_and_json_usage_errors_are_useful_without_secret_disclosure() {
    let f = Fixture::new("codex");
    let out = collector()
        .args(["codex", "verify", "--root"])
        .arg(&f.root)
        .arg("--config")
        .arg(&f.config)
        .arg("--db")
        .arg(&f.db)
        .env("CODEX_SESSIONS_COLLECTOR_QUEUE", &f.queue)
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(1));
    let text = String::from_utf8(out.stdout).unwrap();
    assert!(text.contains("attention needed"));
    assert!(text.contains("setup --apply"));
    assert!(text.contains("offline"));
    let out = collector()
        .args(["claude", "setup", "--json", "--config"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert!(
        serde_json::from_slice::<Value>(&out.stdout).unwrap()["error"]
            .as_str()
            .unwrap()
            .contains("needs a value")
    );
    f.setup();
    let report = f.run(
        "verify",
        &[
            "--check-hub",
            "--hub-url",
            "https://private-user:private-password@example.invalid",
        ],
        1,
    );
    assert!(!report.to_string().contains("private-password"));
    assert_eq!(report["local_ok"], true);
}

#[test]
fn hook_registration_preserves_root_kinds_and_rejects_ambiguous_codex_roots() {
    let f = Fixture::new("codex");
    let wsl = f.temp.path().join("wsl-root");
    std::fs::create_dir(&wsl).unwrap();
    let out = f
        .command("setup")
        .arg("--wsl-root")
        .arg(&wsl)
        .arg("--apply")
        .output()
        .unwrap();
    assert!(out.status.success());
    let config: toml::Table = std::fs::read_to_string(&f.config).unwrap().parse().unwrap();
    let args = config["notify"].as_array().unwrap();
    assert!(args.iter().any(|v| v.as_str() == Some("--windows-root")));
    assert!(args.iter().any(|v| v.as_str() == Some("--wsl-root")));
    let before = std::fs::read(&f.config).unwrap();
    let out = f
        .command("setup")
        .arg("--root")
        .arg(&wsl)
        .arg("--apply")
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(std::fs::read(&f.config).unwrap(), before);
}

#[test]
#[cfg(windows)]
fn generated_hooks_execute_and_queue_synthetic_events_on_windows() {
    use std::io::Write;
    use std::os::windows::process::CommandExt;
    use std::process::{Command, Stdio};
    for harness in ["codex", "claude"] {
        let f = Fixture::new(harness);
        f.setup();
        let contents = std::fs::read_to_string(&f.config).unwrap();
        let mut cmd = if harness == "codex" {
            let config: toml::Table = contents.parse().unwrap();
            let args: Vec<_> = config["notify"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| v.as_str().unwrap().to_owned())
                .collect();
            let mut cmd = Command::new(&args[0]);
            cmd.args(&args[1..])
                .arg("--no-drain")
                .arg(r#"{"type":"agent-turn-complete","thread-id":"synthetic-hook"}"#);
            cmd
        } else {
            let config: Value = serde_json::from_str(&contents).unwrap();
            let command = config["hooks"]["Stop"][0]["hooks"][0]["command"]
                .as_str()
                .unwrap();
            let mut cmd = Command::new("cmd.exe");
            cmd.args(["/D", "/S", "/C"])
                .raw_arg(format!("\"{command} --no-drain\""));
            cmd
        };
        let mut child = cmd
            .env("CODEX_SESSIONS_COLLECTOR_QUEUE", &f.queue)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        if harness == "claude" {
            child.stdin.take().unwrap().write_all(br#"{"session_id":"synthetic-hook","hook_event_name":"Stop","transcript_path":"C:/synthetic/transcript.jsonl"}"#).unwrap();
        }
        let result = child.wait_with_output().unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        let report = f.run("status", &[], 0);
        assert_eq!(report["queue"]["pending"], 1, "{report}");
    }
}

#[test]
fn setup_preview_apply_repeat_preserves_configuration_for_both_harnesses() {
    for harness in ["codex", "claude"] {
        let temp = TempDir::new(harness);
        let root = temp.path().join("sessions");
        std::fs::create_dir(&root).unwrap();
        let config = temp.path().join(if harness == "codex" {
            "config.toml"
        } else {
            "settings.json"
        });
        let original = if harness == "codex" {
            "# keep this comment\napi_key = 'private-test-secret'\nnotify = ['previous-command', 'private-hook-secret']\n[other]\nvalue = 42\n"
        } else {
            r#"{"api_key":"private-test-secret","hooks":{"Stop":[{"hooks":[{"type":"command","command":"old-hook private-hook-secret"}]}]},"other":{"value":42}}"#
        };
        std::fs::write(&config, original).unwrap();
        let run = |apply: bool| {
            let mut cmd = collector();
            cmd.args([harness, "setup", "--json", "--root"])
                .arg(&root)
                .arg("--config")
                .arg(&config);
            if apply {
                cmd.arg("--apply");
            }
            let output = cmd.output().unwrap();
            assert!(
                output.status.success(),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            let text = String::from_utf8(output.stdout).unwrap();
            assert!(!text.contains("private-test-secret"));
            assert!(!text.contains("private-hook-secret"));
            serde_json::from_str::<Value>(&text).unwrap()
        };
        let preview = run(false);
        assert_eq!(std::fs::read_to_string(&config).unwrap(), original);
        assert_eq!(preview["changed"], true);
        let applied = run(true);
        assert_eq!(preview["planned_sha256"], applied["planned_sha256"]);
        let changed = std::fs::read_to_string(&config).unwrap();
        assert!(changed.contains("private-test-secret"));
        assert!(changed.contains("private-hook-secret"));
        if harness == "codex" {
            assert!(changed.contains("# keep this comment"));
        }
        assert_eq!(run(true)["changed"], false);
        assert_eq!(std::fs::read_to_string(&config).unwrap(), changed);
    }
}
