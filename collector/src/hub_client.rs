//! Durable, optional upload of locally committed contract records.

mod continue_transport;

use std::io::Read;
use std::path::Path;
use std::time::{Duration, Instant};

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

use crate::contract::{CONTRACT_NAME, CONTRACT_VERSION, Envelope, Record};
use crate::hub_server::{HUB_PROTOCOL_VERSION, MAX_RECORDS};
use crate::store::schema::{
    SUPPORTED_SCHEMA_VERSION, StoreError, StoreResult, begin_write, finish,
};
use crate::store::writer::{session_row_id, source_status_id};
use crate::store::{OwnerMode, Store};

/// Byte budget of one batch. Small enough that a batch finishes on a slow
/// uplink within its upload timeout. A larger single record is sent alone.
pub const MAX_BATCH_BYTES: usize = 8 * 1024 * 1024;
/// Per-record limit for hubs that do not advertise compressed ingestion.
pub const LEGACY_MAX_RECORD_BYTES: usize = 48 * 1024 * 1024;
const BATCH_ENVELOPE_HEADROOM: usize = 64 * 1024;
/// After this many consecutive transport failures (for example timeouts) of
/// one in-flight batch, the batch is halved before the next attempt.
const SHRINK_AFTER_FAILURES: i64 = 2;
const INFLIGHT_FAILURES_KEY: &str = "hub.inflight_transport_failures";
/// Upper bound of batches per `hub sync` run.
const MAX_BATCHES_PER_RUN: usize = 1000;
/// How long delivery waits for the collector write lease; scans use the same.
pub(crate) const LEASE_WAIT: Duration = Duration::from_secs(600);

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncReport {
    pub sent: usize,
    pub batches: usize,
    pub dead_lettered: usize,
    pub requeued: usize,
    pub pruned: usize,
    pub pending: i64,
    pub last_sequence: i64,
}

/// The coalescing key of a record, and whether an unchanged repeat of the
/// last queued state is dropped. Scans report every source's status and every
/// thread name each time; only changes are delivered.
fn record_key(record: &Record) -> Option<(String, bool)> {
    match record {
        Record::SessionSnapshot(snapshot) => Some((
            format!(
                "session:{}",
                session_row_id(
                    &snapshot.harness,
                    snapshot.session.session_id.as_deref(),
                    &snapshot.source.path,
                )
            ),
            false,
        )),
        Record::SourceStatus(status) => Some((
            format!(
                "status:{}:{}",
                status.harness,
                source_status_id(&status.path)
            ),
            true,
        )),
        Record::ThreadName(name) => {
            Some((format!("thread:{}:{}", name.harness, name.session_id), true))
        }
        Record::ProjectHints(_) => None,
    }
}

/// Called while the local record transaction is open. No destination or
/// credential is stored with a record; hubs remain opt-in.
/// Whether records are queued for a hub. Callers that queue many records
/// check once instead of paying two queries per record.
pub fn queue_enabled(conn: &Connection) -> StoreResult<bool> {
    let table_exists: bool = conn
        .prepare_cached(
            "select exists(select 1 from sqlite_schema where type = 'table' and name = 'collector_hub_state')",
        )?
        .query_row([], |row| row.get(0))?;
    if !table_exists {
        return Ok(false);
    }
    Ok(conn
        .prepare_cached("select enabled from collector_hub_state where id = 1")?
        .query_row([], |row| row.get(0))
        .optional()?
        .unwrap_or(false))
}

pub fn enqueue(conn: &Connection, record: Record, now: &str) -> StoreResult<()> {
    let _lease = crate::store::write_lease::WriteLease::acquire(conn)?;
    // A legacy status has no provenance to add. Keep it in v1 rather than
    // inventing an environment while moving it to a new outbox row.
    let version = if matches!(&record, Record::SourceStatus(status) if status.environment.is_none())
    {
        1
    } else {
        crate::contract::CONTRACT_VERSION
    };
    enqueue_versioned(conn, record, now, version)
}

