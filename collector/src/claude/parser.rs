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
use std::io::Read;
use std::path::Path;

use crate::resume::{
    AbandonReason, BuildFailed, Checkpoint, CheckpointOptions, CheckpointRecord, DeltaScope,
    RESUME_FORMAT, Resume, ResumeOutcome, RowCounts, SessionTotals, SourceReader, WindowCapture,
    observe_checkpoint,
};
use serde::{Deserialize, Serialize};
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

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Builder {
    message_base: i64,
    tool_base: i64,
    usage_base: i64,
    line_base: u64,
    open_tools: BTreeMap<usize, ToolCallRecord>,
    unresolved: BTreeSet<String>,
    closed_usage_keys: BTreeSet<u64>,
    closed_usage_total: UsageRecord,
    closed: SessionTotals,
    tool_names_prefix: String,
    tool_prefix_count: i64,
    abandon: bool,

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

macro_rules! state_value {
    ($state:expr, $value:expr) => {
        match $value {
            Some(value) => value,
            None => {
                $state.abandon = true;
                return;
            }
        }
    };
}

#[deny(
    clippy::arithmetic_side_effects,
    clippy::indexing_slicing,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss,
    clippy::cast_possible_truncation
)]
impl Builder {
    fn message_count(&self) -> Option<i64> {
        self.message_base
            .checked_add(i64::try_from(self.messages.len()).ok()?)
    }
    fn tool_count(&self) -> Option<usize> {
        usize::try_from(self.tool_base)
            .ok()?
            .checked_add(self.tool_calls.len())
    }
    fn scope(&self) -> Option<DeltaScope> {
        Some(DeltaScope {
            message_from: self.message_base,
            tool_from: self.tool_base,
            tool_open: self
                .open_tools
                .keys()
                .map(|index| i64::try_from(*index).ok())
                .collect::<Option<Vec<_>>>()?,
            usage_from_ordinal: self.usage_by_message.first().map_or_else(
                || i64::try_from(self.line_base).ok(),
                |(_, event)| Some(event.source_record_ordinal),
            )?,
        })
    }
    fn valid_checkpoint(&self, cp: &Checkpoint) -> bool {
        serde_json::to_value(self).ok().as_ref() == Some(&cp.state)
            && self.closed == cp.closed
            && self.tool_names_prefix == cp.tool_names_prefix
            && self.tool_prefix_count == cp.tool_prefix_count
            && self.line_base == cp.next_line
            && self.closed.valid_counts(cp.row_counts)
            && self.message_base >= 0
            && self.tool_base >= 0
            && self.usage_base >= 0
            && self.message_base == cp.row_counts.messages
            && self.tool_base == cp.row_counts.tools
            && i64::try_from(self.usage_by_message.len())
                .ok()
                .and_then(|len| self.usage_base.checked_add(len))
                == Some(cp.row_counts.usage)
            && u64::try_from(cp.row_counts.usage).is_ok_and(|count| count <= self.line_base)
            && usize::try_from(self.usage_base).ok() == Some(self.closed_usage_keys.len())
            && self
                .record_types
                .values()
                .try_fold(0u64, |sum, count| sum.checked_add(*count))
                .is_some_and(|count| count <= self.line_base)
            && self
                .unmodeled_blocks
                .values()
                .all(|count| *count <= cp.consumed)
            && self.closed.messages == self.message_base
            && i64::try_from(self.open_tools.len())
                .ok()
                .and_then(|len| self.closed.tool_calls.checked_add(len))
                == Some(self.tool_base)
            && self.tool_prefix_count == self.tool_base
            && self.message_base < i64::MAX
            && self.tool_base < i64::MAX
            && self.usage_base < i64::MAX - 2
            && self.messages.is_empty()
            && self.tool_calls.is_empty()
            && self.usage_by_message.len() <= 2
            && !self.abandon
            && self.open_tools.iter().all(|(index, tool)| {
                i64::try_from(*index).is_ok_and(|index| {
                    index >= 0 && index < self.tool_base && tool.tool_index == index
                }) && tool
                    .message_index
                    .is_some_and(|index| index >= 0 && index <= self.message_base)
            })
            && self.open_tools.len() == self.unresolved.len()
            && self
                .pending_tools
                .values()
                .copied()
                .collect::<BTreeSet<_>>()
                .len()
                == self.open_tools.len()
            && self.unresolved.iter().all(|id| {
                self.pending_tools
                    .get(id)
                    .is_some_and(|index| self.open_tools.contains_key(index))
            })
            && self
                .pending_tools
                .keys()
                .all(|id| self.unresolved.contains(id))
            && self.usage_index.len() == self.usage_by_message.len()
            && self
                .usage_by_message
                .iter()
                .enumerate()
                .all(|(index, (key, event))| {
                    usize::try_from(self.usage_base)
                        .ok()
                        .and_then(|base| base.checked_add(index))
                        .is_some_and(|position| self.usage_index.get(key) == Some(&position))
                        && event.source_record_ordinal >= 0
                        && u64::try_from(event.source_record_ordinal)
                            .is_ok_and(|ordinal| ordinal < self.line_base)
                        && event.rollout_ordinal.is_none()
                        && event.turn_ordinal.is_none()
                        && event.counter_epoch == 0
                })
            && self
                .usage_by_message
                .iter()
                .zip(self.usage_by_message.iter().skip(1))
                .all(|(a, b)| a.1.source_record_ordinal < b.1.source_record_ordinal)
    }
    fn checkpoint(
        &self,
        path: &str,
        options: CheckpointOptions,
        capture: &WindowCapture,
        steps: u32,
        min_bytes: u64,
    ) -> Result<Option<CheckpointRecord>, BuildFailed> {
        if capture.consumed() < min_bytes {
            return Ok(None);
        }
        let checkpoint = (|| -> Option<Checkpoint> {
            let mut state = self.clone();
            state.message_base = state.message_count()?;
            for message in std::mem::take(&mut state.messages) {
                state.closed.add_message(&message);
            }
            let tool_count = state.tool_count()?;
            for tool in &state.tool_calls {
                if tool.tool_index >= state.tool_prefix_count {
                    if state.tool_prefix_count != 0 {
                        state.tool_names_prefix.push(' ');
                    }
                    state.tool_names_prefix.push_str(&tool.tool_name);
                    state.tool_prefix_count = state.tool_prefix_count.checked_add(1)?;
                }
            }
            let open_indices: BTreeSet<usize> = state
                .unresolved
                .iter()
                .filter_map(|id| state.pending_tools.get(id).copied())
                .collect();
            for tool in std::mem::take(&mut state.tool_calls) {
                state
                    .open_tools
                    .insert(usize::try_from(tool.tool_index).ok()?, tool);
            }
            for (index, row) in std::mem::take(&mut state.open_tools) {
                if open_indices.contains(&index) {
                    state.open_tools.insert(index, row);
                } else {
                    state.closed.add_tool(&row);
                }
            }
            state.tool_base = i64::try_from(tool_count).ok()?;
            state
                .pending_tools
                .retain(|id, _| state.unresolved.contains(id));
            let close = state.usage_by_message.len().saturating_sub(2);
            for (key, event) in state.usage_by_message.drain(..close) {
                state.closed_usage_keys.insert(usage_key_hash(&key));
                add_usage(&mut state.closed_usage_total, event.usage);
                state.usage_index.remove(&key);
            }
            state.usage_base = state.usage_base.checked_add(i64::try_from(close).ok()?)?;
            Some(Checkpoint {
                format: RESUME_FORMAT,
                harness: HARNESS.to_owned(),
                parser_version: CLAUDE_PARSER_VERSION,
                options,
                source_path: path.to_owned(),
                consumed: capture.consumed(),
                next_line: state.line_base,
                row_counts: RowCounts {
                    messages: state.message_count()?,
                    tools: i64::try_from(state.tool_count()?).ok()?,
                    usage: state
                        .usage_base
                        .checked_add(i64::try_from(state.usage_by_message.len()).ok()?)?,
                },
                windows: capture.finish()?,
                steps_since_full: steps,
                closed: state.closed.clone(),
                tool_names_prefix: state.tool_names_prefix.clone(),
                tool_prefix_count: state.tool_prefix_count,
                state: serde_json::to_value(state).ok()?,
            })
        })()
        .ok_or(BuildFailed)?;
        Ok(checkpoint.encode())
    }

