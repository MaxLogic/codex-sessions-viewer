"""Run the public collector example through the real ingest CLI in isolation.

Always rebuilds the collector, then runs the commands documented in
docs/collectors/contract-v1.md and the contract's acceptance cases against a
temporary standalone database. Exits non-zero on the first failed check.
"""

import json
import shlex
import sqlite3
import subprocess
import sys
import tempfile
from contextlib import closing
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "samples/collector-contract/example_collector.py"
FIXTURE = ROOT / "samples/collector-contract/session.json"
CONTRACT_DOC = ROOT / "docs/collectors/contract-v1.md"
EXE = ROOT / "collector/target/debug/codex-sessions-collector.exe"
DOC_EXE = "collector/target/debug/codex-sessions-collector.exe"


class CheckFailed(Exception):
    pass


def check(condition: bool, message: str) -> None:
    if not condition:
        raise CheckFailed(message)


def run(*args: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(arg) for arg in args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )


def succeeded(result: subprocess.CompletedProcess[str], what: str) -> str:
    check(result.returncode == 0, f"{what} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout


def count(db: Path, sql: str) -> int:
    with closing(sqlite3.connect(db)) as conn:
        return conn.execute(sql).fetchone()[0]


def sessions(db: Path) -> int:
    return count(db, "select count(*) from sessions")


def generate(source: Path, *args: str) -> dict:
    output = succeeded(run(sys.executable, EXAMPLE, source, *args), "example collector")
    envelope = json.loads(output)
    check(envelope.get("contract") == "codex-sessions-viewer.ingest", "wrong contract name")
    check(envelope.get("version") == 1, "wrong contract version")
    check(envelope.get("kind") == "session_snapshot", "wrong record kind")
    return envelope


def apply(folder: Path, db: Path, line: str) -> subprocess.CompletedProcess[str]:
    record = folder / "record.jsonl"
    record.write_text(line + "\n", encoding="utf-8")
    return run(EXE, "apply", "--standalone", db, "--input", record)


def documented_commands(folder: Path) -> None:
    """Run the first PowerShell block of the contract document verbatim,
    redirecting its example.* files into the temporary folder."""
    text = CONTRACT_DOC.read_text(encoding="utf-8")
    block = text.split("```powershell\n", 1)[1].split("```", 1)[0]
    lines = [line for line in block.splitlines() if line.strip()]
    check(len(lines) >= 3, "contract document lost its example commands")
    searched = False
    for line in lines:
        tokens = [
            str(folder / token) if token.startswith("example.") else token
            for token in shlex.split(line)
        ]
        target = None
        if ">" in tokens:
            index = tokens.index(">")
            target = Path(tokens[index + 1])
            tokens = tokens[:index]
        if tokens[0] == "python":
            tokens[0] = sys.executable
        elif tokens[0] == DOC_EXE:
            tokens[0] = str(EXE)
        else:
            raise CheckFailed(f"unexpected documented command: {line}")
        output = succeeded(run(*tokens), f"documented command `{line}`")
        if target is not None:
            target.write_text(output, encoding="utf-8")
        if tokens[1:3] == ["query", "search"]:
            results = json.loads(output)["results"]
            check(len(results) == 1, f"documented search returned {len(results)} hits")
            check(results[0]["harness"] == "example", "search hit has the wrong harness")
            searched = True
    check(searched, "contract document no longer demonstrates query search")


def main() -> int:
    succeeded(
        run("cargo", "build", "--locked", "--manifest-path", "collector/Cargo.toml"),
        "cargo build",
    )
    with tempfile.TemporaryDirectory(prefix="collector_contract_") as name:
        folder = Path(name)
        documented_commands(folder)

        db = folder / "cases.sqlite"
        source = folder / "session.json"
        source.write_bytes(FIXTURE.read_bytes())
        good = generate(source)
        for _ in range(2):
            succeeded(apply(folder, db, json.dumps(good)), "valid snapshot")
        check(sessions(db) == 1, "duplicate delivery did not converge on one session")
        check(count(db, "select count(*) from messages") == 2, "unexpected message count")
        check(
            count(db, "select count(*) from message_search where message_search match 'searchable'") == 1,
            "applied message is not searchable",
        )

        transcript = json.loads(source.read_text(encoding="utf-8"))
        transcript["messages"].append(
            {"role": "assistant", "text": "A changed revision replaces the old snapshot."}
        )
        source.write_text(json.dumps(transcript), encoding="utf-8")
        succeeded(apply(folder, db, json.dumps(generate(source))), "changed revision")
        check(sessions(db) == 1, "changed revision created another session")
        check(count(db, "select count(*) from messages") == 3, "changed revision did not replace messages")

        unknown = json.loads(json.dumps(good))
        unknown["record"]["future_optional_field"] = {"retained_by_source": True}
        unknown["record"]["session"]["future_session_field"] = 1
        succeeded(apply(folder, db, json.dumps(unknown)), "unknown optional fields")
        check(sessions(db) == 1, "unknown fields changed session identity")

        for label, line in [
            ("malformed JSON", "{not-json}"),
            ("unsupported version", json.dumps({**good, "version": 99})),
            ("wrong contract", json.dumps({**good, "contract": "wrong"})),
            ("unknown kind", json.dumps({**good, "kind": "wrong"})),
        ]:
            check(apply(folder, db, line).returncode != 0, f"{label} was accepted")
            check(sessions(db) == 1, f"{label} wrote to the database")

        other = generate(source, "--harness", "another")
        succeeded(apply(folder, db, json.dumps(other)), "same native ID from another harness")
        check(sessions(db) == 2, "harnesses sharing a native session ID collided")
        foreign = generate(source, "--machine-id", "another-machine")
        check(apply(folder, db, json.dumps(foreign)).returncode != 0, "foreign machine ID was accepted")
        check(sessions(db) == 2, "foreign machine record wrote to the database")

        empty = folder / "empty.json"
        empty.write_text(
            json.dumps({"session_id": "empty-001", "messages": [{"role": "user", "text": ""}]}),
            encoding="utf-8",
        )
        succeeded(apply(folder, db, json.dumps(generate(empty))), "empty message")
        check(sessions(db) == 3, "empty-message session was not stored")
    print(
        "Collector example: documented commands, duplicate delivery, search, changed revision, "
        "unknown fields, malformed/unsupported rejection, harness collision, foreign machine "
        "and empty message passed."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CheckFailed as failure:
        print(f"FAIL: {failure}", file=sys.stderr)
        raise SystemExit(1)
