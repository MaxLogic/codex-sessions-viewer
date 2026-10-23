//! The resident's collection worker. Queue files are authoritative; memory is bounded.
use super::{Shared, protocol, signals};
use serde_json::{Value, json};
pub(super) struct Request {
    pub request: protocol::Request,
    pub reply: std::sync::mpsc::SyncSender<Vec<Value>>,
}
use crate::dart::DartDateTime;
use crate::{
    cli, hooks,
    settings::CollectorSettings,
    store::{OwnerMode, Store, StoreError, StoreResult, write_lease},
};
use std::{
    collections::{BTreeMap, HashMap},
    io::{self, Read},
    path::{Path, PathBuf},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant, SystemTime},
};

const CAPACITY: usize = 10_000;
const DEBOUNCE: Duration = Duration::from_millis(250);
const SWEEP: Duration = Duration::from_secs(30);

struct Entry {
    due: Instant,
}
#[derive(Default)]
pub(crate) struct Pending {
    entries: BTreeMap<PathBuf, Entry>,
    pub(super) claimed: usize,
}

fn valid_name(name: &str) -> bool {
    name.ends_with(".json")
        && name.len() <= 255
        && !name.contains(['/', '\\', ':'])
        && !matches!(name, "." | "..")
        && !name.contains('\0')
}

fn read_item(path: &Path) -> io::Result<hooks::WorkItem> {
    let metadata = std::fs::symlink_metadata(path)?;
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        if metadata.file_attributes() & 0x400 != 0 {
            return Err(io::Error::other("queue entry is a reparse point"));
        }
    }
    if !metadata.is_file() || metadata.file_type().is_symlink() || metadata.len() > 1024 * 1024 {
        return Err(io::Error::other("invalid queue entry"));
    }
    let mut bytes = Vec::new();
    std::fs::File::open(path)?
        .take(1024 * 1024 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > 1024 * 1024 {
        return Err(io::Error::other("queue entry exceeds limit"));
    }
    serde_json::from_slice(&bytes).map_err(io::Error::other)
}
fn belongs(item: &hooks::WorkItem, key: &str) -> bool {
    item.database_key
        .as_deref()
        .is_none_or(|value| value == key)
}
impl Pending {
    pub(crate) fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }
    pub(crate) fn len(&self) -> usize {
        self.entries.len()
    }
    pub(crate) fn retry_in(&self) -> Option<Duration> {
        self.entries
            .values()
            .map(|entry| entry.due.saturating_duration_since(Instant::now()))
            .min()
    }
    pub(crate) fn notify(&mut self, queue: &Path, key: &str, name: &str) -> &'static str {
        self.insert(queue, key, name, DEBOUNCE)
    }
    fn insert(&mut self, queue: &Path, key: &str, name: &str, debounce: Duration) -> &'static str {
        if !valid_name(name) {
            return "rejected";
        }
        let path = queue.join(name);
        if self.entries.contains_key(&path) {
            return "accepted";
        }
        let item = match read_item(&path) {
            Ok(item) => item,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return "already_handled",
            Err(_) => return "rejected",
        };
        if !belongs(&item, key) || !matches!(item.harness.as_str(), "codex" | "claude") {
            return "rejected";
        }
        if self.entries.len() >= CAPACITY {
            // Never acknowledge ownership of an item absent from our pending set.
            return "rejected";
        }
        let retry = item
            .not_before_utc
            .as_deref()
            .and_then(DartDateTime::try_parse)
            .map_or(Duration::ZERO, |at| {
                Duration::from_micros((at.micros() - DartDateTime::now().micros()).max(0) as u64)
            });
        self.entries.insert(
            path,
            Entry {
                due: Instant::now() + debounce.max(retry),
            },
        );
        "accepted"
    }
    pub(crate) fn sweep(&mut self, queue: &Path, key: &str, debounce: Duration) {
        hooks::reclaim_stale(queue);
        if let Ok(entries) = std::fs::read_dir(queue) {
            for entry in entries.flatten() {
                if self.entries.len() >= CAPACITY {
                    break;
                }
                if let Some(name) = entry.file_name().to_str() {
                    self.insert(queue, key, name, debounce);
                }
            }
        }
    }
    fn due_names(&self, limit: usize) -> Vec<PathBuf> {
        self.entries
            .iter()
            .filter(|(_, entry)| entry.due <= Instant::now())
            .take(limit.min(CAPACITY))
            .map(|(name, _)| name.clone())
            .collect()
    }
}

