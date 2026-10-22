//! Command-line interface. `run` returns the process exit code.
//!
//! Exit codes: 0 success, 1 failure, 2 usage error, 3 database refused
//! (ownership, schema version, or a pending viewer migration).

use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};

use rusqlite::OptionalExtension;
use serde_json::json;

use crate::codex::parser::{ParserOptions, SourceType, parse_file};
use crate::codex::scanner::{
    DEFAULT_WSL_ROOT_RETRY_DELAYS, ScanOptions, ScanRoot, session_scan_roots,
};
use crate::codex::session_index::read_thread_names;
use crate::codex::{self, CollectReport};
use crate::contract::{self, Envelope, Record, SourceStatus};
use crate::path_mapping::{PathMapper, canonical_scan_path, is_path_under_root};
use crate::settings::{CollectorSettings, default_settings_file, default_viewer_database};
use crate::store::{ApplySummary, OwnerMode, Store, StoreError};

const USAGE: &str = "\
codex-sessions-collector: collect local coding-agent sessions into the Codex Sessions Viewer database.

USAGE:
  codex-sessions-collector <codex|claude> setup [--apply] [--remove] [DIAGNOSTIC OPTIONS]
  codex-sessions-collector <codex|claude> verify [--local-proof] [--check-hub] [DIAGNOSTIC OPTIONS]
  codex-sessions-collector <codex|claude> status [DIAGNOSTIC OPTIONS]
  codex-sessions-collector codex scan   [OPTIONS]         Scan the configured Codex homes
  codex-sessions-collector codex ingest [OPTIONS] <FILE>  Ingest one Codex session file
  codex-sessions-collector codex parse  [OPTIONS] <FILE>  Print one file as contract records
  codex-sessions-collector codex notify [--previous-notify <JSON>] <PAYLOAD>
                                                          Codex notify hook: queue the turn's session
  codex-sessions-collector claude scan   [OPTIONS]        Scan Claude Code transcripts (SCAN and CLAUDE OPTIONS)
  codex-sessions-collector claude ingest [OPTIONS] <FILE> Ingest one transcript and its subagents
  codex-sessions-collector claude parse  <FILE>           Print one transcript as contract records
  codex-sessions-collector claude hook                    Claude Code hook (JSON on stdin): queue it
  codex-sessions-collector drain  [OPTIONS]               Ingest queued hook work
  codex-sessions-collector apply  [OPTIONS] [--input <FILE>]  Apply contract records (stdin by default)
  codex-sessions-collector query <COMMAND> [OPTIONS]      Read-only history queries (query --help)
  codex-sessions-collector hub enable --hub-url <URL> [DATABASE OPTIONS]
  codex-sessions-collector hub sync [DATABASE OPTIONS]    Deliver queued records
  codex-sessions-collector hub status [DATABASE OPTIONS]  Show delivery state and rejected records
  codex-sessions-collector hub resync [DATABASE OPTIONS]  Continue from the hub's last accepted sequence
  codex-sessions-collector hub disable [DATABASE OPTIONS] Stop queuing and clear the outbox
  codex-sessions-collector version
  codex-sessions-collector serve [OPTIONS] [--lifetime resident|viewer]
  codex-sessions-collector resident <stop|status|info> [--db <FILE>]

DATABASE OPTIONS:
  --db <FILE>           Viewer database (default: platform user data folder)
  --standalone <FILE>   Collector-owned database; created and migrated by the collector

DIAGNOSTIC OPTIONS:
  --root <DIR>         Harness session root (repeatable)
  --config <FILE>      Harness configuration file (Codex TOML / Claude JSON)
  --json               Machine-readable report; setup previews by default
  --hub-url <URL>      Explicit verify endpoint; only --check-hub makes a request

SCAN OPTIONS:
  --settings <FILE>     Viewer settings.toml (default: platform user config folder)
  --windows-root <DIR>  Windows Codex home or sessions folder (overrides settings)
  --wsl-root <DIR>      WSL Codex home as a \\\\wsl.localhost path (overrides settings)
  --wsl-unc-root <DIR>  WSL file-system root, e.g. \\\\wsl.localhost\\Ubuntu\\
  --no-wsl-projects     Do not ask wsl.exe for git project names
  --force               Reparse unchanged files
  --parser-workers <N>  Parallel parsers (default: CPU count - 1, at most 8)
  --json                Print a machine-readable summary
  --progress-json       Stream progress JSON lines (at most one per 100 ms) before the summary
  --cancel-stdin        Gracefully cancel when stdin receives cancel or closes
  --coordinate-writes  Request a GUI writer lease before each database batch
  --flush-sessions <N>  Sessions per persistence batch (default: 64)
  --flush-bytes <N>     Source bytes per persistence batch (default: 8388608)

CLAUDE OPTIONS:
  --claude-root <DIR>     Claude projects folder (default: %USERPROFILE%\\.claude\\projects); repeatable
  --claude-wsl-root <DIR> A WSL Claude projects folder as a \\\\wsl.localhost path; repeatable

HOOK OPTIONS:
  --previous-notify <JSON>  The notify command this one replaced, as a JSON array; it still runs
  --no-drain                Queue the work but do not start a drain
  --no-wait                 drain: handle what is due now instead of waiting for retries
Hooks exit 0 even when they fail; problems go to errors.log in the queue folder
(CODEX_SESSIONS_COLLECTOR_QUEUE, default: platform user cache folder).
Hub sync reads CODEX_SESSIONS_HUB_MACHINE_TOKEN from the environment. Schedule it
separately; local collection never waits for network delivery.
";

