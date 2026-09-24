# Collector setup and diagnostics

The Windows collector supports Codex and Claude Code. Local setup does not
require a hub, token, or network connection. Keep the collector executable at a
stable path: registered hooks use its absolute path.

## Preview, then apply

Start the viewer once to initialize its database. Run from PowerShell:

```powershell
$collector = 'C:\Tools\CodexSessionViewer\codex-sessions-collector.exe'
& $collector codex setup --root "$env:USERPROFILE\.codex"
& $collector codex setup --root "$env:USERPROFILE\.codex" --apply
& $collector claude setup --root "$env:USERPROFILE\.claude\projects"
& $collector claude setup --root "$env:USERPROFILE\.claude\projects" --apply
```

`setup` defaults to a preview. It reports the target configuration, managed hook
arguments, readable roots, whether existing hooks are preserved, and the SHA-256
of the planned file. The same inputs produce the same preview and applied hash.
No existing configuration contents or previous hook arguments are printed.
`--apply` requires readable roots. Repeating an unchanged setup makes no change.

The defaults are `CODEX_HOME/config.toml` (otherwise `~/.codex/config.toml`) and
`CLAUDE_CONFIG_DIR/settings.json` (otherwise `~/.claude/settings.json`). Default
roots are the Codex home and Claude's `projects` directory. `--config FILE`
overrides the harness configuration; this is distinct from the viewer's
`settings.toml`. Diagnostics do not infer custom roots from viewer settings:
pass the same roots used by your collection commands.

Use `--db FILE` for an initialized viewer database or `--standalone FILE` for a
collector-owned database. Setup registers that destination but does not create
or migrate it. Initialize a standalone database with `codex scan --standalone
FILE` or `claude scan --standalone FILE` before verification.

Codex accepts one `--root`/`--windows-root` and optionally one `--wsl-root`.
Claude accepts repeated `--root`/`--claude-root` and `--claude-wsl-root` arguments.
Windows-owned databases stay on Windows; WSL roots are UNC input paths.
Relative roots and database paths are resolved before hook registration.

### What setup changes

- Codex: updates only top-level `notify`, preserving TOML comments and other
  values. Another notify command is retained through `--previous-notify`.
- Claude: adds command hooks to `Stop` and `SessionEnd`, preserving other
  hook entries and unrelated JSON values. JSON formatting can change.
- Setup recognizes its own managed hook by the executable name
  `codex-sessions-collector.exe` (any folder, any letter case) followed by
  `codex notify` or `claude hook`. A managed hook with other arguments, for
  example after moving the executable or changing `--root` or `--db`, is
  replaced rather than chained or duplicated. A replaced Codex notify keeps the
  `--previous-notify` command it already carried, and earlier chains in which
  the collector wrapped itself are unwrapped.
- Before replacing an existing file, setup keeps the previous version beside it
  as `<name>.<UTC time>.collector-backup` and reports that path as `backup`.
  The backup can contain the same secrets as the configuration. Delete it once
  the new configuration works.
- Files are staged and replaced atomically. Existing Windows file ACLs are
  preserved with `ReplaceFileW`, which also gives the backup the original ACL.
  A UTF-8 byte order mark is accepted and kept. Malformed configurations and
  symbolic links are refused. Concurrent edits detected before replacement
  abort setup.
- Claude runs hook commands through a shell. On Windows, setup refuses paths
  containing `"`, `%`, `!`, `$`, a backtick or a line break, which `cmd.exe` or
  Git Bash would expand inside double quotes. Choose another executable, root
  or database path instead.

Hooks queue local work and start a detached drain. Setup does not install a
scheduled job. Periodic full scans remain useful to reconcile missed hooks.

## Verify the right layer

```powershell
& $collector codex verify --json
& $collector claude verify --local-proof --json
& $collector codex status
```

Supply the same `--config`, root and database overrides used during setup.
`detected` means the selected session roots can be read; it does not assert that
the harness executable is on PATH or currently running.

| Check | Behavior |
| --- | --- |
| Configuration | Readable roots, parseable harness configuration, expected hook registration. `hook_state` is `registered`, `different_arguments` (a managed hook exists with another executable path, roots or database) or `absent` |
| Database | Read-only schema, ownership and parser/cost writer-version agreement |
| Queue/status | Pending and claimed work for the selected harness, last collection time, global pending uploads |
| `--local-proof` | Ingest one synthetic session and message through the actual collector into a temporary standalone database, verify rows, then clean up |
| `--check-hub` | Explicit authenticated read-only request to `/v1/verify`; no history upload or outbox drain |

`last_scan_finished_utc` and pending uploads refer to the shared database.
`last_collection_utc` is the selected harness's latest parsed session timestamp;
null means no recorded collection. Status never drains queues, scans roots,
creates the selected database, or writes its contents.

Both text and `--json` output distinguish configuration, local proof and hub
results. Exit codes: **0** all requested checks pass; **1** a check or setup
operation fails; **2** invalid arguments. If a requested hub check fails,
`local_ok` remains independently available. Missing hooks/roots or an
uninitialized database are actionable failures, not successful verification.

## Optional hub verification and delivery

```powershell
# Provide the machine token through the process environment, never CLI arguments.
# CODEX_SESSIONS_HUB_MACHINE_TOKEN must match a registered hub machine.
& $collector codex verify --check-hub --hub-url 'https://history.example.net' --json
& $collector hub sync
```

Without `--check-hub`, no network request occurs, even when the database is paired
with a hub. Explicit checks verify authentication and matching protocol, contract
and schema versions; they never upload private history or synthetic records.
HTTPS is required except for a loopback test server; credentials in URLs and
redirects are refused. Connection checks have a five-second request timeout.
Server error bodies and tokens are not included in diagnostic output.

Delivery is separate: invoke `hub sync` manually or schedule it under an account
whose environment supplies the machine token. Setup does not embed tokens in
hooks, configuration or scheduled commands. A failed delivery leaves local
collection usable and pending records available for retry.

## Retained proof

```powershell
cargo test --manifest-path collector/Cargo.toml --test collector_diagnostics
```

The actual CLI tests cover preview/apply parity, repeatability, retained hooks
and secrets, managed-hook replacement after a move or option change, backups,
byte order marks, refused shell expansion characters, hook states, synthetic ingestion for both harnesses, unavailable roots,
configuration errors, pending work/uploads, text/JSON output and exit codes,
and accepted/rejected authentication against a real isolated local hub.
