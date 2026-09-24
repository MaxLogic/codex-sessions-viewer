//! Optional personal hub. Each authenticated machine has an isolated SQLite
//! database; a shared SQLite file is never opened over the network.
//!
//! The listener is a small HTTP/1.1 server on the standard library so that
//! every connection has socket read and write timeouts, a whole-request
//! deadline, and a bounded body. Each connection is served on its own thread,
//! up to a fixed limit, so a slow client cannot hold up other requests.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use rusqlite::{OpenFlags, OptionalExtension};
use serde::Deserialize;
use serde_json::value::RawValue;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::contract::{self, Record};
use crate::query;
use crate::store::schema::{StoreError, in_write_transaction};
use crate::store::{OwnerMode, Store};

/// Upload bodies above this size are refused before they are read.
pub const MAX_BODY_BYTES: usize = 64 * 1024 * 1024;
/// Every other request carries a small JSON document.
const MAX_SMALL_BODY_BYTES: usize = 8 * 1024 * 1024;
const MAX_HEADER_BYTES: usize = 32 * 1024;
/// Concurrent connections; further clients get 503 instead of waiting.
const MAX_CONNECTIONS: usize = 32;
pub const MAX_RECORDS: usize = 128;
pub const HUB_PROTOCOL_VERSION: u64 = 1;

/// Query options a hub owner may forward. Destination and output options
/// (`--db`, `--format`, `--hub`, `--hub-machine`) are chosen by the hub.
const QUERY_VALUE_OPTIONS: [&str; 18] = [
    "--query",
    "--project",
    "--path",
    "--since",
    "--until",
    "--harness",
    "--machine",
    "--limit",
    "--chars",
    "--cursor",
    "--session",
    "--ref",
    "--after-index",
    "--index",
    "--text-offset",
    "--export-format",
    "--max-chars",
    "--max-messages",
];
const QUERY_FLAG_OPTIONS: [&str; 1] = ["--include-tools"];

#[derive(Deserialize)]
pub struct HubConfig {
    pub owner_token: String,
    pub machines: BTreeMap<String, String>,
    #[serde(default)]
    pub pricing: crate::price_history::FetchConfig,
    /// Each socket read or write must progress within this time, the request
    /// head must arrive within it, and a whole request within ten times it.
    #[serde(default = "default_request_timeout")]
    pub request_timeout_seconds: u64,
}

fn default_request_timeout() -> u64 {
    30
}

#[derive(Deserialize)]
struct Upload {
    protocol: u64,
    sequence: i64,
    batch_id: String,
    records: Vec<Box<RawValue>>,
}

#[derive(Deserialize)]
struct RemoteQuery {
    protocol: u64,
    machine: String,
    args: Vec<String>,
}

#[derive(Deserialize)]
struct UsageQuery {
    protocol: u64,
    machine: String,
    #[serde(default = "default_usage_limit")]
    limit: i64,
}

fn default_usage_limit() -> i64 {
    30
}

