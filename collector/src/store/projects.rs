//! Project assignment, ported from `project_tag_state.dart` and the project
//! resolver in `runtime_session_controller.dart`.

use std::collections::HashMap;

use rusqlite::{Connection, OptionalExtension, params};

use crate::codex::parser::SourceType;
use crate::dart::{DartDateTime, trim, utf16_len};
use crate::path_mapping::normalize_project_path;

use super::schema::StoreResult;

/// Project names resolved on the collecting machine, keyed by working
/// directory. Falls back to the directory's last segment like the viewer.
#[derive(Clone, Debug, Default)]
pub struct ProjectResolver {
    hints: HashMap<String, String>,
}

impl ProjectResolver {
    pub fn new(hints: impl IntoIterator<Item = (String, String)>) -> Self {
        Self {
            hints: hints
                .into_iter()
                .map(|(path, name)| (trim(&path).to_owned(), name))
                .collect(),
        }
    }

    /// `_ProjectPathResolver.resolve`.
    pub fn resolve(
        &self,
        working_directory: Option<&str>,
        source_type: SourceType,
    ) -> Option<String> {
        self.resolve_marked(working_directory, source_type)
            .map(|(name, _)| name)
    }

    /// [`Self::resolve`] plus whether a WSL session's name came from a hint
    /// the resolver found (a git root), not the folder-name fallback. Only WSL
    /// names are marked (`sessions.project_refined`): a Windows name is always
    /// resolved in-process, so it needs no marker.
    pub fn resolve_marked(
        &self,
        working_directory: Option<&str>,
        source_type: SourceType,
    ) -> Option<(String, bool)> {
        let path = trim(working_directory?);
        if path.is_empty() {
            return None;
        }
        if let Some(name) = self.hints.get(path)
            && !trim(name).is_empty()
        {
            return Some((name.clone(), source_type == SourceType::Wsl));
        }
        project_from_path(path).map(|name| (name, false))
    }
}

/// `_projectFromPath`: the last non-blank path segment.
pub fn project_from_path(path: &str) -> Option<String> {
    path.replace('\\', "/")
        .split('/')
        .rev()
        .find(|segment| !trim(segment).is_empty())
        .map(str::to_owned)
}

/// `_resolveWindows`: the nearest enclosing directory with `.git`, or the
/// directory itself.
pub fn resolve_windows_project(path: &str) -> Option<String> {
    let directory = std::path::Path::new(path);
    if !directory.is_dir() {
        return project_from_path(path);
    }
    let mut current = std::path::absolute(directory).unwrap_or_else(|_| directory.to_path_buf());
    loop {
        if current.join(".git").exists() {
            return project_from_path(&current.to_string_lossy());
        }
        match current.parent() {
            Some(parent) if parent != current => current = parent.to_path_buf(),
            _ => break,
        }
    }
    project_from_path(path)
}

pub fn upsert_auto_project(conn: &Connection, name: &str, now: &str) -> StoreResult<i64> {
    conn.prepare_cached(
        "insert into projects (name, description, is_active, created_at_utc, updated_at_utc)
         values (?, ?, 1, ?, ?)
         on conflict(name) do update set updated_at_utc = excluded.updated_at_utc",
    )?
    .execute(params![
        name,
        "Auto-detected from session working directory.",
        now,
        now
    ])?;
    Ok(conn
        .prepare_cached("select id from projects where name = ?")?
        .query_row([name], |row| row.get(0))?)
}

#[derive(Clone, Debug)]
pub struct ProjectMask {
    pub project_id: i64,
    pub project_name: String,
    normalized_mask: String,
    specificity: usize,
}

impl ProjectMask {
    fn matches(&self, path_key: &str) -> bool {
        wildcard_match(&self.normalized_mask, path_key)
    }
}

/// `^` + mask with `*` as `.*` + `$`.
fn wildcard_match(pattern: &str, text: &str) -> bool {
    let parts: Vec<&str> = pattern.split('*').collect();
    if parts.len() == 1 {
        return pattern == text;
    }
    let first = parts[0];
    let last = parts[parts.len() - 1];
    if !text.starts_with(first) || text.len() < first.len() + last.len() || !text.ends_with(last) {
        return false;
    }
    let mut position = first.len();
    let end = text.len() - last.len();
    for part in &parts[1..parts.len() - 1] {
        match text[position..end].find(part) {
            Some(offset) => position += offset + part.len(),
            None => return false,
        }
    }
    true
}

