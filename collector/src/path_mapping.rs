//! Port of `app/lib/src/path_mapping/path_mapper.dart` and the path helpers the
//! Dart scanner uses for identity and cache lookups.

use crate::codex::parser::SourceType;
use crate::dart::{to_lower, trim};

#[derive(Clone, Debug)]
pub struct PathMapper {
    pub wsl_unc_root: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MappedSessionPath {
    pub source_type: SourceType,
    pub display_path: String,
    pub source_file_path: String,
    pub source_file_unc_path: Option<String>,
    pub platform_path: String,
    /// Insertion-ordered set, like the Dart `Set` literal it mirrors.
    pub normalized_path_keys: Vec<String>,
}

fn ordered_set(values: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut result: Vec<String> = Vec::new();
    for value in values {
        if !result.contains(&value) {
            result.push(value);
        }
    }
    result
}

impl PathMapper {
    pub fn map_windows_path(&self, path: &str) -> MappedSessionPath {
        MappedSessionPath {
            source_type: SourceType::Windows,
            display_path: path.to_owned(),
            source_file_path: path.to_owned(),
            source_file_unc_path: None,
            platform_path: path.to_owned(),
            normalized_path_keys: vec![normalize_path_key(path)],
        }
    }

    pub fn map_wsl_unc_path(&self, unc_path: &str) -> MappedSessionPath {
        let linux_path = self.unc_to_linux(unc_path);
        let windows_alias = mnt_to_windows_path(&linux_path);
        let mut keys = vec![
            normalize_path_key(&linux_path),
            normalize_path_key(unc_path),
        ];
        if let Some(alias) = &windows_alias {
            keys.push(normalize_path_key(alias));
        }
        MappedSessionPath {
            source_type: SourceType::Wsl,
            display_path: linux_path.clone(),
            source_file_path: windows_alias.unwrap_or_else(|| unc_path.to_owned()),
            source_file_unc_path: Some(unc_path.to_owned()),
            platform_path: linux_path,
            normalized_path_keys: ordered_set(keys),
        }
    }

    /// A Linux path reported by a WSL program, as a path Windows can open:
    /// `/mnt/c/x` becomes `C:\x`, anything else goes under the WSL root.
    /// `None` without a configured WSL root.
    pub fn linux_to_windows_access_path(&self, linux_path: &str) -> Option<String> {
        if let Some(alias) = mnt_to_windows_path(linux_path) {
            return Some(alias);
        }
        let root = trim_trailing_slash(&self.wsl_unc_root.replace('/', "\\"));
        if trim(&root).is_empty() || root == "\\" {
            return None;
        }
        Some(format!("{root}{}", linux_path.replace('/', "\\")))
    }

