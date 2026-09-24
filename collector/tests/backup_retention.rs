//! Retention of the backups the collector makes: session cache repair v3
//! copies beside the database and setup configuration backups.
mod support;

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use codex_sessions_collector::backup_retention::{
    self, prune_config_backups, prune_repair_backups, retention,
};
use codex_sessions_collector::settings::CollectorSettings;
use rusqlite::Connection;
use serde_json::Value;
use support::TempDir;

const DAY: Duration = Duration::from_secs(24 * 60 * 60);

fn micros(time: SystemTime) -> u128 {
    time.duration_since(UNIX_EPOCH).unwrap().as_micros()
}

fn write(path: &Path, bytes: usize) -> PathBuf {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, vec![b'x'; bytes]).unwrap();
    path.to_path_buf()
}

struct RepairFixture {
    temp: TempDir,
    db: PathBuf,
    conn: Connection,
}

impl RepairFixture {
    fn new(label: &str, completed: bool) -> Self {
        let temp = TempDir::new(label);
        let db = support::viewer_database(&temp);
        let conn = Connection::open(&db).unwrap();
        if completed {
            conn.execute(
                "insert into app_metadata (key, value, updated_at_utc)
                 values ('session_cache_repair.v3.completed', 'repair-3-1-1', '2026-07-01T00:00:00.000Z')",
                [],
            )
            .unwrap();
        } else {
            conn.execute(
                "insert into app_metadata (key, value, updated_at_utc)
                 values ('session_cache_repair.v3.attempt', '{}', '2026-07-01T00:00:00.000Z')",
                [],
            )
            .unwrap();
        }
        Self { temp, db, conn }
    }

    fn stem(&self) -> String {
        self.db.file_stem().unwrap().to_string_lossy().into_owned()
    }

    fn backups(&self) -> PathBuf {
        self.temp.path().join("backups")
    }

    fn repair_backup(&self, created: SystemTime, sequence: u32) -> PathBuf {
        write(
            &self.backups().join(format!(
                "{}.pre-session-cache-repair-v3.repair-3-{}-{sequence}.sqlite",
                self.stem(),
                micros(created)
            )),
            10,
        )
    }
}

#[test]
fn completed_repair_backups_older_than_the_retention_are_deleted_with_their_side_files() {
    let now = SystemTime::now();
    let f = RepairFixture::new("retention-repair", true);
    let old = f.repair_backup(now - 30 * DAY, 1);
    let old_wal = write(&PathBuf::from(format!("{}-wal", old.display())), 3);
    let old_shm = write(&PathBuf::from(format!("{}-shm", old.display())), 4);
    // A side file whose backup is already gone is removed by the name's age.
    let orphan_journal = write(
        &PathBuf::from(format!(
            "{}-journal",
            f.backups()
                .join(format!(
                    "{}.pre-session-cache-repair-v3.repair-3-{}-2.sqlite",
                    f.stem(),
                    micros(now - 40 * DAY)
                ))
                .display()
        )),
        5,
    );
    let recent = f.repair_backup(now - DAY, 3);
    // Viewer-owned backups and unrelated files are never the collector's.
    let untouched = [
        write(
            &f.backups()
                .join("usage-pre16-4e98c339d45e13339601941b7b6c5c69.sqlite"),
            1,
        ),
        write(
            &f.backups().join(format!(
                "{}.pre-session-cache-repair-v1.repair-1-1785183310547358-1.sqlite",
                f.stem()
            )),
            1,
        ),
        write(
            &f.backups().join(format!(
                "{}.pre-session-cache-repair-v3.repair-3-{}-1.sqlite.partial",
                f.stem(),
                micros(now - 30 * DAY)
            )),
            1,
        ),
        write(
            &f.backups().join(format!(
                "other.pre-session-cache-repair-v3.repair-3-{}-1.sqlite",
                micros(now - 30 * DAY)
            )),
            1,
        ),
        write(&f.backups().join("notes.txt"), 1),
        // Outside the backup folder, even with the backup name.
        write(
            &f.temp.path().join(format!(
                "{}.pre-session-cache-repair-v3.repair-3-{}-9.sqlite",
                f.stem(),
                micros(now - 30 * DAY)
            )),
            1,
        ),
    ];

    let outcome = prune_repair_backups(&f.conn, &f.db, retention(7), now);

    for deleted in [&old, &old_wal, &old_shm, &orphan_journal] {
        assert!(!deleted.exists(), "{} is deleted", deleted.display());
    }
    assert!(recent.exists(), "a recent backup is kept");
    for kept in &untouched {
        assert!(kept.exists(), "{} is untouched", kept.display());
    }
    let mut reported: Vec<(String, u64)> = outcome
        .deleted
        .iter()
        .map(|entry| (entry.path.clone(), entry.bytes))
        .collect();
    reported.sort();
    let mut expected = vec![
        (old.display().to_string(), 10),
        (old_wal.display().to_string(), 3),
        (old_shm.display().to_string(), 4),
        (orphan_journal.display().to_string(), 5),
    ];
    expected.sort();
    assert_eq!(reported, expected);
    assert!(outcome.failed.is_empty());
}

#[test]
fn backups_of_a_repair_that_is_not_completed_are_kept_whatever_their_age() {
    let now = SystemTime::now();
    let f = RepairFixture::new("retention-repair-open", false);
    let old = f.repair_backup(now - 300 * DAY, 1);

    let outcome = prune_repair_backups(&f.conn, &f.db, retention(1), now);

    assert!(old.exists());
    assert!(outcome.deleted.is_empty());
}

