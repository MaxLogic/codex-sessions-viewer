mod support;

use std::path::Path;
use std::process::Output;

use rusqlite::Connection;
use serde_json::{Value, json};
use support::{TempDir, collector};

fn example(source: &Path, args: &[&str]) -> Value {
    let output = support::test_command("python")
        .arg(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../samples/collector-contract/example_collector.py"),
        )
        .arg(if source.is_absolute() {
            source.to_path_buf()
        } else {
            Path::new(env!("CARGO_MANIFEST_DIR")).join(source)
        })
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
fn v2_status_requires_explicit_native_environment_before_write() {
    let temp = TempDir::new("native_status_contract");
    let db = temp.path().join("native.sqlite");
    let status = json!({
        "contract": "codex-sessions-viewer.ingest",
        "version": 2,
        "kind": "source_status",
        "record": {
            "harness": "codex",
            "path": "/tmp/windows/home/Session.jsonl",
            "status": "parse_error",
            "state": "active",
            "environment": "linux"
        }
    });
    let output = apply(&temp, &db, &status);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let conn = Connection::open(&db).unwrap();
    let source_type: String = conn
        .query_row(
            "select source_type from sessions where id like 'source-status:%'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(source_type, "linux");
    for invalid in [json!(null), json!("unknown")] {
        let mut bad = status.clone();
        bad["record"]["environment"] = invalid;
        assert!(!apply(&temp, &db, &bad).status.success());
        assert_eq!(count(&db, "sessions"), 1);
    }
    let mut absent = status.clone();
    absent["record"]
        .as_object_mut()
        .unwrap()
        .remove("environment");
    assert!(!apply(&temp, &db, &absent).status.success());
    assert_eq!(count(&db, "sessions"), 1);
}

#[test]
fn native_snapshots_statuses_and_legacy_updates_preserve_explicit_provenance() {
    use codex_sessions_collector::contract::{Envelope, Record};
    let temp = TempDir::new("native_provenance");
    let db = temp.path().join("native.sqlite");
    for environment in ["macos", "linux"] {
        let mut snapshot = support::sample_snapshot(environment);
        snapshot.source.environment = environment.to_owned();
        snapshot.source.path = format!("C:/windows/wsl/{environment}.jsonl");
        let record =
            serde_json::to_value(Envelope::new(Record::SessionSnapshot(Box::new(snapshot))))
                .unwrap();
        assert!(apply(&temp, &db, &record).status.success());
        let mut old = record.clone();
        old["version"] = json!(1);
        let rejected = apply(&temp, &db, &old);
        assert!(!rejected.status.success());
        assert!(
            String::from_utf8_lossy(&rejected.stderr).contains("unsupported source.environment")
        );
        let legacy = json!({"contract":"codex-sessions-viewer.ingest","version":1,"kind":"source_status","record":{"harness":"codex","path":format!("C:/windows/wsl/{environment}.jsonl"),"environment":"windows","status":"missing","state":"missing"}});
        assert!(apply(&temp, &db, &legacy).status.success());
        let conn = Connection::open(&db).unwrap();
        let stored: (String, String) = conn
            .query_row(
                "select source_type,scan_status from sessions where session_id=?",
                [environment],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(stored, (environment.to_owned(), "missing".to_owned()));
        drop(conn);
        let error = json!({"contract":"codex-sessions-viewer.ingest","version":2,"kind":"source_status","record":{"harness":"claude","path":format!("C:/windows/wsl/{environment}-error.jsonl"),"environment":environment,"status":"parse_error","state":"active"}});
        assert!(apply(&temp, &db, &error).status.success());
        let conn = Connection::open(&db).unwrap();
        let placeholder: (String, String) = conn
            .query_row(
                "select source_type,scan_status from sessions where source_file_path=?",
                [format!("C:/windows/wsl/{environment}-error.jsonl")],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(
            placeholder,
            (environment.to_owned(), "parse_error".to_owned())
        );
    }
    assert_eq!(count(&db, "sessions"), 4);
}

#[test]
fn legacy_status_ignores_any_unknown_environment_value_before_typed_decode() {
    use codex_sessions_collector::contract::{Record, parse_line};
    for extra in [
        json!("linux"),
        json!("unknown"),
        json!(null),
        json!(73),
        json!({"future":true}),
        json!(["linux"]),
    ] {
        let value = json!({"contract":"codex-sessions-viewer.ingest","version":1,"kind":"source_status","record":{"harness":"codex","path":"/tmp/windows/legacy.jsonl","environment":extra,"status":"parse_error","state":"active"}});
        let parsed = parse_line(&value.to_string()).unwrap_or_else(|error| {
            panic!("legacy unknown field {extra} must be tolerated: {error}")
        });
        assert_eq!(parsed.version, 1);
        let Record::SourceStatus(status) = parsed.record else {
            panic!("source_status expected")
        };
        assert_eq!(status.environment, None);
    }
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