pub(crate) fn plan_delivery(
    conn: &Connection,
    records: &[Record],
    version: Option<u32>,
) -> StoreResult<Vec<bool>> {
    if !queue_enabled(conn)? {
        return Ok(vec![false; records.len()]);
    }
    #[derive(serde::Serialize)]
    struct BorrowedEnvelope<'a> {
        contract: &'static str,
        version: u32,
        #[serde(flatten)]
        record: &'a Record,
    }
    let mut predicted = std::collections::HashMap::new();
    let mut delivery = Vec::with_capacity(records.len());
    for record in records {
        let Some((key, true)) = record_key(record) else {
            delivery.push(true);
            continue;
        };
        let version = version.unwrap_or_else(|| {
            if matches!(record,Record::SourceStatus(status) if status.environment.is_none()) {
                1
            } else {
                CONTRACT_VERSION
            }
        });
        let envelope = serde_json::to_string(&BorrowedEnvelope {
            contract: CONTRACT_NAME,
            version,
            record,
        })
        .map_err(|error| StoreError::Io(std::io::Error::other(error)))?;
        let hash = crate::dart::sha256_hex(envelope.as_bytes());
        if !predicted.contains_key(&key) {
            let previous: Option<String> = conn
                .prepare_cached(
                    "select record_hash from collector_hub_record_state where record_key=?",
                )?
                .query_row([&key], |row| row.get(0))
                .optional()?;
            predicted.insert(key.clone(), previous);
        }
        delivery.push(predicted[&key].as_deref() != Some(&hash));
        predicted.insert(key, Some(hash));
    }
    Ok(delivery)
}

pub(crate) fn enqueue_versioned(
    conn: &Connection,
    record: Record,
    now: &str,
    version: u32,
) -> StoreResult<()> {
    if !queue_enabled(conn)? {
        return Ok(());
    }
    let key = record_key(&record);
    if let Record::SessionSnapshot(snapshot) = &record {
        // A new snapshot makes the source available again; a later identical
        // missing status must be delivered, not treated as unchanged.
        conn.execute(
            "delete from collector_hub_record_state where record_key = ?",
            [format!(
                "status:{}:{}",
                snapshot.harness,
                source_status_id(&snapshot.source.path)
            )],
        )?;
    }
    let envelope = serde_json::to_string(&Envelope {
        contract: crate::contract::CONTRACT_NAME.to_owned(),
        version,
        record,
    })
    .map_err(|error| StoreError::Io(std::io::Error::other(error)))?;
    let Some((key, deduplicate)) = key else {
        conn.execute(
            "insert into collector_upload_outbox(record_json, created_at_utc) values (?, ?)",
            params![envelope, now],
        )?;
        return Ok(());
    };
    if deduplicate {
        let hash = crate::dart::sha256_hex(envelope.as_bytes());
        let previous: Option<String> = conn
            .query_row(
                "select record_hash from collector_hub_record_state where record_key = ?",
                [&key],
                |row| row.get(0),
            )
            .optional()?;
        if previous.as_deref() == Some(hash.as_str()) {
            return Ok(());
        }
        conn.execute(
            "insert into collector_hub_record_state(record_key, record_hash) values (?, ?)
             on conflict(record_key) do update set record_hash = excluded.record_hash",
            params![key, hash],
        )?;
    }
    // The newest state of a source replaces any unsent older state. It is
    // appended so that delivery order still follows local commit order.
    conn.execute(
        "delete from collector_upload_outbox where record_key = ?",
        [&key],
    )?;
    conn.execute(
        "insert into collector_upload_outbox(record_json, created_at_utc, record_key) values (?, ?, ?)",
        params![envelope, now, key],
    )?;
    Ok(())
}

/// Accepts HTTPS, or plain HTTP only on a literal loopback address. A host
/// name such as `localhost` can be resolved elsewhere, so it is refused.
pub fn validate_url(url: &str) -> Result<String, String> {
    let url = url.trim_end_matches('/');
    let authority = url
        .split_once("://")
        .map(|(_, rest)| rest.split('/').next().unwrap_or(""))
        .unwrap_or("");
    if authority.is_empty() || authority.contains('@') || url.contains('?') || url.contains('#') {
        return Err(
            "hub URL must contain a host and no embedded credentials, query, or fragment"
                .to_owned(),
        );
    }
    let safe_loopback = url.starts_with("http://127.0.0.1:") || url.starts_with("http://[::1]:");
    if !url.starts_with("https://") && !safe_loopback {
        return Err("hub URL must use HTTPS, except a 127.0.0.1 or [::1] listener".to_owned());
    }
    Ok(url.to_owned())
}

fn enable(store: &Store, url: &str, machine: &str) -> Result<i64, String> {
    let _lease = crate::store::write_lease::WriteLease::acquire(&store.conn)
        .map_err(|error| error.to_string())?;
    let _phase = crate::store::write_budget::write_phase("hub");
    begin_write(&store.conn).map_err(|error| error.to_string())?;
    let result = (|| -> StoreResult<i64> {
        let previous: Option<(String, String, i64)> = store
            .conn
            .query_row(
                "select hub_url, machine_id, last_sequence from collector_hub_state where id = 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        if let Some((previous_url, previous_machine, sequence)) = previous {
            if previous_url != url || previous_machine != machine {
                return Err(StoreError::Refused(
                    "this database is paired with another hub or machine; export or reset its delivery state explicitly before switching".to_owned(),
                ));
            }
            store.conn.execute(
                "update collector_hub_state set enabled = 1 where id = 1",
                [],
            )?;
            Ok(sequence)
        } else {
            store.conn.execute(
                "insert into collector_hub_state(id, hub_url, machine_id, last_sequence, enabled) values (1, ?, ?, 0, 1)",
                params![url, machine],
            )?;
            Ok(0)
        }
    })();
    finish(&store.conn, result).map_err(|error| error.to_string())
}

