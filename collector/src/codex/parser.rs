//! The Codex rollout parser, the only one: the viewer reads what it stores.
//! Originally ported from the viewer's retired Dart parser.
//!
//! Behavior is intentionally identical, including quirks, because the viewer
//! and the collector write the same rows. Keep the two in lockstep; the parity
//! fixtures under `samples/collector-parity/` fail when they drift.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::fs::File;
use std::io::{BufRead, BufReader, Read};
use std::path::Path;
use std::time::UNIX_EPOCH;

use crate::resume::{
    AbandonReason, BuildFailed, Checkpoint, CheckpointOptions, CheckpointRecord, DeltaScope,
    RESUME_FORMAT, Resume, ResumeOutcome, RowCounts, SessionTotals, SourceReader, WindowCapture,
    observe_checkpoint,
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::dart::{
    self, DartDateTime, collapse_whitespace, json_decode, json_encode, json_int, sha256_hex, trim,
    truncate_utf16,
};

/// Bump when stored rows change; every Codex session is reparsed on the next
/// scan. 5: protocol events that repeat stored content are no longer messages.
pub const PARSER_VERSION: i64 = 5;
/// Changed file paths kept in a session's source extras; the total is kept
/// alongside when a session changed more.
pub const MAX_FILES_CHANGED: usize = 500;
pub const DEFAULT_MAX_TOOL_OUTPUT_PREVIEW_CHARS: usize = 2000;
pub const DEFAULT_MAX_MESSAGE_CONTENT_CHARS: usize = 12000;
const MAX_LEGACY_JSON_BYTES: u64 = 8 * 1024 * 1024;
const JSON_FORMAT_PROBE_BYTES: u64 = 64 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum AuthorType {
    User,
    Assistant,
    System,
    Tool,
    Reasoning,
    Unknown,
}

impl AuthorType {
    pub fn name(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Assistant => "assistant",
            Self::System => "system",
            Self::Tool => "tool",
            Self::Reasoning => "reasoning",
            Self::Unknown => "unknown",
        }
    }

    pub fn from_name(name: &str) -> Self {
        match name {
            "user" => Self::User,
            "assistant" => Self::Assistant,
            "system" => Self::System,
            "tool" => Self::Tool,
            "reasoning" => Self::Reasoning,
            _ => Self::Unknown,
        }
    }

    fn from_role(value: Option<&str>) -> Self {
        match value {
            Some("user") => Self::User,
            Some("assistant") => Self::Assistant,
            // Codex injects its own context (permissions, mode switches) as
            // developer messages.
            Some("system" | "developer") => Self::System,
            Some("tool" | "tool_call") => Self::Tool,
            _ => Self::Unknown,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SourceType {
    Windows,
    Wsl,
    Macos,
    Linux,
}

impl SourceType {
    pub fn wire_name(self) -> &'static str {
        match self {
            Self::Windows => "windows",
            Self::Wsl => "wsl",
            Self::Macos => "macos",
            Self::Linux => "linux",
        }
    }

    pub fn from_wire(value: &str) -> Option<Self> {
        match value {
            "windows" => Some(Self::Windows),
            "wsl" => Some(Self::Wsl),
            "macos" => Some(Self::Macos),
            "linux" => Some(Self::Linux),
            _ => None,
        }
    }

    pub fn native() -> Self {
        if cfg!(windows) {
            Self::Windows
        } else if cfg!(target_os = "macos") {
            Self::Macos
        } else {
            Self::Linux
        }
    }
}

/// `CodexUsage`: every bucket may be unknown; totals follow the Dart getter.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Usage {
    pub input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub cached_input_tokens: Option<i64>,
    pub cache_write_input_tokens: Option<i64>,
    pub reasoning_output_tokens: Option<i64>,
    pub explicit_total_tokens: Option<i64>,
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
impl Usage {
    pub const EMPTY: Self = Self {
        input_tokens: None,
        output_tokens: None,
        cached_input_tokens: None,
        cache_write_input_tokens: None,
        reasoning_output_tokens: None,
        explicit_total_tokens: None,
    };

    pub const ZERO: Self = Self {
        input_tokens: Some(0),
        output_tokens: Some(0),
        cached_input_tokens: Some(0),
        cache_write_input_tokens: Some(0),
        reasoning_output_tokens: Some(0),
        explicit_total_tokens: Some(0),
    };

    pub fn from_json(value: Option<&Value>) -> Self {
        let Some(Value::Object(map)) = value else {
            return Self::EMPTY;
        };
        let int = |key: &str| map.get(key).and_then(json_int);
        Self {
            input_tokens: int("input_tokens"),
            output_tokens: int("output_tokens"),
            cached_input_tokens: int("cached_input_tokens"),
            cache_write_input_tokens: int("cache_write_input_tokens"),
            reasoning_output_tokens: int("reasoning_output_tokens"),
            explicit_total_tokens: int("total_tokens"),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.input_tokens.is_none()
            && self.output_tokens.is_none()
            && self.cached_input_tokens.is_none()
            && self.cache_write_input_tokens.is_none()
            && self.reasoning_output_tokens.is_none()
            && self.explicit_total_tokens.is_none()
    }

    pub fn total_tokens(&self) -> Option<i64> {
        if self.explicit_total_tokens.is_some() {
            return self.explicit_total_tokens;
        }
        if self.input_tokens.is_none()
            && self.output_tokens.is_none()
            && self.cached_input_tokens.is_none()
            && self.cache_write_input_tokens.is_none()
            && self.reasoning_output_tokens.is_none()
        {
            return None;
        }
        Some(self.component_total())
    }

    fn component_total(&self) -> i64 {
        self.input_tokens
            .unwrap_or(0)
            .wrapping_add(self.output_tokens.unwrap_or(0))
    }

    fn vector(&self) -> [i64; 6] {
        [
            self.input_tokens.unwrap_or(0),
            self.cached_input_tokens.unwrap_or(0),
            self.cache_write_input_tokens.unwrap_or(0),
            self.output_tokens.unwrap_or(0),
            self.reasoning_output_tokens.unwrap_or(0),
            self.component_total(),
        ]
    }

    pub fn vector_values(&self) -> [i64; 6] {
        self.vector()
    }

    fn has_same_vector(&self, other: &Self) -> bool {
        self.vector() == other.vector()
    }

    fn is_componentwise_at_least(&self, other: &Self) -> bool {
        self.vector()
            .iter()
            .zip(other.vector())
            .all(|(current, minimum)| *current >= minimum)
    }

    fn is_non_negative(&self) -> bool {
        self.vector().iter().all(|value| *value >= 0)
    }

    fn has_positive_value(&self) -> bool {
        self.vector().iter().any(|value| *value > 0)
    }

    fn non_negative(&self) -> Self {
        Self {
            input_tokens: Some(self.input_tokens.unwrap_or(0).max(0)),
            cached_input_tokens: Some(self.cached_input_tokens.unwrap_or(0).max(0)),
            cache_write_input_tokens: Some(self.cache_write_input_tokens.unwrap_or(0).max(0)),
            output_tokens: Some(self.output_tokens.unwrap_or(0).max(0)),
            reasoning_output_tokens: Some(self.reasoning_output_tokens.unwrap_or(0).max(0)),
            explicit_total_tokens: Some(self.total_tokens().unwrap_or(0).max(0)),
        }
    }

    fn with_component_total(&self) -> Self {
        Self {
            explicit_total_tokens: Some(self.component_total()),
            ..*self
        }
    }

    fn difference_from(&self, previous: &Self) -> Self {
        let [ci, cc, cw, co, cr, ct] = self.vector();
        let [bi, bc, bw, bo, br, bt] = previous.vector();
        Self {
            input_tokens: Some(ci.wrapping_sub(bi)),
            cached_input_tokens: Some(cc.wrapping_sub(bc)),
            cache_write_input_tokens: Some(cw.wrapping_sub(bw)),
            output_tokens: Some(co.wrapping_sub(bo)),
            reasoning_output_tokens: Some(cr.wrapping_sub(br)),
            explicit_total_tokens: Some(ct.wrapping_sub(bt)),
        }
    }

    fn plus(&self, other: &Self) -> Self {
        Self {
            input_tokens: sum_nullable(self.input_tokens, other.input_tokens),
            output_tokens: sum_nullable(self.output_tokens, other.output_tokens),
            cached_input_tokens: sum_nullable(self.cached_input_tokens, other.cached_input_tokens),
            cache_write_input_tokens: sum_nullable(
                self.cache_write_input_tokens,
                other.cache_write_input_tokens,
            ),
            reasoning_output_tokens: sum_nullable(
                self.reasoning_output_tokens,
                other.reasoning_output_tokens,
            ),
            explicit_total_tokens: sum_nullable(self.total_tokens(), other.total_tokens()),
        }
    }

    fn has_positive_usage(&self) -> bool {
        self.input_tokens.unwrap_or(0) > 0
            || self.cached_input_tokens.unwrap_or(0) > 0
            || self.cache_write_input_tokens.unwrap_or(0) > 0
            || self.output_tokens.unwrap_or(0) > 0
            || self.reasoning_output_tokens.unwrap_or(0) > 0
            || self.total_tokens().unwrap_or(0) > 0
    }
}

fn sum_nullable(left: Option<i64>, right: Option<i64>) -> Option<i64> {
    if left.is_none() && right.is_none() {
        return None;
    }
    Some(left.unwrap_or(0).wrapping_add(right.unwrap_or(0)))
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ParsedMessage {
    pub index: i64,
    pub author_type: AuthorType,
    pub raw_type: Option<String>,
    pub created_at_utc: Option<DartDateTime>,
    pub first_line: String,
    pub content_plain: String,
    pub content_preview: String,
    pub content_truncated: bool,
    pub usage: Usage,
    pub model: Option<String>,
    pub has_tool_calls: bool,
    pub has_error: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ParsedToolCall {
    pub message_index: i64,
    pub tool_index: i64,
    pub tool_name: String,
    pub status: String,
    pub started_at_utc: Option<DartDateTime>,
    pub finished_at_utc: Option<DartDateTime>,
    pub input_preview: String,
    pub output_preview: String,
    pub output_truncated: bool,
    pub error_message: Option<String>,
}

impl ParsedToolCall {
    pub fn has_error(&self) -> bool {
        self.error_message.is_some() || self.status == "error"
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ParsedUsageEvent {
    pub source_record_ordinal: i64,
    pub rollout_ordinal: Option<i64>,
    pub turn_ordinal: Option<i64>,
    pub counter_epoch: i64,
    pub occurred_at_utc: Option<DartDateTime>,
    pub model: Option<String>,
    pub working_directory: Option<String>,
    pub working_directory_unc: Option<String>,
    pub usage: Usage,
    pub derivation: String,
    pub branch_scope: String,
    pub cumulative_usage: Usage,
    pub event_fingerprint: String,
    /// `session_meta.model_provider`; `None` when the rollout does not say.
    pub provider: Option<String>,
    /// Prompt size of the one request this event describes, when known.
    pub request_input_tokens: Option<i64>,
    pub model_context_window: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ParseWarning {
    pub code: String,
    pub record_type: String,
    pub payload_type: Option<String>,
    pub message: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ParsedSession {
    pub internal_id: String,
    pub session_id: Option<String>,
    pub thread_name: Option<String>,
    pub thread_source: Option<String>,
    pub parent_thread_id: Option<String>,
    pub forked_from_id: Option<String>,
    pub history_base_thread_id: Option<String>,
    pub history_base_end_ordinal_exclusive: Option<i64>,
    pub history_base_end_byte_offset: Option<i64>,
    pub subagent_history_start_ordinal: Option<i64>,
    pub usage_events: Vec<ParsedUsageEvent>,
    pub usage_working_directories: Vec<String>,
    pub usage_projection_status: String,
    pub agent_nickname: Option<String>,
    pub agent_role: Option<String>,
    pub subagent_depth: Option<i64>,
    pub source_type: SourceType,
    pub source_path: String,
    pub source_file_unc_path: Option<String>,
    pub display_path: String,
    pub platform_path: String,
    pub working_directory_display: Option<String>,
    pub working_directory_platform: Option<String>,
    pub working_directory_unc: Option<String>,
    pub title: Option<String>,
    pub summary: Option<String>,
    pub started_at_utc: Option<DartDateTime>,
    pub last_message_at_utc: Option<DartDateTime>,
    /// Insertion-ordered set, like Dart's default `Set`.
    pub model_ids: Vec<String>,
    pub messages: Vec<ParsedMessage>,
    pub tool_calls: Vec<ParsedToolCall>,
    pub warnings: Vec<ParseWarning>,
    pub usage: Usage,
    pub last_turn_usage: Usage,
    /// Source evidence kept outside the messages (`files_changed`, `goal`).
    pub extra: Option<Value>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParseErrorKind {
    MalformedJson,
    UnsupportedRoot,
    Io,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParseError {
    pub source_path: String,
    pub kind: ParseErrorKind,
    pub message: String,
    pub line: Option<u64>,
    pub column: Option<u64>,
}

impl ParseError {
    fn new(source_path: &str, kind: ParseErrorKind, message: impl Into<String>) -> Self {
        Self {
            source_path: source_path.to_owned(),
            kind,
            message: message.into(),
            line: None,
            column: None,
        }
    }

    /// `_parseErrorMessage` in the Dart scanner.
    pub fn display_message(&self) -> String {
        match (self.line, self.column) {
            (None, _) => self.message.clone(),
            (Some(line), None) => format!("{} at line {line}.", self.message),
            (Some(line), Some(column)) => {
                format!("{} at line {line}, column {column}.", self.message)
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct ParseSuccess {
    pub session: ParsedSession,
    pub snapshot_size: u64,
    pub snapshot_modified_utc: DartDateTime,
    pub changed_during_parse: bool,
}

#[derive(Clone, Copy, Debug)]
pub struct ParserOptions {
    pub max_tool_output_preview_chars: usize,
    pub max_message_content_chars: usize,
}

impl Default for ParserOptions {
    fn default() -> Self {
        Self {
            max_tool_output_preview_chars: DEFAULT_MAX_TOOL_OUTPUT_PREVIEW_CHARS,
            max_message_content_chars: DEFAULT_MAX_MESSAGE_CONTENT_CHARS,
        }
    }
}

/// `FileStat.modified` on Windows: the Dart VM reports whole seconds.
pub fn file_modified_utc(metadata: &std::fs::Metadata) -> std::io::Result<DartDateTime> {
    let modified = metadata.modified()?;
    let seconds = match modified.duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs() as i64,
        Err(before) => {
            let duration = before.duration();
            let whole = duration.as_secs() as i64;
            if duration.subsec_nanos() > 0 {
                -whole - 1
            } else {
                -whole
            }
        }
    };
    Ok(DartDateTime::from_micros(seconds * 1_000_000))
}

pub fn parse_file(path: &str, options: ParserOptions) -> Result<ParseSuccess, ParseError> {
    let result = parse_file_inner(path, options);
    result.map_err(|error| match error {
        Failure::Parse(error) => error,
        Failure::Io(error) => ParseError::new(path, ParseErrorKind::Io, dart_io_message(&error)),
        Failure::Abandon(_) => unreachable!("full parse cannot abandon"),
    })
}

pub struct CodexParse {
    pub success: ParseSuccess,
    pub outcome: ResumeOutcome,
    pub scope: Option<crate::resume::DeltaScope>,
    pub checkpoint: Option<crate::resume::CheckpointRecord>,
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
pub fn parse_file_with(
    path: &str,
    options: ParserOptions,
    resume: Resume,
) -> Result<CodexParse, ParseError> {
    if !path.to_lowercase().ends_with(".jsonl") {
        return parse_file(path, options).map(|success| CodexParse {
            success,
            outcome: ResumeOutcome::NotAttempted,
            scope: None,
            checkpoint: None,
        });
    }
    let policy = resume.policy();
    let run = |resume| -> Result<CodexParse, Failure> {
        let metadata = std::fs::metadata(path)?;
        Parser { path, options }.parse_jsonl_with(
            metadata.len(),
            file_modified_utc(&metadata)?,
            resume,
        )
    };
    let result = match run(resume) {
        Err(Failure::Abandon(reason)) => run(Resume::Fresh(policy)).map(|mut parsed| {
            parsed.outcome = ResumeOutcome::Abandoned(reason);
            parsed
        }),
        other => other,
    };
    result.map_err(|error| match error {
        Failure::Parse(error) => error,
        Failure::Io(error) => ParseError::new(path, ParseErrorKind::Io, dart_io_message(&error)),
        Failure::Abandon(_) => ParseError::new(
            path,
            ParseErrorKind::MalformedJson,
            "Session arithmetic exceeds supported bounds.",
        ),
    })
}

enum Failure {
    Abandon(AbandonReason),
    Parse(ParseError),
    Io(std::io::Error),
}

impl From<std::io::Error> for Failure {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<ParseError> for Failure {
    fn from(error: ParseError) -> Self {
        Self::Parse(error)
    }
}

fn dart_io_message(error: &std::io::Error) -> String {
    match error.kind() {
        std::io::ErrorKind::PermissionDenied => format!("Permission denied: {error}"),
        _ => error.to_string(),
    }
}

fn parse_file_inner(path: &str, options: ParserOptions) -> Result<ParseSuccess, Failure> {
    let metadata = std::fs::metadata(path)?;
    let size = metadata.len();
    let modified = file_modified_utc(&metadata)?;
    let parser = Parser { path, options };
    if path.to_lowercase().ends_with(".jsonl") || is_compressed_jsonl(path) {
        return parser.parse_jsonl_snapshot(size, modified);
    }
    let probe_end = size.min(JSON_FORMAT_PROBE_BYTES);
    let probe_bytes = read_prefix(path, probe_end)?;
    let probe = if probe_end < size {
        String::from_utf8_lossy(&probe_bytes).into_owned()
    } else {
        String::from_utf8(probe_bytes).map_err(|error| {
            ParseError::new(path, ParseErrorKind::MalformedJson, error.to_string())
        })?
    };
    if looks_like_jsonl(&probe) {
        return parser.parse_jsonl_snapshot(size, modified);
    }
    if size > MAX_LEGACY_JSON_BYTES {
        return Err(ParseError::new(
            path,
            ParseErrorKind::UnsupportedRoot,
            format!(
                "Legacy JSON session exceeds the configured size limit of {MAX_LEGACY_JSON_BYTES} bytes and was not recognized as JSONL."
            ),
        )
        .into());
    }
    let text = if size <= JSON_FORMAT_PROBE_BYTES {
        probe
    } else {
        String::from_utf8(read_prefix(path, size)?).map_err(|error| {
            ParseError::new(path, ParseErrorKind::MalformedJson, error.to_string())
        })?
    };
    let decoded = json_decode(&text).map_err(|error| malformed(path, &error, 0, None))?;
    let Value::Object(map) = decoded else {
        return Err(ParseError::new(
            path,
            ParseErrorKind::UnsupportedRoot,
            "Session root must be a JSON object or JSONL records.",
        )
        .into());
    };
    let session = parser.parse_json_object_session(&map);
    let after = std::fs::metadata(path)?;
    Ok(ParseSuccess {
        session,
        snapshot_size: size,
        snapshot_modified_utc: modified,
        changed_during_parse: after.len() != size || file_modified_utc(&after)? != modified,
    })
}

/// Codex compresses older rollouts in place to `<name>.jsonl.zst` (one zstd
/// stream of the original JSONL). Such a file is read through a decoder.
pub fn is_compressed_jsonl(path: &str) -> bool {
    path.to_lowercase().ends_with(".jsonl.zst")
}

fn read_prefix(path: &str, end: u64) -> Result<Vec<u8>, Failure> {
    let mut bytes = Vec::with_capacity(end as usize);
    File::open(path)?.take(end).read_to_end(&mut bytes)?;
    if bytes.len() as u64 != end {
        return Err(Failure::Io(std::io::Error::other(
            "Session source changed while being parsed.",
        )));
    }
    Ok(bytes)
}

fn malformed(path: &str, error: &serde_json::Error, padding: u64, line: Option<u64>) -> ParseError {
    let message = error.to_string();
    let message = match message.find(" at line ") {
        Some(index) => message[..index].to_owned(),
        None => message,
    };
    ParseError {
        source_path: path.to_owned(),
        kind: ParseErrorKind::MalformedJson,
        message,
        line: Some(line.unwrap_or(error.line() as u64)),
        column: Some(padding + error.column() as u64),
    }
}

fn looks_like_jsonl(text: &str) -> bool {
    let trimmed = dart::trim_left(text);
    let Some(first_line_end) = trimmed.find('\n') else {
        return false;
    };
    let following = dart::trim_left(&trimmed[first_line_end + 1..]);
    if !following.starts_with('{') {
        return false;
    }
    matches!(
        json_decode(dart::trim_right(&trimmed[..first_line_end])),
        Ok(Value::Object(_))
    )
}

fn internal_id(source_path: &str, session_id: Option<&str>) -> String {
    if let Some(id) = session_id {
        let stable = trim(id);
        if !stable.is_empty() {
            return format!("session:{stable}");
        }
    }
    format!("source:{source_path}")
}

struct Parser<'a> {
    path: &'a str,
    options: ParserOptions,
}

fn string<'v>(map: &'v Map<String, Value>, key: &str) -> Option<&'v str> {
    map.get(key).and_then(Value::as_str)
}

fn owned(map: &Map<String, Value>, key: &str) -> Option<String> {
    string(map, key).map(str::to_owned)
}

fn int(map: &Map<String, Value>, key: &str) -> Option<i64> {
    map.get(key).and_then(json_int)
}

fn object<'v>(map: &'v Map<String, Value>, key: &str) -> &'v Map<String, Value> {
    static EMPTY: std::sync::OnceLock<Map<String, Value>> = std::sync::OnceLock::new();
    match map.get(key) {
        Some(Value::Object(inner)) => inner,
        _ => EMPTY.get_or_init(Map::new),
    }
}

fn date_time(map: &Map<String, Value>, key: &str) -> Option<DartDateTime> {
    string(map, key).and_then(DartDateTime::try_parse)
}

fn max_date_time(left: Option<DartDateTime>, right: Option<DartDateTime>) -> Option<DartDateTime> {
    match (left, right) {
        (None, right) => right,
        (left, None) => left,
        (Some(left), Some(right)) => Some(if left.is_after(right) { left } else { right }),
    }
}

fn clean_title(value: Option<&str>) -> Option<String> {
    let trimmed = trim(value?);
    if trimmed.is_empty() || dart::to_lower(trimmed).starts_with("# agents.md") {
        return None;
    }
    Some(trimmed.to_owned())
}

fn clean_summary(value: Option<&str>) -> Option<String> {
    let trimmed = trim(value?);
    if trimmed.is_empty() || dart::to_lower(trimmed) == "auto" {
        return None;
    }
    Some(trimmed.to_owned())
}

fn clean_thread_name(value: Option<&str>) -> Option<String> {
    let trimmed = trim(value?);
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

fn first_line(value: &str) -> String {
    let line = match value.find('\n') {
        Some(index) => &value[..index],
        None => value,
    };
    truncate_utf16(trim(line), 240).0
}

pub fn source_type_for(value: Option<&str>, path: &str) -> SourceType {
    let _ = path;
    value
        .and_then(SourceType::from_wire)
        .unwrap_or_else(SourceType::native)
}

/// `isInjectedEnvironmentContextMessage` from `injected_context_filter.dart`.
pub fn is_injected_environment_context_message(content: &str) -> bool {
    let trimmed = trim(content);
    let lower = dart::to_lower(trimmed);
    if lower.starts_with("# agents.md instructions")
        && lower.contains("<instructions>")
        && lower.contains("</instructions>")
    {
        return true;
    }
    const OPEN: &str = "<environment_context>";
    const CLOSE: &str = "</environment_context>";
    if !trimmed.starts_with(OPEN)
        || !trimmed.ends_with(CLOSE)
        || trimmed.len() < OPEN.len() + CLOSE.len()
    {
        return false;
    }
    let inner = &trimmed[OPEN.len()..trimmed.len() - CLOSE.len()];
    for tag in [
        "current_date",
        "timezone",
        "filesystem",
        "cwd",
        "workspace_roots",
        "permission_profile",
    ] {
        let needle = format!("<{tag}");
        let mut search = inner;
        while let Some(index) = search.find(&needle) {
            let after = &search[index + needle.len()..];
            // `\b`: the tag name must not continue with a word character.
            if !after
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
            {
                return true;
            }
            search = &search[index + 1..];
        }
    }
    false
}

fn add_message(messages: &mut Vec<ParsedMessage>, message: ParsedMessage) {
    if let Some(last) = messages.last_mut()
        && last.author_type == message.author_type
        && collapse_whitespace(&last.content_plain) == collapse_whitespace(&message.content_plain)
    {
        if is_echo_record(last) && !is_echo_record(&message) {
            let index = last.index;
            *last = ParsedMessage { index, ..message };
        }
        return;
    }
    messages.push(message);
}

fn is_echo_record(message: &ParsedMessage) -> bool {
    matches!(
        message.raw_type.as_deref(),
        Some("user_message" | "agent_message")
    )
}

/// The readable summary when there is one: Codex encrypts the full reasoning
/// but writes its summary in the clear (the legacy `agent_reasoning` events
/// repeat it and are not stored).
fn reasoning_content(payload: &Map<String, Value>) -> String {
    let summary = reasoning_summary(payload.get("summary"));
    let summary = trim(&summary);
    if !summary.is_empty() {
        return summary.to_owned();
    }
    if let Some(encrypted) = string(payload, "encrypted_content")
        && !trim(encrypted).is_empty()
    {
        return "Reasoning content is encrypted and cannot be displayed.".to_owned();
    }
    "Reasoning content is unavailable.".to_owned()
}

/// The message of a turn that ended with an error, such as a usage limit.
fn task_error(payload: &Map<String, Value>) -> Option<String> {
    let text = match payload.get("error") {
        Some(Value::String(text)) => text.as_str(),
        Some(Value::Object(error)) => string(error, "message")?,
        _ => return None,
    };
    let text = trim(text);
    (!text.is_empty()).then(|| text.to_owned())
}

/// Paths of a Codex `changes` map (path -> change), with rename targets.
fn changed_paths(changes: Option<&Value>, into: &mut BTreeSet<String>) {
    let Some(Value::Object(changes)) = changes else {
        return;
    };
    for (path, change) in changes {
        if !trim(path).is_empty() {
            into.insert(path.clone());
        }
        if let Value::Object(change) = change
            && let Some(target) = string(change, "move_path")
            && !trim(target).is_empty()
        {
            into.insert(target.to_owned());
        }
    }
}

/// `files_changed` (sorted, bounded) and the latest `goal`, or `None`.
fn codex_extra(files_changed: &BTreeSet<String>, goal: Option<Value>) -> Option<Value> {
    let mut extra = Map::new();
    if !files_changed.is_empty() {
        extra.insert(
            "files_changed".to_owned(),
            Value::Array(
                files_changed
                    .iter()
                    .take(MAX_FILES_CHANGED)
                    .map(|path| Value::String(path.clone()))
                    .collect(),
            ),
        );
        if files_changed.len() > MAX_FILES_CHANGED {
            extra.insert(
                "files_changed_total".to_owned(),
                Value::from(files_changed.len()),
            );
        }
    }
    if let Some(goal) = goal {
        extra.insert("goal".to_owned(), goal);
    }
    (!extra.is_empty()).then_some(Value::Object(extra))
}

fn reasoning_summary(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| reasoning_summary(Some(item)))
            .filter(|part| !trim(part).is_empty())
            .collect::<Vec<_>>()
            .join("\n"),
        Some(Value::Object(map)) => string(map, "text")
            .or_else(|| string(map, "summary"))
            .or_else(|| string(map, "content"))
            .unwrap_or("")
            .to_owned(),
        _ => String::new(),
    }
}

fn content_of_legacy_message(message: &Map<String, Value>) -> String {
    match message.get("content") {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Null) | None => {
            if string(message, "type") == Some("tool_call") {
                string(message, "output").unwrap_or("").to_owned()
            } else {
                json_encode(&Value::Object(message.clone()))
            }
        }
        Some(other) => json_encode(other),
    }
}

fn content_from_response_payload(payload: &Map<String, Value>) -> String {
    match payload.get("content") {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Array(items)) => items
            .iter()
            .map(content_part_text)
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join("\n"),
        Some(Value::Null) | None => String::new(),
        Some(other) => json_encode(other),
    }
}

fn content_part_text(part: &Value) -> String {
    match part {
        Value::String(text) => text.clone(),
        Value::Object(map) => string(map, "text")
            .or_else(|| string(map, "message"))
            .or_else(|| string(map, "content"))
            .unwrap_or("")
            .to_owned(),
        _ => String::new(),
    }
}

fn is_tool_call_payload(payload_type: Option<&str>) -> bool {
    matches!(
        payload_type,
        Some("function_call" | "custom_tool_call" | "tool_search_call" | "web_search_call")
    )
}

fn is_tool_output_payload(payload_type: Option<&str>) -> bool {
    matches!(
        payload_type,
        Some("function_call_output" | "custom_tool_call_output" | "tool_search_output")
    )
}

fn tool_name(payload: &Map<String, Value>, payload_type: Option<&str>) -> String {
    if let Some(name) = string(payload, "name")
        && !name.is_empty()
    {
        return name.to_owned();
    }
    match payload_type {
        Some("tool_search_call") => "tool_search",
        Some("web_search_call") => "web_search",
        _ => "unknown",
    }
    .to_owned()
}

fn tool_input(payload: &Map<String, Value>) -> String {
    string(payload, "arguments")
        .or_else(|| string(payload, "input"))
        .or_else(|| string(payload, "query"))
        .unwrap_or("")
        .to_owned()
}

const KNOWN_PASSIVE_RESPONSE_PAYLOAD_TYPES: [&str; 2] = ["ghost_snapshot", "reasoning"];

/// Event types that are not warned about when they are stored as raw
/// evidence. `item_completed`/`item_started` wrap app-server items; the ones
/// that repeat stored content are dropped before this check.
const KNOWN_EVENT_PAYLOAD_TYPES: [&str; 24] = [
    "agent_message",
    "agent_reasoning",
    "collab_agent_interaction_end",
    "collab_agent_spawn_end",
    "collab_close_end",
    "collab_resume_end",
    "collab_waiting_end",
    "context_compacted",
    "error",
    "exec_command_end",
    "item_completed",
    "item_started",
    "mcp_tool_call_end",
    "model_reroute",
    "patch_apply_end",
    "task_complete",
    "task_started",
    "thread_goal_updated",
    "thread_settings_applied",
    "token_count",
    "turn_aborted",
    "user_message",
    "view_image_tool_call",
    "web_search_end",
];

fn usage_event_fingerprint(timestamp: Option<DartDateTime>, cumulative: &Usage) -> String {
    let mut projection = String::from("[");
    match timestamp {
        Some(value) => dart::write_json_string(&mut projection, &value.to_iso8601()),
        None => projection.push_str("null"),
    }
    for value in cumulative.vector() {
        projection.push(',');
        projection.push_str(&value.to_string());
    }
    projection.push(']');
    sha256_hex(projection.as_bytes())
}

fn is_inherited_projected_record(
    record: &Map<String, Value>,
    history_base_thread_id: Option<&str>,
    subagent_history_start_ordinal: Option<i64>,
) -> bool {
    let Some(boundary) = subagent_history_start_ordinal else {
        return false;
    };
    if history_base_thread_id.is_some() {
        return false;
    }
    match int(record, "rollout_ordinal") {
        None => true,
        Some(rollout) => rollout < boundary,
    }
}

impl Parser<'_> {
    fn truncate(&self, value: &str, max: usize) -> (String, bool) {
        truncate_utf16(value, max)
    }

    /// A message with Dart's defaults: no usage, model, tool calls, or error.
    fn message(
        &self,
        index: i64,
        author_type: AuthorType,
        raw_type: Option<String>,
        created_at_utc: Option<DartDateTime>,
        content: &str,
    ) -> ParsedMessage {
        let (content_plain, content_truncated) =
            self.truncate(content, self.options.max_message_content_chars);
        ParsedMessage {
            index,
            author_type,
            raw_type,
            created_at_utc,
            first_line: first_line(content),
            content_plain,
            content_preview: self.truncate(content, 200).0,
            content_truncated,
            usage: Usage::EMPTY,
            model: None,
            has_tool_calls: false,
            has_error: false,
        }
    }

    fn parse_jsonl_snapshot(
        &self,
        size: u64,
        modified: DartDateTime,
    ) -> Result<ParseSuccess, Failure> {
        let session = self.parse_jsonl_session(size)?;
        let after = std::fs::metadata(self.path)?;
        Ok(ParseSuccess {
            session,
            snapshot_size: size,
            snapshot_modified_utc: modified,
            changed_during_parse: after.len() != size || file_modified_utc(&after)? != modified,
        })
    }

    fn parse_json_object_session(&self, json: &Map<String, Value>) -> ParsedSession {
        let source_path = string(json, "source_file_path")
            .unwrap_or(self.path)
            .to_owned();
        let source_type = source_type_for(string(json, "source_type"), &source_path);
        let display_path = string(json, "display_path")
            .map(str::to_owned)
            .unwrap_or_else(|| source_path.clone());
        let platform_path = string(json, "platform_path")
            .map(str::to_owned)
            .unwrap_or_else(|| display_path.clone());
        let working_directory = owned(json, "working_directory");
        let empty = Vec::new();
        let raw_messages = match json.get("messages") {
            Some(Value::Array(items)) => items,
            _ => &empty,
        };
        let mut messages = Vec::new();
        let mut tool_calls: Vec<ParsedToolCall> = Vec::new();
        let mut usage = Usage::EMPTY;
        let mut model_ids: Vec<String> = Vec::new();
        let mut last_message_at_utc = None;
        if let Some(model) = string(json, "model")
            && !model.is_empty()
        {
            push_unique(&mut model_ids, model);
        }
        usage = usage.plus(&Usage::from_json(json.get("usage")));

        for (index, raw) in raw_messages.iter().enumerate() {
            let fallback;
            let message_map = match raw {
                Value::Object(map) => map,
                other => {
                    let mut map = Map::new();
                    map.insert(
                        "content".to_owned(),
                        match other {
                            Value::Null => Value::Null,
                            other => Value::String(dart::to_dart_string(other)),
                        },
                    );
                    fallback = map;
                    &fallback
                }
            };
            let raw_type = owned(message_map, "type");
            let author_type = AuthorType::from_role(raw_type.as_deref());
            let message_usage = Usage::from_json(message_map.get("usage"));
            usage = usage.plus(&message_usage);
            let model = owned(message_map, "model");
            if let Some(model) = &model
                && !model.is_empty()
            {
                push_unique(&mut model_ids, model);
            }
            let tool_call = self.tool_call_from_legacy_message(
                message_map,
                index as i64,
                tool_calls.len() as i64,
            );
            let has_tool_call = tool_call.is_some();
            if let Some(tool_call) = tool_call {
                tool_calls.push(tool_call);
            }
            let created_at_utc = date_time(message_map, "created_at");
            last_message_at_utc = max_date_time(last_message_at_utc, created_at_utc);
            let content = content_of_legacy_message(message_map);
            if author_type == AuthorType::User && is_injected_environment_context_message(&content)
            {
                continue;
            }
            messages.push(ParsedMessage {
                usage: message_usage,
                model,
                has_tool_calls: has_tool_call,
                has_error: string(message_map, "error").is_some(),
                ..self.message(
                    index as i64,
                    author_type,
                    raw_type,
                    created_at_utc,
                    &content,
                )
            });
        }

        let session_id = owned(json, "session_id");
        let usage_projection_status = if usage.has_positive_usage() {
            "ambiguous"
        } else {
            "complete"
        };
        ParsedSession {
            internal_id: internal_id(&source_path, session_id.as_deref()),
            session_id,
            thread_name: clean_thread_name(
                string(json, "thread_name").or_else(|| string(json, "session_name")),
            ),
            thread_source: owned(json, "thread_source"),
            parent_thread_id: owned(json, "parent_thread_id"),
            forked_from_id: None,
            history_base_thread_id: None,
            history_base_end_ordinal_exclusive: None,
            history_base_end_byte_offset: None,
            subagent_history_start_ordinal: None,
            usage_events: Vec::new(),
            usage_working_directories: Vec::new(),
            usage_projection_status: usage_projection_status.to_owned(),
            agent_nickname: owned(json, "agent_nickname"),
            agent_role: owned(json, "agent_role"),
            subagent_depth: int(json, "subagent_depth"),
            source_type,
            source_file_unc_path: owned(json, "source_file_unc_path"),
            display_path,
            platform_path,
            working_directory_display: working_directory.clone(),
            working_directory_platform: working_directory,
            working_directory_unc: owned(json, "working_directory_unc"),
            title: clean_title(string(json, "title")),
            summary: clean_summary(string(json, "summary")),
            started_at_utc: date_time(json, "created_at"),
            last_message_at_utc,
            model_ids,
            messages,
            tool_calls,
            warnings: Vec::new(),
            usage,
            last_turn_usage: Usage::EMPTY,
            extra: None,
            source_path,
        }
    }

    fn tool_call_from_legacy_message(
        &self,
        message: &Map<String, Value>,
        message_index: i64,
        tool_index: i64,
    ) -> Option<ParsedToolCall> {
        if string(message, "type") != Some("tool_call") {
            return None;
        }
        let output = string(message, "output").unwrap_or("");
        let (output_preview, output_truncated) =
            self.truncate(output, self.options.max_tool_output_preview_chars);
        Some(ParsedToolCall {
            message_index,
            tool_index,
            tool_name: string(message, "tool_name").unwrap_or("unknown").to_owned(),
            status: string(message, "status").unwrap_or("unknown").to_owned(),
            started_at_utc: date_time(message, "started_at"),
            finished_at_utc: date_time(message, "finished_at"),
            input_preview: self.truncate(string(message, "input").unwrap_or(""), 200).0,
            output_preview,
            output_truncated,
            error_message: owned(message, "error"),
        })
    }

    fn parse_jsonl_session(&self, size: u64) -> Result<ParsedSession, Failure> {
        Ok(self
            .parse_jsonl_with(size, DartDateTime::from_micros(0), Resume::Disabled)?
            .success
            .session)
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
    fn parse_jsonl_with(
        &self,
        size: u64,
        modified: DartDateTime,
        resume: Resume,
    ) -> Result<CodexParse, Failure> {
        let mut file = SourceReader::open(self.path)?;
        let policy = resume.policy();
        let options = CheckpointOptions {
            max_tool_output_preview_chars: self.options.max_tool_output_preview_chars,
            max_message_content_chars: self.options.max_message_content_chars,
        };
        let mut state = JsonlState::new(self.path);
        let mut capture = WindowCapture::fresh(size);
        let mut scope = None;
        let mut steps = 0;
        let mut line_number = 0u64;
        if let Resume::From(loaded) = resume {
            let cp = *loaded.checkpoint;
            if !policy.enabled || !cp.matches(self.path, "codex", PARSER_VERSION, options, size) {
                return Err(Failure::Abandon(AbandonReason::Mismatch));
            }
            state = serde_json::from_value(cp.state.clone())
                .map_err(|_| Failure::Abandon(AbandonReason::Structure))?;
            if !state.valid_checkpoint(&cp) {
                return Err(Failure::Abandon(AbandonReason::Structure));
            }
            let Some((tail, head)) = cp.windows.validate(&mut file, cp.consumed)? else {
                return Err(Failure::Abandon(AbandonReason::Windows));
            };
            scope = Some(
                state
                    .scope()
                    .ok_or(Failure::Abandon(AbandonReason::Structure))?,
            );
            line_number = cp.next_line;
            steps = cp
                .steps_since_full
                .checked_add(1)
                .ok_or(Failure::Abandon(AbandonReason::Structure))?;
            capture = WindowCapture::resumed(&cp, tail, head)
                .ok_or(Failure::Abandon(AbandonReason::Structure))?;
        }
        let start = capture.consumed();
        let compressed = is_compressed_jsonl(self.path);
        let mut reader: Box<dyn BufRead> = if compressed {
            let decoder = zstd::stream::read::Decoder::new(file.take(size)).map_err(|error| {
                ParseError::new(self.path, ParseErrorKind::MalformedJson, error.to_string())
            })?;
            Box::new(BufReader::with_capacity(256 * 1024, decoder))
        } else {
            Box::new(BufReader::with_capacity(
                256 * 1024,
                file.take(
                    size.checked_sub(start)
                        .ok_or(Failure::Abandon(AbandonReason::Structure))?,
                ),
            ))
        };
        let can_checkpoint =
            policy.enabled && !compressed && self.path.to_lowercase().ends_with(".jsonl");
        let mut checkpoint = None;
        let mut captured_tail = false;
        let mut bytes_read = 0u64;
        let mut segment = Vec::new();
        loop {
            segment.clear();
            let read = reader
                .read_until(b'\n', &mut segment)
                .map_err(|error| -> Failure {
                    // The decoder reports corrupt data as `Other`; that is a
                    // damaged file, not an unreachable one.
                    if compressed && error.kind() == std::io::ErrorKind::Other {
                        ParseError::new(self.path, ParseErrorKind::MalformedJson, error.to_string())
                            .into()
                    } else {
                        error.into()
                    }
                })?;
            if read == 0 {
                break;
            }
            bytes_read = bytes_read
                .checked_add(
                    u64::try_from(read).map_err(|_| Failure::Abandon(AbandonReason::Structure))?,
                )
                .ok_or(Failure::Abandon(AbandonReason::Structure))?;
            let complete = segment.last() == Some(&b'\n');
            if !complete && can_checkpoint {
                checkpoint = observe_checkpoint(
                    state.checkpoint(options, &capture, line_number, steps, policy.min_bytes),
                    scope.is_some(),
                )
                .map_err(Failure::Abandon)?;
                captured_tail = true;
            }
            if complete && can_checkpoint {
                capture
                    .push(&segment)
                    .ok_or(Failure::Abandon(AbandonReason::Structure))?;
            }
            if segment.last() == Some(&b'\n') {
                segment.pop();
                if segment.last() == Some(&b'\r') {
                    segment.pop();
                }
            } else if segment.last() == Some(&b'\r') {
                segment.pop();
            }
            // A lone carriage return also ends a line in Dart's LineSplitter.
            for line in segment.split(|byte| *byte == b'\r') {
                line_number = line_number
                    .checked_add(1)
                    .ok_or(Failure::Abandon(AbandonReason::Structure))?;
                let text = std::str::from_utf8(line).map_err(|error| {
                    let mut parse_error = ParseError::new(
                        self.path,
                        ParseErrorKind::MalformedJson,
                        format!("Invalid UTF-8 byte at offset {}", error.valid_up_to()),
                    );
                    parse_error.line = Some(1);
                    parse_error
                })?;
                let normalized = text.trim_start_matches('\0');
                let padding = u64::try_from(
                    text.len()
                        .checked_sub(normalized.len())
                        .ok_or(Failure::Abandon(AbandonReason::Structure))?,
                )
                .map_err(|_| Failure::Abandon(AbandonReason::Structure))?;
                if trim(normalized).is_empty() {
                    continue;
                }
                let decoded = json_decode(normalized)
                    .map_err(|error| malformed(self.path, &error, padding, Some(line_number)))?;
                let Value::Object(record) = decoded else {
                    let mut parse_error = ParseError::new(
                        self.path,
                        ParseErrorKind::UnsupportedRoot,
                        "JSONL record must be a JSON object.",
                    );
                    parse_error.line = Some(line_number);
                    parse_error.column = Some(1);
                    return Err(parse_error.into());
                };
                if scope.is_some() && state.must_abandon(&record) {
                    return Err(Failure::Abandon(AbandonReason::Finality));
                }
                state.record(&record, self);
                if state.abandon {
                    return Err(Failure::Abandon(AbandonReason::Structure));
                }
            }
        }
        if !compressed && Some(bytes_read) != size.checked_sub(start) {
            return Err(ParseError::new(
                self.path,
                ParseErrorKind::Io,
                "Session file changed while being parsed.",
            )
            .into());
        }
        if can_checkpoint && !captured_tail {
            checkpoint = observe_checkpoint(
                state.checkpoint(options, &capture, line_number, steps, policy.min_bytes),
                scope.is_some(),
            )
            .map_err(Failure::Abandon)?;
        }
        let after = std::fs::metadata(self.path)?;
        Ok(CodexParse {
            success: ParseSuccess {
                session: state.finish()?,
                snapshot_size: size,
                snapshot_modified_utc: modified,
                changed_during_parse: after.len() != size || file_modified_utc(&after)? != modified,
            },
            outcome: if scope.is_some() {
                ResumeOutcome::Resumed
            } else {
                ResumeOutcome::NotAttempted
            },
            scope,
            checkpoint,
        })
    }
}

fn push_unique(values: &mut Vec<String>, value: &str) {
    if !values.iter().any(|existing| existing == value) {
        values.push(value.to_owned());
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct JsonlState {
    abandon: bool,
    source_path: String,
    source_file_unc_path: Option<String>,
    working_directory: Option<String>,
    working_directory_unc: Option<String>,
    title: Option<String>,
    summary: Option<String>,
    session_id: Option<String>,
    thread_name: Option<String>,
    thread_source: Option<String>,
    parent_thread_id: Option<String>,
    forked_from_id: Option<String>,
    history_base_thread_id: Option<String>,
    history_base_end_ordinal_exclusive: Option<i64>,
    history_base_end_byte_offset: Option<i64>,
    subagent_history_start_ordinal: Option<i64>,
    agent_nickname: Option<String>,
    agent_role: Option<String>,
    subagent_depth: Option<i64>,
    started_at_utc: Option<DartDateTime>,
    last_message_at_utc: Option<DartDateTime>,
    message_base: i64,
    tool_base: i64,
    usage_base: i64,
    open_tools: BTreeMap<i64, ParsedToolCall>,
    unresolved: BTreeSet<String>,
    usage_directories: Vec<String>,
    closed: SessionTotals,
    tool_names_prefix: String,
    tool_prefix_count: i64,
    messages: Vec<ParsedMessage>,
    tool_calls: Vec<ParsedToolCall>,
    warnings: Vec<ParseWarning>,
    usage_events: Vec<ParsedUsageEvent>,
    model_ids: Vec<String>,
    model_id_set: BTreeSet<String>,
    pending_tool_calls: HashMap<String, ParsedToolCall>,
    usage: Usage,
    has_aggregate_usage: bool,
    last_turn_usage: Usage,
    previous_cumulative_usage: Usage,
    has_cumulative_usage: bool,
    source_record_ordinal: i64,
    turn_ordinal: Option<i64>,
    counter_epoch: i64,
    pending_counter_reset: bool,
    effective_model: Option<String>,
    effective_working_directory: Option<String>,
    effective_working_directory_unc: Option<String>,
    usage_projection_status: String,
    provider: Option<String>,
    files_changed: BTreeSet<String>,
    goal: Option<Value>,
}

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
impl JsonlState {
    fn message_count(&self) -> Option<i64> {
        self.message_base
            .checked_add(i64::try_from(self.messages.len()).ok()?)
    }
    fn tool_count(&self) -> Option<i64> {
        self.tool_base
            .checked_add(i64::try_from(self.tool_calls.len()).ok()?)
    }
    fn usage_count(&self) -> Option<i64> {
        self.usage_base
            .checked_add(i64::try_from(self.usage_events.len()).ok()?)
    }
    fn set_tool(&mut self, index: i64, row: ParsedToolCall) {
        let target = if index < self.tool_base {
            self.open_tools.get_mut(&index)
        } else {
            index
                .checked_sub(self.tool_base)
                .and_then(|i| usize::try_from(i).ok())
                .and_then(|i| self.tool_calls.get_mut(i))
        };
        match target {
            Some(target) => *target = row,
            None => self.abandon = true,
        }
    }
    fn scope(&self) -> Option<DeltaScope> {
        Some(DeltaScope {
            message_from: self.message_base,
            tool_from: self.tool_base,
            tool_open: self.open_tools.keys().copied().collect(),
            usage_from_ordinal: self.source_record_ordinal.checked_add(1)?,
        })
    }
    fn valid_checkpoint(&self, checkpoint: &Checkpoint) -> bool {
        serde_json::to_value(self).ok().as_ref() == Some(&checkpoint.state)
            && self.source_path == checkpoint.source_path
            && self.closed == checkpoint.closed
            && self.tool_names_prefix == checkpoint.tool_names_prefix
            && self.tool_prefix_count == checkpoint.tool_prefix_count
            && !self.abandon
            && self.closed.valid_counts(checkpoint.row_counts)
            && self.message_base >= 0
            && self.tool_base >= 0
            && self.usage_base >= 0
            && self.source_record_ordinal >= -1
            && i64::try_from(checkpoint.next_line)
                .is_ok_and(|line| self.source_record_ordinal < line)
            && self
                .source_record_ordinal
                .checked_add(1)
                .is_some_and(|records| {
                    checkpoint.row_counts.messages <= records
                        && checkpoint.row_counts.tools <= records
                        && checkpoint.row_counts.usage <= records
                })
            && i64::try_from(self.messages.len())
                .ok()
                .and_then(|len| self.message_base.checked_add(len))
                == Some(checkpoint.row_counts.messages)
            && self.tool_base == checkpoint.row_counts.tools
            && self.usage_base == checkpoint.row_counts.usage
            && self
                .turn_ordinal
                .is_none_or(|ordinal| ordinal >= 0 && ordinal <= self.source_record_ordinal)
            && self.counter_epoch >= 0
            && self.counter_epoch <= self.usage_base
            && self.model_ids.len() == self.model_id_set.len()
            && self.model_ids.iter().cloned().collect::<BTreeSet<_>>() == self.model_id_set
            && self.closed.messages == self.message_base
            && i64::try_from(self.open_tools.len())
                .ok()
                .and_then(|len| self.closed.tool_calls.checked_add(len))
                == Some(self.tool_base)
            && self.tool_prefix_count == self.tool_base
            && self.message_base < i64::MAX
            && self.tool_base < i64::MAX
            && self.usage_base < i64::MAX
            && self.messages.len() <= 1
            && self.tool_calls.is_empty()
            && self.usage_events.is_empty()
            && self.messages.iter().enumerate().all(|(i, row)| {
                i64::try_from(i)
                    .ok()
                    .and_then(|i| self.message_base.checked_add(i))
                    == Some(row.index)
            })
            && self.open_tools.iter().all(|(i, row)| {
                *i >= 0
                    && *i < self.tool_base
                    && row.tool_index == *i
                    && row.message_index >= 0
                    && row.message_index <= checkpoint.row_counts.messages
            })
            && self.open_tools.len() == self.unresolved.len()
            && self
                .pending_tool_calls
                .values()
                .map(|row| row.tool_index)
                .collect::<BTreeSet<_>>()
                .len()
                == self.open_tools.len()
            && self
                .pending_tool_calls
                .keys()
                .all(|id| self.unresolved.contains(id))
            && self.unresolved.iter().all(|id| {
                self.pending_tool_calls
                    .get(id)
                    .is_some_and(|p| self.open_tools.get(&p.tool_index) == Some(p))
            })
    }
    fn must_abandon(&self, record: &Map<String, Value>) -> bool {
        let payload = object(record, "payload");
        string(record, "type") == Some("response_item")
            && is_tool_output_payload(string(payload, "type"))
            && string(payload, "call_id")
                .is_some_and(|id| !self.pending_tool_calls.contains_key(id))
    }
    fn checkpoint(
        &self,
        options: CheckpointOptions,
        capture: &WindowCapture,
        next_line: u64,
        steps: u32,
        min_bytes: u64,
    ) -> Result<Option<CheckpointRecord>, BuildFailed> {
        if capture.consumed() < min_bytes || self.usage_projection_status == "legacy_pending" {
            return Ok(None);
        }
        let checkpoint = (|| -> Option<Checkpoint> {
            let mut state = self.clone();
            let keep_message = state.messages.len().saturating_sub(1);
            for message in state.messages.drain(..keep_message) {
                state.closed.add_message(&(&message).into());
            }
            state.message_base = state
                .message_base
                .checked_add(i64::try_from(keep_message).ok()?)?;
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
            let open_indices: BTreeSet<i64> = state
                .unresolved
                .iter()
                .filter_map(|id| state.pending_tool_calls.get(id).map(|tool| tool.tool_index))
                .collect();
            for tool in std::mem::take(&mut state.tool_calls) {
                state.open_tools.insert(tool.tool_index, tool);
            }
            for (index, row) in std::mem::take(&mut state.open_tools) {
                if open_indices.contains(&index) {
                    state.open_tools.insert(index, row);
                } else {
                    state.closed.add_tool(&(&row).into());
                }
            }
            state.tool_base = tool_count;
            state.usage_base = state.usage_count()?;
            state.usage_events.clear();
            state
                .pending_tool_calls
                .retain(|id, _| state.unresolved.contains(id));
            // Warnings are not persisted rows, but remain in the whole state so the
            // checkpoint shape and subsequent parsing do not silently lose fields.
            Some(Checkpoint {
                format: RESUME_FORMAT,
                harness: "codex".to_owned(),
                parser_version: PARSER_VERSION,
                options,
                source_path: self.source_path.clone(),
                consumed: capture.consumed(),
                next_line,
                row_counts: RowCounts {
                    messages: state.message_count()?,
                    tools: state.tool_count()?,
                    usage: state.usage_count()?,
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

    fn new(path: &str) -> Self {
        Self {
            abandon: false,
            source_path: path.to_owned(),
            source_file_unc_path: None,
            working_directory: None,
            working_directory_unc: None,
            title: None,
            summary: None,
            session_id: None,
            thread_name: None,
            thread_source: None,
            parent_thread_id: None,
            forked_from_id: None,
            history_base_thread_id: None,
            history_base_end_ordinal_exclusive: None,
            history_base_end_byte_offset: None,
            subagent_history_start_ordinal: None,
            agent_nickname: None,
            agent_role: None,
            subagent_depth: None,
            started_at_utc: None,
            last_message_at_utc: None,
            message_base: 0,
            tool_base: 0,
            usage_base: 0,
            open_tools: BTreeMap::new(),
            unresolved: BTreeSet::new(),
            usage_directories: Vec::new(),
            closed: SessionTotals::default(),
            tool_names_prefix: String::new(),
            tool_prefix_count: 0,
            messages: Vec::new(),
            tool_calls: Vec::new(),
            warnings: Vec::new(),
            usage_events: Vec::new(),
            model_ids: Vec::new(),
            model_id_set: BTreeSet::new(),
            pending_tool_calls: HashMap::new(),
            usage: Usage::EMPTY,
            has_aggregate_usage: false,
            last_turn_usage: Usage::EMPTY,
            previous_cumulative_usage: Usage::ZERO,
            has_cumulative_usage: false,
            source_record_ordinal: -1,
            turn_ordinal: None,
            counter_epoch: 0,
            pending_counter_reset: false,
            effective_model: None,
            effective_working_directory: None,
            effective_working_directory_unc: None,
            usage_projection_status: "complete".to_owned(),
            provider: None,
            files_changed: BTreeSet::new(),
            goal: None,
        }
    }

    fn add_model(&mut self, model: &str) {
        if self.model_id_set.insert(model.to_owned()) {
            self.model_ids.push(model.to_owned());
        }
    }

    fn inherited(&self, record: &Map<String, Value>) -> bool {
        is_inherited_projected_record(
            record,
            self.history_base_thread_id.as_deref(),
            self.subagent_history_start_ordinal,
        )
    }

    fn record(&mut self, record: &Map<String, Value>, parser: &Parser<'_>) {
        let message_count = state_value!(self, self.message_count());
        let tool_count = state_value!(self, self.tool_count());
        self.source_record_ordinal = state_value!(self, self.source_record_ordinal.checked_add(1));
        let record_type = string(record, "type");
        let timestamp = date_time(record, "timestamp");
        let payload = object(record, "payload");
        let payload_type = string(payload, "type");

        if record_type == Some("session_meta") {
            self.session_meta(payload, timestamp);
            return;
        }
        if record_type == Some("turn_context") {
            if self.inherited(record) {
                return;
            }
            self.turn_ordinal = Some(state_value!(
                self,
                self.turn_ordinal.unwrap_or(-1).checked_add(1)
            ));
            let cwd = owned(payload, "cwd");
            let cwd_unc = owned(payload, "working_directory_unc");
            if cwd.is_some() {
                self.working_directory = cwd.clone();
                self.working_directory_unc = cwd_unc.clone();
                self.effective_working_directory = cwd;
                self.effective_working_directory_unc = cwd_unc;
            } else if cwd_unc.is_some() {
                self.working_directory_unc = cwd_unc.clone();
                self.effective_working_directory_unc = cwd_unc;
            }
            if let Some(name) = clean_thread_name(thread_name_candidate(payload)) {
                self.thread_name = Some(name);
            }
            if let Some(title) = clean_title(string(payload, "title")) {
                self.title = Some(title);
            }
            if let Some(summary) = clean_summary(string(payload, "summary")) {
                self.summary = Some(summary);
            }
            if let Some(model) = string(payload, "model")
                && !model.is_empty()
            {
                self.effective_model = Some(model.to_owned());
                self.add_model(model);
            }
            return;
        }
        if record_type == Some("event_msg") && payload_type == Some("thread_settings_applied") {
            if self.inherited(record) {
                return;
            }
            let settings = object(payload, "thread_settings");
            if let Some(model) = string(settings, "model")
                && !model.is_empty()
            {
                self.effective_model = Some(model.to_owned());
                self.add_model(model);
            }
            let cwd = owned(settings, "cwd");
            let cwd_unc = owned(settings, "working_directory_unc");
            if cwd.is_some() {
                self.effective_working_directory = cwd;
                self.effective_working_directory_unc = cwd_unc;
            } else if cwd_unc.is_some() {
                self.effective_working_directory_unc = cwd_unc;
            }
            return;
        }
        if record_type == Some("event_msg") && payload_type == Some("model_reroute") {
            if self.inherited(record) {
                return;
            }
            if let Some(model) = string(payload, "to_model")
                && !model.is_empty()
            {
                self.effective_model = Some(model.to_owned());
                self.add_model(model);
            }
            return;
        }
        if record_type == Some("event_msg") && payload_type == Some("token_count") {
            self.token_count(record, payload, timestamp);
            return;
        }
        if record_type == Some("event_msg")
            && self.consume_event(record, payload, payload_type, timestamp, parser)
        {
            return;
        }
        if record_type != Some("response_item") && record_type != Some("event_msg") {
            if record_type != Some("compacted") {
                self.warnings.push(ParseWarning {
                    code: "unknown_record_type".to_owned(),
                    record_type: record_type.unwrap_or("unknown").to_owned(),
                    payload_type: payload_type.map(str::to_owned),
                    message: "Unknown JSONL record type.".to_owned(),
                });
            }
            return;
        }

        if record_type == Some("response_item") && payload_type == Some("message") {
            let content = content_from_response_payload(payload);
            let author_type = AuthorType::from_role(string(payload, "role"));
            if author_type == AuthorType::User && is_injected_environment_context_message(&content)
            {
                return;
            }
            let message_usage = Usage::from_json(payload.get("usage"));
            if !self.has_aggregate_usage {
                self.usage = self.usage.plus(&message_usage);
            }
            let model = owned(payload, "model");
            if let Some(model) = &model
                && !model.is_empty()
            {
                self.add_model(model);
            }
            let message = ParsedMessage {
                usage: message_usage,
                model,
                ..parser.message(
                    message_count,
                    author_type,
                    payload_type.map(str::to_owned),
                    timestamp,
                    &content,
                )
            };
            add_message(&mut self.messages, message);
            self.last_message_at_utc = max_date_time(self.last_message_at_utc, timestamp);
            return;
        }
        if record_type == Some("event_msg")
            && matches!(payload_type, Some("user_message" | "agent_message"))
        {
            let content = string(payload, "message").unwrap_or("");
            let author_type = if payload_type == Some("user_message") {
                AuthorType::User
            } else {
                AuthorType::Assistant
            };
            if author_type == AuthorType::User && is_injected_environment_context_message(content) {
                return;
            }
            let message = parser.message(
                message_count,
                author_type,
                payload_type.map(str::to_owned),
                timestamp,
                content,
            );
            add_message(&mut self.messages, message);
            self.last_message_at_utc = max_date_time(self.last_message_at_utc, timestamp);
            return;
        }
        if record_type == Some("response_item") && is_tool_call_payload(payload_type) {
            let tool_call = ParsedToolCall {
                message_index: message_count,
                tool_index: tool_count,
                tool_name: tool_name(payload, payload_type),
                status: "started".to_owned(),
                started_at_utc: timestamp,
                finished_at_utc: None,
                input_preview: parser.truncate(&tool_input(payload), 200).0,
                output_preview: String::new(),
                output_truncated: false,
                error_message: None,
            };
            if let Some(call_id) = string(payload, "call_id") {
                self.unresolved.insert(call_id.to_owned());
                self.pending_tool_calls
                    .insert(call_id.to_owned(), tool_call.clone());
            }
            self.tool_calls.push(tool_call);
            return;
        }
        if record_type == Some("response_item") && is_tool_output_payload(payload_type) {
            let prior = string(payload, "call_id")
                .and_then(|call_id| self.pending_tool_calls.get(call_id))
                .cloned();
            if let Some(call_id) = string(payload, "call_id") {
                self.unresolved.remove(call_id);
            }
            let output = string(payload, "output").unwrap_or("");
            let (output_preview, output_truncated) =
                parser.truncate(output, parser.options.max_tool_output_preview_chars);
            let updated = ParsedToolCall {
                message_index: prior.as_ref().map_or(message_count, |p| p.message_index),
                tool_index: prior.as_ref().map_or(tool_count, |p| p.tool_index),
                tool_name: prior
                    .as_ref()
                    .map_or_else(|| "unknown".to_owned(), |p| p.tool_name.clone()),
                status: string(payload, "status").unwrap_or("finished").to_owned(),
                started_at_utc: prior.as_ref().and_then(|p| p.started_at_utc),
                finished_at_utc: timestamp,
                input_preview: prior
                    .as_ref()
                    .map_or_else(String::new, |p| p.input_preview.clone()),
                output_preview,
                output_truncated,
                error_message: owned(payload, "error"),
            };
            match prior {
                None => self.tool_calls.push(updated),
                Some(prior) => self.set_tool(prior.tool_index, updated),
            }
            return;
        }
        if record_type == Some("response_item") && payload_type == Some("reasoning") {
            let content = reasoning_content(payload);
            let message = parser.message(
                message_count,
                AuthorType::Reasoning,
                payload_type.map(str::to_owned),
                timestamp,
                &content,
            );
            add_message(&mut self.messages, message);
            self.last_message_at_utc = max_date_time(self.last_message_at_utc, timestamp);
            return;
        }
        // A message between agents of one thread tree; its readable header
        // and payload are kept, encrypted parts are not.
        if record_type == Some("response_item") && payload_type == Some("agent_message") {
            let content = content_from_response_payload(payload);
            if trim(&content).is_empty() {
                return;
            }
            let message = parser.message(
                message_count,
                AuthorType::System,
                payload_type.map(str::to_owned),
                timestamp,
                &content,
            );
            add_message(&mut self.messages, message);
            self.last_message_at_utc = max_date_time(self.last_message_at_utc, timestamp);
            return;
        }

        if record_type == Some("response_item")
            && !payload_type
                .is_some_and(|value| KNOWN_PASSIVE_RESPONSE_PAYLOAD_TYPES.contains(&value))
        {
            self.warnings.push(ParseWarning {
                code: "unknown_response_item_type".to_owned(),
                record_type: "response_item".to_owned(),
                payload_type: payload_type.map(str::to_owned),
                message: "Unknown response item payload type.".to_owned(),
            });
        } else if record_type == Some("response_item") {
            return;
        } else if !payload_type.is_some_and(|value| KNOWN_EVENT_PAYLOAD_TYPES.contains(&value)) {
            self.warnings.push(ParseWarning {
                code: "unknown_event_message_type".to_owned(),
                record_type: "event_msg".to_owned(),
                payload_type: payload_type.map(str::to_owned),
                message: "Unknown event message payload type.".to_owned(),
            });
        }

        let content = json_encode(&Value::Object(payload.clone()));
        let message = parser.message(
            message_count,
            AuthorType::Unknown,
            payload_type.or(record_type).map(str::to_owned),
            timestamp,
            &content,
        );
        add_message(&mut self.messages, message);
        self.last_message_at_utc = max_date_time(self.last_message_at_utc, timestamp);
    }

    /// Events that are not conversation messages. Returns false for events
    /// stored as before. Dropped: items and events that repeat a stored
    /// message, reasoning, or tool call (`item_completed` agent/user messages,
    /// reasoning, command executions; `exec_command_end`; `agent_reasoning`,
    /// whose text the reasoning item's summary holds; a completed turn's
    /// `last_agent_message`) and turn bookkeeping. File changes and goals
    /// become source extras. Inherited (projected parent) records add none.
    fn consume_event(
        &mut self,
        record: &Map<String, Value>,
        payload: &Map<String, Value>,
        payload_type: Option<&str>,
        timestamp: Option<DartDateTime>,
        parser: &Parser<'_>,
    ) -> bool {
        match payload_type {
            Some(kind @ ("item_completed" | "item_started")) => {
                let item = object(payload, "item");
                match string(item, "type") {
                    Some("FileChange") => {
                        let status = string(item, "status");
                        if kind == "item_completed"
                            && !matches!(status, Some("failed" | "declined"))
                            && !self.inherited(record)
                        {
                            changed_paths(item.get("changes"), &mut self.files_changed);
                        }
                        true
                    }
                    Some(
                        "AgentMessage" | "Reasoning" | "UserMessage" | "ContextCompaction"
                        | "CommandExecution",
                    ) => true,
                    _ => false,
                }
            }
            Some("patch_apply_end") => {
                if payload.get("success") != Some(&Value::Bool(false)) && !self.inherited(record) {
                    changed_paths(payload.get("changes"), &mut self.files_changed);
                }
                true
            }
            Some("thread_goal_updated") => {
                if !self.inherited(record) {
                    self.goal = match payload.get("goal") {
                        Some(Value::Object(goal)) => Some(serde_json::json!({
                            "objective": goal.get("objective").cloned().unwrap_or(Value::Null),
                            "status": goal.get("status").cloned().unwrap_or(Value::Null),
                        })),
                        _ => None,
                    };
                }
                true
            }
            Some("thread_name_updated") => {
                if !self.inherited(record)
                    && let Some(name) = clean_thread_name(string(payload, "thread_name"))
                {
                    self.thread_name = Some(name);
                }
                true
            }
            Some("task_complete") => {
                if let Some(error) = task_error(payload) {
                    let message = ParsedMessage {
                        has_error: true,
                        ..parser.message(
                            match self.message_count() {
                                Some(count) => count,
                                None => {
                                    self.abandon = true;
                                    return true;
                                }
                            },
                            AuthorType::System,
                            payload_type.map(str::to_owned),
                            timestamp,
                            &error,
                        )
                    };
                    add_message(&mut self.messages, message);
                    self.last_message_at_utc = max_date_time(self.last_message_at_utc, timestamp);
                }
                true
            }
            Some(
                "exec_command_end" | "task_started" | "context_compacted" | "turn_aborted"
                | "agent_reasoning",
            ) => true,
            _ => false,
        }
    }

    fn session_meta(&mut self, payload: &Map<String, Value>, timestamp: Option<DartDateTime>) {
        let Some(metadata_session_id) = string(payload, "id") else {
            return;
        };
        if trim(metadata_session_id).is_empty() || self.session_id.is_some() {
            return;
        }
        self.session_id = Some(metadata_session_id.to_owned());
        if let Some(name) = clean_thread_name(thread_name_candidate(payload)) {
            self.thread_name = Some(name);
        }
        if let Some(value) = owned(payload, "thread_source") {
            self.thread_source = Some(value);
        }
        if let Some(value) = owned(payload, "parent_thread_id") {
            self.parent_thread_id = Some(value);
        }
        self.forked_from_id = owned(payload, "forked_from_id");
        let history_base = object(payload, "history_base");
        self.history_base_thread_id = owned(history_base, "thread_id");
        self.history_base_end_ordinal_exclusive = int(history_base, "end_ordinal_exclusive");
        self.history_base_end_byte_offset = int(history_base, "end_byte_offset");
        self.subagent_history_start_ordinal = int(payload, "subagent_history_start_ordinal");
        if let Some(value) = owned(payload, "agent_nickname") {
            self.agent_nickname = Some(value);
        }
        if let Some(value) = owned(payload, "agent_role") {
            self.agent_role = Some(value);
        }
        if let Some(value) = int(payload, "subagent_depth") {
            self.subagent_depth = Some(value);
        }
        let source = object(payload, "source");
        let subagent = object(source, "subagent");
        let thread_spawn = object(subagent, "thread_spawn");
        if !subagent.is_empty() || !thread_spawn.is_empty() {
            self.thread_source = Some("subagent".to_owned());
            if let Some(value) = owned(thread_spawn, "parent_thread_id") {
                self.parent_thread_id = Some(value);
            }
            if let Some(value) = owned(thread_spawn, "agent_nickname") {
                self.agent_nickname = Some(value);
            }
            if let Some(value) = owned(thread_spawn, "agent_role") {
                self.agent_role = Some(value);
            }
            if let Some(value) = int(thread_spawn, "depth") {
                self.subagent_depth = Some(value);
            }
        }
        if self.history_base_thread_id.is_none()
            && self.subagent_history_start_ordinal.is_none()
            && (self.forked_from_id.is_some() || self.parent_thread_id.is_some())
        {
            self.usage_projection_status = "legacy_pending".to_owned();
        }
        let owner_working_directory = owned(payload, "cwd");
        if owner_working_directory.is_some() {
            self.working_directory = owner_working_directory.clone();
            self.working_directory_unc = owned(payload, "working_directory_unc");
            self.effective_working_directory = owner_working_directory;
            self.effective_working_directory_unc = self.working_directory_unc.clone();
        }
        if let Some(title) = clean_title(string(payload, "title")) {
            self.title = Some(title);
        }
        self.source_file_unc_path = owned(payload, "source_file_unc_path");
        self.provider = owned(payload, "model_provider");
        self.started_at_utc = date_time(payload, "timestamp")
            .or(timestamp)
            .or(self.started_at_utc);
    }

    fn token_count(
        &mut self,
        record: &Map<String, Value>,
        payload: &Map<String, Value>,
        timestamp: Option<DartDateTime>,
    ) {
        let info = object(payload, "info");
        let total = Usage::from_json(info.get("total_token_usage"));
        if !total.is_empty() {
            self.usage = total;
            self.has_aggregate_usage = true;
        }
        let last = Usage::from_json(info.get("last_token_usage"));
        if !last.is_empty() {
            self.last_turn_usage = last;
        }
        if !total.is_empty() && !total.has_positive_value() {
            if !self.has_cumulative_usage {
                self.previous_cumulative_usage = total;
                self.has_cumulative_usage = true;
            } else if !total.has_same_vector(&self.previous_cumulative_usage) {
                self.previous_cumulative_usage = total;
                self.pending_counter_reset = true;
            }
        }
        if total.is_empty()
            || !total.has_positive_value()
            || (self.has_cumulative_usage && total.has_same_vector(&self.previous_cumulative_usage))
        {
            return;
        }
        let reset_from_zero = self.pending_counter_reset;
        let counter_reset = reset_from_zero
            || (self.has_cumulative_usage
                && !total.is_componentwise_at_least(&self.previous_cumulative_usage));
        let delta = if counter_reset {
            total.non_negative()
        } else {
            total.difference_from(&self.previous_cumulative_usage)
        };
        let first_legacy_event =
            self.usage_count() == Some(0) && self.usage_projection_status == "legacy_pending";
        let use_last_token_usage = !last.is_empty()
            && last.is_non_negative()
            && if counter_reset {
                if reset_from_zero {
                    last.has_same_vector(&delta)
                } else {
                    total.is_componentwise_at_least(&last)
                }
            } else if first_legacy_event {
                total.is_componentwise_at_least(&last)
            } else {
                last.has_same_vector(&delta)
            };
        if counter_reset {
            self.counter_epoch = state_value!(self, self.counter_epoch.checked_add(1));
            self.pending_counter_reset = false;
        }
        let event_usage = if use_last_token_usage { last } else { delta }.with_component_total();
        let rollout_ordinal = int(record, "rollout_ordinal");
        let branch_scope = if self.history_base_thread_id.is_some() {
            "local"
        } else {
            match self.subagent_history_start_ordinal {
                Some(_) if rollout_ordinal.is_none() => "ambiguous",
                Some(boundary) if rollout_ordinal.is_some_and(|value| value < boundary) => {
                    "inherited"
                }
                None if self.forked_from_id.is_some() || self.parent_thread_id.is_some() => {
                    "ambiguous"
                }
                _ => "local",
            }
        };
        if branch_scope == "ambiguous" && self.subagent_history_start_ordinal.is_some() {
            self.usage_projection_status = "ambiguous".to_owned();
        }
        if let Some(directory) = &self.effective_working_directory {
            push_unique(&mut self.usage_directories, directory);
        }
        self.usage_events.push(ParsedUsageEvent {
            source_record_ordinal: self.source_record_ordinal,
            rollout_ordinal,
            turn_ordinal: self.turn_ordinal,
            counter_epoch: self.counter_epoch,
            occurred_at_utc: timestamp,
            model: self.effective_model.clone(),
            working_directory: self.effective_working_directory.clone(),
            working_directory_unc: self.effective_working_directory_unc.clone(),
            usage: event_usage,
            branch_scope: branch_scope.to_owned(),
            derivation: if counter_reset {
                "counter_reset"
            } else if use_last_token_usage {
                "last_token_usage"
            } else {
                "cumulative_delta"
            }
            .to_owned(),
            cumulative_usage: total,
            event_fingerprint: usage_event_fingerprint(timestamp, &total),
            provider: self.provider.clone(),
            request_input_tokens: if use_last_token_usage {
                last.input_tokens
            } else {
                None
            },
            model_context_window: int(info, "model_context_window"),
        });
        self.previous_cumulative_usage = total;
        self.has_cumulative_usage = true;
    }

    fn finish(mut self) -> Result<ParsedSession, Failure> {
        if self
            .usage_count()
            .ok_or(Failure::Abandon(AbandonReason::Structure))?
            == 0
        {
            self.usage_projection_status = if self.usage.has_positive_usage() {
                "ambiguous"
            } else {
                "complete"
            }
            .to_owned();
        }
        let display_path = self.source_path.clone();
        let extra = codex_extra(&self.files_changed, self.goal.take());
        Ok(ParsedSession {
            extra,
            internal_id: internal_id(&self.source_path, self.session_id.as_deref()),
            session_id: self.session_id,
            thread_name: self.thread_name,
            thread_source: self.thread_source,
            parent_thread_id: self.parent_thread_id,
            forked_from_id: self.forked_from_id,
            history_base_thread_id: self.history_base_thread_id,
            history_base_end_ordinal_exclusive: self.history_base_end_ordinal_exclusive,
            history_base_end_byte_offset: self.history_base_end_byte_offset,
            subagent_history_start_ordinal: self.subagent_history_start_ordinal,
            usage_events: self.usage_events,
            usage_working_directories: self.usage_directories,
            usage_projection_status: self.usage_projection_status,
            agent_nickname: self.agent_nickname,
            agent_role: self.agent_role,
            subagent_depth: self.subagent_depth,
            source_type: source_type_for(None, &self.source_path),
            source_file_unc_path: self.source_file_unc_path,
            platform_path: display_path.clone(),
            display_path,
            working_directory_display: self.working_directory.clone(),
            working_directory_platform: self.working_directory,
            working_directory_unc: self.working_directory_unc,
            title: clean_title(self.title.as_deref()),
            summary: clean_summary(self.summary.as_deref()),
            started_at_utc: self.started_at_utc,
            last_message_at_utc: self.last_message_at_utc,
            model_ids: self.model_ids,
            messages: self.messages,
            tool_calls: self
                .open_tools
                .into_values()
                .chain(self.tool_calls)
                .collect(),
            warnings: self.warnings,
            usage: self.usage,
            last_turn_usage: self.last_turn_usage,
            source_path: self.source_path,
        })
    }
}

fn thread_name_candidate(payload: &Map<String, Value>) -> Option<&str> {
    string(payload, "thread_name")
        .or_else(|| string(payload, "session_name"))
        .or_else(|| string(payload, "name"))
        .or_else(|| string(payload, "title"))
}

pub fn path_display(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}
