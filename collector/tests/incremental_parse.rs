//! Differential reference: the unchanged full parser on the same source bytes.
use codex_sessions_collector::claude::parser::{ClaudeOptions, parse_transcript_with};
use codex_sessions_collector::codex::parser::{
    ParseError, ParserOptions, SourceType, parse_file_with,
};
use codex_sessions_collector::contract::{
    CodexSource, MessageRecord, SessionSnapshot, ToolCallRecord, UsageEventRecord, codex_snapshot,
};
use codex_sessions_collector::path_mapping::PathMapper;
use codex_sessions_collector::resume::{
    AbandonReason, Checkpoint, CheckpointRecord, DeltaScope, LoadedCheckpoint, ReadCounterScope,
    Resume, ResumeOutcome, ResumePolicy, ResumePolicyScope, SessionTotals,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[path = "support/incremental_store.rs"]
mod incremental_store;
#[path = "support/session_gen.rs"]
mod session_gen;
mod support;

fn extreme_source(claude: bool) -> Vec<u8> {
    let mut bytes = Vec::new();
    for (id, input) in [i64::MAX, 1, 1].into_iter().enumerate() {
        let record = if claude {
            json!({"type":"assistant","message":{"id":format!("extreme-{id}"),"content":format!("message-{id}"),"usage":{"input_tokens":input,"cache_read_input_tokens":1,"output_tokens":1}}})
        } else {
            json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":format!("message-{id}"),"usage":{"input_tokens":input,"output_tokens":0}}})
        };
        bytes.extend_from_slice(format!("{record}\n").as_bytes());
    }
    bytes.extend_from_slice(&vec![b' '; 1024 * 1024]);
    bytes.push(b'\n');
    bytes
}

#[test]
fn zero_complete_line_resume_preserves_checkpoint_and_step_counter() {
    for claude in [false, true] {
        let dir = support::TempDir::new("zero-step");
        let file = dir.path().join("session.jsonl");
        let path = file.to_str().unwrap();
        let value = if claude {
            json!({"type":"user","message":{"content":"first"}})
        } else {
            json!({"type":"response_item","payload":{"type":"message","role":"user","content":"first"}})
        };
        let prefix = format!("{value}\n");
        std::fs::write(&file, &prefix).unwrap();
        let saved = parse(
            path,
            claude,
            SourceType::Windows,
            Resume::Fresh(ResumePolicy::testing()),
        )
        .unwrap()
        .checkpoint
        .unwrap();
        for tail in ["", &value.to_string()] {
            std::fs::write(&file, format!("{prefix}{tail}")).unwrap();
            let actual = parse(
                path,
                claude,
                SourceType::Windows,
                Resume::From(LoadedCheckpoint {
                    policy: ResumePolicy::testing(),
                    ..LoadedCheckpoint::new(saved.decode().unwrap(), "row", "hash")
                }),
            )
            .unwrap();
            assert_eq!(actual.outcome, ResumeOutcome::Resumed);
            assert_eq!(
                actual.checkpoint.unwrap(),
                saved,
                "zero complete-line progress preserves the exact saved observer state"
            );
        }
    }
}
fn extreme_full_parse(claude: bool) {
    let dir = support::TempDir::new("extreme-default");
    let file = dir.path().join("session.jsonl");
    let path = file.to_str().unwrap();
    let mut bytes = extreme_source(claude);
    std::fs::write(&file, &bytes).unwrap();
    let full = parse(path, claude, SourceType::Windows, Resume::Disabled)
        .expect("ff6675c release full parse accepts overflowing token sums");
    let expected = if claude {
        i64::MAX.wrapping_add(1).wrapping_add(2).wrapping_add(2)
    } else {
        i64::MAX.wrapping_add(1).wrapping_add(1)
    };
    assert_eq!(
        full.snapshot.session.usage.input_tokens,
        Some(expected),
        "ff6675c wrapping oracle"
    );
    let fresh = parse(
        path,
        claude,
        SourceType::Windows,
        Resume::Fresh(ResumePolicy::default()),
    )
    .expect("checkpoint observer must preserve full parse success");
    assert_eq!(fresh.snapshot, full.snapshot);
    let record = fresh
        .checkpoint
        .expect("extreme tokens must not disable checkpointing");
    assert_eq!(record.decode().unwrap().steps_since_full, 0);
    let mut model = Model::default();
    model.apply(&full);
    bytes.extend_from_slice(b"{}\n");
    std::fs::write(&file, &bytes).unwrap();
    let resumed = parse(
        path,
        claude,
        SourceType::Windows,
        Resume::From(LoadedCheckpoint::new(
            record.decode().unwrap(),
            "row",
            "hash",
        )),
    )
    .unwrap();
    assert_eq!(resumed.outcome, ResumeOutcome::Resumed);
    assert!(
        resumed
            .checkpoint
            .as_ref()
            .unwrap()
            .decode()
            .unwrap()
            .steps_since_full
            > 0
    );
    assert_eq!(
        model.apply(&resumed),
        parse(path, claude, SourceType::Windows, Resume::Disabled)
            .unwrap()
            .snapshot
    );
}
#[test]
fn extreme_token_values_never_change_codex_full_parse() {
    extreme_full_parse(false);
}
#[test]
fn extreme_token_values_never_change_claude_full_parse() {
    extreme_full_parse(true);
}

/// Coordinator decision CXV-215-CR-05 (2026-11-08, review-r4 disposition):
/// a late abandon may read the appended suffix once before one full fallback.
/// Review-r5 requires measured attempt bytes, never the possible suffix length.
/// Blob and second-step limits are unchanged.
fn resume_read_bound(source_bytes: u64, attempt_reads: u64) -> u64 {
    source_bytes + attempt_reads + 288 * 1024
}

fn assert_single_fallback(source_bytes: u64, reader_bytes: &[u64], context: &str) {
    assert!(
        reader_bytes.len().saturating_sub(1) <= 1,
        "at most one full-source fallback: {context}: {reader_bytes:?}"
    );
    assert!(
        reader_bytes
            .iter()
            .skip(1)
            .all(|bytes| *bytes <= source_bytes),
        "fallback reads at most the full source once: {context}: {reader_bytes:?}"
    );
}

fn assert_resume_read_bound(reads: &ReadCounterScope, source_bytes: u64, context: &str) {
    let reader_bytes = reads.reader_bytes();
    assert_eq!(reader_bytes.iter().sum::<u64>(), reads.bytes(), "{context}");
    let attempt_reads = reader_bytes.first().copied().unwrap_or(0);
    assert!(
        reads.bytes() <= resume_read_bound(source_bytes, attempt_reads),
        "bounded source reads: {context}: source={source_bytes} attempt={attempt_reads} total={} readers={reader_bytes:?}",
        reads.bytes()
    );
}

fn assert_resume_reads(reads: &ReadCounterScope, source_bytes: u64, context: &str) {
    assert_resume_read_bound(reads, source_bytes, context);
    assert_single_fallback(source_bytes, &reads.reader_bytes(), context);
}

fn late_abandon_read_bound(claude: bool) {
    let _policy = ResumePolicyScope::enter(ResumePolicy::default());
    let dir = support::TempDir::new("late-abandon");
    let file = dir.path().join("session.jsonl");
    let path = file.to_str().unwrap();
    let mut bytes = vec![b' '; 1024 * 1024];
    bytes.extend_from_slice(b"\n{}\n");
    std::fs::write(&file, &bytes).unwrap();
    let mut cp = parse(
        path,
        claude,
        SourceType::Windows,
        Resume::Fresh(ResumePolicy::default()),
    )
    .unwrap()
    .checkpoint
    .unwrap()
    .decode()
    .unwrap();
    cp.closed.assistant_tokens = 42;
    cp.state["closed"]["assistant_tokens"] = json!(42);
    let cp = cp.encode().unwrap().decode().unwrap();
    let window_bytes: u64 = cp
        .windows
        .head
        .iter()
        .chain(&cp.windows.anchors)
        .chain(&cp.windows.tail)
        .map(|window| window.length)
        .sum();
    bytes.extend(std::iter::repeat_n(b' ', 512 * 1024));
    bytes.push(b'\n');
    bytes.extend_from_slice(if claude {
        b"{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"orphan\",\"content\":\"ok\"}]}}\n"
    } else {
        b"{\"type\":\"response_item\",\"payload\":{\"type\":\"function_call_output\",\"call_id\":\"orphan\",\"output\":\"ok\"}}\n"
    });
    std::fs::write(&file, &bytes).unwrap();
    let source_bytes = bytes.len() as u64;
    let consumed = cp.consumed;
    let suffix_bytes = source_bytes - consumed;
    let reads = ReadCounterScope::enter();
    let actual = parse(
        path,
        claude,
        SourceType::Windows,
        Resume::From(LoadedCheckpoint::new(cp, "row", "hash")),
    )
    .unwrap();
    let read_bytes = reads.bytes();
    drop(reads);
    assert_eq!(
        actual.outcome,
        ResumeOutcome::Abandoned(AbandonReason::Finality)
    );
    let full_reads = ReadCounterScope::enter();
    let full = parse(path, claude, SourceType::Windows, Resume::Disabled).unwrap();
    assert_eq!(full_reads.bytes(), source_bytes);
    drop(full_reads);
    assert_eq!(actual.snapshot, full.snapshot);
    assert_eq!(actual.parser_fields, full.parser_fields);
    // The orphan is last, so the attempt reads the whole suffix. Subtract its
    // bytes and the exact fingerprint windows to isolate the fallback read.
    assert_eq!(read_bytes, window_bytes + suffix_bytes + source_bytes);
    assert!(read_bytes - window_bytes - suffix_bytes <= source_bytes);
    assert!(read_bytes <= resume_read_bound(source_bytes, window_bytes + suffix_bytes));
    println!(
        "late abandon claude={claude}: source={source_bytes} suffix={suffix_bytes} windows={window_bytes} reads={read_bytes}; one full fallback"
    );
}

#[test]
fn late_codex_abandon_read_bound() {
    late_abandon_read_bound(false);
}
#[test]
fn late_claude_abandon_read_bound() {
    late_abandon_read_bound(true);
}

fn early_duplicate_fallback_must_be_rejected(claude: bool) {
    use codex_sessions_collector::resume::BeforeReadScope;
    let _policy = ResumePolicyScope::enter(ResumePolicy::default());
    let dir = support::TempDir::new("duplicate-fallback");
    let file = dir.path().join("session.jsonl");
    let path = file.to_str().unwrap();
    let mut bytes = vec![b' '; 1024 * 1024];
    bytes.extend_from_slice(b"\n{}\n");
    std::fs::write(&file, &bytes).unwrap();
    let mut cp = parse(
        path,
        claude,
        SourceType::Windows,
        Resume::Fresh(ResumePolicy::default()),
    )
    .unwrap()
    .checkpoint
    .unwrap()
    .decode()
    .unwrap();
    assert!(cp.next_line > 0);
    cp.consumed = 0;
    let cp = cp.encode().unwrap().decode().unwrap();
    let hook_path = path.to_owned();
    // This mismatch abandons before any attempt I/O. Inject a second full parse
    // at fallback's first read, exactly as review-r5's generic-bound-probe.rs.
    let hook = BeforeReadScope::enter(move || {
        parse(&hook_path, claude, SourceType::Windows, Resume::Disabled).unwrap();
    });
    let reads = ReadCounterScope::enter();
    let actual = parse(
        path,
        claude,
        SourceType::Windows,
        Resume::From(LoadedCheckpoint::new(cp, "row", "hash")),
    )
    .unwrap();
    drop(hook);
    let source_bytes = bytes.len() as u64;
    assert_eq!(
        actual.outcome,
        ResumeOutcome::Abandoned(AbandonReason::Mismatch)
    );
    assert_eq!(reads.bytes(), 2 * source_bytes);
    assert_eq!(reads.reader_bytes(), [0, source_bytes, source_bytes]);
    let rejected = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        assert_resume_read_bound(&reads, source_bytes, "injected duplicate fallback");
    }));
    assert!(
        rejected.is_err(),
        "generic read bound must reject duplicate fallback"
    );
    let fallback_rejected = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        assert_single_fallback(
            source_bytes,
            &reads.reader_bytes(),
            "injected duplicate fallback",
        );
    }));
    assert!(
        fallback_rejected.is_err(),
        "fallback count must independently reject duplication"
    );
    println!(
        "early duplicate claude={claude}: source={source_bytes} attempt=0 total={} readers={:?}; both assertions reject",
        reads.bytes(),
        reads.reader_bytes()
    );
}

