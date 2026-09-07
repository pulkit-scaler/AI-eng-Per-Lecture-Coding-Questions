#!/usr/bin/env python3
"""Pelham finance desk - the analysis model behind the approval agent.

Root-only. Installed outside the learner project. It answers the analysis call
the agent makes while it is forming an intention, and keeps a per-run record of
what it was asked, so a caller can tell whether the agent really consulted it.

Standard library only.
"""
import json
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("PELHAM_PORT", "8766"))
GRADER_KEY = "pelham-grader-pm3x"
GRADER_PREFIX = "/__pm3x"

THRESHOLD = 100
VALID_CATEGORIES = ("meals", "travel", "software", "office_supplies")

# Wording that makes a finance team look twice, whatever the amount is.
HIGH_RISK = ("gift card", "cash advance", "no receipt", "reimburse a friend",
             "cryptocurrency")
MEDIUM_RISK = ("upgrade", "premium", "last minute")

_LOCK = threading.Lock()
_RUNS = {}


def _blank_run():
    return {"analysis_calls": 0, "prompts": [], "threads": []}


def _run(run_id):
    return _RUNS.setdefault(run_id or "default", _blank_run())


def analyse(text):
    """What the desk concludes about one claim, from its own text."""
    low = (text or "").lower()

    category = None
    match = re.search(r"category[\"']?\s*[:=]\s*[\"']?([a-z_]+)", low)
    if match:
        category = match.group(1)
    if category is None:
        for known in VALID_CATEGORIES:
            if known in low:
                category = known
                break
    category_valid = category in VALID_CATEGORIES

    risk = "low"
    if any(phrase in low for phrase in HIGH_RISK):
        risk = "high"
    elif any(phrase in low for phrase in MEDIUM_RISK):
        risk = "medium"

    if category_valid and risk == "low":
        reasoning = ("The category is on the approved list and nothing in the "
                     "description suggests a problem.")
    elif not category_valid:
        reasoning = ("The category is not on the approved list, so a person "
                     "should look at this one.")
    else:
        reasoning = ("The description carries wording this team reviews by "
                     "hand, so the risk is %s." % risk)

    return {"category_valid": bool(category_valid), "risk_level": risk,
            "reasoning": reasoning}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "pelham-desk/1.0"

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
            return self._send(200, {"ok": True, "service": "pelham-desk"})
        if parsed.path == "/v1/policy":
            return self._send(200, {"threshold_usd": THRESHOLD,
                                    "valid_categories": list(VALID_CATEGORIES)})
        if parsed.path.startswith(GRADER_PREFIX):
            if not self._authorised():
                return self._send(404, {"error": "not found"})
            leaf = parsed.path[len(GRADER_PREFIX):]
            if leaf == "/trace":
                with _LOCK:
                    return self._send(200, dict(_run(query.get("run", [""])[0])))
            if leaf == "/expected":
                return self._send(200, analyse(query.get("text", [""])[0]))
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

        payload = self._body()
        run_id = payload.get("run_id") or os.environ.get("PELHAM_RUN_ID") \
            or "default"

        if parsed.path in ("/v1/analyse", "/v1/chat"):
            if parsed.path == "/v1/chat":
                text = "\n".join((m.get("content") or "")
                                 for m in payload.get("messages") or [])
            else:
                text = payload.get("prompt") or ""
            with _LOCK:
                record = _run(run_id)
                record["analysis_calls"] += 1
                record["prompts"].append(text[:500])
                thread = payload.get("thread_id")
                if thread:
                    record["threads"].append(thread)
            result = analyse(text)
            if parsed.path == "/v1/chat":
                return self._send(200, {"content": json.dumps(result)})
            return self._send(200, result)

        return self._send(404, {"error": "not found"})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
