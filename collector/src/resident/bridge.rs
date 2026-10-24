//! Viewer stdio bridge. Database access belongs exclusively to the resident.
use super::{endpoint, instance, protocol, transport, viewer::Context};
use crate::cli;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    io::{self, BufReader, Write},
    path::Path,
    sync::{Arc, mpsc},
    time::{Duration, Instant},
};

fn state(out: &mut impl Write, name: &str, detail: &str) -> io::Result<()> {
    protocol::send(
        out,
        &json!({"v":1,"event":"bridge","state":name,"detail":detail}),
    )
}

fn compatible(hello: &Value) -> bool {
    hello["protocol"] == protocol::VERSION
        && hello["viewer_protocol"] == protocol::VERSION
        && hello["collector_version"] == env!("CARGO_PKG_VERSION")
        && hello["schema"] == crate::store::schema::SUPPORTED_SCHEMA_VERSION
        && hello["contract"] == crate::contract::CONTRACT_VERSION
        && hello["parsers"]["codex"] == crate::codex::parser::PARSER_VERSION
        && hello["parsers"]["claude"] == crate::claude::parser::CLAUDE_PARSER_VERSION
}

fn valid_hello(hello: &Value, key: &str) -> bool {
    hello["v"] == protocol::VERSION
        && hello["id"] == "bridge-hello"
        && hello["event"] == "hello"
        && hello["database_key"] == key
        && hello["collector_version"].is_string()
        && hello["protocol"].is_u64()
        && hello["schema"].is_u64()
        && hello["contract"].is_u64()
        && hello["parsers"]["codex"].is_u64()
        && hello["parsers"]["claude"].is_u64()
        && hello["state"].is_string()
}

fn replace(
    reader: &mut BufReader<endpoint::Stream>,
    context: &Context,
    version: u64,
    deadline: Instant,
) -> io::Result<()> {
    // The viewer can kill this bridge after four seconds. Transfer startup to
    // a detached process *before* asking the old owner to exit. That process
    // waits for exclusion and becomes the successor, independently of stdio.
    super::stop_deadline::remaining(deadline)?;
    start(context, Some(deadline))?;
    // Identity was positively checked by attach. The old owner can exit before
    // the last frame is read, so replacement waits for exclusion, not delivery.
    let _ = protocol::send(
        reader.get_mut(),
        &json!({"v":version,"id":"bridge-replace","op":"shutdown","reason":"incompatible viewer build"}),
    ).and_then(|()| receive_until(reader, deadline));
    let key = instance::database_key(&context.database)?;
    loop {
        super::stop_deadline::remaining(deadline)?;
        if super::instance_stopped(&context.database)? {
            super::stop_deadline::remaining(deadline)?;
            return Ok(());
        }
        // The successor can acquire the lock before this bridge observes its
        // release. A positive successor hello also proves the old owner exited.
        if let Ok(stream) = endpoint::connect(
            &key,
            Duration::from_millis(200).min(deadline.saturating_duration_since(Instant::now())),
        ) {
            let mut probe = BufReader::new(stream);
            if protocol::send(
                probe.get_mut(),
                &json!({"v":1,"id":"bridge-hello","op":"hello","client":"cli"}),
            )
            .is_ok()
                && let Ok(hello) = receive_until(&mut probe, deadline)
                && valid_hello(&hello, &key)
                && compatible(&hello)
                && hello["state"] != "stopping"
            {
                super::stop_deadline::remaining(deadline)?;
                return Ok(());
            }
        }
        std::thread::sleep(
            Duration::from_millis(20).min(deadline.saturating_duration_since(Instant::now())),
        );
    }
}

fn receive_until(reader: &mut BufReader<endpoint::Stream>, until: Instant) -> io::Result<Value> {
    let mut line = Vec::new();
    let deadline = (Instant::now() + Duration::from_secs(2)).min(until);
    loop {
        match protocol::read_frame(reader, &mut line, protocol::MAX_EVENT_BYTES) {
            Ok(protocol::Frame::Complete) => {
                return serde_json::from_slice(&line).map_err(io::Error::other);
            }
            Ok(protocol::Frame::Eof) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "resident disconnected",
                ));
            }
            Ok(protocol::Frame::Partial) => (),
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) => {}
            Err(e) => return Err(e),
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "resident handshake timed out",
            ));
        }
    }
}

