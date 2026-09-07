#!/usr/bin/env python3
"""Ashcombe intake desk - the document parsing API.

Root-only. Installed outside the learner project. It takes a document and a
strategy and returns typed elements, and it keeps a per-run record of every
document it was asked to parse and what that cost, so a caller can tell which
strategy a pipeline actually chose.

Standard library only. The corpus module beside it is generated.
"""
import base64
import hashlib
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

try:
    from corpus import CORPUS, COST_PER_PAGE
except ImportError:  # running from the pack rather than from /opt
    import sys
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from corpus import CORPUS, COST_PER_PAGE

PORT = int(os.environ.get("ASHCOMBE_PORT", "8777"))
GRADER_KEY = "ashcombe-grader-ac5t"
GRADER_PREFIX = "/__ac5t"

STRATEGIES = tuple(sorted(COST_PER_PAGE))

_LOCK = threading.Lock()
_RUNS = {}


def _blank_run():
    return {"parses": [], "cost_units": 0, "unknown": 0}


def _run(run_id):
    return _RUNS.setdefault(run_id or "default", _blank_run())


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ashcombe-intake/1.0"

    def log_message(self, *args):
        return

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode())
        except Exception:
            return {}

    def _authorised(self):
        return self.headers.get("X-Grader-Key") == GRADER_KEY

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/health":
            return self._send(200, {"ok": True, "service": "ashcombe-intake"})
        if parsed.path == "/v1/samples":
            # The documents that ship with the project. No key: provisioning
            # writes them into the spool from here, and the learner already has
            # them.
            return self._send(200, {"documents": [
                {"name": entry["name"], "b64": entry["b64"]}
                for entry in sorted(CORPUS.values(), key=lambda e: e["name"])
                if entry["group"] == "sample"]})
        if parsed.path == "/v1/strategies":
            return self._send(200, {"strategies": list(STRATEGIES),
                                    "cost_per_page": dict(COST_PER_PAGE)})
        if parsed.path.startswith(GRADER_PREFIX):
            if not self._authorised():
                return self._send(404, {"error": "not found"})
            leaf = parsed.path[len(GRADER_PREFIX):]
            if leaf == "/trace":
                with _LOCK:
                    return self._send(200, dict(_run(query.get("run", [""])[0])))
            if leaf == "/corpus":
                which = query.get("set", ["graded"])[0]
                return self._send(200, {"documents": [
                    {"name": entry["name"], "sha256": digest,
                     "pages": entry["pages"],
                     "text_pages": entry["text_pages"],
                     "b64": entry["b64"]}
                    for digest, entry in sorted(CORPUS.items())
                    if entry["group"] == which]})
            if leaf == "/expected":
                digest = query.get("sha", [""])[0]
                entry = CORPUS.get(digest)
                if entry is None:
                    return self._send(404, {"error": "unknown document"})
                return self._send(200, {
                    "name": entry["name"], "pages": entry["pages"],
                    "text_pages": entry["text_pages"],
                    "plans": {s: len(entry["plans"][s]) for s in STRATEGIES}})
            return self._send(404, {"error": "not found"})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path.startswith(GRADER_PREFIX):
            if not self._authorised():
                return self._send(404, {"error": "not found"})
            if parsed.path[len(GRADER_PREFIX):] == "/reset":
                run_id = query.get("run", [""])[0] or "default"
                with _LOCK:
                    _RUNS[run_id] = _blank_run()
                return self._send(200, {"reset": run_id})
            return self._send(404, {"error": "not found"})

        if parsed.path != "/v1/parse":
            return self._send(404, {"error": "not found"})

        payload = self._body()
        strategy = payload.get("strategy")
        run_id = payload.get("run_id") or os.environ.get("ASHCOMBE_RUN_ID") \
            or "default"
        if strategy not in STRATEGIES:
            return self._send(400, {
                "error": "unknown strategy %r, expected one of %s"
                         % (strategy, ", ".join(STRATEGIES))})
        try:
            raw = base64.b64decode(payload.get("content_b64") or "")
        except Exception:
            return self._send(400, {"error": "content_b64 is not base64"})
        if not raw:
            return self._send(400, {"error": "no document content sent"})

        digest = hashlib.sha256(raw).hexdigest()
        entry = CORPUS.get(digest)
        if entry is None:
            with _LOCK:
                _run(run_id)["unknown"] += 1
            return self._send(422, {
                "error": "this intake account has no plan for that document",
                "sha256": digest})

        elements = entry["plans"][strategy]
        cost = COST_PER_PAGE[strategy] * entry["pages"]
        with _LOCK:
            record = _run(run_id)
            record["parses"].append({
                "name": payload.get("filename") or entry["name"],
                "sha256": digest, "strategy": strategy,
                "cost_units": cost, "elements": len(elements)})
            record["cost_units"] += cost

        return self._send(200, {"elements": elements, "pages": entry["pages"],
                                "strategy": strategy, "cost_units": cost})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
