//! Setup and read-only diagnostics. Configuration content and server responses
//! are deliberately excluded from reports: either can contain credentials.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OpenFlags, OptionalExtension};
use serde_json::{Value, json};

use crate::store::OwnerMode;

mod codex_hooks;

struct Options {
    config: PathBuf,
    roots: Vec<PathBuf>,
    root_flags: Vec<String>,
    db: Option<PathBuf>,
    standalone: bool,
    apply: bool,
    remove: bool,
    local_proof: bool,
    check_hub: bool,
    hub_url: Option<String>,
}

const HELP: &str = "setup previews hook registration; add --apply to write it. setup --remove previews removing the managed hooks and restoring any hook they replaced; add --apply to write it. verify checks configuration and database read-only; --local-proof ingests synthetic data in an isolated temporary database; --check-hub checks machine authentication without uploading history. Options: --config FILE, --root DIR (repeatable), --db FILE or --standalone FILE, --json, --hub-url URL.";

fn options(harness: &str, action: &str, args: &[String]) -> Result<Options, String> {
    let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME"));
    let home = home.map(PathBuf::from).unwrap_or_default();
    let harness_home = if harness == "codex" {
        std::env::var_os("CODEX_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".codex"))
    } else {
        std::env::var_os("CLAUDE_CONFIG_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".claude"))
    };
    let mut o = Options {
        config: harness_home.join(if harness == "codex" {
            "config.toml"
        } else {
            "settings.json"
        }),
        roots: Vec::new(),
        root_flags: Vec::new(),
        db: crate::settings::default_viewer_database(),
        standalone: false,
        apply: false,
        remove: false,
        local_proof: false,
        check_hub: false,
        hub_url: None,
    };
    let mut database_option = false;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--json" | "--preview" => {}
            "--apply" if action == "setup" => o.apply = true,
            "--remove" if action == "setup" => o.remove = true,
            "--local-proof" if action == "verify" => o.local_proof = true,
            "--check-hub" if action == "verify" => o.check_hub = true,
            "--config" | "--root" | "--windows-root" | "--claude-root" | "--wsl-root"
            | "--claude-wsl-root" | "--db" | "--standalone" | "--hub-url" => {
                let value = iter.next().ok_or_else(|| format!("{arg} needs a value"))?;
                match arg.as_str() {
                    "--config" => o.config = PathBuf::from(value),
                    "--db" | "--standalone" => {
                        if database_option {
                            return Err("use exactly one database option".into());
                        }
                        database_option = true;
                        o.db = Some(PathBuf::from(value));
                        o.standalone = arg == "--standalone";
                    }
                    "--hub-url" => o.hub_url = Some(value.clone()),
                    _ => {
                        let flag = match (harness, arg.as_str()) {
                            ("codex", "--root" | "--windows-root") => "--windows-root",
                            ("codex", "--wsl-root") => "--wsl-root",
                            ("claude", "--root" | "--claude-root") => "--claude-root",
                            ("claude", "--claude-wsl-root") => "--claude-wsl-root",
                            _ => return Err("root option belongs to the other harness".into()),
                        };
                        if harness == "codex"
                            && o.root_flags.iter().any(|existing| existing == flag)
                        {
                            return Err("Codex accepts one Windows root and one --wsl-root; use a Codex home to include active and archived sessions".into());
                        }
                        o.roots.push(PathBuf::from(value));
                        o.root_flags.push(flag.into());
                    }
                }
            }
            // Do not reflect unknown values: they may be credentials.
            _ => return Err(format!("unsupported option; {HELP}")),
        }
    }
    if o.roots.is_empty() {
        o.roots.push(if harness == "codex" {
            harness_home
        } else {
            harness_home.join("projects")
        });
        o.root_flags.push(
            if harness == "codex" {
                "--windows-root"
            } else {
                "--claude-root"
            }
            .into(),
        );
    }
    let cwd = std::env::current_dir().map_err(|_| "cannot resolve current directory")?;
    for path in o.roots.iter_mut().chain(o.db.iter_mut()) {
        if path.is_relative() {
            *path = cwd.join(&*path);
        }
    }
    Ok(o)
}

