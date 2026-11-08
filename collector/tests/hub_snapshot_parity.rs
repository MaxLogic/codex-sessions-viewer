mod support;

use codex_sessions_collector::codex::parser::{AuthorType, Usage};
use codex_sessions_collector::dart::DartDateTime;
use codex_sessions_collector::{
    contract::*,
    hub_snapshot::{self, Children},
    store::{OwnerMode, Store},
};
use serde_json::json;

// Exhaustive, deterministic seed/bounds: mask 0..64, explicit total false/true.
// Each bucket is independently absent/present at message, session and event level.
fn normalize(mut s: SessionSnapshot) -> SessionSnapshot {
    fn usage(u: &mut UsageRecord, event: bool) {
        u.total_tokens = Usage::from(*u).total_tokens(); // N1
        if event {
            // N2: event storage uses zero for unreported buckets.
            u.input_tokens = Some(u.input_tokens.unwrap_or(0));
            u.cached_input_tokens = Some(u.cached_input_tokens.unwrap_or(0));
            u.cache_write_input_tokens = Some(u.cache_write_input_tokens.unwrap_or(0));
            u.output_tokens = Some(u.output_tokens.unwrap_or(0));
            u.reasoning_output_tokens = Some(u.reasoning_output_tokens.unwrap_or(0));
            u.total_tokens = Some(u.total_tokens.unwrap_or(0));
        }
    }
    fn time(t: &mut Option<String>) {
        *t = t
            .as_deref()
            .and_then(DartDateTime::try_parse)
            .map(DartDateTime::to_iso8601);
    }
    usage(&mut s.session.usage, false);
    s.session.title = s
        .session
        .title
        .map(|v| v.trim().to_owned())
        .filter(|v| !v.is_empty() && !v.to_lowercase().starts_with("# agents.md"));
    s.session.summary = s
        .session
        .summary
        .map(|v| v.trim().to_owned())
        .filter(|v| !v.is_empty() && v.to_lowercase() != "auto");
    s.session.thread_name = s
        .session
        .thread_name
        .map(|v| v.trim().to_owned())
        .filter(|v| !v.is_empty());
    time(&mut s.session.started_at_utc);
    time(&mut s.session.last_message_at_utc);
    for m in &mut s.messages {
        usage(&mut m.usage, false);
        time(&mut m.created_at_utc);
        m.author_type = AuthorType::from_name(&m.author_type).name().to_owned();
    }
    for t in &mut s.tool_calls {
        t.message_index = t.message_index.and_then(|index| {
            s.messages
                .iter()
                .filter(|m| m.index < index)
                .map(|m| m.index)
                .max()
        }); // N5
        time(&mut t.started_at_utc);
        time(&mut t.finished_at_utc);
    }
    for e in &mut s.usage_events {
        usage(&mut e.usage, true);
        time(&mut e.occurred_at_utc);
    }
    // N8: singleton legacy forks are covered by both parent-present/absent hub tests.
    if s.session.forked_from_id.is_some() || s.session.parent_thread_id.is_some() {
        s.session.usage_projection_status.clear();
        for event in &mut s.usage_events {
            event.branch_scope.clear();
        }
    }
    if s.extra == Some(serde_json::Value::Null) {
        s.extra = None;
    } // N7
    s
}

fn check(snapshot: SessionSnapshot, label: &str) {
    let temp = support::TempDir::new("snap-parity");
    let db = temp.path().join("a.sqlite");
    let store = Store::open(&db, OwnerMode::Standalone).unwrap();
    codex_sessions_collector::store::writer::apply_session_batch(
        &store.conn,
        vec![snapshot.clone()],
    )
    .unwrap();
    let id = codex_sessions_collector::store::writer::session_row_id(
        &snapshot.harness,
        snapshot.session.session_id.as_deref(),
        &snapshot.source.path,
    );
    let built = hub_snapshot::build(&store.conn, &id, Children::Include)
        .unwrap()
        .unwrap();
    support::assert_same(
        &serde_json::to_value(normalize(snapshot.clone())).unwrap(),
        &serde_json::to_value(normalize(built)).unwrap(),
    );
    group_check(vec![snapshot], label);
}

