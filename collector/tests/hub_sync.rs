mod support;

use std::net::TcpListener;
use std::process::{Child, Stdio};
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
        self.child = support::test_command(env!("CARGO_BIN_EXE_codex-sessions-hub"))
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
    let child = support::test_command(env!("CARGO_BIN_EXE_codex-sessions-hub"))
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
        environment: Some("windows".to_owned()),
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
    let enable = support::test_command(env!("CARGO_BIN_EXE_codex-sessions-collector"))
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
        // Persisted pre-upgrade v1 bytes, including unknown fields and spacing,
        // must survive failed delivery and restart without reserialization.
        let raw = store
            .conn
            .query_row(
                "select record_json from collector_upload_outbox",
                [],
                |row| row.get::<_, String>(0),
            )
            .unwrap();
        let legacy = raw.replacen(
            "\"version\":2",
            "\"version\":1, \"future_field\":{\"preserve\":true}",
            1,
        );
        store
            .conn
            .execute(
                "update collector_upload_outbox set record_json=?",
                [&legacy],
            )
            .unwrap();
        std::fs::write(temp.path().join("legacy-record.txt"), legacy).unwrap();
    }
    let _ = hub.child.kill();
    let _ = hub.child.wait();
    let offline = support::test_command(env!("CARGO_BIN_EXE_codex-sessions-collector"))
        .args(["hub", "sync", "--standalone"])
        .arg(&db)
        .env("CODEX_SESSIONS_HUB_MACHINE_TOKEN", MACHINE_A_TOKEN)
        .output()
        .unwrap();
    assert!(!offline.status.success());
    let local_query = support::test_command(env!("CARGO_BIN_EXE_codex-sessions-collector"))
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
    let denied = support::test_command(env!("CARGO_BIN_EXE_codex-sessions-collector"))
        .args(["hub", "sync", "--standalone"])
        .arg(&db)
        .env("CODEX_SESSIONS_HUB_MACHINE_TOKEN", "wrong-token")
        .output()
        .unwrap();
    assert!(!denied.status.success());
    {
        let reopened = Store::open(&db, OwnerMode::Standalone).unwrap();
        assert_eq!(hub_client::pending(&reopened.conn).unwrap(), 1);
        // The client persisted its in-flight batch and the server committed
        // it, but the acknowledgment was lost. Retrying must accept the
        // duplicate ack.
        let (id, queued): (i64, String) = reopened
            .conn
            .query_row(
                "select id, record_json from collector_upload_outbox order by id limit 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        let batch_id = format!("machine-a:1:{id}:00112233aabbccdd");
        reopened
            .conn
            .execute(
                "update collector_hub_state set inflight_batch_id = ?, inflight_last_id = ? where id = 1",
                rusqlite::params![batch_id, id],
            )
            .unwrap();
        let envelope: Value = serde_json::from_str(&queued).unwrap();
        assert_eq!(
            queued,
            std::fs::read_to_string(temp.path().join("legacy-record.txt")).unwrap()
        );
        assert_eq!(envelope["version"], 1);
        assert_eq!(
            upload(&hub, MACHINE_A_TOKEN, 1, &batch_id, vec![envelope]).unwrap()["duplicate"],
            false
        );
    }
    let delivered = support::test_command(env!("CARGO_BIN_EXE_codex-sessions-collector"))
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
    let again = support::test_command(env!("CARGO_BIN_EXE_codex-sessions-collector"))
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

#[test]
fn typed_external_v1_and_builtin_v2_records_keep_versions_in_the_outbox() {
    use codex_sessions_collector::contract::parse_line;
    let temp = TempDir::new("mixed_version_outbox");
    let db = temp.path().join("local.sqlite");
    let store = Store::open(&db, OwnerMode::Standalone).unwrap();
    store.conn.execute("insert into collector_hub_state(id,enabled,hub_url,machine_id) values (1,1,'http://127.0.0.1:1','legacy')", []).unwrap();
    let mut legacy = serde_json::to_value(Envelope::new(Record::SessionSnapshot(Box::new(
        sample_snapshot("legacy"),
    ))))
    .unwrap();
    legacy["version"] = json!(1);
    let legacy_status = json!({"contract":"codex-sessions-viewer.ingest","version":1,"kind":"source_status","record":{"harness":"codex","path":"C:/legacy-error","status":"parse_error","state":"active","environment":"linux"}});
    let mut native = sample_snapshot("native");
    native.source.environment = "linux".to_owned();
    store
        .apply(vec![
            parse_line(&legacy.to_string()).unwrap(),
            parse_line(&legacy_status.to_string()).unwrap(),
            Envelope::new(Record::SessionSnapshot(Box::new(native))),
        ])
        .unwrap();
    let mut statement = store
        .conn
        .prepare("select record_json from collector_upload_outbox order by id")
        .unwrap();
    let rows: Vec<Value> = statement
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .map(|row| serde_json::from_str(&row.unwrap()).unwrap())
        .collect();
    assert_eq!(
        rows.iter()
            .map(|row| row["version"].as_u64().unwrap())
            .collect::<Vec<_>>(),
        vec![1, 1, 2]
    );
    assert!(rows[1]["record"].get("environment").is_none());
    assert_eq!(rows[2]["record"]["source"]["environment"], "linux");
}

#[test]
fn upgraded_hub_reads_v1_and_native_v2_without_changing_http_protocol() {
    let temp = TempDir::new("native_hub_contract");
    let hub = start(&temp);
    let mut legacy = serde_json::to_value(Envelope::new(Record::SessionSnapshot(Box::new(
        sample_snapshot("legacy"),
    ))))
    .unwrap();
    legacy["version"] = json!(1);
    let mut native = sample_snapshot("native");
    native.source.environment = "macos".to_owned();
    native.source.path = "C:/windows/wsl/native.jsonl".to_owned();
    let native =
        serde_json::to_value(Envelope::new(Record::SessionSnapshot(Box::new(native)))).unwrap();
    upload(
        &hub,
        MACHINE_A_TOKEN,
        1,
        "mixed-version",
        vec![legacy, native],
    )
    .unwrap();
    let mut response = ureq::post(format!("{}/v1/query", hub.url))
        .header("Authorization", format!("Bearer {OWNER_TOKEN}"))
        .send_json(json!({"protocol":1,"machine":"machine-a","args":["sessions","--limit","10"]}))
        .unwrap();
    let data: Value = response.body_mut().read_json().unwrap();
    assert_eq!(data["version"], 2);
    let environments: Vec<&str> = data["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["environment"].as_str().unwrap())
        .collect();
    assert!(
        environments.contains(&"windows") && environments.contains(&"macos"),
        "{data}"
    );
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
    support::test_command(env!("CARGO_BIN_EXE_codex-sessions-collector"))
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

fn large_snapshot(session: &str) -> Envelope {
    let mut snapshot = sample_snapshot(session);
    let tool = snapshot.tool_calls[0].clone();
    snapshot.tool_calls = (0..12_544)
        .map(|index| {
            let mut tool = tool.clone();
            tool.tool_index = index;
            tool.output_preview = format!("tool {index}: {}", "x".repeat(4096));
            tool
        })
        .collect();
    let envelope = Envelope::new(Record::SessionSnapshot(Box::new(snapshot)));
    let bytes = serde_json::to_vec(&envelope).unwrap().len();
    assert!(bytes > 48 * 1024 * 1024 && bytes < 56 * 1024 * 1024);
    envelope
}

fn move_to_dead_letter(conn: &rusqlite::Connection, key: &str, status: Option<u16>) {
    conn.execute(
        "insert into collector_upload_dead_letters(outbox_id, record_key, record_json,
         created_at_utc, failed_at_utc, http_status, error)
         select id, record_key, record_json, created_at_utc, 'now', ?,
         'record exceeds the hub upload size limit and was not sent'
         from collector_upload_outbox where record_key = ?",
        rusqlite::params![status, key],
    )
    .unwrap();
    assert_eq!(
        conn.execute(
            "delete from collector_upload_outbox where record_key = ?",
            [key]
        )
        .unwrap(),
        1
    );
}

#[test]
fn records_above_the_old_48_mib_limit_are_delivered_and_their_dead_letters_cleared() {
    let temp = TempDir::new("large_delivery");
    let hub = start(&temp);
    let db = paired_database(&temp, &hub.url);
    let store = Store::open(&db, OwnerMode::Standalone).unwrap();
    store.apply(vec![large_snapshot("large-a")]).unwrap();
    move_to_dead_letter(&store.conn, "session:session:large-a", None);
    store.apply(vec![large_snapshot("large-b")]).unwrap();
    let local_counts: (i64, i64, i64) = store
        .conn
        .query_row(
            "select count(*), sum(message_count), sum(tool_call_count) from sessions",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    let local_bytes: i64 = store
        .conn
        .query_row(
            "select sum(length(cast(output_preview as blob))) from tool_calls",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(
        local_bytes > 48 * 1024 * 1024,
        "tool previews must survive local apply"
    );
    drop(store);
    let report = json_output(&hub_command(&db, "sync", MACHINE_A_TOKEN));
    assert_eq!(report["requeued_dead_letters"], 1, "{report}");
    assert_eq!(report["dead_lettered"], 0);
    assert!(report["sent"].as_u64().unwrap() >= local_counts.0 as u64);
    assert_eq!(report["pending"], 0);
    assert_eq!(
        json_output(&hub_command(&db, "status", ""))["dead_letters"],
        0
    );
    assert_eq!(
        hub_rows(&temp, "select count(*) from sessions"),
        local_counts.0
    );
    assert_eq!(
        hub_rows(&temp, "select sum(message_count) from sessions"),
        local_counts.1
    );
    assert_eq!(
        hub_rows(&temp, "select sum(tool_call_count) from sessions"),
        local_counts.2
    );
    assert_eq!(
        hub_rows(
            &temp,
            "select sum(length(cast(output_preview as blob))) from tool_calls"
        ),
        local_bytes
    );
}

#[test]
fn dead_letter_reconciliation_preserves_current_state_across_event_permutations() {
    const SEED: u64 = 0x201_2026;
    let temp = TempDir::new("replay_class");
    let hub = start(&temp);
    let db = paired_database(&temp, &hub.url);
    let store = Store::open(&db, OwnerMode::Standalone).unwrap();
    let mut cases = Vec::new();
    for clock in [-1, 0, 1] {
        for status_key in [false, true] {
            for reverse_parse in [false, true] {
                for dead_b in [false, true] {
                    for delivered in [false, true] {
                        for deleted in [false, true] {
                            for missing in [false, true] {
                                cases.push((
                                    clock,
                                    status_key,
                                    reverse_parse,
                                    dead_b,
                                    delivered,
                                    deleted,
                                    missing,
                                ));
                            }
                        }
                    }
                }
            }
        }
    }
    let mut random = SEED;
    for index in (1..cases.len()).rev() {
        random = random.wrapping_mul(6364136223846793005).wrapping_add(1);
        cases.swap(index, random as usize % (index + 1));
    }
    eprintln!(
        "replay class seed={SEED:#x}, cases={}, clocks=-1/0/+1 second; snapshot/status keys; A/B parse order; dead A/B; deliver/no-deliver; delete/keep; active/missing",
        cases.len()
    );
    let mut sequence = 0;
    let mut expected = Vec::new();
    for (index, &(clock, status_key, reverse_parse, dead_b, delivered, deleted, missing)) in
        cases.iter().enumerate()
    {
        let session = format!("class-{index}");
        let mut a = sample_snapshot(&session);
        a.messages[0].content_plain = format!("A-{index}");
        let mut b = a.clone();
        b.messages[0].content_plain = format!("B-{index}");
        let (first, newest) = if reverse_parse {
            (b.clone(), a.clone())
        } else {
            (a.clone(), b.clone())
        };
        store
            .apply(vec![
                Envelope::new(Record::SessionSnapshot(Box::new(first))),
                Envelope::new(Record::SessionSnapshot(Box::new(newest.clone()))),
            ])
            .unwrap();
        // Apply separately as real independent parse commits, without relying on a clock ordering.
        store
            .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
                newest.clone(),
            )))])
            .unwrap();
        let path = newest.source.path.clone();
        let current_status = status_record(&path, if missing { "missing" } else { "available" });
        store.apply(vec![current_status.clone()]).unwrap();
        if delivered {
            sequence += 1;
            upload(
                &hub,
                MACHINE_A_TOKEN,
                sequence,
                &format!("class-delivery-{index}"),
                vec![
                    serde_json::to_value(Envelope::new(Record::SessionSnapshot(Box::new(
                        newest.clone(),
                    ))))
                    .unwrap(),
                    serde_json::to_value(current_status).unwrap(),
                ],
            )
            .unwrap();
        }
        let key = format!("session:session:{session}");
        let status = format!(
            "status:codex:{}",
            codex_sessions_collector::store::writer::source_status_id(&path)
        );
        store
            .conn
            .execute(
                "delete from collector_upload_outbox where record_key in (?, ?)",
                rusqlite::params![key, status],
            )
            .unwrap();
        let payload = if status_key {
            // A historical lifecycle event opposite to the latest authoritative path state.
            status_record(&path, if missing { "available" } else { "missing" })
        } else {
            Envelope::new(Record::SessionSnapshot(Box::new(if dead_b {
                b
            } else {
                a
            })))
        };
        store.conn.execute("insert into collector_upload_dead_letters(outbox_id,record_key,record_json,created_at_utc,failed_at_utc,http_status,error)
            values (1,?,?, '2026-10-27T12:00:00Z','now',null,'synthetic local size refusal')",
            rusqlite::params![if status_key { &status } else { &key }, serde_json::to_string(&payload).unwrap()]).unwrap();
        let parsed = format!(
            "2026-10-27T{}Z",
            match clock {
                -1 => "11:59:59",
                0 => "12:00:00",
                _ => "12:00:01",
            }
        );
        store
            .conn
            .execute(
                "update sessions set last_parsed_utc=? where id=?",
                rusqlite::params![parsed, format!("session:{session}")],
            )
            .unwrap();
        if deleted {
            store
                .conn
                .execute(
                    "delete from sessions where id=?",
                    [format!("session:{session}")],
                )
                .unwrap();
        }
        // Deleted local paths have no new state to send; the protocol retains
        // previously delivered history rather than deleting it remotely.
        let state = if !deleted || delivered {
            Some((
                newest.messages[0].content_plain.clone(),
                if missing { "missing" } else { "available" }.to_owned(),
                if missing { "missing" } else { "active" }.to_owned(),
            ))
        } else {
            None
        };
        expected.push((session, state));
    }
    store
        .conn
        .execute(
            "update collector_hub_state set last_sequence=? where id=1",
            [sequence],
        )
        .unwrap();
    drop(store);
    let report = json_output(&hub_command(&db, "sync", MACHINE_A_TOKEN));
    let remote = rusqlite::Connection::open(temp.path().join("hub-data/machine-a.sqlite")).unwrap();
    let mut failures = Vec::new();
    use rusqlite::OptionalExtension;
    for (index, (session, state)) in expected.iter().enumerate() {
        let actual: Option<(String,String,String)> = remote.query_row(
            "select m.content_plain,s.scan_status,s.source_state from sessions s left join messages m on m.session_id=s.id where s.id=?",
            [format!("session:{session}")], |r| Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional().unwrap();
        if &actual != state {
            failures.push(format!(
                "case {index} {:?}: expected {state:?}, got {actual:?}",
                cases[index]
            ));
        }
    }
    let remaining = json_output(&hub_command(&db, "status", ""))["dead_letters"]
        .as_i64()
        .unwrap();
    assert!(
        failures.is_empty() && remaining == 0,
        "seed={SEED:#x}, remaining={remaining}, report={report}, failures={}\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn reconciliation_preserves_retained_parse_error_history_and_status_only_paths() {
    let temp = TempDir::new("rebuild_entity");
    let hub = start(&temp);
    let db = paired_database(&temp, &hub.url);
    let store = Store::open(&db, OwnerMode::Standalone).unwrap();
    let snapshot = sample_snapshot("retained-error");
    let path = snapshot.source.path.clone();
    let expected = snapshot.messages[0].content_plain.clone();
    store
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            snapshot,
        )))])
        .unwrap();
    move_to_dead_letter(&store.conn, "session:session:retained-error", None);
    store
        .apply(vec![status_record(&path, "parse_error")])
        .unwrap();
    let placeholder = r"C:\synthetic\never-parsed.jsonl";
    store
        .apply(vec![status_record(placeholder, "parse_error")])
        .unwrap();
    let status_key = format!(
        "status:codex:{}",
        codex_sessions_collector::store::writer::source_status_id(placeholder)
    );
    move_to_dead_letter(&store.conn, &status_key, None);
    store
        .conn
        .execute("delete from collector_upload_outbox", [])
        .unwrap();
    drop(store);
    let report = json_output(&hub_command(&db, "sync", MACHINE_A_TOKEN));
    assert_eq!(report["dead_lettered"], 0, "{report}");
    assert_eq!(
        hub_rows(&temp, "select count(*) from messages"),
        1,
        "retained parsed history must reach the hub"
    );
    let remote = rusqlite::Connection::open(temp.path().join("hub-data/machine-a.sqlite")).unwrap();
    let actual:(String,String)=remote.query_row("select content_plain,scan_status from messages join sessions on sessions.id=messages.session_id where sessions.id='session:retained-error'",[],|row|Ok((row.get(0)?,row.get(1)?))).unwrap();
    assert_eq!(actual, (expected, "parse_error".to_owned()));
    assert_eq!(
        hub_rows(&temp, "select count(*) from sessions"),
        2,
        "one parsed session and one status-only placeholder"
    );
    assert_eq!(
        json_output(&hub_command(&db, "status", ""))["dead_letters"],
        0
    );
}

