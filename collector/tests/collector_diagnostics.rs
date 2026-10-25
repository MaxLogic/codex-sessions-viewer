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
    fn command(&self, action: &str) -> support::Command {
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
    fn hooks_config(&self) -> std::path::PathBuf {
        if self.harness == "codex" {
            self.config.with_file_name("hooks.json")
        } else {
            self.config.clone()
        }
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
    use std::process::Stdio;
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
        support::test_command(env!("CARGO_BIN_EXE_codex-sessions-hub"))
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
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!(
        "https://private-user:private-password@{}",
        listener.local_addr().unwrap()
    );
    support::own_endpoint(&url);
    let report = f.run("verify", &["--check-hub", "--hub-url", &url], 1);
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
    let command = claude_commands(&f.hooks_config(), "Stop").remove(0);
    assert!(command.contains("--windows-root"));
    assert!(command.contains("--wsl-root"));
    assert!(!f.config.exists());
    let before = std::fs::read(f.hooks_config()).unwrap();
    let out = f
        .command("setup")
        .arg("--root")
        .arg(&wsl)
        .arg("--apply")
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(std::fs::read(f.hooks_config()).unwrap(), before);
}

#[test]
#[cfg(windows)]
fn generated_hooks_execute_and_queue_synthetic_events_on_windows() {
    use std::process::Stdio;
    for harness in ["codex", "claude"] {
        let f = Fixture::new(harness);
        f.setup();
        let command = claude_commands(&f.hooks_config(), "Stop").remove(0);
        let mut cmd = support::test_command("cmd.exe");
        cmd.args(["/D", "/S", "/C"])
            .raw_arg(format!("\"{command} --no-drain\""));
        let input = serde_json::json!({"session_id":"synthetic-hook", "hook_event_name":"Stop", "cwd":f.root,
            "transcript_path":f.root.join("transcript.jsonl")})
        .to_string();
        let child = cmd
            .env("CODEX_SESSIONS_COLLECTOR_QUEUE", &f.queue)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn_with_input(&input)
            .unwrap();
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
            "# keep this comment\napi_key = 'private-test-secret'\n[other]\nvalue = 42\n"
        } else {
            r#"{"api_key":"private-test-secret","hooks":{"Stop":[{"hooks":[{"type":"command","command":"old-hook private-hook-secret"}]}]},"other":{"value":42}}"#
        };
        std::fs::write(&config, original).unwrap();
        if harness == "codex" {
            std::fs::write(config.with_file_name("hooks.json"), r#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"old-hook private-hook-secret"}]}]}}"#).unwrap();
        }
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
        assert!(if harness == "codex" {
            std::fs::read_to_string(config.with_file_name("hooks.json"))
                .unwrap()
                .contains("private-hook-secret")
        } else {
            changed.contains("private-hook-secret")
        });
        if harness == "codex" {
            assert!(changed.contains("# keep this comment"));
        }
        assert_eq!(run(true)["changed"], false);
        assert_eq!(std::fs::read_to_string(&config).unwrap(), changed);
    }
}

fn notify_args(config: &std::path::Path) -> Vec<String> {
    let config: toml::Table = std::fs::read_to_string(config)
        .unwrap()
        .trim_start_matches('\u{feff}')
        .parse()
        .unwrap();
    config["notify"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect()
}

fn claude_commands(config: &std::path::Path, event: &str) -> Vec<String> {
    let text = std::fs::read_to_string(config).unwrap();
    let config: Value = serde_json::from_str(text.trim_start_matches('\u{feff}')).unwrap();
    config["hooks"][event]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|entry| entry["hooks"].as_array().unwrap().clone())
        .map(|item| item["command"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn codex_setup_migrates_nested_collector_only_notify_without_duplicates() {
    let moved = serde_json::json!([
        r"C:\Old Place\CODEX-SESSIONS-COLLECTOR.EXE",
        "codex",
        "notify",
        "--db",
        "old.sqlite"
    ]);
    let nested = serde_json::json!([
        "/opt/codex-sessions-collector",
        "codex",
        "notify",
        "--previous-notify",
        moved.to_string()
    ]);
    for existing in [moved, nested] {
        let f = Fixture::new("codex");
        write_notify(
            &f.config,
            &serde_json::from_value::<Vec<String>>(existing).unwrap(),
        );
        assert_eq!(
            f.run("status", &[], 1)["configuration"]["hook_state"],
            "different_arguments"
        );
        let applied = f.run("setup", &["--apply"], 0);
        assert!(applied["config_changed"].as_bool().unwrap());
        assert!(
            !std::fs::read_to_string(&f.config)
                .unwrap()
                .contains("notify")
        );
        for event in ["Stop", "Interrupt"] {
            let commands = claude_commands(&f.hooks_config(), event);
            assert_eq!(commands.len(), 1);
            assert!(commands[0].contains("hook"));
            assert!(!commands[0].contains("notify"));
        }
        assert_eq!(f.run("setup", &[], 0)["changed"], false);
        assert_eq!(
            f.run("status", &[], 0)["configuration"]["hook_state"],
            "registered"
        );
    }
}

fn write_notify(config: &std::path::Path, args: &[String]) {
    let mut array = toml_edit::Array::new();
    for arg in args {
        array.push(arg.as_str());
    }
    std::fs::write(
        config,
        format!("# retained comment\nmodel = 'x'\nnotify = {array}\n"),
    )
    .unwrap();
}

#[test]
fn claude_setup_replaces_its_managed_hook_when_arguments_or_location_change() {
    let f = Fixture::new("claude");
    let foreign =
        r#""D:\Moved\Codex-Sessions-Collector.exe" "claude" "hook" "--db" "D:\old.sqlite""#;
    std::fs::write(
        &f.config,
        serde_json::json!({"hooks":{"Stop":[{"hooks":[
            {"type":"command","command":"old-hook private-hook-secret"},
            {"type":"command","command":foreign}
        ]}]}})
        .to_string(),
    )
    .unwrap();
    f.setup();
    let other = f.temp.path().join("other-sessions");
    std::fs::create_dir(&other).unwrap();
    let mut cmd = collector();
    cmd.args(["claude", "setup", "--json", "--apply", "--root"])
        .arg(&other)
        .arg("--config")
        .arg(&f.config)
        .arg("--db")
        .arg(&f.db);
    let out = cmd.output().unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
    for event in ["Stop", "SessionEnd"] {
        let commands = claude_commands(&f.config, event);
        let managed: Vec<_> = commands
            .iter()
            .filter(|c| c.to_ascii_lowercase().contains("codex-sessions-collector"))
            .collect();
        assert_eq!(managed.len(), 1, "{event}: {commands:?}");
        assert!(managed[0].contains("other-sessions"), "{commands:?}");
        assert!(!managed[0].contains("Moved"), "{commands:?}");
        if event == "Stop" {
            assert!(commands.iter().any(|c| c == "old-hook private-hook-secret"));
        }
    }
}

#[test]
fn status_distinguishes_changed_managed_hook_from_absent_hook() {
    for harness in ["codex", "claude"] {
        let f = Fixture::new(harness);
        let report = f.run("status", &[], 1);
        assert_eq!(report["configuration"]["hook_state"], "absent", "{report}");
        assert_eq!(report["configuration"]["hook_registered"], false);
        f.setup();
        assert_eq!(
            f.run("status", &[], 0)["configuration"]["hook_state"],
            "registered"
        );
        let other = f.temp.path().join("other-sessions");
        std::fs::create_dir(&other).unwrap();
        // Codex accepts one Windows root, so change its WSL root instead.
        let flag = if harness == "codex" {
            "--wsl-root"
        } else {
            "--claude-root"
        };
        let report = f.run("verify", &[flag, other.to_str().unwrap()], 1);
        assert_eq!(report["configuration"]["hook_registered"], false);
        assert_eq!(
            report["configuration"]["hook_state"], "different_arguments",
            "{report}"
        );
        assert!(
            report["configuration"]["action"]
                .as_str()
                .unwrap()
                .contains("different arguments")
        );
    }
}

#[test]
fn setup_backs_up_an_existing_configuration_before_replacing_it() {
    for harness in ["codex", "claude"] {
        let f = Fixture::new(harness);
        let applied = f.run("setup", &["--apply"], 0);
        assert!(applied["backup"].is_null(), "{applied}");
        let original = r#"{"api_key":"private-test-secret"}"#.to_owned();
        std::fs::write(f.hooks_config(), &original).unwrap();
        let applied = f.run("setup", &["--apply"], 0);
        let backup = std::path::PathBuf::from(applied["backup"].as_str().unwrap());
        assert_eq!(backup.parent(), f.hooks_config().parent());
        assert_eq!(std::fs::read_to_string(&backup).unwrap(), original);
        assert_ne!(std::fs::read_to_string(f.hooks_config()).unwrap(), original);
        assert!(!applied.to_string().contains("private-test-secret"));
        // An unchanged repeat writes neither the file nor another backup.
        assert!(f.run("setup", &["--apply"], 0)["backup"].is_null());
    }
}

#[test]
#[cfg(unix)]
fn setup_keeps_a_secret_configurations_mode_and_owner_on_unix() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    for harness in ["codex", "claude"] {
        let f = Fixture::new(harness);
        let original = if harness == "codex" {
            r#"{"api_key":"private-test-secret"}"#.to_owned()
        } else {
            r#"{"api_key":"private-test-secret"}"#.to_owned()
        };
        std::fs::write(&f.hooks_config(), &original).unwrap();
        std::fs::set_permissions(&f.hooks_config(), std::fs::Permissions::from_mode(0o600))
            .unwrap();
        let before = std::fs::metadata(&f.hooks_config()).unwrap();
        let applied = f.run("setup", &["--apply"], 0);
        let after = std::fs::metadata(&f.hooks_config()).unwrap();
        assert_ne!(
            std::fs::read_to_string(&f.hooks_config()).unwrap(),
            original
        );
        assert_eq!(after.permissions().mode() & 0o7777, 0o600, "{harness}");
        assert_eq!((after.uid(), after.gid()), (before.uid(), before.gid()));
        let backup = std::path::PathBuf::from(applied["backup"].as_str().unwrap());
        let backup = std::fs::metadata(backup).unwrap();
        assert_eq!(backup.permissions().mode() & 0o7777, 0o600, "{harness}");

        // A group-readable file keeps its wider mode; setup does not guess.
        std::fs::set_permissions(&f.hooks_config(), std::fs::Permissions::from_mode(0o640))
            .unwrap();
        std::fs::write(&f.hooks_config(), &original).unwrap();
        f.setup();
        let after = std::fs::metadata(&f.hooks_config()).unwrap();
        assert_eq!(after.permissions().mode() & 0o7777, 0o640, "{harness}");
    }
}

#[test]
fn setup_accepts_and_preserves_a_utf8_byte_order_mark() {
    for harness in ["codex", "claude"] {
        let f = Fixture::new(harness);
        let body = if harness == "codex" {
            "model = 'x'\n"
        } else {
            r#"{"other":{"value":42}}"#
        };
        std::fs::write(&f.config, format!("\u{feff}{body}")).unwrap();
        f.setup();
        let written = std::fs::read_to_string(&f.config).unwrap();
        assert!(written.starts_with('\u{feff}'), "{written}");
        if harness == "codex" {
            assert_eq!(claude_commands(&f.hooks_config(), "Stop").len(), 1);
            assert_eq!(written, format!("\u{feff}{body}"));
        } else {
            assert_eq!(claude_commands(&f.config, "Stop").len(), 1);
        }
        assert_eq!(f.run("setup", &[], 0)["changed"], false);
        assert_eq!(
            f.run("status", &[], 0)["configuration"]["hook_state"],
            "registered"
        );
    }
}

#[test]
#[cfg(windows)]
fn claude_setup_refuses_paths_that_git_bash_would_expand() {
    for name in ["dollar$HOME", "tick`id`"] {
        let f = Fixture::new("claude");
        let root = f.temp.path().join(name);
        std::fs::create_dir(&root).unwrap();
        let mut cmd = collector();
        cmd.args(["claude", "setup", "--json", "--apply", "--root"])
            .arg(&root)
            .arg("--config")
            .arg(&f.config)
            .arg("--db")
            .arg(&f.db);
        let out = cmd.output().unwrap();
        assert_eq!(out.status.code(), Some(1));
        let report: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert!(
            report["error"].as_str().unwrap().contains("expansion"),
            "{report}"
        );
        assert!(!f.config.exists());
    }
}

fn removal_fixture(
    harness: &str,
    original: &str,
) -> (TempDir, std::path::PathBuf, std::path::PathBuf) {
    let temp = TempDir::new(&format!("remove-{harness}"));
    let root = temp.path().join("sessions");
    std::fs::create_dir(&root).unwrap();
    let config = temp.path().join(if harness == "codex" {
        "config.toml"
    } else {
        "settings.json"
    });
    std::fs::write(&config, original).unwrap();
    (temp, root, config)
}

fn setup_run(
    harness: &str,
    root: &std::path::Path,
    config: &std::path::Path,
    flags: &[&str],
) -> Value {
    let output = collector()
        .args([harness, "setup", "--json", "--root"])
        .arg(root)
        .arg("--config")
        .arg(config)
        .args(flags)
        .output()
        .unwrap();
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(
        output.status.success(),
        "{text} {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!text.contains("private-hook-secret"));
    serde_json::from_str(&text).unwrap()
}

#[test]
fn codex_remove_restores_unknown_previous_notify_without_migrating_it() {
    let f = Fixture::new("codex");
    let previous = serde_json::json!(["previous-command", "private-hook-secret"]).to_string();
    write_notify(
        &f.config,
        &[
            "codex-sessions-collector".into(),
            "codex".into(),
            "notify".into(),
            "--previous-notify".into(),
            previous,
        ],
    );
    let original = std::fs::read(&f.config).unwrap();
    let preview = f.run("setup", &["--remove"], 0);
    assert_eq!(preview["changed"], true);
    assert_eq!(std::fs::read(&f.config).unwrap(), original);
    let applied = f.run("setup", &["--remove", "--apply"], 0);
    assert_eq!(preview["planned_sha256"], applied["planned_sha256"]);
    assert_eq!(applied["preserves_existing_hook"], true);
    assert_eq!(
        notify_args(&f.config),
        ["previous-command", "private-hook-secret"]
    );
    assert_eq!(
        f.run("setup", &["--remove", "--apply"], 0)["changed"],
        false
    );
}

#[test]
fn codex_remove_drops_a_notify_that_had_no_predecessor() {
    let (_temp, root, config) = removal_fixture("codex", "model = 'x'\n");
    setup_run("codex", &root, &config, &["--apply"]);
    setup_run("codex", &root, &config, &["--remove", "--apply"]);
    let text = std::fs::read_to_string(&config).unwrap();
    assert!(!text.contains("notify"), "{text}");
    assert!(text.contains("model = 'x'"));
}

#[test]
fn removal_works_when_session_folders_are_gone_and_never_touches_a_foreign_hook() {
    let foreign = "notify = ['other-tool', 'notify']\n";
    let (_temp, root, config) = removal_fixture("codex", foreign);
    let applied = setup_run("codex", &root, &config, &["--remove", "--apply"]);
    assert_eq!(applied["changed"], false);
    assert_eq!(std::fs::read_to_string(&config).unwrap(), foreign);
    std::fs::write(&config, "model = 'x'\n").unwrap();
    setup_run("codex", &root, &config, &["--apply"]);
    std::fs::write(&config, foreign).unwrap();
    std::fs::remove_dir(&root).unwrap();
    setup_run("codex", &root, &config, &["--remove", "--apply"]);
    assert_eq!(notify_args(&config), ["other-tool", "notify"]);
}

#[test]
fn claude_remove_deletes_only_managed_hooks_and_prunes_what_it_created() {
    let original = r#"{"api_key":"private-test-secret","hooks":{"Stop":[{"hooks":[{"type":"command","command":"old-hook private-hook-secret"}]}]},"other":{"value":42}}"#;
    let (_temp, root, config) = removal_fixture("claude", original);
    setup_run("claude", &root, &config, &["--apply"]);
    assert_eq!(claude_commands(&config, "Stop").len(), 2);
    let applied = setup_run("claude", &root, &config, &["--remove", "--apply"]);
    // Other hooks stay, but nothing was chained or restored.
    assert_eq!(applied["preserves_existing_hook"], false);
    assert_eq!(applied["changed"], true);
    let restored: Value = serde_json::from_str(&std::fs::read_to_string(&config).unwrap()).unwrap();
    assert_eq!(restored, serde_json::from_str::<Value>(original).unwrap());
    // A configuration that only held the managed hooks loses the empty object.
    let (_temp, root, config) = removal_fixture("claude", r#"{"model":"x"}"#);
    setup_run("claude", &root, &config, &["--apply"]);
    setup_run("claude", &root, &config, &["--remove", "--apply"]);
    let restored: Value = serde_json::from_str(&std::fs::read_to_string(&config).unwrap()).unwrap();
    assert_eq!(restored, serde_json::json!({"model":"x"}));
}

#[test]
fn claude_remove_does_not_claim_a_restore_when_unrelated_hooks_merely_remain() {
    let original = r#"{"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"guard private-hook-secret"}]}]}}"#;
    let (_temp, root, config) = removal_fixture("claude", original);
    setup_run("claude", &root, &config, &["--apply"]);
    let applied = setup_run("claude", &root, &config, &["--remove", "--apply"]);
    assert_eq!(applied["changed"], true);
    assert_eq!(applied["preserves_existing_hook"], false);
    let restored: Value = serde_json::from_str(&std::fs::read_to_string(&config).unwrap()).unwrap();
    assert_eq!(restored, serde_json::from_str::<Value>(original).unwrap());
}

fn collector_notify(previous: Option<&[String]>) -> Vec<String> {
    let mut args = vec![
        "codex-sessions-collector.exe".into(),
        "codex".into(),
        "notify".into(),
    ];
    if let Some(previous) = previous {
        args.extend([
            "--previous-notify".into(),
            serde_json::to_string(previous).unwrap(),
        ]);
    }
    args
}

fn computer_notify(previous: Option<&[String]>) -> Vec<String> {
    let mut args = vec![
        r"C:\discovered-version\codex-computer-use.exe".into(),
        "turn-ended".into(),
    ];
    if let Some(previous) = previous {
        args.extend([
            "--previous-notify".into(),
            serde_json::to_string(previous).unwrap(),
        ]);
    }
    args
}

#[test]
fn codex_native_repair_preserves_foreign_hooks_settings_and_positions() {
    let f = Fixture::new("codex");
    let stale = r#""D:\moved\codex-sessions-collector.exe" "codex" "hook" "--db" "old.sqlite""#;
    let foreign_a = serde_json::json!({"type":"command", "command":"ActiveAppView private-hook-secret", "timeout":7});
    let foreign_b = serde_json::json!({"type":"command", "command":"rtk rewrite", "async":true});
    let stale_item = serde_json::json!({"type":"command","command":stale});
    let original = serde_json::json!({"enabled":true, "other":{"private-test-secret":42}, "hooks":{
        "Stop":[{"hooks":[foreign_a.clone(),stale_item.clone(),foreign_b.clone()]},
            {"hooks":[stale_item]}, {"matcher":"x","hooks":[foreign_b.clone()]}],
        "PreToolUse":[{"matcher":"Bash","hooks":[foreign_b.clone()]}]}});
    std::fs::write(f.hooks_config(), original.to_string()).unwrap();
    std::fs::write(
        &f.config,
        "# trust must stay unchanged\n[hooks.state]\nprivate_hash = true\n",
    )
    .unwrap();
    let config_before = std::fs::read(&f.config).unwrap();
    f.setup();
    let updated: Value = serde_json::from_slice(&std::fs::read(f.hooks_config()).unwrap()).unwrap();
    assert_eq!(updated["hooks"]["Stop"][0]["hooks"][0], foreign_a);
    assert_eq!(updated["hooks"]["Stop"][0]["hooks"][2], foreign_b);
    assert!(
        updated["hooks"]["Stop"][0]["hooks"][1]["command"]
            .as_str()
            .unwrap()
            .contains("hook")
    );
    assert_eq!(updated["hooks"]["Stop"][2], original["hooks"]["Stop"][2]);
    assert_eq!(
        updated["hooks"]["PreToolUse"],
        original["hooks"]["PreToolUse"]
    );
    assert_eq!(updated["other"], original["other"]);
    assert_eq!(std::fs::read(&f.config).unwrap(), config_before);
    let before = std::fs::read(f.hooks_config()).unwrap();
    assert_eq!(f.run("setup", &["--apply"], 0)["changed"], false);
    assert_eq!(std::fs::read(f.hooks_config()).unwrap(), before);
    let rejected = f.run("setup", &["--remove", "--apply"], 1);
    assert!(
        rejected["error"]
            .as_str()
            .unwrap()
            .contains("handler index")
    );
    assert_eq!(std::fs::read(f.hooks_config()).unwrap(), before);
    assert_eq!(std::fs::read(&f.config).unwrap(), config_before);
}

fn assert_codex_mixed_handler_shift_refused(remove: bool, duplicate: bool, conditional: bool) {
    let f = Fixture::new("codex");
    let managed = serde_json::json!({"type":"command",
        "command":r#""C:\old\codex-sessions-collector.exe" "codex" "hook""#});
    let mut handlers = vec![managed.clone()];
    if duplicate {
        handlers.push(managed);
    }
    let foreign_index = handlers.len();
    handlers.push(serde_json::json!({"type":"command", "command":"ActiveAppView rtk"}));
    let mut group = serde_json::json!({"hooks":handlers});
    if conditional {
        group["matcher"] = serde_json::json!("conditional");
    }
    std::fs::write(
        f.hooks_config(),
        serde_json::json!({"hooks":{"Stop":[group]}}).to_string(),
    )
    .unwrap();
    // Existing state is fixture data, not a newly computed trust decision.
    let config = format!(
        "# saved user hook decisions\n[hooks.state.\"stop:0:{foreign_index}\"]\nenabled = false\ntrusted_hash = 'sha256:preexisting-fixture'\n"
    );
    std::fs::write(&f.config, config).unwrap();
    let config_before = std::fs::read(&f.config).unwrap();
    let hooks_before = std::fs::read(f.hooks_config()).unwrap();
    let applied_flags = if remove {
        vec!["--remove", "--apply"]
    } else {
        vec!["--apply"]
    };
    let preview_flags = if remove { vec!["--remove"] } else { vec![] };
    for flags in [applied_flags, preview_flags] {
        let report = f.run("setup", &flags, 1);
        let error = report["error"].as_str().unwrap();
        assert!(
            error.contains("handler index") && error.contains("/hooks"),
            "{report}"
        );
        assert_eq!(std::fs::read(&f.config).unwrap(), config_before);
        assert_eq!(std::fs::read(f.hooks_config()).unwrap(), hooks_before);
        let entries: Vec<_> = std::fs::read_dir(f.temp.path())
            .unwrap()
            .filter_map(Result::ok)
            .collect();
        assert!(!entries.iter().any(|entry| {
            entry
                .file_name()
                .to_string_lossy()
                .contains("collector-backup")
        }));
    }
}

#[test]
fn codex_mixed_handler_removal_refuses_foreign_trust_index_shift() {
    assert_codex_mixed_handler_shift_refused(true, false, false);
}

#[test]
fn codex_mixed_handler_duplicate_repair_refuses_foreign_trust_index_shift() {
    assert_codex_mixed_handler_shift_refused(false, true, false);
}

#[test]
fn codex_mixed_handler_conditional_repair_refuses_foreign_trust_index_shift() {
    assert_codex_mixed_handler_shift_refused(false, false, true);
}

#[test]
fn codex_setup_refuses_unknown_notify_even_inside_computer_use_without_writing() {
    let unknown = vec!["unrelated-notifier".into(), "private-hook-secret".into()];
    let helper = computer_notify(Some(&unknown));
    for args in [
        unknown.clone(),
        collector_notify(Some(&unknown)),
        helper.clone(),
        computer_notify(Some(&collector_notify(Some(&unknown)))),
        collector_notify(Some(&helper)),
    ] {
        let f = Fixture::new("codex");
        write_notify(&f.config, &args);
        let original = std::fs::read(&f.config).unwrap();
        for flags in [&[][..], &["--apply"][..]] {
            let report = f.run("setup", flags, 1);
            assert!(
                report["error"].as_str().unwrap().contains("full-content"),
                "{report}"
            );
            assert!(!report.to_string().contains("private-hook-secret"));
            assert_eq!(std::fs::read(&f.config).unwrap(), original);
            assert!(!f.hooks_config().exists());
            assert!(
                !f.config
                    .with_file_name("collector-computer-use.json")
                    .exists()
            );
        }
    }
}

#[test]
fn codex_computer_use_migration_keeps_discovered_helper_chain_and_cleanup_on_removal() {
    let only_helper = computer_notify(None);
    let nested_helper = computer_notify(Some(&only_helper));
    for legacy in [
        computer_notify(Some(&collector_notify(None))),
        collector_notify(Some(&nested_helper)),
        computer_notify(Some(&collector_notify(Some(&only_helper)))),
    ] {
        let f = Fixture::new("codex");
        write_notify(&f.config, &legacy);
        let before = std::fs::read(&f.config).unwrap();
        let preview = f.run("setup", &[], 0);
        assert_eq!(std::fs::read(&f.config).unwrap(), before);
        assert!(
            preview["vendor_notice"]
                .as_str()
                .unwrap()
                .contains("reinstall")
        );
        let applied = f.run("setup", &["--apply"], 0);
        assert_eq!(applied["planned_sha256"], preview["planned_sha256"]);
        let saved = f.config.with_file_name("collector-computer-use.json");
        let command: Vec<String> = serde_json::from_slice(&std::fs::read(&saved).unwrap()).unwrap();
        let expected = if legacy == computer_notify(Some(&collector_notify(None))) {
            &only_helper
        } else {
            &nested_helper
        };
        assert_eq!(&command, expected);
        assert!(
            !std::fs::read_to_string(&f.config)
                .unwrap()
                .contains("notify")
        );
        for event in ["Stop", "Interrupt", "SubagentStop"] {
            let commands = claude_commands(&f.hooks_config(), event);
            assert_eq!(commands.len(), if event == "SubagentStop" { 1 } else { 2 });
            assert_eq!(
                commands
                    .iter()
                    .filter(|command| command.contains("computer-use-hook"))
                    .count(),
                1
            );
        }
        let native: Value =
            serde_json::from_slice(&std::fs::read(f.hooks_config()).unwrap()).unwrap();
        for group in native["hooks"]["Interrupt"].as_array().unwrap() {
            for hook in group["hooks"].as_array().unwrap() {
                assert_eq!(hook["timeout"], 3);
            }
        }
        let stable = std::fs::read(f.hooks_config()).unwrap();
        let saved_before = std::fs::read(&saved).unwrap();
        assert_eq!(f.run("setup", &["--apply"], 0)["changed"], false);
        assert_eq!(std::fs::read(f.hooks_config()).unwrap(), stable);
        assert_eq!(
            f.run("status", &[], 0)["configuration"]["hook_state"],
            "registered"
        );
        // Vendor reinstatement is unhealthy even when the native entries stay.
        write_notify(&f.config, &legacy);
        assert_eq!(
            f.run("status", &[], 1)["configuration"]["hook_state"],
            "different_arguments"
        );
        f.setup();
        // Collector removal leaves cleanup native, including its command file.
        f.run("setup", &["--remove", "--apply"], 0);
        for event in ["Stop", "Interrupt", "SubagentStop"] {
            let commands = claude_commands(&f.hooks_config(), event);
            assert_eq!(commands.len(), 1);
            assert!(commands[0].contains("computer-use-hook"));
        }
        assert_eq!(std::fs::read(&saved).unwrap(), saved_before);
        assert!(
            !std::fs::read_to_string(&f.config)
                .unwrap()
                .contains("notify")
        );
        assert_eq!(
            f.run("setup", &["--remove", "--apply"], 0)["changed"],
            false
        );
    }
    // Removal from an unmigrated legacy configuration also keeps cleanup
    // native, instead of restoring the oversized computer-use notify entry.
    let f = Fixture::new("codex");
    let arm64 = vec![
        r"C:\discovered-version\codex-computer-use-arm64.exe".into(),
        "turn-ended".into(),
    ];
    write_notify(&f.config, &collector_notify(Some(&arm64)));
    f.run("setup", &["--remove", "--apply"], 0);
    assert!(
        !std::fs::read_to_string(&f.config)
            .unwrap()
            .contains("notify")
    );
    for event in ["Stop", "Interrupt", "SubagentStop"] {
        let commands = claude_commands(&f.hooks_config(), event);
        assert_eq!(commands.len(), 1);
        assert!(commands[0].contains("computer-use-hook"));
    }
}

#[test]
#[cfg(windows)]
fn codex_failed_config_replacement_rolls_back_new_and_existing_hooks_and_sidecar() {
    use std::os::windows::fs::OpenOptionsExt;
    for existing in [false, true] {
        let f = Fixture::new("codex");
        write_notify(&f.config, &computer_notify(Some(&collector_notify(None))));
        let before_config = std::fs::read(&f.config).unwrap();
        let sidecar = f.config.with_file_name("collector-computer-use.json");
        let original_hooks = "{\"other\":\"private-test-secret\"}\n";
        let original_sidecar =
            serde_json::to_string(&vec!["/old/codex-computer-use", "turn-ended"]).unwrap();
        if existing {
            std::fs::write(f.hooks_config(), original_hooks).unwrap();
            std::fs::write(&sidecar, &original_sidecar).unwrap();
        }
        let held = std::fs::OpenOptions::new()
            .read(true)
            .share_mode(1)
            .open(&f.config)
            .unwrap();
        let report = f.run("setup", &["--apply"], 1);
        drop(held);
        assert!(
            report["error"]
                .as_str()
                .unwrap()
                .contains("rollback: completed"),
            "{report}"
        );
        assert!(!report.to_string().contains("private-test-secret"));
        assert_eq!(std::fs::read(&f.config).unwrap(), before_config);
        if existing {
            assert_eq!(
                std::fs::read_to_string(f.hooks_config()).unwrap(),
                original_hooks
            );
            assert_eq!(std::fs::read_to_string(&sidecar).unwrap(), original_sidecar);
            assert!(
                std::fs::read_dir(f.temp.path())
                    .unwrap()
                    .filter_map(Result::ok)
                    .any(|entry| entry
                        .file_name()
                        .to_string_lossy()
                        .ends_with("collector-backup"))
            );
        } else {
            assert!(!f.hooks_config().exists());
            assert!(!sidecar.exists());
        }
    }
}

#[test]
fn codex_invalid_native_hook_document_never_changes_legacy_configuration() {
    for body in [
        "{private-test-secret",
        "[]",
        r#"{"hooks":[]}"#,
        r#"{"hooks":{"Stop":{}}}"#,
        r#"{"hooks":{"Stop":[{"hooks":{}}]}}"#,
    ] {
        let f = Fixture::new("codex");
        write_notify(&f.config, &collector_notify(None));
        std::fs::write(f.hooks_config(), body).unwrap();
        let before = std::fs::read(&f.config).unwrap();
        let report = f.run("setup", &["--apply"], 1);
        assert!(!report.to_string().contains("private-test-secret"));
        assert_eq!(std::fs::read(&f.config).unwrap(), before);
        assert_eq!(std::fs::read_to_string(f.hooks_config()).unwrap(), body);
    }
}

#[test]
#[cfg(any(windows, unix))]
fn codex_shared_hook_symlink_is_preserved_and_reports_the_canonical_target() {
    let f = Fixture::new("codex");
    let canonical = f.temp.path().join("shared-hooks.json");
    std::fs::write(&canonical, "{\"other\":42}").unwrap();
    #[cfg(windows)]
    let result = std::os::windows::fs::symlink_file(&canonical, f.hooks_config());
    #[cfg(unix)]
    let result = std::os::unix::fs::symlink(&canonical, f.hooks_config());
    if let Err(error) = result {
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
        eprintln!("symlink creation unavailable: {error}; symlink behavior not exercised");
        return;
    }
    let report = f.run("setup", &["--apply"], 1);
    let error = report["error"].as_str().unwrap();
    assert!(
        error.contains("symbolic link") && error.contains("canonical target"),
        "{report}"
    );
    assert!(error.contains("shared-hooks.json"));
    assert_eq!(
        std::fs::read_to_string(&canonical).unwrap(),
        "{\"other\":42}"
    );
    assert!(
        std::fs::symlink_metadata(f.hooks_config())
            .unwrap()
            .file_type()
            .is_symlink()
    );
    // Remove the link itself before the fixture's recursive cleanup.
    std::fs::remove_file(f.hooks_config()).unwrap();
}

#[test]
#[cfg(windows)]
fn codex_replacement_preserves_explicit_windows_acl_owner_and_backup_permissions() {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Foundation::LocalFree;
    use windows_sys::Win32::Security::Authorization::{
        ConvertSecurityDescriptorToStringSecurityDescriptorW, GetNamedSecurityInfoW,
        SE_FILE_OBJECT, SetNamedSecurityInfoW,
    };
    use windows_sys::Win32::Security::{
        DACL_SECURITY_INFORMATION, GROUP_SECURITY_INFORMATION, OWNER_SECURITY_INFORMATION,
        PROTECTED_DACL_SECURITY_INFORMATION,
    };
    fn security(path: &std::path::Path, protect: bool) -> String {
        let name: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
        let flags =
            OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION;
        let mut descriptor = std::ptr::null_mut();
        let mut dacl = std::ptr::null_mut();
        // SAFETY: name and output pointers remain live for this synchronous call.
        assert_eq!(
            unsafe {
                GetNamedSecurityInfoW(
                    name.as_ptr(),
                    SE_FILE_OBJECT,
                    flags,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    &mut dacl,
                    std::ptr::null_mut(),
                    &mut descriptor,
                )
            },
            0
        );
        if protect {
            // SAFETY: dacl points into descriptor until LocalFree below.
            assert_eq!(
                unsafe {
                    SetNamedSecurityInfoW(
                        name.as_ptr(),
                        SE_FILE_OBJECT,
                        DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                        std::ptr::null_mut(),
                        std::ptr::null_mut(),
                        dacl,
                        std::ptr::null_mut(),
                    )
                },
                0
            );
        }
        let mut text = std::ptr::null_mut();
        let mut length = 0;
        // SAFETY: descriptor is initialized and conversion allocates text.
        assert_ne!(
            unsafe {
                ConvertSecurityDescriptorToStringSecurityDescriptorW(
                    descriptor,
                    1,
                    flags,
                    &mut text,
                    &mut length,
                )
            },
            0
        );
        // SAFETY: length includes the terminating nul; both buffers are owned.
        let result = unsafe {
            let result =
                String::from_utf16_lossy(std::slice::from_raw_parts(text, length as usize - 1));
            LocalFree(text.cast());
            LocalFree(descriptor.cast());
            result
        };
        if protect {
            security(path, false)
        } else {
            result
        }
    }
    let f = Fixture::new("codex");
    write_notify(&f.config, &computer_notify(Some(&collector_notify(None))));
    let sidecar = f.config.with_file_name("collector-computer-use.json");
    std::fs::write(
        &sidecar,
        serde_json::to_string(&computer_notify(None)).unwrap(),
    )
    .unwrap();
    std::fs::write(f.hooks_config(), "{\"api_key\":\"private-test-secret\"}").unwrap();
    let paths = [&f.config, &f.hooks_config(), &sidecar];
    let before: Vec<_> = paths.iter().map(|path| security(path, true)).collect();
    let applied = f.run("setup", &["--apply"], 0);
    for (path, before) in paths.iter().zip(&before) {
        assert_eq!(security(path, false), *before);
        let backup = applied["backups"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .map(std::path::PathBuf::from)
            .find(|backup| {
                backup
                    .file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with(&format!("{}.", path.file_name().unwrap().to_string_lossy()))
            })
            .unwrap();
        assert_eq!(security(&backup, false), *before);
    }
}
