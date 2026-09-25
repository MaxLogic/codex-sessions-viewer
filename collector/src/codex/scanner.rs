//! Codex session discovery and parallel parsing, originally ported from the
//! viewer's retired Dart scanner.
//!
//! Folders are listed by a small thread pool; skip decisions run on the
//! calling thread. Changed files are
//! parsed by a fixed pool of worker threads connected through bounded
//! channels, so memory stays proportional to the pool, not to the history.
//! Parsed sessions reach the caller's sink in completion order; the sink
//! persists them in small batches.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use crate::codex::parser::{
    ParseError, ParseErrorKind, ParseSuccess, ParserOptions, SourceType, parse_file,
};
use crate::codex::session_index::ThreadNameEntry;
use crate::contract::{CodexSource, ProjectHint, SessionSnapshot, SourceStatus, codex_snapshot};
use crate::dart::{to_lower, trim};
use crate::path_mapping::{
    PathMapper, basename, canonical_scan_path, dirname, is_path_under_root, join,
    normalize_windows_path,
};
use crate::store::projects::resolve_windows_project;
use crate::store::writer::CachedSource;

pub const CACHE_MODIFIED_TOLERANCE_MICROS: i64 = 2_000_000;

pub const DEFAULT_WSL_ROOT_RETRY_DELAYS: [Duration; 5] = [
    Duration::from_secs(1),
    Duration::from_secs(2),
    Duration::from_secs(4),
    Duration::from_secs(8),
    Duration::from_secs(15),
];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScanRoot {
    pub path: String,
    pub availability_root_path: Option<String>,
    pub source_type: SourceType,
    /// `active` or `codex_archived`.
    pub source_state: &'static str,
}

/// `_sessionScanRoots`: a Codex home scans `sessions` and `archived_sessions`;
/// any other folder is scanned as active sessions.
pub fn session_scan_roots(configured_path: &str, source_type: SourceType) -> Vec<ScanRoot> {
    let trimmed = trim(configured_path);
    if trimmed.is_empty() {
        return Vec::new();
    }
    let normalized = normalize_windows_path(trimmed);
    let leaf = to_lower(basename(&normalized));
    let is_named_root = leaf == "sessions" || leaf == "archived_sessions";
    let codex_root = if is_named_root {
        dirname(&normalized)
    } else {
        normalized.clone()
    };
    let active = join(&codex_root, "sessions");
    let archived = join(&codex_root, "archived_sessions");
    let is_codex_root = is_named_root
        || leaf == ".codex"
        || Path::new(&active).is_dir()
        || Path::new(&archived).is_dir();
    if !is_codex_root {
        return vec![ScanRoot {
            path: normalized,
            availability_root_path: None,
            source_type,
            source_state: "active",
        }];
    }
    vec![
        ScanRoot {
            path: active,
            availability_root_path: Some(codex_root.clone()),
            source_type,
            source_state: "active",
        },
        ScanRoot {
            path: archived,
            availability_root_path: Some(codex_root),
            source_type,
            source_state: "codex_archived",
        },
    ]
}

#[derive(Clone, Debug)]
pub struct ScanOptions {
    pub roots: Vec<ScanRoot>,
    pub mapper: PathMapper,
    pub parser: ParserOptions,
    pub parser_workers: usize,
    pub wsl_root_retry_delays: Vec<Duration>,
    pub thread_names: HashMap<String, ThreadNameEntry>,
    /// Parse even unchanged files (a full reparse).
    pub force: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize)]
pub struct ScanCounts {
    pub cancelled: bool,
    pub persistence_flushes: u64,
    pub directories_scanned: u64,
    pub files_found: u64,
    pub files_skipped: u64,
    pub files_parsed: u64,
    pub files_failed: u64,
    pub sessions_missing: u64,
}

/// A parsed session, for the post-scan project pass.
#[derive(Clone, Debug)]
pub struct ParsedRef {
    pub session_id: Option<String>,
    pub source_path: String,
    pub working_directory: Option<String>,
    pub source_type: SourceType,
}

#[derive(Debug, Default)]
pub struct ScanOutcome {
    pub counts: ScanCounts,
    pub statuses: Vec<SourceStatus>,
    pub parsed: Vec<ParsedRef>,
    pub errors: Vec<SourceStatus>,
    /// Every configured root's owner was reachable and listed completely,
    /// and the scan was not cancelled. Files that fail to parse do not
    /// make discovery incomplete.
    pub discovery_complete: bool,
}

