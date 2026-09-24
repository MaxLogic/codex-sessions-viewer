//! Deletes the backups this collector made once they are older than the
//! retention period (`[database] backup_retention_days`, 7 days by default).
//!
//! Only collector-made files are touched: session cache repair v3 copies in
//! the `backups` folder beside the database, and setup configuration backups
//! beside the harness configuration file. The viewer prunes its own backups
//! (`usage-pre16-*` and the legacy v1/v2 repair copies). A file is deleted
//! only when its whole name matches the collector's naming; its age comes
//! from the time in that name. SQLite side files (`-wal`, `-shm`,
//! `-journal`) go with their backup.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension};
use serde::Serialize;

use crate::store::cache_repair;

pub const DEFAULT_RETENTION_DAYS: u32 = 7;
pub const MAX_RETENTION_DAYS: u32 = 3650;

const DAY: Duration = Duration::from_secs(24 * 60 * 60);
const SIDE_SUFFIXES: [&str; 3] = ["-wal", "-shm", "-journal"];

/// The retention period for `days`, at least one day.
pub fn retention(days: u32) -> Duration {
    DAY * days.clamp(1, MAX_RETENTION_DAYS)
}

/// Clamps a configured value: below one day means one day.
pub fn clamp_days(value: i64) -> u32 {
    value.clamp(1, i64::from(MAX_RETENTION_DAYS)) as u32
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct PrunedBackup {
    pub path: String,
    pub bytes: u64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
pub struct PruneOutcome {
    pub deleted: Vec<PrunedBackup>,
    /// Files that could not be deleted, such as a backup still open
    /// elsewhere. They are retried on the next run.
    pub failed: Vec<String>,
}

/// Prunes session cache repair v3 backups once that repair is completed.
/// While it is not, its backups are kept whatever their age (the repair
/// itself discards the copies of a stopped attempt).
pub fn prune_repair_backups(
    conn: &Connection,
    database: &Path,
    retention: Duration,
    now: SystemTime,
) -> PruneOutcome {
    let completed = conn
        .query_row(
            "select 1 from app_metadata where key = ?1
             and not exists(select 1 from app_metadata where key = ?2)",
            [cache_repair::COMPLETION_KEY, cache_repair::ATTEMPT_KEY],
            |_| Ok(()),
        )
        .optional()
        .ok()
        .flatten()
        .is_some();
    if !completed {
        return PruneOutcome::default();
    }
    let directory = cache_repair::backup_directory(database);
    let prefix = cache_repair::backup_prefix(database);
    let marker = format!("repair-{}-", cache_repair::REPAIR_VERSION);
    prune(&directory, retention, now, |name| {
        let rest = name.strip_prefix(&prefix)?.strip_suffix(".sqlite")?;
        let (micros, sequence) = rest.strip_prefix(&marker)?.split_once('-')?;
        if !is_digits(sequence) || !is_digits(micros) {
            return None;
        }
        let micros: u64 = micros.parse().ok()?;
        UNIX_EPOCH.checked_add(Duration::from_micros(micros))
    })
}

/// Prunes `<name>.<YYYYMMDDTHHMMSSZ>[-N].collector-backup` files beside
/// `config`, where `<name>` is that configuration file's name.
pub fn prune_config_backups(config: &Path, retention: Duration, now: SystemTime) -> PruneOutcome {
    let Some(name) = config
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
    else {
        return PruneOutcome::default();
    };
    let directory = config
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let prefix = format!("{name}.");
    prune(directory, retention, now, |file| {
        let rest = file
            .strip_prefix(&prefix)?
            .strip_suffix(".collector-backup")?;
        let stamp = match rest.split_once('-') {
            Some((stamp, counter)) if is_digits(counter) => stamp,
            Some(_) => return None,
            None => rest,
        };
        if stamp.len() != 16 {
            return None;
        }
        let time = chrono::NaiveDateTime::parse_from_str(stamp, "%Y%m%dT%H%M%SZ").ok()?;
        Some(SystemTime::from(time.and_utc()))
    })
}

fn is_digits(text: &str) -> bool {
    !text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit())
}

/// Deletes each backup whose `created` time (from `created_at(name)`, which
/// returns `None` for any other name) is older than `retention`, then its
/// side files. A side file whose backup is gone follows the backup's name.
fn prune(
    directory: &Path,
    retention: Duration,
    now: SystemTime,
    created_at: impl Fn(&str) -> Option<SystemTime>,
) -> PruneOutcome {
    let mut outcome = PruneOutcome::default();
    let Ok(entries) = std::fs::read_dir(directory) else {
        return outcome;
    };
    // Backup name -> (backup present, side files present).
    let mut groups: BTreeMap<String, (bool, Vec<PathBuf>)> = BTreeMap::new();
    for entry in entries.flatten() {
        if !entry.file_type().is_ok_and(|kind| kind.is_file()) {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        let side = SIDE_SUFFIXES
            .iter()
            .find_map(|suffix| name.strip_suffix(suffix));
        match side {
            Some(base) => groups
                .entry(base.to_owned())
                .or_default()
                .1
                .push(entry.path()),
            None => groups.entry(name).or_default().0 = true,
        }
    }
    for (name, (present, sides)) in groups {
        let Some(created) = created_at(&name) else {
            continue;
        };
        let old = now
            .duration_since(created)
            .is_ok_and(|age| age >= retention);
        if !old {
            continue;
        }
        // Side files belong to the backup; keep them while it stays.
        if present && !delete(&directory.join(&name), &mut outcome) {
            continue;
        }
        for side in sides {
            delete(&side, &mut outcome);
        }
    }
    outcome
}

fn delete(path: &Path, outcome: &mut PruneOutcome) -> bool {
    let bytes = std::fs::metadata(path).map_or(0, |meta| meta.len());
    match std::fs::remove_file(path) {
        Ok(()) => {
            outcome.deleted.push(PrunedBackup {
                path: path.display().to_string(),
                bytes,
            });
            true
        }
        Err(_) => {
            outcome.failed.push(path.display().to_string());
            false
        }
    }
}
