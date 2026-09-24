"""Run the public collector example through the real ingest CLI in isolation."""

import json
import sqlite3
import subprocess
import sys
import tempfile
from contextlib import closing
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / "samples/collector-contract/example_collector.py"
FIXTURE = ROOT / "samples/collector-contract/session.json"
EXE = ROOT / "collector/target/debug/codex-sessions-collector.exe"


def run(*args: object) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [str(arg) for arg in args], cwd=ROOT, capture_output=True, text=True
    )


def main() -> int:
    if not EXE.exists():
        build = run("cargo", "build", "--manifest-path", "collector/Cargo.toml")
        if build.returncode:
            print(build.stderr, file=sys.stderr)
            return build.returncode

    with tempfile.TemporaryDirectory(prefix="collector_contract_") as folder:
        db = Path(folder) / "example.sqlite"
        record = Path(folder) / "record.jsonl"
        generated = run(sys.executable, EXAMPLE, FIXTURE)
        if generated.returncode:
            print(generated.stderr, file=sys.stderr)
            return generated.returncode
        envelope = json.loads(generated.stdout)
        assert envelope["contract"] == "codex-sessions-viewer.ingest"
        assert envelope["version"] == 1
        assert envelope["kind"] == "session_snapshot"
        record.write_text(generated.stdout, encoding="utf-8")
        for _ in range(2):
            applied = run(EXE, "apply", "--standalone", db, "--input", record)
            if applied.returncode:
                print(applied.stderr, file=sys.stderr)
                return applied.returncode
        with closing(sqlite3.connect(db)) as conn:
            assert conn.execute("select count(*) from sessions").fetchone()[0] == 1
            assert conn.execute("select count(*) from messages").fetchone()[0] == 2
            assert conn.execute("select count(*) from message_search where message_search match 'searchable'").fetchone()[0] == 1

        envelope["version"] = 99
        record.write_text(json.dumps(envelope) + "\n", encoding="utf-8")
        rejected = run(EXE, "apply", "--standalone", db, "--input", record)
        assert rejected.returncode != 0, "unsupported contract version was accepted"
        with closing(sqlite3.connect(db)) as conn:
            assert conn.execute("select count(*) from sessions").fetchone()[0] == 1
    print("Collector example: valid, duplicate, search, and version rejection passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
