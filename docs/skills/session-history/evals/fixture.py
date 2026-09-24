"""Isolated history fixtures built through the collector's own ingest path.

The fixture is a standalone collector database created by
`codex-sessions-collector.exe apply --standalone`, so it has the real schema
and views without touching the viewer's database.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess

REPO = Path(__file__).resolve().parents[4]


def collector_exe() -> Path:
    """CODEX_SESSIONS_COLLECTOR, else a fresh debug build of the repository."""
    configured = os.environ.get("CODEX_SESSIONS_COLLECTOR")
    if configured:
        return Path(configured)
    subprocess.run(
        ["cargo", "build", "--quiet", "--manifest-path", str(REPO / "collector" / "Cargo.toml")],
        check=True,
    )
    return REPO / "collector" / "target" / "debug" / "codex-sessions-collector.exe"


def _message(index, author, at, text):
    return {
        "index": index,
        "author_type": author,
        "raw_type": "message",
        "created_at_utc": at,
        "first_line": text.splitlines()[0] if text else "",
        "content_plain": text,
        "content_preview": text[:200],
        "content_truncated": False,
    }


def _session(harness, session_id, directory, project, messages):
    path = f"C:\\fixtures\\{harness}\\{session_id}.jsonl"
    stamps = [m["created_at_utc"] for m in messages if m["created_at_utc"]]
    return {
        "contract": "codex-sessions-viewer.ingest",
        "version": 1,
        "kind": "session_snapshot",
        "record": {
            "harness": harness,
            "source": {
                "path": path,
                "environment": "windows",
                "state": "active",
                "status": "available",
                "size": 100,
                "modified_utc": "2026-09-10T08:00:00.000Z",
                "display_path": path,
                "mapped_source_file_path": path,
                "platform_path": path,
                "normalized_path_keys": [path.replace("\\", "/").lower()],
            },
            "session": {
                "session_id": session_id,
                "usage_projection_status": "complete",
                "parser_version": 4,
                "working_directory_display": directory,
                "working_directory_platform": directory,
                "title": "Queue investigation",
                "started_at_utc": min(stamps) if stamps else None,
                "last_message_at_utc": max(stamps) if stamps else None,
            },
            "messages": messages,
            "project_hints": [{"working_directory": directory, "project_name": project}],
        },
    }


def records():
    long_text = "shutdown queue: claimed fixed, no commit or test evidence. " + "x" * 9000
    return [
        _session("codex", "s-a", "F:\\projects\\Atlas", "Atlas", [
            _message(0, "user", "2026-09-09T08:00:00Z", "Investigate shutdown queue race."),
            _message(1, "assistant", "2026-09-09T08:01:00Z", "Proposed closing the queue under one lock. Not implemented yet."),
            _message(2, "tool", "2026-09-09T08:02:00Z", "shutdown queue test failed"),
            _message(3, "assistant", "2026-09-09T08:03:00Z", long_text),
            _message(4, "user", None, "shutdown queue with no timestamp"),
        ]),
        _session("codex", "s-b", "F:\\projects\\Atlas-old", "Atlas-old", [
            _message(0, "assistant", "2026-09-09T08:04:00Z", "shutdown queue unrelated sibling project"),
        ]),
        _session("claude", "c-1", "F:\\projects\\Atlas", "Atlas", [
            _message(0, "user", "2026-09-10T09:00:00Z", "claude reviewed the shutdown queue lock"),
        ]),
    ]


def build(database: Path, exe: Path | None = None) -> Path:
    """Create `database` with the fixture sessions and return it."""
    exe = exe or collector_exe()
    lines = "\n".join(json.dumps(record) for record in records())
    result = subprocess.run(
        [str(exe), "apply", "--standalone", str(database)],
        input=lines,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if result.returncode != 0:
        raise RuntimeError(f"fixture apply failed: {result.stderr}")
    return database
