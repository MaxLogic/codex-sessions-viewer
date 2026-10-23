//! Explicit viewer collection context. Only the bridge resolves caller defaults.
use super::instance;
use crate::{cli, settings::CollectorSettings};
use serde::{Deserialize, Serialize};
use std::{
    io,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, PartialEq, Eq, Deserialize, Serialize)]
pub struct Context {
    pub database: PathBuf,
    pub settings: Option<PathBuf>,
    pub windows_root: Option<PathBuf>,
    pub wsl_root: Option<PathBuf>,
    pub wsl_unc_root: Option<PathBuf>,
    pub claude_roots: Vec<PathBuf>,
    pub claude_wsl_roots: Vec<PathBuf>,
    pub wsl_projects: bool,
    #[serde(default)]
    pub t3_state_path: Option<PathBuf>,
}

fn resolved(value: &str) -> io::Result<Option<PathBuf>> {
    if value.is_empty() {
        Ok(None)
    } else {
        instance::identity_path(Path::new(value)).map(Some)
    }
}
fn text(path: &Option<PathBuf>) -> String {
    path.as_ref()
        .map_or_else(String::new, |p| p.to_string_lossy().into_owned())
}
impl Context {
    pub(crate) fn resolve(options: &cli::Options) -> Result<Self, String> {
        let settings = cli::load_settings(options).map_err(super::scheduler::cli_message)?;
        let database = options
            .db
            .clone()
            .or_else(|| options.standalone.clone())
            .or_else(crate::settings::default_viewer_database)
            .ok_or("database unavailable")?;
        let paths = |values: &[String]| -> io::Result<Vec<PathBuf>> {
            values
                .iter()
                .map(|p| instance::identity_path(Path::new(p)))
                .collect()
        };
        let result = (|| -> io::Result<Self> {
            Ok(Self {
                database: instance::identity_path(&database)?,
                settings: options
                    .settings
                    .clone()
                    .or_else(crate::settings::default_settings_file)
                    .map(|p| instance::identity_path(&p))
                    .transpose()?,
                windows_root: resolved(&settings.windows_codex_path)?,
                wsl_root: resolved(&settings.wsl_codex_unc_path)?,
                wsl_unc_root: resolved(&settings.wsl_linux_root_unc)?,
                claude_roots: paths(
                    &cli::claude_roots(options)
                        .into_iter()
                        .filter(|r| r.source_type != crate::codex::parser::SourceType::Wsl)
                        .map(|r| r.path)
                        .collect::<Vec<_>>(),
                )?,
                claude_wsl_roots: paths(&options.claude_wsl_roots)?,
                wsl_projects: options.wsl_projects,
                t3_state_path: resolved(&settings.t3_state_path)?,
            })
        })();
        result.map_err(|e| e.to_string())
    }
    pub(crate) fn resolve_paths(mut self) -> io::Result<Self> {
        self.database = instance::identity_path(&self.database)?;
        for path in [
            &mut self.settings,
            &mut self.windows_root,
            &mut self.wsl_root,
            &mut self.wsl_unc_root,
            &mut self.t3_state_path,
        ]
        .into_iter()
        .flatten()
        {
            *path = instance::identity_path(path)?;
        }
        for path in self
            .claude_roots
            .iter_mut()
            .chain(self.claude_wsl_roots.iter_mut())
        {
            *path = instance::identity_path(path)?;
        }
        Ok(self)
    }
    pub(crate) fn validate(&self, key: &str, settings: &Option<PathBuf>) -> Result<(), String> {
        let paths = std::iter::once(&self.database)
            .chain(self.settings.iter())
            .chain(self.windows_root.iter())
            .chain(self.wsl_root.iter())
            .chain(self.wsl_unc_root.iter())
            .chain(self.claude_roots.iter())
            .chain(self.claude_wsl_roots.iter())
            .chain(self.t3_state_path.iter());
        if paths.into_iter().any(|p| !p.is_absolute()) {
            return Err("viewer paths must be absolute".into());
        }
        if instance::database_key(&self.database).map_err(|e| e.to_string())? != key {
            return Err("resident does not own the requested database".into());
        }
        let normalize = |path: &Option<PathBuf>| {
            path.as_ref()
                .map(|p| instance::identity_path(p))
                .transpose()
        };
        if normalize(&self.settings).map_err(|e| e.to_string())? != *settings {
            return Err("resident does not own the requested settings".into());
        }
        Ok(())
    }
    pub(crate) fn options(&self, base: &cli::Options) -> cli::Options {
        let mut options = base.clone();
        options.db = Some(self.database.clone());
        options.standalone = None;
        options.settings = self.settings.clone();
        options.windows_root = Some(text(&self.windows_root));
        options.wsl_root = Some(text(&self.wsl_root));
        options.wsl_unc_root = Some(text(&self.wsl_unc_root));
        options.claude_roots = self
            .claude_roots
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        options.claude_wsl_roots = self
            .claude_wsl_roots
            .iter()
            .map(|p| p.to_string_lossy().into_owned())
            .collect();
        options.wsl_projects = self.wsl_projects;
        options.json = true;
        options
    }
    pub(crate) fn load_settings(&self) -> Result<CollectorSettings, String> {
        let mut settings = match &self.settings {
            Some(path) => CollectorSettings::load(path)?,
            None => CollectorSettings::default(),
        };
        settings.windows_codex_path = text(&self.windows_root);
        settings.wsl_codex_unc_path = text(&self.wsl_root);
        settings.wsl_linux_root_unc = text(&self.wsl_unc_root);
        settings.t3_state_path = text(&self.t3_state_path);
        Ok(settings)
    }
    pub(crate) fn claude_roots(&self) -> Vec<crate::claude::ClaudeRoot> {
        self.claude_roots
            .iter()
            .map(|p| (p, crate::codex::parser::SourceType::native()))
            .chain(
                self.claude_wsl_roots
                    .iter()
                    .map(|p| (p, crate::codex::parser::SourceType::Wsl)),
            )
            .map(|(p, source_type)| crate::claude::ClaudeRoot {
                path: p.to_string_lossy().into_owned(),
                source_type,
            })
            .collect()
    }
}
