//! Harness hooks and the durable work queue behind them.
//!
//! A hook only records what happened in a small JSON file in the queue folder
//! and starts a detached `drain`; it never opens the database, so a busy
//! database or a slow collection cannot block the agent. `drain` claims queue
//! files by renaming them (so concurrent drains never process the same entry),
//! ingests the named sessions, and deletes each entry once it is committed.
//! Failed entries return to the queue with a retry time; claims left by a
//! crashed drain are reclaimed. A periodic full scan (`codex scan`,
//! `claude scan`) repairs anything a hook missed.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::dart::DartDateTime;

/// Entries retried this many times are dropped; the next full scan picks the
/// session up.
pub const MAX_ATTEMPTS: u32 = 6;
/// A claim older than this belongs to a drain that died.
pub const STALE_CLAIM: Duration = Duration::from_secs(600);
const MAX_HOOK_INPUT_BYTES: u64 = 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct WorkItem {
    pub harness: String,
    pub event: String,
    #[serde(default)]
    pub session_id: Option<String>,
    #[serde(default)]
    pub transcript_path: Option<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    pub received_utc: String,
    #[serde(default)]
    pub attempts: u32,
    /// Do not retry before this time.
    #[serde(default)]
    pub not_before_utc: Option<String>,
    #[serde(default)]
    pub last_error: Option<String>,
}

/// `CODEX_SESSIONS_COLLECTOR_QUEUE`, else
/// The platform's per-user cache queue.
pub fn queue_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("CODEX_SESSIONS_COLLECTOR_QUEUE").filter(|v| !v.is_empty())
    {
        return PathBuf::from(dir);
    }
    crate::platform_locations::PlatformLocations::current()
        .map(|locations| locations.queue_dir)
        .unwrap_or_else(|| {
            std::env::temp_dir()
                .join("CodexSessionViewer")
                .join("collector")
                .join("queue")
        })
}

fn unique_name() -> String {
    let nanos = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    format!("{nanos:024}-{}", std::process::id())
}

/// Write `item` durably: a temporary file renamed into place.
pub fn enqueue(dir: &Path, item: &WorkItem) -> std::io::Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    let name = unique_name();
    let temporary = dir.join(format!("{name}.tmp"));
    let target = dir.join(format!("{name}.json"));
    {
        let mut file = std::fs::File::create(&temporary)?;
        file.write_all(serde_json::to_string(item)?.as_bytes())?;
        file.sync_all()?;
    }
    std::fs::rename(&temporary, &target)?;
    Ok(target)
}

/// Record a hook failure without failing the harness.
pub fn log_error(dir: &Path, message: &str) {
    let _ = std::fs::create_dir_all(dir);
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("errors.log"))
    {
        let _ = writeln!(file, "{} {message}", DartDateTime::now().to_iso8601());
    }
}

/// Start a program without waiting and without a console window, outside the
/// harness's job (Windows) or process group (Unix).
pub fn spawn_detached(program: &Path, args: &[String]) -> std::io::Result<()> {
    let mut command = Command::new(program);
    command
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
        stop_inheriting_std_handles();
        // Leave the harness's job, which may kill its children when the hook
        // exits; a job that forbids breaking away refuses the flag.
        command.creation_flags(CREATE_NO_WINDOW | DETACHED_PROCESS | CREATE_BREAKAWAY_FROM_JOB);
        match command.spawn() {
            Ok(_) => return Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied => {
                command.creation_flags(CREATE_NO_WINDOW | DETACHED_PROCESS);
            }
            Err(error) => return Err(error),
        }
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        // Lead a new process group, so a harness that kills the hook's group
        // once the hook returns does not kill the detached work with it.
        command.process_group(0);
    }
    command.spawn().map(|_| ())
}

/// Windows children inherit every inheritable handle, including the pipes a
/// harness gave this process for stdout and stderr. A detached child holding
/// them would keep a harness that reads our output waiting until the child
/// exits, so this process's standard handles stop being inheritable first.
#[cfg(windows)]
fn stop_inheriting_std_handles() {
    use std::ffi::c_void;
    use std::os::windows::io::AsRawHandle;

    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn SetHandleInformation(handle: *mut c_void, mask: u32, flags: u32) -> i32;
    }
    const HANDLE_FLAG_INHERIT: u32 = 1;
    let handles = [
        std::io::stdin().as_raw_handle(),
        std::io::stdout().as_raw_handle(),
        std::io::stderr().as_raw_handle(),
    ];
    for handle in handles {
        if !handle.is_null() {
            // SAFETY: the handle is this process's own standard handle (or an
            // invalid value, which the call rejects); only its inherit flag
            // changes, and a failure leaves the previous behavior.
            unsafe {
                SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0);
            }
        }
    }
}

