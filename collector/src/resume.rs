//! Bounded parser checkpoints, with one transition path for full and resumed parses.
//!
//! T1: storage corruption or envelope/version/options skew fails the digest or
//! structural checks and restarts a full parse. T2: correct writer checkpoints
//! equal a full parse, proved by the differential generator. T3: correctly digested
//! state from a buggy writer may change rows, but must remain panic-free, bounded,
//! and never stricter than a full parse. Token values and folds always wrap;
//! positions are checked. Checkpoint construction observes the parse result.
//! A change to construction or field meaning bumps RESUME_FORMAT; fixing a writer
//! bug that may have stored wrong rows bumps the harness PARSER_VERSION.
#![deny(
    clippy::arithmetic_side_effects,
    clippy::indexing_slicing,
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::cast_possible_wrap,
    clippy::cast_sign_loss,
    clippy::cast_possible_truncation
)]
use std::cell::Cell;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::codex::parser::Usage;
use crate::contract::{MessageRecord, SessionSnapshot, ToolCallRecord, UsageRecord};
use crate::dart::sha256_hex;

pub const RESUME_FORMAT: i64 = 3;
pub const RESUME_MIN_BYTES: u64 = 1024 * 1024;
pub const MAX_BLOB_BYTES: usize = 256 * 1024;
pub const MAX_DECODED_BYTES: usize = 64 * 1024 * 1024;
pub const MAX_STEPS: u32 = 256;
const HEAD_BYTES: usize = 64 * 1024;
const TAIL_BYTES: usize = 16 * 1024;
const ANCHOR_BYTES: usize = 4 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ResumePolicy {
    pub enabled: bool,
    pub min_bytes: u64,
}
impl Default for ResumePolicy {
    fn default() -> Self {
        Self {
            enabled: true,
            min_bytes: RESUME_MIN_BYTES,
        }
    }
}
thread_local! {
    static POLICY: Cell<ResumePolicy> = const { Cell::new(ResumePolicy { enabled: true, min_bytes: RESUME_MIN_BYTES }) };
}
impl ResumePolicy {
    pub fn current() -> Self {
        POLICY.get()
    }
    pub fn testing() -> Self {
        Self {
            enabled: true,
            min_bytes: 0,
        }
    }
}
/// Thread-local override; scan coordinators pass the captured policy to jobs.
pub struct ResumePolicyScope(ResumePolicy, std::marker::PhantomData<std::rc::Rc<()>>);
impl ResumePolicyScope {
    pub fn enter(policy: ResumePolicy) -> Self {
        Self(POLICY.replace(policy), std::marker::PhantomData)
    }
}
impl Drop for ResumePolicyScope {
    fn drop(&mut self) {
        POLICY.set(self.0);
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AbandonReason {
    Mismatch,
    Windows,
    Structure,
    Finality,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ResumeOutcome {
    NotAttempted,
    Resumed,
    Abandoned(AbandonReason),
}
#[derive(Clone, Copy, Debug)]
pub struct BuildFailed;
/// Fresh construction cannot alter success; restored position failures restart.
pub(crate) fn observe_checkpoint(
    build: Result<Option<CheckpointRecord>, BuildFailed>,
    resumed: bool,
) -> Result<Option<CheckpointRecord>, AbandonReason> {
    match build {
        Ok(record) => Ok(record),
        Err(_) if resumed => Err(AbandonReason::Structure),
        Err(_) => Ok(None),
    }
}

#[derive(Clone, Debug)]
pub enum Resume {
    Disabled,
    Fresh(ResumePolicy),
    From(LoadedCheckpoint),
}
impl Resume {
    pub fn policy(&self) -> ResumePolicy {
        match self {
            Self::Disabled => ResumePolicy {
                enabled: false,
                ..ResumePolicy::default()
            },
            Self::Fresh(policy) => *policy,
            Self::From(loaded) => loaded.policy,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CheckpointOptions {
    pub max_tool_output_preview_chars: usize,
    pub max_message_content_chars: usize,
}

impl CheckpointOptions {
    /// Versioned, architecture-independent identity of every parser input option.
    pub fn digest(self) -> String {
        let Self {
            max_tool_output_preview_chars,
            max_message_content_chars,
        } = self;
        sha256_hex(
            format!(
                "parse-options-v1\n{}\n{}\n",
                max_tool_output_preview_chars, max_message_content_chars
            )
            .as_bytes(),
        )
    }
}

impl From<crate::codex::parser::ParserOptions> for CheckpointOptions {
    fn from(options: crate::codex::parser::ParserOptions) -> Self {
        // Exhaustive destructuring makes adding a parser option require updating
        // this identity, rather than silently omitting it from cache validity.
        let crate::codex::parser::ParserOptions {
            max_tool_output_preview_chars,
            max_message_content_chars,
        } = options;
        Self {
            max_tool_output_preview_chars,
            max_message_content_chars,
        }
    }
}

impl From<crate::claude::parser::ClaudeOptions> for CheckpointOptions {
    fn from(options: crate::claude::parser::ClaudeOptions) -> Self {
        let crate::claude::parser::ClaudeOptions {
            max_tool_output_preview_chars,
            max_message_content_chars,
        } = options;
        Self {
            max_tool_output_preview_chars,
            max_message_content_chars,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FingerprintWindow {
    pub offset: u64,
    pub length: u64,
    pub sha256: String,
}
impl FingerprintWindow {
    fn from_bytes(offset: u64, bytes: &[u8]) -> Option<Self> {
        Some(Self {
            offset,
            length: u64::try_from(bytes.len()).ok()?,
            sha256: sha256_hex(bytes),
        })
    }
}
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FingerprintWindows {
    pub head: Option<FingerprintWindow>,
    pub anchors: Vec<FingerprintWindow>,
    pub tail: Option<FingerprintWindow>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Checkpoint {
    pub format: i64,
    pub harness: String,
    pub parser_version: i64,
    pub options: CheckpointOptions,
    pub source_path: String,
    pub consumed: u64,
    pub next_line: u64,
    pub row_counts: RowCounts,
    pub windows: FingerprintWindows,
    /// Zero after a full parse; positive after incremental ingest. Phase 2 uses
    /// this marker to schedule the accepted full parse when growth stops.
    pub steps_since_full: u32,
    pub closed: SessionTotals,
    pub tool_names_prefix: String,
    pub tool_prefix_count: i64,
    pub state: Value,
}
impl Checkpoint {
    pub fn matches(
        &self,
        path: &str,
        harness: &str,
        version: i64,
        options: CheckpointOptions,
        size: u64,
    ) -> bool {
        self.format == RESUME_FORMAT
            && self.harness == harness
            && self.parser_version == version
            && self.options == options
            && self.source_path == path
            && size >= self.consumed
            && self.consumed < i64::MAX as u64
            && self.steps_since_full < MAX_STEPS
            && self.next_line < i64::MAX as u64
            && self.next_line <= self.consumed
            && (self.next_line == 0) == (self.consumed == 0)
            && self.row_counts.valid(self.consumed)
            && self.windows.valid_shape(self.consumed)
    }
    pub fn encode(&self) -> Option<CheckpointRecord> {
        let payload = serde_json::to_value(self).ok()?;
        let canonical = canonical_json(&payload).ok()?;
        let json = serde_json::to_vec(&EncodedCheckpoint {
            digest: sha256_hex(&canonical),
            payload,
        })
        .ok()?;
        if json.len() > MAX_DECODED_BYTES {
            return None;
        }
        let blob = zstd::stream::encode_all(json.as_slice(), 3).ok()?;
        (blob.len() <= MAX_BLOB_BYTES).then(|| CheckpointRecord {
            harness: self.harness.clone(),
            source_path: self.source_path.clone(),
            parser_version: self.parser_version,
            format_version: self.format,
            consumed_bytes: self.consumed,
            state: blob,
        })
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct EncodedCheckpoint {
    digest: String,
    payload: Value,
}

fn canonical_json(value: &Value) -> Result<Vec<u8>, serde_json::Error> {
    fn sorted(value: &Value) -> Value {
        match value {
            Value::Object(map) => Value::Object(
                map.iter()
                    .map(|(k, v)| (k.clone(), sorted(v)))
                    .collect::<std::collections::BTreeMap<_, _>>()
                    .into_iter()
                    .collect(),
            ),
            Value::Array(values) => Value::Array(values.iter().map(sorted).collect()),
            value => value.clone(),
        }
    }
    serde_json::to_vec(&sorted(value))
}

/// Independent absolute counts make missing window rows detectable on decode.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RowCounts {
    pub messages: i64,
    pub tools: i64,
    pub usage: i64,
}
impl RowCounts {
    fn valid(self, consumed: u64) -> bool {
        [self.messages, self.tools, self.usage]
            .into_iter()
            .all(|count| count >= 0 && u64::try_from(count).is_ok_and(|count| count <= consumed))
    }
}
/// Persistence metadata is duplicated in the table for cheap preconditions.
#[derive(Clone, Debug, PartialEq)]
pub struct CheckpointRecord {
    pub harness: String,
    pub source_path: String,
    pub parser_version: i64,
    pub format_version: i64,
    pub consumed_bytes: u64,
    pub state: Vec<u8>,
}
impl CheckpointRecord {
    pub fn decode(&self) -> Result<Checkpoint, String> {
        if self.state.len() > MAX_BLOB_BYTES {
            return Err("checkpoint blob exceeds limit".to_owned());
        }
        let reader =
            zstd::stream::read::Decoder::new(self.state.as_slice()).map_err(|e| e.to_string())?;
        let mut json = Vec::new();
        reader
            .take((MAX_DECODED_BYTES as u64).saturating_add(1))
            .read_to_end(&mut json)
            .map_err(|e| e.to_string())?;
        if json.len() > MAX_DECODED_BYTES {
            return Err("decoded checkpoint exceeds limit".to_owned());
        }
        let encoded: EncodedCheckpoint =
            serde_json::from_slice(&json).map_err(|e| e.to_string())?;
        let canonical = canonical_json(&encoded.payload).map_err(|e| e.to_string())?;
        if sha256_hex(&canonical) != encoded.digest {
            return Err("checkpoint integrity mismatch".to_owned());
        }
        let checkpoint: Checkpoint =
            serde_json::from_value(encoded.payload).map_err(|e| e.to_string())?;
        if checkpoint.harness != self.harness
            || checkpoint.source_path != self.source_path
            || checkpoint.parser_version != self.parser_version
            || checkpoint.format != self.format_version
            || checkpoint.consumed != self.consumed_bytes
        {
            return Err("checkpoint metadata disagrees with blob".to_owned());
        }
        Ok(checkpoint)
    }
}
#[derive(Clone, Debug)]
pub struct LoadedCheckpoint {
    pub checkpoint: Box<Checkpoint>,
    pub row_id: String,
    pub expected_content_hash: String,
    pub policy: ResumePolicy,
}
impl LoadedCheckpoint {
    pub fn new(checkpoint: Checkpoint, row_id: &str, expected_content_hash: &str) -> Self {
        Self {
            checkpoint: Box::new(checkpoint),
            row_id: row_id.to_owned(),
            expected_content_hash: expected_content_hash.to_owned(),
            policy: ResumePolicy::current(),
        }
    }
}
/// Only the writer receipt survives the move of decoded state into a parser job.
#[derive(Clone, Debug)]
pub struct ResumeReceipt {
    pub row_id: String,
    pub expected_content_hash: String,
    pub consumed_bytes: u64,
    pub parse_options_hash: String,
    pub closed: SessionTotals,
    pub tool_names_prefix: String,
    pub tool_prefix_count: i64,
}
impl From<&LoadedCheckpoint> for ResumeReceipt {
    fn from(loaded: &LoadedCheckpoint) -> Self {
        Self {
            row_id: loaded.row_id.clone(),
            expected_content_hash: loaded.expected_content_hash.clone(),
            consumed_bytes: loaded.checkpoint.consumed,
            parse_options_hash: loaded.checkpoint.options.digest(),
            closed: loaded.checkpoint.closed.clone(),
            tool_names_prefix: loaded.checkpoint.tool_names_prefix.clone(),
            tool_prefix_count: loaded.checkpoint.tool_prefix_count,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeltaScope {
    pub message_from: i64,
    pub tool_from: i64,
    pub tool_open: Vec<i64>,
    pub usage_from_ordinal: i64,
}
#[derive(Clone, Debug)]
pub struct SessionDelta {
    pub snapshot: SessionSnapshot,
    pub row_id: String,
    pub expected_content_hash: String,
    pub parse_options_hash: String,
    pub scope: DeltaScope,
    pub closed: SessionTotals,
    pub tool_names_prefix: String,
    pub tool_prefix_count: i64,
    pub checkpoint: Option<CheckpointRecord>,
    /// False when only an unterminated tail was read. The stored receipt must
    /// remain untouched; a changed row digest will naturally fence it out.
    pub checkpoint_advanced: bool,
}
impl SessionDelta {
    pub fn new(
        snapshot: SessionSnapshot,
        scope: DeltaScope,
        checkpoint: Option<CheckpointRecord>,
        loaded: &ResumeReceipt,
    ) -> Self {
        Self {
            checkpoint_advanced: checkpoint
                .as_ref()
                .is_none_or(|next| next.consumed_bytes > loaded.consumed_bytes),
            snapshot,
            row_id: loaded.row_id.clone(),
            expected_content_hash: loaded.expected_content_hash.clone(),
            parse_options_hash: loaded.parse_options_hash.clone(),
            scope,
            closed: loaded.closed.clone(),
            tool_names_prefix: loaded.tool_names_prefix.clone(),
            tool_prefix_count: loaded.tool_prefix_count,
            checkpoint,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SessionTotals {
    pub messages: i64,
    pub user_messages: i64,
    pub assistant_messages: i64,
    pub tool_calls: i64,
    pub user_tokens: i64,
    pub assistant_tokens: i64,
    pub tool_tokens: i64,
    pub has_error_rows: bool,
    pub has_code_blocks: bool,
}
impl SessionTotals {
    pub(crate) fn valid_counts(&self, rows: RowCounts) -> bool {
        self.messages >= 0
            && self.messages <= rows.messages
            && self.tool_calls >= 0
            && self.tool_calls <= rows.tools
            && self.user_messages >= 0
            && self.assistant_messages >= 0
            && self
                .user_messages
                .checked_add(self.assistant_messages)
                .is_some_and(|count| count <= self.messages)
    }
    pub fn add_message(&mut self, message: &MessageRecord) {
        self.messages = self.messages.wrapping_add(1);
        let tokens = Usage::from(message.usage).total_tokens().unwrap_or(0);
        match message.author_type.as_str() {
            "user" => {
                self.user_messages = self.user_messages.wrapping_add(1);
                self.user_tokens = self.user_tokens.wrapping_add(tokens);
            }
            "assistant" => {
                self.assistant_messages = self.assistant_messages.wrapping_add(1);
                self.assistant_tokens = self.assistant_tokens.wrapping_add(tokens);
            }
            "tool" => self.tool_tokens = self.tool_tokens.wrapping_add(tokens),
            _ => {}
        }
        self.has_error_rows |= message.has_error;
        self.has_code_blocks |= message.content_plain.contains("```");
    }
    pub fn add_tool(&mut self, tool: &ToolCallRecord) {
        self.tool_calls = self.tool_calls.wrapping_add(1);
        self.has_error_rows |= tool.error_message.is_some() || tool.status == "error";
    }
    pub fn from_rows(messages: &[MessageRecord], tools: &[ToolCallRecord]) -> Self {
        let mut totals = Self::default();
        for message in messages {
            totals.add_message(message);
        }
        for tool in tools {
            totals.add_tool(tool);
        }
        totals
    }
    pub fn token_buckets(&self, session_usage: UsageRecord) -> (i64, i64, i64) {
        if self
            .user_tokens
            .wrapping_add(self.assistant_tokens)
            .wrapping_add(self.tool_tokens)
            == 0
        {
            (
                session_usage.input_tokens.unwrap_or(0),
                session_usage.output_tokens.unwrap_or(0),
                0,
            )
        } else {
            (self.user_tokens, self.assistant_tokens, self.tool_tokens)
        }
    }
}

impl FingerprintWindows {
    fn valid_shape(&self, consumed: u64) -> bool {
        if self.anchors.len() > 16 {
            return false;
        }
        if consumed == 0 {
            return self.head.is_none() && self.tail.is_none() && self.anchors.is_empty();
        }
        let Some(head) = &self.head else {
            return false;
        };
        let Some(tail) = &self.tail else {
            return false;
        };
        head.offset == 0
            && head.length == consumed.min(HEAD_BYTES as u64)
            && tail.length == consumed.min(TAIL_BYTES as u64)
            && Some(tail.offset) == consumed.checked_sub(tail.length)
            && self.anchors.iter().all(|w| {
                w.length == ANCHOR_BYTES as u64
                    && w.offset
                        .checked_add(w.length)
                        .is_some_and(|end| end <= consumed)
            })
    }
    /// Use the same handle subsequently parsed. Never hash a second read of new data.
    pub(crate) fn validate(
        &self,
        reader: &mut SourceReader,
        consumed: u64,
    ) -> std::io::Result<Option<(Vec<u8>, Vec<u8>)>> {
        if !self.valid_shape(consumed) {
            return Ok(None);
        }
        let mut tail = Vec::new();
        let mut head = Vec::new();
        for window in self
            .head
            .iter()
            .chain(self.anchors.iter())
            .chain(self.tail.iter())
        {
            reader.seek(SeekFrom::Start(window.offset))?;
            let Ok(length) = usize::try_from(window.length) else {
                return Ok(None);
            };
            let mut bytes = vec![0; length];
            if let Err(error) = reader.read_exact(&mut bytes) {
                if error.kind() == std::io::ErrorKind::UnexpectedEof {
                    return Ok(None);
                }
                return Err(error);
            }
            if sha256_hex(&bytes) != window.sha256 {
                return Ok(None);
            }
            if consumed < HEAD_BYTES as u64 && self.head.as_ref() == Some(window) {
                head = bytes.clone();
            }
            if self.tail.as_ref() == Some(window) {
                tail = bytes;
            }
        }
        if consumed != 0 && tail.last() != Some(&b'\n') {
            return Ok(None);
        }
        reader.seek(SeekFrom::Start(consumed))?;
        Ok(Some((tail, head)))
    }
}

/// Windows are captured from completed segments, excluding the partial final segment.
pub(crate) struct WindowCapture {
    consumed: u64,
    head: Vec<u8>,
    head_window: Option<FingerprintWindow>,
    anchors: Vec<FingerprintWindow>,
    pending: Vec<(u64, Vec<u8>)>,
    tail: Vec<u8>,
}
impl WindowCapture {
    pub(crate) fn fresh(size: u64) -> Self {
        let pending = (1u128..=8)
            .filter_map(|k| {
                let anchor = u128::try_from(ANCHOR_BYTES).ok()?;
                let offset = u128::from(size)
                    .checked_mul(k)?
                    .checked_div(9)?
                    .checked_div(anchor)?
                    .checked_mul(anchor)?;
                Some((u64::try_from(offset).ok()?, Vec::new()))
            })
            .collect();
        Self {
            consumed: 0,
            head: Vec::new(),
            head_window: None,
            anchors: Vec::new(),
            pending,
            tail: Vec::new(),
        }
    }
    pub(crate) fn resumed(checkpoint: &Checkpoint, tail: Vec<u8>, head: Vec<u8>) -> Option<Self> {
        let mut anchors = checkpoint.windows.anchors.clone();
        if tail.len() >= ANCHOR_BYTES {
            let window = FingerprintWindow::from_bytes(
                checkpoint.consumed.checked_sub(ANCHOR_BYTES as u64)?,
                tail.get(tail.len().checked_sub(ANCHOR_BYTES)?..)?,
            )?;
            if !anchors.iter().any(|old| old.offset == window.offset) {
                anchors.push(window);
            }
        }
        if anchors.len() > 16 {
            anchors = anchors.into_iter().step_by(2).collect();
        }
        Some(Self {
            consumed: checkpoint.consumed,
            head,
            head_window: checkpoint.windows.head.clone(),
            anchors,
            pending: Vec::new(),
            tail,
        })
    }
    pub(crate) fn push(&mut self, bytes: &[u8]) -> Option<()> {
        let start = self.consumed;
        let end = start.checked_add(u64::try_from(bytes.len()).ok()?)?;
        if start < HEAD_BYTES as u64 {
            self.head.extend_from_slice(
                bytes.get(
                    ..bytes
                        .len()
                        .min(HEAD_BYTES.checked_sub(usize::try_from(start).ok()?)?),
                )?,
            );
        }
        for (offset, captured) in &mut self.pending {
            let from = start.max(*offset);
            let to = end.min(offset.checked_add(ANCHOR_BYTES as u64)?);
            if to > from {
                let from = usize::try_from(from.checked_sub(start)?).ok()?;
                let to = usize::try_from(to.checked_sub(start)?).ok()?;
                captured.extend_from_slice(bytes.get(from..to)?);
            }
        }
        if bytes.len() >= TAIL_BYTES {
            self.tail = bytes.get(bytes.len().checked_sub(TAIL_BYTES)?..)?.to_vec();
        } else {
            let excess = self
                .tail
                .len()
                .checked_add(bytes.len())?
                .saturating_sub(TAIL_BYTES);
            if excess > self.tail.len() {
                return None;
            }
            self.tail.drain(..excess);
            self.tail.extend_from_slice(bytes);
        }
        self.consumed = end;
        Some(())
    }
    pub(crate) fn consumed(&self) -> u64 {
        self.consumed
    }
    pub(crate) fn finish(&self) -> Option<FingerprintWindows> {
        let head = if self.head.is_empty() {
            self.head_window.clone()
        } else {
            Some(FingerprintWindow::from_bytes(0, &self.head)?)
        };
        let mut anchors = self.anchors.clone();
        for (offset, bytes) in &self.pending {
            if bytes.len() == ANCHOR_BYTES && !anchors.iter().any(|w| w.offset == *offset) {
                anchors.push(FingerprintWindow::from_bytes(*offset, bytes)?);
            }
        }
        let tail = if self.tail.is_empty() {
            None
        } else {
            Some(FingerprintWindow::from_bytes(
                self.consumed
                    .checked_sub(u64::try_from(self.tail.len()).ok()?)?,
                &self.tail,
            )?)
        };
        Some(FingerprintWindows {
            head,
            anchors,
            tail,
        })
    }
}

pub(crate) struct SourceReader(
    File,
    #[cfg(feature = "test-hooks")] Option<std::rc::Rc<Cell<u64>>>,
);
impl SourceReader {
    pub(crate) fn open(path: &str) -> std::io::Result<Self> {
        #[cfg(not(feature = "test-hooks"))]
        {
            File::open(path).map(Self)
        }
        #[cfg(feature = "test-hooks")]
        {
            let file = File::open(path)?;
            Ok(Self(
                file,
                READERS.with(|readers| {
                    readers.borrow_mut().as_mut().map(|readers| {
                        let bytes = std::rc::Rc::new(Cell::new(0));
                        readers.push(bytes.clone());
                        bytes
                    })
                }),
            ))
        }
    }
}
impl Read for SourceReader {
    fn read(&mut self, bytes: &mut [u8]) -> std::io::Result<usize> {
        #[cfg(feature = "test-hooks")]
        BEFORE_READ.with(|hook| {
            let callback = hook.borrow_mut().take();
            if let Some(callback) = callback {
                callback();
            }
        });
        let count = self.0.read(bytes)?;
        #[cfg(feature = "test-hooks")]
        READ_BYTES.set(
            READ_BYTES
                .get()
                .saturating_add(u64::try_from(count).unwrap_or(u64::MAX)),
        );
        #[cfg(feature = "test-hooks")]
        if let Some(bytes) = &self.1 {
            bytes.set(
                bytes
                    .get()
                    .saturating_add(u64::try_from(count).unwrap_or(u64::MAX)),
            );
        }
        Ok(count)
    }
}

#[cfg(feature = "test-hooks")]
thread_local! {
    static BEFORE_READ: std::cell::RefCell<Option<Box<dyn FnOnce()>>> = const { std::cell::RefCell::new(None) };
}
/// One-shot, thread-local hook after the size snapshot and before source I/O.
#[cfg(feature = "test-hooks")]
pub struct BeforeReadScope(
    Option<Box<dyn FnOnce()>>,
    std::marker::PhantomData<std::rc::Rc<()>>,
);
#[cfg(feature = "test-hooks")]
impl BeforeReadScope {
    pub fn enter(callback: impl FnOnce() + 'static) -> Self {
        Self(
            BEFORE_READ.with(|hook| hook.replace(Some(Box::new(callback)))),
            std::marker::PhantomData,
        )
    }
}
#[cfg(feature = "test-hooks")]
impl Drop for BeforeReadScope {
    fn drop(&mut self) {
        BEFORE_READ.with(|hook| hook.replace(self.0.take()));
    }
}
impl Seek for SourceReader {
    fn seek(&mut self, position: SeekFrom) -> std::io::Result<u64> {
        self.0.seek(position)
    }
}
#[cfg(feature = "test-hooks")]
thread_local! {
    static READ_BYTES: Cell<u64> = const { Cell::new(0) };
    static READERS: std::cell::RefCell<Option<Vec<std::rc::Rc<Cell<u64>>>>> = const { std::cell::RefCell::new(None) };
}
#[cfg(feature = "test-hooks")]
pub struct ReadCounterScope(u64, Option<Vec<std::rc::Rc<Cell<u64>>>>);
#[cfg(feature = "test-hooks")]
impl ReadCounterScope {
    pub fn enter() -> Self {
        Self(
            READ_BYTES.replace(0),
            READERS.with(|readers| readers.replace(Some(Vec::new()))),
        )
    }
    pub fn bytes(&self) -> u64 {
        READ_BYTES.get()
    }
    /// Actual bytes per opened reader, in open order, including zero-read
    /// attempts. Separate counters keep nested injected parses attributable.
    pub fn reader_bytes(&self) -> Vec<u64> {
        READERS.with(|readers| {
            readers
                .borrow()
                .iter()
                .flatten()
                .map(|bytes| bytes.get())
                .collect()
        })
    }
}
#[cfg(feature = "test-hooks")]
impl Drop for ReadCounterScope {
    fn drop(&mut self) {
        READ_BYTES.set(self.0);
        READERS.with(|readers| readers.replace(self.1.take()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn checkpoint_observer_only_abandons_restored_structure() {
        assert!(matches!(
            observe_checkpoint(Err(BuildFailed), false),
            Ok(None)
        ));
        assert!(matches!(
            observe_checkpoint(Err(BuildFailed), true),
            Err(AbandonReason::Structure)
        ));
    }
}
