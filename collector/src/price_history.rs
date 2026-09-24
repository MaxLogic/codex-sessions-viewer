//! Immutable public price evidence shared by machines. No session content is
//! accepted by the provider fetcher or included in its requests.

use std::collections::{BTreeMap, HashSet};
use std::io::Read;
use std::path::Path;
use std::time::Duration;

use chrono::{DateTime, SecondsFormat, Utc};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Deserialize;
use serde_json::{Map, Value, json};

use crate::store::{OwnerMode, Store};

type Error = (u16, String);
fn invalid(message: &str) -> Error {
    (400, message.into())
}
fn database_error(_: impl std::fmt::Display) -> Error {
    (500, "price history database operation failed".into())
}

/// Dart compares JSON keys as UTF-16 code units, including supplementary keys.
pub fn canonical_json(value: &Value) -> String {
    fn sorted(value: &Value) -> Value {
        match value {
            Value::Object(map) => {
                let mut keys: Vec<_> = map.keys().collect();
                keys.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
                Value::Object(
                    keys.into_iter()
                        .map(|k| (k.clone(), sorted(&map[k])))
                        .collect(),
                )
            }
            Value::Array(items) => Value::Array(items.iter().map(sorted).collect()),
            _ => value.clone(),
        }
    }
    serde_json::to_string(&sorted(value)).expect("JSON Value serialization cannot fail")
}

pub fn fingerprint(value: &Value) -> String {
    crate::dart::sha256_hex(canonical_json(value).as_bytes())
}

#[derive(Clone, Debug)]
pub struct Observation {
    pub value: Value,
    pub fingerprint: String,
    at: DateTime<Utc>,
}

impl Observation {
    pub fn parse(value: &Value) -> Result<Self, Error> {
        if canonical_json(value).len() > 1024 * 1024 {
            return Err(invalid("price observation exceeds 1 MiB"));
        }
        let text = |key: &str| {
            value
                .get(key)
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty())
                .ok_or_else(|| invalid("price observation has missing identity fields"))
        };
        let origin = text("origin")?;
        let authority = text("authority")?;
        if !["hub", "local"].contains(&authority) {
            return Err(invalid("invalid price authority"));
        }
        let parsed = DateTime::parse_from_rfc3339(text("observed_at_utc")?)
            .map_err(|_| invalid("invalid observation UTC timestamp"))?
            .with_timezone(&Utc);
        let at = DateTime::from_timestamp_micros(parsed.timestamp_micros())
            .ok_or_else(|| invalid("observation timestamp out of range"))?;
        let provider = text("provider")?;
        let model_id = text("model_id")?;
        let expected_provider = model_id
            .split_once('/')
            .map(|(provider, _)| provider)
            .filter(|v| !v.is_empty())
            .unwrap_or("unknown");
        if provider != expected_provider {
            return Err(invalid("provider does not match model identity"));
        }
        let model = value
            .get("model")
            .filter(|v| v.is_object())
            .ok_or_else(|| invalid("missing model price payload"))?;
        fn integer_numbers(value: &Value) -> bool {
            match value {
                Value::Number(number) => number.as_i64().is_some(),
                Value::Array(items) => items.iter().all(integer_numbers),
                Value::Object(items) => items.values().all(integer_numbers),
                _ => true,
            }
        }
        if !integer_numbers(model) {
            return Err(invalid(
                "wire model numbers must be signed integers; preserve arbitrary provider metadata in raw_pricing_json",
            ));
        }
        if model["id"].as_str() != Some(model_id) {
            return Err(invalid("model identity does not match observation"));
        }
        validate_rates(
            model
                .get("pricing")
                .and_then(Value::as_object)
                .ok_or_else(|| invalid("missing model pricing"))?,
        )?;
        let value = json!({"origin":origin,"authority":authority,"observed_at_utc":at.to_rfc3339_opts(SecondsFormat::Micros,true),"provider":provider,"model_id":model_id,"model":model});
        Ok(Self {
            fingerprint: fingerprint(&value),
            value,
            at,
        })
    }
    pub fn slot(&self) -> i64 {
        self.at.timestamp_millis() / 21_600_000
    }
}