/// Stops queuing and discards every queued, in-flight and dead-lettered
/// record. The pairing and acknowledged sequence are kept, so enabling again
/// continues the same hub history.
pub fn disable(db_path: &Path, mode: OwnerMode) -> Result<i64, String> {
    let store = Store::open(db_path, mode).map_err(|error| error.to_string())?;
    let _lease = crate::store::write_lease::WriteLease::acquire(&store.conn)
        .map_err(|error| error.to_string())?;
    let _phase = crate::store::write_budget::write_phase("hub");
    begin_write(&store.conn).map_err(|error| error.to_string())?;
    let result = (|| -> StoreResult<i64> {
        let cleared = pending(&store.conn)?;
        store.conn.execute_batch(
            "update collector_hub_state set enabled = 0, inflight_batch_id = null, inflight_last_id = null where id = 1;
             delete from collector_upload_outbox;
             delete from collector_hub_record_state;
             delete from collector_upload_dead_letters;",
        )?;
        Ok(cleared)
    })();
    finish(&store.conn, result).map_err(|error| error.to_string())
}

pub fn pending(conn: &Connection) -> StoreResult<i64> {
    Ok(
        conn.query_row("select count(*) from collector_upload_outbox", [], |row| {
            row.get(0)
        })?,
    )
}

pub fn dead_letters(conn: &Connection) -> StoreResult<(i64, Vec<Value>)> {
    let count: i64 = conn.query_row(
        "select count(*) from collector_upload_dead_letters",
        [],
        |row| row.get(0),
    )?;
    let mut statement = conn.prepare(
        "select id, outbox_id, record_key, failed_at_utc, http_status, error
         from collector_upload_dead_letters order by id desc limit 20",
    )?;
    let recent = statement
        .query_map([], |row| {
            Ok(json!({
                "id": row.get::<_, i64>(0)?,
                "outbox_id": row.get::<_, i64>(1)?,
                "record_key": row.get::<_, Option<String>>(2)?,
                "failed_at_utc": row.get::<_, String>(3)?,
                "http_status": row.get::<_, Option<i64>>(4)?,
                "error": row.get::<_, String>(5)?,
            }))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok((count, recent))
}

/// Time allowed for one upload: a minute plus one second per 64 KiB, so a
/// full batch still completes on an uplink of about 64 KiB/s.
fn upload_timeout(bytes: usize) -> Duration {
    Duration::from_secs(60 + (bytes / (64 * 1024)) as u64)
}

fn agent() -> ureq::Agent {
    let config = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(120)))
        .max_redirects(0)
        .http_status_as_error(false)
        .build();
    continue_transport::agent(config)
}

/// The hub's error text, limited and with the credential removed.
fn error_text(response: &mut ureq::http::Response<ureq::Body>, token: &str) -> (String, String) {
    let mut bytes = Vec::new();
    let _ = response
        .body_mut()
        .as_reader()
        .take(64 * 1024)
        .read_to_end(&mut bytes);
    let parsed: Option<Value> = serde_json::from_slice(&bytes).ok();
    let message = parsed
        .as_ref()
        .and_then(|value| value["error"].as_str())
        .map(str::to_owned)
        .unwrap_or_else(|| String::from_utf8_lossy(&bytes).into_owned());
    let code = parsed
        .as_ref()
        .and_then(|value| value["code"].as_str())
        .unwrap_or("")
        .to_owned();
    let mut message: String = message
        .chars()
        .filter(|c| !c.is_control())
        .take(500)
        .collect();
    if !token.is_empty() {
        message = message.replace(token, "[credential]");
    }
    (code, message)
}

struct Verified {
    machine: String,
    high_water: i64,
    compress: bool,
    max_record_bytes: usize,
}

