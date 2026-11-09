//! Collector-local checkpoint persistence; every receipt is fenced by the row digest.
use std::collections::HashMap;
use std::io::Read;

use rusqlite::{Connection, OptionalExtension, params};

use super::StoreResult;
use crate::dart::DartDateTime;
use crate::path_mapping::canonical_scan_path;
use crate::resume::{
    CheckpointRecord, LoadedCheckpoint, MAX_BLOB_BYTES, MAX_DECODED_BYTES, Resume, ResumePolicy,
};

#[derive(Clone, Debug)]
pub struct CheckpointEntry {
    pub consumed: u64,
    pub content_hash: String,
    pub steps_since_full: u32,
    pub parse_options_hash: Option<String>,
}
pub type CheckpointIndex = HashMap<String, CheckpointEntry>;

/// No state blobs: idle scans only need to know whether a final full parse is due.
pub fn index(conn: &Connection, harness: &str) -> StoreResult<CheckpointIndex> {
    conn.prepare_cached("select source_key, consumed_bytes, content_hash, steps_since_full, parse_options_hash from session_parse_checkpoints where harness = ?")?
        .query_map([harness], |r| Ok((r.get(0)?, CheckpointEntry { consumed: r.get::<_, i64>(1)?.max(0) as u64, content_hash: r.get(2)?, steps_since_full: u32::try_from(r.get::<_, i64>(3)?).unwrap_or(1), parse_options_hash: r.get(4)? })))?
        .collect::<Result<_, _>>().map_err(Into::into)
}

pub fn load(
    conn: &Connection,
    harness: &str,
    path: &str,
    policy: ResumePolicy,
) -> StoreResult<Option<LoadedCheckpoint>> {
    let mut remaining = MAX_DECODED_BYTES;
    load_bounded(conn, harness, path, policy, &mut remaining)
}

/// The coordinating thread owns this shared remaining budget for a scan's jobs.
/// Count decompressed bytes before serde allocations; oversized jobs parse fully.
pub fn load_bounded(
    conn: &Connection,
    harness: &str,
    path: &str,
    policy: ResumePolicy,
    remaining: &mut usize,
) -> StoreResult<Option<LoadedCheckpoint>> {
    if !policy.enabled || *remaining == 0 {
        return Ok(None);
    }
    let found = conn
        .prepare_cached(&format!(
            "select c.session_row_id, c.content_hash, c.parser_version, c.format_version,
               c.consumed_bytes, c.state
        from session_parse_checkpoints c join sessions s on s.id = c.session_row_id
        where c.harness = ? and c.source_key = ? and c.source_file_path = ?
          and s.source_file_path = c.source_file_path and s.content_hash = c.content_hash
          and s.parser_version = c.parser_version and s.parse_options_hash = c.parse_options_hash and length(c.state) <= ?
          and c.consumed_bytes >= 0 and not ({})",
            super::writer::LEGACY_PREDICATE
        ))?
        .query_row(
            params![
                harness,
                canonical_scan_path(path),
                path,
                MAX_BLOB_BYTES as i64
            ],
            |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    CheckpointRecord {
                        harness: harness.to_owned(),
                        source_path: path.to_owned(),
                        parser_version: r.get(2)?,
                        format_version: r.get(3)?,
                        consumed_bytes: r.get::<_, i64>(4)?.max(0) as u64,
                        state: r.get(5)?,
                    },
                ))
            },
        )
        .optional()?;
    let Some((row_id, hash, record)) = found else {
        return Ok(None);
    };
    if record.consumed_bytes < policy.min_bytes
        || record.format_version != crate::resume::RESUME_FORMAT
        || super::schema::parser_version_key(harness)
            .is_some_and(|(_, current)| current != record.parser_version)
    {
        return Ok(None);
    }
    let limit = (*remaining).min(MAX_DECODED_BYTES);
    let Ok(reader) = zstd::stream::read::Decoder::new(record.state.as_slice()) else {
        return Ok(None);
    };
    let Ok(bytes) = std::io::copy(
        &mut reader.take((limit as u64).saturating_add(1)),
        &mut std::io::sink(),
    ) else {
        return Ok(None);
    };
    if bytes > limit as u64 {
        return Ok(None);
    }
    let Ok(checkpoint) = record.decode() else {
        return Ok(None);
    };
    *remaining -= bytes as usize;
    Ok(Some(LoadedCheckpoint {
        checkpoint: Box::new(checkpoint),
        row_id,
        expected_content_hash: hash,
        policy,
    }))
}

pub fn resume(conn: &Connection, harness: &str, path: &str, fresh: bool) -> StoreResult<Resume> {
    let policy = ResumePolicy::current();
    Ok(if fresh {
        Resume::Fresh(policy)
    } else {
        load(conn, harness, path, policy)?.map_or(Resume::Fresh(policy), Resume::From)
    })
}

pub fn delete_for_session(conn: &Connection, id: &str) -> StoreResult<()> {
    conn.prepare_cached("delete from session_parse_checkpoints where session_row_id = ?")?
        .execute([id])?;
    Ok(())
}

