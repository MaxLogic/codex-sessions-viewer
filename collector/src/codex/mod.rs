//! The Codex collector: parses Codex rollouts into contract records.

pub mod parser;
pub mod scanner;
pub mod session_index;
pub mod wsl;

use std::cell::Cell;
use std::collections::HashMap;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};

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
    /// The legacy cache repair's outcome, when a scan ran it.
    pub cache_repair: Option<crate::store::cache_repair::RepairReport>,
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
        |_| Ok(true),
        CollectionBatching::default(),
    )
}

/// A GUI may grant each write batch through its own maintenance scheduler.
/// `gate(true)` acquires a lease and returns `false` when the scan was
/// cancelled instead, so the write is skipped; `gate(false)` releases a
/// granted lease even on failure.
///
/// After cancellation the scan writes nothing that a coordinating GUI would
/// have to grant: pending batches, statuses and refinements are left to the
/// next scan, which reparses the files.
pub fn collect_coordinated(
    store: &Store,
    options: &ScanOptions,
    resolve_wsl_projects: bool,
    cancel: &Arc<AtomicBool>,
    mut progress: impl FnMut(&ScanCounts, usize),
    mut gate: impl FnMut(bool) -> StoreResult<bool>,
    batching: CollectionBatching,
) -> StoreResult<CollectReport> {
    let is_cancelled = || cancel.load(Ordering::Relaxed);
    let mut phases = crate::timing::Phases::start();
    // Count first: a lease that would find nothing to clean only makes the
    // GUI's writers wait.
    if writer::session_metadata_placeholder_count(&store.conn)? > 0
        && gated(&mut gate, || {
            writer::clean_session_metadata_placeholders(&store.conn)
        })?
        .is_none()
    {
        cancel.store(true, Ordering::Relaxed);
    }
    phases.mark("metadata placeholders");
    let cached = writer::cached_sources(&store.conn, "codex")?;
    phases.mark("load cached sources");
    let mut pending: Vec<SessionSnapshot> = Vec::new();
    let mut pending_bytes = 0u64;
    let mut applied = ApplySummary::default();
    let committed = Cell::new(0);
    let flushes = Cell::new(0u64);
    // Started at the first WSL session and fed each parsed WSL working
    // directory, so WSL start-up and the git lookups overlap parsing.
    let mut wsl_resolver: Option<wsl::ProjectResolver> = None;
    let mut outcome = scanner::scan_controlled(
        options,
        &cached,
        |snapshot| {
            if resolve_wsl_projects
                && snapshot.source.environment == SourceType::Wsl.wire_name()
                && let Some(directory) = snapshot.session.working_directory_display.as_deref()
                && !crate::dart::trim(directory).is_empty()
            {
                wsl_resolver
                    .get_or_insert_with(wsl::ProjectResolver::for_current_platform)
                    .push(directory);
            }
            pending_bytes += snapshot.source.size;
            pending.push(snapshot);
            if pending.len() >= batching.sessions.max(1)
                || pending_bytes >= batching.source_bytes.max(1)
            {
                let batch = std::mem::take(&mut pending);
                pending_bytes = 0;
                match gated(&mut gate, || {
                    writer::apply_session_batch(&store.conn, batch)
                })? {
                    Some(written) => {
                        applied.sessions += written;
                        committed.set(applied.sessions);
                        flushes.set(flushes.get() + 1);
                    }
                    None => cancel.store(true, Ordering::Relaxed),
                }
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
    if !pending.is_empty()
        && let Some(written) = gated(&mut gate, || {
            writer::apply_session_batch(&store.conn, pending)
        })?
    {
        applied.sessions += written;
        flushes.set(flushes.get() + 1);
    }
    outcome.counts.persistence_flushes = flushes.get();
    phases.mark("scan and write sessions");
    if !is_cancelled() {
        let hints = refined_project_hints_with(
            &outcome.parsed,
            resolve_wsl_projects,
            wsl_resolver.take(),
            cancel,
        );
        applied.project_updates += gated(&mut gate, || {
            writer::apply_project_hints(&store.conn, &hints.harness, &hints.sessions, &hints.hints)
        })?
        .unwrap_or(0);
    }
    phases.mark("project hints");
    // Every parsed batch is already written, so a complete, uncancelled
    // discovery means every reachable file now carries this parser version.
    let complete = outcome.discovery_complete && !is_cancelled();
    if gated(&mut gate, || {
        writer::apply_source_statuses(&store.conn, &outcome.statuses)?;
        if complete {
            writer::record_complete_codex_scan(&store.conn)?;
        }
        Ok(())
    })?
    .is_some()
    {
        applied.statuses = outcome.statuses.len();
    }
    phases.mark("source statuses");
    let mut cache_repair = None;
    if !is_cancelled() {
        let names: Vec<ThreadName> = thread_name_records(&options.thread_names);
        applied.thread_names_changed = gated(&mut gate, || {
            writer::apply_thread_names(&store.conn, &names)
        })?
        .unwrap_or(0);
        phases.mark("thread names");
        applied.project_updates += backfill_projects(store, &mut gate, resolve_wsl_projects)?;
        phases.mark("project backfill");
        // Only unreachable or unlisted roots make discovery incomplete; a
        // file that fails to parse under a reachable root does not.
        let discovery_complete = outcome.discovery_complete;
        if !is_cancelled() {
            cache_repair = Some(crate::store::cache_repair::run(
                store,
                &options.roots,
                discovery_complete,
                cancel,
                &mut gate,
            )?);
        }
        phases.mark("cache repair check");
    }
    outcome.counts.cancelled |= is_cancelled();
    Ok(CollectReport {
        counts: outcome.counts,
        applied,
        errors: outcome.errors,
        cache_repair,
    })
}

/// Assign automatic projects to stored sessions of any harness that still
/// have none. The viewer used to do this while loading its list; the
/// collector owns it so the viewer never writes parsed session state.
pub fn backfill_projects(
    store: &Store,
    gate: &mut impl FnMut(bool) -> StoreResult<bool>,
    resolve_wsl_projects: bool,
) -> StoreResult<usize> {
    let candidates = writer::project_backfill_candidates(&store.conn)?;
    if candidates.is_empty() {
        return Ok(0);
    }
    let mut hints: Vec<ProjectHint> = Vec::new();
    let mut seen: HashMap<String, ()> = HashMap::new();
    let mut wsl_paths: Vec<String> = Vec::new();
    for candidate in &candidates {
        let path = crate::dart::trim(&candidate.working_directory).to_owned();
        match candidate.source_type {
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
    Ok(gated(gate, || writer::apply_project_backfill(&store.conn, &hints))?.unwrap_or(0))
}

/// Run `write` under a lease. `None` means the lease was refused because the
/// scan was cancelled, so the write did not run.
pub fn gated<T>(
    gate: &mut impl FnMut(bool) -> StoreResult<bool>,
    write: impl FnOnce() -> StoreResult<T>,
) -> StoreResult<Option<T>> {
    if !gate(true)? {
        return Ok(None);
    }
    let result = write();
    let released = gate(false);
    match result {
        Ok(value) => {
            released?;
            Ok(Some(value))
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
    refined_project_hints_with(parsed, resolve_wsl_projects, None, &AtomicBool::new(false))
}

/// [`refined_project_hints`] with an already started WSL resolver, if any.
fn refined_project_hints_with(
    parsed: &[ParsedRef],
    resolve_wsl_projects: bool,
    wsl_resolver: Option<wsl::ProjectResolver>,
    cancel: &AtomicBool,
) -> ProjectHints {
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
        let resolver = wsl_resolver
            .or_else(|| (!wsl_paths.is_empty()).then(wsl::ProjectResolver::for_current_platform));
        let names = crate::timing::timed("project hints: wsl resolve", || match resolver {
            Some(resolver) => resolver.resolve(&wsl_paths, cancel, wsl::RESOLVE_TIMEOUT),
            None => HashMap::new(),
        });
        for (path, name) in names {
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

/// The project a resolver already found for a WSL session, as a hint, while
/// its working directory is unchanged. A folder-name fallback is not kept.
fn stored_wsl_project(store: &Store, parsed: &ParsedRef) -> StoreResult<Option<ProjectHint>> {
    let Some(directory) = parsed.working_directory.as_deref() else {
        return Ok(None);
    };
    if parsed.source_type != SourceType::Wsl || crate::dart::trim(directory).is_empty() {
        return Ok(None);
    }
    let session = SessionRef {
        session_id: parsed.session_id.clone(),
        source_path: parsed.source_path.clone(),
    };
    Ok(
        writer::stored_refined_project(&store.conn, &session, "codex", directory)?.map(|name| {
            ProjectHint {
                working_directory: crate::dart::trim(directory).to_owned(),
                project_name: name,
            }
        }),
    )
}

/// Ingest one Codex file, as if a scan had found only that file changed.
pub fn collect_file(
    store: &Store,
    options: &ScanOptions,
    root: &ScanRoot,
    resolve_wsl_projects: bool,
) -> StoreResult<CollectReport> {
    collect_file_with(store, options, root, |paths| {
        if resolve_wsl_projects {
            wsl::resolve_project_names(paths)
        } else {
            HashMap::new()
        }
    })
}

/// [`collect_file`] with the WSL git-root lookup supplied by the caller. It
/// runs only for a WSL session whose stored project cannot be reused, so a
/// reload does not wait for a cold WSL start (T-172).
pub fn collect_file_with(
    store: &Store,
    options: &ScanOptions,
    root: &ScanRoot,
    resolve_wsl: impl FnOnce(&[String]) -> HashMap<String, String>,
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
            // A WSL session whose working directory did not change keeps the
            // git-root project a resolver found: asking `wsl.exe` again can
            // wait ~12 s for a stopped distro to start (T-172). A changed
            // directory or a folder-name fallback is resolved again.
            let kept = stored_wsl_project(store, &parsed)?;
            applied.sessions = writer::apply_session_batch(&store.conn, vec![snapshot])?;
            let mut hints = refined_project_hints(std::slice::from_ref(&parsed), false);
            match kept {
                Some(hint) => hints.hints.push(hint),
                None => {
                    if let Some(directory) =
                        parsed.working_directory.as_deref().map(crate::dart::trim)
                        && parsed.source_type == SourceType::Wsl
                        && !directory.is_empty()
                    {
                        let names = crate::timing::timed("project hints: wsl resolve", || {
                            resolve_wsl(&[directory.to_owned()])
                        });
                        hints
                            .hints
                            .extend(names.into_iter().map(|(path, name)| ProjectHint {
                                working_directory: path,
                                project_name: name,
                            }));
                    }
                }
            }
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
        cache_repair: None,
    })
}