fn validate_rates(rates: &Map<String, Value>) -> Result<(), Error> {
    for (key, value) in rates {
        match key.as_str() {
            "min_prompt_tokens" | "utc_start" | "utc_end" | "utc_days" => {}
            "overrides" => {
                for rule in value
                    .as_array()
                    .ok_or_else(|| invalid("invalid pricing rules"))?
                {
                    validate_rule(
                        rule.as_object()
                            .ok_or_else(|| invalid("invalid pricing rule"))?,
                    )?;
                }
            }
            _ if value.is_null() => {}
            _ => {
                let s = value.as_str().ok_or_else(|| {
                    invalid("price rates must be decimal strings or unknown null")
                })?;
                let parts: Vec<_> = s.split('.').collect();
                if s != "-1"
                    && (parts.len() > 2
                        || parts
                            .iter()
                            .any(|p| p.is_empty() || !p.bytes().all(|c| c.is_ascii_digit())))
                {
                    return Err(invalid(
                        "price rates must be nonnegative decimal strings or unknown -1",
                    ));
                }
            }
        }
    }
    Ok(())
}

fn validate_rule(rule: &Map<String, Value>) -> Result<(), Error> {
    const RATES: [&str; 13] = [
        "prompt",
        "completion",
        "input_cache_read",
        "input_cache_write",
        "internal_reasoning",
        "request",
        "image",
        "web_search",
        "audio",
        "audio_output",
        "image_output",
        "input_audio_cache",
        "input_cache_write_1h",
    ];
    let mut rates = Map::new();
    for (key, value) in rule {
        if RATES.contains(&key.as_str()) {
            if value.is_null() || value == "-1" {
                return Err(invalid("conditional rates cannot be unknown"));
            }
            rates.insert(key.clone(), value.clone());
        } else if !["min_prompt_tokens", "utc_start", "utc_end", "utc_days"].contains(&key.as_str())
        {
            return Err(invalid("unsupported pricing rule field"));
        }
    }
    if rates.is_empty() {
        return Err(invalid("pricing rule has no rates"));
    }
    validate_rates(&rates)?;
    if rule
        .get("min_prompt_tokens")
        .is_some_and(|v| v.as_u64().is_none())
    {
        return Err(invalid("invalid prompt threshold"));
    }
    let minute = |key: &str| -> Result<Option<u64>, Error> {
        rule.get(key)
            .map(|v| {
                v.as_u64()
                    .filter(|v| *v <= 2359 && *v % 100 <= 59)
                    .ok_or_else(|| invalid("invalid UTC HHMM time"))
            })
            .transpose()
    };
    let start = minute("utc_start")?;
    let end = minute("utc_end")?;
    if start.is_some() != end.is_some() || (start.is_some() && start == end) {
        return Err(invalid("incomplete or ambiguous UTC window"));
    }
    if let Some(days) = rule.get("utc_days") {
        let days = days
            .as_array()
            .filter(|v| !v.is_empty())
            .ok_or_else(|| invalid("invalid UTC weekdays"))?;
        for day in days {
            if !day.as_str().is_some_and(|v| {
                [
                    "monday",
                    "tuesday",
                    "wednesday",
                    "thursday",
                    "friday",
                    "saturday",
                    "sunday",
                ]
                .contains(&v)
            }) {
                return Err(invalid("invalid UTC weekday"));
            }
        }
    }
    Ok(())
}

