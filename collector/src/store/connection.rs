//! Process-wide SQLite configuration shared by binaries and library callers.

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
            // SAFETY: configuration is complete, still under the same Once.
            // Keep rusqlite's normal threading checks after this initialization.
            let code = unsafe { rusqlite::ffi::sqlite3_initialize() };
            if code == rusqlite::ffi::SQLITE_OK {
                Ok(())
            } else {
                Err((code, "sqlite3_initialize"))
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
}
