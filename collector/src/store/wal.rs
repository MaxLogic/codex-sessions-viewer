//! Collector-owned PASSIVE checkpoints, outside physical write transactions.
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::marker::PhantomData;
use std::rc::Rc;
use std::time::{Duration, Instant};

use rusqlite::{Connection, ErrorCode, wal::CheckpointMode};

pub const CHECKPOINT_FRAMES: u32 = 1000;
pub const IDLE_CHECKPOINT: Duration = Duration::from_secs(30);

#[derive(Clone, Copy)]
pub struct WalPolicy {
    pub threshold_frames: u32,
    pub idle: Duration,
}
impl Default for WalPolicy {
    fn default() -> Self {
        Self {
            threshold_frames: CHECKPOINT_FRAMES,
            idle: IDLE_CHECKPOINT,
        }
    }
}
// Initialized once on the owning thread when its collector Store is opened.
// Release builds never read these test environment variables.
fn initial_policy() -> WalPolicy {
    #[cfg(feature = "test-hooks")]
    {
        let mut policy = WalPolicy::default();
        if let Some(frames) = std::env::var("CODEX_SESSIONS_COLLECTOR_TEST_WAL_FRAMES")
            .ok()
            .and_then(|value| value.parse::<u32>().ok())
        {
            policy.threshold_frames = frames.max(1);
        }
        if let Some(ms) = std::env::var("CODEX_SESSIONS_COLLECTOR_TEST_WAL_IDLE_MS")
            .ok()
            .and_then(|value| value.parse::<u64>().ok())
        {
            policy.idle = Duration::from_millis(ms.max(1));
        }
        policy
    }
    #[cfg(not(feature = "test-hooks"))]
    WalPolicy::default()
}
#[derive(Default)]
struct WalSeen {
    frames: u32,
    released_at: Option<Instant>,
    committed_at: Option<Instant>,
    dirty: bool,
    pending: bool,
    last_idle_attempt: Option<Instant>,
}
thread_local! {
    static POLICY: Cell<WalPolicy> = Cell::new(initial_policy());
    static SEEN: RefCell<HashMap<usize, WalSeen>> = RefCell::default();
    static TOTALS: RefCell<WalCheckpointReport> = RefCell::default();
}
/// Library-only policy override, confined to the calling worker thread.
pub struct WalPolicyScope(WalPolicy, PhantomData<Rc<()>>);
impl WalPolicyScope {
    pub fn enter(policy: WalPolicy) -> Self {
        Self(POLICY.with(|p| p.replace(policy)), PhantomData)
    }
}
impl Drop for WalPolicyScope {
    fn drop(&mut self) {
        POLICY.with(|p| p.set(self.0));
    }
}

#[derive(Clone, Debug, Default, serde::Serialize)]
pub struct WalCheckpointReport {
    pub checkpoints: u64,
    pub complete: u64,
    pub partial: u64,
    pub busy: u64,
    pub failed: u64,
    pub max_ms: f64,
    pub total_ms: f64,
    pub max_wal_frames: u32,
    pub max_tx_frames: u32,
    pub last_reason: Option<String>,
}
pub fn checkpoint_report() -> WalCheckpointReport {
    TOTALS.with_borrow(Clone::clone)
}

pub(crate) fn install(conn: &mut Connection) -> rusqlite::Result<()> {
    let key = super::write_budget::connection_key(conn);
    SEEN.with_borrow_mut(|seen| {
        seen.insert(key, WalSeen::default());
    });
    // Replaces SQLite's automatic checkpoint hook. The hook does no I/O and
    // returns success only; checkpoint errors must never turn a commit into an error.
    conn.wal_hook(Some(move |wal: &mut rusqlite::hooks::Wal, frames: i32| {
        if wal.name().to_bytes() == b"main" {
            let now = Instant::now();
            let frames = frames.max(0) as u32;
            SEEN.with_borrow_mut(|seen| {
                let state = seen.entry(key).or_default();
                state.frames = frames;
                state.released_at = Some(now);
                state.committed_at = Some(now);
                state.dirty = true;
                state.pending |= frames >= POLICY.with(Cell::get).threshold_frames;
            });
            TOTALS.with_borrow_mut(|totals| {
                totals.max_wal_frames = totals.max_wal_frames.max(frames)
            });
        }
        Ok(())
    }))
}

