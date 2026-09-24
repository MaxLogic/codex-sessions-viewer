"""Example external collector: emit ingest v1 JSON Lines, never open the DB.

Run: python samples/collector-contract/example_collector.py INPUT.json
"""

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

# This adapter's own parser version. Bump it whenever the records it emits
# for an unchanged source change, so stored sessions are reparsed. It is not
# the Codex parser version and not the viewer's cost projection version.
PARSER_VERSION = 1


def first_line(text: str) -> str:
    return text.splitlines()[0] if text.strip() else ""


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
            "first_line": first_line(message["text"]),
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
            # No usage events and no parent/fork lineage: nothing is left to
            # resolve, so the projection is complete. Omitted `usage` keeps
            # every token count null ("not reported"), never zero.
            "usage_projection_status": "complete",
            "title": next((r["first_line"] for r in records if r["first_line"]), None),
            "summary": next(
                (r["first_line"] for r in reversed(records) if r["first_line"]), None
            ),
            "started_at_utc": timestamp,
            "last_message_at_utc": timestamp,
            "parser_version": PARSER_VERSION,
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