#[test]
fn an_already_delivered_newer_snapshot_is_not_overwritten_by_an_old_dead_letter() {
    let temp = TempDir::new("delivered_newer");
    let hub = start(&temp);
    let db = paired_database(&temp, &hub.url);
    let store = Store::open(&db, OwnerMode::Standalone).unwrap();
    let old = sample_snapshot("already-newer");
    store
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            old.clone(),
        )))])
        .unwrap();
    move_to_dead_letter(&store.conn, "session:session:already-newer", None);
    // Same file revision and row counts: only the committed content changes.
    // An old collector retained A when acknowledging B and removing its outbox row.
    let mut newer = old;
    newer.messages[0].content_plain = "NEW".to_owned();
    let envelope = Envelope::new(Record::SessionSnapshot(Box::new(newer)));
    store.apply(vec![envelope.clone()]).unwrap();
    upload(
        &hub,
        MACHINE_A_TOKEN,
        1,
        "old-collector-delivered-b",
        vec![serde_json::to_value(envelope).unwrap()],
    )
    .unwrap();
    store
        .conn
        .execute_batch(
            "delete from collector_upload_outbox;
        update collector_hub_state set last_sequence = 1 where id = 1",
        )
        .unwrap();
    // Equal commit clocks must not hide stale replay.
    store.conn.execute("update sessions set last_parsed_utc=(select created_at_utc from collector_upload_dead_letters limit 1)", []).unwrap();
    assert_eq!(
        hub_rows(
            &temp,
            "select count(*) from messages where content_plain = 'NEW'"
        ),
        1
    );
    let report = json_output(&hub_command(&db, "sync", MACHINE_A_TOKEN));
    assert_eq!(
        hub_rows(
            &temp,
            "select count(*) from messages where content_plain = 'NEW'"
        ),
        1
    );
    assert_eq!(report["requeued_dead_letters"], 1, "{report}");
    assert_eq!(report["pruned_dead_letters"], 0);
    assert_eq!(report["sent"], 2);
    assert_eq!(
        local_count(
            &db,
            "select count(*) from messages where content_plain = 'NEW'"
        ),
        1
    );
    assert_eq!(
        json_output(&hub_command(&db, "status", ""))["dead_letters"],
        0
    );
}