struct Candidate {
    path: String,
    source_type: SourceType,
    source_state: &'static str,
    /// From the directory listing. On Windows the listing already carries
    /// size and modification time, so no further request per file is made,
    /// which matters for `\wsl.localhost` paths.
    metadata: Option<std::fs::Metadata>,
}

fn status(path: &str, status: &str, state: &str, message: Option<String>) -> SourceStatus {
    SourceStatus {
        harness: "codex".to_owned(),
        path: path.to_owned(),
        status: status.to_owned(),
        state: state.to_owned(),
        message,
    }
}

fn io_status(error: &std::io::Error) -> &'static str {
    if error.raw_os_error() == Some(5) || error.kind() == std::io::ErrorKind::PermissionDenied {
        "permission_denied"
    } else {
        "path_unreachable"
    }
}

pub fn parse_error_status(error: &ParseError) -> &'static str {
    match error.kind {
        ParseErrorKind::UnsupportedRoot => "unsupported_format",
        ParseErrorKind::MalformedJson => "parse_error",
        ParseErrorKind::Io => {
            let message = to_lower(&error.message);
            if message.contains("denied") || message.contains("permission") {
                "permission_denied"
            } else {
                "path_unreachable"
            }
        }
    }
}

fn is_wsl_unc_path(path: &str) -> bool {
    let normalized = to_lower(&path.replace('/', "\\"));
    normalized.starts_with("\\\\wsl.localhost\\") || normalized.starts_with("\\\\wsl$\\")
}

struct CachedIndex {
    by_path: HashMap<String, CachedSource>,
}

impl CachedIndex {
    fn new(cached: &[CachedSource]) -> Self {
        let mut by_path = HashMap::new();
        for source in cached {
            for key in snapshot_keys(source) {
                by_path.insert(key, source.clone());
            }
        }
        Self { by_path }
    }

    fn lookup(&self, path: &str) -> Option<&CachedSource> {
        self.by_path.get(&canonical_scan_path(path))
    }
}

fn snapshot_keys(source: &CachedSource) -> Vec<String> {
    let mut keys = vec![canonical_scan_path(&source.source_path)];
    if let Some(unc) = &source.unc_path {
        keys.push(canonical_scan_path(unc));
    }
    keys
}

/// `_parseDecision`.
fn should_parse(path: &str, listed: Option<&std::fs::Metadata>, cached: &CachedIndex) -> bool {
    let Some(cached) = cached.lookup(path) else {
        return true;
    };
    let (Some(size), Some(modified), Some(version)) =
        (cached.file_size, cached.modified_utc, cached.parser_version)
    else {
        return true;
    };
    if cached.scan_status != "available" || version != crate::codex::parser::PARSER_VERSION {
        return true;
    }
    let Some(metadata) = listed else {
        return true;
    };
    if metadata.len() as i64 != size {
        return true;
    }
    let Ok(current) = crate::codex::parser::file_modified_utc(metadata) else {
        return true;
    };
    (current.micros() - modified.micros()).abs() > CACHE_MODIFIED_TOLERANCE_MICROS
}

struct Discovery {
    counts: ScanCounts,
    statuses: Vec<SourceStatus>,
    errors: Vec<SourceStatus>,
    candidates: Vec<Candidate>,
    reachable_roots: Vec<String>,
    failed_owners: HashSet<String>,
}

