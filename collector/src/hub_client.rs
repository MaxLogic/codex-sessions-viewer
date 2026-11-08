//! Durable, optional upload of locally committed contract records.

mod continue_transport;

use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::Read;
use std::path::Path;
use std::time::{Duration, Instant};

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

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
    finish_pending_reset(conn)?;
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
    let version = record_version(&record);
    enqueue_versioned(conn, record, now, version)
}

fn record_version(record: &Record) -> u32 {
    if matches!(record, Record::SourceStatus(status) if status.environment.is_none()) {
        1
    } else {
        CONTRACT_VERSION
    }
}

fn dedupe_key_hash(record: &Record, version: Option<u32>) -> StoreResult<Option<(String, String)>> {
    let Some((key, true)) = record_key(record) else {
        return Ok(None);
    };
    #[derive(serde::Serialize)]
    struct BorrowedEnvelope<'a> {
        contract: &'static str,
        version: u32,
        #[serde(flatten)]
        record: &'a Record,
    }
    let envelope = serde_json::to_string(&BorrowedEnvelope {
        contract: CONTRACT_NAME,
        version: version.unwrap_or_else(|| record_version(record)),
        record,
    })
    .map_err(|error| StoreError::Io(std::io::Error::other(error)))?;
    Ok(Some((key, crate::dart::sha256_hex(envelope.as_bytes()))))
}