struct Options {
    lifetime: crate::resident::Lifetime,
    db: Option<PathBuf>,
    standalone: Option<PathBuf>,
    settings: Option<PathBuf>,
    windows_root: Option<String>,
    wsl_root: Option<String>,
    wsl_unc_root: Option<String>,
    wsl_projects: bool,
    force: bool,
    parser_workers: Option<usize>,
    json: bool,
    progress_json: bool,
    cancel_stdin: bool,
    coordinate_writes: bool,
    flush_sessions: usize,
    flush_bytes: u64,
    input: Option<PathBuf>,
    positional: Vec<String>,
    previous_notify: Option<String>,
    no_drain: bool,
    no_wait: bool,
    claude_roots: Vec<String>,
    claude_wsl_roots: Vec<String>,
    hub_url: Option<String>,
}

enum CliError {
    Usage(String),
    Failed(String),
    Refused(String),
}

impl From<StoreError> for CliError {
    fn from(error: StoreError) -> Self {
        match error {
            StoreError::Refused(message) => Self::Refused(message),
            other => Self::Failed(other.to_string()),
        }
    }
}

fn parse_options(args: &[String]) -> Result<Options, CliError> {
    let mut options = Options {
        lifetime: crate::resident::Lifetime::Resident,
        db: None,
        standalone: None,
        settings: None,
        windows_root: None,
        wsl_root: None,
        wsl_unc_root: None,
        wsl_projects: true,
        force: false,
        parser_workers: None,
        json: false,
        progress_json: false,
        cancel_stdin: false,
        coordinate_writes: false,
        flush_sessions: codex::FLUSH_SESSIONS,
        flush_bytes: codex::FLUSH_SOURCE_BYTES,
        input: None,
        positional: Vec::new(),
        previous_notify: None,
        no_drain: false,
        no_wait: false,
        claude_roots: Vec::new(),
        claude_wsl_roots: Vec::new(),
        hub_url: None,
    };
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        let mut value = |name: &str| {
            iter.next()
                .cloned()
                .ok_or_else(|| CliError::Usage(format!("{name} needs a value")))
        };
        match arg.as_str() {
            "--lifetime" => {
                options.lifetime = match value("--lifetime")?.as_str() {
                    "resident" => crate::resident::Lifetime::Resident,
                    "viewer" => crate::resident::Lifetime::Viewer,
                    _ => {
                        return Err(CliError::Usage(
                            "--lifetime must be resident or viewer".into(),
                        ));
                    }
                }
            }
            "--db" => options.db = Some(PathBuf::from(value("--db")?)),
            "--standalone" => options.standalone = Some(PathBuf::from(value("--standalone")?)),
            "--settings" => options.settings = Some(PathBuf::from(value("--settings")?)),
            "--windows-root" => options.windows_root = Some(value("--windows-root")?),
            "--wsl-root" => options.wsl_root = Some(value("--wsl-root")?),
            "--wsl-unc-root" => options.wsl_unc_root = Some(value("--wsl-unc-root")?),
            "--input" => options.input = Some(PathBuf::from(value("--input")?)),
            "--hub-url" => options.hub_url = Some(value("--hub-url")?),
            "--parser-workers" => {
                let text = value("--parser-workers")?;
                let count: usize =
                    text.parse()
                        .ok()
                        .filter(|count| *count > 0)
                        .ok_or_else(|| {
                            CliError::Usage(format!(
                                "--parser-workers must be a positive number, not {text:?}"
                            ))
                        })?;
                options.parser_workers = Some(count);
            }
            "--flush-sessions" => {
                options.flush_sessions = value("--flush-sessions")?
                    .parse()
                    .ok()
                    .filter(|v| *v > 0)
                    .ok_or_else(|| CliError::Usage("--flush-sessions must be positive".into()))?
            }
            "--flush-bytes" => {
                options.flush_bytes = value("--flush-bytes")?
                    .parse()
                    .ok()
                    .filter(|v| *v > 0)
                    .ok_or_else(|| CliError::Usage("--flush-bytes must be positive".into()))?
            }
            "--previous-notify" => options.previous_notify = Some(value("--previous-notify")?),
            "--claude-root" => options.claude_roots.push(value("--claude-root")?),
            "--claude-wsl-root" => options.claude_wsl_roots.push(value("--claude-wsl-root")?),
            "--no-drain" => options.no_drain = true,
            "--no-wait" => options.no_wait = true,
            "--no-wsl-projects" => options.wsl_projects = false,
            "--force" => options.force = true,
            "--json" => options.json = true,
            "--progress-json" => {
                options.progress_json = true;
                options.json = true;
            }
            "--cancel-stdin" => options.cancel_stdin = true,
            "--coordinate-writes" => {
                options.coordinate_writes = true;
                options.cancel_stdin = true;
                options.progress_json = true;
                options.json = true;
            }
            flag if flag.starts_with("--") => {
                return Err(CliError::Usage(format!("unknown option {flag}")));
            }
            positional => options.positional.push(positional.to_owned()),
        }
    }
    if options.db.is_some() && options.standalone.is_some() {
        return Err(CliError::Usage(
            "use either --db or --standalone, not both".to_owned(),
        ));
    }
    Ok(options)
}