#[test]
fn stale_orphaned_and_delivered_dead_letters_are_pruned() {
    let temp = TempDir::new("prune_delivery");
    let hub = start(&temp);
    let local_db = temp.path().join("local.sqlite");
    let real_url = hub.url.clone();
    let fake = fake_hub(Box::new(move |body| {
        let ack: Value = ureq::post(format!("{real_url}/v1/ingest"))
            .header("Authorization", format!("Bearer {MACHINE_A_TOKEN}"))
            .send_json(body)
            .unwrap()
            .body_mut()
            .read_json()
            .unwrap();
        // Introduce a refusal after start-of-sync pruning, before the ack:
        // only acknowledgement reconciliation can remove this one.
        let conn = rusqlite::Connection::open(&local_db).unwrap();
        assert_eq!(
            conn.execute(
                "insert into collector_upload_dead_letters(outbox_id, record_key, record_json,
             created_at_utc, failed_at_utc, http_status, error)
             select id, record_key, record_json, created_at_utc, 'now', 409, 'synthetic refusal'
             from collector_upload_outbox where record_key = 'session:session:delivered'",
                [],
            )
            .unwrap(),
            1
        );
        Some((200, ack.to_string()))
    }));
    let db = paired_database(&temp, &fake.url);
    let store = Store::open(&db, OwnerMode::Standalone).unwrap();
    for name in ["stale", "delivered", "gone", "refused"] {
        store
            .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
                sample_snapshot(name),
            )))])
            .unwrap();
        if name != "delivered" {
            move_to_dead_letter(&store.conn, &format!("session:session:{name}"), Some(409));
        }
    }
    store
        .conn
        .execute("delete from sessions where id = 'session:gone'", [])
        .unwrap();
    for name in ["stale", "delivered"] {
        store
            .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
                sample_snapshot(name),
            )))])
            .unwrap();
    }
    drop(store);
    let report = json_output(&hub_command(&db, "sync", MACHINE_A_TOKEN));
    assert_eq!(report["pruned_dead_letters"], 3, "{report}");
    assert_eq!(report["requeued_dead_letters"], 0);
    assert_eq!(report["sent"], 2);
    let status = json_output(&hub_command(&db, "status", ""));
    assert_eq!(status["dead_letters"], 1);
    let conn = rusqlite::Connection::open(&db).unwrap();
    let kept: String = conn
        .query_row(
            "select record_key from collector_upload_dead_letters",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(kept, "session:session:refused");
}