    fn new() -> Self {
        Self {
            message_base: 0,
            tool_base: 0,
            usage_base: 0,
            line_base: 0,
            open_tools: BTreeMap::new(),
            unresolved: BTreeSet::new(),
            closed_usage_keys: BTreeSet::new(),
            closed_usage_total: UsageRecord::default(),
            closed: SessionTotals::default(),
            tool_names_prefix: String::new(),
            tool_prefix_count: 0,
            abandon: false,
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
        }
    }

    fn message(
        &mut self,
        options: &ClaudeOptions,
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
            truncate_utf16(content, options.max_message_content_chars);
        let index = state_value!(self, self.message_count());
        self.messages.push(MessageRecord {
            index,
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

    fn record(
        &mut self,
        options: &ClaudeOptions,
        resumed: bool,
        ordinal: i64,
        record: &Map<String, Value>,
        abandon_reason: &mut AbandonReason,
    ) {
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
            "user" => self.user(options, resumed, record, at, abandon_reason),
            "assistant" => self.assistant(options, resumed, ordinal, record, at, abandon_reason),
            "system" => {
                let content = text_of(record.get("content"));
                let subtype = string(record, "subtype").unwrap_or("message");
                self.message(
                    options,
                    "system",
                    &format!("system:{subtype}"),
                    at,
                    &content,
                    None,
                );
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
            let count = self.record_types.entry(kind).or_default();
            *count = state_value!(self, count.checked_add(1));
        }
    }

    fn user(
        &mut self,
        options: &ClaudeOptions,
        resumed: bool,
        record: &Map<String, Value>,
        at: Option<DartDateTime>,
        abandon_reason: &mut AbandonReason,
    ) {
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
                        Some("tool_result") => {
                            self.tool_result(options, resumed, block, at, abandon_reason)
                        }
                        Some(other) => {
                            let count = self
                                .unmodeled_blocks
                                .entry(format!("user:{other}"))
                                .or_default();
                            *count = state_value!(self, count.checked_add(1));
                        }
                        None => {}
                    }
                }
                self.message(options, author, "message", at, &texts.join("\n"), None);
            }
            other => {
                let text = text_of(other);
                self.message(options, author, "message", at, &text, None);
            }
        }
    }

    fn tool_result(
        &mut self,
        options: &ClaudeOptions,
        resumed: bool,
        block: &Map<String, Value>,
        at: Option<DartDateTime>,
        abandon_reason: &mut AbandonReason,
    ) {
        let output = text_of(block.get("content"));
        let (output_preview, output_truncated) =
            truncate_utf16(&output, options.max_tool_output_preview_chars);
        let is_error = block.get("is_error") == Some(&Value::Bool(true));
        let id = string(block, "tool_use_id");
        let position = id.and_then(|id| self.pending_tools.get(id)).copied();
        if resumed && id.is_some() && position.is_none() {
            *abandon_reason = AbandonReason::Finality;
            self.abandon = true;
            return;
        }
        if let Some(id) = id {
            self.unresolved.remove(id);
        }
        let tool = match position {
            Some(position) => {
                let base = state_value!(self, usize::try_from(self.tool_base).ok());
                let tool = if position < base {
                    self.open_tools.get_mut(&position)
                } else {
                    position
                        .checked_sub(base)
                        .and_then(|index| self.tool_calls.get_mut(index))
                };
                let Some(tool) = tool else {
                    self.abandon = true;
                    return;
                };
                tool
            }
            None => {
                let tool_index = state_value!(
                    self,
                    self.tool_count()
                        .and_then(|value| i64::try_from(value).ok())
                );
                let message_index = state_value!(self, self.message_count());
                self.tool_calls.push(ToolCallRecord {
                    tool_index,
                    message_index: Some(message_index),
                    tool_name: "unknown".to_owned(),
                    status: "started".to_owned(),
                    started_at_utc: None,
                    finished_at_utc: None,
                    input_preview: String::new(),
                    output_preview: String::new(),
                    output_truncated: false,
                    error_message: None,
                });
                let Some(tool) = self.tool_calls.last_mut() else {
                    self.abandon = true;
                    return;
                };
                tool
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

    fn assistant(
        &mut self,
        options: &ClaudeOptions,
        resumed: bool,
        ordinal: i64,
        record: &Map<String, Value>,
        at: Option<DartDateTime>,
        abandon_reason: &mut AbandonReason,
    ) {
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
                        self.message(options, "assistant", "text", at, &text, model.clone());
                    }
                    Some("thinking") => {
                        let thinking = string(block, "thinking").unwrap_or("");
                        let text = if trim(thinking).is_empty() {
                            "Reasoning content is unavailable."
                        } else {
                            thinking
                        };
                        self.message(options, "reasoning", "thinking", at, text, None);
                    }
                    Some("redacted_thinking") => self.message(
                        options,
                        "reasoning",
                        "redacted_thinking",
                        at,
                        "Reasoning content is encrypted and cannot be displayed.",
                        None,
                    ),
                    Some("tool_use") => {
                        let input = block.get("input").map(json_encode).unwrap_or_default();
                        let position = state_value!(self, self.tool_count());
                        let tool_index = state_value!(self, i64::try_from(position).ok());
                        let message_index = state_value!(self, self.message_count());
                        self.tool_calls.push(ToolCallRecord {
                            tool_index,
                            // The text blocks before it are already stored.
                            message_index: Some(message_index),
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
                            self.unresolved.insert(id.to_owned());
                            self.pending_tools.insert(id.to_owned(), position);
                        }
                    }
                    Some(other) => {
                        let count = self
                            .unmodeled_blocks
                            .entry(format!("assistant:{other}"))
                            .or_default();
                        *count = state_value!(self, count.checked_add(1));
                    }
                    None => {}
                }
            }
        } else if let Some(Value::String(text)) = message.get("content") {
            let text = text.clone();
            self.message(options, "assistant", "text", at, &text, model.clone());
        }
        if let Some(usage) = object(message, "usage") {
            let key = string(message, "id")
                .or_else(|| string(record, "requestId"))
                .map_or_else(|| format!("record:{ordinal}"), str::to_owned);
            self.usage((resumed, abandon_reason), ordinal, key, usage, at, model);
        }
    }

    fn usage(
        &mut self,
        transition: (bool, &mut AbandonReason),
        ordinal: i64,
        key: String,
        usage: &Map<String, Value>,
        at: Option<DartDateTime>,
        model: Option<String>,
    ) {
        let (resumed, abandon_reason) = transition;
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
            _ => Some(
                input
                    .unwrap_or(0)
                    .wrapping_add(cache_read.unwrap_or(0))
                    .wrapping_add(cache_write.unwrap_or(0)),
            ),
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
        if resumed && self.closed_usage_keys.contains(&usage_key_hash(&key)) {
            *abandon_reason = AbandonReason::Finality;
            self.abandon = true;
            return;
        }
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
                    _ => Some(prompt.unwrap_or(0).wrapping_add(output.unwrap_or(0))),
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
                let Some((_, existing)) = position
                    .checked_sub(state_value!(self, usize::try_from(self.usage_base).ok()))
                    .and_then(|index| self.usage_by_message.get_mut(index))
                else {
                    self.abandon = true;
                    return;
                };
                existing.usage = event.usage;
                existing.request_input_tokens = event.request_input_tokens;
                existing.billable_units = event.billable_units;
                if existing.model.is_none() {
                    existing.model = event.model;
                }
            }
            None => {
                let position = state_value!(
                    self,
                    usize::try_from(self.usage_base)
                        .ok()
                        .and_then(|base| base.checked_add(self.usage_by_message.len()))
                );
                self.usage_index.insert(key.clone(), position);
                self.usage_by_message.push((key, event));
            }
        }
    }
}