/// Child-row writers invalidate the CAS receipt while retaining the idle-heal
/// signal. An empty state is deliberately not decodable and always parses fully.
pub fn invalidate_for_session(conn: &Connection, id: &str) -> StoreResult<()> {
    conn.prepare_cached("update session_parse_checkpoints set state=x'', content_hash='', steps_since_full=1 where session_row_id=?")?.execute([id])?;
    Ok(())
}

/// A resumed parse may exceed the blob cap. It still needs one full idle parse;
/// do not lose that obligation merely because no resumable state can be stored.
pub fn mark_full_parse_due(
    conn: &Connection,
    id: &str,
    snapshot: &crate::contract::SessionSnapshot,
) -> StoreResult<()> {
    mark_revision(conn, id, snapshot, 1)
}

/// A final full parse may also exceed the blob cap. Retain a zero-step marker
/// so an unchanged partial tail is skipped, even without resumable state.
pub fn mark_full_parse_settled(
    conn: &Connection,
    id: &str,
    snapshot: &crate::contract::SessionSnapshot,
) -> StoreResult<()> {
    mark_revision(conn, id, snapshot, 0)
}

fn mark_revision(
    conn: &Connection,
    id: &str,
    snapshot: &crate::contract::SessionSnapshot,
    steps: u32,
) -> StoreResult<()> {
    conn.prepare_cached("insert into session_parse_checkpoints (harness,source_key,source_file_path,session_row_id,parser_version,format_version,consumed_bytes,content_hash,state,steps_since_full,parse_options_hash,updated_at_utc) values (?,?,?,?,?,?,0,'',x'',?,(select parse_options_hash from sessions where id=?),?) on conflict(harness,source_key) do update set source_file_path=excluded.source_file_path, session_row_id=excluded.session_row_id, parser_version=excluded.parser_version,format_version=excluded.format_version,consumed_bytes=0,content_hash='',state=x'',steps_since_full=excluded.steps_since_full,parse_options_hash=excluded.parse_options_hash,updated_at_utc=excluded.updated_at_utc")?
        .execute(params![snapshot.harness,canonical_scan_path(&snapshot.source.path),snapshot.source.path,id,snapshot.session.parser_version,crate::resume::RESUME_FORMAT,steps,id,DartDateTime::now().to_iso8601()])?;
    Ok(())
}

pub fn store(
    conn: &Connection,
    id: &str,
    record: &CheckpointRecord,
    hash: &str,
) -> StoreResult<()> {
    if let Some(prepared) = PreparedCheckpoint::new(record) {
        prepared.store(conn, id, hash)?;
    }
    Ok(())
}

/// Integrity verification can be expensive even for a bounded compressed blob.
/// Own the verified bytes so planning cannot detach the step count from them.
pub(crate) struct PreparedCheckpoint {
    record: CheckpointRecord,
    steps_since_full: u32,
    parse_options_hash: String,
}

impl PreparedCheckpoint {
    pub(crate) fn new(record: &CheckpointRecord) -> Option<Self> {
        let checkpoint = record.decode().ok()?;
        Some(Self {
            record: record.clone(),
            steps_since_full: checkpoint.steps_since_full,
            parse_options_hash: checkpoint.options.digest(),
        })
    }

    fn store(&self, conn: &Connection, id: &str, hash: &str) -> StoreResult<()> {
        let record = &self.record;
        conn.prepare_cached("insert into session_parse_checkpoints (harness, source_key, source_file_path, session_row_id, parser_version, format_version, consumed_bytes, content_hash, state, steps_since_full, parse_options_hash, updated_at_utc) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) on conflict(harness, source_key) do update set source_file_path=excluded.source_file_path, session_row_id=excluded.session_row_id, parser_version=excluded.parser_version, format_version=excluded.format_version, consumed_bytes=excluded.consumed_bytes, content_hash=excluded.content_hash, state=excluded.state, steps_since_full=excluded.steps_since_full, parse_options_hash=excluded.parse_options_hash, updated_at_utc=excluded.updated_at_utc")?
        .execute(params![record.harness, canonical_scan_path(&record.source_path), record.source_path, id, record.parser_version, record.format_version, record.consumed_bytes as i64, hash, record.state, self.steps_since_full, self.parse_options_hash, DartDateTime::now().to_iso8601()])?;
        Ok(())
    }
}

pub(crate) fn replace_prepared_for_session(
    conn: &Connection,
    id: &str,
    record: Option<&PreparedCheckpoint>,
    hash: &str,
) -> StoreResult<()> {
    delete_for_session(conn, id)?;
    if let Some(record) = record {
        record.store(conn, id, hash)?;
    }
    Ok(())
}

pub fn replace_for_session(
    conn: &Connection,
    id: &str,
    record: Option<&CheckpointRecord>,
    hash: &str,
) -> StoreResult<()> {
    delete_for_session(conn, id)?;
    if let Some(record) = record {
        store(conn, id, record, hash)?;
    }
    Ok(())
}