#[test]
fn an_old_hub_without_ingest_capability_gets_plain_bodies_and_the_old_limit() {
    let temp = TempDir::new("old_hub_limit");
    let fake = fake_hub(Box::new(|body| {
        Some((200, json!({
        "protocol":1,"sequence":body["sequence"],"batch_id":body["batch_id"],"duplicate":false
    }).to_string()))
    }));
    let db = paired_database(&temp, &fake.url);
    let store = Store::open(&db, OwnerMode::Standalone).unwrap();
    store
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            sample_snapshot("small"),
        )))])
        .unwrap();
    let name = ThreadName {
        harness: "codex".to_owned(),
        session_id: "large-name".to_owned(),
        thread_name: "x".repeat(49 * 1024 * 1024),
    };
    // Keep the large payload outside session apply and its FTS indexing.
    hub_client::enqueue(&store.conn, Record::ThreadName(name), "now").unwrap();
    drop(store);
    let report = json_output(&hub_command(&db, "sync", MACHINE_A_TOKEN));
    assert_eq!(report["sent"], 1);
    assert_eq!(report["dead_lettered"], 1);
    let bodies = fake.bodies.lock().unwrap();
    assert_eq!(bodies.len(), 1);
    assert!(bodies[0].is_object(), "old hub must receive plain JSON");
    drop(bodies);
    let wire = fake.wire.lock().unwrap();
    assert_eq!(wire.len(), 1);
    assert_eq!(
        wire[0].content_encoding, None,
        "old hub must not receive Content-Encoding"
    );
    assert!(
        wire[0].plain_json,
        "old hub must receive raw JSON bytes, not zstd"
    );
    drop(wire);
    let conn = rusqlite::Connection::open(&db).unwrap();
    assert_eq!(
        conn.query_row(
            "select count(*) from collector_upload_dead_letters where http_status is null",
            [],
            |row| row.get::<_, i64>(0)
        )
        .unwrap(),
        1
    );
    let repeat = json_output(&hub_command(&db, "sync", MACHINE_A_TOKEN));
    assert_eq!(repeat["requeued_dead_letters"], 0, "{repeat}");
}

#[test]
fn hub_decodes_zstd_ingest_within_its_decoded_limit() {
    let temp = TempDir::new("zstd_ingest");
    let hub = start(&temp);
    let verify: Value = ureq::get(format!("{}/v1/verify", hub.url))
        .header("Authorization", format!("Bearer {MACHINE_A_TOKEN}"))
        .call()
        .unwrap()
        .body_mut()
        .read_json()
        .unwrap();
    assert_eq!(verify["protocol"], 1);
    assert_eq!(verify["contract_version"], 2);
    assert_eq!(verify["ingest"]["content_encodings"], json!(["zstd"]));
    let limit = verify["ingest"]["max_decoded_bytes"].as_u64().unwrap() as usize;
    let body =
        json!({"protocol":1,"sequence":1,"batch_id":"compressed","records":[record("compressed")]})
            .to_string();
    let payload = zstd::bulk::compress(body.as_bytes(), 3).unwrap();
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .http_status_as_error(false)
        .build()
        .into();
    for duplicate in [false, true] {
        let mut response = agent
            .post(format!("{}/v1/ingest", hub.url))
            .header("Authorization", format!("Bearer {MACHINE_A_TOKEN}"))
            .header("Content-Encoding", "ZsTd")
            .send(payload.as_slice())
            .unwrap();
        assert_eq!(response.status(), 200);
        assert_eq!(
            response.body_mut().read_json::<Value>().unwrap()["duplicate"],
            duplicate
        );
    }
    let before = hub_rows(&temp, "select count(*) from hub_received_batches");
    for (encoding, bytes, status, code) in [
        (
            "zstd",
            {
                let mut bomb = zstd::bulk::compress(&vec![0; limit + 1], 3).unwrap();
                // A bounded decoder must stop at limit + 1. Reading to EOF
                // encounters this invalid next frame and returns 400 instead.
                bomb.extend_from_slice(b"invalid trailing zstd frame");
                bomb
            },
            413,
            "record_rejected",
        ),
        ("zstd", b"corrupt frame".to_vec(), 400, "invalid_batch"),
        ("gzip", b"{}".to_vec(), 415, "request"),
    ] {
        let mut response = agent
            .post(format!("{}/v1/ingest", hub.url))
            .header("Authorization", format!("Bearer {MACHINE_A_TOKEN}"))
            .header("Content-Encoding", encoding)
            .send(bytes.as_slice())
            .unwrap();
        assert_eq!(response.status(), status);
        assert_eq!(
            response.body_mut().read_json::<Value>().unwrap()["code"],
            code
        );
        assert_eq!(
            hub_rows(&temp, "select count(*) from hub_received_batches"),
            before
        );
        assert!(ureq::get(format!("{}/v1/health", hub.url)).call().is_ok());
    }
    // A protocol-1 plain upload is the old collector's exact wire format.
    assert_eq!(
        upload(&hub, MACHINE_A_TOKEN, 2, "plain", vec![record("plain")]).unwrap()["duplicate"],
        false
    );
}

