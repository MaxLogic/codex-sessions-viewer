//! The one-time repair of the legacy Codex session cache
//! (`session_cache_repair.v3`), moved from the viewer so only the collector
//! writes parsed session state.
//!
//! Early viewer releases stored placeholder rows (`source:` and
//! `source-status:` IDs) for files that were not sessions, and fallback rows
//! that duplicate a canonical session. After a scan that reached every
//! configured Codex home, the repair records a content-free audit manifest,
//! takes a verified backup, and deletes only rows that satisfy every legacy
//! allowlist predicate. Any doubt postpones the repair to a later scan.

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::Serialize;
use serde_json::{Value, json};

use crate::codex::parser::SourceType;
use crate::codex::scanner::ScanRoot;
use crate::dart::{DartDateTime, sha256_hex};

use super::Store;
use super::schema::{StoreError, StoreResult, begin_write, finish, last_applied_version};

pub const REPAIR_VERSION: i64 = 3;
/// The viewer and older collectors check this key; it must not change.
pub const COMPLETION_KEY: &str = "session_cache_repair.v3.completed";

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Category {
    Canonical,
    Relocated,
    FallbackDuplicate,
    LegacyNonSessionArtifact,
    Unresolved,
}

impl Category {
    pub const ALL: [Self; 5] = [
        Self::Canonical,
        Self::Relocated,
        Self::FallbackDuplicate,
        Self::LegacyNonSessionArtifact,
        Self::Unresolved,
    ];

    pub fn wire_name(self) -> &'static str {
        match self {
            Self::Canonical => "canonical",
            Self::Relocated => "relocated",
            Self::FallbackDuplicate => "fallback_duplicate",
            Self::LegacyNonSessionArtifact => "legacy_non_session_artifact",
            Self::Unresolved => "unresolved",
        }
    }
}

/// What a scan reports about the repair. It never fails a scan.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct RepairReport {
    /// `completed`, `already_completed`, or `postponed`.
    pub status: &'static str,
    pub reason_code: &'static str,
    pub deleted_rows: usize,
    /// Audited rows per category; empty when no audit ran.
    pub categories: BTreeMap<&'static str, usize>,
    /// The verified pre-repair backup's file name, when rows were deleted.
    pub backup_file: Option<String>,
}

impl RepairReport {
    fn new(status: &'static str, reason_code: &'static str, audit: Option<&Audit>) -> Self {
        Self {
            status,
            reason_code,
            deleted_rows: 0,
            categories: audit.map(Audit::category_counts).unwrap_or_default(),
            backup_file: None,
        }
    }

