//! Port of `CodexSessionIndexReader` and `_readSessionIndexThreadNames`.

use std::collections::HashMap;
use std::io::{BufRead, BufReader};

use serde_json::Value;

use crate::dart::{DartDateTime, json_decode, trim};
use crate::path_mapping::join;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ThreadNameEntry {
    pub id: String,
    pub thread_name: String,
    pub updated_at_utc: Option<DartDateTime>,
}

fn is_newer(candidate: Option<DartDateTime>, previous: Option<DartDateTime>) -> bool {
    match (candidate, previous) {
        (None, previous) => previous.is_none(),
        (Some(_), None) => true,
        (Some(candidate), Some(previous)) => candidate.is_after(previous),
    }
}

/// Entries of one `session_index.jsonl`, newest name per session ID. A
/// missing or unreadable file yields no entries.
pub fn read_session_index(path: &str) -> HashMap<String, ThreadNameEntry> {
    let mut entries: HashMap<String, ThreadNameEntry> = HashMap::new();
    let Ok(file) = std::fs::File::open(path) else {
        return entries;
    };
    let mut reader = BufReader::new(file);
    let mut segment = Vec::new();
    loop {
        segment.clear();
        match reader.read_until(b'\n', &mut segment) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        let Ok(text) = std::str::from_utf8(&segment) else {
            break;
        };
        for line in text.split(['\n', '\r']) {
            let trimmed = trim(line);
            if trimmed.is_empty() {
                continue;
            }
            let Ok(Value::Object(value)) = json_decode(trimmed) else {
                continue;
            };
            let text_field = |key: &str| match value.get(key) {
                Some(Value::String(text)) => Some(Some(trim(text).to_owned())),
                None | Some(Value::Null) => Some(None),
                // `as String?` throws for other types; the row is skipped.
                Some(_) => None,
            };
            let (Some(id), Some(thread_name), Some(updated_at)) = (
                text_field("id"),
                text_field("thread_name"),
                text_field("updated_at"),
            ) else {
                continue;
            };
            let id = id.unwrap_or_default();
            let thread_name = thread_name.unwrap_or_default();
            if id.is_empty() || thread_name.is_empty() {
                continue;
            }
            let candidate = ThreadNameEntry {
                id: id.clone(),
                thread_name,
                updated_at_utc: DartDateTime::try_parse(&updated_at.unwrap_or_default()),
            };
            let replace = match entries.get(&id) {
                None => true,
                Some(previous) => is_newer(candidate.updated_at_utc, previous.updated_at_utc),
            };
            if replace {
                entries.insert(id, candidate);
            }
        }
    }
    entries
}

/// Names from both configured Codex homes, newest first.
pub fn read_thread_names(codex_homes: &[&str]) -> HashMap<String, ThreadNameEntry> {
    let mut merged: HashMap<String, ThreadNameEntry> = HashMap::new();
    for home in codex_homes {
        if home.is_empty() {
            continue;
        }
        for entry in read_session_index(&join(home, "session_index.jsonl")).into_values() {
            let replace = match merged.get(&entry.id) {
                None => true,
                Some(previous) => is_newer(entry.updated_at_utc, previous.updated_at_utc),
            };
            if replace {
                merged.insert(entry.id.clone(), entry);
            }
        }
    }
    merged
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn newest_name_wins_and_bad_rows_are_skipped() {
        let dir = std::env::temp_dir().join(format!("csv_index_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("session_index.jsonl");
        std::fs::write(
            &file,
            concat!(
                "{\"id\":\"a\",\"thread_name\":\"Old\",\"updated_at\":\"2026-01-01T00:00:00Z\"}\n",
                "not json\n",
                "{\"id\":\"a\",\"thread_name\":\" New \",\"updated_at\":\"2026-02-01T00:00:00Z\"}\n",
                "{\"id\":7,\"thread_name\":\"x\"}\n",
                "{\"id\":\"b\",\"thread_name\":\"\"}\n",
            ),
        )
        .unwrap();
        let entries = read_session_index(&file.to_string_lossy());
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries["a"].thread_name, "New");
    }
}
