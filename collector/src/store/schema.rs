//! Database ownership, schema checks, and standalone schema creation.
//!
//! The viewer owns a viewer database: it creates and migrates it, including
//! data migrations written in Dart. The collector only writes to a viewer
//! database at exactly the schema it was built for, and never while a startup
//! migration is pending. A standalone collector (no viewer on the machine)
//! creates its own database from the same SQL files and records itself as the
//! owner; it then migrates only that database.

use rusqlite::{Connection, OptionalExtension, params};

use super::writer::USAGE_COST_PROJECTION_VERSION;
use crate::claude::parser::CLAUDE_PARSER_VERSION;
use crate::codex::parser::PARSER_VERSION;
use crate::dart::{DartDateTime, sha256_hex};

pub const SUPPORTED_SCHEMA_VERSION: i64 = 25;

pub struct Migration {
    pub version: i64,
    pub filename: &'static str,
    pub sql: &'static str,
}

impl Migration {
    pub fn checksum(&self) -> String {
        sha256_hex(self.sql.as_bytes())
    }
}

macro_rules! migration {
    ($version:expr, $folder:literal, $file:literal) => {
        Migration {
            version: $version,
            filename: $file,
            sql: include_str!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/../sql/",
                $folder,
                "/",
                $file
            )),
        }
    };
}

/// Every schema file, in version order. `tests::migrations_match_sql_folder`
/// fails when a file is added to `sql/` without being listed here.
pub const MIGRATIONS: &[Migration] = &[
    migration!(1, "init", "001_initial_schema.sql"),
    migration!(2, "migration", "002_search_filter_schema.sql"),
    migration!(3, "migration", "003_project_override.sql"),
    migration!(4, "migration", "004_session_token_buckets.sql"),
    migration!(5, "migration", "005_scan_run_status.sql"),
    migration!(6, "migration", "006_session_origin.sql"),
    migration!(7, "migration", "007_session_thread_name.sql"),
    migration!(8, "migration", "008_local_eval_metadata.sql"),
    migration!(9, "migration", "009_message_search.sql"),
    migration!(10, "migration", "010_session_id_lookup_index.sql"),
    migration!(11, "migration", "011_stable_session_identity.sql"),
    migration!(12, "migration", "012_external_content_search.sql"),
    migration!(13, "migration", "013_session_source_state.sql"),
    migration!(14, "migration", "014_session_cache_repair_manifest.sql"),
    migration!(15, "migration", "015_branch_aware_usage.sql"),
    migration!(
        16,
        "migration",
        "016_persisted_usage_pricing_maintenance.sql"
    ),
    migration!(17, "migration", "017_message_delete_foreign_key_index.sql"),
    migration!(
        18,
        "migration",
        "018_collector_identity_and_usage_inputs.sql"
    ),
    migration!(19, "migration", "019_session_history_views.sql"),
    migration!(20, "migration", "020_harness_scoped_session_identity.sql"),
    migration!(21, "migration", "021_session_change_journal.sql"),
    migration!(22, "migration", "022_collector_upload_outbox.sql"),
    migration!(23, "migration", "023_price_history_sync.sql"),
    // 024 is reserved for a migration developed in parallel; list it here
    // when it lands so the versions are contiguous again.
    migration!(25, "migration", "025_session_change_journal_precision.sql"),
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OwnerMode {
    /// Write into the viewer's database; the viewer migrates it.
    Viewer,
    /// Create and migrate a collector-owned database.
    Standalone,
}

pub const OWNER_VIEWER: &str = "viewer";
pub const OWNER_COLLECTOR: &str = "collector";

#[derive(Debug)]
pub enum StoreError {
    Sql(rusqlite::Error),
    Io(std::io::Error),
    /// The database cannot be written safely; the message says what to do.
    Refused(String),
}

impl std::fmt::Display for StoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Sql(rusqlite::Error::SqliteFailure(code, message)) => write!(
                f,
                "SQLite error {} ({:?}): {}",
                code.extended_code,
                code.code,
                message.as_deref().unwrap_or("")
            ),
            Self::Sql(error) => write!(f, "SQLite error: {error}"),
            Self::Io(error) => write!(f, "I/O error: {error}"),
            Self::Refused(message) => f.write_str(message),
        }
    }
}