pub(crate) fn begin(conn: &Connection) {
    SEEN.with_borrow_mut(|seen| {
        if let Some(state) = seen.get_mut(&super::write_budget::connection_key(conn)) {
            state.released_at = None;
        }
    });
    cache_writes(conn);
}
pub(crate) fn take_release(conn: &Connection) -> Option<Instant> {
    SEEN.with_borrow_mut(|seen| {
        seen.get_mut(&super::write_budget::connection_key(conn))?
            .released_at
            .take()
    })
}
pub(crate) fn frames(conn: &Connection) -> (u32, u32) {
    let tx = cache_writes(conn);
    let wal = SEEN.with_borrow(|seen| {
        seen.get(&super::write_budget::connection_key(conn))
            .map_or(0, |s| s.frames)
    });
    TOTALS.with_borrow_mut(|totals| totals.max_tx_frames = totals.max_tx_frames.max(tx));
    (tx, wal)
}
fn cache_writes(conn: &Connection) -> u32 {
    let mut current = 0;
    let mut high = 0;
    // SAFETY: the connection is live and used only on its owning thread;
    // both out-pointers refer to initialized stack integers. Reset prevents
    // a previous transaction's writes from entering this transaction's count.
    let code = unsafe {
        rusqlite::ffi::sqlite3_db_status(
            conn.handle(),
            rusqlite::ffi::SQLITE_DBSTATUS_CACHE_WRITE,
            &mut current,
            &mut high,
            1,
        )
    };
    debug_assert_eq!(code, rusqlite::ffi::SQLITE_OK);
    current.max(0) as u32
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CheckpointResult {
    Complete,
    Partial,
    Busy,
    Failed,
    NotWal,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CheckpointOutcome {
    pub result: CheckpointResult,
    pub log_frames: i32,
    pub checkpointed_frames: i32,
}
impl CheckpointOutcome {
    fn label(self) -> &'static str {
        match self.result {
            CheckpointResult::Complete => "complete",
            CheckpointResult::Partial => "partial",
            CheckpointResult::Busy => "busy",
            CheckpointResult::Failed => "failed",
            CheckpointResult::NotWal => "not_wal",
        }
    }
}
fn classify(result: &rusqlite::Result<(i32, i32)>) -> CheckpointOutcome {
    let (kind, log_frames, checkpointed_frames) = match result {
        Ok((-1, -1)) => (CheckpointResult::NotWal, -1, -1),
        Ok((log, ckpt)) if log == ckpt => (CheckpointResult::Complete, *log, *ckpt),
        Ok((log, ckpt)) => (CheckpointResult::Partial, *log, *ckpt),
        Err(error) if error.sqlite_error_code() == Some(ErrorCode::DatabaseBusy) => {
            (CheckpointResult::Busy, -1, -1)
        }
        Err(_) => (CheckpointResult::Failed, -1, -1),
    };
    CheckpointOutcome {
        result: kind,
        log_frames,
        checkpointed_frames,
    }
}

/// Never propagates an error into an already committed ingest. PASSIVE does
/// not wait for readers or writers and does not acquire the WAL write lock.
pub fn checkpoint(conn: &Connection, reason: &'static str) -> CheckpointOutcome {
    #[cfg(debug_assertions)]
    super::write_budget::audit::checkpoint(conn);
    let start = Instant::now();
    let result = if conn.is_autocommit() {
        #[cfg(feature = "test-hooks")]
        std::thread::sleep(test_hooks::DELAY.with(Cell::get));
        conn.wal_checkpoint_v2(Some("main"), CheckpointMode::PASSIVE)
    } else {
        Err(rusqlite::Error::InvalidQuery)
    };
    let elapsed = start.elapsed().as_secs_f64() * 1000.0;
    let outcome = classify(&result);
    SEEN.with_borrow_mut(|seen| {
        if let Some(state) = seen.get_mut(&super::write_budget::connection_key(conn)) {
            if reason == "idle" {
                state.last_idle_attempt = Some(Instant::now());
            }
            if outcome.result == CheckpointResult::Complete {
                state.dirty = false;
                state.pending = false;
            }
        }
    });
    TOTALS.with_borrow_mut(|report| {
        report.checkpoints += 1;
        match outcome.result {
            CheckpointResult::Complete => report.complete += 1,
            CheckpointResult::Partial => report.partial += 1,
            CheckpointResult::Busy => report.busy += 1,
            CheckpointResult::Failed => report.failed += 1,
            CheckpointResult::NotWal => (),
        }
        report.total_ms += elapsed;
        report.max_ms = report.max_ms.max(elapsed);
        report.last_reason = Some(reason.to_owned());
    });
    if crate::timing::enabled() {
        let wal_bytes = conn
            .path()
            .and_then(|path| std::fs::metadata(format!("{path}-wal")).ok())
            .map_or(-1, |m| m.len().min(i64::MAX as u64) as i64);
        eprintln!(
            "wal_checkpoint reason={reason} phase={} result={} log_frames={} checkpointed_frames={} remaining_frames={} duration_ms={elapsed:.6} wal_bytes={wal_bytes}",
            super::write_budget::current_phase(),
            outcome.label(),
            outcome.log_frames,
            outcome.checkpointed_frames,
            (outcome.log_frames - outcome.checkpointed_frames).max(0)
        );
    }
    if let Err(error) = result
        && !matches!(
            error.sqlite_error_code(),
            Some(ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked)
        )
    {
        eprintln!("collector WAL checkpoint failed: reason={reason} error={error}");
    }
    outcome
}

pub(crate) fn committed(conn: &Connection) {
    let due = SEEN.with_borrow(|seen| {
        seen.get(&super::write_budget::connection_key(conn))
            .is_some_and(|s| s.pending)
    });
    if due && super::write_budget::check_control().is_ok() {
        checkpoint(conn, "threshold");
    }
}
pub(crate) fn idle_due(conn: &Connection, now: Instant) -> bool {
    let interval = POLICY.with(Cell::get).idle;
    SEEN.with_borrow(|seen| {
        seen.get(&super::write_budget::connection_key(conn))
            .is_some_and(|s| {
                s.dirty
                    && s.committed_at
                        .is_some_and(|at| now.saturating_duration_since(at) >= interval)
                    && s.last_idle_attempt
                        .is_none_or(|at| now.saturating_duration_since(at) >= interval)
            })
    })
}
pub(crate) fn leave_bounded(conn: &Connection) {
    let key = super::write_budget::connection_key(conn);
    let pending = SEEN.with_borrow(|seen| seen.get(&key).is_some_and(|s| s.pending));
    if pending && !std::thread::panicking() && super::write_budget::check_control().is_ok() {
        checkpoint(conn, "exit");
    }
    SEEN.with_borrow_mut(|seen| {
        seen.remove(&key);
    });
}

#[cfg(feature = "test-hooks")]
pub mod test_hooks {
    use super::*;
    pub fn with_cancelled<T>(body: impl FnOnce() -> T) -> T {
        let _control = super::super::write_budget::WriteControlScope::enter(|| true);
        body()
    }
    thread_local! { pub(super) static DELAY: Cell<Duration> = const { Cell::new(Duration::ZERO) }; }
    pub struct CheckpointDelay(Duration, PhantomData<Rc<()>>);
    pub fn checkpoint_delay(delay: Duration) -> CheckpointDelay {
        CheckpointDelay(DELAY.with(|d| d.replace(delay)), PhantomData)
    }
    impl Drop for CheckpointDelay {
        fn drop(&mut self) {
            DELAY.with(|d| d.set(self.0));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn checkpoint_outcomes_distinguish_busy_partial_and_failure() {
        for (input, expected) in [
            (Ok((12, 12)), CheckpointResult::Complete),
            (Ok((12, 4)), CheckpointResult::Partial),
            (Ok((-1, -1)), CheckpointResult::NotWal),
            (
                Err(rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_BUSY),
                    None,
                )),
                CheckpointResult::Busy,
            ),
            (
                Err(rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_LOCKED),
                    None,
                )),
                CheckpointResult::Failed,
            ),
            (
                Err(rusqlite::Error::SqliteFailure(
                    rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_IOERR),
                    None,
                )),
                CheckpointResult::Failed,
            ),
        ] {
            assert_eq!(classify(&input).result, expected);
        }
    }
    #[test]
    fn idle_due_waits_for_commit_and_limits_partial_retries() {
        crate::store::connection::ensure().unwrap();
        let conn = Connection::open_in_memory().unwrap();
        let key = super::super::write_budget::connection_key(&conn);
        let _policy = WalPolicyScope::enter(WalPolicy::default());
        let start = Instant::now();
        SEEN.with_borrow_mut(|seen| {
            seen.insert(
                key,
                WalSeen {
                    dirty: true,
                    committed_at: Some(start),
                    ..Default::default()
                },
            );
        });
        assert!(!idle_due(&conn, start + Duration::from_secs(29)));
        assert!(idle_due(&conn, start + Duration::from_secs(30)));
        SEEN.with_borrow_mut(|seen| {
            seen.get_mut(&key).unwrap().last_idle_attempt = Some(start + Duration::from_secs(30))
        });
        assert!(!idle_due(&conn, start + Duration::from_secs(59)));
        assert!(idle_due(&conn, start + Duration::from_secs(60)));
        SEEN.with_borrow_mut(|seen| seen.get_mut(&key).unwrap().dirty = false);
        assert!(!idle_due(&conn, start + Duration::from_secs(90)));
        SEEN.with_borrow_mut(|seen| {
            seen.remove(&key);
        });
    }
}
