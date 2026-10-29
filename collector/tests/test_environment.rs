mod support;

#[test]
fn relative_queue_is_confined_to_the_owned_working_directory() {
    let owned = support::TempDir::new("relative-queue");
    let result = support::collector()
        .current_dir(owned.path())
        .env("CODEX_SESSIONS_COLLECTOR_QUEUE", "queue")
        .arg("version")
        .output()
        .unwrap();
    assert!(result.status.success());
    let escaped = support::collector()
        .current_dir(owned.path())
        .env("CODEX_SESSIONS_COLLECTOR_QUEUE", "../../../../escape")
        .arg("version")
        .output();
    assert_eq!(
        escaped.unwrap_err().kind(),
        std::io::ErrorKind::PermissionDenied
    );
}

#[test]
fn collector_rejects_profile_escape_before_spawn() {
    let synthetic_profile = std::env::current_dir()
        .unwrap()
        .join("synthetic-real-profile-not-created");
    let result = support::collector()
        .arg("version")
        .env("APPDATA", synthetic_profile)
        .output();
    assert!(result.is_err(), "unowned APPDATA must fail before spawn");
}

#[test]
fn all_profile_overrides_and_unknown_collector_paths_fail_closed() {
    let outside = support::test_root()
        .parent()
        .unwrap()
        .join("synthetic-real-profile");
    for key in [
        "LOCALAPPDATA",
        "APPDATA",
        "USERPROFILE",
        "HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
        "XDG_CACHE_HOME",
        "XDG_RUNTIME_DIR",
        "XDG_CONFIG_DIRS",
        "XDG_DATA_DIRS",
        "CODEX_HOME",
        "CLAUDE_CONFIG_DIR",
        "CLAUDE_HOME",
        "CODEX_SESSIONS_COLLECTOR_QUEUE",
        "TEMP",
        "TMP",
        "TMPDIR",
        "CODEX_SESSIONS_COLLECTOR_FUTURE_LOG",
    ] {
        let result = support::collector()
            .arg("version")
            .env(key, &outside)
            .output();
        assert_eq!(
            result.unwrap_err().kind(),
            std::io::ErrorKind::PermissionDenied,
            "{key}"
        );
    }
}

/// An absolute path outside the sandbox: `C:/...` is relative on Unix.
fn outside(name: &str) -> String {
    if cfg!(windows) {
        format!("C:\\synthetic-real-profile\\{name}")
    } else {
        format!("/synthetic-real-profile/{name}")
    }
}

#[test]
fn native_default_settings_probe_cannot_read_an_unowned_profile() {
    let owned = support::TempDir::new("settings-isolation");
    let settings = owned.path().join("settings.toml");
    std::fs::write(
        &settings,
        format!("[paths]\nwindows_codex_path = '{}'\n", outside("sessions")),
    )
    .unwrap();
    let result = support::collector()
        .args(["codex", "scan", "--settings"])
        .arg(&settings)
        .output();
    assert_eq!(
        result.unwrap_err().kind(),
        std::io::ErrorKind::PermissionDenied
    );
}

#[test]
fn resident_lifecycle_defaults_remain_inside_the_owned_profile() {
    use std::time::{Duration, Instant};
    let owned = support::TempDir::new("lifecycle-isolation");
    let database = owned.path().join("missing.sqlite");
    let mut command = support::collector();
    command.profile(owned.path());
    let child = command
        .args(["serve", "--lifetime", "viewer", "--db"])
        .arg(&database)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
    struct Resident(std::process::Child);
    impl Drop for Resident {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let mut resident = Resident(child);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let output = support::collector()
            .profile(owned.path())
            .args(["resident", "status", "--db"])
            .arg(&database)
            .output()
            .unwrap();
        if output.status.success() {
            break;
        }
        assert!(Instant::now() < deadline, "resident did not start");
        std::thread::sleep(Duration::from_millis(20));
    }
    let stop = support::collector()
        .profile(owned.path())
        .args(["resident", "stop", "--db"])
        .arg(&database)
        .output()
        .unwrap();
    assert!(stop.status.success());
    assert!(resident.0.wait().unwrap().success());
    #[cfg(windows)]
    assert!(
        owned
            .path()
            .join("CodexSessionViewer/collector/resident.log")
            .is_file()
    );
}

#[test]
fn a_default_settings_scan_does_not_inherit_profile_configuration() {
    let owned = support::TempDir::new("default-settings");
    let db = support::viewer_database(&owned);
    let home = support::codex_home(&owned, &[]);
    let result = support::scan(&db, &home, &[]);
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
}

#[test]
fn hook_transcript_escape_is_rejected_before_spawn() {
    let input = serde_json::json!({"transcript_path": outside("transcript.jsonl")}).to_string();
    let result = support::collector()
        .args(["claude", "hook"])
        .spawn_with_input(&input);
    let error = match result {
        Err(error) => error,
        Ok(mut child) => {
            let _ = child.kill();
            let _ = child.wait();
            panic!("transcript guard admitted an escaped path");
        }
    };
    assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied);
}

#[test]
fn positional_ingest_input_is_guarded_before_spawn() {
    let result = support::collector()
        .args(["codex", "ingest", &outside("input"), "--db"])
        .arg(support::test_root().join("owned.sqlite"))
        .output();
    assert_eq!(
        result.unwrap_err().kind(),
        std::io::ErrorKind::PermissionDenied
    );
}

#[test]
fn native_scan_does_not_read_poisoned_inherited_settings() {
    let poison = support::TempDir::new("poisoned-profile");
    let setting = poison.path().join("CodexSessionViewer/settings.toml");
    std::fs::create_dir_all(setting.parent().unwrap()).unwrap();
    std::fs::write(&setting, "POISONED_INHERITED_SETTINGS = [").unwrap();
    let output = support::command_with_inherited_profile(
        env!("CARGO_BIN_EXE_codex-sessions-collector"),
        poison.path(),
    )
    .args(["codex", "scan", "--standalone"])
    .arg(support::test_root().join("poison-probe.sqlite"))
    .args(["--no-wsl-projects", "--json"])
    .output()
    .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        std::fs::read_to_string(&setting).unwrap(),
        "POISONED_INHERITED_SETTINGS = ["
    );
}
#[test]
fn unknown_executables_and_native_stores_are_denied() {
    for name in ["schtasks.exe", "reg.exe", "wsl.exe", "unknown.exe"] {
        let error = support::test_command(name)
            .arg("/Create")
            .output()
            .unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied, "{name}");
    }
}

#[test]
fn system_variable_overrides_are_rejected_before_spawn() {
    for key in ["SYSTEMROOT", "WINDIR", "COMSPEC", "PATHEXT"] {
        let error = support::collector()
            .arg("version")
            .env(key, support::test_root().join("poison-system"))
            .output()
            .expect_err("system override must not reach child");
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied, "{key}");
    }
}

#[test]
fn native_hub_endpoints_require_owned_loopback_fixtures() {
    for url in ["https://example.invalid", "http://127.0.0.1:12345"] {
        // Admission only: never allow the RED run to make an external request.
        let error = support::collector()
            .args(["codex", "verify", "--hub-url", url])
            .output()
            .expect_err("endpoint must fail admission");
        assert_eq!(error.kind(), std::io::ErrorKind::PermissionDenied, "{url}");
    }
}
