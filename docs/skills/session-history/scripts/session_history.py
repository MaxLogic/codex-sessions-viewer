"""Bounded, read-only access to the Windows-owned Codex Session Viewer index."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time


def windows_dispatch(argv):
    """Never let a Linux SQLite VFS open the Windows application database."""
    if os.name == "nt":
        return None
    if "microsoft" not in Path("/proc/version").read_text().lower():
        raise ValueError("This database requires Windows Python or WSL Windows interop.")
    def convert(value):
        return subprocess.check_output(["wslpath", "-w", value], text=True).strip()
    forwarded = list(argv)
    for i, value in enumerate(forwarded):
        if value in ("--db", "--path") and i + 1 < len(forwarded):
            if forwarded[i + 1].startswith("/mnt/"):
                forwarded[i + 1] = convert(forwarded[i + 1])
        elif value.startswith("--db=/mnt/") or value.startswith("--path=/mnt/"):
            key, path = value.split("=", 1)
            forwarded[i] = key + "=" + convert(path)
    return subprocess.run(
        ["/mnt/c/Windows/py.exe", "-3", convert(str(Path(__file__).resolve())), *forwarded],
        check=False,
    ).returncode


def bounded_int(low, high):
    def parse(value):
        number = int(value)
        if not low <= number <= high:
            raise argparse.ArgumentTypeError(f"must be between {low} and {high}")
        return number
    return parse


def utc(value):
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        value += "T00:00:00+00:00"
    stamp = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if stamp.tzinfo is None:
        raise ValueError("Timestamps require a timezone offset or a UTC calendar date.")
    return stamp.astimezone(dt.timezone.utc).isoformat()


def arguments(argv):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--db", type=Path)
    sub = p.add_subparsers(dest="command", required=True)
    sub.add_parser("status")
    for name in ("projects", "search", "messages", "message"):
        cmd = sub.add_parser(name)
        cmd.add_argument("--limit", type=bounded_int(1, 100), default=10)
        if name == "projects":
            continue
        cmd.add_argument("--chars", type=bounded_int(100, 8000), default=1200)
        cmd.add_argument("--include-tools", action="store_true")
        if name == "search":
            cmd.add_argument("--query", required=True)
            cmd.add_argument("--project")
            cmd.add_argument("--path")
            cmd.add_argument("--since")
            cmd.add_argument("--until")
            cmd.add_argument("--offset", type=bounded_int(0, 10000), default=0)
        else:
            cmd.add_argument("--session", required=True)
            if name == "messages":
                cmd.add_argument("--after-index", type=bounded_int(-1, 2147483647), default=-1)
            else:
                cmd.add_argument("--index", type=bounded_int(0, 2147483647), required=True)
                cmd.add_argument("--text-offset", type=bounded_int(0, 100000000), default=0)
    return p.parse_args(argv)


REQUIRED = {
    "sessions": {"id", "title", "project_id", "project_name_snapshot", "source_type",
                 "source_file_path", "working_directory_display", "working_directory_platform",
                 "last_parsed_utc", "scan_status", "parse_status"},
    "messages": {"id", "session_id", "message_index", "author_type", "created_at_utc",
                 "content_plain", "content_truncated"},
    "projects": {"id", "name"},
}


def connect(path):
    if not path.is_file():
        raise ValueError(f"Database does not exist: {path}; specify --db or index sessions in the app.")
    db = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=3)
    try:
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA query_only=ON")
        deadline = time.monotonic() + 10
        db.set_progress_handler(lambda: int(time.monotonic() > deadline), 10000)
        for table, expected in REQUIRED.items():
            columns = {row[1] for row in db.execute(f"PRAGMA table_info({table})")}
            if expected - columns:
                raise ValueError(f"Unsupported schema: {table} missing {sorted(expected - columns)}")
        return db
    except Exception:
        db.close()
        raise


def run(db, args):
    if args.command == "status":
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        meta = dict(db.execute("SELECT key,value FROM app_metadata WHERE key LIKE 'message_search.backfill.%' LIMIT 12")) if "app_metadata" in tables else {}
        return {"sqlite_version": sqlite3.sqlite_version, "schema_version": db.execute("SELECT max(version) FROM schema_version WHERE success=1").fetchone()[0] if "schema_version" in tables else None,
                "fts_available": "message_search" in tables, "backfill": meta,
                "coverage_note": "This is the existing index; missing or stale source files are not scanned."}
    if args.command == "projects":
        rows = db.execute("SELECT id,name FROM projects ORDER BY name COLLATE NOCASE,id LIMIT ?", (args.limit + 1,)).fetchall()
        return {"results": [dict(r) for r in rows[:args.limit]], "has_more": len(rows) > args.limit}
    where, params = [], []
    join = ""
    if not args.include_tools:
        where.append("m.author_type IN ('user','assistant')")
    offset = 0
    if args.command == "search":
        terms = re.findall(r"\w+", args.query, re.UNICODE)
        if not terms or len(terms) > 30 or len(args.query) > 2000:
            raise ValueError("Search requires 1-30 literal words, at most 2000 characters.")
        join = "JOIN message_search ON message_search.rowid=m.id"
        where.append("message_search MATCH ?")
        params.append(" AND ".join('"' + word + '"' for word in terms))
        if args.project:
            where.append("coalesce(p.name,s.project_name_snapshot,'') = ? COLLATE NOCASE")
            params.append(args.project)
        if args.path:
            path = args.path.replace("\\", "/").rstrip("/").lower()
            expr = "lower(replace(coalesce(nullif(s.working_directory_platform,''),s.working_directory_display,''),char(92),'/'))"
            where.append(f"({expr}=? OR substr({expr},1,?)=?)")
            params.extend((path, len(path) + 1, path + "/"))
        for name, operator in (("since", ">="), ("until", "<")):
            if getattr(args, name):
                where.append(f"julianday(m.created_at_utc) {operator} julianday(?)")
                params.append(utc(getattr(args, name)))
        if args.since and args.until and utc(args.since) >= utc(args.until):
            raise ValueError("--since must precede --until.")
        offset = args.offset
        order = "julianday(m.created_at_utc) DESC,m.session_id,m.message_index"
    else:
        where.append("s.id=?")
        params.append(args.session)
        where.append("m.message_index " + (">?" if args.command == "messages" else "=?"))
        params.append(args.after_index if args.command == "messages" else args.index)
        order = "m.message_index"
    text_offset = getattr(args, "text_offset", 0)
    limit = 1 if args.command == "message" else args.limit
    text = "snippet(message_search,0,'[',']','...',24)" if args.command == "search" else "substr(coalesce(m.content_plain,''),?,?)"
    text_params = [] if args.command == "search" else [text_offset + 1, args.chars]
    rows = db.execute(f"""
        SELECT s.id AS session_id,s.title,coalesce(p.name,s.project_name_snapshot,'') AS project,
          s.source_type,s.source_file_path,s.last_parsed_utc,s.scan_status,s.parse_status,
          m.message_index,m.author_type,m.created_at_utc,
          {text} AS excerpt,length(coalesce(m.content_plain,'')) AS content_length,
          m.content_truncated AS source_content_truncated
        FROM messages m JOIN sessions s ON s.id=m.session_id
        LEFT JOIN projects p ON p.id=s.project_id {join}
        WHERE {' AND '.join(where)} ORDER BY {order} LIMIT ? OFFSET ?
        """, [*text_params, *params, limit + 1, offset]).fetchall()
    results = []
    for row in rows[:limit]:
        item = dict(row)
        item["reference"] = f"{item['session_id']}#message-{item['message_index']}"
        item["excerpt"] = (item["excerpt"] or "")[:args.chars]
        item["excerpt_truncated"] = args.command == "search" or item["content_length"] > text_offset + len(item["excerpt"])
        if args.command == "message":
            item["next_text_offset"] = text_offset + len(item["excerpt"]) if item["excerpt_truncated"] else None
        results.append(item)
    result = {"results": results, "has_more": len(rows) > limit}
    if args.command == "search":
        result["next_offset"] = offset + limit if result["has_more"] else None
    elif args.command == "messages":
        result["next_after_index"] = results[-1]["message_index"] if result["has_more"] else None
    return result


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    try:
        forwarded = windows_dispatch(argv)
        if forwarded is not None:
            return forwarded
        args = arguments(argv)
        if args.db is None:
            appdata = os.environ.get("APPDATA")
            if not appdata:
                raise ValueError("APPDATA is unavailable; supply --db explicitly.")
            args.db = Path(appdata) / "CodexSessionViewer" / "codex_sessions_viewer.sqlite"
        db = connect(args.db)
        try:
            db.execute("BEGIN")
            output = run(db, args)
        finally:
            db.close()
        print(json.dumps({"database": str(args.db.resolve()), "read_only": True, **output}, ensure_ascii=True))
        return 0
    except (OSError, ValueError, sqlite3.Error, subprocess.SubprocessError) as error:
        print(json.dumps({"error": str(error), "read_only": True}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