#[test]
fn early_codex_duplicate_fallback_must_be_rejected() {
    early_duplicate_fallback_must_be_rejected(false);
}
#[test]
fn early_claude_duplicate_fallback_must_be_rejected() {
    early_duplicate_fallback_must_be_rejected(true);
}

fn bounded_resigned_step(path: &str, claude: bool, cp: Checkpoint, context: &str) -> Parsed {
    let source_bytes = std::fs::metadata(path).unwrap().len();
    let reads = ReadCounterScope::enter();
    let actual = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        parse(
            path,
            claude,
            SourceType::Windows,
            Resume::From(LoadedCheckpoint::new(cp, "row", "hash")),
        )
    }))
    .unwrap_or_else(|_| panic!("panic: {context}"))
    .unwrap_or_else(|error| panic!("stricter parse: {context}: {error:?}"));
    assert_resume_reads(&reads, source_bytes, context);
    drop(reads);
    if let Some(record) = &actual.checkpoint {
        assert!(
            record.state.len() <= codex_sessions_collector::resume::MAX_BLOB_BYTES,
            "{context}"
        );
        assert!(
            zstd::stream::decode_all(record.state.as_slice())
                .unwrap()
                .len()
                <= codex_sessions_collector::resume::MAX_DECODED_BYTES,
            "{context}"
        );
        record.decode().expect("emitted checkpoint decodes");
    }
    if actual.outcome != ResumeOutcome::Resumed {
        assert_eq!(
            actual.snapshot,
            parse(path, claude, SourceType::Windows, Resume::Disabled)
                .unwrap()
                .snapshot,
            "fallback equals full parse: {context}"
        );
    }
    actual
}
fn second_resigned_step(path: &str, claude: bool, actual: &Parsed, context: &str) {
    use std::io::Write;
    if actual.outcome == ResumeOutcome::Resumed {
        let cp = actual
            .checkpoint
            .as_ref()
            .expect("resumed small source must emit a checkpoint")
            .decode()
            .unwrap();
        std::fs::OpenOptions::new()
            .append(true)
            .open(path)
            .unwrap()
            .write_all(b"{}\n")
            .unwrap();
        let _ = bounded_resigned_step(path, claude, cp, context);
    }
}
#[test]
fn retained_usage_mutation_falls_back_unless_resigned() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("retained-usage");
    let file = dir.path().join("claude.jsonl");
    let path = file.to_str().unwrap();
    let prefix=(0..2).map(|id|format!("{}\n",json!({"type":"assistant","message":{"id":format!("id-{id}"),"content":"text","usage":{"input_tokens":1,"output_tokens":1}}}))).collect::<String>();
    for value in [7, i64::MAX] {
        std::fs::write(&file, &prefix).unwrap();
        let saved = fresh_checkpoint(path, true);
        let record = saved.encode().unwrap();
        let mut envelope: Value =
            serde_json::from_slice(&zstd::stream::decode_all(record.state.as_slice()).unwrap())
                .unwrap();
        envelope["payload"]["state"]["usage_by_message"][0][1]["usage"]["input_tokens"] =
            json!(value);
        let mut unsigned = record;
        unsigned.state =
            zstd::stream::encode_all(serde_json::to_vec(&envelope).unwrap().as_slice(), 3).unwrap();
        assert!(unsigned.decode().is_err());
        let mut cp = saved;
        cp.state["usage_by_message"][0][1]["usage"]["input_tokens"] = json!(value);
        std::fs::write(&file, format!("{prefix}{{}}\n")).unwrap();
        let actual = bounded_resigned_step(
            path,
            true,
            cp.encode().unwrap().decode().unwrap(),
            "retained usage",
        );
        assert_eq!(actual.outcome, ResumeOutcome::Resumed);
        second_resigned_step(path, true, &actual, "retained usage second");
    }
}
#[test]
fn resigned_extreme_closed_totals_resume_with_wrapping() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("closed-wrapping");
    for claude in [false, true] {
        let file = dir.path().join(if claude {
            "claude.jsonl"
        } else {
            "codex.jsonl"
        });
        let path = file.to_str().unwrap();
        let message = |id| {
            if claude {
                json!({"type":"assistant","message":{"id":format!("id-{id}"),"content":format!("text-{id}"),"usage":{"input_tokens":1,"output_tokens":1}}})
            } else {
                json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":format!("text-{id}"),"usage":{"input_tokens":1,"output_tokens":1}}})
            }
        };
        let prefix = (0..3)
            .map(|id| format!("{}\n", message(id)))
            .collect::<String>();
        std::fs::write(&file, &prefix).unwrap();
        let mut cp = fresh_checkpoint(path, claude);
        if claude {
            cp.state["closed_usage_total"]["input_tokens"] = json!(i64::MAX);
            cp.state["closed_usage_total"]["output_tokens"] = json!(0);
            cp.state["closed_usage_total"]["total_tokens"] = json!(i64::MAX);
        } else {
            cp.closed.assistant_tokens = i64::MAX;
            cp.state["closed"]["assistant_tokens"] = json!(i64::MAX);
        }
        let old = cp.clone();
        std::fs::write(&file, format!("{prefix}{}\n", message(3))).unwrap();
        let actual = bounded_resigned_step(
            path,
            claude,
            cp.encode().unwrap().decode().unwrap(),
            "closed wrapping",
        );
        assert_eq!(actual.outcome, ResumeOutcome::Resumed);
        if claude {
            assert_eq!(
                actual.snapshot.session.usage.input_tokens,
                Some(i64::MAX.wrapping_add(3))
            );
        } else {
            let mut totals = old.closed;
            for row in &actual.snapshot.messages {
                totals.add_message(row);
            }
            assert_eq!(totals.assistant_tokens, i64::MAX.wrapping_add(4));
            assert_eq!(
                actual
                    .checkpoint
                    .as_ref()
                    .unwrap()
                    .decode()
                    .unwrap()
                    .closed
                    .assistant_tokens,
                i64::MAX.wrapping_add(2)
            );
        }
        second_resigned_step(path, claude, &actual, "closed wrapping second");
    }
}
#[test]
fn resigned_cumulative_mismatch_is_bounded() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("cumulative-mismatch");
    let file = dir.path().join("codex.jsonl");
    let path = file.to_str().unwrap();
    let event = |n| {
        format!(
            "{}\n",
            json!({"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":n,"output_tokens":0}}}})
        )
    };
    let prefix = format!("{}{}", event(10), event(15));
    std::fs::write(&file, &prefix).unwrap();
    let mut cp = fresh_checkpoint(path, false);
    cp.state["previous_cumulative_usage"]["input_tokens"] = json!(10);
    std::fs::write(&file, format!("{prefix}{}", event(20))).unwrap();
    let actual = bounded_resigned_step(
        path,
        false,
        cp.encode().unwrap().decode().unwrap(),
        "cumulative mismatch",
    );
    assert_eq!(actual.outcome, ResumeOutcome::Resumed);
    second_resigned_step(path, false, &actual, "cumulative mismatch second");
}