#[test]
fn generated_snapshot_fields_survive_storage() {
    for mask in 0..64u32 {
        for explicit in [false, true] {
            let bucket = |bit: u32, value: i64| (mask & (1u32 << bit) != 0u32).then_some(value);
            let u = UsageRecord {
                input_tokens: bucket(0, 11),
                cached_input_tokens: bucket(1, 3),
                cache_write_input_tokens: bucket(2, 5),
                output_tokens: bucket(3, 7),
                reasoning_output_tokens: bucket(4, 2),
                total_tokens: if explicit { Some(97) } else { bucket(5, 31) },
            };
            let mut s = support::sample_snapshot("generated");
            s.messages[0].usage = u;
            s.session.usage = u;
            s.usage_events[0].usage = u;
            s.session.thread_name = Some("  named thread  ".into());
            s.extra = Some(if explicit {
                json!({"retained": [1,2]})
            } else {
                json!(null)
            });
            check(s, &format!("mask={mask}, explicit={explicit}"));
        }
    }
}

fn db_content(db: &std::path::Path) -> serde_json::Value {
    let mut content = support::content_snapshot(db);
    for row in content["sessions"].as_array_mut().unwrap() {
        row.as_object_mut().unwrap().remove("content_hash");
    }
    codex_sessions_collector::store::connection::ensure().unwrap();
    let conn = rusqlite::Connection::open(db).unwrap();
    for row in content["tool_calls"].as_array_mut().unwrap() {
        let linked = row["message_id"].as_i64().map(|id| {
            conn.query_row("select message_index from messages where id=?", [id], |r| {
                r.get::<_, i64>(0)
            })
            .unwrap()
        });
        row["message_id"] = json!(linked);
    }
    content["session_source_extras"] = json!(support::rows(
        &conn,
        "select session_row_id,extra_json from session_source_extras order by session_row_id"
    ));
    content
}

fn group_check(snapshots: Vec<SessionSnapshot>, label: &str) {
    let temp = support::TempDir::new("snap-group");
    let a = temp.path().join("a.sqlite");
    let b = temp.path().join("b.sqlite");
    let sa = Store::open(&a, OwnerMode::Standalone).unwrap();
    let sb = Store::open(&b, OwnerMode::Standalone).unwrap();
    codex_sessions_collector::store::writer::apply_session_batch(&sa.conn, snapshots).unwrap();
    let ids: Vec<String> = sa
        .conn
        .prepare("select id from sessions order by id")
        .unwrap()
        .query_map([], |r| r.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    let rebuilt = ids
        .iter()
        .map(|id| {
            hub_snapshot::build(&sa.conn, id, Children::Include)
                .unwrap()
                .unwrap()
        })
        .collect();
    codex_sessions_collector::store::writer::apply_session_batch(&sb.conn, rebuilt).unwrap();
    eprintln!("group {label}");
    support::assert_same(&db_content(&a), &db_content(&b));
}

fn fixture_files(dir: &std::path::Path, files: &mut Vec<std::path::PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let entry = entry.unwrap();
        if entry.file_type().unwrap().is_dir() {
            fixture_files(&entry.path(), files);
        } else if matches!(
            entry.path().extension().and_then(|s| s.to_str()),
            Some("json" | "jsonl")
        ) {
            files.push(entry.path());
        }
    }
}

fn codex_fixture(name: &str) -> SessionSnapshot {
    use codex_sessions_collector::{
        codex::parser::{ParserOptions, parse_file},
        path_mapping::PathMapper,
    };
    let file = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../samples/collector-parity/sessions")
        .join(name);
    let p = parse_file(file.to_str().unwrap(), ParserOptions::default()).unwrap();
    let path = format!(r"C:\synthetic\{name}");
    let mapped = PathMapper::new("").map_windows_path(&path);
    codex_snapshot(
        &p.session,
        &CodexSource {
            path: &path,
            mapped: &mapped,
            state: "active",
            status: "available",
            size: p.snapshot_size,
            modified_utc: p.snapshot_modified_utc,
        },
        None,
        Vec::new(),
    )
}

#[test]
fn singleton_lineage_has_identical_hub_content_with_and_without_a_parent() {
    let temp = support::TempDir::new("lineage");
    let child = codex_fixture("forked_legacy_session.jsonl");
    let parent = codex_fixture("rich_session.jsonl");
    let local = Store::open(&temp.path().join("local.sqlite"), OwnerMode::Standalone).unwrap();
    local
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            child.clone(),
        )))])
        .unwrap();
    let rebuilt = hub_snapshot::build(&local.conn, "session:parity-fork-003", Children::Include)
        .unwrap()
        .unwrap();
    assert_eq!(child.session.usage_projection_status, "legacy_pending");
    assert_eq!(rebuilt.session.usage_projection_status, "missing_parent");
    for has_parent in [false, true] {
        let a = temp.path().join(format!("parsed-{has_parent}.sqlite"));
        let b = temp.path().join(format!("rebuilt-{has_parent}.sqlite"));
        for (db, snapshot) in [(&a, child.clone()), (&b, rebuilt.clone())] {
            let hub = Store::open(db, OwnerMode::Standalone).unwrap();
            if has_parent {
                hub.apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
                    parent.clone(),
                )))])
                .unwrap();
            }
            hub.apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
                snapshot,
            )))])
            .unwrap();
        }
        eprintln!("singleton lineage parent_present={has_parent}");
        support::assert_same(&db_content(&a), &db_content(&b));
    }
}

