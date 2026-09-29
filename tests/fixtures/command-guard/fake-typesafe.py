#!/usr/bin/env python3
# A stand-in for the TypeSafe System One endpoint, for tests/fm-command-guard.test.sh.
#
# Usage: fake-typesafe.py <dir>
# Listens on 127.0.0.1 on a free port and writes the port to <dir>/port.
# Every request appends its body to <dir>/requests.jsonl and its Authorization
# header to <dir>/auth, then waits <dir>/delay seconds when that file exists and
# answers with <dir>/status (default 200) and the current <dir>/response.json.
# The test rewrites those files between cases, so one server serves the suite.
import http.server
import json
import pathlib
import sys
import time

DIR = pathlib.Path(sys.argv[1])


def read(name, default):
    try:
        return (DIR / name).read_text(encoding="utf-8").strip()
    except OSError:
        return default


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):  # noqa: N802 - the stdlib's name
        body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode("utf-8")
        with open(DIR / "requests.jsonl", "a", encoding="utf-8") as handle:
            handle.write(json.dumps(json.loads(body)) + "\n")
        with open(DIR / "auth", "a", encoding="utf-8") as handle:
            handle.write(self.headers.get("Authorization", "") + "\n")
        time.sleep(float(read("delay", "0") or "0"))
        payload = read("response.json", "{}").encode("utf-8")
        try:
            self.send_response(int(read("status", "200")))
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except OSError:
            pass

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(DIR / "port").write_text(str(server.server_address[1]), encoding="utf-8")
server.serve_forever()
