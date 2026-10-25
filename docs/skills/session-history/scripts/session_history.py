"""Launch the collector's read-only history queries.

All querying happens in `codex-sessions-collector.exe query ...`, which opens
the Windows-owned database read-only. This launcher only finds that
executable, converts WSL paths, and forwards arguments without a shell. It
contains no SQL and never opens the database itself.

Usage:
  session_history.py [--exe PATH] [--db PATH | --local | --hub URL [--hub-machine ID]]
                     <command> [options]

Commands: status, projects, sessions, search, session, messages, message,
export. Run `session_history.py help` for the full option list.

When CODEX_SESSIONS_HUB_URL is configured, queries go to that personal hub
unless --db or --local selects the local database. Without --hub-machine,
the query runs once per machine on the hub. The owner token comes from
CODEX_SESSIONS_HUB_OWNER_TOKEN or from the KEY=VALUE file named by
CODEX_SESSIONS_HUB_ENV_FILE, which may also map names to machine IDs with
CODEX_SESSIONS_HUB_MACHINE_ID_<NAME>=<id> lines. In WSL, unset values are read
from the Windows user environment.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request

EXE_NAME = "codex-sessions-collector.exe"
HUB_URL = "CODEX_SESSIONS_HUB_URL"
HUB_TOKEN = "CODEX_SESSIONS_HUB_OWNER_TOKEN"
HUB_ENV_FILE = "CODEX_SESSIONS_HUB_ENV_FILE"
MACHINE_PREFIX = "CODEX_SESSIONS_HUB_MACHINE_ID_"
# Only the database is a Windows file path. --path values stay as written:
# the collector matches both the Windows and the /mnt/<drive>/ form, and WSL
# sessions record Linux paths such as /home/me/project.
PATH_OPTIONS = ("--db",)
# Options that may appear before the command name.
LEADING_OPTIONS = ("--db", "--format")
CMD = "/mnt/c/Windows/System32/cmd.exe"
REG = "/mnt/c/Windows/System32/reg.exe"


def in_wsl() -> bool:
    if os.name == "nt":
        return False
    try:
        return "microsoft" in Path("/proc/version").read_text().lower()
    except OSError:
        return False


def find_exe(explicit: str | None) -> str:
    """Explicit --exe, then CODEX_SESSIONS_COLLECTOR, then the product
    repository's release folder next to this skill, then PATH."""
    candidates = []
    if explicit:
        candidates.append(Path(explicit))
    if os.environ.get("CODEX_SESSIONS_COLLECTOR"):
        candidates.append(Path(os.environ["CODEX_SESSIONS_COLLECTOR"]))
    # docs/skills/session-history/scripts -> repository root.
    repo = Path(__file__).resolve().parents[4]
    candidates.append(repo / "release" / "windows" / EXE_NAME)
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    found = shutil.which(EXE_NAME) or shutil.which("codex-sessions-collector")
    if found:
        return found
    raise FileNotFoundError(
        f"{EXE_NAME} was not found. Pass --exe PATH, set CODEX_SESSIONS_COLLECTOR, "
        "or build the release with scripts/build_windows.ps1."
    )


def to_windows(path: str) -> str:
    return subprocess.check_output(["wslpath", "-w", path], text=True).strip()


def split_launcher_options(argv: list[str]) -> tuple[dict[str, str | bool | None], list[str]]:
    """Take --exe, --local, --hub and --hub-machine out of the arguments."""
    options: dict[str, str | bool | None] = {"exe": None, "local": False, "hub": None, "hub_machine": None}
    names = {"--exe": "exe", "--hub": "hub", "--hub-machine": "hub_machine"}
    forwarded = []
    items = iter(argv)
    for item in items:
        name, has_value, value = item.partition("=")
        if item == "--local":
            options["local"] = True
        elif name in names:
            if not has_value:
                value = next(items, None)
                if value is None:
                    raise ValueError(f"{name} needs a value")
            options[names[name]] = value
        else:
            forwarded.append(item)
    return options, forwarded


def windows_variable(name: str) -> str | None:
    """A Windows user environment value seen from WSL, or None. The registry
    is read because a running WSL instance keeps the Windows environment of its
    start. Without interop the local path reports the missing prerequisite."""
    try:
        listing = subprocess.check_output([REG, "query", r"HKCU\Environment", "/v", name],
                                          cwd="/mnt/c", text=True, stderr=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return None
    for line in listing.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].lower() == name.lower() and parts[1].startswith("REG_"):
            return parts[2].strip() or None
    return None


def setting(name: str, wsl: bool) -> str | None:
    return os.environ.get(name) or (windows_variable(name) if wsl else None)


def read_env_file(path: str, wsl: bool) -> dict[str, str]:
    if wsl and len(path) > 2 and path[1] == ":":
        path = subprocess.check_output(["wslpath", "-u", path], text=True).strip()
    values = {}
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        key, sep, value = line.partition("=")
        if sep and not key.lstrip().startswith("#"):
            values[key.strip()] = value.strip()
    return values


