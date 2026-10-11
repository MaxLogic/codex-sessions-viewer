//! Versioned, language-independent ingestion contract.
//!
//! A collector writes one JSON object per line:
//!
//! ```json
//! {"contract":"codex-sessions-viewer.ingest","version":2,"kind":"session_snapshot","record":{...}}
//! ```
//!
//! Records describe what a source says; they carry no SQL row IDs, costs, or
//! project assignments. Unknown fields are ignored so newer collectors can add
//! optional data; an unsupported `version` or `kind` is rejected. Timestamps
//! are UTC ISO-8601 strings. `null` token buckets mean "not reported", never 0.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::codex::parser::{
    AuthorType, PARSER_VERSION, ParsedMessage, ParsedSession, ParsedToolCall, ParsedUsageEvent,
    Usage,
};
use crate::dart::DartDateTime;
use crate::path_mapping::MappedSessionPath;

pub const CONTRACT_NAME: &str = "codex-sessions-viewer.ingest";
pub const CONTRACT_VERSION: u32 = 2;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Envelope {
    pub contract: String,
    pub version: u32,
    #[serde(flatten)]
    pub record: Record,
}

impl Envelope {
    pub fn new(record: Record) -> Self {
        Self {
            contract: CONTRACT_NAME.to_owned(),
            version: CONTRACT_VERSION,
            record,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", content = "record", rename_all = "snake_case")]
pub enum Record {
    /// The complete current state of one session source. Applying the same
    /// snapshot twice leaves the database unchanged apart from timestamps.
    SessionSnapshot(Box<SessionSnapshot>),
    /// Scan outcome for a source path that produced no snapshot (skipped as
    /// unchanged, missing, unreadable, or unparseable).
    SourceStatus(SourceStatus),
    /// A harness-level display name for a session (Codex `session_index.jsonl`).
    ThreadName(ThreadName),
    /// Project names the collector resolved on the source machine for
    /// sessions already stored (for example through `wsl.exe` and `git`).
    ProjectHints(ProjectHints),
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SessionSnapshot {
    /// `codex`, `claude`, ... Identifies the source format and ID namespace.
    pub harness: String,
    /// The collecting machine. `None` means the database's own machine.
    #[serde(default)]
    pub machine_id: Option<String>,
    pub source: Source,
    pub session: SessionRecord,
    #[serde(default)]
    pub messages: Vec<MessageRecord>,
    #[serde(default)]
    pub tool_calls: Vec<ToolCallRecord>,
    #[serde(default)]
    pub usage_events: Vec<UsageEventRecord>,
    /// Project names resolved on the source machine, by working directory.
    #[serde(default)]
    pub project_hints: Vec<ProjectHint>,
    /// Harness fields the contract does not model yet, kept as evidence.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extra: Option<Value>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Source {
    /// The file as the collector found it; the source identity for rescans.
    pub path: String,
    /// `windows`, `wsl`, `macos`, or `linux`: where the harness ran.
    pub environment: String,
    /// `active`, `codex_archived`, or `missing`.
    pub state: String,
    /// `available`, or `changed_pending_parse` when the file changed while it
    /// was read and must be read again.
    pub status: String,
    /// Source revision: size and modification time of the parsed snapshot.
    pub size: u64,
    pub modified_utc: String,
    pub display_path: String,
    pub mapped_source_file_path: String,
    #[serde(default)]
    pub unc_path: Option<String>,
    pub platform_path: String,
    #[serde(default)]
    pub normalized_path_keys: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct SessionRecord {
    /// The harness's own session ID, unchanged.
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub thread_name: Option<String>,
    #[serde(default)]
    pub thread_source: Option<String>,
    #[serde(default)]
    pub parent_thread_id: Option<String>,
    #[serde(default)]
    pub forked_from_id: Option<String>,
    #[serde(default)]
    pub history_base_thread_id: Option<String>,
    #[serde(default)]
    pub history_base_end_ordinal_exclusive: Option<i64>,
    #[serde(default)]
    pub history_base_end_byte_offset: Option<i64>,
    #[serde(default)]
    pub subagent_history_start_ordinal: Option<i64>,
    pub usage_projection_status: String,
    #[serde(default)]
    pub agent_nickname: Option<String>,
    #[serde(default)]
    pub agent_role: Option<String>,
    #[serde(default)]
    pub subagent_depth: Option<i64>,
    #[serde(default)]
    pub working_directory_display: Option<String>,
    #[serde(default)]
    pub working_directory_platform: Option<String>,
    #[serde(default)]
    pub working_directory_unc: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub summary: Option<String>,
    #[serde(default)]
    pub started_at_utc: Option<String>,
    #[serde(default)]
    pub last_message_at_utc: Option<String>,
    /// Models in first-use order.
    #[serde(default)]
    pub models: Vec<String>,
    #[serde(default)]
    pub usage: UsageRecord,
    pub parser_version: i64,
}

/// Token buckets. `total_tokens` is the reported total, if the source
/// reported one; consumers derive `input + output` only when it is absent.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct UsageRecord {
    #[serde(default)]
    pub input_tokens: Option<i64>,
    #[serde(default)]
    pub cached_input_tokens: Option<i64>,
    #[serde(default)]
    pub cache_write_input_tokens: Option<i64>,
    #[serde(default)]
    pub output_tokens: Option<i64>,
    #[serde(default)]
    pub reasoning_output_tokens: Option<i64>,
    #[serde(default)]
    pub total_tokens: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MessageRecord {
    pub index: i64,
    /// `user`, `assistant`, `system`, `tool`, `reasoning`, or `unknown`.
    pub author_type: String,
    #[serde(default)]
    pub raw_type: Option<String>,
    #[serde(default)]
    pub created_at_utc: Option<String>,
    pub first_line: String,
    pub content_plain: String,
    pub content_preview: String,
    #[serde(default)]
    pub content_truncated: bool,
    #[serde(default)]
    pub usage: UsageRecord,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub has_tool_calls: bool,
    #[serde(default)]
    pub has_error: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ToolCallRecord {
    pub tool_index: i64,
    /// The number of the session's messages that came before the call: the
    /// index of the next message after the message that issued it (the
    /// viewer's historical `message_index`). The writer links the call to
    /// the last stored message before this index (`tool_calls.message_id`).
    /// Absent in records from older producers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_index: Option<i64>,
    pub tool_name: String,
    pub status: String,
    #[serde(default)]
    pub started_at_utc: Option<String>,
    #[serde(default)]
    pub finished_at_utc: Option<String>,
    #[serde(default)]
    pub input_preview: String,
    #[serde(default)]
    pub output_preview: String,
    #[serde(default)]
    pub output_truncated: bool,
    #[serde(default)]
    pub error_message: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct UsageEventRecord {
    /// Position of the reporting record in the source; the event identity.
    pub source_record_ordinal: i64,
    #[serde(default)]
    pub rollout_ordinal: Option<i64>,
    #[serde(default)]
    pub turn_ordinal: Option<i64>,
    #[serde(default)]
    pub counter_epoch: i64,
    #[serde(default)]
    pub occurred_at_utc: Option<String>,
    #[serde(default)]
    pub model: Option<String>,
    #[serde(default)]
    pub provider: Option<String>,
    #[serde(default)]
    pub working_directory: Option<String>,
    #[serde(default)]
    pub working_directory_unc: Option<String>,
    pub usage: UsageRecord,
    /// Prompt size of the single request, when the event is one request.
    #[serde(default)]
    pub request_input_tokens: Option<i64>,
    #[serde(default)]
    pub model_context_window: Option<i64>,
    /// Non-token billable units, such as `{"web_search_calls": 2}`.
    #[serde(default)]
    pub billable_units: Option<serde_json::Map<String, Value>>,
    /// `last_token_usage`, `cumulative_delta`, or `counter_reset`.
    pub derivation: String,
    /// `local`, `inherited`, or `ambiguous`: lineage of the usage.
    pub branch_scope: String,
    /// Stable hash of the timestamp and cumulative counters; used to detect
    /// usage a fork inherited from its parent.
    pub event_fingerprint: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectHint {
    pub working_directory: String,
    pub project_name: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SourceStatus {
    pub harness: String,
    pub path: String,
    /// Explicit in v2. Absent only for a legacy v1 status.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub environment: Option<String>,
    /// `available`, `missing`, `path_unreachable`, `parse_error`,
    /// `permission_denied`, `unsupported_format`, `changed_pending_parse`.
    pub status: String,
    pub state: String,
    #[serde(default)]
    pub message: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ThreadName {
    pub harness: String,
    pub session_id: String,
    pub thread_name: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProjectHints {
    pub harness: String,
    /// The sessions the hints apply to.
    pub sessions: Vec<SessionRef>,
    pub hints: Vec<ProjectHint>,
}

/// Identifies a stored session the way the collector saw it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionRef {
    #[serde(default)]
    pub session_id: Option<String>,
    pub source_path: String,
}

#[derive(Debug)]
pub enum ContractError {
    Json(serde_json::Error),
    Contract(String),
}

impl std::fmt::Display for ContractError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Json(error) => write!(f, "invalid record: {error}"),
            Self::Contract(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for ContractError {}

/// Parse one contract line, rejecting other contracts and versions.
pub fn parse_line(line: &str) -> Result<Envelope, ContractError> {
    let mut value: Value = serde_json::from_str(line).map_err(ContractError::Json)?;
    let contract = value.get("contract").and_then(Value::as_str);
    if contract != Some(CONTRACT_NAME) {
        return Err(ContractError::Contract(format!(
            "unsupported contract {contract:?}; expected {CONTRACT_NAME:?}"
        )));
    }
    let version = value.get("version").and_then(Value::as_u64);
    if !matches!(version, Some(1 | 2)) {
        return Err(ContractError::Contract(format!(
            "unsupported contract version {version:?}; this collector reads version {CONTRACT_VERSION}"
        )));
    }
    if version == Some(1)
        && value.get("kind").and_then(Value::as_str) == Some("source_status")
        && let Some(record) = value.get_mut("record").and_then(Value::as_object_mut)
    {
        // v1 never defined this field. Ignore any JSON value before typed
        // decoding so its tolerance and lack of provenance remain unchanged.
        record.remove("environment");
    }
    let envelope: Envelope = serde_json::from_value(value).map_err(ContractError::Json)?;
    envelope.record.validate(envelope.version)?;
    Ok(envelope)
}

impl Record {
    fn validate(&self, version: u32) -> Result<(), ContractError> {
        let fail = |message: String| Err(ContractError::Contract(message));
        match self {
            Self::SessionSnapshot(snapshot) => {
                validate_harness(&snapshot.harness)?;
                let valid = match version {
                    1 => matches!(snapshot.source.environment.as_str(), "windows" | "wsl"),
                    2 => matches!(
                        snapshot.source.environment.as_str(),
                        "windows" | "wsl" | "macos" | "linux"
                    ),
                    _ => false,
                };
                if !valid {
                    return fail(format!(
                        "unsupported source.environment {:?} in v{version}",
                        snapshot.source.environment
                    ));
                }
                validate_state(&snapshot.source.state)?;
                if !matches!(
                    snapshot.source.status.as_str(),
                    "available" | "changed_pending_parse"
                ) {
                    return fail(format!(
                        "source.status of a snapshot must be available or changed_pending_parse, not {:?}",
                        snapshot.source.status
                    ));
                }
                if DartDateTime::try_parse(&snapshot.source.modified_utc).is_none() {
                    return fail("source.modified_utc is not a timestamp".to_owned());
                }
                for event in &snapshot.usage_events {
                    if !matches!(
                        event.derivation.as_str(),
                        "last_token_usage" | "cumulative_delta" | "counter_reset"
                    ) {
                        return fail(format!("unknown usage derivation {:?}", event.derivation));
                    }
                    if !matches!(
                        event.branch_scope.as_str(),
                        "local" | "inherited" | "ambiguous"
                    ) {
                        return fail(format!("unknown branch scope {:?}", event.branch_scope));
                    }
                    if event.event_fingerprint.len() != 64 {
                        return fail(
                            "usage event fingerprint must be 64 hex characters".to_owned(),
                        );
                    }
                    if event.source_record_ordinal < 0 {
                        return fail("usage event source_record_ordinal must be >= 0".to_owned());
                    }
                }
                let mut ordinals: Vec<i64> = snapshot
                    .usage_events
                    .iter()
                    .map(|event| event.source_record_ordinal)
                    .collect();
                ordinals.sort_unstable();
                if ordinals.windows(2).any(|pair| pair[0] == pair[1]) {
                    return fail("usage events repeat a source_record_ordinal".to_owned());
                }
                Ok(())
            }
            Self::SourceStatus(status) => {
                validate_harness(&status.harness)?;
                if version == 2
                    && !matches!(
                        status.environment.as_deref(),
                        Some("windows" | "wsl" | "macos" | "linux")
                    )
                {
                    return fail(format!(
                        "source_status.environment must be explicit windows, wsl, macos or linux in v2, not {:?}",
                        status.environment
                    ));
                }
                validate_state(&status.state)?;
                if !matches!(
                    status.status.as_str(),
                    "available"
                        | "missing"
                        | "path_unreachable"
                        | "parse_error"
                        | "permission_denied"
                        | "unsupported_format"
                        | "changed_pending_parse"
                ) {
                    return fail(format!("unknown source status {:?}", status.status));
                }
                Ok(())
            }
            Self::ThreadName(name) => validate_harness(&name.harness),
            Self::ProjectHints(hints) => validate_harness(&hints.harness),
        }
    }
}

fn validate_harness(harness: &str) -> Result<(), ContractError> {
    let valid = !harness.is_empty()
        && harness
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-');
    if valid {
        Ok(())
    } else {
        Err(ContractError::Contract(format!(
            "harness must be lowercase letters, digits, or '-', not {harness:?}"
        )))
    }
}

fn validate_state(state: &str) -> Result<(), ContractError> {
    if matches!(state, "active" | "codex_archived" | "missing") {
        Ok(())
    } else {
        Err(ContractError::Contract(format!(
            "unknown source state {state:?}"
        )))
    }
}

// ---------------------------------------------------------------------------
// Conversions between the Codex parser model and the contract.

fn iso(value: Option<DartDateTime>) -> Option<String> {
    value.map(DartDateTime::to_iso8601)
}

pub fn parse_time(value: Option<&str>) -> Option<DartDateTime> {
    value.and_then(DartDateTime::try_parse)
}

impl From<Usage> for UsageRecord {
    fn from(usage: Usage) -> Self {
        Self {
            input_tokens: usage.input_tokens,
            cached_input_tokens: usage.cached_input_tokens,
            cache_write_input_tokens: usage.cache_write_input_tokens,
            output_tokens: usage.output_tokens,
            reasoning_output_tokens: usage.reasoning_output_tokens,
            total_tokens: usage.explicit_total_tokens,
        }
    }
}

impl From<UsageRecord> for Usage {
    fn from(record: UsageRecord) -> Self {
        Self {
            input_tokens: record.input_tokens,
            output_tokens: record.output_tokens,
            cached_input_tokens: record.cached_input_tokens,
            cache_write_input_tokens: record.cache_write_input_tokens,
            reasoning_output_tokens: record.reasoning_output_tokens,
            explicit_total_tokens: record.total_tokens,
        }
    }
}

impl From<&ParsedMessage> for MessageRecord {
    fn from(message: &ParsedMessage) -> Self {
        Self {
            index: message.index,
            author_type: message.author_type.name().to_owned(),
            raw_type: message.raw_type.clone(),
            created_at_utc: iso(message.created_at_utc),
            first_line: message.first_line.clone(),
            content_plain: message.content_plain.clone(),
            content_preview: message.content_preview.clone(),
            content_truncated: message.content_truncated,
            usage: message.usage.into(),
            model: message.model.clone(),
            has_tool_calls: message.has_tool_calls,
            has_error: message.has_error,
        }
    }
}

impl From<&ParsedToolCall> for ToolCallRecord {
    fn from(tool: &ParsedToolCall) -> Self {
        Self {
            tool_index: tool.tool_index,
            message_index: Some(tool.message_index),
            tool_name: tool.tool_name.clone(),
            status: tool.status.clone(),
            started_at_utc: iso(tool.started_at_utc),
            finished_at_utc: iso(tool.finished_at_utc),
            input_preview: tool.input_preview.clone(),
            output_preview: tool.output_preview.clone(),
            output_truncated: tool.output_truncated,
            error_message: tool.error_message.clone(),
        }
    }
}

impl From<&ParsedUsageEvent> for UsageEventRecord {
    fn from(event: &ParsedUsageEvent) -> Self {
        Self {
            source_record_ordinal: event.source_record_ordinal,
            rollout_ordinal: event.rollout_ordinal,
            turn_ordinal: event.turn_ordinal,
            counter_epoch: event.counter_epoch,
            occurred_at_utc: iso(event.occurred_at_utc),
            model: event.model.clone(),
            provider: event.provider.clone(),
            working_directory: event.working_directory.clone(),
            working_directory_unc: event.working_directory_unc.clone(),
            usage: event.usage.into(),
            request_input_tokens: event.request_input_tokens,
            model_context_window: event.model_context_window,
            billable_units: None,
            derivation: event.derivation.clone(),
            branch_scope: event.branch_scope.clone(),
            event_fingerprint: event.event_fingerprint.clone(),
        }
    }
}

/// Where a parsed Codex file came from and which revision was read.
pub struct CodexSource<'a> {
    pub path: &'a str,
    pub mapped: &'a MappedSessionPath,
    pub state: &'a str,
    pub status: &'a str,
    pub size: u64,
    pub modified_utc: DartDateTime,
}

/// Build the snapshot record for one parsed Codex file.
pub fn codex_snapshot(
    parsed: &ParsedSession,
    source: &CodexSource<'_>,
    thread_name: Option<String>,
    project_hints: Vec<ProjectHint>,
) -> SessionSnapshot {
    let CodexSource {
        path: source_path,
        mapped,
        state,
        status,
        size,
        modified_utc,
    } = *source;
    SessionSnapshot {
        harness: "codex".to_owned(),
        machine_id: None,
        source: Source {
            path: source_path.to_owned(),
            environment: mapped.source_type.wire_name().to_owned(),
            state: state.to_owned(),
            status: status.to_owned(),
            size,
            modified_utc: modified_utc.to_iso8601(),
            display_path: mapped.display_path.clone(),
            mapped_source_file_path: mapped.source_file_path.clone(),
            unc_path: mapped.source_file_unc_path.clone(),
            platform_path: mapped.platform_path.clone(),
            normalized_path_keys: mapped.normalized_path_keys.clone(),
        },
        session: SessionRecord {
            session_id: parsed.session_id.clone(),
            thread_name,
            thread_source: parsed.thread_source.clone(),
            parent_thread_id: parsed.parent_thread_id.clone(),
            forked_from_id: parsed.forked_from_id.clone(),
            history_base_thread_id: parsed.history_base_thread_id.clone(),
            history_base_end_ordinal_exclusive: parsed.history_base_end_ordinal_exclusive,
            history_base_end_byte_offset: parsed.history_base_end_byte_offset,
            subagent_history_start_ordinal: parsed.subagent_history_start_ordinal,
            usage_projection_status: parsed.usage_projection_status.clone(),
            agent_nickname: parsed.agent_nickname.clone(),
            agent_role: parsed.agent_role.clone(),
            subagent_depth: parsed.subagent_depth,
            working_directory_display: parsed.working_directory_display.clone(),
            working_directory_platform: parsed.working_directory_platform.clone(),
            working_directory_unc: parsed.working_directory_unc.clone(),
            title: parsed.title.clone(),
            summary: parsed.summary.clone(),
            started_at_utc: iso(parsed.started_at_utc),
            last_message_at_utc: iso(parsed.last_message_at_utc),
            models: parsed.model_ids.clone(),
            usage: parsed.usage.into(),
            parser_version: PARSER_VERSION,
        },
        messages: parsed.messages.iter().map(MessageRecord::from).collect(),
        tool_calls: parsed.tool_calls.iter().map(ToolCallRecord::from).collect(),
        usage_events: parsed
            .usage_events
            .iter()
            .map(UsageEventRecord::from)
            .collect(),
        project_hints,
        extra: parsed.extra.clone(),
    }
}

impl MessageRecord {
    pub fn author(&self) -> AuthorType {
        AuthorType::from_name(&self.author_type)
    }
}