pub fn run(harness: &str, action: &str, args: &[String], out: &mut impl Write) -> i32 {
    let json_output = args.iter().any(|arg| arg == "--json");
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        let _ = writeln!(out, "{HELP}");
        return 0;
    }
    let options = match options(harness, action, args) {
        Ok(options) => options,
        Err(error) => {
            emit(
                out,
                json_output,
                &json!({"harness":harness,"command":action,"ok":false,"error":error,"exit_code":2}),
            );
            return 2;
        }
    };
    let result = if action == "setup" {
        setup(harness, &options)
    } else {
        diagnose(harness, action, &options)
    };
    let (report, code) = match result {
        Ok(report) => {
            let code = if report["ok"] == false { 1 } else { 0 };
            (report, code)
        }
        Err(error) => (
            json!({"harness":harness,"command":action,"ok":false,"error":error}),
            1,
        ),
    };
    emit(out, json_output, &report);
    code
}

fn emit(out: &mut impl Write, as_json: bool, report: &Value) {
    if as_json {
        let _ = writeln!(out, "{report}");
    } else {
        let _ = writeln!(
            out,
            "{} {}: {}",
            report["harness"].as_str().unwrap_or("collector"),
            report["command"].as_str().unwrap_or("diagnostics"),
            if report["ok"] == true {
                "OK"
            } else {
                "attention needed"
            }
        );
        if let Some(fields) = report.as_object() {
            for (key, value) in fields {
                if !["harness", "command", "ok"].contains(&key.as_str()) {
                    let _ = writeln!(out, "{key}: {value}");
                }
            }
        }
    }
}

fn read_config(path: &Path) -> Result<String, String> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => {
            let target = std::fs::canonicalize(path)
                .map(|target| target.display().to_string())
                .unwrap_or_else(|_| "unresolved target (repair the link first)".into());
            Err(format!(
                "configuration is a symbolic link; canonical target: {target}; pass --config pointing to config.toml alongside that canonical hooks.json target (or the canonical config.toml itself)"
            ))
        }
        Ok(_) => std::fs::read_to_string(path).map_err(|_| {
            "configuration is not readable UTF-8; check --config and permissions".into()
        }),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(_) => Err("cannot inspect configuration; check --config and permissions".into()),
    }
}

fn hook_args(harness: &str, o: &Options) -> Result<Vec<String>, String> {
    let exe = std::env::current_exe().map_err(|_| "cannot locate collector executable")?;
    let mut args = vec![
        exe.to_string_lossy().into_owned(),
        harness.into(),
        "hook".into(),
    ];
    if let Some(db) = &o.db {
        args.extend([
            if o.standalone { "--standalone" } else { "--db" }.into(),
            db.to_string_lossy().into_owned(),
        ]);
    }
    for (flag, root) in o.root_flags.iter().zip(&o.roots) {
        args.extend([flag.clone(), root.to_string_lossy().into_owned()]);
    }
    Ok(args)
}

// Claude executes command strings through a shell: cmd.exe or Git Bash on
// Windows. Quote every argument, and reject characters either shell expands
// inside double quotes rather than generating an unsafe hook.
fn shell_command(args: &[String]) -> Result<String, String> {
    args.iter().map(|arg| {
        if cfg!(windows) {
            if arg.contains(['"', '%', '!', '$', '`', '\r', '\n']) { return Err("hook paths contain shell expansion characters; use paths without quotes, percent, exclamation marks, dollar signs, backticks or line breaks".into()); }
            let trailing = arg.chars().rev().take_while(|c| *c == '\\').count();
            Ok(format!("\"{arg}{}\"", "\\".repeat(trailing)))
        } else {
            Ok(format!("'{}'", arg.replace('\'', "'\\''")))
        }
    }).collect::<Result<Vec<_>, String>>().map(|parts| parts.join(" "))
}

/// The leading tokens of a hook command generated by [`shell_command`] (or
/// written by hand in the same double- or single-quoted style).
fn command_tokens(command: &str, limit: usize) -> Vec<String> {
    let mut tokens = Vec::new();
    let mut chars = command.trim_start().chars().peekable();
    while tokens.len() < limit {
        while chars.next_if(|c| c.is_whitespace()).is_some() {}
        let Some(first) = chars.next() else { break };
        let mut token = String::new();
        if first == '"' || first == '\'' {
            for c in chars.by_ref() {
                if c == first {
                    break;
                }
                token.push(c);
            }
        } else {
            token.push(first);
            while let Some(c) = chars.next_if(|c| !c.is_whitespace()) {
                token.push(c);
            }
        }
        tokens.push(token);
    }
    tokens
}