#[test]
fn checkpoint_folds_are_grouping_independent() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let mut rng = session_gen::Rng::new(0xc215_0303);
    let dir = support::TempDir::new("fold-groups");
    let file = dir.path().join("claude.jsonl");
    let path = file.to_str().unwrap();
    let values = [i64::MIN, i64::MAX, i64::MAX - 1, -1, 0, 1, 1i64 << 62];
    let sample = support::sample_snapshot("groups");
    let mut rows = 0;
    for case in 0..64 {
        let length = 1 + rng.bounded(16);
        let split = rng.bounded(length + 1);
        let mut messages = Vec::new();
        let mut tools = Vec::new();
        let mut source = String::new();
        let mut expected_input = 0i128;
        let mut expected_output = 0i128;
        for index in 0..length {
            let input = values[rng.bounded(values.len())];
            let output = values[rng.bounded(values.len())];
            let cache = values[rng.bounded(values.len())];
            let mut message = sample.messages[0].clone();
            message.author_type = ["user", "assistant", "tool"][rng.bounded(3)].to_owned();
            message.usage.input_tokens = Some(input);
            message.usage.output_tokens = Some(output);
            message.usage.total_tokens = None;
            message.has_error = rng.bounded(2) == 0;
            message.content_plain = if rng.bounded(2) == 0 {
                "```code"
            } else {
                "text"
            }
            .to_owned();
            messages.push(message);
            let mut tool = sample.tool_calls[0].clone();
            tool.status = if rng.bounded(2) == 0 {
                "error"
            } else {
                "finished"
            }
            .to_owned();
            tools.push(tool);
            source.push_str(&format!("{}\n",json!({"type":"assistant","message":{"id":format!("case-{case}-row-{index}"),"content":"text","usage":{"input_tokens":input,"cache_read_input_tokens":cache,"output_tokens":output}}})));
            expected_input += i128::from(input) + i128::from(cache);
            expected_output += i128::from(output);
        }
        let mut grouped = SessionTotals::from_rows(&messages[..split], &tools[..split]);
        for message in &messages[split..] {
            grouped.add_message(message);
        }
        for tool in &tools[split..] {
            grouped.add_tool(tool);
        }
        assert_eq!(grouped, SessionTotals::from_rows(&messages, &tools));
        std::fs::write(&file, &source).unwrap();
        let full = parse(path, true, SourceType::Windows, Resume::Disabled).unwrap();
        let fresh = parse(
            path,
            true,
            SourceType::Windows,
            Resume::Fresh(ResumePolicy::testing()),
        )
        .unwrap();
        assert_eq!(fresh.snapshot, full.snapshot);
        assert_eq!(
            full.snapshot.session.usage.input_tokens,
            Some(expected_input as i64)
        );
        assert_eq!(
            full.snapshot.session.usage.output_tokens,
            Some(expected_output as i64)
        );
        let cp = fresh.checkpoint.unwrap().decode().unwrap();
        let mut folded_input = i128::from(
            cp.state["closed_usage_total"]["input_tokens"]
                .as_i64()
                .unwrap_or(0),
        );
        let mut folded_output = i128::from(
            cp.state["closed_usage_total"]["output_tokens"]
                .as_i64()
                .unwrap_or(0),
        );
        for event in cp.state["usage_by_message"].as_array().unwrap() {
            folded_input += i128::from(event[1]["usage"]["input_tokens"].as_i64().unwrap());
            folded_output += i128::from(event[1]["usage"]["output_tokens"].as_i64().unwrap());
        }
        assert_eq!(folded_input as i64, expected_input as i64);
        assert_eq!(folded_output as i64, expected_output as i64);
        rows += length;
    }
    println!(
        "fold grouping seed=0xc2150303 cases=64 rows={rows} lengths=1..16 random splits; signed extremes included"
    );
}

#[test]
fn resume_outcomes_distinguish_abandon_reasons() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("outcomes");
    for claude in [false, true] {
        let file = dir.path().join(if claude {
            "claude.jsonl"
        } else {
            "codex.jsonl"
        });
        let path = file.to_str().unwrap();
        let prefix = b"{\"x\":1}\n";
        std::fs::write(&file, prefix).unwrap();
        let fresh = parse(
            path,
            claude,
            SourceType::Windows,
            Resume::Fresh(ResumePolicy::testing()),
        )
        .unwrap();
        assert_eq!(fresh.outcome, ResumeOutcome::NotAttempted);
        let cp = fresh.checkpoint.unwrap().decode().unwrap();
        for reason in [
            AbandonReason::Mismatch,
            AbandonReason::Structure,
            AbandonReason::Windows,
            AbandonReason::Finality,
        ] {
            let mut saved = cp.clone();
            let mut bytes = prefix.to_vec();
            match reason {
                AbandonReason::Mismatch=>saved.steps_since_full=codex_sessions_collector::resume::MAX_STEPS,
                AbandonReason::Structure=>saved.state["message_base"]=json!(-1),
                AbandonReason::Windows=>bytes=b"{\"x\":2}\n".to_vec(),
                AbandonReason::Finality=>bytes.extend_from_slice(format!("{}\n",if claude {json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"unknown","content":"result"}]}})} else {json!({"type":"response_item","payload":{"type":"function_call_output","call_id":"unknown","output":"result"}})}).as_bytes()),
            }
            std::fs::write(&file, bytes).unwrap();
            let actual = bounded_resigned_step(
                path,
                claude,
                saved.encode().unwrap().decode().unwrap(),
                "abandon reason",
            );
            assert_eq!(actual.outcome, ResumeOutcome::Abandoned(reason));
            assert_eq!(
                actual
                    .checkpoint
                    .unwrap()
                    .decode()
                    .unwrap()
                    .steps_since_full,
                0
            );
        }
    }
}

fn leaf_mutations(
    value: &Value,
    path: String,
    output: &mut Vec<(String, Value)>,
    leaves: &mut usize,
) {
    let replacements = match value {
        Value::Object(fields) => {
            for (key, value) in fields {
                leaf_mutations(
                    value,
                    format!("{path}/{}", key.replace('~', "~0").replace('/', "~1")),
                    output,
                    leaves,
                );
            }
            return;
        }
        Value::Array(values) => {
            for (index, value) in values.iter().enumerate() {
                leaf_mutations(value, format!("{path}/{index}"), output, leaves);
            }
            let mut replacements = vec![json!([])];
            if !values.is_empty() {
                replacements.push(json!(&values[..values.len() - 1]));
                let mut duplicate = values.clone();
                duplicate.push(values[0].clone());
                replacements.push(json!(duplicate));
            }
            if values.len() >= 2 {
                let mut swapped = values.clone();
                swapped.swap(0, 1);
                replacements.push(json!(swapped));
            }
            replacements
        }
        Value::Number(_) => {
            *leaves += 1;
            vec![
                json!(0),
                json!(1),
                json!(-1),
                json!(-7),
                json!(i64::MIN),
                json!(i64::MAX),
                json!(u64::MAX),
            ]
        }
        Value::String(_) => {
            *leaves += 1;
            vec![json!(""), json!("changed")]
        }
        Value::Bool(flag) => {
            *leaves += 1;
            vec![json!(!flag)]
        }
        Value::Null => {
            *leaves += 1;
            vec![json!(0), json!("changed")]
        }
    };
    for replacement in replacements {
        if &replacement != value {
            output.push((path.clone(), replacement));
        }
    }
}

