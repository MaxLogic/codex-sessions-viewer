"""Example external collector: emit ingest v1 JSON Lines, never open the DB.

Run: python samples/collector-contract/example_collector.py INPUT.json
"""

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--harness", default="example")
    parser.add_argument("--machine-id")
    args = parser.parse_args()

    source = args.source.resolve()
    transcript = json.loads(source.read_text(encoding="utf-8"))
    messages = transcript["messages"]
    modified = datetime.fromtimestamp(source.stat().st_mtime, timezone.utc)
    timestamp = modified.isoformat().replace("+00:00", "Z")
    records = [
        {
            "index": index,
            "author_type": message["role"],
            "first_line": message["text"].splitlines()[0],
            "content_plain": message["text"],
            "content_preview": message["text"][:240],
        }
        for index, message in enumerate(messages)
    ]
    snapshot = {
        "harness": args.harness,
        "machine_id": args.machine_id,
        "source": {
            "path": str(source),
            "environment": "windows",
            "state": "active",
            "status": "available",
            "size": source.stat().st_size,
            "modified_utc": timestamp,
            "display_path": str(source),
            "mapped_source_file_path": str(source),
            "platform_path": str(source),
        },
        "session": {
            "session_id": transcript["session_id"],
            "usage_projection_status": "complete",
            "title": records[0]["first_line"] if records else None,
            "summary": records[-1]["first_line"] if records else None,
            "started_at_utc": timestamp,
            "last_message_at_utc": timestamp,
            "parser_version": 4,
            "usage": {},
        },
        "messages": records,
        "tool_calls": [],
        "usage_events": [],
        "extra": {"unmodelled_example": transcript.get("extra")},
    }
    print(
        json.dumps(
            {
                "contract": "codex-sessions-viewer.ingest",
                "version": 1,
                "kind": "session_snapshot",
                "record": snapshot,
            },
            ensure_ascii=False,
        )
    )


if __name__ == "__main__":
    main()