#[test]
fn the_retention_period_is_configurable_with_a_one_day_minimum() {
    let now = SystemTime::now();
    let f = RepairFixture::new("retention-repair-days", true);
    let three_days = f.repair_backup(now - 3 * DAY, 1);
    let half_day = f.repair_backup(now - DAY / 2, 2);

    prune_repair_backups(&f.conn, &f.db, retention(7), now);
    assert!(three_days.exists(), "kept under a 7-day retention");

    prune_repair_backups(&f.conn, &f.db, retention(2), now);
    assert!(!three_days.exists(), "deleted under a 2-day retention");

    prune_repair_backups(&f.conn, &f.db, retention(0), now);
    assert!(half_day.exists(), "a retention below one day means one day");

    let parse = |text: &str| {
        CollectorSettings::parse(text)
            .unwrap()
            .backup_retention_days
    };
    assert_eq!(parse(""), backup_retention::DEFAULT_RETENTION_DAYS);
    assert_eq!(backup_retention::DEFAULT_RETENTION_DAYS, 7);
    assert_eq!(parse("[database]\nbackup_retention_days = 3\n"), 3);
    assert_eq!(parse("[database]\nbackup_retention_days = 0\n"), 1);
    assert_eq!(parse("[database]\nbackup_retention_days = -5\n"), 1);
    assert_eq!(parse("[database]\nbackup_retention_days = 99999\n"), 3650);
}

#[test]
fn old_setup_configuration_backups_are_deleted_by_their_own_naming_only() {
    let now = SystemTime::now();
    let temp = TempDir::new("retention-config");
    let config = write(&temp.path().join("config.toml"), 1);
    let stamp = |time: SystemTime| {
        chrono::DateTime::<chrono::Utc>::from(time)
            .format("%Y%m%dT%H%M%SZ")
            .to_string()
    };
    let old = write(
        &temp.path().join(format!(
            "config.toml.{}.collector-backup",
            stamp(now - 30 * DAY)
        )),
        6,
    );
    let old_counter = write(
        &temp.path().join(format!(
            "config.toml.{}-2.collector-backup",
            stamp(now - 30 * DAY)
        )),
        7,
    );
    let recent = write(
        &temp
            .path()
            .join(format!("config.toml.{}.collector-backup", stamp(now - DAY))),
        1,
    );
    let untouched = [
        write(
            &temp.path().join(format!(
                "settings.json.{}.collector-backup",
                stamp(now - 30 * DAY)
            )),
            1,
        ),
        write(
            &temp
                .path()
                .join("config.toml.20260101T00000Z.collector-backup"),
            1,
        ),
        write(&temp.path().join("config.toml.bak"), 1),
        write(
            &temp.path().join(format!(
                "config.toml.{}.collector-backup.txt",
                stamp(now - 30 * DAY)
            )),
            1,
        ),
    ];

    let outcome = prune_config_backups(&config, retention(7), now);

    assert!(!old.exists() && !old_counter.exists());
    assert!(recent.exists() && config.exists());
    for kept in &untouched {
        assert!(kept.exists(), "{} is untouched", kept.display());
    }
    let mut bytes: Vec<u64> = outcome.deleted.iter().map(|entry| entry.bytes).collect();
    bytes.sort();
    assert_eq!(bytes, [6, 7]);
}

#[test]
fn setup_apply_prunes_old_configuration_backups() {
    let temp = TempDir::new("retention-setup");
    let root = temp.path().join("sessions");
    std::fs::create_dir(&root).unwrap();
    let config = write(&temp.path().join("config.toml"), 0);
    std::fs::write(&config, "model = \"x\"\n").unwrap();
    let old = write(
        &temp
            .path()
            .join("config.toml.20200101T000000Z.collector-backup"),
        2,
    );
    let db = support::viewer_database(&temp);

    let out = support::collector()
        .args(["codex", "setup", "--apply", "--json", "--root"])
        .arg(&root)
        .arg("--config")
        .arg(&config)
        .arg("--db")
        .arg(&db)
        .output()
        .unwrap();

    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
    assert!(!old.exists(), "an old configuration backup is deleted");
    let report: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(
        report["pruned_backups"][0]["path"],
        old.display().to_string()
    );
    assert_eq!(report["pruned_backups"][0]["bytes"], 2);
    let fresh = report["backup"].as_str().expect("setup made a new backup");
    assert!(Path::new(fresh).exists(), "the new backup is kept");
}

#[test]
fn a_scan_prunes_old_backups_of_the_completed_repair_by_the_configured_retention() {
    let now = SystemTime::now();
    let f = RepairFixture::new("retention-scan", true);
    let four_days = f.repair_backup(now - 4 * DAY, 1);
    let home = support::codex_home(&f.temp, &[]);
    let settings = f.temp.path().join("settings.toml");
    std::fs::write(&settings, "[database]\nbackup_retention_days = 5\n").unwrap();
    drop(f.conn);

    let scan = |extra: &[&str]| -> Value {
        let out = support::scan(&f.db, &home, extra);
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice(&out.stdout).unwrap()
    };
    let settings_arg = settings.display().to_string();
    let report = scan(&["--json", "--settings", &settings_arg]);
    assert!(four_days.exists(), "kept under a 5-day retention");
    assert_eq!(report["cache_repair"]["status"], "already_completed");

    std::fs::write(&settings, "[database]\nbackup_retention_days = 3\n").unwrap();
    let report = scan(&["--json", "--settings", &settings_arg]);
    assert!(!four_days.exists(), "deleted under a 3-day retention");
    assert_eq!(
        report["cache_repair"]["pruned_backups"][0]["path"],
        four_days.display().to_string()
    );
}
