//! The Codex collector: parses Codex rollouts into contract records.

pub mod parser;
pub mod scanner;
pub mod session_index;
pub mod wsl;

use std::cell::Cell;
use std::collections::HashMap;
use std::sync::{Arc, atomic::AtomicBool};

use crate::contract::{
    ProjectHint, ProjectHints, SessionRef, SessionSnapshot, SourceStatus, ThreadName,
};
use crate::store::projects::resolve_windows_project;
use crate::store::{ApplySummary, Store, StoreResult, writer};

use parser::SourceType;
use parser::{ParseError, ParseSuccess, parse_file};
use scanner::{ParsedRef, ScanCounts, ScanOptions, ScanRoot};

/// Snapshots per write transaction. Small batches keep the viewer's writes
/// from waiting long behind a collector.
pub const FLUSH_SESSIONS: usize = 64;
pub const FLUSH_SOURCE_BYTES: u64 = 8 * 1024 * 1024;

#[derive(Clone, Copy)]
pub struct CollectionBatching {
    pub sessions: usize,
    pub source_bytes: u64,
}
impl Default for CollectionBatching {
    fn default() -> Self {
        Self {
            sessions: FLUSH_SESSIONS,
            source_bytes: FLUSH_SOURCE_BYTES,
        }
    }
}

#[derive(Debug, Default)]
pub struct CollectReport {
    pub counts: ScanCounts,
    pub applied: ApplySummary,
    pub errors: Vec<SourceStatus>,
}

/// Scan Codex roots into `store` in the viewer's order: parsed sessions in
/// batches, then refined project names, then file statuses, then
/// `session_index.jsonl` thread names.
pub fn collect(
    store: &Store,
    options: &ScanOptions,
    resolve_wsl_projects: bool,
) -> StoreResult<CollectReport> {
    collect_controlled(
        store,
        options,
        resolve_wsl_projects,
        &Arc::new(AtomicBool::new(false)),
        |_, _| {},
    )
}

pub fn collect_controlled(
    store: &Store,
    options: &ScanOptions,
    resolve_wsl_projects: bool,
    cancel: &Arc<AtomicBool>,
    progress: impl FnMut(&ScanCounts, usize),
) -> StoreResult<CollectReport> {
    collect_coordinated(
        store,
        options,
        resolve_wsl_projects,
        cancel,
        progress,
        |_| Ok(()),
        CollectionBatching::default(),
    )
}

/// A GUI may grant each write batch through its own maintenance scheduler.
/// `gate(true)` acquires a lease; `gate(false)` releases it even on failure.
pub fn collect_coordinated(
    store: &Store,
    options: &ScanOptions,
    resolve_wsl_projects: bool,
    cancel: &Arc<AtomicBool>,
    mut progress: impl FnMut(&ScanCounts, usize),
    mut gate: impl FnMut(bool) -> StoreResult<()>,
    batching: CollectionBatching,
) -> StoreResult<CollectReport> {
    gated(&mut gate, || {
        writer::clean_session_metadata_placeholders(&store.conn)
    })?;
    let cached = writer::cached_sources(&store.conn, "codex")?;
    let mut pending: Vec<SessionSnapshot> = Vec::new();
    let mut pending_bytes = 0u64;
    let mut applied = ApplySummary::default();
    let committed = Cell::new(0);
    let flushes = Cell::new(0u64);
    let mut outcome = scanner::scan_controlled(
        options,
        &cached,
        |snapshot| {
            pending_bytes += snapshot.source.size;
            pending.push(snapshot);
            if pending.len() >= batching.sessions.max(1)
                || pending_bytes >= batching.source_bytes.max(1)
            {
                applied.sessions += gated(&mut gate, || {
                    writer::apply_session_batch(&store.conn, std::mem::take(&mut pending))
                })?;
                committed.set(applied.sessions);
                flushes.set(flushes.get() + 1);
                pending_bytes = 0;
            }
            Ok::<(), crate::store::StoreError>(())
        },
        cancel,
        |counts| {
            let mut counts = counts.clone();
            counts.persistence_flushes = flushes.get();
            progress(&counts, committed.get());
        },
    )?;
    if !pending.is_empty() {
        applied.sessions += gated(&mut gate, || {
            writer::apply_session_batch(&store.conn, pending)
        })?;
        flushes.set(flushes.get() + 1);
    }
    outcome.counts.persistence_flushes = flushes.get();
    let hints = refined_project_hints(&outcome.parsed, resolve_wsl_projects);
    applied.project_updates += gated(&mut gate, || {
        writer::apply_project_hints(&store.conn, &hints.harness, &hints.sessions, &hints.hints)
    })?;
    gated(&mut gate, || {
        writer::apply_source_statuses(&store.conn, &outcome.statuses)
    })?;
    applied.statuses = outcome.statuses.len();
    let names: Vec<ThreadName> = thread_name_records(&options.thread_names);
    applied.thread_names_changed = gated(&mut gate, || {
        writer::apply_thread_names(&store.conn, &names)
    })?;
    outcome.counts.cancelled |= cancel.load(std::sync::atomic::Ordering::Relaxed);
    Ok(CollectReport {
        counts: outcome.counts,
        applied,
        errors: outcome.errors,
    })
}