fn discover(
    options: &ScanOptions,
    cancel: &AtomicBool,
    progress: &mut impl FnMut(&ScanCounts),
) -> Discovery {
    let mut discovery = Discovery {
        counts: ScanCounts::default(),
        statuses: Vec::new(),
        errors: Vec::new(),
        candidates: Vec::new(),
        reachable_roots: Vec::new(),
        failed_owners: HashSet::new(),
    };
    let mut availability: HashMap<String, bool> = HashMap::new();
    let mut reported: HashSet<String> = HashSet::new();
    let mut directories: Vec<(String, String, SourceType, &'static str)> = Vec::new();
    for root in &options.roots {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        if root.path.is_empty() {
            continue;
        }
        let owner_path = root
            .availability_root_path
            .clone()
            .unwrap_or_else(|| root.path.clone());
        let owner_key = canonical_scan_path(&owner_path);
        let mut report = |discovery: &mut Discovery, path: &str, code: &str, message: &str| {
            discovery.failed_owners.insert(owner_key.clone());
            if !reported.insert(owner_key.clone()) {
                return;
            }
            discovery.counts.files_failed += 1;
            let entry = status(path, code, root.source_state, Some(message.to_owned()));
            discovery.errors.push(entry.clone());
            discovery.statuses.push(entry);
        };
        let owner_exists = || Path::new(&owner_path).is_dir();
        let reachable = match availability.get(&owner_key) {
            Some(value) => *value,
            None => {
                let mut reachable = owner_exists();
                if root.source_type == SourceType::Wsl && is_wsl_unc_path(&owner_path) {
                    for delay in &options.wsl_root_retry_delays {
                        if reachable || cancel.load(Ordering::Relaxed) {
                            break;
                        }
                        let started = std::time::Instant::now();
                        while started.elapsed() < *delay && !cancel.load(Ordering::Relaxed) {
                            std::thread::sleep(
                                (*delay - started.elapsed().min(*delay))
                                    .min(Duration::from_millis(25)),
                            );
                        }
                        reachable = owner_exists();
                    }
                }
                availability.insert(owner_key.clone(), reachable);
                reachable
            }
        };
        if !reachable {
            report(
                &mut discovery,
                &owner_path,
                "path_unreachable",
                "Session root is unreachable.",
            );
            continue;
        }
        if owner_path != root.path {
            match std::fs::symlink_metadata(&root.path) {
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                    if !owner_exists() {
                        report(
                            &mut discovery,
                            &owner_path,
                            "path_unreachable",
                            "Session root became unreachable during discovery.",
                        );
                        continue;
                    }
                    discovery.reachable_roots.push(root.path.clone());
                    continue;
                }
                Err(error) => {
                    report(
                        &mut discovery,
                        &root.path,
                        io_status(&error),
                        &error.to_string(),
                    );
                    continue;
                }
                Ok(metadata) if !metadata.is_dir() => {
                    report(
                        &mut discovery,
                        &root.path,
                        "path_unreachable",
                        "Session source root is not a directory.",
                    );
                    continue;
                }
                Ok(_) => {}
            }
        }
        discovery.reachable_roots.push(root.path.clone());
        directories.push((
            root.path.clone(),
            owner_path,
            root.source_type,
            root.source_state,
        ));
    }

    walk(directories, &mut discovery, cancel, progress);
    discovery
}