/// True when `args` invoke this collector's `<harness> <verb>` entry point,
/// wherever that executable lives now or used to live.
fn is_managed(args: &[String], harness: &str, verb: &str) -> bool {
    let Some(exe) = args.first() else {
        return false;
    };
    let name = exe.rsplit(['\\', '/']).next().unwrap_or(exe);
    (name.eq_ignore_ascii_case("codex-sessions-collector.exe")
        || name.eq_ignore_ascii_case("codex-sessions-collector"))
        && args.get(1).map(String::as_str) == Some(harness)
        && args.get(2).map(String::as_str) == Some(verb)
}

/// Whether the configuration carries the desired managed hook, a managed hook
/// with other arguments (moved executable, other roots or database), or none.
#[derive(Clone, Copy, PartialEq, Eq)]
enum HookState {
    Registered,
    DifferentArguments,
    Absent,
}

impl HookState {
    fn name(self) -> &'static str {
        match self {
            Self::Registered => "registered",
            Self::DifferentArguments => "different_arguments",
            Self::Absent => "absent",
        }
    }
}

struct Plan {
    contents: String,
    state: HookState,
    preserves_previous: bool,
}

/// Plans the configuration change. A leading UTF-8 byte order mark, as
/// written by some Windows editors, is kept outside the parsed text and
/// preserved in the planned contents.
fn plan(harness: &str, original: &str, args: &[String]) -> Result<Plan, String> {
    match original.strip_prefix('\u{feff}') {
        Some(body) => plan_body(harness, body, args).map(|plan| Plan {
            contents: format!("\u{feff}{}", plan.contents),
            ..plan
        }),
        None => plan_body(harness, original, args),
    }
}

fn plan_body(_harness: &str, original: &str, args: &[String]) -> Result<Plan, String> {
    let mut doc: Value = if original.trim().is_empty() {
        json!({})
    } else {
        serde_json::from_str(original)
            .map_err(|_| "invalid Claude JSON; repair configuration before setup")?
    };
    let object = doc
        .as_object_mut()
        .ok_or("Claude settings must be a JSON object")?;
    let hooks = object
        .entry("hooks")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or("Claude hooks must be an object")?;
    let command = shell_command(args)?;
    let (mut all_registered, mut any_managed) = (true, false);
    let preserves_previous = !hooks.is_empty();
    let is_ours = |item: &Value| {
        item["type"] == "command"
            && item["command"]
                .as_str()
                .is_some_and(|c| is_managed(&command_tokens(c, 3), "claude", "hook"))
    };
    for event in ["Stop", "SessionEnd"] {
        let entries = hooks
            .entry(event)
            .or_insert_with(|| json!([]))
            .as_array_mut()
            .ok_or("Claude hook events must be arrays")?;
        let managed: Vec<&str> = entries
            .iter()
            .filter_map(|entry| entry.get("hooks").and_then(Value::as_array))
            .flatten()
            .filter(|item| is_ours(item))
            .filter_map(|item| item["command"].as_str())
            .collect();
        any_managed |= !managed.is_empty();
        if managed == [command.as_str()] {
            continue;
        }
        all_registered = false;
        // Replace the first managed hook in place and drop any others, so
        // a moved executable or changed options never leave duplicates.
        let mut replaced = false;
        let mut emptied = Vec::new();
        for (index, entry) in entries.iter_mut().enumerate() {
            let Some(items) = entry.get_mut("hooks").and_then(Value::as_array_mut) else {
                continue;
            };
            let before = items.len();
            items.retain_mut(|item| {
                if !is_ours(item) {
                    return true;
                }
                if replaced {
                    return false;
                }
                replaced = true;
                item["command"] = json!(command);
                true
            });
            if before > 0 && items.is_empty() {
                emptied.push(index);
            }
        }
        for index in emptied.into_iter().rev() {
            entries.remove(index);
        }
        if !replaced {
            entries.push(json!({"hooks":[{"type":"command","command":command}]}));
        }
    }
    let registered = all_registered;
    let state = if registered {
        HookState::Registered
    } else if any_managed {
        HookState::DifferentArguments
    } else {
        HookState::Absent
    };
    Ok(Plan {
        contents: if registered {
            original.into()
        } else {
            format!("{}\n", serde_json::to_string_pretty(&doc).unwrap())
        },
        state,
        preserves_previous,
    })
}

