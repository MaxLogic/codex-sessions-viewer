//! The Claude Code collector: scans `~/.claude/projects` transcripts into
//! contract records and applies them like the Codex collector.

pub mod parser;

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::sync_channel;
use std::sync::{Arc, Mutex};

use crate::codex::parser::{ParseError, SourceType, file_modified_utc};
use crate::codex::scanner::{ScanCounts, parse_error_status};
use crate::codex::{CollectReport, gated};
use crate::contract::{ProjectHint, SessionSnapshot, Source, SourceStatus};
use crate::path_mapping::{
    PathMapper, canonical_scan_path, is_path_under_root, normalize_path_key,
};
use crate::store::projects::resolve_windows_project;
use crate::store::writer::CachedSource;
use crate::store::{ApplySummary, Store, StoreResult, writer};

use parser::{CLAUDE_PARSER_VERSION, ClaudeOptions, ClaudeTranscript, HARNESS, parse_transcript};

pub const FLUSH_SESSIONS: usize = 32;
const CACHE_MODIFIED_TOLERANCE_MICROS: i64 = 2_000_000;

/// A folder holding Claude project folders (`~/.claude/projects`).
#[derive(Clone, Debug)]
pub struct ClaudeRoot {
    pub path: String,
    pub source_type: SourceType,
}

/// `<home>/.claude/projects` for the current user; see
/// [`crate::settings::DefaultFolders`].
pub fn default_root() -> Option<ClaudeRoot> {
    let path = crate::settings::DefaultFolders::current().claude_projects_root;
    (!path.is_empty()).then_some(ClaudeRoot {
        path,
        source_type: SourceType::native(),
    })
}

fn jsonl_files(folder: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(folder) else {
        return Vec::new();
    };
    let mut files: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_file()))
        .map(|entry| entry.path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "jsonl"))
        .collect();
    files.sort();
    files
}

/// Main transcripts `<root>/<project>/<session>.jsonl` and subagent
/// transcripts `<root>/<project>/<session>/subagents/*.jsonl`.
pub fn discover(root: &Path) -> Vec<PathBuf> {
    let Ok(projects) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    let mut files = Vec::new();
    let mut project_folders: Vec<PathBuf> = projects
        .filter_map(Result::ok)
        .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
        .map(|entry| entry.path())
        .collect();
    project_folders.sort();
    for project in project_folders {
        files.extend(jsonl_files(&project));
        if let Ok(children) = std::fs::read_dir(&project) {
            let mut sessions: Vec<PathBuf> = children
                .filter_map(Result::ok)
                .filter(|entry| entry.file_type().is_ok_and(|kind| kind.is_dir()))
                .map(|entry| entry.path().join("subagents"))
                .filter(|path| path.is_dir())
                .collect();
            sessions.sort();
            for subagents in sessions {
                files.extend(jsonl_files(&subagents));
            }
        }
    }
    files
}

/// Subagent transcripts that belong to the main transcript `path`.
pub fn subagent_files(path: &Path) -> Vec<PathBuf> {
    match (path.parent(), path.file_stem()) {
        (Some(folder), Some(stem)) => jsonl_files(&folder.join(stem).join("subagents")),
        _ => Vec::new(),
    }
}

fn status(
    path: &str,
    status: &str,
    source_type: SourceType,
    message: Option<String>,
) -> SourceStatus {
    SourceStatus {
        harness: HARNESS.to_owned(),
        path: path.to_owned(),
        environment: Some(source_type.wire_name().to_owned()),
        status: status.to_owned(),
        state: "active".to_owned(),
        message,
    }
}

fn is_unchanged(path: &str, cached: &HashMapCache) -> bool {
    let Some(source) = cached.get(&canonical_scan_path(path)) else {
        return false;
    };
    let (Some(size), Some(modified), Some(version)) =
        (source.file_size, source.modified_utc, source.parser_version)
    else {
        return false;
    };
    if source.scan_status != "available" || version != CLAUDE_PARSER_VERSION {
        return false;
    }
    let Ok(metadata) = std::fs::metadata(path) else {
        return false;
    };
    let Ok(current) = file_modified_utc(&metadata) else {
        return false;
    };
    metadata.len() as i64 == size
        && (current.micros() - modified.micros()).abs() <= CACHE_MODIFIED_TOLERANCE_MICROS
}

type HashMapCache = std::collections::HashMap<String, CachedSource>;