// The first proxy connection holds the hub's ingest gate before forwarding
// its body. The second event proves another real sync reached that gate.
#[test]
fn overlapping_sync_runs_wait_before_sending_large_bodies() {
    use std::io::{BufRead, BufReader, Read, Write};
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
        mpsc,
    };
    let temp = TempDir::new("overlap_sync");
    let other = TempDir::new("overlap_sync_b");
    let hub = start(&temp);
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let proxy_url = format!("http://{}", listener.local_addr().unwrap());
    let address = hub.url.trim_start_matches("http://").to_owned();
    let (events, arrived) = mpsc::channel();
    let (release, released) = mpsc::channel();
    let released = Arc::new(std::sync::Mutex::new(released));
    let count = Arc::new(AtomicUsize::new(0));
    let proxy = thread::spawn(move || {
        let mut workers = Vec::new();
        // Each sync performs one verify and one ingest; the hub closes responses.
        for _ in 0..4 {
            let (socket, _) = listener.accept().unwrap();
            let address = address.clone();
            let events = events.clone();
            let released = released.clone();
            let count = count.clone();
            workers.push(thread::spawn(move || {
                let mut client = BufReader::new(socket);
                client
                    .get_ref()
                    .set_read_timeout(Some(Duration::from_secs(30)))
                    .unwrap();
                let mut head = String::new();
                loop {
                    let mut line = String::new();
                    client.read_line(&mut line).unwrap();
                    head.push_str(&line);
                    if line == "\r\n" {
                        break;
                    }
                }
                let ingest = head.starts_with("POST /v1/ingest ");
                let expecting = head.to_ascii_lowercase().contains("expect: 100-continue");
                if ingest && !expecting {
                    head.truncate(head.len() - 2);
                    head.push_str("Expect: 100-continue\r\n\r\n");
                }
                let length: u64 = head
                    .lines()
                    .find_map(|line| {
                        let (key, value) = line.split_once(':')?;
                        key.eq_ignore_ascii_case("content-length")
                            .then(|| value.trim().parse().unwrap())
                    })
                    .unwrap_or(0);
                let mut upstream = BufReader::new(std::net::TcpStream::connect(address).unwrap());
                upstream
                    .get_ref()
                    .set_read_timeout(Some(Duration::from_secs(30)))
                    .unwrap();
                upstream.get_mut().write_all(head.as_bytes()).unwrap();
                if ingest {
                    let index = count.fetch_add(1, Ordering::SeqCst);
                    if index == 1 {
                        events.send(1).unwrap();
                    }
                    let mut interim = String::new();
                    loop {
                        let mut line = String::new();
                        upstream.read_line(&mut line).unwrap();
                        interim.push_str(&line);
                        if line == "\r\n" {
                            break;
                        }
                    }
                    if interim.starts_with("HTTP/1.1 100") {
                        if expecting {
                            client.get_mut().write_all(interim.as_bytes()).unwrap();
                        }
                        if index == 0 {
                            events.send(0).unwrap();
                            released
                                .lock()
                                .unwrap()
                                .recv_timeout(Duration::from_secs(10))
                                .unwrap();
                        }
                        std::io::copy(&mut client.by_ref().take(length), upstream.get_mut())
                            .unwrap();
                    } else {
                        client.get_mut().write_all(interim.as_bytes()).unwrap();
                    }
                }
                std::io::copy(&mut upstream, client.get_mut()).ok();
            }));
        }
        for worker in workers {
            worker.join().unwrap();
        }
    });
    let db_a = paired_database(&temp, &proxy_url);
    let db_b = other.path().join("local.sqlite");
    {
        let store = Store::open(&db_b, OwnerMode::Standalone).unwrap();
        store
            .conn
            .execute(
                "update app_metadata set value='machine-b' where key='machine_id'",
                [],
            )
            .unwrap();
    }
    hub_client::enable_for_collection(&db_b, OwnerMode::Standalone, &proxy_url).unwrap();
    let mut large = sample_snapshot("overlap-large");
    let mut random = 0x201u64;
    large.tool_calls[0].output_preview = (0..12 * 1024 * 1024)
        .map(|_| {
            random ^= random << 13;
            random ^= random >> 7;
            random ^= random << 17;
            char::from(b'!' + (random % 90) as u8)
        })
        .collect();
    let expected_bytes = large.tool_calls[0].output_preview.len() as i64;
    Store::open(&db_a, OwnerMode::Standalone)
        .unwrap()
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            large,
        )))])
        .unwrap();
    Store::open(&db_b, OwnerMode::Standalone)
        .unwrap()
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            sample_snapshot("overlap-small"),
        )))])
        .unwrap();
    let first_db = db_a.clone();
    let first = thread::spawn(move || hub_command(&first_db, "sync", MACHINE_A_TOKEN));
    assert_eq!(arrived.recv_timeout(Duration::from_secs(20)).unwrap(), 0);
    let second_db = db_b.clone();
    let second = thread::spawn(move || hub_command(&second_db, "sync", MACHINE_B_TOKEN));
    assert_eq!(arrived.recv_timeout(Duration::from_secs(20)).unwrap(), 1);
    // Leave the first admitted while the hub handles the second request head.
    thread::sleep(Duration::from_millis(250));
    let started = Instant::now();
    assert!(ureq::get(format!("{}/v1/health", hub.url)).call().is_ok());
    assert_eq!(session_count(&hub, "machine-b"), 0);
    assert!(started.elapsed() < Duration::from_secs(2));
    release.send(()).unwrap();
    let a = first.join().unwrap();
    let b = second.join().unwrap();
    proxy.join().unwrap();
    assert_eq!(json_output(&a)["pending"], 0);
    assert_eq!(json_output(&b)["pending"], 0);
    assert_eq!(
        hub_rows(
            &temp,
            "select length(cast(output_preview as blob)) from tool_calls"
        ),
        expected_bytes
    );
    assert_eq!(session_count(&hub, "machine-b"), 1);
    for db in [&db_a, &db_b] {
        assert_eq!(
            local_count(
                db,
                "select count(*) from app_metadata where key='hub.inflight_transport_failures'"
            ),
            0
        );
    }
}

#[test]
fn an_in_progress_ingest_refuses_another_body_without_starving_queries() {
    use std::io::{BufRead, BufReader, Write};
    let temp = TempDir::new("ingest_admission");
    let hub = start_with(&temp, json!({"request_timeout_seconds":1}));
    let address = hub.url.trim_start_matches("http://");
    let connect = |size| {
        let mut stream = std::net::TcpStream::connect(address).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        write!(stream, "POST /v1/ingest HTTP/1.1\r\nHost: hub\r\nAuthorization: Bearer {MACHINE_A_TOKEN}\r\nContent-Length: {size}\r\nExpect: 100-continue\r\n\r\n").unwrap();
        BufReader::new(stream)
    };
    let mut first = connect(10);
    let mut line = String::new();
    first.read_line(&mut line).unwrap();
    assert_eq!(line, "HTTP/1.1 100 Continue\r\n");
    line.clear();
    first.read_line(&mut line).unwrap();
    assert_eq!(line, "\r\n");
    let mut producer = first.get_ref().try_clone().unwrap();
    let progress = thread::spawn(move || {
        for _ in 0..6 {
            producer.write_all(b" ").unwrap();
            thread::sleep(Duration::from_millis(500));
        }
    });
    // The body is progressing, but remains incomplete. The gate must already cover its allocation/read.
    // A second 64 MiB declaration gets 503 before 100 Continue or buffering.
    let waiting = Instant::now();
    let mut second = connect(64 * 1024 * 1024);
    line.clear();
    second.read_line(&mut line).unwrap();
    assert!(line.starts_with("HTTP/1.1 503"), "{line}");
    assert!(waiting.elapsed() >= Duration::from_secs(2));
    let started = Instant::now();
    assert!(ureq::get(format!("{}/v1/health", hub.url)).call().is_ok());
    assert_eq!(session_count(&hub, "machine-a"), 0);
    assert!(started.elapsed() < Duration::from_secs(2));
    progress.join().unwrap();
    line.clear();
    first.read_line(&mut line).unwrap();
    assert!(line.starts_with("HTTP/1.1 408"), "{line}");
    // A stalled accepted body still times out and releases admission.
    assert!(
        upload(
            &hub,
            MACHINE_A_TOKEN,
            1,
            "after-timeout",
            vec![record("after-timeout")]
        )
        .is_ok()
    );
}

