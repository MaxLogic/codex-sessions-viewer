//! Resident control plane. The scheduler and collection operations join in S2b/S3a.
pub mod bridge;
pub mod endpoint;
pub mod instance;
pub mod protocol;
pub mod scheduler;
mod transport;
pub mod viewer;

use crate::store::{OwnerMode, StoreError, schema, write_budget};
use rusqlite::{Connection, OpenFlags};
use serde_json::{Value, json};
use std::io::{self, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};
use std::thread;
use std::time::{Duration, Instant};

const CLIENT_TIMEOUT: Duration = Duration::from_secs(1);
const START_TIMEOUT: Duration = Duration::from_secs(5);
const VIEWER_IDLE: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Lifetime {
    Resident,
    Viewer,
}
impl Lifetime {
    fn name(self) -> &'static str {
        match self {
            Self::Resident => "resident",
            Self::Viewer => "viewer",
        }
    }
}
struct State {
    state: &'static str,
    lifetime: Lifetime,
    viewers: usize,
    idle_since: Instant,
    started: Instant,
    write_hold: write_budget::WriteHoldReport,
    last_scan: Value,
}
struct Shared {
    state: Mutex<State>,
    stopping: AtomicBool,
    connections: AtomicUsize,
    pending: Mutex<scheduler::Pending>,
    key: String,
    queue: PathBuf,
    requests: Mutex<std::collections::VecDeque<scheduler::Request>>,
    wake: std::sync::mpsc::SyncSender<()>,
    pausers: AtomicUsize,
    settings: Option<PathBuf>,
}

impl Shared {
    fn sweep_queues(&self, debounce: Duration) {
        scheduler::sweep_shared(&self.pending, &self.queue, &self.key, debounce);
    }
    // The callback exposes the decision/publication boundary to deterministic
    // concurrency tests; production supplies a no-op.
    fn stop_if_idle(&self, now: Instant, before_publish: impl FnOnce()) -> bool {
        let mut state = self.state.lock().unwrap();
        let idle = state.lifetime == Lifetime::Viewer
            && state.viewers == 0
            && self.pending.lock().unwrap().is_empty()
            && self.requests.lock().unwrap().is_empty()
            && now.saturating_duration_since(state.idle_since) >= VIEWER_IDLE;
        if idle {
            before_publish();
            self.publish_stopping(&mut state);
        }
        idle
    }

    fn publish_stopping(&self, state: &mut State) {
        state.state = "stopping";
        self.stopping.store(true, Ordering::SeqCst);
    }

    fn stop(&self) {
        self.publish_stopping(&mut self.state.lock().unwrap());
    }
}

fn register_hello(request: &protocol::Request, state: &mut State, viewer: &mut bool) -> Value {
    if !matches!(
        request.client.as_deref(),
        Some("hook" | "viewer" | "cli" | "launcher")
    ) || !matches!(request.lifetime.as_deref(), None | Some("resident"))
    {
        protocol::error(
            &request.id,
            "bad_request",
            "invalid hello client or lifetime",
        )
    } else if state.state == "stopping" {
        // A starter must wait for lock release, not acknowledge an upgrade
        // that the already committed shutdown would discard.
        hello(&request.id, state)
    } else {
        if request.lifetime.as_deref() == Some("resident") {
            state.lifetime = Lifetime::Resident;
        }
        if request.client.as_deref() == Some("viewer") && !*viewer {
            state.viewers += 1;
            *viewer = true;
        }
        hello(&request.id, state)
    }
}

fn hello(id: &str, state: &State) -> Value {
    json!({"v":protocol::VERSION,"id":id,"event":"hello", "protocol":protocol::VERSION,
        "viewer_protocol":protocol::VERSION,
        "collector_version":env!("CARGO_PKG_VERSION"), "schema":schema::SUPPORTED_SCHEMA_VERSION,
        "contract":crate::contract::CONTRACT_VERSION,
        "parsers":{"codex":crate::codex::parser::PARSER_VERSION,"claude":crate::claude::parser::CLAUDE_PARSER_VERSION},
        "pid":std::process::id(), "lifetime":state.lifetime.name(), "state":state.state})
}
fn status(id: &str, state: &State) -> Value {
    json!({"v":protocol::VERSION,"id":id,"event":"status","pid":std::process::id(),
        "state":state.state,"lifetime":state.lifetime.name(),"queue":{"pending":0,"claimed":0},
        "last_scan":state.last_scan,"write_hold":state.write_hold,"uptime":state.started.elapsed().as_secs_f64()})
}