pub fn run(args: &[String]) -> i32 {
    let mut stdout = std::io::stdout().lock();
    let mut stderr = std::io::stderr().lock();
    let command: Vec<&str> = args.iter().take(2).map(String::as_str).collect();
    let result = match command.as_slice() {
        ["serve", ..] => parse_options(&args[1..]).and_then(|options| {
            if options.standalone.is_some() || !options.positional.is_empty() {
                return Err(CliError::Usage(
                    "serve needs --db and no positional arguments or --standalone".into(),
                ));
            }
            let database = options.db.or_else(default_viewer_database).ok_or_else(|| {
                CliError::Usage("database location unavailable; pass --db".into())
            })?;
            crate::resident::run(&database, options.lifetime).map_err(|error| {
                if error.kind() == std::io::ErrorKind::PermissionDenied {
                    CliError::Refused(error.to_string())
                } else {
                    CliError::Failed(error.to_string())
                }
            })
        }),
        ["resident", action @ ("stop" | "status" | "info")] => {
            parse_options(&args[2..]).and_then(|options| {
                if options.standalone.is_some() || !options.positional.is_empty() {
                    return Err(CliError::Usage(
                        "resident needs --db and no positional arguments or --standalone".into(),
                    ));
                }
                let database = options.db.or_else(default_viewer_database).ok_or_else(|| {
                    CliError::Usage("database location unavailable; pass --db".into())
                })?;
                let reply = crate::resident::control(&database, action)
                    .map_err(|error| CliError::Failed(error.to_string()))?;
                writeln!(stdout, "{reply}").map_err(|error| CliError::Failed(error.to_string()))
            })
        }
        [
            harness @ ("codex" | "claude"),
            action @ ("setup" | "verify" | "status"),
            ..,
        ] => {
            return crate::diagnostics::run(harness, action, &args[2..], &mut stdout);
        }
        ["codex", "scan", ..] => {
            parse_options(&args[2..]).and_then(|o| codex_scan(&o, &mut stdout))
        }
        ["codex", "ingest", ..] => {
            parse_options(&args[2..]).and_then(|o| codex_ingest(&o, &mut stdout))
        }
        ["codex", "parse", ..] => {
            parse_options(&args[2..]).and_then(|o| codex_parse(&o, &mut stdout))
        }
        ["codex", "notify", ..] => {
            // Hooks never fail the harness; problems are logged.
            codex_notify(&args[2..]);
            Ok(())
        }
        ["claude", "hook", ..] => {
            claude_hook(&args[2..]);
            Ok(())
        }
        ["claude", "scan", ..] => {
            parse_options(&args[2..]).and_then(|o| claude_scan(&o, &mut stdout))
        }
        ["claude", "ingest", ..] => {
            parse_options(&args[2..]).and_then(|o| claude_ingest(&o, &mut stdout))
        }
        ["claude", "parse", ..] => {
            parse_options(&args[2..]).and_then(|o| claude_parse(&o, &mut stdout))
        }
        ["drain", ..] => parse_options(&args[1..]).and_then(|o| drain(&o, &mut stdout)),
        ["apply", ..] => parse_options(&args[1..]).and_then(|o| apply(&o, &mut stdout)),
        ["query", ..] => {
            return crate::query::run(&args[1..], &mut stdout, &mut stderr);
        }
        ["hub", "enable", ..] => {
            parse_options(&args[2..]).and_then(|o| hub_enable(&o, &mut stdout))
        }
        ["hub", "sync", ..] => parse_options(&args[2..]).and_then(|o| hub_sync(&o, &mut stdout)),
        ["hub", "status", ..] => {
            parse_options(&args[2..]).and_then(|o| hub_status(&o, &mut stdout))
        }
        ["hub", "resync", ..] => {
            parse_options(&args[2..]).and_then(|o| hub_resync(&o, &mut stdout))
        }
        ["hub", "disable", ..] => {
            parse_options(&args[2..]).and_then(|o| hub_disable(&o, &mut stdout))
        }
        ["version", ..] | ["--version", ..] => {
            let _ = writeln!(
                stdout,
                "codex-sessions-collector {} (contract {} v{}, schema {})",
                env!("CARGO_PKG_VERSION"),
                contract::CONTRACT_NAME,
                contract::CONTRACT_VERSION,
                crate::store::schema::SUPPORTED_SCHEMA_VERSION
            );
            Ok(())
        }
        ["help", ..] | ["--help", ..] | ["-h", ..] | [] => {
            let _ = write!(stdout, "{USAGE}");
            Ok(())
        }
        _ => Err(CliError::Usage(format!(
            "unknown command {:?}",
            args.join(" ")
        ))),
    };
    match result {
        Ok(()) => 0,
        Err(CliError::Usage(message)) => {
            let _ = writeln!(stderr, "error: {message}\n\n{USAGE}");
            2
        }
        Err(CliError::Failed(message)) => {
            let _ = writeln!(stderr, "error: {message}");
            1
        }
        Err(CliError::Refused(message)) => {
            let _ = writeln!(stderr, "refused: {message}");
            3
        }
    }
}

fn open_store(options: &Options) -> Result<Store, CliError> {
    if let Some(path) = &options.standalone {
        return Ok(Store::open(path, OwnerMode::Standalone)?);
    }
    let path = match &options.db {
        Some(path) => path.clone(),
        None => default_viewer_database().ok_or_else(|| {
            CliError::Usage("Cannot locate user database; pass --db <FILE>".to_owned())
        })?,
    };
    Ok(Store::open(&path, OwnerMode::Viewer)?)
}

fn hub_enable(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    let url = options
        .hub_url
        .as_deref()
        .ok_or_else(|| CliError::Usage("hub enable needs --hub-url".into()))?;
    let store = open_store(options)?;
    crate::hub_client::enable_for_collection(std::path::Path::new(&store.path), store.mode, url)
        .map_err(CliError::Failed)?;
    writeln!(
        out,
        "{}",
        json!({"command":"hub enable","enabled":true,"machine_id":store.machine_id()?})
    )
    .map_err(|error| CliError::Failed(error.to_string()))
}

fn hub_token(command: &str) -> Result<String, CliError> {
    std::env::var("CODEX_SESSIONS_HUB_MACHINE_TOKEN").map_err(|_| {
        CliError::Usage(format!(
            "set CODEX_SESSIONS_HUB_MACHINE_TOKEN for {command}"
        ))
    })
}