type WalkDirectory = (String, String, SourceType, &'static str);

/// Listing threads. The walk waits on the file system, and a
/// `\wsl.localhost` folder costs a round trip, so folders are listed
/// concurrently.
const DISCOVERY_WORKERS: usize = 8;

#[derive(Default)]
struct Walked {
    candidates: Vec<Candidate>,
    unsupported: Vec<SourceStatus>,
    failures: Vec<(String, String, &'static str, std::io::Error)>,
}

/// Lists every folder under `roots`. The result does not depend on thread
/// timing: candidates are sorted by path.
fn walk(
    roots: Vec<WalkDirectory>,
    discovery: &mut Discovery,
    cancel: &AtomicBool,
    progress: &mut impl FnMut(&ScanCounts),
) {
    if roots.is_empty() {
        return;
    }
    // Pending folders and the number of folders being listed right now.
    let queue = Mutex::new((roots, 0usize));
    let changed = Condvar::new();
    let scanned = AtomicU64::new(0);
    let (finished, done) = std::sync::mpsc::channel::<Walked>();
    let mut results = Vec::with_capacity(DISCOVERY_WORKERS);
    std::thread::scope(|scope| {
        for _ in 0..DISCOVERY_WORKERS {
            let finished = finished.clone();
            let (queue, changed, scanned) = (&queue, &changed, &scanned);
            scope.spawn(move || {
                let mut walked = Walked::default();
                loop {
                    let next = {
                        let mut state = queue.lock().expect("discovery queue");
                        loop {
                            if cancel.load(Ordering::Relaxed) {
                                break None;
                            }
                            if let Some(directory) = state.0.pop() {
                                state.1 += 1;
                                break Some(directory);
                            }
                            if state.1 == 0 {
                                break None;
                            }
                            state = changed
                                .wait_timeout(state, Duration::from_millis(50))
                                .expect("discovery queue")
                                .0;
                        }
                    };
                    let Some(directory) = next else {
                        changed.notify_all();
                        break;
                    };
                    let subdirectories = list_directory(directory, cancel, &mut walked);
                    scanned.fetch_add(1, Ordering::Relaxed);
                    let mut state = queue.lock().expect("discovery queue");
                    state.0.extend(subdirectories);
                    state.1 -= 1;
                    drop(state);
                    changed.notify_all();
                }
                let _ = finished.send(walked);
            });
        }
        drop(finished);
        while results.len() < DISCOVERY_WORKERS {
            match done.recv_timeout(Duration::from_millis(50)) {
                Ok(walked) => results.push(walked),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
            }
            discovery.counts.directories_scanned = scanned.load(Ordering::Relaxed);
            progress(&discovery.counts);
        }
    });
    discovery.counts.directories_scanned = scanned.load(Ordering::Relaxed);
    let mut candidates = Vec::new();
    let mut unsupported = Vec::new();
    let mut failures = Vec::new();
    for walked in results {
        candidates.extend(walked.candidates);
        unsupported.extend(walked.unsupported);
        failures.extend(walked.failures);
    }
    candidates.sort_by(|left, right| left.path.cmp(&right.path));
    unsupported.sort_by(|left, right| left.path.cmp(&right.path));
    failures.sort_by(|left, right| left.0.cmp(&right.0));
    for (directory, owner_path, state, error) in failures {
        directory_failed(discovery, &directory, &owner_path, state, &error);
    }
    discovery.counts.files_skipped += unsupported.len() as u64;
    discovery.errors.extend(unsupported.iter().cloned());
    discovery.statuses.extend(unsupported);
    discovery.counts.files_found += candidates.len() as u64;
    discovery.candidates = candidates;
}

/// Lists one folder into `walked` and returns its subfolders.
fn list_directory(
    (directory, owner_path, source_type, source_state): WalkDirectory,
    cancel: &AtomicBool,
    walked: &mut Walked,
) -> Vec<WalkDirectory> {
    let mut subdirectories = Vec::new();
    let entries = match std::fs::read_dir(&directory) {
        Ok(entries) => entries,
        Err(error) => {
            walked
                .failures
                .push((directory, owner_path, source_state, error));
            return subdirectories;
        }
    };
    for entry in entries {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        let entry = match entry {
            Ok(entry) => entry,
            Err(error) => {
                walked
                    .failures
                    .push((directory.clone(), owner_path.clone(), source_state, error));
                break;
            }
        };
        let path = join(&directory, &entry.file_name().to_string_lossy());
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            subdirectories.push((path, owner_path.clone(), source_type, source_state));
            continue;
        }
        if !file_type.is_file() {
            continue;
        }
        if !(path.ends_with(".json") || path.ends_with(".jsonl")) {
            walked.unsupported.push(status(
                &path,
                "unsupported_format",
                source_state,
                Some("Unsupported session file format.".to_owned()),
            ));
            continue;
        }
        // NTFS updates a listed file's size and time lazily while another
        // process holds it open, so local files are checked directly; the
        // WSL file server lists current values.
        let metadata = if source_type == SourceType::Wsl {
            entry.metadata().ok()
        } else {
            std::fs::metadata(&path).ok()
        };
        walked.candidates.push(Candidate {
            path,
            source_type,
            source_state,
            metadata,
        });
    }
    subdirectories
}

fn directory_failed(
    discovery: &mut Discovery,
    directory: &str,
    owner_path: &str,
    state: &str,
    error: &std::io::Error,
) {
    discovery
        .failed_owners
        .insert(canonical_scan_path(owner_path));
    discovery.counts.files_failed += 1;
    let entry = status(directory, io_status(error), state, Some(error.to_string()));
    discovery.errors.push(entry.clone());
    discovery.statuses.push(entry);
}

type ParseJob = (usize, String);
type ParseResult = (usize, Result<ParseSuccess, ParseError>);

/// Scan the roots, handing every parsed session to `sink` as it completes.
/// The sink's error stops the scan.
pub fn scan<E>(
    options: &ScanOptions,
    cached: &[CachedSource],
    sink: impl FnMut(SessionSnapshot) -> Result<(), E>,
) -> Result<ScanOutcome, E> {
    scan_controlled(
        options,
        cached,
        sink,
        &Arc::new(AtomicBool::new(false)),
        |_| {},
    )
}

pub fn scan_controlled<E>(
    options: &ScanOptions,
    cached: &[CachedSource],
    mut sink: impl FnMut(SessionSnapshot) -> Result<(), E>,
    cancel: &Arc<AtomicBool>,
    mut progress: impl FnMut(&ScanCounts),
) -> Result<ScanOutcome, E> {
    progress(&ScanCounts::default());
    let mut phases = crate::timing::Phases::start();
    let discovery = discover(options, cancel, &mut progress);
    phases.mark("discover files");
    let mut counts = discovery.counts;
    progress(&counts);
    let mut statuses = discovery.statuses;
    let mut errors = discovery.errors;
    let index = CachedIndex::new(cached);
    let mut to_parse: Vec<usize> = Vec::new();
    for (position, candidate) in discovery.candidates.iter().enumerate() {
        if cancel.load(Ordering::Relaxed) {
            break;
        }
        if options.force || should_parse(&candidate.path, candidate.metadata.as_ref(), &index) {
            to_parse.push(position);
        } else {
            counts.files_skipped += 1;
            statuses.push(status(
                &candidate.path,
                "available",
                candidate.source_state,
                None,
            ));
        }
    }

    phases.mark("skip decisions");
    let workers = options.parser_workers.max(1);
    let (job_sender, job_receiver) = sync_channel::<ParseJob>(workers * 2);
    let (result_sender, result_receiver) = sync_channel::<ParseResult>(workers * 2);
    let job_receiver = Arc::new(Mutex::new(job_receiver));
    let mut handles = Vec::with_capacity(workers);
    for _ in 0..workers {
        let jobs = Arc::clone(&job_receiver);
        let results = result_sender.clone();
        let parser = options.parser;
        let cancellation = Arc::clone(cancel);
        handles.push(
            std::thread::Builder::new()
                .name("codex-parser".to_owned())
                .stack_size(16 * 1024 * 1024)
                .spawn(move || parser_worker(&jobs, &results, parser, &cancellation))
                .expect("spawn parser thread"),
        );
    }
    drop(result_sender);
    let jobs: Vec<ParseJob> = to_parse
        .iter()
        .map(|position| (*position, discovery.candidates[*position].path.clone()))
        .collect();
    let cancellation = Arc::clone(cancel);
    let feeder = std::thread::spawn(move || feed(jobs, job_sender, &cancellation));

    let mut parsed = Vec::new();
    let mut project_cache: HashMap<String, Option<String>> = HashMap::new();
    let mut sink_error = None;
    for (position, result) in result_receiver.iter() {
        if sink_error.is_some() {
            continue;
        }
        let candidate = &discovery.candidates[position];
        match result {
            Err(error) => {
                counts.files_failed += 1;
                let entry = status(
                    &candidate.path,
                    parse_error_status(&error),
                    candidate.source_state,
                    Some(error.display_message()),
                );
                errors.push(entry.clone());
                statuses.push(entry);
            }
            Ok(success) => {
                counts.files_parsed += 1;
                let snapshot = build_snapshot(
                    options,
                    &candidate.path,
                    candidate.source_type,
                    candidate.source_state,
                    &success,
                    &mut project_cache,
                );
                statuses.push(status(
                    &candidate.path,
                    &snapshot.source.status,
                    candidate.source_state,
                    None,
                ));
                parsed.push(ParsedRef {
                    session_id: success.session.session_id.clone(),
                    source_path: candidate.path.clone(),
                    working_directory: success.session.working_directory_display.clone(),
                    source_type: candidate.source_type,
                });
                if let Err(error) = sink(snapshot) {
                    sink_error = Some(error);
                }
            }
        }
        progress(&counts);
    }
    let _ = feeder.join();
    for handle in handles {
        let _ = handle.join();
    }
    phases.mark("parse and sink");
    if let Some(error) = sink_error {
        return Err(error);
    }

    // `_recordMissingCachedSessions` over roots whose owner scanned fully.
    let complete_roots: Vec<&String> = discovery
        .reachable_roots
        .iter()
        .filter(|root| {
            let owner = options
                .roots
                .iter()
                .find(|candidate| canonical_scan_path(&candidate.path) == canonical_scan_path(root))
                .map(|candidate| {
                    canonical_scan_path(
                        candidate
                            .availability_root_path
                            .as_deref()
                            .unwrap_or(&candidate.path),
                    )
                })
                .unwrap_or_else(|| canonical_scan_path(root));
            !discovery.failed_owners.contains(&owner)
        })
        .collect();
    counts.cancelled = cancel.load(Ordering::Relaxed);
    let discovery_complete = !counts.cancelled && discovery.failed_owners.is_empty();
    if !counts.cancelled && !complete_roots.is_empty() {
        let found: HashSet<String> = discovery
            .candidates
            .iter()
            .map(|candidate| canonical_scan_path(&candidate.path))
            .collect();
        for source in cached {
            let keys = snapshot_keys(source);
            if keys.iter().any(|key| found.contains(key)) {
                continue;
            }
            if !keys.iter().any(|key| {
                complete_roots
                    .iter()
                    .any(|root| is_path_under_root(key, root))
            }) {
                continue;
            }
            counts.sessions_missing += 1;
            let entry = status(
                &source.source_path,
                "missing",
                "missing",
                Some("Previously cached session file is missing.".to_owned()),
            );
            errors.push(entry.clone());
            statuses.push(entry);
        }
    }
    Ok(ScanOutcome {
        counts,
        statuses,
        parsed,
        errors,
        discovery_complete,
    })
}

fn feed(jobs: Vec<ParseJob>, sender: SyncSender<ParseJob>, cancel: &AtomicBool) {
    for mut job in jobs {
        loop {
            if cancel.load(Ordering::Relaxed) {
                return;
            }
            match sender.try_send(job) {
                Ok(()) => break,
                Err(std::sync::mpsc::TrySendError::Disconnected(_)) => return,
                Err(std::sync::mpsc::TrySendError::Full(pending)) => {
                    job = pending;
                    std::thread::sleep(Duration::from_millis(5));
                }
            }
        }
    }
}

fn parser_worker(
    jobs: &Mutex<Receiver<ParseJob>>,
    results: &SyncSender<ParseResult>,
    options: ParserOptions,
    cancel: &AtomicBool,
) {
    loop {
        if cancel.load(Ordering::Relaxed) {
            return;
        }
        let job = {
            let Ok(receiver) = jobs.lock() else {
                return;
            };
            receiver.recv()
        };
        let Ok((position, path)) = job else {
            return;
        };
        let result = parse_file(&path, options);
        if results.send((position, result)).is_err() {
            return;
        }
    }
}

pub fn build_snapshot(
    options: &ScanOptions,
    path: &str,
    source_type: SourceType,
    source_state: &str,
    success: &ParseSuccess,
    project_cache: &mut HashMap<String, Option<String>>,
) -> SessionSnapshot {
    let mapped = match source_type {
        SourceType::Windows => options.mapper.map_windows_path(path),
        SourceType::Wsl => options.mapper.map_wsl_unc_path(path),
    };
    let session = &success.session;
    let index_name = session
        .session_id
        .as_deref()
        .and_then(|id| options.thread_names.get(id))
        .map(|entry| trim(&entry.thread_name).to_owned())
        .filter(|name| !name.is_empty());
    let thread_name = index_name.or_else(|| {
        session
            .thread_name
            .as_deref()
            .map(|name| trim(name).to_owned())
    });
    let hints = project_hints(session, source_type, project_cache);
    codex_snapshot(
        session,
        &CodexSource {
            path,
            mapped: &mapped,
            state: source_state,
            status: if success.changed_during_parse {
                "changed_pending_parse"
            } else {
                "available"
            },
            size: success.snapshot_size,
            modified_utc: success.snapshot_modified_utc,
        },
        thread_name,
        hints,
    )
}

/// Windows project names come from the nearest `.git` on this machine. WSL
/// names use the folder name here; `wsl.exe` refines them after the scan,
/// like the viewer.
fn project_hints(
    session: &crate::codex::parser::ParsedSession,
    source_type: SourceType,
    cache: &mut HashMap<String, Option<String>>,
) -> Vec<ProjectHint> {
    if source_type != SourceType::Windows {
        return Vec::new();
    }
    let mut directories: Vec<&str> = Vec::new();
    if let Some(directory) = session.working_directory_display.as_deref() {
        directories.push(directory);
    }
    for event in &session.usage_events {
        if let Some(directory) = event.working_directory.as_deref() {
            directories.push(directory);
        }
    }
    let mut hints: Vec<ProjectHint> = Vec::new();
    for directory in directories {
        let path = trim(directory);
        if path.is_empty() || hints.iter().any(|hint| hint.working_directory == path) {
            continue;
        }
        let name = cache
            .entry(path.to_owned())
            .or_insert_with(|| resolve_windows_project(path))
            .clone();
        if let Some(name) = name {
            hints.push(ProjectHint {
                working_directory: path.to_owned(),
                project_name: name,
            });
        }
    }
    hints
}
