mod support;

use std::net::TcpListener;
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use codex_sessions_collector::contract::{Envelope, Record, SourceStatus, ThreadName};
use codex_sessions_collector::hub_client;
use codex_sessions_collector::store::{OwnerMode, Store};
use serde_json::{Value, json};
use support::{TempDir, sample_snapshot};

const MACHINE_A_TOKEN: &str = "synthetic-machine-a-token-123456789";
const MACHINE_B_TOKEN: &str = "synthetic-machine-b-token-123456789";
const OWNER_TOKEN: &str = "synthetic-owner-token-123456789012";

struct Hub {
    child: Child,
    url: String,
}

impl Drop for Hub {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Hub {
    fn restart(&mut self, temp: &TempDir) {
        let address = self.url.trim_start_matches("http://");
        self.child = Command::new(env!("CARGO_BIN_EXE_codex-sessions-hub"))
            .arg(address)
            .arg(temp.path().join("hub-data"))
            .arg(temp.path().join("hub.json"))
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if ureq::get(format!("{}/v1/health", self.url)).call().is_ok() {
                break;
            }
            if let Some(status) = self.child.try_wait().unwrap() {
                panic!("hub exited during restart: {status}");
            }
            assert!(Instant::now() < deadline, "hub did not restart");
            thread::sleep(Duration::from_millis(30));
        }
    }
}

fn start(temp: &TempDir) -> Hub {
    start_with(temp, json!({}))
}

fn start_with(temp: &TempDir, extra: Value) -> Hub {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let config = temp.path().join("hub.json");
    let mut value = json!({
        "owner_token": OWNER_TOKEN,
        "machines": {"machine-a": MACHINE_A_TOKEN, "machine-b": MACHINE_B_TOKEN}
    });
    for (key, item) in extra.as_object().unwrap() {
        value[key] = item.clone();
    }
    std::fs::write(&config, value.to_string()).unwrap();
    let url = format!("http://127.0.0.1:{port}");
    let child = Command::new(env!("CARGO_BIN_EXE_codex-sessions-hub"))
        .arg(format!("127.0.0.1:{port}"))
        .arg(temp.path().join("hub-data"))
        .arg(config)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut hub = Hub { child, url };
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if ureq::get(format!("{}/v1/health", hub.url)).call().is_ok() {
            return hub;
        }
        if let Some(status) = hub.child.try_wait().unwrap() {
            panic!("hub exited before health check: {status}");
        }
        assert!(Instant::now() < deadline, "hub did not start");
        thread::sleep(Duration::from_millis(30));
    }
}

fn upload(
    hub: &Hub,
    token: &str,
    sequence: i64,
    batch: &str,
    records: Vec<Value>,
) -> Result<Value, ureq::Error> {
    let mut response = ureq::post(format!("{}/v1/ingest", hub.url))
        .header("Authorization", format!("Bearer {token}"))
        .send_json(json!({
            "protocol": 1, "sequence": sequence, "batch_id": batch, "records": records
        }))?;
    response.body_mut().read_json()
}

fn query(hub: &Hub, machine: &str, args: &[&str]) -> Value {
    let mut response = ureq::post(format!("{}/v1/query", hub.url))
        .header("Authorization", format!("Bearer {OWNER_TOKEN}"))
        .send_json(json!({"protocol":1,"machine":machine,"args":args}))
        .unwrap();
    response.body_mut().read_json().unwrap()
}

fn record(session: &str) -> Value {
    serde_json::to_value(Envelope::new(Record::SessionSnapshot(Box::new(
        sample_snapshot(session),
    ))))
    .unwrap()
}

fn session_count(hub: &Hub, machine: &str) -> usize {
    query(hub, machine, &["sessions", "--limit", "10"])["results"]
        .as_array()
        .unwrap()
        .len()
}

