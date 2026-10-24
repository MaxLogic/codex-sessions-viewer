//! Controlled time around the real attach/replace and successor lock-wait code.
//! Only process creation and the ready successor's endpoint are fixture doubles;
//! resident.rs separately exercises native process startup, serving and teardown.
use super::*;
use std::{
    cell::RefCell,
    sync::{
        Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread::{self, JoinHandle},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Actor {
    Bridge,
    Successor,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::resident) enum Phase {
    Attach,
    Wait,
}
enum Event {
    Checkpoint(Actor, Phase, mpsc::Sender<()>),
    Shutdown,
    Bridge(io::Result<Vec<u8>>),
    Successor(io::Result<()>),
}
struct Clock {
    origin: Instant,
    millis: AtomicU64,
    cancelled: AtomicBool,
    events: mpsc::Sender<Event>,
    children: Mutex<Vec<JoinHandle<()>>>,
}
thread_local! {
    static CLOCK: RefCell<Option<(Arc<Clock>, Actor)>> = const { RefCell::new(None) };
}
fn local() -> Option<(Arc<Clock>, Actor)> {
    CLOCK.with(|c| c.borrow().clone())
}
fn with_clock(clock: Arc<Clock>, actor: Actor, f: impl FnOnce()) {
    CLOCK.with(|c| *c.borrow_mut() = Some((clock, actor)));
    struct Reset;
    impl Drop for Reset {
        fn drop(&mut self) {
            CLOCK.with(|c| c.borrow_mut().take());
        }
    }
    let _reset = Reset;
    f();
}
fn elapsed(clock: &Clock) -> u64 {
    if clock.cancelled.load(Ordering::SeqCst) {
        3_600_000
    } else {
        clock.millis.load(Ordering::SeqCst)
    }
}
pub(in crate::resident) fn now() -> Option<Instant> {
    local().map(|(c, _)| c.origin + Duration::from_millis(elapsed(&c)))
}
pub(in crate::resident) fn ticks_ms() -> Option<u64> {
    local().map(|(c, _)| 100_000 + elapsed(&c))
}
pub(in crate::resident) fn checkpoint(phase: Phase) {
    let Some((clock, actor)) = local() else {
        return;
    };
    if clock.cancelled.load(Ordering::SeqCst) {
        return;
    }
    let (resume, wait) = mpsc::channel();
    if clock
        .events
        .send(Event::Checkpoint(actor, phase, resume))
        .is_err()
    {
        return;
    }
    loop {
        match wait.recv_timeout(Duration::from_millis(50)) {
            Ok(()) | Err(mpsc::RecvTimeoutError::Disconnected) => return,
            Err(mpsc::RecvTimeoutError::Timeout) if clock.cancelled.load(Ordering::SeqCst) => {
                return;
            }
            Err(mpsc::RecvTimeoutError::Timeout) => (),
        }
    }
}

pub(super) fn spawn(args: &[String]) -> Option<io::Result<()>> {
    let (clock, _) = local()?;
    let args = args.to_vec();
    let child_clock = clock.clone();
    let child = thread::spawn(move || {
        with_clock(child_clock.clone(), Actor::Successor, || {
            let result = (|| {
                assert_eq!(args[0], "serve-replacement");
                // Consume the actual serialized CLI argument and the same import /
                // clamping entry point as run_configured_after_stop, then the real
                // pre/post-lock expiry checks. No independent test deadline exists.
                let options = cli::parse_options(&args[1..])
                    .map_err(|_| io::Error::other("replacement options"))?;
                let database = options.db.as_ref().unwrap();
                let deadline = super::super::replacement_shutdown_deadline(&options)?;
                super::super::wait_for_stop(database, deadline)?;
                let until = Instant::now() + Duration::from_secs(5);
                let _lock = loop {
                    if let Some(lock) = instance::InstanceLock::try_acquire(database)? {
                        break lock;
                    }
                    if Instant::now() >= until {
                        return Err(io::Error::other("successor lock handoff stalled"));
                    }
                    thread::yield_now();
                };
                let key = instance::database_key(database)?;
                let mut listener = endpoint::Listener::bind(&key)?;
                while !child_clock.cancelled.load(Ordering::SeqCst) {
                    match listener.accept() {
                        Ok(stream) => {
                            let mut reader = BufReader::new(stream);
                            let request = read(&mut reader)?;
                            assert_eq!(request["op"], "hello");
                            protocol::send(reader.get_mut(), &hello(&key))?;
                        }
                        Err(e) if e.kind() == io::ErrorKind::TimedOut => (),
                        Err(e) => return Err(e),
                    }
                }
                Ok(())
            })();
            let _ = child_clock.events.send(Event::Successor(result));
        })
    });
    clock.children.lock().unwrap().push(child);
    Some(Ok(()))
}

fn hello(key: &str) -> Value {
    let instant = Instant::now();
    let state = super::super::State {
        state: "ready",
        lifetime: super::super::Lifetime::Viewer,
        viewers: 0,
        idle_since: instant,
        started: instant,
        write_hold: crate::store::write_budget::hold_report(),
        last_scan: Value::Null,
    };
    let mut hello = super::super::hello("bridge-hello", &state);
    hello["database_key"] = json!(key);
    hello
}
fn read(reader: &mut BufReader<endpoint::Stream>) -> io::Result<Value> {
    let mut line = Vec::new();
    let until = Instant::now() + Duration::from_secs(20);
    loop {
        match protocol::read_frame(reader, &mut line, protocol::MAX_EVENT_BYTES) {
            Ok(protocol::Frame::Complete) => {
                return serde_json::from_slice(&line).map_err(io::Error::other);
            }
            Ok(protocol::Frame::Partial) => (),
            Err(e) if e.kind() == io::ErrorKind::TimedOut => (),
            Ok(protocol::Frame::Eof) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Err(error) => return Err(error),
        }
        if Instant::now() >= until {
            return Err(io::ErrorKind::TimedOut.into());
        }
    }
}

struct Fixture {
    clock: Arc<Clock>,
    lock: Option<instance::InstanceLock>,
    root: std::path::PathBuf,
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.clock.cancelled.store(true, Ordering::SeqCst);
        self.lock.take();
        loop {
            let children = std::mem::take(&mut *self.clock.children.lock().unwrap());
            if children.is_empty() {
                break;
            }
            for child in children {
                assert!(child.join().is_ok(), "deadline fixture thread panicked");
            }
        }
        // This unique fixture contains only its explicitly named sidecar.
        std::fs::remove_file(self.root.join("viewer.sqlite.collector.lock")).unwrap();
        std::fs::remove_dir(&self.root).unwrap();
    }
}

fn handoff_at(release_ms: u64, unsupported: bool) -> Result<(), String> {
    let root = std::env::temp_dir().join(format!(
        "replacement-clock-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir(&root).unwrap();
    eprintln!("controlled replacement fixture: {}", root.display());
    let database = root.join("viewer.sqlite");
    let key = instance::database_key(&database).unwrap();
    let (events, received) = mpsc::channel();
    let clock = Arc::new(Clock {
        origin: Instant::now(),
        millis: AtomicU64::new(0),
        cancelled: AtomicBool::new(false),
        events,
        children: Mutex::new(Vec::new()),
    });
    let mut fixture = Fixture {
        clock: clock.clone(),
        lock: Some(
            instance::InstanceLock::try_acquire(&database)
                .unwrap()
                .unwrap(),
        ),
        root,
    };
    let mut listener = endpoint::Listener::bind(&key).unwrap();
    let old_clock = clock.clone();
    let old_key = key.clone();
    let old = thread::spawn(move || {
        let accept = |listener: &mut endpoint::Listener| {
            let until = Instant::now() + Duration::from_secs(20);
            loop {
                if old_clock.cancelled.load(Ordering::SeqCst) {
                    return None;
                }
                match listener.accept() {
                    Ok(stream) => return Some(BufReader::new(stream)),
                    Err(e) if e.kind() == io::ErrorKind::TimedOut => {
                        assert!(Instant::now() < until)
                    }
                    Err(e) => panic!("old endpoint: {e}"),
                }
            }
        };
        let Some(mut reader) = accept(&mut listener) else {
            return;
        };
        assert_eq!(read(&mut reader).unwrap()["op"], "hello");
        if unsupported {
            protocol::send(
                reader.get_mut(),
                &json!({"v":2,"id":"bridge-hello","event":"error","code":"unsupported_version"}),
            )
            .unwrap();
            drop(reader);
            let Some(next) = accept(&mut listener) else {
                return;
            };
            reader = next;
        } else {
            let mut old = hello(&old_key);
            old["collector_version"] = json!("older-build");
            protocol::send(reader.get_mut(), &old).unwrap();
        }
        assert_eq!(read(&mut reader).unwrap()["op"], "shutdown");
        drop(reader); // Deliberately lose the final reply, as in the native test.
        drop(listener);
        old_clock.events.send(Event::Shutdown).unwrap();
    });
    clock.children.lock().unwrap().push(old);
    let context = Context {
        database: database.clone(),
        settings: None,
        windows_root: None,
        wsl_root: None,
        wsl_unc_root: None,
        claude_roots: Vec::new(),
        claude_wsl_roots: Vec::new(),
        wsl_projects: false,
        t3_state_path: None,
    };
    let bridge_clock = clock.clone();
    let bridge = thread::spawn(move || {
        with_clock(bridge_clock.clone(), Actor::Bridge, || {
            let mut output = Vec::new();
            let result = attach(&context, &mut output).map(|reader| {
                drop(reader);
                output
            });
            let _ = bridge_clock.events.send(Event::Bridge(result));
        })
    });
    clock.children.lock().unwrap().push(bridge);
    let (mut bridge_wait, mut successor_wait) = (None, None);
    let (mut shutdown, mut released, mut bridge_done, mut successor_done) =
        (false, false, false, false);
    while !bridge_done || !successor_done {
        let event = received
            .recv_timeout(Duration::from_secs(20))
            .map_err(|e| format!("fixture stalled: {e}"))?;
        match event {
            Event::Checkpoint(actor, phase, resume) => {
                if released && phase == Phase::Attach && release_ms > 10_000 {
                    return Err(
                        "bridge continued attachment after the original 10 s replacement deadline"
                            .into(),
                    );
                }
                if !released && phase == Phase::Wait {
                    match actor {
                        Actor::Bridge => bridge_wait = Some(resume),
                        Actor::Successor => successor_wait = Some(resume),
                    }
                } else {
                    let _ = resume.send(());
                }
            }
            Event::Shutdown => shutdown = true,
            Event::Bridge(result) => {
                if !released {
                    return Err(format!(
                        "bridge finished before controlled release: {result:?}"
                    ));
                }
                if release_ms < 10_000 {
                    let output =
                        result.map_err(|e| format!("rejected release at {release_ms} ms: {e}"))?;
                    let text = String::from_utf8(output).unwrap();
                    if !text.contains("\"state\":\"replaced\"")
                        || !text.contains("\"state\":\"connected\"")
                    {
                        return Err(format!("successor not accepted: {text}"));
                    }
                } else {
                    let error = result.err().ok_or("accepted expired replacement")?;
                    if error.kind() != io::ErrorKind::TimedOut
                        || error.to_string() != "resident did not release its instance lock"
                    {
                        return Err(format!("wrong replacement failure: {error}"));
                    }
                }
                bridge_done = true;
                if release_ms < 10_000 {
                    clock.cancelled.store(true, Ordering::SeqCst);
                }
            }
            Event::Successor(result) => {
                if release_ms < 10_000 {
                    result.map_err(|e| format!("successor rejected valid handoff: {e}"))?;
                } else if result.err().map(|e| e.kind()) != Some(io::ErrorKind::TimedOut) {
                    return Err("successor accepted expired handoff".into());
                }
                successor_done = true;
            }
        }
        if !released && shutdown && bridge_wait.is_some() && successor_wait.is_some() {
            assert!(
                instance::InstanceLock::try_acquire(&database)
                    .unwrap()
                    .is_none()
            );
            // Both real wait loops are parked before checking expiry. Time is
            // frozen until this step, independently of host scheduling/load.
            clock.millis.store(release_ms, Ordering::SeqCst);
            fixture.lock.take();
            released = true;
            bridge_wait.take().unwrap().send(()).unwrap();
            successor_wait.take().unwrap().send(()).unwrap();
        }
    }
    eprintln!(
        "controlled replacement: release_ms={release_ms} unsupported={unsupported} accepted={}",
        release_ms < 10_000
    );
    Ok(())
}

#[test]
fn replacement_obeys_the_shared_deadline_through_handoff() {
    for unsupported in [false, true] {
        for release_ms in [9_500, 10_500] {
            handoff_at(release_ms, unsupported).unwrap();
        }
    }
}
