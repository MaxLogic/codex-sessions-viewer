# Collector setup and diagnostics

The Windows collector supports two harnesses, Codex and Claude Code. In this
guide, "harness" means either of these tools. Local setup does not require a
hub, token, or network connection. Keep the collector executable at a stable
path, because registered hooks call it by its absolute path.

## Preview, then apply

Start the viewer once to initialize its database. Then run these commands from
PowerShell, with `$collector` set to the collector in the folder where you
extracted the release:

```powershell
$collector = 'C:\Tools\CodexSessionViewer\codex-sessions-collector.exe'
& $collector codex setup --root "$env:USERPROFILE\.codex"
& $collector codex setup --root "$env:USERPROFILE\.codex" --apply
& $collector claude setup --root "$env:USERPROFILE\.claude\projects"
& $collector claude setup --root "$env:USERPROFILE\.claude\projects" --apply
```

Without `--apply`, `setup` only previews. The preview reports the target
configuration file, the managed hook arguments, the readable session roots,
whether existing hooks are preserved, and the SHA-256 of the planned file. For
the same inputs, the preview and `--apply` report the same hash. The preview
never prints existing configuration contents or previous hook arguments.
`--apply` requires readable roots. Repeating an unchanged setup makes no change.

The default configuration files are `CODEX_HOME/config.toml` (otherwise
`~/.codex/config.toml`) and `CLAUDE_CONFIG_DIR/settings.json` (otherwise
`~/.claude/settings.json`). The default roots are the Codex home and Claude's
`projects` directory. `--config FILE` selects a different harness configuration
file; this is not the viewer's `settings.toml`. Setup and the diagnostic
commands do not read custom roots from the viewer settings, so pass the same
roots that your collection commands use.

Use `--db FILE` for a viewer database that has been initialized, or
`--standalone FILE` for a database the collector owns without the viewer. Setup
registers that database in the hook but does not create or migrate it.
Initialize a standalone database with `codex scan --standalone FILE` or
`claude scan --standalone FILE` before verification.

Codex accepts one `--root`/`--windows-root` and optionally one `--wsl-root`.
Claude accepts repeated `--root`/`--claude-root` and `--claude-wsl-root`
arguments. The database stays on Windows; pass WSL roots as UNC paths. Relative
roots and database paths are resolved to absolute paths before the hook is
registered.

### What setup changes

- Codex: adds command hooks to `Stop` and `Interrupt` in the `hooks.json`
  beside `config.toml`, preserving other hook entries. Codex runs a new or
  changed hook only after you approve it in `/hooks`; setup never creates trust
  hashes, and it refuses an edit that would move another handler's saved trust
  within a shared hook group.
- Codex `notify`: a collector command left in the top-level `notify` of
  `config.toml` by an older setup is removed, preserving TOML comments and
  other values. The Codex computer-use notify command is saved in
  `collector-computer-use.json` and run by a separate adapter. Any other
  `notify` command stops setup without changing files, because it may depend
  on conversation text; migrate it to a native hook first.
- Claude: adds command hooks to `Stop` and `SessionEnd`, preserving other
  hook entries and unrelated JSON values. JSON formatting can change.
- Setup recognizes its own managed hook by the executable name
  `codex-sessions-collector.exe` (any folder, any letter case) followed by
  `codex hook` or `claude hook`. If a managed hook has other arguments, for
  example after you moved the executable or changed `--root` or `--db`, setup
  replaces it instead of duplicating it.
- Before replacing an existing file, setup keeps the previous version beside it
  as `<name>.<UTC time>.collector-backup` and reports that path as `backup`.
  The backup can contain the same secrets as the configuration. Each
  `setup --apply` deletes this configuration's own `*.collector-backup` files
  that are older than `[database] backup_retention_days` (7 days by default).
  That value is read from the `settings.toml` beside the collector. Other files
  are never touched.
- Files are written to a staging file and then replaced atomically. Existing
  Windows file ACLs are preserved with `ReplaceFileW`, which also gives the
  backup the original ACL. A UTF-8 byte order mark is accepted and kept.
  Malformed configurations and symbolic links are refused. If setup detects
  that another program changed the file before the replacement, it aborts.
- Claude runs hook commands through a shell. On Windows, setup refuses paths
  containing `"`, `%`, `!`, `$`, a backtick or a line break, because `cmd.exe`
  or Git Bash would expand them inside double quotes. Choose another
  executable, root or database path instead.

Each hook call queues the work locally and starts a detached process that works
through the queue. Setup does not install a scheduled job. Periodic full scans
are still useful to pick up sessions whose hook did not run.

## Verify the right layer

```powershell
& $collector codex verify --json
& $collector claude verify --local-proof --json
& $collector codex status
```

Pass the same `--config`, root and database overrides that you used during
setup. `detected` means the selected session roots can be read. It does not
mean that the harness executable is on PATH or currently running.

| Check | Behavior |
| --- | --- |
| Configuration | Readable roots, parseable harness configuration, expected hook registration. `hook_state` is `registered`, `different_arguments` (a managed hook exists with another executable path, roots or database) or `absent` |
| Database | Read-only schema, ownership and parser/cost writer-version agreement |
| Queue/status | Pending and claimed work for the selected harness, last collection time, global pending uploads |
| `--local-proof` | Ingest one synthetic session and message through the actual collector into a temporary standalone database, verify rows, then clean up |
| `--check-hub` | Explicit authenticated read-only request to `/v1/verify`; no history upload or outbox drain |

`last_scan_finished_utc` and pending uploads refer to the shared database.
`last_collection_utc` is the timestamp of the latest parsed session for the
selected harness; null means no collection has been recorded. Status never
drains queues, scans roots, creates the selected database, or writes to it.

Both text and `--json` output report configuration, local proof and hub results
separately. Exit codes: **0** all requested checks pass; **1** a check or setup
operation fails; **2** invalid arguments. If a requested hub check fails, the
local result is still reported in `local_ok`. Missing hooks or roots and an
uninitialized database count as failures, not as successful verification.

## Optional hub verification and delivery

```powershell
# Provide the machine token through the process environment, never CLI arguments.
# CODEX_SESSIONS_HUB_MACHINE_TOKEN must match a registered hub machine.
& $collector codex verify --check-hub --hub-url 'https://history.example.net' --json
& $collector hub sync
```

Without `--check-hub`, verify makes no network request, even when the database
is paired with a hub. `--check-hub` verifies authentication and checks that the
protocol, contract and schema versions match. It never uploads private history
or synthetic records. HTTPS is required except for a loopback test server, and
credentials in URLs and redirects are refused. Connection checks have a
five-second request timeout. Diagnostic output never includes server error
bodies or tokens.

Delivery is a separate step: run `hub sync` manually, or schedule it under an
account whose environment supplies the machine token. Setup does not embed
tokens in hooks, configuration or scheduled commands. If a delivery fails,
local collection keeps working and the pending records stay queued for the
next attempt.

## Tests

From a source checkout, run:

```powershell
cargo test --manifest-path collector/Cargo.toml --test collector_diagnostics
```

These tests run the real collector CLI. They cover preview and apply parity,
repeatability, retained hooks and secrets, managed-hook replacement after a
move or option change, backups, byte order marks, refused shell expansion
characters, hook states, synthetic ingestion for both harnesses, unavailable
roots, configuration errors, pending work and uploads, text and JSON output,
exit codes, and accepted and rejected authentication against a real isolated
local hub.