#[test]
fn hub_authenticates_and_keeps_machine_histories_separate() {
    let temp = TempDir::new("hub_auth");
    let hub = start(&temp);
    assert!(upload(&hub, "bad-token", 1, "a-1", vec![record("same-id")]).is_err());
    assert_eq!(
        upload(&hub, MACHINE_A_TOKEN, 1, "a-1", vec![record("same-id")]).unwrap()["duplicate"],
        false
    );
    assert_eq!(
        upload(&hub, MACHINE_A_TOKEN, 1, "a-1", vec![record("same-id")]).unwrap()["duplicate"],
        true
    );
    assert_eq!(session_count(&hub, "machine-a"), 1);
    assert_eq!(
        upload(&hub, MACHINE_B_TOKEN, 1, "b-1", vec![record("same-id")]).unwrap()["duplicate"],
        false
    );
    assert_eq!(session_count(&hub, "machine-b"), 1);
    assert!(
        upload(
            &hub,
            MACHINE_A_TOKEN,
            1,
            "different-batch",
            vec![record("different")]
        )
        .is_err()
    );
    assert!(upload(&hub, MACHINE_A_TOKEN, 3, "a-3", vec![record("different")]).is_err());
    assert_eq!(session_count(&hub, "machine-a"), 1);
}

#[test]
fn out_of_order_and_explicit_missing_status_preserve_newer_data() {
    let temp = TempDir::new("hub_order");
    let hub = start(&temp);
    let first = record("revisioned");
    assert!(upload(&hub, MACHINE_A_TOKEN, 1, "a-1", vec![first.clone()]).is_ok());
    let mut newer = first.clone();
    newer["record"]["source"]["modified_utc"] = json!("2026-09-11T10:00:00Z");
    newer["record"]["session"]["last_message_at_utc"] = json!("2026-09-11T10:00:00Z");
    newer["record"]["messages"][0]["content_plain"] = json!("newer content");
    assert!(upload(&hub, MACHINE_A_TOKEN, 2, "a-2", vec![newer.clone()]).is_ok());
    assert!(upload(&hub, MACHINE_A_TOKEN, 1, "a-1", vec![first.clone()]).is_ok());
    let db = temp.path().join("hub-data/machine-a.sqlite");
    let connection = rusqlite::Connection::open(db).unwrap();
    let text: String = connection
        .query_row("select content_plain from messages limit 1", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(text, "newer content");
    let source_path: String = connection
        .query_row("select source_file_path from sessions limit 1", [], |row| {
            row.get(0)
        })
        .unwrap();
    drop(connection);
    let status = Envelope::new(Record::SourceStatus(SourceStatus {
        harness: "codex".to_owned(),
        path: source_path,
        status: "missing".to_owned(),
        state: "missing".to_owned(),
        message: None,
    }));
    assert!(
        upload(
            &hub,
            MACHINE_A_TOKEN,
            3,
            "a-3",
            vec![serde_json::to_value(status).unwrap()]
        )
        .is_ok()
    );
    // Missing source is an explicit lifecycle update, not deletion of history.
    let connection =
        rusqlite::Connection::open(temp.path().join("hub-data/machine-a.sqlite")).unwrap();
    let state: String = connection
        .query_row("select source_state from sessions limit 1", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(state, "missing");
    drop(connection);
    assert_eq!(session_count(&hub, "machine-a"), 1);
    assert!(upload(&hub, MACHINE_A_TOKEN, 4, "a-4", vec![newer]).is_ok());
    assert_eq!(session_count(&hub, "machine-a"), 1);
}

#[test]
fn hub_rejects_foreign_identity_and_protocol_without_creating_history() {
    let temp = TempDir::new("hub_reject");
    let hub = start(&temp);
    let mut foreign = record("foreign");
    foreign["record"]["machine_id"] = json!("machine-b");
    assert!(upload(&hub, MACHINE_A_TOKEN, 1, "foreign", vec![foreign]).is_err());
    let bad = ureq::post(format!("{}/v1/ingest", hub.url))
        .header("Authorization", format!("Bearer {MACHINE_A_TOKEN}"))
        .send_json(json!({"protocol":99,"sequence":1,"batch_id":"bad","records":[]}));
    assert!(bad.is_err());
    assert_eq!(session_count(&hub, "machine-a"), 0);
}

#[test]
fn hub_recovers_an_empty_database_left_between_bootstrap_and_identity_assignment() {
    let temp = TempDir::new("hub_empty_identity_recovery");
    let path = temp.path().join("hub-data/machine-a.sqlite");
    let original = Store::open(&path, OwnerMode::Standalone)
        .unwrap()
        .machine_id()
        .unwrap()
        .unwrap();
    assert_ne!(original, "machine-a");
    let hub = start(&temp);
    assert_eq!(session_count(&hub, "machine-a"), 0);
    let store = Store::open(&path, OwnerMode::Standalone).unwrap();
    assert_eq!(store.machine_id().unwrap().as_deref(), Some("machine-a"));
}

#[test]
fn owner_annotations_survive_source_reingestion_and_reject_stale_edits() {
    let temp = TempDir::new("hub_annotations");
    let hub = start(&temp);
    let source = record("annotated");
    upload(
        &hub,
        MACHINE_A_TOKEN,
        1,
        "annotation-source",
        vec![source.clone()],
    )
    .unwrap();
    let reference =
        query(&hub, "machine-a", &["sessions", "--limit", "10"])["results"][0]["reference"]
            .as_str()
            .unwrap()
            .to_owned();
    let identity = json!({"protocol":1,"machine":"machine-a","reference":reference});
    let denied = ureq::post(format!("{}/v1/annotations", hub.url))
        .header("Authorization", format!("Bearer {MACHINE_A_TOKEN}"))
        .send_json(&identity);
    assert!(denied.is_err());
    let mut response = ureq::post(format!("{}/v1/annotations", hub.url))
        .header("Authorization", format!("Bearer {OWNER_TOKEN}"))
        .send_json(&identity)
        .unwrap();
    let initial: Value = response.body_mut().read_json().unwrap();
    assert_eq!(initial["revision"], 0);
    let edit = json!({"protocol":1,"machine":"machine-a","reference":reference,
        "expected_revision":0,"title":"Hub title","notes":"Private hub note"});
    let mut response = ureq::post(format!("{}/v1/annotations/edit", hub.url))
        .header("Authorization", format!("Bearer {OWNER_TOKEN}"))
        .send_json(&edit)
        .unwrap();
    let saved: Value = response.body_mut().read_json().unwrap();
    assert_eq!(saved["revision"], 1);
    assert!(
        ureq::post(format!("{}/v1/annotations/edit", hub.url))
            .header("Authorization", format!("Bearer {OWNER_TOKEN}"))
            .send_json(&edit)
            .is_err()
    );
    upload(&hub, MACHINE_A_TOKEN, 2, "source-retry", vec![source]).unwrap();
    let mut response = ureq::post(format!("{}/v1/annotations", hub.url))
        .header("Authorization", format!("Bearer {OWNER_TOKEN}"))
        .send_json(&identity)
        .unwrap();
    let after: Value = response.body_mut().read_json().unwrap();
    assert_eq!(
        (
            after["revision"].as_i64(),
            after["title"].as_str(),
            after["notes"].as_str()
        ),
        (Some(1), Some("Hub title"), Some("Private hub note"))
    );
}

#[test]
fn locally_committed_records_survive_failed_upload_and_restart() {
    let temp = TempDir::new("hub_outbox_restart");
    let mut hub = start(&temp);
    let db = temp.path().join("local.sqlite");
    {
        let store = Store::open(&db, OwnerMode::Standalone).unwrap();
        store
            .conn
            .execute(
                "update app_metadata set value = 'machine-a' where key = 'machine_id'",
                [],
            )
            .unwrap();
    }
    let enable = Command::new(env!("CARGO_BIN_EXE_codex-sessions-collector"))
        .args(["hub", "enable", "--hub-url", &hub.url, "--standalone"])
        .arg(&db)
        .output()
        .unwrap();
    assert!(
        enable.status.success(),
        "{}",
        String::from_utf8_lossy(&enable.stderr)
    );
    {
        let store = Store::open(&db, OwnerMode::Standalone).unwrap();
        store
            .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
                sample_snapshot("queued-session"),
            )))])
            .unwrap();
        assert_eq!(hub_client::pending(&store.conn).unwrap(), 1);
    }
    let _ = hub.child.kill();
    let _ = hub.child.wait();
    let offline = Command::new(env!("CARGO_BIN_EXE_codex-sessions-collector"))
        .args(["hub", "sync", "--standalone"])
        .arg(&db)
        .env("CODEX_SESSIONS_HUB_MACHINE_TOKEN", MACHINE_A_TOKEN)
        .output()
        .unwrap();
    assert!(!offline.status.success());
    let local_query = Command::new(env!("CARGO_BIN_EXE_codex-sessions-collector"))
        .args(["query", "sessions", "--db"])
        .arg(&db)
        .args(["--limit", "10"])
        .output()
        .unwrap();
    assert!(
        local_query.status.success(),
        "{}",
        String::from_utf8_lossy(&local_query.stderr)
    );
    let local: Value = serde_json::from_slice(&local_query.stdout).unwrap();
    assert_eq!(local["results"].as_array().unwrap().len(), 1);
    hub.restart(&temp);
    let denied = Command::new(env!("CARGO_BIN_EXE_codex-sessions-collector"))
        .args(["hub", "sync", "--standalone"])
        .arg(&db)
        .env("CODEX_SESSIONS_HUB_MACHINE_TOKEN", "wrong-token")
        .output()
        .unwrap();
    assert!(!denied.status.success());
    {
        let reopened = Store::open(&db, OwnerMode::Standalone).unwrap();
        assert_eq!(hub_client::pending(&reopened.conn).unwrap(), 1);
        // The server commits this record, but the client does not receive
        // an acknowledgment. Retrying must accept the duplicate ack.
        let queued: String = reopened
            .conn
            .query_row(
                "select record_json from collector_upload_outbox order by id limit 1",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let envelope: Value = serde_json::from_str(&queued).unwrap();
        assert_eq!(
            upload(&hub, MACHINE_A_TOKEN, 1, "machine-a:1:1", vec![envelope]).unwrap()["duplicate"],
            false
        );
    }
    let delivered = Command::new(env!("CARGO_BIN_EXE_codex-sessions-collector"))
        .args(["hub", "sync", "--standalone"])
        .arg(&db)
        .env("CODEX_SESSIONS_HUB_MACHINE_TOKEN", MACHINE_A_TOKEN)
        .output()
        .unwrap();
    assert!(
        delivered.status.success(),
        "{}",
        String::from_utf8_lossy(&delivered.stderr)
    );
    let report: Value = serde_json::from_slice(&delivered.stdout).unwrap();
    assert_eq!(
        (
            report["sent"].as_u64(),
            report["pending"].as_i64(),
            report["last_sequence"].as_i64()
        ),
        (Some(1), Some(0), Some(1))
    );
    assert_eq!(session_count(&hub, "machine-a"), 1);
    let again = Command::new(env!("CARGO_BIN_EXE_codex-sessions-collector"))
        .args(["hub", "sync", "--standalone"])
        .arg(&db)
        .env("CODEX_SESSIONS_HUB_MACHINE_TOKEN", MACHINE_A_TOKEN)
        .output()
        .unwrap();
    assert!(again.status.success());
    let report: Value = serde_json::from_slice(&again.stdout).unwrap();
    assert_eq!(
        (report["sent"].as_u64(), report["pending"].as_i64()),
        (Some(0), Some(0))
    );
    assert_eq!(session_count(&hub, "machine-a"), 1);
}

