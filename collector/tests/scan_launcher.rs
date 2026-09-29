//! The scheduled-task launcher runs both scans with the caller's arguments and
//! returns the first failure. A fake collector script records what it is given.
#![cfg(windows)]

mod support;

use std::path::Path;
use std::process::Command;

use support::TempDir;

fn launcher() -> Command {
    Command::new(env!("CARGO_BIN_EXE_codex-sessions-scan-launcher"))
}

/// A collector stand-in that logs its arguments and exits with `code`
/// for the given harness.
fn fake_collector(dir: &Path, codex_code: i32, claude_code: i32) -> std::path::PathBuf {
    let script = dir.join("fake collector.cmd");
    std::fs::write(
        &script,
        format!(
            "@echo off\r\necho busy=%CODEX_SESSIONS_COLLECTOR_BUSY_TIMEOUT_MS% %*>>\"{}\"\r\nif \"%1\"==\"codex\" exit /b {codex_code}\r\nexit /b {claude_code}\r\n",
            dir.join("calls.log").display()
        ),
    )
    .unwrap();
    script
}

fn run(dir: &Path, home: &Path, script: &Path, args: &[&str]) -> i32 {
    launcher()
        .args(args)
        .env("CODEX_SESSIONS_COLLECTOR_EXE", script)
        .env_remove("CODEX_SESSIONS_COLLECTOR_BUSY_TIMEOUT_MS")
        .env("USERPROFILE", home)
        .env("HOME", home)
        .status()
        .unwrap()
        .code()
        .unwrap_or_else(|| panic!("launcher in {} was killed", dir.display()))
}

fn calls(dir: &Path) -> Vec<String> {
    std::fs::read_to_string(dir.join("calls.log"))
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect()
}

#[test]
fn both_scans_run_with_the_arguments_and_short_write_batches() {
    let temp = TempDir::new("launcher-both");
    let home = temp.path().join("home");
    std::fs::create_dir_all(home.join(".claude").join("projects")).unwrap();
    let script = fake_collector(temp.path(), 0, 0);
    assert_eq!(run(temp.path(), &home, &script, &["--db", "a b.sqlite"]), 0);
    let calls = calls(temp.path());
    assert_eq!(calls.len(), 2, "{calls:?}");
    assert!(calls[0].starts_with(
        "busy=60000 codex scan --db \"a b.sqlite\" --flush-sessions 16 --flush-bytes 2097152"
    ));
    assert!(calls[1].starts_with(
        "busy=60000 claude scan --db \"a b.sqlite\" --flush-sessions 16 --flush-bytes 2097152"
    ));
}

#[test]
fn claude_is_skipped_when_its_projects_folder_is_missing() {
    let temp = TempDir::new("launcher-skip");
    let home = temp.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let script = fake_collector(temp.path(), 0, 5);
    assert_eq!(run(temp.path(), &home, &script, &[]), 0);
    let calls = calls(temp.path());
    assert_eq!(calls.len(), 1, "{calls:?}");
    assert!(calls[0].starts_with("busy=60000 codex scan"));
}

#[test]
fn the_first_failure_is_the_exit_code_and_the_other_scan_still_runs() {
    let temp = TempDir::new("launcher-codes");
    let home = temp.path().join("home");
    std::fs::create_dir_all(home.join(".claude").join("projects")).unwrap();
    let script = fake_collector(temp.path(), 3, 5);
    assert_eq!(run(temp.path(), &home, &script, &[]), 3);
    assert_eq!(calls(temp.path()).len(), 2);
    let script = fake_collector(temp.path(), 0, 5);
    assert_eq!(run(temp.path(), &home, &script, &[]), 5);
}

#[test]
fn a_missing_collector_fails_without_a_window_or_panic() {
    let temp = TempDir::new("launcher-missing");
    let code = launcher()
        .env("CODEX_SESSIONS_COLLECTOR_EXE", temp.path().join("nope.exe"))
        .env("USERPROFILE", temp.path())
        .env("HOME", temp.path())
        .status()
        .unwrap()
        .code();
    assert_eq!(code, Some(127));
}

#[test]
fn the_launcher_is_a_windows_subsystem_program() {
    // PE optional header Subsystem field: 2 = GUI, 3 = console.
    let bytes = std::fs::read(env!("CARGO_BIN_EXE_codex-sessions-scan-launcher")).unwrap();
    let pe = u32::from_le_bytes(bytes[0x3c..0x40].try_into().unwrap()) as usize;
    let subsystem = u16::from_le_bytes(bytes[pe + 24 + 68..pe + 24 + 70].try_into().unwrap());
    assert_eq!(subsystem, 2);
}