fn verify(agent: &ureq::Agent, url: &str, token: &str, machine: &str) -> Result<Verified, String> {
    let mut response = agent
        .get(format!("{url}/v1/verify"))
        .header("Authorization", format!("Bearer {token}"))
        .call()
        .map_err(|error| format!("hub compatibility check failed: {error}"))?;
    if !response.status().is_success() {
        let status = response.status().as_u16();
        let (_, message) = error_text(&mut response, token);
        return Err(format!(
            "hub compatibility check failed (HTTP {status}): {message}"
        ));
    }
    let server: Value = response
        .body_mut()
        .read_json()
        .map_err(|_| "hub returned an invalid compatibility response".to_owned())?;
    if server["protocol"] != HUB_PROTOCOL_VERSION
        || server["schema_version"] != SUPPORTED_SCHEMA_VERSION
        || server["contract"] != CONTRACT_NAME
        || server["contract_version"] != CONTRACT_VERSION
        || server["machine_id"] != machine
    {
        return Err("hub protocol, schema, contract, or machine identity differs from this collector release".to_owned());
    }
    let decoded_limit = server["ingest"]["max_decoded_bytes"].as_u64();
    let compress = server["ingest"]["content_encodings"]
        .as_array()
        .is_some_and(|encodings| encodings.iter().any(|value| value.as_str() == Some("zstd")))
        && decoded_limit.is_some_and(|limit| limit >= LEGACY_MAX_RECORD_BYTES as u64);
    Ok(Verified {
        machine: machine.to_owned(),
        high_water: server["high_water"].as_i64().unwrap_or(0),
        compress,
        max_record_bytes: if compress {
            decoded_limit.unwrap_or_default().min(1024 * 1024 * 1024) as usize
                - BATCH_ENVELOPE_HEADROOM
        } else {
            LEGACY_MAX_RECORD_BYTES
        },
    })
}

fn local_machine(store: &Store) -> Result<String, String> {
    store
        .machine_id()
        .map_err(|error| error.to_string())?
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "local database has no machine identity".to_owned())
}

struct Batch {
    batch_id: String,
    last_id: i64,
    rows: Vec<(i64, String)>,
}

fn now_utc() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Micros, true)
}

// NULL status means exactly a local size refusal that was never sent.
// Only next_batch may pass None; hub refusals always retain their HTTP status.
fn dead_letter(conn: &Connection, id: i64, status: Option<u16>, error: &str) -> StoreResult<()> {
    conn.execute(
            "insert into collector_upload_dead_letters(outbox_id, record_key, record_json, created_at_utc, failed_at_utc, http_status, error)
             select id, record_key, record_json, created_at_utc, ?, ?, ? from collector_upload_outbox where id = ?",
            params![now_utc(), status, error, id],
        )?;
    conn.execute("delete from collector_upload_outbox where id = ?", [id])?;
    conn.execute(
            "update collector_hub_state set inflight_batch_id = null, inflight_last_id = null where id = 1",
        [],
    )?;
    Ok(())
}

fn reconcile_dead_letters(
    conn: &Connection,
    max_record_bytes: usize,
) -> StoreResult<(usize, usize)> {
    let _lease = crate::store::write_lease::WriteLease::acquire(conn)?;
    let _phase = crate::store::write_budget::write_phase("hub");
    begin_write(conn)?;
    let result = (|| -> StoreResult<(usize, usize)> {
        let mut pruned = conn.execute(
            "delete from collector_upload_dead_letters as dead
             where record_key is not null and (
                 exists(select 1 from collector_upload_outbox where record_key=dead.record_key)
                 or exists(select 1 from collector_upload_dead_letters newer
                           where newer.record_key=dead.record_key and newer.id>dead.id))
             or (record_key like 'session:%' and not exists(
                 select 1 from sessions where id=substr(dead.record_key,9)))",
            [],
        )?;
        // Read keys, never payloads. Wall clocks and delivery history cannot
        // establish replay safety. The lease AND transaction cover discovery,
        // authoritative reconstruction, deletion and enqueue as one operation.
        let letters: Vec<(i64, String)> = conn
            .prepare(
                "select id, record_key from collector_upload_dead_letters
             where http_status is null and record_key is not null
             and length(cast(record_json as blob)) <= ? order by id",
            )?
            .query_map([max_record_bytes as i64], |row| {
                Ok((row.get(0)?, row.get(1)?))
            })?
            .collect::<Result<_, _>>()?;
        let mut requeued = 0;
        for (id, key) in letters {
            let ids = if let Some(session) = key.strip_prefix("session:") {
                vec![session.to_owned()]
            } else if key.starts_with("status:") {
                // Use the same canonical path identity as enqueue, including
                // UNC aliases. No state or locator is read from record_json.
                conn.prepare("select id,coalesce(harness,'codex'),source_file_path,source_file_unc_path from sessions")?
                    .query_map([], |row| Ok((row.get::<_,String>(0)?, row.get::<_,String>(1)?, row.get::<_,Option<String>>(2)?, row.get::<_,Option<String>>(3)?)))?
                    .collect::<Result<Vec<_>,_>>()?.into_iter()
                    .filter(|(_,harness,path,unc)| [path,unc].into_iter().flatten()
                        .any(|path| format!("status:{harness}:{}",source_status_id(path)) == key))
                    .map(|(id,_,_,_)| id).collect()
            } else {
                // Non-session metadata has no authoritative snapshot here.
                // Retain it for diagnosis; never replay its historical payload.
                continue;
            };
            conn.execute("delete from collector_upload_dead_letters where id=?", [id])?;
            let mut queued = false;
            for session in ids {
                let snapshot_key = format!("session:{session}");
                let pending: bool = conn.query_row(
                    "select exists(select 1 from collector_upload_outbox where record_key=?)",
                    [&snapshot_key],
                    |row| row.get(0),
                )?;
                if pending {
                    continue;
                }
                let now = now_utc();
                // Queue the current snapshot before its current lifecycle status
                // so a missing source cannot be inadvertently restored to active.
                if let Some((snapshot, status)) =
                    crate::hub_backfill::rebuild_current(conn, &session)?
                {
                    enqueue(conn, Record::SessionSnapshot(Box::new(snapshot)), &now)?;
                    enqueue(conn, Record::SourceStatus(status), &now)?;
                    queued = true;
                } else if let Some(status) = crate::hub_backfill::current_status(conn, &session)? {
                    conn.execute(
                        "delete from collector_hub_record_state where record_key=?",
                        [&key],
                    )?;
                    enqueue(conn, Record::SourceStatus(status), &now)?;
                    queued = true;
                }
            }
            if queued {
                requeued += 1;
            } else {
                pruned += 1;
            }
        }
        Ok((requeued, pruned))
    })();
    finish(conn, result)
}

