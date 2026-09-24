//! Read-only history queries (T-120), exercised through the real CLI.

mod support;

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::process::Output;

use codex_sessions_collector::contract::{
    Envelope, MessageRecord, ProjectHint, Record, SessionSnapshot,
};
use codex_sessions_collector::dart::sha256_hex;
use rusqlite::Connection;
use serde_json::{Value, json};

use support::{TempDir, collector, sample_snapshot, viewer_database};

fn message(index: i64, author: &str, at: Option<&str>, text: &str) -> MessageRecord {
    MessageRecord {
        index,
        author_type: author.to_owned(),
        raw_type: Some("message".to_owned()),
        created_at_utc: at.map(str::to_owned),
        first_line: text.lines().next().unwrap_or("").to_owned(),
        content_plain: text.to_owned(),
        content_preview: text.chars().take(200).collect(),
        content_truncated: false,
        usage: Default::default(),
        model: None,
        has_tool_calls: false,
        has_error: false,
    }
}

fn session(
    harness: &str,
    id: &str,
    directory: &str,
    project: &str,
    messages: Vec<MessageRecord>,
) -> SessionSnapshot {
    let mut snapshot = sample_snapshot(id);
    snapshot.harness = harness.to_owned();
    snapshot.source.path = format!("C:\\fixtures\\{harness}\\{id}.jsonl");
    snapshot.session.working_directory_display = Some(directory.to_owned());
    snapshot.session.working_directory_platform = Some(directory.to_owned());
    snapshot.session.title = Some(format!("Title of {id}"));
    snapshot.session.last_message_at_utc = messages
        .iter()
        .filter_map(|message| message.created_at_utc.clone())
        .max();
    snapshot.project_hints = vec![ProjectHint {
        working_directory: directory.to_owned(),
        project_name: project.to_owned(),
    }];
    snapshot.messages = messages;
    snapshot
}

struct Fixture {
    _temp: TempDir,
    db: PathBuf,
}

/// Two projects with sibling folders, two harnesses, a second machine, tool
/// output, a long message, and a message without a timestamp.
fn fixture() -> Fixture {
    let temp = TempDir::new("query");
    let db = viewer_database(&temp);
    let long = format!("shutdown queue: claimed fixed. {}", "x".repeat(9000));
    let mut many = Vec::new();
    for index in 0..25 {
        many.push(message(
            index,
            if index % 2 == 0 { "user" } else { "assistant" },
            Some(&format!("2026-09-05T10:{index:02}:00Z")),
            &format!("pager message {index} about the shutdown queue"),
        ));
    }
    let snapshots = vec![
        session(
            "codex",
            "atlas-1",
            "F:\\projects\\Atlas",
            "Atlas",
            vec![
                message(
                    0,
                    "user",
                    Some("2026-09-09T08:00:00Z"),
                    "Investigate shutdown queue race.",
                ),
                message(
                    1,
                    "assistant",
                    Some("2026-09-09T08:01:00Z"),
                    "Proposed closing the queue under one lock.",
                ),
                message(
                    2,
                    "tool",
                    Some("2026-09-09T08:02:00Z"),
                    "shutdown queue test failed",
                ),
                message(3, "assistant", Some("2026-09-09T08:03:00Z"), &long),
                message(4, "user", None, "shutdown queue with no timestamp"),
            ],
        ),
        session(
            "codex",
            "atlas-old-2",
            "F:\\projects\\Atlas-old",
            "Atlas-old",
            vec![message(
                0,
                "assistant",
                Some("2026-09-09T08:04:00Z"),
                "shutdown queue unrelated sibling project",
            )],
        ),
        session(
            "codex",
            "atlas-sub-3",
            "F:\\projects\\Atlas\\worker",
            "Atlas",
            vec![message(
                0,
                "user",
                Some("2026-08-20T08:00:00Z"),
                "older shutdown queue note in a subfolder",
            )],
        ),
        session("claude", "claude-4", "F:\\projects\\Atlas", "Atlas", {
            vec![message(
                0,
                "assistant",
                Some("2026-09-10T09:00:00Z"),
                "claude looked at the shutdown queue too",
            )]
        }),
        session("codex", "pager-5", "F:\\projects\\Pager", "Pager", many),
    ];
    let input = temp.path().join("records.jsonl");
    let lines: Vec<String> = snapshots
        .into_iter()
        .map(|snapshot| {
            serde_json::to_string(&Envelope::new(Record::SessionSnapshot(Box::new(snapshot))))
                .unwrap()
        })
        .collect();
    std::fs::write(&input, lines.join("\n")).unwrap();
    let output = collector()
        .args(["apply", "--db"])
        .arg(&db)
        .arg("--input")
        .arg(&input)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    // A session collected on another machine (as a hub import would store it).
    let conn = Connection::open(&db).unwrap();
    conn.execute(
        "update sessions set machine_id = 'feedfacefeedfacefeedfacefeedface' where session_id = 'atlas-sub-3'",
        [],
    )
    .unwrap();
    drop(conn);
    Fixture { _temp: temp, db }
}

