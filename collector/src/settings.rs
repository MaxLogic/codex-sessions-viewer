//! The subset of the viewer's `settings.toml` the collector needs.
//!
//! The collector reads the same file as the viewer so both scan the same
//! roots. It never writes the file and never reads unrelated sections such as
//! API keys.

use std::path::{Path, PathBuf};

use crate::codex::parser::{DEFAULT_MAX_TOOL_OUTPUT_PREVIEW_CHARS, SourceType};
use crate::platform_locations::PlatformLocations;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CollectorSettings {
    pub windows_codex_path: String,
    pub wsl_codex_unc_path: String,
    pub wsl_linux_root_unc: String,
    pub max_tool_output_preview_chars: usize,
    /// `[database] backup_retention_days`: days to keep the collector's own
    /// backups, from 1 to 3650 (a smaller value means 1).
    pub backup_retention_days: u32,
}

impl Default for CollectorSettings {
    fn default() -> Self {
        Self {
            windows_codex_path: DefaultFolders::current().codex_home,
            // The viewer fills the WSL folders from the detected default
            // distribution when it creates settings.toml; without that they
            // stay empty rather than naming one distribution.
            wsl_codex_unc_path: String::new(),
            wsl_linux_root_unc: String::new(),
            max_tool_output_preview_chars: DEFAULT_MAX_TOOL_OUTPUT_PREVIEW_CHARS,
            backup_retention_days: crate::backup_retention::DEFAULT_RETENTION_DAYS,
        }
    }
}

/// Session folders used when neither settings nor flags name them, derived
/// from the current user like the viewer's `DefaultSessionFolders`
/// (`app/lib/src/config/default_session_folders.dart`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DefaultFolders {
    /// `CODEX_HOME` when set, else `<home>/.codex`; empty without a home.
    pub codex_home: String,
    /// `<home>/.claude/projects`; empty without a home.
    pub claude_projects_root: String,
}

impl DefaultFolders {
    /// The home folder is `USERPROFILE`, falling back to `HOME`.
    pub fn from_env(var: impl Fn(&str) -> Option<String>) -> Self {
        Self::from_env_for(SourceType::native(), var)
    }

    pub fn from_env_for(platform: SourceType, var: impl Fn(&str) -> Option<String>) -> Self {
        let non_empty = |name: &str| {
            var(name)
                .map(|value| value.trim().to_owned())
                .filter(|value| !value.is_empty())
        };
        let home = if platform == SourceType::Windows {
            non_empty("USERPROFILE").or_else(|| non_empty("HOME"))
        } else {
            non_empty("HOME").or_else(|| non_empty("USERPROFILE"))
        };
        let under_home = |parts: &[&str]| {
            home.as_ref().map_or_else(String::new, |home| {
                let mut path = PathBuf::from(home);
                path.extend(parts);
                path.to_string_lossy().into_owned()
            })
        };
        Self {
            codex_home: non_empty("CODEX_HOME").unwrap_or_else(|| under_home(&[".codex"])),
            claude_projects_root: under_home(&[".claude", "projects"]),
        }
    }

    pub fn current() -> Self {
        Self::from_env(|name| std::env::var(name).ok())
    }
}

impl CollectorSettings {
    pub fn load(path: &Path) -> Result<Self, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|error| format!("cannot read settings {}: {error}", path.display()))?;
        Self::parse(&text).map_err(|error| format!("invalid settings {}: {error}", path.display()))
    }

    pub fn parse(text: &str) -> Result<Self, String> {
        let table: toml::Table = text
            .parse()
            .map_err(|error: toml::de::Error| error.to_string())?;
        let defaults = Self::default();
        let string = |section: &str, key: &str, default: &str| -> String {
            table
                .get(section)
                .and_then(|value| value.get(key))
                .and_then(toml::Value::as_str)
                .map_or_else(|| default.to_owned(), str::to_owned)
        };
        let positive = |section: &str, key: &str, default: usize| -> usize {
            table
                .get(section)
                .and_then(|value| value.get(key))
                .and_then(toml::Value::as_integer)
                .filter(|value| *value > 0)
                .map_or(default, |value| value as usize)
        };
        Ok(Self {
            windows_codex_path: string("paths", "windows_codex_path", &defaults.windows_codex_path),
            wsl_codex_unc_path: string("paths", "wsl_codex_unc_path", &defaults.wsl_codex_unc_path),
            wsl_linux_root_unc: string("wsl", "linux_root_unc", &defaults.wsl_linux_root_unc),
            max_tool_output_preview_chars: positive(
                "tool_output",
                "max_tool_output_preview_chars",
                defaults.max_tool_output_preview_chars,
            ),
            backup_retention_days: table
                .get("database")
                .and_then(|value| value.get("backup_retention_days"))
                .and_then(toml::Value::as_integer)
                .map_or(
                    defaults.backup_retention_days,
                    crate::backup_retention::clamp_days,
                ),
        })
    }
}

