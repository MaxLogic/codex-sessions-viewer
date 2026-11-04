# Test target timing baseline

Retained source: Native release CI run 41074635074, 2026-10-30,
Windows job 124127425351; Linux job 124127425797. Inventory prepared for
CXV-207 at base 335d68d. These are historical CI measurements, not fresh
full-suite proof. Raw evidence: cxv207-prep-20095 under the established
codex-sessions-viewer-main run root.

Rust durations exclude compilation. Flutter spans overlap because files run
concurrently; a missing span is unknown, not zero. Owning-area guesses from
the preparer are omitted here; selection rules are maintained in fast_tests.py.

## 3. Rust test targets (cargo test --locked --no-fail-fast, cwd collector/)
Durations are libtest 'finished in' (test execution only, per binary, tests inside a binary run in parallel threads). Cost flag: >60 s.
| target | kind | tests (win) | Windows s | Linux s |
|---|---|---|---|---|
| src/lib.rs | unit | 72 | 3.12 | 3.14 |
| src/main.rs | unit | 0 | 0 | 0 |
| src/bin/codex-sessions-hub.rs | unit | 0 | 0 | 0 |
| src/bin/codex-sessions-scan-launcher.rs | unit | 0 | 0 | 0 |
| tests/backup_retention.rs | integration | 6 | 2.04 | 1.86 |
| tests/codex_event_messages.rs | integration | 5 | 2.17 | 3.34 |
| tests/collector_contract.rs | integration | 6 | 1.38 | 1.21 |
| tests/collector_diagnostics.rs | integration | 29 | 6.84 | 5.37 |
| tests/context_query.rs | integration | 15 | 3.87 | 3.25 |
| tests/harness_hooks.rs | integration | 24 | 5.85 | 5.06 |
| tests/hub_query.rs | integration | 3 | 1.84 | 1.28 |
| tests/hub_sync.rs | integration | 38 | 126.01 **SLOW** | 124.79 |
| tests/local_ingestion.rs | integration | 60 | 33.33 | 32.34 |
| tests/platform_locations.rs | integration | 3 | 0.01 | 0 |
| tests/price_history_sync.rs | integration | 17 | 4.08 | 2.88 |
| tests/resident.rs | integration | 73 | 133.73 **SLOW** | 125.41 |
| tests/scan_launcher.rs | integration | 2 | 0.17 | 0.13 |
| tests/scan_transport.rs | integration | 4 | 4.9 | 4.83 |
| tests/test_environment.rs | integration | 12 | 0.98 | 0.91 |
| tests/write_budget.rs | integration | 36 | 41.29 | 42.87 |
| tests/write_interleavings.rs | integration | 12 | 99.47 **SLOW** | 66.11 |
| tests/write_lease.rs | integration | 15 | 601.33 **SLOW** | 601.32 |
| tests/write_side_effects.rs | integration | 12 | 4.82 | 4.21 |

Rust totals: Windows 1077.2 s, Linux 1030.3 s. Dominant cost: tests/write_lease.rs 601 s on both platforms (15 tests, 56 percent of the total); then resident 134/125 s, hub_sync 126/125 s, write_interleavings 99/66 s, write_budget 41/43 s, local_ingestion 33/32 s. Everything else is under 7 s each; the 18 remaining targets together are about 50 s. Linux cargo-test gate json: 1085.4 s wall, 424 tests. The Windows wall time of the 'Test collector' step is not in the retained log.