pub fn serve(listen: &str, data_root: &Path, config_path: &Path) -> Result<(), String> {
    let address: SocketAddr = listen
        .parse()
        .map_err(|_| "--listen must be an IP:port".to_owned())?;
    if !address.ip().is_loopback() {
        return Err("the hub HTTP listener must bind to loopback; use a TLS reverse proxy for remote access".to_owned());
    }
    let config: HubConfig = serde_json::from_slice(
        &std::fs::read(config_path)
            .map_err(|error| format!("cannot read hub configuration: {error}"))?,
    )
    .map_err(|error| format!("invalid hub configuration: {error}"))?;
    if config.owner_token.len() < 24 || config.machines.values().any(|token| token.len() < 24) {
        return Err("hub credentials must contain at least 24 characters".to_owned());
    }
    let tokens: std::collections::HashSet<&str> =
        config.machines.values().map(String::as_str).collect();
    if tokens.len() != config.machines.len() || tokens.contains(config.owner_token.as_str()) {
        return Err("hub credentials must be distinct for the owner and each machine".to_owned());
    }
    if config.machines.keys().any(|id| !valid_machine_id(id)) {
        return Err("hub machine IDs must use ASCII letters, digits, '-' or '_'".to_owned());
    }
    if !(1..=3600).contains(&config.request_timeout_seconds) {
        return Err("request_timeout_seconds must be between 1 and 3600".to_owned());
    }
    std::fs::create_dir_all(data_root)
        .map_err(|error| format!("cannot create hub data directory: {error}"))?;
    for machine in config.machines.keys() {
        open_machine(data_root, machine)?;
    }
    let listener = TcpListener::bind(address)
        .map_err(|error| format!("cannot start hub listener: {error}"))?;
    let _price_worker = crate::price_history::Worker::start(data_root, config.pricing.clone())?;
    // Report the bound address, so a caller that asked for port 0 learns
    // which port it got.
    let bound = listener.local_addr().unwrap_or(address);
    println!("hub listening on http://{bound}");
    let _ = std::io::Write::flush(&mut std::io::stdout());
    let config = Arc::new(config);
    let data_root = Arc::new(data_root.to_owned());
    let active = Arc::new(AtomicUsize::new(0));
    for stream in listener.incoming() {
        let Ok(stream) = stream else {
            // For example, out of file handles: do not spin on the error.
            std::thread::sleep(Duration::from_millis(50));
            continue;
        };
        if active.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
            active.fetch_sub(1, Ordering::SeqCst);
            write_busy(&stream);
            continue;
        }
        let (config, data_root) = (config.clone(), data_root.clone());
        spawn_with_slot(&active, move || {
            serve_connection(stream, &data_root, &config);
        });
    }
    Ok(())
}

/// Releases one counted connection slot when dropped, also when the
/// connection thread panics or never starts.
struct Slot(Arc<AtomicUsize>);

impl Drop for Slot {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Runs `work` on a connection thread that holds one already counted slot.
fn spawn_with_slot(
    active: &Arc<AtomicUsize>,
    work: impl FnOnce() + Send + 'static,
) -> Option<std::thread::JoinHandle<()>> {
    let slot = Slot(active.clone());
    std::thread::Builder::new()
        .name("hub-connection".into())
        .spawn(move || {
            let _slot = slot;
            work();
        })
        .ok()
}

fn valid_machine_id(value: &str) -> bool {
    !value.is_empty()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
}

fn token_matches(expected: &str, actual: &str) -> bool {
    let expected = Sha256::digest(expected.as_bytes());
    let actual = Sha256::digest(actual.as_bytes());
    expected
        .iter()
        .zip(actual.iter())
        .fold(0u8, |diff, (a, b)| diff | (a ^ b))
        == 0
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        408 => "Request Timeout",
        409 => "Conflict",
        413 => "Content Too Large",
        431 => "Request Header Fields Too Large",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        _ => "Status",
    }
}

fn response_bytes(status: u16, value: &Value) -> Vec<u8> {
    let body = value.to_string();
    format!(
        "HTTP/1.1 {status} {}\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        reason(status),
        body.len()
    )
    .into_bytes()
}

/// Answers a client above the connection limit on the accept thread. The
/// short response fits the socket buffer, so it is written without blocking
/// and without draining the request: a silent client cannot hold the
/// listener.
fn write_busy(mut stream: &TcpStream) {
    if stream.set_nonblocking(true).is_err() {
        return;
    }
    let _ = stream.write_all(&response_bytes(
        503,
        &json!({"error":"hub is busy; retry later","code":"busy"}),
    ));
    let _ = stream.shutdown(std::net::Shutdown::Write);
}