impl std::error::Error for StoreError {}

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        Self::Sql(error)
    }
}

impl From<std::io::Error> for StoreError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

pub type StoreResult<T> = Result<T, StoreError>;

/// Busy wait before a write gives up. The viewer uses 5 s for interactive
/// work; a background collector can wait longer for a scan batch to finish.
pub const BUSY_TIMEOUT_MS: u64 = 30_000;

pub fn configure(conn: &Connection, busy_timeout_ms: u64) -> StoreResult<()> {
    conn.busy_timeout(std::time::Duration::from_millis(busy_timeout_ms))?;
    conn.pragma_update(None, "foreign_keys", "on")?;
    let foreign_keys: i64 = conn.query_row("pragma foreign_keys", [], |row| row.get(0))?;
    if foreign_keys != 1 {
        return Err(StoreError::Refused(
            "SQLite foreign key enforcement could not be enabled.".to_owned(),
        ));
    }
    let mode: String = conn.query_row("pragma journal_mode = wal", [], |row| row.get(0))?;
    if !mode.eq_ignore_ascii_case("wal") {
        return Err(StoreError::Refused(format!(
            "SQLite did not enable WAL journal mode; active mode is {mode}."
        )));
    }
    Ok(())
}

fn table_exists(conn: &Connection, name: &str) -> StoreResult<bool> {
    Ok(conn
        .query_row(
            "select 1 from sqlite_schema where type = 'table' and name = ?",
            [name],
            |_| Ok(()),
        )
        .optional()?
        .is_some())
}

pub fn last_applied_version(conn: &Connection) -> StoreResult<i64> {
    if !table_exists(conn, "schema_version")? {
        return Ok(0);
    }
    Ok(conn.query_row(
        "select coalesce(max(version), 0) from schema_version where success = 1",
        [],
        |row| row.get(0),
    )?)
}

pub fn metadata(conn: &Connection, key: &str) -> StoreResult<Option<String>> {
    if !table_exists(conn, "app_metadata")? {
        return Ok(None);
    }
    Ok(conn
        .query_row(
            "select value from app_metadata where key = ?",
            [key],
            |row| row.get(0),
        )
        .optional()?)
}

/// The owner records the writer algorithms independently of schema checksums:
/// parser and cost changes need not change the SQL schema.
///
/// Agreement rule: every write needs the owner's cost projection version,
/// because every harness's usage becomes daily cost rows. A session write
/// additionally needs the owner's parser version for that harness when the
/// viewer interprets it (`parser_version_key`): Codex rows are gated only by
/// the Codex parser version and Claude rows only by the Claude parser
/// version. Third-party harnesses carry their own parser versions, which the
/// viewer does not filter on.
pub const PARSER_VERSION_KEY: &str = "writer_codex_parser_version";
pub const CLAUDE_PARSER_VERSION_KEY: &str = "writer_claude_parser_version";
pub const COST_VERSION_KEY: &str = "writer_usage_cost_projection_version";

/// The metadata key and this collector's parser version for `harness`, when
/// the viewer and collector must agree on it.
pub fn parser_version_key(harness: &str) -> Option<(&'static str, i64)> {
    match harness {
        "codex" => Some((PARSER_VERSION_KEY, PARSER_VERSION)),
        "claude" => Some((CLAUDE_PARSER_VERSION_KEY, CLAUDE_PARSER_VERSION)),
        _ => None,
    }
}

fn version_mismatch(conn: &Connection, harness: &str) -> StoreResult<StoreError> {
    let (key, collector_parser) = parser_version_key(harness).unwrap_or(("", 0));
    let parser = if key.is_empty() {
        None
    } else {
        metadata(conn, key)?
    };
    let cost = metadata(conn, COST_VERSION_KEY)?;
    Ok(StoreError::Refused(format!(
        "Writer version mismatch for {harness} sessions: database/viewer parser={}, cost projection={}; collector parser={}, cost projection={}. Install the viewer and collector from the same release, then open the viewer once to record its versions. Standalone databases must use their matching collector release.",
        if key.is_empty() {
            "not checked"
        } else {
            parser.as_deref().unwrap_or("missing")
        },
        cost.as_deref().unwrap_or("missing"),
        if key.is_empty() {
            "not checked".to_owned()
        } else {
            collector_parser.to_string()
        },
        USAGE_COST_PROJECTION_VERSION,
    )))
}

