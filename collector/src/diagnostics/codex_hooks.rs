//! Native Codex lifecycle hook registration and legacy notify migration.
use super::*;

pub(super) const TRUST_NOTICE: &str = "Codex requires user approval in /hooks. Restart Codex or reload hooks and approve the changed hooks there; setup does not create or modify trust hashes.";

pub(super) fn hooks_path(o: &Options) -> PathBuf {
    o.config.with_file_name("hooks.json")
}

fn notify_array(doc: &toml_edit::DocumentMut) -> Result<Vec<String>, String> {
    match doc.get("notify") {
        None => Ok(Vec::new()),
        Some(item) => item
            .as_array()
            .ok_or("Codex notify must be an array of strings")?
            .iter()
            .map(|v| {
                v.as_str()
                    .map(str::to_owned)
                    .ok_or_else(|| "Codex notify must be an array of strings".into())
            })
            .collect(),
    }
}

fn computer_use(args: &[String]) -> bool {
    args.first().is_some_and(|exe| {
        let name = exe.rsplit(['\\', '/']).next().unwrap_or(exe);
        (name.eq_ignore_ascii_case("codex-computer-use")
            || name.eq_ignore_ascii_case("codex-computer-use.exe")
            || name.eq_ignore_ascii_case("codex-computer-use-arm64")
            || name.eq_ignore_ascii_case("codex-computer-use-arm64.exe"))
            && args.get(1).map(String::as_str) == Some("turn-ended")
    })
}

/// Strip collector nodes only. A supported outer wrapper retains its original
/// argv, with only its nested collector chain removed. Never recurse through
/// arbitrary programs whose --previous-notify contract is unknown.
fn strip_notify(args: &[String], depth: usize) -> Result<(Vec<String>, bool), String> {
    if depth >= 16 {
        return Err(
            "legacy notify chain is too deeply nested; repair it manually before setup".into(),
        );
    }
    let managed = is_managed(args, "codex", "notify");
    if !managed && !computer_use(args) {
        return Ok((args.to_vec(), false));
    }
    let positions: Vec<_> = args
        .iter()
        .enumerate()
        .filter_map(|(i, arg)| (arg == "--previous-notify").then_some(i))
        .collect();
    if positions.len() > 1 {
        return Err(
            "legacy notify chain has repeated --previous-notify options; repair it manually".into(),
        );
    }
    let Some(&index) = positions.first() else {
        return Ok((if managed { Vec::new() } else { args.to_vec() }, managed));
    };
    let inner = args
        .get(index + 1)
        .ok_or("legacy notify chain is incomplete; repair it manually")?;
    let inner: Vec<String> = serde_json::from_str(inner)
        .map_err(|_| "legacy notify predecessor is unreadable; repair it manually without discarding its contents")?;
    let (inner, removed) = strip_notify(&inner, depth + 1)?;
    if managed {
        return Ok((inner, true));
    }
    if !removed {
        return Ok((args.to_vec(), false));
    }
    let mut preserved = args.to_vec();
    if inner.is_empty() {
        preserved.drain(index..=index + 1);
    } else {
        preserved[index + 1] = serde_json::to_string(&inner).unwrap();
    }
    Ok((preserved, true))
}

fn legacy_plan(original: &str, remove: bool) -> Result<Plan, String> {
    let body = original.strip_prefix('\u{feff}').unwrap_or(original);
    let mut doc = body
        .parse::<toml_edit::DocumentMut>()
        .map_err(|_| "invalid Codex TOML; repair configuration before setup")?;
    let previous = notify_array(&doc)?;
    let (remaining, removed) = strip_notify(&previous, 0)?;
    if !remove && !remaining.is_empty() && !computer_use(&remaining) {
        return Err("legacy notify has an unsupported full-content contract; native migration cannot safely preserve it. No files were changed. Migrate that command to a compatible native hook explicitly before retrying setup".into());
    }
    let migrating = computer_use(&remaining);
    if migrating {
        validate_cleanup_chain(&remaining, 0)?;
    }

    if removed || migrating {
        if remaining.is_empty() || migrating {
            doc.remove("notify");
        } else {
            let mut array = toml_edit::Array::new();
            for arg in &remaining {
                array.push(arg.as_str());
            }
            doc["notify"] = toml_edit::value(array);
        }
    }
    Ok(Plan {
        contents: if removed || migrating {
            format!(
                "{}{}",
                if original.starts_with('\u{feff}') {
                    "\u{feff}"
                } else {
                    ""
                },
                doc
            )
        } else {
            original.into()
        },
        state: if removed || migrating {
            HookState::DifferentArguments
        } else {
            HookState::Absent
        },
        preserves_previous: removed && !remaining.is_empty(),
    })
}