/// The contract snapshot for one parsed transcript.
pub fn snapshot(
    path: &str,
    source_type: SourceType,
    mapper: &PathMapper,
    transcript: ClaudeTranscript,
) -> SessionSnapshot {
    let mapped = match source_type {
        SourceType::Windows => mapper.map_windows_path(path),
        SourceType::Wsl => mapper.map_wsl_unc_path(path),
        native @ (SourceType::Macos | SourceType::Linux) => mapper.map_native_path(path, native),
    };
    let project_hints = match (&transcript.session.working_directory_display, source_type) {
        (Some(cwd), SourceType::Windows | SourceType::Macos | SourceType::Linux) => {
            resolve_windows_project(cwd)
                .map(|name| {
                    vec![ProjectHint {
                        working_directory: cwd.clone(),
                        project_name: name,
                    }]
                })
                .unwrap_or_default()
        }
        _ => Vec::new(),
    };
    SessionSnapshot {
        harness: HARNESS.to_owned(),
        machine_id: None,
        source: Source {
            path: path.to_owned(),
            environment: source_type.wire_name().to_owned(),
            state: "active".to_owned(),
            status: if transcript.needs_reread {
                "changed_pending_parse"
            } else {
                "available"
            }
            .to_owned(),
            size: transcript.size,
            modified_utc: transcript.modified_utc.to_iso8601(),
            display_path: mapped.display_path,
            mapped_source_file_path: mapped.source_file_path,
            unc_path: mapped.source_file_unc_path,
            platform_path: mapped.platform_path,
            normalized_path_keys: if mapped.normalized_path_keys.is_empty() {
                vec![normalize_path_key(path)]
            } else {
                mapped.normalized_path_keys
            },
        },
        session: transcript.session,
        messages: transcript.messages,
        tool_calls: transcript.tool_calls,
        usage_events: transcript.usage_events,
        project_hints,
        extra: Some(transcript.extra),
    }
}

pub struct ClaudeScanOptions {
    pub roots: Vec<ClaudeRoot>,
    pub mapper: PathMapper,
    pub parser: ClaudeOptions,
    pub workers: usize,
    pub force: bool,
    /// Ask `wsl.exe` for the project names of WSL working directories, as
    /// the Codex scan does (`--no-wsl-projects` turns it off).
    pub resolve_wsl_projects: bool,
}

type Parsed = (String, SourceType, Result<ClaudeTranscript, ParseError>);

/// Scan Claude transcripts into `store`, reparsing only changed files.
pub fn collect(store: &Store, options: &ClaudeScanOptions) -> StoreResult<CollectReport> {
    collect_coordinated(
        store,
        options,
        &Arc::new(AtomicBool::new(false)),
        |_, _| {},
        |_| Ok(true),
        FLUSH_SESSIONS,
    )
}