/// A standalone local database with machine-a's identity, paired with `url`.
fn paired_database(temp: &TempDir, url: &str) -> std::path::PathBuf {
    let db = temp.path().join("local.sqlite");
    {
        let store = Store::open(&db, OwnerMode::Standalone).unwrap();
        store
            .conn
            .execute(
                "update app_metadata set value = 'machine-a' where key = 'machine_id'",
                [],
            )
            .unwrap();
    }
    hub_client::enable_for_collection(&db, OwnerMode::Standalone, url).unwrap();
    db
}

fn hub_command(db: &std::path::Path, command: &str, token: &str) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_codex-sessions-collector"))
        .args(["hub", command, "--standalone"])
        .arg(db)
        .env("CODEX_SESSIONS_HUB_MACHINE_TOKEN", token)
        .output()
        .unwrap()
}

fn json_output(output: &std::process::Output) -> Value {
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn hub_rows(temp: &TempDir, sql: &str) -> i64 {
    rusqlite::Connection::open(temp.path().join("hub-data/machine-a.sqlite"))
        .unwrap()
        .query_row(sql, [], |row| row.get(0))
        .unwrap()
}

fn status_record(path: &str, status: &str) -> Envelope {
    Envelope::new(Record::SourceStatus(SourceStatus {
        harness: "codex".to_owned(),
        path: path.to_owned(),
        status: status.to_owned(),
        state: if status == "missing" {
            "missing"
        } else {
            "active"
        }
        .to_owned(),
        message: None,
    }))
}

fn thread_name(session: &str, name: &str) -> Envelope {
    Envelope::new(Record::ThreadName(ThreadName {
        harness: "codex".to_owned(),
        session_id: session.to_owned(),
        thread_name: name.to_owned(),
    }))
}

fn outbox_keys(store: &Store) -> Vec<Option<String>> {
    let mut statement = store
        .conn
        .prepare("select record_key from collector_upload_outbox order by id")
        .unwrap();
    statement
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

#[test]
fn outbox_queues_only_changes_and_coalesces_unsent_state_per_source() {
    let temp = TempDir::new("hub_outbox_changes");
    let db = paired_database(&temp, "http://127.0.0.1:9");
    let store = Store::open(&db, OwnerMode::Standalone).unwrap();
    let path = "C:\\synthetic\\status-only.jsonl";
    // Every scan reports every source; unchanged state is queued once.
    for _ in 0..3 {
        store
            .apply(vec![
                status_record(path, "available"),
                thread_name("named", "Stable title"),
            ])
            .unwrap();
    }
    assert_eq!(hub_client::pending(&store.conn).unwrap(), 2);
    // A newer state replaces the unsent older state of the same source.
    store.apply(vec![status_record(path, "missing")]).unwrap();
    store.apply(vec![thread_name("named", "Renamed")]).unwrap();
    let mut first = sample_snapshot("coalesced");
    first.session.title = Some("First".to_owned());
    let mut second = sample_snapshot("coalesced");
    second.session.title = Some("Second".to_owned());
    second.source.size = 200;
    store
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            first,
        )))])
        .unwrap();
    store
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            second,
        )))])
        .unwrap();
    let keys = outbox_keys(&store);
    assert_eq!(keys.len(), 3, "{keys:?}");
    let queued: Vec<String> = {
        let mut statement = store
            .conn
            .prepare("select record_json from collector_upload_outbox order by id")
            .unwrap();
        statement
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    };
    assert!(queued[0].contains("\"missing\""));
    assert!(queued[1].contains("Renamed"));
    assert!(queued[2].contains("Second") && !queued[2].contains("First"));
}