fn validate_cleanup_chain(args: &[String], depth: usize) -> Result<(), String> {
    if depth >= 16 || !computer_use(args) {
        return Err("computer-use notify includes an unsupported full-content predecessor; no files were changed. Migrate that notifier explicitly before retrying setup".into());
    }
    match &args[2..] {
        [] => Ok(()),
        [flag, nested] if flag == "--previous-notify" => {
            let nested: Vec<String> = serde_json::from_str(nested)
                .map_err(|_| "computer-use notify predecessor is unreadable; repair it manually")?;
            validate_cleanup_chain(&nested, depth + 1)
        }
        _ => Err("computer-use notify has unsupported arguments; no files were changed. Review the legacy command before migrating".into()),
    }
}

fn managed_hook(item: &Value, verb: &str) -> bool {
    item["type"] == "command"
        && item["command"]
            .as_str()
            .is_some_and(|command| is_managed(&command_tokens(command, 3), "codex", verb))
}

fn native_plan(
    original: &str,
    args: &[String],
    verb: &str,
    events: &[&str],
    remove: bool,
) -> Result<Plan, String> {
    let body = original.strip_prefix('\u{feff}').unwrap_or(original);
    let mut doc: Value = if body.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str(body)
            .map_err(|_| "invalid Codex hooks.json; repair it before setup")?
    };
    let object = doc
        .as_object_mut()
        .ok_or("Codex hooks.json must be a JSON object")?;
    if remove && !object.contains_key("hooks") {
        return Ok(Plan {
            contents: original.into(),
            state: HookState::Absent,
            preserves_previous: false,
        });
    }
    let hooks = object
        .entry("hooks")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("Codex hooks must be an object")?;
    let command = shell_command(args)?;
    let (mut registered, mut any_managed, mut changed) = (true, false, false);
    for &event in events {
        let desired = if event == "Interrupt" {
            json!({"type":"command", "command":command, "timeout":3})
        } else {
            json!({"type":"command", "command":command})
        };
        if !hooks.contains_key(event) && remove {
            continue;
        }
        let entries = hooks
            .entry(event)
            .or_insert_with(|| json!([]))
            .as_array_mut()
            .ok_or("Codex hook events must be arrays")?;
        let mut managed = Vec::new();
        for entry in entries.iter() {
            let group = entry
                .as_object()
                .ok_or("Codex hook groups must be objects")?;
            let items = group
                .get("hooks")
                .and_then(Value::as_array)
                .ok_or("Codex hook groups must contain a hooks array")?;
            for item in items.iter().filter(|item| managed_hook(item, verb)) {
                managed.push((item, group));
            }
        }
        any_managed |= !managed.is_empty();
        let exact = managed.len() == 1
            && managed[0].0 == &desired
            && managed[0].1.keys().all(|key| key == "hooks");
        registered &= exact;
        if (!remove && exact) || (remove && managed.is_empty()) {
            continue;
        }
        changed = true;
        // Update the first unconditioned managed item in place. Retain
        // emptied groups before unrelated entries to keep their trust indexes.
        let mut replaced = false;
        let mut emptied_groups = Vec::new();
        for (index, entry) in entries.iter_mut().enumerate() {
            let plain = entry.as_object().unwrap().keys().all(|key| key == "hooks");
            let items = entry["hooks"].as_array_mut().unwrap();
            let before = items.len();
            let mut removed_handler = false;
            let mut shifts_foreign_handler = false;
            items.retain_mut(|item| {
                if !managed_hook(item, verb) {
                    shifts_foreign_handler |= removed_handler;
                    return true;
                }
                if !remove && !replaced && plain {
                    *item = desired.clone();
                    replaced = true;
                    true
                } else {
                    removed_handler = true;
                    false
                }
            });
            if shifts_foreign_handler {
                // Hook trust and enabled decisions are keyed by group and
                // handler index. This entire plan must fail before any writes.
                return Err(format!(
                    "cannot change {event} mixed hook group {index}: removing a managed handler would shift an unrelated handler index and invalidate its saved trust or enabled state. Explicitly restructure and review this mixed group in /hooks before retrying setup; no files were changed"
                ));
            }
            if before != items.len() && items.is_empty() && plain {
                emptied_groups.push(index);
            }
        }
        // Prune only trailing groups we emptied. Removing an earlier group
        // would unnecessarily shift trust identities of unrelated groups.
        while entries
            .len()
            .checked_sub(1)
            .is_some_and(|last| emptied_groups.contains(&last))
        {
            entries.pop();
        }
        if !remove && !replaced {
            entries.push(json!({"hooks":[desired.clone()]}));
        }
        if remove && entries.is_empty() {
            hooks.remove(event);
        }
    }
    if remove && changed && hooks.is_empty() {
        object.remove("hooks");
    }
    let state = if !remove && registered {
        HookState::Registered
    } else if any_managed {
        HookState::DifferentArguments
    } else {
        HookState::Absent
    };
    Ok(Plan {
        contents: if changed {
            format!(
                "{}{}\n",
                if original.starts_with('\u{feff}') {
                    "\u{feff}"
                } else {
                    ""
                },
                serde_json::to_string_pretty(&doc).unwrap()
            )
        } else {
            original.into()
        },
        state,
        preserves_previous: false,
    })
}

