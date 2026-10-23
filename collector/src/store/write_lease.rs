//! Per-database collector exclusion across a public call's bounded SQLite chunks.
//! The viewer does not take this lease. Lock files are never truncated/unlinked.
use super::{StoreError, StoreResult, write_budget};
use rusqlite::Connection;
use std::{
    cell::{Cell, RefCell},
    collections::HashMap,
    fs::{File, OpenOptions, TryLockError},
    marker::PhantomData,
    path::{Path, PathBuf},
    rc::Rc,
    time::{Duration, Instant},
};
thread_local! {
    static HELD: RefCell<HashMap<usize,Held>> = RefCell::default();
    static WAIT: Cell<Option<Duration>> = const { Cell::new(None) };
    static RELEASED: Cell<Option<Instant>> = const { Cell::new(None) };
    static YIELDING: Cell<bool> = const { Cell::new(false) };
}
struct Held {
    depth: usize,
    _file: Option<File>,
    started: Instant,
    wait: Duration,
    gap: Duration,
    phase: &'static str,
}
fn key(conn: &Connection) -> usize {
    // SAFETY: opaque live SQLite handle identity, never dereferenced.
    unsafe { conn.handle() as usize }
}
pub fn lock_path(database: &Path) -> PathBuf {
    let mut name = database.as_os_str().to_owned();
    name.push(".collector.write.lock");
    PathBuf::from(name)
}
/// Scoped acquisition timeout, not a lease hold. Scans use ten minutes;
/// drains use their remaining deadline. Default is the connection busy timeout.
pub struct LeaseWait(Option<Duration>, PhantomData<Rc<()>>);
impl LeaseWait {
    pub fn enter(wait: Duration) -> Self {
        Self(WAIT.with(|v| v.replace(Some(wait))), PhantomData)
    }
}
impl Drop for LeaseWait {
    fn drop(&mut self) {
        WAIT.with(|v| v.set(self.0));
    }
}
pub(crate) struct BetweenChunks(bool);
pub(crate) fn between_chunks() -> BetweenChunks {
    BetweenChunks(YIELDING.with(|v| v.replace(true)))
}
impl Drop for BetweenChunks {
    fn drop(&mut self) {
        YIELDING.with(|v| v.set(self.0));
    }
}
pub(crate) fn held(conn: &Connection) -> bool {
    HELD.with_borrow(|v| v.contains_key(&key(conn)))
}
/// Grant owners may wait for a collector lease; the reverse order would cycle.
/// Check all handles so a nested call cannot retain an outer lease by reentrancy.
pub(crate) fn before_viewer_grant() -> StoreResult<()> {
    if HELD.with_borrow(|all| !all.is_empty()) {
        return Err(StoreError::Refused(
            "viewer grant requested while holding a collector write lease".into(),
        ));
    }
    Ok(())
}
pub fn is_busy(error: &StoreError) -> bool {
    matches!(error,StoreError::Sql(rusqlite::Error::SqliteFailure(code,_)) if code.code==rusqlite::ErrorCode::DatabaseBusy)
}
fn busy() -> StoreError {
    rusqlite::Error::SqliteFailure(
        rusqlite::ffi::Error::new(rusqlite::ffi::SQLITE_BUSY),
        Some("another collector is writing this database".into()),
    )
    .into()
}
/// Reentrant only for this live connection. Not Send; drop releases at depth zero.
pub struct WriteLease<'a> {
    conn: &'a Connection,
    _thread: PhantomData<Rc<()>>,
}
impl<'a> WriteLease<'a> {
    pub fn acquire(conn: &'a Connection) -> StoreResult<Self> {
        if YIELDING.with(Cell::get) {
            return Err(StoreError::Refused(
                "collector writer called between chunks".into(),
            ));
        }
        let nested = HELD.with_borrow_mut(|all| {
            if let Some(h) = all.get_mut(&key(conn)) {
                h.depth += 1;
                true
            } else {
                false
            }
        });
        if nested {
            return Ok(Self {
                conn,
                _thread: PhantomData,
            });
        }
        let timeout = match WAIT.with(Cell::get) {
            Some(v) => v,
            None => Duration::from_millis(u64::from(conn.query_row(
                "pragma busy_timeout",
                [],
                |r| r.get::<_, u32>(0),
            )?)),
        };
        let start = Instant::now();
        // Fairness between public calls; no SQLite lock is held while waiting.
        let gap = RELEASED.with(Cell::get).map_or(Duration::ZERO, |last| {
            write_budget::current_budget()
                .gap
                .saturating_sub(last.elapsed())
        });
        std::thread::sleep(gap);
        let poll_started = Instant::now();
        let file = match conn.path().filter(|p| !p.is_empty() && *p != ":memory:") {
            Some(path) => {
                let file = OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create(true)
                    .truncate(false)
                    .open(lock_path(Path::new(path)))?;
                loop {
                    match file.try_lock() {
                        Ok(()) => break,
                        Err(TryLockError::WouldBlock) => {
                            if start.elapsed() >= timeout {
                                return Err(busy());
                            }
                            std::thread::sleep(
                                Duration::from_millis(25)
                                    .min(timeout.saturating_sub(start.elapsed())),
                            );
                        }
                        Err(TryLockError::Error(e)) => return Err(e.into()),
                    }
                }
                Some(file)
            }
            None => None,
        };
        HELD.with_borrow_mut(|all| {
            all.insert(
                key(conn),
                Held {
                    depth: 1,
                    _file: file,
                    started: Instant::now(),
                    wait: poll_started.elapsed(),
                    gap: poll_started.saturating_duration_since(start),
                    phase: write_budget::current_phase(),
                },
            )
        });
        Ok(Self {
            conn,
            _thread: PhantomData,
        })
    }
}
impl Drop for WriteLease<'_> {
    fn drop(&mut self) {
        let released = HELD.with_borrow_mut(|all| {
            let h = all.get_mut(&key(self.conn)).expect("lease balanced");
            h.depth -= 1;
            if h.depth == 0 {
                all.remove(&key(self.conn))
            } else {
                None
            }
        });
        if let Some(h) = released {
            let hold = h.started.elapsed();
            drop(h._file);
            RELEASED.with(|v| v.set(Some(Instant::now())));
            if crate::timing::enabled() {
                eprintln!(
                    "write_lease phase={} wait_ms={:.6} hold_ms={:.6} gap_ms={:.6}",
                    h.phase,
                    h.wait.as_secs_f64() * 1000.0,
                    hold.as_secs_f64() * 1000.0,
                    h.gap.as_secs_f64() * 1000.0
                );
            }
        }
    }
}
