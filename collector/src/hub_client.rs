//! Durable, optional upload of locally committed contract records.

use std::path::Path;
use std::time::Duration;

use rusqlite::{Connection, OptionalExtension, params};
use serde_json::{Value, json};

use crate::contract::{CONTRACT_NAME, CONTRACT_VERSION, Envelope, Record};
use crate::hub_server::HUB_PROTOCOL_VERSION;
use crate::store::schema::{
    SUPPORTED_SCHEMA_VERSION, StoreError, StoreResult, begin_write, finish,
};
use crate::store::{OwnerMode, Store};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncReport {
    pub sent: usize,
    pub pending: i64,
    pub last_sequence: i64,
}

/// Called while the local record transaction is open. No destination or
/// credential is stored with a record; hubs remain opt-in.
pub fn enqueue(conn: &Connection, record: Record, now: &str) -> StoreResult<()> {
    let table_exists: bool = conn.query_row(
        "select exists(select 1 from sqlite_schema where type = 'table' and name = 'collector_hub_state')",
        [],
        |row| row.get(0),
    )?;
    if !table_exists {
        return Ok(());
    }
    let enabled: bool = conn
        .query_row(
            "select enabled from collector_hub_state where id = 1",
            [],
            |row| row.get(0),
        )
        .optional()?
        .unwrap_or(false);
    if !enabled {
        return Ok(());
    }
    let envelope = serde_json::to_string(&Envelope::new(record))
        .map_err(|error| StoreError::Io(std::io::Error::other(error)))?;
    conn.execute(
        "insert into collector_upload_outbox(record_json, created_at_utc) values (?, ?)",
        params![envelope, now],
    )?;
    Ok(())
}

fn validate_url(url: &str) -> Result<String, String> {
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
    let safe_loopback = url.starts_with("http://127.0.0.1:")
        || url.starts_with("http://[::1]:")
        || url.starts_with("http://localhost:");
    if !url.starts_with("https://") && !safe_loopback {
        return Err("hub URL must use HTTPS, except a loopback listener".to_owned());
    }
    Ok(url.to_owned())
}

fn enable(store: &Store, url: &str, machine: &str) -> Result<i64, String> {
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

pub fn pending(conn: &Connection) -> StoreResult<i64> {
    Ok(
        conn.query_row("select count(*) from collector_upload_outbox", [], |row| {
            row.get(0)
        })?,
    )
}

/// An acknowledged record is removed only after the server's matching
/// sequence and batch ID are observed. A lost acknowledgment retries the
/// exact record and the server returns a duplicate acknowledgment.
pub fn sync(db_path: &Path, mode: OwnerMode, url: &str, token: &str) -> Result<SyncReport, String> {
    let url = validate_url(url)?;
    if token.trim().is_empty() {
        return Err("hub credential is missing".to_owned());
    }
    let store = Store::open(db_path, mode).map_err(|error| error.to_string())?;
    let machine = store
        .machine_id()
        .map_err(|error| error.to_string())?
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "local database has no machine identity".to_owned())?;
    let mut sequence = enable(&store, &url, &machine)?;
    let agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(15)))
        .build()
        .new_agent();
    let mut verify = agent
        .get(format!("{url}/v1/verify"))
        .header("Authorization", format!("Bearer {token}"))
        .call()
        .map_err(|error| format!("hub compatibility check failed: {error}"))?;
    let server: Value = verify
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
    let mut sent = 0usize;
    while sent < 256 {
        let next: Option<(i64, String)> = store
            .conn
            .query_row(
                "select id, record_json from collector_upload_outbox order by id limit 1",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()
            .map_err(|error| error.to_string())?;
        let Some((id, record_json)) = next else {
            break;
        };
        let record: Value = serde_json::from_str(&record_json)
            .map_err(|error| format!("queued record {id} is malformed: {error}"))?;
        let batch_id = format!("{machine}:{id}");
        let expected = sequence + 1;
        let payload = json!({
            "protocol": HUB_PROTOCOL_VERSION,
            "sequence": expected,
            "batch_id": batch_id,
            "records": [record]
        });
        let mut response = agent
            .post(format!("{url}/v1/ingest"))
            .header("Authorization", format!("Bearer {token}"))
            .send_json(&payload)
            .map_err(|error| format!("hub upload failed; local record remains queued: {error}"))?;
        let ack: Value = response.body_mut().read_json().map_err(|_| {
            "hub returned an invalid acknowledgment; local record remains queued".to_owned()
        })?;
        if ack["protocol"] != HUB_PROTOCOL_VERSION
            || ack["sequence"] != expected
            || ack["batch_id"] != batch_id
        {
            return Err("hub acknowledgment does not match the queued record".to_owned());
        }
        begin_write(&store.conn).map_err(|error| error.to_string())?;
        let result = (|| -> StoreResult<()> {
            store
                .conn
                .execute("delete from collector_upload_outbox where id = ?", [id])?;
            store.conn.execute(
                "update collector_hub_state set last_sequence = ? where id = 1",
                [expected],
            )?;
            Ok(())
        })();
        finish(&store.conn, result).map_err(|error| error.to_string())?;
        sequence = expected;
        sent += 1;
    }
    Ok(SyncReport {
        sent,
        pending: pending(&store.conn).map_err(|error| error.to_string())?,
        last_sequence: sequence,
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
