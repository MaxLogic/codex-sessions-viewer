//! Per-platform viewer storage and packaged resource locations.

use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HostPlatform {
    Windows,
    Macos,
    Linux,
}

#[derive(Clone, Debug)]
pub struct PlatformLocations {
    pub database_file: PathBuf,
    pub settings_file: PathBuf,
    pub log_dir: PathBuf,
    pub queue_dir: PathBuf,
    pub backup_dir: PathBuf,
    pub sql_dir: PathBuf,
    pub assets_dir: PathBuf,
    pub sample_settings_file: PathBuf,
}

impl PlatformLocations {
    pub fn current() -> Option<Self> {
        let platform = if cfg!(windows) {
            HostPlatform::Windows
        } else if cfg!(target_os = "macos") {
            HostPlatform::Macos
        } else if cfg!(target_os = "linux") {
            HostPlatform::Linux
        } else {
            return None;
        };
        let executable = std::env::current_exe().ok()?;
        Self::resolve(platform, |name| std::env::var(name).ok(), &executable)
    }

    pub fn resolve(
        platform: HostPlatform,
        var: impl Fn(&str) -> Option<String>,
        executable: &Path,
    ) -> Option<Self> {
        let non_empty = |name| {
            var(name)
                .filter(|value| !value.trim().is_empty())
                .map(PathBuf::from)
        };
        let exe_dir = executable.parent().unwrap_or_else(|| Path::new("."));
        let home = non_empty("HOME");
        let (data, config, logs, cache, resources) = match platform {
            HostPlatform::Windows => {
                let data = non_empty("APPDATA")
                    .map(|path| path.join("CodexSessionViewer"))
                    .unwrap_or_else(|| exe_dir.to_path_buf());
                let cache = non_empty("LOCALAPPDATA")
                    .unwrap_or_else(std::env::temp_dir)
                    .join("CodexSessionViewer");
                (
                    data.clone(),
                    data,
                    PathBuf::from("logs"),
                    cache,
                    exe_dir.to_path_buf(),
                )
            }
            HostPlatform::Macos => {
                let home = home.as_ref()?;
                let resources = executable
                    .to_string_lossy()
                    .find("/Contents/MacOS/")
                    .map(|at| {
                        PathBuf::from(&executable.to_string_lossy()[..at])
                            .join("Contents")
                            .join("Resources")
                    })
                    .unwrap_or_else(|| exe_dir.join("data"));
                let data = home
                    .join("Library")
                    .join("Application Support")
                    .join("CodexSessionViewer");
                (
                    data.clone(),
                    data,
                    home.join("Library").join("Logs").join("CodexSessionViewer"),
                    home.join("Library")
                        .join("Caches")
                        .join("CodexSessionViewer"),
                    resources,
                )
            }
            HostPlatform::Linux => {
                let xdg = |key, fallback: &[&str]| {
                    non_empty(key)
                        .or_else(|| {
                            let mut base = home.clone()?;
                            base.extend(fallback);
                            Some(base)
                        })
                        .map(|base| base.join("CodexSessionViewer"))
                };
                (
                    xdg("XDG_DATA_HOME", &[".local", "share"])?,
                    xdg("XDG_CONFIG_HOME", &[".config"])?,
                    xdg("XDG_STATE_HOME", &[".local", "state"])?.join("logs"),
                    xdg("XDG_CACHE_HOME", &[".cache"])?,
                    exe_dir.join("data"),
                )
            }
        };
        let adjacent = exe_dir.join("settings.toml");
        let settings = if platform == HostPlatform::Windows && adjacent.is_file() {
            adjacent
        } else {
            config.join("settings.toml")
        };
        Some(Self {
            database_file: data.join("codex_sessions_viewer.sqlite"),
            settings_file: settings,
            log_dir: logs,
            queue_dir: cache.join("collector").join("queue"),
            backup_dir: data.join("backups"),
            sql_dir: resources.join("sql"),
            assets_dir: resources.join("assets"),
            sample_settings_file: resources.join("settings.sample.toml"),
        })
    }
}
