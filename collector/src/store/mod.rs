//! The single persistence path for collected records.

pub mod cache_repair;
pub mod projects;
pub mod schema;
pub mod writer;

use std::path::Path;

use rusqlite::{Connection, OpenFlags};

use crate::contract::{Envelope, Record};

pub use schema::{OwnerMode, StoreError, StoreResult};

pub struct Store {
    pub conn: Connection,
    pub path: String,
    pub mode: OwnerMode,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ApplySummary {
    pub sessions: usize,
    pub statuses: usize,
    pub thread_names_changed: usize,
    pub project_updates: usize,
}

impl ApplySummary {
    pub fn add(&mut self, other: &Self) {
        self.sessions += other.sessions;
        self.statuses += other.statuses;
        self.thread_names_changed += other.thread_names_changed;
        self.project_updates += other.project_updates;
    }
}

impl Store {
    /// Open a database this collector may write in `mode`, creating a
    /// standalone database when needed. Never creates a viewer database.
    pub fn open(path: &Path, mode: OwnerMode) -> StoreResult<Self> {
        let display = path.display().to_string();
        let conn = match mode {
            OwnerMode::Viewer => {
                if !path.is_file() {
                    return Err(StoreError::Refused(format!(
                        "No viewer database at {display}. Start the viewer once to create it, or collect with --standalone into a database of the collector's own."
                    )));
                }
                Connection::open_with_flags(
                    path,
                    OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
                )?
            }
            OwnerMode::Standalone => {
                if let Some(parent) = path.parent()
                    && !parent.as_os_str().is_empty()
                {
                    std::fs::create_dir_all(parent)?;
                }
                Connection::open(path)?
            }
        };
        // Tests shorten the wait to prove a busy database fails cleanly.
        let busy_timeout = std::env::var("CODEX_SESSIONS_COLLECTOR_BUSY_TIMEOUT_MS")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(schema::BUSY_TIMEOUT_MS);
        schema::configure(&conn, busy_timeout)?;
        if mode == OwnerMode::Standalone {
            schema::prepare_standalone(&conn, &display)?;
        }
        schema::check_writable(&conn, mode, &display)?;
        Ok(Self {
            conn,
            path: display,
            mode,
        })
    }

    pub fn machine_id(&self) -> StoreResult<Option<String>> {
        schema::metadata(&self.conn, "machine_id")
    }

    /// Apply contract records in order. Consecutive records of one kind are
    /// committed together, like the viewer's scan batches.
    pub fn apply(&self, records: Vec<Envelope>) -> StoreResult<ApplySummary> {
        let mut summary = ApplySummary::default();
        let mut pending = Pending::default();
        for envelope in records {
            let kind = std::mem::discriminant(&envelope.record);
            if pending
                .kind
                .is_some_and(|current| current != kind || pending.version != envelope.version)
            {
                summary.add(&self.flush(&mut pending)?);
            }
            pending.kind = Some(kind);
            pending.version = envelope.version;
            match envelope.record {
                Record::SessionSnapshot(snapshot) => pending.snapshots.push(*snapshot),
                Record::SourceStatus(status) => pending.statuses.push(status),
                Record::ThreadName(name) => pending.thread_names.push(name),
                Record::ProjectHints(hints) => pending.hints.push(hints),
            }
        }
        summary.add(&self.flush(&mut pending)?);
        Ok(summary)
    }

    fn flush(&self, pending: &mut Pending) -> StoreResult<ApplySummary> {
        let mut summary = ApplySummary::default();
        if !pending.snapshots.is_empty() {
            summary.sessions = writer::apply_session_batch_versioned(
                &self.conn,
                std::mem::take(&mut pending.snapshots),
                Some(pending.version),
            )?;
        }
        if !pending.statuses.is_empty() {
            writer::apply_source_statuses_versioned(
                &self.conn,
                &pending.statuses,
                Some(pending.version),
            )?;
            summary.statuses = pending.statuses.len();
            pending.statuses.clear();
        }
        if !pending.thread_names.is_empty() {
            summary.thread_names_changed = writer::apply_thread_names_versioned(
                &self.conn,
                &pending.thread_names,
                Some(pending.version),
            )?;
            pending.thread_names.clear();
        }
        for hints in pending.hints.drain(..) {
            summary.project_updates += writer::apply_project_hints_versioned(
                &self.conn,
                &hints.harness,
                &hints.sessions,
                &hints.hints,
                Some(pending.version),
            )?;
        }
        pending.kind = None;
        Ok(summary)
    }
}

#[derive(Default)]
struct Pending {
    version: u32,
    kind: Option<std::mem::Discriminant<Record>>,
    snapshots: Vec<crate::contract::SessionSnapshot>,
    statuses: Vec<crate::contract::SourceStatus>,
    thread_names: Vec<crate::contract::ThreadName>,
    hints: Vec<crate::contract::ProjectHints>,
}
