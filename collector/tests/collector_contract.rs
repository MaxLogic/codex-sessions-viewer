mod support;

use std::path::Path;
use std::process::{Command, Output};

use rusqlite::Connection;
use serde_json::{Value, json};
use support::{TempDir, collector};

fn example(source: &Path, args: &[&str]) -> Value {
    let output = Command::new("python")
        .arg("../samples/collector-contract/example_collector.py")
        .arg(source)
        .args(args)
        .output()
        .expect("run independent example collector");
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).unwrap()
}

fn apply(temp: &TempDir, db: &Path, value: &Value) -> Output {
    let input = temp.path().join("records.jsonl");
    std::fs::write(&input, format!("{value}\n")).unwrap();
    collector()
        .args(["apply", "--standalone"])
        .arg(db)
        .arg("--input")
        .arg(input)
        .output()
        .unwrap()
}

fn count(db: &Path, table: &str) -> i64 {
    Connection::open(db)
        .unwrap()
        .query_row(&format!("select count(*) from {table}"), [], |row| {
            row.get(0)
        })
        .unwrap()
}

#[test]
fn independent_example_is_searchable_idempotent_and_revisable() {
    let temp = TempDir::new("contract_example");
    let db = temp.path().join("example.sqlite");
    let source = temp.path().join("session.json");
    std::fs::copy("../samples/collector-contract/session.json", &source).unwrap();
    let first = example(&source, &[]);
    for _ in 0..2 {
        let output = apply(&temp, &db, &first);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
    assert_eq!(count(&db, "sessions"), 1);
    assert_eq!(count(&db, "messages"), 2);
    assert_eq!(count(&db, "session_source_extras"), 1);
    let conn = Connection::open(&db).unwrap();
    let hits: i64 = conn
        .query_row(
            "select count(*) from message_search where message_search match 'searchable'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(hits, 1);
    drop(conn);

    let mut changed: Value = serde_json::from_slice(&std::fs::read(&source).unwrap()).unwrap();
    changed["messages"].as_array_mut().unwrap().push(json!({
        "role": "assistant", "text": "A changed revision replaces the old snapshot."
    }));
    std::fs::write(&source, serde_json::to_vec(&changed).unwrap()).unwrap();
    let output = apply(&temp, &db, &example(&source, &[]));
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(count(&db, "sessions"), 1);
    assert_eq!(count(&db, "messages"), 3);
}

#[test]
fn example_handles_empty_messages_and_uses_its_own_versions() {
    let temp = TempDir::new("contract_empty_message");
    let db = temp.path().join("example.sqlite");
    let source = temp.path().join("session.json");
    std::fs::write(
        &source,
        json!({"session_id":"empty-001","messages":[
            {"role":"user","text":""},
            {"role":"assistant","text":"Answer after an empty prompt."}
        ]})
        .to_string(),
    )
    .unwrap();
    let envelope = example(&source, &[]);
    let session = &envelope["record"]["session"];
    // The adapter's own parser version, not the Codex parser's.
    assert_eq!(session["parser_version"], 1);
    assert_eq!(envelope["record"]["messages"][0]["first_line"], "");
    let output = apply(&temp, &db, &envelope);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(count(&db, "messages"), 2);
    let tokens: Option<i64> = Connection::open(&db)
        .unwrap()
        .query_row("select input_tokens from sessions", [], |row| row.get(0))
        .unwrap();
    assert_eq!(tokens, None, "missing usage must stay unknown, not zero");
}

#[test]
fn contract_rejects_bad_envelopes_without_writing_and_scopes_harness_identity() {
    let temp = TempDir::new("contract_rejections");
    let db = temp.path().join("example.sqlite");
    let source = temp.path().join("session.json");
    std::fs::copy("../samples/collector-contract/session.json", &source).unwrap();
    let good = example(&source, &[]);
    assert!(apply(&temp, &db, &good).status.success());
    let mut additive = good.clone();
    additive["record"]["future_optional_field"] = json!({"retained_by_source": true});
    assert!(apply(&temp, &db, &additive).status.success());
    for bad in [
        json!({"contract":"wrong","version":1,"kind":"session_snapshot","record":{}}),
        json!({"contract":"codex-sessions-viewer.ingest","version":99,"kind":"session_snapshot","record":{}}),
        json!({"contract":"codex-sessions-viewer.ingest","version":1,"kind":"wrong","record":{}}),
        json!({"contract":"codex-sessions-viewer.ingest","version":1,"kind":"session_snapshot","record":{}}),
    ] {
        assert!(!apply(&temp, &db, &bad).status.success());
        assert_eq!(count(&db, "sessions"), 1);
    }
    let malformed = temp.path().join("malformed.jsonl");
    std::fs::write(&malformed, "{not-json}\n").unwrap();
    let rejected = collector()
        .args(["apply", "--standalone"])
        .arg(&db)
        .arg("--input")
        .arg(&malformed)
        .output()
        .unwrap();
    assert!(!rejected.status.success());
    assert_eq!(count(&db, "sessions"), 1);
    let other_harness = example(&source, &["--harness", "another"]);
    assert!(apply(&temp, &db, &other_harness).status.success());
    assert_eq!(count(&db, "sessions"), 2);

    let foreign = example(&source, &["--machine-id", "another-machine"]);
    let output = apply(&temp, &db, &foreign);
    assert!(!output.status.success());
    assert_eq!(count(&db, "sessions"), 2);
}