/// Plans removing this collector's managed hooks and restoring the hook they
/// chained to, leaving every other setting untouched.
fn plan_removal(harness: &str, original: &str) -> Result<Plan, String> {
    match original.strip_prefix('\u{feff}') {
        Some(body) => plan_removal_body(harness, body).map(|plan| Plan {
            contents: format!("\u{feff}{}", plan.contents),
            ..plan
        }),
        None => plan_removal_body(harness, original),
    }
}

fn plan_removal_body(_harness: &str, original: &str) -> Result<Plan, String> {
    let unchanged = |state| Plan {
        contents: original.into(),
        state,
        preserves_previous: false,
    };
    if original.trim().is_empty() {
        return Ok(unchanged(HookState::Absent));
    }
    let mut doc: Value = serde_json::from_str(original)
        .map_err(|_| "invalid Claude JSON; repair configuration before setup")?;
    let object = doc
        .as_object_mut()
        .ok_or("Claude settings must be a JSON object")?;
    let Some(hooks) = object.get_mut("hooks") else {
        return Ok(unchanged(HookState::Absent));
    };
    let hooks = hooks
        .as_object_mut()
        .ok_or("Claude hooks must be an object")?;
    let is_ours = |item: &Value| {
        item["type"] == "command"
            && item["command"]
                .as_str()
                .is_some_and(|c| is_managed(&command_tokens(c, 3), "claude", "hook"))
    };
    let mut removed = false;
    for event in ["Stop", "SessionEnd"] {
        let Some(entries) = hooks.get_mut(event).and_then(Value::as_array_mut) else {
            continue;
        };
        let mut touched = false;
        for entry in entries.iter_mut() {
            let Some(items) = entry.get_mut("hooks").and_then(Value::as_array_mut) else {
                continue;
            };
            let before = items.len();
            items.retain(|item| !is_ours(item));
            touched |= items.len() != before;
        }
        if touched {
            removed = true;
            entries.retain(|entry| {
                entry
                    .get("hooks")
                    .and_then(Value::as_array)
                    .is_none_or(|items| !items.is_empty())
            });
            if entries.is_empty() {
                hooks.remove(event);
            }
        }
    }
    if !removed {
        return Ok(unchanged(HookState::Absent));
    }
    if hooks.is_empty() {
        object.remove("hooks");
    }
    Ok(Plan {
        contents: format!("{}\n", serde_json::to_string_pretty(&doc).unwrap()),
        state: HookState::Registered,
        // Claude hooks are only added on install, never chained, so
        // nothing is restored; other hooks merely stay.
        preserves_previous: false,
    })
}

fn roots(o: &Options) -> (Vec<Value>, bool) {
    let reports: Vec<_> = o.roots.iter().map(|root| {
        let readable = std::fs::read_dir(root).is_ok();
        json!({"path":root,"readable":readable,"error":if readable { None } else { Some("session root is missing or unreadable; check --root and permissions") }})
    }).collect();
    let ok = reports.iter().all(|report| report["readable"] == true);
    (reports, ok)
}

fn setup(harness: &str, o: &Options) -> Result<Value, String> {
    if harness == "codex" {
        return codex_hooks::setup(o);
    }
    let original = read_config(&o.config)?;
    let args = hook_args(harness, o)?;
    let plan = if o.remove {
        plan_removal(harness, &original)?
    } else {
        plan(harness, &original, &args)?
    };
    let (roots, detected) = roots(o);
    let changed = original != plan.contents;
    // Removing a hook never needs the session folders.
    if o.apply && !o.remove && !detected {
        return Err("harness session roots are missing or unreadable; create/select the correct --root before applying setup".into());
    }
    let backup = if o.apply && changed {
        write_config(&o.config, &original, &plan.contents)?
    } else {
        None
    };
    // An applied setup also deletes its own old configuration backups.
    let pruned = if o.apply {
        let days = crate::settings::default_settings_file()
            .and_then(|path| crate::settings::CollectorSettings::load(&path).ok())
            .map_or(
                crate::backup_retention::DEFAULT_RETENTION_DAYS,
                |settings| settings.backup_retention_days,
            );
        crate::backup_retention::prune_config_backups(
            &o.config,
            crate::backup_retention::retention(days),
            SystemTime::now(),
        )
    } else {
        crate::backup_retention::PruneOutcome::default()
    };
    Ok(
        json!({"command":"setup","harness":harness,"ok":true,"detected":detected,"roots":roots,"config":o.config,"changed":changed,"applied":o.apply,"removal":o.remove,"backup":backup,"pruned_backups":pruned.deleted,"backup_prune_failures":pruned.failed,"hook_state_before":plan.state.name(),"planned_sha256":crate::dart::sha256_hex(plan.contents.as_bytes()),"hook_command":args,"preserves_existing_hook":plan.preserves_previous,"notice":"Preview contains the managed command only; existing notify arguments and unrelated configuration are never printed. Rerun with --apply to write this plan."}),
    )
}