    fn unc_to_linux(&self, unc_path: &str) -> String {
        let normalized_root = trim_trailing_slash(&to_lower(&self.wsl_unc_root.replace('/', "\\")));
        let normalized_unc = unc_path.replace('/', "\\");
        let lower_unc = trim_trailing_slash(&to_lower(&normalized_unc));
        if lower_unc == normalized_root {
            return "/".to_owned();
        }
        let root_with_separator = format!("{normalized_root}\\");
        if lower_unc.starts_with(&root_with_separator) {
            let relative = &normalized_unc[normalized_root.len() + 1..];
            return format!("/{}", relative.replace('\\', "/"));
        }
        let without_prefix = strip_wsl_unc_prefix(&normalized_unc).unwrap_or(&normalized_unc);
        format!("/{}", without_prefix.replace('\\', "/"))
    }
}

/// `^\\\\wsl(?:\.localhost)?\\[^\\]+\\` (case-insensitive).
fn strip_wsl_unc_prefix(path: &str) -> Option<&str> {
    let lower = path.to_ascii_lowercase();
    let host_end = if lower.starts_with("\\\\wsl.localhost\\") {
        "\\\\wsl.localhost\\".len()
    } else if lower.starts_with("\\\\wsl\\") {
        "\\\\wsl\\".len()
    } else {
        return None;
    };
    let rest = &path[host_end..];
    let distro_end = rest.find('\\')?;
    if distro_end == 0 {
        return None;
    }
    Some(&rest[distro_end + 1..])
}

fn trim_trailing_slash(value: &str) -> String {
    let mut result = value;
    while result.len() > 1 && (result.ends_with('\\') || result.ends_with('/')) {
        result = &result[..result.len() - 1];
    }
    result.to_owned()
}

fn collapse_slashes(value: &str) -> String {
    let mut result = String::with_capacity(value.len());
    let mut previous_slash = false;
    for c in value.chars() {
        if c == '/' {
            if !previous_slash {
                result.push(c);
            }
            previous_slash = true;
        } else {
            result.push(c);
            previous_slash = false;
        }
    }
    result
}

/// `normalizePathKey` from `path_mapper.dart`.
pub fn normalize_path_key(path: &str) -> String {
    let mut value = collapse_slashes(&to_lower(&trim(path).replace('\\', "/")));
    // ^/wsl(?:\.localhost)?/[^/]+(/.*)?$
    let host_len = if value.starts_with("/wsl.localhost/") {
        Some("/wsl.localhost/".len())
    } else if value.starts_with("/wsl/") {
        Some("/wsl/".len())
    } else {
        None
    };
    if let Some(host_len) = host_len {
        let rest = &value[host_len..];
        let distro_end = rest.find('/').unwrap_or(rest.len());
        if distro_end > 0 {
            let tail = &rest[distro_end..];
            value = if tail.is_empty() {
                "/".to_owned()
            } else {
                tail.to_owned()
            };
        }
    }
    if value.len() > 1 && value.ends_with('/') {
        value.pop();
    }
    value
}

/// `_mntToWindowsPath`.
fn mnt_to_windows_path(linux_path: &str) -> Option<String> {
    let rest = linux_path.strip_prefix("/mnt/")?;
    let mut chars = rest.chars();
    let drive = chars.next().filter(char::is_ascii_alphabetic)?;
    let after = chars.as_str();
    let tail = if after.is_empty() {
        None
    } else {
        Some(after.strip_prefix('/')?)
    };
    let drive = drive.to_ascii_uppercase();
    match tail {
        None | Some("") => Some(format!("{drive}:\\")),
        Some(tail) => Some(format!("{drive}:\\{}", tail.replace('/', "\\"))),
    }
}

/// `_canonicalScanPath` from `session_scanner.dart`.
pub fn canonical_scan_path(path: &str) -> String {
    let mut normalized = collapse_slashes(&to_lower(&path.replace('\\', "/")));
    while normalized.len() > 1 && normalized.ends_with('/') {
        normalized.pop();
    }
    normalized
}

pub fn is_path_under_root(path: &str, root: &str) -> bool {
    let path = canonical_scan_path(path);
    let root = canonical_scan_path(root);
    path == root || path.starts_with(&format!("{root}/"))
}

/// `normalizeProjectPath` from `project_tag_state.dart`.
pub fn normalize_project_path(path: &str) -> String {
    to_lower(&collapse_slashes(&path.replace('\\', "/")))
}

/// `_normalizeIdentityPath` from `runtime_session_controller.dart`.
pub fn normalize_identity_path(path: &str, case_sensitive: bool) -> String {
    let normalized = trim(path).replace('\\', "/");
    if case_sensitive {
        normalized
    } else {
        to_lower(&normalized)
    }
}

/// `package:path` `p.normalize` for Windows-style paths.
pub fn normalize_windows_path(path: &str) -> String {
    let path = path.replace('/', "\\");
    let (prefix, rest) = if let Some(unc) = path.strip_prefix("\\\\") {
        // \\server\share is the root of a UNC path.
        let mut parts = unc.splitn(3, '\\');
        let server = parts.next().unwrap_or("");
        let share = parts.next();
        let rest = parts.next().unwrap_or("");
        match share {
            Some(share) => (format!("\\\\{server}\\{share}\\"), rest.to_owned()),
            None => (format!("\\\\{server}"), String::new()),
        }
    } else if path.len() >= 2
        && path.as_bytes()[1] == b':'
        && path.as_bytes()[0].is_ascii_alphabetic()
    {
        let drive = &path[..2];
        let rest = &path[2..];
        if let Some(stripped) = rest.strip_prefix('\\') {
            (format!("{drive}\\"), stripped.to_owned())
        } else {
            (drive.to_owned(), rest.to_owned())
        }
    } else if let Some(stripped) = path.strip_prefix('\\') {
        ("\\".to_owned(), stripped.to_owned())
    } else {
        (String::new(), path.clone())
    };
    let absolute = !prefix.is_empty();
    let mut parts: Vec<&str> = Vec::new();
    for part in rest.split('\\') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.last().is_some_and(|last| *last != "..") {
                    parts.pop();
                } else if !absolute {
                    parts.push("..");
                }
            }
            other => parts.push(other),
        }
    }
    let joined = parts.join("\\");
    if prefix.is_empty() {
        if joined.is_empty() {
            ".".to_owned()
        } else {
            joined
        }
    } else if joined.is_empty() {
        if prefix.len() > 2 && prefix.starts_with("\\\\") {
            prefix.trim_end_matches('\\').to_owned()
        } else {
            prefix
        }
    } else {
        format!("{prefix}{joined}")
    }
}