fn write_response(mut stream: &TcpStream, status: u16, value: &Value) {
    let _ = stream
        .write_all(&response_bytes(status, value))
        .and_then(|()| stream.flush());
    let _ = stream.shutdown(std::net::Shutdown::Write);
    // Closing with unread request bytes resets the connection, which can
    // discard the response before the client reads it. Drain briefly.
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let mut sink = [0u8; 16 * 1024];
    let mut drained = 0usize;
    let deadline = Instant::now() + Duration::from_secs(2);
    while drained < 8 * 1024 * 1024 && Instant::now() < deadline {
        match stream.read(&mut sink) {
            Ok(0) | Err(_) => break,
            Ok(read) => drained += read,
        }
    }
}

/// Fails a read once the whole request exceeds its deadline; the socket read
/// timeout bounds each individual read.
struct DeadlineReader {
    inner: TcpStream,
    deadline: Instant,
}

impl Read for DeadlineReader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if Instant::now() > self.deadline {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "request deadline exceeded",
            ));
        }
        self.inner.read(buf)
    }
}

type HttpError = (u16, String);
type Connection = BufReader<DeadlineReader>;

/// A request that stops early (timeout, end of stream, or a reset
/// connection) is a transient failure: the client may send it again. It is
/// never reported as a rejected request.
fn io_error(error: &std::io::Error) -> HttpError {
    use std::io::ErrorKind;
    match error.kind() {
        ErrorKind::TimedOut | ErrorKind::WouldBlock => (408, "request timed out".to_owned()),
        ErrorKind::UnexpectedEof
        | ErrorKind::ConnectionReset
        | ErrorKind::ConnectionAborted
        | ErrorKind::BrokenPipe => (408, "request ended before it was complete".to_owned()),
        _ => (400, "cannot read request".to_owned()),
    }
}

fn read_line(reader: &mut Connection, budget: &mut usize) -> Result<String, HttpError> {
    let mut line = Vec::new();
    reader
        .by_ref()
        .take(*budget as u64 + 1)
        .read_until(b'\n', &mut line)
        .map_err(|error| io_error(&error))?;
    if line.len() > *budget {
        return Err((431, "request header is too large".to_owned()));
    }
    if !line.ends_with(b"\n") {
        // The stream ended inside the line.
        return Err((408, "request ended before it was complete".to_owned()));
    }
    *budget -= line.len();
    let text =
        String::from_utf8(line).map_err(|_| (400, "request header is not UTF-8".to_owned()))?;
    Ok(text.trim_end_matches(['\r', '\n']).to_owned())
}

struct Head {
    method: String,
    path: String,
    authorization: String,
    content_length: Option<usize>,
    chunked: bool,
    expect_continue: bool,
}

fn read_head(reader: &mut Connection) -> Result<Head, HttpError> {
    let mut budget = MAX_HEADER_BYTES;
    let request_line = read_line(reader, &mut budget)?;
    let mut parts = request_line.split(' ');
    let (Some(method), Some(path), Some(version), None) =
        (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return Err((400, "invalid request line".to_owned()));
    };
    if !version.starts_with("HTTP/1.") {
        return Err((400, "unsupported HTTP version".to_owned()));
    }
    let mut head = Head {
        method: method.to_owned(),
        path: path.to_owned(),
        authorization: String::new(),
        content_length: None,
        chunked: false,
        expect_continue: false,
    };
    loop {
        let line = read_line(reader, &mut budget)?;
        if line.is_empty() {
            return Ok(head);
        }
        // Obsolete line folding and whitespace before the colon are refused
        // (RFC 9112 5.1 and 5.2): proxies may read such a header differently.
        let Some((name, value)) = line.split_once(':') else {
            return Err((400, "invalid request header".to_owned()));
        };
        if name.is_empty() || name.bytes().any(|byte| byte == b' ' || byte == b'\t') {
            return Err((400, "invalid request header".to_owned()));
        }
        let value = value.trim_matches([' ', '\t']);
        match name.to_ascii_lowercase().as_str() {
            "authorization" => head.authorization = value.to_owned(),
            "content-length" => {
                // Digits only: `+5` is not a valid length.
                let length = Some(value)
                    .filter(|value| !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()))
                    .and_then(|value| value.parse::<usize>().ok())
                    .ok_or_else(|| (400, "invalid Content-Length".to_owned()))?;
                if head
                    .content_length
                    .is_some_and(|previous| previous != length)
                {
                    return Err((400, "conflicting Content-Length".to_owned()));
                }
                head.content_length = Some(length);
            }
            "transfer-encoding" => {
                if value.eq_ignore_ascii_case("chunked") {
                    head.chunked = true;
                } else {
                    return Err((501, "unsupported Transfer-Encoding".to_owned()));
                }
            }
            "expect" => head.expect_continue = value.eq_ignore_ascii_case("100-continue"),
            _ => {}
        }
    }
}