/// `_activeMasks`: active rules, most specific folder first.
pub fn active_masks(conn: &Connection) -> StoreResult<Vec<ProjectMask>> {
    let mut statement = conn.prepare_cached(
        "select ppm.project_id, p.name, ppm.path_mask, ppm.priority
         from project_path_masks ppm
         join projects p on p.id = ppm.project_id
         where ppm.is_active = 1 and p.is_active = 1
         order by ppm.priority asc, ppm.id asc",
    )?;
    let mut masks: Vec<ProjectMask> = statement
        .query_map([], |row| {
            let path_mask: String = row.get(2)?;
            let normalized_mask = normalize_project_path(&path_mask);
            let specificity = match normalized_mask.find('*') {
                Some(index) => utf16_len(&normalized_mask[..index]),
                None => utf16_len(&normalized_mask),
            };
            Ok(ProjectMask {
                project_id: row.get(0)?,
                project_name: row.get(1)?,
                normalized_mask,
                specificity,
            })
        })?
        .collect::<Result<_, _>>()?;
    // Stable sort keeps priority/age order among equally specific rules.
    masks.sort_by_key(|mask| std::cmp::Reverse(mask.specificity));
    Ok(masks)
}

pub fn best_project_match<'m>(
    path_keys: &[String],
    masks: &'m [ProjectMask],
) -> Option<&'m ProjectMask> {
    masks
        .iter()
        .find(|mask| path_keys.iter().any(|key| mask.matches(key)))
}

fn ordered_unique(values: Vec<String>) -> Vec<String> {
    let mut result: Vec<String> = Vec::with_capacity(values.len());
    for value in values {
        if !result.contains(&value) {
            result.push(value);
        }
    }
    result
}

/// `ProjectTagStateStore.resolveUsagePathContext`.
pub fn resolve_usage_path_context(
    conn: &Connection,
    display_path: Option<&str>,
    platform_path: Option<&str>,
    unc_path: Option<&str>,
    detected_project_id: Option<i64>,
) -> StoreResult<i64> {
    let raw = [
        display_path.unwrap_or("").to_owned(),
        platform_path.unwrap_or("").to_owned(),
        unc_path.unwrap_or("").to_owned(),
    ];
    let keys: Vec<String> = raw
        .iter()
        .map(|path| normalize_project_path(path))
        .collect();
    let existing: Option<(i64, Option<i64>, Option<String>)> = conn
        .prepare_cached(
            "select id, detected_project_id, detected_project_source from usage_path_contexts
             where normalization_version = 1
               and display_path_key = ? and platform_path_key = ? and unc_path_key = ?",
        )?
        .query_row(params![keys[0], keys[1], keys[2]], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })
        .optional()?;
    if let Some((id, existing_detected, existing_source)) = existing {
        if let Some(detected) = detected_project_id
            && (existing_detected != Some(detected)
                || existing_source.as_deref() != Some("detected"))
        {
            conn.prepare_cached(
                "update usage_path_contexts set detected_project_id = ?,
                   detected_project_source = 'detected',
                   effective_project_id = coalesce(mask_project_id, ?),
                   resolution_source = case when mask_project_id is null then 'detected' else 'mask' end,
                   updated_at_utc = ? where id = ?",
            )?
            .execute(params![detected, detected, DartDateTime::now().to_iso8601(), id])?;
        }
        retain_context_aliases(conn, id, &raw)?;
        return Ok(id);
    }
    let non_empty: Vec<String> = keys.iter().filter(|key| !key.is_empty()).cloned().collect();
    let masks = active_masks(conn)?;
    let matched = best_project_match(&non_empty, &masks);
    let now = DartDateTime::now().to_iso8601();
    let resolution_source = if matched.is_some() {
        "mask"
    } else if detected_project_id.is_some() {
        "detected"
    } else {
        "unassigned"
    };
    conn.prepare_cached(
        "insert into usage_path_contexts (
           display_path_raw, platform_path_raw, unc_path_raw,
           display_path_key, platform_path_key, unc_path_key, normalization_version,
           detected_project_id, mask_project_id, effective_project_id,
           resolution_source, project_rules_version, created_at_utc, updated_at_utc
         ) values (?, ?, ?, ?, ?, ?, 1, ?, ?, ?, ?,
           (select project_rules_version from database_state where id = 1), ?, ?)",
    )?
    .execute(params![
        raw[0],
        raw[1],
        raw[2],
        keys[0],
        keys[1],
        keys[2],
        detected_project_id,
        matched.map(|mask| mask.project_id),
        matched.map(|mask| mask.project_id).or(detected_project_id),
        resolution_source,
        now,
        now
    ])?;
    let id = conn.last_insert_rowid();
    retain_context_aliases(conn, id, &raw)?;
    Ok(id)
}