/// Uses the viewer's per-user settings, with adjacent Windows settings for
/// existing installations. A missing file leaves scan roots at their defaults.
pub fn default_settings_file() -> Option<PathBuf> {
    let candidate = PlatformLocations::current()?.settings_file;
    candidate.is_file().then_some(candidate)
}

/// The same platform user database path as the viewer.
pub fn default_viewer_database() -> Option<PathBuf> {
    Some(PlatformLocations::current()?.database_file)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env<'a>(pairs: &'a [(&'a str, &'a str)]) -> impl Fn(&str) -> Option<String> + 'a {
        move |name| {
            pairs
                .iter()
                .find(|(key, _)| *key == name)
                .map(|(_, value)| (*value).to_owned())
        }
    }

    fn joined(home: &str, parts: &[&str]) -> String {
        let mut path = PathBuf::from(home);
        path.extend(parts);
        path.to_string_lossy().into_owned()
    }

    #[test]
    fn default_folders_follow_the_user_profile() {
        let folders = DefaultFolders::from_env(env(&[("USERPROFILE", r"D:\Profiles\ada")]));
        assert_eq!(folders.codex_home, joined(r"D:\Profiles\ada", &[".codex"]));
        assert_eq!(
            folders.claude_projects_root,
            joined(r"D:\Profiles\ada", &[".claude", "projects"])
        );
        assert!(!folders.codex_home.contains("pawel"));
    }

    #[test]
    fn default_folders_prefer_codex_home_and_fall_back_to_home() {
        let folders = DefaultFolders::from_env(env(&[
            ("USERPROFILE", r"C:\Users\ada"),
            ("CODEX_HOME", r"E:\codex-home"),
        ]));
        assert_eq!(folders.codex_home, r"E:\codex-home");
        let posix = DefaultFolders::from_env(env(&[("USERPROFILE", " "), ("HOME", "/Users/ada")]));
        assert_eq!(posix.codex_home, joined("/Users/ada", &[".codex"]));
        assert_eq!(
            posix.claude_projects_root,
            joined("/Users/ada", &[".claude", "projects"])
        );
        assert_eq!(
            DefaultFolders::from_env(env(&[])),
            DefaultFolders::default()
        );
    }

    #[test]
    fn default_settings_name_no_particular_user_or_distribution() {
        let settings = CollectorSettings::default();
        assert_eq!(
            settings.windows_codex_path,
            DefaultFolders::current().codex_home
        );
        assert!(settings.wsl_codex_unc_path.is_empty());
        assert!(settings.wsl_linux_root_unc.is_empty());
        let parsed = CollectorSettings::parse(
            r#"
[paths]
windows_codex_path = 'X:\explicit'
"#,
        )
        .unwrap();
        assert_eq!(parsed.windows_codex_path, r"X:\explicit");
        assert!(parsed.wsl_linux_root_unc.is_empty());
    }

    #[test]
    fn reads_scan_roots_and_limits() {
        let settings = CollectorSettings::parse(
            r#"
[paths]
windows_codex_path = 'C:\Users\me\.codex'
wsl_codex_unc_path = '\\wsl.localhost\Ubuntu\home\me\.codex'
[wsl]
linux_root_unc = '\\wsl.localhost\Ubuntu\'
[tool_output]
max_tool_output_preview_chars = 50
[pricing]
openrouter_api_key = 'secret'
"#,
        )
        .unwrap();
        assert_eq!(settings.windows_codex_path, "C:\\Users\\me\\.codex");
        assert_eq!(
            settings.wsl_codex_unc_path,
            "\\\\wsl.localhost\\Ubuntu\\home\\me\\.codex"
        );
        assert_eq!(settings.max_tool_output_preview_chars, 50);
    }
}