/// A new backup path beside `path`, named after the replacement time. Each
/// changing setup keeps its own copy so an earlier original is never lost.
fn backup_path(path: &Path) -> PathBuf {
    let name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "configuration".into());
    let stamp = chrono::Utc::now().format("%Y%m%dT%H%M%SZ");
    let mut candidate = path.with_file_name(format!("{name}.{stamp}.collector-backup"));
    let mut counter = 1;
    while std::fs::symlink_metadata(&candidate).is_ok() {
        candidate = path.with_file_name(format!("{name}.{stamp}-{counter}.collector-backup"));
        counter += 1;
    }
    candidate
}

/// Atomically replaces the configuration and returns the backup of the
/// replaced file, if one existed.
fn write_config(path: &Path, original: &str, updated: &str) -> Result<Option<PathBuf>, String> {
    let parent = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent)
        .map_err(|_| "cannot create configuration directory; check permissions")?;
    let temporary = parent.join(format!(
        ".collector-setup-{}-{}.tmp",
        std::process::id(),
        nonce()
    ));
    let result = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            // Owner-only until the original's mode is copied, so a secret
            // never sits in a world-readable staging file.
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options
            .open(&temporary)
            .map_err(|_| "cannot create configuration staging file")?;
        file.write_all(updated.as_bytes())
            .and_then(|_| file.sync_all())
            .map_err(|_| "cannot write configuration staging file")?;
        drop(file);
        if let Ok(meta) = std::fs::metadata(path) {
            let permissions = preserve_owner(&meta, &temporary)
                .map_err(|_| "cannot preserve configuration ownership")?;
            std::fs::set_permissions(&temporary, permissions)
                .map_err(|_| "cannot preserve configuration permissions")?;
        }
        if read_config(path)? != original {
            return Err(
                "configuration changed during setup; review a new preview before retrying".into(),
            );
        }
        let backup = path.exists().then(|| backup_path(path));
        replace_config(&temporary, path, backup.as_deref())
            .map_err(|_| "cannot replace configuration; check permissions and retry")?;
        Ok(backup)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result
}

/// Gives the staged file the original's owner and group where allowed, and
/// returns the permissions to apply to it.
///
/// Only a privileged user may change the owner; otherwise the file stays the
/// current user's, who runs setup, and the original group is kept when the
/// user belongs to it. When the group cannot be kept either, the original's
/// group and other bits would grant them to the wrong group, so only the
/// owner bits survive.
#[cfg(unix)]
fn preserve_owner(
    original: &std::fs::Metadata,
    staged: &Path,
) -> std::io::Result<std::fs::Permissions> {
    use std::os::unix::fs::{MetadataExt, PermissionsExt, chown};
    let denied = |result: &std::io::Result<()>| matches!(result, Err(error) if error.kind() == std::io::ErrorKind::PermissionDenied);
    let mut result = chown(staged, Some(original.uid()), Some(original.gid()));
    if denied(&result) {
        result = chown(staged, None, Some(original.gid()));
    }
    let group_kept = if denied(&result) {
        false
    } else {
        result?;
        true
    };
    Ok(std::fs::Permissions::from_mode(staged_mode(
        original.permissions().mode(),
        group_kept,
    )))
}

/// The staged file's mode: the original's, or only its owner bits when the
/// original group could not be kept.
#[cfg(unix)]
fn staged_mode(original_mode: u32, group_kept: bool) -> u32 {
    if group_kept {
        original_mode & 0o7777
    } else {
        original_mode & 0o700
    }
}

/// Windows keeps the owner and ACL through `ReplaceFileW`.
#[cfg(not(unix))]
fn preserve_owner(
    original: &std::fs::Metadata,
    _staged: &Path,
) -> std::io::Result<std::fs::Permissions> {
    Ok(original.permissions())
}