struct ConnectionGuard {
    shared: Arc<Shared>,
    viewer: bool,
    paused: bool,
    work: Vec<scheduler::Request>,
}
impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        for work in &self.work {
            work.cancelled.store(true, Ordering::SeqCst);
        }
        if self.paused {
            self.shared.pausers.fetch_sub(1, Ordering::SeqCst);
        }
        let _ = self.shared.wake.try_send(());
        if self.viewer {
            let mut state = self.shared.state.lock().unwrap();
            state.viewers -= 1;
            if state.viewers == 0 {
                state.idle_since = Instant::now();
            }
        }
        self.shared.connections.fetch_sub(1, Ordering::SeqCst);
    }
}
fn handle(stream: endpoint::Stream, shared: Arc<Shared>) -> io::Result<()> {
    let mut guard = ConnectionGuard {
        shared,
        viewer: false,
        paused: false,
        work: Vec::new(),
    };
    let wake = Arc::new(transport::Wake::default());
    let incoming =
        transport::Incoming::new(BufReader::new(stream.try_clone()?), true, wake.clone())?;
    let closed = incoming.closed_flag();
    let output_closed = closed.clone();
    let shared = guard.shared.clone();
    let mut writer = transport::Output::new(stream, move || {
        output_closed.load(Ordering::SeqCst) || shared.stopping.load(Ordering::SeqCst)
    });
    let mut paused_reply: Option<String> = None;
    let mut replies = Vec::new();
    while !guard.shared.stopping.load(Ordering::SeqCst) && !closed.load(Ordering::SeqCst) {
        let mut delivery_error = None;
        type ReplyInbox = (std::sync::mpsc::Receiver<Value>, Arc<Mutex<Option<Value>>>);
        replies.retain(|(receiver, progress): &ReplyInbox| {
            let mut events = Vec::new();
            let mut connected = true;
            {
                let mut progress = progress.lock().unwrap();
                loop {
                    match receiver.try_recv() {
                        Ok(event) => events.push(event),
                        Err(std::sync::mpsc::TryRecvError::Empty) => break,
                        Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                            connected = false;
                            break;
                        }
                    }
                }
                if let Some(snapshot) = progress.take() {
                    events.push(snapshot);
                }
            }
            for event in events {
                if let Err(error) = protocol::send(&mut writer, &event) {
                    delivery_error = Some(error);
                    return false;
                }
            }
            connected
        });
        if let Some(error) = delivery_error {
            return Err(error);
        }
        if guard
            .work
            .iter()
            .any(|work| work.delivery_failed.load(Ordering::SeqCst))
        {
            return Err(io::Error::other(
                "viewer is not consuming collection events",
            ));
        }
        guard
            .work
            .retain(|work| !work.completed.load(Ordering::SeqCst));
        if paused_reply.is_some() && guard.shared.state.lock().unwrap().state == "paused" {
            protocol::send(
                &mut writer,
                &protocol::event(&paused_reply.take().unwrap(), "paused"),
            )?;
        }
        let line = match incoming.try_recv() {
            Some(transport::Event::Frame(bytes)) => bytes,
            Some(transport::Event::Rejected(error)) => {
                protocol::send(&mut writer, &error)?;
                continue;
            }
            Some(transport::Event::Closed(error))
                if error.kind() == io::ErrorKind::UnexpectedEof =>
            {
                break;
            }
            Some(transport::Event::Closed(error)) => return Err(error),
            None => {
                wake.wait();
                continue;
            }
        };
        let mut request = match protocol::decode(&line) {
            Ok(request) => request,
            Err(error) => {
                protocol::send(&mut writer, &error)?;
                if error["code"] == "unsupported_version" {
                    break;
                }
                continue;
            }
        };
        debug_assert_eq!(request.v, protocol::VERSION);
        if matches!(request.op.as_str(), "scan" | "ingest") {
            let validation = request
                .context
                .as_ref()
                .ok_or("viewer request requires explicit context".to_owned())
                .and_then(|context| context.validate(&guard.shared.key, &guard.shared.settings));
            if let Err(message) = validation {
                protocol::send(
                    &mut writer,
                    &protocol::error(&request.id, "refused", &message),
                )?;
                continue;
            }
            let invalid = if request.op == "scan" {
                request.harnesses.len() > 2
                    || request
                        .harnesses
                        .iter()
                        .any(|h| !matches!(h.as_str(), "codex" | "claude"))
                    || matches!(request.parser_workers, Some(0 | 257..))
            } else {
                !matches!(request.harness.as_deref(), Some("codex" | "claude"))
                    || request
                        .path
                        .as_ref()
                        .is_none_or(|p| !Path::new(p).is_absolute())
            };
            if invalid {
                protocol::send(
                    &mut writer,
                    &protocol::error(
                        &request.id,
                        "bad_request",
                        "invalid harness, workers or absolute ingest path",
                    ),
                )?;
                continue;
            }
            if request.op == "scan" {
                if request.harnesses.is_empty() {
                    request.harnesses = vec!["codex".into(), "claude".into()];
                }
                request.harnesses.sort();
                request.harnesses.dedup();
                request.force = Some(request.force.unwrap_or(false));
                request.parser_workers = Some(
                    request
                        .parser_workers
                        .unwrap_or_else(crate::cli::default_parser_workers),
                );
            }
            let (sender, receiver) = std::sync::mpsc::sync_channel(32);
            let state = guard.shared.state.lock().unwrap();
            let mut requests = guard.shared.requests.lock().unwrap();
            if state.state == "stopping"
                || requests.len() >= 64
                || guard.work.len() >= 64
                || guard.work.iter().any(|w| w.request.id == request.id)
            {
                let reply = protocol::error(
                    &request.id,
                    "refused",
                    "resident stopping, duplicate id or request queue full",
                );
                drop(requests);
                drop(state);
                protocol::send(&mut writer, &reply)?;
                continue;
            }
            let work = scheduler::Request::new(request, sender);
            guard.work.push(work.clone());
            replies.push((receiver, work.progress.clone()));
            requests.push_back(work);
            let _ = guard.shared.wake.try_send(());
            continue;
        }
        if request.op == "cancel" {
            if let Some(work) = guard.work.iter().find(|work| {
                Some(&work.request.id) == request.target.as_ref()
                    && !work.completed.load(Ordering::SeqCst)
            }) {
                work.cancelled.store(true, Ordering::SeqCst);
                let _ = guard.shared.wake.try_send(());
            } else {
                protocol::send(
                    &mut writer,
                    &protocol::error(
                        &request.id,
                        "bad_request",
                        "unknown cancellation target on this connection",
                    ),
                )?;
            }
            continue;
        }
        if request.op == "pause" {
            let state = guard.shared.state.lock().unwrap();
            if !guard.paused {
                guard.shared.pausers.fetch_add(1, Ordering::SeqCst);
                guard.paused = true;
            }
            drop(state);
            if paused_reply.is_some() {
                protocol::send(
                    &mut writer,
                    &protocol::error(
                        &request.id,
                        "bad_request",
                        "pause acknowledgement already pending",
                    ),
                )?;
            } else {
                paused_reply = Some(request.id);
            }
            let _ = guard.shared.wake.try_send(());
            continue;
        }
        if request.op == "resume" {
            if guard.paused {
                guard.shared.pausers.fetch_sub(1, Ordering::SeqCst);
                guard.paused = false;
            }
            if let Some(id) = paused_reply.take() {
                protocol::send(
                    &mut writer,
                    &protocol::error(&id, "refused", "pause withdrawn before acknowledgement"),
                )?;
            }
            protocol::send(&mut writer, &protocol::event(&request.id, "resumed"))?;
            let _ = guard.shared.wake.try_send(());
            continue;
        }
        let notification = (request.op == "notify"
            && request
                .queue
                .as_ref()
                .is_none_or(|queue| queue == &guard.shared.queue)
            && request
                .database_key
                .as_ref()
                .is_none_or(|key| key == &guard.shared.key))
        .then(|| {
            scheduler::prepare_notification(
                &guard.shared.queue,
                &guard.shared.key,
                request.entry.as_deref().unwrap_or(""),
                Duration::from_millis(250),
            )
        });
        let mut state = guard.shared.state.lock().unwrap();
        let reply = match request.op.as_str() {
            "hello" => {
                let mut reply = register_hello(&request, &mut state, &mut guard.viewer);
                reply["database_key"] = json!(guard.shared.key);
                reply["queue"] = json!(guard.shared.queue);
                reply
            }
            "status" => {
                let mut reply = status(&request.id, &state);
                reply["queue"]["pending"] = json!(guard.shared.pending.lock().unwrap().len());
                reply["queue"]["claimed"] = json!(guard.shared.pending.lock().unwrap().claimed);
                reply["work_requests"] = json!(guard.shared.requests.lock().unwrap().len());
                reply
            }
            "notify" => {
                if state.state == "stopping" {
                    json!({"v":1,"id":request.id,"event":"ack","state":"stopping"})
                } else if request
                    .queue
                    .as_ref()
                    .is_some_and(|queue| queue != &guard.shared.queue)
                    || request
                        .database_key
                        .as_ref()
                        .is_some_and(|key| key != &guard.shared.key)
                {
                    json!({"v":1,"id":request.id,"event":"ack","state":"ownership_mismatch"})
                } else {
                    let result = guard
                        .shared
                        .pending
                        .lock()
                        .unwrap()
                        .accept(notification.expect("validated notification context"));
                    state.lifetime = Lifetime::Resident;
                    json!({"v":1,"id":request.id,"event":"ack","state":result})
                }
            }
            "shutdown" => {
                guard.shared.publish_stopping(&mut state);
                protocol::event(&request.id, "stopping")
            }
            _ => protocol::error(&request.id, "bad_request", "unknown operation"),
        };
        drop(state);
        let _ = guard.shared.wake.try_send(());
        protocol::send(&mut writer, &reply)?;
    }
    Ok(())
}

