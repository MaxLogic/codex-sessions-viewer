//! Process-wide SQLite configuration shared by binaries and library callers.

#[cfg(windows)]
const STATEMENT_JOURNAL_SPILL_BYTES: i32 = 1024 * 1024;

/// Configure SQLite before any connection is opened.
///
/// Call this before using raw rusqlite in a process that also uses the collector.
/// An earlier SQLite initialization is reported on every call, without retrying
/// process-wide configuration or poisoning the initialization Once.
pub fn ensure() -> rusqlite::Result<()> {
    static CONFIGURED: std::sync::Once = std::sync::Once::new();
    static RESULT: std::sync::OnceLock<Result<(), (i32, &str)>> = std::sync::OnceLock::new();
    CONFIGURED.call_once(|| {
        // SAFETY: participating collector/fixture entry points call this Once
        // before rusqlite can initialize SQLite. An uncoordinated raw caller is
        // detected by SQLITE_MISUSE; never shut SQLite down to retry configuration.
        let code =
            unsafe { rusqlite::ffi::sqlite3_config(rusqlite::ffi::SQLITE_CONFIG_MEMSTATUS, 0_i32) };
        let result = if code != rusqlite::ffi::SQLITE_OK {
            Err((code, "SQLITE_CONFIG_MEMSTATUS"))
        } else {
            // Windows can keep statement rollback journals in memory up to this
            // bounded threshold without changing durable WAL/fsync. Leave other
            // platforms at SQLite's default: SQLite 3.54.1's Unix seekAndWriteFd
            // masks large write lengths, turning a 1 MiB spill into false SQLITE_FULL.
            // CXV-215 deployment evidence: nas-hub-e7ba905/diag/RESULT.md.
            // SAFETY: this int-valued option is set under the same process-wide
            // Once, before SQLite initialization or any connection can be opened.
            #[cfg(windows)]
            let code = unsafe {
                rusqlite::ffi::sqlite3_config(
                    rusqlite::ffi::SQLITE_CONFIG_STMTJRNL_SPILL,
                    STATEMENT_JOURNAL_SPILL_BYTES,
                )
            };
            #[cfg(not(windows))]
            let code = rusqlite::ffi::SQLITE_OK;
            if code != rusqlite::ffi::SQLITE_OK {
                Err((code, "SQLITE_CONFIG_STMTJRNL_SPILL"))
            } else {
                // SAFETY: configuration is complete, still under the same Once.
                // Keep rusqlite's normal threading checks after this initialization.
                let code = unsafe { rusqlite::ffi::sqlite3_initialize() };
                if code == rusqlite::ffi::SQLITE_OK {
                    Ok(())
                } else {
                    Err((code, "sqlite3_initialize"))
                }
            }
        };
        RESULT
            .set(result)
            .expect("SQLite initialization result is set once");
    });
    match *RESULT.get().expect("SQLite initialization Once completed") {
        Ok(()) => Ok(()),
        Err((code, operation)) => Err(rusqlite::Error::SqliteFailure(
            rusqlite::ffi::Error::new(code),
            Some(format!(
                "{operation} failed ({code}); SQLite may have been initialized before store::connection::ensure; call the seam before any raw rusqlite use"
            )),
        )),
    }
}

#[cfg(test)]
mod tests {
    use rusqlite::Connection;

