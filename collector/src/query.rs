//! Read-only queries over collected history (`query` commands).
//!
//! Output is the versioned JSON contract `codex-sessions-viewer.query`
//! version 1. Every command opens the database read-only with `query_only`,
//! reads through the `history_*` views (migration 019) inside one read
//! transaction, validates its limits, and pages with keyset cursors so a page
//! never repeats or skips rows of the same ordering. Nothing here writes,
//! starts the viewer, contacts a network service, or calls a model.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use rusqlite::types::Value as SqlValue;
use rusqlite::{Connection, OpenFlags, OptionalExtension, Row, params_from_iter};
use serde_json::{Map, Value, json};

use crate::dart::DartDateTime;
use crate::settings::default_viewer_database;
use crate::store::schema::{last_applied_version, metadata};

pub const QUERY_CONTRACT: &str = "codex-sessions-viewer.query";
pub const QUERY_CONTRACT_VERSION: u32 = 1;
/// The first schema with the `history_*` views.
pub const VIEWS_SCHEMA_VERSION: i64 = 19;

const QUERY_TIME_LIMIT: Duration = Duration::from_secs(10);
const MAX_QUERY_CHARS: usize = 2000;
const MAX_QUERY_WORDS: usize = 30;

const USAGE: &str = "\
codex-sessions-collector query: read-only access to collected session history.

USAGE:
  query status
  query projects  [--limit N] [--cursor C]
  query sessions  [FILTERS] [--limit N] [--cursor C]
  query search    --query TEXT [FILTERS] [--include-tools] [--limit N] [--chars N] [--cursor C]
  query session   --session REF
  query messages  --session REF [--after-index N] [--include-tools] [--limit N] [--chars N]
  query message   --session REF --index N [--text-offset N] [--chars N]
                  (or --ref history://MACHINE/HARNESS/SESSION#INDEX)
  query export    --session REF [--export-format json|markdown] [--include-tools]
                  [--after-index N] [--max-messages N] [--chars N] [--max-chars N]

FILTERS:
  --project NAME   exact project name, case-insensitive
  --path DIR       working directory DIR and its subfolders
  --since TIME     inclusive; a UTC date (2026-09-01) or a timestamp with an offset
  --until TIME     exclusive; same forms as --since
  --harness NAME   repeatable, e.g. codex, claude
  --machine ID     repeatable machine ID

COMMON:
  --db FILE        database (default: %APPDATA%\\CodexSessionViewer\\codex_sessions_viewer.sqlite)
  --format json|text   json (default) or readable text
";

#[derive(Debug)]
pub enum QueryError {
    Usage(String),
    Failed(String),
    Refused(String),
    NotFound(String),
}

impl QueryError {
    pub fn exit_code(&self) -> i32 {
        match self {
            Self::Usage(_) => 2,
            Self::Refused(_) => 3,
            Self::Failed(_) | Self::NotFound(_) => 1,
        }
    }

    fn message(&self) -> &str {
        match self {
            Self::Usage(message)
            | Self::Failed(message)
            | Self::Refused(message)
            | Self::NotFound(message) => message,
        }
    }
}

impl From<rusqlite::Error> for QueryError {
    fn from(error: rusqlite::Error) -> Self {
        if let rusqlite::Error::SqliteFailure(code, _) = &error
            && code.code == rusqlite::ErrorCode::OperationInterrupted
        {
            return Self::Failed(format!(
                "The query took longer than {} seconds and was stopped; narrow it with filters or a lower --limit.",
                QUERY_TIME_LIMIT.as_secs()
            ));
        }
        Self::Failed(format!("SQLite error: {error}"))
    }
}

impl From<crate::store::StoreError> for QueryError {
    fn from(error: crate::store::StoreError) -> Self {
        Self::Failed(error.to_string())
    }
}

type QueryResult<T> = Result<T, QueryError>;

#[derive(Default)]
struct Options {
    db: Option<PathBuf>,
    text: bool,
    query: Option<String>,
    project: Option<String>,
    path: Option<String>,
    since: Option<String>,
    until: Option<String>,
    harnesses: Vec<String>,
    machines: Vec<String>,
    include_tools: bool,
    limit: Option<i64>,
    chars: Option<i64>,
    cursor: Option<String>,
    session: Option<String>,
    reference: Option<String>,
    after_index: Option<i64>,
    index: Option<i64>,
    text_offset: Option<i64>,
    export_format: Option<String>,
    max_messages: Option<i64>,
    max_chars: Option<i64>,
}

fn number(name: &str, value: &str) -> QueryResult<i64> {
    value
        .parse()
        .map_err(|_| QueryError::Usage(format!("{name} must be a whole number, not {value:?}")))
}

fn parse_options(args: &[String]) -> QueryResult<Options> {
    let mut options = Options::default();
    // Accept `--name=value` as well as `--name value`.
    let args: Vec<String> = args
        .iter()
        .flat_map(|arg| match arg.split_once('=') {
            Some((name, value)) if name.starts_with("--") => {
                vec![name.to_owned(), value.to_owned()]
            }
            _ => vec![arg.clone()],
        })
        .collect();
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        let mut value = |name: &str| {
            iter.next()
                .cloned()
                .ok_or_else(|| QueryError::Usage(format!("{name} needs a value")))
        };
        match arg.as_str() {
            "--db" => options.db = Some(PathBuf::from(value("--db")?)),
            "--format" => {
                let format = value("--format")?;
                options.text = match format.as_str() {
                    "json" => false,
                    "text" => true,
                    other => {
                        return Err(QueryError::Usage(format!(
                            "--format must be json or text, not {other:?}"
                        )));
                    }
                };
            }
            "--query" => options.query = Some(value("--query")?),
            "--project" => options.project = Some(value("--project")?),
            "--path" => options.path = Some(value("--path")?),
            "--since" => options.since = Some(value("--since")?),
            "--until" => options.until = Some(value("--until")?),
            "--harness" => options.harnesses.push(value("--harness")?),
            "--machine" => options.machines.push(value("--machine")?),
            "--include-tools" => options.include_tools = true,
            "--limit" => options.limit = Some(number("--limit", &value("--limit")?)?),
            "--chars" => options.chars = Some(number("--chars", &value("--chars")?)?),
            "--cursor" => options.cursor = Some(value("--cursor")?),
            "--session" => options.session = Some(value("--session")?),
            "--ref" => options.reference = Some(value("--ref")?),
            "--after-index" => {
                options.after_index = Some(number("--after-index", &value("--after-index")?)?);
            }
            "--index" => options.index = Some(number("--index", &value("--index")?)?),
            "--text-offset" => {
                options.text_offset = Some(number("--text-offset", &value("--text-offset")?)?);
            }
            "--export-format" => options.export_format = Some(value("--export-format")?),
            "--max-chars" => {
                options.max_chars = Some(number("--max-chars", &value("--max-chars")?)?);
            }
            "--max-messages" => {
                options.max_messages = Some(number("--max-messages", &value("--max-messages")?)?);
            }
            other => return Err(QueryError::Usage(format!("unknown option {other}"))),
        }
    }
    Ok(options)
}

