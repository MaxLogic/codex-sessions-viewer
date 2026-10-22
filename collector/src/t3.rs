//! Optional read-only T3 v2 projection lookup. Native references, never app IDs
//! or provider-session IDs, identify the provider transcripts in this store.
use rusqlite::{Connection, OpenFlags, params};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::Path;

fn field<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key)?.as_str().filter(|s| !s.trim().is_empty())
}

fn payloads(conn: &Connection, table: &str) -> Result<Vec<Value>, String> {
    let mut stmt = conn
        .prepare(&format!("select payload_json from {table}"))
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(|e| e.to_string())?;
    rows.map(|row| {
        serde_json::from_str(&row.map_err(|e| e.to_string())?).map_err(|e| e.to_string())
    })
    .collect()
}

/// A failed optional lookup leaves the last known relationships intact. A
/// successful snapshot replaces only T3 metadata in the configured source.
pub fn import(viewer: &Connection, path: &Path, source: &str) -> Result<usize, String> {
    let t3 = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(|e| e.to_string())?;
    t3.busy_timeout(std::time::Duration::from_millis(100))
        .map_err(|e| e.to_string())?;
    t3.execute_batch("pragma query_only = on; begin")
        .map_err(|e| e.to_string())?;
    let threads = payloads(&t3, "orchestration_v2_projection_threads")?;
    let providers = payloads(&t3, "orchestration_v2_projection_provider_threads")?;
    let mut sessions: HashMap<(String, String), Vec<String>> = HashMap::new();
    let mut stmt = viewer
        .prepare("select id, harness, session_id from sessions where source_type = ? and parse_status = 'available' and scan_status = 'available'")
        .map_err(|e| e.to_string())?;
    let rows = stmt
        .query_map([source], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, Option<String>>(2)?,
            ))
        })
        .map_err(|e| e.to_string())?;
    for row in rows {
        let (id, harness, native) = row.map_err(|e| e.to_string())?;
        if let Some(native) = native {
            sessions.entry((harness, native)).or_default().push(id);
        }
    }
    // One app thread may have several historical provider bindings. A native
    // ID may also be reported by several instances: ambiguity is not a match.
    let mut app_sessions: HashMap<String, HashSet<String>> = HashMap::new();
    let mut session_apps: HashMap<String, HashSet<String>> = HashMap::new();
    for provider in providers {
        let Some(app) = field(&provider, "appThreadId") else {
            continue;
        };
        let Some(reference) = provider.get("nativeThreadRef") else {
            continue;
        };
        let Some(native) = field(reference, "nativeId") else {
            continue;
        };
        if field(reference, "strength") != Some("strong") {
            continue;
        }
        let driver = field(&provider, "driver");
        if driver != field(reference, "driver") {
            continue;
        }
        let harness = match driver {
            Some("codex") => "codex",
            Some("claudeAgent") => "claude",
            _ => continue,
        };
        if let Some(ids) = sessions.get(&(harness.to_owned(), native.to_owned())) {
            if ids.len() != 1 {
                continue;
            }
            app_sessions
                .entry(app.to_owned())
                .or_default()
                .insert(ids[0].clone());
            session_apps
                .entry(ids[0].clone())
                .or_default()
                .insert(app.to_owned());
        }
    }
    let mut updates = Vec::new();
    for thread in threads {
        let app = field(&thread, "id").ok_or("T3 thread has no id")?;
        let lineage = thread
            .get("lineage")
            .ok_or("Unsupported T3 thread lineage")?;
        let parent = field(lineage, "parentThreadId");
        let relation = field(lineage, "relationshipToParent");
        if parent.is_some() && !matches!(relation, Some("fork" | "subagent")) {
            return Err("Unsupported T3 parent relationship".to_owned());
        }
        let Some(children) = app_sessions.get(app) else {
            continue;
        };
        for child in children {
            if session_apps.get(child).is_none_or(|apps| apps.len() != 1) {
                continue;
            }
            let parent_session = parent.and_then(|p| app_sessions.get(p)).and_then(|ids| {
                if ids.len() == 1 {
                    let id = ids.iter().next()?;
                    (id != child && session_apps.get(id).is_some_and(|apps| apps.len() == 1))
                        .then_some(id.clone())
                } else {
                    None
                }
            });
            updates.push((
                child.clone(),
                parent.map(str::to_owned),
                parent_session,
                relation.map(str::to_owned),
            ));
        }
    }
    let _phase = crate::store::write_budget::write_phase("t3_lineage");
    crate::store::write_budget::begin_write(viewer).map_err(|e| e.to_string())?;
    let _rollback = crate::store::write_budget::rollback_on_panic(viewer);
    let result = (|| -> Result<usize, String> {
        // Do not clear first: unchanged snapshots must not emit change revisions.
        let retained: HashSet<_> = updates.iter().map(|u| u.0.as_str()).collect();
        let mut old = viewer
            .prepare(
                "select id from sessions where source_type = ? and t3_parent_thread_id is not null",
            )
            .map_err(|e| e.to_string())?;
        let old_ids = old
            .query_map([source], |r| r.get::<_, String>(0))
            .map_err(|e| e.to_string())?
            .collect::<Result<Vec<_>, _>>()
            .map_err(|e| e.to_string())?;
        drop(old);
        for id in old_ids {
            if !retained.contains(id.as_str()) {
                viewer.execute("update sessions set t3_parent_thread_id = null, t3_parent_session_id = null, t3_relationship = null where id = ?", [id]).map_err(|e| e.to_string())?;
            }
        }
        for (id, parent, resolved, relation) in &updates {
            viewer.execute("update sessions set t3_parent_thread_id = ?, t3_parent_session_id = ?, t3_relationship = ? where id = ?",
            params![parent, resolved, relation, id]).map_err(|e| e.to_string())?;
        }
        Ok(updates.len())
    })();
    crate::store::write_budget::finish(viewer, result.map_err(crate::store::StoreError::Refused))
        .map_err(|e| e.to_string())
}

pub fn import_optional(viewer: &Connection, settings: &crate::settings::CollectorSettings) {
    if settings.t3_state_path.trim().is_empty() {
        return;
    }
    if !matches!(
        settings.t3_source_type.as_str(),
        "windows" | "wsl" | "macos" | "linux"
    ) {
        eprintln!("Optional T3 lineage lookup unavailable: unsupported session source");
        return;
    }
    if let Err(error) = import(
        viewer,
        Path::new(&settings.t3_state_path),
        &settings.t3_source_type,
    ) {
        eprintln!("Optional T3 lineage lookup unavailable: {error}");
    }
}