## 4. Flutter unit/widget test files (app/test/**, 121 *_test.dart files; 83 appear in the Linux expanded log)
Spans are last-minus-first mm:ss stamps seen for the file in the expanded reporter, an approximation (files run concurrently, so spans overlap and do not sum to the step time). '-' means no stamped line for that file in that log. Records only per-file wall time that exists.
| file | tests seen (linux) | Linux span s | Windows span s |
|---|---|---|---|
| test/accessibility/accessibility_smoke_test.dart | - | - | 5 |
| test/accessibility/announcement_test.dart | - | - | - |
| test/accessibility/focus_reader_semantics_test.dart | 1 | 0 | 1 |
| test/accessibility/logs_screen_semantics_test.dart | 3 | 0 | 0 |
| test/accessibility/no_giant_conversation_node_test.dart | 2 | 0 | 0 |
| test/accessibility/semantics_audit_test.dart | 21 | 9 | 5 |
| test/accessibility/usage_chart_table_test.dart | - | - | - |
| test/app_shell_test.dart | 5 | 2 | 0 |
| test/app/app_composition_test.dart | - | - | - |
| test/app/app_usage_test.dart | 15 | 9 | 7 |
| test/app/app_writer_coordinator_test.dart | 11 | 3 | 2 |
| test/app/collector_ingestion_compat_test.dart | - | - | 18 |
| test/app/external_ingestion_refresh_test.dart | 48 | 25 | 23 |
| test/app/hub_data_source_test.dart | - | - | - |
| test/app/logs_loader_test.dart | 1 | 0 | 0 |
| test/app/move_to_project_test.dart | - | - | - |
| test/app/multi_harness_ingestion_test.dart | - | - | 5 |
| test/app/runtime_scan_app_test.dart | 61 | 79 | 224 |
| test/app/startup_registration_app_test.dart | 1 | 0 | 0 |
| test/background_collection/background_collection_test.dart | 1 | 0 | - |
| test/benchmark/scan_memory_benchmark_test.dart | - | - | 0 |
| test/benchmark/usage_projection_benchmark_test.dart | 1 | 0 | - |
| test/commands/remote_session_actions_test.dart | - | - | - |
| test/commands/resume_command_generator_test.dart | - | - | - |
| test/commands/windows_command_line_test.dart | - | - | - |
| test/config/app_settings_test.dart | 3 | 0 | - |
| test/database/application_maintenance_test.dart | 4 | 1 | 1 |
| test/database/backup_retention_test.dart | 7 | 1 | - |
| test/database/database_connection_test.dart | 7 | 5 | 3 |
| test/database/database_generation_interrupt_test.dart | - | - | - |
| test/database/database_migration_preflight_test.dart | 30 | 9 | 3 |
| test/database/database_migration_test.dart | 21 | 4 | 4 |
| test/database/database_optimize_integration_test.dart | 1 | 0 | - |
| test/database/database_startup_app_test.dart | - | - | - |
| test/database/disk_space_probe_test.dart | - | - | - |
| test/database/maintenance_concurrency_test.dart | 115 | 25 | 15 |
| test/database/maintenance_job_test.dart | 3 | 1 | - |
| test/database/maintenance_scheduler_test.dart | 7 | 2 | 0 |
| test/database/message_delete_index_test.dart | 3 | 1 | - |
| test/database/project_tag_state_test.dart | - | - | - |
| test/database/session_activity_reader_test.dart | 1 | 0 | - |
| test/database/session_activity_test.dart | 4 | 2 | 2 |
| test/database/space_reclaim_test.dart | - | - | 0 |
| test/database/sqlite_interrupt_test.dart | - | - | - |
| test/database/startup_during_collection_test.dart | 17 | 4 | 10 |
| test/database/startup_usage_migration_test.dart | 3 | 0 | 4 |
| test/database/startup_usage_populated_test.dart | 5 | 1 | - |
| test/database/usage_path_context_migration_test.dart | 19 | 4 | 0 |
| test/database/writer_version_agreement_test.dart | - | - | - |
| test/export/eval_dataset_exporter_test.dart | 7 | 0 | - |
| test/export/eval_dataset_loader_test.dart | 17 | 1 | 2 |
| test/export/session_list_exporter_test.dart | - | - | - |
| test/export/session_list_message_loader_test.dart | 3 | 0 | - |
| test/logging/structured_logger_test.dart | 8 | 0 | 0 |
| test/parser/session_fixture_test.dart | 3 | 0 | 0 |
| test/path_mapping/path_mapper_test.dart | - | - | - |
| test/platform/app_instance_lock_test.dart | 1 | 0 | - |
| test/platform/app_locations_test.dart | 1 | 0 | - |
| test/platform/application_working_directory_test.dart | - | - | - |
| test/platform/startup_registration_test.dart | - | - | - |
| test/platform/terminal_launcher_test.dart | - | - | 0 |
| test/platform/windows_startup_registration_test.dart | - | - | - |
| test/pricing/hub_price_history_test.dart | 43 | 3 | 2 |
| test/pricing/local_price_confirmation_test.dart | 9 | 1 | - |
| test/pricing/openrouter_catalog_client_test.dart | 1 | 0 | - |
| test/pricing/openrouter_price_rules_test.dart | 2 | 0 | - |
| test/pricing/pricing_repository_test.dart | 4 | 1 | - |
| test/scanner/resident_collector_client_test.dart | 39 | 45 | 51 |
| test/scanner/scan_batching_test.dart | 5 | 0 | - |
| test/search/archive_pin_filter_test.dart | - | - | - |
| test/search/message_search_backfill_test.dart | - | - | - |
| test/search/message_search_test.dart | - | - | - |
| test/search/project_filter_test.dart | - | - | - |
| test/search/semantic_search_evaluation_test.dart | - | - | - |
| test/search/session_search_test.dart | 1 | 0 | - |
| test/support/collector_fixture_test.dart | - | - | 8 |
| test/support/test_environment_test.dart | 6 | 1 | - |
| test/ui/app_button_test.dart | 1 | 0 | - |
| test/ui/app_shell_test.dart | 5 | 4 | 0 |
| test/ui/background_collection_panel_test.dart | 19 | 3 | 3 |
| test/ui/collection_status_test.dart | 6 | 1 | 1 |
| test/ui/command_preview_test.dart | 7 | 1 | 0 |
| test/ui/context_search_screen_test.dart | 2 | 0 | 1 |
| test/ui/conversation_find_scroll_test.dart | 8 | 2 | 3 |
| test/ui/conversation_view_test.dart | 14 | 5 | 4 |
| test/ui/copy_shortcut_test.dart | 6 | 1 | 5 |
| test/ui/database_migration_progress_test.dart | 1 | 0 | 1 |
| test/ui/evals_screen_test.dart | 65 | 3 | 2 |
| test/ui/focus_reader_test.dart | 6 | 1 | 0 |
| test/ui/hub_sessions_test.dart | 12 | 7 | 6 |
| test/ui/keyboard_shortcuts_test.dart | 13 | 5 | 0 |
| test/ui/logs_screen_test.dart | - | - | 0 |
| test/ui/motion_test.dart | 1 | 0 | 0 |
| test/ui/move_to_project_dialog_test.dart | 2 | 0 | 1 |
| test/ui/number_formatting_test.dart | 24 | 0 | - |
| test/ui/project_filter_request_test.dart | 5 | 1 | 2 |
| test/ui/projects_screen_test.dart | 12 | 3 | 4 |
| test/ui/session_actions_test.dart | 16 | 8 | 7 |
| test/ui/session_detail_test.dart | 9 | 7 | 5 |
| test/ui/session_eval_actions_test.dart | 11 | 4 | 1 |
| test/ui/session_filter_refresh_test.dart | 50 | 22 | 19 |
| test/ui/session_harness_actions_test.dart | 4 | 2 | 2 |
| test/ui/session_project_filters_test.dart | 15 | 5 | 6 |
| test/ui/session_stats_activity_cache_test.dart | 1 | 0 | 0 |
| test/ui/sessions_review_fixes_test.dart | 9 | 7 | 6 |
| test/ui/sessions_screen_test.dart | 19 | 6 | 4 |
| test/ui/settings_diagnostics_test.dart | 11 | 1 | 3 |
| test/ui/settings_screen_test.dart | 13 | 9 | 11 |
| test/ui/shortcuts_test.dart | 21 | 2 | 2 |
| test/ui/theme_test.dart | - | - | - |
| test/ui/usage_screen_test.dart | 5 | 2 | 4 |
| test/ui/voice_events_test.dart | 4 | 1 | 2 |
| test/usage/session_activity_test.dart | 3 | 0 | - |
| test/usage/usage_cost_reprice_benchmark_test.dart | 1 | 0 | 0 |
| test/usage/usage_projection_query_plan_test.dart | 92 | 17 | 21 |
| test/usage/usage_projection_test.dart | - | - | - |
| test/usage/usage_summary_test.dart | - | - | - |
| test/utils/profiling_test.dart | - | - | - |
| test/voice_over/platform_voice_over_test.dart | - | - | - |
| test/voice_over/voice_over_service_test.dart | - | - | - |
| test/window/window_state_test.dart | 13 | 0 | - |