/// Reserve two pipe slots while accept creates its next instance: six handlers,
/// the newly accepted stream, and the next pending listener (eight OS instances).
fn accept_loop(mut listener: endpoint::Listener, shared: Arc<Shared>) -> io::Result<()> {
    let mut handlers: Vec<thread::JoinHandle<io::Result<()>>> = Vec::new();
    let result = (|| {
        while !shared.stopping.load(Ordering::SeqCst) {
            let stream = match listener.accept() {
                Ok(stream) => stream,
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::TimedOut
                            | io::ErrorKind::WouldBlock
                            | io::ErrorKind::Interrupted
                            | io::ErrorKind::ConnectionAborted
                            | io::ErrorKind::ConnectionReset
                            | io::ErrorKind::BrokenPipe
                    ) =>
                {
                    thread::sleep(Duration::from_millis(10));
                    continue;
                }
                Err(error) => return Err(error),
            };
            for index in (0..handlers.len()).rev() {
                if handlers[index].is_finished() {
                    report_handler(handlers.swap_remove(index).join());
                }
            }
            if shared.stopping.load(Ordering::SeqCst) {
                break;
            }
            if shared.connections.load(Ordering::SeqCst) >= 6 {
                drop(stream);
                continue;
            }
            shared.connections.fetch_add(1, Ordering::SeqCst);
            let shared = shared.clone();
            handlers.push(thread::spawn(move || handle(stream, shared)));
        }
        Ok(())
    })();
    shared.stop();
    for handler in handlers {
        report_handler(handler.join());
    }
    result
}
fn report_handler(result: thread::Result<io::Result<()>>) {
    match result {
        Ok(Ok(())) => (),
        Ok(Err(error))
            if matches!(
                error.kind(),
                io::ErrorKind::BrokenPipe
                    | io::ErrorKind::ConnectionReset
                    | io::ErrorKind::TimedOut
            ) => {}
        Ok(Err(error)) => eprintln!("resident client: {error}"),
        Err(_) => eprintln!("resident client handler panicked"),
    }
}