pub struct History {
    pub revision: String,
    pub observations: BTreeMap<String, Observation>,
}
impl History {
    pub fn new(input: impl IntoIterator<Item = Observation>) -> Self {
        let observations: BTreeMap<_, _> = input
            .into_iter()
            .map(|o| (o.fingerprint.clone(), o))
            .collect();
        let revision = fingerprint(&json!(observations.keys().collect::<Vec<_>>()));
        Self {
            revision,
            observations,
        }
    }
    pub fn response(&self) -> Value {
        json!({"protocol":1,"revision":self.revision,"observations":self.observations.values().map(|o| &o.value).collect::<Vec<_>>()})
    }
    /// Hub precedence applies only to genuinely conflicting evidence at the
    /// same provider/model/instant. Six-hour fetch slots never erase chronology.
    pub fn winners(&self) -> Vec<&Observation> {
        let mut slots: BTreeMap<(String, String, DateTime<Utc>), &Observation> = BTreeMap::new();
        for observation in self.observations.values() {
            let key = (
                observation.value["provider"].as_str().unwrap().into(),
                observation.value["model_id"].as_str().unwrap().into(),
                observation.at,
            );
            let rank =
                |o: &Observation| (o.value["authority"] == "hub", o.at, o.fingerprint.clone());
            if slots
                .get(&key)
                .is_none_or(|prior| rank(observation) > rank(prior))
            {
                slots.insert(key, observation);
            }
        }
        slots.into_values().collect()
    }
}

fn open(data_root: &Path) -> Result<Store, Error> {
    let directory = data_root.join("hub-pricing");
    std::fs::create_dir_all(&directory).map_err(database_error)?;
    Store::open(&directory.join("history.sqlite"), OwnerMode::Standalone).map_err(database_error)
}

fn read(conn: &Connection) -> Result<History, Error> {
    let mut stmt = conn
        .prepare("select payload_json from price_observations order by fingerprint")
        .map_err(database_error)?;
    let rows = stmt
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(database_error)?;
    let mut observations = Vec::new();
    for row in rows {
        observations.push(Observation::parse(
            &serde_json::from_str(&row.map_err(database_error)?).map_err(database_error)?,
        )?);
    }
    Ok(History::new(observations))
}