#[test]
fn every_checkpoint_leaf_is_safe_in_both_integrity_modes() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("leaf-mutations");
    let mut tested = [false; 2];
    let started = std::time::Instant::now();
    let mut all_counts = [[[0usize; 3]; 2]; 2]; // harness, integrity mode, mutated/fallback/resumed
    let mut covered_leaves = [0; 2];
    for input in session_gen::inputs()
        .into_iter()
        .filter(|input| input.name == "codex-seed-1-meta-0" || input.name == "claude-seed-1")
    {
        let harness = usize::from(input.claude);
        let counts = &mut all_counts[harness];
        let file = dir.path().join(if input.claude {
            "claude.jsonl"
        } else {
            "codex.jsonl"
        });
        let path = file.to_str().unwrap();
        for end in input
            .bytes
            .iter()
            .enumerate()
            .filter_map(|(i, b)| (*b == b'\n').then_some(i + 1))
        {
            std::fs::write(&file, &input.bytes[..end]).unwrap();
            let Ok(before) = parse(
                path,
                input.claude,
                SourceType::Windows,
                Resume::Fresh(ResumePolicy::testing()),
            ) else {
                continue;
            };
            let Some(record) = &before.checkpoint else {
                continue;
            };
            let saved = record.decode().unwrap();
            if saved.state["open_tools"].as_object().unwrap().is_empty()
                || saved.state["usage_base"].as_i64().unwrap() == 0
            {
                continue;
            }
            let mut encoded: Value =
                serde_json::from_slice(&zstd::stream::decode_all(record.state.as_slice()).unwrap())
                    .unwrap();
            let payload = encoded.get("payload").unwrap_or(&encoded).clone();
            let mut mutations = Vec::new();
            leaf_mutations(
                &payload,
                String::new(),
                &mut mutations,
                &mut covered_leaves[harness],
            );
            assert!(mutations.len() < 10000, "bounded corpus");
            // Continue through the paths that use restored counters, usage and
            // pending-call positions, rather than only decoding inert state.
            let pending = saved.state[if input.claude {
                "pending_tools"
            } else {
                "pending_tool_calls"
            }]
            .as_object()
            .unwrap()
            .keys()
            .next()
            .unwrap();
            let records = if input.claude {
                vec![
                    json!({"type":"assistant","message":{"id":"mutator-new-usage","content":"new","usage":{"input_tokens":1,"output_tokens":1}}}),
                    json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":pending,"content":"done"}]}}),
                ]
            } else {
                vec![
                    json!({"type":"turn_context","payload":{"model":"mutator-model"}}),
                    json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":"new","usage":{"input_tokens":1,"output_tokens":1}}}),
                    json!({"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"output_tokens":3}}}}),
                    json!({"type":"response_item","payload":{"type":"function_call_output","call_id":pending,"output":"done"}}),
                ]
            };
            let suffix = records
                .iter()
                .map(|record| format!("{record}\n"))
                .collect::<String>();
            std::fs::write(&file, [&input.bytes[..end], suffix.as_bytes()].concat()).unwrap();
            let full = parse(path, input.claude, SourceType::Windows, Resume::Disabled);
            let absent = parse(
                path,
                input.claude,
                SourceType::Windows,
                Resume::Fresh(ResumePolicy::testing()),
            );
            fresh_equals_disabled(&full, &absent, "stale digest loader fallback");
            assert!(
                parse(
                    path,
                    input.claude,
                    SourceType::Windows,
                    Resume::From(LoadedCheckpoint::new(saved, "row", "hash"))
                )
                .unwrap()
                .scope
                .is_some()
            );
            for (pointer, replacement) in mutations {
                let mut changed = payload.clone();
                *changed.pointer_mut(&pointer).unwrap() = replacement.clone();
                for (mode, count) in counts.iter_mut().enumerate() {
                    let decoded = if mode == 0 {
                        if encoded.get("payload").is_some() {
                            encoded["payload"] = changed.clone();
                        } else {
                            encoded = changed.clone();
                        }
                        let mut corrupt = record.clone();
                        corrupt.state = zstd::stream::encode_all(
                            serde_json::to_vec(&encoded).unwrap().as_slice(),
                            3,
                        )
                        .unwrap();
                        corrupt.decode().ok()
                    } else {
                        serde_json::from_value::<Checkpoint>(changed.clone())
                            .ok()
                            .and_then(|cp| cp.encode())
                            .and_then(|record| record.decode().ok())
                    };
                    count[0] += 1;
                    let Some(cp) = decoded else {
                        count[1] += 1;
                        continue;
                    };
                    assert_eq!(mode, 1, "stale digest must fail decoding");
                    let context = format!(
                        "input={} mode={mode} pointer={pointer} replacement={replacement}",
                        input.name
                    );
                    let actual = bounded_resigned_step(path, input.claude, cp, &context);
                    if actual.outcome == ResumeOutcome::Resumed {
                        count[2] += 1;
                    } else {
                        count[1] += 1;
                    }
                    second_resigned_step(path, input.claude, &actual, &context);
                    std::fs::write(&file, [&input.bytes[..end], suffix.as_bytes()].concat())
                        .unwrap();
                }
            }
            tested[harness] = true;
            break;
        }
    }
    assert!(tested.into_iter().all(|value| value));
    for (harness, counts) in all_counts.iter().enumerate() {
        assert_eq!(counts[0][0], counts[0][1]);
        assert_eq!(counts[0][2], 0);
        println!(
            "generic leaf mutator harness={harness} leaves={}; [cases,fallback,resumed] stale-digest={:?} re-signed={:?}",
            covered_leaves[harness], counts[0], counts[1]
        );
    }
    println!(
        "generic leaf mutator elapsed={:?}; bounded mutations <10000/harness, source reads <= source+measured attempt+288KiB, at most one full-source fallback, blobs <=256KiB / decoded <=64MiB",
        started.elapsed()
    );
}

#[test]
fn corrupt_claude_tool_position_falls_back_without_panic() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("corrupt-position");
    let file = dir.path().join("claude.jsonl");
    let path = file.to_str().unwrap();
    let prefix = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"late\",\"name\":\"Read\",\"input\":{}}]}}\n";
    std::fs::write(&file, prefix).unwrap();
    let mut cp = fresh_checkpoint(path, true);
    let tools = cp.state["open_tools"].as_object_mut().unwrap();
    let mut row = tools.remove("0").unwrap();
    row["tool_index"] = json!(-1);
    tools.insert(usize::MAX.to_string(), row);
    cp.state["pending_tools"]["late"] = json!(usize::MAX);
    let cp = cp.encode().unwrap().decode().unwrap();
    std::fs::write(&file, format!("{prefix}{{\"type\":\"user\",\"message\":{{\"content\":[{{\"type\":\"tool_result\",\"tool_use_id\":\"late\",\"content\":\"done\"}}]}}}}\n")).unwrap();
    let parsed = parse(
        path,
        true,
        SourceType::Windows,
        Resume::From(LoadedCheckpoint::new(cp, "row", "hash")),
    )
    .unwrap();
    assert!(parsed.scope.is_none(), "invalid checkpoint must fall back");
    assert_eq!(
        parsed.snapshot,
        parse(path, true, SourceType::Windows, Resume::Disabled)
            .unwrap()
            .snapshot
    );
}

#[test]
fn appended_lines_read_only_the_delta() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("resume");
    let file = dir.path().join("session.jsonl");
    let path = file.to_str().unwrap();
    let (mut prefix, mut append) = session_gen::late_codex_tool();
    prefix.extend_from_slice(&b" \n".repeat(600_000));
    for i in 1..20 {
        append.extend_from_slice(format!("{}\n", json!({"type":"response_item","payload":{"type":"message","role":"assistant","content":format!("append {i}")}})).as_bytes());
    }
    std::fs::write(&file, &prefix).unwrap();
    let first = parse_file_with(
        path,
        ParserOptions::default(),
        Resume::Fresh(ResumePolicy::testing()),
    )
    .unwrap();
    let saved = first
        .checkpoint
        .expect("complete JSONL must produce a checkpoint");
    let loaded = LoadedCheckpoint::new(saved.decode().unwrap(), "row", "hash");
    let consumed = loaded.checkpoint.consumed;
    let append_bytes = append.len() as u64;
    std::fs::write(&file, [prefix, append].concat()).unwrap();
    let reads = ReadCounterScope::enter();
    let resumed = parse_file_with(path, ParserOptions::default(), Resume::From(loaded)).unwrap();
    assert!(resumed.scope.is_some(), "the append must actually resume");
    assert_eq!(
        resumed.success.session.tool_calls[0].output_preview,
        "late answer"
    );
    assert!(
        reads.bytes() <= append_bytes + 144 * 1024,
        "read {} bytes for {append_bytes} appended",
        reads.bytes()
    );
    println!(
        "Codex appended 20 lines: consumed={consumed} appended_bytes={append_bytes} file_read_bytes={} bound={}",
        reads.bytes(),
        append_bytes + 144 * 1024
    );
}

#[derive(Debug)]
struct Parsed {
    outcome: ResumeOutcome,
    snapshot: SessionSnapshot,
    parser_fields: Value,
    scope: Option<DeltaScope>,
    checkpoint: Option<CheckpointRecord>,
}

fn parse(
    path: &str,
    claude: bool,
    environment: SourceType,
    resume: Resume,
) -> Result<Parsed, ParseError> {
    let mapper = PathMapper::new(r"\\wsl.localhost\fixture");
    if claude {
        let parsed = parse_transcript_with(path, &ClaudeOptions::default(), resume)?;
        let parser_fields = json!({"size":parsed.success.size,"modified":parsed.success.modified_utc,"needs_reread":parsed.success.needs_reread});
        Ok(Parsed {
            snapshot: codex_sessions_collector::claude::snapshot(
                path,
                environment,
                &mapper,
                parsed.success,
            ),
            parser_fields,
            outcome: parsed.outcome,
            scope: parsed.scope,
            checkpoint: parsed.checkpoint,
        })
    } else {
        let parsed = parse_file_with(path, ParserOptions::default(), resume)?;
        let mut fields = serde_json::to_value(&parsed.success.session).unwrap();
        for key in ["messages", "tool_calls", "usage_events", "warnings"] {
            fields.as_object_mut().unwrap().remove(key);
        }
        let mapped = match environment {
            SourceType::Windows => mapper.map_windows_path(path),
            SourceType::Wsl => mapper.map_wsl_unc_path(path),
            _ => unreachable!(),
        };
        let success = parsed.success;
        let snapshot = codex_snapshot(
            &success.session,
            &CodexSource {
                path,
                mapped: &mapped,
                state: "active",
                status: if success.changed_during_parse {
                    "changed_pending_parse"
                } else {
                    "available"
                },
                size: success.snapshot_size,
                modified_utc: success.snapshot_modified_utc,
            },
            success.session.thread_name.clone(),
            Vec::new(),
        );
        Ok(Parsed {
            snapshot,
            parser_fields: fields,
            outcome: parsed.outcome,
            scope: parsed.scope,
            checkpoint: parsed.checkpoint,
        })
    }
}

fn fresh_equals_disabled(
    full: &Result<Parsed, ParseError>,
    fresh: &Result<Parsed, ParseError>,
    context: &str,
) {
    match (full, fresh) {
        (Ok(full), Ok(fresh)) => {
            assert_eq!(fresh.snapshot, full.snapshot, "fresh rows: {context}");
            assert_eq!(
                fresh.parser_fields, full.parser_fields,
                "fresh fields: {context}"
            );
            assert_eq!(fresh.outcome, ResumeOutcome::NotAttempted);
        }
        (Err(full), Err(fresh)) => assert_eq!(fresh, full, "fresh errors: {context}"),
        _ => panic!("Fresh/Disabled success mismatch: {context}: {full:?} / {fresh:?}"),
    }
}
fn healthy_outcome(parsed: &Parsed) {
    assert!(
        matches!(
            parsed.outcome,
            ResumeOutcome::Resumed | ResumeOutcome::Abandoned(AbandonReason::Finality)
        ),
        "healthy continuation: {:?}",
        parsed.outcome
    );
}

#[derive(Default)]
struct Model {
    messages: BTreeMap<i64, MessageRecord>,
    tools: BTreeMap<i64, ToolCallRecord>,
    usage: BTreeMap<i64, UsageEventRecord>,
}
impl Model {
    fn apply(&mut self, parsed: &Parsed) -> SessionSnapshot {
        match &parsed.scope {
            Some(scope) => {
                self.messages.retain(|index, _| *index < scope.message_from);
                self.tools.retain(|index, _| {
                    *index < scope.tool_from && !scope.tool_open.contains(index)
                });
                self.usage
                    .retain(|ordinal, _| *ordinal < scope.usage_from_ordinal);
            }
            None => {
                self.messages.clear();
                self.tools.clear();
                self.usage.clear();
            }
        }
        for row in &parsed.snapshot.messages {
            assert!(
                parsed
                    .scope
                    .as_ref()
                    .is_none_or(|s| row.index >= s.message_from)
            );
            self.messages.insert(row.index, row.clone());
        }
        for row in &parsed.snapshot.tool_calls {
            assert!(parsed.scope.as_ref().is_none_or(
                |s| row.tool_index >= s.tool_from || s.tool_open.contains(&row.tool_index)
            ));
            self.tools.insert(row.tool_index, row.clone());
        }
        for row in &parsed.snapshot.usage_events {
            assert!(
                parsed
                    .scope
                    .as_ref()
                    .is_none_or(|s| row.source_record_ordinal >= s.usage_from_ordinal)
            );
            self.usage.insert(row.source_record_ordinal, row.clone());
        }
        let mut snapshot = parsed.snapshot.clone();
        snapshot.messages = self.messages.values().cloned().collect();
        snapshot.tool_calls = self.tools.values().cloned().collect();
        snapshot.usage_events = self.usage.values().cloned().collect();
        snapshot
    }
}