fn bounded(name: &str, value: Option<i64>, default: i64, low: i64, high: i64) -> QueryResult<i64> {
    let value = value.unwrap_or(default);
    if (low..=high).contains(&value) {
        Ok(value)
    } else {
        Err(QueryError::Usage(format!(
            "{name} must be between {low} and {high}, not {value}"
        )))
    }
}

/// Run `query <command> ...`; returns the process exit code.
pub fn run(args: &[String], out: &mut impl Write, err: &mut impl Write) -> i32 {
    let Some(command) = args.first() else {
        let _ = write!(out, "{USAGE}");
        return 0;
    };
    if matches!(command.as_str(), "help" | "--help" | "-h") {
        let _ = write!(out, "{USAGE}");
        return 0;
    }
    let result = parse_options(&args[1..]).and_then(|options| {
        let database = match &options.db {
            Some(path) => path.clone(),
            None => default_viewer_database().ok_or_else(|| {
                QueryError::Usage("APPDATA is not set; pass --db FILE".to_owned())
            })?,
        };
        let conn = open_read_only(&database)?;
        let payload = execute(&conn, command, &options);
        let _ = conn.execute_batch("rollback");
        let mut payload = payload?;
        let mut envelope = Map::new();
        envelope.insert("contract".to_owned(), json!(QUERY_CONTRACT));
        envelope.insert("version".to_owned(), json!(QUERY_CONTRACT_VERSION));
        envelope.insert("command".to_owned(), json!(command));
        envelope.insert("database".to_owned(), json!(database.display().to_string()));
        envelope.insert("read_only".to_owned(), json!(true));
        if let Value::Object(fields) = &mut payload {
            envelope.append(fields);
        }
        Ok((Value::Object(envelope), options.text))
    });
    match result {
        Ok((value, text)) => {
            let rendered = if text {
                render_text(&value)
            } else {
                value.to_string()
            };
            let _ = writeln!(out, "{rendered}");
            0
        }
        Err(error) => {
            let _ = writeln!(
                err,
                "{}",
                json!({"error": error.message(), "read_only": true, "exit_code": error.exit_code()})
            );
            if matches!(error, QueryError::Usage(_)) {
                let _ = write!(err, "\n{USAGE}");
            }
            error.exit_code()
        }
    }
}

/// Open without write access. `query_only` also blocks writes through this
/// connection, and a progress handler bounds the time any statement may run.
pub fn open_read_only(path: &Path) -> QueryResult<Connection> {
    if !path.is_file() {
        return Err(QueryError::NotFound(format!(
            "No database at {}. Pass --db FILE, or let the viewer or a collector create it; a missing database is not empty history.",
            path.display()
        )));
    }
    let conn = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    conn.busy_timeout(Duration::from_secs(3))?;
    conn.pragma_update(None, "query_only", "on")?;
    let deadline = Instant::now() + QUERY_TIME_LIMIT;
    conn.progress_handler(10_000, Some(move || Instant::now() > deadline))?;
    let has_views: bool = conn
        .query_row(
            "select 1 from sqlite_schema where type = 'view' and name = 'history_sessions'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !has_views {
        let version = last_applied_version(&conn)?;
        return Err(QueryError::Refused(format!(
            "{} is at schema version {version}; history queries need schema {VIEWS_SCHEMA_VERSION}. Open the viewer (or run a collector on a standalone database) once to upgrade it.",
            path.display()
        )));
    }
    // One snapshot for every statement of the command.
    conn.execute_batch("begin")?;
    Ok(conn)
}

fn execute(conn: &Connection, command: &str, options: &Options) -> QueryResult<Value> {
    match command {
        "status" => status(conn),
        "projects" => projects(conn, options),
        "sessions" => sessions(conn, options),
        "search" => search(conn, options),
        "session" => session(conn, options),
        "messages" => messages(conn, options),
        "message" => message(conn, options),
        "export" => export(conn, options),
        other => Err(QueryError::Usage(format!(
            "unknown query command {other:?}"
        ))),
    }
}

// ---------------------------------------------------------------------------
// Rows, cursors, filters

fn json_value(row: &Row<'_>, index: usize) -> rusqlite::Result<Value> {
    Ok(match row.get::<_, SqlValue>(index)? {
        SqlValue::Null => Value::Null,
        SqlValue::Integer(value) => json!(value),
        SqlValue::Real(value) => json!(value),
        SqlValue::Text(value) => json!(value),
        SqlValue::Blob(value) => json!(format!("<{} bytes>", value.len())),
    })
}