/// `collect` with cancellation, progress, and the GUI writer-lease gate of
/// [`crate::codex::collect_coordinated`]: every database write asks the gate
/// first, and nothing asks for a lease once the scan is cancelled.
pub fn collect_coordinated(
    store: &Store,
    options: &ClaudeScanOptions,
    cancel: &Arc<AtomicBool>,
    mut progress: impl FnMut(&ScanCounts, usize),
    mut gate: impl FnMut(bool) -> StoreResult<bool>,
    flush_sessions: usize,
) -> StoreResult<CollectReport> {
    let _wait = crate::store::write_lease::LeaseWait::enter(std::time::Duration::from_secs(600));
    let holds = crate::store::write_budget::WriteHoldScope::start();
    let is_cancelled = || cancel.load(Ordering::Relaxed);
    let cached: HashMapCache = writer::cached_sources(&store.conn, HARNESS)?
        .into_iter()
        .flat_map(|source| {
            let mut keys = vec![canonical_scan_path(&source.source_path)];
            if let Some(unc) = &source.unc_path {
                keys.push(canonical_scan_path(unc));
            }
            keys.into_iter().map(move |key| (key, source.clone()))
        })
        .collect();
    let mut counts = ScanCounts::default();
    let mut statuses = Vec::new();
    let mut errors = Vec::new();
    let mut found: HashSet<String> = HashSet::new();
    let mut work: Vec<(String, SourceType)> = Vec::new();
    let mut scanned_roots = Vec::new();
    progress(&counts, 0);
    for root in &options.roots {
        if is_cancelled() {
            break;
        }
        if !Path::new(&root.path).is_dir() {
            let entry = status(
                &root.path,
                "path_unreachable",
                root.source_type,
                Some("Claude projects folder is unreachable.".to_owned()),
            );
            errors.push(entry.clone());
            statuses.push(entry);
            counts.files_failed += 1;
            continue;
        }
        counts.directories_scanned += 1;
        scanned_roots.push(root.path.clone());
        for file in discover(Path::new(&root.path)) {
            let path = file.to_string_lossy().into_owned();
            counts.files_found += 1;
            found.insert(canonical_scan_path(&path));
            if !options.force && is_unchanged(&path, &cached) {
                counts.files_skipped += 1;
                statuses.push(status(&path, "available", root.source_type, None));
            } else {
                work.push((path, root.source_type));
            }
        }
        progress(&counts, 0);
    }

    let mut applied = ApplySummary::default();
    let queue = Mutex::new(work.into_iter());
    let workers = options.workers.max(1);
    let (sender, receiver) = sync_channel::<Parsed>(workers * 2);
    let parser_options = options.parser;
    let mut apply_error = None;
    let mut flushes = 0u64;
    std::thread::scope(|scope| {
        for _ in 0..workers {
            let sender = sender.clone();
            let queue = &queue;
            scope.spawn(move || {
                loop {
                    if cancel.load(Ordering::Relaxed) {
                        return;
                    }
                    let next = queue.lock().ok().and_then(|mut items| items.next());
                    let Some((path, source_type)) = next else {
                        return;
                    };
                    let result = parse_transcript(&path, &parser_options);
                    if sender.send((path, source_type, result)).is_err() {
                        return;
                    }
                }
            });
        }
        drop(sender);
        let mut pending: Vec<SessionSnapshot> = Vec::new();
        let mut flush = |pending: Vec<SessionSnapshot>,
                         applied: &mut ApplySummary,
                         flushes: &mut u64|
         -> StoreResult<()> {
            match gated(&mut gate, || {
                writer::apply_session_batch(&store.conn, pending)
            })? {
                Some(count) => {
                    applied.sessions += count;
                    *flushes += 1;
                }
                None => cancel.store(true, Ordering::Relaxed),
            }
            Ok(())
        };
        for (path, source_type, result) in receiver.iter() {
            if apply_error.is_some() {
                continue;
            }
            match result {
                Ok(transcript) => {
                    counts.files_parsed += 1;
                    let snapshot = snapshot(&path, source_type, &options.mapper, transcript);
                    statuses.push(status(&path, &snapshot.source.status, source_type, None));
                    pending.push(snapshot);
                    if pending.len() >= flush_sessions.max(1)
                        && let Err(error) =
                            flush(std::mem::take(&mut pending), &mut applied, &mut flushes)
                    {
                        apply_error = Some(error);
                    }
                }
                Err(error) => {
                    counts.files_failed += 1;
                    let entry = status(
                        &path,
                        parse_error_status(&error),
                        source_type,
                        Some(error.display_message()),
                    );
                    errors.push(entry.clone());
                    statuses.push(entry);
                }
            }
            counts.persistence_flushes = flushes;
            progress(&counts, applied.sessions);
        }
        if apply_error.is_none()
            && !pending.is_empty()
            && let Err(error) = flush(pending, &mut applied, &mut flushes)
        {
            apply_error = Some(error);
        }
    });
    if let Some(error) = apply_error {
        return Err(error);
    }
    counts.persistence_flushes = flushes;

    // Previously collected transcripts that disappeared from a scanned root.
    // A cancelled scan did not look at every file, so it reports none.
    let mut missing_seen = HashSet::new();
    for source in cached.values() {
        if is_cancelled() {
            break;
        }
        let key = canonical_scan_path(&source.source_path);
        if found.contains(&key) || !missing_seen.insert(key.clone()) {
            continue;
        }
        if scanned_roots
            .iter()
            .any(|root| is_path_under_root(&key, root))
        {
            counts.sessions_missing += 1;
            let entry = SourceStatus {
                state: "missing".to_owned(),
                ..status(
                    &source.source_path,
                    "missing",
                    source.source_type,
                    Some("Previously collected transcript is missing.".to_owned()),
                )
            };
            errors.push(entry.clone());
            statuses.push(entry);
        }
    }
    if gated(&mut gate, || {
        writer::apply_source_statuses(&store.conn, &statuses)
    })?
    .is_some()
    {
        applied.statuses = statuses.len();
    }
    if !is_cancelled() {
        applied.project_updates +=
            crate::codex::backfill_projects(store, &mut gate, options.resolve_wsl_projects)?;
    }
    counts.cancelled = is_cancelled();
    Ok(CollectReport {
        write_hold: holds.report(),
        counts,
        applied,
        errors,
        cache_repair: None,
    })
}

/// Ingest one transcript and, for a main transcript, its subagents.
pub fn collect_file(
    store: &Store,
    path: &Path,
    source_type: SourceType,
    mapper: &PathMapper,
    options: &ClaudeOptions,
) -> StoreResult<CollectReport> {
    let _lease = crate::store::write_lease::WriteLease::acquire(&store.conn)?;
    let holds = crate::store::write_budget::WriteHoldScope::start();
    let mut files = vec![path.to_path_buf()];
    files.extend(subagent_files(path));
    let mut counts = ScanCounts::default();
    let mut statuses = Vec::new();
    let mut errors = Vec::new();
    let mut snapshots = Vec::new();
    for file in files {
        let file = file.to_string_lossy().into_owned();
        counts.files_found += 1;
        match parse_transcript(&file, options) {
            Ok(transcript) => {
                counts.files_parsed += 1;
                let snapshot = snapshot(&file, source_type, mapper, transcript);
                statuses.push(status(&file, &snapshot.source.status, source_type, None));
                snapshots.push(snapshot);
            }
            Err(error) => {
                counts.files_failed += 1;
                let entry = status(
                    &file,
                    parse_error_status(&error),
                    source_type,
                    Some(error.display_message()),
                );
                errors.push(entry.clone());
                statuses.push(entry);
            }
        }
    }
    let mut applied = ApplySummary::default();
    if !snapshots.is_empty() {
        applied.sessions = writer::apply_session_batch(&store.conn, snapshots)?;
    }
    writer::apply_source_statuses(&store.conn, &statuses)?;
    applied.statuses = statuses.len();
    Ok(CollectReport {
        write_hold: holds.report(),
        counts,
        applied,
        errors,
        cache_repair: None,
    })
}