pub(super) const VENDOR_NOTICE: &str = "The Codex Windows app can reinstall legacy notify when computer-use starts or its helper path changes. Recheck status after those events; this migration does not prevent vendor reinsertion.";

struct Change {
    path: PathBuf,
    original: String,
    updated: String,
}

struct Installation {
    changes: Vec<Change>,
    plan: Plan,
    args: Vec<String>,
    adapter: bool,
}

fn installation(o: &Options) -> Result<Installation, String> {
    let original_config = read_config(&o.config)?;
    let original_hooks = read_config(&hooks_path(o))?;
    let legacy = legacy_plan(&original_config, o.remove)?;
    let args = hook_args("codex", o)?;
    let collection = native_plan(
        &original_hooks,
        &args,
        "hook",
        &["Stop", "Interrupt"],
        o.remove,
    )?;
    let command_path = o.config.with_file_name("collector-computer-use.json");
    let mut sidecar = None;
    let mut adapter = false;
    let mut native = collection;
    let doc = original_config
        .trim_start_matches('\u{feff}')
        .parse::<toml_edit::DocumentMut>()
        .map_err(|_| "invalid Codex TOML; repair configuration before setup")?;
    let (cleanup, _) = strip_notify(&notify_array(&doc)?, 0)?;
    if !o.remove || computer_use(&cleanup) {
        let original_command = read_config(&command_path)?;
        let migrating = !cleanup.is_empty();
        let command = if !cleanup.is_empty() {
            validate_cleanup_chain(&cleanup, 0)?;
            Some(cleanup)
        } else if !original_command.trim().is_empty() {
            let command: Vec<String> = serde_json::from_str(original_command.trim_start_matches('\u{feff}'))
                .map_err(|_| "invalid collector-computer-use.json; repair the saved cleanup command before setup")?;
            validate_cleanup_chain(&command, 0)?;
            Some(command)
        } else {
            None
        };
        if let Some(command) = command {
            adapter = true;
            let updated = if !migrating {
                original_command.clone()
            } else {
                format!("{}\n", serde_json::to_string_pretty(&command).unwrap())
            };
            sidecar = Some(Change {
                path: command_path.clone(),
                original: original_command,
                updated,
            });
            let adapter_args = vec![
                args[0].clone(),
                "codex".into(),
                "computer-use-hook".into(),
                "--command-file".into(),
                std::path::absolute(&command_path)
                    .map_err(|_| "cannot resolve cleanup command file path")?
                    .to_string_lossy()
                    .into_owned(),
            ];
            let cleanup_plan = native_plan(
                &native.contents,
                &adapter_args,
                "computer-use-hook",
                &["Stop", "Interrupt", "SubagentStop"],
                false,
            )?;
            let state = match (native.state, cleanup_plan.state) {
                (HookState::Registered, HookState::Registered) => HookState::Registered,
                (HookState::Absent, HookState::Absent) => HookState::Absent,
                _ => HookState::DifferentArguments,
            };
            native.contents = cleanup_plan.contents;
            native.state = state;
        } else if original_hooks.contains("computer-use-hook") {
            return Err("native computer-use cleanup is registered but its saved command file is missing; restore collector-computer-use.json or remove the stale cleanup entries explicitly".into());
        }
    }
    let mut state = native.state;
    if legacy.state != HookState::Absent {
        state = HookState::DifferentArguments;
    }
    let plan = Plan {
        contents: native.contents.clone(),
        state,
        preserves_previous: legacy.preserves_previous,
    };
    // The sidecar must exist before the adapter is registered. Remove the
    // oversized legacy entry only after both replacements succeed.
    let mut changes = Vec::new();
    if let Some(sidecar) = sidecar {
        changes.push(sidecar);
    }
    changes.push(Change {
        path: hooks_path(o),
        original: original_hooks,
        updated: native.contents,
    });
    changes.push(Change {
        path: o.config.clone(),
        original: original_config,
        updated: legacy.contents,
    });
    Ok(Installation {
        changes,
        plan,
        args,
        adapter,
    })
}