/// A short-lived read-only probe; no migration, WAL switch, write, or retained connection.
fn database_state(database: &Path) -> Result<(), StoreError> {
    if !database.is_file() {
        return Err(StoreError::Refused("database missing".into()));
    }
    let conn = Connection::open_with_flags(
        database,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    conn.busy_timeout(Duration::from_millis(200))?;
    schema::check_writable(&conn, OwnerMode::Viewer, &database.display().to_string())
}

struct LifecycleLog {
    path: Option<PathBuf>,
}
impl LifecycleLog {
    fn new() -> io::Result<Self> {
        let Some(locations) = crate::platform_locations::PlatformLocations::current() else {
            return Ok(Self { path: None });
        };
        let directory = locations
            .queue_dir
            .parent()
            .ok_or_else(|| io::Error::other("cache location has no parent"))?;
        std::fs::create_dir_all(directory)?;
        Ok(Self {
            path: Some(directory.join("resident.log")),
        })
    }
    fn record(&self, message: &str) -> io::Result<()> {
        let Some(path) = &self.path else {
            eprintln!("resident: {message}");
            return Ok(());
        };
        if std::fs::metadata(path).is_ok_and(|m| m.len() >= 1024 * 1024) {
            let old = path.with_extension("log.1");
            match std::fs::remove_file(&old) {
                Ok(()) => (),
                Err(e) if e.kind() == io::ErrorKind::NotFound => (),
                Err(e) => return Err(e),
            }
            std::fs::rename(path, old)?;
        }
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)?;
        writeln!(
            file,
            "{} pid={} {message}",
            chrono::Utc::now().to_rfc3339(),
            std::process::id()
        )
    }
}

