//! `hub backfill`: queue stored sessions whose source files are gone.
//!
//! Hub delivery builds snapshots from the current stored rows.
//! A session collected before the machine was paired, whose file has since
//! been deleted, exists only in the local database. Backfill rebuilds its
//! snapshot from the stored rows and queues it with an explicit missing
//! status, so the hub keeps the history and knows that the file is gone.
//!
//! The rebuilt snapshot is the stored state. Reasoning and cache-write tokens
//! are retained after schema migration and re-ingest. A hub that already holds a parsed copy keeps that
//! copy, because a missing source ranks below an available one.

use std::path::Path;

use rusqlite::Connection;

use crate::contract::Record;
use crate::dart::DartDateTime;
use crate::store::schema::{StoreError, StoreResult, begin_write, finish};
use crate::store::{OwnerMode, Store};

/// Sessions queued per write transaction, so the viewer's writers wait for
/// at most one chunk.
const CHUNK: usize = 32;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BackfillReport {
    pub candidates: usize,
    /// Recorded missing, but the file (or its `.zst`) is on disk again.
    pub still_present: usize,
    pub queued: usize,
    pub pending: i64,
}

/// Queues every available-parse session whose source is recorded missing.
/// Refuses when hub delivery is not enabled: nothing would be queued.
pub fn backfill(db_path: &Path, mode: OwnerMode) -> Result<BackfillReport, String> {
    let _wait = crate::store::write_lease::LeaseWait::enter(crate::hub_client::LEASE_WAIT);
    let store = Store::open(db_path, mode).map_err(|error| error.to_string())?;
    run(&store.conn).map_err(|error| error.to_string())
}

fn run(conn: &Connection) -> StoreResult<BackfillReport> {
    if !crate::hub_client::queue_enabled(conn)? {
        return Err(StoreError::Refused(
            "hub delivery is not enabled; run hub enable first".to_owned(),
        ));
    }
    let recorded: Vec<(String, Option<String>, Option<String>)> = conn
        .prepare(
            "select id, source_file_path, source_file_unc_path from sessions
             where scan_status = 'missing' and parse_status = 'available'
               and message_count > 0
             order by coalesce(last_message_at_utc, started_at_utc), id",
        )?
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
        .collect::<Result<_, _>>()?;
    let mut report = BackfillReport {
        candidates: recorded.len(),
        ..BackfillReport::default()
    };
    // A file that still exists, or that Codex compressed in place, is sent
    // parsed by the next scan; the stored rows would only be a weaker copy.
    let ids: Vec<String> = recorded
        .into_iter()
        .filter(|(_, path, unc)| {
            let present = [path, unc]
                .into_iter()
                .flatten()
                .any(|path| Path::new(path).exists() || Path::new(&format!("{path}.zst")).exists());
            report.still_present += usize::from(present);
            !present
        })
        .map(|(id, _, _)| id)
        .collect();
    for chunk in ids.chunks(CHUNK) {
        let _lease = crate::store::write_lease::WriteLease::acquire(conn)?;
        let _phase = crate::store::write_budget::write_phase("hub");
        begin_write(conn)?;
        let result = (|| -> StoreResult<usize> {
            if !crate::hub_client::queue_enabled(conn)? {
                return Err(StoreError::Refused(
                    "hub delivery was disabled before backfill committed".to_owned(),
                ));
            }
            let now = DartDateTime::now().to_iso8601();
            let mut queued = 0;
            for id in chunk {
                // Revalidated under the lock: a scan may have found the file.
                let qualifies: bool = conn.query_row("select exists(select 1 from sessions where id=? and scan_status='missing' and parse_status='available' and message_count>0)", [id], |r| r.get(0))?;
                if !qualifies {
                    continue;
                }
                let Some(snapshot) =
                    crate::hub_snapshot::build(conn, id, crate::hub_snapshot::Children::Omit)?
                else {
                    continue;
                };
                crate::hub_client::enqueue_session(
                    conn,
                    id,
                    &snapshot.harness,
                    &snapshot.source.path,
                    &now,
                    true,
                )?;
                if let Some(status) = crate::hub_snapshot::current_status(conn, id)? {
                    crate::hub_client::enqueue(conn, Record::SourceStatus(status), &now)?;
                }
                queued += 1;
            }
            Ok(queued)
        })();
        report.queued += finish(conn, result)?;
    }
    report.pending = crate::hub_client::pending(conn)?;
    Ok(report)
}