pub(super) fn has_legacy_notify(o: &Options) -> bool {
    read_config(&o.config)
        .ok()
        .and_then(|original| {
            original
                .trim_start_matches('\u{feff}')
                .parse::<toml_edit::DocumentMut>()
                .ok()
        })
        .and_then(|doc| notify_array(&doc).ok())
        .is_some_and(|argv| !argv.is_empty())
}

pub(super) fn detection(o: &Options) -> Result<Plan, String> {
    installation(o).map(|installation| installation.plan)
}

struct AppliedChange<'a> {
    change: &'a Change,
    existed: bool,
    identity: std::fs::File,
}

#[cfg(windows)]
fn same_file(left: &std::fs::File, right: &std::fs::File) -> std::io::Result<bool> {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{
        BY_HANDLE_FILE_INFORMATION, GetFileInformationByHandle,
    };
    let information = |file: &std::fs::File| -> std::io::Result<BY_HANDLE_FILE_INFORMATION> {
        let mut info = std::mem::MaybeUninit::uninit();
        // SAFETY: the handle stays alive and info is a correctly sized output.
        if unsafe { GetFileInformationByHandle(file.as_raw_handle(), info.as_mut_ptr()) } == 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: GetFileInformationByHandle succeeded and initialized info.
        Ok(unsafe { info.assume_init() })
    };
    let (left, right) = (information(left)?, information(right)?);
    Ok((
        left.dwVolumeSerialNumber,
        left.nFileIndexHigh,
        left.nFileIndexLow,
    ) == (
        right.dwVolumeSerialNumber,
        right.nFileIndexHigh,
        right.nFileIndexLow,
    ))
}

#[cfg(unix)]
fn same_file(left: &std::fs::File, right: &std::fs::File) -> std::io::Result<bool> {
    use std::os::unix::fs::MetadataExt;
    let (left, right) = (left.metadata()?, right.metadata()?);
    Ok((left.dev(), left.ino()) == (right.dev(), right.ino()))
}

fn rollback(applied: &AppliedChange<'_>) -> Result<Option<PathBuf>, String> {
    use std::io::Read;
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        // Deny concurrent writes and path replacement while checking/removing
        // a newly created file. DELETE operates on this exact opened object.
        options.access_mode(0x8001_0000).share_mode(1);
    }
    let mut current = options
        .open(&applied.change.path)
        .map_err(|_| "rollback cannot lock the updated configuration")?;
    if !same_file(&applied.identity, &current)
        .map_err(|_| "rollback cannot verify file identity")?
    {
        return Err(
            "rollback refused: configuration identity changed; preserve it and inspect manually"
                .into(),
        );
    }
    let mut contents = String::new();
    current
        .read_to_string(&mut contents)
        .map_err(|_| "rollback cannot read updated configuration")?;
    if contents != applied.change.updated {
        return Err(
            "rollback refused: configuration contents changed; preserve it and inspect manually"
                .into(),
        );
    }
    if applied.existed {
        drop(current);
        write_config(&applied.change.path, &contents, &applied.change.original)
    } else {
        #[cfg(windows)]
        {
            use std::os::windows::io::AsRawHandle;
            use windows_sys::Win32::Storage::FileSystem::{
                FILE_DISPOSITION_INFO, FileDispositionInfo, SetFileInformationByHandle,
            };
            let info = FILE_DISPOSITION_INFO { DeleteFile: true };
            // SAFETY: current owns a DELETE-capable handle, and info has the
            // exact size and layout required by FileDispositionInfo.
            if unsafe {
                SetFileInformationByHandle(
                    current.as_raw_handle(),
                    FileDispositionInfo,
                    (&info as *const FILE_DISPOSITION_INFO).cast(),
                    std::mem::size_of_val(&info) as u32,
                )
            } == 0
            {
                return Err("rollback could not remove newly created configuration".into());
            }
        }
        #[cfg(not(windows))]
        std::fs::remove_file(&applied.change.path)
            .map_err(|_| "rollback could not remove newly created configuration")?;
        Ok(None)
    }
}