#[cfg(not(windows))]
fn replace_config(staged: &Path, target: &Path, backup: Option<&Path>) -> std::io::Result<()> {
    if let Some(backup) = backup {
        std::fs::hard_link(target, backup).or_else(|_| std::fs::copy(target, backup).map(drop))?;
    }
    std::fs::rename(staged, target)
}

#[cfg(windows)]
fn replace_config(staged: &Path, target: &Path, backup: Option<&Path>) -> std::io::Result<()> {
    use std::os::windows::ffi::OsStrExt;
    if !target.exists() {
        return std::fs::rename(staged, target);
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn ReplaceFileW(
            replaced: *const u16,
            replacement: *const u16,
            backup: *const u16,
            flags: u32,
            exclude: *mut std::ffi::c_void,
            reserved: *mut std::ffi::c_void,
        ) -> i32;
    }
    let target: Vec<u16> = target.as_os_str().encode_wide().chain(Some(0)).collect();
    let staged: Vec<u16> = staged.as_os_str().encode_wide().chain(Some(0)).collect();
    let backup: Option<Vec<u16>> =
        backup.map(|path| path.as_os_str().encode_wide().chain(Some(0)).collect());
    // SAFETY: owned, nul-terminated UTF-16 buffers outlive this synchronous
    // call. ReplaceFile preserves the original ACL and moves the replaced file,
    // with its ACL, to the backup name; do not ignore ACL merge errors or fall
    // back to a lossy rename for an existing secret-bearing file.
    let result = unsafe {
        ReplaceFileW(
            target.as_ptr(),
            staged.as_ptr(),
            backup
                .as_ref()
                .map_or(std::ptr::null(), |path| path.as_ptr()),
            0,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if result == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

fn nonce() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos()
}

fn diagnose(harness: &str, action: &str, o: &Options) -> Result<Value, String> {
    let (roots, roots_ok) = roots(o);
    let config = if harness == "codex" {
        codex_hooks::detection(o)
    } else {
        read_config(&o.config)
            .and_then(|original| plan(harness, &original, &hook_args(harness, o)?))
    };
    let (state, config_error) = match config {
        Ok(plan) => (Some(plan.state), None),
        Err(error) => (None, Some(error)),
    };
    let state = if harness == "codex" && codex_hooks::has_legacy_notify(o) {
        Some(HookState::DifferentArguments)
    } else {
        state
    };
    let registered = state == Some(HookState::Registered);
    let hook_action = match state {
        Some(HookState::Registered) => None,
        Some(HookState::DifferentArguments) => Some(
            "a managed hook is registered with different arguments (moved executable, roots or database); rerun setup with the intended options, review its preview, then setup --apply",
        ),
        _ => Some("run setup, review its preview, then setup --apply"),
    };
    let queue = queue_status(harness);
    let database = database_status(harness, o);
    let local = if o.local_proof {
        local_proof(harness)
    } else {
        json!({"state":"not_requested"})
    };
    let hub_url = o
        .hub_url
        .clone()
        .or_else(|| database["hub_url"].as_str().map(str::to_owned));
    let hub = if o.check_hub {
        hub_check(hub_url.as_deref())
    } else {
        json!({"state":if hub_url.is_some() { "not_checked" } else { "offline" },"notice":"local collection does not require a hub"})
    };
    let configuration_ok = roots_ok && registered && config_error.is_none();
    let local_ok = configuration_ok
        && database["ok"] == true
        && queue["ok"] == true
        && local["state"] != "failed";
    let ok = local_ok && hub["state"] != "failed";
    let mut database = database;
    // URLs can contain credentials or query secrets. They are input only.
    database.as_object_mut().unwrap().remove("hub_url");
    Ok(
        json!({"command":action,"harness":harness,"ok":ok,"detected":roots_ok,"roots":roots,"configuration":{"ok":configuration_ok,"config":o.config,"hook_registered":registered,"hook_state":state.map(HookState::name),"error":config_error,"action":hook_action},"hooks_config":if harness == "codex" { Some(codex_hooks::hooks_path(o)) } else { None },"trust_notice":if harness == "codex" { Some(codex_hooks::TRUST_NOTICE) } else { None },"vendor_notice":if harness == "codex" { Some(codex_hooks::VENDOR_NOTICE) } else { None },"local_ok":local_ok,"database":database,"queue":queue,"local_ingestion_proof":local,"hub":hub}),
    )
}

fn queue_status(harness: &str) -> Value {
    let path = crate::hooks::queue_dir();
    let entries = match std::fs::read_dir(&path) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return json!({"ok":true,"pending":0,"claimed":0});
        }
        Err(_) => {
            return json!({"ok":false,"error":"cannot read hook queue; check CODEX_SESSIONS_COLLECTOR_QUEUE and permissions"});
        }
    };
    let (mut pending, mut claimed, mut unreadable) = (0, 0, 0);
    for entry in entries {
        let Ok(entry) = entry else {
            unreadable += 1;
            continue;
        };
        let name = entry.file_name().to_string_lossy().into_owned();
        let is_pending = name.ends_with(".json");
        let is_claimed = name.contains(".claimed-");
        if !is_pending && !is_claimed {
            continue;
        }
        match std::fs::read(entry.path())
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        {
            Some(item) if item["harness"] == harness => {
                if is_pending {
                    pending += 1;
                } else {
                    claimed += 1;
                }
            }
            Some(_) => {}
            None => unreadable += 1,
        }
    }
    json!({"ok":unreadable == 0,"pending":pending,"claimed":claimed,"unreadable":unreadable})
}

