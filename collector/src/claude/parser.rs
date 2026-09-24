//! Claude Code transcripts (`~/.claude/projects/<project>/<session>.jsonl`,
//! and `<session>/subagents/agent-<id>.jsonl`) as contract snapshots.
//!
//! Claude Code writes one record per content block, so one model response
//! spans several `assistant` records that share `message.id` and repeat its
//! usage. Usage is counted once per `message.id`, from its last record.
//! Anthropic reports `input_tokens` without cache reads and writes; the
//! viewer's buckets include them, so input = input + cache read + cache
//! creation. Record types, content blocks, and usage keys the contract does
//! not model are kept in the snapshot's `extra` evidence.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs::File;
use std::io::Read;
use std::path::Path;

use serde_json::{Map, Value, json};

use crate::codex::parser::{
    DEFAULT_MAX_MESSAGE_CONTENT_CHARS, DEFAULT_MAX_TOOL_OUTPUT_PREVIEW_CHARS, ParseError,
    ParseErrorKind, file_modified_utc,
};
use crate::contract::{
    MessageRecord, SessionRecord, ToolCallRecord, UsageEventRecord, UsageRecord,
};
use crate::dart::{
    DartDateTime, json_decode, json_encode, json_int, sha256_hex, trim, truncate_utf16,
};

pub const CLAUDE_PARSER_VERSION: i64 = 1;
pub const HARNESS: &str = "claude";

#[derive(Clone, Copy, Debug)]
pub struct ClaudeOptions {
    pub max_tool_output_preview_chars: usize,
    pub max_message_content_chars: usize,
}

impl Default for ClaudeOptions {
    fn default() -> Self {
        Self {
            max_tool_output_preview_chars: DEFAULT_MAX_TOOL_OUTPUT_PREVIEW_CHARS,
            max_message_content_chars: DEFAULT_MAX_MESSAGE_CONTENT_CHARS,
        }
    }
}

/// A parsed transcript: the contract parts of a snapshot plus what the
/// scanner needs to finish it.
#[derive(Clone, Debug)]
pub struct ClaudeTranscript {
    pub session: SessionRecord,
    pub messages: Vec<MessageRecord>,
    pub tool_calls: Vec<ToolCallRecord>,
    pub usage_events: Vec<UsageEventRecord>,
    pub extra: Value,
    pub size: u64,
    pub modified_utc: DartDateTime,
    /// The file changed while it was read, or ends in a partial record; read
    /// it again later.
    pub needs_reread: bool,
}

fn string<'v>(map: &'v Map<String, Value>, key: &str) -> Option<&'v str> {
    map.get(key).and_then(Value::as_str)
}

fn object<'v>(map: &'v Map<String, Value>, key: &str) -> Option<&'v Map<String, Value>> {
    map.get(key).and_then(Value::as_object)
}

fn first_line(value: &str) -> String {
    let line = value.split('\n').next().unwrap_or("");
    truncate_utf16(trim(line), 240).0
}

/// `content` of a tool result or message: a string, or text blocks.
fn text_of(content: Option<&Value>) -> String {
    match content {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(blocks)) => blocks
            .iter()
            .filter_map(|block| match block {
                Value::String(text) => Some(text.clone()),
                Value::Object(map) if string(map, "type").is_none_or(|kind| kind == "text") => {
                    string(map, "text").map(str::to_owned)
                }
                _ => None,
            })
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>()
            .join("\n"),
        Some(Value::Null) | None => String::new(),
        Some(other) => json_encode(other),
    }
}

struct Builder<'o> {
    options: &'o ClaudeOptions,
    messages: Vec<MessageRecord>,
    tool_calls: Vec<ToolCallRecord>,
    pending_tools: HashMap<String, usize>,
    usage_by_message: Vec<(String, UsageEventRecord)>,
    usage_index: HashMap<String, usize>,
    models: Vec<String>,
    session_id: Option<String>,
    agent_id: Option<String>,
    is_sidechain: bool,
    cwd: Option<String>,
    title: Option<String>,
    summary: Option<String>,
    started: Option<DartDateTime>,
    last_message: Option<DartDateTime>,
    record_types: BTreeMap<String, u64>,
    unmodeled_blocks: BTreeMap<String, u64>,
    usage_fields: BTreeSet<String>,
    service_tiers: BTreeSet<String>,
    versions: BTreeSet<String>,
    git_branches: BTreeSet<String>,
}

const MODELED_USAGE_KEYS: [&str; 6] = [
    "input_tokens",
    "output_tokens",
    "cache_read_input_tokens",
    "cache_creation_input_tokens",
    "cache_creation",
    "server_tool_use",
];

