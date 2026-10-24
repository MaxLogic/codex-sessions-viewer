mod support;

use std::net::TcpListener;
use std::process::{Child, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use codex_sessions_collector::contract::{Envelope, Record};
use serde_json::{Value, json};
use support::{TempDir, collector, sample_snapshot};

const MACHINE_TOKEN: &str = "query-machine-token-123456789012345";
const OWNER_TOKEN: &str = "query-owner-token-12345678901234567";

struct Hub(Child, String);

impl Drop for Hub {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn start(temp: &TempDir) -> Hub {
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let config = temp.path().join("hub.json");
    std::fs::write(
        &config,
        json!({
            "owner_token": OWNER_TOKEN,
            "machines": {"test-machine": MACHINE_TOKEN}
        })
        .to_string(),
    )
    .unwrap();
    let url = format!("http://127.0.0.1:{port}");
    let child = support::test_command(env!("CARGO_BIN_EXE_codex-sessions-hub"))
        .arg(format!("127.0.0.1:{port}"))
        .arg(temp.path().join("hub-data"))
        .arg(config)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let hub = Hub(child, url);
    let deadline = Instant::now() + Duration::from_secs(10);
    while ureq::get(format!("{}/v1/health", hub.1)).call().is_err() {
        assert!(Instant::now() < deadline, "hub did not start");
        thread::sleep(Duration::from_millis(25));
    }
    hub
}

fn remote(hub: &Hub, args: &[&str]) -> Value {
    let mut response = ureq::post(format!("{}/v1/query", hub.1))
        .header("Authorization", format!("Bearer {OWNER_TOKEN}"))
        .send_json(json!({"protocol":1,"machine":"test-machine","args":args}))
        .unwrap();
    response.body_mut().read_json().unwrap()
}

fn local(temp: &TempDir, args: &[&str]) -> Value {
    let output = collector()
        .arg("query")
        .args(args)
        .arg("--db")
        .arg(temp.path().join("hub-data/test-machine.sqlite"))
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

#[test]
fn remote_queries_preserve_local_contract_filters_paging_context_and_usage() {
    let temp = TempDir::new("hub_query");
    let hub = start(&temp);
    let snapshots = ["one", "two"].map(|id| {
        serde_json::to_value(Envelope::new(Record::SessionSnapshot(Box::new(
            sample_snapshot(id),
        ))))
        .unwrap()
    });
    let mut response = ureq::post(format!("{}/v1/ingest", hub.1))
        .header("Authorization", format!("Bearer {MACHINE_TOKEN}"))
        .send_json(json!({"protocol":1,"sequence":1,"batch_id":"first","records":snapshots}))
        .unwrap();
    let _: Value = response.body_mut().read_json().unwrap();

    let page = remote(&hub, &["sessions", "--limit", "1", "--harness", "codex"]);
    let direct = local(&temp, &["sessions", "--limit", "1", "--harness", "codex"]);
    assert_eq!(page["contract"], direct["contract"]);
    assert_eq!(page["results"], direct["results"]);
    assert_eq!(page["next_cursor"], direct["next_cursor"]);
    assert!(page["has_more"].as_bool().unwrap());
    let cli = collector()
        .args([
            "query",
            "sessions",
            "--limit",
            "1",
            "--harness",
            "codex",
            "--hub",
            &hub.1,
            "--hub-machine",
            "test-machine",
        ])
        .env("CODEX_SESSIONS_HUB_OWNER_TOKEN", OWNER_TOKEN)
        .output()
        .unwrap();
    assert!(
        cli.status.success(),
        "{}",
        String::from_utf8_lossy(&cli.stderr)
    );
    let cli: Value = serde_json::from_slice(&cli.stdout).unwrap();
    assert_eq!(cli["contract"], page["contract"]);
    assert_eq!(cli["results"], page["results"]);
    let cursor = page["next_cursor"].as_str().unwrap();
    let second = remote(
        &hub,
        &[
            "sessions",
            "--limit",
            "1",
            "--harness",
            "codex",
            "--cursor",
            cursor,
        ],
    );
    assert_ne!(
        page["results"][0]["reference"],
        second["results"][0]["reference"]
    );
    let reference = page["results"][0]["reference"].as_str().unwrap();
    for args in [
        vec!["search", "--query", "hello", "--limit", "2"],
        vec!["session", "--session", reference],
        vec!["messages", "--session", reference, "--limit", "2"],
        vec!["export", "--session", reference, "--export-format", "json"],
    ] {
        assert_eq!(
            remote(&hub, &args)["contract"],
            local(&temp, &args)["contract"]
        );
        assert_eq!(
            remote(&hub, &args)["results"],
            local(&temp, &args)["results"]
        );
    }

    let mut usage = ureq::post(format!("{}/v1/usage", hub.1))
        .header("Authorization", format!("Bearer {OWNER_TOKEN}"))
        .send_json(json!({"protocol":1,"machine":"test-machine","limit":10}))
        .unwrap();
    let usage: Value = usage.body_mut().read_json().unwrap();
    assert_eq!(usage["days"].as_array().unwrap().len(), 1);
    assert!(usage["days"][0]["input_tokens"].as_i64().unwrap() > 0);
}

#[test]
fn remote_query_rejects_protocol_and_credential_mismatch() {
    let temp = TempDir::new("hub_query_reject");
    let hub = start(&temp);
    for (token, protocol) in [("wrong", 1), (OWNER_TOKEN, 99)] {
        let result = ureq::post(format!("{}/v1/query", hub.1))
            .header("Authorization", format!("Bearer {token}"))
            .send_json(json!({"protocol":protocol,"machine":"test-machine","args":["sessions"]}));
        assert!(result.is_err());
    }
    let override_attempt = ureq::post(format!("{}/v1/query", hub.1))
        .header("Authorization", format!("Bearer {OWNER_TOKEN}"))
        .send_json(json!({"protocol":1,"machine":"test-machine","args":["sessions","--db=C:\\other.sqlite"]}));
    assert!(override_attempt.is_err());
}

#[test]
fn remote_query_never_forwards_to_another_hub_with_the_server_credential() {
    let temp = TempDir::new("hub_query_forward");
    // Another destination that must never receive a connection.
    let trap = TcpListener::bind("127.0.0.1:0").unwrap();
    trap.set_nonblocking(true).unwrap();
    let trap_url = format!("http://{}", trap.local_addr().unwrap());
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    let config = temp.path().join("hub.json");
    std::fs::write(
        &config,
        json!({"owner_token": OWNER_TOKEN, "machines": {"test-machine": MACHINE_TOKEN}})
            .to_string(),
    )
    .unwrap();
    // The hub process has an owner credential in its environment, which a
    // forwarded `--hub` would send to the chosen destination.
    let child = support::test_command(env!("CARGO_BIN_EXE_codex-sessions-hub"))
        .arg(format!("127.0.0.1:{port}"))
        .arg(temp.path().join("hub-data"))
        .arg(config)
        .env("CODEX_SESSIONS_HUB_OWNER_TOKEN", OWNER_TOKEN)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let hub = Hub(child, format!("http://127.0.0.1:{port}"));
    let deadline = Instant::now() + Duration::from_secs(10);
    while ureq::get(format!("{}/v1/health", hub.1)).call().is_err() {
        assert!(Instant::now() < deadline, "hub did not start");
        thread::sleep(Duration::from_millis(25));
    }
    for args in [
        vec![
            "sessions",
            "--hub",
            &trap_url,
            "--hub-machine",
            "test-machine",
        ],
        vec!["sessions", "--hub-machine=test-machine", "--hub=x"],
        vec!["sessions", "--format", "text"],
        vec!["sessions", "--unknown-option", "1"],
        vec!["--hub", &trap_url],
    ] {
        let result = ureq::post(format!("{}/v1/query", hub.1))
            .header("Authorization", format!("Bearer {OWNER_TOKEN}"))
            .config()
            .timeout_global(Some(Duration::from_secs(20)))
            .build()
            .send_json(json!({"protocol":1,"machine":"test-machine","args":args}));
        assert!(
            matches!(result, Err(ureq::Error::StatusCode(400))),
            "{args:?}: {result:?}"
        );
    }
    assert!(
        trap.accept().is_err(),
        "the hub connected to a forwarded destination"
    );
    // A search text that looks like an option is a value, not an option.
    let search = remote(&hub, &["search", "--query", "--hub", "--limit", "2"]);
    assert_eq!(search["results"].as_array().map(Vec::len), Some(0));
}
