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

#[derive(Clone, Copy, Debug)]
pub struct WriteBudget {
    pub soft: Duration,
    pub hard: Duration,
    pub gap: Duration,
}
impl Default for WriteBudget {
    fn default() -> Self {
        Self {
            soft: Duration::from_millis(250),
            hard: Duration::from_millis(1000),
            gap: Duration::from_millis(150),
        }
    }
}
thread_local! {
    static BUDGET: std::cell::Cell<WriteBudget> = std::cell::Cell::new(WriteBudget::default());
    // One worker, including consecutive phases and parse-side batches. Do not
    // key by a raw connection address that SQLite can reuse after close.
    static RELEASED: std::cell::Cell<Option<Instant>> = const { std::cell::Cell::new(None) };
    static COMPLETION_TIME: std::cell::Cell<Duration> = const { std::cell::Cell::new(Duration::ZERO) };
    static SESSION_SHAPE: std::cell::Cell<Option<SessionWriteShape>> = const { std::cell::Cell::new(None) };
    static CHUNK_OBSERVER: RefCell<Option<Box<ChunkObserver>>> = const { RefCell::new(None) };
}

type ChunkObserver = dyn FnMut(&'static str);
/// Library-only deterministic interleaving witness. Called after COMMIT and
/// SQLite lock release; a fixture may perform raw viewer SQL here. Collector
/// API calls are forbidden until the public writer call returns.
pub struct WriteChunkScope(Option<Box<ChunkObserver>>, std::marker::PhantomData<Rc<()>>);
impl WriteChunkScope {
    pub fn observe(observer: impl FnMut(&'static str) + 'static) -> Self {
        Self(
            CHUNK_OBSERVER.with_borrow_mut(|current| current.replace(Box::new(observer))),
            std::marker::PhantomData,
        )
    }
}
impl Drop for WriteChunkScope {
    fn drop(&mut self) {
        CHUNK_OBSERVER.with_borrow_mut(|current| *current = self.0.take());
    }
}

/// Optional diagnostics, computed from the immutable snapshot outside the lock.
#[derive(Clone, Copy)]
pub(crate) struct SessionWriteShape {
    pub messages: usize,
    pub tool_calls: usize,
    pub source_bytes: u64,
    pub content_bytes: usize,
}

pub(crate) fn record_session_shape(shape: Option<SessionWriteShape>) {
    SESSION_SHAPE.with(|current| current.set(shape));
}
/// Library-only override for deterministic chunking proof; never an environment knob.
pub struct WriteBudgetScope(WriteBudget, std::marker::PhantomData<Rc<()>>);
impl WriteBudgetScope {
    pub fn enter(budget: WriteBudget) -> Self {
        Self(
            BUDGET.with(|current| current.replace(budget)),
            std::marker::PhantomData,
        )
    }
}
impl Drop for WriteBudgetScope {
    fn drop(&mut self) {
        BUDGET.with(|current| current.set(self.0));
    }
}

/// Apply independently valid units, yielding at time and row boundaries. Setup
/// must be constant-time or indexed. Empty work never starts a transaction.
pub fn write_chunked<U, S>(
    conn: &Connection,
    phase: &'static str,
    budget: WriteBudget,
    max_units: usize,
    units: impl IntoIterator<Item = U>,
    mut setup: impl FnMut() -> StoreResult<S>,
    mut apply: impl FnMut(&mut S, U) -> StoreResult<()>,
) -> StoreResult<()> {
    let _budget = WriteBudgetScope::enter(budget);
    let _phase = write_phase(phase);
    let mut units = units.into_iter().peekable();
    while units.peek().is_some() {
        SESSION_SHAPE.with(|current| current.set(None));
        begin_write(conn)?;
        let _rollback = rollback_on_panic(conn);
        let owner_started =
            ACTIVE.with_borrow(|active| active.get(&connection_key(conn)).map(|value| value.0));
        let validation_time = owner_started.map_or(Duration::ZERO, |started| started.elapsed());
        let gap = owner_started.and_then(|started| {
            RELEASED.with(|last| {
                last.get()
                    .map(|released| started.saturating_duration_since(released))
            })
        });
        let start = Instant::now();
        let mut count = 0;
        let mut largest = Duration::ZERO;
        let mut setup_time = Duration::ZERO;
        let mut apply_time = Duration::ZERO;
        let result = (|| {
            let setup_start = Instant::now();
            let mut state = setup()?;
            setup_time = setup_start.elapsed();
            for _ in 0..max_units.max(1) {
                let Some(unit) = units.next() else { break };
                let unit_start = Instant::now();
                apply(&mut state, unit)?;
                let elapsed = unit_start.elapsed();
                largest = largest.max(elapsed);
                apply_time += elapsed;
                count += 1;
                if start.elapsed() >= budget.soft {
                    break;
                }
            }
            Ok(())
        })();
        finish(conn, result)?;
        if crate::timing::enabled() {
            eprintln!(
                "write_chunk phase={phase} units={count} largest_unit_ms={:.3} elapsed_ms={:.3}",
                largest.as_secs_f64() * 1000.0,
                start.elapsed().as_secs_f64() * 1000.0,
            );
            let shape = SESSION_SHAPE.with(std::cell::Cell::get);
            eprintln!(
                "write_detail phase={phase} setup_ms={:.6} apply_ms={:.6} commit_ms={:.6} gap_ms={:.6} required_gap_ms={:.6} messages={} tool_calls={} source_bytes={} content_bytes={}",
                (validation_time + setup_time).as_secs_f64() * 1000.0,
                apply_time.as_secs_f64() * 1000.0,
                COMPLETION_TIME.with(std::cell::Cell::get).as_secs_f64() * 1000.0,
                gap.map_or(-1.0, |elapsed| elapsed.as_secs_f64() * 1000.0),
                budget.gap.as_secs_f64() * 1000.0,
                shape.map_or(0, |shape| shape.messages),
                shape.map_or(0, |shape| shape.tool_calls),
                shape.map_or(0, |shape| shape.source_bytes),
                shape.map_or(0, |shape| shape.content_bytes),
            );
        }
        let _yielding = super::write_lease::between_chunks();
        if units.peek().is_some() {
            wait_for_gap();
        }
        // Observer code may perform raw viewer SQL; collector API calls are
        // refused by the between-chunk fence even on this same connection.
        if let Some(mut observer) = CHUNK_OBSERVER.with_borrow_mut(Option::take) {
            observer(phase);
            CHUNK_OBSERVER.with_borrow_mut(|current| *current = Some(observer));
        }
    }
    Ok(())
}

pub(crate) fn current_phase() -> &'static str {
    PHASE.with_borrow(|p| *p)
}

pub fn current_budget() -> WriteBudget {
    BUDGET.with(std::cell::Cell::get)
}

/// Plan once inside the caller's collector lease, outside SQLite's write lock.
/// Only viewer V-set edits may interleave; every dependent value must be read
/// or guarded in each unit's own statements. Never copy viewer values from a
/// plan. Model earlier units of this same call when planning ordered inputs.
pub(crate) fn write_planned<U>(
    conn: &Connection,
    phase: &'static str,
    max_units: usize,
    plan: impl FnOnce() -> StoreResult<Vec<U>>,
    mut apply: impl FnMut(U) -> StoreResult<()>,
) -> StoreResult<()> {
    let _lease = super::write_lease::WriteLease::acquire(conn)?;
    let units = plan()?;
    write_chunked(
        conn,
        phase,
        current_budget(),
        max_units,
        units,
        || Ok(()),
        |_, unit| apply(unit),
    )
}

#[cfg(debug_assertions)]
pub mod audit;

#[derive(Clone, Debug, Default, Serialize)]
pub struct WriteHoldReport {
    pub transactions: u64,
    pub max_ms: f64,
    pub p99_ms: f64,
    pub max_phase: Option<String>,
    pub over_budget: u64,
    /// Largest indivisible session application, excluding shared setup/commit.
    /// The sessions-phase max hold is its conservative bound including commit.
    pub max_session_ms: f64,
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
    over_budget: u64,
    max_session: Duration,
}
impl Default for HoldStats {
    fn default() -> Self {
        Self {
            transactions: 0,
            max: Duration::ZERO,
            max_phase: None,
            histogram: vec![0; 4097 + 52 * 64],
            over_budget: 0,
            max_session: Duration::ZERO,
        }
    }
}
impl HoldStats {
    pub fn record(&mut self, hold: Duration, phase: &str) {
        self.transactions += 1;
        if hold > current_budget().hard {
            self.over_budget += 1;
        }
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
            over_budget: self.over_budget,
            max_session_ms: self.max_session.as_secs_f64() * 1000.0,
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

pub(crate) fn record_session_unit(elapsed: Duration) {
    TOTALS.with_borrow_mut(|stats| stats.max_session = stats.max_session.max(elapsed));
    OBSERVERS.with_borrow(|observers| {
        for observer in observers {
            if observer.phase.is_none_or(|phase| phase == "sessions") {
                let mut stats = observer.stats.borrow_mut();
                stats.max_session = stats.max_session.max(elapsed);
            }
        }
    });
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
        RELEASED.with(|last| last.set(Some(Instant::now())));
        if crate::timing::enabled() {
            eprintln!(
                "write_hold phase={phase} hold_ms={:.6}",
                elapsed.as_secs_f64() * 1000.0
            );
        }
        if elapsed > current_budget().hard {
            eprintln!(
                "collector write hold exceeded hard budget: phase={phase} hold_ms={:.3}",
                elapsed.as_secs_f64() * 1000.0
            );
        }
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
    let _lease = super::write_lease::WriteLease::acquire(conn)?;
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
    if !super::write_lease::held(conn) {
        return Err(StoreError::Refused(
            "collector write requires a writer lease".into(),
        ));
    }
    wait_for_gap();
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

fn wait_for_gap() {
    if let Some(released) = RELEASED.with(std::cell::Cell::get) {
        std::thread::sleep(current_budget().gap.saturating_sub(released.elapsed()));
    }
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
    let completion_start = Instant::now();
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
    COMPLETION_TIME.with(|elapsed| elapsed.set(completion_start.elapsed()));
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
    let _lease = super::write_lease::WriteLease::acquire(conn)?;
    if !conn.is_autocommit() {
        return Ok(conn.execute(sql, params)?);
    }
    let _phase = write_phase(phase);
    in_write_transaction(conn, || Ok(conn.execute(sql, params)?))
}