fn start(context: &Context, replacement_deadline: Option<Instant>) -> io::Result<()> {
    let mut args = vec![
        if replacement_deadline.is_some() {
            "serve-replacement"
        } else {
            "serve"
        }
        .into(),
        "--db".into(),
        context.database.to_string_lossy().into_owned(),
        "--lifetime".into(),
        "viewer".into(),
    ];
    if let Some(deadline) = replacement_deadline {
        args.extend([
            "--replacement-deadline-ms".into(),
            super::stop_deadline::export(deadline)?.to_string(),
        ]);
    }
    if let Some(path) = &context.settings {
        args.extend(["--settings".into(), path.to_string_lossy().into_owned()]);
    }
    for (flag, path) in [
        ("--windows-root", &context.windows_root),
        ("--wsl-root", &context.wsl_root),
        ("--wsl-unc-root", &context.wsl_unc_root),
    ] {
        args.extend([
            flag.into(),
            path.as_ref()
                .map_or_else(String::new, |p| p.to_string_lossy().into_owned()),
        ]);
    }
    for (flag, paths) in [
        ("--claude-root", &context.claude_roots),
        ("--claude-wsl-root", &context.claude_wsl_roots),
    ] {
        for path in paths {
            args.extend([flag.into(), path.to_string_lossy().into_owned()]);
        }
    }
    if context.claude_roots.is_empty() && context.claude_wsl_roots.is_empty() {
        args.extend(["--claude-root".into(), String::new()]);
    }
    if !context.wsl_projects {
        args.push("--no-wsl-projects".into());
    }
    crate::hooks::spawn_detached(&std::env::current_exe()?, &args)
}

fn attach(context: &Context, out: &mut impl Write) -> io::Result<BufReader<endpoint::Stream>> {
    let key = instance::database_key(&context.database)?;
    const ATTACH_TIMEOUT: Duration = Duration::from_secs(6);
    // Shutdown and successor attachment have separate budgets, within this
    // fixed overall bound. Repeated attempts never extend the total deadline.
    let total_deadline = Instant::now() + ATTACH_TIMEOUT + super::STOP_TIMEOUT + ATTACH_TIMEOUT;
    let mut deadline = Instant::now() + ATTACH_TIMEOUT;
    let mut started = false;
    let mut replaced = false;
    loop {
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "resident start timed out",
            ));
        }
        match endpoint::connect(
            &key,
            Duration::from_millis(200).min(deadline.saturating_duration_since(Instant::now())),
        ) {
            Ok(stream) => {
                let mut reader = BufReader::new(stream);
                protocol::send(
                    reader.get_mut(),
                    &json!({"v":1,"id":"bridge-hello","op":"hello","client":"viewer"}),
                )?;
                let hello = receive_until(&mut reader, deadline)?;
                let unsupported = hello["event"] == "error"
                    && hello["code"] == "unsupported_version"
                    && hello["id"] == "bridge-hello"
                    && hello["v"].as_u64().is_some_and(|v| v > 0);
                if unsupported {
                    if replaced {
                        return Err(io::Error::other("replacement resident is incompatible"));
                    }
                    // Unsupported versions close the connection. Request deliberate
                    // shutdown on a fresh connection using the advertised version.
                    drop(reader);
                    let mut reader =
                        BufReader::new(endpoint::connect(&key, Duration::from_millis(200))?);
                    replace(
                        &mut reader,
                        context,
                        hello["v"].as_u64().unwrap(),
                        (Instant::now() + super::STOP_TIMEOUT).min(total_deadline),
                    )?;
                    replaced = true;
                    started = true;
                    deadline = (Instant::now() + ATTACH_TIMEOUT).min(total_deadline);
                } else if !valid_hello(&hello, &key) {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "invalid resident hello",
                    ));
                } else if hello["state"] == "stopping" { /* Wait for lock release, without replacing a live build. */
                } else if compatible(&hello) {
                    if replaced {
                        state(out, "replaced", "incompatible collector identity")?;
                    }
                    state(out, "connected", "")?;
                    return Ok(reader);
                } else {
                    if replaced {
                        return Err(io::Error::other("replacement resident is incompatible"));
                    }
                    // Only positive build/protocol evidence permits replacement. I/O errors never do.
                    replace(
                        &mut reader,
                        context,
                        protocol::VERSION,
                        (Instant::now() + super::STOP_TIMEOUT).min(total_deadline),
                    )?;
                    replaced = true;
                    started = true;
                    deadline = (Instant::now() + ATTACH_TIMEOUT).min(total_deadline);
                }
            }
            Err(error) => {
                // The instance lock is a sidecar, never the database. A busy lock
                // distinguishes a starting/stalled server from an absent resident.
                let absent = match instance::InstanceLock::try_acquire(&context.database) {
                    Ok(Some(lock)) => {
                        drop(lock);
                        true
                    }
                    Ok(None) => false,
                    Err(e) if e.kind() == io::ErrorKind::NotFound => true,
                    Err(e) => return Err(e),
                };
                if absent && !started {
                    state(out, "starting", "")?;
                    start(context, None)?;
                    started = true;
                } else if Instant::now() >= deadline {
                    return Err(error);
                }
            }
        }
        if Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "resident start timed out",
            ));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