fn query(db: &Path, args: &[&str]) -> Output {
    collector()
        .arg("query")
        .args(args)
        .arg("--db")
        .arg(db)
        .output()
        .unwrap()
}

fn ok(db: &Path, args: &[&str]) -> Value {
    let output = query(db, args);
    assert!(
        output.status.success(),
        "query {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(value["contract"], "codex-sessions-viewer.query");
    assert_eq!(value["version"], 1);
    assert_eq!(value["read_only"], true);
    value
}

fn references(value: &Value) -> Vec<String> {
    value["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["reference"].as_str().unwrap().to_owned())
        .collect()
}

/// The database bytes, and the size of any write-ahead log. A read-only
/// reader of a WAL database may create empty `-wal`/`-shm` side files; it must
/// never add frames or change the database.
fn database_fingerprint(db: &Path) -> (String, u64) {
    let wal = PathBuf::from(format!("{}-wal", db.display()));
    (
        sha256_hex(&std::fs::read(db).unwrap()),
        std::fs::metadata(wal).map_or(0, |metadata| metadata.len()),
    )
}

#[test]
fn search_scopes_to_a_project_path_and_excludes_sibling_folders() {
    let fixture = fixture();
    let result = ok(
        &fixture.db,
        &[
            "search",
            "--query",
            "shutdown queue",
            "--path",
            "F:/projects/Atlas",
            "--limit",
            "50",
        ],
    );
    let found = references(&result);
    assert!(
        found
            .iter()
            .all(|reference| !reference.contains("atlas-old-2")),
        "{found:?}"
    );
    assert!(
        found
            .iter()
            .any(|reference| reference.contains("/codex/atlas-1#0"))
    );
    assert!(
        found
            .iter()
            .any(|reference| reference.contains("atlas-sub-3")),
        "subfolders are included"
    );
    // Tool output is excluded unless requested.
    assert!(
        !found
            .iter()
            .any(|reference| reference.ends_with("atlas-1#2"))
    );
    let with_tools = ok(
        &fixture.db,
        &[
            "search",
            "--query",
            "shutdown queue",
            "--path",
            "F:/projects/Atlas",
            "--include-tools",
            "--limit",
            "50",
        ],
    );
    assert!(
        references(&with_tools)
            .iter()
            .any(|reference| reference.ends_with("atlas-1#2"))
    );
    // Project, harness, machine, and dates keep their meaning.
    let project = ok(
        &fixture.db,
        &["search", "--query", "shutdown", "--project", "atlas-OLD"],
    );
    assert_eq!(references(&project).len(), 1);
    let claude = ok(
        &fixture.db,
        &["search", "--query", "shutdown", "--harness", "claude"],
    );
    assert_eq!(references(&claude).len(), 1);
    assert!(references(&claude)[0].contains("/claude/claude-4#0"));
    let foreign = ok(
        &fixture.db,
        &[
            "search",
            "--query",
            "shutdown",
            "--machine",
            "feedfacefeedfacefeedfacefeedface",
        ],
    );
    assert_eq!(references(&foreign).len(), 1);
    assert!(
        references(&foreign)[0]
            .starts_with("history://feedfacefeedfacefeedfacefeedface/codex/atlas-sub-3")
    );
    let dated = ok(
        &fixture.db,
        &[
            "search",
            "--query",
            "queue",
            "--project",
            "Atlas",
            "--since",
            "2026-09-09",
            "--until",
            "2026-09-09T08:02:00+00:00",
        ],
    );
    let dated = references(&dated);
    assert_eq!(dated.len(), 2, "{dated:?}");
    assert!(dated.iter().all(|reference| reference.contains("atlas-1#")));
}

#[test]
fn search_pages_cover_every_match_once_in_a_stable_order() {
    let fixture = fixture();
    let all = ok(
        &fixture.db,
        &[
            "search",
            "--query",
            "shutdown queue",
            "--include-tools",
            "--limit",
            "50",
        ],
    );
    assert_eq!(all["has_more"], false);
    let expected = references(&all);
    assert!(expected.len() > 25);
    let mut paged = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let mut args = vec![
            "search",
            "--query",
            "shutdown queue",
            "--include-tools",
            "--limit",
            "4",
        ];
        if let Some(cursor) = &cursor {
            args.push("--cursor");
            args.push(cursor);
        }
        let page = ok(&fixture.db, &args);
        assert!(page["results"].as_array().unwrap().len() <= 4);
        paged.extend(references(&page));
        match page["next_cursor"].as_str() {
            Some(next) => cursor = Some(next.to_owned()),
            None => {
                assert_eq!(page["has_more"], false);
                break;
            }
        }
    }
    assert_eq!(paged, expected);
    assert_eq!(
        paged.iter().collect::<HashSet<_>>().len(),
        paged.len(),
        "no duplicates"
    );
    // Newest first; the undated message sorts last.
    assert!(expected.last().unwrap().ends_with("atlas-1#4"));
    // Repeating a query returns the same references.
    assert_eq!(
        references(&ok(
            &fixture.db,
            &[
                "search",
                "--query",
                "shutdown queue",
                "--include-tools",
                "--limit",
                "50"
            ]
        )),
        expected
    );
}

#[test]
fn session_listing_pages_with_filters() {
    let fixture = fixture();
    let all = ok(&fixture.db, &["sessions", "--limit", "100"]);
    let expected = references(&all);
    assert_eq!(expected.len(), 5);
    let mut paged = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let mut args = vec!["sessions", "--limit", "2"];
        if let Some(cursor) = &cursor {
            args.push("--cursor");
            args.push(cursor);
        }
        let page = ok(&fixture.db, &args);
        paged.extend(references(&page));
        match page["next_cursor"].as_str() {
            Some(next) => cursor = Some(next.to_owned()),
            None => break,
        }
    }
    assert_eq!(paged, expected);
    let atlas = ok(&fixture.db, &["sessions", "--project", "Atlas"]);
    assert_eq!(references(&atlas).len(), 3);
    let projects = ok(&fixture.db, &["projects"]);
    let names: Vec<&str> = projects["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["project"].as_str().unwrap())
        .collect();
    assert_eq!(names, vec!["Atlas", "Atlas-old", "Pager"]);
    let first = ok(&fixture.db, &["projects", "--limit", "2"]);
    let rest = ok(
        &fixture.db,
        &[
            "projects",
            "--limit",
            "2",
            "--cursor",
            first["next_cursor"].as_str().unwrap(),
        ],
    );
    assert_eq!(rest["results"][0]["project"], "Pager");
}

#[test]
fn references_from_search_resolve_to_the_same_messages() {
    let fixture = fixture();
    let hit = ok(&fixture.db, &["search", "--query", "claimed fixed"]);
    let reference = hit["results"][0]["reference"].as_str().unwrap().to_owned();
    assert!(reference.starts_with("history://") && reference.ends_with("/codex/atlas-1#3"));
    let by_ref = ok(
        &fixture.db,
        &["message", "--ref", &reference, "--chars", "100"],
    );
    assert_eq!(by_ref["result"]["reference"], reference.as_str());
    assert_eq!(by_ref["result"]["excerpt_truncated"], true);
    let session_ref = hit["results"][0]["session_reference"]
        .as_str()
        .unwrap()
        .to_owned();
    let by_index = ok(
        &fixture.db,
        &[
            "message",
            "--session",
            &session_ref,
            "--index",
            "3",
            "--chars",
            "100",
        ],
    );
    assert_eq!(by_index["result"], by_ref["result"]);
    // Page through the long message to its end.
    let mut offset = 0;
    let mut text = String::new();
    loop {
        let offset_text = offset.to_string();
        let page = ok(
            &fixture.db,
            &[
                "message",
                "--ref",
                &reference,
                "--chars",
                "4000",
                "--text-offset",
                &offset_text,
            ],
        );
        text.push_str(page["result"]["excerpt"].as_str().unwrap());
        match page["result"]["next_text_offset"].as_i64() {
            Some(next) => offset = next,
            None => break,
        }
    }
    assert_eq!(
        text.chars().count() as i64,
        by_ref["result"]["content_length"].as_i64().unwrap()
    );
    assert!(text.ends_with("xxx"));
    // A bare session ID resolves when it is unique.
    let bare = ok(&fixture.db, &["session", "--session", "atlas-1"]);
    assert_eq!(bare["session"]["reference"], session_ref.as_str());
    assert_eq!(bare["session"]["project"], "Atlas");
    assert!(bare["local_usage_by_model"].as_array().unwrap().len() == 1);
}

#[test]
fn export_contains_exactly_what_paging_messages_returns() {
    let fixture = fixture();
    let exported = ok(
        &fixture.db,
        &["export", "--session", "pager-5", "--include-tools"],
    );
    assert_eq!(exported["truncated"], false);
    let exported_messages = exported["messages"].as_array().unwrap();
    let mut paged = Vec::new();
    let mut after = "-1".to_owned();
    loop {
        let page = ok(
            &fixture.db,
            &[
                "messages",
                "--session",
                "pager-5",
                "--include-tools",
                "--after-index",
                &after,
                "--limit",
                "7",
                "--chars",
                "8000",
            ],
        );
        for row in page["results"].as_array().unwrap() {
            paged.push((row["reference"].clone(), row["excerpt"].clone()));
        }
        match page["next_after_index"].as_i64() {
            Some(next) => after = next.to_string(),
            None => break,
        }
    }
    assert_eq!(paged.len(), 25);
    let from_export: Vec<(Value, Value)> = exported_messages
        .iter()
        .map(|row| (row["reference"].clone(), row["content_plain"].clone()))
        .collect();
    assert_eq!(from_export, paged);
    let markdown = ok(
        &fixture.db,
        &[
            "export",
            "--session",
            "pager-5",
            "--export-format",
            "markdown",
            "--include-tools",
        ],
    );
    let text = markdown["markdown"].as_str().unwrap();
    for (_, content) in &from_export {
        assert!(text.contains(content.as_str().unwrap()));
    }
    let bounded = ok(
        &fixture.db,
        &[
            "export",
            "--session",
            "pager-5",
            "--include-tools",
            "--max-messages",
            "10",
        ],
    );
    assert_eq!(bounded["truncated"], true);
    assert_eq!(bounded["messages"].as_array().unwrap().len(), 10);
    assert_eq!(bounded["next_after_index"], 9);
}

#[test]
fn empty_results_are_explicit() {
    let fixture = fixture();
    let result = ok(
        &fixture.db,
        &["search", "--query", "quantum banana rewrite"],
    );
    assert_eq!(result["results"], json!([]));
    assert_eq!(result["has_more"], false);
    assert_eq!(result["next_cursor"], Value::Null);
    let none = ok(&fixture.db, &["sessions", "--project", "Nobody"]);
    assert_eq!(none["results"], json!([]));
}

#[test]
fn limits_and_inputs_are_validated() {
    let fixture = fixture();
    for args in [
        vec!["search", "--query", "x", "--limit", "51"],
        vec!["search", "--query", "x", "--chars", "5000"],
        vec!["search", "--query", "!!!"],
        vec!["search", "--query", "x", "--since", "2026-09-01T10:00:00"],
        vec![
            "search",
            "--query",
            "x",
            "--since",
            "2026-09-02",
            "--until",
            "2026-09-01",
        ],
        vec!["search", "--query", "x", "--cursor", "not-a-cursor"],
        vec!["messages", "--session", "atlas-1", "--limit", "0"],
        vec!["message", "--session", "atlas-1"],
        vec!["export", "--session", "atlas-1", "--export-format", "pdf"],
        vec!["mystery"],
    ] {
        let output = query(&fixture.db, &args);
        assert_eq!(
            output.status.code(),
            Some(2),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let first_line = String::from_utf8_lossy(&output.stderr)
            .lines()
            .next()
            .unwrap_or("")
            .to_owned();
        let error: Value = serde_json::from_str(&first_line).unwrap();
        assert_eq!(error["read_only"], true);
    }
    // A cursor from another command is rejected.
    let page = ok(&fixture.db, &["sessions", "--limit", "1"]);
    let cursor = page["next_cursor"].as_str().unwrap();
    assert_eq!(
        query(&fixture.db, &["search", "--query", "x", "--cursor", cursor])
            .status
            .code(),
        Some(2)
    );
    // Unknown references and missing databases are errors, not empty history.
    assert_eq!(
        query(
            &fixture.db,
            &["session", "--session", "history://x/codex/none"]
        )
        .status
        .code(),
        Some(1)
    );
    let missing = fixture.db.with_file_name("absent.sqlite");
    assert_eq!(query(&missing, &["status"]).status.code(), Some(1));
    assert!(!missing.exists());
}

#[test]
fn databases_without_history_views_are_refused() {
    let temp = TempDir::new("query-old");
    let db = temp.path().join("v18.sqlite");
    support::create_database_at_version(&db, 18);
    let output = query(&db, &["status"]);
    assert_eq!(output.status.code(), Some(3));
    assert!(String::from_utf8_lossy(&output.stderr).contains("schema 19"));
}

#[test]
fn queries_never_change_the_database() {
    let fixture = fixture();
    // Settle the WAL so only the database file carries content.
    let conn = Connection::open(&fixture.db).unwrap();
    conn.query_row("pragma wal_checkpoint(TRUNCATE)", [], |_| Ok(()))
        .unwrap();
    drop(conn);
    let before = database_fingerprint(&fixture.db);
    assert_eq!(before.1, 0);
    let reference = ok(&fixture.db, &["search", "--query", "claimed"])["results"][0]["reference"]
        .as_str()
        .unwrap()
        .to_owned();
    for args in [
        vec!["status"],
        vec!["projects"],
        vec!["sessions", "--path", "F:/projects"],
        vec!["search", "--query", "shutdown queue", "--include-tools"],
        vec!["session", "--session", "atlas-1"],
        vec!["messages", "--session", "atlas-1"],
        vec!["message", "--ref", reference.as_str()],
        vec![
            "export",
            "--session",
            "pager-5",
            "--export-format",
            "markdown",
        ],
    ] {
        ok(&fixture.db, &args);
    }
    assert_eq!(database_fingerprint(&fixture.db), before);
    let status = ok(&fixture.db, &["status"]);
    assert_eq!(status["schema_version"], 20);
    let harnesses: Vec<(String, i64)> = status["harnesses"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| {
            (
                row["harness"].as_str().unwrap().to_owned(),
                row["sessions"].as_i64().unwrap(),
            )
        })
        .collect();
    assert_eq!(harnesses.iter().map(|(_, count)| count).sum::<i64>(), 5);
}

#[test]
fn text_output_is_readable_and_bounded() {
    let fixture = fixture();
    let output = query(
        &fixture.db,
        &[
            "search",
            "--query",
            "shutdown queue",
            "--limit",
            "2",
            "--format",
            "text",
        ],
    );
    assert!(output.status.success());
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("history://"));
    assert!(text.contains("-- more: --cursor"));
    let none = query(
        &fixture.db,
        &["search", "--query", "quantum banana", "--format", "text"],
    );
    assert_eq!(String::from_utf8_lossy(&none.stdout).trim(), "No matches.");
}

// ---------------------------------------------------------------------------
// Review follow-ups: ties, non-ASCII names, WSL paths, bounded export

/// Sessions and messages that share timestamps across harnesses and machines,
/// projects whose names differ only beyond ASCII, and a WSL working directory.
fn tie_fixture() -> Fixture {
    let temp = TempDir::new("query-ties");
    let db = viewer_database(&temp);
    let tie = "2026-09-06T00:00:00Z";
    let mut snapshots = Vec::new();
    for (harness, id, project) in [
        ("codex", "tie-a", "Ćma"),
        ("claude", "tie-b", "Ćmb"),
        ("codex", "tie-c", "Ćmc"),
        ("codex", "tie-d", "Zeta"),
        ("claude", "tie-e", "ćmd"),
    ] {
        snapshots.push(session(
            harness,
            id,
            &format!("F:\\projects\\{id}"),
            project,
            vec![
                message(0, "user", Some(tie), "tiebreak question"),
                message(1, "assistant", Some(tie), "tiebreak answer"),
            ],
        ));
    }
    snapshots.push(session(
        "codex",
        "wsl-1",
        "/mnt/f/projects/Atlas/wsl",
        "Atlas",
        vec![message(
            0,
            "user",
            Some("2026-09-07T00:00:00Z"),
            "wsl pathmatch note",
        )],
    ));
    snapshots.push(session(
        "codex",
        "win-1",
        "F:\\projects\\Atlas",
        "Atlas",
        vec![message(
            0,
            "user",
            Some("2026-09-07T00:01:00Z"),
            "windows pathmatch note",
        )],
    ));
    let long = format!("exportcap {}", "y".repeat(30_000));
    snapshots.push(session(
        "codex",
        "long-1",
        "F:\\projects\\Long",
        "Long",
        (0..6)
            .map(|index| {
                message(
                    index,
                    "assistant",
                    Some(&format!("2026-09-08T00:0{index}:00Z")),
                    &long,
                )
            })
            .collect(),
    ));
    let input = temp.path().join("ties.jsonl");
    let lines: Vec<String> = snapshots
        .into_iter()
        .map(|snapshot| {
            serde_json::to_string(&Envelope::new(Record::SessionSnapshot(Box::new(snapshot))))
                .unwrap()
        })
        .collect();
    std::fs::write(&input, lines.join("\n")).unwrap();
    let output = collector()
        .args(["apply", "--db"])
        .arg(&db)
        .arg("--input")
        .arg(&input)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let conn = Connection::open(&db).unwrap();
    conn.execute(
        "update sessions set machine_id = '0000000000000000000000000000000a' where session_id = 'tie-c'",
        [],
    )
    .unwrap();
    drop(conn);
    Fixture { _temp: temp, db }
}

fn page_all(db: &Path, base: &[&str]) -> Vec<String> {
    let mut all = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let mut args: Vec<&str> = base.to_vec();
        if let Some(cursor) = &cursor {
            args.push("--cursor");
            args.push(cursor);
        }
        let page = ok(db, &args);
        for row in page["results"].as_array().unwrap() {
            all.push(
                row.get("reference")
                    .or_else(|| row.get("project"))
                    .and_then(Value::as_str)
                    .unwrap()
                    .to_owned(),
            );
        }
        match page["next_cursor"].as_str() {
            Some(next) => cursor = Some(next.to_owned()),
            None => return all,
        }
    }
}