fn database_status(harness: &str, o: &Options) -> Value {
    let Some(path) = &o.db else {
        return json!({"ok":false,"error":"no database selected; pass --db or --standalone"});
    };
    let conn = match Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY) {
        Ok(conn) => conn,
        Err(_) => {
            return json!({"ok":false,"error":"cannot open database read-only; start viewer once or initialize with a standalone scan"});
        }
    };
    let _ = conn.busy_timeout(Duration::from_secs(2));
    let mode = if o.standalone {
        OwnerMode::Standalone
    } else {
        OwnerMode::Viewer
    };
    if let Err(error) = crate::store::schema::check_writable(&conn, mode, "selected database") {
        return json!({"ok":false,"error":error.to_string()});
    }
    let last: Option<String> = conn
        .query_row("select max(finished_at_utc) from scan_runs", [], |row| {
            row.get(0)
        })
        .unwrap_or(None);
    let last_session: Option<String> = conn
        .query_row(
            "select max(last_parsed_utc) from sessions where harness = ?",
            [harness],
            |row| row.get(0),
        )
        .unwrap_or(None);
    let pending: Option<i64> = conn
        .query_row("select count(*) from collector_upload_outbox", [], |row| {
            row.get(0)
        })
        .ok();
    let hub: Option<String> = conn
        .query_row(
            "select hub_url from collector_hub_state where id=1 and enabled=1",
            [],
            |row| row.get(0),
        )
        .optional()
        .unwrap_or(None);
    json!({"ok":true,"last_scan_finished_utc":last,"last_collection_utc":last_session,"pending_uploads":pending,"hub_url":hub})
}

