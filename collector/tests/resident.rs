mod support;

use codex_sessions_collector::resident::{endpoint, instance, protocol};
use serde_json::Value;
use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

trait Wire: Read + Write + Send {}
impl<T: Read + Write + Send> Wire for T {}

struct Fixture {
    root: PathBuf,
    db: PathBuf,
    children: Vec<Child>,
}
impl Fixture {
    fn new() -> Self {
        let parent = std::env::var_os("CXV_RESIDENT_TEST_ROOT")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let root = parent.join(format!(
            "resident-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&root).unwrap();
        let db = root.join("viewer.sqlite");
        support::create_viewer_database(&db);
        Self {
            root,
            db,
            children: Vec::new(),
        }
    }
    fn command(&self) -> Command {
        let mut command = support::collector();
        command
            .env("LOCALAPPDATA", &self.root)
            .env("XDG_RUNTIME_DIR", &self.root)
            .env("XDG_CACHE_HOME", &self.root);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x08000000);
        }
        command
    }
    fn start(&mut self, lifetime: &str) {
        let child = self
            .command()
            .args(["serve", "--db"])
            .arg(&self.db)
            .args(["--lifetime", lifetime])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        self.children.push(child);
    }
    fn cli(&self, action: &str) -> std::process::Output {
        self.command()
            .args(["resident", action, "--db"])
            .arg(&self.db)
            .output()
            .unwrap()
    }
    fn ready(&mut self) -> Value {
        let deadline = Instant::now() + Duration::from_secs(4);
        loop {
            let output = self.cli("status");
            if output.status.success() {
                let value: Value = serde_json::from_slice(&output.stdout).unwrap();
                if value["state"] != "starting" {
                    return value;
                }
            }
            assert!(
                self.children
                    .iter_mut()
                    .any(|c| c.try_wait().unwrap().is_none()),
                "serve exited before readiness: {}",
                String::from_utf8_lossy(&output.stderr)
            );
            assert!(
                Instant::now() < deadline,
                "resident did not become reachable"
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    fn wire(&self) -> BufReader<Box<dyn Wire>> {
        #[cfg(windows)]
        let stream = endpoint::connect(
            &instance::database_key(&self.db).unwrap(),
            Duration::from_secs(2),
        )
        .unwrap();
        #[cfg(unix)]
        let stream = {
            let info: Value = serde_json::from_slice(&self.cli("info").stdout).unwrap();
            let stream =
                std::os::unix::net::UnixStream::connect(info["endpoint"].as_str().unwrap())
                    .unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            stream
                .set_write_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            stream
        };
        BufReader::new(Box::new(stream))
    }
    fn wait_all(&mut self, timeout: Duration) {
        let deadline = Instant::now() + timeout;
        for child in &mut self.children {
            loop {
                if let Some(status) = child.try_wait().unwrap() {
                    assert!(status.success(), "child {} exited {status}", child.id());
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "child {} did not exit",
                    child.id()
                );
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
}
fn exchange(wire: &mut BufReader<Box<dyn Wire>>, value: Value) -> Value {
    protocol::send(wire.get_mut(), &value).unwrap();
    let mut line = String::new();
    wire.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}
impl Drop for Fixture {
    fn drop(&mut self) {
        for child in &mut self.children {
            if child.try_wait().unwrap().is_none() {
                child.kill().unwrap();
            }
            child.wait().unwrap();
        }
        // Only this test's freshly allocated root; never follow reparse points.
        fn no_links(path: &Path) -> bool {
            std::fs::read_dir(path).unwrap().all(|entry| {
                let entry = entry.unwrap();
                let metadata = std::fs::symlink_metadata(entry.path()).unwrap();
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if metadata.file_attributes() & 0x400 != 0 {
                        return false;
                    }
                }
                !metadata.file_type().is_symlink()
                    && (!metadata.is_dir() || no_links(&entry.path()))
            })
        }
        assert!(no_links(&self.root));
        std::fs::remove_dir_all(&self.root).unwrap();
    }
}

#[test]
fn protocol_connect_close_preserves_endpoint_and_resident() {
    let mut fixture = Fixture::new();
    let key = instance::database_key(&fixture.db).unwrap();
    for _ in 0..16 {
        // A newly created instance permits connect before ConnectNamedPipe;
        // a reset instance requires accept to be posted before reconnect.
        let mut listener = endpoint::Listener::bind(&key).unwrap();
        // Close before accept starts: on Windows this deterministically puts
        // the pending instance into ERROR_NO_DATA, rather than racing accept.
        drop(endpoint::connect(&key, Duration::from_secs(2)).unwrap());
        match listener.accept() {
            Ok(stream) => drop(stream),
            Err(error) => assert!(matches!(
                error.kind(),
                std::io::ErrorKind::ConnectionAborted | std::io::ErrorKind::BrokenPipe
            )),
        }
        assert!(
            endpoint::Listener::bind(&key).is_err(),
            "a disconnected client must not release first-instance ownership"
        );
    }
    fixture.start("resident");
    let pid = fixture.ready()["pid"].clone();
    for n in 0..16 {
        drop(fixture.wire());
        let reply = exchange(
            &mut fixture.wire(),
            serde_json::json!({"v":1,"id":format!("after-close-{n}"),"op":"hello","client":"cli"}),
        );
        assert_eq!(reply["event"], "hello");
        assert_eq!(reply["pid"], pid);
    }
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
}

#[test]
fn single_instance_eight_concurrent_starters() {
    let mut fixture = Fixture::new();
    let start = Instant::now();
    for _ in 0..8 {
        fixture.start("resident");
    }
    let status = fixture.ready();
    let deadline = start + Duration::from_secs(6);
    loop {
        let mut alive = Vec::new();
        for child in &mut fixture.children {
            match child.try_wait().unwrap() {
                Some(status) => assert!(status.success(), "loser exited {status}"),
                None => alive.push(child.id()),
            }
        }
        if alive.len() == 1 {
            assert_eq!(status["pid"].as_u64().unwrap(), u64::from(alive[0]));
            break;
        }
        assert!(
            Instant::now() < deadline,
            "{} starters still running",
            alive.len()
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(fixture.db.with_extension("sqlite.collector.lock"))
        .unwrap();
    assert!(matches!(
        lock.try_lock(),
        Err(std::fs::TryLockError::WouldBlock)
    ));
    for n in 0..8 {
        let hello = exchange(
            &mut fixture.wire(),
            serde_json::json!({"v":1,"id":format!("hello-{n}"),"op":"hello","client":"cli"}),
        );
        assert_eq!(hello["pid"], status["pid"]);
    }
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
    lock.try_lock().unwrap();
}

#[cfg(windows)]
#[test]
fn single_instance_database_key_uses_absolute_case_normalization() {
    // Independently computed with .NET SHA256 over UTF-8 c:\viewer\db.sqlite.
    assert_eq!(
        instance::database_key(Path::new("C:/Viewer/DB.sqlite")).unwrap(),
        "3696a1c048ed0f03"
    );
    assert_eq!(
        instance::database_key(Path::new("c:\\viewer\\db.sqlite")).unwrap(),
        "3696a1c048ed0f03"
    );
    let relative = Path::new(".").join("resident-identity-uncreated.sqlite");
    let absolute = std::env::current_dir()
        .unwrap()
        .join("resident-identity-uncreated.sqlite");
    assert_eq!(
        instance::database_key(&relative).unwrap(),
        instance::database_key(&absolute).unwrap()
    );
}

#[test]
fn protocol_wire_version_and_validation() {
    let mut fixture = Fixture::new();
    fixture.start("viewer");
    fixture.ready();
    let mut wire = fixture.wire();
    let hello = exchange(
        &mut wire,
        serde_json::json!({"v":1,"id":"h","op":"hello","client":"viewer","future_field":true}),
    );
    assert_eq!(hello["event"], "hello");
    assert_eq!(hello["id"], "h");
    assert_eq!(hello["protocol"], 1);
    assert_eq!(hello["schema"], 30);
    assert_eq!(hello["contract"], 2);
    assert!(hello["parsers"]["codex"].as_i64().unwrap() > 0);
    assert!(hello["parsers"]["claude"].as_i64().unwrap() > 0);
    assert_eq!(hello["collector_version"], env!("CARGO_PKG_VERSION"));
    assert_eq!(hello["lifetime"], "viewer");
    let unknown = exchange(
        &mut wire,
        serde_json::json!({"v":1,"id":"u","op":"not_an_operation"}),
    );
    assert_eq!(unknown["code"], "bad_request");
    let upgraded = exchange(
        &mut wire,
        serde_json::json!({"v":1,"id":"h2","op":"hello","client":"launcher","lifetime":"resident"}),
    );
    assert_eq!(upgraded["lifetime"], "resident");
    let v2 = exchange(
        &mut wire,
        serde_json::json!({"v":2,"id":"v2","op":"status"}),
    );
    assert_eq!(v2["v"], 1);
    assert_eq!(v2["id"], "v2");
    assert_eq!(v2["code"], "unsupported_version");
    let mut byte = [0];
    assert_eq!(
        wire.read(&mut byte).unwrap(),
        0,
        "unsupported version closes connection"
    );
    drop(wire);
    let mut oversized = fixture.wire();
    oversized
        .get_mut()
        .write_all(&vec![b' '; protocol::MAX_REQUEST_BYTES + 1])
        .unwrap();
    let mut line = String::new();
    oversized.read_line(&mut line).unwrap();
    let error: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(error["code"], "bad_request");
    drop(oversized);
    let mut invalid = fixture.wire();
    invalid.get_mut().write_all(b"{bad json}\n").unwrap();
    let mut line = String::new();
    invalid.read_line(&mut line).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&line).unwrap()["code"],
        "bad_request"
    );
    drop(invalid);
    let idle = fixture.wire();
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
    drop(idle);
}

#[test]
fn single_instance_hard_kill_releases_lock_and_restarts() {
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let first = fixture.children[0].id();
    fixture.children[0].kill().unwrap();
    fixture.children[0].wait().unwrap();
    fixture.start("resident");
    assert_ne!(fixture.ready()["pid"], u64::from(first));
    assert!(fixture.cli("stop").status.success());
    let child = fixture.children.last_mut().unwrap();
    assert!(child.wait().unwrap().success());
}

#[test]
fn single_instance_waits_for_lock_when_no_endpoint_is_available() {
    let mut fixture = Fixture::new();
    let lock = instance::InstanceLock::try_acquire(&fixture.db)
        .unwrap()
        .unwrap();
    fixture.start("resident");
    std::thread::sleep(Duration::from_millis(5200));
    assert!(
        fixture.children[0].try_wait().unwrap().is_none(),
        "starter must wait beyond the 5 s hello window"
    );
    drop(lock);
    assert_eq!(fixture.ready()["state"], "ready");
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
}

#[test]
fn protocol_missing_database_waits_without_creating_it() {
    let mut fixture = Fixture::new();
    std::fs::remove_file(&fixture.db).unwrap();
    fixture.start("resident");
    assert_eq!(fixture.ready()["state"], "waiting_for_database");
    assert!(!fixture.db.exists());
    support::create_viewer_database(&fixture.db);
    let deadline = Instant::now() + Duration::from_secs(32);
    loop {
        let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
        if status["state"] == "ready" {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "missing database was not retried"
        );
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
}

#[test]
fn protocol_viewer_idle_exit_after_last_viewer_disconnects() {
    let mut fixture = Fixture::new();
    fixture.start("viewer");
    fixture.ready();
    let mut viewer = fixture.wire();
    assert_eq!(
        exchange(
            &mut viewer,
            serde_json::json!({"v":1,"id":"viewer","op":"hello","client":"viewer"})
        )["lifetime"],
        "viewer"
    );
    // A live viewer must suppress idle exit even beyond the startup idle window.
    std::thread::sleep(Duration::from_secs(31));
    assert!(fixture.children[0].try_wait().unwrap().is_none());
    drop(viewer);
    let disconnected = Instant::now();
    std::thread::sleep(Duration::from_secs(29));
    assert!(
        fixture.children[0].try_wait().unwrap().is_none(),
        "exited before the 30 s disconnect grace"
    );
    fixture.wait_all(Duration::from_secs(4));
    assert!(disconnected.elapsed() >= Duration::from_secs(30));
    assert!(
        instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .is_some()
    );
}

#[test]
fn protocol_pending_migration_recovers_without_writing() {
    let mut fixture = Fixture::new();
    support::insert_running_usage_migration(&fixture.db);
    fixture.start("resident");
    assert_eq!(fixture.ready()["state"], "waiting_for_database");
    let connection = rusqlite::Connection::open(&fixture.db).unwrap();
    connection
        .execute("update maintenance_jobs set state='succeeded'", [])
        .unwrap();
    drop(connection);
    let deadline = Instant::now() + Duration::from_secs(12);
    loop {
        let status: Value = serde_json::from_slice(&fixture.cli("status").stdout).unwrap();
        if status["state"] == "ready" {
            assert_eq!(status["write_hold"]["transactions"], 0);
            break;
        }
        assert!(Instant::now() < deadline, "migration was not retried");
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
}

#[test]
fn protocol_saturated_clients_do_not_break_accept_or_shutdown() {
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let mut clients = Vec::new();
    for _ in 0..12 {
        clients.push(fixture.wire());
    }
    // New connections beyond capacity are closed. Release all test-owned clients;
    // a control client must then be admitted and shutdown must still join everyone.
    drop(clients);
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        if fixture.cli("stop").status.success() {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "accept loop failed under saturation"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
    fixture.wait_all(Duration::from_secs(5));
}

#[test]
fn protocol_shutdown_interrupts_a_continuously_partial_request() {
    let mut fixture = Fixture::new();
    fixture.start("resident");
    fixture.ready();
    let mut wire = fixture.wire();
    wire.get_mut().write_all(b" ").unwrap();
    let writer = std::thread::spawn(move || {
        let until = Instant::now() + Duration::from_secs(7);
        while Instant::now() < until {
            if wire.get_mut().write_all(b" ").is_err() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    });
    let start = Instant::now();
    let stop = fixture.cli("stop");
    let elapsed = start.elapsed();
    writer.join().unwrap();
    assert!(stop.status.success());
    fixture.wait_all(Duration::from_secs(1));
    assert!(
        elapsed < Duration::from_secs(5),
        "shutdown took {elapsed:?} while a partial request kept arriving"
    );
}

#[test]
fn protocol_newer_schema_exits_three() {
    let mut fixture = Fixture::new();
    let conn = rusqlite::Connection::open(&fixture.db).unwrap();
    conn.execute(
        "insert into schema_version values (31, 'future.sql','future','now',1,null)",
        [],
    )
    .unwrap();
    drop(conn);
    fixture.start("resident");
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(status) = fixture.children[0].try_wait().unwrap() {
            assert_eq!(status.code(), Some(3));
            break;
        }
        assert!(Instant::now() < deadline, "outdated resident stayed alive");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(
        instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .is_some()
    );
}

#[cfg(windows)]
#[test]
fn protocol_windows_first_instance_security_and_handle_cleanup() {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::{
        Foundation::*,
        Security::{Authorization::*, *},
        Storage::FileSystem::*,
        System::Threading::*,
    };
    if std::env::var_os("CXV_HANDLE_CHECK_CHILD").is_none() {
        use std::os::windows::process::CommandExt;
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "protocol_windows_first_instance_security_and_handle_cleanup",
                "--nocapture",
            ])
            .env("CXV_HANDLE_CHECK_CHILD", "1")
            .creation_flags(0x08000000)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "isolated handle check: {} {}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }
    let fixture = Fixture::new();
    let key = instance::database_key(&fixture.db).unwrap();
    // Obtain the account SID independently from the actual process token.
    // SAFETY: token and variable-sized TOKEN_USER stay owned through SID conversion.
    let account_sid = unsafe {
        let mut raw = std::ptr::null_mut();
        assert_ne!(
            OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut raw),
            0
        );
        let token = <std::os::windows::io::OwnedHandle as std::os::windows::io::FromRawHandle>::from_raw_handle(raw);
        let mut size = 0;
        GetTokenInformation(
            token.as_raw_handle(),
            TokenUser,
            std::ptr::null_mut(),
            0,
            &mut size,
        );
        assert!(size > 0);
        let mut buffer = vec![0usize; (size as usize).div_ceil(size_of::<usize>())];
        assert_ne!(
            GetTokenInformation(
                token.as_raw_handle(),
                TokenUser,
                buffer.as_mut_ptr().cast(),
                size,
                &mut size
            ),
            0
        );
        let user = &*buffer.as_ptr().cast::<TOKEN_USER>();
        let mut text = std::ptr::null_mut();
        assert_ne!(ConvertSidToStringSidW(user.User.Sid, &mut text), 0);
        let mut length = 0;
        while *text.add(length) != 0 {
            length += 1;
        }
        let sid = String::from_utf16_lossy(std::slice::from_raw_parts(text, length));
        LocalFree(text.cast());
        sid
    };
    // Inspect the actual kernel object's descriptor, rather than its input SDDL.
    let mut before = 0;
    // SAFETY: process pseudohandle is valid and before is writable.
    assert_ne!(
        unsafe { GetProcessHandleCount(GetCurrentProcess(), &mut before) },
        0
    );
    for iteration in 0..33 {
        let _lock = instance::InstanceLock::try_acquire(&fixture.db)
            .unwrap()
            .unwrap();
        let listener = endpoint::Listener::bind(&key).unwrap();
        assert!(
            endpoint::Listener::bind(&key).is_err(),
            "first-instance guard must reject a second server"
        );
        let name: Vec<u16> = endpoint::endpoint_name(&key)
            .unwrap()
            .encode_utf16()
            .chain(Some(0))
            .collect();
        // Open with READ_CONTROL so GetSecurityInfo examines the live pipe.
        // SAFETY: valid NUL-terminated name, returned owned handle closed below.
        let raw = unsafe {
            CreateFileW(
                name.as_ptr(),
                READ_CONTROL,
                0,
                std::ptr::null(),
                OPEN_EXISTING,
                0,
                std::ptr::null_mut(),
            )
        };
        assert_ne!(raw, INVALID_HANDLE_VALUE);
        // SAFETY: raw is newly owned, and remains valid until File drop.
        let file =
            unsafe { <std::fs::File as std::os::windows::io::FromRawHandle>::from_raw_handle(raw) };
        let mut descriptor = std::ptr::null_mut();
        // SAFETY: all optional outputs null except descriptor, allocated by this API.
        let result = unsafe {
            GetSecurityInfo(
                file.as_raw_handle(),
                SE_KERNEL_OBJECT,
                DACL_SECURITY_INFORMATION,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut descriptor,
            )
        };
        assert_eq!(result, 0);
        let mut text = std::ptr::null_mut();
        // SAFETY: descriptor is valid until LocalFree; text is an out pointer.
        assert_ne!(
            unsafe {
                ConvertSecurityDescriptorToStringSecurityDescriptorW(
                    descriptor,
                    SDDL_REVISION_1,
                    DACL_SECURITY_INFORMATION,
                    &mut text,
                    std::ptr::null_mut(),
                )
            },
            0
        );
        let mut len = 0;
        // SAFETY: the API returns a NUL-terminated UTF-16 string.
        let sddl = unsafe {
            while *text.add(len) != 0 {
                len += 1;
            }
            String::from_utf16_lossy(std::slice::from_raw_parts(text, len))
        };
        // SAFETY: free exactly the allocations returned by the security APIs.
        unsafe {
            LocalFree(text.cast());
            LocalFree(descriptor);
        }
        assert!(sddl.starts_with("D:P"), "DACL must be protected: {sddl}");
        assert_eq!(
            sddl.matches("(A;").count(),
            2,
            "only user and SYSTEM grants: {sddl}"
        );
        assert!(sddl.contains(";;;SY)"));
        assert!(
            sddl.contains(&format!(";;;{account_sid})")),
            "current account SID: {sddl}"
        );
        assert!(!sddl.contains(";;;WD)") && !sddl.contains(";;;AU)"));
        drop(file);
        drop(listener);
        drop(_lock);
        if iteration == 0 {
            // Security APIs load Windows DLLs on first use. Measure after that
            // initialization, in this isolated process with no sibling test activity.
            // SAFETY: process pseudohandle is valid and before is writable.
            assert_ne!(
                unsafe { GetProcessHandleCount(GetCurrentProcess(), &mut before) },
                0
            );
        }
    }
    let mut after = 0;
    // SAFETY: process pseudohandle is valid and after is writable.
    assert_ne!(
        unsafe { GetProcessHandleCount(GetCurrentProcess(), &mut after) },
        0
    );
    assert_eq!(after, before, "32 bind/security/drop cycles leaked handles");
}

#[test]
fn protocol_cli_info_status_shutdown() {
    let mut fixture = Fixture::new();
    let info = fixture.cli("info");
    assert!(
        info.status.success(),
        "resident info failed: {}",
        String::from_utf8_lossy(&info.stderr)
    );
    let info: Value = serde_json::from_slice(&info.stdout).unwrap();
    assert_eq!(info["database_key"].as_str().unwrap().len(), 16);
    assert!(!info["endpoint"].as_str().unwrap().is_empty());
    fixture.start("resident");
    let status = fixture.ready();
    assert_eq!(status["v"], 1);
    assert_eq!(status["event"], "status");
    assert_eq!(status["state"], "ready");
    assert_eq!(status["queue"]["pending"], 0);
    assert_eq!(status["write_hold"]["transactions"], 0);
    assert!(fixture.cli("stop").status.success());
    fixture.wait_all(Duration::from_secs(5));
    assert!(!fixture.cli("status").status.success());
    assert!(fixture.cli("stop").status.success(), "stop is idempotent");
}