fn enabled_hub_url(store: &Store) -> Result<String, CliError> {
    let row: Option<String> = store
        .conn
        .query_row(
            "select hub_url from collector_hub_state where id = 1 and enabled = 1",
            [],
            |row| row.get(0),
        )
        .optional()
        .map_err(StoreError::Sql)?;
    row.ok_or_else(|| CliError::Refused("hub delivery is not enabled; run hub enable first".into()))
}

fn hub_resync(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    let store = open_store(options)?;
    let url = enabled_hub_url(&store)?;
    let token = hub_token("hub resync")?;
    let report =
        crate::hub_client::resync(std::path::Path::new(&store.path), store.mode, &url, &token)
            .map_err(CliError::Failed)?;
    writeln!(out, "{}", json!({"command":"hub resync","previous_sequence":report.previous_sequence,"last_sequence":report.last_sequence,"pending":report.pending}))
        .map_err(|error| CliError::Failed(error.to_string()))
}

fn hub_disable(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    let store = open_store(options)?;
    let cleared = crate::hub_client::disable(std::path::Path::new(&store.path), store.mode)
        .map_err(CliError::Failed)?;
    writeln!(
        out,
        "{}",
        json!({"command":"hub disable","enabled":false,"cleared":cleared})
    )
    .map_err(|error| CliError::Failed(error.to_string()))
}

fn hub_sync(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    let store = open_store(options)?;
    let url = enabled_hub_url(&store)?;
    let token = hub_token("hub sync")?;
    let report =
        crate::hub_client::sync(std::path::Path::new(&store.path), store.mode, &url, &token)
            .map_err(CliError::Failed)?;
    writeln!(out, "{}", json!({"command":"hub sync","sent":report.sent,"batches":report.batches,"dead_lettered":report.dead_lettered,"pending":report.pending,"last_sequence":report.last_sequence}))
        .map_err(|error| CliError::Failed(error.to_string()))
}

fn hub_status(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    let store = open_store(options)?;
    let state: Option<(String, String, i64, bool)> = store.conn.query_row(
        "select hub_url, machine_id, last_sequence, enabled from collector_hub_state where id = 1",
        [], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
    ).optional().map_err(StoreError::Sql)?;
    let pending = crate::hub_client::pending(&store.conn)?;
    let (dead_count, dead_recent) = crate::hub_client::dead_letters(&store.conn)?;
    writeln!(out, "{}", json!({"command":"hub status","delivery":state.as_ref().map(|(url,machine,sequence,enabled)| json!({"hub_url":url,"machine_id":machine,"last_sequence":sequence,"enabled":enabled})),"pending":pending,"dead_letters":dead_count,"recent_dead_letters":dead_recent}))
        .map_err(|error| CliError::Failed(error.to_string()))
}

fn load_settings(options: &Options) -> Result<CollectorSettings, CliError> {
    let mut settings = match options.settings.clone().or_else(default_settings_file) {
        Some(path) => CollectorSettings::load(&path).map_err(CliError::Failed)?,
        None => CollectorSettings::default(),
    };
    if let Some(root) = &options.windows_root {
        settings.windows_codex_path = root.clone();
    }
    if let Some(root) = &options.wsl_root {
        settings.wsl_codex_unc_path = root.clone();
    }
    if let Some(root) = &options.wsl_unc_root {
        settings.wsl_linux_root_unc = root.clone();
    }
    Ok(settings)
}

fn default_parser_workers() -> usize {
    let processors = std::thread::available_parallelism().map_or(1, usize::from);
    if processors <= 2 {
        1
    } else {
        (processors - 1).min(8)
    }
}

fn scan_options(
    options: &Options,
    settings: &CollectorSettings,
    roots: Vec<ScanRoot>,
) -> ScanOptions {
    ScanOptions {
        roots,
        mapper: PathMapper::new(settings.wsl_linux_root_unc.clone()),
        parser: ParserOptions {
            max_tool_output_preview_chars: settings.max_tool_output_preview_chars,
            ..ParserOptions::default()
        },
        parser_workers: options
            .parser_workers
            .unwrap_or_else(default_parser_workers),
        wsl_root_retry_delays: DEFAULT_WSL_ROOT_RETRY_DELAYS.to_vec(),
        thread_names: read_thread_names(&[
            &settings.windows_codex_path,
            &settings.wsl_codex_unc_path,
        ]),
        force: options.force,
    }
}

fn configured_roots(settings: &CollectorSettings) -> Vec<ScanRoot> {
    let mut roots = session_scan_roots(&settings.windows_codex_path, SourceType::native());
    if SourceType::native() == SourceType::Windows {
        roots.extend(session_scan_roots(
            &settings.wsl_codex_unc_path,
            SourceType::Wsl,
        ));
    }
    roots
}

fn codex_scan(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    let holds = crate::store::write_budget::WriteHoldScope::start();
    if !options.positional.is_empty() {
        return Err(CliError::Usage(format!(
            "unexpected argument {:?}",
            options.positional[0]
        )));
    }
    let mut phases = crate::timing::Phases::start();
    let settings = load_settings(options)?;
    let store = open_store(options)?;
    phases.mark("open store");
    let scan = scan_options(options, &settings, configured_roots(&settings));
    phases.mark("read thread names");
    let mut report = scan_transport(options, out, |cancel, progress, gate| {
        codex::collect_coordinated(
            &store,
            &scan,
            options.wsl_projects,
            cancel,
            progress,
            gate,
            codex::CollectionBatching {
                sessions: options.flush_sessions,
                source_bytes: options.flush_bytes,
            },
        )
    })?;
    // After the repair, delete its backups once they are past the retention.
    if let Some(repair) = report.cache_repair.as_mut() {
        let pruned = crate::backup_retention::prune_repair_backups(
            &store.conn,
            Path::new(&store.path),
            crate::backup_retention::retention(settings.backup_retention_days),
            std::time::SystemTime::now(),
        );
        repair.pruned_backups = pruned.deleted;
        repair.prune_failures = pruned.failed;
    }
    crate::t3::import_optional(&store.conn, &settings);
    report.write_hold = holds.report();
    phases.mark("collect and prune");
    crate::timing::report_totals();
    let printed = print_report(out, "codex scan", &store, &report, options.json);
    phases.mark("report");
    printed
}