/// Rows as JSON objects keyed by column name, in column order.
fn select_rows(
    conn: &Connection,
    sql: &str,
    values: &[SqlValue],
) -> QueryResult<Vec<Map<String, Value>>> {
    let mut statement = conn.prepare(sql)?;
    let names: Vec<String> = statement
        .column_names()
        .iter()
        .map(|name| (*name).to_owned())
        .collect();
    let rows = statement.query_map(params_from_iter(values.iter()), |row| {
        let mut map = Map::new();
        for (index, name) in names.iter().enumerate() {
            map.insert(name.clone(), json_value(row, index)?);
        }
        Ok(map)
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn hex_decode(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(text.get(index..index + 2)?, 16).ok())
        .collect()
}

/// Opaque keyset cursor: the sort key of the last returned row, tagged with
/// the command and a fingerprint of the query and filters, so a cursor only
/// continues the result set that produced it. The page size may change.
fn encode_cursor(command: &str, scope: &str, key: &[Value]) -> String {
    hex_encode(json!([command, scope, key]).to_string().as_bytes())
}

fn decode_cursor(command: &str, scope: &str, cursor: &str) -> QueryResult<Vec<Value>> {
    let invalid = || {
        QueryError::Usage(
            "--cursor does not continue this query; repeat the same command and filters that returned it".to_owned(),
        )
    };
    let bytes = hex_decode(cursor).ok_or_else(invalid)?;
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| invalid())?;
    match value {
        Value::Array(mut items)
            if items.len() == 3 && items[0] == json!(command) && items[1] == json!(scope) =>
        {
            match items.pop() {
                Some(Value::Array(key)) => Ok(key),
                _ => Err(invalid()),
            }
        }
        _ => Err(invalid()),
    }
}

/// What a cursor may continue: the search text, filters, and tool option.
fn cursor_scope(options: &Options) -> String {
    let scope = json!([
        options.query,
        Filters::describe(options),
        options.include_tools,
    ]);
    crate::dart::sha256_hex(scope.to_string().as_bytes())[..16].to_owned()
}

fn sql_value(value: &Value) -> SqlValue {
    match value {
        Value::Null => SqlValue::Null,
        Value::Number(number) => number.as_i64().map_or_else(
            || SqlValue::Real(number.as_f64().unwrap_or(0.0)),
            SqlValue::Integer,
        ),
        Value::String(text) => SqlValue::Text(text.clone()),
        other => SqlValue::Text(other.to_string()),
    }
}

/// `2026-09-01` (UTC midnight) or a timestamp with `Z` or an offset.
fn parse_instant(name: &str, value: &str) -> QueryResult<String> {
    let trimmed = value.trim();
    let is_date = trimmed.len() == 10
        && trimmed.as_bytes()[4] == b'-'
        && trimmed.as_bytes()[7] == b'-'
        && trimmed
            .bytes()
            .enumerate()
            .all(|(i, b)| i == 4 || i == 7 || b.is_ascii_digit());
    let candidate = if is_date {
        format!("{trimmed}T00:00:00Z")
    } else {
        let tail = trimmed.rsplit(['T', ' ']).next().unwrap_or("");
        let has_zone = tail.ends_with(['Z', 'z'])
            || tail.contains('+')
            || tail[1.min(tail.len())..].contains('-');
        if !trimmed.contains(['T', ' ']) || !has_zone {
            return Err(QueryError::Usage(format!(
                "{name} needs a UTC date (2026-09-01) or a timestamp with Z or an offset, not {value:?}"
            )));
        }
        trimmed.to_owned()
    };
    DartDateTime::try_parse(&candidate)
        .map(DartDateTime::to_iso8601)
        .ok_or_else(|| QueryError::Usage(format!("{name} is not a valid time: {value:?}")))
}

struct Filters {
    clauses: Vec<String>,
    values: Vec<SqlValue>,
}

impl Filters {
    /// Session-scope filters over `h` (history_sessions); dates apply to
    /// `time_column`.
    fn new(options: &Options, time_column: &str) -> QueryResult<Self> {
        let mut filters = Self {
            clauses: Vec::new(),
            values: Vec::new(),
        };
        if let Some(project) = &options.project {
            filters
                .clauses
                .push("coalesce(h.project, '') = ? collate nocase".to_owned());
            filters.values.push(SqlValue::Text(project.clone()));
        }
        if let Some(path) = &options.path {
            let path = path.replace('\\', "/").trim_end_matches('/').to_lowercase();
            if path.is_empty() {
                return Err(QueryError::Usage("--path must not be empty".to_owned()));
            }
            let expr = "lower(replace(coalesce(nullif(h.working_directory_platform, ''), h.working_directory, ''), char(92), '/'))";
            let mut alternatives = Vec::new();
            for form in path_forms(&path) {
                alternatives.push(format!("{expr} = ? or substr({expr}, 1, ?) = ?"));
                filters.values.push(SqlValue::Text(form.clone()));
                filters
                    .values
                    .push(SqlValue::Integer(form.chars().count() as i64 + 1));
                filters.values.push(SqlValue::Text(format!("{form}/")));
            }
            filters
                .clauses
                .push(format!("({})", alternatives.join(" or ")));
        }
        let since = options
            .since
            .as_deref()
            .map(|value| parse_instant("--since", value))
            .transpose()?;
        let until = options
            .until
            .as_deref()
            .map(|value| parse_instant("--until", value))
            .transpose()?;
        if let (Some(since), Some(until)) = (&since, &until)
            && since >= until
        {
            return Err(QueryError::Usage(
                "--since must be earlier than --until".to_owned(),
            ));
        }
        if let Some(since) = since {
            filters
                .clauses
                .push(format!("julianday({time_column}) >= julianday(?)"));
            filters.values.push(SqlValue::Text(since));
        }
        if let Some(until) = until {
            filters
                .clauses
                .push(format!("julianday({time_column}) < julianday(?)"));
            filters.values.push(SqlValue::Text(until));
        }
        for (column, list) in [
            ("h.harness", &options.harnesses),
            ("h.machine_id", &options.machines),
        ] {
            if !list.is_empty() {
                filters.clauses.push(format!(
                    "{column} in ({})",
                    vec!["?"; list.len()].join(", ")
                ));
                filters
                    .values
                    .extend(list.iter().cloned().map(SqlValue::Text));
            }
        }
        Ok(filters)
    }

    fn describe(options: &Options) -> Value {
        json!({
            "project": options.project,
            "path": options.path,
            "since": options.since,
            "until": options.until,
            "harness": options.harnesses,
            "machine": options.machines,
        })
    }
}

/// A folder as Windows sessions record it (`f:/x`) and as WSL sessions do
/// (`/mnt/f/x`); both name the same place.
fn path_forms(path: &str) -> Vec<String> {
    let mut forms = vec![path.to_owned()];
    let bytes = path.as_bytes();
    if let Some(rest) = path.strip_prefix("/mnt/")
        && let Some(drive) = rest.chars().next()
        && drive.is_ascii_alphabetic()
        && (rest.len() == 1 || rest.as_bytes()[1] == b'/')
    {
        forms.push(format!("{drive}:{}", &rest[1..]));
    } else if bytes.len() >= 2 && bytes[1] == b':' && bytes[0].is_ascii_alphabetic() {
        forms.push(format!("/mnt/{}{}", &path[..1], &path[2..]));
    }
    forms
}

/// Literal words for FTS5, combined with AND; never raw FTS syntax.
fn fts_query(text: &str) -> QueryResult<String> {
    if text.chars().count() > MAX_QUERY_CHARS {
        return Err(QueryError::Usage(format!(
            "--query is longer than {MAX_QUERY_CHARS} characters"
        )));
    }
    let words: Vec<String> = text
        .split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .filter(|word| !word.is_empty())
        .map(str::to_owned)
        .collect();
    if words.is_empty() || words.len() > MAX_QUERY_WORDS {
        return Err(QueryError::Usage(format!(
            "--query needs 1 to {MAX_QUERY_WORDS} words; it is matched as literal words, not SQL or FTS syntax"
        )));
    }
    Ok(words
        .iter()
        .map(|word| format!("\"{word}\""))
        .collect::<Vec<_>>()
        .join(" AND "))
}

fn take_chars(text: &str, max: usize) -> (String, bool) {
    match text.char_indices().nth(max) {
        Some((end, _)) => (text[..end].to_owned(), true),
        None => (text.to_owned(), false),
    }
}

// ---------------------------------------------------------------------------
// Session references

/// A `history://MACHINE/HARNESS/SESSION[#INDEX]` reference or a bare session
/// ID / row ID.
fn resolve_session(conn: &Connection, reference: &str) -> QueryResult<Map<String, Value>> {
    let session_part = reference;
    let rows = if let Some(rest) = session_part.strip_prefix("history://") {
        let mut parts = rest.splitn(3, '/');
        let (Some(machine), Some(harness), Some(key)) = (parts.next(), parts.next(), parts.next())
        else {
            return Err(QueryError::Usage(format!(
                "{reference:?} is not a history://MACHINE/HARNESS/SESSION reference"
            )));
        };
        select_rows(
            conn,
            "select * from history_sessions where machine_id = ? and harness = ? and session_key = ?",
            &[
                SqlValue::Text(machine.to_owned()),
                SqlValue::Text(harness.to_owned()),
                SqlValue::Text(key.to_owned()),
            ],
        )?
    } else {
        select_rows(
            conn,
            "select * from history_sessions where session_key = ? or row_id = ? order by reference limit 10",
            &[
                SqlValue::Text(session_part.to_owned()),
                SqlValue::Text(session_part.to_owned()),
            ],
        )?
    };
    match rows.len() {
        0 => Err(QueryError::NotFound(format!(
            "No collected session matches {reference:?}. It may belong to another database or has not been collected."
        ))),
        1 => Ok(rows.into_iter().next().expect("one row")),
        _ => Err(QueryError::Usage(format!(
            "{reference:?} matches several sessions; use one of these references: {}",
            rows.iter()
                .map(|row| row["reference"].as_str().unwrap_or("").to_owned())
                .collect::<Vec<_>>()
                .join(", ")
        ))),
    }
}

/// Split `...#N` into the session part and the message index.
fn split_message_reference(reference: &str) -> (&str, Option<i64>) {
    if let Some((session, index)) = reference.rsplit_once('#')
        && !index.is_empty()
        && index.bytes().all(|byte| byte.is_ascii_digit())
    {
        return (session, index.parse().ok());
    }
    (reference, None)
}

fn session_reference_option(options: &Options) -> QueryResult<(String, Option<i64>)> {
    match (&options.session, &options.reference) {
        (Some(session), None) => Ok((session.clone(), None)),
        (None, Some(reference)) => {
            let (session, index) = split_message_reference(reference);
            Ok((session.to_owned(), index))
        }
        (Some(_), Some(_)) => Err(QueryError::Usage(
            "use either --session or --ref, not both".to_owned(),
        )),
        (None, None) => Err(QueryError::Usage("--session REF is required".to_owned())),
    }
}

const SESSION_SUMMARY_COLUMNS: &str =
    "h.reference, h.machine_id, h.harness, h.session_key, h.session_id,
    h.title, h.thread_name, h.project, h.environment, h.working_directory, h.source_state,
    h.started_at_utc, h.last_message_at_utc, h.last_parsed_utc, h.message_count,
    h.tool_call_count, h.total_tokens";

// ---------------------------------------------------------------------------
// Commands

fn status(conn: &Connection) -> QueryResult<Value> {
    let harnesses = select_rows(
        conn,
        "select harness, machine_id, count(*) as sessions, max(activity_at_utc) as last_activity_utc
         from history_sessions group by harness, machine_id order by harness, machine_id",
        &[],
    )?;
    let backfill = select_rows(
        conn,
        "select key, value from app_metadata where key like 'message_search.backfill.%' order by key limit 20",
        &[],
    )?;
    let mut backfill_map = Map::new();
    for row in backfill {
        if let (Some(key), Some(value)) = (row["key"].as_str(), row.get("value")) {
            backfill_map.insert(key.to_owned(), value.clone());
        }
    }
    Ok(json!({
        "sqlite_version": rusqlite::version(),
        "schema_version": last_applied_version(conn)?,
        "database_owner": metadata(conn, "database_owner")?.unwrap_or_else(|| "viewer".to_owned()),
        "machine_id": metadata(conn, "machine_id")?,
        "harnesses": harnesses,
        "message_search_backfill": backfill_map,
        "tool_output_search_enabled": metadata(conn, "tool_output_search.enabled")?.as_deref() == Some("1"),
        "coverage_note": "Reports the existing index only. Sources not yet collected, or changed since the last scan, are not included.",
    }))
}

fn projects(conn: &Connection, options: &Options) -> QueryResult<Value> {
    let limit = bounded("--limit", options.limit, 50, 1, 200)?;
    let mut values: Vec<SqlValue> = Vec::new();
    let mut keyset = String::new();
    if let Some(cursor) = &options.cursor {
        let key = decode_cursor("projects", "", cursor)?;
        if key.len() != 2 {
            return Err(QueryError::Usage(
                "--cursor is not a cursor this command returned".to_owned(),
            ));
        }
        keyset = "having (sort_name, project) > (?, ?)".to_owned();
        values.extend(key.iter().map(sql_value));
    }
    values.push(SqlValue::Integer(limit + 1));
    let mut rows = select_rows(
        conn,
        &format!(
            "select project, lower(project) as sort_name, count(*) as sessions,
               max(activity_at_utc) as last_activity_utc,
               group_concat(distinct harness) as harnesses
             from history_sessions where coalesce(project, '') <> ''
             group by project {keyset}
             order by sort_name, project limit ?"
        ),
        &values,
    )?;
    let has_more = rows.len() as i64 > limit;
    rows.truncate(limit as usize);
    let next = has_more.then(|| {
        let last = rows.last().expect("a full page");
        encode_cursor(
            "projects",
            "",
            &[last["sort_name"].clone(), last["project"].clone()],
        )
    });
    for row in &mut rows {
        row.remove("sort_name");
    }
    Ok(json!({"results": rows, "has_more": has_more, "next_cursor": next}))
}

fn sessions(conn: &Connection, options: &Options) -> QueryResult<Value> {
    let limit = bounded("--limit", options.limit, 20, 1, 100)?;
    let filters = Filters::new(options, "h.activity_at_utc")?;
    let mut clauses = filters.clauses.clone();
    let mut values = filters.values.clone();
    if let Some(cursor) = &options.cursor {
        let key = decode_cursor("sessions", &cursor_scope(options), cursor)?;
        if key.len() != 4 {
            return Err(QueryError::Usage(
                "--cursor is not a cursor this command returned".to_owned(),
            ));
        }
        clauses.push(
            "(coalesce(h.activity_at_utc, '') < ? or (coalesce(h.activity_at_utc, '') = ?
               and (h.harness, h.machine_id, h.session_key) > (?, ?, ?)))"
                .to_owned(),
        );
        values.push(sql_value(&key[0]));
        values.extend(key.iter().map(sql_value));
    }
    values.push(SqlValue::Integer(limit + 1));
    let where_clause = if clauses.is_empty() {
        String::new()
    } else {
        format!("where {}", clauses.join(" and "))
    };
    let mut rows = select_rows(
        conn,
        &format!(
            "select {SESSION_SUMMARY_COLUMNS}, coalesce(h.activity_at_utc, '') as sort_time
             from history_sessions h {where_clause}
             order by sort_time desc, h.harness, h.machine_id, h.session_key limit ?"
        ),
        &values,
    )?;
    let has_more = rows.len() as i64 > limit;
    rows.truncate(limit as usize);
    let next = has_more.then(|| {
        let last = rows.last().expect("a full page");
        encode_cursor(
            "sessions",
            &cursor_scope(options),
            &[
                last["sort_time"].clone(),
                last["harness"].clone(),
                last["machine_id"].clone(),
                last["session_key"].clone(),
            ],
        )
    });
    for row in &mut rows {
        row.remove("sort_time");
    }
    Ok(json!({
        "filters": Filters::describe(options),
        "results": rows,
        "has_more": has_more,
        "next_cursor": next,
    }))
}