    fn postponed(reason_code: &'static str, audit: Option<&Audit>) -> Self {
        Self::new("postponed", reason_code, audit)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Entry {
    row_id: i64,
    fingerprint: String,
    category: Category,
    reason_code: &'static str,
    delete_eligible: bool,
}

struct Audit {
    id: String,
    entries: Vec<Entry>,
}

impl Audit {
    fn category_counts(&self) -> BTreeMap<&'static str, usize> {
        let mut counts: BTreeMap<&'static str, usize> = Category::ALL
            .iter()
            .map(|category| (category.wire_name(), 0))
            .collect();
        for entry in &self.entries {
            *counts.entry(entry.category.wire_name()).or_default() += 1;
        }
        counts
    }

    fn delete_eligible(&self) -> usize {
        self.entries
            .iter()
            .filter(|entry| entry.delete_eligible)
            .count()
    }
}

/// Resolves a path to its physical location, failing for anything that is
/// not a plain file or a directory (or a directory link) as expected.
pub type PhysicalPathResolver = dyn Fn(&str, bool) -> Result<String, String>;

/// Run the repair after a scan. `discovery_complete` is true when the scan
/// reached every configured root, was not cancelled, and failed no file.
pub fn run(
    store: &Store,
    roots: &[ScanRoot],
    discovery_complete: bool,
    cancel: &Arc<AtomicBool>,
) -> RepairReport {
    run_with(
        &store.conn,
        Path::new(&store.path),
        roots,
        discovery_complete,
        cancel,
        &resolve_physical_path_strict,
    )
}

pub fn run_with(
    conn: &Connection,
    database: &Path,
    roots: &[ScanRoot],
    discovery_complete: bool,
    cancel: &Arc<AtomicBool>,
    resolver: &PhysicalPathResolver,
) -> RepairReport {
    match repair(conn, database, roots, discovery_complete, cancel, resolver) {
        Ok(report) => report,
        Err(_) => {
            if !conn.is_autocommit() {
                let _ = conn.execute_batch("rollback");
            }
            RepairReport::postponed("unexpected_repair_error", None)
        }
    }
}

fn repair(
    conn: &Connection,
    database: &Path,
    roots: &[ScanRoot],
    discovery_complete: bool,
    cancel: &Arc<AtomicBool>,
    resolver: &PhysicalPathResolver,
) -> StoreResult<RepairReport> {
    let cancelled = || cancel.load(Ordering::Relaxed);
    if is_completed(conn)? {
        return Ok(RepairReport::new(
            "already_completed",
            "already_completed",
            None,
        ));
    }
    if cancelled() {
        return Ok(RepairReport::postponed("cancelled", None));
    }
    let cleanup_discovery_complete = discovery_complete && has_recognized_codex_owners(roots);
    let audit = record_audit(conn, roots, cleanup_discovery_complete, resolver)?;
    if !cleanup_discovery_complete {
        return Ok(RepairReport::postponed(
            if discovery_complete {
                "no_recognized_codex_owner"
            } else {
                "root_discovery_incomplete"
            },
            Some(&audit),
        ));
    }
    if audit.delete_eligible() == 0 {
        if cancelled() {
            return Ok(RepairReport::postponed("cancelled", Some(&audit)));
        }
        begin_write(conn)?;
        let result = (|| -> StoreResult<()> {
            if classify_rows(conn, roots, true, resolver)? != audit.entries {
                return Err(StoreError::Refused(
                    "repair predicates changed after the audit".to_owned(),
                ));
            }
            write_completion(conn, &audit.id)
        })();
        return Ok(match finish(conn, result) {
            Ok(()) => RepairReport::new("completed", "no_changes", Some(&audit)),
            Err(_) => RepairReport::postponed("repair_invariant_failed", Some(&audit)),
        });
    }

    let data_version = data_version(conn)?;
    if cancelled() {
        return Ok(RepairReport::postponed("cancelled", Some(&audit)));
    }
    let backup_directory = database
        .parent()
        .map_or_else(|| PathBuf::from("backups"), |parent| parent.join("backups"));
    let backup = backup_directory.join(backup_name(database, &audit.id));
    if let Err(_error) = create_verified_backup(conn, database, &backup, &audit) {
        discard_backup(&backup);
        return Ok(RepairReport::postponed("backup_failed", Some(&audit)));
    }
    if cancelled() {
        discard_backup(&backup);
        return Ok(RepairReport::postponed("cancelled", Some(&audit)));
    }

    begin_write(conn)?;
    let result = (|| -> StoreResult<usize> {
        if self::data_version(conn)? != data_version {
            return Err(StoreError::Refused(
                "the database changed after the repair audit".to_owned(),
            ));
        }
        let entries = classify_rows(conn, roots, true, resolver)?;
        if entries != audit.entries {
            return Err(StoreError::Refused(
                "repair predicates changed after the backup".to_owned(),
            ));
        }
        let mut deleted = 0;
        for entry in entries.iter().filter(|entry| entry.delete_eligible) {
            let id: String = conn
                .query_row(
                    "select id from sessions where rowid = ?",
                    [entry.row_id],
                    |row| row.get(0),
                )
                .optional()?
                .ok_or_else(|| StoreError::Refused("a repair candidate disappeared".to_owned()))?;
            conn.execute("delete from usage_events where session_row_id = ?", [&id])?;
            conn.execute("delete from tool_calls where session_id = ?", [&id])?;
            conn.execute("delete from messages where session_id = ?", [&id])?;
            conn.execute("delete from session_tags where session_id = ?", [&id])?;
            conn.execute("delete from session_path_keys where session_id = ?", [&id])?;
            conn.execute("delete from session_search where rowid = ?", [entry.row_id])?;
            conn.execute("delete from sessions where rowid = ?", [entry.row_id])?;
            deleted += 1;
        }
        write_completion(conn, &audit.id)?;
        if !is_healthy(conn)? {
            return Err(StoreError::Refused(
                "repair database invariants failed".to_owned(),
            ));
        }
        Ok(deleted)
    })();
    match finish(conn, result) {
        Ok(deleted) => {
            let mut report = RepairReport::new("completed", "completed", Some(&audit));
            report.deleted_rows = deleted;
            report.backup_file = backup
                .file_name()
                .map(|name| name.to_string_lossy().into_owned());
            Ok(report)
        }
        Err(_) => {
            discard_backup(&backup);
            Ok(RepairReport::postponed(
                "repair_invariant_failed",
                Some(&audit),
            ))
        }
    }
}

fn is_completed(conn: &Connection) -> StoreResult<bool> {
    Ok(conn
        .query_row(
            "select 1 from app_metadata where key = ?",
            [COMPLETION_KEY],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

fn write_completion(conn: &Connection, audit_id: &str) -> StoreResult<()> {
    conn.execute(
        "insert into app_metadata (key, value, updated_at_utc) values (?, ?, ?)
         on conflict(key) do update set value = excluded.value, updated_at_utc = excluded.updated_at_utc",
        params![COMPLETION_KEY, audit_id, DartDateTime::now().to_iso8601()],
    )?;
    Ok(())
}

static AUDIT_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn record_audit(
    conn: &Connection,
    roots: &[ScanRoot],
    discovery_complete: bool,
    resolver: &PhysicalPathResolver,
) -> StoreResult<Audit> {
    let now = DartDateTime::now();
    let id = format!(
        "repair-{REPAIR_VERSION}-{}-{}",
        now.micros(),
        AUDIT_SEQUENCE.fetch_add(1, Ordering::Relaxed) + 1
    );
    let entries = classify_rows(conn, roots, discovery_complete, resolver)?;
    begin_write(conn)?;
    let result = (|| -> StoreResult<()> {
        conn.execute("delete from session_cache_repair_manifest", [])?;
        let mut insert = conn.prepare(
            "insert into session_cache_repair_manifest (
               audit_id, repair_version, session_rowid, row_fingerprint,
               category, reason_code, delete_eligible, recorded_at_utc
             ) values (?, ?, ?, ?, ?, ?, ?, ?)",
        )?;
        let recorded = now.to_iso8601();
        for entry in &entries {
            insert.execute(params![
                id,
                REPAIR_VERSION,
                entry.row_id,
                entry.fingerprint,
                entry.category.wire_name(),
                entry.reason_code,
                entry.delete_eligible,
                recorded,
            ])?;
        }
        Ok(())
    })();
    finish(conn, result)?;
    Ok(Audit { id, entries })
}

fn backup_name(database: &Path, audit_id: &str) -> String {
    let stem = database.file_stem().map_or_else(
        || "database".to_owned(),
        |stem| stem.to_string_lossy().into_owned(),
    );
    format!("{stem}.pre-session-cache-repair-v{REPAIR_VERSION}.{audit_id}.sqlite")
}

fn create_verified_backup(
    conn: &Connection,
    database: &Path,
    backup: &Path,
    audit: &Audit,
) -> Result<(), String> {
    let same = |left: &Path, right: &Path| {
        std::path::absolute(left)
            .ok()
            .zip(std::path::absolute(right).ok())
            .is_some_and(|(left, right)| {
                left.to_string_lossy().to_lowercase() == right.to_string_lossy().to_lowercase()
            })
    };
    if same(backup, database) {
        return Err("the repair backup cannot be the source database".to_owned());
    }
    if let Some(parent) = backup.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    conn.execute("vacuum into ?", [backup.to_string_lossy().into_owned()])
        .map_err(|error| error.to_string())?;
    let expected_schema = last_applied_version(conn).map_err(|error| error.to_string())?;
    verify_backup(backup, audit, expected_schema).map_err(|error| error.to_string())
}

fn verify_backup(backup: &Path, audit: &Audit, expected_schema: i64) -> StoreResult<()> {
    let verification = Connection::open_with_flags(
        backup,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    if !is_healthy(&verification)? {
        return Err(StoreError::Refused(
            "the repair backup failed SQLite integrity checks".to_owned(),
        ));
    }
    if last_applied_version(&verification)? != expected_schema {
        return Err(StoreError::Refused(
            "the repair backup has an unexpected schema version".to_owned(),
        ));
    }
    let mut statement = verification.prepare(
        "select session_rowid, row_fingerprint, category, reason_code, delete_eligible
         from session_cache_repair_manifest where audit_id = ? order by session_rowid",
    )?;
    let rows: Vec<(i64, String, String, String, bool)> = statement
        .query_map([&audit.id], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
            ))
        })?
        .collect::<Result<_, _>>()?;
    let mut expected: Vec<&Entry> = audit.entries.iter().collect();
    expected.sort_by_key(|entry| entry.row_id);
    let matches = rows.len() == expected.len()
        && rows.iter().zip(&expected).all(|(row, entry)| {
            row.0 == entry.row_id
                && row.1 == entry.fingerprint
                && row.2 == entry.category.wire_name()
                && row.3 == entry.reason_code
                && row.4 == entry.delete_eligible
        });
    if !matches {
        return Err(StoreError::Refused(
            "the repair backup manifest does not match the audit".to_owned(),
        ));
    }
    Ok(())
}

fn discard_backup(backup: &Path) {
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut path = backup.as_os_str().to_owned();
        path.push(suffix);
        let _ = std::fs::remove_file(PathBuf::from(path));
    }
}