fn revision_at(conn: &Connection, through: i64) -> Result<String, Error> {
    use sha2::{Digest, Sha256};
    let mut digest = Sha256::new();
    digest.update(b"[");
    let mut stmt = conn
        .prepare("select fingerprint from price_observations where rowid<=? order by fingerprint")
        .map_err(database_error)?;
    let rows = stmt
        .query_map([through], |r| r.get::<_, String>(0))
        .map_err(database_error)?;
    for (index, row) in rows.enumerate() {
        if index > 0 {
            digest.update(b",");
        }
        digest.update(
            serde_json::to_string(&row.map_err(database_error)?)
                .unwrap()
                .as_bytes(),
        );
    }
    digest.update(b"]");
    Ok(digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}
fn latest_rowid(conn: &Connection) -> Result<i64, Error> {
    conn.query_row(
        "select coalesce(max(rowid),0) from price_observations",
        [],
        |r| r.get(0),
    )
    .map_err(database_error)
}
fn merge_conn(conn: &Connection, observations: &[Observation]) -> Result<String, Error> {
    for o in observations {
        conn.execute("insert or ignore into price_observations(fingerprint,origin,authority,observed_at_utc,provider,model_id,payload_json) values (?,?,?,?,?,?,?)",params![o.fingerprint,o.value["origin"].as_str(),o.value["authority"].as_str(),o.value["observed_at_utc"].as_str(),o.value["provider"].as_str(),o.value["model_id"].as_str(),canonical_json(&o.value)]).map_err(database_error)?;
    }
    let through = latest_rowid(conn)?;
    let revision = revision_at(conn, through)?;
    // Hub revisions retain a cursor into append-only immutable evidence rather
    // than copying the whole catalog for every refresh. Local Dart revisions
    // retain their own materialization metadata in the same generic JSON field.
    conn.execute("insert or ignore into price_history_revisions(revision,observations_json,created_at_utc) values (?,?,?)",params![revision,json!({"through_rowid":through}).to_string(),Utc::now().to_rfc3339_opts(SecondsFormat::Micros,true)]).map_err(database_error)?;
    conn.execute(
        "update price_history_state set revision=? where id=1",
        [&revision],
    )
    .map_err(database_error)?;
    Ok(revision)
}

pub fn synchronize(data_root: &Path, machine: &str, input: Value) -> Result<Value, Error> {
    if input["protocol"] != 1 {
        return Err(invalid("unsupported price history protocol"));
    }
    let incoming = input["observations"]
        .as_array()
        .ok_or_else(|| invalid("observations must be an array"))?;
    if incoming.len() > 512 {
        return Err(invalid("upload at most 512 price observations per request"));
    }
    let mut observations = Vec::with_capacity(incoming.len());
    for value in incoming {
        let observation = Observation::parse(value)?;
        if observation.value["authority"] != "local" || observation.value["origin"] != machine {
            return Err((
                403,
                "price observations must be local evidence from the authenticated machine".into(),
            ));
        }
        observations.push(observation);
    }
    let paged = input.get("after").is_some() || input.get("download").is_some();
    let download = input
        .get("download")
        .map(|v| {
            v.as_bool()
                .ok_or_else(|| invalid("download must be boolean"))
        })
        .transpose()?
        .unwrap_or(true);
    let after = input
        .get("after")
        .map(|v| {
            v.as_i64()
                .filter(|v| *v >= 0)
                .ok_or_else(|| invalid("after must be a nonnegative row cursor"))
        })
        .transpose()?
        .unwrap_or(0);
    let requested_through = input
        .get("through")
        .filter(|v| !v.is_null())
        .map(|v| {
            v.as_i64()
                .filter(|v| *v >= 0)
                .ok_or_else(|| invalid("through must be a nonnegative row cursor"))
        })
        .transpose()?;
    let store = open(data_root)?;
    store
        .conn
        .execute_batch("begin immediate")
        .map_err(database_error)?;
    let result = (|| {
        let revision = merge_conn(&store.conn, &observations)?;
        if !download {
            return Ok(json!({"protocol":1,"revision":revision,"accepted":observations.len()}));
        }
        let latest = latest_rowid(&store.conn)?;
        let through = requested_through.unwrap_or(latest);
        if after > through || through > latest {
            return Err((
                409,
                "price history cursor is no longer available; restart with after=0".into(),
            ));
        }
        if !paged {
            let (count, bytes): (i64, i64) = store
                .conn
                .query_row(
                    "select count(*),coalesce(sum(length(payload_json)),0) from price_observations",
                    [],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .map_err(database_error)?;
            if count > 512 || bytes > 4 * 1024 * 1024 {
                return Err(invalid(
                    "price history requires paged download with after=0",
                ));
            }
            return Ok(read(&store.conn)?.response());
        }
        let mut stmt=store.conn.prepare("select rowid,payload_json from price_observations where rowid>? and rowid<=? order by rowid limit 512").map_err(database_error)?;
        let rows = stmt
            .query_map(params![after, through], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?))
            })
            .map_err(database_error)?;
        let mut values = Vec::<Value>::new();
        let mut cursor = after;
        let mut bytes = 0usize;
        for row in rows {
            let (rowid, text) = row.map_err(database_error)?;
            // Bound each page by count and bytes. One observation is limited
            // to 1 MiB at ingestion, so at least one item always fits.
            if bytes + text.len() > 4 * 1024 * 1024 && !values.is_empty() {
                break;
            }
            bytes += text.len();
            cursor = rowid;
            values.push(serde_json::from_str(&text).map_err(database_error)?);
        }
        let complete = cursor >= through;
        Ok(
            json!({"protocol":1,"revision":revision_at(&store.conn,through)?,"observations":values,"after":cursor,"through":through,"complete":complete}),
        )
    })();
    match result {
        Ok(response) => {
            store.conn.execute_batch("commit").map_err(database_error)?;
            Ok(response)
        }
        Err(error) => {
            let _ = store.conn.execute_batch("rollback");
            Err(error)
        }
    }
}

#[derive(Clone, Deserialize)]
#[serde(default)]
pub struct FetchConfig {
    pub enabled: bool,
    pub endpoint: String,
    pub interval_hours: u32,
}
impl Default for FetchConfig {
    fn default() -> Self {
        Self {
            enabled: false,
            endpoint: "https://openrouter.ai/api/v1/models".into(),
            interval_hours: 6,
        }
    }
}

