//! Single owner of collector write transactions and hold-time measurement.
use super::schema::{
    SUPPORTED_SCHEMA_VERSION, StoreError, StoreResult, check_writer_versions,
    ensure_no_pending_viewer_migration, last_applied_version,
};
use rusqlite::Connection;
use serde::Serialize;
use std::cell::RefCell;
use std::rc::Rc;
use std::time::{Duration, Instant};

#[cfg(debug_assertions)]
pub mod audit;

#[derive(Clone, Debug, Default, Serialize)]
pub struct WriteHoldReport {
    pub transactions: u64,
    pub max_ms: f64,
    pub p99_ms: f64,
    pub max_phase: Option<String>,
}

/// Bounded histogram: 1 ms buckets through 4096 ms, then 64 subdivisions per
/// power of two. p99 is the nearest-rank bucket upper bound (at most 1 ms or
/// 1/64 of its power-of-two range above the sample), capped at the exact max.
/// Recording happens after the lock is released and performs no sorting, logging or I/O.
pub struct HoldStats {
    transactions: u64,
    max: Duration,
    max_phase: Option<String>,
    histogram: Vec<u64>,
}
impl Default for HoldStats {
    fn default() -> Self {
        Self {
            transactions: 0,
            max: Duration::ZERO,
            max_phase: None,
            histogram: vec![0; 4097 + 52 * 64],
        }
    }
}
impl HoldStats {
    pub fn record(&mut self, hold: Duration, phase: &str) {
        self.transactions += 1;
        if self.max_phase.is_none() || hold > self.max {
            self.max = hold;
            self.max_phase = Some(phase.to_owned());
        }
        let ms = hold
            .as_nanos()
            .div_ceil(1_000_000)
            .min(u128::from(u64::MAX)) as u64;
        let bucket = if ms <= 4096 {
            ms as usize
        } else {
            let power = ms.ilog2();
            let base = 1u64 << power;
            let step = base / 64;
            // Exact powers of two occupy the first bucket of the next range.
            4097 + (power as usize - 12) * 64 + ((ms - base) / step) as usize
        };
        self.histogram[bucket] += 1;
    }
    pub fn report(&self) -> WriteHoldReport {
        let max_ms = self.max.as_secs_f64() * 1000.0;
        let rank = self.transactions - self.transactions / 100;
        let mut cumulative = 0;
        let mut p99_ms = 0.0;
        if rank > 0 {
            for (bucket, count) in self.histogram.iter().enumerate() {
                cumulative += count;
                if cumulative >= rank {
                    p99_ms = if bucket <= 4096 {
                        bucket as f64
                    } else {
                        let offset = bucket - 4097;
                        let base = 1u128 << (12 + offset / 64);
                        (base + base / 64 * (offset % 64 + 1) as u128 - 1) as f64
                    }
                    .min(max_ms);
                    break;
                }
            }
        }
        WriteHoldReport {
            transactions: self.transactions,
            max_ms,
            p99_ms,
            max_phase: self.max_phase.clone(),
        }
    }
}
thread_local! {
    static TOTALS: RefCell<HoldStats> = RefCell::default();
    static OBSERVERS: RefCell<Vec<HoldObserver>> = const { RefCell::new(Vec::new()) };
    static PHASE: RefCell<&'static str> = const { RefCell::new("unlabelled") };
    static ACTIVE: RefCell<std::collections::HashMap<usize, (Instant, &'static str)>> = RefCell::default();
}
struct HoldObserver {
    stats: Rc<RefCell<HoldStats>>,
    phase: Option<&'static str>,
}

/// Preserve rollback-on-unwind for callers formerly using rusqlite::Transaction.
pub(crate) struct PanicRollback<'a>(&'a Connection);
pub(crate) fn rollback_on_panic(conn: &Connection) -> PanicRollback<'_> {
    PanicRollback(conn)
}
impl Drop for PanicRollback<'_> {
    fn drop(&mut self) {
        if std::thread::panicking() && !self.0.is_autocommit() {
            let _ = self.0.execute_batch("rollback");
            complete_hold(self.0);
        }
    }
}

/// Cumulative physical write holds on the current collector worker thread.
pub fn hold_report() -> WriteHoldReport {
    TOTALS.with_borrow(HoldStats::report)
}