fn apply_changes(changes: &[Change]) -> Result<Vec<PathBuf>, String> {
    let mut backups = Vec::new();
    let mut applied = Vec::new();
    for change in changes
        .iter()
        .filter(|change| change.original != change.updated)
    {
        let existed = std::fs::symlink_metadata(&change.path).is_ok();
        let result = write_config(&change.path, &change.original, &change.updated);
        match result {
            Ok(backup) => {
                if let Some(backup) = backup {
                    backups.push(backup);
                }
                let identity = std::fs::File::open(&change.path)
                    .map_err(|_| "configuration was updated but its rollback identity cannot be captured; inspect files and retained backups")?;
                applied.push(AppliedChange {
                    change,
                    existed,
                    identity,
                });
            }
            Err(error) => {
                let mut failures = Vec::new();
                for change in applied.iter().rev() {
                    match rollback(change) {
                        Ok(Some(backup)) => backups.push(backup),
                        Ok(None) => {}
                        Err(error) => failures.push(error),
                    }
                }
                return Err(format!(
                    "{error}; rollback: {}; retained backups: {}",
                    if failures.is_empty() {
                        "completed".into()
                    } else {
                        failures.join("; ")
                    },
                    serde_json::to_string(&backups).unwrap()
                ));
            }
        }
    }
    Ok(backups)
}

pub(super) fn setup(o: &Options) -> Result<Value, String> {
    let installation = installation(o)?;
    let changed = installation
        .changes
        .iter()
        .any(|change| change.original != change.updated);
    let (roots, detected) = roots(o);
    if o.apply && !o.remove && !detected {
        return Err("harness session roots are missing or unreadable; create/select the correct --root before applying setup".into());
    }
    let backups = if o.apply && changed {
        for change in &installation.changes {
            if read_config(&change.path)? != change.original {
                return Err(
                    "configuration changed during setup; review a new preview before retrying"
                        .into(),
                );
            }
        }
        apply_changes(&installation.changes)?
    } else {
        Vec::new()
    };
    let mut pruned = crate::backup_retention::PruneOutcome::default();
    if o.apply {
        let days = crate::settings::default_settings_file()
            .and_then(|path| crate::settings::CollectorSettings::load(&path).ok())
            .map_or(
                crate::backup_retention::DEFAULT_RETENTION_DAYS,
                |settings| settings.backup_retention_days,
            );
        for path in [
            &o.config,
            &hooks_path(o),
            &o.config.with_file_name("collector-computer-use.json"),
        ] {
            let result = crate::backup_retention::prune_config_backups(
                path,
                crate::backup_retention::retention(days),
                SystemTime::now(),
            );
            pruned.deleted.extend(result.deleted);
            pruned.failed.extend(result.failed);
        }
    }
    let planned: Vec<_> = installation
        .changes
        .iter()
        .map(|change| (&change.path, &change.updated))
        .collect();
    let planned = serde_json::to_vec(&planned).unwrap();
    Ok(json!({"command":"setup", "harness":"codex", "ok":true,
        "detected":detected, "roots":roots, "config":o.config, "hooks_config":hooks_path(o),
        "changed":changed,
        "config_changed":installation.changes.iter().any(|change| change.path == o.config && change.original != change.updated),
        "applied":o.apply, "removal":o.remove, "backup":backups.first(), "backups":backups,
        "pruned_backups":pruned.deleted, "backup_prune_failures":pruned.failed,
        "hook_state_before":installation.plan.state.name(), "planned_sha256":crate::dart::sha256_hex(&planned),
        "hook_command":installation.args, "preserves_existing_hook":installation.plan.preserves_previous,
        "computer_use_adapter":installation.adapter, "trust_notice":TRUST_NOTICE, "vendor_notice":VENDOR_NOTICE,
        "notice":"Existing hook commands, legacy notify arguments and unrelated configuration are never printed. Review the preview, then rerun with --apply."}))
}
