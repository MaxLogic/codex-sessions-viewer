//! Collects local coding-agent sessions into the Codex Sessions Viewer
//! database through a versioned ingestion contract.

pub mod claude;
pub mod cli;
pub mod codex;
pub mod contract;
pub mod dart;
pub mod hooks;
pub mod path_mapping;
pub mod query;
pub mod settings;
pub mod store;