fn read_body(
    reader: &mut Connection,
    stream: &TcpStream,
    head: &Head,
    limit: usize,
) -> Result<Vec<u8>, HttpError> {
    let too_large = || {
        (
            413,
            format!("request body exceeds {} MiB", limit / (1024 * 1024)),
        )
    };
    if head.content_length.is_some_and(|length| length > limit) {
        return Err(too_large());
    }
    if head.expect_continue {
        let mut writer = stream;
        writer
            .write_all(b"HTTP/1.1 100 Continue\r\n\r\n")
            .map_err(|error| io_error(&error))?;
    }
    if head.chunked {
        if head.content_length.is_some() {
            return Err((400, "both Content-Length and chunked encoding".to_owned()));
        }
        let mut body = Vec::new();
        loop {
            let mut budget = 1024;
            let size_line = read_line(reader, &mut budget)?;
            let size = usize::from_str_radix(size_line.split(';').next().unwrap_or("").trim(), 16)
                .map_err(|_| (400, "invalid chunk size".to_owned()))?;
            if size == 0 {
                // Optional trailers end with an empty line.
                let mut budget = MAX_HEADER_BYTES;
                while !read_line(reader, &mut budget)?.is_empty() {}
                return Ok(body);
            }
            if body.len().saturating_add(size) > limit {
                return Err(too_large());
            }
            let start = body.len();
            body.resize(start + size, 0);
            reader
                .read_exact(&mut body[start..])
                .map_err(|error| io_error(&error))?;
            let mut terminator = [0u8; 2];
            reader
                .read_exact(&mut terminator)
                .map_err(|error| io_error(&error))?;
            if &terminator != b"\r\n" {
                return Err((400, "invalid chunk terminator".to_owned()));
            }
        }
    }
    let mut body = vec![0u8; head.content_length.unwrap_or(0)];
    reader
        .read_exact(&mut body)
        .map_err(|error| io_error(&error))?;
    Ok(body)
}

fn serve_connection(stream: TcpStream, data_root: &Path, config: &HubConfig) {
    let timeout = Duration::from_secs(config.request_timeout_seconds);
    if stream.set_read_timeout(Some(timeout)).is_err()
        || stream.set_write_timeout(Some(timeout)).is_err()
    {
        return;
    }
    let Ok(read_half) = stream.try_clone() else {
        return;
    };
    // The request head must arrive within one timeout; only a body may use
    // the longer whole-request deadline.
    let started = Instant::now();
    let mut reader = BufReader::new(DeadlineReader {
        inner: read_half,
        deadline: started + timeout,
    });
    let (status, value) = match read_head(&mut reader) {
        Ok(head) => {
            reader.get_mut().deadline = started + timeout * 10;
            handle(&head, &mut reader, &stream, data_root, config)
        }
        Err((status, message)) => (status, json!({"error": message})),
    };
    write_response(&stream, status, &value);
}

fn parse_json(body: &[u8]) -> Result<Value, HttpError> {
    serde_json::from_slice(body).map_err(|_| (400, "invalid JSON body".to_owned()))
}