pub fn basename(path: &str) -> &str {
    let trimmed = path.trim_end_matches(['\\', '/']);
    match trimmed.rfind(['\\', '/']) {
        Some(index) => &trimmed[index + 1..],
        None => trimmed,
    }
}

pub fn dirname(path: &str) -> String {
    let trimmed = path.trim_end_matches(['\\', '/']);
    match trimmed.rfind(['\\', '/']) {
        Some(0) => trimmed[..1].to_owned(),
        Some(index) => {
            let parent = &trimmed[..index];
            if parent.len() == 2 && parent.ends_with(':') {
                format!("{parent}\\")
            } else {
                parent.to_owned()
            }
        }
        None => ".".to_owned(),
    }
}

/// `p.join` on Windows: adds a backslash unless the base already ends in one.
pub fn join(base: &str, name: &str) -> String {
    if base.is_empty() {
        return name.to_owned();
    }
    if base.ends_with(['\\', '/']) {
        format!("{base}{name}")
    } else {
        format!("{base}\\{name}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn mapper() -> PathMapper {
        PathMapper {
            wsl_unc_root: "\\\\wsl.localhost\\Ubuntu\\".to_owned(),
        }
    }

    #[test]
    fn opens_linux_paths_reported_from_wsl() {
        assert_eq!(
            mapper()
                .linux_to_windows_access_path("/home/dev/.claude/projects/p/s.jsonl")
                .as_deref(),
            Some(r"\\wsl.localhost\Ubuntu\home\dev\.claude\projects\p\s.jsonl")
        );
        assert_eq!(
            mapper()
                .linux_to_windows_access_path("/mnt/c/x/s.jsonl")
                .as_deref(),
            Some(r"C:\x\s.jsonl")
        );
        let unconfigured = PathMapper {
            wsl_unc_root: String::new(),
        };
        assert_eq!(
            unconfigured.linux_to_windows_access_path("/home/dev/s.jsonl"),
            None
        );
    }

    #[test]
    fn maps_wsl_unc_paths_like_dart() {
        let mapped = mapper()
            .map_wsl_unc_path("\\\\wsl.localhost\\Ubuntu\\home\\me\\.codex\\sessions\\a.jsonl");
        assert_eq!(mapped.display_path, "/home/me/.codex/sessions/a.jsonl");
        assert_eq!(
            mapped.normalized_path_keys,
            vec!["/home/me/.codex/sessions/a.jsonl".to_owned()]
        );
        let mnt = mapper().map_wsl_unc_path("\\\\wsl.localhost\\Ubuntu\\mnt\\c\\x\\a.jsonl");
        assert_eq!(mnt.source_file_path, "C:\\x\\a.jsonl");
        assert_eq!(mnt.normalized_path_keys.len(), 2);
    }

    #[test]
    fn normalizes_keys() {
        assert_eq!(normalize_path_key(" C:\\Users\\Me\\ "), "c:/users/me");
        assert_eq!(
            normalize_path_key("//wsl.localhost/Ubuntu/home/x"),
            "/home/x"
        );
        assert_eq!(normalize_path_key("\\\\wsl$\\Ubuntu"), "/wsl$/ubuntu");
        assert_eq!(canonical_scan_path("C:\\A\\\\B\\"), "c:/a/b");
    }

    #[test]
    fn normalizes_windows_paths() {
        assert_eq!(normalize_windows_path("C:/a/./b/../c/"), "C:\\a\\c");
        assert_eq!(
            normalize_windows_path("\\\\wsl.localhost\\Ubuntu\\home\\"),
            "\\\\wsl.localhost\\Ubuntu\\home"
        );
        assert_eq!(basename("C:\\x\\.codex"), ".codex");
        assert_eq!(dirname("C:\\x\\sessions"), "C:\\x");
        assert_eq!(dirname("C:\\x"), "C:\\");
    }
}