/// The shortest gap between two progress events unless a batch committed.
const PROGRESS_INTERVAL: std::time::Duration = std::time::Duration::from_millis(100);

/// A line from the GUI on stdin.
enum Control {
    Grant,
    Cancel,
}

/// The stdin/stdout protocol of a GUI-driven scan.
///
/// stdin carries `grant` (for the pending `write_requested`) and `cancel`;
/// closing stdin also cancels. stdout carries `progress` events, at most one
/// per [`PROGRESS_INTERVAL`] unless a batch committed, and with
/// `--coordinate-writes` a `write_requested`/`write_released` pair around
/// every database write. A cancel while waiting for a grant withdraws the
/// request with `write_released`; after a cancel no further lease is asked for.
fn scan_transport<W: Write>(
    options: &Options,
    out: &mut W,
    collect: impl FnOnce(
        &std::sync::Arc<std::sync::atomic::AtomicBool>,
        &mut dyn FnMut(&codex::scanner::ScanCounts, usize),
        &mut dyn FnMut(bool) -> Result<bool, StoreError>,
    ) -> Result<CollectReport, StoreError>,
) -> Result<CollectReport, CliError> {
    use std::sync::atomic::Ordering;
    let cancel = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let (controls, control) = std::sync::mpsc::channel::<Control>();
    if options.cancel_stdin {
        let cancellation = std::sync::Arc::clone(&cancel);
        std::thread::spawn(move || {
            for line in std::io::stdin().lock().lines() {
                match line.as_deref().map(str::trim) {
                    Ok("grant") => {
                        if controls.send(Control::Grant).is_err() {
                            return;
                        }
                    }
                    Ok("cancel") => {
                        cancellation.store(true, Ordering::Relaxed);
                        let _ = controls.send(Control::Cancel);
                    }
                    Ok(_) => {}
                    Err(_) => break,
                }
            }
            cancellation.store(true, Ordering::Relaxed);
            let _ = controls.send(Control::Cancel);
        });
    }
    let output = std::cell::RefCell::new(out);
    let emit = |event: serde_json::Value| -> std::io::Result<()> {
        let mut out = output.borrow_mut();
        writeln!(out, "{event}")?;
        out.flush()
    };
    let mut output_error = None;
    let mut last_progress: Option<(std::time::Instant, usize)> = None;
    let mut progress = |counts: &codex::scanner::ScanCounts, committed: usize| {
        if !options.progress_json || output_error.is_some() {
            return;
        }
        let now = std::time::Instant::now();
        if let Some((at, previous)) = last_progress
            && previous == committed
            && now.duration_since(at) < PROGRESS_INTERVAL
        {
            return;
        }
        last_progress = Some((now, committed));
        if let Err(error) =
            emit(json!({"event": "progress", "counts": counts, "sessions_written": committed}))
        {
            output_error = Some(error);
            cancel.store(true, Ordering::Relaxed);
        }
    };
    let mut gate = |acquire: bool| -> Result<bool, StoreError> {
        if !options.coordinate_writes {
            return Ok(true);
        }
        if !acquire {
            emit(json!({"event": "write_released"}))?;
            return Ok(true);
        }
        if cancel.load(Ordering::Relaxed) {
            return Ok(false);
        }
        emit(json!({"event": "write_requested"}))?;
        match control.recv() {
            Ok(Control::Grant) => Ok(true),
            Ok(Control::Cancel) | Err(_) => {
                cancel.store(true, Ordering::Relaxed);
                // Withdraw the request so the GUI's writer queue moves on.
                emit(json!({"event": "write_released"}))?;
                Ok(false)
            }
        }
    };
    let report = collect(&cancel, &mut progress, &mut gate)?;
    if let Some(error) = output_error {
        return Err(CliError::Failed(error.to_string()));
    }
    Ok(report)
}

/// The root a file belongs to, or a root inferred from the path.
fn root_for_file(settings: &CollectorSettings, file: &str) -> ScanRoot {
    let file_key = canonical_scan_path(file);
    for root in configured_roots(settings) {
        if is_path_under_root(&file_key, &root.path) {
            return ScanRoot {
                path: file.to_owned(),
                availability_root_path: None,
                ..root
            };
        }
    }
    let source_type = SourceType::native();
    let archived = file_key
        .split('/')
        .any(|segment| segment == "archived_sessions");
    ScanRoot {
        path: file.to_owned(),
        availability_root_path: None,
        source_type,
        source_state: if archived { "codex_archived" } else { "active" },
    }
}

fn codex_ingest(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    let [file] = options.positional.as_slice() else {
        return Err(CliError::Usage(
            "codex ingest needs exactly one <FILE>".to_owned(),
        ));
    };
    let settings = load_settings(options)?;
    let store = open_store(options)?;
    let absolute = std::path::absolute(file)
        .map(|path| path.to_string_lossy().into_owned())
        .unwrap_or_else(|_| file.clone());
    let root = root_for_file(&settings, &absolute);
    let mut scan = scan_options(options, &settings, Vec::new());
    scan.force = true;
    let report = codex::collect_file(&store, &scan, &root, options.wsl_projects)?;
    crate::t3::import_optional(&store.conn, &settings);
    print_report(out, "codex ingest", &store, &report, options.json)?;
    if report.counts.files_parsed == 0 {
        return Err(CliError::Failed(match report.errors.first() {
            Some(error) => format!(
                "{} was not ingested ({}): {}",
                error.path,
                error.status,
                error.message.as_deref().unwrap_or("")
            ),
            None => format!("{absolute} was not ingested"),
        }));
    }
    Ok(())
}