/// The Codex notify payload is the last argument: a JSON object with
/// `type`, `thread-id`, `turn-id`, `cwd`, ...
pub fn codex_work_item(payload: &str) -> WorkItem {
    let value: Value = serde_json::from_str(payload).unwrap_or(Value::Null);
    let text = |key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
    WorkItem {
        harness: "codex".to_owned(),
        event: text("type").unwrap_or_else(|| "notify".to_owned()),
        session_id: text("thread-id").or_else(|| text("thread_id")),
        transcript_path: None,
        cwd: text("cwd"),
        received_utc: DartDateTime::now().to_iso8601(),
        attempts: 0,
        not_before_utc: None,
        last_error: None,
    }
}

/// Claude Code hooks pass a JSON object on stdin with `session_id`,
/// `transcript_path`, `cwd`, and `hook_event_name`.
pub fn claude_work_item(input: &str) -> WorkItem {
    let value: Value = serde_json::from_str(input).unwrap_or(Value::Null);
    let text = |key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
    WorkItem {
        harness: "claude".to_owned(),
        event: text("hook_event_name").unwrap_or_else(|| "hook".to_owned()),
        session_id: text("session_id"),
        transcript_path: text("transcript_path"),
        cwd: text("cwd"),
        received_utc: DartDateTime::now().to_iso8601(),
        attempts: 0,
        not_before_utc: None,
        last_error: None,
    }
}

/// The hook event from stdin, at most [`MAX_HOOK_INPUT_BYTES`]; the rest is
/// read and discarded so the harness never blocks writing it.
pub fn read_hook_input() -> String {
    let mut stdin = std::io::stdin().lock();
    let mut input = Vec::new();
    let _ = (&mut stdin)
        .take(MAX_HOOK_INPUT_BYTES)
        .read_to_end(&mut input);
    let _ = std::io::copy(&mut stdin, &mut std::io::sink());
    String::from_utf8_lossy(&input).into_owned()
}

/// Run the previously configured Codex notify command with the same payload
/// and do not wait for it: the collector joins a notify chain, it does not
/// replace it.
pub fn run_previous_notify(previous: &str, payload: &str) -> Result<(), String> {
    let argv: Vec<String> = serde_json::from_str(previous)
        .map_err(|error| format!("--previous-notify is not a JSON array of strings: {error}"))?;
    let Some((program, args)) = argv.split_first() else {
        return Ok(());
    };
    let mut args = args.to_vec();
    args.push(payload.to_owned());
    spawn_detached(Path::new(program), &args)
        .map_err(|error| format!("previous notify {program}: {error}"))
}

// ---------------------------------------------------------------------------
// Claiming work

pub struct Claim {
    pub path: PathBuf,
    pub item: WorkItem,
}

fn claim_suffix() -> String {
    format!(".claimed-{}", std::process::id())
}

fn is_due(item: &WorkItem, now: DartDateTime) -> bool {
    item.not_before_utc
        .as_deref()
        .and_then(DartDateTime::try_parse)
        .is_none_or(|not_before| not_before <= now)
}

