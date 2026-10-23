//! Not shipped. Run only against an authorized database copy:
//! write_lock_probe hold|viewer --db COPY [--duration-seconds 60]
//! JSONL busy windows have 20 ms sampling resolution; viewer attempts use the
//! same 5000 ms busy timeout and app_metadata upsert as viewer startup.
use std::io::{BufWriter, Write};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use codex_sessions_collector::dart::DartDateTime;
use rusqlite::{Connection, ErrorCode, OpenFlags, params};
use serde_json::{Value, json};

fn emit(out: &mut impl Write, event: Value) -> Result<(), Box<dyn std::error::Error>> {
    writeln!(out, "{event}")?;
    out.flush()?;
    Ok(())
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(1);
    let mode = args.next().ok_or("expected hold or viewer")?;
    if !matches!(mode.as_str(), "hold" | "viewer") {
        return Err("expected hold or viewer".into());
    }
    let mut db = None;
    let mut seconds = 60u64;
    let mut stop_file = None;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--db" => db = Some(PathBuf::from(args.next().ok_or("--db needs a path")?)),
            "--duration-seconds" => {
                seconds = args.next().ok_or("duration needs seconds")?.parse()?;
            }
            "--stop-file" => {
                stop_file = Some(PathBuf::from(args.next().ok_or("stop-file needs a path")?))
            }
            _ => return Err(format!("unexpected argument {arg}").into()),
        }
    }
    if seconds == 0 {
        return Err("duration must be positive".into());
    }
    let db = db.ok_or("--db COPY is required (the probe never creates a database)")?;
    let conn = Connection::open_with_flags(
        &db,
        OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    conn.busy_timeout(Duration::from_millis(if mode == "hold" { 0 } else { 5000 }))?;
    let mut out = BufWriter::new(std::io::stdout().lock());
    emit(
        &mut out,
        json!({"event":"start", "mode":mode, "database":db,
        "os":std::env::consts::OS, "sqlite":rusqlite::version(),
        "duration_seconds":seconds, "interval_ms":if mode == "hold" {20} else {1000},
        "busy_timeout_ms":if mode == "hold" {0} else {5000}}),
    )?;
    let start = Instant::now();
    let duration = Duration::from_secs(seconds);
    let mut busy_since: Option<Instant> = None;
    let mut max_busy = Duration::ZERO;
    let mut max_wait = Duration::ZERO;
    let mut attempts = 0u64;
    let mut failures = 0u64;
    while start.elapsed() < duration && !stop_file.as_ref().is_some_and(|path| path.exists()) {
        let tick = Instant::now();
        attempts += 1;
        if mode == "hold" {
            match conn.execute_batch("begin immediate") {
                Ok(()) => {
                    conn.execute_batch("rollback")?;
                    if let Some(since) = busy_since.take() {
                        let hold = tick.duration_since(since);
                        max_busy = max_busy.max(hold);
                        emit(
                            &mut out,
                            json!({"event":"busy_window",
                            "start_ms":since.duration_since(start).as_secs_f64()*1000.0,
                            "duration_ms":hold.as_secs_f64()*1000.0, "truncated":false}),
                        )?;
                    }
                }
                Err(rusqlite::Error::SqliteFailure(code, _))
                    if matches!(
                        code.code,
                        ErrorCode::DatabaseBusy | ErrorCode::DatabaseLocked
                    ) =>
                {
                    busy_since.get_or_insert(tick);
                }
                Err(error) => return Err(error.into()),
            }
        } else {
            let now = DartDateTime::now().to_iso8601();
            let waiting = Instant::now();
            let result = conn.execute(
                "insert into app_metadata(key,value,updated_at_utc) values ('cxv178_probe',?,?)
                 on conflict(key) do update set value=excluded.value,updated_at_utc=excluded.updated_at_utc",
                params![now, now],
            );
            let wait = waiting.elapsed();
            max_wait = max_wait.max(wait);
            if result.is_err() {
                failures += 1;
            }
            emit(
                &mut out,
                json!({"event":"viewer_write",
                "elapsed_ms":tick.duration_since(start).as_secs_f64()*1000.0,
                "wait_ms":wait.as_secs_f64()*1000.0, "ok":result.is_ok(),
                "error":result.err().map(|error| error.to_string())}),
            )?;
        }
        let interval = Duration::from_millis(if mode == "hold" { 20 } else { 1000 });
        let remaining = duration.saturating_sub(start.elapsed());
        std::thread::sleep(interval.saturating_sub(tick.elapsed()).min(remaining));
    }
    if let Some(since) = busy_since {
        let hold = since.elapsed();
        max_busy = max_busy.max(hold);
        emit(
            &mut out,
            json!({"event":"busy_window",
            "start_ms":since.duration_since(start).as_secs_f64()*1000.0,
            "duration_ms":hold.as_secs_f64()*1000.0, "truncated":true}),
        )?;
    }
    emit(
        &mut out,
        json!({"event":"summary", "attempts":attempts, "failures":failures,
        "max_busy_ms":max_busy.as_secs_f64()*1000.0,
        "max_wait_ms":max_wait.as_secs_f64()*1000.0,
        "elapsed_ms":start.elapsed().as_secs_f64()*1000.0}),
    )
}

fn main() {
    if let Err(error) = run() {
        eprintln!("write_lock_probe: {error}");
        std::process::exit(1);
    }
}
