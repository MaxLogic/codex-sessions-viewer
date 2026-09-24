"""Verify the session-history skill against the collector's query contract.

Runs every documented launcher example from SKILL.md against an isolated
fixture database, checks that returned references resolve, that the database
is unchanged afterwards, and that neither the skill nor its launcher depends
on a hub, a network service, or writable SQL.

Usage: python scripts/verify_session_query_skill.py
Set CODEX_SESSIONS_COLLECTOR to test a specific executable; otherwise the
repository's collector is built in debug mode.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

REPO = Path(__file__).resolve().parents[1]
SKILL = REPO / "docs" / "skills" / "session-history"
LAUNCHER = SKILL / "scripts" / "session_history.py"
sys.path.insert(0, str(SKILL / "evals"))
import fixture  # noqa: E402

FAILURES: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        FAILURES.append(message)


def documented_commands(text: str) -> list[list[str]]:
    """Launcher invocations from fenced code blocks, as argument lists."""
    commands = []
    for block in re.findall(r"```[a-z]*\n(.*?)```", text, re.S):
        for line in block.splitlines():
            if "session_history.py" in line:
                commands.append(shlex.split(line.strip(), posix=True))
    return commands


def run_launcher(exe: Path, db: Path, args: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(LAUNCHER), "--exe", str(exe), "--db", str(db), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )


def fingerprint(db: Path) -> tuple[str, int]:
    wal = Path(f"{db}-wal")
    return hashlib.sha256(db.read_bytes()).hexdigest(), wal.stat().st_size if wal.exists() else 0


def main() -> int:
    skill_text = (SKILL / "SKILL.md").read_text(encoding="utf-8")
    reference_text = (SKILL / "references" / "database.md").read_text(encoding="utf-8")
    launcher_text = LAUNCHER.read_text(encoding="utf-8")

    # No hub, network, or write dependency in the skill or its launcher.
    for name, text in (("SKILL.md", skill_text), ("database.md", reference_text), ("launcher", launcher_text)):
        check(not re.search(r"https?://", text), f"{name} mentions a network URL")
        check(not re.search(r"\bhub\b", text, re.I), f"{name} depends on a hub")
    check("import sqlite3" not in launcher_text, "the launcher opens SQLite itself")
    for statement in re.findall(r"```sql\n(.*?)```", reference_text, re.S):
        check(
            not re.search(r"\b(insert|update|delete|create|drop|alter|replace|attach|vacuum|reindex)\b", statement, re.I),
            "a documented SQL example writes to the database",
        )

    exe = fixture.collector_exe()
    with tempfile.TemporaryDirectory(prefix="verify-session-query-") as temp:
        db = fixture.build(Path(temp) / "fixture.sqlite", exe)
        # Settle the WAL so the fingerprint covers all committed content.
        subprocess.run(
            [sys.executable, "-c", f"import sqlite3; c=sqlite3.connect(r'{db}'); c.execute('pragma wal_checkpoint(TRUNCATE)'); c.close()"],
            check=True,
        )
        before = fingerprint(db)

        status = json.loads(run_launcher(exe, db, ["status"]).stdout)
        machine = status["machine_id"]
        session_ref = f"history://{machine}/codex/s-a"
        message_ref = f"{session_ref}#3"
        paged = json.loads(
            run_launcher(exe, db, ["search", "--project", "Atlas", "--query", "shutdown queue", "--limit", "1"]).stdout
        )
        cursor = paged.get("next_cursor")
        check(bool(cursor), "the fixture search did not produce a cursor")
        substitutions = {
            "<session-ref>": session_ref,
            "<message-ref>": message_ref,
            "<cursor>": cursor or "",
        }

        commands = documented_commands(skill_text)
        check(len(commands) >= 9, f"expected the documented examples, found {len(commands)}")
        references: set[str] = set()
        for command in commands:
            script_index = next(i for i, part in enumerate(command) if part.endswith("session_history.py"))
            args = [substitutions.get(part, part) for part in command[script_index + 1:]]
            result = run_launcher(exe, db, args)
            label = " ".join(command[script_index + 1:])
            if result.returncode != 0:
                check(False, f"documented example failed ({result.returncode}): {label}\n{result.stderr}")
                continue
            payload = json.loads(result.stdout)
            check(payload.get("read_only") is True, f"not reported read-only: {label}")
            check(payload.get("contract") == "codex-sessions-viewer.query", f"wrong contract: {label}")
            for row in payload.get("results", []):
                if "#" in row.get("reference", ""):
                    references.add(row["reference"])
            if "result" in payload:
                references.add(payload["result"]["reference"])

        check(bool(references), "no documented example returned a message reference")
        for reference in sorted(references):
            result = run_launcher(exe, db, ["message", "--ref", reference, "--chars", "100"])
            resolved = json.loads(result.stdout)["result"]["reference"] if result.returncode == 0 else None
            check(resolved == reference, f"reference does not resolve: {reference}")

        check(fingerprint(db) == before, "the database changed during read-only queries")

    if FAILURES:
        for failure in FAILURES:
            print(f"FAIL: {failure}")
        return 1
    print(f"Session query skill verified: {len(commands)} documented examples, {len(references)} references resolved.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