fn canonical_checkpoint(mut checkpoint: Checkpoint) -> Checkpoint {
    checkpoint.windows = Default::default();
    checkpoint.steps_since_full = 0;
    checkpoint
}

fn corrupt_checkpoint(cp: &mut Checkpoint, operation: usize, rng: &mut session_gen::Rng) {
    let bad = [json!(-1), json!(i64::MAX), json!(u64::MAX)][rng.bounded(3)].clone();
    let state = &mut cp.state;
    match operation {
        0 => state[["message_base", "tool_base", "usage_base"][rng.bounded(3)]] = bad,
        1..=3 => {
            if let Some((key, mut row)) = state["open_tools"]
                .as_object()
                .unwrap()
                .iter()
                .next()
                .map(|(k, v)| (k.clone(), v.clone()))
            {
                if operation == 1 {
                    state["open_tools"].as_object_mut().unwrap().remove(&key);
                    row["tool_index"] = json!(-1);
                    state["open_tools"][usize::MAX.to_string()] = row;
                } else {
                    row[if operation == 2 {
                        "tool_index"
                    } else {
                        "message_index"
                    }] = bad;
                    state["open_tools"][key] = row;
                }
            } else {
                state["tool_base"] = json!(-1);
            }
        }
        4 => {
            let map = if cp.harness == "claude" {
                "pending_tools"
            } else {
                "pending_tool_calls"
            };
            if let Some(key) = state[map].as_object().unwrap().keys().next().cloned() {
                if cp.harness == "claude" {
                    state[map][key] = bad;
                } else {
                    state[map][key]["tool_index"] = bad;
                }
            } else {
                state["tool_base"] = json!(-1);
            }
        }
        5 => state["unresolved"]
            .as_array_mut()
            .unwrap()
            .push(json!("dangling-corrupt-call")),
        6 => {
            let vector = if cp.harness == "claude" {
                "usage_by_message"
            } else {
                "messages"
            };
            if !state[vector].as_array().unwrap().is_empty() {
                state[vector].as_array_mut().unwrap().pop();
            } else {
                state["message_base"] = json!(-1);
            }
        }
        7 => {
            state["unresolved"].as_array_mut().unwrap().pop();
        }
        8 => {
            if let Some(key) = state["open_tools"]
                .as_object()
                .unwrap()
                .keys()
                .next()
                .cloned()
            {
                state["open_tools"].as_object_mut().unwrap().remove(&key);
            } else {
                state["tool_base"] = json!(-1);
            }
        }
        9 => {
            if cp.harness == "claude" {
                let key = state["usage_index"]
                    .as_object()
                    .unwrap()
                    .keys()
                    .next()
                    .unwrap()
                    .clone();
                state["usage_index"][key] = bad;
            } else {
                state["source_record_ordinal"] = bad;
            }
        }
        10 => {
            if cp.harness == "claude" {
                let rows = state["usage_by_message"].as_array_mut().unwrap();
                let ordinal = rows[0][1]["source_record_ordinal"].clone();
                rows[0][1]["source_record_ordinal"] = rows[1][1]["source_record_ordinal"].clone();
                rows[1][1]["source_record_ordinal"] = ordinal;
            } else {
                state["turn_ordinal"] = bad;
            }
        }
        11 => cp.consumed = u64::MAX,
        12 => cp.next_line = u64::MAX,
        13 => cp.row_counts.messages = i64::MAX,
        14 => cp.windows.tail.as_mut().unwrap().offset = cp.consumed + 1,
        15 => {
            if cp.harness == "claude" {
                state["usage_by_message"][0][1]["source_record_ordinal"] = bad;
            } else {
                state["counter_epoch"] = bad;
            }
        }
        16 => {
            if cp.harness == "claude" {
                state["usage_by_message"][0][1]["counter_epoch"] = json!(1);
            } else {
                state["messages"][0]["index"] = bad;
            }
        }
        17 => {
            state.as_object_mut().unwrap().remove("messages");
        }
        18 => {
            let map = if cp.harness == "claude" {
                "pending_tools"
            } else {
                "pending_tool_calls"
            };
            let value = state[map]
                .as_object()
                .unwrap()
                .values()
                .next()
                .unwrap()
                .clone();
            state[map]["dangling-map-id"] = value;
        }
        19 => {
            if cp.harness == "claude" {
                let key = state["usage_index"]
                    .as_object()
                    .unwrap()
                    .keys()
                    .next()
                    .unwrap()
                    .clone();
                state["usage_index"][key] = json!(usize::MAX);
            } else {
                let id = state["pending_tool_calls"]
                    .as_object()
                    .unwrap()
                    .keys()
                    .next()
                    .unwrap()
                    .clone();
                state["pending_tool_calls"][id]["message_index"] = bad;
            }
        }
        20 => {
            cp.closed.messages = -1;
            state["closed"]["messages"] = json!(-1);
        }
        21 => {
            if cp.harness == "claude" {
                state["record_types"]["assistant"] = json!(u64::MAX);
            } else {
                state["usage_base"] = json!(cp.next_line + 1);
            }
        }
        22 => cp.row_counts.tools = i64::MAX,
        23 => cp.row_counts.usage = i64::MAX,
        _ => unreachable!(),
    }
}

#[test]
fn generated_checkpoint_corruptions_never_panic_or_change_rows() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("corrupt-property");
    let mut rng = session_gen::Rng::new(0xc215_0001);
    let quota = if session_gen::exhaustive() { 8 } else { 2 };
    let mutations = if session_gen::exhaustive() { 64 } else { 24 };
    let mut selected = [0, 0];
    let mut cases = [0usize; 24];
    let mut fallbacks = 0;
    for input in session_gen::inputs().into_iter().filter(|input| {
        input.name.starts_with("codex-seed") || input.name.starts_with("claude-seed")
    }) {
        let harness = usize::from(input.claude);
        if selected[harness] >= quota {
            continue;
        }
        let file = dir.path().join(if input.claude {
            "claude.jsonl"
        } else {
            "codex.jsonl"
        });
        let path = file.to_str().unwrap();
        for end in input
            .bytes
            .iter()
            .enumerate()
            .filter_map(|(i, b)| (*b == b'\n').then_some(i + 1))
        {
            if selected[harness] >= quota {
                break;
            }
            let prefix = &input.bytes[..end];
            std::fs::write(&file, prefix).unwrap();
            let Ok(before) = parse(
                path,
                input.claude,
                SourceType::Windows,
                Resume::Fresh(ResumePolicy::testing()),
            ) else {
                continue;
            };
            let Some(record) = &before.checkpoint else {
                continue;
            };
            let saved = record.decode().unwrap();
            if saved.state["open_tools"].as_object().unwrap().is_empty()
                || if input.claude {
                    saved.state["usage_by_message"].as_array().unwrap().len() < 2
                } else {
                    saved.state["usage_base"].as_i64().unwrap() == 0
                }
            {
                continue;
            }
            let map = if input.claude {
                "pending_tools"
            } else {
                "pending_tool_calls"
            };
            let id = saved.state[map].as_object().unwrap().keys().next().unwrap();
            let append = if input.claude {
                let key = saved.state["usage_by_message"][0][0].as_str().unwrap();
                format!(
                    "{}\n{}\n",
                    json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":id,"content":"delayed"}]}}),
                    json!({"type":"assistant","message":{"id":key,"content":"next","usage":{"input_tokens":7,"output_tokens":3}}})
                )
            } else {
                format!(
                    "{}\n{}\n",
                    json!({"type":"response_item","payload":{"type":"function_call_output","call_id":id,"output":"delayed"}}),
                    json!({"type":"response_item","payload":{"type":"message","role":"user","content":"next"}})
                )
            };
            std::fs::write(&file, [prefix, append.as_bytes()].concat()).unwrap();
            let reference =
                parse(path, input.claude, SourceType::Windows, Resume::Disabled).unwrap();
            // First prove this exact checkpoint/continuation actually resumes.
            assert!(
                parse(
                    path,
                    input.claude,
                    SourceType::Windows,
                    Resume::From(LoadedCheckpoint::new(saved.clone(), "row", "hash"))
                )
                .unwrap()
                .scope
                .is_some()
            );
            for trial in 0..mutations {
                let operation = if trial < cases.len() {
                    trial
                } else {
                    rng.bounded(cases.len())
                };
                let mut cp = saved.clone();
                corrupt_checkpoint(&mut cp, operation, &mut rng);
                assert_ne!(cp, saved, "mutation must change its input");
                let cp = cp.encode().unwrap().decode().unwrap();
                let context = format!(
                    "seed=0xc2150001 input={} end={end} trial={trial} operation={operation} state={}",
                    input.name, cp.state
                );
                let actual = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    parse(
                        path,
                        input.claude,
                        SourceType::Windows,
                        Resume::From(LoadedCheckpoint::new(cp, "row", "hash")),
                    )
                }));
                let actual = actual
                    .unwrap_or_else(|_| panic!("checkpoint panic: {context}"))
                    .unwrap();
                let mut model = Model::default();
                model.apply(&before);
                assert_eq!(model.apply(&actual), reference.snapshot, "{context}");
                if actual.scope.is_none() {
                    fallbacks += 1;
                }
                cases[operation] += 1;
            }
            selected[harness] += 1;
        }
    }
    assert!(selected.iter().all(|count| *count == quota));
    assert!(cases.iter().all(|count| *count > 0));
    println!(
        "structural corruptions seed=0xc2150001 checkpoints={selected:?} mutations/checkpoint={mutations} classes={} cases={} fallbacks={fallbacks}",
        cases.len(),
        cases.iter().sum::<usize>()
    );
}