fn data_version(conn: &Connection) -> StoreResult<i64> {
    Ok(conn.query_row("pragma data_version", [], |row| row.get(0))?)
}

fn is_healthy(conn: &Connection) -> StoreResult<bool> {
    let integrity: Vec<String> = conn
        .prepare("pragma integrity_check")?
        .query_map([], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    let foreign_key_problems = conn
        .prepare("pragma foreign_key_check")?
        .query_map([], |_| Ok(()))?
        .count();
    Ok(integrity == ["ok"] && foreign_key_problems == 0)
}

fn has_recognized_codex_owners(roots: &[ScanRoot]) -> bool {
    !roots.is_empty()
        && roots.iter().all(|root| {
            let Some(owner) = root.availability_root_path.as_deref() else {
                return false;
            };
            if owner.trim().is_empty() {
                return false;
            }
            let leaf = leaf_name(&root.path).to_lowercase();
            match root.source_state {
                "active" => leaf == "sessions",
                "codex_archived" => leaf == "archived_sessions",
                _ => false,
            }
        })
}

fn leaf_name(path: &str) -> &str {
    path.trim_end_matches(['\\', '/'])
        .rsplit(['\\', '/'])
        .next()
        .unwrap_or("")
}

struct Row {
    row_id: i64,
    id: String,
    session_id: Option<String>,
    source_type: Option<String>,
    paths: Vec<String>,
    parser_version: Option<i64>,
    flags: [bool; 4],
    texts: [Option<String>; 7],
    counts: [i64; 4],
}

impl Row {
    fn source_type(&self) -> SourceType {
        if self.source_type.as_deref() == Some("wsl") {
            SourceType::Wsl
        } else {
            SourceType::Windows
        }
    }

    fn stable_id(&self) -> &str {
        self.session_id.as_deref().unwrap_or("").trim()
    }

    fn is_fallback(&self) -> bool {
        self.id.starts_with("source:") || self.id.starts_with("source-status:")
    }

    fn has_protected_metadata(&self) -> bool {
        self.flags.iter().any(|flag| *flag)
            || self
                .texts
                .iter()
                .any(|text| text.as_deref().is_some_and(|text| !text.trim().is_empty()))
            || self.counts[3] != 0
    }

    fn fingerprint(&self) -> String {
        let mut values: Vec<Value> = vec![
            json!(self.row_id),
            json!(self.id),
            json!(self.session_id),
            json!(self.source_type),
        ];
        values.extend(self.paths.iter().map(|path| json!(path)));
        values.push(json!(self.parser_version));
        values.extend(self.flags.iter().map(|flag| json!(flag)));
        values.extend(self.texts.iter().map(|text| json!(text)));
        values.extend(self.counts.iter().map(|count| json!(count)));
        sha256_hex(Value::Array(values).to_string().as_bytes())
    }
}

fn load_rows(conn: &Connection) -> StoreResult<Vec<Row>> {
    let mut statement = conn.prepare(
        "select s.rowid, s.id, s.session_id, s.source_type,
           s.source_file_path, s.source_file_unc_path, s.display_path, s.platform_path,
           s.parser_version,
           coalesce(s.is_pinned, 0) = 1, coalesce(s.is_archived, 0) = 1,
           coalesce(s.project_override, 0) = 1, coalesce(s.eval_ready, 0) = 1,
           s.archived_at_utc, s.archive_reason, s.eval_status, s.eval_notes,
           s.eval_expected_output, s.eval_reviewed_at_utc, s.eval_updated_at_utc,
           (select count(*) from messages m where m.session_id = s.id),
           (select count(*) from tool_calls tc where tc.session_id = s.id),
           (select count(*) from usage_events ue where ue.session_row_id = s.id),
           (select count(*) from session_tags st where st.session_id = s.id)
         from sessions s where s.harness = 'codex' order by s.rowid",
    )?;
    let rows = statement
        .query_map([], |row| {
            let mut paths: Vec<String> = Vec::new();
            for index in 4..8 {
                if let Some(path) = row.get::<_, Option<String>>(index)? {
                    let path = path.trim().to_owned();
                    if !path.is_empty() && !paths.contains(&path) {
                        paths.push(path);
                    }
                }
            }
            Ok(Row {
                row_id: row.get(0)?,
                id: row.get(1)?,
                session_id: row.get(2)?,
                source_type: row.get(3)?,
                paths,
                parser_version: row.get(8)?,
                flags: [row.get(9)?, row.get(10)?, row.get(11)?, row.get(12)?],
                texts: [
                    row.get(13)?,
                    row.get(14)?,
                    row.get(15)?,
                    row.get(16)?,
                    row.get(17)?,
                    row.get(18)?,
                    row.get(19)?,
                ],
                counts: [row.get(20)?, row.get(21)?, row.get(22)?, row.get(23)?],
            })
        })?
        .collect::<Result<_, _>>()?;
    Ok(rows)
}

fn classify_rows(
    conn: &Connection,
    roots: &[ScanRoot],
    discovery_complete: bool,
    resolver: &PhysicalPathResolver,
) -> StoreResult<Vec<Entry>> {
    let rows = load_rows(conn)?;
    let mut canonical: HashSet<(bool, String)> = HashSet::new();
    for row in &rows {
        if row.stable_id().is_empty() {
            continue;
        }
        let source_type = row.source_type();
        if !within_any_root(&row.paths, roots, source_type) {
            continue;
        }
        for path in &row.paths {
            canonical.insert((source_type == SourceType::Wsl, path_key(path, source_type)));
        }
    }
    Ok(rows
        .iter()
        .map(|row| classify_row(row, roots, &canonical, discovery_complete, resolver))
        .collect())
}

fn classify_row(
    row: &Row,
    roots: &[ScanRoot],
    canonical: &HashSet<(bool, String)>,
    discovery_complete: bool,
    resolver: &PhysicalPathResolver,
) -> Entry {
    let entry = |category, reason_code, delete_eligible| Entry {
        row_id: row.row_id,
        fingerprint: row.fingerprint(),
        category,
        reason_code,
        delete_eligible,
    };
    let unresolved = |reason| entry(Category::Unresolved, reason, false);
    if !discovery_complete {
        return unresolved("root_discovery_incomplete");
    }
    let source_type = row.source_type();
    let paths = &row.paths;
    if !row.stable_id().is_empty() {
        if within_state_root(paths, roots, source_type, "active") {
            return entry(Category::Canonical, "stable_active_session", false);
        }
        if within_state_root(paths, roots, source_type, "codex_archived") {
            return entry(Category::Relocated, "stable_archived_session", false);
        }
        return unresolved("stable_identity_outside_session_roots");
    }
    if paths.iter().any(|path| has_traversal_segment(path)) {
        return unresolved("path_traversal_ambiguous");
    }
    let parser_version = row.parser_version.unwrap_or(0);
    let owns_nothing = row.counts[0] == 0 && row.counts[1] == 0 && row.counts[2] == 0;
    if paths.iter().any(|path| {
        canonical.contains(&(source_type == SourceType::Wsl, path_key(path, source_type)))
    }) {
        let empty_legacy = row.is_fallback()
            && parser_version == 1
            && !row.has_protected_metadata()
            && owns_nothing;
        return entry(
            Category::FallbackDuplicate,
            if empty_legacy {
                "canonical_path_match_empty_legacy"
            } else {
                "canonical_path_match_requires_reconciliation"
            },
            empty_legacy,
        );
    }
    if !row.is_fallback() {
        return unresolved("non_fallback_identity");
    }
    if contains_session_namespace(paths, source_type) {
        return unresolved("session_namespace_path");
    }
    if row.has_protected_metadata() {
        return unresolved("protected_viewer_metadata");
    }
    if row.counts[0] != 0 {
        return unresolved("owns_messages");
    }
    if row.counts[1] != 0 {
        return unresolved("owns_tools");
    }
    if row.counts[2] != 0 {
        return unresolved("owns_usage_events");
    }
    if parser_version != 1 {
        return unresolved("current_parser_version");
    }
    if within_any_root(paths, roots, source_type) {
        return unresolved("fallback_in_session_root");
    }
    let Some(physical) = resolve_file_aliases(paths, source_type, resolver) else {
        return unresolved("source_alias_resolution_ambiguous");
    };
    if known_non_session_namespace(&physical, roots, source_type, resolver).is_none() {
        return unresolved("source_namespace_not_allowlisted");
    }
    entry(
        Category::LegacyNonSessionArtifact,
        "allowlisted_non_session_namespace",
        true,
    )
}

/// `_pathKey`: lexical normalization; Windows keys ignore case.
fn path_key(path: &str, source_type: SourceType) -> String {
    let raw = path.trim().replace('\\', "/");
    let absolute = raw.starts_with('/');
    let mut segments: Vec<&str> = Vec::new();
    for segment in raw.split('/') {
        match segment {
            "" | "." => {}
            ".." => {
                if segments.last().is_some_and(|last| *last != "..") {
                    segments.pop();
                } else {
                    segments.push(segment);
                }
            }
            _ => segments.push(segment),
        }
    }
    let normalized = format!("{}{}", if absolute { "/" } else { "" }, segments.join("/"));
    match source_type {
        SourceType::Windows => normalized.to_lowercase(),
        SourceType::Wsl => normalized,
    }
}

fn is_within(path: &str, directory: &str, source_type: SourceType) -> bool {
    let path = path_key(path, source_type);
    let directory = path_key(directory, source_type);
    let directory = directory.trim_end_matches('/');
    path == directory || path.starts_with(&format!("{directory}/"))
}

fn within_state_root(
    paths: &[String],
    roots: &[ScanRoot],
    source_type: SourceType,
    state: &str,
) -> bool {
    roots
        .iter()
        .filter(|root| root.source_type == source_type && root.source_state == state)
        .any(|root| {
            paths
                .iter()
                .any(|path| is_within(path, &root.path, source_type))
        })
}

fn within_any_root(paths: &[String], roots: &[ScanRoot], source_type: SourceType) -> bool {
    roots
        .iter()
        .filter(|root| root.source_type == source_type)
        .any(|root| {
            paths
                .iter()
                .any(|path| is_within(path, &root.path, source_type))
        })
}

fn has_traversal_segment(path: &str) -> bool {
    path.replace('\\', "/")
        .split('/')
        .any(|segment| segment == "." || segment == "..")
}

fn contains_session_namespace(paths: &[String], source_type: SourceType) -> bool {
    paths.iter().any(|path| {
        path.replace('\\', "/")
            .split('/')
            .filter(|segment| !segment.is_empty())
            .map(|segment| match source_type {
                SourceType::Windows => segment.to_lowercase(),
                SourceType::Wsl => segment.to_owned(),
            })
            .any(|segment| segment == "sessions" || segment == "archived_sessions")
    })
}

/// `p.windows.isAbsolute`.
fn is_windows_absolute(path: &str) -> bool {
    let bytes = path.as_bytes();
    path.starts_with(['\\', '/'])
        || (bytes.len() >= 3
            && bytes[0].is_ascii_alphabetic()
            && bytes[1] == b':'
            && matches!(bytes[2], b'\\' | b'/'))
}

/// Every stored alias must resolve to the same physical file.
fn resolve_file_aliases(
    paths: &[String],
    source_type: SourceType,
    resolver: &PhysicalPathResolver,
) -> Option<String> {
    if paths.is_empty() || paths.iter().any(|path| !is_windows_absolute(path)) {
        return None;
    }
    let mut first = None;
    let mut keys = HashSet::new();
    for path in paths {
        if has_traversal_segment(path) {
            return None;
        }
        let resolved = resolver(path, false).ok()?;
        keys.insert(path_key(&resolved, source_type));
        first.get_or_insert(resolved);
    }
    (keys.len() == 1).then(|| first.expect("at least one path"))
}

const KNOWN_NON_SESSION_NAMESPACES: [&str; 6] = [
    ".tmp",
    ".sandbox",
    ".sandbox-secrets",
    "plugins",
    "cache",
    "computer-use",
];

const KNOWN_NON_SESSION_ROOT_FILES: [&str; 7] = [
    ".codex-global-state.json",
    "auth.json",
    "external_agent_session_imports.json",
    "history.jsonl",
    "internal_storage.json",
    "models_cache.json",
    "session_index.jsonl",
];

fn known_non_session_namespace(
    source_path: &str,
    roots: &[ScanRoot],
    source_type: SourceType,
    resolver: &PhysicalPathResolver,
) -> Option<String> {
    for root in roots.iter().filter(|root| root.source_type == source_type) {
        let Some(owner) = root.availability_root_path.as_deref() else {
            continue;
        };
        if owner.trim().is_empty() {
            continue;
        }
        let Ok(physical_owner) = resolver(owner, true) else {
            continue;
        };
        let path = path_key(source_path, source_type);
        let owner = path_key(&physical_owner, source_type);
        let owner = owner.trim_end_matches('/');
        let Some(relative) = path.strip_prefix(&format!("{owner}/")) else {
            continue;
        };
        let segments: Vec<&str> = relative.split('/').filter(|s| !s.is_empty()).collect();
        if segments.is_empty()
            || segments.contains(&"sessions")
            || segments.contains(&"archived_sessions")
        {
            continue;
        }
        if segments.len() == 1 && KNOWN_NON_SESSION_ROOT_FILES.contains(&segments[0]) {
            return Some("<root-file>".to_owned());
        }
        if KNOWN_NON_SESSION_NAMESPACES.contains(&segments[0]) {
            return Some(segments[0].to_owned());
        }
    }
    None
}

/// Resolve links, requiring a regular file (`directory == false`) or a
/// directory or directory link (`directory == true`).
pub fn resolve_physical_path_strict(path: &str, directory: bool) -> Result<String, String> {
    let lexical = std::fs::symlink_metadata(path).map_err(|error| error.to_string())?;
    let kind = lexical.file_type();
    if !directory && !kind.is_file() {
        return Err(format!("{path} is not a regular file"));
    }
    if directory && !kind.is_dir() && !kind.is_symlink() {
        return Err(format!("{path} is not a directory"));
    }
    let resolved = std::fs::canonicalize(path).map_err(|error| error.to_string())?;
    let metadata = std::fs::symlink_metadata(&resolved).map_err(|error| error.to_string())?;
    if metadata.is_dir() != directory || (!directory && !metadata.is_file()) {
        return Err(format!("{path} resolved to an unexpected type"));
    }
    Ok(strip_verbatim_prefix(&resolved.to_string_lossy()))
}

/// `canonicalize` returns `\\?\C:\...` or `\\?\UNC\server\...` on Windows.
fn strip_verbatim_prefix(path: &str) -> String {
    if let Some(rest) = path.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else if let Some(rest) = path.strip_prefix(r"\\?\") {
        rest.to_owned()
    } else {
        path.to_owned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn path_keys_normalize_like_the_viewer() {
        assert_eq!(
            path_key(r"C:\Users\A\.codex\sessions\..\x.json", SourceType::Windows),
            "c:/users/a/.codex/x.json"
        );
        assert_eq!(path_key("/home/A/./x", SourceType::Wsl), "/home/A/x");
        assert_eq!(strip_verbatim_prefix(r"\\?\C:\a"), r"C:\a");
        assert_eq!(strip_verbatim_prefix(r"\\?\UNC\srv\s\a"), r"\\srv\s\a");
        assert!(is_windows_absolute(r"C:\a") && is_windows_absolute(r"\\srv\s"));
        assert!(!is_windows_absolute("relative/path"));
    }
}