fn codex_parse(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    let [file] = options.positional.as_slice() else {
        return Err(CliError::Usage(
            "codex parse needs exactly one <FILE>".to_owned(),
        ));
    };
    let settings = load_settings(options)?;
    let root = root_for_file(&settings, file);
    let scan = scan_options(options, &settings, Vec::new());
    let record = match parse_file(file, scan.parser) {
        Ok(success) => {
            let snapshot = codex::snapshot_for(&scan, &root, &success);
            Record::SessionSnapshot(Box::new(snapshot))
        }
        Err(error) => Record::SourceStatus(SourceStatus {
            harness: "codex".to_owned(),
            path: file.clone(),
            environment: Some(root.source_type.wire_name().to_owned()),
            status: codex::scanner_status_for(&error).to_owned(),
            state: root.source_state.to_owned(),
            message: Some(error.display_message()),
        }),
    };
    let line = serde_json::to_string(&Envelope::new(record))
        .map_err(|error| CliError::Failed(error.to_string()))?;
    writeln!(out, "{line}").map_err(|error| CliError::Failed(error.to_string()))
}

fn apply(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    if !options.positional.is_empty() {
        return Err(CliError::Usage(format!(
            "unexpected argument {:?}",
            options.positional[0]
        )));
    }
    let reader: Box<dyn BufRead> = match &options.input {
        Some(path) if path.as_os_str() != "-" => Box::new(std::io::BufReader::new(
            std::fs::File::open(path)
                .map_err(|error| CliError::Failed(format!("{}: {error}", path.display())))?,
        )),
        _ => Box::new(std::io::stdin().lock()),
    };
    // Validate every record before writing any, so a bad line cannot leave
    // half a batch applied.
    let mut records = Vec::new();
    for (index, line) in reader.lines().enumerate() {
        let line = line.map_err(|error| CliError::Failed(error.to_string()))?;
        if line.trim().is_empty() {
            continue;
        }
        let envelope = contract::parse_line(&line)
            .map_err(|error| CliError::Failed(format!("line {}: {error}", index + 1)))?;
        records.push(envelope);
    }
    let store = open_store(options)?;
    let applied = store.apply(records)?;
    let report = CollectReport {
        applied,
        ..CollectReport::default()
    };
    print_report(out, "apply", &store, &report, options.json)
}

fn print_report(
    out: &mut impl Write,
    command: &str,
    store: &Store,
    report: &CollectReport,
    json: bool,
) -> Result<(), CliError> {
    let ApplySummary {
        sessions,
        statuses,
        thread_names_changed,
        project_updates,
    } = report.applied;
    let counts = &report.counts;
    let text = if json {
        json!({
            "event": "finished",
            "cancelled": counts.cancelled,
            "command": command,
            "database": store.path,
            "owner": match store.mode { OwnerMode::Viewer => "viewer", OwnerMode::Standalone => "collector" },
            "sessions_written": sessions,
            "statuses_written": statuses,
            "thread_names_changed": thread_names_changed,
            "project_updates": project_updates,
            "directories_scanned": counts.directories_scanned,
            "files_found": counts.files_found,
            "files_skipped": counts.files_skipped,
            "files_parsed": counts.files_parsed,
            "files_failed": counts.files_failed,
            "sessions_missing": counts.sessions_missing,
            "persistence_flushes": counts.persistence_flushes,
            "cache_repair": report.cache_repair,
            "write_hold": report.write_hold,
            "errors": report.errors.iter().map(|error| json!({
                "path": error.path,
                "status": error.status,
                "message": error.message,
            })).collect::<Vec<_>>(),
        })
        .to_string()
    } else {
        let mut text = format!(
            "{command}: {sessions} session(s) written to {}; {} found, {} unchanged, {} parsed, {} failed, {} missing.",
            store.path,
            counts.files_found,
            counts.files_skipped,
            counts.files_parsed,
            counts.files_failed,
            counts.sessions_missing
        );
        text.push_str(&format!(
            "\n  write_hold: {} transaction(s), max {:.3} ms, p99 {:.3} ms, max_phase {}.",
            report.write_hold.transactions,
            report.write_hold.max_ms,
            report.write_hold.p99_ms,
            report.write_hold.max_phase.as_deref().unwrap_or("none")
        ));
        for error in &report.errors {
            text.push_str(&format!(
                "\n  {} {}: {}",
                error.status,
                error.path,
                error.message.as_deref().unwrap_or("")
            ));
        }
        text
    };
    writeln!(out, "{text}").map_err(|error| CliError::Failed(error.to_string()))
}

// ---------------------------------------------------------------------------
// Claude Code

fn claude_roots(options: &Options) -> Vec<crate::claude::ClaudeRoot> {
    let mut roots: Vec<crate::claude::ClaudeRoot> = options
        .claude_roots
        .iter()
        .map(|path| crate::claude::ClaudeRoot {
            path: path.clone(),
            source_type: SourceType::native(),
        })
        .collect();
    if roots.is_empty()
        && options.claude_wsl_roots.is_empty()
        && let Some(root) = crate::claude::default_root()
    {
        roots.push(root);
    }
    if SourceType::native() == SourceType::Windows {
        roots.extend(
            options
                .claude_wsl_roots
                .iter()
                .map(|path| crate::claude::ClaudeRoot {
                    path: path.clone(),
                    source_type: SourceType::Wsl,
                }),
        );
    }
    roots
}

fn claude_parser_options(settings: &CollectorSettings) -> crate::claude::parser::ClaudeOptions {
    crate::claude::parser::ClaudeOptions {
        max_tool_output_preview_chars: settings.max_tool_output_preview_chars,
        ..crate::claude::parser::ClaudeOptions::default()
    }
}