def hub_machines(url: str, token: str) -> list[str]:
    request = urllib.request.Request(url.rstrip("/") + "/v1/machines",
                                     headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(request, timeout=15) as response:
        return list(json.load(response)["machines"])


def run_hub(executable: str, forwarded: list[str], url: str, token: str,
            machine: str | None, names: dict[str, str], wsl: bool) -> int:
    env = dict(os.environ, **{HUB_TOKEN: token})
    if wsl:
        env["WSLENV"] = ":".join(filter(None, [env.get("WSLENV"), HUB_TOKEN + "/w"]))
    labels = {machine_id: name for name, machine_id in names.items()}
    machines = [names.get(machine, machine)] if machine else hub_machines(url, token)
    text = "--format=text" in forwarded or any(
        item == "--format" and forwarded[index + 1:index + 2] == ["text"] for index, item in enumerate(forwarded))
    outcomes = []
    for machine_id in machines:
        result = subprocess.run([executable, "query", *forwarded, "--hub", url, "--hub-machine", machine_id],
                                env=env, capture_output=True, text=True, encoding="utf-8", check=False)
        outcomes.append((machine_id, result))
    if len(outcomes) == 1:
        sys.stdout.write(outcomes[0][1].stdout)
        sys.stderr.write(outcomes[0][1].stderr)
        return outcomes[0][1].returncode
    if text:
        for machine_id, result in outcomes:
            print(f"== {labels.get(machine_id, machine_id)} ({machine_id})")
            sys.stdout.write(result.stdout or result.stderr)
    else:
        merged = []
        for machine_id, result in outcomes:
            entry = {"machine": machine_id, "name": labels.get(machine_id), "exit_code": result.returncode}
            try:
                entry["result" if result.returncode == 0 else "error"] = json.loads(
                    result.stdout if result.returncode == 0 else result.stderr.splitlines()[0])
            except (json.JSONDecodeError, IndexError):
                entry["error"] = (result.stderr or result.stdout).strip()
            merged.append(entry)
        print(json.dumps({"hub": url, "read_only": True, "machines": merged}, ensure_ascii=False, indent=2))
    return 0 if all(result.returncode == 0 for _, result in outcomes) else 1


def windows_appdata_database() -> str:
    """The viewer's default database seen from WSL. WSL does not forward
    APPDATA to Windows programs unless WSLENV says so, so ask Windows."""
    appdata = subprocess.check_output(
        [CMD, "/c", "echo %APPDATA%"], cwd="/mnt/c", text=True
    ).strip()
    if not appdata or "%" in appdata:
        raise OSError("Windows APPDATA is unavailable from WSL; pass --db explicitly.")
    return appdata + "\\CodexSessionViewer\\codex_sessions_viewer.sqlite"


def split_leading_options(argv: list[str]) -> tuple[list[str], list[str]]:
    """Separate `--db X`, `--db=X`, `--format X` given before the command."""
    leading = []
    rest = list(argv)
    while rest and rest[0].split("=", 1)[0] in LEADING_OPTIONS:
        option = rest.pop(0)
        if "=" in option:
            name, value = option.split("=", 1)
            leading += [name, value]
        elif rest:
            leading += [option, rest.pop(0)]
        else:
            raise ValueError(f"{option} needs a value")
    return leading, rest


def windows_arguments(argv: list[str]) -> list[str]:
    """Convert /mnt/<drive>/ database paths for the Windows executable."""
    converted = list(argv)
    for index, value in enumerate(converted):
        if value in PATH_OPTIONS and index + 1 < len(converted):
            if converted[index + 1].startswith("/mnt/"):
                converted[index + 1] = to_windows(converted[index + 1])
        else:
            for option in PATH_OPTIONS:
                prefix = option + "="
                if value.startswith(prefix + "/mnt/"):
                    converted[index] = prefix + to_windows(value[len(prefix):])
    return converted


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    try:
        options, forwarded = split_launcher_options(argv)
        leading, forwarded = split_leading_options(forwarded)
        if not forwarded or forwarded[0] in ("-h", "--help"):
            forwarded = ["help"]
        # The collector accepts options anywhere after the command.
        forwarded = [forwarded[0], *leading, *forwarded[1:]]
        wsl = in_wsl()
        if not wsl and os.name != "nt":
            raise OSError("The history database is Windows-owned; run on Windows or in WSL with Windows interop.")
        executable = find_exe(options["exe"])
        local = options["local"] or "--db" in forwarded or forwarded[0] == "help"
        url = None if local else (options["hub"] or setting(HUB_URL, wsl))
        if url:
            env_file = setting(HUB_ENV_FILE, wsl)
            values = read_env_file(env_file, wsl) if env_file else {}
            token = setting(HUB_TOKEN, wsl) or values.get(HUB_TOKEN)
            if not token:
                raise ValueError(f"{HUB_TOKEN} is not set; set it or {HUB_ENV_FILE}, or pass --local.")
            names = {key[len(MACHINE_PREFIX):]: value for key, value in values.items()
                     if key.startswith(MACHINE_PREFIX)}
            return run_hub(executable, forwarded, url, token, options["hub_machine"], names, wsl)
        if options["hub_machine"]:
            raise ValueError("--hub-machine needs a hub: set CODEX_SESSIONS_HUB_URL or pass --hub, without --local or --db.")
        if wsl:
            forwarded = windows_arguments(forwarded)
            if forwarded[0] != "help" and "--db" not in forwarded:
                forwarded += ["--db", windows_appdata_database()]
        return subprocess.run([executable, "query", *forwarded], check=False).returncode
    except (OSError, ValueError, subprocess.SubprocessError, KeyError) as error:
        print(json.dumps({"error": str(error), "read_only": True}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