/// Thread-local capture; nested captures independently observe the same physical transactions.
pub struct WriteHoldScope(Rc<RefCell<HoldStats>>);
impl WriteHoldScope {
    pub fn start() -> Self {
        Self::capture(None)
    }
    /// Capture one phase independently of other work on this worker thread.
    pub fn for_phase(phase: &'static str) -> Self {
        Self::capture(Some(phase))
    }
    fn capture(phase: Option<&'static str>) -> Self {
        let stats = Rc::new(RefCell::new(HoldStats::default()));
        OBSERVERS.with_borrow_mut(|observers| {
            observers.push(HoldObserver {
                stats: stats.clone(),
                phase,
            })
        });
        Self(stats)
    }
    pub fn report(&self) -> WriteHoldReport {
        self.0.borrow().report()
    }
}
impl Drop for WriteHoldScope {
    fn drop(&mut self) {
        OBSERVERS.with_borrow_mut(|observers| observers.retain(|s| !Rc::ptr_eq(&s.stats, &self.0)));
    }
}
pub struct WritePhase(&'static str, std::marker::PhantomData<Rc<()>>);
pub fn write_phase(phase: &'static str) -> WritePhase {
    WritePhase(
        PHASE.with_borrow_mut(|current| std::mem::replace(current, phase)),
        std::marker::PhantomData,
    )
}
impl Drop for WritePhase {
    fn drop(&mut self) {
        PHASE.with_borrow_mut(|phase| *phase = self.0);
    }
}
/// Schema bootstrap and the price-history database have their own validation contracts.
/// They still use this same measured BEGIN IMMEDIATE owner.
pub(crate) fn begin_immediate(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch("begin immediate")?;
    let start = Instant::now();
    let phase = PHASE.with_borrow(|phase| *phase);
    #[cfg(debug_assertions)]
    audit::check_replaced_owner(conn);
    ACTIVE.with_borrow_mut(|active| active.insert(connection_key(conn), (start, phase)));
    Ok(())
}
pub(crate) fn complete_hold(conn: &Connection) {
    if !conn.is_autocommit() {
        return;
    }
    if let Some((start, phase)) =
        ACTIVE.with_borrow_mut(|active| active.remove(&connection_key(conn)))
    {
        let elapsed = start.elapsed();
        TOTALS.with_borrow_mut(|stats| stats.record(elapsed, phase));
        OBSERVERS.with_borrow(|observers| {
            for observer in observers {
                if observer.phase.is_none_or(|filter| filter == phase) {
                    observer.stats.borrow_mut().record(elapsed, phase);
                }
            }
        });
        #[cfg(debug_assertions)]
        audit::completed(conn);
    }
}
thread_local! {
    /// The connection whose outer transaction `in_write_transaction` owns on
    /// this thread (its address, 0 for none). Writers on that connection use
    /// a savepoint inside it; any other connection starts its own checked
    /// transaction.
    static OUTER_WRITE: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

fn connection_key(conn: &Connection) -> usize {
    // SAFETY: only use the live connection's SQLite handle as an opaque
    // identity; never dereference it. Unlike &Connection this survives moves.
    unsafe { conn.handle() as usize }
}

/// Measure an operation SQLite requires outside BEGIN (for example changing
/// journal_mode). The elapsed sample conservatively includes any lock wait:
/// SQLite does not expose its internal lock-acquisition instant for this path.
/// Record failed attempts too, since they may acquire/release a lock internally.
pub(crate) fn outside_transaction<T>(
    conn: &Connection,
    phase: &'static str,
    body: impl FnOnce() -> rusqlite::Result<T>,
) -> rusqlite::Result<T> {
    if !conn.is_autocommit() {
        return Err(rusqlite::Error::InvalidQuery);
    }
    #[cfg(debug_assertions)]
    audit::check_replaced_owner(conn);
    ACTIVE.with_borrow_mut(|active| {
        active.insert(connection_key(conn), (Instant::now(), phase));
    });
    struct Complete<'a>(&'a Connection);
    impl Drop for Complete<'_> {
        fn drop(&mut self) {
            complete_hold(self.0);
        }
    }
    let _complete = Complete(conn);
    body()
}