pub fn request(key: &str, value: &Value, timeout: Duration) -> io::Result<Value> {
    let mut stream = endpoint::connect(key, timeout)?;
    protocol::send(&mut stream, value)?;
    let mut reader = BufReader::new(stream);
    let mut line = Vec::new();
    let deadline = Instant::now() + timeout;
    loop {
        match protocol::read_frame(&mut reader, &mut line, protocol::MAX_EVENT_BYTES)? {
            protocol::Frame::Complete => break,
            protocol::Frame::Eof => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "resident closed without a reply",
                ));
            }
            protocol::Frame::Partial => (),
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "resident response timeout",
            ));
        }
    }
    let reply: Value = serde_json::from_slice(&line)?;
    if reply["v"] != protocol::VERSION || reply["id"] != value["id"] || reply["event"] == "error" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "incompatible or refused resident reply",
        ));
    }
    Ok(reply)
}

/// Bound the complete hook IPC exchange, including a stalled/squatted peer.
/// The basename and ownership metadata cross IPC; the queue remains authoritative.
pub(crate) enum HookNotify {
    Handled,
    OtherQueue,
    Unavailable,
}
pub(crate) fn notify_hook(key: &str, entry: &str) -> HookNotify {
    let queue = match instance::identity_path(&crate::hooks::queue_dir()) {
        Ok(queue) => queue,
        Err(_) => return HookNotify::Unavailable,
    };
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    let key = key.to_owned();
    let entry = entry.to_owned();
    thread::spawn(move || {
        let result = (|| {
            let hello = request(&key, &json!({"v":1,"id":"hook-hello","op":"hello","client":"hook","lifetime":"resident"}), Duration::from_millis(300))?;
            if hello["state"] == "stopping" { return Ok(HookNotify::Unavailable); }
            if hello["database_key"] != key {
                return Ok(HookNotify::Unavailable);
            }
            if hello["queue"] != json!(queue) { return Ok(HookNotify::OtherQueue); }
            let ack = request(&key, &json!({"v":1,"id":"hook-notify","op":"notify","entry":entry,"database_key":key,"queue":queue}), Duration::from_millis(300))?;
            if ack["state"] == "ownership_mismatch" { return Ok(HookNotify::OtherQueue); }
            if ack["state"] == "rejected" {
                crate::hooks::log_error(&crate::hooks::queue_dir(), "resident rejected hook notification; durable entry retained for sweep");
            }
            Ok::<_, io::Error>(if ack["event"] == "ack" && matches!(ack["state"].as_str(), Some("accepted" | "already_handled" | "rejected")) { HookNotify::Handled } else { HookNotify::Unavailable })
        })().unwrap_or(HookNotify::Unavailable);
        let _ = sender.send(result);
    });
    receiver
        .recv_timeout(Duration::from_secs(1))
        .unwrap_or(HookNotify::Unavailable)
}

pub fn run(database: &Path, lifetime: Lifetime) -> io::Result<()> {
    let options =
        crate::cli::parse_options(&[]).map_err(|_| io::Error::other("default options"))?;
    run_configured(database, lifetime, options)
}