#[test]
fn bom_and_crlf_cut_boundaries_match_full_parse() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("bom-crlf");
    let mut comparisons = 0;
    let mut resumes = 0;
    let mut errors = 0;
    for claude in [false, true] {
        let line = if claude {
            json!({"type":"user","message":{"content":"hello 🐢"}})
        } else {
            json!({"type":"response_item","payload":{"type":"message","role":"user","content":"hello 🐢"}})
        };
        for prefix in ["", "\u{feff}", "\u{feff}\r\n"] {
            let bytes = format!("{prefix}{line}\r\n{line}\r\n").into_bytes();
            let file = dir.path().join(if claude {
                "claude.jsonl"
            } else {
                "codex.jsonl"
            });
            let path = file.to_str().unwrap();
            let mut cuts = vec![0, 1, 2, 3, bytes.len()];
            for (i, byte) in bytes.iter().enumerate() {
                if *byte == b'\r' {
                    cuts.extend([i, i + 1, i + 2]);
                }
            }
            cuts.sort_unstable();
            cuts.dedup();
            let mut cp = None;
            let mut model = Model::default();
            for cut in cuts {
                std::fs::write(&file, &bytes[..cut]).unwrap();
                let reference = parse(path, claude, SourceType::Windows, Resume::Disabled);
                let fresh = parse(
                    path,
                    claude,
                    SourceType::Windows,
                    Resume::Fresh(ResumePolicy::testing()),
                );
                fresh_equals_disabled(&reference, &fresh, "BOM/CRLF");
                let attempted = cp.is_some();
                let request = cp
                    .clone()
                    .map_or(Resume::Fresh(ResumePolicy::testing()), |cp| {
                        Resume::From(LoadedCheckpoint::new(cp, "row", "hash"))
                    });
                let actual = parse(path, claude, SourceType::Windows, request);
                match (reference, actual) {
                    (Ok(reference), Ok(actual)) => {
                        if attempted {
                            healthy_outcome(&actual);
                        }
                        resumes += usize::from(actual.scope.is_some());
                        assert_eq!(
                            model.apply(&actual),
                            reference.snapshot,
                            "claude={claude} prefix={prefix:?} cut={cut}"
                        );
                        cp = actual.checkpoint.map(|record| record.decode().unwrap());
                        if let Some(cp) = &cp {
                            assert!(cp.consumed == 0 || bytes[cp.consumed as usize - 1] == b'\n');
                        }
                    }
                    (Err(reference), Err(actual)) => {
                        assert_eq!(actual, reference);
                        errors += 1;
                    }
                    _ => panic!(
                        "BOM/CRLF success mismatch claude={claude} prefix={prefix:?} cut={cut}"
                    ),
                }
                comparisons += 1;
            }
        }
    }
    assert!(resumes > 0 && errors > 0);
    println!("BOM/CRLF comparisons={comparisons} resumes={resumes} matching_errors={errors}");
}

#[test]
fn growth_between_size_snapshot_and_read_converges() {
    use codex_sessions_collector::resume::BeforeReadScope;
    use std::io::Write;
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("grow-during-read");
    for claude in [false, true] {
        for resumed in [false, true] {
            let file = dir.path().join(if claude {
                "claude.jsonl"
            } else {
                "codex.jsonl"
            });
            let path = file.to_str().unwrap();
            let line = |text: &str| {
                if claude {
                    json!({"type":"user","message":{"content":text}})
                } else {
                    json!({"type":"response_item","payload":{"type":"message","role":"user","content":text}})
                }
            };
            let prefix = format!("{}\r\n", line("first"));
            std::fs::write(&file, &prefix).unwrap();
            let cp = fresh_checkpoint(path, claude);
            let mut model = Model::default();
            model.apply(&parse(path, claude, SourceType::Windows, Resume::Disabled).unwrap());
            // The size snapshot ends between CR and LF. A one-shot read hook
            // then completes that line and adds another complete record.
            let visible = format!("{prefix}{}\r", line("second"));
            std::fs::write(&file, &visible).unwrap();
            let expected_result = parse(path, claude, SourceType::Windows, Resume::Disabled);
            let visible_fresh = parse(
                path,
                claude,
                SourceType::Windows,
                Resume::Fresh(ResumePolicy::testing()),
            );
            fresh_equals_disabled(&expected_result, &visible_fresh, "visible growth cut");
            let expected = expected_result.unwrap();
            let append = format!("\n{}\r\n", line("third"));
            let appended = std::rc::Rc::new(std::cell::Cell::new(false));
            let flag = appended.clone();
            let owned_file = file.clone();
            let hook = BeforeReadScope::enter(move || {
                std::fs::OpenOptions::new()
                    .append(true)
                    .open(owned_file)
                    .unwrap()
                    .write_all(append.as_bytes())
                    .unwrap();
                flag.set(true);
            });
            let request = if resumed {
                Resume::From(LoadedCheckpoint::new(cp, "row", "hash"))
            } else {
                Resume::Fresh(ResumePolicy::testing())
            };
            let actual = parse(path, claude, SourceType::Windows, request).unwrap();
            drop(hook);
            assert!(appended.get(), "growth must occur inside source read");
            assert_eq!(actual.scope.is_some(), resumed);
            if resumed {
                healthy_outcome(&actual);
            }
            let observed = model.apply(&actual);
            assert_eq!(observed.messages, expected.snapshot.messages);
            assert_eq!(observed.tool_calls, expected.snapshot.tool_calls);
            assert_eq!(observed.usage_events, expected.snapshot.usage_events);
            let cp = actual.checkpoint.unwrap().decode().unwrap();
            assert_eq!(
                cp.consumed,
                prefix.len() as u64,
                "checkpoint must exclude the CR-only tail and unseen growth"
            );
            assert_eq!(cp.next_line, 1);
            if claude {
                assert_eq!(actual.parser_fields["needs_reread"], json!(true));
            } else {
                assert_eq!(observed.source.size, visible.len() as u64);
            }
            let next = parse(
                path,
                claude,
                SourceType::Windows,
                Resume::From(LoadedCheckpoint::new(cp, "row", "hash")),
            )
            .unwrap();
            healthy_outcome(&next);
            let full = parse(path, claude, SourceType::Windows, Resume::Disabled);
            let fresh = parse(
                path,
                claude,
                SourceType::Windows,
                Resume::Fresh(ResumePolicy::testing()),
            );
            fresh_equals_disabled(&full, &fresh, "completed growth");
            assert!(next.scope.is_some());
            assert_eq!(
                model.apply(&next),
                parse(path, claude, SourceType::Windows, Resume::Disabled)
                    .unwrap()
                    .snapshot
            );
        }
    }
    println!("deterministic growth: both harnesses, fresh and resumed; 4 convergent cases");
}

#[derive(Default, Debug)]
struct Counts {
    inputs: usize,
    chains: usize,
    steps: usize,
    codex_resumes: usize,
    claude_resumes: usize,
    fallbacks: usize,
    errors: usize,
    midline: usize,
    utf8: usize,
    checkpoints: usize,
    max_blob: usize,
}