pub(crate) fn plan_delivery(
    conn: &Connection,
    records: &[Record],
    version: Option<u32>,
) -> StoreResult<Vec<bool>> {
    if !queue_enabled(conn)? {
        #[cfg(feature = "test-hooks")]
        test_hooks::record_plan(&vec![false; records.len()]);
        return Ok(vec![false; records.len()]);
    }
    let mut predicted = HashMap::new();
    let mut delivery = Vec::with_capacity(records.len());
    for record in records {
        let Some((key, hash)) = dedupe_key_hash(record, version)? else {
            delivery.push(true);
            continue;
        };
        if !predicted.contains_key(&key) {
            #[cfg(feature = "test-hooks")]
            test_hooks::record_probe();
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
    #[cfg(feature = "test-hooks")]
    test_hooks::record_plan(&delivery);
    Ok(delivery)
}

const STATUS_BUCKETS: usize = 1024;

fn status_bucket(key: &str) -> usize {
    let hash = Sha256::digest(key.as_bytes());
    usize::from(u16::from_be_bytes([hash[0], hash[1]])) & (STATUS_BUCKETS - 1)
}

struct StatusHarnessCommit {
    harness: String,
    last_hash: HashMap<String, String>,
    changed_buckets: Vec<(usize, Option<Vec<u8>>)>,
}

pub(crate) struct StatusPlanCommit {
    scopes: Vec<StatusHarnessCommit>,
}

fn dirty_status_keys(conn: &Connection, harness: &str) -> StoreResult<Vec<String>> {
    Ok(conn
        .prepare_cached(
            "select record_key from hub_status_plan_dirty where record_key>=?1 and record_key<?2",
        )?
        .query_map(
            params![format!("status:{harness}:"), format!("status:{harness};")],
            |row| row.get(0),
        )?
        .collect::<Result<_, _>>()?)
}

/// Only scans use this memo. The caller holds the collector lease from planning
/// through the final commit. Every record-state DML writer, including foreign
/// SQL, invalidates status keys through schema triggers.
pub(crate) fn plan_scanned_status_delivery(
    conn: &Connection,
    records: &[Record],
    version: Option<u32>,
) -> StoreResult<(Vec<bool>, Option<StatusPlanCommit>)> {
    if !queue_enabled(conn)? {
        let delivery = vec![false; records.len()];
        #[cfg(feature = "test-hooks")]
        test_hooks::record_plan(&delivery);
        return Ok((delivery, None));
    }
    let hashes: Vec<_> = records
        .iter()
        .map(|record| dedupe_key_hash(record, version))
        .collect::<StoreResult<_>>()?;
    let mut harnesses: BTreeMap<&str, Vec<usize>> = BTreeMap::new();
    for (index, record) in records.iter().enumerate() {
        let Record::SourceStatus(status) = record else {
            return Err(StoreError::Refused(
                "scan status planner received a non-status record".to_owned(),
            ));
        };
        harnesses.entry(&status.harness).or_default().push(index);
    }
    let mut known = HashMap::new();
    let mut scopes = Vec::new();
    for (harness, indices) in harnesses {
        let mut buckets: BTreeMap<usize, Sha256> = BTreeMap::new();
        let mut last_hash = HashMap::new();
        for index in indices {
            let (key, hash) = hashes[index]
                .as_ref()
                .expect("source status is deduplicated");
            let digest = buckets.entry(status_bucket(key)).or_default();
            digest.update(key.as_bytes());
            digest.update([0]);
            digest.update(hash.as_bytes());
            digest.update(b"\n");
            last_hash.insert(key.clone(), hash.clone());
        }
        // A 128-bit SHA-256 prefix describes each ordered bucket, not its key
        // number alone. Colliding bucket numbers only cause extra probes.
        let digests: BTreeMap<usize, Vec<u8>> = buckets
            .into_iter()
            .map(|(bucket, hash)| (bucket, hash.finalize()[..16].to_vec()))
            .collect();
        let stored: BTreeMap<usize, Vec<u8>> = conn
            .prepare_cached("select bucket,digest from hub_status_plan where harness=?")?
            .query_map([harness], |row| {
                Ok((usize::from(row.get::<_, u16>(0)?), row.get(1)?))
            })?
            .collect::<Result<_, _>>()?;
        let dirty: HashSet<_> = dirty_status_keys(conn, harness)?.into_iter().collect();
        for (key, hash) in &last_hash {
            let bucket = status_bucket(key);
            if !dirty.contains(key) && digests.get(&bucket) == stored.get(&bucket) {
                known.insert(key.clone(), hash.clone());
            }
        }
        let mut changed_buckets: Vec<_> = digests
            .iter()
            .filter(|(bucket, digest)| stored.get(bucket) != Some(digest))
            .map(|(bucket, digest)| (*bucket, Some(digest.clone())))
            .collect();
        changed_buckets.extend(
            stored
                .keys()
                .filter(|bucket| !digests.contains_key(bucket))
                .map(|bucket| (*bucket, None)),
        );
        if !changed_buckets.is_empty() || !dirty.is_empty() {
            scopes.push(StatusHarnessCommit {
                harness: harness.to_owned(),
                last_hash,
                changed_buckets,
            });
        }
    }
    let mut predicted = HashMap::new();
    let mut delivery = Vec::with_capacity(records.len());
    for pair in hashes {
        let (key, hash) = pair.expect("source status is deduplicated");
        if !predicted.contains_key(&key) {
            let previous = if let Some(hash) = known.remove(&key) {
                Some(hash)
            } else {
                #[cfg(feature = "test-hooks")]
                test_hooks::record_probe();
                conn.prepare_cached(
                    "select record_hash from collector_hub_record_state where record_key=?",
                )?
                .query_row([&key], |row| row.get(0))
                .optional()?
            };
            predicted.insert(key.clone(), previous);
        }
        delivery.push(predicted[&key].as_deref() != Some(&hash));
        predicted.insert(key, Some(hash));
    }
    #[cfg(feature = "test-hooks")]
    test_hooks::record_plan(&delivery);
    Ok((
        delivery,
        if scopes.is_empty() {
            None
        } else {
            Some(StatusPlanCommit { scopes })
        },
    ))
}

/// Applied as the final status unit, inside its write transaction. Re-read dirty
/// keys here: own deliveries and any intervening SQL must not be vouched for
/// unless the committed record hash actually equals the input's last hash.
pub(crate) fn commit_status_plan(conn: &Connection, commit: StatusPlanCommit) -> StoreResult<()> {
    finish_pending_reset(conn)?;
    for scope in commit.scopes {
        for key in dirty_status_keys(conn, &scope.harness)? {
            let clean = if let Some(hash) = scope.last_hash.get(&key) {
                let stored: Option<String> = conn
                    .prepare_cached(
                        "select record_hash from collector_hub_record_state where record_key=?",
                    )?
                    .query_row([&key], |row| row.get(0))
                    .optional()?;
                stored.as_ref() == Some(hash)
            } else {
                true
            };
            if clean {
                conn.prepare_cached("delete from hub_status_plan_dirty where record_key=?")?
                    .execute([&key])?;
            }
        }
        for (bucket, digest) in scope.changed_buckets {
            if let Some(digest) = digest {
                conn.prepare_cached("insert into hub_status_plan(harness,bucket,digest) values (?1,?2,?3) on conflict(harness,bucket) do update set digest=excluded.digest")?
                    .execute(params![scope.harness,bucket as u16,digest])?;
            } else {
                conn.prepare_cached("delete from hub_status_plan where harness=?1 and bucket=?2")?
                    .execute(params![scope.harness, bucket as u16])?;
            }
        }
    }
    Ok(())
}

#[cfg(feature = "test-hooks")]
pub mod test_hooks {
    use std::cell::{Cell, RefCell};
    thread_local! {
        static PROBES: Cell<usize> = const { Cell::new(0) };
        static PLAN: RefCell<Vec<bool>> = const { RefCell::new(Vec::new()) };
        static FAIL_AFTER: Cell<Option<usize>> = const { Cell::new(None) };
        static RESET_FAIL_AFTER: Cell<Option<usize>> = const { Cell::new(None) };
    }
    pub fn status_plan_probes() -> usize {
        PROBES.with(Cell::get)
    }
    pub fn reset_status_plan_probes() {
        PROBES.with(|value| value.set(0));
    }
    pub fn status_plan() -> Vec<bool> {
        PLAN.with_borrow(Clone::clone)
    }
    pub(crate) fn record_probe() {
        PROBES.with(|value| value.set(value.get() + 1));
    }
    pub(crate) fn record_plan(plan: &[bool]) {
        PLAN.with_borrow_mut(|value| *value = plan.to_vec());
    }
    pub fn fail_status_unit_after(units: Option<usize>) {
        FAIL_AFTER.with(|value| value.set(units));
    }
    pub fn fail_reset_after_commit(boundary: Option<usize>) {
        RESET_FAIL_AFTER.with(|value| value.set(boundary));
    }
    pub(crate) fn after_reset_commit() -> crate::store::schema::StoreResult<()> {
        RESET_FAIL_AFTER.with(|value| match value.get() {
            Some(0) => Err(crate::store::schema::StoreError::Refused(
                "injected failure after reset commit".to_owned(),
            )),
            Some(left) => {
                value.set(Some(left - 1));
                Ok(())
            }
            None => Ok(()),
        })
    }
    pub(crate) fn before_status_unit() -> crate::store::schema::StoreResult<()> {
        FAIL_AFTER.with(|value| match value.get() {
            Some(0) => Err(crate::store::schema::StoreError::Refused(
                "injected status unit failure".to_owned(),
            )),
            Some(left) => {
                value.set(Some(left - 1));
                Ok(())
            }
            None => Ok(()),
        })
    }
}

/// Legacy fixture packing threshold; production no longer packs outbox records. A
/// session snapshot carries every message and tool call, and an active session
/// is queued again after each turn, so storing it as plain text dominated the
/// collector's disk writes. The outbox column must stay valid JSON (its CHECK),
/// so the compressed bytes travel base64-encoded inside a wrapper object that
/// only this module writes and reads; `hub sync` sends the original envelope.
#[cfg(test)]
const PACK_AT: usize = 16 * 1024;
const PACKED_PREFIX: &str = r#"{"outbox_encoding":"zstd-base64","bytes":"#;
/// Largest decoded record a packed outbox row may claim.
const MAX_PACKED_BYTES: usize = 1024 * 1024 * 1024;

#[derive(serde::Deserialize)]
struct Packed {
    bytes: usize,
    data: String,
}

/// SQL for a stored outbox or dead-letter record's decoded size in UTF-8
/// bytes, which the size limits refer to.
fn record_bytes_sql() -> String {
    format!(
        "(case when substr(record_json, 1, {}) = '{PACKED_PREFIX}' \
         then cast(json_extract(record_json, '$.bytes') as integer) \
         when substr(record_json,1,15) = '{{\"outbox_ref\":\"' then coalesce(cast(json_extract(record_json,'$.bytes') as integer),0) else length(cast(record_json as blob)) end)",
        PACKED_PREFIX.len()
    )
}

/// The stored form of an envelope: compressed when large and when that is smaller.
#[cfg(test)]
pub(crate) fn pack_record(json: String) -> StoreResult<String> {
    if json.len() < PACK_AT {
        return Ok(json);
    }
    let compressed = zstd::bulk::compress(json.as_bytes(), 3).map_err(StoreError::Io)?;
    let mut packed = format!("{PACKED_PREFIX}{},\"data\":\"", json.len());
    base64_encode(&compressed, &mut packed);
    packed.push_str("\"}");
    Ok(if packed.len() < json.len() {
        packed
    } else {
        json
    })
}

/// The envelope a stored outbox row holds, decompressed when it was packed.
pub(crate) fn unpack_record(stored: String) -> StoreResult<String> {
    if !stored.starts_with(PACKED_PREFIX) {
        return Ok(stored);
    }
    let invalid = |message: &str| {
        StoreError::Io(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("queued hub record cannot be decoded: {message}"),
        ))
    };
    let packed: Packed =
        serde_json::from_str(&stored).map_err(|error| invalid(&error.to_string()))?;
    if packed.bytes > MAX_PACKED_BYTES {
        return Err(invalid("decoded size exceeds the limit"));
    }
    let compressed = base64_decode(&packed.data).ok_or_else(|| invalid("invalid base64"))?;
    let json = zstd::bulk::decompress(&compressed, packed.bytes)
        .map_err(|error| invalid(&error.to_string()))?;
    if json.len() != packed.bytes {
        return Err(invalid("decoded size differs from the recorded size"));
    }
    String::from_utf8(json).map_err(|_| invalid("decoded record is not UTF-8"))
}

#[cfg(test)]
const BASE64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

#[cfg(test)]
fn base64_encode(bytes: &[u8], out: &mut String) {
    out.reserve(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let value = (u32::from(chunk[0]) << 16)
            | (u32::from(*chunk.get(1).unwrap_or(&0)) << 8)
            | u32::from(*chunk.get(2).unwrap_or(&0));
        for index in 0..4 {
            if index <= chunk.len() {
                out.push(BASE64[((value >> (18 - 6 * index)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
}

fn base64_decode(text: &str) -> Option<Vec<u8>> {
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let digit = |byte: u8| match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    };
    let quads = bytes.len() / 4;
    let mut out = Vec::with_capacity(quads * 3);
    for (index, quad) in bytes.chunks(4).enumerate() {
        let padding = if index + 1 == quads {
            quad.iter().rev().take_while(|byte| **byte == b'=').count()
        } else {
            0
        };
        if padding > 2 {
            return None;
        }
        let mut value = 0u32;
        for (position, byte) in quad.iter().enumerate() {
            let sextet = if position >= 4 - padding {
                0
            } else {
                digit(*byte)?
            };
            value = (value << 6) | u32::from(sextet);
        }
        let decoded = [(value >> 16) as u8, (value >> 8) as u8, value as u8];
        out.extend_from_slice(&decoded[..3 - padding]);
    }
    Some(out)
}

/// Serialize a session without cloning its potentially large snapshot.
pub(crate) fn session_envelope_json(
    snapshot: &crate::contract::SessionSnapshot,
    version: Option<u32>,
) -> StoreResult<String> {
    #[derive(serde::Serialize)]
    struct SessionEnvelope<'a> {
        contract: &'static str,
        version: u32,
        kind: &'static str,
        record: &'a crate::contract::SessionSnapshot,
    }
    serde_json::to_string(&SessionEnvelope {
        contract: CONTRACT_NAME,
        version: version.unwrap_or(CONTRACT_VERSION),
        kind: "session_snapshot",
        record: snapshot,
    })
    .map_err(|error| StoreError::Io(std::io::Error::other(error)))
}

/// Session outbox rows refer to committed stored state; ingest never serializes children.
pub const SESSION_REF: &str = r#"{"outbox_ref":"session_snapshot"}"#;

pub fn enqueue_session(
    conn: &Connection,
    id: &str,
    harness: &str,
    source_path: &str,
    now: &str,
    force: bool,
) -> StoreResult<()> {
    finish_pending_reset(conn)?;
    let Some(digest) = crate::hub_snapshot::state_digest(conn, id)? else {
        return Ok(());
    };
    let key = format!("session:{id}");
    if !force {
        let previous: Option<String> = conn
            .query_row(
                "select record_hash from collector_hub_record_state where record_key=?",
                [&key],
                |r| r.get(0),
            )
            .optional()?;
        let refused: bool = conn.query_row(
            "select exists(select 1 from collector_upload_dead_letters where record_key=?)",
            [&key],
            |r| r.get(0),
        )?;
        if previous.as_deref() == Some(&digest) && !refused {
            return Ok(());
        }
    }
    conn.execute(
        "delete from collector_hub_record_state where record_key=?",
        [format!(
            "status:{harness}:{}",
            source_status_id(source_path)
        )],
    )?;
    conn.execute("insert into collector_hub_record_state(record_key,record_hash) values (?,?) on conflict(record_key) do update set record_hash=excluded.record_hash",params![key,digest])?;
    // A new id puts changed state beyond a persisted ambiguous batch's boundary.
    conn.execute(
        "delete from collector_upload_outbox where record_key=?",
        [&key],
    )?;
    conn.execute(
        "insert into collector_upload_outbox(record_json,created_at_utc,record_key) values (?,?,?)",
        params![SESSION_REF, now, key],
    )?;
    Ok(())
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
    if let Record::SessionSnapshot(snapshot) = &record {
        let id = session_row_id(
            &snapshot.harness,
            snapshot.session.session_id.as_deref(),
            &snapshot.source.path,
        );
        return enqueue_session(
            conn,
            &id,
            &snapshot.harness,
            &snapshot.source.path,
            now,
            false,
        );
    }
    PreparedRecord::new(record, version)?.enqueue(conn, now)
}

/// Serialized before taking SQLite's write lock during authoritative rebuilds.
/// The collector lease still protects every stored input until enqueue commits.
struct PreparedRecord {
    key: Option<(String, bool)>,
    /// Plain metadata envelope; session records use SESSION_REF.
    envelope: String,
    hash: Option<String>,
}

impl PreparedRecord {
    fn current(record: Record) -> StoreResult<Self> {
        let version = record_version(&record);
        Self::new(record, version)
    }

    fn new(record: Record, version: u32) -> StoreResult<Self> {
        let key = record_key(&record);
        let envelope = serde_json::to_string(&Envelope {
            contract: CONTRACT_NAME.to_owned(),
            version,
            record,
        })
        .map_err(|error| StoreError::Io(std::io::Error::other(error)))?;
        let hash = key
            .as_ref()
            .filter(|(_, deduplicate)| *deduplicate)
            .map(|_| crate::dart::sha256_hex(envelope.as_bytes()));
        Ok(Self {
            key,
            envelope,
            hash,
        })
    }

    fn enqueue(&self, conn: &Connection, now: &str) -> StoreResult<()> {
        finish_pending_reset(conn)?;
        let Some((key, _)) = &self.key else {
            conn.execute(
                "insert into collector_upload_outbox(record_json,created_at_utc) values (?,?)",
                params![self.envelope, now],
            )?;
            return Ok(());
        };
        if let Some(hash) = &self.hash {
            let previous: Option<String> = conn
                .query_row(
                    "select record_hash from collector_hub_record_state where record_key=?",
                    [key],
                    |row| row.get(0),
                )
                .optional()?;
            if previous.as_ref() == Some(hash) {
                return Ok(());
            }
            conn.execute(
                "insert into collector_hub_record_state(record_key,record_hash) values (?,?)
                on conflict(record_key) do update set record_hash=excluded.record_hash",
                params![key, hash],
            )?;
        }
        conn.execute(
            "delete from collector_upload_outbox where record_key=?",
            [key],
        )?;
        conn.execute("insert into collector_upload_outbox(record_json,created_at_utc,record_key) values (?,?,?)",
            params![self.envelope,now,key])?;
        Ok(())
    }
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
    finish_pending_reset(&store.conn).map_err(|error| error.to_string())?;
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
    finish_pending_reset(&store.conn).map_err(|error| error.to_string())?;
    let _phase = crate::store::write_budget::write_phase("hub");
    begin_write(&store.conn).map_err(|error| error.to_string())?;
    let result = (|| -> StoreResult<i64> {
        let cleared = pending(&store.conn)?;
        store.conn.execute_batch(
            "update collector_hub_state set enabled = 0, inflight_batch_id = null, inflight_last_id = null where id = 1;
             delete from collector_upload_outbox;
             delete from collector_upload_dead_letters;",
        )?;
        store.conn.execute("insert into app_metadata(key,value,updated_at_utc) values(?,'disable',?) on conflict(key) do update set value=excluded.value,updated_at_utc=excluded.updated_at_utc", params![RESET_INTENT,crate::dart::DartDateTime::now().to_iso8601()])?;
        Ok(cleared)
    })();
    let cleared = finish(&store.conn, result).map_err(|error| error.to_string())?;
    #[cfg(feature = "test-hooks")]
    test_hooks::after_reset_commit().map_err(|error| error.to_string())?;
    finish_pending_reset(&store.conn).map_err(|error| error.to_string())?;
    Ok(cleared)
}

/// Triggers make a full reset proportional to the number of status keys. Keep
/// the caller's collector lease across the reset, yielding SQLite's lock after
/// each bounded prefix. No collector can plan against an incomplete reset.
const RESET_INTENT: &str = "collector_hub_reset_intent";

/// A persisted intent fences every hash consumer, including foreign enabling of
/// the hub row. Recover only outside an existing transaction, under the lease;
/// an in-transaction caller refuses rather than consuming a partial reset.
fn finish_pending_reset(conn: &Connection) -> StoreResult<()> {
    let intent: Option<String> = conn
        .query_row(
            "select value from app_metadata where key=?",
            [RESET_INTENT],
            |r| r.get(0),
        )
        .optional()?;
    let Some(_) = intent else {
        return Ok(());
    };
    if !conn.is_autocommit() {
        return Err(StoreError::Refused(
            "hub reset is pending; finish recovery before starting a write transaction".to_owned(),
        ));
    }
    let _lease = crate::store::write_lease::WriteLease::acquire(conn)?;
    // Another owner may have completed recovery while this caller waited.
    let intent: Option<String> = conn
        .query_row(
            "select value from app_metadata where key=?",
            [RESET_INTENT],
            |r| r.get(0),
        )
        .optional()?;
    let Some(intent) = intent else {
        return Ok(());
    };
    let enabled = match intent.as_str() {
        "disable" => 0,
        "resync" => 1,
        _ => {
            return Err(StoreError::Refused(
                "unknown pending hub reset kind".to_owned(),
            ));
        }
    };
    clear_record_state(conn, enabled)
}

fn clear_record_state(conn: &Connection, enabled: i64) -> StoreResult<()> {
    use crate::store::write_budget::{current_budget, write_chunked};
    let keys: Vec<String> = conn
        .prepare("select record_key from collector_hub_record_state order by record_key")?
        .query_map([], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    let mut boundaries: Vec<Option<String>> =
        keys.chunks(2048).map(|keys| keys.last().cloned()).collect();
    if boundaries.is_empty() {
        boundaries.push(None);
    }
    let last = boundaries.len() - 1;
    for (index, boundary) in boundaries.into_iter().enumerate() {
        write_chunked(
            conn,
            "hub",
            current_budget(),
            1,
            std::iter::once(boundary),
            || Ok(()),
            |_, boundary| {
                if let Some(boundary) = boundary {
                    conn.prepare_cached(
                        "delete from collector_hub_record_state where record_key<=?",
                    )?
                    .execute([boundary])?;
                }
                if index == last {
                    conn.execute("delete from app_metadata where key=?", [RESET_INTENT])?;
                    conn.execute(
                        "update collector_hub_state set enabled=? where id=1",
                        [enabled],
                    )?;
                }
                Ok(())
            },
        )?;
        #[cfg(feature = "test-hooks")]
        test_hooks::after_reset_commit()?;
    }
    Ok(())
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

// NULL status means a local refusal that was never sent: a record above the
// size limit, or a stored record that cannot be decoded. Both are rebuilt.
// Only persist_batch may pass None; hub refusals always retain their HTTP status.
fn dead_letter(
    conn: &Connection,
    id: i64,
    status: Option<u16>,
    error: &str,
    stored_override: Option<&str>,
) -> StoreResult<()> {
    conn.execute(
            "insert into collector_upload_dead_letters(outbox_id, record_key, record_json, created_at_utc, failed_at_utc, http_status, error)
             select id, record_key, coalesce(?,record_json), created_at_utc, ?, ?, ? from collector_upload_outbox where id = ?",
            params![stored_override, now_utc(), status, error, id],
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
    use crate::store::write_budget::{current_budget, write_chunked};
    let _lease = crate::store::write_lease::WriteLease::acquire(conn)?;
    finish_pending_reset(conn)?;
    let orphaned: Vec<String> = conn.prepare("select record_key from collector_hub_record_state where record_key like 'session:%' and not exists(select 1 from sessions where id=substr(record_key,9))")?.query_map([],|r|r.get(0))?.collect::<Result<_,_>>()?;
    write_chunked(
        conn,
        "hub_reconcile",
        current_budget(),
        1,
        orphaned,
        || Ok(()),
        |_, key| {
            conn.execute(
                "delete from collector_hub_record_state where record_key=?",
                [key],
            )?;
            Ok(())
        },
    )?;
    // Collector-owned inputs cannot change under this lease. Discovery, table
    // scans, reconstruction and serialization stay OUTSIDE SQLite write holds.
    // Viewer-owned annotations are never copied into the upload contract.
    // A queued record with the same key proves a letter obsolete, except for a
    // reconstructable status letter: its key can cover several current
    // sessions, and an interruption after the first pair leaves that pair's
    // status queued while later identities still need rebuilding. Those
    // letters go through reconstruction, which skips already-queued sessions.
    let obsolete: Vec<i64> = conn
        .prepare(&format!(
            "select dead.id from collector_upload_dead_letters dead
         where record_key is not null and (
             (exists(select 1 from collector_upload_outbox where record_key=dead.record_key)
              and not (record_key like 'status:%' and http_status is null
                       and {}<=?1))
             or exists(select 1 from collector_upload_dead_letters newer
                       where newer.record_key=dead.record_key and newer.id>dead.id))
         or (record_key like 'session:%' and not exists(
             select 1 from sessions where id=substr(dead.record_key,9)))",
            record_bytes_sql()
        ))?
        .query_map([max_record_bytes as i64], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    let mut pruned = 0;
    write_chunked(
        conn,
        "hub_reconcile",
        current_budget(),
        1,
        obsolete,
        || Ok(()),
        |_, id| {
            pruned += conn.execute("delete from collector_upload_dead_letters where id=?", [id])?;
            Ok(())
        },
    )?;
    // Read keys, never historical payloads. Clocks and delivery history cannot
    // establish replay safety; rebuild the current authoritative entity instead.
    let letters: Vec<(i64, String)> = conn
        .prepare(&format!(
            "select id,record_key from collector_upload_dead_letters
         where http_status is null and record_key is not null
         and {}<=? order by id",
            record_bytes_sql()
        ))?
        .query_map([max_record_bytes as i64], |row| {
            Ok((row.get(0)?, row.get(1)?))
        })?
        .collect::<Result<_, _>>()?;
    let mut requeued = 0;
    for (id, key) in letters {
        let ids = if let Some(session) = key.strip_prefix("session:") {
            vec![session.to_owned()]
        } else if key.starts_with("status:") {
            // Includes UNC aliases, with exactly enqueue's canonical identity.
            conn.prepare("select id,coalesce(harness,'codex'),source_file_path,source_file_unc_path from sessions")?
                .query_map([],|row| Ok((row.get::<_,String>(0)?,row.get::<_,String>(1)?,row.get::<_,Option<String>>(2)?,row.get::<_,Option<String>>(3)?)))?
                .collect::<Result<Vec<_>,_>>()?.into_iter()
                .filter(|(_,harness,path,unc)| [path,unc].into_iter().flatten()
                    .any(|path| format!("status:{harness}:{}",source_status_id(path))==key))
                .map(|(id,_,_,_)| id).collect()
        } else {
            // No authoritative snapshot for this metadata: retain for diagnosis.
            continue;
        };
        let mut records = Vec::new();
        let mut clear_status = false;
        for session in ids {
            let pending: bool = conn.query_row(
                "select exists(select 1 from collector_upload_outbox where record_key=?)",
                [format!("session:{session}")],
                |r| r.get(0),
            )?;
            if pending {
                continue;
            }
            let snapshot =
                crate::hub_snapshot::build(conn, &session, crate::hub_snapshot::Children::Omit)?;
            let status = crate::hub_snapshot::current_status(conn, &session)?;
            if let Some(snapshot) = snapshot {
                records.push((
                    Some((session, snapshot.harness, snapshot.source.path)),
                    status
                        .map(|s| PreparedRecord::current(Record::SourceStatus(s)))
                        .transpose()?,
                ));
            } else if let Some(status) = status {
                clear_status = true;
                records.push((
                    None,
                    Some(PreparedRecord::current(Record::SourceStatus(status))?),
                ));
            }
        }
        let queued = !records.is_empty();
        // Each current snapshot + lifecycle status commits atomically BEFORE
        // deleting the historical blob in a separate chunk. A crash between
        // them leaves an outbox pair; the next sync's existing prune rule then
        // removes the letter. Never combine two large blob writes in one hold.
        // Multiple current identities for a status key also get separate units.
        write_chunked(
            conn,
            "hub_reconcile",
            current_budget(),
            1,
            records.iter().map(Some).chain(std::iter::once(None)),
            || Ok(()),
            |_, group| {
                if let Some(records) = group {
                    if clear_status {
                        conn.execute(
                            "delete from collector_hub_record_state where record_key=?",
                            [&key],
                        )?;
                        clear_status = false;
                    }
                    let now = now_utc();
                    if let Some((session, harness, path)) = &records.0 {
                        enqueue_session(conn, session, harness, path, &now, true)?;
                    }
                    if let Some(status) = &records.1 {
                        status.enqueue(conn, &now)?;
                    }
                } else {
                    conn.execute("delete from collector_upload_dead_letters where id=?", [id])?;
                }
                Ok(())
            },
        )?;
        if queued {
            requeued += 1;
        } else {
            pruned += 1;
        }
    }
    Ok((requeued, pruned))
}

/// One WAL snapshot spans every header and child read in a batch.
fn read_consistent<T>(conn: &Connection, read: impl FnOnce() -> StoreResult<T>) -> StoreResult<T> {
    conn.execute_batch("begin deferred")?;
    let result = read();
    match result {
        Ok(value) => match conn.execute_batch("commit") {
            Ok(()) => Ok(value),
            Err(error) => {
                let _ = conn.execute_batch("rollback");
                Err(error.into())
            }
        },
        Err(error) => {
            let _ = conn.execute_batch("rollback");
            Err(error)
        }
    }
}

struct ReadBatch {
    batch: Option<Batch>,
    vanished: Vec<(i64, Option<String>)>,
    refusal: Option<(i64, String, Option<String>)>,
    inflight: bool,
}

fn read_record(
    conn: &Connection,
    id: i64,
    key: Option<&str>,
    reference: bool,
) -> StoreResult<Option<String>> {
    if reference {
        let Some(session) = key.and_then(|key| key.strip_prefix("session:")) else {
            return Err(StoreError::Refused(
                "session reference has no session key".into(),
            ));
        };
        crate::hub_snapshot::build(conn, session, crate::hub_snapshot::Children::Include)?
            .map(|snapshot| session_envelope_json(&snapshot, None))
            .transpose()
    } else {
        let stored: String = conn.query_row(
            "select record_json from collector_upload_outbox where id=?",
            [id],
            |r| r.get(0),
        )?;
        unpack_record(stored).map(Some)
    }
}

fn read_batch(
    conn: &Connection,
    machine: &str,
    sequence: i64,
    isolate_until: Option<i64>,
    max_record_bytes: usize,
) -> StoreResult<ReadBatch> {
    let inflight: Option<(Option<String>, Option<i64>)> = conn
        .query_row(
            "select inflight_batch_id,inflight_last_id from collector_hub_state where id=1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    let mut result = ReadBatch {
        batch: None,
        vanished: Vec::new(),
        refusal: None,
        inflight: false,
    };
    if let Some((Some(batch_id), Some(last_id))) = inflight {
        let candidates: Vec<(i64,Option<String>,bool)> = conn.prepare("select id,record_key,record_json=?1 from collector_upload_outbox where id<=?2 order by id")?.query_map(params![SESSION_REF,last_id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?.collect::<Result<_,_>>()?;
        let mut rows = Vec::new();
        for (id, key, reference) in candidates {
            if let Some(json) = read_record(conn, id, key.as_deref(), reference)? {
                rows.push((id, json));
            }
        }
        result.inflight = true;
        result.batch = Some(Batch {
            batch_id,
            last_id,
            rows,
        });
        return Ok(result);
    }
    let candidates: Vec<(i64,Option<String>,bool,i64)> = conn.prepare(&format!("select id,record_key,record_json=?1,{} from collector_upload_outbox order by id limit ?2",record_bytes_sql()))?.query_map(params![SESSION_REF,if isolate_until.is_some(){1}else{MAX_RECORDS as i64}],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?)))?.collect::<Result<_,_>>()?;
    let mut rows = Vec::new();
    let mut bytes = 0usize;
    for (id, key, reference, stored_size) in candidates {
        let mut size = usize::try_from(stored_size).unwrap_or(usize::MAX);
        let json = if reference || size <= max_record_bytes {
            if !reference && !rows.is_empty() && bytes.saturating_add(size) > MAX_BATCH_BYTES {
                break;
            }
            match crate::timing::timed("hub: build record", || {
                read_record(conn, id, key.as_deref(), reference)
            }) {
                Ok(Some(json)) => {
                    if reference {
                        size = json.len();
                    }
                    Some(json)
                }
                Ok(None) => {
                    result.vanished.push((id, key));
                    continue;
                }
                Err(error @ StoreError::Io(_)) if !reference => {
                    if rows.is_empty() {
                        result.refusal = Some((id, error.to_string(), None));
                    }
                    break;
                }
                Err(error) => return Err(error),
            }
        } else {
            None
        };
        if size > max_record_bytes {
            if rows.is_empty() {
                result.refusal = Some((
                    id,
                    format!(
                        "record of {size} bytes exceeds the hub's {max_record_bytes}-byte record limit and was not sent"
                    ),
                    reference
                        .then(|| json!({"outbox_ref":"session_snapshot","bytes":size}).to_string()),
                ));
            }
            break;
        }
        if !rows.is_empty() && bytes.saturating_add(size) > MAX_BATCH_BYTES {
            break;
        }
        bytes += size;
        rows.push((id, json.expect("an allowed record was decoded")));
    }
    if let Some(&(last_id, _)) = rows.last() {
        let nonce: String = conn.query_row("select lower(hex(randomblob(8)))", [], |r| r.get(0))?;
        result.batch = Some(Batch {
            batch_id: format!("{machine}:{sequence}:{last_id}:{nonce}"),
            last_id,
            rows,
        });
    }
    Ok(result)
}

/// Only small queue bookkeeping runs under SQLite's write lock.
fn persist_batch(conn: &Connection, read: &ReadBatch) -> StoreResult<(usize, usize)> {
    if read.inflight {
        return Ok((0, 0));
    }
    let mut pruned = 0;
    for (id, key) in &read.vanished {
        pruned += conn.execute("delete from collector_upload_outbox where id=?", [id])?;
        if let Some(key) = key {
            conn.execute(
                "delete from collector_hub_record_state where record_key=?",
                [key],
            )?;
        }
    }
    let dead = if let Some((id, error, stored)) = &read.refusal {
        dead_letter(conn, *id, None, error, stored.as_deref())?;
        1
    } else {
        0
    };
    if let Some(batch) = &read.batch {
        conn.execute(
            "update collector_hub_state set inflight_batch_id=?,inflight_last_id=? where id=1",
            params![batch.batch_id, batch.last_id],
        )?;
        conn.execute(
            "delete from app_metadata where key=?",
            [INFLIGHT_FAILURES_KEY],
        )?;
    }
    Ok((pruned, dead))
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
        finish_pending_reset(conn).map_err(|error| error.to_string())?;
        if let Some(last) = isolate_until {
            let first: i64 = conn
                .query_row(
                    "select coalesce(min(id),0) from collector_upload_outbox",
                    [],
                    |row| row.get(0),
                )
                .map_err(|e| e.to_string())?;
            if first == 0 || first > last {
                isolate_until = None;
            }
        }
        let read = read_consistent(conn, || {
            read_batch(
                conn,
                &verified.machine,
                sequence + 1,
                isolate_until,
                verified.max_record_bytes,
            )
        })
        .map_err(|e| e.to_string())?;
        let (pruned, dead) = {
            let _phase = crate::store::write_budget::write_phase("hub");
            begin_write(conn).map_err(|e| e.to_string())?;
            finish(conn, persist_batch(conn, &read)).map_err(|e| e.to_string())?
        };
        report.pruned += pruned;
        report.dead_lettered += dead;
        drop(lease);
        let Some(batch) = read.batch else {
            if pruned > 0 || dead > 0 {
                continue;
            }
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
                let result = dead_letter(conn, batch.rows[0].0, Some(status), &message, None);
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
            "update collector_hub_state set enabled=0, last_sequence = ?, inflight_batch_id = null, inflight_last_id = null where id = 1",
            [verified.high_water],
        )?;
        store.conn.execute("insert into app_metadata(key,value,updated_at_utc) values(?,'resync',?) on conflict(key) do update set value=excluded.value,updated_at_utc=excluded.updated_at_utc", params![RESET_INTENT,crate::dart::DartDateTime::now().to_iso8601()])?;
        Ok(())
    })();
    finish(&store.conn, result).map_err(|error| error.to_string())?;
    #[cfg(feature = "test-hooks")]
    test_hooks::after_reset_commit().map_err(|error| error.to_string())?;
    finish_pending_reset(&store.conn).map_err(|error| error.to_string())?;
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
    fn oversize_reference_records_decoded_bytes_and_reconciles_after_limit_increases() {
        crate::store::connection::ensure().unwrap();
        let mut conn = Connection::open_in_memory().unwrap();
        crate::store::schema::prepare_standalone(&mut conn, ":memory:").unwrap();
        conn.execute("insert into collector_hub_state(id,enabled,hub_url,machine_id) values(1,1,'http://127.0.0.1:1','test')",[]).unwrap();
        let snapshot = serde_json::from_value(json!({
            "harness":"codex",
            "source":{"path":"C:/oversize","environment":"windows","state":"active","status":"available","size":1,"modified_utc":"2026-09-10T10:00:00.000Z","display_path":"C:/oversize","mapped_source_file_path":"C:/oversize","platform_path":"C:/oversize"},
            "session":{"session_id":"oversize","usage_projection_status":"complete","parser_version":5,"summary":"x".repeat(4096)}
        })).unwrap();
        crate::store::writer::apply_session_batch(&conn, vec![snapshot]).unwrap();
        let lease = crate::store::write_lease::WriteLease::acquire(&conn).unwrap();
        let read = read_consistent(&conn, || read_batch(&conn, "test", 1, None, 256)).unwrap();
        assert!(read.batch.is_none());
        let stored = read.refusal.as_ref().unwrap().2.as_ref().unwrap();
        let value: Value = serde_json::from_str(stored).unwrap();
        assert_eq!(value["outbox_ref"], "session_snapshot");
        assert!(value["bytes"].as_u64().unwrap() > 4096);
        begin_write(&conn).unwrap();
        assert_eq!(finish(&conn, persist_batch(&conn, &read)).unwrap(), (0, 1));
        drop(lease);
        assert_eq!(reconcile_dead_letters(&conn, 256).unwrap(), (0, 0));
        assert_eq!(reconcile_dead_letters(&conn, 1024 * 1024).unwrap(), (1, 0));
        let rebuilt =
            read_consistent(&conn, || read_batch(&conn, "test", 1, None, 1024 * 1024)).unwrap();
        let records = &rebuilt.batch.unwrap().rows;
        let session: Value = serde_json::from_str(&records[0].1).unwrap();
        assert_eq!(session["record"]["session"]["summary"], "x".repeat(4096));
        assert_eq!(session["version"], 2);
        assert_eq!(records.len(), 2); // current snapshot plus its lifecycle status
    }

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

    #[test]
    fn base64_round_trips_every_padding_length() {
        for length in 0usize..=7 {
            let bytes: Vec<u8> = (0..length).map(|value| (value * 89 + 250) as u8).collect();
            let mut text = String::new();
            base64_encode(&bytes, &mut text);
            assert_eq!(text.len(), length.div_ceil(3) * 4);
            assert_eq!(base64_decode(&text).unwrap(), bytes, "{text}");
        }
        let mut text = String::new();
        base64_encode(b"Man", &mut text);
        assert_eq!(text, "TWFu");
        assert_eq!(base64_decode("TWE=").unwrap(), b"Ma");
        assert_eq!(base64_decode("TQ==").unwrap(), b"M");
        assert!(base64_decode("TQ=").is_none());
        assert!(base64_decode("T===").is_none());
        assert!(base64_decode("TQ==TWFu").is_none());
        assert!(base64_decode("TW!u").is_none());
    }

    #[test]
    fn large_envelopes_are_stored_compressed_and_read_back_unchanged() {
        let small = r#"{"contract":"x","kind":"source_status"}"#.to_owned();
        assert_eq!(pack_record(small.clone()).unwrap(), small);
        assert_eq!(unpack_record(small.clone()).unwrap(), small);

        let messages: Vec<_> = (0..2000)
            .map(|index| json!({"index": index, "text": format!("message {index} with ünïcode text")}))
            .collect();
        let large =
            json!({"contract":"codex-sessions-viewer.ingest","record":{"messages":messages}})
                .to_string();
        let packed = pack_record(large.clone()).unwrap();
        assert!(packed.starts_with(PACKED_PREFIX));
        assert!(
            packed.len() * 4 < large.len(),
            "{} vs {}",
            packed.len(),
            large.len()
        );
        assert_eq!(unpack_record(packed.clone()).unwrap(), large);

        // The outbox CHECK accepts the wrapper, and SQL reports the decoded size.
        crate::store::connection::ensure().unwrap();
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch(
            "create table outbox(record_json text not null check (json_valid(record_json)))",
        )
        .unwrap();
        for record in [&small, &packed] {
            conn.execute("insert into outbox values (?)", [record])
                .unwrap();
        }
        let sizes: Vec<i64> = conn
            .prepare(&format!("select {} from outbox", record_bytes_sql()))
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(sizes, [small.len() as i64, large.len() as i64]);
    }

    #[test]
    fn a_damaged_packed_record_is_an_error_not_a_different_record() {
        let large = "x".repeat(PACK_AT * 2);
        let large = json!({ "text": large }).to_string();
        let packed = pack_record(large.clone()).unwrap();
        let wrong_size = packed.replacen(
            &format!("\"bytes\":{}", large.len()),
            &format!("\"bytes\":{}", large.len() + 1),
            1,
        );
        assert!(unpack_record(wrong_size).is_err());
        let truncated = format!("{PACKED_PREFIX}{},\"data\":\"AAAA\"}}", large.len());
        assert!(unpack_record(truncated).is_err());
    }
}