#[test]
fn ties_across_harnesses_and_machines_page_without_gaps() {
    let fixture = tie_fixture();
    let search = ["search", "--query", "tiebreak", "--limit", "50"];
    let expected = references(&ok(&fixture.db, &search));
    assert_eq!(expected.len(), 10);
    assert_eq!(
        page_all(
            &fixture.db,
            &["search", "--query", "tiebreak", "--limit", "1"]
        ),
        expected
    );
    let sessions = references(&ok(&fixture.db, &["sessions", "--limit", "100"]));
    assert_eq!(
        page_all(&fixture.db, &["sessions", "--limit", "1"]),
        sessions
    );
    assert_eq!(
        sessions.iter().collect::<HashSet<_>>().len(),
        sessions.len()
    );
}

#[test]
fn project_pages_follow_sqlite_ordering_for_non_ascii_names() {
    let fixture = tie_fixture();
    let expected: Vec<String> = ok(&fixture.db, &["projects", "--limit", "200"])["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["project"].as_str().unwrap().to_owned())
        .collect();
    assert!(expected.len() >= 7, "{expected:?}");
    assert_eq!(
        page_all(&fixture.db, &["projects", "--limit", "1"]),
        expected
    );
}

#[test]
fn path_filters_match_windows_and_wsl_forms_of_a_folder() {
    let fixture = tie_fixture();
    for path in [
        "F:/projects/Atlas",
        "/mnt/f/projects/Atlas",
        "f:\\projects\\atlas\\",
    ] {
        let found = references(&ok(
            &fixture.db,
            &["search", "--query", "pathmatch", "--path", path],
        ));
        assert_eq!(found.len(), 2, "{path}: {found:?}");
    }
    let wsl_only = references(&ok(
        &fixture.db,
        &[
            "search",
            "--query",
            "pathmatch",
            "--path",
            "/mnt/f/projects/Atlas/wsl",
        ],
    ));
    assert_eq!(wsl_only.len(), 1);
}

#[test]
fn cursors_only_continue_the_query_that_produced_them() {
    let fixture = tie_fixture();
    let first = ok(
        &fixture.db,
        &["search", "--query", "tiebreak", "--limit", "1"],
    );
    let cursor = first["next_cursor"].as_str().unwrap();
    for other in [
        vec![
            "search",
            "--query",
            "tiebreak answer",
            "--limit",
            "1",
            "--cursor",
            cursor,
        ],
        vec![
            "search",
            "--query",
            "tiebreak",
            "--harness",
            "codex",
            "--limit",
            "1",
            "--cursor",
            cursor,
        ],
        vec![
            "search",
            "--query",
            "tiebreak",
            "--include-tools",
            "--limit",
            "1",
            "--cursor",
            cursor,
        ],
    ] {
        assert_eq!(
            query(&fixture.db, &other).status.code(),
            Some(2),
            "{other:?}"
        );
    }
    // The page size may change between pages.
    ok(
        &fixture.db,
        &[
            "search", "--query", "tiebreak", "--limit", "3", "--cursor", cursor,
        ],
    );
}

#[test]
fn export_is_bounded_in_characters_and_continues_after_an_index() {
    let fixture = tie_fixture();
    let exported = ok(
        &fixture.db,
        &["export", "--session", "long-1", "--chars", "1000"],
    );
    let messages = exported["messages"].as_array().unwrap();
    assert_eq!(messages.len(), 6);
    for row in messages {
        assert_eq!(row["content_plain"].as_str().unwrap().chars().count(), 1000);
        assert_eq!(row["content_truncated_by_export"], true);
        assert_eq!(row["content_length"], 30_010);
    }
    // The default budget stops before everything fits and says where to resume.
    let budget = ok(
        &fixture.db,
        &[
            "export",
            "--session",
            "long-1",
            "--max-chars",
            "70000",
            "--chars",
            "20000",
        ],
    );
    assert_eq!(budget["truncated"], true);
    let first: Vec<i64> = budget["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["message_index"].as_i64().unwrap())
        .collect();
    assert_eq!(first, vec![0, 1, 2]);
    assert_eq!(budget["next_after_index"], 2);
    let rest = ok(
        &fixture.db,
        &[
            "export",
            "--session",
            "long-1",
            "--after-index",
            "2",
            "--chars",
            "20000",
            "--max-chars",
            "70000",
        ],
    );
    let second: Vec<i64> = rest["messages"]
        .as_array()
        .unwrap()
        .iter()
        .map(|row| row["message_index"].as_i64().unwrap())
        .collect();
    assert_eq!(second, vec![3, 4, 5]);
    assert_eq!(rest["truncated"], false);
    let markdown = ok(
        &fixture.db,
        &[
            "export",
            "--session",
            "long-1",
            "--export-format",
            "markdown",
            "--chars",
            "500",
        ],
    );
    assert!(markdown["markdown"].as_str().unwrap().chars().count() < 6 * 700);
    assert_eq!(
        query(
            &fixture.db,
            &["export", "--session", "long-1", "--chars", "50000"]
        )
        .status
        .code(),
        Some(2)
    );
}
