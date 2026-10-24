//! The launcher itself owns the resident, endpoint, and database work.
mod support;
use codex_sessions_collector::resident::instance;
use std::{
    process::Stdio,
    time::{Duration, Instant},
};

#[test]
fn launcher_is_the_resident_and_killing_it_releases_ownership() {
    let temp = support::TempDir::new("launcher-resident");
    let db = support::viewer_database(&temp);
    let mut command = support::test_command(env!("CARGO_BIN_EXE_codex-sessions-scan-launcher"));
    command.profile(temp.path());
    command
        .args(["--db"])
        .arg(&db)
        .env("CODEX_SESSIONS_COLLECTOR_QUEUE", temp.path().join("queue"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        command.creation_flags(0x08000000);
    }
    struct Child(std::process::Child);
    impl Drop for Child {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let mut child = Child(command.spawn().unwrap());
    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        let output = support::collector()
            .args(["resident", "status", "--db"])
            .arg(&db)
            .output()
            .unwrap();
        if output.status.success() {
            break serde_json::from_slice::<serde_json::Value>(&output.stdout).unwrap();
        }
        assert!(
            child.0.try_wait().unwrap().is_none(),
            "launcher exited instead of serving"
        );
        assert!(Instant::now() < deadline, "launcher endpoint missing");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(status["pid"], child.0.id());
    child.0.kill().unwrap();
    child.0.wait().unwrap();
    assert!(instance::InstanceLock::try_acquire(&db).unwrap().is_some());
    let conn = rusqlite::Connection::open(&db).unwrap();
    conn.busy_timeout(Duration::from_millis(200)).unwrap();
    conn.execute_batch("begin immediate; rollback").unwrap();
}

#[cfg(windows)]
#[test]
fn the_launcher_is_a_windows_subsystem_program() {
    // PE optional header Subsystem field: 2 = GUI, 3 = console.
    let bytes = std::fs::read(env!("CARGO_BIN_EXE_codex-sessions-scan-launcher")).unwrap();
    let pe = u32::from_le_bytes(bytes[0x3c..0x40].try_into().unwrap()) as usize;
    let subsystem = u16::from_le_bytes(bytes[pe + 24 + 68..pe + 24 + 70].try_into().unwrap());
    assert_eq!(subsystem, 2);
}