fn search(conn: &Connection, options: &Options) -> QueryResult<Value> {
    let text = options
        .query
        .as_deref()
        .ok_or_else(|| QueryError::Usage("search needs --query TEXT".to_owned()))?;
    let fts = fts_query(text)?;
    let limit = bounded("--limit", options.limit, 10, 1, 50)?;
    let chars = bounded("--chars", options.chars, 300, 40, 2000)?;
    let filters = Filters::new(options, "m.created_at_utc")?;
    let snippet_tokens = (chars / 6).clamp(8, 64);
    let mut clauses = vec!["message_search match ?".to_owned()];
    let mut values = vec![SqlValue::Integer(snippet_tokens), SqlValue::Text(fts)];
    if !options.include_tools {
        clauses.push("m.author_type in ('user', 'assistant')".to_owned());
    }
    clauses.extend(filters.clauses.iter().cloned());
    values.extend(filters.values.iter().cloned());
    if let Some(cursor) = &options.cursor {
        let key = decode_cursor("search", &cursor_scope(options), cursor)?;
        if key.len() != 5 {
            return Err(QueryError::Usage(
                "--cursor is not a cursor this command returned".to_owned(),
            ));
        }
        clauses.push(
            "(coalesce(m.created_at_utc, '') < ? or (coalesce(m.created_at_utc, '') = ?
               and (m.harness, m.machine_id, m.session_key, m.message_index) > (?, ?, ?, ?)))"
                .to_owned(),
        );
        values.push(sql_value(&key[0]));
        values.extend(key.iter().map(sql_value));
    }
    values.push(SqlValue::Integer(limit + 1));
    let mut rows = select_rows(
        conn,
        &format!(
            "select m.reference, m.session_reference, m.message_index, m.author_type,
               m.created_at_utc, snippet(message_search, 0, '[', ']', '...', ?) as excerpt,
               length(coalesce(m.content_plain, '')) as content_length,
               m.content_truncated as source_content_truncated,
               h.title, h.project, h.harness, h.machine_id, h.session_key, h.environment,
               h.working_directory, h.last_parsed_utc,
               coalesce(m.created_at_utc, '') as sort_time
             from message_search
             join history_messages m on m.message_rowid = message_search.rowid
             join history_sessions h on h.row_id = m.session_row_id
             where {}
             order by sort_time desc, m.harness, m.machine_id, m.session_key, m.message_index
             limit ?",
            clauses.join(" and ")
        ),
        &values,
    )?;
    let has_more = rows.len() as i64 > limit;
    rows.truncate(limit as usize);
    let next = has_more.then(|| {
        let last = rows.last().expect("a full page");
        encode_cursor(
            "search",
            &cursor_scope(options),
            &[
                last["sort_time"].clone(),
                last["harness"].clone(),
                last["machine_id"].clone(),
                last["session_key"].clone(),
                last["message_index"].clone(),
            ],
        )
    });
    for row in &mut rows {
        row.remove("sort_time");
        let excerpt = row["excerpt"].as_str().unwrap_or("").to_owned();
        let (excerpt, cut) = take_chars(&excerpt, chars as usize);
        row.insert("excerpt".to_owned(), json!(excerpt));
        // A snippet is always a window of the message.
        row.insert("excerpt_is_partial".to_owned(), json!(true));
        row.insert("excerpt_cut_at_chars".to_owned(), json!(cut));
    }
    Ok(json!({
        "query": text,
        "filters": Filters::describe(options),
        "include_tools": options.include_tools,
        "results": rows,
        "has_more": has_more,
        "next_cursor": next,
    }))
}