fn claim(queue: &Path, key: &str, name: &str) -> io::Result<Option<hooks::Claim>> {
    let source = queue.join(name);
    let target = queue.join(format!("{name}.claimed-{}", std::process::id()));
    match std::fs::rename(&source, &target) {
        Ok(()) => (),
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    }
    let item = match read_item(&target) {
        Ok(item) => item,
        Err(error) => {
            std::fs::rename(&target, &source)?;
            return Err(error);
        }
    };
    let claim = hooks::Claim { path: target, item };
    if !belongs(&claim.item, key) || !hooks::is_due(&claim.item, DartDateTime::now()) {
        hooks::release(&claim)?;
        return Ok(None);
    }
    std::fs::File::options()
        .write(true)
        .open(&claim.path)?
        .set_modified(SystemTime::now())?;
    Ok(Some(claim))
}

#[derive(Default)]
pub(crate) struct Pass {
    pub completed: usize,
    pub retried: usize,
    pub database_error: Option<StoreError>,
}
enum ItemError {
    File(String),
    Database(StoreError),
}
impl From<StoreError> for ItemError {
    fn from(error: StoreError) -> Self {
        Self::Database(error)
    }
}

pub(crate) fn drain_pass(
    store: &Store,
    options: &cli::Options,
    settings: &CollectorSettings,
    key: &str,
    pending: &Mutex<Pending>,
    limit: usize,
    budget: Duration,
) -> Pass {
    let mut cache = HashMap::new();
    process(
        store, options, settings, key, pending, limit, budget, budget, &mut cache,
    )
}

#[allow(clippy::too_many_arguments)]
fn process(
    store: &Store,
    options: &cli::Options,
    settings: &CollectorSettings,
    key: &str,
    pending: &Mutex<Pending>,
    limit: usize,
    budget: Duration,
    lease_wait: Duration,
    cache: &mut HashMap<String, PathBuf>,
) -> Pass {
    let started = Instant::now();
    let mut pass = Pass::default();
    // One target is parsed once per pass. Every coalesced entry still has its own claim.
    let mut completed = std::collections::HashSet::new();
    let names = pending.lock().unwrap().due_names(limit);
    for path in names {
        if started.elapsed() >= budget || signals::stopping() {
            break;
        }
        if pending.lock().unwrap().entries.remove(&path).is_none() {
            continue;
        }
        let queue = path.parent().expect("queue entry has parent");
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .expect("validated entry name");
        let claim = match claim(queue, key, name) {
            Ok(Some(claim)) => claim,
            Ok(None) => continue,
            Err(error) => {
                hooks::log_error(queue, &format!("queue claim: {error}"));
                continue;
            }
        };
        struct Claimed<'a>(&'a Mutex<Pending>);
        impl Drop for Claimed<'_> {
            fn drop(&mut self) {
                self.0.lock().unwrap().claimed -= 1;
            }
        }
        pending.lock().unwrap().claimed += 1;
        let _claimed = Claimed(pending);
        let target = (
            claim.item.harness.clone(),
            claim.item.transcript_path.clone(),
            claim.item.session_id.clone(),
        );
        let result = if completed.contains(&target) {
            Ok(())
        } else {
            // One-shots may wait up to their remaining deadline. The resident
            // supplies a short wait so controls and other work stay responsive.
            let _wait = write_lease::LeaseWait::enter(
                lease_wait.min(budget.saturating_sub(started.elapsed())),
            );
            ingest_item(store, options, settings, &claim.item, cache)
        };
        match result {
            Ok(()) => {
                completed.insert(target);
                hooks::complete(&claim);
                pass.completed += 1;
            }
            Err(ItemError::Database(error)) => {
                if let Err(error) = hooks::release(&claim) {
                    hooks::log_error(queue, &format!("queue release: {error}"));
                }
                pending
                    .lock()
                    .unwrap()
                    .insert(queue, key, name, Duration::ZERO);
                pass.database_error = Some(error);
                break;
            }
            Err(ItemError::File(message)) => {
                hooks::retry(queue, claim, &message);
                pending
                    .lock()
                    .unwrap()
                    .insert(queue, key, name, Duration::ZERO);
                pass.retried += 1;
            }
        }
    }
    pass
}