#[test]
fn sync_delivers_full_batches_and_hub_disable_stops_queuing() {
    let temp = TempDir::new("hub_batches");
    let hub = start(&temp);
    let db = paired_database(&temp, &hub.url);
    {
        let store = Store::open(&db, OwnerMode::Standalone).unwrap();
        let records: Vec<Envelope> = (0..300)
            .map(|index| {
                Envelope::new(Record::SessionSnapshot(Box::new(sample_snapshot(
                    &format!("batched-{index}"),
                ))))
            })
            .collect();
        store.apply(records).unwrap();
        assert_eq!(hub_client::pending(&store.conn).unwrap(), 300);
    }
    let report = json_output(&hub_command(&db, "sync", MACHINE_A_TOKEN));
    assert_eq!(
        (
            report["sent"].as_u64(),
            report["batches"].as_u64(),
            report["pending"].as_i64(),
            report["last_sequence"].as_i64()
        ),
        (Some(300), Some(3), Some(0), Some(3))
    );
    assert_eq!(hub_rows(&temp, "select count(*) from sessions"), 300);
    assert_eq!(
        hub_rows(&temp, "select count(*) from hub_received_batches"),
        3
    );

    {
        let store = Store::open(&db, OwnerMode::Standalone).unwrap();
        store
            .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
                sample_snapshot("before-disable"),
            )))])
            .unwrap();
        assert_eq!(hub_client::pending(&store.conn).unwrap(), 1);
    }
    let disabled = json_output(&hub_command(&db, "disable", ""));
    assert_eq!(
        (disabled["enabled"].as_bool(), disabled["cleared"].as_i64()),
        (Some(false), Some(1))
    );
    {
        let store = Store::open(&db, OwnerMode::Standalone).unwrap();
        store
            .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
                sample_snapshot("after-disable"),
            )))])
            .unwrap();
        assert_eq!(hub_client::pending(&store.conn).unwrap(), 0);
    }
    let status = json_output(&hub_command(&db, "status", ""));
    assert_eq!(status["delivery"]["enabled"], false);
    assert_eq!(status["pending"], 0);
    assert!(!hub_command(&db, "sync", MACHINE_A_TOKEN).status.success());
}

