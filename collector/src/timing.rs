//! Phase timings for diagnosing slow scans. Set
//! `CODEX_SESSIONS_COLLECTOR_TIMINGS=1` to print one line per phase to stderr;
//! otherwise nothing is measured or printed. Where the platform reports it, a
//! phase line also carries the bytes this process read and wrote during it
//! (session files and the database alike).

use std::sync::OnceLock;
use std::time::Instant;

pub(crate) fn enabled() -> bool {
    static ENABLED: OnceLock<bool> = OnceLock::new();
    *ENABLED.get_or_init(|| std::env::var_os("CODEX_SESSIONS_COLLECTOR_TIMINGS").is_some())
}

/// Prints the time since the previous mark, or since `start`.
pub struct Phases {
    last: Option<(Instant, Option<(u64, u64)>)>,
}

impl Phases {
    pub fn start() -> Self {
        Self {
            last: enabled().then(|| (Instant::now(), io_counters())),
        }
    }

    pub fn mark(&mut self, phase: &str) {
        if let Some((last, io)) = self.last {
            let now = Instant::now();
            let current = io_counters();
            let bytes = match (io, current) {
                (Some((read, written)), Some((read_now, written_now))) => format!(
                    " read={:.1} MB written={:.2} MB",
                    read_now.saturating_sub(read) as f64 / 1_048_576.0,
                    written_now.saturating_sub(written) as f64 / 1_048_576.0
                ),
                _ => String::new(),
            };
            eprintln!(
                "timing {phase}: {:.1} ms{bytes}",
                (now - last).as_secs_f64() * 1000.0
            );
            self.last = Some((now, current));
        }
    }
}

/// Bytes this process has read and written so far, all files included.
#[cfg(windows)]
fn io_counters() -> Option<(u64, u64)> {
    use windows_sys::Win32::System::Threading::{
        GetCurrentProcess, GetProcessIoCounters, IO_COUNTERS,
    };
    // SAFETY: the pseudo handle needs no closing; the struct is plain data.
    unsafe {
        let mut counters: IO_COUNTERS = std::mem::zeroed();
        (GetProcessIoCounters(GetCurrentProcess(), &mut counters) != 0)
            .then_some((counters.ReadTransferCount, counters.WriteTransferCount))
    }
}

/// Bytes this process has read and written so far, all files included.
#[cfg(not(windows))]
fn io_counters() -> Option<(u64, u64)> {
    let io = std::fs::read_to_string("/proc/self/io").ok()?;
    let field = |name: &str| {
        io.lines()
            .find_map(|line| line.strip_prefix(name)?.trim().parse().ok())
    };
    Some((field("rchar:")?, field("wchar:")?))
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
