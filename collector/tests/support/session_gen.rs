//! Deterministic xorshift64* inputs and chains for the full/resumed oracle.
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

#[derive(Clone)]
pub struct Input {
    pub name: String,
    pub claude: bool,
    pub bytes: Vec<u8>,
    pub extension: String,
}
pub struct Rng(u64);
impl Rng {
    pub fn new(seed: u64) -> Self {
        assert_ne!(seed, 0);
        Self(seed)
    }
    pub fn next(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    pub fn bounded(&mut self, bound: usize) -> usize {
        self.next() as usize % bound
    }
}
pub fn seed_count() -> u64 {
    let count = std::env::var("CXV_INCREMENTAL_SEEDS")
        .map_or(if exhaustive() { 16 } else { 1 }, |v| {
            v.parse().expect("CXV_INCREMENTAL_SEEDS must be an integer")
        });
    assert!((1..=256).contains(&count), "seed bound is 1..=256");
    count
}
pub fn exhaustive() -> bool {
    std::env::var("CXV_INCREMENTAL_EXHAUSTIVE").as_deref() == Ok("1")
}
fn walk(path: &Path, paths: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(path).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            walk(&path, paths);
        } else {
            paths.push(path);
        }
    }
}
pub fn inputs() -> Vec<Input> {
    let samples = Path::new(env!("CARGO_MANIFEST_DIR")).join("../samples");
    let mut paths = Vec::new();
    for root in ["sessions", "collector-parity/sessions", "claude/projects"] {
        walk(&samples.join(root), &mut paths);
    }
    paths.sort();
    let mut inputs: Vec<Input> = paths
        .into_iter()
        .map(|path| Input {
            name: path
                .strip_prefix(&samples)
                .unwrap()
                .to_string_lossy()
                .into_owned(),
            claude: path.starts_with(samples.join("claude")),
            bytes: std::fs::read(&path).unwrap(),
            extension: path.extension().unwrap().to_str().unwrap().to_owned(),
        })
        .collect();
    for seed in 1..=seed_count() {
        for variant in 0..4 {
            inputs.push(Input {
                name: format!("codex-seed-{seed}-meta-{variant}"),
                claude: false,
                bytes: codex(seed, variant),
                extension: "jsonl".to_owned(),
            });
        }
        inputs.push(Input {
            name: format!("claude-seed-{seed}"),
            claude: true,
            bytes: claude(seed),
            extension: "jsonl".to_owned(),
        });
    }
    for claude in [false, true] {
        inputs.push(Input {
            name: format!("extreme-values-{claude}"),
            claude,
            bytes: extreme_values(claude),
            extension: "jsonl".to_owned(),
        });
    }
    inputs
}
fn extreme_values(claude: bool) -> Vec<u8> {
    let values = [
        json!(i64::MAX),
        json!(i64::MAX - 1),
        json!(i64::MIN),
        json!(-1),
        json!(0),
        json!(1i64 << 62),
        json!(u64::MAX),
    ];
    let mut records = Vec::new();
    for (i, value) in values.into_iter().enumerate() {
        if claude {
            records.push(json!({"type":"assistant","message":{"id":format!("extreme-{i}"),"content":format!("extreme-{i}"),"usage":{"input_tokens":value,"cache_read_input_tokens":value,"cache_creation_input_tokens":value,"output_tokens":value,"output_tokens_details":{"thinking_tokens":value}}}}));
        } else {
            records.push(response(json!({"type":"message","role":"assistant","content":format!("extreme-{i}"),"usage":{"input_tokens":value,"output_tokens":1}})));
            records.push(event(json!({"type":"token_count","info":{"total_token_usage":{"input_tokens":value,"output_tokens":1},"last_token_usage":{"input_tokens":value,"output_tokens":1}}})));
        }
    }
    lines(records, 1, false)
}
fn record(kind: &str, payload: Value) -> Value {
    json!({"type":kind,"timestamp":"2026-10-01T12:00:00.123456Z","payload":payload})
}
fn response(payload: Value) -> Value {
    record("response_item", payload)
}
fn event(payload: Value) -> Value {
    record("event_msg", payload)
}
fn lines(records: Vec<Value>, seed: u64, mixed: bool) -> Vec<u8> {
    let mut bytes = Vec::new();
    for (i, value) in records.iter().enumerate() {
        if mixed && i % 7 == 0 {
            bytes.extend_from_slice(b"\0\0");
        }
        bytes.extend_from_slice(value.to_string().as_bytes());
        bytes.extend_from_slice(if mixed && (i as u64 + seed).is_multiple_of(5) {
            b"\r"
        } else if i % 3 == 0 {
            b"\r\n"
        } else {
            b"\n"
        });
        if i % 11 == 0 {
            bytes.extend_from_slice(b" \n");
        }
    }
    bytes
}
pub fn late_codex_tool() -> (Vec<u8>, Vec<u8>) {
    let prefix = lines(
        vec![
            record(
                "session_meta",
                json!({"id":"generated","cwd":"F:/nonexistent-fixture"}),
            ),
            response(
                json!({"type":"function_call","call_id":"late","name":"exec","arguments":"{}"}),
            ),
        ],
        1,
        false,
    );
    let append = lines(
        vec![response(
            json!({"type":"function_call_output","call_id":"late","output":"late answer"}),
        )],
        1,
        false,
    );
    (prefix, append)
}
fn codex(seed: u64, variant: u64) -> Vec<u8> {
    let mut rng = Rng::new(seed);
    let mut meta = json!({"id":format!("generated-{seed}-{variant}"),"cwd":"F:/nonexistent-fixture","model_provider":"openai","title":"initial title","thread_name":"thread"});
    match variant {
        1 => {
            meta["source"] = json!({"subagent":{"thread_spawn":{"parent_thread_id":"parent","agent_nickname":"worker","agent_role":"test","depth":2}}});
            meta["subagent_history_start_ordinal"] = json!(0);
        }
        2 => {
            meta["forked_from_id"] = json!("parent");
            meta["history_base"] =
                json!({"thread_id":"parent","end_ordinal_exclusive":4,"end_byte_offset":100});
        }
        3 => {
            meta["forked_from_id"] = json!("legacy-parent");
        }
        _ => {}
    }
    let mut records = vec![record("session_meta", meta)];
    records.push(record("turn_context", json!({"cwd":"/home/test/alpha","working_directory_unc":"unc-alpha","model":"gpt-6","title":"title","summary":"summary"})));
    records.push(event(
        json!({"type":"user_message","message":"Echo  żółw 🐢"}),
    ));
    records.push(response(
        json!({"type":"message","role":"user","content":"Echo żółw 🐢","usage":{"input_tokens":2}}),
    ));
    records.push(response(
        json!({"type":"reasoning","summary":[{"text":"reasoning 🧠"}]}),
    ));
    records.push(response(
        json!({"type":"function_call","call_id":"late","name":"exec","arguments":"{}"}),
    ));
    records.push(event(json!({"type":"thread_settings_applied","thread_settings":{"cwd":"/home/test/beta","model":"gpt-6.1"}})));
    records.push(event(
        json!({"type":"model_reroute","to_model":"gpt-6-mini"}),
    ));
    let base = 5 + rng.bounded(45) as i64;
    let step = 1 + rng.bounded(9) as i64;
    let totals = [
        (base, 2),
        (base + step, 4),
        (base + step, 4),
        (0, 0),
        (3, 1),
        (3 + step, 3),
        (1, 0),
        (base, 5),
    ];
    let mut previous = (0, 0);
    for (i, (input, output)) in totals.into_iter().enumerate() {
        let last = if i % 2 == 0 {
            (input - previous.0, output - previous.1)
        } else {
            (2, 1)
        };
        records.push(event(json!({"type":"token_count","info":{"total_token_usage":{"input_tokens":input,"output_tokens":output,"cached_input_tokens":0},"last_token_usage":{"input_tokens":last.0,"output_tokens":last.1},"model_context_window":128000}})));
        previous = (input, output);
    }
    records.push(response(json!({"type":"message","role":"assistant","model":"gpt-6","content":"code\n```rust\nfn main() {}\n```","usage":{"output_tokens":3}})));
    records.push(response(json!({"type":"function_call_output","call_id":"late","output":"late answer","status":"finished"})));
    records.push(response(json!({"type":"function_call_output","call_id":"late","output":"duplicate answer","error":"second result"})));
    records.push(response(
        json!({"type":"function_call_output","call_id":"orphan","output":"orphan"}),
    ));
    records.push(response(
        json!({"type":"function_call_output","output":"no id"}),
    ));
    for name in [
        "function_call",
        "custom_tool_call",
        "tool_search_call",
        "web_search_call",
    ] {
        records.push(response(
            json!({"type":name,"call_id":"reissued","name":name,"arguments":"{}","query":"query"}),
        ));
    }
    records.push(response(json!({"type":"custom_tool_call_output","call_id":"reissued","output":"replacement result"})));
    records.push(response(
        json!({"type":"agent_message","content":"between agents"}),
    ));
    records.push(event(json!({"type":"item_completed","item":{"type":"FileChange","status":"completed","changes":{"a.rs":{"move_path":"b.rs"}}}})));
    records.push(event(
        json!({"type":"patch_apply_end","success":true,"changes":{"c.rs":{}}}),
    ));
    records.push(event(
        json!({"type":"thread_goal_updated","goal":{"objective":"ship","status":"active"}}),
    ));
    records.push(event(
        json!({"type":"thread_name_updated","thread_name":"renamed"}),
    ));
    records.push(event(
        json!({"type":"task_complete","error":{"message":"failure"}}),
    ));
    records.push(record("future_record", json!({"type":"future"})));
    records.push(response(
        json!({"type":"unknown_payload","value":rng.next()}),
    ));
    records.push(response(json!({"type":"message","role":"assistant","content":format!("{}🐢", "x".repeat(12001 + rng.bounded(8)))})));
    records.push(record(
        "turn_context",
        json!({"cwd":"/home/test/gamma","model":"gpt-6","summary":"new summary"}),
    ));
    // Both inherited and local ordinals, as well as absent ordinals, reach the state machine.
    for (ordinal, record) in records.iter_mut().enumerate() {
        if ordinal % 3 != 0 {
            record["rollout_ordinal"] = json!(ordinal);
        }
    }
    lines(records, seed, seed.is_multiple_of(2))
}
fn claude(seed: u64) -> Vec<u8> {
    let assistant = |id: Option<&str>, request: Option<&str>, content: Value, tokens: i64| {
        let mut value = json!({"type":"assistant","timestamp":"2026-10-01T12:00:01Z","sessionId":"claude-generated","cwd":"/home/fixture","version":"2","gitBranch":"main","message":{"model":"claude-sonnet-4-6","content":content,"usage":{"input_tokens":tokens,"output_tokens":tokens+1,"cache_read_input_tokens":2,"cache_creation_input_tokens":3,"cache_creation":{"ephemeral_5m_input_tokens":2,"ephemeral_1h_input_tokens":1},"server_tool_use":{"web_search_calls":1},"output_tokens_details":{"thinking_tokens":1},"service_tier":"standard","future_usage":42}}});
        if let Some(id) = id {
            value["message"]["id"] = json!(id);
        }
        if let Some(id) = request {
            value["requestId"] = json!(id);
        }
        value
    };
    let mut records = vec![
        json!({"type":"user","sessionId":"claude-generated","timestamp":"2026-10-01T12:00:00Z","cwd":"/home/fixture","message":{"content":"hello żółw 🐢"}}),
        assistant(
            Some("m0"),
            None,
            json!([{"type":"text","text":"first"},{"type":"tool_use","id":"late","name":"Read","input":{"file_path":"a"}}]),
            4,
        ),
        assistant(
            Some("m0"),
            None,
            json!([{"type":"thinking","thinking":"thought 🧠"},{"type":"redacted_thinking"},{"type":"future"}]),
            6,
        ),
        assistant(None, Some("request-only"), json!("request key"), 2),
        assistant(None, None, json!([{"type":"text","text":"record key"}]), 3),
        json!({"type":"user","isMeta":true,"message":{"content":[{"type":"text","text":"context"},{"type":"future"}]}}),
        json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"late","content":[{"type":"text","text":"late answer"}],"is_error":true}]}}),
        json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"late","content":"duplicate"}]}}),
        json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"orphan","content":"orphan"},{"type":"tool_result","content":"no id"}]}}),
        assistant(
            Some("m0"),
            None,
            json!([{"type":"text","text":"closed key returns"}]),
            8,
        ),
        assistant(
            Some("last"),
            None,
            json!([{"type":"tool_use","id":"again","name":"Write","input":{}}]),
            5,
        ),
        assistant(
            Some("last"),
            None,
            json!([{"type":"tool_use","id":"again","name":"Edit","input":{}}]),
            7,
        ),
        json!({"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"again","content":"new call answer"}]}}),
        json!({"type":"system","subtype":"notification","content":"system"}),
        json!({"type":"ai-title","aiTitle":"Title"}),
        json!({"type":"summary","summary":"Summary"}),
        json!({"type":"future","agentId":format!("agent-{seed}"),"isSidechain":true,"cwd":"/home/second","version":"3","gitBranch":"branch"}),
        assistant(
            Some("large"),
            None,
            json!([{"type":"text","text":format!("{}``` 🐢","x".repeat(12005))}]),
            seed as i64,
        ),
    ];
    if seed.is_multiple_of(2) {
        records.push(
            json!({"type":"assistant","message":{"model":"<synthetic>","content":"synthetic"}}),
        );
    }
    let mut bytes = lines(records, seed, false);
    if seed.is_multiple_of(3) {
        bytes.extend_from_slice(b"{\"type\":\"assistant\",\"message\":");
    }
    if seed.is_multiple_of(5) {
        bytes.extend_from_slice(b"broken\n\n");
    }
    bytes
}
/// Exhaustive line boundaries and midpoints, UTF-8 interiors, plus 50 seeded chains.
pub fn chains(bytes: &[u8], seed: u64) -> Vec<Vec<usize>> {
    let ends: Vec<usize> = bytes
        .iter()
        .enumerate()
        .filter_map(|(i, b)| (*b == b'\n').then_some(i + 1))
        .collect();
    if !exhaustive() {
        // Every fixture still runs. Bound work per fixture, rather than merely
        // reducing seeds while retaining every large-file boundary.
        let mut cuts = vec![0, bytes.len()];
        for end in ends
            .iter()
            .copied()
            .take(3)
            .chain(ends.iter().copied().rev().take(3))
        {
            cuts.extend([end.saturating_sub(1), end]);
        }
        for (index, _) in bytes
            .iter()
            .enumerate()
            .filter(|(_, byte)| **byte & 0xc0 == 0x80)
            .take(2)
        {
            cuts.push(index);
        }
        if let Some(&end) = ends.first() {
            cuts.push(end / 2);
        }
        cuts.sort_unstable();
        cuts.dedup();
        let mut rng = Rng::new(seed);
        let mut chains = vec![vec![0, *ends.first().unwrap_or(&0), bytes.len()]];
        for _ in 0..3 {
            let mut chain = std::collections::BTreeSet::from([0, bytes.len()]);
            while chain.len() < 5.min(cuts.len()) {
                chain.insert(cuts[rng.bounded(cuts.len())]);
            }
            chains.push(chain.into_iter().collect());
        }
        return chains;
    }
    let mut result = vec![ends.iter().copied().chain([bytes.len()]).collect()];
    let mut candidates = vec![0, bytes.len()];
    let mut start = 0;
    for end in ends.iter().copied().chain([bytes.len()]) {
        if end > start {
            for cut in [end - 1, start + (end - start) / 2] {
                result.push(vec![start, cut, end]);
                candidates.push(cut);
            }
            for (relative, byte) in bytes[start..end].iter().enumerate() {
                let position = start + relative;
                if byte & 0xc0 == 0x80 {
                    result.push(vec![start, position, end]);
                    candidates.push(position);
                }
            }
        }
        candidates.push(end);
        start = end;
    }
    candidates.sort_unstable();
    candidates.dedup();
    let mut rng = Rng::new(seed);
    for _ in 0..50 {
        let count = 2 + rng.bounded(9);
        let mut chosen = std::collections::BTreeSet::from([bytes.len()]);
        while chosen.len() < count.min(candidates.len()) {
            chosen.insert(candidates[rng.bounded(candidates.len())]);
        }
        result.push(chosen.into_iter().collect());
    }
    for chain in &mut result {
        chain.sort_unstable();
        chain.dedup();
    }
    result
}