fn session(conn: &Connection, options: &Options) -> QueryResult<Value> {
    let (reference, _) = session_reference_option(options)?;
    let summary = resolve_session(conn, &reference)?;
    let row_id = summary["row_id"].as_str().unwrap_or("").to_owned();
    let usage = select_rows(
        conn,
        "select model, count(*) as events, sum(input_tokens) as input_tokens,
           sum(cached_input_tokens) as cached_input_tokens,
           sum(cache_write_input_tokens) as cache_write_input_tokens,
           sum(output_tokens) as output_tokens,
           sum(reasoning_output_tokens) as reasoning_output_tokens,
           sum(total_tokens) as total_tokens
         from usage_events where session_row_id = ? and branch_scope = 'local'
         group by model order by model",
        &[SqlValue::Text(row_id.clone())],
    )?;
    let tools = select_rows(
        conn,
        "select tool_name, count(*) as calls, sum(case when error_message is not null or status = 'error' then 1 else 0 end) as errors
         from history_tool_calls where session_row_id = ? group by tool_name order by calls desc, tool_name limit 50",
        &[SqlValue::Text(row_id)],
    )?;
    let mut summary = summary;
    summary.remove("row_id");
    for key in ["title", "summary", "thread_name"] {
        if let Some(Value::String(text)) = summary.get(key) {
            let (bounded_text, _) = take_chars(text, 2000);
            summary.insert(key.to_owned(), json!(bounded_text));
        }
    }
    Ok(json!({
        "session": summary,
        "local_usage_by_model": usage,
        "usage_note": "Token counts of the session's own requests. Costs are not included; the viewer prices usage.",
        "tools": tools,
    }))
}