#[test]
fn a_parent_arriving_locally_requeues_the_resolved_child() {
    let temp = support::TempDir::new("lineage-queue");
    let store = Store::open(&temp.path().join("local.sqlite"), OwnerMode::Standalone).unwrap();
    store.conn.execute("insert into collector_hub_state(id,enabled,hub_url,machine_id) values(1,1,'http://127.0.0.1:1','test')",[]).unwrap();
    store
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            codex_fixture("forked_legacy_session.jsonl"),
        )))])
        .unwrap();
    store
        .conn
        .execute("delete from collector_upload_outbox", [])
        .unwrap();
    store
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            codex_fixture("rich_session.jsonl"),
        )))])
        .unwrap();
    let status: String = store
        .conn
        .query_row(
            "select usage_projection_status from sessions where id='session:parity-fork-003'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(status, "complete");
    let count:i64=store.conn.query_row("select count(*) from collector_upload_outbox where record_key='session:session:parity-fork-003'",[],|r|r.get(0)).unwrap();
    assert_eq!(count, 1, "resolved child must pass through enqueue_session");
    let first:i64=store.conn.query_row("select id from collector_upload_outbox where record_key='session:session:parity-fork-003'",[],|r|r.get(0)).unwrap();
    store
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(
            codex_fixture("rich_session.jsonl"),
        )))])
        .unwrap();
    let second:i64=store.conn.query_row("select id from collector_upload_outbox where record_key='session:session:parity-fork-003'",[],|r|r.get(0)).unwrap();
    assert_eq!(first, second, "unchanged sibling must not be requeued");
}

#[test]
fn parser_fixtures_and_directory_groups_match_stored_snapshots() {
    use codex_sessions_collector::{
        codex::parser::{self, ParserOptions, SourceType},
        path_mapping::PathMapper,
    };
    let mapper = PathMapper::new(r"\\wsl.localhost\Ubuntu");
    let mut files = Vec::new();
    for root in [
        "samples/sessions",
        "samples/collector-parity/sessions",
        "samples/claude/projects",
    ] {
        fixture_files(
            &std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("..")
                .join(root),
            &mut files,
        );
    }
    files.sort();
    let mut groups = std::collections::BTreeMap::<String, Vec<SessionSnapshot>>::new();
    let mut parsed_count = 0;
    let mut rejected = 0;
    for file in files {
        let claude = file.components().any(|c| c.as_os_str() == "claude");
        for variant in 0..if claude { 2 } else { 3 } {
            let name = file.file_name().unwrap().to_str().unwrap();
            let path = match variant {
                0 => format!(r"C:\synthetic\{name}"),
                1 => format!(r"\\wsl.localhost\Ubuntu\home\synthetic\{name}"),
                _ => format!(r"\\wsl.localhost\Ubuntu\mnt\c\synthetic\{name}"),
            };
            let snapshot = if claude {
                codex_sessions_collector::claude::parser::parse_transcript(
                    file.to_str().unwrap(),
                    &Default::default(),
                )
                .map(|t| {
                    codex_sessions_collector::claude::snapshot(
                        &path,
                        if variant == 0 {
                            SourceType::Windows
                        } else {
                            SourceType::Wsl
                        },
                        &mapper,
                        t,
                    )
                })
            } else {
                parser::parse_file(file.to_str().unwrap(), ParserOptions::default()).map(|p| {
                    let mapped = if variant == 0 {
                        mapper.map_windows_path(&path)
                    } else {
                        mapper.map_wsl_unc_path(&path)
                    };
                    codex_snapshot(
                        &p.session,
                        &CodexSource {
                            path: &path,
                            mapped: &mapped,
                            state: "active",
                            status: if p.changed_during_parse {
                                "changed_pending_parse"
                            } else {
                                "available"
                            },
                            size: p.snapshot_size,
                            modified_utc: p.snapshot_modified_utc,
                        },
                        None,
                        Vec::new(),
                    )
                })
            };
            match snapshot {
                Ok(s) => {
                    let label = format!("{} variant {variant}", file.display());
                    eprintln!("fixture {label}");
                    check(s.clone(), &label);
                    groups
                        .entry(format!("{}:{variant}", file.parent().unwrap().display()))
                        .or_default()
                        .push(s);
                    parsed_count += 1;
                }
                Err(error) => {
                    let negative = matches!(
                        file.file_name().unwrap().to_str().unwrap(),
                        "array_record.jsonl"
                            | "invalid_utf8.jsonl"
                            | "malformed_line.jsonl"
                            | "malformed_session.json"
                            | "malformed_session.jsonl"
                            | "scalar_root.json"
                    );
                    assert!(
                        negative,
                        "unexpected parser rejection for {}: {error:?}",
                        file.display()
                    );
                    eprintln!("rejected {}: {:?}", file.display(), error);
                    rejected += 1;
                }
            }
        }
    }
    assert!(parsed_count > 30);
    assert!(rejected > 0);
    for (label, snapshots) in groups {
        group_check(snapshots, &label);
    }
    eprintln!("fixture coverage parsed={parsed_count}, rejected={rejected}");
}

