//! Optional personal hub. Each authenticated machine has an isolated SQLite
//! database; a shared SQLite file is never opened over the network.

use std::collections::BTreeMap;
use std::io::Read;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};

use rusqlite::{OpenFlags, OptionalExtension};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tiny_http::{Header, Method, Request, Response, Server, StatusCode};

use crate::contract::{self, Record};
use crate::query;
use crate::store::{OwnerMode, Store};

const MAX_BODY_BYTES: u64 = 64 * 1024 * 1024;
const MAX_RECORDS: usize = 128;
pub const HUB_PROTOCOL_VERSION: u64 = 1;

#[derive(Deserialize)]
pub struct HubConfig {
    pub owner_token: String,
    pub machines: BTreeMap<String, String>,
    #[serde(default)]
    pub pricing: crate::price_history::FetchConfig,
}

#[derive(Deserialize)]
struct Upload {
    protocol: u64,
    sequence: i64,
    batch_id: String,
    records: Vec<Value>,
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
    std::fs::create_dir_all(data_root)
        .map_err(|error| format!("cannot create hub data directory: {error}"))?;
    for machine in config.machines.keys() {
        open_machine(data_root, machine)?;
    }
    let server =
        Server::http(address).map_err(|error| format!("cannot start hub listener: {error}"))?;
    let _price_worker = crate::price_history::Worker::start(data_root, config.pricing.clone())?;
    println!("hub listening on http://{address}");
    for request in server.incoming_requests() {
        handle(request, data_root, &config);
    }
    Ok(())
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

fn bearer(request: &Request) -> &str {
    request
        .headers()
        .iter()
        .find(|header| header.field.equiv("Authorization"))
        .and_then(|header| header.value.as_str().strip_prefix("Bearer "))
        .unwrap_or("")
}

fn respond(request: Request, status: u16, value: Value) {
    let header = Header::from_bytes("Content-Type", "application/json; charset=utf-8").unwrap();
    let response = Response::from_string(value.to_string())
        .with_status_code(StatusCode(status))
        .with_header(header);
    let _ = request.respond(response);
}

fn body(request: &mut Request) -> Result<Value, (u16, String)> {
    let mut bytes = Vec::new();
    request
        .as_reader()
        .take(MAX_BODY_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| (400, "cannot read request body".to_owned()))?;
    if bytes.len() as u64 > MAX_BODY_BYTES {
        return Err((413, "request body exceeds 64 MiB".to_owned()));
    }
    serde_json::from_slice(&bytes).map_err(|_| (400, "invalid JSON body".to_owned()))
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

fn ingest(data_root: &Path, machine: &str, value: Value) -> Result<Value, (u16, String)> {
    let upload: Upload =
        serde_json::from_value(value).map_err(|_| (400, "invalid upload envelope".to_owned()))?;
    if upload.protocol != HUB_PROTOCOL_VERSION {
        return Err((409, "unsupported hub protocol version".to_owned()));
    }
    if upload.sequence <= 0
        || upload.batch_id.is_empty()
        || upload.batch_id.len() > 128
        || upload.records.len() > MAX_RECORDS
    {
        return Err((400, "invalid batch ID or record count".to_owned()));
    }
    let mut records = Vec::with_capacity(upload.records.len());
    for value in upload.records {
        let mut envelope =
            contract::parse_line(&value.to_string()).map_err(|error| (400, error.to_string()))?;
        if let Record::SessionSnapshot(snapshot) = &mut envelope.record {
            if snapshot
                .machine_id
                .as_deref()
                .is_some_and(|id| id != machine)
            {
                return Err((403, "record machine does not match credential".to_owned()));
            }
            snapshot.machine_id = Some(machine.to_owned());
        }
        records.push(envelope);
    }
    let store = open_machine(data_root, machine).map_err(|error| (500, error))?;
    let received: Option<String> = store
        .conn
        .query_row(
            "select batch_id from hub_received_batches where sequence = ?",
            [upload.sequence],
            |row| row.get(0),
        )
        .optional()
        .map_err(|error| (500, error.to_string()))?;
    if let Some(received) = received {
        if received != upload.batch_id {
            return Err((409, "sequence was already used by another batch".to_owned()));
        }
        return Ok(
            json!({"protocol": HUB_PROTOCOL_VERSION, "sequence": upload.sequence, "batch_id": upload.batch_id, "duplicate": true}),
        );
    }
    let previous: i64 = store
        .conn
        .query_row(
            "select coalesce(max(sequence), 0) from hub_received_batches",
            [],
            |row| row.get(0),
        )
        .map_err(|error| (500, error.to_string()))?;
    if upload.sequence != previous + 1 {
        return Err((
            409,
            "upload sequence has a gap or is older than the accepted revision".to_owned(),
        ));
    }
    store
        .apply(records)
        .map_err(|error| (409, error.to_string()))?;
    store
        .conn
        .execute(
            "insert into hub_received_batches(sequence, batch_id) values (?, ?)",
            rusqlite::params![upload.sequence, upload.batch_id],
        )
        .map_err(|error| (500, error.to_string()))?;
    Ok(
        json!({"protocol": HUB_PROTOCOL_VERSION, "sequence": upload.sequence, "batch_id": upload.batch_id, "duplicate": false}),
    )
}

fn remote_query(
    data_root: &Path,
    config: &HubConfig,
    value: Value,
) -> Result<Value, (u16, String)> {
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
    if args.is_empty()
        || args.len() > 40
        || args.iter().any(|arg| {
            arg == "--db"
                || arg.starts_with("--db=")
                || arg == "--format"
                || arg.starts_with("--format=")
        })
    {
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
        return Err((if code == 2 { 400 } else { 404 }, "query failed".to_owned()));
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

fn remote_usage(
    data_root: &Path,
    config: &HubConfig,
    value: Value,
) -> Result<Value, (u16, String)> {
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

fn handle(mut request: Request, data_root: &Path, config: &HubConfig) {
    if request.method() == &Method::Get && request.url() == "/v1/health" {
        return respond(request, 200, json!({"protocol": HUB_PROTOCOL_VERSION}));
    }
    let token = bearer(&request);
    let machine = config
        .machines
        .iter()
        .find_map(|(machine, expected)| token_matches(expected, token).then_some(machine.as_str()));
    match (request.method(), request.url()) {
        (&Method::Post, "/v1/prices/sync") => {
            let Some(machine) = machine else {
                return respond(request, 401, json!({"error":"invalid machine credential"}));
            };
            let result = body(&mut request)
                .and_then(|value| crate::price_history::synchronize(data_root, machine, value));
            match result {
                Ok(value) => respond(request, 200, value),
                Err((status, message)) => respond(request, status, json!({"error":message})),
            }
        }
        (&Method::Post, "/v1/annotations" | "/v1/annotations/edit") => {
            if !token_matches(&config.owner_token, token) {
                return respond(request, 401, json!({"error":"invalid owner credential"}));
            }
            let edit = request.url().ends_with("/edit");
            let result = body(&mut request).and_then(|value| {
                if edit {
                    crate::hub_annotations::edit(data_root, config, value)
                } else {
                    crate::hub_annotations::read(data_root, config, value)
                }
            });
            match result {
                Ok(value) => respond(request, 200, value),
                Err((status, message)) => respond(request, status, json!({"error":message})),
            }
        }
        (&Method::Get, "/v1/verify") => {
            let Some(machine) = machine else {
                return respond(request, 401, json!({"error":"invalid machine credential"}));
            };
            respond(
                request,
                200,
                json!({
                    "protocol": HUB_PROTOCOL_VERSION,
                    "schema_version": crate::store::schema::SUPPORTED_SCHEMA_VERSION,
                    "contract": crate::contract::CONTRACT_NAME,
                    "contract_version": crate::contract::CONTRACT_VERSION,
                    "machine_id": machine
                }),
            )
        }
        (&Method::Post, "/v1/ingest") => {
            let Some(machine) = machine else {
                return respond(request, 401, json!({"error":"invalid machine credential"}));
            };
            let result = body(&mut request).and_then(|value| ingest(data_root, machine, value));
            match result {
                Ok(value) => respond(request, 200, value),
                Err((status, message)) => respond(request, status, json!({"error": message})),
            }
        }
        (&Method::Post, "/v1/query") => {
            if !token_matches(&config.owner_token, token) {
                return respond(request, 401, json!({"error":"invalid owner credential"}));
            }
            let result =
                body(&mut request).and_then(|value| remote_query(data_root, config, value));
            match result {
                Ok(value) => respond(request, 200, value),
                Err((status, message)) => respond(request, status, json!({"error": message})),
            }
        }
        (&Method::Post, "/v1/usage") => {
            if !token_matches(&config.owner_token, token) {
                return respond(request, 401, json!({"error":"invalid owner credential"}));
            }
            let result =
                body(&mut request).and_then(|value| remote_usage(data_root, config, value));
            match result {
                Ok(value) => respond(request, 200, value),
                Err((status, message)) => respond(request, status, json!({"error": message})),
            }
        }
        (&Method::Get, "/v1/machines") => {
            if !token_matches(&config.owner_token, token) {
                return respond(request, 401, json!({"error":"invalid owner credential"}));
            }
            let machines: Vec<&str> = config.machines.keys().map(String::as_str).collect();
            respond(
                request,
                200,
                json!({"protocol":HUB_PROTOCOL_VERSION,"machines":machines}),
            )
        }
        _ => respond(request, 404, json!({"error":"unknown route"})),
    }
}