    #[test]
    fn resident_sqlite_accounting_is_off_with_live_parallel_allocations() {
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(8));
        std::thread::scope(|scope| {
            for _ in 0..8 {
                let barrier = barrier.clone();
                scope.spawn(move || {
                    crate::store::connection::ensure().unwrap();
                    let conn = Connection::open_in_memory().unwrap();
                    conn.execute_batch("create table payload(value blob); insert into payload values(randomblob(1048576))").unwrap();
                    barrier.wait();
                    assert_eq!(conn.query_row("select length(value) from payload", [], |r| r.get::<_, i64>(0)).unwrap(), 1048576);
                    // SAFETY: SQLite's memory counter is safe to read with live connections.
                    assert_eq!(unsafe { rusqlite::ffi::sqlite3_memory_used() }, 0);
                });
            }
        });
    }

    #[test]
    fn resident_sqlite_late_initialization_is_reported() {
        const MARKER: &str = "CXV_SQLITE_LATE_INIT_PROBE";
        if std::env::var_os(MARKER).is_some() {
            // SAFETY: a fresh isolated process, before any other SQLite caller.
            assert_eq!(
                unsafe { rusqlite::ffi::sqlite3_initialize() },
                rusqlite::ffi::SQLITE_OK
            );
            let opened = std::panic::catch_unwind(|| {
                crate::store::Store::open(
                    std::path::Path::new(":memory:"),
                    crate::store::OwnerMode::Standalone,
                )
            });
            assert!(
                opened.is_ok(),
                "late initialization must return an error, not panic"
            );
            let error = opened
                .unwrap()
                .err()
                .expect("late initialization must be reported");
            assert!(
                error
                    .to_string()
                    .contains("SQLITE_CONFIG_MEMSTATUS failed (21)")
            );
            println!("{error}");
            // Repeated opens must return the same clear failure, not a poisoned Once.
            assert!(
                crate::store::Store::open(
                    std::path::Path::new(":memory:"),
                    crate::store::OwnerMode::Standalone,
                )
                .is_err()
            );
            return;
        }
        let mut command = std::process::Command::new(std::env::current_exe().unwrap());
        command
            .args([
                "--exact",
                "store::connection::tests::resident_sqlite_late_initialization_is_reported",
                "--nocapture",
            ])
            .env(MARKER, "1");
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000);
        }
        let output = command.output().unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            String::from_utf8_lossy(&output.stdout).contains("SQLITE_CONFIG_MEMSTATUS failed (21)")
        );
    }

    #[test]
    fn resident_sqlite_open_sites_require_configuration() {
        fn scan(path: &std::path::Path) {
            for entry in std::fs::read_dir(path).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    scan(&path);
                } else if path.extension().is_some_and(|ext| ext == "rs") {
                    let source = std::fs::read_to_string(&path).unwrap();
                    let lines: Vec<_> = source.lines().collect();
                    let needle = ["Connection", "::open"].concat();
                    for (index, line) in lines.iter().enumerate() {
                        if line.contains(&needle) {
                            let prefix = lines[..index].join("\n");
                            let configured =
                                prefix.rsplit_once(';').is_some_and(|(before, after)| {
                                    before.rsplit(';').next().is_some_and(|statement| {
                                        statement.contains("connection::ensure()")
                                    }) && !after.contains(['{', '}'])
                                });
                            assert!(
                                configured,
                                "{}:{}: call connection::ensure immediately before opening SQLite",
                                path.display(),
                                index + 1
                            );
                        }
                    }
                }
            }
        }
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        scan(&root.join("src"));
        scan(&root.join("tests"));
        let main = std::fs::read_to_string(root.join("src/main.rs")).unwrap();
        let first_statement = main
            .lines()
            .skip(1)
            .find(|line| !line.trim().is_empty())
            .unwrap()
            .trim();
        assert_eq!(
            first_statement,
            "if let Err(error) = codex_sessions_collector::store::connection::ensure() {",
            "the shipped binary must configure SQLite before argument parsing or dispatch"
        );
    }
    /// Enough changed pages to force a journal larger than the Unix VFS's
    /// 128 KiB write boundary. The failure must roll back only this statement.
    #[test]
    fn large_statement_journal_reports_check_constraint_and_preserves_transaction() {
        let dir = std::env::var_os("CXV_TEST_SANDBOX_PARENT")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(format!("cxv-stmt-large-{}.sqlite", std::process::id()));
        drop(std::fs::File::create_new(&path).unwrap());
        crate::store::connection::ensure().unwrap();
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "pragma page_size=4096;
             pragma journal_mode=wal;
             pragma temp_store=file;
             create table audit(value text);
             create table payload(id integer primary key, flag integer check(flag<>9), data blob);",
        )
        .unwrap();
        let rows = 768_i64;
        conn.execute(
            "with recursive n(i) as (values(1) union all select i+1 from n where i<?)
             insert into payload select i,0,zeroblob(2000) from n",
            [rows],
        )
        .unwrap();
        let pages: i64 = conn
            .query_row("pragma page_count", [], |r| r.get(0))
            .unwrap();
        assert!(
            pages * 4096 > 1024 * 1024,
            "fixture exceeds the 128 KiB journal boundary"
        );
        conn.execute_batch("begin immediate; insert into audit values('before');")
            .unwrap();
        let error = conn
            .execute(
                "update payload set flag=case when id=? then 9 else 1 end",
                [rows],
            )
            .unwrap_err();
        assert_eq!(
            error.sqlite_error_code(),
            Some(rusqlite::ErrorCode::ConstraintViolation),
            "large statement journal must not turn CHECK into FULL: {error}"
        );
        let rusqlite::Error::SqliteFailure(code, _) = error else {
            panic!("expected SQLite CHECK constraint");
        };
        assert_eq!(code.extended_code, rusqlite::ffi::SQLITE_CONSTRAINT_CHECK);
        assert!(!conn.is_autocommit(), "the transaction must remain open");
        assert_eq!(
            conn.query_row("select count(*) from payload where flag<>0", [], |r| r
                .get::<_, i64>(0))
                .unwrap(),
            0
        );
        conn.execute_batch("insert into audit values('after'); commit;")
            .unwrap();
        assert_eq!(
            conn.query_row("select group_concat(value, ',') from audit", [], |r| r
                .get::<_, String>(
                0
            ))
            .unwrap(),
            "before,after"
        );
        assert_eq!(
            conn.query_row("select count(*) from payload", [], |r| r.get::<_, i64>(0))
                .unwrap(),
            rows
        );
        println!("large journal CHECK rollback: rows={rows} pages={pages}");
        drop(conn);
        std::fs::remove_file(path).unwrap();
    }

    #[cfg(windows)]
    use std::sync::atomic::{AtomicPtr, AtomicUsize, Ordering};

    #[cfg(windows)]
    use rusqlite::ffi;

    #[cfg(windows)]
    static ORIGINAL_VFS: AtomicPtr<ffi::sqlite3_vfs> = AtomicPtr::new(std::ptr::null_mut());
    #[cfg(windows)]
    static JOURNAL_OPENS: AtomicUsize = AtomicUsize::new(0);

    // Only the isolated child installs this observer. SQLite provides all callback
    // arguments; file layout and every operation still belong to the native VFS.
    #[cfg(windows)]
    unsafe extern "C" fn observe_open(
        _: *mut ffi::sqlite3_vfs,
        name: *const std::ffi::c_char,
        file: *mut ffi::sqlite3_file,
        flags: i32,
        out_flags: *mut i32,
    ) -> i32 {
        let original = ORIGINAL_VFS.load(Ordering::Acquire);
        // SAFETY: the built-in VFS remains registered for this child's lifetime.
        let Some(open) = (unsafe { original.as_ref() }).and_then(|vfs| vfs.xOpen) else {
            return ffi::SQLITE_CANTOPEN;
        };
        // SAFETY: forward SQLite's unmodified arguments to their original VFS.
        let result = unsafe { open(original, name, file, flags, out_flags) };
        if result == ffi::SQLITE_OK && flags & ffi::SQLITE_OPEN_SUBJOURNAL != 0 {
            JOURNAL_OPENS.fetch_add(1, Ordering::Relaxed);
        }
        result
    }

    #[cfg(windows)]
    #[test]
    fn sqlite_statement_journal_spill_preserves_statement_rollback() {
        const MARKER: &str = "CXV_SQLITE_JOURNAL_PROBE";
        if std::env::var_os(MARKER).is_none() {
            let mut command = std::process::Command::new(std::env::current_exe().unwrap());
            command
                .args([
                    "--exact",
                    "store::connection::tests::sqlite_statement_journal_spill_preserves_statement_rollback",
                    "--nocapture",
                ])
                .env(MARKER, "1");
            #[cfg(windows)]
            {
                use std::os::windows::process::CommandExt;
                command.creation_flags(0x08000000);
            }
            let output = command.output().unwrap();
            assert!(
                output.status.success(),
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
            print!("{}", String::from_utf8_lossy(&output.stdout));
            return;
        }

        crate::store::connection::ensure().unwrap();
        // SAFETY: SQLite is initialized; its default VFS is a live C struct without
        // Rust-owned fields. The observer changes only xOpen and the static name.
        // Leak this small registration in the isolated process so even a failed
        // assertion cannot leave SQLite with a dangling VFS pointer.
        let observer = unsafe {
            let original = ffi::sqlite3_vfs_find(std::ptr::null());
            assert!(!original.is_null());
            ORIGINAL_VFS.store(original, Ordering::Release);
            let mut observer = Box::new(std::ptr::read(original));
            observer.zName = c"statement-journal-observer".as_ptr();
            observer.xOpen = Some(observe_open);
            Box::leak(observer)
        };
        // SAFETY: the registration and its name outlive every connection in this
        // single-test child. All other methods retain the native implementation.
        assert_eq!(unsafe { ffi::sqlite3_vfs_register(observer, 1) }, 0);
        let dir = std::env::var_os("CXV_TEST_SANDBOX_PARENT")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        std::fs::create_dir_all(&dir).unwrap();
        for (rows, should_spill) in [(384_i64, false), (768, true)] {
            let path = dir.join(format!("cxv-stmt-{}-{rows}.sqlite", std::process::id()));
            // Exclusive creation establishes ownership before SQLite opens the file.
            drop(std::fs::File::create_new(&path).unwrap());
            crate::store::connection::ensure().unwrap();
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(
                "pragma page_size=4096;
                 pragma journal_mode=wal;
                 pragma temp_store=file;
                 create table audit(value text);
                 create table payload(id integer primary key, flag integer check(flag<>9), data blob);",
            )
            .unwrap();
            conn.execute(
                "with recursive n(i) as (values(1) union all select i+1 from n where i<?)
                 insert into payload select i,0,zeroblob(2000) from n",
                [rows],
            )
            .unwrap();
            let pages: i64 = conn
                .query_row("pragma page_count", [], |row| row.get(0))
                .unwrap();
            assert_eq!(pages * 4096 > 1024 * 1024, should_spill);
            assert!(pages * 4096 > 64 * 1024);

            conn.execute_batch("begin immediate; insert into audit values('before');")
                .unwrap();
            JOURNAL_OPENS.store(0, Ordering::Relaxed);
            let error = conn
                .execute(
                    "update payload set flag=case when id=? then 9 else 1 end",
                    [rows],
                )
                .unwrap_err();
            assert_eq!(
                error.sqlite_error_code(),
                Some(rusqlite::ErrorCode::ConstraintViolation)
            );
            let opens = JOURNAL_OPENS.load(Ordering::Relaxed);
            println!("rows={rows} pages={pages} subjournal_opens={opens}");
            assert_eq!(opens > 0, should_spill, "rows={rows}");
            assert!(!conn.is_autocommit(), "only the statement must roll back");
            assert_eq!(
                conn.query_row("select count(*) from payload where flag<>0", [], |r| r
                    .get::<_, i64>(0))
                    .unwrap(),
                0
            );
            conn.execute_batch("insert into audit values('after'); commit;")
                .unwrap();
            assert_eq!(
                conn.query_row("select group_concat(value, ',') from audit", [], |r| r
                    .get::<_, String>(
                    0
                ))
                .unwrap(),
                "before,after"
            );
            assert_eq!(
                conn.query_row("select count(*) from payload", [], |r| r.get::<_, i64>(0))
                    .unwrap(),
                rows
            );
            drop(conn);
            std::fs::remove_file(path).unwrap();
        }
    }
}