#[test]
fn generated_headers_paths_tools_and_extras_survive_storage() {
    for (index, title, summary, extra, status) in [
        (0, "# AGENTS.md injected", "auto", json!(null), "available"),
        (
            9,
            "  Retained title  ",
            "  Retained summary  ",
            json!({"nested":{"retained":true}}),
            "changed_pending_parse",
        ),
    ] {
        let mut s = support::sample_snapshot("headers");
        s.session.usage.reasoning_output_tokens = Some(17);
        s.messages[0].usage.reasoning_output_tokens = Some(13);
        s.messages[0].index = 4;
        s.messages[0].author_type = "future_author".into();
        s.tool_calls[0].message_index = Some(index);
        s.session.title = Some(title.into());
        s.session.summary = Some(summary.into());
        s.session.thread_name = Some("  surrounding spaces  ".into());
        s.extra = Some(extra);
        s.source.status = status.into();
        s.source.normalized_path_keys =
            vec!["z:/last".into(), "a:/first".into(), "m:/middle".into()];
        s.project_hints = vec![
            ProjectHint {
                working_directory: s.session.working_directory_display.clone().unwrap(),
                project_name: "session-project".into(),
            },
            ProjectHint {
                working_directory: "C:/usage-dir".into(),
                project_name: "usage-project".into(),
            },
        ];
        s.usage_events[0].working_directory = Some("C:/usage-dir".into());
        s.usage_events[0].billable_units =
            Some(json!({"web_search_calls":7}).as_object().unwrap().clone());
        check(s, &format!("headers-tool-index={index}"));
    }
}

#[test]
fn pre_migration_rows_have_unknown_tokens_and_legacy_refined_hints() {
    let temp = support::TempDir::new("legacy-fields");
    let store = Store::open(&temp.path().join("db.sqlite"), OwnerMode::Standalone).unwrap();
    let mut s = support::sample_snapshot("old");
    s.project_hints = vec![ProjectHint {
        working_directory: s.session.working_directory_display.clone().unwrap(),
        project_name: "legacy-project".into(),
    }];
    store
        .apply(vec![Envelope::new(Record::SessionSnapshot(Box::new(s)))])
        .unwrap();
    store.conn.execute_batch("update projects set name='legacy-project' where id=(select detected_project_id from sessions where id='session:old');update sessions set cache_write_input_tokens=null,reasoning_output_tokens=null,project_hints_json=null,project_refined=1;update messages set token_cache_write=null,token_reasoning=null;").unwrap();
    let rebuilt = hub_snapshot::build(&store.conn, "session:old", Children::Include)
        .unwrap()
        .unwrap();
    assert_eq!(rebuilt.session.usage.cache_write_input_tokens, None);
    assert_eq!(rebuilt.session.usage.reasoning_output_tokens, None);
    assert_eq!(rebuilt.messages[0].usage.cache_write_input_tokens, None);
    assert_eq!(rebuilt.messages[0].usage.reasoning_output_tokens, None);
    assert_eq!(rebuilt.project_hints[0].project_name, "legacy-project");
    store
        .conn
        .execute("update sessions set project_refined=0", [])
        .unwrap();
    assert!(
        hub_snapshot::build(&store.conn, "session:old", Children::Include)
            .unwrap()
            .unwrap()
            .project_hints
            .is_empty()
    );
}