fn status_record(path: &str, status: &str) -> Envelope {
    Envelope::new(Record::SourceStatus(SourceStatus {
        harness: "codex".to_owned(),
        path: path.to_owned(),
        environment: Some("windows".to_owned()),
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
fn rejected_multi_record_batch_accounts_for_recovery_write() {
    use codex_sessions_collector::store::write_budget::WriteHoldScope;
    let temp = TempDir::new("hub_rejection_hold");
    let hub = start(&temp);
    let db = paired_database(&temp, &hub.url);
    let store = Store::open(&db, OwnerMode::Standalone).unwrap();
    store
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            sample_snapshot("rejection-hold-good"),
        )))])
        .unwrap();
    store.conn.execute(
        "insert into collector_upload_outbox(record_json, created_at_utc) values (?, 'now')",
        [json!({"contract":"codex-sessions-viewer.ingest","version":999,"kind":"thread_name","record":{}}).to_string()],
    ).unwrap();
    drop(store);
    let recovery = WriteHoldScope::for_phase("hub_rejection");
    #[cfg(debug_assertions)]
    let audit = codex_sessions_collector::store::write_budget::audit::WriteAudit::start();
    let report = hub_client::sync(&db, OwnerMode::Standalone, &hub.url, MACHINE_A_TOKEN).unwrap();
    #[cfg(debug_assertions)]
    audit.assert_complete();
    assert_eq!(
        (report.sent, report.dead_lettered, report.pending),
        (1, 1, 0)
    );
    let hold = recovery.report();
    assert_eq!(
        hold.transactions, 1,
        "the rejected multi-record batch must release its persisted inflight state through the measured owner"
    );
    assert_eq!(hold.max_phase.as_deref(), Some("hub_rejection"));
    assert!(hold.max_ms > 0.0);
    #[cfg(debug_assertions)]
    {
        assert!(audit.report().commits > 0);
        audit.assert_complete();
    }
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

/// The ingest reply of a stand-in hub or proxy; `None` closes the connection
/// without a response.
type IngestReply = Box<dyn FnMut(&Value) -> Option<(u16, String)> + Send>;

/// A stand-in for a hub behind a proxy: it answers the compatibility check
/// like machine-a's hub and lets the test choose every ingest reply. It
/// records each ingest body.
struct FakeHub {
    url: String,
    bodies: std::sync::Arc<std::sync::Mutex<Vec<Value>>>,
    wire: std::sync::Arc<std::sync::Mutex<Vec<CapturedUpload>>>,
}

struct CapturedUpload {
    content_encoding: Option<String>,
    plain_json: bool,
}

fn fake_hub(reply: IngestReply) -> FakeHub {
    fake_hub_contract(codex_sessions_collector::contract::CONTRACT_VERSION, reply)
}

fn fake_hub_contract(contract_version: u32, mut reply: IngestReply) -> FakeHub {
    use std::io::{BufRead, BufReader, Read, Write};
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let bodies = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let seen = bodies.clone();
    let wire = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let seen_wire = wire.clone();
    thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut request_line = String::new();
            if reader.read_line(&mut request_line).unwrap_or(0) == 0 {
                continue;
            }
            let path = request_line.split(' ').nth(1).unwrap_or("").to_owned();
            let mut length = 0usize;
            let mut encoding = None;
            let mut expect_continue = false;
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or(0) == 0 {
                    break;
                }
                let line = line.trim_end();
                if line.is_empty() {
                    break;
                }
                if let Some((name, value)) = line.split_once(':') {
                    if name.eq_ignore_ascii_case("content-length") {
                        length = value.trim().parse().unwrap();
                    } else if name.eq_ignore_ascii_case("expect") {
                        expect_continue = value.trim().eq_ignore_ascii_case("100-continue");
                    } else if name.eq_ignore_ascii_case("content-encoding") {
                        encoding = Some(value.trim().to_owned());
                    }
                }
            }
            if expect_continue {
                stream.write_all(b"HTTP/1.1 100 Continue\r\n\r\n").unwrap();
            }
            let mut body = vec![0u8; length];
            let _ = reader.read_exact(&mut body);
            let (status, text) = if path == "/v1/verify" {
                (
                    200,
                    json!({
                        "protocol": codex_sessions_collector::hub_server::HUB_PROTOCOL_VERSION,
                        "schema_version": codex_sessions_collector::store::schema::SUPPORTED_SCHEMA_VERSION,
                        "contract": codex_sessions_collector::contract::CONTRACT_NAME,
                        "contract_version": contract_version,
                        "machine_id": "machine-a",
                        "high_water": 0
                    })
                    .to_string(),
                )
            } else {
                let value: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
                let plain_json = body.first() == Some(&b'{') && value.is_object();
                seen_wire.lock().unwrap().push(CapturedUpload {
                    content_encoding: encoding.clone(),
                    plain_json,
                });
                seen.lock().unwrap().push(value.clone());
                if encoding.is_some() || !plain_json {
                    // This old peer neither advertises nor accepts compression.
                    (415, json!({"code":"request","error":"old hub requires plain JSON without Content-Encoding"}).to_string())
                } else {
                    match reply(&value) {
                        Some(answer) => answer,
                        None => continue,
                    }
                }
            };
            let _ = write!(
                stream,
                "HTTP/1.1 {status} Status\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}",
                text.len()
            );
        }
    });
    FakeHub { url, bodies, wire }
}

#[test]
fn old_or_future_peer_contract_refusal_keeps_queued_and_inflight_bytes() {
    for version in [1, 3] {
        let temp = TempDir::new("peer_contract_mismatch");
        let fake = fake_hub_contract(
            version,
            Box::new(|_| panic!("mismatched peers must not receive uploads")),
        );
        let db = paired_database(&temp, &fake.url);
        queue_sessions(&db, &["queued", "inflight"]);
        let store = Store::open(&db, OwnerMode::Standalone).unwrap();
        store.conn.execute("update collector_hub_state set inflight_batch_id='retained-batch', inflight_last_id=(select min(id) from collector_upload_outbox) where id=1", []).unwrap();
        let snapshot = || {
            let mut statement = store
                .conn
                .prepare("select id,record_json from collector_upload_outbox order by id")
                .unwrap();
            statement
                .query_map([], |row| {
                    Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?))
                })
                .unwrap()
                .map(Result::unwrap)
                .collect::<Vec<_>>()
        };
        let before = snapshot();
        let failure =
            hub_client::sync(&db, OwnerMode::Standalone, &fake.url, MACHINE_A_TOKEN).unwrap_err();
        assert_eq!(
            failure,
            "hub protocol, schema, contract, or machine identity differs from this collector release"
        );
        assert_eq!(snapshot(), before);
        assert_eq!(
            store
                .conn
                .query_row(
                    "select inflight_batch_id from collector_hub_state",
                    [],
                    |row| row.get::<_, String>(0)
                )
                .unwrap(),
            "retained-batch"
        );
    }
}

