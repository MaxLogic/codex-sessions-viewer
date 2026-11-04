//! Native-pipe regression for losing a successor during its hello exchange.
use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

#[test]
fn reconnect_recognizes_the_windows_pipe_not_connected_error() {
    // Observed from a real pipe write in the Windows resident target. Rust
    // currently classifies error 233 as Uncategorized rather than NotConnected.
    let error = io::Error::from_raw_os_error(
        windows_sys::Win32::Foundation::ERROR_PIPE_NOT_CONNECTED as i32,
    );
    assert!(retryable_hello_error(&error), "{error:?}");
    assert!(!retryable_hello_error(&io::ErrorKind::InvalidData.into()));
    assert!(!retryable_hello_error(
        &io::ErrorKind::PermissionDenied.into()
    ));
}

#[test]
fn reconnect_survives_a_disconnect_during_hello() {
    let parent = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("target/test-sandboxes");
    std::fs::create_dir_all(&parent).unwrap();
    let root = parent.join(format!(
        "reconnect-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir(&root).unwrap();
    let context = Context {
        database: root.join("viewer.sqlite"),
        settings: None,
        windows_root: None,
        wsl_root: None,
        wsl_unc_root: None,
        claude_roots: Vec::new(),
        claude_wsl_roots: Vec::new(),
        wsl_projects: false,
        t3_state_path: None,
    };
    let key = instance::database_key(&context.database).unwrap();
    // A live owner remains throughout: a transport failure must neither replace
    // it nor launch a competing resident. Only a later compatible hello wins.
    let lock = instance::InstanceLock::try_acquire(&context.database)
        .unwrap()
        .unwrap();
    let mut listener = endpoint::Listener::bind(&key).unwrap();
    let stopped = Arc::new(AtomicBool::new(false));
    let stop = stopped.clone();
    let server = std::thread::spawn(move || -> io::Result<usize> {
        let until = Instant::now() + Duration::from_secs(10);
        for attempt in 0..2 {
            let stream = loop {
                if stop.load(Ordering::SeqCst) {
                    return Ok(attempt);
                }
                match listener.accept() {
                    Ok(stream) => break stream,
                    Err(error) if error.kind() == io::ErrorKind::TimedOut => {
                        if Instant::now() >= until {
                            return Err(error);
                        }
                    }
                    Err(error) => return Err(error),
                }
            };
            let mut reader = BufReader::new(stream);
            let request = receive_until(&mut reader, until)?;
            assert_eq!(request["op"], "hello", "collection request was replayed");
            if attempt == 0 {
                // Deterministically close after the client sends hello, before
                // any reply. This is the handshake boundary a dying owner loses.
                continue;
            }
            let instant = Instant::now();
            let state = crate::resident::State {
                state: "ready",
                lifetime: crate::resident::Lifetime::Viewer,
                viewers: 0,
                idle_since: instant,
                started: instant,
                write_hold: crate::store::write_budget::hold_report(),
                last_scan: Value::Null,
            };
            let mut hello = crate::resident::hello("bridge-hello", &state);
            hello["database_key"] = json!(key);
            protocol::send(reader.get_mut(), &hello)?;
            while !stop.load(Ordering::SeqCst) {
                match protocol::read_frame(&mut reader, &mut Vec::new(), protocol::MAX_EVENT_BYTES)
                {
                    Err(error) if error.kind() == io::ErrorKind::TimedOut => (),
                    Ok(protocol::Frame::Eof) => break,
                    other => panic!("unexpected request after reconnect: {:?}", other.err()),
                }
            }
        }
        Ok(2)
    });
    let mut connection = None;
    let mut inflight = HashMap::from([(
        "interrupted".into(),
        Pending {
            op: "scan".into(),
            target: None,
            bytes: 1,
        },
    )]);
    let mut output = Vec::new();
    let result = reconnect(
        &mut connection,
        &context,
        &mut output,
        &mut inflight,
        &io::Error::new(io::ErrorKind::BrokenPipe, "killed resident"),
        &Arc::new(transport::Wake::default()),
    );
    stopped.store(true, Ordering::SeqCst);
    drop(connection);
    let attempts = server.join().unwrap();
    drop(lock);
    std::fs::remove_file(instance::lock_path(&context.database).unwrap()).unwrap();
    std::fs::remove_dir(root).unwrap();
    assert!(
        result.is_ok(),
        "reconnect gave up on transient hello: {result:?}; events={}",
        String::from_utf8_lossy(&output)
    );
    assert_eq!(attempts.unwrap(), 2);
    assert!(inflight.is_empty());
    let events: Vec<Value> = String::from_utf8(output)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(events.len(), 3, "{events:?}");
    assert_eq!(events[0]["id"], "interrupted");
    assert_eq!(events[0]["code"], "disconnected");
    assert_eq!(events[1]["state"], "reconnecting");
    assert_eq!(events[2]["state"], "connected");
}