fn message_rows(
    conn: &Connection,
    row_id: &str,
    after_index: i64,
    include_tools: bool,
    limit: i64,
) -> QueryResult<Vec<Map<String, Value>>> {
    let tools = if include_tools {
        ""
    } else {
        "and author_type in ('user', 'assistant')"
    };
    select_rows(
        conn,
        &format!(
            "select reference, message_index, author_type, raw_type, created_at_utc, model,
               content_plain, content_truncated as source_content_truncated, token_total
             from history_messages
             where session_row_id = ? and message_index > ? {tools}
             order by message_index limit ?"
        ),
        &[
            SqlValue::Text(row_id.to_owned()),
            SqlValue::Integer(after_index),
            SqlValue::Integer(limit + 1),
        ],
    )
}

fn messages(conn: &Connection, options: &Options) -> QueryResult<Value> {
    let (reference, _) = session_reference_option(options)?;
    let summary = resolve_session(conn, &reference)?;
    let row_id = summary["row_id"].as_str().unwrap_or("");
    let limit = bounded("--limit", options.limit, 20, 1, 100)?;
    let chars = bounded("--chars", options.chars, 1200, 100, 8000)?;
    let after = bounded(
        "--after-index",
        options.after_index,
        -1,
        -1,
        i64::from(i32::MAX),
    )?;
    let mut rows = message_rows(conn, row_id, after, options.include_tools, limit)?;
    let has_more = rows.len() as i64 > limit;
    rows.truncate(limit as usize);
    for row in &mut rows {
        let content = row
            .remove("content_plain")
            .and_then(|value| value.as_str().map(str::to_owned))
            .unwrap_or_default();
        let length = content.chars().count();
        let (excerpt, cut) = take_chars(&content, chars as usize);
        row.insert("content_length".to_owned(), json!(length));
        row.insert("excerpt".to_owned(), json!(excerpt));
        row.insert("excerpt_truncated".to_owned(), json!(cut));
        row.insert("next_text_offset".to_owned(), json!(cut.then_some(chars)));
    }
    let next = has_more
        .then(|| rows.last().map(|row| row["message_index"].clone()))
        .flatten();
    Ok(json!({
        "session_reference": summary["reference"],
        "include_tools": options.include_tools,
        "results": rows,
        "has_more": has_more,
        "next_after_index": next,
    }))
}