/// Returns the persisted in-flight batch, or builds and persists the next one.
/// `isolate_until` sends records one at a time so a rejected batch reveals
/// which record is refused.
fn next_batch(
    conn: &Connection,
    machine: &str,
    sequence: i64,
    isolate_until: Option<i64>,
    max_record_bytes: usize,
    dead_lettered: &mut usize,
) -> StoreResult<Option<Batch>> {
    let inflight: Option<(Option<String>, Option<i64>)> = conn
        .query_row(
            "select inflight_batch_id, inflight_last_id from collector_hub_state where id = 1",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    if let Some((Some(batch_id), Some(last_id))) = inflight {
        let mut statement = conn.prepare(
            "select id, record_json from collector_upload_outbox where id <= ? order by id",
        )?;
        let rows = statement
            .query_map([last_id], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect::<Result<Vec<_>, _>>()?;
        return Ok(Some(Batch {
            batch_id,
            last_id,
            rows,
        }));
    }
    loop {
        let mut rows: Vec<(i64, String)> = Vec::new();
        let mut bytes = 0usize;
        let mut oversized = None;
        {
            // Sizes in UTF-8 bytes: length() of text counts characters.
            let mut statement = conn.prepare(
                "select id, length(cast(record_json as blob)) from collector_upload_outbox order by id limit ?",
            )?;
            let limit = if isolate_until.is_some() {
                1
            } else {
                MAX_RECORDS as i64
            };
            let candidates = statement
                .query_map([limit], |row| {
                    Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))
                })?
                .collect::<Result<Vec<_>, _>>()?;
            for (id, size) in candidates {
                let size = usize::try_from(size).unwrap_or(usize::MAX);
                if size > max_record_bytes {
                    if rows.is_empty() {
                        oversized = Some((id, size));
                    }
                    break;
                }
                // A record above the batch budget is sent alone.
                if !rows.is_empty() && bytes + size > MAX_BATCH_BYTES {
                    break;
                }
                bytes += size;
                let json: String = conn.query_row(
                    "select record_json from collector_upload_outbox where id = ?",
                    [id],
                    |row| row.get(0),
                )?;
                rows.push((id, json));
            }
        }
        if let Some((id, size)) = oversized {
            dead_letter(
                conn,
                id,
                None,
                &format!(
                    "record of {size} bytes exceeds the hub's {max_record_bytes}-byte record limit and was not sent"
                ),
            )?;
            *dead_lettered += 1;
            continue;
        }
        let Some(&(last_id, _)) = rows.last() else {
            return Ok(None);
        };
        // The random part keeps the ID unique when a restored database
        // builds a different batch with the same sequence and outbox row:
        // the hub then reports a sequence conflict instead of a duplicate
        // that would drop records it never stored. Retries reuse the
        // persisted ID.
        let nonce: String =
            conn.query_row("select lower(hex(randomblob(8)))", [], |row| row.get(0))?;
        let batch_id = format!("{machine}:{sequence}:{last_id}:{nonce}");
        conn.execute(
            "update collector_hub_state set inflight_batch_id = ?, inflight_last_id = ? where id = 1",
            params![batch_id, last_id],
        )?;
        conn.execute(
            "delete from app_metadata where key = ?",
            [INFLIGHT_FAILURES_KEY],
        )?;
        return Ok(Some(Batch {
            batch_id,
            last_id,
            rows,
        }));
    }
}