/// Every write: the owner's cost projection version must be this collector's.
fn check_writer_versions(conn: &Connection) -> StoreResult<()> {
    if metadata(conn, COST_VERSION_KEY)?.as_deref()
        != Some(USAGE_COST_PROJECTION_VERSION.to_string().as_str())
    {
        return Err(version_mismatch(conn, "codex")?);
    }
    Ok(())
}

/// Session writes: the owner's parser version for `harness`, if any, must
/// be this collector's. Call inside the write transaction.
pub fn check_parser_version(conn: &Connection, harness: &str) -> StoreResult<()> {
    let Some((key, version)) = parser_version_key(harness) else {
        return Ok(());
    };
    if metadata(conn, key)?.as_deref() != Some(version.to_string().as_str()) {
        return Err(version_mismatch(conn, harness)?);
    }
    Ok(())
}

fn record_writer_versions(conn: &Connection, keys: &[&str]) -> StoreResult<()> {
    let now = DartDateTime::now().to_iso8601();
    for (key, version) in [
        (PARSER_VERSION_KEY, PARSER_VERSION),
        (CLAUDE_PARSER_VERSION_KEY, CLAUDE_PARSER_VERSION),
        (COST_VERSION_KEY, USAGE_COST_PROJECTION_VERSION),
    ] {
        if !keys.contains(&key) {
            continue;
        }
        conn.execute("insert into app_metadata(key,value,updated_at_utc) values (?,?,?) on conflict(key) do update set value=excluded.value, updated_at_utc=excluded.updated_at_utc",
            params![key,version.to_string(),now])?;
    }
    Ok(())
}

const ALL_VERSION_KEYS: [&str; 3] = [
    PARSER_VERSION_KEY,
    CLAUDE_PARSER_VERSION_KEY,
    COST_VERSION_KEY,
];

/// `database_owner`; databases older than schema 18 belong to the viewer.
pub fn database_owner(conn: &Connection) -> StoreResult<String> {
    Ok(metadata(conn, "database_owner")?.unwrap_or_else(|| OWNER_VIEWER.to_owned()))
}

fn validate_applied_checksums(conn: &Connection) -> StoreResult<()> {
    let mut statement =
        conn.prepare("select version, filename, checksum from schema_version where success = 1")?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
        ))
    })?;
    for row in rows {
        let (version, filename, checksum) = row?;
        let Some(migration) = MIGRATIONS.iter().find(|m| m.version == version) else {
            return Err(StoreError::Refused(format!(
                "Database schema version {version} ({filename}) is newer than this collector supports ({SUPPORTED_SCHEMA_VERSION}). Update the collector."
            )));
        };
        if migration.checksum() != checksum {
            return Err(StoreError::Refused(format!(
                "Database migration {filename} does not match this collector's copy. Use a collector from the same release as the viewer."
            )));
        }
    }
    Ok(())
}

/// Refuse while the viewer's startup migration owns the database. Mirrors the
/// read-only guards in `openFileBackedDatabase`.
fn ensure_no_pending_viewer_migration(conn: &Connection) -> StoreResult<()> {
    if metadata(conn, "usage_migration_bootstrap")?.is_some() {
        return Err(StoreError::Refused(
            "The viewer is migrating this database. Open the viewer and let the migration finish, then collect again.".to_owned(),
        ));
    }
    if table_exists(conn, "maintenance_jobs")? {
        let latest: Option<String> = conn
            .query_row(
                "select state from maintenance_jobs where job_type = 'usage_projection_migration' order by id desc limit 1",
                [],
                |row| row.get(0),
            )
            .optional()?;
        if latest.is_some_and(|state| state != "succeeded") {
            return Err(StoreError::Refused(
                "A usage migration of this database has not finished. Open the viewer and let it complete, then collect again.".to_owned(),
            ));
        }
    }
    let target: Option<i64> = conn
        .query_row(
            "select g.target_schema_version from database_state s join database_generations g on g.id = s.active_usage_generation_id where s.id = 1",
            [],
            |row| row.get(0),
        )
        .optional()?;
    if target.is_none_or(|version| version < 16) {
        return Err(StoreError::Refused(
            "The database has no active usage generation for schema 16 or newer. Open the viewer to finish migrating it.".to_owned(),
        ));
    }
    Ok(())
}