#[deny(
    clippy::arithmetic_side_effects,
    clippy::indexing_slicing,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss,
    clippy::cast_possible_truncation
)]
fn add(left: Option<i64>, right: Option<i64>) -> Option<i64> {
    match (left, right) {
        (None, None) => None,
        _ => Some(left.unwrap_or(0).wrapping_add(right.unwrap_or(0))),
    }
}

fn usage_key_hash(key: &str) -> u64 {
    u64::from_str_radix(&sha256_hex(format!("claude:{key}").as_bytes())[..16], 16)
        .expect("SHA-256 is hexadecimal")
}
#[deny(
    clippy::arithmetic_side_effects,
    clippy::indexing_slicing,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss,
    clippy::cast_possible_truncation
)]
fn add_usage(total: &mut UsageRecord, usage: UsageRecord) {
    total.input_tokens = add(total.input_tokens, usage.input_tokens);
    total.cached_input_tokens = add(total.cached_input_tokens, usage.cached_input_tokens);
    total.cache_write_input_tokens = add(
        total.cache_write_input_tokens,
        usage.cache_write_input_tokens,
    );
    total.output_tokens = add(total.output_tokens, usage.output_tokens);
    total.reasoning_output_tokens =
        add(total.reasoning_output_tokens, usage.reasoning_output_tokens);
    total.total_tokens = add(total.total_tokens, usage.total_tokens);
}

