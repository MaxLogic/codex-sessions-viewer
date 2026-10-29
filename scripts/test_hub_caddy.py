"""Opt-in CXV-203 integration: native Caddy + a scratch local hub.

Prerequisites and invocation: docs/hub-setup.md, "Local Caddy regression".
All endpoints use loopback; no Docker, installed app, or live hub is used.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import random
import socket
import sqlite3
import subprocess
import tempfile
import threading
import time
import urllib.request

TOKEN = "synthetic-cxv203-machine-token-123456789"


def port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--caddy", type=Path, required=True)
    parser.add_argument("--output-root", type=Path, required=True)
    parser.add_argument("--profile", choices=["debug", "release"], default="debug")
    parser.add_argument("--noise-mib", type=int, choices=range(0, 17), default=0,
                        help="seeded entropy inside the 56 MiB decoded fixture; 9 exposes the default-Caddy early-response reset")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    suffix = ".exe" if os.name == "nt" else ""
    binaries = repo / "collector" / "target" / args.profile
    collector = binaries / ("codex-sessions-collector" + suffix)
    hub_exe = binaries / ("codex-sessions-hub" + suffix)
    for binary in (collector, hub_exe, args.caddy):
        if not binary.is_file():
            parser.error(f"missing binary: {binary}")
    root = Path(tempfile.mkdtemp(prefix="caddy-busy-", dir=args.output_root.resolve()))
    print(root, flush=True)
    results = {"scratch_root": str(root), "commands": [], "passed": False}
    processes = []
    logs = []
    gate = None
    producer = None
    stop = threading.Event()
    env = os.environ.copy()
    env["CODEX_SESSIONS_HUB_MACHINE_TOKEN"] = TOKEN
    for key in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME"):
        isolated = root / key
        isolated.mkdir()
        env[key] = str(isolated)
    # Hide native children on Windows, retaining their exit and output.
    flags = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}

    def run(command, timeout=45):
        command = list(map(str, command))
        started = time.monotonic()
        try:
            done = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env,
                                  timeout=timeout, **flags)
        except subprocess.TimeoutExpired as error:
            # subprocess.run kills and waits for this child before raising.
            results["commands"].append({"command": command, "exit": None,
                "timed_out": True, "child_killed_and_waited": True,
                "seconds": time.monotonic() - started,
                "stdout": (error.stdout or b"").decode(errors="replace"),
                "stderr": (error.stderr or b"").decode(errors="replace")})
            raise
        result = {"command": command, "exit": done.returncode, "stdout": done.stdout,
                  "stderr": done.stderr, "seconds": time.monotonic() - started}
        results["commands"].append(result)
        return result

    def spawn(command, label):
        log = (root / f"{label}.log").open("w", encoding="utf-8")
        logs.append(log)
        child = subprocess.Popen(list(map(str, command)), stdout=log, stderr=log,
                                 env=env, **flags)
        processes.append(child)
        return child

    def sql(path, query):
        with sqlite3.connect(path) as conn:
            return conn.execute(query).fetchall()

    def require(condition, message):
        if not condition:
            raise AssertionError(message)

    try:
        version = run([args.caddy, "version"])
        require(version["exit"] == 0, version)
        results["caddy_sha256"] = hashlib.sha256(args.caddy.read_bytes()).hexdigest()
        hp, pp = port(), port()
        direct, proxy = f"http://127.0.0.1:{hp}", f"http://127.0.0.1:{pp}"
        db = root / "local.sqlite"
        enabled = run([collector, "hub", "enable", "--hub-url", proxy, "--standalone", db])
        require(enabled["exit"] == 0, enabled)
        machine = sql(db, "select value from app_metadata where key='machine_id'")[0][0]
        config = root / "hub.json"
        config.write_text(json.dumps({"owner_token": "synthetic-cxv203-owner-token-123456789",
                                      "machines": {machine: TOKEN},
                                      "request_timeout_seconds": 2}), encoding="utf-8")
        caddyfile = root / "Caddyfile"
        caddyfile.write_text(f"""{{
 admin off
 auto_https off
}}
http://127.0.0.1:{pp} {{
 log {{
  output file {(root / 'access.jsonl').as_posix()}
  format json
 }}
 request_body {{
  max_size 80MB
 }}
 reverse_proxy 127.0.0.1:{hp} {{
  transport http {{
   read_timeout 15m
   write_timeout 15m
  }}
 }}
}}
""", encoding="utf-8")
        spawn([hub_exe, f"127.0.0.1:{hp}", root / "hub-data", config], "hub")
        spawn([args.caddy, "run", "--config", caddyfile, "--adapter", "caddyfile"], "caddy")
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        deadline = time.monotonic() + 10
        while True:
            try:
                with opener.open(proxy + "/v1/health", timeout=1) as response:
                    require(response.status == 200, "health response")
                break
            except OSError:
                require(time.monotonic() < deadline, "local fixtures did not start")
                time.sleep(.05)
        ingested = run([collector, "codex", "ingest", "--standalone", db,
                        repo / "samples/sessions/sample_codex_jsonl_session.jsonl"])
        require(ingested["exit"] == 0, ingested)
        # A full-sized decoded record; opt-in entropy also stresses wire upload.
        entropy = base64.b64encode(random.Random(203).randbytes(args.noise_mib * 1024 * 1024)).decode()
        noise = entropy + "x" * (56 * 1024 * 1024 - len(entropy))
        results["noise_mib"] = args.noise_mib
        with sqlite3.connect(db) as conn:
            rows = conn.execute("select id,record_json from collector_upload_outbox order by id").fetchall()
            for row_id, payload in rows:
                record = json.loads(payload)
                if record["kind"] == "session_snapshot":
                    record["record"]["tool_calls"][0]["output_preview"] = noise
                    conn.execute("update collector_upload_outbox set record_json=? where id=?",
                                 (json.dumps(record, separators=(",", ":")), row_id))
                    large_id = row_id
                    break
            else:
                raise AssertionError("no snapshot in fixture")
        before = sql(db, "select id,record_json from collector_upload_outbox order by id")
        require(before[0][0] == large_id, "fixture must start with the oversized snapshot")
        results["decoded_record_bytes"] = sum(len(text.encode()) for _, text in before)
        require(results["decoded_record_bytes"] > 56 * 1024 * 1024, "large fixture missing")
        # A direct client owns the REAL hub's ingest gate after receiving 100.
        gate = socket.create_connection(("127.0.0.1", hp), timeout=5)
        gate.sendall(f"POST /v1/ingest HTTP/1.1\r\nHost: hub\r\nAuthorization: Bearer {TOKEN}\r\nContent-Length: 1048576\r\nExpect: 100-continue\r\n\r\n".encode())
        head = b""
        while not head.endswith(b"\r\n\r\n"):
            head += gate.recv(1)
        require(head.startswith(b"HTTP/1.1 100 Continue"), head)
        results["gate_response"] = head.decode()

        def progress():
            while not stop.wait(.2):
                try:
                    gate.sendall(b" ")
                except OSError:
                    return
        producer = threading.Thread(target=progress)
        producer.start()
        busy = run([collector, "hub", "sync", "--standalone", db], timeout=35)
        results["busy_observation"] = {
            "queue_unchanged": sql(db,"select id,record_json from collector_upload_outbox order by id") == before,
            "transport_failures": sql(db,"select key,value from app_metadata where key='hub.inflight_transport_failures'"),
            "inflight": sql(db,"select inflight_batch_id,inflight_last_id,last_sequence from collector_hub_state"),
        }
        require(busy["exit"] != 0 and "HTTP 503" in busy["stderr"] and
                "queued" in busy["stderr"], busy)
        require(busy["seconds"] < 30, "busy exhaustion exceeded bound")
        require(sql(db, "select id,record_json from collector_upload_outbox order by id") == before,
                "busy changed queued records")
        failures = sql(db, "select key,value from app_metadata where key='hub.inflight_transport_failures'")
        require(failures == [], f"busy counted as transport failure: {failures}")
        inflight = sql(db, "select inflight_batch_id,inflight_last_id,last_sequence from collector_hub_state")[0]
        results["busy_inflight"] = inflight
        require(inflight[0] and inflight[1] == large_id and inflight[2] == 0,
                "busy shrank batch or advanced sequence")
        with opener.open(proxy + "/v1/health", timeout=2) as response:
            require(response.status == 200, "health starved by gate")
        stop.set()
        producer.join(3)
        gate.close()
        gate = None
        success = run([collector, "hub", "sync", "--standalone", db], timeout=35)
        require(success["exit"] == 0, success)
        report = json.loads(success["stdout"])
        require(report["pending"] == 0 and report["dead_lettered"] == 0, report)
        remote = root / "hub-data" / f"{machine}.sqlite"
        received = sql(remote, "select sequence,batch_id from hub_received_batches order by sequence")
        require(received[0] == (1, inflight[0]), f"retry identity changed: {received}")
        require(sql(db, "select key,value from app_metadata where key='hub.inflight_transport_failures'") == [],
                "success recorded a transport failure")
        access = [json.loads(line) for line in (root / "access.jsonl").read_text().splitlines()]
        uploads = [item for item in access if item.get("request", {}).get("uri") == "/v1/ingest"]
        results["uploads"] = [{key: item.get(key) for key in ("status", "bytes_read", "duration")} for item in uploads]
        require([item["status"] for item in uploads] == [503] * 4 + [200] * report["batches"], uploads)
        if args.noise_mib:
            require(max(item.get("bytes_read", 0) for item in uploads) > args.noise_mib * 1024 * 1024,
                    "Caddy did not proxy the high-entropy wire body")
        results.update(passed=True, received_batches=received, sync_report=report,
                       transport_failure_rows=failures)
    except Exception as error:
        results["error"] = str(error)
        raise
    finally:
        stop.set()
        if producer is not None:
            producer.join(3)
        if gate is not None:
            gate.close()
        for child in reversed(processes):
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=10)
        for log in logs:
            log.close()
        access_path=root / "access.jsonl"
        if access_path.exists():
            access=[json.loads(line) for line in access_path.read_text().splitlines()]
            results["observed_uploads"]=[{key:item.get(key) for key in ("status","bytes_read","duration")} for item in access if item.get("request",{}).get("uri")=="/v1/ingest"]
        results["children_stopped"] = all(child.poll() is not None for child in processes)
        (root / "result.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
        print(json.dumps({"passed": results["passed"], "result": str(root / "result.json")}))


if __name__ == "__main__":
    main()