fn local_proof(harness: &str) -> Value {
    let temp = std::env::temp_dir().join(format!(
        "collector-proof-{}-{}",
        std::process::id(),
        nonce()
    ));
    let result = (|| -> Result<(), String> {
        std::fs::create_dir(&temp).map_err(|_| "cannot create isolated proof directory")?;
        let input = temp.join("diagnostic-synthetic.jsonl");
        let text = if harness == "codex" {
            "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"collector-diagnostic-synthetic\",\"cwd\":\"C:/synthetic\"}}\n{\"timestamp\":\"2026-01-01T00:00:01Z\",\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"Synthetic collector diagnostic\"}]}}\n"
        } else {
            "{\"type\":\"user\",\"timestamp\":\"2026-01-01T00:00:01Z\",\"sessionId\":\"collector-diagnostic-synthetic\",\"uuid\":\"diagnostic-message\",\"cwd\":\"C:/synthetic\",\"message\":{\"role\":\"user\",\"content\":\"Synthetic collector diagnostic\"}}\n"
        };
        std::fs::write(&input, text).map_err(|_| "cannot stage synthetic proof input")?;
        let db = temp.join("proof.sqlite");
        let settings = temp.join("settings.toml");
        std::fs::write(
            &settings,
            "[paths]\nwindows_codex_path = ''\nwsl_codex_unc_path = ''\n",
        )
        .map_err(|_| "cannot stage proof settings")?;
        let output = std::process::Command::new(
            std::env::current_exe().map_err(|_| "cannot locate collector")?,
        )
        .args([harness, "ingest", "--standalone"])
        .arg(&db)
        .arg("--settings")
        .arg(&settings)
        .args(["--no-wsl-projects", "--json"])
        .arg(&input)
        .output()
        .map_err(|_| "cannot start isolated ingestion proof")?;
        if !output.status.success() {
            return Err(
                "synthetic ingestion failed; run the collector regression suite for details".into(),
            );
        }
        let conn = Connection::open_with_flags(&db, OpenFlags::SQLITE_OPEN_READ_ONLY)
            .map_err(|_| "cannot read isolated ingestion result")?;
        let count: i64 = conn
            .query_row(
                "select count(*) from sessions where harness = ?",
                [harness],
                |row| row.get(0),
            )
            .map_err(|_| "cannot verify synthetic session")?;
        let messages: i64 = conn.query_row("select count(*) from messages where content_plain = 'Synthetic collector diagnostic'", [], |row| row.get(0)).map_err(|_| "cannot verify synthetic message")?;
        if count != 1 || messages != 1 {
            return Err(
                "synthetic ingestion did not persist the expected session and message".into(),
            );
        }
        Ok(())
    })();
    let cleanup = std::fs::remove_dir_all(&temp);
    match (result, cleanup) {
        (Ok(()), Ok(())) => {
            json!({"state":"passed","synthetic":true,"isolated":true,"sessions":1,"messages":1})
        }
        (Err(error), _) => json!({"state":"failed","error":error}),
        (_, Err(_)) => {
            json!({"state":"failed","error":"proof passed but temporary directory cleanup failed"})
        }
    }
}

fn hub_check(url: Option<&str>) -> Value {
    let Some(url) = url else {
        return json!({"state":"failed","error":"hub is not configured; pass --hub-url or omit --check-hub for local-only verification"});
    };
    let url = url.trim_end_matches('/');
    if !(url.starts_with("https://")
        || url.starts_with("http://127.0.0.1:")
        || url.starts_with("http://localhost:")
        || url.starts_with("http://[::1]:"))
        || url.contains(['@', '?', '#'])
    {
        return json!({"state":"failed","error":"hub URL must use HTTPS (HTTP allowed on loopback), with no credentials, query or fragment"});
    }
    let token = match std::env::var("CODEX_SESSIONS_HUB_MACHINE_TOKEN") {
        Ok(token) if !token.is_empty() => token,
        _ => {
            return json!({"state":"failed","error":"set CODEX_SESSIONS_HUB_MACHINE_TOKEN; local ingestion remains independent"});
        }
    };
    let agent: ureq::Agent = ureq::Agent::config_builder()
        .timeout_global(Some(Duration::from_secs(5)))
        .max_redirects(0)
        .build()
        .into();
    match agent
        .get(format!("{url}/v1/verify"))
        .header("Authorization", format!("Bearer {token}"))
        .call()
    {
        Ok(mut response) => match response.body_mut().read_json::<Value>() {
            Ok(value)
                if value["protocol"] == crate::hub_server::HUB_PROTOCOL_VERSION
                    && value["contract"] == crate::contract::CONTRACT_NAME
                    && value["contract_version"] == crate::contract::CONTRACT_VERSION
                    && value["schema_version"]
                        == crate::store::schema::SUPPORTED_SCHEMA_VERSION =>
            {
                json!({"state":"passed","authenticated":true,"uploaded_records":0})
            }
            _ => {
                json!({"state":"failed","error":"hub returned an incompatible verification response"})
            }
        },
        Err(ureq::Error::StatusCode(401 | 403)) => {
            json!({"state":"failed","error":"hub rejected machine credentials; check token registration; local ingestion is unaffected"})
        }
        Err(_) => {
            json!({"state":"failed","error":"hub connection failed; check URL, service and network; local ingestion is unaffected"})
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::staged_mode;

    #[test]
    fn a_lost_group_keeps_only_the_owner_bits() {
        assert_eq!(staged_mode(0o100640, true), 0o640);
        assert_eq!(staged_mode(0o100640, false), 0o600);
        assert_eq!(staged_mode(0o100604, false), 0o600);
        assert_eq!(staged_mode(0o100600, false), 0o600);
    }
}