impl Builder<'_> {
    fn message(
        &mut self,
        author: &str,
        raw_type: &str,
        at: Option<DartDateTime>,
        content: &str,
        model: Option<String>,
    ) {
        if trim(content).is_empty() {
            return;
        }
        let (content_plain, content_truncated) =
            truncate_utf16(content, self.options.max_message_content_chars);
        self.messages.push(MessageRecord {
            index: self.messages.len() as i64,
            author_type: author.to_owned(),
            raw_type: Some(raw_type.to_owned()),
            created_at_utc: at.map(DartDateTime::to_iso8601),
            first_line: first_line(content),
            content_plain,
            content_preview: truncate_utf16(content, 200).0,
            content_truncated,
            usage: UsageRecord::default(),
            model,
            has_tool_calls: false,
            has_error: false,
        });
        if let Some(at) = at {
            self.last_message = Some(self.last_message.map_or(at, |last| last.max(at)));
        }
    }

    fn add_model(&mut self, model: &str) {
        if !model.is_empty() && model != "<synthetic>" && !self.models.iter().any(|m| m == model) {
            self.models.push(model.to_owned());
        }
    }

    fn record(&mut self, ordinal: i64, record: &Map<String, Value>) {
        let kind = string(record, "type").unwrap_or("unknown").to_owned();
        let at = string(record, "timestamp").and_then(DartDateTime::try_parse);
        if let Some(at) = at {
            self.started = Some(self.started.map_or(at, |first| first.min(at)));
        }
        if self.session_id.is_none()
            && let Some(id) = string(record, "sessionId").or_else(|| string(record, "session_id"))
            && !trim(id).is_empty()
        {
            self.session_id = Some(id.to_owned());
        }
        if self.agent_id.is_none()
            && let Some(agent) = string(record, "agentId")
        {
            self.agent_id = Some(agent.to_owned());
        }
        if record.get("isSidechain") == Some(&Value::Bool(true)) {
            self.is_sidechain = true;
        }
        if let Some(cwd) = string(record, "cwd")
            && !cwd.is_empty()
        {
            self.cwd = Some(cwd.to_owned());
        }
        if let Some(version) = string(record, "version") {
            self.versions.insert(version.to_owned());
        }
        if let Some(branch) = string(record, "gitBranch")
            && !branch.is_empty()
        {
            self.git_branches.insert(branch.to_owned());
        }
        match kind.as_str() {
            "user" => self.user(record, at),
            "assistant" => self.assistant(ordinal, record, at),
            "system" => {
                let content = text_of(record.get("content"));
                let subtype = string(record, "subtype").unwrap_or("message");
                self.message("system", &format!("system:{subtype}"), at, &content, None);
            }
            "ai-title" => {
                if let Some(title) = string(record, "aiTitle")
                    && !trim(title).is_empty()
                {
                    self.title = Some(trim(title).to_owned());
                }
            }
            "summary" => {
                if let Some(summary) = string(record, "summary")
                    && !trim(summary).is_empty()
                {
                    self.summary = Some(trim(summary).to_owned());
                }
            }
            _ => {}
        }
        if !matches!(
            kind.as_str(),
            "user" | "assistant" | "system" | "ai-title" | "summary"
        ) {
            *self.record_types.entry(kind).or_default() += 1;
        }
    }

    fn user(&mut self, record: &Map<String, Value>, at: Option<DartDateTime>) {
        let Some(message) = object(record, "message") else {
            return;
        };
        // Injected context (hook output, caveats, command echoes) is not the
        // person's prompt.
        let author = if record.get("isMeta") == Some(&Value::Bool(true)) {
            "system"
        } else {
            "user"
        };
        match message.get("content") {
            Some(Value::Array(blocks)) => {
                let mut texts = Vec::new();
                for block in blocks {
                    let Some(block) = block.as_object() else {
                        continue;
                    };
                    match string(block, "type") {
                        Some("text") => {
                            if let Some(text) = string(block, "text") {
                                texts.push(text.to_owned());
                            }
                        }
                        Some("tool_result") => self.tool_result(block, at),
                        Some(other) => {
                            *self
                                .unmodeled_blocks
                                .entry(format!("user:{other}"))
                                .or_default() += 1;
                        }
                        None => {}
                    }
                }
                self.message(author, "message", at, &texts.join("\n"), None);
            }
            other => {
                let text = text_of(other);
                self.message(author, "message", at, &text, None);
            }
        }
    }

    fn tool_result(&mut self, block: &Map<String, Value>, at: Option<DartDateTime>) {
        let output = text_of(block.get("content"));
        let (output_preview, output_truncated) =
            truncate_utf16(&output, self.options.max_tool_output_preview_chars);
        let is_error = block.get("is_error") == Some(&Value::Bool(true));
        let position = string(block, "tool_use_id")
            .and_then(|id| self.pending_tools.get(id))
            .copied();
        let tool = match position {
            Some(position) => &mut self.tool_calls[position],
            None => {
                self.tool_calls.push(ToolCallRecord {
                    tool_index: self.tool_calls.len() as i64,
                    tool_name: "unknown".to_owned(),
                    status: "started".to_owned(),
                    started_at_utc: None,
                    finished_at_utc: None,
                    input_preview: String::new(),
                    output_preview: String::new(),
                    output_truncated: false,
                    error_message: None,
                });
                self.tool_calls.last_mut().expect("just pushed")
            }
        };
        tool.status = if is_error { "error" } else { "finished" }.to_owned();
        tool.finished_at_utc = at.map(DartDateTime::to_iso8601);
        tool.output_preview = output_preview;
        tool.output_truncated = output_truncated;
        if is_error {
            tool.error_message = Some(truncate_utf16(&output, 500).0);
        }
    }

    fn assistant(&mut self, ordinal: i64, record: &Map<String, Value>, at: Option<DartDateTime>) {
        let Some(message) = object(record, "message") else {
            return;
        };
        let model = string(message, "model").map(str::to_owned);
        if let Some(model) = &model {
            self.add_model(model);
        }
        let model = model.filter(|model| model != "<synthetic>");
        if let Some(Value::Array(blocks)) = message.get("content") {
            for block in blocks {
                let Some(block) = block.as_object() else {
                    continue;
                };
                match string(block, "type") {
                    Some("text") => {
                        let text = string(block, "text").unwrap_or("").to_owned();
                        self.message("assistant", "text", at, &text, model.clone());
                    }
                    Some("thinking") => {
                        let thinking = string(block, "thinking").unwrap_or("");
                        let text = if trim(thinking).is_empty() {
                            "Reasoning content is unavailable."
                        } else {
                            thinking
                        };
                        self.message("reasoning", "thinking", at, text, None);
                    }
                    Some("redacted_thinking") => self.message(
                        "reasoning",
                        "redacted_thinking",
                        at,
                        "Reasoning content is encrypted and cannot be displayed.",
                        None,
                    ),
                    Some("tool_use") => {
                        let input = block.get("input").map(json_encode).unwrap_or_default();
                        let position = self.tool_calls.len();
                        self.tool_calls.push(ToolCallRecord {
                            tool_index: position as i64,
                            tool_name: string(block, "name").unwrap_or("unknown").to_owned(),
                            status: "started".to_owned(),
                            started_at_utc: at.map(DartDateTime::to_iso8601),
                            finished_at_utc: None,
                            input_preview: truncate_utf16(&input, 200).0,
                            output_preview: String::new(),
                            output_truncated: false,
                            error_message: None,
                        });
                        if let Some(id) = string(block, "id") {
                            self.pending_tools.insert(id.to_owned(), position);
                        }
                    }
                    Some(other) => {
                        *self
                            .unmodeled_blocks
                            .entry(format!("assistant:{other}"))
                            .or_default() += 1;
                    }
                    None => {}
                }
            }
        } else if let Some(Value::String(text)) = message.get("content") {
            let text = text.clone();
            self.message("assistant", "text", at, &text, model.clone());
        }
        if let Some(usage) = object(message, "usage") {
            self.usage(ordinal, record, message, usage, at, model);
        }
    }

    fn usage(
        &mut self,
        ordinal: i64,
        record: &Map<String, Value>,
        message: &Map<String, Value>,
        usage: &Map<String, Value>,
        at: Option<DartDateTime>,
        model: Option<String>,
    ) {
        for key in usage.keys() {
            if !MODELED_USAGE_KEYS.contains(&key.as_str()) {
                self.usage_fields.insert(key.clone());
            }
        }
        if let Some(tier) = string(usage, "service_tier") {
            self.service_tiers.insert(tier.to_owned());
        }
        let int = |key: &str| usage.get(key).and_then(json_int);
        let (input, cache_read, cache_write, output) = (
            int("input_tokens"),
            int("cache_read_input_tokens"),
            int("cache_creation_input_tokens"),
            int("output_tokens"),
        );
        let prompt = match (input, cache_read, cache_write) {
            (None, None, None) => None,
            _ => Some(input.unwrap_or(0) + cache_read.unwrap_or(0) + cache_write.unwrap_or(0)),
        };
        let reasoning = object(usage, "output_tokens_details")
            .and_then(|details| details.get("thinking_tokens").and_then(json_int));
        let mut units = Map::new();
        if let Some(creation) = object(usage, "cache_creation") {
            for (key, name) in [
                ("ephemeral_5m_input_tokens", "cache_write_5m_input_tokens"),
                ("ephemeral_1h_input_tokens", "cache_write_1h_input_tokens"),
            ] {
                if let Some(value) = creation.get(key).and_then(json_int).filter(|v| *v > 0) {
                    units.insert(name.to_owned(), json!(value));
                }
            }
        }
        if let Some(server) = object(usage, "server_tool_use") {
            for (key, value) in server {
                if let Some(value) = json_int(value).filter(|v| *v > 0) {
                    units.insert(key.clone(), json!(value));
                }
            }
        }
        let key = string(message, "id")
            .or_else(|| string(record, "requestId"))
            .map_or_else(|| format!("record:{ordinal}"), str::to_owned);
        let event = UsageEventRecord {
            source_record_ordinal: ordinal,
            rollout_ordinal: None,
            turn_ordinal: None,
            counter_epoch: 0,
            occurred_at_utc: at.map(DartDateTime::to_iso8601),
            model,
            provider: Some("anthropic".to_owned()),
            working_directory: self.cwd.clone(),
            working_directory_unc: None,
            usage: UsageRecord {
                input_tokens: prompt,
                cached_input_tokens: cache_read,
                cache_write_input_tokens: cache_write,
                output_tokens: output,
                reasoning_output_tokens: reasoning,
                total_tokens: match (prompt, output) {
                    (None, None) => None,
                    _ => Some(prompt.unwrap_or(0) + output.unwrap_or(0)),
                },
            },
            request_input_tokens: prompt,
            model_context_window: None,
            billable_units: (!units.is_empty()).then_some(units),
            derivation: "last_token_usage".to_owned(),
            branch_scope: "local".to_owned(),
            event_fingerprint: sha256_hex(format!("claude:{key}").as_bytes()),
        };
        match self.usage_index.get(&key) {
            // Later records of one response repeat or complete its usage;
            // keep the first record's position and time.
            Some(position) => {
                let existing = &mut self.usage_by_message[*position].1;
                existing.usage = event.usage;
                existing.request_input_tokens = event.request_input_tokens;
                existing.billable_units = event.billable_units;
                if existing.model.is_none() {
                    existing.model = event.model;
                }
            }
            None => {
                self.usage_index
                    .insert(key.clone(), self.usage_by_message.len());
                self.usage_by_message.push((key, event));
            }
        }
    }
}

