//! Phase timings for diagnosing slow scans. Set
//! `CODEX_SESSIONS_COLLECTOR_TIMINGS=1` to print one line per phase to stderr;
//! otherwise nothing is measured or printed.

use std::sync::OnceLock;
use std::time::Instant;

fn enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| std::env::var_os("CODEX_SESSIONS_COLLECTOR_TIMINGS").is_some())
}

/// Prints the time since the previous mark, or since `start`.
pub struct Phases {
    last: Option<Instant>,
}

impl Phases {
    pub fn start() -> Self {
        Self {
            last: enabled().then(Instant::now),
        }
    }

    pub fn mark(&mut self, phase: &str) {
        if let Some(last) = self.last {
            let now = Instant::now();
            eprintln!(
                "timing {phase}: {:.1} ms",
                (now - last).as_secs_f64() * 1000.0
            );
            self.last = Some(now);
        }
    }
}

static TOTALS: std::sync::Mutex<Vec<(&'static str, std::time::Duration, u64)>> =
    std::sync::Mutex::new(Vec::new());

/// Runs `work`, adding its duration to `phase`'s running total when timings
/// are enabled. Used inside loops, where one line per call would be noise.
pub fn timed<T>(phase: &'static str, work: impl FnOnce() -> T) -> T {
    if !enabled() {
        return work();
    }
    let started = Instant::now();
    let result = work();
    let elapsed = started.elapsed();
    let mut totals = TOTALS.lock().unwrap_or_else(|poison| poison.into_inner());
    match totals.iter_mut().find(|(name, _, _)| *name == phase) {
        Some((_, total, calls)) => {
            *total += elapsed;
            *calls += 1;
        }
        None => totals.push((phase, elapsed, 1)),
    }
    result
}

/// Prints and clears the running totals of [`timed`].
pub fn report_totals() {
    if !enabled() {
        return;
    }
    let mut totals = TOTALS.lock().unwrap_or_else(|poison| poison.into_inner());
    for (phase, total, calls) in totals.drain(..) {
        eprintln!(
            "timing total {phase}: {:.1} ms in {calls} call(s)",
            total.as_secs_f64() * 1000.0
        );
    }
}
