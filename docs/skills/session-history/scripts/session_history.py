"""Launch the collector's read-only history queries.

All querying happens in `codex-sessions-collector.exe query ...`, which opens
the Windows-owned database read-only. This launcher only finds that
executable, converts WSL paths, and forwards arguments without a shell. It
contains no SQL and never opens the database itself.

Usage:
  session_history.py [--exe PATH] [--db PATH] <command> [options]

Commands: status, projects, sessions, search, session, messages, message,
export. Run `session_history.py help` for the full option list.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

EXE_NAME = "codex-sessions-collector.exe"
# Only the database is a Windows file path. --path values stay as written:
# the collector matches both the Windows and the /mnt/<drive>/ form, and WSL
# sessions record Linux paths such as /home/me/project.
PATH_OPTIONS = ("--db",)
# Options that may appear before the command name.
LEADING_OPTIONS = ("--db", "--format")
CMD = "/mnt/c/Windows/System32/cmd.exe"


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


def split_launcher_options(argv: list[str]) -> tuple[str | None, list[str]]:
    exe = None
    forwarded = []
    items = iter(argv)
    for item in items:
        if item == "--exe":
            exe = next(items, None)
            if exe is None:
                raise ValueError("--exe needs a value")
        elif item.startswith("--exe="):
            exe = item.split("=", 1)[1]
        else:
            forwarded.append(item)
    return exe, forwarded


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
        exe, forwarded = split_launcher_options(argv)
        leading, forwarded = split_leading_options(forwarded)
        if not forwarded or forwarded[0] in ("-h", "--help"):
            forwarded = ["help"]
        # The collector accepts options anywhere after the command.
        forwarded = [forwarded[0], *leading, *forwarded[1:]]
        wsl = in_wsl()
        if wsl:
            forwarded = windows_arguments(forwarded)
            if forwarded[0] != "help" and "--db" not in forwarded:
                forwarded += ["--db", windows_appdata_database()]
        elif os.name != "nt":
            raise OSError("The history database is Windows-owned; run on Windows or in WSL with Windows interop.")
        executable = find_exe(exe)
        return subprocess.run([executable, "query", *forwarded], check=False).returncode
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(json.dumps({"error": str(error), "read_only": True}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