pub fn slot_at(now: DateTime<Utc>, interval_hours: u32) -> i64 {
    now.timestamp()
        .div_euclid(i64::from(interval_hours.max(1)) * 3600)
}

fn metadata(conn: &Connection, key: &str) -> Result<Option<String>, Error> {
    conn.query_row("select value from app_metadata where key=?", [key], |r| {
        r.get(0)
    })
    .optional()
    .map_err(database_error)
}
fn set_metadata(conn: &Connection, key: &str, value: &str) -> Result<(), Error> {
    conn.execute("insert into app_metadata(key,value,updated_at_utc) values (?,?,?) on conflict(key) do update set value=excluded.value,updated_at_utc=excluded.updated_at_utc",params![key,value,Utc::now().to_rfc3339_opts(SecondsFormat::Micros,true)]).map_err(database_error)?;
    Ok(())
}
pub fn fetch_due(
    data_root: &Path,
    config: &FetchConfig,
    now: DateTime<Utc>,
) -> Result<bool, Error> {
    if !config.enabled {
        return Ok(false);
    }
    let store = open(data_root)?;
    let current = slot_at(now, config.interval_hours);
    let last = metadata(&store.conn, "hub_prices.last_success_utc")?
        .and_then(|v| DateTime::parse_from_rfc3339(&v).ok())
        .map(|at| slot_at(at.with_timezone(&Utc), config.interval_hours));
    let retry = metadata(&store.conn, "hub_prices.retry_at")?
        .and_then(|v| DateTime::parse_from_rfc3339(&v).ok());
    Ok(last.is_none_or(|last| last < current) && retry.is_none_or(|retry| now >= retry))
}

/// Fetch complete catalog before opening a write transaction. A failed page
/// records a retry; it never publishes a partial authoritative catalog.
pub fn fetch_once(data_root: &Path, config: &FetchConfig) -> Result<usize, Error> {
    if !config.enabled {
        return Ok(0);
    }
    let mut retry_after = None;
    let result = fetch_catalog(&config.endpoint, &mut retry_after);
    let completed = Utc::now();
    let result = result.and_then(|models| {
        let mut observations = Vec::new();
            for model in models {
                let id = model["id"]
                    .as_str()
                    .ok_or_else(|| invalid("provider model has no id"))?;
                let provider = id
                    .split_once('/')
                    .map(|(provider, _)| provider)
                    .filter(|v| !v.is_empty())
                    .unwrap_or("unknown");
                let mut wire = json!({"id":id,"pricing":model["pricing"],"raw_pricing_json":serde_json::to_string(&model).map_err(database_error)?});
                for key in ["name", "canonical_slug"] {
                    if let Some(value) = model.get(key).filter(|v| v.is_string()) {
                        wire[key] = value.clone();
                    }
                }
                observations.push(Observation::parse(&json!({"origin":"hub","authority":"hub","observed_at_utc":completed.to_rfc3339_opts(SecondsFormat::Micros,true),"provider":provider,"model_id":id,"model":wire}))?);
            }
        Ok(observations)
    });
    let store = open(data_root)?;
    store
        .conn
        .execute_batch("begin immediate")
        .map_err(database_error)?;
    let commit = (|| match result {
        Ok(mut observations) => {
            let current_ids: HashSet<_> = observations
                .iter()
                .map(|o| o.value["model_id"].as_str().unwrap().to_owned())
                .collect();
            // Only a fully validated catalog may close formerly authoritative
            // models. Unrelated local-only models remain useful gap evidence.
            let previous = read(&store.conn)?;
            let mut latest: BTreeMap<(String, String), &Observation> = BTreeMap::new();
            for observation in previous
                .observations
                .values()
                .filter(|o| o.value["authority"] == "hub")
            {
                let key = (
                    observation.value["provider"].as_str().unwrap().to_owned(),
                    observation.value["model_id"].as_str().unwrap().to_owned(),
                );
                if latest
                    .get(&key)
                    .is_none_or(|prior| observation.at > prior.at)
                {
                    latest.insert(key, observation);
                }
            }
            for ((provider, id), prior) in latest {
                if !current_ids.contains(&id) && prior.value["model"]["removed"] != true {
                    observations.push(Observation::parse(&json!({"origin":"hub","authority":"hub","observed_at_utc":completed.to_rfc3339_opts(SecondsFormat::Micros,true),"provider":provider,"model_id":id,"model":{"id":id,"pricing":{},"removed":true}}))?);
                }
            }
            merge_conn(&store.conn, &observations)?;
            set_metadata(
                &store.conn,
                "hub_prices.success_slot",
                &slot_at(completed, config.interval_hours).to_string(),
            )?;
            set_metadata(
                &store.conn,
                "hub_prices.last_success_utc",
                &completed.to_rfc3339_opts(SecondsFormat::Micros, true),
            )?;
            set_metadata(&store.conn, "hub_prices.retry_at", "")?;
            set_metadata(&store.conn, "hub_prices.retry_count", "0")?;
            set_metadata(&store.conn, "hub_prices.error", "")?;
            Ok(observations.len())
        }
        Err(error) => {
            let count = metadata(&store.conn, "hub_prices.retry_count")?
                .and_then(|v| v.parse::<u32>().ok())
                .unwrap_or(0)
                .saturating_add(1);
            let base = [15i64, 60, 240, 720, 1440][(count.saturating_sub(1) as usize).min(4)] * 60;
            let jitter = (completed.timestamp_subsec_micros() as i64 % (base / 10 + 1)) + 1;
            let delay = (base + jitter).max(retry_after.unwrap_or(0)).min(86400);
            set_metadata(&store.conn, "hub_prices.retry_count", &count.to_string())?;
            set_metadata(
                &store.conn,
                "hub_prices.retry_at",
                &(completed + chrono::Duration::seconds(delay))
                    .to_rfc3339_opts(SecondsFormat::Micros, true),
            )?;
            set_metadata(&store.conn, "hub_prices.error", &error.1)?;
            Ok(0)
        }
    })();
    match commit {
        Ok(count) => {
            store.conn.execute_batch("commit").map_err(database_error)?;
            Ok(count)
        }
        Err(error) => {
            let _ = store.conn.execute_batch("rollback");
            Err(error)
        }
    }
}