#[test]
fn rejected_record_moves_to_dead_letters_without_blocking_the_queue() {
    let temp = TempDir::new("hub_dead_letter");
    let hub = start(&temp);
    let db = paired_database(&temp, &hub.url);
    {
        let store = Store::open(&db, OwnerMode::Standalone).unwrap();
        store
            .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
                sample_snapshot("before-poison"),
            )))])
            .unwrap();
        // A record this collector queued but the hub can never accept.
        store
            .conn
            .execute(
                "insert into collector_upload_outbox(record_json, created_at_utc) values (?, 'now')",
                [json!({"contract":"codex-sessions-viewer.ingest","version":999,"kind":"thread_name","record":{}}).to_string()],
            )
            .unwrap();
        store
            .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
                sample_snapshot("after-poison"),
            )))])
            .unwrap();
    }
    // Wrong credential: a transient failure that keeps every record queued
    // and reports the hub's reason without echoing the credential.
    let denied = hub_command(&db, "sync", "wrong-token-that-must-not-be-echoed");
    assert!(!denied.status.success());
    let stderr = String::from_utf8_lossy(&denied.stderr);
    assert!(stderr.contains("HTTP 401"), "{stderr}");
    assert!(stderr.contains("invalid machine credential"), "{stderr}");
    assert!(!stderr.contains("wrong-token-that-must-not-be-echoed"));
    let status = json_output(&hub_command(&db, "status", ""));
    assert_eq!(
        (status["pending"].as_i64(), status["dead_letters"].as_i64()),
        (Some(3), Some(0))
    );

    let report = json_output(&hub_command(&db, "sync", MACHINE_A_TOKEN));
    assert_eq!(
        (
            report["sent"].as_u64(),
            report["dead_lettered"].as_u64(),
            report["pending"].as_i64()
        ),
        (Some(2), Some(1), Some(0))
    );
    assert_eq!(hub_rows(&temp, "select count(*) from sessions"), 2);
    let status = json_output(&hub_command(&db, "status", ""));
    assert_eq!(status["dead_letters"], 1);
    let rejected = &status["recent_dead_letters"][0];
    assert!(
        rejected["error"]
            .as_str()
            .unwrap()
            .contains("unsupported contract version"),
        "{rejected}"
    );
    assert_eq!(rejected["http_status"], 400);
    assert!(!status.to_string().contains(MACHINE_A_TOKEN));
}