pub(crate) fn run_configured(
    database: &Path,
    lifetime: Lifetime,
    options: crate::cli::Options,
) -> io::Result<()> {
    let log = LifecycleLog::new()?;
    let result = run_inner(database, lifetime, options, &log);
    if let Err(error) = &result
        && let Err(log_error) = log.record(&format!("failed: {error}"))
    {
        eprintln!("resident lifecycle log: {log_error}");
    }
    result
}

fn run_inner(
    database: &Path,
    lifetime: Lifetime,
    options: crate::cli::Options,
    log: &LifecycleLog,
) -> io::Result<()> {
    let signal = signals::Guard::install()?;
    let key = instance::database_key(database)?;
    let queue = crate::hooks::queue_dir();
    std::fs::create_dir_all(&queue)?;
    let queue = instance::identity_path(&queue)?;
    if let Some(parent) = std::path::absolute(database)?.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let deadline = Instant::now() + START_TIMEOUT;
    let lock_deadline = Instant::now() + Duration::from_secs(10 * 60);
    let lock = loop {
        if signal.stopping() {
            return Ok(());
        }
        if let Some(lock) = instance::InstanceLock::try_acquire(database)? {
            break lock;
        }
        let mut value = json!({"v":1,"id":"starter","op":"hello","client":"cli"});
        if lifetime == Lifetime::Resident {
            value["lifetime"] = json!("resident");
        }
        if let Ok(reply) = request(&key, &value, Duration::from_millis(200))
            && reply["event"] == "hello"
            && reply["state"] != "stopping"
        {
            if reply["database_key"] != key {
                return Err(io::Error::other("resident database identity mismatch"));
            }
            if reply["queue"] != json!(queue) {
                // Another starter won with a different queue. Keep this caller's
                // configuration and run its bounded retry policy here.
                let mut options = options.clone();
                if options.db.is_none() && options.standalone.is_none() {
                    options.db = Some(database.to_owned());
                }
                crate::cli::drain(&options, &mut io::sink())
                    .map_err(|_| io::Error::other("fallback drain failed"))?;
            }
            return Ok(());
        }
        if Instant::now() >= lock_deadline {
            log.record("startup lock wait timed out; durable work remains for the next start")?;
            return Ok(());
        }
        thread::sleep(if Instant::now() < deadline {
            Duration::from_millis(20)
        } else {
            Duration::from_secs(1)
        });
    };
    let now = Instant::now();
    let (wake, wakes) = std::sync::mpsc::sync_channel(1);
    let shared = Arc::new(Shared {
        state: Mutex::new(State {
            state: "starting",
            lifetime,
            viewers: 0,
            idle_since: now,
            started: now,
            write_hold: write_budget::hold_report(),
            last_scan: Value::Null,
        }),
        stopping: AtomicBool::new(false),
        connections: AtomicUsize::new(0),
        pending: Mutex::new(scheduler::Pending::default()),
        key: key.clone(),
        queue,
        requests: Mutex::new(std::collections::VecDeque::new()),
        wake,
        pausers: AtomicUsize::new(0),
        settings: options
            .settings
            .clone()
            .or_else(crate::settings::default_settings_file)
            .map(|p| instance::identity_path(&p))
            .transpose()?,
    });
    let listener = match endpoint::Listener::bind(&key) {
        Ok(listener) => Some(listener),
        Err(error) if error.kind() == io::ErrorKind::Unsupported => None,
        Err(error) => return Err(error),
    };
    log.record("starting")?;
    let accept = listener.map(|listener| {
        let shared = shared.clone();
        thread::spawn(move || accept_loop(listener, shared))
    });
    let mut worker = scheduler::Scheduler::new(database, options, shared.clone());
    let mut previous_state = "starting";
    let mut fatal = None;
    while !shared.stopping.load(Ordering::SeqCst) && !signal.stopping() {
        if let Err(error) = worker.tick() {
            fatal = Some(error);
            break;
        }
        let state = shared.state.lock().unwrap().state;
        if state != previous_state {
            if let Err(error) = log.record(state) {
                fatal = Some(error);
                break;
            }
            previous_state = state;
        }
        if shared.stop_if_idle(Instant::now(), || {}) {
            break;
        }
        let _ = wakes.recv_timeout(worker.wait());
    }
    shared.stop();
    if let Some(accept) = accept {
        // Wake the blocking accept without a second process or an inherited database handle.
        // A full pipe set drains within the handlers' 200 ms I/O timeouts.
        let wake_deadline = Instant::now() + Duration::from_secs(2);
        while !accept.is_finished() {
            if endpoint::connect(&key, Duration::from_millis(200)).is_ok() {
                break;
            }
            if Instant::now() >= wake_deadline {
                fatal = Some(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "could not wake resident accept loop",
                ));
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        match accept.join() {
            Ok(Ok(())) => (),
            Ok(Err(error)) => fatal = Some(error),
            Err(_) => fatal = Some(io::Error::other("resident accept loop panicked")),
        }
    }
    drop(worker);
    log.record("stopped")?;
    drop(lock);
    if let Some(error) = fatal {
        return Err(error);
    }
    Ok(())
}

pub fn info(database: &Path) -> io::Result<Value> {
    let key = instance::database_key(database)?;
    Ok(json!({"v":protocol::VERSION,"database_key":key,"endpoint":endpoint::endpoint_name(&key)?}))
}
pub fn control(database: &Path, action: &str) -> io::Result<Value> {
    if action == "info" {
        return info(database);
    }
    let key = instance::database_key(database)?;
    if action == "stop" {
        match instance::InstanceLock::try_acquire(database) {
            Ok(Some(_)) => return Ok(json!({"v":1,"event":"stopped"})),
            Ok(None) => (),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                return Ok(json!({"v":1,"event":"stopped"}));
            }
            Err(error) => return Err(error),
        }
        let reply = request(
            &key,
            &json!({"v":1,"id":"stop","op":"shutdown","reason":"resident stop"}),
            CLIENT_TIMEOUT,
        )?;
        if reply["event"] != "stopping" {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "resident did not acknowledge shutdown",
            ));
        }
        let deadline = Instant::now() + Duration::from_secs(10);
        while instance::InstanceLock::try_acquire(database)?.is_none() {
            if Instant::now() >= deadline {
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    "resident did not release its instance lock",
                ));
            }
            thread::sleep(Duration::from_millis(20));
        }
        return Ok(reply);
    }
    request(
        &key,
        &json!({"v":1,"id":"status","op":"status"}),
        CLIENT_TIMEOUT,
    )
}