/// Check that `conn` is a database this collector may write in `mode`.
pub fn check_writable(conn: &Connection, mode: OwnerMode, path: &str) -> StoreResult<()> {
    let version = last_applied_version(conn)?;
    if version == 0 {
        return Err(StoreError::Refused(match mode {
            OwnerMode::Viewer => format!(
                "{path} is not an initialized viewer database. Start the viewer once to create it, or collect with --standalone into a database of the collector's own."
            ),
            OwnerMode::Standalone => format!("{path} has no schema."),
        }));
    }
    validate_applied_checksums(conn)?;
    let owner = database_owner(conn)?;
    match mode {
        OwnerMode::Viewer if owner != OWNER_VIEWER => {
            return Err(StoreError::Refused(format!(
                "{path} is owned by a standalone collector ({owner}), not by the viewer. Collect with --standalone."
            )));
        }
        OwnerMode::Standalone if owner != OWNER_COLLECTOR => {
            return Err(StoreError::Refused(format!(
                "{path} belongs to the viewer. A standalone collector only writes a database it created; drop --standalone to collect into the viewer's database."
            )));
        }
        _ => {}
    }
    if version < SUPPORTED_SCHEMA_VERSION {
        return Err(StoreError::Refused(format!(
            "{path} is at schema version {version}; this collector writes schema {SUPPORTED_SCHEMA_VERSION}. Open the viewer once to upgrade the database."
        )));
    }
    ensure_no_pending_viewer_migration(conn)?;
    check_writer_versions(conn)
}

const SCHEMA_VERSION_TABLE: &str = "create table if not exists schema_version (
    version integer primary key,
    filename text not null,
    checksum text not null,
    applied_at_utc text not null,
    success integer not null check (success in (0, 1)),
    error_message text
)";

/// Create a collector-owned database, or migrate one the collector owns.
/// Uses the viewer migrator's steps so the result is an ordinary database.
pub fn prepare_standalone(conn: &Connection, path: &str) -> StoreResult<()> {
    if last_applied_version(conn)? == 0 {
        return create_standalone(conn, path, MIGRATIONS);
    }
    validate_applied_checksums(conn)?;
    let owner = database_owner(conn)?;
    if owner != OWNER_COLLECTOR {
        return Err(StoreError::Refused(format!(
            "{path} belongs to the viewer. A standalone collector only writes a database it created; drop --standalone to collect into the viewer's database."
        )));
    }
    // Only the standalone owner may adopt a legacy database without the pair.
    // Never overwrite a recorded mismatch or a partially damaged pair.
    conn.execute_batch("begin immediate")?;
    let agreement = (|| -> StoreResult<()> {
        if metadata(conn, PARSER_VERSION_KEY)?.is_none()
            && metadata(conn, COST_VERSION_KEY)?.is_none()
        {
            record_writer_versions(conn, &ALL_VERSION_KEYS)?;
        } else if metadata(conn, CLAUDE_PARSER_VERSION_KEY)?.is_none() {
            // Databases from before the Claude key existed.
            record_writer_versions(conn, &[CLAUDE_PARSER_VERSION_KEY])?;
        }
        check_writer_versions(conn)?;
        check_parser_version(conn, "codex")
    })();
    finish(conn, agreement)?;
    for migration in MIGRATIONS {
        let applied: bool = conn
            .query_row(
                "select 1 from schema_version where version = ? and success = 1",
                [migration.version],
                |_| Ok(()),
            )
            .optional()?
            .is_some();
        if !applied {
            conn.execute_batch("begin immediate")?;
            let result = apply_migration_in_transaction(conn, migration);
            finish(conn, result)?;
        }
    }
    Ok(())
}