/// Marks `conn` as owning the outer write for its lifetime. Dropping it
/// restores the previous owner, also when the body panics; a panic rolls the
/// outer transaction back, since `finish` never runs.
struct OuterWrite<'a> {
    conn: &'a Connection,
    previous: usize,
}

impl<'a> OuterWrite<'a> {
    fn enter(conn: &'a Connection) -> Self {
        let previous = OUTER_WRITE.with(|outer| outer.replace(connection_key(conn)));
        Self { conn, previous }
    }
}

impl Drop for OuterWrite<'_> {
    fn drop(&mut self) {
        OUTER_WRITE.with(|outer| outer.set(self.previous));
        if std::thread::panicking() {
            let _ = self.conn.execute_batch("rollback");
            complete_hold(self.conn);
        }
    }
}

/// Runs several writers in one transaction: either all of their changes
/// commit together or none do. Used by hub ingestion so that the applied
/// records and the received-batch row are atomic.
pub fn in_write_transaction<T>(
    conn: &Connection,
    body: impl FnOnce() -> StoreResult<T>,
) -> StoreResult<T> {
    begin_write(conn)?;
    let outer = OuterWrite::enter(conn);
    let result = body();
    drop(outer);
    finish(conn, result)
}

fn nested_write(conn: &Connection) -> bool {
    OUTER_WRITE.with(std::cell::Cell::get) == connection_key(conn)
}

/// Start a write and re-check, under the write lock, that the database is
/// still at this collector's schema with no viewer migration pending. The
/// check at open is not enough: a newer viewer can migrate the database
/// between two batches of a long scan. Inside `in_write_transaction` (same
/// thread and connection) it opens a savepoint in the outer transaction.
pub fn begin_write(conn: &Connection) -> StoreResult<()> {
    if nested_write(conn) {
        conn.execute_batch("savepoint nested_write")?;
        return Ok(());
    }
    begin_immediate(conn)?;
    let check = (|| -> StoreResult<()> {
        let version = last_applied_version(conn)?;
        if version != SUPPORTED_SCHEMA_VERSION {
            return Err(StoreError::Refused(format!(
                "The database moved to schema version {version} while collecting; this collector writes schema {SUPPORTED_SCHEMA_VERSION}. Use a collector from the same release as the viewer."
            )));
        }
        ensure_no_pending_viewer_migration(conn)?;
        check_writer_versions(conn)
    })();
    if let Err(error) = check {
        let _ = conn.execute_batch("rollback");
        complete_hold(conn);
        return Err(error);
    }
    Ok(())
}

/// Commit on success, roll back on failure, keeping the first error.
pub fn finish<T>(conn: &Connection, result: StoreResult<T>) -> StoreResult<T> {
    if nested_write(conn) {
        return match result {
            Ok(value) => {
                conn.execute_batch("release nested_write")?;
                Ok(value)
            }
            Err(error) => {
                let _ = conn.execute_batch("rollback to nested_write; release nested_write");
                Err(error)
            }
        };
    }
    finish_immediate(conn, result, StoreError::from)
}

/// Complete a measured transaction with the caller's existing error type.
/// A commit failure rolls back before recording; the first error is retained.
pub(crate) fn finish_immediate<T, E>(
    conn: &Connection,
    result: Result<T, E>,
    sql_error: impl FnOnce(rusqlite::Error) -> E,
) -> Result<T, E> {
    let finished = match result {
        Ok(value) => match conn.execute_batch("commit") {
            Ok(()) => Ok(value),
            Err(error) => {
                let _ = conn.execute_batch("rollback");
                Err(sql_error(error))
            }
        },
        Err(error) => {
            let _ = conn.execute_batch("rollback");
            Err(error)
        }
    };
    complete_hold(conn);
    finished
}

/// Execute one DML/DDL statement through the write owner. Existing outer
/// transactions own the sample; standalone statements get their own hold.
pub fn execute_write(
    conn: &Connection,
    phase: &'static str,
    sql: &str,
    params: impl rusqlite::Params,
) -> StoreResult<usize> {
    if !conn.is_autocommit() {
        return Ok(conn.execute(sql, params)?);
    }
    let _phase = write_phase(phase);
    in_write_transaction(conn, || Ok(conn.execute(sql, params)?))
}