fn claude_scan(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    let holds = crate::store::write_budget::WriteHoldScope::start();
    if !options.positional.is_empty() {
        return Err(CliError::Usage(format!(
            "unexpected argument {:?}",
            options.positional[0]
        )));
    }
    let settings = load_settings(options)?;
    let store = open_store(options)?;
    let scan = crate::claude::ClaudeScanOptions {
        roots: claude_roots(options),
        mapper: PathMapper::new(settings.wsl_linux_root_unc.clone()),
        parser: claude_parser_options(&settings),
        workers: options
            .parser_workers
            .unwrap_or_else(default_parser_workers),
        force: options.force,
        resolve_wsl_projects: options.wsl_projects,
    };
    let flush_sessions = if options.flush_sessions == codex::FLUSH_SESSIONS {
        crate::claude::FLUSH_SESSIONS
    } else {
        options.flush_sessions
    };
    let mut report = scan_transport(options, out, |cancel, progress, gate| {
        crate::claude::collect_coordinated(&store, &scan, cancel, progress, gate, flush_sessions)
    })?;
    crate::t3::import_optional(&store.conn, &settings);
    report.write_hold = holds.report();
    print_report(out, "claude scan", &store, &report, options.json)
}

fn claude_source_type(options: &Options, file: &str) -> SourceType {
    let key = canonical_scan_path(file);
    if SourceType::native() == SourceType::Windows
        && (options
            .claude_wsl_roots
            .iter()
            .any(|root| is_path_under_root(&key, root))
            || file.starts_with("\\\\wsl"))
    {
        SourceType::Wsl
    } else {
        SourceType::native()
    }
}

fn claude_ingest(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    let [file] = options.positional.as_slice() else {
        return Err(CliError::Usage(
            "claude ingest needs exactly one <FILE>".to_owned(),
        ));
    };
    let settings = load_settings(options)?;
    let store = open_store(options)?;
    let report = crate::claude::collect_file(
        &store,
        std::path::Path::new(file),
        claude_source_type(options, file),
        &PathMapper::new(settings.wsl_linux_root_unc.clone()),
        &claude_parser_options(&settings),
    )?;
    crate::t3::import_optional(&store.conn, &settings);
    print_report(out, "claude ingest", &store, &report, options.json)?;
    if report.counts.files_parsed == 0 {
        return Err(CliError::Failed(format!("{file} was not ingested")));
    }
    Ok(())
}

fn claude_parse(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    let [file] = options.positional.as_slice() else {
        return Err(CliError::Usage(
            "claude parse needs exactly one <FILE>".to_owned(),
        ));
    };
    let settings = load_settings(options)?;
    let transcript =
        crate::claude::parser::parse_transcript(file, &claude_parser_options(&settings))
            .map_err(|error| CliError::Failed(error.display_message()))?;
    let snapshot = crate::claude::snapshot(
        file,
        claude_source_type(options, file),
        &PathMapper::new(settings.wsl_linux_root_unc.clone()),
        transcript,
    );
    let line = serde_json::to_string(&Envelope::new(Record::SessionSnapshot(Box::new(snapshot))))
        .map_err(|error| CliError::Failed(error.to_string()))?;
    writeln!(out, "{line}").map_err(|error| CliError::Failed(error.to_string()))
}

// ---------------------------------------------------------------------------
// Hooks and the queue

/// Database, settings, and root options a hook passes on to its drain.
fn drain_arguments(args: &[String]) -> Vec<String> {
    const FORWARDED: [&str; 8] = [
        "--db",
        "--standalone",
        "--settings",
        "--windows-root",
        "--wsl-root",
        "--wsl-unc-root",
        "--claude-root",
        "--claude-wsl-root",
    ];
    let mut forwarded = vec!["drain".to_owned()];
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if FORWARDED.contains(&arg.as_str())
            && let Some(value) = iter.next()
        {
            forwarded.push(arg.clone());
            forwarded.push(value.clone());
        } else if arg == "--no-wsl-projects" {
            forwarded.push(arg.clone());
        }
    }
    forwarded
}

fn start_drain(args: &[String]) {
    let queue = crate::hooks::queue_dir();
    match std::env::current_exe() {
        Ok(exe) => {
            if let Err(error) = crate::hooks::spawn_detached(&exe, &drain_arguments(args)) {
                crate::hooks::log_error(&queue, &format!("could not start drain: {error}"));
            }
        }
        Err(error) => crate::hooks::log_error(&queue, &format!("could not start drain: {error}")),
    }
}

/// Codex calls its `notify` program with the event JSON as the last argument.
fn codex_notify(args: &[String]) {
    let queue = crate::hooks::queue_dir();
    let options = match parse_options(args) {
        Ok(options) => options,
        Err(CliError::Usage(message) | CliError::Failed(message) | CliError::Refused(message)) => {
            crate::hooks::log_error(&queue, &format!("codex notify: {message}"));
            return;
        }
    };
    let payload = options.positional.last().cloned().unwrap_or_default();
    if let Some(previous) = &options.previous_notify
        && let Err(error) = crate::hooks::run_previous_notify(previous, &payload)
    {
        crate::hooks::log_error(&queue, &format!("codex notify: {error}"));
    }
    let item = crate::hooks::codex_work_item(&payload);
    if let Err(error) = crate::hooks::enqueue(&queue, &item) {
        crate::hooks::log_error(&queue, &format!("codex notify: could not queue: {error}"));
        return;
    }
    if !options.no_drain {
        start_drain(args);
    }
}

