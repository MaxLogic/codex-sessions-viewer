//! A monotonic deadline shared by a bridge and its detached successor.
use std::io;
use std::time::{Duration, Instant};

fn ticks_ms() -> io::Result<u64> {
    #[cfg(all(test, windows))]
    if let Some(ticks) = super::bridge::deadline_tests::ticks_ms() {
        return Ok(ticks);
    }
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::Performance::{
            QueryPerformanceCounter, QueryPerformanceFrequency,
        };
        let (mut counter, mut frequency) = (0, 0);
        // SAFETY: both output pointers refer to valid local storage. QPC uses
        // one high-resolution, monotonic clock across processes on Windows.
        if unsafe { QueryPerformanceCounter(&mut counter) } == 0
            || unsafe { QueryPerformanceFrequency(&mut frequency) } == 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok((counter as u128 * 1000 / frequency as u128) as u64)
    }
    #[cfg(unix)]
    {
        let mut time = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        // SAFETY: time is valid writable storage for the whole call.
        if unsafe { libc::clock_gettime(libc::CLOCK_MONOTONIC, &mut time) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok((time.tv_sec as u64).saturating_mul(1000) + time.tv_nsec as u64 / 1_000_000)
    }
    #[cfg(not(any(windows, unix)))]
    {
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "shared monotonic clock unavailable",
        ))
    }
}

pub(super) fn now() -> Instant {
    #[cfg(all(test, windows))]
    if let Some(now) = super::bridge::deadline_tests::now() {
        return now;
    }
    Instant::now()
}

pub(super) fn remaining(deadline: Instant) -> io::Result<Duration> {
    remaining_at(deadline, now())
}

fn remaining_at(deadline: Instant, now: Instant) -> io::Result<Duration> {
    deadline
        .checked_duration_since(now)
        .filter(|duration| !duration.is_zero())
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::TimedOut,
                "resident did not release its instance lock",
            )
        })
}

pub(super) fn export(deadline: Instant) -> io::Result<u64> {
    // Read the shared clock first so conversion never grants extra startup time.
    let ticks = ticks_ms()?;
    // Reserve the rounding millisecond rather than extending the bound.
    Ok(ticks
        .saturating_add(remaining(deadline)?.as_millis() as u64)
        .saturating_sub(1))
}

pub(super) fn import(ticks: u64) -> io::Result<Instant> {
    let now = now();
    let milliseconds = ticks.saturating_sub(ticks_ms()?);
    let deadline = now + Duration::from_millis(milliseconds).min(super::STOP_TIMEOUT);
    remaining(deadline)?;
    Ok(deadline)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shutdown_boundary_uses_the_original_budget() {
        let started = Instant::now();
        let deadline = started + super::super::STOP_TIMEOUT;
        // Independent literals pin the 10 s contract. No real sleep or host
        // scheduling margin is involved in the near/at/after boundary cases.
        assert_eq!(
            remaining_at(deadline, started + Duration::from_millis(9500)).unwrap(),
            Duration::from_millis(500)
        );
        for elapsed_ms in [10000, 10500] {
            assert_eq!(
                remaining_at(deadline, started + Duration::from_millis(elapsed_ms))
                    .unwrap_err()
                    .kind(),
                io::ErrorKind::TimedOut
            );
        }
    }

    #[test]
    fn shared_deadline_cannot_restart_the_shutdown_budget() {
        let deadline = Instant::now() + Duration::from_secs(1);
        let transferred = import(export(deadline).unwrap()).unwrap();
        assert!(transferred <= deadline);
        assert!(transferred > Instant::now());
        assert_eq!(import(0).unwrap_err().kind(), io::ErrorKind::TimedOut);
    }
}