#[test]
fn hub_resync_continues_after_a_restored_local_database() {
    let temp = TempDir::new("hub_resync");
    let hub = start(&temp);
    let db = paired_database(&temp, &hub.url);
    let queue = |session: &str| {
        let store = Store::open(&db, OwnerMode::Standalone).unwrap();
        store
            .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
                sample_snapshot(session),
            )))])
            .unwrap();
    };
    queue("first");
    json_output(&hub_command(&db, "sync", MACHINE_A_TOKEN));
    // Restoring an older backup rewinds the local sequence.
    Store::open(&db, OwnerMode::Standalone)
        .unwrap()
        .conn
        .execute("update collector_hub_state set last_sequence = 0", [])
        .unwrap();
    queue("second");
    let conflict = hub_command(&db, "sync", MACHINE_A_TOKEN);
    assert!(!conflict.status.success());
    assert!(
        String::from_utf8_lossy(&conflict.stderr).contains("hub resync"),
        "{}",
        String::from_utf8_lossy(&conflict.stderr)
    );
    let resync = json_output(&hub_command(&db, "resync", MACHINE_A_TOKEN));
    assert_eq!(
        (
            resync["previous_sequence"].as_i64(),
            resync["last_sequence"].as_i64(),
            resync["pending"].as_i64()
        ),
        (Some(0), Some(1), Some(1))
    );
    let report = json_output(&hub_command(&db, "sync", MACHINE_A_TOKEN));
    assert_eq!(
        (report["sent"].as_u64(), report["last_sequence"].as_i64()),
        (Some(1), Some(2))
    );
    assert_eq!(hub_rows(&temp, "select count(*) from sessions"), 2);
}