/// A new standalone database in one transaction: schema, the viewer's empty
/// usage generation, and the collector as owner commit together, so a crash
/// leaves either nothing or a complete collector-owned database.
fn create_standalone(conn: &Connection, path: &str, migrations: &[Migration]) -> StoreResult<()> {
    let has_tables: i64 = conn.query_row(
        "select count(*) from sqlite_schema where type = 'table' and name not like 'sqlite_%'",
        [],
        |row| row.get(0),
    )?;
    if has_tables > 0 {
        return Err(StoreError::Refused(format!(
            "{path} already contains tables but no schema history; refusing to initialize it."
        )));
    }
    conn.execute_batch("begin immediate")?;
    let result = (|| -> StoreResult<()> {
        conn.execute_batch(SCHEMA_VERSION_TABLE)?;
        for migration in migrations {
            apply_migration_in_transaction(conn, migration)?;
        }
        let now = DartDateTime::now().to_iso8601();
        activate_empty_usage_generation(conn, &now)?;
        record_writer_versions(conn, &ALL_VERSION_KEYS)?;
        conn.execute(
            "insert into app_metadata (key, value, updated_at_utc) values ('database_owner', ?, ?)
             on conflict(key) do update set value = excluded.value, updated_at_utc = excluded.updated_at_utc",
            params![OWNER_COLLECTOR, now],
        )?;
        conn.execute(
            "update database_state set last_optimized_schema_version = ?, updated_at_utc = ? where id = 1",
            params![SUPPORTED_SCHEMA_VERSION, now],
        )?;
        conn.execute(
            "insert into app_metadata (key, value, updated_at_utc) values ('sqlite_version', ?, ?)
             on conflict(key) do update set value = excluded.value, updated_at_utc = excluded.updated_at_utc",
            params![rusqlite::version(), now],
        )?;
        Ok(())
    })();
    finish(conn, result)
}

/// The end state of the viewer's usage migration for a database with no
/// usage yet: a validated schema-16 generation is active, the shadow event
/// table has replaced the legacy one, and normal writes have resumed.
fn activate_empty_usage_generation(conn: &Connection, now: &str) -> StoreResult<()> {
    let legacy_events: i64 =
        conn.query_row("select count(*) from usage_events", [], |row| row.get(0))?;
    if legacy_events > 0 {
        return Err(StoreError::Refused(
            "A new standalone database unexpectedly contains usage events.".to_owned(),
        ));
    }
    conn.execute(
        "insert into database_generations (source_schema_version, target_schema_version,
           source_fingerprint, state, created_at_utc, activated_at_utc, completed_at_utc,
           validation_report_json)
         values (15, 16, 'collector-standalone-empty', 'complete', ?, ?, ?, ?)",
        params![
            now,
            now,
            now,
            serde_json::json!({
                "context_parity": {"event_count": 0},
                "cost_projection_version": USAGE_COST_PROJECTION_VERSION,
            })
            .to_string()
        ],
    )?;
    let generation = conn.last_insert_rowid();
    conn.execute_batch(
        "drop view billable_usage_events;
         alter table usage_events rename to usage_events_legacy;
         alter table usage_events_next rename to usage_events;
         create view billable_usage_events as
           select e.*, c.effective_project_id as project_id
           from usage_events e join usage_path_contexts c on c.id = e.path_context_id
           where e.branch_scope = 'local';
         drop table usage_events_legacy;",
    )?;
    conn.execute(
        "update database_generations set state = 'complete', completed_at_utc = ?
         where id <> ? and state in ('legacy', 'active', 'cleanup_pending')",
        params![now, generation],
    )?;
    conn.execute(
        "update database_state set active_usage_generation_id = ?,
           normal_writes_resumed_at_utc = coalesce(normal_writes_resumed_at_utc, ?), updated_at_utc = ?
         where id = 1",
        params![generation, now, now],
    )?;
    // The viewer treats a succeeded migration job as "no startup migration".
    conn.execute(
        "insert into maintenance_jobs (job_type, database_generation_id, state, phase,
           status_message, started_at_utc, updated_at_utc, finished_at_utc, created_at_utc)
         values ('usage_projection_migration', ?, 'succeeded', 'cleanup_complete',
           'Created empty by a standalone collector.', ?, ?, ?, ?)",
        params![generation, now, now, now, now],
    )?;
    Ok(())
}

fn apply_migration_in_transaction(conn: &Connection, migration: &Migration) -> StoreResult<()> {
    conn.execute_batch("pragma defer_foreign_keys = on")?;
    conn.execute_batch(migration.sql)?;
    conn.execute(
        "insert into schema_version (version, filename, checksum, applied_at_utc, success, error_message)
         values (?, ?, ?, ?, 1, null)
         on conflict(version) do update set
           filename = excluded.filename, checksum = excluded.checksum,
           applied_at_utc = excluded.applied_at_utc, success = 1, error_message = null
         where schema_version.success = 0",
        params![
            migration.version,
            migration.filename,
            migration.checksum(),
            DartDateTime::now().to_iso8601()
        ],
    )?;
    Ok(())
}