fn acknowledge(body: &Value) -> (u16, String) {
    (
        200,
        json!({"protocol": 1, "sequence": body["sequence"], "batch_id": body["batch_id"], "duplicate": false})
            .to_string(),
    )
}

fn queue_sessions(db: &std::path::Path, names: &[&str]) {
    let store = Store::open(db, OwnerMode::Standalone).unwrap();
    store
        .apply(
            names
                .iter()
                .map(|name| Envelope::new(Record::SessionSnapshot(Box::new(sample_snapshot(name)))))
                .collect(),
        )
        .unwrap();
}

fn local_count(db: &std::path::Path, sql: &str) -> i64 {
    Store::open(db, OwnerMode::Standalone)
        .unwrap()
        .conn
        .query_row(sql, [], |row| row.get(0))
        .unwrap()
}

#[test]
fn http_errors_without_a_hub_rejection_code_keep_records_queued() {
    let replies = [
        (400, "<html><body>400 Bad Request</body></html>".to_owned()),
        (
            413,
            "<html><body>413 Request Entity Too Large</body></html>".to_owned(),
        ),
        (409, "{}".to_owned()),
        (
            400,
            json!({"error":"cannot read request","code":"request"}).to_string(),
        ),
    ];
    for (index, (status, text)) in replies.into_iter().enumerate() {
        let temp = TempDir::new(&format!("hub_proxy_error_{index}"));
        let fake = fake_hub(Box::new(move |_| Some((status, text.clone()))));
        let db = paired_database(&temp, &fake.url);
        queue_sessions(&db, &["proxied-a", "proxied-b"]);
        let result = hub_client::sync(&db, OwnerMode::Standalone, &fake.url, MACHINE_A_TOKEN);
        assert!(result.is_err(), "HTTP {status}: {result:?}");
        assert_eq!(
            (
                local_count(&db, "select count(*) from collector_upload_outbox"),
                local_count(&db, "select count(*) from collector_upload_dead_letters")
            ),
            (2, 0),
            "HTTP {status}"
        );
    }
}

#[test]
fn a_body_cut_off_by_the_client_is_a_transient_failure() {
    use std::io::{Read, Write};
    let temp = TempDir::new("hub_truncated_body");
    let hub = start(&temp);
    let address = hub.url.trim_start_matches("http://").to_owned();
    let mut client = std::net::TcpStream::connect(&address).unwrap();
    client
        .write_all(
            format!(
                "POST /v1/ingest HTTP/1.1\r\nHost: hub\r\nAuthorization: Bearer {MACHINE_A_TOKEN}\r\nContent-Length: 1000\r\n\r\n{{\"protocol\""
            )
            .as_bytes(),
        )
        .unwrap();
    client.shutdown(std::net::Shutdown::Write).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(10)))
        .unwrap();
    let mut response = String::new();
    let _ = client.read_to_string(&mut response);
    assert!(response.starts_with("HTTP/1.1 408"), "{response:?}");
    assert!(!response.contains("record_rejected"), "{response:?}");
}

#[test]
fn a_restored_local_database_cannot_acknowledge_a_batch_the_hub_never_stored() {
    let temp = TempDir::new("hub_restored_batch_id");
    let hub = start(&temp);
    let db = paired_database(&temp, &hub.url);
    let backup = temp.path().join("backup.sqlite");
    Store::open(&db, OwnerMode::Standalone)
        .unwrap()
        .conn
        .execute("vacuum into ?", [backup.to_str().unwrap()])
        .unwrap();
    queue_sessions(&db, &["before-restore"]);
    let first = hub_client::sync(&db, OwnerMode::Standalone, &hub.url, MACHINE_A_TOKEN).unwrap();
    assert_eq!(first.sent, 1);
    // Restoring the backup rewinds the queue: the next record reuses the
    // first outbox row ID at the same sequence.
    for suffix in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{suffix}", db.display()));
    }
    std::fs::copy(&backup, &db).unwrap();
    queue_sessions(&db, &["after-restore"]);
    let second = hub_client::sync(&db, OwnerMode::Standalone, &hub.url, MACHINE_A_TOKEN);
    assert!(
        second
            .as_ref()
            .is_err_and(|error| error.contains("hub resync")),
        "{second:?}"
    );
    assert_eq!(
        local_count(&db, "select count(*) from collector_upload_outbox"),
        1
    );
    hub_client::resync(&db, OwnerMode::Standalone, &hub.url, MACHINE_A_TOKEN).unwrap();
    let delivered =
        hub_client::sync(&db, OwnerMode::Standalone, &hub.url, MACHINE_A_TOKEN).unwrap();
    assert_eq!(delivered.sent, 1);
    assert_eq!(hub_rows(&temp, "select count(*) from sessions"), 2);
}

#[test]
fn busy_uploads_retry_the_same_batch_without_transport_failure_or_halving() {
    let temp = TempDir::new("busy_retry");
    let mut attempts = 0;
    let fake = fake_hub(Box::new(move |body| {
        attempts += 1;
        if attempts <= 2 {
            Some((
                503,
                json!({"code":"busy","error":"synthetic admission wait exhausted"}).to_string(),
            ))
        } else {
            Some(acknowledge(body))
        }
    }));
    let db = paired_database(&temp, &fake.url);
    queue_sessions(&db, &["busy-a", "busy-b", "busy-c", "busy-d"]);
    let result = hub_client::sync(&db, OwnerMode::Standalone, &fake.url, MACHINE_A_TOKEN);
    assert!(result.is_ok(), "{result:?}");
    let report = result.unwrap();
    assert_eq!((report.sent, report.batches, report.pending), (4, 1, 0));
    let bodies = fake.bodies.lock().unwrap();
    assert_eq!(bodies.len(), 3);
    assert!(bodies.iter().all(|body| body == &bodies[0]));
    assert_eq!(
        local_count(
            &db,
            "select count(*) from app_metadata where key='hub.inflight_transport_failures'"
        ),
        0
    );
}

#[test]
fn repeated_transport_failures_shrink_the_inflight_batch_under_the_same_id() {
    let temp = TempDir::new("hub_shrink_inflight");
    let mut dropped = 0;
    let fake = fake_hub(Box::new(move |body| {
        if dropped < 2 {
            dropped += 1;
            return None;
        }
        Some(acknowledge(body))
    }));
    let db = paired_database(&temp, &fake.url);
    let names: Vec<String> = (0..8).map(|index| format!("slow-{index}")).collect();
    queue_sessions(&db, &names.iter().map(String::as_str).collect::<Vec<_>>());
    for _ in 0..2 {
        assert!(hub_client::sync(&db, OwnerMode::Standalone, &fake.url, MACHINE_A_TOKEN).is_err());
    }
    let report = hub_client::sync(&db, OwnerMode::Standalone, &fake.url, MACHINE_A_TOKEN).unwrap();
    assert_eq!((report.sent, report.pending), (8, 0));
    let bodies = fake.bodies.lock().unwrap();
    let sizes: Vec<usize> = bodies
        .iter()
        .map(|body| body["records"].as_array().unwrap().len())
        .collect();
    assert_eq!(sizes, vec![8, 8, 4, 4], "{sizes:?}");
    // A retry keeps the persisted batch ID, also when it is shrunk.
    assert_eq!(bodies[0]["batch_id"], bodies[2]["batch_id"]);
    assert_eq!(bodies[0]["sequence"], bodies[2]["sequence"]);
    assert_ne!(bodies[2]["batch_id"], bodies[3]["batch_id"]);
}