#[test]
fn failed_ingest_leaves_neither_records_nor_a_consumed_sequence() {
    let temp = TempDir::new("hub_atomic_ingest");
    let hub = start(&temp);
    upload(
        &hub,
        MACHINE_A_TOKEN,
        1,
        "reused-batch",
        vec![record("first")],
    )
    .unwrap();
    // The batch ID was already used by sequence 1, so this batch fails.
    let failed = upload(
        &hub,
        MACHINE_A_TOKEN,
        2,
        "reused-batch",
        vec![record("second")],
    );
    assert!(failed.is_err());
    assert_eq!(hub_rows(&temp, "select count(*) from sessions"), 1);
    assert_eq!(
        hub_rows(&temp, "select count(*) from hub_received_batches"),
        1
    );
    assert!(
        upload(
            &hub,
            MACHINE_A_TOKEN,
            2,
            "fresh-batch",
            vec![record("second")]
        )
        .is_ok()
    );
    assert_eq!(hub_rows(&temp, "select count(*) from sessions"), 2);
}

#[test]
fn slow_or_oversized_requests_do_not_block_the_hub() {
    use std::io::{Read, Write};
    let temp = TempDir::new("hub_slow_client");
    let hub = start_with(&temp, json!({"request_timeout_seconds": 1}));
    let address = hub.url.trim_start_matches("http://").to_owned();
    // A client that announces a body and then stops sending.
    let mut slow = std::net::TcpStream::connect(&address).unwrap();
    slow.write_all(
        format!(
            "POST /v1/ingest HTTP/1.1\r\nHost: hub\r\nAuthorization: Bearer {MACHINE_A_TOKEN}\r\nContent-Type: application/json\r\nContent-Length: 1000\r\n\r\n{{"
        )
        .as_bytes(),
    )
    .unwrap();
    thread::sleep(Duration::from_millis(100));
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(3)))
        .build()
        .into();
    let started = Instant::now();
    assert!(agent.get(format!("{}/v1/health", hub.url)).call().is_ok());
    assert!(started.elapsed() < Duration::from_secs(2));
    // The stalled request is closed by the socket read timeout.
    slow.set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut response = String::new();
    let _ = slow.read_to_string(&mut response);
    assert!(response.starts_with("HTTP/1.1 408"), "{response:?}");

    // An oversized body is refused from its declared length, unread.
    let mut large = std::net::TcpStream::connect(&address).unwrap();
    large
        .write_all(
            format!(
                "POST /v1/ingest HTTP/1.1\r\nHost: hub\r\nAuthorization: Bearer {MACHINE_A_TOKEN}\r\nContent-Length: {}\r\n\r\n",
                80 * 1024 * 1024
            )
            .as_bytes(),
        )
        .unwrap();
    large
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut response = String::new();
    let _ = large.read_to_string(&mut response);
    assert!(response.starts_with("HTTP/1.1 413"), "{response:?}");
    // Unauthenticated bodies are never read.
    let mut anonymous = std::net::TcpStream::connect(&address).unwrap();
    anonymous
        .write_all(b"POST /v1/ingest HTTP/1.1\r\nHost: hub\r\nContent-Length: 1000000\r\n\r\n")
        .unwrap();
    anonymous
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut response = String::new();
    let _ = anonymous.read_to_string(&mut response);
    assert!(response.starts_with("HTTP/1.1 401"), "{response:?}");
}