/// Counts a transport failure of the persisted in-flight batch. After
/// repeated failures a batch of several records is halved; it keeps its batch
/// ID, so if the hub did store the full batch it acknowledges the smaller one
/// as a duplicate and the rest is sent again (records apply idempotently).
/// Returns whether the batch was shrunk.
fn record_transport_failure(conn: &Connection, batch: &Batch) -> StoreResult<bool> {
    let _lease = crate::store::write_lease::WriteLease::acquire(conn)?;
    let _phase = crate::store::write_budget::write_phase("hub");
    begin_write(conn)?;
    let result = (|| -> StoreResult<bool> {
        let failures = conn
            .query_row(
                "select value from app_metadata where key = ?",
                [INFLIGHT_FAILURES_KEY],
                |row| row.get::<_, String>(0),
            )
            .optional()?
            .and_then(|value| value.parse::<i64>().ok())
            .unwrap_or(0)
            + 1;
        let shrink = failures >= SHRINK_AFTER_FAILURES && batch.rows.len() > 1;
        if shrink {
            let last_id = batch.rows[batch.rows.len() / 2 - 1].0;
            conn.execute(
                "update collector_hub_state set inflight_last_id = ? where id = 1 and inflight_batch_id = ?",
                params![last_id, batch.batch_id],
            )?;
        }
        conn.execute(
            "insert into app_metadata(key, value, updated_at_utc) values (?, ?, ?)
             on conflict(key) do update set value = excluded.value, updated_at_utc = excluded.updated_at_utc",
            params![
                INFLIGHT_FAILURES_KEY,
                if shrink { 0 } else { failures }.to_string(),
                now_utc()
            ],
        )?;
        Ok(shrink)
    })();
    finish(conn, result)
}

fn batch_body(sequence: i64, batch: &Batch) -> String {
    let mut body = String::with_capacity(
        batch
            .rows
            .iter()
            .map(|(_, json)| json.len() + 1)
            .sum::<usize>()
            + 256,
    );
    body.push_str(&format!(
        "{{\"protocol\":{HUB_PROTOCOL_VERSION},\"sequence\":{sequence},\"batch_id\":{},\"records\":[",
        serde_json::to_string(&batch.batch_id).expect("string serialization cannot fail")
    ));
    for (index, (_, json)) in batch.rows.iter().enumerate() {
        if index > 0 {
            body.push(',');
        }
        body.push_str(json);
    }
    body.push_str("]}");
    body
}

