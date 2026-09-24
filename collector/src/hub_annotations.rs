//! Hub-owned notes are separate from source records and survive re-ingestion.

use std::path::Path;

use rusqlite::{OptionalExtension, TransactionBehavior, params};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::hub_server::{HUB_PROTOCOL_VERSION, HubConfig, open_machine};

#[derive(Deserialize)]
struct ReadRequest {
    protocol: u64,
    machine: String,
    reference: String,
}

#[derive(Deserialize)]
struct EditRequest {
    protocol: u64,
    machine: String,
    reference: String,
    expected_revision: i64,
    title: Option<String>,
    notes: Option<String>,
}

fn validate(
    config: &HubConfig,
    protocol: u64,
    machine: &str,
    reference: &str,
) -> Result<(), (u16, String)> {
    if protocol != HUB_PROTOCOL_VERSION {
        return Err((409, "unsupported hub protocol version".into()));
    }
    if !config.machines.contains_key(machine) {
        return Err((404, "unknown machine".into()));
    }
    if reference.len() > 1024 || !reference.starts_with(&format!("history://{machine}/")) {
        return Err((400, "invalid session reference".into()));
    }
    Ok(())
}

fn exists(conn: &rusqlite::Connection, reference: &str) -> Result<bool, (u16, String)> {
    conn.query_row(
        "select exists(select 1 from history_sessions where reference = ?)",
        [reference],
        |row| row.get(0),
    )
    .map_err(|_| (500, "cannot verify hub session".into()))
}

pub fn read(data_root: &Path, config: &HubConfig, value: Value) -> Result<Value, (u16, String)> {
    let request: ReadRequest = serde_json::from_value(value)
        .map_err(|_| (400, "invalid annotation request".to_owned()))?;
    validate(
        config,
        request.protocol,
        &request.machine,
        &request.reference,
    )?;
    let store = open_machine(data_root, &request.machine)
        .map_err(|_| (500, "cannot open hub database".to_owned()))?;
    if !exists(&store.conn, &request.reference)? {
        return Err((404, "session not found".into()));
    }
    let row: Option<(i64, Option<String>, Option<String>)> = store
        .conn
        .query_row(
            "select revision, title, notes from hub_annotations where reference = ?",
            [&request.reference],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()
        .map_err(|_| (500, "cannot read hub annotation".to_owned()))?;
    let (revision, title, notes) = row.unwrap_or((0, None, None));
    Ok(
        json!({"protocol":HUB_PROTOCOL_VERSION,"machine":request.machine,"reference":request.reference,"revision":revision,"title":title,"notes":notes}),
    )
}

pub fn edit(data_root: &Path, config: &HubConfig, value: Value) -> Result<Value, (u16, String)> {
    let request: EditRequest =
        serde_json::from_value(value).map_err(|_| (400, "invalid annotation edit".to_owned()))?;
    validate(
        config,
        request.protocol,
        &request.machine,
        &request.reference,
    )?;
    if request.expected_revision < 0
        || request
            .title
            .as_ref()
            .is_some_and(|text| text.chars().count() > 200)
        || request
            .notes
            .as_ref()
            .is_some_and(|text| text.chars().count() > 20000)
    {
        return Err((400, "annotation exceeds allowed length or revision".into()));
    }
    let mut store = open_machine(data_root, &request.machine)
        .map_err(|_| (500, "cannot open hub database".to_owned()))?;
    let tx = store
        .conn
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(|_| (500, "cannot begin annotation edit".to_owned()))?;
    if !exists(&tx, &request.reference)? {
        return Err((404, "session not found".into()));
    }
    let current: Option<i64> = tx
        .query_row(
            "select revision from hub_annotations where reference = ?",
            [&request.reference],
            |row| row.get(0),
        )
        .optional()
        .map_err(|_| (500, "cannot read annotation revision".to_owned()))?;
    if current.unwrap_or(0) != request.expected_revision {
        return Err((409, "annotation changed; reload before saving".into()));
    }
    let next = request
        .expected_revision
        .checked_add(1)
        .ok_or((400, "annotation revision is too large".to_owned()))?;
    tx.execute(
        "insert into hub_annotations(reference, revision, title, notes) values (?, ?, ?, ?)
         on conflict(reference) do update set revision = excluded.revision,
         title = excluded.title, notes = excluded.notes",
        params![request.reference, next, request.title, request.notes],
    )
    .map_err(|_| (500, "cannot save hub annotation".to_owned()))?;
    tx.commit()
        .map_err(|_| (500, "cannot commit hub annotation".to_owned()))?;
    Ok(
        json!({"protocol":HUB_PROTOCOL_VERSION,"machine":request.machine,"reference":request.reference,"revision":next,"title":request.title,"notes":request.notes}),
    )
}