fn ingest_item(
    store: &Store,
    options: &cli::Options,
    settings: &CollectorSettings,
    item: &hooks::WorkItem,
    cache: &mut HashMap<String, PathBuf>,
) -> Result<(), ItemError> {
    let file_error = |message: &str| ItemError::File(message.to_owned());
    match item.harness.as_str() {
        "codex" => {
            let thread = item
                .session_id
                .as_deref()
                .filter(|id| !id.trim().is_empty())
                .ok_or_else(|| file_error("notification named no thread"))?;
            let homes: Vec<String> = [&settings.windows_codex_path, &settings.wsl_codex_unc_path]
                .into_iter()
                .take(
                    if crate::codex::parser::SourceType::native()
                        == crate::codex::parser::SourceType::Windows
                    {
                        2
                    } else {
                        1
                    },
                )
                .filter(|home| !home.trim().is_empty())
                .cloned()
                .collect();
            let path = cache
                .get(thread)
                .filter(|path| path.is_file())
                .cloned()
                .or_else(|| recent_rollout(&homes, thread))
                .or_else(|| hooks::find_codex_rollout(&homes, thread))
                .ok_or_else(|| file_error("no rollout for thread yet"))?;
            cache.insert(thread.to_owned(), path.clone());
            let root = cli::root_for_file(settings, &path.to_string_lossy());
            let scan = cli::scan_options(options, settings, Vec::new());
            let report = crate::codex::collect_file(store, &scan, &root, options.wsl_projects)?;
            if report.counts.files_parsed == 0 {
                return Err(file_error("rollout not parsed"));
            }
        }
        "claude" => {
            let reported = item
                .transcript_path
                .as_deref()
                .ok_or_else(|| file_error("hook named no transcript"))?;
            let mapper = crate::path_mapping::PathMapper::new(settings.wsl_linux_root_unc.clone());
            let mapped = mapper
                .hook_access_path(reported)
                .ok_or_else(|| file_error("configure the WSL root for this transcript"))?;
            let path = mapped.as_str();
            if !Path::new(path).is_file() {
                return Err(file_error("transcript does not exist yet"));
            }
            let report = crate::claude::collect_file(
                store,
                Path::new(path),
                cli::claude_source_type(options, path),
                &mapper,
                &cli::claude_parser_options(settings),
            )?;
            if !report.errors.is_empty() {
                return Err(file_error("transcript parse failed"));
            }
            let pending: i64 = store.conn.query_row("select count(*) from sessions where harness = 'claude' and source_file_path = ? and scan_status = 'changed_pending_parse'", [path], |row| row.get(0)).map_err(StoreError::from)?;
            if pending > 0 {
                return Err(file_error("the transcript was still being written"));
            }
        }
        _ => return Err(file_error("unknown harness")),
    }
    Ok(())
}

fn recent_rollout(homes: &[String], thread: &str) -> Option<PathBuf> {
    let utc = chrono::Utc::now().date_naive();
    let local = chrono::Local::now().date_naive();
    for date in [local, local.pred_opt()?, utc, utc.pred_opt()?] {
        let roots = homes
            .iter()
            .map(|home| {
                Path::new(home)
                    .join("sessions")
                    .join(date.format("%Y/%m/%d").to_string())
                    .to_string_lossy()
                    .into_owned()
            })
            .collect::<Vec<_>>();
        if let Some(path) = hooks::find_codex_rollout(&roots, thread) {
            return Some(path);
        }
    }
    None
}