#[test]
fn seeded_all_fixture_differential() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("differential");
    let mut counts = Counts::default();
    for (input_index, input) in session_gen::inputs().into_iter().enumerate() {
        counts.inputs += 1;
        let folder =
            dir.path()
                .join(input_index.to_string())
                .join(if input.name.contains("subagents") {
                    "subagents"
                } else {
                    "sessions"
                });
        std::fs::create_dir_all(&folder).unwrap();
        let file = folder.join(format!("agent-fixture.{}", input.extension));
        let path = file.to_str().unwrap();
        let chains = session_gen::chains(&input.bytes, input_index as u64 + 1);
        for environment in [SourceType::Windows, SourceType::Wsl] {
            for (chain_index, chain) in chains.iter().enumerate() {
                counts.chains += 1;
                let mut model = Model::default();
                let mut checkpoint: Option<Checkpoint> = None;
                for &cut in chain {
                    counts.steps += 1;
                    if cut > 0 && input.bytes[cut - 1] != b'\n' {
                        counts.midline += 1;
                    }
                    if cut < input.bytes.len() && input.bytes[cut] & 0xc0 == 0x80 {
                        counts.utf8 += 1;
                    }
                    std::fs::write(&file, &input.bytes[..cut]).unwrap();
                    let context = format!(
                        "input={} environment={environment:?} chain={chain_index} cut={cut}",
                        input.name
                    );
                    let loaded = checkpoint.clone();
                    let request = loaded
                        .clone()
                        .map_or(Resume::Fresh(ResumePolicy::testing()), |cp| {
                            Resume::From(LoadedCheckpoint::new(cp, "row", "hash"))
                        });
                    let reference = parse(path, input.claude, environment, Resume::Disabled);
                    let candidate = parse(path, input.claude, environment, request);
                    let fresh_result = parse(
                        path,
                        input.claude,
                        environment,
                        Resume::Fresh(ResumePolicy::testing()),
                    );
                    fresh_equals_disabled(&reference, &fresh_result, &context);
                    if loaded.is_some()
                        && let Ok(parsed) = &candidate
                    {
                        healthy_outcome(parsed);
                    }
                    match (reference, candidate) {
                        (Err(reference), Err(candidate)) => {
                            assert_eq!(reference, candidate, "{context}");
                            counts.errors += 1;
                        }
                        (Ok(reference), Ok(candidate)) => {
                            if candidate.scope.is_some() {
                                if input.claude {
                                    counts.claude_resumes += 1;
                                } else {
                                    counts.codex_resumes += 1;
                                }
                            } else if loaded.is_some() {
                                counts.fallbacks += 1;
                            }
                            assert_eq!(
                                candidate.parser_fields, reference.parser_fields,
                                "parser fields: {context}"
                            );
                            assert_eq!(
                                model.apply(&candidate),
                                reference.snapshot,
                                "rows: {context}"
                            );
                            let mut totals = if candidate.scope.is_some() {
                                loaded.as_ref().unwrap().closed.clone()
                            } else {
                                SessionTotals::default()
                            };
                            for row in &candidate.snapshot.messages {
                                totals.add_message(row);
                            }
                            for row in &candidate.snapshot.tool_calls {
                                totals.add_tool(row);
                            }
                            let expected_totals = SessionTotals::from_rows(
                                &reference.snapshot.messages,
                                &reference.snapshot.tool_calls,
                            );
                            assert_eq!(totals, expected_totals, "totals: {context}");
                            assert_eq!(
                                totals.token_buckets(candidate.snapshot.session.usage),
                                expected_totals.token_buckets(reference.snapshot.session.usage),
                                "token fallback: {context}"
                            );
                            let mut names = if candidate.scope.is_some() {
                                loaded.as_ref().unwrap().tool_names_prefix.clone()
                            } else {
                                String::new()
                            };
                            let prefix_count = if candidate.scope.is_some() {
                                loaded.as_ref().unwrap().tool_prefix_count
                            } else {
                                0
                            };
                            let new_names: Vec<&str> = candidate
                                .snapshot
                                .tool_calls
                                .iter()
                                .filter(|row| row.tool_index >= prefix_count)
                                .map(|row| row.tool_name.as_str())
                                .collect();
                            if !new_names.is_empty() {
                                if prefix_count > 0 {
                                    names.push(' ');
                                }
                                names.push_str(&new_names.join(" "));
                            }
                            assert_eq!(
                                names,
                                reference
                                    .snapshot
                                    .tool_calls
                                    .iter()
                                    .map(|row| row.tool_name.as_str())
                                    .collect::<Vec<_>>()
                                    .join(" "),
                                "tool names: {context}"
                            );
                            let fresh = fresh_result.unwrap();
                            checkpoint = candidate.checkpoint.as_ref().map(|record| {
                                counts.checkpoints += 1;
                                counts.max_blob = counts.max_blob.max(record.state.len());
                                let cp = record.decode().unwrap();
                                assert!(cp.consumed <= cut as u64, "{context}");
                                assert!(
                                    cp.consumed == 0
                                        || input.bytes[cp.consumed as usize - 1] == b'\n',
                                    "partial checkpoint: {context}"
                                );
                                assert_eq!(
                                    canonical_checkpoint(cp.clone()),
                                    canonical_checkpoint(
                                        fresh
                                            .checkpoint
                                            .as_ref()
                                            .expect("fresh checkpoint")
                                            .decode()
                                            .unwrap()
                                    ),
                                    "checkpoint: {context}"
                                );
                                cp
                            });
                            assert_eq!(
                                candidate.checkpoint.is_some(),
                                fresh.checkpoint.is_some(),
                                "checkpoint eligibility: {context}"
                            );
                        }
                        (reference, candidate) => panic!(
                            "success/error mismatch {context}: reference={:?} candidate={:?}",
                            reference.err(),
                            candidate.err()
                        ),
                    }
                }
            }
        }
        println!("differential input={} cumulative={counts:?}", input.name);
    }
    println!(
        "xorshift64* seeds=1..={} fixture roots=3; mode={}; {counts:?}",
        session_gen::seed_count(),
        if session_gen::exhaustive() {
            "exhaustive: all boundaries/UTF8 interiors and 50 random chains/input/environment of length 2..10"
        } else {
            "fast: every fixture, 4 chains/input/environment of at most 5 cuts from bounded boundary/midline/UTF8 candidates"
        }
    );
    assert!(
        counts.codex_resumes > 0
            && counts.claude_resumes > 0
            && counts.errors > 0
            && counts.midline > 0
            && counts.utf8 > 0
            && counts.fallbacks > 0
    );
}

fn fresh_checkpoint(path: &str, claude: bool) -> Checkpoint {
    parse(
        path,
        claude,
        SourceType::Windows,
        Resume::Fresh(ResumePolicy::testing()),
    )
    .unwrap()
    .checkpoint
    .unwrap()
    .decode()
    .unwrap()
}

#[test]
fn unterminated_last_line_is_not_checkpointed() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("partial");
    for claude in [false, true] {
        let file = dir.path().join(if claude {
            "claude.jsonl"
        } else {
            "codex.jsonl"
        });
        let path = file.to_str().unwrap();
        let line = if claude { json!({"type":"user","sessionId":"partial","message":{"content":"🐢 text"}}) }
            else { json!({"type":"response_item","payload":{"type":"message","role":"user","content":"🐢 text"}}) }.to_string();
        let prefix = format!("{line}\n");
        std::fs::write(&file, &prefix).unwrap();
        let cp = fresh_checkpoint(path, claude);
        let mut model = Model::default();
        model.apply(&parse(path, claude, SourceType::Windows, Resume::Disabled).unwrap());
        let complete_tail = format!("{prefix}{line}");
        std::fs::write(&file, &complete_tail).unwrap();
        let parsed = parse(
            path,
            claude,
            SourceType::Windows,
            Resume::From(LoadedCheckpoint::new(cp.clone(), "row", "hash")),
        )
        .unwrap();
        assert!(parsed.scope.is_some());
        assert_eq!(
            parsed.checkpoint.unwrap().consumed_bytes,
            prefix.len() as u64
        );
        let partial = [prefix.as_bytes(), &line.as_bytes()[..line.len() / 2]].concat();
        std::fs::write(&file, partial).unwrap();
        let actual = parse(
            path,
            claude,
            SourceType::Windows,
            Resume::From(LoadedCheckpoint::new(cp.clone(), "row", "hash")),
        );
        let reference = parse(path, claude, SourceType::Windows, Resume::Disabled);
        if claude {
            let actual = actual.unwrap();
            assert_eq!(
                actual.snapshot.extra.as_ref().unwrap()["incomplete_tail"],
                true
            );
            assert_eq!(
                actual.checkpoint.unwrap().consumed_bytes,
                prefix.len() as u64
            );
            assert_eq!(actual.snapshot.session, reference.unwrap().snapshot.session);
        } else {
            assert_eq!(actual.err().unwrap(), reference.err().unwrap());
        }
        std::fs::write(&file, format!("{prefix}{line}\n")).unwrap();
        let actual = parse(
            path,
            claude,
            SourceType::Windows,
            Resume::From(LoadedCheckpoint::new(cp, "row", "hash")),
        )
        .unwrap();
        assert!(actual.scope.is_some());
        assert_eq!(
            model.apply(&actual),
            parse(path, claude, SourceType::Windows, Resume::Disabled)
                .unwrap()
                .snapshot
        );
    }
}

#[test]
fn shrunk_or_rewritten_file_is_parsed_in_full() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("rewrite");
    for claude in [false, true] {
        let file = dir.path().join(if claude {
            "claude.jsonl"
        } else {
            "codex.jsonl"
        });
        let path = file.to_str().unwrap();
        let mut original = b" \n".repeat(150_000);
        original.extend_from_slice(if claude { b"{\"type\":\"user\",\"message\":{\"content\":\"hello\"}}\n" } else { b"{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":\"hello\"}}\n" });
        std::fs::write(&file, &original).unwrap();
        let cp = fresh_checkpoint(path, claude);
        let offsets = [
            cp.windows.head.as_ref().unwrap().offset,
            cp.windows.anchors[0].offset,
            cp.windows.tail.as_ref().unwrap().offset,
        ];
        for offset in offsets {
            let mut rewritten = original.clone();
            let offset = (offset as usize + 1) & !1;
            rewritten[offset] = b'\t';
            rewritten.extend_from_slice(b" \n");
            std::fs::write(&file, rewritten).unwrap();
            let actual = parse(
                path,
                claude,
                SourceType::Windows,
                Resume::From(LoadedCheckpoint::new(cp.clone(), "row", "hash")),
            )
            .unwrap();
            assert!(actual.scope.is_none(), "rewrite at {offset} must fall back");
            assert_eq!(
                actual.snapshot,
                parse(path, claude, SourceType::Windows, Resume::Disabled)
                    .unwrap()
                    .snapshot
            );
            assert_eq!(
                actual
                    .checkpoint
                    .unwrap()
                    .decode()
                    .unwrap()
                    .steps_since_full,
                0
            );
        }
        std::fs::write(&file, b" \n").unwrap();
        let actual = parse(
            path,
            claude,
            SourceType::Windows,
            Resume::From(LoadedCheckpoint::new(cp, "row", "hash")),
        )
        .unwrap();
        assert!(actual.scope.is_none());
        assert_eq!(actual.checkpoint.unwrap().consumed_bytes, 2);
    }
}

#[test]
fn parser_or_format_change_parses_in_full() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("invalid-state");
    for claude in [false, true] {
        let file = dir.path().join(if claude {
            "claude.jsonl"
        } else {
            "codex.jsonl"
        });
        let path = file.to_str().unwrap();
        std::fs::write(&file, b"{}\n").unwrap();
        let saved = fresh_checkpoint(path, claude);
        let mut cases = Vec::new();
        let mut cp = saved.clone();
        cp.parser_version += 1;
        cases.push(cp);
        let mut cp = saved.clone();
        cp.format += 1;
        cases.push(cp);
        let mut cp = saved.clone();
        cp.options.max_message_content_chars += 1;
        cases.push(cp);
        let mut cp = saved.clone();
        cp.options.max_tool_output_preview_chars += 1;
        cases.push(cp);
        let mut cp = saved.clone();
        cp.source_path.push('x');
        cases.push(cp);
        let mut cp = saved.clone();
        cp.steps_since_full = codex_sessions_collector::resume::MAX_STEPS;
        cases.push(cp);
        let mut cp = saved.clone();
        cp.state = Value::Null;
        cases.push(cp);
        let mut cp = saved.clone();
        cp.state.as_object_mut().unwrap().remove("messages");
        cases.push(cp);
        let mut cp = saved.clone();
        cp.state.as_object_mut().unwrap().remove("session_id");
        cases.push(cp);
        let mut cp = saved.clone();
        cp.windows.tail.as_mut().unwrap().length = u64::MAX;
        cases.push(cp);
        for cp in cases {
            let parsed = parse(
                path,
                claude,
                SourceType::Windows,
                Resume::From(LoadedCheckpoint::new(cp, "row", "hash")),
            )
            .unwrap();
            assert!(parsed.scope.is_none());
            assert_eq!(
                parsed.snapshot,
                parse(path, claude, SourceType::Windows, Resume::Disabled)
                    .unwrap()
                    .snapshot
            );
        }
        let mut corrupt = saved.encode().unwrap();
        corrupt.state = b"corrupt".to_vec();
        assert!(corrupt.decode().is_err());
        let mut mismatch = saved.encode().unwrap();
        mismatch.consumed_bytes += 1;
        assert!(mismatch.decode().is_err());
        let mut oversized = saved.encode().unwrap();
        oversized.state = vec![0; codex_sessions_collector::resume::MAX_BLOB_BYTES + 1];
        assert!(oversized.decode().is_err());
    }
}

