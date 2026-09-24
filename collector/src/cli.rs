//! Command-line interface. `run` returns the process exit code.
//!
//! Exit codes: 0 success, 1 failure, 2 usage error, 3 database refused
//! (ownership, schema version, or a pending viewer migration).

use std::io::{BufRead, Write};
use std::path::PathBuf;

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
  codex-sessions-collector codex scan   [OPTIONS]         Scan the configured Codex homes
  codex-sessions-collector codex ingest [OPTIONS] <FILE>  Ingest one Codex session file
  codex-sessions-collector codex parse  [OPTIONS] <FILE>  Print one file as contract records
  codex-sessions-collector apply  [OPTIONS] [--input <FILE>]  Apply contract records (stdin by default)
  codex-sessions-collector version

DATABASE OPTIONS:
  --db <FILE>           Viewer database (default: %APPDATA%\\CodexSessionViewer\\codex_sessions_viewer.sqlite)
  --standalone <FILE>   Collector-owned database; created and migrated by the collector

SCAN OPTIONS:
  --settings <FILE>     Viewer settings.toml (default: next to this executable)
  --windows-root <DIR>  Windows Codex home or sessions folder (overrides settings)
  --wsl-root <DIR>      WSL Codex home as a \\\\wsl.localhost path (overrides settings)
  --wsl-unc-root <DIR>  WSL file-system root, e.g. \\\\wsl.localhost\\Ubuntu\\
  --no-wsl-projects     Do not ask wsl.exe for git project names
  --force               Reparse unchanged files
  --parser-workers <N>  Parallel parsers (default: CPU count - 1, at most 8)
  --json                Print a machine-readable summary
";

struct Options {
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
    input: Option<PathBuf>,
    positional: Vec<String>,
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
        input: None,
        positional: Vec::new(),
    };
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        let mut value = |name: &str| {
            iter.next()
                .cloned()
                .ok_or_else(|| CliError::Usage(format!("{name} needs a value")))
        };
        match arg.as_str() {
            "--db" => options.db = Some(PathBuf::from(value("--db")?)),
            "--standalone" => options.standalone = Some(PathBuf::from(value("--standalone")?)),
            "--settings" => options.settings = Some(PathBuf::from(value("--settings")?)),
            "--windows-root" => options.windows_root = Some(value("--windows-root")?),
            "--wsl-root" => options.wsl_root = Some(value("--wsl-root")?),
            "--wsl-unc-root" => options.wsl_unc_root = Some(value("--wsl-unc-root")?),
            "--input" => options.input = Some(PathBuf::from(value("--input")?)),
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
            "--no-wsl-projects" => options.wsl_projects = false,
            "--force" => options.force = true,
            "--json" => options.json = true,
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
        ["codex", "scan", ..] => {
            parse_options(&args[2..]).and_then(|o| codex_scan(&o, &mut stdout))
        }
        ["codex", "ingest", ..] => {
            parse_options(&args[2..]).and_then(|o| codex_ingest(&o, &mut stdout))
        }
        ["codex", "parse", ..] => {
            parse_options(&args[2..]).and_then(|o| codex_parse(&o, &mut stdout))
        }
        ["apply", ..] => parse_options(&args[1..]).and_then(|o| apply(&o, &mut stdout)),
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
        None => default_viewer_database()
            .ok_or_else(|| CliError::Usage("APPDATA is not set; pass --db <FILE>".to_owned()))?,
    };
    Ok(Store::open(&path, OwnerMode::Viewer)?)
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
        mapper: PathMapper {
            wsl_unc_root: settings.wsl_linux_root_unc.clone(),
        },
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
    let mut roots = session_scan_roots(&settings.windows_codex_path, SourceType::Windows);
    roots.extend(session_scan_roots(
        &settings.wsl_codex_unc_path,
        SourceType::Wsl,
    ));
    roots
}

fn codex_scan(options: &Options, out: &mut impl Write) -> Result<(), CliError> {
    if !options.positional.is_empty() {
        return Err(CliError::Usage(format!(
            "unexpected argument {:?}",
            options.positional[0]
        )));
    }
    let settings = load_settings(options)?;
    let store = open_store(options)?;
    let scan = scan_options(options, &settings, configured_roots(&settings));
    let report = codex::collect(&store, &scan, options.wsl_projects)?;
    print_report(out, "codex scan", &store, &report, options.json)
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
    let source_type = if file.starts_with("\\\\wsl") || file.contains("/home/") {
        SourceType::Wsl
    } else {
        SourceType::Windows
    };
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