fn message(conn: &Connection, options: &Options) -> QueryResult<Value> {
    let (reference, index_from_ref) = session_reference_option(options)?;
    let index = match (options.index, index_from_ref) {
        (Some(index), _) | (None, Some(index)) => index,
        (None, None) => {
            return Err(QueryError::Usage(
                "message needs --index N or a --ref ending in #N".to_owned(),
            ));
        }
    };
    let summary = resolve_session(conn, &reference)?;
    let row_id = summary["row_id"].as_str().unwrap_or("");
    let chars = bounded("--chars", options.chars, 4000, 100, 20_000)?;
    let offset = bounded("--text-offset", options.text_offset, 0, 0, 100_000_000)?;
    let mut rows = select_rows(
        conn,
        "select reference, session_reference, message_index, author_type, raw_type,
           created_at_utc, model, token_total, content_truncated as source_content_truncated,
           length(coalesce(content_plain, '')) as content_length,
           substr(coalesce(content_plain, ''), ? + 1, ?) as excerpt
         from history_messages where session_row_id = ? and message_index = ?",
        &[
            SqlValue::Integer(offset),
            SqlValue::Integer(chars),
            SqlValue::Text(row_id.to_owned()),
            SqlValue::Integer(index),
        ],
    )?;
    let Some(mut row) = rows.pop() else {
        return Err(QueryError::NotFound(format!(
            "{} has no message {index}",
            summary["reference"].as_str().unwrap_or(&reference)
        )));
    };
    let length = row["content_length"].as_i64().unwrap_or(0);
    let returned = row["excerpt"]
        .as_str()
        .map_or(0, |text| text.chars().count() as i64);
    let end = offset + returned;
    row.insert("text_offset".to_owned(), json!(offset));
    row.insert("excerpt_truncated".to_owned(), json!(end < length));
    row.insert(
        "next_text_offset".to_owned(),
        json!((end < length).then_some(end)),
    );
    row.insert(
        "last_parsed_utc".to_owned(),
        summary["last_parsed_utc"].clone(),
    );
    Ok(json!({"result": row}))
}

fn export(conn: &Connection, options: &Options) -> QueryResult<Value> {
    let (reference, _) = session_reference_option(options)?;
    let mut summary = resolve_session(conn, &reference)?;
    let row_id = summary
        .remove("row_id")
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_default();
    let max = bounded("--max-messages", options.max_messages, 500, 1, 5000)?;
    let chars = bounded("--chars", options.chars, 8000, 100, 20_000)?;
    let budget = bounded(
        "--max-chars",
        options.max_chars,
        1_000_000,
        1000,
        10_000_000,
    )?;
    let after = bounded(
        "--after-index",
        options.after_index,
        -1,
        -1,
        i64::from(i32::MAX),
    )?;
    let format = options.export_format.as_deref().unwrap_or("json");
    if !matches!(format, "json" | "markdown") {
        return Err(QueryError::Usage(format!(
            "--export-format must be json or markdown, not {format:?}"
        )));
    }
    let tools = if options.include_tools {
        ""
    } else {
        "and author_type in ('user', 'assistant')"
    };
    let candidates = select_rows(
        conn,
        &format!(
            "select reference, message_index, author_type, raw_type, created_at_utc, model,
               substr(coalesce(content_plain, ''), 1, ?) as content_plain,
               length(coalesce(content_plain, '')) as content_length,
               content_truncated as source_content_truncated, token_total
             from history_messages
             where session_row_id = ? and message_index > ? {tools}
             order by message_index limit ?"
        ),
        &[
            SqlValue::Integer(chars),
            SqlValue::Text(row_id),
            SqlValue::Integer(after),
            SqlValue::Integer(max + 1),
        ],
    )?;
    let mut rows = Vec::new();
    let mut used = 0i64;
    let mut truncated = false;
    for mut row in candidates {
        if rows.len() as i64 == max {
            truncated = true;
            break;
        }
        let returned = row["content_plain"]
            .as_str()
            .map_or(0, |text| text.chars().count() as i64);
        // Always return at least one message so a page always advances.
        if !rows.is_empty() && used + returned > budget {
            truncated = true;
            break;
        }
        used += returned;
        let length = row["content_length"].as_i64().unwrap_or(0);
        row.insert(
            "content_truncated_by_export".to_owned(),
            json!(returned < length),
        );
        rows.push(row);
    }
    let next = truncated
        .then(|| rows.last().map(|row| row["message_index"].clone()))
        .flatten();
    let mut payload = json!({
        "session": summary,
        "include_tools": options.include_tools,
        "export_format": format,
        "chars_per_message": chars,
        "truncated": truncated,
        "next_after_index": next,
    });
    if format == "json" {
        payload["messages"] = json!(rows);
    } else {
        payload["markdown"] = json!(markdown(&payload["session"], &rows, truncated));
    }
    Ok(payload)
}