#[test]
fn policies_exclusions_and_blob_limit() {
    let dir = support::TempDir::new("limits");
    let file = dir.path().join("session.jsonl");
    let path = file.to_str().unwrap();
    std::fs::write(&file, b"{}\n").unwrap();
    let small = parse_file_with(
        path,
        ParserOptions::default(),
        Resume::Fresh(ResumePolicy::default()),
    )
    .unwrap();
    assert!(small.checkpoint.is_none());
    let disabled = parse_file_with(path, ParserOptions::default(), Resume::Disabled).unwrap();
    assert!(disabled.checkpoint.is_none());
    let legacy = dir.path().join("session.json");
    std::fs::write(&legacy, b"{}\n{}\n").unwrap();
    assert!(
        parse_file_with(
            legacy.to_str().unwrap(),
            ParserOptions::default(),
            Resume::Fresh(ResumePolicy::testing())
        )
        .unwrap()
        .checkpoint
        .is_none()
    );
    let compressed = dir.path().join("session.jsonl.zst");
    std::fs::write(
        &compressed,
        zstd::stream::encode_all(b"{}\n".as_slice(), 3).unwrap(),
    )
    .unwrap();
    assert!(
        parse_file_with(
            compressed.to_str().unwrap(),
            ParserOptions::default(),
            Resume::Fresh(ResumePolicy::testing())
        )
        .unwrap()
        .checkpoint
        .is_none()
    );
    let mut rng = session_gen::Rng::new(41);
    let name: String = (0..600_000)
        .map(|_| char::from(b'!' + rng.bounded(90) as u8))
        .collect();
    std::fs::write(&file, format!("{}\n", json!({"type":"response_item","payload":{"type":"function_call","call_id":"open","name":name}}))).unwrap();
    assert!(
        parse_file_with(
            path,
            ParserOptions::default(),
            Resume::Fresh(ResumePolicy::testing())
        )
        .unwrap()
        .checkpoint
        .is_none(),
        "oversized checkpoint must be abandoned"
    );
}

#[test]
fn late_tool_output_updates_the_stored_call() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("late-result");
    for claude in [false, true] {
        let file = dir.path().join(if claude {
            "claude.jsonl"
        } else {
            "codex.jsonl"
        });
        let path = file.to_str().unwrap();
        let (prefix, append) = if claude {
            (format!("{}\n", json!({"type":"assistant","message":{"content":[{"type":"tool_use","id":"late","name":"Read","input":{}}]}})).into_bytes(),
             format!("{}\n", json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"late","content":"late answer"}]}})).into_bytes())
        } else {
            session_gen::late_codex_tool()
        };
        std::fs::write(&file, &prefix).unwrap();
        let cp = fresh_checkpoint(path, claude);
        let before = parse(path, claude, SourceType::Windows, Resume::Disabled).unwrap();
        let mut model = Model::default();
        model.apply(&before);
        std::fs::write(&file, [prefix.clone(), append.clone()].concat()).unwrap();
        let actual = parse(
            path,
            claude,
            SourceType::Windows,
            Resume::From(LoadedCheckpoint::new(cp, "row", "hash")),
        )
        .unwrap();
        assert!(actual.scope.is_some());
        assert_eq!(actual.snapshot.tool_calls[0].output_preview, "late answer");
        assert_eq!(
            model.apply(&actual),
            parse(path, claude, SourceType::Windows, Resume::Disabled)
                .unwrap()
                .snapshot
        );
        let cp = actual.checkpoint.unwrap().decode().unwrap();
        std::fs::write(&file, [prefix, append.clone(), append].concat()).unwrap();
        let duplicate = parse(
            path,
            claude,
            SourceType::Windows,
            Resume::From(LoadedCheckpoint::new(cp, "row", "hash")),
        )
        .unwrap();
        assert!(
            duplicate.scope.is_none(),
            "duplicate resolved result must abandon"
        );
        assert_eq!(
            duplicate.snapshot,
            parse(path, claude, SourceType::Windows, Resume::Disabled)
                .unwrap()
                .snapshot
        );
    }
}

#[test]
fn sampled_windows_rotate_and_remain_bounded() {
    use std::io::Write;
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("window-rotate");
    for claude in [false, true] {
        let file = dir.path().join(if claude {
            "claude.jsonl"
        } else {
            "codex.jsonl"
        });
        let path = file.to_str().unwrap();
        std::fs::write(&file, b" \n".repeat(150_000)).unwrap();
        let mut cp = fresh_checkpoint(path, claude);
        let mut model = Model::default();
        model.apply(&parse(path, claude, SourceType::Windows, Resume::Disabled).unwrap());
        for step in 1..=32 {
            let append = format!(
                "{}\n",
                if claude {
                    json!({"type":"user","message":{"content":format!("step {step} 🐢")}})
                } else {
                    json!({"type":"response_item","payload":{"type":"message","role":"user","content":format!("step {step} 🐢")}})
                }
            );
            std::fs::OpenOptions::new()
                .append(true)
                .open(&file)
                .unwrap()
                .write_all(append.as_bytes())
                .unwrap();
            let reads = ReadCounterScope::enter();
            let actual = parse(
                path,
                claude,
                SourceType::Windows,
                Resume::From(LoadedCheckpoint::new(cp, "row", "hash")),
            )
            .unwrap();
            assert!(actual.scope.is_some());
            assert!(reads.bytes() <= append.len() as u64 + 144 * 1024);
            drop(reads);
            assert_eq!(
                model.apply(&actual),
                parse(path, claude, SourceType::Windows, Resume::Disabled)
                    .unwrap()
                    .snapshot
            );
            cp = actual.checkpoint.unwrap().decode().unwrap();
            assert!(cp.windows.anchors.len() <= 16);
            assert_eq!(cp.steps_since_full, step);
        }
    }
}

#[test]
fn totals_keep_unknowns_and_apply_fallback_only_after_folding() {
    let mut snapshot = support::sample_snapshot("totals");
    snapshot.session.usage.input_tokens = Some(17);
    snapshot.session.usage.output_tokens = Some(23);
    let empty = SessionTotals::default();
    assert_eq!(empty.token_buckets(snapshot.session.usage), (17, 23, 0));
    let mut message = snapshot.messages[0].clone();
    message.author_type = "user".to_owned();
    message.content_plain = "```code".to_owned();
    message.usage.total_tokens = Some(5);
    message.has_error = true;
    let mut totals = empty;
    totals.add_message(&message);
    assert_eq!(totals.messages, 1);
    assert_eq!(totals.user_messages, 1);
    assert!(totals.has_code_blocks && totals.has_error_rows);
    assert_eq!(totals.token_buckets(snapshot.session.usage), (5, 0, 0));
}

#[test]
fn decoded_blob_limit_rejects_compression_bombs() {
    use std::io::Write;
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("decode-limit");
    let file = dir.path().join("session.jsonl");
    std::fs::write(&file, b"{}\n").unwrap();
    let mut record = fresh_checkpoint(file.to_str().unwrap(), false)
        .encode()
        .unwrap();
    let mut encoder = zstd::stream::Encoder::new(Vec::new(), 3).unwrap();
    let chunk = [b' '; 64 * 1024];
    for _ in 0..=codex_sessions_collector::resume::MAX_DECODED_BYTES / chunk.len() {
        encoder.write_all(&chunk).unwrap();
    }
    record.state = encoder.finish().unwrap();
    assert!(record.state.len() < codex_sessions_collector::resume::MAX_BLOB_BYTES);
    assert_eq!(
        record.decode().unwrap_err(),
        "decoded checkpoint exceeds limit"
    );
}

#[test]
fn head_growth_uses_validated_prefix_bytes() {
    let _policy = ResumePolicyScope::enter(ResumePolicy::testing());
    let dir = support::TempDir::new("head-growth");
    for claude in [false, true] {
        let file = dir.path().join(if claude {
            "claude.jsonl"
        } else {
            "codex.jsonl"
        });
        let path = file.to_str().unwrap();
        let mut bytes = b" \n".repeat(12_000);
        std::fs::write(&file, &bytes).unwrap();
        let cp = fresh_checkpoint(path, claude);
        let append = if claude {
            json!({"type":"user","message":{"content":"x".repeat(70_000)}})
        } else {
            json!({"type":"response_item","payload":{"type":"message","role":"user","content":"x".repeat(70_000)}})
        };
        bytes.extend_from_slice(format!("{append}\n").as_bytes());
        std::fs::write(&file, &bytes).unwrap();
        let grown = parse(
            path,
            claude,
            SourceType::Windows,
            Resume::From(LoadedCheckpoint::new(cp, "row", "hash")),
        )
        .unwrap();
        assert!(grown.scope.is_some());
        let cp = grown.checkpoint.unwrap().decode().unwrap();
        let expected = fresh_checkpoint(path, claude);
        assert_eq!(cp.windows.head, expected.windows.head);
        assert_eq!(cp.windows.tail, expected.windows.tail);
        bytes.extend_from_slice(b"{}\n");
        std::fs::write(&file, bytes).unwrap();
        assert!(
            parse(
                path,
                claude,
                SourceType::Windows,
                Resume::From(LoadedCheckpoint::new(cp, "row", "hash"))
            )
            .unwrap()
            .scope
            .is_some()
        );
    }
}