fn gated<T>(
    gate: &mut impl FnMut(bool) -> StoreResult<()>,
    write: impl FnOnce() -> StoreResult<T>,
) -> StoreResult<T> {
    gate(true)?;
    let result = write();
    let released = gate(false);
    match result {
        Ok(value) => {
            released?;
            Ok(value)
        }
        Err(error) => Err(error),
    }
}

pub fn thread_name_records(
    names: &HashMap<String, session_index::ThreadNameEntry>,
) -> Vec<ThreadName> {
    let mut records: Vec<ThreadName> = names
        .values()
        .map(|entry| ThreadName {
            harness: "codex".to_owned(),
            session_id: entry.id.clone(),
            thread_name: entry.thread_name.clone(),
        })
        .collect();
    records.sort_by(|left, right| left.session_id.cmp(&right.session_id));
    records
}

/// `_applyResolvedProjectsForParsedCandidates`: names for every parsed
/// session's working directory, with WSL names from `git` inside WSL.
pub fn refined_project_hints(parsed: &[ParsedRef], resolve_wsl_projects: bool) -> ProjectHints {
    let mut hints: Vec<ProjectHint> = Vec::new();
    let mut seen: HashMap<String, ()> = HashMap::new();
    let mut wsl_paths: Vec<String> = Vec::new();
    for session in parsed {
        let Some(directory) = session.working_directory.as_deref() else {
            continue;
        };
        let path = crate::dart::trim(directory).to_owned();
        if path.is_empty() {
            continue;
        }
        match session.source_type {
            SourceType::Windows => {
                if seen.insert(format!("windows|{path}"), ()).is_none()
                    && let Some(name) = resolve_windows_project(&path)
                {
                    hints.push(ProjectHint {
                        working_directory: path,
                        project_name: name,
                    });
                }
            }
            SourceType::Wsl => {
                if seen.insert(format!("wsl|{path}"), ()).is_none() {
                    wsl_paths.push(path);
                }
            }
        }
    }
    if resolve_wsl_projects {
        for (path, name) in wsl::resolve_project_names(&wsl_paths) {
            hints.push(ProjectHint {
                working_directory: path,
                project_name: name,
            });
        }
    }
    ProjectHints {
        harness: "codex".to_owned(),
        sessions: parsed
            .iter()
            .map(|session| SessionRef {
                session_id: session.session_id.clone(),
                source_path: session.source_path.clone(),
            })
            .collect(),
        hints,
    }
}

pub fn scanner_status_for(error: &ParseError) -> &'static str {
    scanner::parse_error_status(error)
}

/// The snapshot for one parsed file under `root`.
pub fn snapshot_for(
    options: &ScanOptions,
    root: &ScanRoot,
    success: &ParseSuccess,
) -> SessionSnapshot {
    scanner::build_snapshot(
        options,
        &root.path,
        root.source_type,
        root.source_state,
        success,
        &mut HashMap::new(),
    )
}

/// Ingest one Codex file, as if a scan had found only that file changed.
pub fn collect_file(
    store: &Store,
    options: &ScanOptions,
    root: &ScanRoot,
    resolve_wsl_projects: bool,
) -> StoreResult<CollectReport> {
    writer::clean_session_metadata_placeholders(&store.conn)?;
    let mut counts = ScanCounts {
        files_found: 1,
        ..ScanCounts::default()
    };
    let mut applied = ApplySummary::default();
    let mut errors = Vec::new();
    let status = match parse_file(&root.path, options.parser) {
        Ok(success) => {
            counts.files_parsed = 1;
            let snapshot = snapshot_for(options, root, &success);
            let status = SourceStatus {
                harness: "codex".to_owned(),
                path: root.path.clone(),
                status: snapshot.source.status.clone(),
                state: root.source_state.to_owned(),
                message: None,
            };
            let parsed = ParsedRef {
                session_id: success.session.session_id.clone(),
                source_path: root.path.clone(),
                working_directory: success.session.working_directory_display.clone(),
                source_type: root.source_type,
            };
            let session_id = success.session.session_id.clone();
            applied.sessions = writer::apply_session_batch(&store.conn, vec![snapshot])?;
            let hints = refined_project_hints(std::slice::from_ref(&parsed), resolve_wsl_projects);
            applied.project_updates = writer::apply_project_hints(
                &store.conn,
                &hints.harness,
                &hints.sessions,
                &hints.hints,
            )?;
            if let Some(id) = session_id
                && let Some(entry) = options.thread_names.get(crate::dart::trim(&id))
            {
                applied.thread_names_changed = writer::apply_thread_names(
                    &store.conn,
                    &[ThreadName {
                        harness: "codex".to_owned(),
                        session_id: entry.id.clone(),
                        thread_name: entry.thread_name.clone(),
                    }],
                )?;
            }
            status
        }
        Err(error) => {
            counts.files_failed = 1;
            let status = SourceStatus {
                harness: "codex".to_owned(),
                path: root.path.clone(),
                status: scanner::parse_error_status(&error).to_owned(),
                state: root.source_state.to_owned(),
                message: Some(error.display_message()),
            };
            errors.push(status.clone());
            status
        }
    };
    writer::apply_source_statuses(&store.conn, std::slice::from_ref(&status))?;
    applied.statuses = 1;
    Ok(CollectReport {
        counts,
        applied,
        errors,
    })
}