fn retain_context_aliases(
    conn: &Connection,
    context_id: i64,
    raw: &[String; 3],
) -> StoreResult<()> {
    conn.prepare_cached(
        "insert or ignore into usage_path_context_aliases (
           path_context_id, display_path_raw, platform_path_raw, unc_path_raw
         ) values (?, ?, ?, ?)",
    )?
    .execute(params![context_id, raw[0], raw[1], raw[2]])?;
    Ok(())
}

/// Candidate path columns, detected project ID, and detected project name.
type SessionProjectRow = (Vec<Option<String>>, Option<i64>, Option<String>);

/// `ProjectTagStateStore.refreshSessionProject`.
pub fn refresh_session_project(conn: &Connection, session_id: &str) -> StoreResult<()> {
    let masks = active_masks(conn)?;
    let row: Option<SessionProjectRow> = conn
        .prepare_cached(
            "select display_path, working_directory_display, working_directory_platform,
                    working_directory_unc, s.detected_project_id, detected.name
             from sessions s
             left join projects detected on detected.id = s.detected_project_id
             where s.project_override = 0 and s.id = ?",
        )?
        .query_row([session_id], |row| {
            Ok((
                vec![row.get(1)?, row.get(2)?, row.get(3)?, row.get(0)?],
                row.get(4)?,
                row.get(5)?,
            ))
        })
        .optional()?;
    let Some((columns, detected_id, detected_name)) = row else {
        return Ok(());
    };
    let mut keys: Vec<String> = columns
        .into_iter()
        .flatten()
        .filter(|value| !value.is_empty())
        .map(|value| normalize_project_path(&value))
        .collect();
    let mut statement =
        conn.prepare_cached("select path_key from session_path_keys where session_id = ?")?;
    let path_keys = statement.query_map([session_id], |row| row.get::<_, String>(0))?;
    for key in path_keys {
        keys.push(normalize_project_path(&key?));
    }
    let keys = ordered_unique(keys);
    let matched = best_project_match(&keys, &masks);
    let project_id = matched.map(|mask| mask.project_id).or(detected_id);
    let project_name = matched
        .map(|mask| mask.project_name.clone())
        .or(detected_name);
    conn.prepare_cached(
        "update sessions set project_id = ?, project_name_snapshot = ?, updated_at_utc = ? where id = ?",
    )?
    .execute(params![
        project_id,
        project_name,
        DartDateTime::now().to_iso8601(),
        session_id
    ])?;
    update_search_project(conn, session_id, project_name.as_deref().unwrap_or(""))
}

fn update_search_project(
    conn: &Connection,
    session_id: &str,
    project_name: &str,
) -> StoreResult<()> {
    let rowid: Option<i64> = conn
        .prepare_cached("select rowid from sessions where id = ?")?
        .query_row([session_id], |row| row.get(0))
        .optional()?;
    if let Some(rowid) = rowid {
        conn.prepare_cached("update session_search set project_name = ? where rowid = ?")?
            .execute(params![project_name, rowid])?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wildcard_matches_like_the_anchored_regex() {
        assert!(wildcard_match("c:/work/*", "c:/work/a/b"));
        assert!(wildcard_match("c:/work/*", "c:/work/"));
        assert!(!wildcard_match("c:/work/*", "c:/workx"));
        assert!(wildcard_match("c:/work", "c:/work"));
        assert!(wildcard_match("*/viewer/*", "f:/x/viewer/y"));
        assert!(!wildcard_match("a*a", "a"));
    }

    #[test]
    fn project_names_come_from_the_last_segment() {
        assert_eq!(
            project_from_path("F:\\projects\\viewer\\").as_deref(),
            Some("viewer")
        );
        assert_eq!(project_from_path("/home/me/app").as_deref(), Some("app"));
        assert_eq!(project_from_path("  "), None);
    }
}