pub(super) struct Scheduler {
    database: PathBuf,
    options: cli::Options,
    settings: CollectorSettings,
    settings_mtime: Option<SystemTime>,
    settings_loaded: bool,
    shared: Arc<Shared>,
    store: Option<Store>,
    next_sweep: Instant,
    next_scan: Instant,
    retry_at: Instant,
    busy_delay: Duration,
    last_work: Instant,
    last_import: Option<Instant>,
    last_scan_finished: Option<Instant>,
    rollouts: HashMap<String, PathBuf>,
}
impl Scheduler {
    pub(super) fn wait(&self) -> Duration {
        let now = Instant::now();
        let mut deadline = self.next_sweep.min(now + Duration::from_millis(200));
        if self.retry_at > now {
            deadline = deadline.min(self.retry_at);
        } else {
            if self.settings.background_rescan_enabled {
                deadline = deadline.min(self.next_scan);
            }
            if let Some(due) = self
                .shared
                .pending
                .lock()
                .unwrap()
                .entries
                .values()
                .map(|entry| entry.due)
                .min()
            {
                deadline = deadline.min(due);
            }
        }
        deadline.saturating_duration_since(now)
    }
    pub(super) fn new(database: &Path, options: cli::Options, shared: Arc<Shared>) -> Self {
        let now = Instant::now();
        Self {
            database: database.into(),
            options,
            settings: CollectorSettings::default(),
            settings_mtime: None,
            settings_loaded: false,
            shared,
            store: None,
            next_sweep: now,
            next_scan: now + SWEEP,
            retry_at: now,
            busy_delay: Duration::from_secs(5),
            last_work: now,
            last_import: None,
            last_scan_finished: None,
            rollouts: HashMap::new(),
        }
    }
    fn state(&self, name: &'static str) {
        let mut state = self.shared.state.lock().unwrap();
        if state.state != "stopping" {
            state.state = name;
        }
        state.write_hold = crate::store::write_budget::hold_report();
    }
    fn reload(&mut self) {
        let path = self
            .options
            .settings
            .clone()
            .or_else(crate::settings::default_settings_file);
        let mtime = path
            .as_ref()
            .and_then(|path| std::fs::metadata(path).ok())
            .and_then(|meta| meta.modified().ok());
        if self.settings_mtime == mtime && self.settings_loaded {
            return;
        }
        self.settings_mtime = mtime;
        self.settings_loaded = true;
        match cli::load_settings(&self.options) {
            Ok(settings) => {
                if settings.background_rescan_interval_seconds
                    != self.settings.background_rescan_interval_seconds
                    && let Some(finished) = self.last_scan_finished
                {
                    self.next_scan = finished
                        .checked_add(Duration::from_secs(
                            settings.background_rescan_interval_seconds,
                        ))
                        .unwrap_or_else(|| finished + Duration::from_secs(u32::MAX.into()));
                }
                self.settings = settings;
                self.settings_mtime = mtime;
                self.settings_loaded = true;
            }
            Err(
                cli::CliError::Usage(message)
                | cli::CliError::Failed(message)
                | cli::CliError::Refused(message),
            ) => hooks::log_error(&hooks::queue_dir(), &message),
        }
    }
    fn unavailable(&mut self, error: StoreError) -> io::Result<()> {
        self.store = None;
        if self.shared.stopping.load(Ordering::SeqCst) || signals::stopping() {
            return Ok(());
        }
        if let StoreError::Refused(message) | StoreError::Unavailable(message) = &error
            && (message.contains("newer than") || message.contains("moved to schema version"))
        {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, error));
        }
        let delay = if !self.database.is_file() {
            SWEEP
        } else if matches!(error, StoreError::Refused(_) | StoreError::Unavailable(_)) {
            Duration::from_secs(10)
        } else {
            let delay = self.busy_delay;
            self.busy_delay = (delay * 2).min(Duration::from_secs(60));
            delay
        };
        if self.shared.state.lock().unwrap().state != "waiting_for_database" {
            hooks::log_error(
                &hooks::queue_dir(),
                &format!("resident waiting for database: {error}"),
            );
        }
        self.state("waiting_for_database");
        self.retry_at = Instant::now() + delay;
        Ok(())
    }
    pub(super) fn tick(&mut self) -> io::Result<()> {
        let shared = self.shared.clone();
        let _control = crate::store::write_budget::WriteControlScope::enter(move || {
            shared.stopping.load(Ordering::SeqCst) || signals::stopping()
        });
        self.reload();
        let probe_due = Instant::now() >= self.next_sweep;
        if probe_due {
            self.shared.sweep_queues(DEBOUNCE);
            self.next_sweep = Instant::now() + SWEEP;
        }
        if Instant::now() < self.retry_at {
            return Ok(());
        }
        let has_work = !self.shared.pending.lock().unwrap().is_empty()
            || !self.shared.requests.lock().unwrap().is_empty()
            || (self.settings.background_rescan_enabled && Instant::now() >= self.next_scan);
        if self.store.is_none() && !has_work && self.last_work.elapsed() >= Duration::from_secs(60)
        {
            if probe_due && let Err(error) = super::database_state(&self.database) {
                return self.unavailable(error);
            }
            return Ok(());
        }
        if self.store.is_none() {
            let opened = if self.options.standalone.is_some() {
                Store::open(&self.database, OwnerMode::Standalone)
            } else {
                super::database_state(&self.database)
                    .and_then(|()| Store::open(&self.database, OwnerMode::Viewer))
            };
            match opened {
                Ok(store) => {
                    store
                        .conn
                        .busy_timeout(Duration::from_millis(200))
                        .map_err(io::Error::other)?;
                    self.store = Some(store);
                    self.state("ready");
                }
                Err(error) => return self.unavailable(error),
            }
        }
        let store = self.store.as_ref().unwrap();
        let pass = process(
            store,
            &self.options,
            &self.settings,
            &self.shared.key,
            &self.shared.pending,
            8,
            Duration::from_secs(1),
            Duration::from_millis(200),
            &mut self.rollouts,
        );
        if let Some(error) = pass.database_error {
            return self.unavailable(error);
        }
        if pass.completed + pass.retried > 0 {
            self.last_work = Instant::now();
        }
        if pass.completed > 0
            && self
                .last_import
                .is_none_or(|at| at.elapsed() >= Duration::from_secs(60))
        {
            crate::t3::import_optional(&store.conn, &self.settings);
            self.last_import = Some(Instant::now());
        }
        let request = self.shared.requests.lock().unwrap().pop_front();
        if let Some(request) = request {
            self.execute(request)?;
        } else if self.settings.background_rescan_enabled && Instant::now() >= self.next_scan {
            let options = self.options.clone();
            match self.full_scan(&["codex".into(), "claude".into()], &options) {
                Ok(_) => (),
                Err(error) => return self.unavailable(error),
            }
        }
        if self.store.is_none() {
            return Ok(());
        }
        self.busy_delay = Duration::from_secs(5);
        self.state("ready");
        if self.last_work.elapsed() >= Duration::from_secs(60) {
            self.store = None;
        }
        Ok(())
    }
    fn full_scan(
        &mut self,
        harnesses: &[String],
        options: &cli::Options,
    ) -> StoreResult<Vec<(String, crate::codex::CollectReport)>> {
        self.state("scanning");
        let store = self.store.as_ref().unwrap();
        let cancel = Arc::new(AtomicBool::new(false));
        let work = std::cell::RefCell::new((&mut self.rollouts, None));
        let next_sweep = std::cell::Cell::new(self.next_sweep);
        let service = || -> StoreResult<bool> {
            if Instant::now() >= next_sweep.get() {
                self.shared.sweep_queues(DEBOUNCE);
                next_sweep.set(Instant::now() + SWEEP);
            }
            if self.shared.stopping.load(Ordering::SeqCst) || signals::stopping() {
                cancel.store(true, Ordering::Relaxed);
                return Ok(false);
            }
            let mut work = work.borrow_mut();
            if work.1.is_some() {
                cancel.store(true, Ordering::Relaxed);
                return Ok(false);
            }
            let pass = process(
                store,
                &self.options,
                &self.settings,
                &self.shared.key,
                &self.shared.pending,
                8,
                Duration::from_secs(1),
                Duration::from_millis(200),
                work.0,
            );
            work.1 = pass.database_error;
            Ok(work.1.is_none())
        };
        let settings =
            cli::load_settings(options).map_err(|error| StoreError::Refused(cli_message(error)))?;
        let mut reports = Vec::new();
        for harness in harnesses {
            if cancel.load(Ordering::Relaxed) {
                break;
            }
            let report = match harness.as_str() {
                "codex" => {
                    let scan =
                        cli::scan_options(options, &settings, cli::configured_roots(&settings));
                    crate::codex::collect_coordinated(
                        store,
                        &scan,
                        options.wsl_projects,
                        &cancel,
                        |_, _| {
                            let _ = service();
                        },
                        |acquire| if acquire { service() } else { Ok(true) },
                        crate::codex::CollectionBatching {
                            sessions: options.flush_sessions.min(64),
                            source_bytes: options.flush_bytes,
                        },
                    )?
                }
                "claude" => {
                    let roots = cli::claude_roots(options);
                    let scan = crate::claude::ClaudeScanOptions {
                        roots,
                        mapper: crate::path_mapping::PathMapper::new(
                            settings.wsl_linux_root_unc.clone(),
                        ),
                        parser: cli::claude_parser_options(&settings),
                        workers: options
                            .parser_workers
                            .unwrap_or_else(cli::default_parser_workers),
                        force: options.force,
                        resolve_wsl_projects: options.wsl_projects,
                    };
                    crate::claude::collect_coordinated(
                        store,
                        &scan,
                        &cancel,
                        |_, _| {
                            let _ = service();
                        },
                        |acquire| if acquire { service() } else { Ok(true) },
                        options.flush_sessions.min(64),
                    )?
                }
                _ => return Err(StoreError::Refused("unknown scan harness".into())),
            };
            reports.push((format!("{harness} scan"), report));
        }
        if let Some(error) = work.into_inner().1 {
            return Err(error);
        }
        // Discovery has reconciled the persisted identities, including unchanged rollouts.
        // Keep the lookup across hook bursts instead of repeatedly walking every dated folder.
        if harnesses.iter().any(|harness| harness == "codex") {
            let mut statement = store.conn.prepare("select session_id, source_file_path from sessions where harness = 'codex' and session_id is not null and source_file_path is not null")?;
            self.rollouts.clear();
            for row in statement.query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    PathBuf::from(row.get::<_, String>(1)?),
                ))
            })? {
                let (id, path) = row?;
                self.rollouts.insert(id, path);
            }
        }
        crate::t3::import_optional(&store.conn, &settings);
        self.last_import = Some(Instant::now());
        self.next_sweep = next_sweep.get();
        self.last_work = Instant::now();
        let now = Instant::now();
        self.last_scan_finished = Some(now);
        self.next_scan = now
            .checked_add(Duration::from_secs(
                self.settings.background_rescan_interval_seconds,
            ))
            .unwrap_or_else(|| now + Duration::from_secs(u32::MAX.into()));
        {
            let mut state = self.shared.state.lock().unwrap();
            let sequence = state.last_scan["sequence"].as_u64().unwrap_or(0) + 1;
            state.last_scan =
                json!({"sequence":sequence,"finished_utc":DartDateTime::now().to_iso8601()});
        }
        Ok(reports)
    }
    fn execute(&mut self, request: Request) -> io::Result<()> {
        // Snapshot waiters before starting. Requests received during this scan
        // remain queued for exactly one follow-up, never the scan already in flight.
        let mut combined = request.request.clone();
        let mut waiters = vec![request];
        if combined.op == "scan" {
            let mut requests = self.shared.requests.lock().unwrap();
            let mut index = 0;
            while index < requests.len() {
                let next = &requests[index].request;
                if next.op == "scan"
                    && next.force == combined.force
                    && next.parser_workers == combined.parser_workers
                    && next.harnesses == combined.harnesses
                {
                    waiters.push(requests.remove(index).unwrap());
                } else {
                    index += 1;
                }
            }
        }
        combined.id = waiters[0].request.id.clone();
        let result = self.execute_inner(&combined);
        for waiter in waiters {
            let id = &waiter.request.id;
            let events = match &result {
                Ok(events) => {
                    let mut events = events.to_vec();
                    for event in &mut events {
                        event["id"] = json!(id);
                    }
                    let cancelled = events.iter().any(|event| event["cancelled"] == true);
                    if !events.iter().any(|event| event["event"] == "error") {
                        events.push(json!({"v":1,"id":id,"event":"done","cancelled":cancelled}));
                    }
                    events
                }
                Err(error) => vec![protocol::error(id, "refused", error)],
            };
            // A disconnected viewer does not discard committed work.
            let _ = waiter.reply.send(events);
        }
        Ok(())
    }
    fn execute_inner(&mut self, request: &protocol::Request) -> Result<Vec<Value>, String> {
        let mut options = self.options.clone();
        if self.options.standalone.is_some() {
            options.db = None;
            options.standalone = Some(self.database.clone());
        } else {
            options.db = Some(self.database.clone());
            options.standalone = None;
        }
        options.json = true;
        if let Some(force) = request.force {
            options.force = force;
        }
        if let Some(workers) = request.parser_workers {
            if workers == 0 || workers > 256 {
                return Err("parser_workers out of range".into());
            }
            options.parser_workers = Some(workers);
        }
        if request.op == "scan" {
            let harnesses = if request.harnesses.is_empty() {
                vec!["codex".into(), "claude".into()]
            } else {
                request.harnesses.clone()
            };
            if harnesses.len() > 2
                || harnesses
                    .iter()
                    .any(|h| !matches!(h.as_str(), "codex" | "claude"))
            {
                return Err("invalid harnesses".into());
            }
            let reports = match self.full_scan(&harnesses, &options) {
                Ok(reports) => reports,
                Err(error) => {
                    let message = error.to_string();
                    self.unavailable(error).map_err(|e| e.to_string())?;
                    return Err(message);
                }
            };
            let store = self.store.as_ref().ok_or("database unavailable")?;
            let mut events = Vec::new();
            for (command, report) in reports {
                let mut bytes = Vec::new();
                cli::print_report(&mut bytes, &command, store, &report, true)
                    .map_err(cli_message)?;
                let mut event: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
                event["v"] = json!(1);
                event["id"] = json!(request.id);
                events.push(event);
            }
            return Ok(events);
        }
        let mut bytes = Vec::new();
        if let Some(path) = &request.path {
            options.positional = vec![path.clone()];
        }
        let harness = request.harness.as_deref();
        let result = match harness {
            Some("codex") => cli::codex_ingest_on(
                self.store.as_ref().ok_or("database unavailable")?,
                &options,
                &mut bytes,
            ),
            Some("claude") => cli::claude_ingest_on(
                self.store.as_ref().ok_or("database unavailable")?,
                &options,
                &mut bytes,
            ),
            _ => return Err("invalid ingest harness".into()),
        };
        if let Err(error) = result {
            let exit_code = match &error {
                cli::CliError::Usage(_) => 2,
                cli::CliError::Refused(_) => 3,
                cli::CliError::Failed(_) => 1,
            };
            // An unsuccessful ingest can still persist a failure status.
            let report = serde_json::from_slice::<Value>(&bytes).ok();
            return Ok(vec![json!({"v":1,"id":request.id,"event":"error",
                    "code":"collection_failed","message":cli_message(error),
                "exit_code":exit_code,"report":report})]);
        }
        self.last_work = Instant::now();
        let report: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        Ok(vec![
            json!({"v":1,"id":request.id,"event":"finished","report":report}),
        ])
    }
}