fn add(left: Option<i64>, right: Option<i64>) -> Option<i64> {
    match (left, right) {
        (None, None) => None,
        _ => Some(left.unwrap_or(0) + right.unwrap_or(0)),
    }
}

/// Parse one transcript. `subagent_of` names the parent session when the
/// file is a subagent transcript.
pub fn parse_transcript(
    path: &str,
    options: &ClaudeOptions,
) -> Result<ClaudeTranscript, ParseError> {
    let io_error = |error: std::io::Error| ParseError {
        source_path: path.to_owned(),
        kind: ParseErrorKind::Io,
        message: error.to_string(),
        line: None,
        column: None,
    };
    let metadata = std::fs::metadata(path).map_err(io_error)?;
    let size = metadata.len();
    let modified_utc = file_modified_utc(&metadata).map_err(io_error)?;
    let mut bytes = Vec::with_capacity(size as usize);
    File::open(path)
        .map_err(io_error)?
        .take(size)
        .read_to_end(&mut bytes)
        .map_err(io_error)?;
    let mut builder = Builder {
        options,
        messages: Vec::new(),
        tool_calls: Vec::new(),
        pending_tools: HashMap::new(),
        usage_by_message: Vec::new(),
        usage_index: HashMap::new(),
        models: Vec::new(),
        session_id: None,
        agent_id: None,
        is_sidechain: false,
        cwd: None,
        title: None,
        summary: None,
        started: None,
        last_message: None,
        record_types: BTreeMap::new(),
        unmodeled_blocks: BTreeMap::new(),
        usage_fields: BTreeSet::new(),
        service_tiers: BTreeSet::new(),
        versions: BTreeSet::new(),
        git_branches: BTreeSet::new(),
    };
    let mut needs_reread = bytes.len() as u64 != size;
    let ends_with_newline = bytes.last() == Some(&b'\n');
    let lines: Vec<&[u8]> = bytes.split(|byte| *byte == b'\n').collect();
    let last_content_line = lines
        .iter()
        .rposition(|line| !line.iter().all(u8::is_ascii_whitespace));
    for (number, line) in lines.iter().enumerate() {
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        let malformed = |message: String| ParseError {
            source_path: path.to_owned(),
            kind: ParseErrorKind::MalformedJson,
            message,
            line: Some(number as u64 + 1),
            column: None,
        };
        let decoded = std::str::from_utf8(line)
            .map_err(|error| error.to_string())
            .and_then(|text| json_decode(text).map_err(|error| error.to_string()));
        let record = match decoded {
            Ok(Value::Object(record)) => record,
            Ok(_) => {
                return Err(malformed(
                    "Transcript record must be a JSON object.".to_owned(),
                ));
            }
            // Claude Code appends while a session runs: a partial last record
            // is expected. Keep what is complete and read the file again later.
            Err(_) if Some(number) == last_content_line && !ends_with_newline => {
                needs_reread = true;
                break;
            }
            Err(error) => return Err(malformed(error)),
        };
        builder.record(number as i64, &record);
    }
    let after = std::fs::metadata(path).map_err(io_error)?;
    if after.len() != size || file_modified_utc(&after).map_err(io_error)? != modified_utc {
        needs_reread = true;
    }

    let file_agent = Path::new(path)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .and_then(|stem| stem.strip_prefix("agent-"))
        .map(str::to_owned);
    let in_subagents_folder = Path::new(path)
        .parent()
        .and_then(|parent| parent.file_name())
        .is_some_and(|name| name == "subagents");
    let agent = builder
        .agent_id
        .clone()
        .or(file_agent)
        .filter(|_| in_subagents_folder || builder.is_sidechain);
    let parent = builder.session_id.clone();
    let session_id = match (&parent, &agent) {
        (Some(parent), Some(agent)) => Some(format!("{parent}:agent-{agent}")),
        (parent, None) => parent.clone(),
        (None, Some(_)) => None,
    };

    let usage_events: Vec<UsageEventRecord> = builder
        .usage_by_message
        .into_iter()
        .map(|(_, event)| event)
        .collect();
    let mut total = UsageRecord::default();
    for event in &usage_events {
        total.input_tokens = add(total.input_tokens, event.usage.input_tokens);
        total.cached_input_tokens = add(total.cached_input_tokens, event.usage.cached_input_tokens);
        total.cache_write_input_tokens = add(
            total.cache_write_input_tokens,
            event.usage.cache_write_input_tokens,
        );
        total.output_tokens = add(total.output_tokens, event.usage.output_tokens);
        total.reasoning_output_tokens = add(
            total.reasoning_output_tokens,
            event.usage.reasoning_output_tokens,
        );
        total.total_tokens = add(total.total_tokens, event.usage.total_tokens);
    }
    let extra = json!({
        "harness_format": "claude-code-transcript",
        "unmodeled_record_types": builder.record_types,
        "unmodeled_content_blocks": builder.unmodeled_blocks,
        "unmodeled_usage_fields": builder.usage_fields,
        "service_tiers": builder.service_tiers,
        "claude_code_versions": builder.versions,
        "git_branches": builder.git_branches,
        "incomplete_tail": needs_reread,
    });
    Ok(ClaudeTranscript {
        session: SessionRecord {
            session_id,
            thread_name: builder.title.clone(),
            thread_source: agent.as_ref().map(|_| "subagent".to_owned()),
            parent_thread_id: agent.as_ref().and(parent),
            // All of a subagent's own usage is local; this keeps the viewer's
            // legacy fork reconciliation (a Codex concept) away from it.
            subagent_history_start_ordinal: agent.as_ref().map(|_| 0),
            usage_projection_status: "complete".to_owned(),
            agent_nickname: agent,
            working_directory_display: builder.cwd.clone(),
            working_directory_platform: builder.cwd,
            title: builder.title,
            summary: builder.summary,
            started_at_utc: builder.started.map(DartDateTime::to_iso8601),
            last_message_at_utc: builder.last_message.map(DartDateTime::to_iso8601),
            models: builder.models,
            usage: total,
            parser_version: CLAUDE_PARSER_VERSION,
            ..SessionRecord::default()
        },
        messages: builder.messages,
        tool_calls: builder.tool_calls,
        usage_events,
        extra,
        size,
        modified_utc,
        needs_reread,
    })
}
