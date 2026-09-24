//! Codex protocol events that repeat stored content or carry no conversation
//! value are not stored as messages (T-146). The fixture mixes the app-server
//! `item_completed` stream with the legacy `event_msg` events.

mod support;

use codex_sessions_collector::codex::parser::{AuthorType, ParserOptions, parse_file};
use rusqlite::Connection;
use serde_json::{Value, json};

use support::{TempDir, viewer_database};

const FIXTURE: &str = "../samples/collector-parity/sessions/event_stream_session.jsonl";

fn messages() -> Vec<(AuthorType, Option<String>, String)> {
    let parsed = parse_file(FIXTURE, ParserOptions::default()).expect("fixture parses");
    parsed
        .session
        .messages
        .into_iter()
        .map(|message| (message.author_type, message.raw_type, message.content_plain))
        .collect()
}

#[test]
fn duplicate_and_bookkeeping_events_are_not_stored_as_messages() {
    let messages = messages();
    let raw_types: Vec<&str> = messages
        .iter()
        .filter_map(|(_, raw, _)| raw.as_deref())
        .collect();
    for dropped in [
        "item_completed",
        "item_started",
        "exec_command_end",
        "patch_apply_end",
        "task_started",
        "context_compacted",
        "turn_aborted",
        "thread_name_updated",
        "thread_goal_updated",
        "agent_reasoning",
    ] {
        let kept_items = messages.iter().any(|(_, raw, content)| {
            raw.as_deref() == Some(dropped) && !content.contains("\"SubAgentActivity\"")
        });
        assert!(!kept_items, "{dropped} stored in {raw_types:?}");
    }
    assert!(
        !messages
            .iter()
            .any(|(_, raw, content)| raw.as_deref() == Some("task_complete")
                && content.contains("last_agent_message")),
        "a completed turn repeats the final answer"
    );
    assert!(
        messages
            .iter()
            .all(|(author, _, content)| *author != AuthorType::Unknown
                || !content.contains("\"patch_apply_end\"")),
    );
}

#[test]
fn the_conversation_keeps_every_prompt_answer_and_readable_reasoning_once() {
    let conversation: Vec<(AuthorType, String)> = messages()
        .into_iter()
        .filter(|(author, _, _)| *author != AuthorType::Unknown)
        .map(|(author, _, content)| (author, content))
        .collect();
    assert_eq!(
        conversation,
        vec![
            (
                AuthorType::System,
                "<permissions instructions>\nFilesystem sandboxing defines which files can be read or written.\n</permissions instructions>".to_owned()
            ),
            (
                AuthorType::User,
                "Rename the widget and fix the build.".to_owned()
            ),
            // The summary is readable even though the item is also encrypted.
            (AuthorType::Reasoning, "**Planning the rename**".to_owned()),
            (
                AuthorType::Reasoning,
                "Reasoning content is encrypted and cannot be displayed.".to_owned()
            ),
            (
                AuthorType::Assistant,
                "Renamed the widget; the build passes.".to_owned()
            ),
            (
                AuthorType::System,
                "Message Type: FINAL_ANSWER\nSender: /root/worker\nPayload:\nWorker finished the audit."
                    .to_owned()
            ),
            (AuthorType::System, "You have hit your usage limit.".to_owned()),
        ]
    );
}

#[test]
fn small_unmodelled_events_keep_their_raw_evidence() {
    let unknown: Vec<String> = messages()
        .into_iter()
        .filter(|(author, _, _)| *author == AuthorType::Unknown)
        .filter_map(|(_, raw, _)| raw)
        .collect();
    assert_eq!(unknown, vec!["item_completed", "web_search_end"]);
}

#[test]
fn the_latest_thread_name_update_names_the_session() {
    let parsed = parse_file(FIXTURE, ParserOptions::default()).unwrap();
    assert_eq!(parsed.session.thread_name.as_deref(), Some("Widget rename"));
}

fn open(path: &std::path::Path) -> Connection {
    let conn = Connection::open(path).unwrap();
    conn.busy_timeout(std::time::Duration::from_secs(30))
        .unwrap();
    conn
}

#[test]
fn changed_files_and_the_latest_goal_are_stored_as_source_extras() {
    let temp = TempDir::new("event-extras");
    let home = support::codex_home(&temp, &["event_stream_session.jsonl"]);
    let db = viewer_database(&temp);
    let output = support::scan(&db, &home, &[]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let conn = open(&db);
    let extra: String = conn
        .query_row(
            "select extra_json from session_source_extras
             where session_row_id = 'session:parity-events-003'",
            [],
            |row| row.get(0),
        )
        .expect("the session has source extras");
    let extra: Value = serde_json::from_str(&extra).unwrap();
    assert_eq!(
        extra,
        json!({
            "files_changed": [
                "C:\\nonexistent\\events\\src\\lib.rs",
                "C:\\nonexistent\\events\\src\\moved_widget.rs",
                "C:\\nonexistent\\events\\src\\new_widget.rs",
                "C:\\nonexistent\\events\\src\\old_widget.rs",
            ],
            "goal": {"objective": "Rename the widget and ship it", "status": "complete"},
        })
    );
    // Reparsing replaces the rows; the external-content index follows.
    let forced = support::scan(&db, &home, &["--force"]);
    assert!(forced.status.success());
    let messages: i64 = conn
        .query_row("select count(*) from messages", [], |row| row.get(0))
        .unwrap();
    let indexed: i64 = conn
        .query_row(
            "select count(*) from message_search where message_search match 'widget'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(messages, 9);
    assert_eq!(indexed, 2, "user prompt and answer mention the widget");
    conn.execute(
        "insert into message_search(message_search) values('integrity-check')",
        [],
    )
    .expect("the message index matches the stored messages");
}