struct Pending {
    op: String,
    target: Option<String>,
    bytes: usize,
}
struct Connected {
    incoming: transport::Incoming,
    outgoing: transport::Outgoing,
}
fn connect(
    context: &Context,
    out: &mut impl Write,
    wake: &Arc<transport::Wake>,
) -> io::Result<Connected> {
    let reader = attach(context, out).inspect_err(|error| {
        let _ = state(out, "failed", &error.to_string());
    })?;
    let writer = reader.get_ref().try_clone()?;
    let incoming = transport::Incoming::new(reader, false, wake.clone())?;
    let outgoing = incoming.outgoing(writer);
    Ok(Connected { incoming, outgoing })
}
fn reconnect(
    connection: &mut Option<Connected>,
    context: &Context,
    out: &mut impl Write,
    inflight: &mut HashMap<String, Pending>,
    detail: &str,
    wake: &Arc<transport::Wake>,
) -> io::Result<()> {
    connection.take(); // Stop and join both endpoint I/O paths before reattaching.
    for (id, _) in inflight.drain() {
        protocol::send(
            out,
            &protocol::error(&id, "disconnected", "resident endpoint disconnected"),
        )?;
    }
    state(out, "reconnecting", detail)?;
    *connection = Some(connect(context, out, wake)?);
    Ok(())
}

pub(crate) fn run(options: &cli::Options) -> io::Result<()> {
    let wake = Arc::new(transport::Wake::default());
    let input = transport::Incoming::stdin(wake.clone());
    let closed = input.closed_flag();
    let output_closed = closed.clone();
    let mut out =
        transport::Output::stdout(move || output_closed.load(std::sync::atomic::Ordering::SeqCst))?;
    let result = relay(options, &mut out, &input, &wake);
    match result {
        Err(error)
            if error.kind() == io::ErrorKind::ConnectionAborted
                && closed.load(std::sync::atomic::Ordering::SeqCst) =>
        {
            Ok(())
        }
        other => other,
    }
}