/// Records are sent in batches of up to the hub's record limit and
/// [`MAX_BATCH_BYTES`]. A batch is persisted before sending; a lost
/// acknowledgment retries the same sequence and batch ID and the hub answers
/// with a duplicate acknowledgment. A record the hub rejects with its
/// `record_rejected` or `invalid_batch` code moves to the dead-letter table;
/// every other failure leaves the queue untouched for the next run.
pub fn sync(db_path: &Path, mode: OwnerMode, url: &str, token: &str) -> Result<SyncReport, String> {
    let url = validate_url(url)?;
    if token.trim().is_empty() {
        return Err("hub credential is missing".to_owned());
    }
    // Wait as long as a scan does: a long scan holds the lease for each of its
    // batches and releases it only briefly, so the busy timeout alone refused
    // every sync until the scan ended.
    let _wait = crate::store::write_lease::LeaseWait::enter(LEASE_WAIT);
    let store = Store::open(db_path, mode).map_err(|error| error.to_string())?;
    let machine = local_machine(&store)?;
    let mut sequence = enable(&store, &url, &machine)?;
    let agent = agent();
    let verified = verify(&agent, &url, token, &machine)?;
    let mut report = SyncReport {
        sent: 0,
        batches: 0,
        dead_lettered: 0,
        requeued: 0,
        pruned: 0,
        pending: 0,
        last_sequence: sequence,
    };
    let mut isolate_until: Option<i64> = None;
    let conn = &store.conn;
    (report.requeued, report.pruned) = reconcile_dead_letters(conn, verified.max_record_bytes)
        .map_err(|error| error.to_string())?;
    while report.batches < MAX_BATCHES_PER_RUN {
        let lease = crate::store::write_lease::WriteLease::acquire(conn)
            .map_err(|error| error.to_string())?;
        if isolate_until.is_some_and(|last| {
            conn.query_row(
                "select coalesce(min(id), 0) from collector_upload_outbox",
                [],
                |row| row.get::<_, i64>(0),
            )
            .map_or(true, |first| first == 0 || first > last)
        }) {
            isolate_until = None;
        }
        let _phase = crate::store::write_budget::write_phase("hub");
        begin_write(conn).map_err(|error| error.to_string())?;
        let mut dead = 0;
        let batch = next_batch(
            conn,
            &verified.machine,
            sequence + 1,
            isolate_until,
            verified.max_record_bytes,
            &mut dead,
        );
        let batch = finish(conn, batch).map_err(|error| error.to_string())?;
        report.dead_lettered += dead;
        drop(lease);
        let Some(batch) = batch else {
            break;
        };
        let expected = sequence + 1;
        let body = batch_body(expected, &batch);
        let body_len = body.len();
        let payload = if verified.compress {
            zstd::bulk::compress(body.as_bytes(), 3).map_err(|error| {
                format!("cannot compress hub upload; local records remain queued: {error}")
            })?
        } else {
            body.into_bytes()
        };
        // Busy is an admission response, not a failed transport. Keep the
        // persisted batch and sequence through up to three bounded retries.
        let deadline = Instant::now() + upload_timeout(body_len);
        let mut busy_retries = 0;
        let mut response = loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let mut request = agent
                .post(format!("{url}/v1/ingest"))
                .config()
                .timeout_global(Some(remaining))
                .timeout_await_100(Some(Duration::from_secs(35).min(remaining)))
                .build()
                .header("Authorization", format!("Bearer {token}"))
                .header("Content-Type", "application/json")
                .header("Expect", "100-continue");
            if verified.compress {
                request = request.header("Content-Encoding", "zstd");
            }
            let mut response = match request.send(payload.as_slice()) {
                Ok(response) => response,
                Err(error) => {
                    let shrunk = record_transport_failure(conn, &batch)
                        .map_err(|error| error.to_string())?;
                    let next = if shrunk {
                        "; the next attempt sends a smaller batch"
                    } else {
                        ""
                    };
                    return Err(format!(
                        "hub upload failed; local records remain queued{next}: {error}"
                    ));
                }
            };
            if response.status().as_u16() != 503 {
                break response;
            }
            let (code, message) = error_text(&mut response, token);
            if code != "busy" || busy_retries == 3 {
                return Err(format!(
                    "hub upload failed (HTTP 503): {message}. Local records remain queued"
                ));
            }
            let backoff = Duration::from_millis(100 << busy_retries);
            if deadline.saturating_duration_since(Instant::now()) <= backoff {
                return Err("hub remains busy; local records remain queued".to_owned());
            }
            std::thread::sleep(backoff);
            busy_retries += 1;
        };
        let status = response.status().as_u16();
        if status != 200 {
            let (code, message) = error_text(&mut response, token);
            if code == "sequence_conflict" {
                return Err(format!(
                    "hub rejected upload sequence {expected}: {message}. Local records remain queued; run `hub resync` to continue from the hub's last accepted sequence"
                ));
            }
            // Only the hub's own rejection codes are permanent. Any other
            // failure, including a proxy's error page without a hub code,
            // leaves the queue untouched.
            let permanent = matches!(code.as_str(), "record_rejected" | "invalid_batch");
            if !permanent {
                return Err(format!(
                    "hub upload failed (HTTP {status}): {message}. Local records remain queued"
                ));
            }
            // The hub applies a batch atomically, so nothing was stored.
            if batch.rows.len() == 1 {
                let _lease = crate::store::write_lease::WriteLease::acquire(conn)
                    .map_err(|error| error.to_string())?;
                let _phase = crate::store::write_budget::write_phase("hub");
                begin_write(conn).map_err(|error| error.to_string())?;
                let result = dead_letter(conn, batch.rows[0].0, Some(status), &message);
                finish(conn, result).map_err(|error| error.to_string())?;
                report.dead_lettered += 1;
            } else {
                crate::store::write_budget::execute_write(
                    conn,
                    "hub_rejection",
                    "update collector_hub_state set inflight_batch_id = null, inflight_last_id = null where id = 1",
                    [],
                )
                .map_err(|error| error.to_string())?;
                isolate_until = Some(batch.last_id);
            }
            report.batches += 1;
            continue;
        }
        let ack: Value = response.body_mut().read_json().map_err(|_| {
            "hub returned an invalid acknowledgment; local records remain queued".to_owned()
        })?;
        if ack["protocol"] != HUB_PROTOCOL_VERSION
            || ack["sequence"] != expected
            || ack["batch_id"] != batch.batch_id.as_str()
        {
            return Err("hub acknowledgment does not match the queued batch".to_owned());
        }
        let _lease = crate::store::write_lease::WriteLease::acquire(conn)
            .map_err(|error| error.to_string())?;
        let _phase = crate::store::write_budget::write_phase("hub");
        begin_write(conn).map_err(|error| error.to_string())?;
        let result = (|| -> StoreResult<usize> {
            let pruned = conn.execute(
                "delete from collector_upload_dead_letters
                 where record_key in (select record_key from collector_upload_outbox
                                      where id <= ? and record_key is not null)",
                [batch.last_id],
            )?;
            conn.execute(
                "delete from collector_upload_outbox where id <= ?",
                [batch.last_id],
            )?;
            conn.execute(
                "update collector_hub_state set last_sequence = ?, inflight_batch_id = null, inflight_last_id = null where id = 1",
                [expected],
            )?;
            Ok(pruned)
        })();
        report.pruned += finish(conn, result).map_err(|error| error.to_string())?;
        sequence = expected;
        report.sent += batch.rows.len();
        report.batches += 1;
    }
    let _lease =
        crate::store::write_lease::WriteLease::acquire(conn).map_err(|error| error.to_string())?;
    report.pending = pending(conn).map_err(|error| error.to_string())?;
    report.last_sequence = sequence;
    Ok(report)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResyncReport {
    pub previous_sequence: i64,
    pub last_sequence: i64,
    pub pending: i64,
}