/// Start a write and re-check, under the write lock, that the database is
/// still at this collector's schema with no viewer migration pending. The
/// check at open is not enough: a newer viewer can migrate the database
/// between two batches of a long scan.
pub fn begin_write(conn: &Connection) -> StoreResult<()> {
    conn.execute_batch("begin immediate")?;
    let check = (|| -> StoreResult<()> {
        let version = last_applied_version(conn)?;
        if version != SUPPORTED_SCHEMA_VERSION {
            return Err(StoreError::Refused(format!(
                "The database moved to schema version {version} while collecting; this collector writes schema {SUPPORTED_SCHEMA_VERSION}. Use a collector from the same release as the viewer."
            )));
        }
        ensure_no_pending_viewer_migration(conn)?;
        check_writer_versions(conn)
    })();
    if let Err(error) = check {
        let _ = conn.execute_batch("rollback");
        return Err(error);
    }
    Ok(())
}

/// Commit on success, roll back on failure, keeping the first error.
pub fn finish<T>(conn: &Connection, result: StoreResult<T>) -> StoreResult<T> {
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn migrations_match_sql_folder() {
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../sql");
        let mut files: Vec<String> = ["init", "migration"]
            .iter()
            .flat_map(|folder| {
                std::fs::read_dir(format!("{root}/{folder}"))
                    .unwrap()
                    .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
                    .filter(|name| name.ends_with(".sql"))
                    .collect::<Vec<_>>()
            })
            .collect();
        files.sort();
        let listed: Vec<String> = MIGRATIONS.iter().map(|m| m.filename.to_owned()).collect();
        assert_eq!(listed, files);
        assert_eq!(MIGRATIONS.last().unwrap().version, SUPPORTED_SCHEMA_VERSION);
        // Versions strictly increase from 1; 024 is reserved (see MIGRATIONS).
        assert_eq!(MIGRATIONS[0].version, 1);
        for pair in MIGRATIONS.windows(2) {
            assert!(pair[0].version < pair[1].version);
        }
        for migration in MIGRATIONS {
            assert!(
                migration
                    .filename
                    .starts_with(&format!("{:03}_", migration.version)),
                "{} is not version {}",
                migration.filename,
                migration.version
            );
        }
    }

    #[test]
    fn standalone_database_is_created_and_owned_by_the_collector() {
        let conn = Connection::open_in_memory().unwrap();
        prepare_standalone(&conn, ":memory:").unwrap();
        assert_eq!(
            last_applied_version(&conn).unwrap(),
            SUPPORTED_SCHEMA_VERSION
        );
        assert_eq!(database_owner(&conn).unwrap(), OWNER_COLLECTOR);
        assert!(
            metadata(&conn, "machine_id")
                .unwrap()
                .is_some_and(|id| id.len() == 32)
        );
        check_writable(&conn, OwnerMode::Standalone, ":memory:").unwrap();
        assert!(matches!(
            check_writable(&conn, OwnerMode::Viewer, ":memory:"),
            Err(StoreError::Refused(_))
        ));
        // Idempotent for a database the collector owns.
        prepare_standalone(&conn, ":memory:").unwrap();
    }

    #[test]
    fn a_failed_standalone_bootstrap_leaves_no_partial_database() {
        const BROKEN: &[Migration] = &[
            migration!(1, "init", "001_initial_schema.sql"),
            Migration {
                version: 2,
                filename: "002_broken.sql",
                sql: "create table broken (; ",
            },
        ];
        let conn = Connection::open_in_memory().unwrap();
        assert!(create_standalone(&conn, ":memory:", BROKEN).is_err());
        let tables: i64 = conn
            .query_row("select count(*) from sqlite_schema", [], |row| row.get(0))
            .unwrap();
        assert_eq!(tables, 0);
        prepare_standalone(&conn, ":memory:").unwrap();
        assert_eq!(database_owner(&conn).unwrap(), OWNER_COLLECTOR);
        let job: String = conn
            .query_row(
                "select state from maintenance_jobs where job_type = 'usage_projection_migration'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(job, "succeeded");
    }
}