/// Return claims older than [`STALE_CLAIM`] to the queue and delete
/// temporary files a killed hook left behind. A claim's age counts from the
/// claim, which touches the file.
pub fn reclaim_stale(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.filter_map(Result::ok) {
        let name = entry.file_name().to_string_lossy().into_owned();
        let stale = entry
            .metadata()
            .and_then(|metadata| metadata.modified())
            .ok()
            .and_then(|modified| SystemTime::now().duration_since(modified).ok())
            .is_some_and(|age| age > STALE_CLAIM);
        if !stale {
            continue;
        }
        if let Some((base, _)) = name.split_once(".claimed-") {
            let _ = std::fs::rename(entry.path(), dir.join(base));
        } else if name.ends_with(".tmp") {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

fn queued_names(dir: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut names: Vec<String> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".json"))
        .collect();
    names.sort();
    names
}

/// Claim every due entry. The rename comes first, so the item read is the
/// one this drain owns; a rename that fails means another drain won it.
pub fn claim_due(dir: &Path) -> Vec<Claim> {
    let now = DartDateTime::now();
    let mut claims = Vec::new();
    for name in queued_names(dir) {
        let source = dir.join(&name);
        let claimed = dir.join(format!("{name}{}", claim_suffix()));
        if std::fs::rename(&source, &claimed).is_err() {
            continue;
        }
        let item: WorkItem = match std::fs::read_to_string(&claimed)
            .map_err(|error| error.to_string())
            .and_then(|text| serde_json::from_str(&text).map_err(|error| error.to_string()))
        {
            Ok(item) => item,
            Err(error) => {
                log_error(
                    dir,
                    &format!("dropped unreadable queue entry {name}: {error}"),
                );
                let _ = std::fs::remove_file(&claimed);
                continue;
            }
        };
        if !is_due(&item, now) {
            let _ = std::fs::rename(&claimed, &source);
            continue;
        }
        // Renaming keeps the old modification time; the claim's age starts now.
        let _ = std::fs::File::options()
            .write(true)
            .open(&claimed)
            .and_then(|file| file.set_modified(SystemTime::now()));
        claims.push(Claim {
            path: claimed,
            item,
        });
    }
    claims
}

/// How long until the earliest queued retry is due; `None` for an empty
/// queue. Unreadable entries count as due.
pub fn next_retry_in(dir: &Path) -> Option<Duration> {
    let now = DartDateTime::now();
    queued_names(dir)
        .into_iter()
        .map(|name| {
            std::fs::read_to_string(dir.join(name))
                .ok()
                .and_then(|text| serde_json::from_str::<WorkItem>(&text).ok())
                .and_then(|item| item.not_before_utc)
                .and_then(|text| DartDateTime::try_parse(&text))
                .map_or(Duration::ZERO, |not_before| {
                    let micros = (not_before.micros() - now.micros()).max(0);
                    Duration::from_micros(u64::try_from(micros).unwrap_or(0))
                })
        })
        .min()
}

/// The work is committed: forget the entry.
pub fn complete(claim: &Claim) {
    let _ = std::fs::remove_file(&claim.path);
}

/// Put the entry back with a retry time, or drop it after [`MAX_ATTEMPTS`].
pub fn retry(dir: &Path, claim: Claim, error: &str) {
    let mut item = claim.item;
    item.attempts += 1;
    item.last_error = Some(error.to_owned());
    if item.attempts >= MAX_ATTEMPTS {
        log_error(
            dir,
            &format!(
                "gave up on {} {:?} after {} attempts: {error}",
                item.harness, item.session_id, item.attempts
            ),
        );
        let _ = std::fs::remove_file(&claim.path);
        return;
    }
    let delay = 2i64.pow(item.attempts.min(10));
    item.not_before_utc = Some(
        DartDateTime::from_micros(DartDateTime::now().micros() + delay * 1_000_000).to_iso8601(),
    );
    let name = claim
        .path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let base = name.split(".claimed-").next().unwrap_or(&name).to_owned();
    let written = serde_json::to_string(&item)
        .map_err(std::io::Error::other)
        .and_then(|text| std::fs::write(&claim.path, text))
        .and_then(|()| std::fs::rename(&claim.path, dir.join(base)));
    if let Err(write_error) = written {
        log_error(dir, &format!("could not requeue {name}: {write_error}"));
    }
}

/// The Codex rollout of `thread_id` under the given Codex homes, newest first.
pub fn find_codex_rollout(roots: &[String], thread_id: &str) -> Option<PathBuf> {
    let suffix = format!("{thread_id}.jsonl");
    let mut found: Vec<(SystemTime, PathBuf)> = Vec::new();
    let mut folders: Vec<PathBuf> = roots.iter().map(PathBuf::from).collect();
    while let Some(folder) = folders.pop() {
        let Ok(entries) = std::fs::read_dir(&folder) else {
            continue;
        };
        for entry in entries.filter_map(Result::ok) {
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            if kind.is_dir() {
                folders.push(entry.path());
            } else if kind.is_file() && entry.file_name().to_string_lossy().ends_with(&suffix) {
                let modified = entry
                    .metadata()
                    .and_then(|metadata| metadata.modified())
                    .unwrap_or(SystemTime::UNIX_EPOCH);
                found.push((modified, entry.path()));
            }
        }
    }
    found.sort();
    found.pop().map(|(_, path)| path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn queue(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "csv-queue-{label}-{}-{}",
            std::process::id(),
            unique_name()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn item() -> WorkItem {
        claude_work_item(r#"{"session_id":"s","transcript_path":"C:\t.jsonl"}"#)
    }

    fn age(path: &Path, seconds: u64) {
        std::fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(seconds))
            .unwrap();
    }

    #[test]
    fn a_fresh_claim_of_an_old_entry_is_not_reclaimed() {
        let dir = queue("fresh-claim");
        let entry = enqueue(&dir, &item()).unwrap();
        age(&entry, 3600);
        let claims = claim_due(&dir);
        assert_eq!(claims.len(), 1);
        reclaim_stale(&dir);
        assert!(claims[0].path.exists(), "a concurrent drain took the claim");
        assert!(claim_due(&dir).is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_retry_that_is_not_due_stays_queued_and_reports_its_wait() {
        let dir = queue("not-due");
        enqueue(&dir, &item()).unwrap();
        let claim = claim_due(&dir).pop().unwrap();
        retry(&dir, claim, "still being written");
        assert!(claim_due(&dir).is_empty());
        let names = queued_names(&dir);
        assert_eq!(names.len(), 1, "the entry went back unclaimed");
        let requeued: WorkItem =
            serde_json::from_str(&std::fs::read_to_string(dir.join(&names[0])).unwrap()).unwrap();
        assert_eq!(requeued.attempts, 1);
        let wait = next_retry_in(&dir).unwrap();
        assert!(wait > Duration::from_millis(500) && wait <= Duration::from_secs(2));
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn old_temporary_files_are_removed() {
        let dir = queue("tmp");
        let leftover = dir.join("0-1.tmp");
        std::fs::write(&leftover, "{").unwrap();
        age(&leftover, 3600);
        reclaim_stale(&dir);
        assert!(!leftover.exists());
        assert_eq!(next_retry_in(&dir), None);
        let _ = std::fs::remove_dir_all(dir);
    }
}
