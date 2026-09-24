//! The subset of the viewer's `settings.toml` the collector needs.
//!
//! The collector reads the same file as the viewer so both scan the same
//! roots. It never writes the file and never reads unrelated sections such as
//! API keys.

use std::path::{Path, PathBuf};

use crate::codex::parser::DEFAULT_MAX_TOOL_OUTPUT_PREVIEW_CHARS;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CollectorSettings {
    pub windows_codex_path: String,
    pub wsl_codex_unc_path: String,
    pub wsl_linux_root_unc: String,
    pub max_tool_output_preview_chars: usize,
}

impl Default for CollectorSettings {
    fn default() -> Self {
        let home = std::env::var("USERPROFILE").unwrap_or_default();
        Self {
            windows_codex_path: if home.is_empty() {
                String::new()
            } else {
                format!("{home}\\.codex")
            },
            wsl_codex_unc_path: String::new(),
            wsl_linux_root_unc: "\\\\wsl.localhost\\Ubuntu\\".to_owned(),
            max_tool_output_preview_chars: DEFAULT_MAX_TOOL_OUTPUT_PREVIEW_CHARS,
        }
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
        })
    }
}

/// The viewer looks for `settings.toml` next to its executable; the bundled
/// collector sits in the same folder.
pub fn default_settings_file() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let candidate = exe.parent()?.join("settings.toml");
    candidate.is_file().then_some(candidate)
}

/// `%APPDATA%\CodexSessionViewer\codex_sessions_viewer.sqlite`, like the viewer.
pub fn default_viewer_database() -> Option<PathBuf> {
    let app_data = std::env::var_os("APPDATA").filter(|value| !value.is_empty())?;
    Some(
        PathBuf::from(app_data)
            .join("CodexSessionViewer")
            .join("codex_sessions_viewer.sqlite"),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

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