fn machine_db(data_root: &Path, machine: &str) -> PathBuf {
    data_root.join(format!("{machine}.sqlite"))
}

pub(crate) fn open_machine(data_root: &Path, machine: &str) -> Result<Store, String> {
    let path = machine_db(data_root, machine);
    let first = !path.exists();
    let store = Store::open(&path, OwnerMode::Standalone).map_err(|error| error.to_string())?;
    let actual_machine = store.machine_id().map_err(|error| error.to_string())?;
    let empty_database: bool = store
        .conn
        .query_row("select not exists(select 1 from sessions)", [], |row| {
            row.get(0)
        })
        .map_err(|error| error.to_string())?;
    let has_batch_table: bool = store.conn.query_row(
        "select exists(select 1 from sqlite_schema where type = 'table' and name = 'hub_received_batches')",
        [], |row| row.get(0)
    ).map_err(|error| error.to_string())?;
    let no_received_batches = if has_batch_table {
        store
            .conn
            .query_row(
                "select not exists(select 1 from hub_received_batches)",
                [],
                |row| row.get(0),
            )
            .map_err(|error| error.to_string())?
    } else {
        true
    };
    if first
        || (empty_database && no_received_batches && actual_machine.as_deref() != Some(machine))
    {
        // Standalone bootstrap and the identity update are separate steps.
        // A crash between them leaves a valid empty DB with a generated ID.
        // Recover only while it contains no session data.
        store
            .conn
            .execute(
                "update app_metadata set value = ? where key = 'machine_id'",
                [machine],
            )
            .map_err(|error| error.to_string())?;
    } else if actual_machine.as_deref() != Some(machine) {
        return Err("hub database machine identity mismatch".to_owned());
    }
    store
        .conn
        .execute_batch("create table if not exists hub_received_batches (sequence integer primary key, batch_id text not null unique);
            create table if not exists hub_annotations (reference text primary key, revision integer not null, title text, notes text);")
        .map_err(|error| error.to_string())?;
    Ok(store)
}

/// The highest sequence the hub accepted from a machine.
fn high_water(store: &Store) -> Result<i64, String> {
    store
        .conn
        .query_row(
            "select coalesce(max(sequence), 0) from hub_received_batches",
            [],
            |row| row.get(0),
        )
        .map_err(|error| error.to_string())
}

/// `code` lets a client tell a refused record, which it sets aside, from a
/// sequence conflict or a transient failure, which keep the queue intact.
type IngestError = (u16, &'static str, String);

fn store_error(error: &StoreError) -> IngestError {
    match error {
        StoreError::Refused(message) => (409, "record_rejected", message.clone()),
        StoreError::Sql(rusqlite::Error::SqliteFailure(code, _))
            if matches!(
                code.code,
                rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked
            ) =>
        {
            (503, "busy", "hub database is busy; retry later".to_owned())
        }
        StoreError::Sql(rusqlite::Error::SqliteFailure(code, _))
            if code.code == rusqlite::ErrorCode::ConstraintViolation =>
        {
            (
                409,
                "record_rejected",
                "record violates a hub database constraint".to_owned(),
            )
        }
        _ => (500, "internal", "hub database operation failed".to_owned()),
    }
}

fn ingest(data_root: &Path, machine: &str, body: &[u8]) -> Result<Value, IngestError> {
    let upload: Upload = serde_json::from_slice(body)
        .map_err(|_| (400, "invalid_batch", "invalid upload envelope".to_owned()))?;
    if upload.protocol != HUB_PROTOCOL_VERSION {
        return Err((
            409,
            "protocol",
            "unsupported hub protocol version".to_owned(),
        ));
    }
    if upload.sequence <= 0
        || upload.batch_id.is_empty()
        || upload.batch_id.len() > 256
        || upload.records.len() > MAX_RECORDS
    {
        return Err((
            400,
            "invalid_batch",
            "invalid batch ID or record count".to_owned(),
        ));
    }
    let mut records = Vec::with_capacity(upload.records.len());
    for raw in upload.records {
        let mut envelope = contract::parse_line(raw.get())
            .map_err(|error| (400, "record_rejected", error.to_string()))?;
        if let Record::SessionSnapshot(snapshot) = &mut envelope.record {
            if snapshot
                .machine_id
                .as_deref()
                .is_some_and(|id| id != machine)
            {
                return Err((
                    403,
                    "record_rejected",
                    "record machine does not match credential".to_owned(),
                ));
            }
            snapshot.machine_id = Some(machine.to_owned());
        }
        records.push(envelope);
    }
    let store = open_machine(data_root, machine).map_err(|error| (500, "internal", error))?;
    let sequence = upload.sequence;
    let batch_id = upload.batch_id;
    // The sequence check, the records, and the received-batch row commit in
    // one immediate transaction: concurrent uploads serialize, and a failed
    // record leaves neither data nor a consumed sequence behind.
    let outcome = in_write_transaction(&store.conn, || {
        let received: Option<String> = store
            .conn
            .query_row(
                "select batch_id from hub_received_batches where sequence = ?",
                [sequence],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(received) = received {
            if received != batch_id {
                return Ok(Err((
                    409,
                    "sequence_conflict",
                    "sequence was already used by another batch".to_owned(),
                )));
            }
            return Ok(Ok(true));
        }
        let previous: i64 = store.conn.query_row(
            "select coalesce(max(sequence), 0) from hub_received_batches",
            [],
            |row| row.get(0),
        )?;
        let batch_reused: bool = store.conn.query_row(
            "select exists(select 1 from hub_received_batches where batch_id = ?)",
            [&batch_id],
            |row| row.get(0),
        )?;
        if batch_reused {
            return Ok(Err((
                409,
                "sequence_conflict",
                "batch ID was already accepted under another sequence".to_owned(),
            )));
        }
        if sequence != previous + 1 {
            return Ok(Err((
                409,
                "sequence_conflict",
                format!(
                    "upload sequence {sequence} does not follow the hub's last accepted sequence {previous}"
                ),
            )));
        }
        store.apply(records)?;
        store.conn.execute(
            "insert into hub_received_batches(sequence, batch_id) values (?, ?)",
            rusqlite::params![sequence, batch_id],
        )?;
        Ok(Ok(false))
    });
    let duplicate = outcome.map_err(|error| store_error(&error))??;
    Ok(
        json!({"protocol": HUB_PROTOCOL_VERSION, "sequence": sequence, "batch_id": batch_id, "duplicate": duplicate}),
    )
}

/// Only listed query options are forwarded; every option name is checked,
/// and each option's value is skipped exactly as the query parser consumes it.
fn allowed_query_arguments(args: &[String]) -> bool {
    if args.is_empty() || args.len() > 40 || args[0].starts_with('-') {
        return false;
    }
    let mut index = 1;
    while index < args.len() {
        let arg = &args[index];
        let (name, inline_value) = match arg.split_once('=') {
            Some((name, _)) if name.starts_with("--") => (name, true),
            _ => (arg.as_str(), false),
        };
        if QUERY_FLAG_OPTIONS.contains(&name) && !inline_value {
            index += 1;
        } else if QUERY_VALUE_OPTIONS.contains(&name) {
            index += if inline_value { 1 } else { 2 };
        } else {
            return false;
        }
    }
    index == args.len()
}

fn remote_query(data_root: &Path, config: &HubConfig, value: Value) -> Result<Value, HttpError> {
    let query_request: RemoteQuery =
        serde_json::from_value(value).map_err(|_| (400, "invalid query envelope".to_owned()))?;
    if query_request.protocol != HUB_PROTOCOL_VERSION {
        return Err((409, "unsupported hub protocol version".to_owned()));
    }
    if !config.machines.contains_key(&query_request.machine) {
        return Err((404, "unknown machine".to_owned()));
    }
    let path = machine_db(data_root, &query_request.machine);
    let mut args = query_request.args;
    if !allowed_query_arguments(&args) {
        return Err((400, "invalid query arguments".to_owned()));
    }
    args.extend([
        "--db".to_owned(),
        path.display().to_string(),
        "--format".to_owned(),
        "json".to_owned(),
    ]);
    let mut out = Vec::new();
    let mut err = Vec::new();
    let code = query::run(&args, &mut out, &mut err);
    if code != 0 {
        let status = match code {
            2 => 400,
            3 => 403,
            _ => 404,
        };
        return Err((status, "query failed".to_owned()));
    }
    let mut payload: Value =
        serde_json::from_slice(&out).map_err(|_| (500, "invalid query response".to_owned()))?;
    if let Value::Object(fields) = &mut payload {
        fields.remove("database");
        fields.insert("machine".to_owned(), json!(query_request.machine));
        fields.insert("hub_protocol".to_owned(), json!(HUB_PROTOCOL_VERSION));
    }
    Ok(payload)
}

fn remote_usage(data_root: &Path, config: &HubConfig, value: Value) -> Result<Value, HttpError> {
    let request: UsageQuery =
        serde_json::from_value(value).map_err(|_| (400, "invalid usage query".to_owned()))?;
    if request.protocol != HUB_PROTOCOL_VERSION {
        return Err((409, "unsupported hub protocol version".to_owned()));
    }
    if !config.machines.contains_key(&request.machine) {
        return Err((404, "unknown machine".to_owned()));
    }
    if !(1..=365).contains(&request.limit) {
        return Err((400, "usage limit must be between 1 and 365".to_owned()));
    }
    let conn = rusqlite::Connection::open_with_flags(
        machine_db(data_root, &request.machine),
        OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .map_err(|_| (500, "cannot open hub usage database".to_owned()))?;
    conn.pragma_update(None, "query_only", "on")
        .map_err(|_| (500, "cannot prepare usage query".to_owned()))?;
    let mut statement = conn
        .prepare(
            "select day_utc, sum(input_tokens), sum(cached_input_tokens),
                sum(cache_write_input_tokens), sum(output_tokens), sum(total_tokens)
         from usage_session_daily where branch_scope = 'local'
         group by day_utc order by day_utc desc limit ?",
        )
        .map_err(|_| (500, "cannot prepare usage query".to_owned()))?;
    let rows = statement
        .query_map([request.limit], |row| {
            Ok(json!({
                "day_utc": row.get::<_, String>(0)?,
                "input_tokens": row.get::<_, i64>(1)?,
                "cached_input_tokens": row.get::<_, i64>(2)?,
                "cache_write_input_tokens": row.get::<_, i64>(3)?,
                "output_tokens": row.get::<_, i64>(4)?,
                "total_tokens": row.get::<_, i64>(5)?,
            }))
        })
        .map_err(|_| (500, "usage query failed".to_owned()))?
        .collect::<Result<Vec<_>, _>>()
        .map_err(|_| (500, "usage query failed".to_owned()))?;
    Ok(json!({"protocol":HUB_PROTOCOL_VERSION,"machine":request.machine,"days":rows}))
}

fn reply(result: Result<Value, HttpError>) -> (u16, Value) {
    match result {
        Ok(value) => (200, value),
        Err((status, message)) => (status, json!({"error": message})),
    }
}

/// Authentication is checked before any request body is read.
fn handle(
    head: &Head,
    reader: &mut Connection,
    stream: &TcpStream,
    data_root: &Path,
    config: &HubConfig,
) -> (u16, Value) {
    let method = head.method.as_str();
    let path = head.path.as_str();
    if method == "GET" && path == "/v1/health" {
        return (200, json!({"protocol": HUB_PROTOCOL_VERSION}));
    }
    let token = head
        .authorization
        .strip_prefix("Bearer ")
        .unwrap_or_default();
    let machine = config
        .machines
        .iter()
        .find_map(|(machine, expected)| token_matches(expected, token).then_some(machine.as_str()));
    let owner = token_matches(&config.owner_token, token);
    let machine_route = matches!(
        (method, path),
        ("POST", "/v1/prices/sync" | "/v1/ingest") | ("GET", "/v1/verify")
    );
    let owner_route = matches!(
        (method, path),
        (
            "POST",
            "/v1/annotations" | "/v1/annotations/edit" | "/v1/query" | "/v1/usage"
        ) | ("GET", "/v1/machines")
    );
    if !machine_route && !owner_route {
        return (404, json!({"error":"unknown route"}));
    }
    if machine_route && machine.is_none() {
        return (401, json!({"error":"invalid machine credential"}));
    }
    if owner_route && !owner {
        return (401, json!({"error":"invalid owner credential"}));
    }
    let limit = if path == "/v1/ingest" {
        MAX_BODY_BYTES
    } else {
        MAX_SMALL_BODY_BYTES
    };
    let body = if method == "POST" {
        match read_body(reader, stream, head, limit) {
            Ok(body) => body,
            Err((status, message)) => {
                let code = if status == 413 {
                    "record_rejected"
                } else {
                    "request"
                };
                return (status, json!({"error": message, "code": code}));
            }
        }
    } else {
        Vec::new()
    };
    match (method, path) {
        ("POST", "/v1/prices/sync") => reply(parse_json(&body).and_then(|value| {
            crate::price_history::synchronize(data_root, machine.unwrap_or_default(), value)
        })),
        ("POST", "/v1/annotations") => reply(
            parse_json(&body)
                .and_then(|value| crate::hub_annotations::read(data_root, config, value)),
        ),
        ("POST", "/v1/annotations/edit") => reply(
            parse_json(&body)
                .and_then(|value| crate::hub_annotations::edit(data_root, config, value)),
        ),
        ("GET", "/v1/verify") => {
            let machine = machine.unwrap_or_default();
            let high_water =
                match open_machine(data_root, machine).and_then(|store| high_water(&store)) {
                    Ok(value) => value,
                    Err(_) => {
                        return (500, json!({"error":"cannot read hub delivery state"}));
                    }
                };
            (
                200,
                json!({
                    "protocol": HUB_PROTOCOL_VERSION,
                    "schema_version": crate::store::schema::SUPPORTED_SCHEMA_VERSION,
                    "contract": crate::contract::CONTRACT_NAME,
                    "contract_version": crate::contract::CONTRACT_VERSION,
                    "machine_id": machine,
                    "high_water": high_water
                }),
            )
        }
        ("POST", "/v1/ingest") => match ingest(data_root, machine.unwrap_or_default(), &body) {
            Ok(value) => (200, value),
            Err((status, code, message)) => (status, json!({"error": message, "code": code})),
        },
        ("POST", "/v1/query") => {
            reply(parse_json(&body).and_then(|value| remote_query(data_root, config, value)))
        }
        ("POST", "/v1/usage") => {
            reply(parse_json(&body).and_then(|value| remote_usage(data_root, config, value)))
        }
        ("GET", "/v1/machines") => {
            let machines: Vec<&str> = config.machines.keys().map(String::as_str).collect();
            (
                200,
                json!({"protocol":HUB_PROTOCOL_VERSION,"machines":machines}),
            )
        }
        _ => (404, json!({"error":"unknown route"})),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_panicking_connection_releases_its_slot() {
        let active = Arc::new(AtomicUsize::new(1));
        let handle = spawn_with_slot(&active, || panic!("synthetic connection failure"))
            .expect("connection thread starts");
        assert!(handle.join().is_err());
        assert_eq!(active.load(Ordering::SeqCst), 0);
    }
}