#[test]
fn batches_are_bounded_by_utf8_bytes_not_characters() {
    let temp = TempDir::new("hub_utf8_budget");
    let hub = start(&temp);
    let db = paired_database(&temp, &hub.url);
    // Each name is 3 Mi characters but 9 MiB of UTF-8.
    let name = "\u{20ac}".repeat(3 * 1024 * 1024);
    {
        let store = Store::open(&db, OwnerMode::Standalone).unwrap();
        store
            .apply(vec![
                thread_name("wide-a", &name),
                thread_name("wide-b", &name),
            ])
            .unwrap();
    }
    let report = hub_client::sync(&db, OwnerMode::Standalone, &hub.url, MACHINE_A_TOKEN).unwrap();
    assert_eq!((report.sent, report.batches), (2, 2));
}

#[test]
fn busy_responses_do_not_stall_the_listener() {
    use std::io::{Read, Write};
    let temp = TempDir::new("hub_busy");
    let hub = start(&temp);
    let address = hub.url.trim_start_matches("http://").to_owned();
    // Fill every connection slot with a client that never finishes its head.
    let stalled: Vec<std::net::TcpStream> = (0..32)
        .map(|_| {
            let mut stream = std::net::TcpStream::connect(&address).unwrap();
            stream.write_all(b"GET /v1/health HTTP/1.1\r\n").unwrap();
            stream
        })
        .collect();
    thread::sleep(Duration::from_millis(300));
    // Clients that stay silent after connecting must not hold the listener.
    let started = Instant::now();
    let mut busy: Vec<std::net::TcpStream> = (0..6)
        .map(|_| std::net::TcpStream::connect(&address).unwrap())
        .collect();
    for stream in &mut busy {
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let mut response = [0u8; 12];
        stream.read_exact(&mut response).unwrap();
        assert_eq!(&response, b"HTTP/1.1 503");
    }
    assert!(
        started.elapsed() < Duration::from_millis(1000),
        "{:?}",
        started.elapsed()
    );
    drop(stalled);
}

#[test]
fn malformed_header_syntax_is_rejected() {
    use std::io::{Read, Write};
    let temp = TempDir::new("hub_header_syntax");
    let hub = start(&temp);
    let address = hub.url.trim_start_matches("http://").to_owned();
    for request in [
        "GET /v1/health HTTP/1.1\r\nHost : hub\r\n\r\n",
        "GET /v1/health HTTP/1.1\r\nHost: hub\r\n folded-continuation\r\n\r\n",
        "GET /v1/health HTTP/1.1\r\nHost: hub\r\nContent-Length: +0\r\n\r\n",
    ] {
        let mut stream = std::net::TcpStream::connect(&address).unwrap();
        stream.write_all(request.as_bytes()).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        let mut response = String::new();
        let _ = stream.read_to_string(&mut response);
        assert!(
            response.starts_with("HTTP/1.1 400"),
            "{request:?}: {response:?}"
        );
    }
}

/// A session collected before pairing whose file was deleted reaches the hub
/// through `hub backfill`, rebuilt from the local rows, and is marked missing.
#[test]
fn backfill_delivers_a_stored_session_whose_file_is_gone() {
    let temp = TempDir::new("hub_backfill");
    let hub = start(&temp);
    let home = support::codex_home(&temp, &["rich_session.jsonl"]);
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
    let scan = || {
        let output = support::test_command(env!("CARGO_BIN_EXE_codex-sessions-collector"))
            .args(["codex", "scan", "--no-wsl-projects", "--standalone"])
            .arg(&db)
            .arg("--windows-root")
            .arg(&home)
            .args(["--wsl-root", ""])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    };
    scan();
    std::fs::remove_file(support::day_folder(&home).join("rich_session.jsonl")).unwrap();
    scan();
    let refused = hub_command(&db, "backfill", MACHINE_A_TOKEN);
    assert_eq!(refused.status.code(), Some(3), "not paired yet");

    hub_client::enable_for_collection(&db, OwnerMode::Standalone, &hub.url).unwrap();
    // A compressed copy on disk is left to the next scan.
    let compressed = support::day_folder(&home).join("rich_session.jsonl.zst");
    std::fs::write(&compressed, b"not read by backfill").unwrap();
    let skipped = json_output(&hub_command(&db, "backfill", MACHINE_A_TOKEN));
    assert_eq!(
        (
            skipped["still_present"].as_i64(),
            skipped["queued"].as_i64()
        ),
        (Some(1), Some(0))
    );
    std::fs::remove_file(&compressed).unwrap();
    let report = json_output(&hub_command(&db, "backfill", MACHINE_A_TOKEN));
    assert_eq!(
        (report["candidates"].as_i64(), report["queued"].as_i64()),
        (Some(1), Some(1))
    );
    json_output(&hub_command(&db, "sync", MACHINE_A_TOKEN));

    let id = "session:parity-rich-001";
    let local = rusqlite::Connection::open(&db).unwrap();
    let digest = |conn: &rusqlite::Connection, sql: &str| -> String {
        conn.query_row(sql, [id], |row| row.get(0)).unwrap()
    };
    let messages = "select group_concat(message_index || '|' || author_type || '|' || content_plain || '|' || coalesce(token_total, ''), char(10)) from (select * from messages where session_id = ? order by message_index)";
    let tools = "select coalesce(group_concat(t.tool_index || '|' || t.tool_name || '|' || coalesce(m.message_index, ''), char(10)), '') from (select * from tool_calls where session_id = ?1 order by tool_index) t left join messages m on m.id = t.message_id";
    let usage = "select group_concat(source_record_ordinal || '|' || coalesce(total_tokens, '') || '|' || event_fingerprint, char(10)) from (select * from usage_events where session_row_id = ? order by source_record_ordinal)";
    let session = "select title || '|' || coalesce(working_directory_display, '') || '|' || models_used || '|' || coalesce(total_tokens, '') from sessions where id = ?";
    let remote = rusqlite::Connection::open(temp.path().join("hub-data/machine-a.sqlite")).unwrap();
    for sql in [messages, tools, usage, session] {
        assert_eq!(digest(&remote, sql), digest(&local, sql), "{sql}");
    }
    assert_eq!(
        hub_rows(
            &temp,
            "select count(*) from messages where session_id = 'session:parity-rich-001'"
        ),
        12
    );
    let status: String = remote
        .query_row(
            "select scan_status from sessions where id = ?",
            [id],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(status, "missing");
}