/// Re-bases the local sequence on the hub's last accepted sequence, for
/// example after restoring an older local database or hub backup. Queued
/// records stay queued and are delivered after the hub's high-water mark;
/// the hub applies source revisions idempotently. Change tracking is reset so
/// that the next scan reports every status and thread name again.
pub fn resync(
    db_path: &Path,
    mode: OwnerMode,
    url: &str,
    token: &str,
) -> Result<ResyncReport, String> {
    let url = validate_url(url)?;
    if token.trim().is_empty() {
        return Err("hub credential is missing".to_owned());
    }
    let store = Store::open(db_path, mode).map_err(|error| error.to_string())?;
    let machine = local_machine(&store)?;
    let previous = enable(&store, &url, &machine)?;
    let verified = verify(&agent(), &url, token, &machine)?;
    let _lease = crate::store::write_lease::WriteLease::acquire(&store.conn)
        .map_err(|error| error.to_string())?;
    let _phase = crate::store::write_budget::write_phase("hub");
    begin_write(&store.conn).map_err(|error| error.to_string())?;
    let result = (|| -> StoreResult<()> {
        store.conn.execute(
            "update collector_hub_state set last_sequence = ?, inflight_batch_id = null, inflight_last_id = null where id = 1",
            [verified.high_water],
        )?;
        store
            .conn
            .execute("delete from collector_hub_record_state", [])?;
        Ok(())
    })();
    finish(&store.conn, result).map_err(|error| error.to_string())?;
    Ok(ResyncReport {
        previous_sequence: previous,
        last_sequence: verified.high_water,
        pending: pending(&store.conn).map_err(|error| error.to_string())?,
    })
}

/// Records already present when hub delivery is enabled must be collected
/// again with `--force`; collection itself remains completely local.
pub fn enable_for_collection(db_path: &Path, mode: OwnerMode, url: &str) -> Result<(), String> {
    let url = validate_url(url)?;
    let store = Store::open(db_path, mode).map_err(|error| error.to_string())?;
    let machine = store
        .machine_id()
        .map_err(|error| error.to_string())?
        .ok_or_else(|| "local database has no machine identity".to_owned())?;
    enable(&store, &url, &machine)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_full_batch_fits_its_upload_timeout_on_a_slow_uplink() {
        const SLOW_UPLINK_BYTES_PER_SECOND: u64 = 64 * 1024;
        let transfer = MAX_BATCH_BYTES as u64 / SLOW_UPLINK_BYTES_PER_SECOND;
        assert!(upload_timeout(MAX_BATCH_BYTES).as_secs() > transfer);
        // A single large record gets proportionally more time.
        assert!(
            upload_timeout(crate::hub_server::MAX_INGEST_DECODED_BYTES).as_secs()
                > crate::hub_server::MAX_INGEST_DECODED_BYTES as u64 / SLOW_UPLINK_BYTES_PER_SECOND
        );
        const _: () = assert!(MAX_BATCH_BYTES <= 8 * 1024 * 1024);
    }
}