Largest Linux spans: runtime_scan_app_test 79 s, resident_collector_client_test 45 s, external_ingestion_refresh_test 25, maintenance_concurrency_test 25, session_filter_refresh_test 22, usage_projection_query_plan_test 17. Windows step is slower overall (389 s).

## 5. Flutter integration tests (app/integration_test/)
- integration_test/core_workflows_test.dart (+ flutter_test_config.dart). 5 tests. Windows about 7 s test time, Linux 32.0 s step, ThreadRipper 86 s step.


## CXV-207 round-1 measurements (superseded selection)

These round-1 selections were expanded after dependency review. See the round-2
measurements below for the current candidate.

PAWEL3, Windows, PowerShell 7.6.9, Python 3.13, debug sidecars, incremental
caches. CPU shared with the other lane's load test; single observations, not
isolated benchmarks or percentile estimates. Total includes setup. No full
Rust or Flutter suite was run in this slice. Retained proof root:
`F:/dev-artifacts/runs/codex-sessions-viewer-main/cxv207-5120bcb5`.

### collector/src/resident/bridge.rs

Total: 197.67 s; all native exits 0; under the 300 s budget.

| Target/setup step | Wall s | Passed |
|---|---:|---:|
| rust-lib | 4.48 | 72 |
| rust-resident | 96.82 | 73 |
| rust-scan_launcher | 0.84 | 2 |
| rust-scan_transport | 5.28 | 4 |
| native-debug-build | 0.24 | - |
| flutter-pub-get | 2.19 | - |
| flutter-test_scanner_resident_collector_client_test_dart | 87.61 | 28 |