/// Parse one transcript. `subagent_of` names the parent session when the
/// file is a subagent transcript.
pub fn parse_transcript(
    path: &str,
    options: &ClaudeOptions,
) -> Result<ClaudeTranscript, ParseError> {
    Ok(parse_transcript_with(path, options, Resume::Disabled)?.success)
}

#[derive(Clone, Debug)]
pub struct ClaudeParse {
    pub success: ClaudeTranscript,
    pub outcome: ResumeOutcome,
    pub scope: Option<DeltaScope>,
    pub checkpoint: Option<CheckpointRecord>,
}
#[deny(
    clippy::arithmetic_side_effects,
    clippy::indexing_slicing,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss,
    clippy::cast_possible_truncation
)]
pub fn parse_transcript_with(
    path: &str,
    options: &ClaudeOptions,
    resume: Resume,
) -> Result<ClaudeParse, ParseError> {
    let policy = resume.policy();
    match parse_transcript_inner(path, options, resume)? {
        Ok(parsed) => Ok(parsed),
        Err(reason) => match parse_transcript_inner(path, options, Resume::Fresh(policy))? {
            Ok(mut parsed) => {
                parsed.outcome = ResumeOutcome::Abandoned(reason);
                Ok(parsed)
            }
            Err(_) => Err(ParseError {
                source_path: path.to_owned(),
                kind: ParseErrorKind::Io,
                message: "Source positions exceed supported bounds.".to_owned(),
                line: None,
                column: None,
            }),
        },
    }
}
#[deny(
    clippy::arithmetic_side_effects,
    clippy::indexing_slicing,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss,
    clippy::cast_possible_truncation
)]
fn parse_transcript_inner(
    path: &str,
    options: &ClaudeOptions,
    resume: Resume,
) -> Result<Result<ClaudeParse, AbandonReason>, ParseError> {
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
    let policy = resume.policy();
    let checkpoint_options = CheckpointOptions {
        max_tool_output_preview_chars: options.max_tool_output_preview_chars,
        max_message_content_chars: options.max_message_content_chars,
    };
    let mut file = SourceReader::open(path).map_err(io_error)?;
    let mut builder = Builder::new();
    let mut capture = WindowCapture::fresh(size);
    let mut scope = None;
    let mut steps = 0;
    if let Resume::From(loaded) = resume {
        let cp = *loaded.checkpoint;
        if !policy.enabled
            || !path.to_lowercase().ends_with(".jsonl")
            || !cp.matches(
                path,
                HARNESS,
                CLAUDE_PARSER_VERSION,
                checkpoint_options,
                size,
            )
        {
            return Ok(Err(AbandonReason::Mismatch));
        }
        builder = match serde_json::from_value(cp.state.clone()) {
            Ok(state) => state,
            Err(_) => return Ok(Err(AbandonReason::Structure)),
        };
        if !builder.valid_checkpoint(&cp) {
            return Ok(Err(AbandonReason::Structure));
        }
        let Some((tail, head)) = cp
            .windows
            .validate(&mut file, cp.consumed)
            .map_err(io_error)?
        else {
            return Ok(Err(AbandonReason::Windows));
        };
        let Some(restored_scope) = builder.scope() else {
            return Ok(Err(AbandonReason::Structure));
        };
        scope = Some(restored_scope);
        let Some(next_step) = cp.steps_since_full.checked_add(1) else {
            return Ok(Err(AbandonReason::Structure));
        };
        steps = next_step;
        let Some(restored) = WindowCapture::resumed(&cp, tail, head) else {
            return Ok(Err(AbandonReason::Structure));
        };
        capture = restored;
    }
    let start = capture.consumed();
    let line_base = builder.line_base;
    let Some(remaining) = size.checked_sub(start) else {
        return Ok(Err(AbandonReason::Structure));
    };
    let Ok(capacity) = usize::try_from(remaining) else {
        return Ok(Err(AbandonReason::Structure));
    };
    let mut bytes = Vec::with_capacity(capacity);
    file.take(remaining)
        .read_to_end(&mut bytes)
        .map_err(io_error)?;
    let can_checkpoint = policy.enabled && path.to_lowercase().ends_with(".jsonl");
    let mut checkpoint = None;
    let mut captured_tail = false;
    let mut needs_reread = u64::try_from(bytes.len()).ok() != Some(remaining);
    let ends_with_newline = bytes.last() == Some(&b'\n');
    let lines: Vec<&[u8]> = bytes.split(|byte| *byte == b'\n').collect();
    let last_content_line = lines
        .iter()
        .rposition(|line| !line.iter().all(u8::is_ascii_whitespace));
    for (number, line) in lines.iter().enumerate() {
        let Some(ordinal) = u64::try_from(number)
            .ok()
            .and_then(|number| line_base.checked_add(number))
        else {
            return Ok(Err(AbandonReason::Structure));
        };
        let Some(next_line) = ordinal.checked_add(1) else {
            return Ok(Err(AbandonReason::Structure));
        };
        let Ok(record_ordinal) = i64::try_from(ordinal) else {
            return Ok(Err(AbandonReason::Structure));
        };
        let complete = number.checked_add(1).is_some_and(|next| next < lines.len());
        if !complete && can_checkpoint {
            checkpoint = match observe_checkpoint(
                builder.checkpoint(path, checkpoint_options, &capture, steps, policy.min_bytes),
                scope.is_some(),
            ) {
                Ok(record) => record,
                Err(reason) => return Ok(Err(reason)),
            };
            captured_tail = true;
        }
        let finish_line = |builder: &mut Builder, capture: &mut WindowCapture| {
            if complete {
                if can_checkpoint {
                    capture.push(line)?;
                    capture.push(b"\n")?;
                }
                builder.line_base = next_line;
            }
            Some(())
        };
        if line.iter().all(u8::is_ascii_whitespace) {
            if finish_line(&mut builder, &mut capture).is_none() {
                return Ok(Err(AbandonReason::Structure));
            }
            continue;
        }
        let malformed = |message: String| ParseError {
            source_path: path.to_owned(),
            kind: ParseErrorKind::MalformedJson,
            message,
            line: Some(next_line),
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
                if can_checkpoint {
                    checkpoint = match observe_checkpoint(
                        builder.checkpoint(
                            path,
                            checkpoint_options,
                            &capture,
                            steps,
                            policy.min_bytes,
                        ),
                        scope.is_some(),
                    ) {
                        Ok(record) => record,
                        Err(reason) => return Ok(Err(reason)),
                    };
                    captured_tail = true;
                }
                break;
            }
            Err(error) => return Err(malformed(error)),
        };
        let mut abandon_reason = AbandonReason::Structure;
        builder.record(
            options,
            scope.is_some(),
            record_ordinal,
            &record,
            &mut abandon_reason,
        );
        if builder.abandon {
            return Ok(Err(abandon_reason));
        }
        if finish_line(&mut builder, &mut capture).is_none() {
            return Ok(Err(AbandonReason::Structure));
        }
    }
    if can_checkpoint && !captured_tail {
        checkpoint = match observe_checkpoint(
            builder.checkpoint(path, checkpoint_options, &capture, steps, policy.min_bytes),
            scope.is_some(),
        ) {
            Ok(record) => record,
            Err(reason) => return Ok(Err(reason)),
        };
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
    let mut total = builder.closed_usage_total;
    for event in &usage_events {
        add_usage(&mut total, event.usage);
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
    Ok(Ok(ClaudeParse {
        outcome: if scope.is_some() {
            ResumeOutcome::Resumed
        } else {
            ResumeOutcome::NotAttempted
        },
        scope,
        checkpoint,
        success: ClaudeTranscript {
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
            tool_calls: builder
                .open_tools
                .into_values()
                .chain(builder.tool_calls)
                .collect(),
            usage_events,
            extra,
            size,
            modified_utc,
            needs_reread,
        },
    }))
}