fn relay(
    options: &cli::Options,
    out: &mut impl Write,
    input: &transport::Incoming,
    wake: &Arc<transport::Wake>,
) -> io::Result<()> {
    let context = Context::resolve(options).map_err(io::Error::other)?;
    let mut connection = Some(connect(&context, out, wake)?);
    let mut inflight: HashMap<String, Pending> = HashMap::new();
    let mut prepared: Option<(protocol::Request, Vec<u8>)> = None;
    let mut forwarding: Option<Vec<u8>> = None;
    loop {
        if input
            .closed_flag()
            .load(std::sync::atomic::Ordering::SeqCst)
        {
            return Ok(());
        }
        let mut active = false;
        // Forwarding never owns the endpoint reader. Even a blocked write cannot
        // prevent replies from reaching this bounded queue and releasing credits.
        for _ in 0..32 {
            let Some(event) = connection.as_ref().unwrap().incoming.try_recv() else {
                break;
            };
            active = true;
            match event {
                transport::Event::Frame(bytes) => {
                    let event: Value = serde_json::from_slice(&bytes)?;
                    if let Some(id) = event["id"].as_str() {
                        let terminal = event["event"] != "progress"
                            && (event["event"] != "finished"
                                || inflight.get(id).is_some_and(|p| p.op == "ingest"));
                        if terminal {
                            inflight.remove(id);
                            // Successful cancel has no separate v1 acknowledgement:
                            // its target's terminal event releases every cancel waiter.
                            inflight.retain(|_, p| {
                                !(p.op == "cancel" && p.target.as_deref() == Some(id))
                            });
                        }
                    }
                    protocol::send(out, &event)?;
                }
                transport::Event::Closed(error) => {
                    forwarding = None;
                    reconnect(
                        &mut connection,
                        &context,
                        out,
                        &mut inflight,
                        &error.to_string(),
                        wake,
                    )?;
                    break;
                }
                transport::Event::Rejected(error) => protocol::send(out, &error)?,
            }
        }
        if let Some(bytes) = forwarding.take() {
            match connection.as_ref().unwrap().outgoing.try_send(bytes) {
                Ok(()) => active = true,
                Err(mpsc::TrySendError::Full(bytes)) => forwarding = Some(bytes),
                Err(mpsc::TrySendError::Disconnected(_)) => {
                    reconnect(
                        &mut connection,
                        &context,
                        out,
                        &mut inflight,
                        "resident writer closed",
                        wake,
                    )?;
                }
            }
        }
        if prepared.is_none() && forwarding.is_none() {
            match input.try_recv() {
                Some(transport::Event::Closed(_)) => {
                    return Ok(());
                }
                Some(transport::Event::Rejected(error)) => {
                    active = true;
                    protocol::send(out, &error)?;
                }
                Some(transport::Event::Frame(bytes)) => {
                    active = true;
                    match protocol::decode(&bytes) {
                        Err(error) => protocol::send(out, &error)?,
                        Ok(request) => {
                            let mut value: Value = serde_json::from_slice(&bytes)?;
                            if matches!(request.op.as_str(), "scan" | "ingest") {
                                let explicit = match request.context.clone() {
                                    Some(context) => context.resolve_paths()?,
                                    None => Context::resolve(options).map_err(io::Error::other)?,
                                };
                                value["context"] = serde_json::to_value(explicit)?;
                                if let Some(path) = &request.path {
                                    value["path"] = json!(std::path::absolute(Path::new(path))?);
                                }
                            }
                            let mut bytes = serde_json::to_vec(&value)?;
                            bytes.push(b'\n');
                            if bytes.len() > protocol::MAX_REQUEST_BYTES {
                                protocol::send(
                                    out,
                                    &protocol::error(
                                        &request.id,
                                        "bad_request",
                                        "resolved request exceeds 64 KiB",
                                    ),
                                )?;
                            } else {
                                prepared = Some((request, bytes));
                            }
                        }
                    }
                }
                None => (),
            }
        }
        let is_collection = |op: &str| matches!(op, "scan" | "ingest");
        let (mut work_count, mut work_bytes, mut control_count, mut control_bytes) = (0, 0, 0, 0);
        for pending in inflight.values() {
            if is_collection(&pending.op) {
                work_count += 1;
                work_bytes += pending.bytes;
            } else {
                control_count += 1;
                control_bytes += pending.bytes;
            }
        }
        if forwarding.is_none()
            && let Some((request, bytes)) = prepared.take()
        {
            let collection = is_collection(&request.op);
            if inflight.contains_key(&request.id)
                || (collection
                    && (work_count >= 64
                        || work_bytes + bytes.len() > 64 * protocol::MAX_REQUEST_BYTES))
            {
                protocol::send(
                    out,
                    &protocol::error(
                        &request.id,
                        "refused",
                        "collection capacity exceeded or duplicate request id",
                    ),
                )?;
                active = true;
            } else if !collection
                && (control_count >= 64
                    || control_bytes + bytes.len() > protocol::MAX_REQUEST_BYTES)
            {
                prepared = Some((request, bytes));
            } else {
                inflight.insert(
                    request.id,
                    Pending {
                        op: request.op,
                        target: request.target,
                        bytes: bytes.len(),
                    },
                );
                forwarding = Some(bytes);
                active = true;
            }
        }
        if !active {
            wake.wait();
        }
    }
}