/// Claude Code passes the hook event as JSON on stdin.
fn claude_hook(args: &[String]) {
    let queue = crate::hooks::queue_dir();
    let input = crate::hooks::read_hook_input();
    let item = crate::hooks::claude_work_item(&input);
    if item.transcript_path.is_none() {
        crate::hooks::log_error(&queue, "claude hook: the event named no transcript_path");
        return;
    }
    if let Err(error) = crate::hooks::enqueue(&queue, &item) {
        crate::hooks::log_error(&queue, &format!("claude hook: could not queue: {error}"));
        return;
    }
    if !args.iter().any(|arg| arg == "--no-drain") {
        start_drain(args);
    }
}

#[derive(Default)]
struct DrainCounts {
    completed: usize,
    retried: usize,
}

fn drain(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    let queue = crate::hooks::queue_dir();
    crate::hooks::reclaim_stale(&queue);
    let settings = load_settings(options)?;
    let mapper = PathMapper::new(settings.wsl_linux_root_unc.clone());
    let codex_homes: Vec<String> = [&settings.windows_codex_path, &settings.wsl_codex_unc_path]
        .into_iter()
        .take(if SourceType::native() == SourceType::Windows {
            2
        } else {
            1
        })
        .filter(|home| !home.trim().is_empty())
        .cloned()
        .collect();
    let mut store: Option<Store> = None;
    let mut open_error: Option<CliError> = None;
    let mut counts = DrainCounts::default();
    // A drain started by a hook stays until the queued retries are done, so
    // the last hook of a day is not left waiting for the next one; it is
    // bounded by MAX_DRAIN_TIME and by each item's retry limit.
    let deadline = std::time::Instant::now() + MAX_DRAIN_TIME;
    loop {
        let claims = crate::hooks::claim_due(&queue);
        if claims.is_empty() {
            if options.no_wait {
                break;
            }
            match crate::hooks::next_retry_in(&queue) {
                Some(wait) if std::time::Instant::now() + wait < deadline => {
                    std::thread::sleep(wait.max(std::time::Duration::from_millis(50)));
                    crate::hooks::reclaim_stale(&queue);
                    continue;
                }
                _ => break,
            }
        }
        if store.is_none() {
            match open_store(options) {
                Ok(opened) => {
                    store = Some(opened);
                    open_error = None;
                }
                Err(error) => {
                    let message = match &error {
                        CliError::Usage(message)
                        | CliError::Failed(message)
                        | CliError::Refused(message) => message.clone(),
                    };
                    for claim in claims {
                        crate::hooks::retry(&queue, claim, &message);
                        counts.retried += 1;
                    }
                    open_error = Some(error);
                    continue;
                }
            }
        }
        let store = store.as_ref().expect("opened above");
        for claim in claims {
            match drain_one(
                store,
                options,
                &settings,
                &mapper,
                &codex_homes,
                &claim.item,
            ) {
                Ok(()) => {
                    crate::hooks::complete(&claim);
                    counts.completed += 1;
                }
                Err(message) => {
                    crate::hooks::retry(&queue, claim, &message);
                    counts.retried += 1;
                }
            }
        }
    }
    let _ = writeln!(
        out,
        "{}",
        json!({"command": "drain", "completed": counts.completed, "retried": counts.retried})
    );
    match open_error {
        Some(error) if counts.completed == 0 => Err(error),
        _ => Ok(()),
    }
}

/// The longest a drain keeps waiting for queued retries.
const MAX_DRAIN_TIME: std::time::Duration = std::time::Duration::from_secs(300);

fn drain_one(
    store: &Store,
    options: &Options,
    settings: &CollectorSettings,
    mapper: &PathMapper,
    codex_homes: &[String],
    item: &crate::hooks::WorkItem,
) -> Result<(), String> {
    match item.harness.as_str() {
        "codex" => {
            let thread = item
                .session_id
                .as_deref()
                .filter(|id| !id.trim().is_empty())
                .ok_or("the notification named no thread")?;
            let file = crate::hooks::find_codex_rollout(codex_homes, thread)
                .ok_or_else(|| format!("no rollout for thread {thread} yet"))?;
            let file = file.to_string_lossy().into_owned();
            let root = root_for_file(settings, &file);
            let mut scan = scan_options(options, settings, Vec::new());
            scan.force = true;
            let report = codex::collect_file(store, &scan, &root, options.wsl_projects)
                .map_err(|error| error.to_string())?;
            if report.counts.files_parsed == 0 {
                return Err(report
                    .errors
                    .first()
                    .map_or_else(|| "not parsed".to_owned(), |error| error.status.clone()));
            }
            Ok(())
        }
        "claude" => {
            let reported = item
                .transcript_path
                .as_deref()
                .ok_or("the hook named no transcript")?;
            // On Windows, Claude Code in WSL reports a Linux path.
            let mapped = mapper.hook_access_path(reported).ok_or_else(|| {
                format!(
                    "transcript {reported} is a WSL path; configure the WSL root (wsl_linux_root_unc or --wsl-unc-root)"
                )
            })?;
            let path = mapped.as_str();
            if !std::path::Path::new(path).is_file() {
                return Err(format!("transcript {path} does not exist yet"));
            }
            let report = crate::claude::collect_file(
                store,
                std::path::Path::new(path),
                claude_source_type(options, path),
                mapper,
                &claude_parser_options(settings),
            )
            .map_err(|error| error.to_string())?;
            if let Some(error) = report.errors.first() {
                return Err(format!("{}: {}", error.status, error.path));
            }
            // A transcript still being written is stored and read again later.
            let conn = &store.conn;
            let pending: i64 = conn
                .query_row(
                    "select count(*) from sessions where harness = 'claude' and source_file_path = ? and scan_status = 'changed_pending_parse'",
                    [path],
                    |row| row.get(0),
                )
                .map_err(|error| error.to_string())?;
            if pending > 0 {
                return Err("the transcript was still being written".to_owned());
            }
            Ok(())
        }
        other => Err(format!("unknown harness {other:?}")),
    }
}