fn cli_message(error: cli::CliError) -> String {
    match error {
        cli::CliError::Usage(message)
        | cli::CliError::Failed(message)
        | cli::CliError::Refused(message) => message,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hook_back_pressure_keeps_the_overflow_entry_durable() {
        let root = std::env::temp_dir().join(format!(
            "cxv182-pressure-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                for entry in std::fs::read_dir(&self.0).unwrap() {
                    std::fs::remove_file(entry.unwrap().path()).unwrap();
                }
                std::fs::remove_dir(&self.0).unwrap();
            }
        }
        let _cleanup = Cleanup(root.clone());
        let entry =
            hooks::enqueue(&root, &hooks::codex_work_item(r#"{"thread-id":"test"}"#)).unwrap();
        let bytes = std::fs::read(&entry).unwrap();
        let mut pending = Pending::default();
        for index in 0..CAPACITY {
            pending.entries.insert(
                root.join(format!("{index}.json")),
                Entry {
                    due: Instant::now(),
                },
            );
        }
        let name = entry.file_name().unwrap().to_str().unwrap();
        assert_eq!(pending.notify(&root, "key", name), "rejected");
        assert_eq!(pending.len(), CAPACITY);
        assert_eq!(std::fs::read(&entry).unwrap(), bytes);
        pending.entries.remove(&root.join("0.json"));
        assert_eq!(pending.notify(&root, "key", name), "accepted");
        assert_eq!(pending.len(), CAPACITY);
        assert!(pending.due_names(8).len() <= 8);
    }
}