### app/lib/src/database/application_maintenance.dart

Total: 75.15 s; all native exits 0; under the 300 s budget.

| Target/setup step | Wall s | Passed |
|---|---:|---:|
| native-debug-build | 0.25 | - |
| flutter-pub-get | 2.30 | - |
| flutter-test_app_app_writer_coordinator_test_dart | 10.53 | 4 |
| flutter-test_app_runtime_scan_app_test_dart | 14.60 | 1 |
| flutter-test_database_application_maintenance_test_dart | 9.21 | 13 |
| flutter-test_database_backup_retention_test_dart | 7.07 | 6 |
| flutter-test_database_space_reclaim_test_dart | 7.05 | 5 |
| flutter-test_pricing_hub_price_history_test_dart | 8.66 | 18 |
| flutter-test_ui_settings_screen_test_dart | 15.00 | 18 |


## CXV-207 round-2 bounded policy measurements

Current candidate after R1/R2: Rust direct references plus one non-hub importer
hop and semantic mappings; Dart full reverse-import closure. Windows PAWEL3,
debug sidecars, incremental caches; CPU shared with the other lane. These are
single observations, not percentile measurements. The 300 s budget is unchanged.
Retained proof: `F:/dev-artifacts/runs/codex-sessions-viewer-main/cxv207-r2-380ca4fb`.

### collector/src/resident/bridge.rs

4 Rust targets, 4 Flutter files; total 211.02 s.
All native exits 0, under 300 s.

| Command/setup | Wall s |
|---|---:|
| rust-lib | 4.23 |
| rust-resident | 96.64 |
| rust-scan_launcher | 1.13 |
| rust-scan_transport | 10.05 |
| native-debug-build | 0.26 |
| flutter-pub-get | 2.68 |
| flutter-selected | 95.76 |

Concurrent Flutter spans include load and overlap; they do not sum to batch wall time.

| Flutter file | Span s | Passed |
|---|---:|---:|
| test/app/collector_ingestion_compat_test.dart | 35.787 | 5 |
| test/pricing/hub_price_history_test.dart | 6.653 | 18 |
| test/pricing/local_price_confirmation_test.dart | 4.091 | 5 |
| test/scanner/resident_collector_client_test.dart | 91.504 | 28 |

### app/lib/src/database/application_maintenance.dart

0 Rust targets, 18 Flutter files; total 73.44 s.
All native exits 0, under 300 s.

| Command/setup | Wall s |
|---|---:|
| native-debug-build | 0.33 |
| flutter-pub-get | 2.40 |
| flutter-selected | 51.41 |
| flutter-test_app_runtime_scan_app_test_dart | 19.00 |

Concurrent Flutter spans include load and overlap; they do not sum to batch wall time.

| Flutter file | Span s | Passed |
|---|---:|---:|
| test/accessibility/semantics_audit_test.dart | 14.082 | 6 |
| test/app_shell_test.dart | 6.260 | 5 |
| test/app/app_composition_test.dart | 4.973 | 2 |
| test/app/app_usage_test.dart | 16.369 | 6 |
| test/app/app_writer_coordinator_test.dart | 9.829 | 4 |
| test/app/external_ingestion_refresh_test.dart | 47.184 | 10 |
| test/app/startup_registration_app_test.dart | 6.580 | 1 |
| test/database/application_maintenance_test.dart | 9.732 | 13 |
| test/database/backup_retention_test.dart | 5.788 | 6 |
| test/database/database_startup_app_test.dart | 5.599 | 3 |
| test/database/maintenance_concurrency_test.dart | 27.741 | 34 |
| test/database/space_reclaim_test.dart | 6.473 | 5 |
| test/pricing/hub_price_history_test.dart | 9.286 | 18 |
| test/pricing/local_price_confirmation_test.dart | 4.921 | 5 |
| test/ui/app_shell_test.dart | 10.071 | 3 |
| test/ui/settings_screen_test.dart | 18.577 | 18 |
| test/window/window_state_test.dart | 1.565 | 13 |

