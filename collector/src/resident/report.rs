//! Bounded viewer summaries. The CLI keeps its full diagnostic report.
use crate::codex::CollectReport;
use serde_json::{Value, json};

const MAX_DETAILS: usize = 100;
const MAX_TEXT_BYTES: usize = 1024;

fn text(value: &str) -> String {
    if value.len() <= MAX_TEXT_BYTES {
        return value.to_owned();
    }
    let mut end = MAX_TEXT_BYTES;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}...", &value[..end])
}

pub(super) fn finished(command: &str, report: &CollectReport) -> Value {
    let counts = &report.counts;
    // Counts and root availability must include even the omitted diagnostics.
    let reachable = !report.errors.iter().any(|e| e.status == "path_unreachable");
    let errors: Vec<_> = report
        .errors
        .iter()
        .take(MAX_DETAILS)
        .map(|error| {
            json!({
                "path": text(&error.path), "status": text(&error.status),
                "message": error.message.as_deref().map(text),
            })
        })
        .collect();
    let repair = report.cache_repair.as_ref().map(|repair| json!({
        "status": repair.status, "reason_code": repair.reason_code,
        "deleted_rows": repair.deleted_rows, "categories": repair.categories,
        "backup_file": repair.backup_file.as_deref().map(text),
        "pruned_backups": repair.pruned_backups.iter().take(MAX_DETAILS).map(|entry| json!({
            "path": text(&entry.path), "bytes": entry.bytes,
        })).collect::<Vec<_>>(),
        "pruned_backups_omitted": repair.pruned_backups.len().saturating_sub(MAX_DETAILS),
        "prune_failures": repair.prune_failures.iter().take(MAX_DETAILS).map(|entry| text(entry)).collect::<Vec<_>>(),
        "prune_failures_omitted": repair.prune_failures.len().saturating_sub(MAX_DETAILS),
    }));
    // At most 100 details per list, with <= 1027 UTF-8 bytes per external
    // string. Even worst-case JSON escaping stays well below 16 MiB. Do not
    // serialize the full report and trim afterward: that duplicates large data.
    json!({
        "v": 1, "event": "finished", "command": command,
        "cancelled": counts.cancelled,
        "sessions_written": report.applied.sessions,
        "statuses_written": report.applied.statuses,
        "thread_names_changed": report.applied.thread_names_changed,
        "project_updates": report.applied.project_updates,
        "directories_scanned": counts.directories_scanned,
        "files_found": counts.files_found, "files_skipped": counts.files_skipped,
        "files_parsed": counts.files_parsed, "files_failed": counts.files_failed,
        "sessions_missing": counts.sessions_missing,
        "persistence_flushes": counts.persistence_flushes,
        "cache_repair": repair, "write_hold": report.write_hold,
        "errors_omitted": report.errors.len().saturating_sub(errors.len()),
        "unreachable_paths_omitted": report.errors.iter().skip(MAX_DETAILS)
            .filter(|error| error.status == "path_unreachable").count(),
        "all_configured_roots_reachable": reachable,
        "errors": errors,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::contract::SourceStatus;
    use crate::resident::protocol;

    #[test]
    fn large_scan_report_bounds_escaped_details_and_preserves_global_counts() {
        let long = "\u{1}".repeat(20_000);
        let mut report = CollectReport::default();
        report.counts.files_parsed = 147_500;
        report.applied.sessions = 147_500;
        for index in 0..200 {
            report.errors.push(SourceStatus {
                harness: "codex".into(),
                path: long.clone(),
                environment: None,
                status: if index == 199 {
                    "path_unreachable"
                } else {
                    "missing"
                }
                .into(),
                state: "missing".into(),
                message: Some(long.clone()),
            });
        }
        report.cache_repair = Some(crate::store::cache_repair::RepairReport {
            status: "completed",
            reason_code: "test",
            deleted_rows: 0,
            categories: Default::default(),
            backup_file: Some(long.clone()),
            pruned_backups: (0..200)
                .map(|_| crate::backup_retention::PrunedBackup {
                    path: long.clone(),
                    bytes: 1,
                })
                .collect(),
            prune_failures: vec![long; 200],
        });
        let mut event = finished("codex scan", &report);
        event["id"] = json!("x".repeat(protocol::MAX_ID_BYTES));
        assert_eq!(event["files_parsed"], 147_500);
        assert_eq!(event["sessions_written"], 147_500);
        assert_eq!(event["all_configured_roots_reachable"], false);
        assert_eq!(event["errors"].as_array().unwrap().len(), 100);
        assert_eq!(event["errors_omitted"], 100);
        assert_eq!(event["unreachable_paths_omitted"], 1);
        assert_eq!(event["cache_repair"]["pruned_backups_omitted"], 100);
        assert_eq!(event["cache_repair"]["prune_failures_omitted"], 100);
        let mut wire = Vec::new();
        protocol::send(&mut wire, &event).unwrap();
        assert!(wire.len() < protocol::MAX_EVENT_BYTES);
        eprintln!("large_scan_report worst_escape_bytes={}", wire.len());
        let utf8 = format!("{}{}", "a".repeat(1023), "😀".repeat(100));
        assert_eq!(text(&utf8), format!("{}...", "a".repeat(1023)));
    }
}