fn fetch_catalog(endpoint: &str, retry_after: &mut Option<i64>) -> Result<Vec<Value>, Error> {
    let base = endpoint
        .parse::<ureq::http::Uri>()
        .map_err(|_| invalid("invalid provider endpoint"))?;
    let scheme = base.scheme_str().unwrap_or("");
    let host = base.host().unwrap_or("");
    if !(scheme == "https"
        || (scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(&host)))
        || endpoint.contains('@')
    {
        return Err(invalid(
            "provider endpoint requires HTTPS or loopback without credentials",
        ));
    }
    let origin = format!(
        "{}://{}",
        scheme,
        base.authority()
            .ok_or_else(|| invalid("provider endpoint has no authority"))?
    );
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(30)))
        .max_redirects(0)
        .http_status_as_error(false)
        .build()
        .into();
    let mut url = endpoint.to_owned();
    let mut visited = HashSet::new();
    let mut ids = HashSet::new();
    let mut models = Vec::new();
    let mut total = None;
    let mut bytes_total = 0usize;
    loop {
        if !visited.insert(url.clone()) || visited.len() > 100 {
            return Err(invalid("provider pagination cycle or limit"));
        }
        let mut response = agent
            .get(&url)
            .header("Accept", "application/json")
            .call()
            .map_err(|_| (502, "provider price request failed; retry scheduled".into()))?;
        if !response.status().is_success() {
            *retry_after = response
                .headers()
                .get("Retry-After")
                .and_then(|v| v.to_str().ok())
                .and_then(|v| {
                    v.parse::<i64>().ok().or_else(|| {
                        DateTime::parse_from_rfc2822(v)
                            .ok()
                            .map(|at| (at.with_timezone(&Utc) - Utc::now()).num_seconds())
                    })
                })
                .map(|v| v.clamp(0, 86400));
            return Err((
                502,
                "provider price request rejected; retry scheduled".into(),
            ));
        }
        let mut bytes = Vec::new();
        response
            .body_mut()
            .as_reader()
            .take(5 * 1024 * 1024 + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| (502, "provider price response read failed".into()))?;
        bytes_total += bytes.len();
        if bytes.len() > 5 * 1024 * 1024 || bytes_total > 50 * 1024 * 1024 {
            return Err(invalid("provider catalog exceeds size limit"));
        }
        let page: Value =
            serde_json::from_slice(&bytes).map_err(|_| invalid("provider catalog JSON invalid"))?;
        if let Some(declared) = page.get("total_count").filter(|v| !v.is_null()) {
            let n = declared
                .as_u64()
                .filter(|n| *n <= 100_000)
                .ok_or_else(|| invalid("invalid provider total count"))?
                as usize;
            if total.is_some_and(|previous| previous != n) {
                return Err(invalid("provider page totals differ"));
            }
            total = Some(n);
        }
        for model in page["data"]
            .as_array()
            .ok_or_else(|| invalid("provider catalog data missing"))?
        {
            let id = model["id"]
                .as_str()
                .filter(|s| !s.is_empty())
                .ok_or_else(|| invalid("provider model id missing"))?;
            if !ids.insert(id.to_owned()) || ids.len() > 100_000 {
                return Err(invalid("provider model ids repeat or exceed limit"));
            }
            validate_rates(
                model["pricing"]
                    .as_object()
                    .ok_or_else(|| invalid("provider pricing missing"))?,
            )?;
            models.push(model.clone());
        }
        match page
            .get("links")
            .and_then(|v| v.get("next"))
            .filter(|v| !v.is_null())
        {
            None => break,
            Some(value) => {
                let next = value
                    .as_str()
                    .filter(|v| !v.is_empty())
                    .ok_or_else(|| invalid("invalid provider continuation"))?;
                url = if next.starts_with('/') && !next.starts_with("//") {
                    format!("{origin}{next}")
                } else if next.starts_with('?') {
                    format!("{}{}", url.split('?').next().unwrap(), next)
                } else if !next.contains("://") && !next.starts_with("//") {
                    let current = url.split('?').next().unwrap();
                    let directory = current
                        .rsplit_once('/')
                        .map(|(directory, _)| directory)
                        .unwrap_or(&origin);
                    format!("{directory}/{next}")
                } else {
                    next.to_owned()
                };
                let target = url
                    .parse::<ureq::http::Uri>()
                    .map_err(|_| invalid("invalid provider continuation URI"))?;
                if target.scheme_str() != base.scheme_str()
                    || target.authority() != base.authority()
                {
                    return Err(invalid("provider continuation changed origin"));
                }
            }
        }
    }
    if models.is_empty() || total.is_some_and(|total| total != models.len()) {
        return Err(invalid("provider catalog is empty or incomplete"));
    }
    Ok(models)
}

/// Lifetime is owned by the server; stop wakes the worker promptly.
pub struct Worker {
    stop: std::sync::mpsc::Sender<()>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Worker {
    pub fn start(root: &Path, config: FetchConfig) -> Result<Option<Self>, String> {
        if !config.enabled {
            return Ok(None);
        }
        if !(1..=168).contains(&config.interval_hours) {
            return Err("pricing interval_hours must be between 1 and 168".into());
        }
        let root = root.to_owned();
        let (stop, receiver) = std::sync::mpsc::channel();
        let thread = std::thread::Builder::new()
            .name("hub-price-refresh".into())
            .spawn(move || {
                loop {
                    if fetch_due(&root, &config, Utc::now()).unwrap_or(false) {
                        let _ = fetch_once(&root, &config);
                    }
                    if receiver.recv_timeout(Duration::from_secs(30))
                        != Err(std::sync::mpsc::RecvTimeoutError::Timeout)
                    {
                        break;
                    }
                }
            })
            .map_err(|_| "could not start hub pricing worker")?;
        Ok(Some(Self {
            stop,
            thread: Some(thread),
        }))
    }
}
impl Drop for Worker {
    fn drop(&mut self) {
        let _ = self.stop.send(());
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