// Signal handlers do only an atomic store. All teardown stays on the owner thread.
mod signals {
    use super::*;
    static STOP: AtomicBool = AtomicBool::new(false);
    pub(super) fn stopping() -> bool {
        STOP.load(Ordering::SeqCst)
    }
    pub struct Guard {
        #[cfg(unix)]
        old_int: libc::sigaction,
        #[cfg(unix)]
        old_term: libc::sigaction,
    }
    #[cfg(windows)]
    unsafe extern "system" fn handler(event: u32) -> i32 {
        if matches!(event, 0 | 1 | 2 | 5 | 6) {
            STOP.store(true, Ordering::SeqCst);
            1
        } else {
            0
        }
    }
    #[cfg(unix)]
    extern "C" fn handler(_: i32) {
        STOP.store(true, Ordering::SeqCst);
    }
    impl Guard {
        pub fn install() -> io::Result<Self> {
            STOP.store(false, Ordering::SeqCst);
            #[cfg(windows)]
            {
                // SAFETY: handler has the specified ABI and remains valid until unregistered.
                if unsafe {
                    windows_sys::Win32::System::Console::SetConsoleCtrlHandler(Some(handler), 1)
                } == 0
                {
                    return Err(io::Error::last_os_error());
                }
            }
            #[cfg(unix)]
            {
                // SAFETY: zero-initialized sigaction structs are initialized before use; the
                // handler is signal-safe and previous dispositions are retained for restoration.
                unsafe {
                    let mut action: libc::sigaction = std::mem::zeroed();
                    action.sa_sigaction = handler as usize;
                    libc::sigemptyset(&mut action.sa_mask);
                    let mut old_int = std::mem::zeroed();
                    let mut old_term = std::mem::zeroed();
                    if libc::sigaction(libc::SIGINT, &action, &mut old_int) != 0 {
                        return Err(io::Error::last_os_error());
                    }
                    if libc::sigaction(libc::SIGTERM, &action, &mut old_term) != 0 {
                        libc::sigaction(libc::SIGINT, &old_int, std::ptr::null_mut());
                        return Err(io::Error::last_os_error());
                    }
                    return Ok(Self { old_int, old_term });
                }
            }
            #[cfg(not(unix))]
            Ok(Self {})
        }
        pub fn stopping(&self) -> bool {
            STOP.load(Ordering::SeqCst)
        }
    }
    impl Drop for Guard {
        fn drop(&mut self) {
            #[cfg(windows)]
            // SAFETY: removes exactly the static handler installed by this guard.
            unsafe {
                windows_sys::Win32::System::Console::SetConsoleCtrlHandler(Some(handler), 0);
            }
            #[cfg(unix)]
            // SAFETY: restore the original, initialized dispositions from installation.
            unsafe {
                libc::sigaction(libc::SIGINT, &self.old_int, std::ptr::null_mut());
                libc::sigaction(libc::SIGTERM, &self.old_term, std::ptr::null_mut());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{TryLockError, mpsc};

    fn idle_shared() -> Arc<Shared> {
        let now = Instant::now();
        Arc::new(Shared {
            state: Mutex::new(State {
                state: "ready",
                lifetime: Lifetime::Viewer,
                viewers: 0,
                idle_since: now - VIEWER_IDLE,
                started: now,
                write_hold: write_budget::hold_report(),
                last_scan: Value::Null,
            }),
            stopping: AtomicBool::new(false),
            connections: AtomicUsize::new(0),
            pending: Mutex::new(scheduler::Pending::default()),
            key: "0000000000000000".into(),
            queue: PathBuf::new(),
            requests: Mutex::new(std::collections::VecDeque::new()),
            wake: std::sync::mpsc::sync_channel(1).0,
            pausers: AtomicUsize::new(0),
            settings: None,
        })
    }
    fn requests() -> [protocol::Request; 2] {
        [
            protocol::decode(br#"{"v":1,"id":"viewer","op":"hello","client":"viewer"}"#).unwrap(),
            protocol::decode(
                br#"{"v":1,"id":"upgrade","op":"hello","client":"launcher","lifetime":"resident"}"#,
            )
            .unwrap(),
        ]
    }

    #[test]
    fn idle_exit_publishes_stopping_before_late_hello() {
        for request in requests() {
            let shared = idle_shared();
            let owner = shared.clone();
            let (at_decision, decision) = mpsc::channel();
            let (release, resume) = mpsc::channel();
            let owner = thread::spawn(move || {
                owner.stop_if_idle(Instant::now(), || {
                    at_decision.send(()).unwrap();
                    resume.recv().unwrap();
                })
            });
            decision.recv_timeout(Duration::from_secs(5)).unwrap();
            let mut viewer = false;
            // Probe at the exact decision/publication boundary. If the mutex
            // is released, reproduce the acknowledged-but-discarded hello.
            let early = match shared.state.try_lock() {
                Ok(mut state) => Some(register_hello(&request, &mut state, &mut viewer)),
                Err(TryLockError::WouldBlock) => None,
                Err(error) => panic!("state poisoned: {error}"),
            };
            release.send(()).unwrap();
            assert!(owner.join().unwrap());
            let reply = early.unwrap_or_else(|| {
                register_hello(&request, &mut shared.state.lock().unwrap(), &mut viewer)
            });
            assert_eq!(
                reply["state"], "stopping",
                "late hello must tell its starter to wait for takeover"
            );
            assert_eq!(
                reply["lifetime"], "viewer",
                "late upgrade must not be acknowledged"
            );
            assert!(!viewer, "late viewer must not be registered");
            assert!(shared.stopping.load(Ordering::SeqCst));
        }
    }

    #[test]
    fn idle_exit_is_cancelled_when_hello_wins() {
        for request in requests() {
            let shared = idle_shared();
            let owner = shared.clone();
            let (release, resume) = mpsc::channel();
            let owner = thread::spawn(move || {
                resume.recv().unwrap();
                owner.stop_if_idle(Instant::now(), || panic!("hello cancelled idle exit"))
            });
            let mut viewer = false;
            let reply = register_hello(&request, &mut shared.state.lock().unwrap(), &mut viewer);
            release.send(()).unwrap();
            assert_eq!(reply["state"], "ready");
            assert!(!owner.join().unwrap());
            assert!(!shared.stopping.load(Ordering::SeqCst));
        }
    }
}
