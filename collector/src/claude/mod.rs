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

use crate::resume::{Resume, SessionDelta};
use crate::store::checkpoints;
use parser::{
    CLAUDE_PARSER_VERSION, ClaudeOptions, ClaudeTranscript, HARNESS, parse_transcript_with,
};

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

fn is_unchanged_with(path: &str, cached: &HashMapCache, allow_pending: bool) -> bool {
    let Some(source) = cached.get(&canonical_scan_path(path)) else {
        return false;
    };
    let (Some(size), Some(modified), Some(version)) =
        (source.file_size, source.modified_utc, source.parser_version)
    else {
        return false;
    };
    if (source.scan_status != "available"
        && !(allow_pending && source.scan_status == "changed_pending_parse"))
        || version != CLAUDE_PARSER_VERSION
    {
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

type Parsed = (
    String,
    SourceType,
    Result<parser::ClaudeParse, ParseError>,
    Option<crate::resume::ResumeReceipt>,
);
type PreparedTranscript = (
    String,
    SourceType,
    parser::ClaudeParse,
    Option<crate::resume::ResumeReceipt>,
);

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
    let loaded = writer::cached_sources(&store.conn, HARNESS)?;
    let status_index = writer::StatusIndex::new(&loaded);
    let checkpoint_index = checkpoints::index(&store.conn, HARNESS)?;
    let options_hash = crate::resume::CheckpointOptions::from(options.parser).digest();
    let policy = crate::resume::ResumePolicy::current();
    let mut remaining = crate::resume::MAX_DECODED_BYTES;
    let cached: HashMapCache = loaded
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
    let mut work: Vec<(String, SourceType, Resume)> = Vec::new();
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
            let checkpoint = checkpoint_index.get(&canonical_scan_path(&path));
            let same_revision = is_unchanged_with(&path, &cached, true);
            // No checkpoint preserves the pre-existing scan limitation: an
            // option change alone does not reparse an unchanged legacy session.
            let options_changed = checkpoint
                .is_some_and(|cp| cp.parse_options_hash.as_deref() != Some(options_hash.as_str()));
            let settle = same_revision && checkpoint.is_some_and(|c| c.steps_since_full > 0);
            let unchanged = is_unchanged_with(
                &path,
                &cached,
                checkpoint.is_some_and(|c| c.steps_since_full == 0),
            );
            if !options.force && unchanged && !settle && !options_changed {
                counts.files_skipped += 1;
                let status_name = cached
                    .get(&canonical_scan_path(&path))
                    .map_or("available", |c| c.scan_status.as_str());
                statuses.push(status(&path, status_name, root.source_type, None));
            } else {
                let resume = if options.force || settle || options_changed {
                    Resume::Fresh(policy)
                } else {
                    checkpoints::load_bounded(&store.conn, HARNESS, &path, policy, &mut remaining)?
                        .map_or(Resume::Fresh(policy), Resume::From)
                };
                work.push((path, root.source_type, resume));
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
                    let Some((path, source_type, resume)) = next else {
                        return;
                    };
                    let loaded = match &resume {
                        Resume::From(cp) => Some(crate::resume::ResumeReceipt::from(cp)),
                        _ => None,
                    };
                    let mut phases = crate::timing::Phases::start();
                    let result = parse_transcript_with(&path, &parser_options, resume);
                    if let Ok(parsed) = &result {
                        phases.mark(&format!("parse {:?}", parsed.outcome));
                    }
                    if sender.send((path, source_type, result, loaded)).is_err() {
                        return;
                    }
                }
            });
        }
        drop(sender);
        let mut pending: Vec<PreparedTranscript> = Vec::new();
        let mut flush = |pending: Vec<PreparedTranscript>,
                         applied: &mut ApplySummary,
                         flushes: &mut u64|
         -> StoreResult<()> {
            match gated(&mut gate, || {
                apply_parsed_batch(store, &options.mapper, &parser_options, pending)
            })? {
                Some(count) => {
                    applied.sessions += count;
                    *flushes += 1;
                }
                None => cancel.store(true, Ordering::Relaxed),
            }
            Ok(())
        };
        for (path, source_type, result, loaded) in receiver.iter() {
            if apply_error.is_some() {
                continue;
            }
            match result {
                Ok(parsed) => {
                    counts.files_parsed += 1;
                    let status_name = if parsed.success.needs_reread {
                        "changed_pending_parse"
                    } else {
                        "available"
                    };
                    statuses.push(status(&path, status_name, source_type, None));
                    pending.push((path, source_type, parsed, loaded));
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
    // Judged against the rows loaded before the scan only when it wrote no session.
    let unchanged: Vec<bool> = if applied.sessions == 0 && flushes == 0 {
        statuses
            .iter()
            .map(|status| status_index.is_unchanged(status))
            .collect()
    } else {
        vec![false; statuses.len()]
    };
    let backfill_clear = crate::codex::backfill_clear_revision(store)?;
    if gated(&mut gate, || {
        writer::apply_scanned_source_statuses(&store.conn, &statuses, &unchanged)?;
        // As for Codex scans: unchanged scans write nothing.
        if holds.report().transactions > 0 {
            writer::record_checked_revision(
                &store.conn,
                writer::PROJECT_BACKFILL_CHECKED_KEY,
                backfill_clear,
            )?;
        }
        Ok(())
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

/// Direct hooks skip unchanged revisions; the idle scan owns the one-time
/// full convergence parse, including partial tails and missing state blobs.
fn ingest_unchanged(store: &Store, path: &str, options: &ClaudeOptions) -> StoreResult<bool> {
    let Some(source) = writer::cached_source_by_path(&store.conn, HARNESS, path)? else {
        return Ok(false);
    };
    if source.parse_options_hash.as_deref()
        != Some(
            crate::resume::CheckpointOptions::from(*options)
                .digest()
                .as_str(),
        )
    {
        return Ok(false);
    }
    let mut cache = HashMapCache::new();
    for key in std::iter::once(&source.source_path).chain(source.unc_path.as_ref()) {
        cache.insert(canonical_scan_path(key), source.clone());
    }
    Ok(is_unchanged_with(path, &cache, true))
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
    let mut parsed_files = Vec::new();
    let mut phases = crate::timing::Phases::start();
    for file in files {
        let file = file.to_string_lossy().into_owned();
        counts.files_found += 1;
        if ingest_unchanged(store, &file, options)? {
            counts.files_skipped += 1;
            continue;
        }
        let resume = checkpoints::resume(&store.conn, HARNESS, &file, false)?;
        phases.mark("load checkpoint");
        let loaded = match &resume {
            Resume::From(cp) => Some(crate::resume::ResumeReceipt::from(cp)),
            _ => None,
        };
        match parse_transcript_with(&file, options, resume) {
            Ok(parsed) => {
                phases.mark(&format!("parse {:?}", parsed.outcome));
                let transcript = &parsed.success;
                counts.files_parsed += 1;
                let status_name = if transcript.needs_reread {
                    "changed_pending_parse"
                } else {
                    "available"
                };
                statuses.push(status(&file, status_name, source_type, None));
                parsed_files.push((file, source_type, parsed, loaded));
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
    let mut applied = ApplySummary {
        sessions: apply_parsed_batch(store, mapper, options, parsed_files)?,
        ..ApplySummary::default()
    };
    phases.mark("write session");
    phases.mark("project hints");
    writer::apply_source_statuses(&store.conn, &statuses)?;
    phases.mark("statuses");
    applied.statuses = statuses.len();
    Ok(CollectReport {
        write_hold: holds.report(),
        counts,
        applied,
        errors,
        cache_repair: None,
    })
}

/// Receipts and child rows share one transaction; stale deltas restart from byte 0.
fn apply_parsed_batch(
    store: &Store,
    mapper: &PathMapper,
    options: &ClaudeOptions,
    items: Vec<PreparedTranscript>,
) -> StoreResult<usize> {
    let mut snapshots = Vec::new();
    let mut records = std::collections::HashMap::new();
    let mut deltas = Vec::new();
    for (path, source_type, parsed, loaded) in items {
        let snapshot = snapshot(&path, source_type, mapper, parsed.success);
        if let Some((scope, loaded)) = parsed.scope.zip(loaded.as_ref()) {
            deltas.push(SessionDelta::new(
                snapshot,
                scope,
                parsed.checkpoint,
                loaded,
            ));
        } else {
            if let Some(record) = parsed.checkpoint {
                records.insert(path, record);
            }
            snapshots.push(snapshot);
        }
    }
    let sources: Vec<_> = deltas
        .iter()
        .map(|delta| delta.snapshot.source.clone())
        .collect();
    let outcomes = writer::apply_session_deltas(&store.conn, deltas)?;
    let mut count = 0;
    for (source, outcome) in sources.into_iter().zip(outcomes) {
        if outcome == writer::DeltaOutcome::Applied {
            count += 1;
            continue;
        }
        let path = source.path;
        let source_type = SourceType::from_wire(&source.environment).unwrap_or(SourceType::Windows);
        let parsed = parse_transcript_with(
            &path,
            options,
            Resume::Fresh(crate::resume::ResumePolicy::current()),
        )
        .map_err(|e| crate::store::StoreError::Refused(e.display_message()))?;
        if let Some(record) = parsed.checkpoint {
            records.insert(path.clone(), record);
        }
        snapshots.push(snapshot(&path, source_type, mapper, parsed.success));
    }
    if !snapshots.is_empty() {
        count += writer::apply_session_batch_with_checkpoints(
            &store.conn,
            snapshots,
            records,
            Some((*options).into()),
        )?;
    }
    Ok(count)
}