fn markdown(session: &Value, rows: &[Map<String, Value>], truncated: bool) -> String {
    let text = |key: &str| session[key].as_str().unwrap_or("").to_owned();
    let title = [text("title"), text("thread_name"), text("session_key")]
        .into_iter()
        .find(|value| !value.trim().is_empty())
        .unwrap_or_default();
    let mut out = format!("# {title}\n\n");
    for (label, key) in [
        ("Reference", "reference"),
        ("Project", "project"),
        ("Harness", "harness"),
        ("Working directory", "working_directory"),
        ("Started", "started_at_utc"),
        ("Last message", "last_message_at_utc"),
    ] {
        let value = text(key);
        if !value.is_empty() {
            out.push_str(&format!("- {label}: {value}\n"));
        }
    }
    out.push_str("\n## Conversation\n");
    for row in rows {
        let author = row["author_type"].as_str().unwrap_or("unknown");
        let time = row["created_at_utc"].as_str().unwrap_or("");
        let index = row["message_index"].as_i64().unwrap_or(0);
        out.push_str(&format!("\n### {index}. {author} {time}\n\n"));
        out.push_str(row["content_plain"].as_str().unwrap_or(""));
        out.push('\n');
    }
    if truncated {
        let last = rows
            .last()
            .and_then(|row| row["message_index"].as_i64())
            .unwrap_or(-1);
        out.push_str(&format!(
            "\n_Export truncated; continue with export --after-index {last}._\n"
        ));
    }
    out
}

// ---------------------------------------------------------------------------
// Text output

fn render_text(value: &Value) -> String {
    let mut out = String::new();
    let str_of = |row: &Value, key: &str| row[key].as_str().unwrap_or("").to_owned();
    match value["command"].as_str().unwrap_or("") {
        "search" | "sessions" | "messages" | "projects" => {
            for row in value["results"].as_array().into_iter().flatten() {
                let head = if row.get("reference").is_some() {
                    format!(
                        "{}  {}  {}",
                        str_of(row, "reference"),
                        str_of(row, "author_type"),
                        row["created_at_utc"]
                            .as_str()
                            .or_else(|| row["last_message_at_utc"].as_str())
                            .unwrap_or("")
                    )
                } else {
                    format!("{}  ({} sessions)", str_of(row, "project"), row["sessions"])
                };
                out.push_str(head.trim_end());
                out.push('\n');
                for key in ["title", "excerpt"] {
                    let text = str_of(row, key);
                    if !text.is_empty() {
                        out.push_str("  ");
                        out.push_str(&text.replace('\n', "\n  "));
                        out.push('\n');
                    }
                }
            }
            if value["has_more"] == json!(true) {
                if let Some(cursor) = value["next_cursor"].as_str() {
                    out.push_str(&format!("-- more: --cursor {cursor}\n"));
                } else if let Some(index) = value["next_after_index"].as_i64() {
                    out.push_str(&format!("-- more: --after-index {index}\n"));
                }
            }
            if out.is_empty() {
                out.push_str("No matches.\n");
            }
        }
        "message" => {
            let row = &value["result"];
            out.push_str(&format!(
                "{}  {}  {}\n{}\n",
                str_of(row, "reference"),
                str_of(row, "author_type"),
                str_of(row, "created_at_utc"),
                str_of(row, "excerpt")
            ));
            if let Some(next) = row["next_text_offset"].as_i64() {
                out.push_str(&format!("-- more: --text-offset {next}\n"));
            }
        }
        "export" if value["markdown"].is_string() => {
            out.push_str(value["markdown"].as_str().unwrap_or(""));
        }
        _ => {
            out = serde_json::to_string_pretty(value).unwrap_or_default();
        }
    }
    out.trim_end().to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn queries_are_literal_words() {
        assert_eq!(
            fts_query("shutdown queue").unwrap(),
            "\"shutdown\" AND \"queue\""
        );
        assert_eq!(
            fts_query("a\" OR b*").unwrap(),
            "\"a\" AND \"OR\" AND \"b\""
        );
        assert!(fts_query("  ").is_err());
        assert!(fts_query(&"w ".repeat(31)).is_err());
    }

    #[test]
    fn cursors_round_trip_and_reject_other_commands() {
        let cursor = encode_cursor("search", "scope", &[json!("2026"), json!(3)]);
        assert_eq!(
            decode_cursor("search", "scope", &cursor).unwrap(),
            vec![json!("2026"), json!(3)]
        );
        assert!(decode_cursor("sessions", "scope", &cursor).is_err());
        assert!(decode_cursor("search", "other", &cursor).is_err());
        assert!(decode_cursor("search", "scope", "zz").is_err());
    }

    #[test]
    fn instants_need_a_zone() {
        assert_eq!(
            parse_instant("--since", "2026-09-01").unwrap(),
            "2026-09-01T00:00:00.000Z"
        );
        assert_eq!(
            parse_instant("--since", "2026-09-01T10:00:00+02:00").unwrap(),
            "2026-09-01T08:00:00.000Z"
        );
        assert!(parse_instant("--since", "2026-09-01T10:00:00").is_err());
        assert!(parse_instant("--since", "yesterday").is_err());
    }

    #[test]
    fn message_references_split_at_a_numeric_suffix() {
        assert_eq!(
            split_message_reference("history://m/codex/s#12"),
            ("history://m/codex/s", Some(12))
        );
        assert_eq!(
            split_message_reference("history://m/codex/s"),
            ("history://m/codex/s", None)
        );
        assert_eq!(split_message_reference("a#b"), ("a#b", None));
    }
}
