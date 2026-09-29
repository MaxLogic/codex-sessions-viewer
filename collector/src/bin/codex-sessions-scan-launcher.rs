//! Runs the Codex and Claude Code scans for the scheduled task, then exits.
//!
//! This is a Windows-subsystem program, so Task Scheduler never opens a
//! console or Terminal window for it, and it starts each collector scan with
//! `CREATE_NO_WINDOW` for the same reason. Every argument it receives
//! (`--db`, `--settings`, ...) goes to both scans. Its exit code is the first
//! scan failure, or 0.
//!
//! Environment: `CODEX_SESSIONS_COLLECTOR_EXE` overrides the collector, which
//! otherwise sits next to this program.
#![cfg_attr(windows, windows_subsystem = "windows")]

use std::ffi::OsString;
use std::path::PathBuf;
use std::process::{Command, Stdio};

/// Short write transactions, so a viewer that is open at the same time is
/// never held past its own database wait.
const FLUSH_ARGS: [&str; 4] = ["--flush-sessions", "16", "--flush-bytes", "2097152"];

/// Longer than the collector's default, so a scan waits for the viewer's own
/// writes instead of failing.
const BUSY_TIMEOUT_MS: &str = "60000";

const EXIT_NO_COLLECTOR: i32 = 127;

fn collector_path() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("CODEX_SESSIONS_COLLECTOR_EXE") {
        return Some(PathBuf::from(path));
    }
    let name = if cfg!(windows) {
        "codex-sessions-collector.exe"
    } else {
        "codex-sessions-collector"
    };
    Some(std::env::current_exe().ok()?.with_file_name(name))
}

fn run_scan(collector: &PathBuf, harness: &str, args: &[OsString]) -> i32 {
    let mut command = Command::new(collector);
    command
        .arg(harness)
        .arg("scan")
        .args(args)
        .args(FLUSH_ARGS)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    if std::env::var_os("CODEX_SESSIONS_COLLECTOR_BUSY_TIMEOUT_MS").is_none() {
        command.env("CODEX_SESSIONS_COLLECTOR_BUSY_TIMEOUT_MS", BUSY_TIMEOUT_MS);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    match command.status() {
        Ok(status) => status.code().unwrap_or(1),
        Err(_) => EXIT_NO_COLLECTOR,
    }
}

/// The viewer skips Claude Code when its projects folder does not exist, so a
/// machine without Claude Code records nothing on every run.
fn claude_installed() -> bool {
    let root = codex_sessions_collector::settings::DefaultFolders::current().claude_projects_root;
    !root.is_empty() && std::path::Path::new(&root).is_dir()
}

fn main() {
    // Not `args()`: a non-Unicode argument must not panic a windowless program.
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let Some(collector) = collector_path() else {
        std::process::exit(EXIT_NO_COLLECTOR);
    };
    let mut code = run_scan(&collector, "codex", &args);
    if claude_installed() {
        let claude = run_scan(&collector, "claude", &args);
        if code == 0 {
            code = claude;
        }
    }
    std::process::exit(code);
}
